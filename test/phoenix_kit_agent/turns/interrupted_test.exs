defmodule PhoenixKitAgent.Turns.InterruptedTest do
  @moduledoc """
  A turn lost with its node (a restart, a monitor that went down): its locks
  stay until their TTL, and nothing in the chat says what happened. When the
  chat is opened again (`Turns.settle_interrupted/3`) such a turn — its lock
  older than the TTL, its task not running here — gets the notice "the answer
  was interrupted" and its locks are released (decision of 2026-10-20, spec
  §6.1).
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitAgent.{Config, Conversations, Turns}
  alias PhoenixKitAgent.Schemas.{Conversation, Message, UserSettings}

  @registry PhoenixKitAgent.Turns.Registry

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    user = user_with(["agent"], "interrupted")
    {ref, _token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, impersonated: false)
    %{user: user, ref: ref, chat: chat}
  end

  defp ttl_s, do: Config.turn_deadline_s() + 60

  defp lock!(ctx, turn_ref, age_s) do
    since = DateTime.add(DateTime.utc_now(), -age_s, :second)

    Repo.update_all(from(c in Conversation, where: c.uuid == ^ctx.chat.uuid),
      set: [busy_since: since, busy_turn_ref: turn_ref]
    )

    Repo.insert!(
      %UserSettings{user_uuid: ctx.user.uuid, busy_since: since, busy_turn_ref: turn_ref},
      on_conflict: [set: [busy_since: since, busy_turn_ref: turn_ref]],
      conflict_target: :user_uuid
    )
  end

  defp chat_lock(ctx) do
    c = Repo.get!(Conversation, ctx.chat.uuid)
    {c.busy_since, c.busy_turn_ref}
  end

  defp user_lock(ctx) do
    s = Repo.get!(UserSettings, ctx.user.uuid)
    {s.busy_since, s.busy_turn_ref}
  end

  defp notices(ctx) do
    Repo.all(
      from(m in Message, where: m.conversation_uuid == ^ctx.chat.uuid and m.role == "notice")
    )
  end

  test "a lock older than the TTL with no task here: a notice, and the locks are free", ctx do
    turn_ref = UUIDv7.generate()
    lock!(ctx, turn_ref, ttl_s() + 30)

    assert {:ok, :interrupted} = Turns.settle_interrupted(ctx.ref, false, ctx.chat.uuid)

    assert [%Message{error: "interrupted", turn_ref: ^turn_ref, content: content}] = notices(ctx)
    assert content =~ "interrupted"
    assert chat_lock(ctx) == {nil, nil}
    assert user_lock(ctx) == {nil, nil}

    chat_uuid = ctx.chat.uuid
    assert_received {:agent_message_added, ^chat_uuid, _message_uuid}
    assert_received {:agent_turn_finished, ^chat_uuid, ^turn_ref}

    # Once only.
    assert {:ok, :idle} = Turns.settle_interrupted(ctx.ref, false, ctx.chat.uuid)
    assert length(notices(ctx)) == 1
  end

  test "a lock within its TTL is a turn under way: nothing is written", ctx do
    turn_ref = UUIDv7.generate()
    lock!(ctx, turn_ref, 5)

    assert {:ok, {:running, ^turn_ref}} = Turns.settle_interrupted(ctx.ref, false, ctx.chat.uuid)
    assert notices(ctx) == []
    assert {_, ^turn_ref} = chat_lock(ctx)
  end

  test "a stale lock whose task still runs here is left alone", ctx do
    turn_ref = UUIDv7.generate()
    lock!(ctx, turn_ref, ttl_s() + 30)
    {:ok, _} = Registry.register(@registry, turn_ref, ctx.chat.uuid)

    assert {:ok, {:running, ^turn_ref}} = Turns.settle_interrupted(ctx.ref, false, ctx.chat.uuid)
    assert notices(ctx) == []
    assert {_, ^turn_ref} = chat_lock(ctx)
  end

  test "the user's lock held by another turn stays", ctx do
    lost = UUIDv7.generate()
    lock!(ctx, lost, ttl_s() + 30)
    newer = UUIDv7.generate()

    Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid),
      set: [busy_since: DateTime.utc_now(), busy_turn_ref: newer]
    )

    assert {:ok, :interrupted} = Turns.settle_interrupted(ctx.ref, false, ctx.chat.uuid)
    assert chat_lock(ctx) == {nil, nil}
    assert {_, ^newer} = user_lock(ctx)
  end

  test "a chat without a lock is idle", ctx do
    assert {:ok, :idle} = Turns.settle_interrupted(ctx.ref, false, ctx.chat.uuid)
    assert notices(ctx) == []
  end

  test "an impersonated session or someone else's chat is refused, and nothing changes", ctx do
    turn_ref = UUIDv7.generate()
    lock!(ctx, turn_ref, ttl_s() + 30)

    assert {:error, :impersonated} = Turns.settle_interrupted(ctx.ref, true, ctx.chat.uuid)

    other = user_with(["agent"], "other")
    {other_ref, _} = session_fixture(other)
    assert {:error, :not_found} = Turns.settle_interrupted(other_ref, false, ctx.chat.uuid)

    assert notices(ctx) == []
    assert {_, ^turn_ref} = chat_lock(ctx)
  end
end
