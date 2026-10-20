defmodule PhoenixKitAgent.Conversations do
  @moduledoc """
  The chats and messages of the assistant (spec §5.1-5.2, §8, §10).

  Every function acts for a **live browser session**, never for a bare user
  uuid: the first argument is the `{session_token_uuid, user_uuid}` reference
  that `PhoenixKit.Users.Auth.SessionRef.from_session/1` reads from a
  LiveView's signed session (in its connected mount), and the last is a
  keyword list that must carry `impersonated: boolean` — the answer of
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1` for the same session.
  The flag has no default on purpose: a caller that forgets it raises
  `ArgumentError` instead of being let in.

  Each call is checked in this order, and the first failure is the answer:

    1. `impersonated: true` — `{:error, :impersonated}`. An operator who
       entered a user's session through impersonation would otherwise read the
       whole chat history (customer data from tool results) and write as the
       user, spending their limits (spec §8, В13). Nothing is read or written.
    2. The session's scope (`SessionRef.scope_for_session/2`): a revoked or
       expired session, a blocked user, a session of another user —
       `{:error, :session_gone | :mismatch | :inactive | :unconfirmed |
       :referral_required}`. The scope is rebuilt on every call, so a logout
       takes effect on the next one.
    3. The module is enabled, the scope holds `agent`, and the assistant is
       not switched off for the user (`user_settings.enabled`) —
       `{:error, :forbidden}`.
    4. For one chat: it belongs to the session's user. Anything else — someone
       else's chat, a deleted one, one that never existed, a malformed uuid —
       is the same `{:error, :not_found}`, so the answer does not reveal that
       a chat exists.

  The owner is the only one who reads or writes a chat. A soft-deleted chat
  (`status: "deleted"`) is gone for every function here; an archived one is
  left out of `list_conversations/2` only, and can still be opened and
  written to (a turn in flight when the user archives the chat must still be
  able to save its answer).

  ## Events

  `add_message/4` broadcasts `{:agent_message_added, conversation_uuid,
  message_uuid}` on `topic/1` (`"agent:conv:<uuid>"`) after the message is
  stored. The event carries uuids, not the message: a listener reads the chat
  again through `get_conversation/3`, with a fresh scope. `subscribe/3`
  subscribes only after the checks above. PubSub is in-process and anyone in
  the VM can subscribe to a topic directly; the check guards the code that
  serves a user's browser, not hostile code in the node.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKitAgent.Schemas.{Conversation, Message, UserSettings}

  @page_size 20
  @max_page_size 50
  @title_from_message 60

  @typedoc "`{session_token_uuid, user_uuid}` from `SessionRef.from_session/1`."
  @type session_ref :: SessionRef.t()

  @typedoc "Where the next page of the list starts; opaque, taken from `list_conversations/2`."
  @type cursor :: {DateTime.t(), String.t()}

  @typedoc "Why a call was refused."
  @type refusal ::
          :impersonated
          | SessionRef.refusal()
          | :forbidden
          | :not_found

  @doc "The PubSub topic of a chat's events."
  @spec topic(String.t()) :: String.t()
  def topic(conversation_uuid), do: "agent:conv:" <> conversation_uuid

  @doc """
  Creates an empty active chat for the session's user. `attrs` may carry a
  `:title`; the owner and status are never taken from it.
  """
  @spec create_conversation(session_ref(), map(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def create_conversation(session_ref, attrs, opts) when is_map(attrs) do
    with_user(session_ref, opts, fn user_uuid ->
      %Conversation{user_uuid: user_uuid, last_message_at: DateTime.utc_now()}
      |> Conversation.changeset(Map.take(attrs, [:title, "title"]))
      |> repo().insert()
    end)
  end

  @doc """
  The user's active chats, newest `last_message_at` first, one page at a time.

  Options (besides `impersonated:`): `:limit` (default 20, at most 50) and
  `:cursor`, the `next_cursor` of the previous page. Returns the chats and the
  cursor of the next page (`nil` on the last one). Archived and deleted chats
  are not listed. Messages are not loaded.
  """
  @spec list_conversations(session_ref(), keyword()) ::
          {:ok, %{conversations: [Conversation.t()], next_cursor: cursor() | nil}}
          | {:error, refusal() | :invalid_cursor}
  def list_conversations(session_ref, opts) do
    with_user(session_ref, opts, fn user_uuid ->
      with {:ok, cursor} <- cursor(Keyword.get(opts, :cursor)) do
        {:ok, page(user_uuid, cursor, page_size(Keyword.get(opts, :limit)))}
      end
    end)
  end

  @doc "The user's chat with all its messages, oldest first."
  @spec get_conversation(session_ref(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal()}
  def get_conversation(session_ref, conversation_uuid, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      messages = from(m in Message, order_by: [asc: m.inserted_at, asc: m.uuid])
      {:ok, repo().preload(conversation, messages: messages)}
    end)
  end

  @doc "Renames a chat. A blank title or one over 200 characters is an `{:error, changeset}`."
  @spec rename_conversation(session_ref(), term(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def rename_conversation(session_ref, conversation_uuid, title, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      conversation
      |> Conversation.changeset(%{title: trim(title)})
      |> Ecto.Changeset.validate_required([:title])
      |> repo().update()
    end)
  end

  @doc "Archives a chat: it leaves the list, nothing is deleted."
  @spec archive_conversation(session_ref(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def archive_conversation(session_ref, conversation_uuid, opts),
    do: set_status(session_ref, conversation_uuid, "archived", opts)

  @doc """
  Soft-deletes a chat: its row and messages stay, but no function here sees it
  any more.
  """
  @spec delete_conversation(session_ref(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def delete_conversation(session_ref, conversation_uuid, opts),
    do: set_status(session_ref, conversation_uuid, "deleted", opts)

  @doc """
  Adds a message to the user's chat and updates the chat in the same
  transaction: the message count, the token and cost totals, `last_message_at`
  and — when the chat has no title yet — the title, the first 60 characters of
  the first `user` message. The chat is taken from the argument, never from
  `attrs`. After the commit the chat's topic hears
  `{:agent_message_added, conversation_uuid, message_uuid}`.
  """
  @spec add_message(session_ref(), term(), map(), keyword()) ::
          {:ok, Message.t()} | {:error, refusal() | Ecto.Changeset.t()}
  def add_message(session_ref, conversation_uuid, attrs, opts) when is_map(attrs) do
    with_user(session_ref, opts, fn user_uuid ->
      add_turn_message(user_uuid, conversation_uuid, attrs)
    end)
  end

  @doc false
  # `add_message/4` without the session checks, for `PhoenixKitAgent.Turns`: the
  # turn checked the session when it started and checks it again every round,
  # and must still be able to write the notice that says the session is gone.
  # The chat must belong to `user_uuid` (not deleted), as in `add_message/4`.
  # `fields` are set on the struct, never cast: `:uuid` (given to the model
  # call before the message exists) and `:ai_request_uuid`.
  @spec add_turn_message(String.t(), term(), map(), keyword()) ::
          {:ok, Message.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def add_turn_message(user_uuid, conversation_uuid, attrs, fields \\ []) when is_map(attrs) do
    result =
      repo().transaction(fn ->
        with {:ok, conversation} <- fetch_owned(user_uuid, conversation_uuid, lock: true),
             {:ok, message} <- insert_message(conversation, attrs, fields) do
          message
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, %Message{} = message} <- result do
      PubSub.broadcast(
        topic(message.conversation_uuid),
        {:agent_message_added, message.conversation_uuid, message.uuid}
      )
    end

    result
  end

  @doc """
  Checks 1-3 of the moduledoc for a session, without a chat: `{:ok,
  user_uuid}` when the session may use the assistant now.
  """
  @spec authorize_session(session_ref(), keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def authorize_session(session_ref, opts),
    do: with_user(session_ref, opts, fn user_uuid -> {:ok, user_uuid} end)

  @doc """
  Subscribes the calling process to the chat's topic, but only after the
  checks of the moduledoc — a chat of someone else is `{:error, :not_found}`
  and nothing is subscribed.
  """
  @spec subscribe(session_ref(), term(), keyword()) :: :ok | {:error, refusal()}
  def subscribe(session_ref, conversation_uuid, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      PubSub.subscribe(topic(conversation.uuid))
    end)
  end

  # ── the gate ────────────────────────────────────────────────────

  # Runs `fun.(user_uuid)` for a session that passes the checks 1-3 of the
  # moduledoc. A `fun` result of `:ok`, `{:ok, _}` or `{:error, _}` is the
  # answer as is.
  defp with_user(session_ref, opts, fun) do
    with :ok <- not_impersonated(impersonated!(opts)),
         {:ok, scope} <- scope_for(session_ref),
         user_uuid = Scope.user_uuid(scope),
         :ok <- authorize(scope, user_uuid) do
      fun.(user_uuid)
    end
  end

  # `fun.(conversation)` for a chat of the session's user (check 4).
  defp with_owned(session_ref, conversation_uuid, opts, fun) do
    with_user(session_ref, opts, fn user_uuid ->
      with {:ok, conversation} <- fetch_owned(user_uuid, conversation_uuid) do
        fun.(conversation)
      end
    end)
  end

  defp impersonated!(opts) do
    case Keyword.fetch(opts, :impersonated) do
      {:ok, flag} when is_boolean(flag) ->
        flag

      _missing_or_malformed ->
        raise ArgumentError,
              "PhoenixKitAgent.Conversations needs `impersonated: true | false` in its options " <>
                "(MultiSession.impersonated?/1 of the session); got: #{inspect(opts)}"
    end
  end

  defp not_impersonated(false), do: :ok
  defp not_impersonated(true), do: {:error, :impersonated}

  defp scope_for({session_token_uuid, user_uuid}),
    do: SessionRef.scope_for_session(session_token_uuid, user_uuid)

  defp scope_for(_not_a_reference), do: {:error, :session_gone}

  defp authorize(scope, user_uuid) do
    if PhoenixKitAgent.enabled?() and Scope.can?(scope, "agent") and
         not switched_off?(user_uuid),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp switched_off?(user_uuid) do
    repo().exists?(
      from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.enabled == false)
    )
  end

  defp fetch_owned(user_uuid, conversation_uuid, opts \\ []) do
    with {:ok, uuid} <- Ecto.UUID.cast(conversation_uuid),
         %Conversation{} = conversation <-
           uuid |> owned_query(user_uuid) |> lock(opts[:lock]) |> repo().one() do
      {:ok, conversation}
    else
      _unknown_or_not_theirs -> {:error, :not_found}
    end
  end

  defp owned_query(uuid, user_uuid) do
    from(c in Conversation,
      where: c.uuid == ^uuid and c.user_uuid == ^user_uuid and c.status != "deleted"
    )
  end

  defp lock(query, true), do: from(c in query, lock: "FOR UPDATE")
  defp lock(query, _no_lock), do: query

  # ── helpers ─────────────────────────────────────────────────────

  defp set_status(session_ref, conversation_uuid, status, opts) do
    with_owned(session_ref, conversation_uuid, opts, fn conversation ->
      conversation |> Conversation.changeset(%{status: status}) |> repo().update()
    end)
  end

  defp trim(title) when is_binary(title), do: String.trim(title)
  defp trim(title), do: title

  defp insert_message(conversation, attrs, fields) do
    message =
      struct(
        Message,
        [conversation_uuid: conversation.uuid] ++ Keyword.take(fields, [:uuid, :ai_request_uuid])
      )

    changeset = Message.changeset(message, attrs)

    with {:ok, message} <- repo().insert(changeset) do
      touch(conversation, message)
      {:ok, message}
    end
  end

  # The chat's totals follow the message. `COALESCE` keeps a title that is
  # already there (set by hand or by the first user message).
  defp touch(conversation, message) do
    now = DateTime.utc_now()

    from(c in Conversation,
      where: c.uuid == ^conversation.uuid,
      update: [
        inc: [
          message_count: 1,
          input_tokens: ^(message.input_tokens || 0),
          output_tokens: ^(message.output_tokens || 0),
          cost_micro_usd: ^(message.cost_micro_usd || 0)
        ],
        set: [
          last_message_at: ^now,
          updated_at: ^now,
          title: fragment("COALESCE(?, ?)", c.title, type(^title_from(message), :string))
        ]
      ]
    )
    |> repo().update_all([])
  end

  defp title_from(%Message{role: "user", content: content}) when is_binary(content) do
    case String.trim(content) do
      "" -> nil
      text -> String.slice(text, 0, @title_from_message)
    end
  end

  defp title_from(_message), do: nil

  defp page_size(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_page_size)
  defp page_size(_default), do: @page_size

  defp cursor(nil), do: {:ok, nil}

  defp cursor({%DateTime{} = sort_key, uuid}) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, {sort_key, uuid}}
      :error -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_malformed), do: {:error, :invalid_cursor}

  # The sort key is `last_message_at`, or `inserted_at` for a chat that has no
  # message time yet; the uuid (time-ordered) breaks ties, so the cursor is
  # exact and a chat that moves up between two pages cannot make a page repeat.
  defp page(user_uuid, cursor, size) do
    rows =
      from(c in Conversation,
        where: c.user_uuid == ^user_uuid and c.status == "active",
        order_by: [
          desc: fragment("coalesce(?, ?)", c.last_message_at, c.inserted_at),
          desc: c.uuid
        ],
        limit: ^(size + 1)
      )
      |> after_cursor(cursor)
      |> repo().all()

    {conversations, rest} = Enum.split(rows, size)
    %{conversations: conversations, next_cursor: next_cursor(conversations, rest)}
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {sort_key, uuid}) do
    from(c in query,
      where:
        fragment("coalesce(?, ?)", c.last_message_at, c.inserted_at) < ^sort_key or
          (fragment("coalesce(?, ?)", c.last_message_at, c.inserted_at) == ^sort_key and
             c.uuid < ^uuid)
    )
  end

  defp next_cursor(_conversations, []), do: nil

  defp next_cursor(conversations, _rest) do
    last = List.last(conversations)
    {last.last_message_at || last.inserted_at, last.uuid}
  end

  defp repo, do: RepoHelper.repo()
end
