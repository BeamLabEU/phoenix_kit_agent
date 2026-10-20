defmodule PhoenixKitAgent.Attachments.Extract do
  @moduledoc """
  Turns the bytes of an attachment into what the model reads (spec §9): the
  text of a text file, a CSV file or a PDF; CSV text of a workbook; JPEG or
  PNG pictures of an image or of the first pages of a scan.

  Every function takes the path of a file already read from Storage and
  answers `{:ok, result}` or `{:error, code}`; the codes are the ones the
  attachment row keeps in `error` (`unreadable`, `too_large`,
  `pdf_tools_missing`, `image_tools_missing`) and say nothing of the content.
  A file that makes a parser raise is `unreadable`; what the parser said is
  dropped, as it can quote the file.
  """

  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKitAgent.Attachments.{Bounds, Cmd, Jpeg, Unzip, Work}
  alias PhoenixKitAgent.Schemas.Message

  @typedoc "Text for the model, cut to the limit; `truncated` when the file had more."
  @type text :: %{text: String.t(), truncated: boolean()}

  @typedoc "The text of a PDF, with how many pages it has."
  @type pdf_text :: %{text: String.t(), pages: pos_integer(), truncated: boolean()}

  @csv NimbleCSV.RFC4180

  # ── text and CSV ────────────────────────────────────────────────────

  @doc """
  The start of a text file as text (a byte order mark and NUL bytes dropped).
  A byte that is not UTF-8 shows as U+FFFD, it is not silently left out.
  """
  @spec text(Path.t()) :: {:ok, text()} | {:error, :unreadable}
  def text(path) do
    with {:ok, text, cut?} <- read_text(path) do
      {text, clipped?} = clip(text)
      {:ok, %{text: text, truncated: cut? or clipped?}}
    end
  end

  @doc "The first rows of a CSV file, as written in it (any delimiter)."
  @spec csv(Path.t()) :: {:ok, text()} | {:error, :unreadable}
  def csv(path) do
    with {:ok, text, cut?} <- read_text(path) do
      lines =
        text
        |> String.split(~r/\r\n|\n|\r/)
        |> drop_blank_tail()

      rows = Bounds.get(:sheet_rows)
      {kept, rest} = Enum.split(lines, rows)
      {text, clipped?} = kept |> Enum.join("\n") |> clip()
      {:ok, %{text: text, truncated: cut? or rest != [] or clipped?}}
    end
  end

  # At most as many bytes as the longest text could take; the cut is moved
  # back to the start of a character.
  defp read_text(path) do
    max = Bounds.get(:text_chars) * 4 + 4

    with {:ok, size} <- file_size(path),
         {:ok, data} <- File.open(path, [:read, :binary], &IO.binread(&1, max)),
         true <- is_binary(data) do
      cut? = size > byte_size(data)

      text =
        data
        |> whole_characters()
        |> String.replace_invalid("\uFFFD")
        |> Message.strip_nul()
        |> String.replace_prefix("\uFEFF", "")

      {:ok, text, cut?}
    else
      _unreadable -> {:error, :unreadable}
    end
  end

  defp whole_characters(data) do
    Enum.find_value(0..3, data, fn cut ->
      size = byte_size(data) - cut
      if size >= 0 and String.valid?(binary_part(data, 0, size)), do: binary_part(data, 0, size)
    end)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      _ -> :error
    end
  end

  defp drop_blank_tail(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end

  @doc false
  # `text` cut to the text limit, and whether it was cut.
  @spec clip(String.t()) :: {String.t(), boolean()}
  def clip(text) do
    max = Bounds.get(:text_chars)
    if String.length(text) > max, do: {String.slice(text, 0, max), true}, else: {text, false}
  end

  # ── workbooks ───────────────────────────────────────────────────────

  @doc """
  A workbook as CSV: for each sheet (hidden ones left out) a `## Name` line and
  its first rows, blank rows skipped. The parts of the workbook are inflated
  by `PhoenixKitAgent.Attachments.Unzip`, which counts the bytes it produces
  and does not believe the sizes the file declares: one that unpacks to more
  than the limit is `:too_large`, however it was forged, and is not opened.
  """
  @spec xlsx(Path.t()) :: {:ok, text()} | {:error, :unreadable | :too_large}
  def xlsx(path) do
    with {:ok, workbook} <- Unzip.workbook(path, Bounds.get(:sheet_unzipped_bytes)),
         {:ok, package} <- open_workbook(workbook),
         {:ok, sheets} <- read_sheets(package) do
      rows = Bounds.get(:sheet_rows)

      {blocks, cut?} =
        Enum.map_reduce(sheets, false, fn {name, sheet_rows}, cut? ->
          {kept, rest} = Enum.split(sheet_rows, rows)
          {sheet_block(name, kept), cut? or rest != []}
        end)

      {text, clipped?} = blocks |> Enum.join("\n") |> clip()
      all = package |> XlsxReader.sheet_names() |> length()
      {:ok, %{text: text, truncated: cut? or clipped? or all > length(sheets)}}
    else
      {:error, :too_large} -> {:error, :too_large}
      _unreadable -> {:error, :unreadable}
    end
  rescue
    _ -> {:error, :unreadable}
  end

  defp open_workbook(workbook) do
    case XlsxReader.open(workbook, source: :binary, exclude_hidden_sheets?: true) do
      {:ok, package} -> {:ok, package}
      {:error, _message} -> {:error, :unreadable}
    end
  end

  defp read_sheets(package) do
    package
    |> XlsxReader.sheet_names()
    |> Enum.take(Bounds.get(:sheets))
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case XlsxReader.sheet(package, name, skip_row?: &blank_row?/1) do
        {:ok, rows} -> {:cont, {:ok, [{name, rows} | acc]}}
        {:error, _message} -> {:halt, {:error, :unreadable}}
      end
    end)
    |> case do
      {:ok, sheets} -> {:ok, Enum.reverse(sheets)}
      error -> error
    end
  end

  defp blank_row?(row), do: Enum.all?(row, &(cell_text(&1) == ""))

  defp sheet_block(name, rows) do
    csv =
      rows
      |> Enum.map(fn row -> row |> Enum.map(&cell_text/1) |> trim_empty_tail() end)
      |> @csv.dump_to_iodata()
      |> IO.iodata_to_binary()
      |> String.replace("\r\n", "\n")

    "## " <> String.replace(name, ~r/[\r\n]+/, " ") <> "\n" <> csv
  end

  defp trim_empty_tail(cells),
    do: cells |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

  defp cell_text(nil), do: ""
  defp cell_text(text) when is_binary(text), do: Message.strip_nul(text)
  defp cell_text(true), do: "TRUE"
  defp cell_text(false), do: "FALSE"
  defp cell_text(number) when is_integer(number), do: Integer.to_string(number)

  defp cell_text(number) when is_float(number) do
    if number == Float.round(number) and abs(number) < 1.0e15,
      do: number |> trunc() |> Integer.to_string(),
      else: Float.to_string(number)
  end

  defp cell_text(%mod{} = value) when mod in [Date, Time, NaiveDateTime, DateTime],
    do: mod.to_iso8601(value)

  defp cell_text(other), do: other |> inspect() |> Message.strip_nul()

  # ── PDF ─────────────────────────────────────────────────────────────

  @doc """
  The text of a PDF (`pdftotext`) with its page count. `{:ok, {:scan, pages}}`
  when it holds (almost) no text: a scan, to be read as pictures.
  """
  @spec pdf(Path.t()) ::
          {:ok, pdf_text()}
          | {:ok, {:scan, pos_integer()}}
          | {:error, :unreadable | :pdf_tools_missing}
  def pdf(path) do
    with :ok <- pdf_tools(),
         {:ok, pages} <- page_count(path),
         {:ok, text} <- pdf_text(path, min(pages, Bounds.get(:pdf_text_pages))) do
      if meaningful?(text) do
        {text, clipped?} = clip(text)

        {:ok,
         %{text: text, pages: pages, truncated: clipped? or pages > Bounds.get(:pdf_text_pages)}}
      else
        {:ok, {:scan, pages}}
      end
    end
  end

  @doc "The first pages of a PDF as PNG binaries (at most `scan_pages`, 1600 px on the long side) and the page count."
  @spec pdf_pages(Path.t()) ::
          {:ok, [binary()], pos_integer()} | {:error, :unreadable | :pdf_tools_missing}
  def pdf_pages(path) do
    with :ok <- pdf_tools(),
         {:ok, pages} <- page_count(path),
         {:ok, pngs} <- render_pages(path, min(pages, Bounds.get(:scan_pages))) do
      {:ok, pngs, pages}
    end
  end

  defp pdf_tools do
    if Enum.all?(~w(pdfinfo pdftotext pdftoppm), &Cmd.available?/1),
      do: :ok,
      else: {:error, :pdf_tools_missing}
  end

  defp page_count(path) do
    with {:ok, output} <- Cmd.run("pdfinfo", [path]),
         [_, pages] <- Regex.run(~r/^Pages:\s+(\d+)/m, output),
         {pages, ""} when pages > 0 <- Integer.parse(pages) do
      {:ok, pages}
    else
      _ -> {:error, :unreadable}
    end
  end

  defp pdf_text(path, last_page) do
    Work.with_dir(fn dir ->
      out = Path.join(dir, "text.txt")

      with {:ok, _output} <-
             Cmd.run("pdftotext", [
               "-layout",
               "-enc",
               "UTF-8",
               "-l",
               Integer.to_string(last_page),
               path,
               out
             ]),
           {:ok, text} <- File.read(out) do
        {:ok,
         text
         |> String.replace_invalid("")
         |> Message.strip_nul()
         |> String.replace("\f", "\n\n")
         |> String.trim()}
      else
        _ -> {:error, :unreadable}
      end
    end)
  end

  defp meaningful?(text),
    do: String.length(String.replace(text, ~r/\s/u, "")) >= Bounds.get(:min_pdf_text_chars)

  defp render_pages(path, last_page) do
    Work.with_dir(fn dir ->
      args = [
        "-png",
        "-scale-to",
        Integer.to_string(Bounds.image_px()),
        "-f",
        "1",
        "-l",
        Integer.to_string(last_page),
        path,
        Path.join(dir, "page")
      ]

      with {:ok, _output} <- Cmd.run("pdftoppm", args),
           [_ | _] = files <- rendered_pages(dir, last_page) do
        {:ok, Enum.map(files, &File.read!/1)}
      else
        _ -> {:error, :unreadable}
      end
    end)
  end

  # `page-1.png` … (poppler pads the number to the width of the last page's);
  # nothing else in the directory is a page.
  defp rendered_pages(dir, last_page) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      with [_, digits] <- Regex.run(~r/\Apage-(\d+)\.png\z/, name),
           {number, ""} when number in 1..last_page//1 <- Integer.parse(digits) do
        [{number, Path.join(dir, name)}]
      else
        _ -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  # ── pictures ────────────────────────────────────────────────────────

  @doc """
  A picture as a JPEG whose long side is at most 1600 px (never enlarged),
  upright, on white where it was transparent, without its camera metadata
  (EXIF with the place and time of a photo, XMP, IPTC, comments:
  `PhoenixKitAgent.Attachments.Jpeg.strip_metadata/1`) — what goes to a model
  provider is the picture, not where it was taken.
  """
  @spec picture(Path.t()) :: {:ok, binary()} | {:error, :unreadable | :image_tools_missing}
  def picture(path) do
    if Enum.all?(~w(convert identify), &Cmd.available?/1) do
      Work.with_dir(fn dir ->
        out = Path.join(dir, "picture.jpg")

        with {:ok, ^out} <- ImageProcessor.preview_jpeg(path, out, Bounds.image_px()),
             {:ok, jpeg} <- File.read(out),
             {:ok, bare} <- Jpeg.strip_metadata(jpeg) do
          {:ok, bare}
        else
          _ -> {:error, :unreadable}
        end
      end)
    else
      {:error, :image_tools_missing}
    end
  end
end
