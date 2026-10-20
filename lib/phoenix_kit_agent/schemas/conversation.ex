defmodule PhoenixKitAgent.Schemas.Conversation do
  @moduledoc """
  A user's chat with the assistant (`phoenix_kit_agent_conversations`).

  `user_uuid` is the owner — the only person who reads and writes the chat — and
  is set on the struct by the caller, never cast from attributes. `busy_since`
  and `busy_turn_ref` are the lock of a turn in flight; `cost_micro_usd` sums
  the turns for display (limits are counted from the AI request journal).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active archived deleted)
  @title_max 200

  @type t :: %__MODULE__{}

  schema "phoenix_kit_agent_conversations" do
    field(:title, :string)
    field(:status, :string, default: "active")
    field(:last_message_at, :utc_datetime_usec)
    field(:message_count, :integer, default: 0)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
    field(:cost_micro_usd, :integer, default: 0)
    field(:busy_since, :utc_datetime_usec)
    field(:busy_turn_ref, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:user, PhoenixKit.Users.Auth.User, foreign_key: :user_uuid, references: :uuid)

    has_many(:messages, PhoenixKitAgent.Schemas.Message,
      foreign_key: :conversation_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The statuses a chat can have: `active`, `archived`, `deleted` (soft delete)."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Changes the title, status or metadata of a chat."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:title, :status, :metadata])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, max: @title_max)
    |> foreign_key_constraint(:user_uuid,
      name: :phoenix_kit_agent_conversations_user_uuid_fkey
    )
  end
end
