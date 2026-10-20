defmodule PhoenixKitAgent.Schemas.Attachment do
  @moduledoc """
  A file attached to a message (`phoenix_kit_agent_attachments`). The bytes live
  in Storage, in the module's hidden library (`file_uuid`); the row keeps what
  the model reads: the extracted text of a PDF or a sheet, truncated to a limit.

  `conversation_uuid`, `message_uuid`, `user_uuid` and `file_uuid` are set by the
  caller, never cast.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @kinds ~w(image pdf sheet text)
  @statuses ~w(pending ready failed)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_agent_attachments" do
    field(:filename, :string)
    field(:content_type, :string)
    field(:size_bytes, :integer)
    field(:kind, :string)
    field(:status, :string, default: "pending")
    field(:extracted_text, :string)
    field(:pages, :integer)
    field(:truncated, :boolean, default: false)
    field(:error, :string)

    belongs_to(:conversation, PhoenixKitAgent.Schemas.Conversation,
      foreign_key: :conversation_uuid,
      references: :uuid
    )

    belongs_to(:message, PhoenixKitAgent.Schemas.Message,
      foreign_key: :message_uuid,
      references: :uuid
    )

    belongs_to(:user, PhoenixKit.Users.Auth.User, foreign_key: :user_uuid, references: :uuid)
    belongs_to(:file, PhoenixKit.Modules.Storage.File, foreign_key: :file_uuid, references: :uuid)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The kinds of attachment: `image`, `pdf`, `sheet`, `text`."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Builds an attachment from its file description and processing state."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :filename,
      :content_type,
      :size_bytes,
      :kind,
      :status,
      :extracted_text,
      :pages,
      :truncated,
      :error
    ])
    |> validate_required([:filename, :content_type, :size_bytes, :kind, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:conversation_uuid,
      name: :phoenix_kit_agent_attachments_conversation_uuid_fkey
    )
    |> foreign_key_constraint(:message_uuid,
      name: :phoenix_kit_agent_attachments_message_uuid_fkey
    )
    |> foreign_key_constraint(:user_uuid, name: :phoenix_kit_agent_attachments_user_uuid_fkey)
    |> foreign_key_constraint(:file_uuid, name: :phoenix_kit_agent_attachments_file_uuid_fkey)
  end
end
