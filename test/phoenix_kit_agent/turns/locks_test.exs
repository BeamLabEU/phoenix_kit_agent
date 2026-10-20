defmodule PhoenixKitAgent.Turns.LocksTest do
  @moduledoc """
  The two row locks of a turn (spec §6.1 step 3): taken together, held by one
  turn ref, released only by the turn that holds them.
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitAgent.Schemas.{Conversation, UserSettings}
  alias PhoenixKitAgent.Turns.Locks

  @ttl_s 360

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    user = user_fixture("locks")
    %{user: user, chat: conversation_fixture(user)}
  end

  defp holders(ctx) do
    {Repo.get!(Conversation, ctx.chat.uuid).busy_turn_ref,
     Repo.get!(UserSettings, ctx.user.uuid).busy_turn_ref}
  end

  test "a release by an older turn leaves the newer turn's locks in place", ctx do
    assert :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "old", @ttl_s)
    :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "old")
    assert :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "new", @ttl_s)

    :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "old")

    assert holders(ctx) == {"new", "new"}
    assert Locks.held?(ctx.user.uuid, ctx.chat.uuid, "new")
  end

  test "held?/3 is true only while the turn holds both locks", ctx do
    refute Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t1")

    :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)
    assert Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t1")
    refute Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t2")

    Repo.update_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid),
      set: [busy_turn_ref: "t2"]
    )

    refute Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t1")

    :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "t1")
    refute Locks.held?(ctx.user.uuid, ctx.chat.uuid, "t1")
  end

  test "taking and releasing the user's lock leaves the settings' updated_at alone", ctx do
    changed = ~U[2026-01-02 03:04:05.000000Z]

    Repo.insert!(%UserSettings{
      user_uuid: ctx.user.uuid,
      daily_turn_limit: 3,
      updated_at: changed
    })

    :ok = Locks.acquire(ctx.user.uuid, ctx.chat.uuid, "t1", @ttl_s)
    assert Repo.get!(UserSettings, ctx.user.uuid).updated_at == changed

    :ok = Locks.release(ctx.user.uuid, ctx.chat.uuid, "t1")
    settings = Repo.get!(UserSettings, ctx.user.uuid)
    assert settings.updated_at == changed
    assert settings.daily_turn_limit == 3
  end
end
