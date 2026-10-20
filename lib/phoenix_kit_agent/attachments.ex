defmodule PhoenixKitAgent.Attachments do
  @moduledoc """
  Files attached to a chat (spec §5.3, §9).

  Like `PhoenixKitAgent.Conversations`, every function acts for a **live
  browser session**: the `{session_token_uuid, user_uuid}` reference and, in
  the options, `impersonated: boolean` (`PhoenixKitAgent.Conversations` has the
  checks that come first and their refusals: an impersonated or revoked
  session, a user without `agent`, a chat that is not the user's). The owner
  is the only one who adds a file to a chat, reads its row, discards it or is
  given the address of its bytes; an Owner or an Admin of the site is no
  exception here.

  ## Adding a file

  `add/4` takes the file the Dock got from `allow_upload` (its temporary
  path and the name and type the browser gave), checks it, keeps it and starts
  its processing, and returns the row as `pending`. In order:

    1. the chat is the session user's; the upload is a readable, non-empty
       file no larger than `max_attachment_mb` (the size is read from the file,
       not believed from the caller);
    2. the **content** tells the kind (`PhoenixKitAgent.Attachments.Detect`):
       png/jpg/webp/heic, pdf, xlsx/csv, txt/md; anything else is
       `:unsupported_type`;
    3. the chat has room: no more than `max_attachments_per_message` files that
       are not part of a message yet (a failed one takes no room). The count
       and the row are made under a lock on the chat, so parallel uploads
       cannot pass it;
    4. the bytes are stored in the module's hidden Storage library, in the
       user's folder (`PhoenixKitAgent.Library`), uploaded by the user — a
       Manager with `media.view_all` neither sees nor reads them, and the
       permanent file token is refused; the file is not in Media. The same
       bytes of the same user are one Storage file, as in any library;
    5. `PhoenixKitAgent.Attachments.Processor` works on the file in a task.

  `add/4` writes to Storage and may take long: call it off the LiveView
  process. The row's `status` goes `pending` → `ready` | `failed`; when it
  does the chat's topic (`PhoenixKitAgent.Conversations.topic/1`) hears
  `{:agent_attachment_processed, conversation_uuid, attachment_uuid}`, and the
  listener reads the row with `get/3`. `error` of a failed row is a code (see
  the processor), never text of the file.

  ## Sending

  A `ready` attachment that belongs to the user and to the chat is passed to
  `PhoenixKitAgent.Turns.start/6` by uuid; the turn links it to the user
  message it stores. Its extracted text goes with the message and stays in the
  history; a picture's pixels (`pictures/1`) go only in the turn of that
  message.

  ## The bytes

  Nobody but the owner gets at them, and only through `url/3`: an expiring
  address of the file in Storage, minted for the session's own scope.

  ## Refusals

  Those of `PhoenixKitAgent.Conversations`, and `:file_unreadable`,
  `:empty_file`, `:too_large`, `:unsupported_type`, `:too_many`,
  `:storage_unavailable`, `:already_sent`.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitAgent.Attachments.{Detect, Extract, Processor}
  alias PhoenixKitAgent.{Conversations, Library, Models, UserConfig}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation}

  @mb 1_048_576
  @name_chars 200

  @typedoc "The file as the Dock got it from `allow_upload`."
  @type upload :: %{
          required(:path) => Path.t(),
          required(:filename) => String.t(),
          optional(:content_type) => String.t() | nil
        }

  @typedoc "Why a call was refused."
  @type refusal ::
          Conversations.refusal()
          | :file_unreadable
          | :empty_file
          | :too_large
          | :unsupported_type
          | :too_many
          | :storage_unavailable
          | :already_sent

  # ── adding ──────────────────────────────────────────────────────────

  @doc """
  Adds `upload` to the session user's chat (see the moduledoc). Returns the
  `pending` row; the file's processing has started.
  """
  @spec add(Conversations.session_ref(), term(), upload() | term(), keyword()) ::
          {:ok, Attachment.t()} | {:error, refusal()}
  def add(session_ref, conversation_uuid, upload, opts) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid, opts),
         {:ok, source} <- readable(upload),
         settings = UserConfig.effective(conversation.user_uuid),
         :ok <- size_allowed(source.size, settings),
         {:ok, detected} <- Detect.detect(source.path, source.filename),
         {:ok, attachment} <- reserve(conversation, source, detected, settings),
         {:ok, attachment} <- store(attachment, source, detected) do
      :ok = Processor.start(attachment.uuid)
      {:ok, attachment}
    end
  end

  defp readable(%{path: path, filename: filename}) when is_binary(path) and is_binary(filename) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} ->
        {:error, :empty_file}

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:ok, %{path: path, filename: clean_name(filename), size: size}}

      _not_a_file ->
        {:error, :file_unreadable}
    end
  end

  defp readable(_not_an_upload), do: {:error, :file_unreadable}

  defp size_allowed(size, settings) do
    if size <= settings.max_attachment_mb * @mb, do: :ok, else: {:error, :too_large}
  end

  # A plain name: the last path segment of either kind, no control characters.
  defp clean_name(filename) do
    name =
      filename
      |> String.split(["/", "\\"])
      |> List.last()
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.trim()
      |> String.slice(0, @name_chars)

    if name in ["", ".", ".."], do: "file", else: name
  end

  # The row, made under a lock on the chat so that the count of files waiting
  # for a message and the new row are one step.
  defp reserve(conversation, source, detected, settings) do
    result =
      repo().transaction(fn ->
        locked =
          repo().one(
            from(c in Conversation,
              where: c.uuid == ^conversation.uuid and c.status != "deleted",
              lock: "FOR UPDATE"
            )
          )

        waiting =
          repo().aggregate(
            from(a in Attachment,
              where:
                a.conversation_uuid == ^conversation.uuid and is_nil(a.message_uuid) and
                  a.status in ["pending", "ready"]
            ),
            :count
          )

        cond do
          is_nil(locked) -> repo().rollback(:not_found)
          waiting >= settings.max_attachments_per_message -> repo().rollback(:too_many)
          true -> insert_row(conversation, source, detected)
        end
      end)

    case result do
      {:ok, attachment} -> {:ok, attachment}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  # `log: false`: Ecto would print the bound values, and the file's name is the
  # user's (spec §8.2, the log rule of AGENTS.md).
  defp insert_row(conversation, source, detected) do
    %Attachment{conversation_uuid: conversation.uuid, user_uuid: conversation.user_uuid}
    |> Attachment.changeset(%{
      filename: source.filename,
      content_type: detected.content_type,
      size_bytes: source.size,
      kind: detected.kind,
      status: "pending"
    })
    |> repo().insert!(log: false)
  end

  # The bytes go to Storage; a row whose file could not be kept is removed.
  defp store(attachment, source, detected) do
    with {:ok, folder} <- Library.ensure_user_folder(attachment.user_uuid),
         {:ok, checksum} <- checksum(source.path),
         {:ok, file} <- put_file(attachment, source, detected, folder, checksum),
         {:ok, _file} <- Storage.attach_file_to_folder(file, folder.uuid),
         {1, _} <- link_file(attachment, file) do
      {:ok, %{attachment | file_uuid: file.uuid}}
    else
      _failed ->
        remove_row(attachment)
        {:error, :storage_unavailable}
    end
  rescue
    _exception ->
      remove_row(attachment)
      {:error, :storage_unavailable}
  end

  defp put_file(attachment, source, detected, folder, checksum) do
    result =
      Storage.store_file_in_buckets(
        source.path,
        Storage.determine_file_type(detected.content_type, source.filename),
        attachment.user_uuid,
        checksum,
        detected.ext,
        source.filename,
        library_uuid: folder.library_uuid,
        mime_type: detected.content_type
      )

    case result do
      {:ok, %Storage.File{} = file} -> {:ok, file}
      {:ok, %Storage.File{} = file, _duplicate} -> {:ok, file}
      _failed -> :error
    end
  end

  defp checksum(path) do
    hash =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, hash}
  rescue
    _ -> :error
  end

  defp link_file(attachment, file) do
    repo().update_all(from(a in Attachment, where: a.uuid == ^attachment.uuid),
      set: [file_uuid: file.uuid]
    )
  end

  defp remove_row(attachment) do
    repo().delete_all(from(a in Attachment, where: a.uuid == ^attachment.uuid))
  rescue
    _ -> :ok
  end

  # ── reading ─────────────────────────────────────────────────────────

  @doc "The session user's attachment `attachment_uuid`."
  @spec get(Conversations.session_ref(), term(), keyword()) ::
          {:ok, Attachment.t()} | {:error, refusal()}
  def get(session_ref, attachment_uuid, opts) do
    with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts) do
      fetch(user_uuid, attachment_uuid)
    end
  end

  @doc """
  The files of the chat that wait for a message, oldest first, whatever their
  status (a failed one is there to be seen and discarded).
  """
  @spec list_unsent(Conversations.session_ref(), term(), keyword()) ::
          {:ok, [Attachment.t()]} | {:error, refusal()}
  def list_unsent(session_ref, conversation_uuid, opts) do
    with {:ok, conversation} <-
           Conversations.owned_conversation(session_ref, conversation_uuid, opts) do
      {:ok,
       repo().all(
         from(a in Attachment,
           where: a.conversation_uuid == ^conversation.uuid and is_nil(a.message_uuid),
           order_by: [asc: a.inserted_at, asc: a.uuid]
         )
       )}
    end
  end

  @doc """
  Removes a file that has not been sent yet from the chat. The bytes stay in
  Storage until the module's retention removes them (spec §9, Б3.4); a file
  that is part of a message is `{:error, :already_sent}`.
  """
  @spec discard(Conversations.session_ref(), term(), keyword()) :: :ok | {:error, refusal()}
  def discard(session_ref, attachment_uuid, opts) do
    with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts),
         {:ok, attachment} <- fetch(user_uuid, attachment_uuid) do
      {count, _} =
        repo().delete_all(
          from(a in Attachment,
            where:
              a.uuid == ^attachment.uuid and a.user_uuid == ^user_uuid and is_nil(a.message_uuid)
          )
        )

      if count == 1, do: :ok, else: {:error, :already_sent}
    end
  end

  @doc """
  An expiring address of the bytes of the user's attachment, minted for the
  session's own scope (`variant`: `"original"` by default, or a Storage
  variant such as `"thumbnail"` of a picture).
  """
  @spec url(Conversations.session_ref(), term(), keyword()) ::
          {:ok, String.t()} | {:error, refusal()}
  def url(session_ref, attachment_uuid, opts) do
    variant = if is_binary(opts[:variant]), do: opts[:variant], else: "original"

    with {:ok, scope} <- Conversations.authorized_scope(session_ref, opts),
         {:ok, %Attachment{file_uuid: file_uuid}} when is_binary(file_uuid) <-
           fetch(Scope.user_uuid(scope), attachment_uuid),
         %Storage.File{} = file <- repo().get(Storage.File, file_uuid),
         url when is_binary(url) <- Storage.authorized_url(scope, file, variant) do
      {:ok, url}
    else
      {:error, _refusal} = error -> error
      _no_file_or_no_right -> {:error, :not_found}
    end
  end

  defp fetch(user_uuid, attachment_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(attachment_uuid),
         %Attachment{} = attachment <-
           repo().one(
             from(a in Attachment,
               join: c in Conversation,
               on: c.uuid == a.conversation_uuid,
               where: a.uuid == ^uuid and a.user_uuid == ^user_uuid and c.status != "deleted"
             )
           ) do
      {:ok, attachment}
    else
      _unknown_or_not_theirs -> {:error, :not_found}
    end
  end

  # ── what the model is given ─────────────────────────────────────────

  @doc """
  Whether the model is shown this attachment as pixels: a `ready` picture, or
  a scanned PDF, that has no text.
  """
  @spec pixels?(Attachment.t()) :: boolean()
  def pixels?(%Attachment{status: "ready", kind: kind, extracted_text: nil}),
    do: kind in ["image", "pdf"]

  def pixels?(_attachment), do: false

  @doc """
  The pictures of a pixel attachment as data URLs for a model: a picture as a
  JPEG of at most 1600 px on its long side, a scan as PNGs of its first pages.
  `{:ok, []}` for any other attachment.
  """
  @spec pictures(Attachment.t()) ::
          {:ok, [String.t()]} | {:error, :unreadable | :image_tools_missing | :pdf_tools_missing}
  def pictures(%Attachment{kind: "image", file_uuid: file_uuid}) when is_binary(file_uuid) do
    with_file(file_uuid, fn path ->
      with {:ok, jpeg} <- Extract.picture(path), do: {:ok, [data_url("image/jpeg", jpeg)]}
    end)
  end

  def pictures(%Attachment{kind: "pdf", file_uuid: file_uuid}) when is_binary(file_uuid) do
    with_file(file_uuid, fn path ->
      with {:ok, pngs, _pages} <- Extract.pdf_pages(path),
           do: {:ok, Enum.map(pngs, &data_url("image/png", &1))}
    end)
  end

  def pictures(%Attachment{}), do: {:ok, []}

  defp with_file(file_uuid, fun) do
    case Storage.retrieve_file(file_uuid) do
      {:ok, path, _file} ->
        try do
          fun.(path)
        after
          File.rm(path)
        end

      _not_retrievable ->
        {:error, :unreadable}
    end
  end

  defp data_url(type, bytes), do: "data:" <> type <> ";base64," <> Base.encode64(bytes)

  @doc false
  # What the turn adds to the user's message after its text, for the pixel
  # attachments among `uuids` (the user's own): the pictures as `image_url`
  # parts, or a note when the model cannot see them or a picture cannot be
  # made. `[]` when there are none.
  @spec model_parts([String.t()], String.t(), String.t() | nil) :: [map()]
  def model_parts(uuids, user_uuid, endpoint_uuid) do
    rows =
      repo().all(
        from(a in Attachment,
          where: a.uuid in ^uuids and a.user_uuid == ^user_uuid,
          order_by: [asc: a.inserted_at, asc: a.uuid]
        )
      )
      |> Enum.filter(&pixels?/1)

    cond do
      rows == [] ->
        []

      Models.image_input(endpoint_uuid) == :unsupported ->
        [note("The attached pictures were not shown: this model cannot see images.")]

      true ->
        Enum.flat_map(rows, &parts_of/1)
    end
  end

  defp parts_of(attachment) do
    case pictures(attachment) do
      {:ok, urls} ->
        Enum.map(urls, &%{"type" => "image_url", "image_url" => %{"url" => &1}})

      {:error, _code} ->
        [note("The attachment #{attachment.filename} could not be shown.")]
    end
  end

  defp note(text), do: %{"type" => "text", "text" => "[" <> text <> "]"}

  defp repo, do: RepoHelper.repo()
end
