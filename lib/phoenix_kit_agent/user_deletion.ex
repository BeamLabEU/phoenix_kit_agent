defmodule PhoenixKitAgent.UserDeletion do
  @moduledoc """
  What the module does before core deletes a user (`before_user_delete/1`,
  spec §5.7). Core calls it outside the delete's transaction, whether or not the
  module is enabled, and a failure here never stops the delete.

    1. **Attachment files.** Every Storage file of the user's attachments is
       deleted completely (`Storage.delete_file_completely/1`) — **only if** it
       lies in the module's hidden library (`PhoenixKitAgent.Library`) **and**
       nothing but this user's attachments refers to it. Anything else (a file
       in Media, a file another row points at) is only unlinked from the
       attachment and left alone. Without this the files would stay behind,
       with personal data, owned by nobody (`phoenix_kit_files.user_uuid` is
       set to `NULL` with the user).
    2. **The user's folder** in the module's library: files still in it that
       nothing refers to are deleted the same way, then the folder is removed
       (a file that is kept moves to the library root).
    3. The user's uuid leaves `notify_user_uuids` of other users' settings and
       the `agent_limit_watchers` setting.

  The user's rows in the module's tables are deleted with the user row by the
  database (`ON DELETE CASCADE`).

  "Refers to" means a row of any table whose foreign key points at the file,
  found in the database catalogue, so a module that links files later is
  covered too. Storage's own rows of the file (its instances, its system
  children) do not count; a folder link, a derived copy or a folder cover does.
  A reference without a foreign key cannot be seen; the hidden library is not
  offered by any picker, which is what keeps such references from existing.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Folder, Library}
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Config, Migrations}
  alias PhoenixKitAgent.Library, as: AgentLibrary
  alias PhoenixKitAgent.Schemas.{Attachment, UserSettings}

  require Logger

  # Storage's own rows of a file: its stored variants and its system-managed
  # children. They go with the file and are not "someone else using it".
  @storage_internal [
    {"phoenix_kit_file_instances", "file_uuid"},
    {"phoenix_kit_files", "parent_file_uuid"}
  ]

  @attachments_table "phoenix_kit_agent_attachments"

  @doc "Runs the cleanup for `user_uuid`. Always `:ok`; failures are logged."
  @spec run(String.t()) :: :ok
  def run(user_uuid) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, user_uuid} -> do_run(user_uuid)
      :error -> :ok
    end
  end

  # Each step runs on its own: one that fails is logged and the others still
  # run (the user row is deleted either way).
  defp do_run(user_uuid) do
    if Migrations.migrated_version_runtime() > 0 do
      ctx = %{user_uuid: user_uuid, library: AgentLibrary.library(), refs: nil}

      ctx =
        if ctx.library,
          do: %{ctx | refs: step("file references", nil, &file_references/0)},
          else: ctx

      step("attachment files", :ok, fn -> remove_attachment_files(ctx) end)
      step("user folder", :ok, fn -> remove_user_folder(ctx) end)
      step("notice lists", :ok, fn -> remove_from_notice_lists(user_uuid) end)
    end

    step("agent_limit_watchers", :ok, fn -> remove_from_watchers(user_uuid) end)
    :ok
  end

  defp step(what, fallback, fun) do
    fun.()
  rescue
    error ->
      log_failure(what, Exception.message(error))
      fallback
  catch
    kind, reason ->
      log_failure(what, {kind, reason})
      fallback
  end

  # ── 1. attachment files ───────────────────────────────────────────────

  defp remove_attachment_files(%{user_uuid: user_uuid} = ctx) do
    from(a in Attachment,
      where: a.user_uuid == ^user_uuid and not is_nil(a.file_uuid),
      distinct: true,
      select: a.file_uuid
    )
    |> repo().all()
    |> Enum.each(fn file_uuid ->
      if deletable?(file_uuid, ctx) do
        delete_file(file_uuid)
      else
        unlink(file_uuid, user_uuid)
      end
    end)
  end

  defp unlink(file_uuid, user_uuid) do
    from(a in Attachment, where: a.user_uuid == ^user_uuid and a.file_uuid == ^file_uuid)
    |> repo().update_all(set: [file_uuid: nil])
  end

  # ── 2. the user's folder ──────────────────────────────────────────────

  defp remove_user_folder(%{library: nil}), do: :ok

  defp remove_user_folder(%{user_uuid: user_uuid} = ctx) do
    case AgentLibrary.user_folder(user_uuid) do
      %Folder{} = folder ->
        from(f in Storage.File, where: f.folder_uuid == ^folder.uuid, select: f.uuid)
        |> repo().all()
        |> Enum.filter(&deletable?(&1, ctx))
        |> Enum.each(&delete_file/1)

        case Storage.delete_folder(folder) do
          {:ok, _} -> :ok
          other -> log_failure("folder #{folder.uuid}", other)
        end

      nil ->
        :ok
    end
  end

  # ── 3. notice lists and watchers ──────────────────────────────────────

  defp remove_from_notice_lists(user_uuid) do
    from(s in UserSettings,
      where: fragment("? = ANY(?)", type(^user_uuid, UUIDv7), s.notify_user_uuids),
      update: [
        set: [
          notify_user_uuids:
            fragment("array_remove(?, ?)", s.notify_user_uuids, type(^user_uuid, UUIDv7)),
          updated_at: ^DateTime.utc_now()
        ]
      ]
    )
    |> repo().update_all([])

    :ok
  end

  defp remove_from_watchers(user_uuid) do
    case Config.remove_limit_watcher(user_uuid) do
      {:ok, _} -> :ok
      other -> log_failure("agent_limit_watchers", other)
    end
  end

  # ── whether a file may go ─────────────────────────────────────────────

  # Never without the library or the list of references: unknown means keep.
  defp deletable?(_file_uuid, %{library: nil}), do: false
  defp deletable?(_file_uuid, %{refs: nil}), do: false

  defp deletable?(file_uuid, %{library: %Library{uuid: library_uuid}} = ctx) do
    case repo().get(Storage.File, file_uuid) do
      %Storage.File{library_uuid: ^library_uuid} ->
        not referenced_elsewhere?(file_uuid, ctx)

      _ ->
        false
    end
  end

  defp referenced_elsewhere?(file_uuid, %{user_uuid: user_uuid, refs: refs}) do
    {:ok, file} = Ecto.UUID.dump(file_uuid)
    {:ok, user} = Ecto.UUID.dump(user_uuid)

    Enum.any?(refs, fn {_schema, table, column} = ref ->
      cond do
        {table, column} in @storage_internal ->
          false

        # The user's own attachments are what is being removed; another user's
        # attachment of the same file is a use.
        table == @attachments_table ->
          exists?(ref, "AND user_uuid <> $2", [file, user])

        true ->
          exists?(ref, "", [file])
      end
    end)
  end

  # Every single-column foreign key that points at phoenix_kit_files, as
  # {schema, table, column}, read from the catalogue.
  defp file_references do
    %{rows: rows} =
      repo().query!(
        """
        SELECT n.nspname, t.relname, a.attname
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
        WHERE c.contype = 'f'
          AND c.confrelid = $1::text::regclass
          AND array_length(c.conkey, 1) = 1
        """,
        [files_table()]
      )

    Enum.map(rows, fn [schema, table, column] -> {schema, table, column} end)
  end

  defp exists?({schema, table, column}, extra_condition, params) do
    %{rows: [[found]]} =
      repo().query!(
        "SELECT EXISTS (SELECT 1 FROM #{quote_ident(schema)}.#{quote_ident(table)} " <>
          "WHERE #{quote_ident(column)} = $1 #{extra_condition})",
        params
      )

    found
  end

  defp delete_file(file_uuid) do
    case Storage.delete_file_completely(file_uuid) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      other -> log_failure("file #{file_uuid}", other)
    end
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp repo, do: RepoHelper.repo()

  defp files_table do
    case Storage.File.__schema__(:prefix) do
      nil -> Storage.File.__schema__(:source)
      prefix -> "#{prefix}.#{Storage.File.__schema__(:source)}"
    end
  end

  defp quote_ident(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  defp log_failure(what, reason) do
    Logger.warning(
      "[PhoenixKitAgent] user deletion cleanup of #{what} failed: #{inspect(reason)}"
    )

    :ok
  end
end
