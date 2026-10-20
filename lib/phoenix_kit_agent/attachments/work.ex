defmodule PhoenixKitAgent.Attachments.Work do
  @moduledoc """
  The scratch space of attachment processing: a private directory tree in the
  system's temporary directory (`pk_agent_att/`), where a user's file is copied
  to be read and the pages of a scan are rendered.

  Everything here is made for one user's data, so:

    * the root and every directory in it are readable by the server's own user
      only (mode `0700`), and a directory's name is random and never reused
      (`File.mkdir/1` fails if it exists), so one run can never pick up
      what an earlier, killed one left behind;
    * the copy of a file is made *inside* such a directory (the destination is
      ours, not a name Storage invents in `/tmp`), so whatever a killed worker
      leaves is under one directory the supervising process removes;
    * a directory that nothing removed (the node was killed, a turn was stopped
      while it was reading a picture) is swept when its age is past the longest
      time a job may take — at start-up and whenever a new one is made.

  A worker `adopt/1`s the directory its supervisor made; the directories it
  makes itself are then made inside it.
  """

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{FileInstance, Manager}
  alias PhoenixKitAgent.Attachments.Bounds

  @root_name "pk_agent_att"
  @adopted :pk_agent_work_dir
  # Beyond the longest a job may take, in seconds.
  @stale_margin_s 300

  @doc "The directory every scratch directory is made in."
  @spec root() :: Path.t()
  def root, do: Path.join(System.tmp_dir!(), @root_name)

  @doc """
  A new, empty directory with a random name, `0700`: inside the one this
  process `adopt/1`ed, else in the root.
  """
  @spec create() :: {:ok, Path.t()} | {:error, :unavailable}
  def create do
    with {:ok, parent} <- parent() do
      dir = Path.join(parent, Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))

      case File.mkdir(dir) do
        :ok -> private(dir)
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end

  @doc """
  Runs `fun` with a new directory and removes it afterwards; `{:error,
  :unreadable}` where there is none to be had.
  """
  @spec with_dir((Path.t() -> result)) :: result | {:error, :unreadable} when result: term()
  def with_dir(fun) do
    case create() do
      {:ok, dir} ->
        try do
          fun.(dir)
        after
          remove(dir)
        end

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  @doc "Removes `dir` and what is in it."
  @spec remove(Path.t()) :: :ok
  def remove(dir) do
    File.rm_rf(dir)
    :ok
  end

  @doc "Makes `dir` the place this process's own directories are made in."
  @spec adopt(Path.t()) :: :ok
  def adopt(dir) do
    Process.put(@adopted, dir)
    :ok
  end

  @doc """
  Copies the original of the Storage file `file_uuid` to a new file in `dir`
  (readable by this user only) and returns its path.
  """
  @spec fetch(String.t(), Path.t()) :: {:ok, Path.t()} | {:error, :unreadable}
  def fetch(file_uuid, dir) do
    with %Storage.File{} <- Storage.get_file(file_uuid),
         %FileInstance{file_name: key} <- Storage.get_file_instance_by_name(file_uuid, "original"),
         destination = Path.join(dir, "original" <> Manager.temp_extension(key)),
         {:ok, _path} <- Manager.retrieve_file(key, destination_path: destination),
         :ok <- File.chmod(destination, 0o600) do
      {:ok, destination}
    else
      _not_retrievable -> {:error, :unreadable}
    end
  rescue
    _ -> {:error, :unreadable}
  end

  @doc """
  Runs `fun` with the path of a copy of the Storage file `file_uuid`, and
  removes the copy afterwards. `{:error, :unreadable}` when it cannot be read.
  """
  @spec with_file(String.t(), (Path.t() -> result)) :: result | {:error, :unreadable}
        when result: term()
  def with_file(file_uuid, fun) do
    with_dir(fn dir -> fetch_and_run(file_uuid, dir, fun) end)
  end

  defp fetch_and_run(file_uuid, dir, fun) do
    case fetch(file_uuid, dir) do
      {:ok, path} -> fun.(path)
      {:error, :unreadable} = error -> error
    end
  end

  @doc """
  Removes the scratch directories older than the longest a job may take (plus
  a margin). Returns how many were removed.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = System.os_time(:second)
    max_age = div(Bounds.get(:process_deadline_ms), 1000) + @stale_margin_s

    case File.ls(root()) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(root(), &1))
        |> Enum.filter(&stale?(&1, now, max_age))
        |> Enum.count(&(File.rm_rf(&1) |> elem(0) == :ok))

      {:error, _reason} ->
        0
    end
  end

  @doc false
  # The task that sweeps at start-up (`PhoenixKitAgent.children/0`). Its id is
  # its own: PhoenixKit.Supervisor starts the children of every module in one
  # list, and the default id `Task` is taken there already (core's Sitemap).
  def sweep_task,
    do: Supervisor.child_spec(Task.child_spec(fn -> sweep() end), id: __MODULE__.Sweep)

  defp stale?(path, now, max_age) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> now - mtime > max_age
      {:error, _reason} -> false
    end
  end

  defp parent do
    case Process.get(@adopted) do
      dir when is_binary(dir) -> {:ok, dir}
      nil -> ensure_root()
    end
  end

  defp ensure_root do
    root = root()

    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        _ = sweep()
        private(root)

      {:ok, _not_a_directory} ->
        {:error, :unavailable}

      {:error, :enoent} ->
        case File.mkdir(root) do
          result when result in [:ok, {:error, :eexist}] -> private(root)
          {:error, _reason} -> {:error, :unavailable}
        end

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp private(dir) do
    case File.chmod(dir, 0o700) do
      :ok -> {:ok, dir}
      {:error, _reason} -> {:error, :unavailable}
    end
  end
end
