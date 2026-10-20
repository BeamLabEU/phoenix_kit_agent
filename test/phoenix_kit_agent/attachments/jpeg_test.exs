defmodule PhoenixKitAgent.Attachments.JpegTest do
  @moduledoc """
  A picture sent to a model provider is the picture alone: no camera, time or
  place, no comments. The pixels are not touched.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Attachments.{Extract, Jpeg}
  alias PhoenixKitAgent.Test.Files

  @moduletag :imagemagick

  defp exif_make(path) do
    {out, 0} = System.cmd("identify", ["-format", "%[EXIF:Make]", path], stderr_to_stdout: true)
    out
  end

  defp scan_data(jpeg) do
    [_, data] = :binary.split(jpeg, <<0xFF, 0xDA>>)
    data
  end

  test "EXIF and comments are dropped and the image data is the same" do
    jpeg = Files.jpeg(60, 40)
    marked = Files.with_metadata(jpeg, "SECRETCAM", "SECRET-COMMENT")

    # The fixture does carry them, for ImageMagick too.
    assert exif_make(Files.tmp!(marked, "marked.jpg")) == "SECRETCAM"
    assert :binary.match(marked, "SECRET-COMMENT") != :nomatch

    assert {:ok, bare} = Jpeg.strip_metadata(marked)

    assert :binary.match(bare, "SECRETCAM") == :nomatch
    assert :binary.match(bare, "SECRET-COMMENT") == :nomatch
    assert scan_data(bare) == scan_data(jpeg)
    refute exif_make(Files.tmp!(bare, "bare.jpg")) =~ "SECRETCAM"

    {dims, 0} = System.cmd("identify", ["-format", "%wx%h", Files.tmp!(bare, "bare2.jpg")])
    assert dims == "60x40"
  end

  test "what is not a JPEG, or is cut inside its segments, is unreadable" do
    assert {:error, :unreadable} = Jpeg.strip_metadata("GIF89a")
    assert {:error, :unreadable} = Jpeg.strip_metadata(<<0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 1>>)
    assert {:error, :unreadable} = Jpeg.strip_metadata(<<0xFF, 0xD8, 1, 2, 3>>)
  end

  test "the JPEG that Extract.picture gives for a photo with metadata has none" do
    photo = Files.with_metadata(Files.jpeg(300, 200), "SECRETCAM", "SECRET-COMMENT")
    path = Files.tmp!(photo, "photo.jpg")

    assert {:ok, picture} = Extract.picture(path)

    assert :binary.match(picture, "SECRETCAM") == :nomatch
    assert :binary.match(picture, "SECRET-COMMENT") == :nomatch
    refute exif_make(Files.tmp!(picture, "picture.jpg")) =~ "SECRETCAM"
  end
end
