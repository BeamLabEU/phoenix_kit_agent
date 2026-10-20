defmodule PhoenixKitAgent.Turns.Locks do
  @moduledoc """
  The two locks of a turn (spec §6.1 step 3), both rows in the database:

    * the chat's — `busy_since` / `busy_turn_ref` of
      `phoenix_kit_agent_conversations`: one turn per chat;
    * the user's — the same columns of `phoenix_kit_agent_user_settings` (the
      row is created empty when the user has none): one turn in flight per
      user, so parallel chats cannot run past a limit.

  Each is taken by one atomic statement that succeeds only when the lock is
  free or older than its TTL (`busy_since < now - ttl`), so a lock left by a
  node that went down frees itself. No advisory lock: it would hold a pool
  connection for the whole turn. A lock is released only by the turn that
  holds it (`busy_turn_ref`), so a late release cannot free a newer turn, and
  a running turn checks before each round that it still holds both
  (`held?/3`): a turn whose lock was taken over stops there. Times are the
  database's (`now()`), so the TTL does not depend on the clocks of the nodes.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.Schemas.{Conversation, UserSettings}

  @doc """
  Takes both locks for `turn_ref`, or neither. The chat is tried first, so a
  second turn in the same chat is `:conversation_busy`; a turn of the user in
  another chat is `:turn_in_flight`.
  """
  @spec acquire(String.t(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, :conversation_busy | :turn_in_flight}
  def acquire(user_uuid, conversation_uuid, turn_ref, ttl_s) do
    result =
      repo().transaction(fn ->
        now = db_now()
        stale = DateTime.add(now, -ttl_s, :second)

        with :ok <- lock_conversation(user_uuid, conversation_uuid, turn_ref, now, stale),
             :ok <- lock_user(user_uuid, turn_ref, now, stale) do
          :ok
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Whether `turn_ref` holds both locks."
  @spec held?(String.t(), String.t(), String.t()) :: boolean()
  def held?(user_uuid, conversation_uuid, turn_ref) do
    repo().exists?(
      from(c in Conversation,
        where: c.uuid == ^conversation_uuid and c.busy_turn_ref == ^turn_ref
      )
    ) and
      repo().exists?(
        from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.busy_turn_ref == ^turn_ref)
      )
  end

  @doc "Releases both locks if `turn_ref` still holds them."
  @spec release(String.t(), String.t(), String.t()) :: :ok
  def release(user_uuid, conversation_uuid, turn_ref) do
    now = DateTime.utc_now()

    repo().update_all(
      from(c in Conversation,
        where: c.uuid == ^conversation_uuid and c.busy_turn_ref == ^turn_ref
      ),
      set: [busy_since: nil, busy_turn_ref: nil]
    )

    repo().update_all(
      from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.busy_turn_ref == ^turn_ref),
      set: [busy_since: nil, busy_turn_ref: nil, updated_at: now]
    )

    :ok
  end

  defp lock_conversation(user_uuid, conversation_uuid, turn_ref, now, stale) do
    {count, _} =
      repo().update_all(
        from(c in Conversation,
          where:
            c.uuid == ^conversation_uuid and c.user_uuid == ^user_uuid and
              (is_nil(c.busy_since) or c.busy_since < ^stale)
        ),
        set: [busy_since: now, busy_turn_ref: turn_ref]
      )

    if count == 1, do: :ok, else: {:error, :conversation_busy}
  end

  # One statement: insert the row, or take the lock of the existing one when
  # it is free or stale. A conflict whose `WHERE` fails touches no row.
  defp lock_user(user_uuid, turn_ref, now, stale) do
    take =
      from(s in UserSettings,
        where: is_nil(s.busy_since) or s.busy_since < ^stale,
        update: [set: [busy_since: ^now, busy_turn_ref: ^turn_ref, updated_at: ^now]]
      )

    {count, _} =
      repo().insert_all(
        UserSettings,
        [
          %{
            user_uuid: user_uuid,
            busy_since: now,
            busy_turn_ref: turn_ref,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: take,
        conflict_target: [:user_uuid]
      )

    if count == 1, do: :ok, else: {:error, :turn_in_flight}
  end

  # `now()` is the transaction's start, the same for both locks.
  defp db_now do
    %{rows: [[now]]} = repo().query!("SELECT now()")
    now
  end

  defp repo, do: RepoHelper.repo()
end
