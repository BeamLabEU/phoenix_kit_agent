defmodule PhoenixKitAgent.Attachments.Processor do
  @moduledoc """
  The work done on an attachment before the turn that sends it (spec §9), in a
  task under `PhoenixKitAgent.Attachments.TaskSupervisor`: the row goes from
  `pending` to `ready` with what the model will read, or to `failed` with a
  code in `error`; the chat's topic then hears `{:agent_attachment_processed,
  conversation_uuid, attachment_uuid}`.

    * `text` and `sheet` — the text, or the CSV, cut to the limits of
      `PhoenixKitAgent.Attachments.Bounds`; `truncated` says it was cut;
    * `pdf` — its text (`pdftotext`); a PDF with no text is a scan and is read
      like a picture, from its first pages;
    * `image` — checked to be a picture ImageMagick can read.

  A picture (or a scan) is shown to the model in one of two ways, decided here
  by the user's model as it is now (`PhoenixKitAgent.Models.image_input/1`):

    * the model takes images (or is not known not to, and no vision model is
      set): the row stays without text — the turn sends the pixels, in its own
      message only (`PhoenixKitAgent.Attachments.pictures/1`);
    * it does not: the vision model of the module (`agent_vision_endpoint_uuid`)
      describes it once, now, and the description is the row's text, which the
      history keeps. With no vision model the picture `failed` as
      `no_vision_model`. The vision call is paid, so it is made only for a user
      still within their limits (`limit_reached` otherwise); it carries the
      user and `source: "agent"` — the spending limits count it — and the
      content of the call is never written to the AI journal.

  ## Failing safely

  A task never lives for ever (`process_deadline_ms`, then `timeout`), is kept
  to a heap size (`crashed`), and turns every exception into a code; the codes
  are `unreadable`, `too_large`, `pdf_tools_missing`, `image_tools_missing`,
  `no_vision_model`, `limit_reached`, `budget_exceeded`, `model_error`,
  `timeout`, `crashed`, `unavailable`. The file's content, what a parser said
  about it and what the model answered never reach the log — not as a message,
  nor in a crash report.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.Attachments.{Bounds, Extract}
  alias PhoenixKitAgent.{Config, Conversations, Models, UserConfig}
  alias PhoenixKitAgent.Limits, as: SpendLimits
  alias PhoenixKitAgent.Schemas.{Attachment, Message}

  @task_supervisor PhoenixKitAgent.Attachments.TaskSupervisor

  # In words (8 bytes each): 256 MB for the heap of one worker.
  @max_heap_words 32_000_000

  @describe_picture "Describe this picture for someone who cannot see it. Transcribe every " <>
                      "piece of text, number and table in it exactly, then say what else it shows."

  @describe_scan "These are the first pages of a scanned document. Transcribe all of its " <>
                   "text, numbers and tables exactly, page by page, then say what else the pages show."

  @typedoc "What the task found: the fields of the row to store."
  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Starts the processing of the pending attachment `uuid` and returns at once."
  @spec start(String.t()) :: :ok
  def start(uuid) do
    case Task.Supervisor.start_child(@task_supervisor, fn -> supervise(uuid) end) do
      {:ok, _pid} -> :ok
      _not_started -> finish(uuid, {:error, :unavailable})
    end
  catch
    :exit, _supervisor_gone -> finish(uuid, {:error, :unavailable})
  end

  defp supervise(uuid) do
    worker = Task.Supervisor.async_nolink(@task_supervisor, fn -> work(uuid) end)

    outcome =
      case Task.yield(worker, Bounds.get(:process_deadline_ms)) ||
             Task.shutdown(worker, :brutal_kill) do
        {:ok, result} -> result
        # The reason of a kill can hold the heap; it is not looked at.
        {:exit, _reason} -> {:error, :crashed}
        nil -> {:error, :timeout}
      end

    finish(uuid, outcome)
  end

  # ── the worker ──────────────────────────────────────────────────────

  defp work(uuid) do
    Process.flag(:max_heap_size, %{size: @max_heap_words, kill: true, error_logger: false})

    with %Attachment{status: "pending", file_uuid: file_uuid} = attachment
         when is_binary(file_uuid) <-
           RepoHelper.repo().get(Attachment, uuid),
         {:ok, path, _file} <- Storage.retrieve_file(file_uuid) do
      try do
        process(attachment, path)
      after
        File.rm(path)
      end
    else
      _gone_or_not_stored -> {:error, :unreadable}
    end
  rescue
    _exception -> {:error, :crashed}
  catch
    _kind, _reason -> {:error, :crashed}
  end

  defp process(%{kind: "text"}, path), do: path |> Extract.text() |> fields()

  defp process(%{kind: "sheet", content_type: "text/csv"}, path),
    do: path |> Extract.csv() |> fields()

  defp process(%{kind: "sheet"}, path), do: path |> Extract.xlsx() |> fields()

  defp process(%{kind: "pdf"} = attachment, path) do
    case Extract.pdf(path) do
      {:ok, {:scan, pages}} -> scan(attachment, path, pages)
      other -> fields(other)
    end
  end

  defp process(%{kind: "image"} = attachment, path) do
    with {:ok, jpeg} <- Extract.picture(path),
         settings = UserConfig.effective(attachment.user_uuid),
         {:ok, mode} <- picture_mode(settings) do
      case mode do
        :pixels ->
          {:ok, %{extracted_text: nil, truncated: false}}

        {:describe, vision} ->
          describe(settings, vision, [jpeg_input(jpeg)], @describe_picture, %{})
      end
    end
  end

  defp scan(attachment, path, pages) do
    settings = UserConfig.effective(attachment.user_uuid)

    with {:ok, mode} <- picture_mode(settings),
         {:ok, pngs, ^pages} <- Extract.pdf_pages(path) do
      shown = %{pages: pages, truncated: pages > length(pngs)}

      case mode do
        :pixels ->
          {:ok, Map.put(shown, :extracted_text, nil)}

        {:describe, vision} ->
          inputs = Enum.map(pngs, &%{data: &1, content_type: "image/png"})
          describe(settings, vision, inputs, @describe_scan, shown)
      end
    end
  end

  defp fields({:ok, fields}) when is_map(fields), do: {:ok, rename(fields)}
  defp fields({:error, _code} = error), do: error

  defp rename(%{text: text} = fields),
    do: fields |> Map.delete(:text) |> Map.put(:extracted_text, text)

  defp jpeg_input(jpeg), do: %{data: jpeg, content_type: "image/jpeg"}

  # ── how a picture reaches the model ─────────────────────────────────

  defp picture_mode(settings) do
    vision = Config.vision_endpoint_uuid()

    case {Models.image_input(settings.endpoint_uuid), vision} do
      {:supported, _vision} -> {:ok, :pixels}
      {:unsupported, nil} -> {:error, :no_vision_model}
      {:unknown, nil} -> {:ok, :pixels}
      {_not_supported, vision} -> {:ok, {:describe, vision}}
    end
  end

  defp describe(settings, vision, inputs, prompt, fields) do
    with :ok <- within_limits(settings),
         {:ok, text} <- ask_vision(settings, vision, inputs, prompt) do
      {text, clipped?} = Extract.clip(text)
      truncated = Map.get(fields, :truncated, false) or clipped?
      {:ok, Map.merge(fields, %{extracted_text: text, truncated: truncated})}
    end
  end

  defp within_limits(settings) do
    case SpendLimits.check(settings, settings.endpoint_uuid) do
      :ok -> :ok
      {:error, {:limit_reached, _status}} -> {:error, :limit_reached}
    end
  end

  defp ask_vision(settings, vision, inputs, prompt) do
    result =
      PhoenixKitAI.describe_image(vision, inputs,
        prompt: prompt,
        user_uuid: settings.user_uuid,
        source: "agent",
        capture_request_content: false
      )

    case result do
      {:ok, %{text: text}} when is_binary(text) ->
        if String.trim(text) == "",
          do: {:error, :model_error},
          else: {:ok, text |> Message.strip_nul() |> String.trim()}

      {:error, {:budget_exceeded, _scope}} ->
        {:error, :budget_exceeded}

      _failed ->
        {:error, :model_error}
    end
  end

  # ── the end ─────────────────────────────────────────────────────────

  # Writes the outcome of `uuid` if it is still pending (a discarded row, or one
  # that is settled already, is left alone) and tells the chat.
  defp finish(uuid, outcome) do
    changes =
      case outcome do
        {:ok, fields} ->
          [status: "ready", error: nil, pages: nil, extracted_text: nil, truncated: false]
          |> Keyword.merge(Map.to_list(Map.take(fields, [:extracted_text, :pages, :truncated])))

        {:error, code} ->
          [status: "failed", error: Atom.to_string(code)]
      end

    update(uuid, changes)
  rescue
    exception ->
      Logger.warning(
        "[PhoenixKitAgent] an attachment could not be settled: #{inspect(exception.__struct__)}"
      )

      fail_quietly(uuid)
  end

  defp update(uuid, changes) do
    {count, conversations} =
      from(a in Attachment,
        where: a.uuid == ^uuid and a.status == "pending",
        select: a.conversation_uuid
      )
      |> RepoHelper.repo().update_all([set: changes], log: false)

    for conversation_uuid <- conversations, count == 1 do
      PubSub.broadcast(
        Conversations.topic(conversation_uuid),
        {:agent_attachment_processed, conversation_uuid, uuid}
      )
    end

    :ok
  end

  defp fail_quietly(uuid) do
    update(uuid, status: "failed", error: "crashed")
  rescue
    _ -> :ok
  end
end
