defmodule PhoenixKitAgent.Library do
  @moduledoc """
  The module's own Storage library, where attachment bytes are kept.

  It is a **hidden** system library (`Libraries.create_system_library/2` with
  `hidden: true`): the site does not list it, not in Media's switcher nor in the
  media pickers, its files get only expiring URLs, and `media.view_all` opens
  none of them — only their uploader and an Owner/Admin may read one (an
  Owner/Admin reads any file of Storage by design). It is found again by its
  fixed slug and created on first use.

  Inside it every user has a folder named by their `user_uuid`, at the library
  root, created on demand. The folder only keeps things in order: Storage
  rights are per file, the protection is the hidden library and the module
  being the only way to the bytes.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Folder, Libraries, Library}
  alias PhoenixKit.RepoHelper

  # Name and slug share one namespace with every system library of the site,
  # so both carry the module's own prefix.
  @slug "phoenix-kit-agent"
  @name "PhoenixKit Agent attachments"

  @doc "The fixed slug the module finds its library by."
  @spec slug() :: String.t()
  def slug, do: @slug

  @doc "The module's library, or `nil` while it has not been created."
  @spec library() :: Library.t() | nil
  def library, do: Libraries.get_hidden_library_by_slug(@slug)

  @doc """
  The module's library, created when it does not exist yet. Two callers racing
  to create it both get the one library. `{:error, changeset}` when the slug
  or the name is taken by a library the module did not create.
  """
  @spec ensure_library() :: {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def ensure_library do
    case library() do
      %Library{} = library -> {:ok, library}
      nil -> create_library()
    end
  end

  defp create_library do
    case Libraries.create_system_library(%{"name" => @name, "slug" => @slug}, hidden: true) do
      {:ok, library} ->
        {:ok, library}

      {:error, changeset} ->
        # Another caller created it in the meantime.
        case library() do
          %Library{} = library -> {:ok, library}
          nil -> {:error, changeset}
        end
    end
  end

  @doc "The user's folder in the module's library, or `nil` while there is none."
  @spec user_folder(String.t()) :: Folder.t() | nil
  def user_folder(user_uuid) do
    with {:ok, user_uuid} <- Ecto.UUID.cast(user_uuid),
         %Library{} = library <- library() do
      find_user_folder(library, user_uuid)
    else
      _ -> nil
    end
  end

  @doc """
  The user's folder in the module's library, created (with the library) when it
  does not exist yet.
  """
  @spec ensure_user_folder(String.t()) ::
          {:ok, Folder.t()} | {:error, :invalid_user_uuid | Ecto.Changeset.t()}
  def ensure_user_folder(user_uuid) do
    with {:ok, user_uuid} <- cast_user_uuid(user_uuid),
         {:ok, library} <- ensure_library() do
      case find_user_folder(library, user_uuid) do
        %Folder{} = folder -> {:ok, folder}
        nil -> create_user_folder(library, user_uuid)
      end
    end
  end

  defp cast_user_uuid(user_uuid) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_user_uuid}
    end
  end

  defp find_user_folder(%Library{uuid: library_uuid}, user_uuid) do
    RepoHelper.repo().one(
      from(f in Folder,
        where:
          f.library_uuid == ^library_uuid and is_nil(f.parent_uuid) and f.name == ^user_uuid and
            is_nil(f.trashed_at),
        limit: 1
      )
    )
  end

  defp create_user_folder(library, user_uuid) do
    attrs = %{name: user_uuid, user_uuid: user_uuid, library_uuid: library.uuid}

    case Storage.create_folder(attrs) do
      {:ok, folder} ->
        {:ok, folder}

      {:error, changeset} ->
        # The library's root holds one live folder of a name: a concurrent
        # caller made it first.
        case find_user_folder(library, user_uuid) do
          %Folder{} = folder -> {:ok, folder}
          nil -> {:error, changeset}
        end
    end
  end
end
