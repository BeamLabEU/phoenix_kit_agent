defmodule PhoenixKitAgent.Schemas.UserSettings do
  @moduledoc """
  The assistant settings of one user (`phoenix_kit_agent_user_settings`, keyed by
  `user_uuid`). A `nil` field means "the module default" (`PhoenixKitAgent.Config`);
  `enabled: false` switches the assistant off for this user even with the `agent`
  permission.

  `notify_user_uuids` are extra people told when this user hits a limit (the
  uuid of a deleted user is removed from every row, see
  `PhoenixKitAgent.UserDeletion`). `busy_since` / `busy_turn_ref` are the
  "one turn in flight per user" lock (`PhoenixKitAgent.Turns.Locks`, which
  leaves `updated_at` alone) and `updated_by_uuid` the last admin who changed
  the row: both are set by the caller, never cast. Money is in micro-dollars
  ($1 = 1_000_000).

  Two changesets, for the two people who write a row: `admin_changeset/2` —
  the switch, the model, the admin's prompt, the limits and the notices, for
  a caller that has checked `agent.manage`; `personal_changeset/2` — the
  user's own `personal_instructions`, nothing else. Neither casts the lock
  columns, `updated_by_uuid` or the key. Never upsert this row with
  `on_conflict: :replace_all`: that would wipe a live turn lock.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKitAgent.Schemas.Message

  @primary_key {:user_uuid, UUIDv7, autogenerate: false}
  @foreign_key_type UUIDv7

  @limits ~w(daily_cost_limit_micro_usd monthly_cost_limit_micro_usd daily_turn_limit max_attachment_mb max_attachments_per_message)a

  # The longest admin prompt and the longest personal instructions, in
  # characters: both go into every request of the user.
  @prompt_max 8_000
  @personal_max 4_000

  # The limits kept in `integer` columns (the money ones are `bigint`).
  @int4_limits ~w(daily_turn_limit max_attachment_mb max_attachments_per_message)a
  @int4_max 2_147_483_647

  # The most a money limit may be: $1,000,000, as for the module default.
  @money_max 1_000_000_000_000
  @money_limits ~w(daily_cost_limit_micro_usd monthly_cost_limit_micro_usd)a

  @type t :: %__MODULE__{}

  schema "phoenix_kit_agent_user_settings" do
    field(:enabled, :boolean)
    field(:endpoint_uuid, UUIDv7)
    field(:system_prompt, :string)
    field(:personal_instructions, :string)
    field(:daily_cost_limit_micro_usd, :integer)
    field(:monthly_cost_limit_micro_usd, :integer)
    field(:daily_turn_limit, :integer)
    field(:max_attachment_mb, :integer)
    field(:max_attachments_per_message, :integer)
    field(:notify_on_limit, :boolean, default: false)
    field(:notify_user_uuids, {:array, UUIDv7}, default: [])
    field(:busy_since, :utc_datetime_usec)
    field(:busy_turn_ref, :string)
    field(:updated_by_uuid, UUIDv7)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The per-user limit fields; each falls back to the module default when `nil`."
  @spec limit_fields() :: [atom()]
  def limit_fields, do: @limits

  @doc """
  What an admin with `agent.manage` sets for a user: switch, model, the
  admin's prompt, limits, notices. The caller checks the permission.
  """
  @spec admin_changeset(t(), map()) :: Ecto.Changeset.t()
  def admin_changeset(settings, attrs) do
    settings
    |> cast(
      attrs,
      [:enabled, :endpoint_uuid, :system_prompt, :notify_on_limit, :notify_user_uuids] ++ @limits
    )
    |> validate_required([:notify_on_limit, :notify_user_uuids])
    |> clean_text(:system_prompt, @prompt_max)
    |> then(fn changeset ->
      Enum.reduce(@limits, changeset, &validate_number(&2, &1, greater_than_or_equal_to: 0))
    end)
    |> then(fn changeset ->
      Enum.reduce(
        @money_limits,
        changeset,
        &validate_number(&2, &1, less_than_or_equal_to: @money_max)
      )
    end)
    |> then(fn changeset ->
      Enum.reduce(
        @int4_limits,
        changeset,
        &validate_number(&2, &1, less_than_or_equal_to: @int4_max)
      )
    end)
    |> key_constraints()
  end

  @doc "What the user writes for themself: `personal_instructions` only."
  @spec personal_changeset(t(), map()) :: Ecto.Changeset.t()
  def personal_changeset(settings, attrs) do
    settings
    |> cast(attrs, [:personal_instructions])
    |> clean_text(:personal_instructions, @personal_max)
    |> key_constraints()
  end

  # A text field: NUL characters cut (the database refuses them), the ends
  # trimmed, blank means none, and a length cap.
  defp clean_text(changeset, field, max) do
    changeset
    |> update_change(field, fn
      text when is_binary(text) ->
        case text |> Message.strip_nul() |> String.trim() do
          "" -> nil
          text -> text
        end

      other ->
        other
    end)
    |> validate_length(field, max: max)
  end

  defp key_constraints(changeset) do
    changeset
    |> unique_constraint(:user_uuid, name: :phoenix_kit_agent_user_settings_pkey)
    |> foreign_key_constraint(:user_uuid,
      name: :phoenix_kit_agent_user_settings_user_uuid_fkey
    )
    |> foreign_key_constraint(:endpoint_uuid,
      name: :phoenix_kit_agent_user_settings_endpoint_uuid_fkey
    )
  end
end
