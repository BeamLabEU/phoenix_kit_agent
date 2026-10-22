defmodule PhoenixKitAgent.Confirmations do
  @moduledoc """
  The confirmation cards of the chat (spec §12 Ф2, Б2.2): a write the model
  asked for waits for the user, who runs it, turns it down or asks for it
  again.

  A turn never writes (`PhoenixKitAgent.Turns.Runner`): core answers a write of
  a live session with a preview and holds the call in a confirmation row bound
  to the user (`PhoenixKit.API.Executor.execute_as/5`, `allow: :all`), and the
  turn stores a `tool` message `needs_confirmation` with the row's uuid
  (`confirmation_uuid`) and the answer that asked for it
  (`assistant_message_uuid`), and ends there. A card is that message; it
  waits while the chat has no `notice` with the same `confirmation_uuid`.

  Like `PhoenixKitAgent.Conversations`, every function acts for a **live
  browser session** and takes the answer of `MultiSession.impersonated?/1` for
  it: an impersonated session, a session that cannot act, a user who may not
  use the assistant, someone else's chat, or a message that is not a card of
  it, are refused before anything else is read (the refusals of
  `Conversations.owned_conversation/3`, then `:not_waiting`).

  ## A click

  `confirm/5`, `reject/5` and `repeat/5` take the user's turn lock for the
  click (`PhoenixKitAgent.Turns.Locks.acquire_user/4`, held for at most
  30 s should it never be released): while a turn of the user runs, a click
  is `{:error, :turn_running}`, and no turn starts while a click runs. A click
  calls no model and stores no user message, so it spends neither money nor a
  turn of the user's limits. The card is read again under the lock.

    * `confirm/5` redeems the row (`Executor.redeem_as/6`) with the same tool
      and the arguments the model sent — the registry name of the card and
      `PhoenixKitAgent.Turns.Tools.arguments/1` of the call in its assistant
      message — under the rights of the session that clicks, now. Core checks
      everything again (the session, the tool and its module, the "Agent may
      act" box, the scope and the permission, the rate limit, the input, a
      fresh dry run against the preview's fingerprint) and spends the row
      atomically before the handler runs.
    * `reject/5` turns the row down (`PhoenixKit.API.Confirm.reject_for_user/2`).
    * `repeat/5`, for a card whose row ran out (or that core has deleted),
      asks for the same call again (`execute_as/5`): a new card.

  What became of the card is a new `notice` with its `confirmation_uuid`, the
  tool's name and `tool_outcome`: `confirmed` (the handler ran), `rejected`,
  `expired` (the row ran out or is gone), `changed` (the values changed under
  the preview: core holds the call in a new row, which is a new card with the
  same assistant message, right after it) or `failed` (the row was spent but
  the handler failed). A refusal before the row is spent — the session, the
  rights, the module's box, the handler's own dry run, the rate limit — writes
  nothing: the card keeps waiting and the click answers `{:error, {:refused,
  code}}` with core's code. Such a notice is the only thing of a click the
  model learns, in the history of the next turn
  (`PhoenixKitAgent.Turns.History`).

  Neither the arguments, nor the preview, nor what the handler returned are
  stored or logged here.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Executor
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Conversations, Turns}
  alias PhoenixKitAgent.Schemas.{Conversation, Message}
  alias PhoenixKitAgent.Turns.{Locks, Tools}

  # How long a click's lock blocks a turn if it is never released.
  @hold_s 30

  # The most of the model's arguments a card shows.
  @arguments_chars 2_000

  @outcomes ~w(confirmed rejected expired changed failed)

  @typedoc "What a card shows (see `cards/4`)."
  @type card :: %{
          state: String.t(),
          tool: String.t(),
          preview: map() | nil,
          arguments: String.t() | nil,
          expires_at: DateTime.t() | nil,
          repeatable?: boolean()
        }

  @typedoc "Why a click did nothing."
  @type refusal ::
          Conversations.refusal()
          | :not_waiting
          | :not_expired
          | :turn_running
          | :no_arguments
          | {:refused, atom()}

  @doc "The outcomes a card's notice takes."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc """
  The user runs the write the card `message_uuid` waits for (see the
  moduledoc). `{:ok, outcome}` — `:confirmed`, `:changed`, `:expired`,
  `:rejected` or `:failed`, written as the card's notice — or `{:error,
  reason}`, after which the card still waits.

  Options: `:request_context` — as for `PhoenixKitAgent.Turns.start/6`;
  `:request_id` is the click's own.
  """
  @spec confirm(Conversations.session_ref(), boolean(), term(), term(), keyword()) ::
          {:ok, :confirmed | :changed | :expired | :rejected | :failed} | {:error, refusal()}
  def confirm(session_ref, impersonated?, conversation_uuid, message_uuid, opts \\ []),
    do: click(session_ref, impersonated?, conversation_uuid, message_uuid, opts, &do_confirm/1)

  @doc """
  The user turns down the write the card `message_uuid` waits for:
  `{:ok, :rejected}` (or `:expired` / `:failed` when the row was no longer
  waiting), written as the card's notice.
  """
  @spec reject(Conversations.session_ref(), boolean(), term(), term(), keyword()) ::
          {:ok, :rejected | :expired | :failed} | {:error, refusal()}
  def reject(session_ref, impersonated?, conversation_uuid, message_uuid, opts \\ []),
    do: click(session_ref, impersonated?, conversation_uuid, message_uuid, opts, &do_reject/1)

  @doc """
  The user asks again for the write of the card `message_uuid`, whose row ran
  out or is gone: core holds the same call in a new row, a new card with the
  same assistant message (`{:ok, :repeated}`). The old card is closed as
  `expired` if it was not yet. `{:error, :not_expired}` for any other card,
  and for one asked for again already.
  """
  @spec repeat(Conversations.session_ref(), boolean(), term(), term(), keyword()) ::
          {:ok, :repeated} | {:error, refusal()}
  def repeat(session_ref, impersonated?, conversation_uuid, message_uuid, opts \\ []),
    do: click(session_ref, impersonated?, conversation_uuid, message_uuid, opts, &do_repeat/1)

  @doc """
  What the chat panel shows of the cards among `messages` (messages of the
  user's chat `conversation_uuid`, as `PhoenixKitAgent.Conversations` hands
  them out): a map from the uuid of each card to `t:card/0`. Only the uuids
  of `messages` are used; the rows are read again in this chat, and a message
  that is not a card of it is left out.

    * `state` — `"waiting"`, an outcome of its notice, `"expired"` for a row
      that ran out or is gone, or `"unavailable"` (the session cannot read it,
      or the row was settled without a notice here);
    * `preview`, `expires_at`, `arguments` — for a waiting card only: core's
      preview (`PhoenixKit.API.Confirm.get_for_user/2`, read with this
      session), when it runs out, and the arguments the model sent, as plain
      JSON text (to be shown as text, never as markup), cut to
      #{@arguments_chars} characters;
    * `repeatable?` — the card ran out and was not asked for again.
  """
  @spec cards(Conversations.session_ref(), boolean(), term(), [%{uuid: term()}]) ::
          {:ok, %{String.t() => card()}} | {:error, Conversations.refusal()}
  def cards(session_ref, impersonated?, conversation_uuid, messages) when is_list(messages) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ) do
      rows = card_rows(conversation, Enum.map(messages, & &1.uuid))
      settled = outcomes(conversation, Enum.map(rows, & &1.confirmation_uuid))

      {:ok,
       Map.new(rows, fn row ->
         {row.uuid, card(session_ref, conversation, row, settled[row.confirmation_uuid])}
       end)}
    end
  end

  # ── a click ─────────────────────────────────────────────────────

  defp click(session_ref, impersonated?, conversation_uuid, message_uuid, opts, action) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid,
             impersonated: impersonated?
           ),
         {:ok, _card} <- card_row(conversation, message_uuid) do
      locked(conversation.user_uuid, fn click_ref ->
        # Read again under the lock: another tab may have settled it.
        with {:ok, card} <- card_row(conversation, message_uuid) do
          action.(%{
            session_ref: session_ref,
            conversation: conversation,
            card: card,
            outcome: outcomes(conversation, [card.confirmation_uuid])[card.confirmation_uuid],
            request_context:
              opts
              |> Keyword.get(:request_context, [])
              |> Keyword.put(:request_id, click_ref)
          })
        end
      end)
    end
  end

  defp locked(user_uuid, fun) do
    click_ref = "confirm-" <> UUIDv7.generate()

    case Locks.acquire_user(user_uuid, click_ref, Turns.lock_ttl_s(), @hold_s) do
      :ok ->
        try do
          fun.(click_ref)
        after
          Locks.release_user(user_uuid, click_ref)
        end

      {:error, :turn_in_flight} ->
        {:error, :turn_running}
    end
  end

  defp do_confirm(%{outcome: nil} = click) do
    with {:ok, input} <- call_input(click.conversation, click.card) do
      click.session_ref
      |> Executor.redeem_as(
        :admin,
        click.card.confirmation_uuid,
        click.card.tool_name,
        input,
        request_context: click.request_context,
        via: "agent"
      )
      |> redeemed(click)
    end
  end

  defp do_confirm(_settled), do: {:error, :not_waiting}

  # The handler ran, or core holds the call in a new row (the values changed).
  defp redeemed({:ok, %{result: result}, _headers}, click) do
    case Tools.held(result) do
      {:ok, new_uuid} ->
        settle(click, "changed")
        add_card(click, new_uuid)
        {:ok, :changed}

      :error ->
        settle(click, "confirmed")
        {:ok, :confirmed}
    end
  end

  # The row can no longer be redeemed.
  defp redeemed({:error, :confirm_token_invalid, _detail, %{reason: reason}, _headers}, click)
       when reason in ["expired", "invalid", "rejected", "used"] do
    outcome =
      case reason do
        "rejected" -> "rejected"
        "used" -> "failed"
        _expired_or_gone -> "expired"
      end

    settle(click, outcome)
    {:ok, String.to_existing_atom(outcome)}
  end

  # Spent, then the handler failed: `failed`. Not spent: the card waits.
  defp redeemed({:error, code, _detail, _context, _headers}, click) do
    case Confirm.get_for_user(click.card.confirmation_uuid, click.session_ref) do
      {:ok, %{status: "used"}} ->
        settle(click, "failed")
        {:ok, :failed}

      _waiting_or_unreadable ->
        {:error, {:refused, code}}
    end
  end

  defp do_reject(%{outcome: nil} = click) do
    case Confirm.reject_for_user(click.card.confirmation_uuid, click.session_ref) do
      result when result in [:ok, {:error, :rejected}] -> settled(click, "rejected")
      {:error, reason} when reason in [:expired, :unknown] -> settled(click, "expired")
      {:error, :used} -> settled(click, "failed")
      {:error, :unauthorized} -> {:error, :session_gone}
      {:error, reason} -> {:error, {:refused, reason}}
    end
  end

  defp do_reject(_settled), do: {:error, :not_waiting}

  defp settled(click, outcome) do
    settle(click, outcome)
    {:ok, String.to_existing_atom(outcome)}
  end

  defp do_repeat(click) do
    with :ok <- repeatable(click),
         {:ok, input} <- call_input(click.conversation, click.card) do
      click.session_ref
      |> Executor.execute_as(:admin, click.card.tool_name, input,
        allow: :all,
        via: "agent",
        request_context: click.request_context
      )
      |> asked_again(click)
    end
  end

  defp asked_again({:ok, %{result: result}, _headers}, click) do
    case Tools.held(result) do
      {:ok, new_uuid} ->
        if click.outcome == nil, do: settle(click, "expired")
        add_card(click, new_uuid)
        {:ok, :repeated}

      :error ->
        {:error, {:refused, :not_held}}
    end
  end

  defp asked_again({:error, code, _detail, _context, _headers}, _click),
    do: {:error, {:refused, code}}

  defp repeatable(%{outcome: "expired"} = click), do: not_superseded(click)

  defp repeatable(%{outcome: nil} = click) do
    case Confirm.get_for_user(click.card.confirmation_uuid, click.session_ref) do
      {:ok, %{status: "expired"}} -> not_superseded(click)
      {:error, :unknown} -> not_superseded(click)
      _waiting_or_settled -> {:error, :not_expired}
    end
  end

  defp repeatable(_settled), do: {:error, :not_expired}

  defp not_superseded(click) do
    if superseded?(click.conversation, click.card), do: {:error, :not_expired}, else: :ok
  end

  # ── what a click writes ─────────────────────────────────────────

  # The card's notice: its outcome and the tool's name; the text is the
  # stored form, the panel shows it by its outcome.
  defp settle(click, outcome) do
    click.conversation.user_uuid
    |> Conversations.add_turn_message(
      click.conversation.uuid,
      %{
        role: "notice",
        content: notice_text(outcome),
        tool_name: click.card.tool_name,
        tool_outcome: outcome
      },
      confirmation_uuid: click.card.confirmation_uuid
    )
    |> stored("notice")
  end

  # A new card for the same call: the same assistant message and call id.
  defp add_card(click, confirmation_uuid) do
    click.conversation.user_uuid
    |> Conversations.add_turn_message(
      click.conversation.uuid,
      %{
        role: "tool",
        tool_call_id: click.card.tool_call_id,
        tool_name: click.card.tool_name,
        tool_outcome: "needs_confirmation",
        tool_result: Tools.held_result(confirmation_uuid)
      },
      assistant_message_uuid: click.card.assistant_message_uuid,
      confirmation_uuid: confirmation_uuid
    )
    |> stored("tool")
  end

  # A refused message is logged by its field names and validation codes only.
  defp stored({:ok, _message}, _role), do: :ok

  defp stored({:error, %Ecto.Changeset{} = changeset}, role) do
    codes =
      Enum.map(changeset.errors, fn {field, {_text, opts}} -> {field, opts[:validation]} end)

    Logger.warning(
      "[PhoenixKitAgent] a #{role} message of a confirmation was not stored: #{inspect(codes)}"
    )
  end

  defp stored({:error, reason}, role) when is_atom(reason) do
    Logger.warning(
      "[PhoenixKitAgent] a #{role} message of a confirmation was not stored: #{reason}"
    )
  end

  defp notice_text("confirmed"), do: "The change was made."
  defp notice_text("rejected"), do: "The change was cancelled."
  defp notice_text("expired"), do: "The confirmation ran out; nothing was changed."
  defp notice_text("changed"), do: "The data changed since the preview; check the new one."
  defp notice_text("failed"), do: "The change failed."

  # ── reading ─────────────────────────────────────────────────────

  defp card(session_ref, conversation, row, nil) do
    base = %{
      state: "waiting",
      tool: row.tool_name,
      preview: nil,
      arguments: nil,
      expires_at: nil,
      repeatable?: false
    }

    case Confirm.get_for_user(row.confirmation_uuid, session_ref) do
      {:ok, %{status: "unused"} = held} ->
        %{
          base
          | preview: held.preview,
            expires_at: held.expires_at,
            arguments: arguments_text(conversation, row)
        }

      {:ok, %{status: "expired"}} ->
        %{base | state: "expired", repeatable?: not superseded?(conversation, row)}

      {:error, :unknown} ->
        %{base | state: "expired", repeatable?: not superseded?(conversation, row)}

      _settled_elsewhere_or_unreadable ->
        %{base | state: "unavailable"}
    end
  end

  defp card(_session_ref, conversation, row, outcome) do
    %{
      state: outcome,
      tool: row.tool_name,
      preview: nil,
      arguments: nil,
      expires_at: nil,
      repeatable?: outcome == "expired" and not superseded?(conversation, row)
    }
  end

  defp arguments_text(conversation, row) do
    case call_input(conversation, row) do
      {:ok, input} ->
        text = Jason.encode!(input, pretty: true)

        if String.length(text) > @arguments_chars,
          do: String.slice(text, 0, @arguments_chars) <> "…",
          else: text

      {:error, :no_arguments} ->
        nil
    end
  end

  # The arguments the call went to core with: those of the call with the
  # card's id in its assistant message, without control fields.
  defp call_input(conversation, card) do
    with uuid when is_binary(uuid) <- card.assistant_message_uuid,
         %Message{tool_calls: calls} when is_list(calls) <-
           repo().one(
             from(m in Message,
               where:
                 m.uuid == ^uuid and m.conversation_uuid == ^conversation.uuid and
                   m.role == "assistant"
             )
           ),
         [call] <- Enum.filter(calls, &(&1["id"] == card.tool_call_id)),
         {:ok, input} <- Tools.arguments(call["arguments"]) do
      {:ok, input}
    else
      _missing -> {:error, :no_arguments}
    end
  end

  defp card_row(%Conversation{} = conversation, message_uuid) do
    case card_rows(conversation, [message_uuid]) do
      [card] -> {:ok, card}
      [] -> {:error, :not_waiting}
    end
  end

  defp card_rows(conversation, message_uuids) do
    uuids =
      for uuid <- message_uuids, {:ok, cast} <- [Ecto.UUID.cast(uuid)], uniq: true, do: cast

    repo().all(
      from(m in Message,
        where:
          m.conversation_uuid == ^conversation.uuid and m.uuid in ^uuids and m.role == "tool" and
            m.tool_outcome == "needs_confirmation" and not is_nil(m.confirmation_uuid),
        order_by: [asc: m.inserted_at, asc: m.uuid]
      )
    )
  end

  # The outcome of each confirmation that has its notice in the chat.
  defp outcomes(_conversation, []), do: %{}

  defp outcomes(conversation, confirmation_uuids) do
    repo().all(
      from(m in Message,
        where:
          m.conversation_uuid == ^conversation.uuid and m.role == "notice" and
            m.confirmation_uuid in ^confirmation_uuids and m.tool_outcome in ^@outcomes,
        order_by: [asc: m.inserted_at, asc: m.uuid],
        select: {m.confirmation_uuid, m.tool_outcome}
      )
    )
    |> Map.new()
  end

  # A later card of the same call (asked for again, or the values changed).
  defp superseded?(_conversation, %{assistant_message_uuid: nil}), do: false

  defp superseded?(conversation, card) do
    repo().exists?(
      from(m in Message,
        where:
          m.conversation_uuid == ^conversation.uuid and m.role == "tool" and
            m.tool_outcome == "needs_confirmation" and
            m.assistant_message_uuid == ^card.assistant_message_uuid and
            m.tool_call_id == ^card.tool_call_id and m.uuid != ^card.uuid and
            (m.inserted_at > ^card.inserted_at or
               (m.inserted_at == ^card.inserted_at and m.uuid > ^card.uuid))
      )
    )
  end

  defp repo, do: RepoHelper.repo()
end
