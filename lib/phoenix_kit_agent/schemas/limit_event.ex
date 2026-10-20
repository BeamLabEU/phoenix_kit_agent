defmodule PhoenixKitAgent.Schemas.LimitEvent do
  @moduledoc """
  A limit notice that was sent (`phoenix_kit_agent_limit_events`): at most one per
  user, kind and period (`period_key` is `"2026-10-19"` for a day, `"2026-10"` for
  a month), which is how a limit is announced once. A `warn_80` row names its
  limit in the key — `"cost:2026-10-19"`, `"cost:2026-10"`, `"turns:2026-10-19"` —
  so each of the three limits warns once (`PhoenixKitAgent.Limits`). `used` and
  `limit` are in the limit's own unit (micro-dollars or turns; none for
  `ai_budget`). `user_uuid` is set by the caller.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @kinds ~w(daily_cost monthly_cost daily_turns warn_80 ai_budget)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_agent_limit_events" do
    field(:limit_kind, :string)
    field(:period_key, :string)
    field(:used, :integer)
    field(:limit, :integer)
    field(:notified_at, :utc_datetime_usec)

    belongs_to(:user, PhoenixKit.Users.Auth.User, foreign_key: :user_uuid, references: :uuid)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The kinds of limit notice."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Builds a limit notice."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:limit_kind, :period_key, :used, :limit, :notified_at])
    |> validate_required([:limit_kind, :period_key])
    |> validate_inclusion(:limit_kind, @kinds)
    |> validate_length(:period_key, max: 16)
    |> unique_constraint(:user_uuid,
      name: :phoenix_kit_agent_limit_events_user_kind_period_index
    )
    |> foreign_key_constraint(:user_uuid,
      name: :phoenix_kit_agent_limit_events_user_uuid_fkey
    )
  end
end
