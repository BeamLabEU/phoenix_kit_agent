defmodule PhoenixKitAgent.Test.Files do
  @moduledoc """
  Files and storage for the attachment tests: real bytes of the supported
  kinds built in memory (a PNG, text and scanned PDFs, an xlsx), and a local
  storage bucket in a temporary directory, so a file is really stored and read
  back.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKitAgent.Test.Repo

  @buckets_cache :phoenix_kit_buckets_cache

  @doc """
  Makes a local bucket the only one that takes uploads and runs Oban in manual
  mode (Storage queues variant jobs). Undone when the test ends.
  """
  def local_bucket! do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_agent_files_#{n}")
    Repo.update_all(Bucket, set: [enabled: false])

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "agent-files-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual, queues: [], plugins: []})

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    bucket
  end

  @doc "Writes `binary` to a new temporary file called `name` and returns its path."
  def tmp!(binary, name) do
    dir = Path.join(System.tmp_dir!(), "pk_agent_upload_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, binary)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  @doc """
  The upload map `PhoenixKitAgent.Attachments.add/4` takes, for `binary` sent as
  `name`; the file on disk is called by a neutral name, as a LiveView upload is.
  """
  def upload!(binary, name, content_type \\ nil) do
    # The temporary file of a LiveView upload has a name of its own, not the user's.
    %{path: tmp!(binary, "live_view_upload"), filename: name, content_type: content_type}
  end

  @doc "Whether the executable is installed (tests that need one are tagged)."
  def tool?(name), do: System.find_executable(name) != nil

  # ── bytes ───────────────────────────────────────────────────────────

  @doc "A grey PNG of the given size (a few kilobytes, whatever the size)."
  def png(width, height) do
    row = <<0, :binary.copy(<<128>>, width)::binary>>
    raw = :binary.copy(row, height)

    signature = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
    ihdr = <<width::32, height::32, 8, 0, 0, 0, 0>>

    signature <>
      chunk("IHDR", ihdr) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end

  @doc """
  A JPEG of the given size made by ImageMagick (the tests that use it are tagged
  `:imagemagick`).
  """
  def jpeg(width, height) do
    dir = Path.join(System.tmp_dir!(), "pk_agent_jpeg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    out = Path.join(dir, "out.jpg")

    {_, 0} =
      System.cmd("convert", ["-size", "#{width}x#{height}", "xc:#4080c0", "jpeg:" <> out],
        stderr_to_stdout: true
      )

    binary = File.read!(out)
    File.rm_rf!(dir)
    binary
  end

  @doc """
  `jpeg` with an EXIF segment (the camera's make is `make`) and a comment
  segment, as a camera and an editor would leave them, right after the start of
  the image.
  """
  def with_metadata(<<0xFF, 0xD8, rest::binary>>, make, comment) do
    value = make <> <<0>>

    tiff =
      <<"II", 42::16-little, 8::32-little, 1::16-little>> <>
        <<0x010F::16-little, 2::16-little, byte_size(value)::32-little, 26::32-little>> <>
        <<0::32-little>> <> value

    exif = "Exif" <> <<0, 0>> <> tiff
    comment_segment = <<0xFF, 0xFE, byte_size(comment) + 2::16>> <> comment

    <<0xFF, 0xD8>> <>
      <<0xFF, 0xE1, byte_size(exif) + 2::16>> <> exif <> comment_segment <> rest
  end

  @doc "A PDF with one page per string, each holding that text."
  def text_pdf(pages) when is_list(pages) do
    pdf(Enum.map(pages, &"BT /F1 14 Tf 20 100 Td (#{pdf_escape(&1)}) Tj ET"))
  end

  @doc "A PDF of `count` pages that hold a drawing and no text, as a scan has none to read."
  def scan_pdf(count \\ 1) do
    pdf(List.duplicate("0.2 0.4 0.8 rg 20 20 200 100 re f", count))
  end

  defp pdf(contents) do
    page_numbers = Enum.map(1..length(contents)//1, &(4 + (&1 - 1) * 2))

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{Enum.map_join(page_numbers, " ", &"#{&1} 0 R")}] /Count #{length(contents)} >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
      ] ++
        Enum.flat_map(Enum.with_index(contents), fn {content, i} ->
          [
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents #{5 + i * 2} 0 R " <>
              "/Resources << /Font << /F1 3 0 R >> >> >>",
            "<< /Length #{byte_size(content)} >>\nstream\n#{content}\nendstream"
          ]
        end)

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, number}, {acc, offsets} ->
        {acc <> "#{number} 0 obj\n#{object}\nendobj\n", [byte_size(acc) | offsets]}
      end)

    xref_at = byte_size(body)

    xref =
      offsets
      |> Enum.reverse()
      |> Enum.map_join(&"#{String.pad_leading(Integer.to_string(&1), 10, "0")} 00000 n \n")

    body <>
      "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n#{xref}" <>
      "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
  end

  defp pdf_escape(text), do: String.replace(text, ["\\", "(", ")"], &"\\#{&1}")

  @doc """
  An xlsx of `sheets`, `[{name, rows}]`, a row being a list of strings and
  numbers.
  """
  def xlsx(sheets) do
    numbered = Enum.with_index(sheets, 1)

    files =
      [
        {"[Content_Types].xml",
         ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
           ~s(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">) <>
           ~s(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) <>
           ~s(<Default Extension="xml" ContentType="application/xml"/>) <>
           ~s(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>) <>
           Enum.map_join(numbered, fn {_sheet, n} ->
             ~s(<Override PartName="/xl/worksheets/sheet#{n}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
           end) <> "</Types>"},
        {"_rels/.rels",
         ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
           ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
           ~s(<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>) <>
           "</Relationships>"},
        {"xl/workbook.xml",
         ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
           ~s(<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>) <>
           Enum.map_join(numbered, fn {{name, _rows}, n} ->
             ~s(<sheet name="#{xml(name)}" sheetId="#{n}" r:id="rId#{n}"/>)
           end) <> "</sheets></workbook>"},
        {"xl/_rels/workbook.xml.rels",
         ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
           ~s(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) <>
           Enum.map_join(numbered, fn {_sheet, n} ->
             ~s(<Relationship Id="rId#{n}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{n}.xml"/>)
           end) <> "</Relationships>"}
      ] ++
        Enum.map(numbered, fn {{_name, rows}, n} ->
          {"xl/worksheets/sheet#{n}.xml", sheet(rows)}
        end)

    zip(files)
  end

  @doc """
  `zip` with the uncompressed size of every entry in its central directory
  replaced by `size`: what a zip made to get past a check on declared sizes
  looks like.
  """
  def forge_sizes(zip, size) do
    zip
    |> :binary.matches(<<0x50, 0x4B, 0x01, 0x02>>)
    |> Enum.reduce(zip, fn {at, _length}, acc ->
      <<before::binary-size(at + 24), _declared::32, rest::binary>> = acc
      before <> <<size::32-little>> <> rest
    end)
  end

  @doc "A zip of `[{path, binary}]`."
  def zip(files) do
    entries = Enum.map(files, fn {name, data} -> {String.to_charlist(name), data} end)
    {:ok, {_name, binary}} = :zip.create(~c"archive.zip", entries, [:memory])
    binary
  end

  defp sheet(rows) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>) <>
      (rows
       |> Enum.with_index(1)
       |> Enum.map_join(fn {cells, r} ->
         ~s(<row r="#{r}">) <>
           (cells
            |> Enum.with_index()
            |> Enum.map_join(fn {cell, c} -> cell(cell, <<?A + c>> <> "#{r}") end)) <> "</row>"
       end)) <> "</sheetData></worksheet>"
  end

  defp cell(value, ref) when is_binary(value),
    do: ~s(<c r="#{ref}" t="inlineStr"><is><t>#{xml(value)}</t></is></c>)

  defp cell(value, ref) when is_number(value), do: ~s(<c r="#{ref}"><v>#{value}</v></c>)

  defp xml(text), do: text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
end
