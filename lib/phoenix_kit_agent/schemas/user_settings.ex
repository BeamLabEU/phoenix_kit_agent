defmodule PhoenixKitAgent.Schemas.UserSettings do
  @moduledoc """
  The assistant settings of one user (`phoenix_kit_agent_user_settings`, keyed by
  `user_uuid`). A `nil` field means "the module default" (`PhoenixKitAgent.Config`);
  `enabled: false` switches the assistant off for this user even with the `agent`
  permission.

  `notify_user_uuids` are extra people told when this user hits a limit (the
  uuid of a deleted user is removed from every row, see
  `PhoenixKitAgent.UserDeletion`). `busy_since` / `busy_turn_ref` are the
  "one turn in flight per user" lock and `updated_by_uuid` the last admin who
  changed the row: both are set by the caller, never cast. Money is in
  micro-dollars ($1 = 1_000_000).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:user_uuid, UUIDv7, autogenerate: false}
  @foreign_key_type UUIDv7

  @limits ~w(daily_cost_limit_micro_usd monthly_cost_limit_micro_usd daily_turn_limit max_attachment_mb max_attachments_per_message)a

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

  @doc "Changes the settings a person edits: switch, model, prompts, limits, notices."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(
      attrs,
      [
        :enabled,
        :endpoint_uuid,
        :system_prompt,
        :personal_instructions,
        :notify_on_limit,
        :notify_user_uuids
      ] ++ @limits
    )
    |> then(fn changeset ->
      Enum.reduce(@limits, changeset, &validate_number(&2, &1, greater_than_or_equal_to: 0))
    end)
    |> unique_constraint(:user_uuid, name: :phoenix_kit_agent_user_settings_pkey)
    |> foreign_key_constraint(:user_uuid,
      name: :phoenix_kit_agent_user_settings_user_uuid_fkey
    )
    |> foreign_key_constraint(:endpoint_uuid,
      name: :phoenix_kit_agent_user_settings_endpoint_uuid_fkey
    )
  end
end
