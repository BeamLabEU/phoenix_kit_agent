defmodule PhoenixKitAgent.Attachments.Detect do
  @moduledoc """
  What an uploaded file is, told by its content (spec §9: png/jpg/webp/heic,
  pdf, xlsx/csv, txt/md).

  The first bytes decide for everything that has a signature — a picture, a
  PDF, a workbook (a zip with `xl/workbook.xml`); the name and the type the
  browser claimed are never believed against them. Only a file without any
  signature may be text, and then it must really be text (no NUL byte, valid
  UTF-8 at the start) and its extension picks `.csv`, `.txt` or `.md`. A
  file whose bytes are another known format (a GIF, an SVG, a Word document,
  an executable) or a binary named `.txt` is `{:error, :unsupported_type}`.

  A file named like a text file that is text in another encoding — what Excel
  writes as "CSV" or "Unicode text" in many locales (Windows-1251, Windows-1252,
  UTF-16) — is `{:error, :unsupported_encoding}`, so that the user is told to
  save it as UTF-8 and not that the file is of a kind that is not accepted.
  """

  alias PhoenixKit.Modules.Storage.Sniff

  @xlsx_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @images %{
    png: {"image/png", "png"},
    jpeg: {"image/jpeg", "jpg"},
    webp: {"image/webp", "webp"},
    heic: {"image/heic", "heic"}
  }

  @text_extensions %{
    ".csv" => {"sheet", "text/csv", "csv"},
    ".txt" => {"text", "text/plain", "txt"},
    ".md" => {"text", "text/markdown", "md"},
    ".markdown" => {"text", "text/markdown", "md"}
  }

  @head_bytes 8192

  @typedoc "The kind of an attachment (`Attachment.kinds/0`), its type and the extension to store it by."
  @type detected :: %{kind: String.t(), content_type: String.t(), ext: String.t()}

  @doc "Tells the kind of the file at `path`, called `filename` by the uploader."
  @spec detect(Path.t(), String.t()) ::
          {:ok, detected()} | {:error, :unsupported_type | :unsupported_encoding}
  def detect(path, filename) do
    case Sniff.sniff(path) do
      {:ok, %{format: format}} -> by_format(format, path)
      :unknown -> by_text(path, filename)
    end
  end

  defp by_format(format, _path) when is_map_key(@images, format) do
    {type, ext} = Map.fetch!(@images, format)
    {:ok, %{kind: "image", content_type: type, ext: ext}}
  end

  defp by_format(:pdf, _path),
    do: {:ok, %{kind: "pdf", content_type: "application/pdf", ext: "pdf"}}

  defp by_format(:zip, path) do
    if workbook?(path),
      do: {:ok, %{kind: "sheet", content_type: @xlsx_type, ext: "xlsx"}},
      else: {:error, :unsupported_type}
  end

  defp by_format(_other_format, _path), do: {:error, :unsupported_type}

  defp workbook?(path) do
    case :zip.list_dir(String.to_charlist(path)) do
      {:ok, entries} ->
        names =
          for {:zip_file, name, _info, _comment, _offset, _size} <- entries, do: to_string(name)

        "xl/workbook.xml" in names and "[Content_Types].xml" in names

      {:error, _reason} ->
        false
    end
  end

  defp by_text(path, filename) do
    extension = filename |> Path.extname() |> String.downcase()

    with {:ok, {kind, type, ext}} <- Map.fetch(@text_extensions, extension),
         :text <- text_head(path) do
      {:ok, %{kind: kind, content_type: type, ext: ext}}
    else
      :other_encoding -> {:error, :unsupported_encoding}
      _not_text -> {:error, :unsupported_type}
    end
  end

  # Text: no NUL byte and valid UTF-8 (a multi-byte character may be cut by the
  # end of the head). A UTF-16 or UTF-32 byte order mark, or bytes that are not
  # UTF-8 and no binary (an 8-bit code page), is text in another encoding.
  defp text_head(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @head_bytes)) do
      {:ok, <<bom::binary-size(2), _::binary>>} when bom in [<<0xFF, 0xFE>>, <<0xFE, 0xFF>>] ->
        :other_encoding

      {:ok, head} when is_binary(head) ->
        cond do
          String.contains?(head, <<0>>) -> :binary
          valid_utf8?(head) -> :text
          true -> :other_encoding
        end

      _unreadable_or_empty ->
        :binary
    end
  end

  defp valid_utf8?(head) do
    Enum.any?(0..3, fn cut ->
      size = byte_size(head) - cut
      size >= 0 and String.valid?(binary_part(head, 0, size))
    end)
  end
end
