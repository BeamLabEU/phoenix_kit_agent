defmodule PhoenixKitAgent.Attachments.Jpeg do
  @moduledoc """
  Takes the metadata out of a JPEG, without decoding or re-encoding it.

  A photo carries the make and time of the camera and, often, the place it was
  taken (EXIF, in an `APP1` segment), also XMP, IPTC (`APP13`) and comments. A
  picture on its way to a model provider is the picture alone. The segments
  before the image data are walked and those are dropped; `APP0` (JFIF), `APP14`
  (Adobe: how the colours are stored), the tables and the frame stay, and the
  image data is copied as it is, so the pixels do not change.
  """

  @sos 0xDA
  @eoi 0xD9

  @doc """
  `bytes` without EXIF, XMP, IPTC, the ICC profile and comments. `{:error,
  :unreadable}` when they do not start like a JPEG or the segments before the
  image do not add up.
  """
  @spec strip_metadata(binary()) :: {:ok, binary()} | {:error, :unreadable}
  def strip_metadata(<<0xFF, 0xD8, rest::binary>>) do
    with {:ok, kept} <- segments(rest, []),
         do: {:ok, IO.iodata_to_binary([<<0xFF, 0xD8>> | kept])}
  end

  def strip_metadata(_not_a_jpeg), do: {:error, :unreadable}

  # Fill bytes (`FF FF`) between segments are legal.
  defp segments(<<0xFF, 0xFF, rest::binary>>, acc), do: segments(<<0xFF, rest::binary>>, acc)

  # From the scan on it is image data to the end.
  defp segments(<<0xFF, @sos, _::binary>> = rest, acc), do: {:ok, Enum.reverse([rest | acc])}
  defp segments(<<0xFF, @eoi, _::binary>> = rest, acc), do: {:ok, Enum.reverse([rest | acc])}

  defp segments(<<0xFF, marker, length::16, _::binary>> = data, acc) when length >= 2 do
    size = length + 2

    case data do
      <<segment::binary-size(size), rest::binary>> ->
        segments(rest, if(drop?(marker), do: acc, else: [segment | acc]))

      _short ->
        {:error, :unreadable}
    end
  end

  defp segments(_malformed, _acc), do: {:error, :unreadable}

  # APP1-APP13 and APP15 (EXIF, XMP, ICC, Photoshop, …) and the comment.
  # APP0 (JFIF) and APP14 (Adobe) are structure.
  defp drop?(marker), do: marker in 0xE1..0xED or marker == 0xEF or marker == 0xFE
end
