defmodule PhoenixKitAgent.Attachments.Bounds do
  @moduledoc """
  The technical bounds of attachment processing (spec §9): how much of a file
  the model is given and how long the work may take. They are not settings of
  the module; a host or a test may override them with `config :phoenix_kit_agent,
  attachment_limits: [text_chars: …]`.

  | Key | Default | Meaning |
  |---|---|---|
  | `text_chars` | `16_000` | characters of one attachment's text (a PDF, a text file, a sheet, a description); in a message the attachments share `agent_history_chars` between them, so each gets at most that divided by their number |
  | `sheet_rows` | `200` | rows of each sheet or of a CSV file |
  | `sheets` | `10` | sheets of one workbook |
  | `sheet_unzipped_bytes` | `100_000_000` | what a workbook may unpack to |
  | `pdf_text_pages` | `50` | pages whose text is read |
  | `scan_pages` | `3` | pages of a scan that become pictures |
  | `min_pdf_text_chars` | `20` | below this a PDF has no text, it is a scan |
  | `process_deadline_ms` | `120_000` | the whole processing of one attachment |
  | `tool_timeout_s` | `60` | one run of `pdftotext`, `pdftoppm` or ImageMagick |
  | `worker_heap_words` | `32_000_000` | the heap of one worker, in words of 8 bytes (256 MB); over it the worker is killed and the file is `too_large` |
  | `concurrent_jobs` | `8` | files processed at the same time on the node; more are `unavailable` |
  | `unsent_files` | `20` | files of one user that wait for a message (any status, a failed one included) |

  A picture is shrunk to `image_px/0` (1600) on its long side.
  """

  @defaults [
    text_chars: 16_000,
    sheet_rows: 200,
    sheets: 10,
    sheet_unzipped_bytes: 100_000_000,
    pdf_text_pages: 50,
    scan_pages: 3,
    min_pdf_text_chars: 20,
    process_deadline_ms: 120_000,
    tool_timeout_s: 60,
    worker_heap_words: 32_000_000,
    concurrent_jobs: 8,
    unsent_files: 20
  ]

  @image_px 1600

  @doc "The value of `key` (see the moduledoc)."
  @spec get(atom()) :: non_neg_integer()
  def get(key) when is_atom(key) do
    overrides = Application.get_env(:phoenix_kit_agent, :attachment_limits, [])

    case Keyword.get(overrides, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> Keyword.fetch!(@defaults, key)
    end
  end

  @doc "The longest side a picture sent to a model may have, in pixels."
  @spec image_px() :: pos_integer()
  def image_px, do: @image_px
end
