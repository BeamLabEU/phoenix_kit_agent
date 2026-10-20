defmodule PhoenixKitAgent.Attachments.Unzip do
  @moduledoc """
  Reads the parts of a workbook out of an uploaded zip without trusting it.

  The sizes in a zip's central directory are written by whoever made the file:
  a forged archive can say a part is a kilobyte and inflate to gigabytes, and
  `:zip.extract/2` believes it. Here no declared size is believed. Each part is
  inflated in chunks while the bytes produced are counted, against one budget
  for the whole archive; the moment it is spent the reading stops with
  `:too_large`, whatever the headers claimed. How many parts are read is
  bounded too, so is the input read for one part (the archive's own size).

  Only the parts a workbook is read from are taken (`[Content_Types].xml` and
  the XML and relationship files under `xl/`); the rest (pictures, charts,
  macros) is never inflated. `workbook/2` gives them back as a new, honest zip
  made here, which is what `XlsxReader` opens.
  """

  @max_parts 2_000
  @chunk 65_536
  @local_header 30

  @typedoc "Why a workbook was not read."
  @type failure :: :too_large | :unreadable

  @doc """
  The workbook parts of the zip at `path`, inflated within `budget` bytes in
  all, as the binary of a new zip.
  """
  @spec workbook(Path.t(), non_neg_integer()) :: {:ok, binary()} | {:error, failure()}
  def workbook(path, budget) do
    with {:ok, parts} <- read(path, budget),
         {:ok, {_name, zip}} <- create(parts) do
      {:ok, zip}
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :unreadable}
    end
  end

  @doc "The parts as `[{name, binary}]`, within `budget` bytes of inflated data."
  @spec read(Path.t(), non_neg_integer()) :: {:ok, [{String.t(), binary()}]} | {:error, failure()}
  def read(path, budget) do
    with {:ok, size} <- file_size(path),
         {:ok, entries} <- entries(path),
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      try do
        take(entries, io, size, budget, [])
      after
        :file.close(io)
      end
    else
      {:error, :too_large} -> {:error, :too_large}
      _ -> {:error, :unreadable}
    end
  end

  # ── the central directory ───────────────────────────────────────────

  defp entries(path) do
    case :zip.list_dir(String.to_charlist(path)) do
      {:ok, listing} ->
        parts =
          for {:zip_file, name, _info, _comment, offset, compressed} <- listing,
              name = to_string(name),
              wanted?(name),
              do: %{name: name, offset: offset, compressed: compressed}

        if length(parts) > @max_parts, do: {:error, :too_large}, else: {:ok, parts}

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  @skipped ~w(xl/media/ xl/drawings/ xl/charts/ xl/theme/ xl/embeddings/ xl/diagrams/ xl/printerSettings/)

  defp wanted?("[Content_Types].xml"), do: true
  defp wanted?("_rels/.rels"), do: true

  defp wanted?("xl/" <> _ = name) do
    (String.ends_with?(name, ".xml") or String.ends_with?(name, ".rels")) and
      not String.starts_with?(name, @skipped)
  end

  defp wanted?(_name), do: false

  # ── the parts ───────────────────────────────────────────────────────

  defp take([], _io, _size, _budget, acc), do: {:ok, Enum.reverse(acc)}

  defp take([part | rest], io, size, budget, acc) do
    case inflate_part(io, size, part, budget) do
      {:ok, data} ->
        take(rest, io, size, budget - byte_size(data), [{part.name, data} | acc])

      {:error, _failure} = error ->
        error
    end
  end

  defp inflate_part(io, size, %{offset: offset, compressed: declared}, budget) do
    with {:ok,
          <<0x50, 0x4B, 0x03, 0x04, _version::16-little, flags::16-little, method::16-little,
            _rest::binary>> = header} <-
           :file.pread(io, offset, @local_header),
         0 <- Bitwise.band(flags, 1),
         <<_::binary-size(26), name_len::16-little, extra_len::16-little>> = header,
         start = offset + @local_header + name_len + extra_len,
         true <- start <= size do
      available = min(declared, size - start)
      method(method, io, start, available, budget)
    else
      _bad_header -> {:error, :unreadable}
    end
  end

  # Stored: as long as it says, and that is the size.
  defp method(0, io, start, available, budget) do
    if available > budget do
      {:error, :too_large}
    else
      case :file.pread(io, start, available) do
        {:ok, data} when byte_size(data) == available -> {:ok, data}
        _short -> {:error, :unreadable}
      end
    end
  end

  defp method(8, io, start, available, budget) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      feed(z, io, start, available, budget, [], 0)
    catch
      _kind, _reason -> {:error, :unreadable}
    after
      :zlib.close(z)
    end
  end

  defp method(_unsupported, _io, _start, _available, _budget), do: {:error, :unreadable}

  # Feeds the input in chunks; after each, drains what it inflates to, counting.
  defp feed(z, io, position, left, budget, acc, produced) when left > 0 do
    wanted = min(@chunk, left)

    case :file.pread(io, position, wanted) do
      {:ok, chunk} ->
        case drain(z, chunk, budget, acc, produced) do
          {:ok, acc, produced} ->
            feed(
              z,
              io,
              position + byte_size(chunk),
              left - byte_size(chunk),
              budget,
              acc,
              produced
            )

          {:error, _failure} = error ->
            error
        end

      _unreadable ->
        {:error, :unreadable}
    end
  end

  defp feed(z, _io, _position, _left, _budget, acc, _produced) do
    case :zlib.inflateEnd(z) do
      :ok -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      _stream_not_complete -> {:error, :unreadable}
    end
  end

  defp drain(z, input, budget, acc, produced) do
    case :zlib.safeInflate(z, input) do
      {:continue, out} -> account(z, out, true, budget, acc, produced)
      {:finished, out} -> account(z, out, false, budget, acc, produced)
    end
  end

  defp account(z, out, more?, budget, acc, produced) do
    produced = produced + IO.iodata_length(out)

    cond do
      produced > budget -> {:error, :too_large}
      more? -> drain(z, [], budget, [out | acc], produced)
      true -> {:ok, [out | acc], produced}
    end
  end

  # ── the new zip ─────────────────────────────────────────────────────

  defp create(parts) do
    files = Enum.map(parts, fn {name, data} -> {String.to_charlist(name), data} end)
    :zip.create(~c"workbook.xlsx", files, [:memory])
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      _ -> {:error, :unreadable}
    end
  end
end
