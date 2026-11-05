defmodule PhoenixKitAgent.Telegram.Turn do
  @moduledoc """
  One message of a linked chat, carried through the agent: the person's
  current Telegram conversation (or a new one), the turn, and the answer in
  the chat. The turn is the person's own: their model, limits, instructions
  and spending (`PhoenixKitAgent.Turns.start/6` with the chat reference).

  The reaction tells how it went: 👀 while the agent works (with "typing…"
  every 4 seconds), then 👍 with the answer, or 🤷 with a short explanation
  when the turn was refused, ended in a notice, asked for a change the chat
  may not make (a tool of the turn was denied) or when the answer could not
  be sent. A turn that ended with a change held for the user's confirmation
  says what the assistant said (if it said anything), then sends the card
  (`PhoenixKitAgent.Telegram.Cards`): 👍; when the card could not be sent, one
  message that sends the person to the site, and 🤷. The topic of the
  conversation is subscribed **before** the turn starts, so its end cannot be
  missed; the wait is the turn's deadline plus a minute. If this process dies
  mid-turn (a deploy), the message keeps its 👀 and is not answered.

  A voice message (`:voice` job) is written down first
  (`PhoenixKitAgent.Speech`), before any download: the speech model must be
  set, the chat's link and rights are checked as a text turn's are, and a
  recording of more than two minutes or ten megabytes is refused. The words
  are sent back as "🎙 Recognised: …", and then the turn runs on them exactly as
  on a typed message. When it cannot be written down, the person is told why
  (🤷) and no turn is started.

  A picture (`:photo` job: a photo, or a document that is a jpeg, png or webp)
  is added to the person's Telegram conversation as the chat panel's upload is
  (`PhoenixKitAgent.Attachments.add_picture_for_telegram/4`: the same checks,
  storage, processing and limits; the model sees pixels or a description as
  `Processor.picture_mode/1` says, and a person whose model cannot see and who
  has no vision model is told so). The turn waits, for a bounded time, for the
  picture to be read, and then runs on the caption (or "What is in this
  picture?") with the picture. The pictures of one album are one question: the
  first one waits a moment, takes the others (`ChatQueue.take_siblings/3`), and
  all that could be read go in one message with the first caption there is. A
  picture that is not read, or a turn that is refused, leaves no file behind.

  The job holds the text of the message (the caption, the recording) only
  while it runs; nothing of it is logged.
  """

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Utils.Routes
  use Gettext, backend: PhoenixKitAgent.Gettext

  alias PhoenixKitAgent.{Attachments, Config, Conversations, Speech, Turns}
  alias PhoenixKitAgent.Attachments.Bounds
  alias PhoenixKitAgent.Telegram.{Bridge, Cards, ChatQueue, Client, Format, Texts}

  @typing_every_ms 4_000
  @grace_ms 60_000

  @doc "Runs `job` (see `PhoenixKitAgent.Telegram.Bridge`) for the chat `ref` of the bot."
  @spec run(String.t(), Bridge.ref(), map()) :: :ok
  def run(connection_uuid, {:telegram_link, user_uuid, _connection, chat_id} = ref, job) do
    Bridge.safely(fn ->
      Bridge.in_locale(user_uuid, fn locale ->
        case job.kind do
          :new -> new_conversation(connection_uuid, ref, job, user_uuid, chat_id)
          :turn -> converse(connection_uuid, ref, job, user_uuid, chat_id, locale)
          :voice -> voice(connection_uuid, ref, job, user_uuid, chat_id, locale)
          :photo -> photo(connection_uuid, ref, job, user_uuid, chat_id, locale)
        end
      end)
    end)
  end

  defp new_conversation(connection_uuid, ref, job, user_uuid, chat_id) do
    case start_conversation(user_uuid, ref) do
      {:ok, _conversation} ->
        reply(connection_uuid, chat_id, job.message_id, Texts.static(:new_started))

      {:error, _changeset} ->
        refuse(connection_uuid, chat_id, job.message_id, :not_found)
    end
  end

  # A voice message: written down, shown, and then the turn of what it said.
  defp voice(connection_uuid, ref, job, user_uuid, chat_id, locale) do
    Bridge.react(connection_uuid, chat_id, job.message_id, "👀")
    _ = Client.impl().typing(connection_uuid, chat_id)

    with {:ok, bytes} <- recording(connection_uuid, ref, job.voice),
         {:ok, text} <- Speech.transcribe(ref, bytes, job.voice.format, impersonated: false) do
      Bridge.say(connection_uuid, chat_id, Texts.recognised(text))
      converse(connection_uuid, ref, %{job | kind: :turn, text: text}, user_uuid, chat_id, locale)
    else
      {:error, reason} ->
        refuse_with(connection_uuid, chat_id, job.message_id, Texts.speech(reason))
    end
  end

  # The recording, once the person is known to be allowed to ask for it and it
  # is no longer or larger than a recognition takes.
  defp recording(connection_uuid, ref, voice) do
    with :ok <- speech_on(),
         {:ok, _user_uuid} <- Conversations.authorize_session(ref, impersonated: false),
         :ok <- within_bounds(voice) do
      download(connection_uuid, voice.file_id)
    end
  end

  defp speech_on, do: if(Config.speech?(), do: :ok, else: {:error, :speech_off})

  defp within_bounds(%{duration: duration, size: size}) do
    if too?(duration, Speech.max_seconds()) or too?(size, Speech.max_bytes()),
      do: {:error, :too_long},
      else: :ok
  end

  defp too?(value, max), do: is_integer(value) and value > max

  defp download(connection_uuid, file_id) do
    case fetch(connection_uuid, file_id, Speech.max_bytes()) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :too_large} -> {:error, :too_long}
      {:error, :unavailable} -> {:error, :voice_unavailable}
      {:error, :failed} -> {:error, :download_failed}
    end
  end

  # The file from Telegram, within `max_bytes`.
  defp fetch(connection_uuid, file_id, max_bytes) do
    case Client.impl().download_file(connection_uuid, file_id,
           max_bytes: max_bytes,
           deadline_ms: download_deadline_ms()
         ) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:error, {:file_too_large, _size, _max}} -> {:error, :too_large}
      {:error, :unavailable} -> {:error, :unavailable}
      _failed -> {:error, :failed}
    end
  end

  defp download_deadline_ms,
    do: Application.get_env(:phoenix_kit_agent, :telegram_download_deadline_ms, 30_000)

  defp converse(connection_uuid, ref, job, user_uuid, chat_id, locale) do
    case current_conversation(user_uuid, ref) do
      {:ok, conversation} ->
        with_topic(conversation, fn ->
          Bridge.react(connection_uuid, chat_id, job.message_id, "👀")
          start_turn(connection_uuid, ref, job.message_id, conversation, job.text, [], locale)
        end)

      {:error, _changeset} ->
        refuse(connection_uuid, chat_id, job.message_id, :not_found)
    end
  end

  # The conversation's topic is subscribed **before** anything starts, so the
  # end of its turn cannot be missed.
  defp with_topic(conversation, fun) do
    topic = Conversations.topic(conversation.uuid)
    :ok = PubSub.subscribe(topic)

    try do
      fun.()
    after
      PubSub.unsubscribe(topic)
    end
  end

  # The turn, and its answer in the chat. A turn that is refused leaves the
  # pictures it was to carry nowhere (`attachments`, uuids).
  defp start_turn(connection_uuid, ref, message_id, conversation, text, attachments, locale) do
    start = Turns.start(ref, false, conversation.uuid, text, attachments, options(locale))
    if match?({:error, _reason}, start), do: discard(ref, attachments)
    outcome(connection_uuid, ref, message_id, conversation, start)
  end

  # ── pictures ────────────────────────────────────────────────────────

  # The leader of an album waits a moment for the rest of it.
  defp photo(connection_uuid, ref, job, user_uuid, chat_id, locale) do
    Bridge.react(connection_uuid, chat_id, job.message_id, "👀")
    _ = Client.impl().typing(connection_uuid, chat_id)

    with {:ok, _user_uuid} <- Conversations.authorize_session(ref, impersonated: false),
         {:ok, conversation} <- current_conversation(user_uuid, ref) do
      jobs = [job | siblings(connection_uuid, chat_id, job)]

      with_topic(conversation, fn ->
        picture_turn(connection_uuid, ref, job.message_id, conversation, jobs, locale)
      end)
    else
      {:error, reason} ->
        refuse_with(connection_uuid, chat_id, job.message_id, picture_text(reason))
    end
  end

  defp siblings(connection_uuid, chat_id, %{group: group}) when is_binary(group) do
    Process.sleep(album_settle_ms())
    for {_ref, sibling} <- ChatQueue.take_siblings(connection_uuid, chat_id, group), do: sibling
  end

  defp siblings(_connection_uuid, _chat_id, _job), do: []

  defp picture_turn(connection_uuid, ref, message_id, conversation, jobs, locale) do
    {added, errors} = attach_all(connection_uuid, ref, conversation, jobs)

    case await(ref, added) do
      {[], failed} ->
        discard(ref, Enum.map(added, & &1.uuid))

        refuse_with(
          connection_uuid,
          elem(ref, 3),
          message_id,
          picture_text(first_error(errors ++ failed))
        )

      {ready, _failed} ->
        discard(ref, for(a <- added, a.uuid not in ready, do: a.uuid))
        text = caption(jobs) || default_prompt(length(ready))
        start_turn(connection_uuid, ref, message_id, conversation, text, ready, locale)
    end
  end

  # Every picture, one by one: the ones that could not be added are the errors.
  defp attach_all(connection_uuid, ref, conversation, jobs) do
    {added, errors} =
      Enum.reduce(jobs, {[], []}, fn job, {added, errors} ->
        case attach(connection_uuid, ref, conversation, job.photo) do
          {:ok, attachment} -> {[attachment | added], errors}
          {:error, reason} -> {added, [reason | errors]}
        end
      end)

    {Enum.reverse(added), Enum.reverse(errors)}
  end

  defp attach(connection_uuid, ref, conversation, photo) do
    max = Bridge.max_picture_bytes()

    with :ok <- if(too?(photo.size, max), do: {:error, :too_large}, else: :ok),
         {:ok, bytes} <- fetch(connection_uuid, photo.file_id, max) |> picture_error(),
         do:
           Attachments.add_picture_for_telegram(
             ref,
             conversation.uuid,
             bytes,
             photo.name || "photo"
           )
  end

  defp picture_error({:error, :failed}), do: {:error, :download_failed}
  defp picture_error(other), do: other

  # Until every picture is read or has failed, or the wait is over (a picture
  # still unread then has failed). `{ready uuids, error codes of the others}`.
  defp await(ref, added) do
    deadline = System.monotonic_time(:millisecond) + attachment_wait_ms()
    settle(ref, Enum.map(added, & &1.uuid), deadline)
  end

  defp settle(ref, uuids, deadline) do
    rows =
      Enum.map(uuids, fn uuid ->
        case Attachments.get_for_telegram(ref, uuid) do
          {:ok, row} -> row
          {:error, _gone} -> %{uuid: uuid, status: "failed", error: "unreadable"}
        end
      end)

    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      Enum.all?(rows, &(&1.status in ["ready", "failed"])) -> split(rows)
      remaining <= 0 -> split(Enum.map(rows, &timed_out/1))
      true -> wait_for_reading(ref, uuids, deadline, min(remaining, 1_000))
    end
  end

  defp wait_for_reading(ref, uuids, deadline, ms) do
    receive do
      {:agent_attachment_processed, _conversation_uuid, _attachment_uuid} ->
        settle(ref, uuids, deadline)
    after
      ms -> settle(ref, uuids, deadline)
    end
  end

  defp timed_out(%{status: "pending"} = row), do: %{row | status: "failed", error: "timeout"}
  defp timed_out(row), do: row

  defp split(rows) do
    {for(%{status: "ready"} = row <- rows, do: row.uuid),
     for(%{status: "failed"} = row <- rows, do: row.error || "unreadable")}
  end

  defp discard(ref, uuids), do: Enum.each(uuids, &Attachments.discard_for_telegram(ref, &1))

  defp caption(jobs) do
    Enum.find_value(jobs, fn job ->
      text = job.text
      if is_binary(text) and String.trim(text) != "", do: text
    end)
  end

  defp default_prompt(1), do: gettext("What is in this picture?")
  defp default_prompt(_several), do: gettext("What is in these pictures?")

  defp first_error([reason | _rest]), do: reason
  defp first_error([]), do: :file_unreadable

  # An error code of a row, or the refusal of `Attachments` / `Conversations`.
  defp picture_text(code) when is_binary(code), do: Texts.attachment_error(code)
  defp picture_text(reason), do: Texts.picture(reason)

  defp attachment_wait_ms do
    Application.get_env(:phoenix_kit_agent, :telegram_attachment_wait_ms) ||
      Bounds.get(:queue_wait_ms) + Bounds.get(:process_deadline_ms) + 10_000
  end

  defp album_settle_ms,
    do: Application.get_env(:phoenix_kit_agent, :telegram_album_settle_ms, 1_000)

  defp options(locale) do
    [locale: locale, request_context: [language: locale, base_url: Routes.base_url()]]
  end

  defp current_conversation(user_uuid, ref) do
    case Conversations.latest_telegram_conversation(user_uuid) do
      %{metadata: %{"chat_id" => stored}} = conversation ->
        if to_string(stored) == to_string(elem(ref, 3)),
          do: {:ok, conversation},
          else: start_conversation(user_uuid, ref)

      _none_or_unmarked ->
        start_conversation(user_uuid, ref)
    end
  end

  defp start_conversation(user_uuid, {:telegram_link, _user, _connection, chat_id}) do
    Conversations.create_conversation_for(user_uuid,
      metadata: %{"source" => "telegram", "chat_id" => chat_id}
    )
  end

  defp outcome(
         connection_uuid,
         {:telegram_link, _user, _connection, chat_id} = ref,
         message_id,
         conversation,
         {:ok, turn_ref}
       ) do
    await(connection_uuid, chat_id, conversation.uuid, turn_ref)

    case Conversations.turn_result(conversation.uuid, turn_ref) do
      {:answer, text} ->
        answer(
          connection_uuid,
          chat_id,
          message_id,
          text,
          not Conversations.turn_denied?(conversation.uuid, turn_ref)
        )

      {:needs_confirmation, text, card} ->
        held(connection_uuid, ref, message_id, conversation, turn_ref, {text, card})

      {:notice, code} ->
        refuse_with(connection_uuid, chat_id, message_id, Texts.notice(code))

      :none ->
        refuse_with(connection_uuid, chat_id, message_id, Texts.notice("deadline"))
    end
  end

  defp outcome(
         connection_uuid,
         {:telegram_link, _user, _connection, chat_id},
         message_id,
         _conversation,
         {:error, reason}
       ),
       do: refuse(connection_uuid, chat_id, message_id, reason)

  # The turn ended with a change held for the user: what the assistant said,
  # then the card with its buttons, and 👍. A card Telegram would not take is
  # one message that sends the person to the site (🤷); the change waits there.
  # An error that ended the turn after the hold is told in a message of its own.
  defp held(connection_uuid, ref, message_id, conversation, turn_ref, {text, card}) do
    {:telegram_link, _user, _connection, chat_id} = ref
    if text, do: say_plain(connection_uuid, chat_id, text)

    emoji =
      case Cards.deliver(connection_uuid, ref, conversation.uuid, card) do
        :ok ->
          "👍"

        :error ->
          Bridge.say(connection_uuid, chat_id, Texts.static(:card_not_shown))
          "🤷"
      end

    case Conversations.turn_error(conversation.uuid, turn_ref) do
      nil -> :ok
      code -> Bridge.say(connection_uuid, chat_id, Texts.notice(code))
    end

    Bridge.react(connection_uuid, chat_id, message_id, emoji)
  end

  defp say_plain(connection_uuid, chat_id, text) do
    case Format.plain(text) do
      "" -> :ok
      plain -> Bridge.say(connection_uuid, chat_id, plain)
    end
  end

  # "Typing…" every 4 seconds until the turn says it is over, or gives up
  # one minute after the turn's own deadline.
  defp await(connection_uuid, chat_id, conversation_uuid, turn_ref) do
    deadline = System.monotonic_time(:millisecond) + wait_ms()
    wait(connection_uuid, chat_id, conversation_uuid, turn_ref, deadline)
  end

  defp wait(connection_uuid, chat_id, conversation_uuid, turn_ref, deadline) do
    _ = Client.impl().typing(connection_uuid, chat_id)
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {:agent_turn_finished, ^conversation_uuid, ^turn_ref} ->
          :finished
      after
        min(typing_every_ms(), remaining) ->
          wait(connection_uuid, chat_id, conversation_uuid, turn_ref, deadline)
      end
    else
      :timeout
    end
  end

  # 👍 only for an answer that was sent, and that is not "I cannot do that
  # here" (the turn asked for a change the chat is not allowed): that is 🤷,
  # with the text the model said (it points to the site).
  defp answer(connection_uuid, chat_id, message_id, text, fulfilled?) do
    case Format.plain(text) do
      "" -> refuse_with(connection_uuid, chat_id, message_id, Texts.notice("empty_answer"))
      plain -> reply(connection_uuid, chat_id, message_id, plain, fulfilled?)
    end
  end

  defp reply(connection_uuid, chat_id, message_id, text, fulfilled? \\ true) do
    emoji =
      if Bridge.say(connection_uuid, chat_id, text) == :ok and fulfilled?, do: "👍", else: "🤷"

    Bridge.react(connection_uuid, chat_id, message_id, emoji)
  end

  defp refuse(connection_uuid, chat_id, message_id, reason),
    do: refuse_with(connection_uuid, chat_id, message_id, Texts.refusal(reason))

  defp refuse_with(connection_uuid, chat_id, message_id, text),
    do: reply(connection_uuid, chat_id, message_id, text, false)

  # The turn's own deadline and a minute more; `:telegram_turn_wait_ms` stands
  # in for it in tests.
  defp wait_ms do
    Application.get_env(:phoenix_kit_agent, :telegram_turn_wait_ms) ||
      Config.turn_deadline_s() * 1_000 + @grace_ms
  end

  defp typing_every_ms,
    do: Application.get_env(:phoenix_kit_agent, :telegram_typing_every_ms, @typing_every_ms)
end
