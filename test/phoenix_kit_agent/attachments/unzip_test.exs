defmodule PhoenixKitAgent.Attachments.UnzipTest do
  @moduledoc """
  Reading a workbook out of a zip made by someone else: no size the file
  declares is believed; the bytes inflated are counted against the budget.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAgent.Attachments.{Extract, Unzip}
  alias PhoenixKitAgent.Test.Files

  @zeros_5mb :binary.copy(<<0>>, 5_000_000)

  defp tmp_zip!(files, name \\ "book.xlsx"), do: files |> Files.zip() |> Files.tmp!(name)

  defp bomb_files do
    [
      {"[Content_Types].xml", "x"},
      {"xl/workbook.xml", "x"},
      {"xl/worksheets/sheet1.xml", @zeros_5mb},
      {"xl/worksheets/sheet2.xml", @zeros_5mb}
    ]
  end

  test "the parts of a honest archive come back whole, the others are not read" do
    path =
      tmp_zip!([
        {"[Content_Types].xml", "ct"},
        {"xl/workbook.xml", "wb"},
        {"xl/sharedStrings.xml", String.duplicate("s", 300_000)},
        {"xl/media/image1.png", "picture"},
        {"docProps/app.xml", "app"}
      ])

    assert {:ok, parts} = Unzip.read(path, 1_000_000)

    assert Map.new(parts) == %{
             "[Content_Types].xml" => "ct",
             "xl/workbook.xml" => "wb",
             "xl/sharedStrings.xml" => String.duplicate("s", 300_000)
           }
  end

  test "an archive that unpacks to more than the budget is too large, whatever it declares" do
    honest = Files.zip(bomb_files())
    assert {:error, :too_large} = Unzip.read(Files.tmp!(honest, "honest.xlsx"), 1_000)

    # The central directory says every part is one byte.
    forged = Files.forge_sizes(honest, 1)
    assert forged != honest
    path = Files.tmp!(forged, "forged.xlsx")

    assert {:error, :too_large} = Unzip.read(path, 1_000)
    assert {:error, :too_large} = Unzip.read(path, 9_000_000)
    assert {:ok, parts} = Unzip.read(path, 11_000_000)
    assert parts |> Enum.map(fn {_name, data} -> byte_size(data) end) |> Enum.sum() == 10_000_002
  end

  test "the reading stops at the budget instead of inflating everything" do
    # 300 MB of zeros in one part, 300 KB on disk, declared as 1 byte.
    zip =
      Files.zip([
        {"[Content_Types].xml", "x"},
        {"xl/worksheets/sheet1.xml", :binary.copy(<<0>>, 300_000_000)}
      ])
      |> Files.forge_sizes(1)

    path = Files.tmp!(zip, "huge.xlsx")
    {micros, result} = :timer.tc(fn -> Unzip.read(path, 2_000_000) end)

    assert result == {:error, :too_large}
    # Inflating all of it takes a second and more; the budget is spent in a few ms.
    assert micros < 500_000
  end

  test "an xlsx with forged sizes is too large for Extract too, and one within the limit opens" do
    path = Files.tmp!(bomb_files() |> Files.zip() |> Files.forge_sizes(1), "forged.xlsx")

    previous = Application.get_env(:phoenix_kit_agent, :attachment_limits)
    Application.put_env(:phoenix_kit_agent, :attachment_limits, sheet_unzipped_bytes: 1_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_agent, :attachment_limits, previous),
        else: Application.delete_env(:phoenix_kit_agent, :attachment_limits)
    end)

    assert {:error, :too_large} = Extract.xlsx(path)

    ok = Files.tmp!(Files.xlsx([{"S", [["a", 1]]}]), "ok.xlsx")
    Application.put_env(:phoenix_kit_agent, :attachment_limits, sheet_unzipped_bytes: 1_000_000)
    assert {:ok, %{text: "## S\na,1\n"}} = Extract.xlsx(ok)
  end

  test "a part whose stream is cut short, an encrypted one and a broken archive are unreadable" do
    good = Files.zip([{"[Content_Types].xml", String.duplicate("abc", 10_000)}])

    # Cut the compressed data of the only part in half by lying about its length.
    <<0x50, 0x4B, 0x03, 0x04, _::binary-size(14), compressed::32-little, _::binary>> = good
    cut = compressed |> div(2) |> max(1)
    [{at, _}] = :binary.matches(good, <<0x50, 0x4B, 0x01, 0x02>>)
    <<head::binary-size(at + 20), _::32, tail::binary>> = good
    short = head <> <<cut::32-little>> <> tail

    assert {:error, :unreadable} = Unzip.read(Files.tmp!(short, "cut.xlsx"), 1_000_000)
    assert {:error, :unreadable} = Unzip.read(Files.tmp!("not a zip", "x.xlsx"), 1_000_000)

    # The "encrypted" flag of the local header.
    <<pre::binary-size(6), flags::16-little, post::binary>> = good
    encrypted = pre <> <<Bitwise.bor(flags, 1)::16-little>> <> post
    assert {:error, :unreadable} = Unzip.read(Files.tmp!(encrypted, "enc.xlsx"), 1_000_000)
  end

  test "more parts than any workbook has are too large" do
    files = for n <- 1..2_100, do: {"xl/worksheets/sheet#{n}.xml", "x"}
    path = tmp_zip!([{"[Content_Types].xml", "x"} | files])

    assert {:error, :too_large} = Unzip.read(path, 1_000_000)
  end
end
