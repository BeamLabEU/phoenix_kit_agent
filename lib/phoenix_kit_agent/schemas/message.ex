defmodule PhoenixKitAgent.Schemas.Message do
  @moduledoc """
  One message of a chat (`phoenix_kit_agent_messages`): what the user wrote, a
  model answer (with the tool calls it asked for), a tool result, or a notice
  (a limit, an error, a refusal). The table is also the assistant's journal of
  tool calls: who, what, when, and the outcome.

  `conversation_uuid` and `ai_request_uuid` are set by the caller, never cast.
  `tool_name` is the registry name of the tool, not the name shown to the model;
  `tool_result` is the truncated result, without confirmation tokens or other
  control fields.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @roles ~w(user assistant tool notice)
  @tool_outcomes ~w(ok error denied needs_confirmation confirmed rejected)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_agent_messages" do
    field(:turn_ref, :string)
    field(:role, :string)
    field(:content, :string)
    field(:tool_calls, {:array, :map})
    field(:tool_call_id, :string)
    field(:tool_name, :string)
    field(:tool_outcome, :string)
    field(:tool_result, :map)
    field(:model, :string)
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    field(:cost_micro_usd, :integer)
    field(:latency_ms, :integer)
    field(:error, :string)

    belongs_to(:conversation, PhoenixKitAgent.Schemas.Conversation,
      foreign_key: :conversation_uuid,
      references: :uuid
    )

    field(:ai_request_uuid, UUIDv7)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The message roles: `user`, `assistant`, `tool`, `notice`."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc "The outcomes of a tool call."
  @spec tool_outcomes() :: [String.t()]
  def tool_outcomes, do: @tool_outcomes

  @doc "Builds a message from its content fields."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :turn_ref,
      :role,
      :content,
      :tool_calls,
      :tool_call_id,
      :tool_name,
      :tool_outcome,
      :tool_result,
      :model,
      :input_tokens,
      :output_tokens,
      :cost_micro_usd,
      :latency_ms,
      :error
    ])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:tool_outcome, @tool_outcomes)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:conversation_uuid,
      name: :phoenix_kit_agent_messages_conversation_uuid_fkey
    )
    |> foreign_key_constraint(:ai_request_uuid,
      name: :phoenix_kit_agent_messages_ai_request_uuid_fkey
    )
  end
end
