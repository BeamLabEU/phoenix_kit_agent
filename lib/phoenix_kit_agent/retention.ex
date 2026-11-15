defmodule PhoenixKitAgent.Retention do
  @moduledoc """
  The optional time limit on chats (`agent_retention_days`, see
  `PhoenixKitAgent.Config.retention_days/0`).

  **Unset is the default and deletes nothing**: every chat stays, a deleted
  one included (a deleted chat is only hidden, `Conversations.delete_conversation/3`),
  exactly as before this setting existed. Nothing here runs against a site
  that did not set it.

  When it is set to N days, `run/1` (the nightly `PhoenixKitAgent.RetentionWorker`)
  deletes **for good**:

    * every chat whose last message is older than N days — its last
      activity is `last_message_at`, or the day it was made while it has no
      message — whatever its status (an archived chat included);
    * every chat the user **deleted**, at the next run and whatever its age:
      the module has no way back for a deleted chat, so a site that asked for
      retention gets the chat gone at the first run after the user's
      "Delete", not N days later.

  A chat whose turn holds its lock right now (a turn in flight, or a click
  that confirms a write; `PhoenixKitAgent.Turns.lock_ttl_s/0`) is left for the
  next run, and so is a row a transaction of the module holds.

  With a chat go, in the one transaction, its messages and its attachment rows
  (the database's `ON DELETE CASCADE`); afterwards the Storage files of its
  attachments are deleted completely from the hidden library
  (`PhoenixKitAgent.UserDeletion.release_files/1`) — only a file that lies in
  the module's library and that nothing else refers to; a file something else
  uses is left alone.

  **A release that did not happen is made good, not forgotten.** The rows are
  gone once the transaction commits, so a file whose release failed (the job
  or the node stopped between the commit and the release, or Storage or the
  database refused the delete) is no longer found through them. Each run
  therefore ends with a sweep (`PhoenixKitAgent.UserDeletion.release_orphans/1`):
  every file of the hidden library that no attachment row refers to and that is
  older than a day (a file a request is storing now is never met) is released
  the same way. A failure is logged as its class, and the file is met again the
  next night.

  **What the sweep cannot recover: bytes an S3 outage left in the bucket.**
  Storage (`PhoenixKit.Modules.Storage.delete_file_completely/1`) deletes the
  file's row first and the bucket objects after it; if the bucket refuses, it
  only logs a warning and still answers `{:ok, _}`. The row is then gone, so
  neither this module's release nor the sweep can know that bytes remain, and
  they are counted as deleted. Only Storage can fix that (keep the keys it
  failed to delete and retry them); until it does, a stretch of S3 errors during
  a run leaves the bytes of the files released in it, and the only trace is
  Storage's own log warning.

  What this does not touch: the AI request journal (`phoenix_kit_ai`), which
  has its own retention and, with `agent_capture_ai_content` on, keeps the
  text of requests; the spending the journal counts; the user's settings, their
  personal instructions and the notices of limits.

  The period is read from the database each run (`Config.retention_days_direct/0`),
  not from the cache. Work is done in batches within a time budget; what is
  left waits for the next night. The run is recorded in the Activity log as
  `agent.retention_purged` — counts (chats, messages, attachment rows, Storage
  files deleted, files the sweep deleted) and the period, never a title, a
  text or a file name — when it deleted something. It runs whether or not the
  module is switched on: data kept for a module that is off is still data.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.{Config, Migrations, Turns, UserDeletion}
  alias PhoenixKitAgent.Schemas.{Attachment, Conversation, Message}

  @batch 100
  @budget_ms :timer.minutes(5)
  @sweep_budget_ms :timer.minutes(2)

  @typedoc "What a run deleted."
  @type summary :: %{
          days: pos_integer(),
          conversations: non_neg_integer(),
          messages: non_neg_integer(),
          attachments: non_neg_integer(),
          files: non_neg_integer(),
          orphan_files: non_neg_integer()
        }

  @doc """
  Applies the retention now. Options: `now:` (a `DateTime`), `batch:` (chats
  per transaction), `budget_ms:` (stop starting batches after this long),
  `sweep_budget_ms:` (the same for the sweep of files left behind), `grace_s:`
  (how old a file nothing refers to must be for the sweep).

  `{:skipped, :off}` when no period is set (nothing is read or deleted),
  `{:skipped, :not_installed}` when the module's tables are not in the
  database, else `{:ok, summary}`.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:skipped, :off | :not_installed}
  def run(opts \\ []) do
    case Config.retention_days_direct() do
      nil ->
        {:skipped, :off}

      days ->
        if tables_installed?(), do: {:ok, purge(days, opts)}, else: {:skipped, :not_installed}
    end
  end

  @doc """
  How many chats a period of `days` would delete at the next run, as of `now`:
  the Settings page tells it before and after a person saves a period.
  """
  @spec due_count(pos_integer(), DateTime.t()) :: non_neg_integer()
  def due_count(days, now \\ DateTime.utc_now()) when is_integer(days) and days > 0 do
    now |> due_query(days) |> repo().aggregate(:count)
  end

  defp purge(days, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    batch = Keyword.get(opts, :batch, @batch)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @budget_ms)

    summary =
      loop(now, days, batch, deadline, %{
        days: days,
        conversations: 0,
        messages: 0,
        attachments: 0,
        files: 0,
        orphan_files: 0
      })

    summary = sweep(summary, now, opts)
    if summary.conversations > 0 or summary.orphan_files > 0, do: log_run(summary)
    summary
  end

  # After the chats: the files an earlier release left behind.
  defp sweep(summary, now, opts) do
    budget = Keyword.get(opts, :sweep_budget_ms, @sweep_budget_ms)

    sweep_opts =
      [now: now, deadline: System.monotonic_time(:millisecond) + budget] ++
        Keyword.take(opts, [:grace_s, :batch])

    %{summary | orphan_files: UserDeletion.release_orphans(sweep_opts)}
  end

  defp loop(now, days, batch, deadline, acc) do
    if System.monotonic_time(:millisecond) >= deadline do
      acc
    else
      case purge_batch(now, days, batch) do
        {0, _messages, _attachments, _files} ->
          acc

        {chats, messages, attachments, files} ->
          deleted_files = UserDeletion.release_files(files, deadline: deadline)

          acc = %{
            acc
            | conversations: acc.conversations + chats,
              messages: acc.messages + messages,
              attachments: acc.attachments + attachments,
              files: acc.files + deleted_files
          }

          loop(now, days, batch, deadline, acc)
      end
    end
  end

  # One transaction: the chats it picked (rows another transaction holds are
  # skipped, not waited for), the counts, the files they point at, and the
  # delete, which takes the messages and attachment rows with it.
  defp purge_batch(now, days, batch) do
    {:ok, result} =
      repo().transaction(fn ->
        uuids =
          from(c in due_query(now, days), select: c.uuid, order_by: c.uuid, limit: ^batch)
          |> lock_skipping()
          |> repo().all()

        case uuids do
          [] ->
            {0, 0, 0, []}

          uuids ->
            messages = count(Message, uuids)
            file_uuids = attachment_files(uuids)
            attachments = count(Attachment, uuids)
            {deleted, _} = repo().delete_all(from(c in Conversation, where: c.uuid in ^uuids))
            {deleted, messages, attachments, file_uuids}
        end
      end)

    result
  end

  defp lock_skipping(query), do: from(c in query, lock: "FOR UPDATE SKIP LOCKED")

  defp count(schema, conversation_uuids) do
    repo().aggregate(
      from(r in schema, where: r.conversation_uuid in ^conversation_uuids),
      :count
    )
  end

  defp attachment_files(conversation_uuids) do
    repo().all(
      from(a in Attachment,
        where: a.conversation_uuid in ^conversation_uuids and not is_nil(a.file_uuid),
        distinct: true,
        select: a.file_uuid
      )
    )
  end

  defp due_query(now, days) do
    cutoff = DateTime.add(now, -days * 86_400, :second)
    stale = DateTime.add(now, -Turns.lock_ttl_s(), :second)

    from(c in Conversation,
      where:
        (is_nil(c.busy_since) or c.busy_since < ^stale) and
          (c.status == "deleted" or
             fragment("coalesce(?, ?)", c.last_message_at, c.inserted_at) < ^cutoff)
    )
  end

  defp log_run(summary) do
    Activity.log("agent", "agent.retention_purged",
      mode: "cron",
      resource_type: "agent_retention",
      permanent: true,
      metadata: %{
        "days" => summary.days,
        "conversations" => summary.conversations,
        "messages" => summary.messages,
        "attachments" => summary.attachments,
        "files" => summary.files,
        "orphan_files" => summary.orphan_files
      }
    )

    :ok
  end

  # The marker is read in the schema the module's tables live in, as the
  # user-deletion cleanup does.
  defp tables_installed? do
    prefix = Conversation.__schema__(:prefix) || "public"
    Migrations.migrated_version_runtime(prefix: prefix) > 0
  end

  defp repo, do: RepoHelper.repo()
end
