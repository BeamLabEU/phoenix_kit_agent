defmodule PhoenixKitAgent.AttachmentsTest do
  @moduledoc """
  Files attached to a chat (spec §5.3, §9): accepted for the session's own
  chat only, kept in the module's hidden Storage library in the user's folder,
  and processed in a task before the turn — PDF and text to text, a scan and a
  picture to pixels for a model that sees or to a description for one that does
  not, a sheet to CSV.

  Real bytes go through a real local bucket; the models are `Req.Test` stubs of
  the provider behind `phoenix_kit_ai`; `pdftotext`/`pdftoppm`/ImageMagick are
  the real programs (the tests that need them are tagged `:poppler` and
  `:imagemagick`, and are excluded — loudly — where they are not installed).
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{ImageProcessor, Libraries, URLSigner}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKitAgent.{Attachments, Conversations, Library, Turns}
  alias PhoenixKitAgent.Schemas.{Attachment, Message, UserSettings}
  alias PhoenixKitAgent.Test.{Files, LogProbe}
  alias PhoenixKitAI.Request
  alias PhoenixKitWeb.FileController

  @stub __MODULE__
  @me [impersonated: false]
  @secret "SECRET-MARKER-4f7a"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()
    Files.local_bucket!()

    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)

    chat_endpoint = endpoint_fixture(%{name: "Chat", model: "a/chat"})
    {:ok, _} = Settings.update_setting("agent_default_endpoint_uuid", chat_endpoint.uuid)

    {:ok, role} = Roles.create_role(%{name: "AgentFiles#{System.unique_integer([:positive])}"})
    _ = owner_fixture()
    for key <- ["agent", "dashboard"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user_fixture("files")
    {:ok, _} = Roles.assign_role(user, role.name)

    {ref, token} = session_fixture(user)
    chat = conversation_fixture(user)
    :ok = Conversations.subscribe(ref, chat.uuid, @me)

    %{user: user, role: role, ref: ref, token: token, chat: chat, chat_endpoint: chat_endpoint}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp add(ctx, binary, name, content_type \\ nil) do
    Attachments.add(ctx.ref, ctx.chat.uuid, Files.upload!(binary, name, content_type), @me)
  end

  defp await_done(attachment) do
    chat_uuid = attachment.conversation_uuid
    uuid = attachment.uuid
    assert_receive {:agent_attachment_processed, ^chat_uuid, ^uuid}, 10_000
    Repo.get!(Attachment, uuid)
  end

  defp add_done!(ctx, binary, name, content_type \\ nil) do
    assert {:ok, attachment} = add(ctx, binary, name, content_type)
    assert attachment.status == "pending"
    await_done(attachment)
  end

  # The models' listing and the answers: a chat model that sees or does not,
  # a vision model that answers with `description`.
  defp serve_ai(opts \\ []) do
    test = self()
    sees? = Keyword.get(opts, :main_sees, true)
    description = Keyword.get(opts, :description, "A grey square that reads SOFA 3 PCS.")

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/api/v1/models" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "a/chat",
                "name" => "chat",
                "architecture" => %{
                  "modality" => if(sees?, do: "text+image->text", else: "text->text")
                }
              },
              %{
                "id" => "a/eyes",
                "name" => "eyes",
                "architecture" => %{"modality" => "text+image->text"}
              }
            ]
          })

        "/api/v1/chat/completions" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test, {:model_request, Jason.decode!(raw)})

          Req.Test.json(conn, %{
            "model" => "a/eyes",
            "choices" => [%{"message" => %{"role" => "assistant", "content" => description}}],
            "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 8, "total_tokens" => 38}
          })
      end
    end)
  end

  defp vision_endpoint!(model \\ "a/eyes") do
    endpoint = endpoint_fixture(%{name: "Eyes", model: model})
    {:ok, _} = Settings.update_setting("agent_vision_endpoint_uuid", endpoint.uuid)
    endpoint
  end

  defp limits!(user, attrs) do
    %UserSettings{user_uuid: user.uuid}
    |> UserSettings.admin_changeset(attrs)
    |> Repo.insert!(on_conflict: {:replace, Map.keys(attrs)}, conflict_target: :user_uuid)
  end

  defp with_limits(opts) do
    previous = Application.get_env(:phoenix_kit_agent, :attachment_limits)
    Application.put_env(:phoenix_kit_agent, :attachment_limits, opts)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_agent, :attachment_limits, previous),
        else: Application.delete_env(:phoenix_kit_agent, :attachment_limits)
    end)
  end

  defp storage_file(attachment), do: Repo.get!(Storage.File, attachment.file_uuid)

  # ── what is accepted ────────────────────────────────────────────────

  describe "kinds are told by the content" do
    test "a text file is stored for the user in the module's hidden library", ctx do
      attachment = add_done!(ctx, "Sofa 3 pcs\nTable 1\n", "notes.txt", "text/plain")

      assert attachment.kind == "text"
      assert attachment.status == "ready"
      assert attachment.filename == "notes.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.size_bytes == byte_size("Sofa 3 pcs\nTable 1\n")
      assert attachment.extracted_text == "Sofa 3 pcs\nTable 1\n"
      assert attachment.truncated == false
      assert attachment.user_uuid == ctx.user.uuid
      assert attachment.conversation_uuid == ctx.chat.uuid
      assert attachment.message_uuid == nil

      file = storage_file(attachment)
      {:ok, library} = Library.ensure_library()
      folder = Library.user_folder(ctx.user.uuid)

      assert Libraries.hidden?(library)
      assert file.library_uuid == library.uuid
      assert file.folder_uuid == folder.uuid
      assert folder.name == ctx.user.uuid
      assert file.user_uuid == ctx.user.uuid
    end

    test "a picture named .pdf is a picture; text named .png is no picture; an unknown binary is refused",
         ctx do
      serve_ai()

      image = add_done!(ctx, Files.png(40, 30), "scan.pdf", "application/pdf")
      assert image.kind == "image"
      assert image.content_type == "image/png"

      assert {:error, :unsupported_type} = add(ctx, "just words", "photo.png", "image/png")

      assert {:error, :unsupported_type} =
               add(ctx, <<0, 1, 2, 3, 0, 255, 254, 0>>, "notes.txt", "text/plain")
    end

    test "other documents, archives and executables are refused", ctx do
      docx = Files.zip([{"word/document.xml", "<w:document/>"}])

      for {binary, name} <- [
            {docx, "letter.docx"},
            {"MZ" <> :binary.copy(<<0>>, 64), "tool.exe"},
            {"<svg xmlns='http://www.w3.org/2000/svg'></svg>", "logo.svg"},
            {"GIF89a" <> :binary.copy(<<0>>, 20), "anim.gif"},
            {"<html></html>", "page.html"},
            {"{\"a\":1}", "data.json"},
            {"a text without extension", "README"}
          ] do
        assert {:error, :unsupported_type} = add(ctx, binary, name)
      end

      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "an empty file is refused", ctx do
      assert {:error, :empty_file} = add(ctx, "", "empty.txt")
    end

    test "webp and heic are accepted by their first bytes", ctx do
      serve_ai()
      webp = "RIFF" <> <<12::little-32>> <> "WEBP" <> :binary.copy(<<0>>, 32)
      heic = <<0, 0, 0, 24>> <> "ftypheic" <> :binary.copy(<<0>>, 32)

      for {binary, name, type} <- [
            {webp, "a.bin", "image/webp"},
            {heic, "IMG_0001.HEIC", "image/heic"}
          ] do
        assert {:ok, attachment} = add(ctx, binary, name)
        assert attachment.kind == "image"
        assert attachment.content_type == type
        # Not real pictures: the task says so (and ends), it does not crash.
        assert %{status: "failed"} = await_done(attachment)
      end
    end

    test "the file name is kept as a plain name", ctx do
      upload = %{Files.upload!("x", "a.txt") | filename: "../../etc/pa\nss\0wd.txt"}
      assert {:ok, attachment} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)
      assert await_done(attachment).filename == "passwd.txt"

      upload = %{Files.upload!("y", "b.txt") | filename: "C:\\Users\\me\\report.txt"}
      assert {:ok, attachment} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)
      assert await_done(attachment).filename == "report.txt"

      upload = %{Files.upload!("z", "c.txt") | filename: ".."}
      assert {:error, :unsupported_type} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)
    end
  end

  # ── processing: text and sheets ─────────────────────────────────────

  describe "text" do
    test "a long text is cut and says so", ctx do
      with_limits(text_chars: 100)
      text = String.duplicate("Line of an order list\n", 30)

      attachment = add_done!(ctx, text, "long.txt")

      assert attachment.status == "ready"
      assert attachment.truncated
      assert String.length(attachment.extracted_text) <= 100
      assert String.starts_with?(text, attachment.extracted_text)
    end

    test "markdown is text; a byte order mark is dropped", ctx do
      md = add_done!(ctx, "# Title\n\n* one", "notes.md")
      assert md.kind == "text"
      assert md.content_type == "text/markdown"
      assert md.extracted_text == "# Title\n\n* one"

      bom = add_done!(ctx, "﻿hello", "bom.txt")
      assert bom.extracted_text == "hello"
    end

    test "csv is read as CSV rows, the first ones", ctx do
      with_limits(sheet_rows: 3)
      csv = "name;qty\nsofa;3\ntable;1\nchair;4\nlamp;9\n"

      attachment = add_done!(ctx, csv, "list.csv", "text/csv")

      assert attachment.kind == "sheet"
      assert attachment.content_type == "text/csv"
      assert attachment.extracted_text == "name;qty\nsofa;3\ntable;1"
      assert attachment.truncated
    end
  end

  describe "sheets" do
    test "an xlsx becomes CSV, the first rows of each sheet", ctx do
      with_limits(sheet_rows: 2)

      xlsx =
        Files.xlsx([
          {"Orders", [["Item", "Qty"], ["Sofa, big", 3], ["Table", 1.5]]},
          {"Notes", [["Only one"]]}
        ])

      attachment = add_done!(ctx, xlsx, "orders.xlsx")

      assert attachment.kind == "sheet"
      assert attachment.status == "ready"

      assert attachment.content_type ==
               "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      assert attachment.extracted_text ==
               "## Orders\nItem,Qty\n\"Sofa, big\",3\n\n## Notes\nOnly one\n"

      assert attachment.truncated
    end

    test "an xlsx is told by its content, not by its name", ctx do
      xlsx = Files.xlsx([{"S", [["a", 1]]}])
      attachment = add_done!(ctx, xlsx, "table.dat")
      assert attachment.kind == "sheet"
      assert attachment.extracted_text =~ "a,1"
    end

    test "a damaged xlsx fails with a code and nothing of it in the log", ctx do
      broken =
        Files.zip([
          {"[Content_Types].xml", "<Types>#{@secret}"},
          {"xl/workbook.xml", "<workbook>#{@secret}"}
        ])

      {attachment, logs} =
        LogProbe.capture(fn ->
          add_done!(ctx, broken, "broken.xlsx")
        end)

      assert attachment.status == "failed"
      assert attachment.error == "unreadable"
      assert attachment.extracted_text == nil
      refute Enum.any?(logs, &(&1 =~ @secret))
    end

    test "a zip that unpacks to far more than the file's size is not read", ctx do
      bomb = Files.zip([{"[Content_Types].xml", "x"}, {"xl/workbook.xml", "x"}])
      with_limits(sheet_unzipped_bytes: 1)

      attachment = add_done!(ctx, bomb, "bomb.xlsx")
      assert attachment.status == "failed"
      assert attachment.error == "too_large"
    end
  end

  # ── processing: PDF ─────────────────────────────────────────────────

  describe "pdf" do
    @describetag :poppler

    test "a PDF with text gives its text and its page count", ctx do
      pdf = Files.text_pdf(["Quote number 4711", "Second page: delivery on Friday"])

      attachment = add_done!(ctx, pdf, "quote.pdf", "application/pdf")

      assert attachment.kind == "pdf"
      assert attachment.status == "ready"
      assert attachment.content_type == "application/pdf"
      assert attachment.pages == 2
      assert attachment.extracted_text =~ "Quote number 4711"
      assert attachment.extracted_text =~ "delivery on Friday"
      refute attachment.truncated
    end

    test "a long PDF text is cut", ctx do
      with_limits(text_chars: 30)
      pdf = Files.text_pdf(["Quote number 4711 and a long line of words that goes on"])

      attachment = add_done!(ctx, pdf, "quote.pdf")

      assert attachment.truncated
      assert String.length(attachment.extracted_text) <= 30
    end

    test "a scan, for a model that sees, stays pixels: the first pages as pictures", ctx do
      serve_ai(main_sees: true)
      with_limits(scan_pages: 2)

      attachment = add_done!(ctx, Files.scan_pdf(3), "scan.pdf")

      assert attachment.kind == "pdf"
      assert attachment.status == "ready"
      assert attachment.extracted_text == nil
      assert attachment.pages == 3
      assert attachment.truncated

      assert {:ok, [first, second]} = Attachments.pictures(attachment)
      assert "data:image/png;base64," <> png = first
      assert {:ok, <<0x89, "PNG", _::binary>>} = Base.decode64(png)
      assert "data:image/png;base64," <> _ = second
    end

    test "a scan, for a model that does not see, is described by the vision model", ctx do
      serve_ai(main_sees: false, description: "A blue rectangle on white.")
      vision = vision_endpoint!()

      attachment = add_done!(ctx, Files.scan_pdf(1), "scan.pdf")

      assert attachment.status == "ready"
      assert attachment.extracted_text == "A blue rectangle on white."
      assert attachment.pages == 1

      assert_received {:model_request, body}
      assert model_request_images(body) == 1

      assert %{endpoint_uuid: endpoint_uuid} = vision_request(ctx.user)
      assert endpoint_uuid == vision.uuid
    end
  end

  describe "when the programs are not there" do
    test "a PDF is refused with a plain reason, the task does not crash", ctx do
      path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")
      on_exit(fn -> System.put_env("PATH", path) end)

      attachment = add_done!(ctx, Files.text_pdf(["Hello"]), "quote.pdf")

      assert attachment.status == "failed"
      assert attachment.error == "pdf_tools_missing"
    end

    test "a picture is refused with a plain reason", ctx do
      serve_ai()
      path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")
      on_exit(fn -> System.put_env("PATH", path) end)

      attachment = add_done!(ctx, Files.png(40, 30), "photo.png")

      assert attachment.status == "failed"
      assert attachment.error == "image_tools_missing"
    end
  end

  # ── processing: pictures ────────────────────────────────────────────

  describe "pictures" do
    @describetag :imagemagick

    test "for a model that sees, a picture stays pixels, shrunk to 1600 px", ctx do
      serve_ai(main_sees: true)

      attachment = add_done!(ctx, Files.png(2400, 1200), "wide.png", "image/png")

      assert attachment.kind == "image"
      assert attachment.status == "ready"
      assert attachment.extracted_text == nil
      refute_received {:model_request, _}

      assert {:ok, [url]} = Attachments.pictures(attachment)
      assert "data:image/jpeg;base64," <> jpeg = url
      bytes = Base.decode64!(jpeg)

      assert {:ok, {1600, 800}} =
               ImageProcessor.extract_dimensions(Files.tmp!(bytes, "out.jpg"))
    end

    test "a small picture is not enlarged", ctx do
      serve_ai(main_sees: true)
      attachment = add_done!(ctx, Files.png(300, 200), "small.png")

      assert {:ok, ["data:image/jpeg;base64," <> jpeg]} = Attachments.pictures(attachment)

      assert {:ok, {300, 200}} =
               ImageProcessor.extract_dimensions(Files.tmp!(Base.decode64!(jpeg), "out.jpg"))
    end

    test "for a model that does not see, the vision model describes it", ctx do
      serve_ai(main_sees: false, description: "A grey square that reads SOFA 3 PCS.")
      vision = vision_endpoint!()

      attachment = add_done!(ctx, Files.png(2400, 1200), "wide.png")

      assert attachment.status == "ready"
      assert attachment.extracted_text == "A grey square that reads SOFA 3 PCS."

      assert_received {:model_request, body}
      assert model_request_images(body) == 1

      request = vision_request(ctx.user)
      assert request.endpoint_uuid == vision.uuid
      assert request.request_type == "vision"
      assert request.metadata["source"] == "agent"
      # What the user showed is not kept in the AI journal, whatever the global setting.
      refute Map.has_key?(request.metadata, "input")
      refute Map.has_key?(request.metadata, "response")
    end

    test "an endpoint of unknown abilities with a vision model set is described too", ctx do
      serve_ai(description: "Described.")
      vision_endpoint!()
      deepseek = endpoint_fixture(%{provider: "deepseek", model: "deepseek-chat"})
      limits!(ctx.user, %{endpoint_uuid: deepseek.uuid})

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")
      assert attachment.extracted_text == "Described."
    end

    test "a model that does not see and no vision model: the picture fails, it is not guessed",
         ctx do
      serve_ai(main_sees: false)

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "failed"
      assert attachment.error == "no_vision_model"
      refute_received {:model_request, _}
    end

    test "a picture is not described for a user over the limit, and costs nothing", ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()
      limits!(ctx.user, %{daily_turn_limit: 0})

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "failed"
      assert attachment.error == "limit_reached"
      refute_received {:model_request, _}
    end

    test "a failed description is a code, not the provider's text", ctx do
      serve_ai(main_sees: false)
      vision_endpoint!()

      Req.Test.stub(@stub, fn conn ->
        case conn.request_path do
          "/api/v1/models" ->
            Req.Test.json(conn, %{"data" => []})

          _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "boom"}}))
        end
      end)

      attachment = add_done!(ctx, Files.png(40, 30), "a.png")

      assert attachment.status == "failed"
      assert attachment.error == "model_error"
      assert attachment.extracted_text == nil
    end

    test "bytes that are not a picture fail, they do not crash", ctx do
      serve_ai()
      png = Files.png(40, 30)
      broken = binary_part(png, 0, 40) <> :binary.copy(<<7>>, 20)

      attachment = add_done!(ctx, broken, "broken.png")

      assert attachment.status == "failed"
      assert attachment.error == "unreadable"
    end
  end

  # ── the task ────────────────────────────────────────────────────────

  describe "the processing task" do
    test "one that takes too long ends as failed", ctx do
      with_limits(process_deadline_ms: 0)

      attachment = add_done!(ctx, "text", "a.txt")

      assert attachment.status == "failed"
      assert attachment.error == "timeout"
    end

    test "a discarded attachment is not brought back by a task that ends later", ctx do
      assert {:ok, attachment} = add(ctx, "text", "a.txt")
      assert :ok = Attachments.discard(ctx.ref, attachment.uuid, @me)

      # Whichever came first, the row is gone and stays gone.
      _ = :sys.get_state(Process.whereis(PhoenixKitAgent.Attachments.TaskSupervisor))
      wait_for_children_to_end()
      assert Repo.get(Attachment, attachment.uuid) == nil
    end

    test "the text of a file never reaches the log", ctx do
      {_, logs} =
        LogProbe.capture(fn ->
          add_done!(ctx, "#{@secret} order list", "list.txt")
          add_done!(ctx, Files.xlsx([{"S", [[@secret, 1]]}]), "list.xlsx")
        end)

      refute Enum.any?(logs, &(&1 =~ @secret))
    end
  end

  defp wait_for_children_to_end do
    for pid <- Task.Supervisor.children(PhoenixKitAgent.Attachments.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  # ── limits ──────────────────────────────────────────────────────────

  describe "limits" do
    test "a file over max_attachment_mb is refused; nothing is stored", ctx do
      limits!(ctx.user, %{max_attachment_mb: 1})
      big = String.duplicate("a", 1_048_576 + 1)

      assert {:error, :too_large} = add(ctx, big, "big.txt")
      assert Repo.aggregate(Attachment, :count) == 0
      assert Library.user_folder(ctx.user.uuid) == nil

      ok = String.duplicate("a", 1_048_576)
      assert {:ok, attachment} = add(ctx, ok, "ok.txt")
      await_done(attachment)
    end

    test "0 MB means no files at all; the module default applies without a user value", ctx do
      limits!(ctx.user, %{max_attachment_mb: 0})
      assert {:error, :too_large} = add(ctx, "x", "a.txt")

      Repo.delete_all(from(s in UserSettings, where: s.user_uuid == ^ctx.user.uuid))
      {:ok, _} = Settings.update_setting("agent_max_attachment_mb", "1")
      assert {:error, :too_large} = add(ctx, String.duplicate("a", 1_048_577), "big.txt")
    end

    test "no more than max_attachments_per_message wait for a message", ctx do
      limits!(ctx.user, %{max_attachments_per_message: 2})

      first = add_done!(ctx, "one", "1.txt")
      _second = add_done!(ctx, "two", "2.txt")
      assert {:error, :too_many} = add(ctx, "three", "3.txt")

      # Removing one makes room.
      assert :ok = Attachments.discard(ctx.ref, first.uuid, @me)
      assert {:ok, third} = add(ctx, "three", "3.txt")
      await_done(third)
      assert {:error, :too_many} = add(ctx, "four", "4.txt")
    end

    test "a failed file takes no room; one already sent takes none either", ctx do
      serve_ai()
      limits!(ctx.user, %{max_attachments_per_message: 1})

      damaged = Files.zip([{"[Content_Types].xml", "<Types>"}, {"xl/workbook.xml", "<workbook>"}])
      assert %{status: "failed"} = add_done!(ctx, damaged, "broken.xlsx")

      sent = add_done!(ctx, "sent", "sent.txt")
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [sent.uuid])
      await_turn(ctx, turn_ref)

      assert {:ok, next} = add(ctx, "next", "next.txt")
      await_done(next)
      assert {:error, :too_many} = add(ctx, "one more", "more.txt")
    end

    test "parallel uploads cannot get past the count", ctx do
      limits!(ctx.user, %{max_attachments_per_message: 2})
      uploads = for n <- 1..6, do: Files.upload!("file #{n}", "f#{n}.txt")

      results =
        uploads
        |> Task.async_stream(
          fn upload -> Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me) end,
          timeout: 20_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 2
      assert Enum.count(results, &(&1 == {:error, :too_many})) == 4

      for {:ok, attachment} <- results, do: await_done(attachment)
    end
  end

  # ── who may ─────────────────────────────────────────────────────────

  describe "the owner only" do
    test "an impersonated session, a revoked one and a user without the permission are refused",
         ctx do
      upload = Files.upload!("x", "a.txt")

      assert {:error, :impersonated} =
               Attachments.add(ctx.ref, ctx.chat.uuid, upload, impersonated: true)

      Auth.delete_user_session_token(ctx.token)
      assert {:error, :session_gone} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)

      plain = user_with([], "plain")
      {plain_ref, _} = session_fixture(plain)
      chat = conversation_fixture(plain)
      assert {:error, :forbidden} = Attachments.add(plain_ref, chat.uuid, upload, @me)

      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "a chat of someone else, a deleted chat or a bad uuid is not found", ctx do
      other = user_fixture("other")
      other_chat = conversation_fixture(other)
      upload = Files.upload!("x", "a.txt")

      for uuid <- [other_chat.uuid, Ecto.UUID.generate(), "junk", nil] do
        assert {:error, :not_found} = Attachments.add(ctx.ref, uuid, upload, @me)
      end

      assert {:ok, _} = Conversations.delete_conversation(ctx.ref, ctx.chat.uuid, @me)
      assert {:error, :not_found} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)

      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "the caller must say whether the session is impersonated", ctx do
      assert_raise ArgumentError, fn ->
        Attachments.add(ctx.ref, ctx.chat.uuid, Files.upload!("x", "a.txt"), [])
      end
    end

    test "an upload that is not a readable file is refused", ctx do
      for upload <- [
            %{path: "/nonexistent/file.txt", filename: "a.txt"},
            %{path: System.tmp_dir!(), filename: "dir.txt"},
            %{filename: "a.txt"},
            "junk"
          ] do
        assert {:error, :file_unreadable} = Attachments.add(ctx.ref, ctx.chat.uuid, upload, @me)
      end
    end

    test "another user does not read, list, discard or fetch the file of an attachment", ctx do
      attachment = add_done!(ctx, "mine", "mine.txt")

      other = user_with(["agent"], "other")
      {other_ref, _} = session_fixture(other)
      other_chat = conversation_fixture(other)

      assert {:error, :not_found} = Attachments.get(other_ref, attachment.uuid, @me)
      assert {:error, :not_found} = Attachments.list_unsent(other_ref, ctx.chat.uuid, @me)
      assert {:error, :not_found} = Attachments.discard(other_ref, attachment.uuid, @me)
      assert {:error, :not_found} = Attachments.url(other_ref, attachment.uuid, @me)
      assert {:error, :not_found} = Attachments.url(other_ref, "junk", @me)
      assert Repo.get(Attachment, attachment.uuid)

      # Nor into a chat of theirs.
      assert {:error, :not_found} =
               Attachments.get(other_ref, Ecto.UUID.generate(), @me)

      assert other_chat.uuid != ctx.chat.uuid
    end

    test "the owner reads, lists, and gets a temporary address of the file", ctx do
      attachment = add_done!(ctx, "mine", "mine.txt")

      assert {:ok, %Attachment{uuid: uuid}} = Attachments.get(ctx.ref, attachment.uuid, @me)
      assert uuid == attachment.uuid

      assert {:ok, [%Attachment{uuid: ^uuid}]} =
               Attachments.list_unsent(ctx.ref, ctx.chat.uuid, @me)

      assert {:ok, url} = Attachments.url(ctx.ref, attachment.uuid, @me)
      assert {:ok, %{uuid: file_uuid, variant: "original"}} = URLSigner.verify_url(url)
      assert file_uuid == attachment.file_uuid
      [token] = url |> String.split("/") |> Enum.take(-1)
      assert "w" <> _ = token
    end

    test "an Admin or Owner is no owner of an attachment through the module", ctx do
      attachment = add_done!(ctx, "mine", "mine.txt")
      owner = owner_fixture()
      {owner_ref, _} = session_fixture(owner)

      assert {:error, :not_found} = Attachments.url(owner_ref, attachment.uuid, @me)
      assert {:error, :not_found} = Attachments.get(owner_ref, attachment.uuid, @me)
    end

    test "a session ended or impersonated gets no address either", ctx do
      attachment = add_done!(ctx, "mine", "mine.txt")

      assert {:error, :impersonated} =
               Attachments.url(ctx.ref, attachment.uuid, impersonated: true)

      Auth.delete_user_session_token(ctx.token)
      assert {:error, :session_gone} = Attachments.url(ctx.ref, attachment.uuid, @me)
    end
  end

  # ── nobody else sees the file in Storage ────────────────────────────

  describe "the hidden library" do
    test "a Manager with media.view_all finds the file nowhere, and no address works for them",
         ctx do
      attachment = add_done!(ctx, "private notes", "private.txt")
      file = storage_file(attachment)
      {:ok, library} = Library.ensure_library()

      {:ok, manager_role} =
        Roles.create_role(%{name: "Managers#{System.unique_integer([:positive])}"})

      for key <- ~w(media media.view_all media.manage),
          do: {:ok, _} = Permissions.grant_permission(manager_role.uuid, key)

      manager = user_fixture("manager")
      {:ok, _} = Roles.assign_role(manager, manager_role.name)
      manager_scope = scope_of(manager)

      # The media picker and the media browser list files of no named library.
      {files, _} = Storage.list_files_in_scope(nil, per_page: 1000)
      refute file.uuid in Enum.map(files, & &1.uuid)

      refute Enum.any?(Storage.list_folders(nil, nil), &(&1.library_uuid == library.uuid))

      # /admin/media: the library switcher and its page by slug.
      refute library.uuid in Enum.map(Libraries.list_system_libraries(), & &1.uuid)
      assert Libraries.get_system_library_by_slug(library.slug) == nil
      assert Libraries.hidden?(library)

      # The file itself: no read, no address.
      refute Libraries.can?(manager_scope, file, :read)
      refute Libraries.can?(manager_scope, file, :edit)
      assert Storage.authorized_url(manager_scope, file, "original") == nil

      # The permanent token is refused; the owner's expiring one serves.
      permanent = URLSigner.generate_token(file.uuid, "original")

      denied =
        FileController.show(conn(:get, "/"), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => permanent
        })

      assert denied.status == 401

      {:ok, url} = Attachments.url(ctx.ref, attachment.uuid, @me)
      [token] = url |> String.split("/") |> Enum.take(-1)

      served =
        FileController.show(conn(:get, "/"), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => token
        })

      assert served.status == 200
    end
  end

  # ── the turn ────────────────────────────────────────────────────────

  describe "in a turn" do
    test "the text of a ready attachment goes with the message, and the row is linked", ctx do
      serve_ai()
      attachment = add_done!(ctx, "Sofa 3 pcs", "notes.txt")

      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "See file", [attachment.uuid])
      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = chat_messages(body)
      assert content =~ "See file"
      assert content =~ "Sofa 3 pcs"

      user_message =
        Repo.one(
          from(m in Message, where: m.conversation_uuid == ^ctx.chat.uuid and m.role == "user")
        )

      assert Repo.get!(Attachment, attachment.uuid).message_uuid == user_message.uuid
      assert {:ok, []} = Attachments.list_unsent(ctx.ref, ctx.chat.uuid, @me)
    end

    @tag :imagemagick
    test "a picture goes to a model that sees as pixels, in its own turn only", ctx do
      serve_ai(main_sees: true, description: "It is a sofa.")
      attachment = add_done!(ctx, Files.png(2400, 1200), "sofa.png")

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [attachment.uuid])

      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => parts}] = chat_messages(body)
      assert [%{"type" => "text", "text" => text}, %{"type" => "image_url"} = image] = parts
      assert text =~ "What is this?"
      assert text =~ "sofa.png"
      assert "data:image/jpeg;base64," <> _ = image["image_url"]["url"]

      # The next turn: the pixels are not sent again, the file is named.
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "And now?", [])
      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      contents = body |> chat_messages() |> Enum.map(& &1["content"])
      assert Enum.all?(contents, &is_binary/1)
      assert Enum.any?(contents, &(&1 =~ "sofa.png"))
    end

    @tag :imagemagick
    test "a turn that carries pictures stays out of the AI journal even when capture is on",
         ctx do
      {:ok, _} = PhoenixKitAgent.Config.put_capture_ai_content(true, [])
      serve_ai(main_sees: true)
      picture = add_done!(ctx, Files.png(40, 30), "sofa.png")

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [picture.uuid])

      await_turn(ctx, turn_ref)

      pictured = journal_row_of_last_answer(ctx)
      assert pictured.metadata["content_redacted"] == true
      refute inspect(pictured.metadata) =~ "base64"

      # The same setting does capture a turn without pictures: the check above
      # is not an effect of the setting being off.
      text = add_done!(ctx, "Sofa 3 pcs", "notes.txt")
      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "Read it", [text.uuid])
      await_turn(ctx, turn_ref)

      assert journal_row_of_last_answer(ctx).metadata["content_redacted"] != true
    end

    @tag :imagemagick
    test "a picture goes to a model that does not see as its description, kept in the history",
         ctx do
      serve_ai(main_sees: false, description: "A grey square that reads SOFA 3 PCS.")
      vision_endpoint!()
      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")
      assert_received {:model_request, _vision_call}

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [attachment.uuid])

      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = chat_messages(body)
      assert is_binary(content)
      assert content =~ "SOFA 3 PCS"

      {:ok, turn_ref} = Turns.start(ctx.ref, false, ctx.chat.uuid, "And now?", [])
      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert body |> chat_messages() |> Enum.any?(&(&1["content"] =~ "SOFA 3 PCS"))
    end

    @tag :imagemagick
    test "a picture shown to a model that was changed to one that cannot see it is not sent",
         ctx do
      serve_ai(main_sees: true)
      attachment = add_done!(ctx, Files.png(40, 30), "sofa.png")

      # Between the upload and the send the user's model changes to one that is blind.
      blind = endpoint_fixture(%{name: "Blind", model: "a/blind"})
      limits!(ctx.user, %{endpoint_uuid: blind.uuid})

      test = self()

      Req.Test.stub(@stub, fn conn ->
        case conn.request_path do
          "/api/v1/models" ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "id" => "a/blind",
                  "name" => "b",
                  "architecture" => %{"modality" => "text->text"}
                }
              ]
            })

          _ ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:model_request, Jason.decode!(raw)})

            Req.Test.json(conn, %{
              "model" => "a/blind",
              "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
            })
        end
      end)

      {:ok, turn_ref} =
        Turns.start(ctx.ref, false, ctx.chat.uuid, "What is this?", [attachment.uuid])

      await_turn(ctx, turn_ref)

      assert_received {:model_request, body}
      assert [%{"role" => "user", "content" => content}] = chat_messages(body)
      assert is_binary(content)
      assert content =~ "sofa.png"
      refute inspect(body) =~ "image_url"
    end

    test "an attachment of another chat of the same user, a pending one and a foreign one are refused",
         ctx do
      other_chat = conversation_fixture(ctx.user)
      :ok = Conversations.subscribe(ctx.ref, other_chat.uuid, @me)

      {:ok, in_other} =
        Attachments.add(ctx.ref, other_chat.uuid, Files.upload!("x", "x.txt"), @me)

      await_done(in_other)

      stranger = user_with(["agent"], "stranger")
      {stranger_ref, _} = session_fixture(stranger)
      stranger_chat = conversation_fixture(stranger)
      :ok = Conversations.subscribe(stranger_ref, stranger_chat.uuid, @me)

      {:ok, foreign} =
        Attachments.add(stranger_ref, stranger_chat.uuid, Files.upload!("y", "y.txt"), @me)

      await_done(foreign)

      pending = add_done!(ctx, "z", "z.txt")

      Repo.update_all(from(a in Attachment, where: a.uuid == ^pending.uuid),
        set: [status: "pending"]
      )

      for uuid <- [in_other.uuid, foreign.uuid, pending.uuid] do
        assert {:error, :invalid_attachments} =
                 Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", [uuid])
      end

      assert Repo.aggregate(
               from(m in Message, where: m.conversation_uuid == ^ctx.chat.uuid),
               :count
             ) == 0

      assert Repo.get!(Attachment, foreign.uuid).message_uuid == nil
    end

    test "more attachments than the user may send in one message are refused", ctx do
      limits!(ctx.user, %{max_attachments_per_message: 5})
      ready = for n <- 1..2, do: add_done!(ctx, "file #{n}", "f#{n}.txt")

      limits!(ctx.user, %{max_attachments_per_message: 1})

      assert {:error, :too_many_attachments} =
               Turns.start(ctx.ref, false, ctx.chat.uuid, "Hi", Enum.map(ready, & &1.uuid))

      assert Repo.aggregate(
               from(m in Message, where: m.conversation_uuid == ^ctx.chat.uuid),
               :count
             ) == 0
    end
  end

  defp journal_row_of_last_answer(ctx) do
    answer =
      Repo.one!(
        from(m in Message,
          where: m.conversation_uuid == ^ctx.chat.uuid and m.role == "assistant",
          order_by: [desc: m.inserted_at, desc: m.uuid],
          limit: 1
        )
      )

    Repo.get!(Request, answer.ai_request_uuid)
  end

  defp await_turn(ctx, turn_ref) do
    chat_uuid = ctx.chat.uuid
    assert_receive {:agent_turn_finished, ^chat_uuid, ^turn_ref}, 10_000
  end

  defp chat_messages(body), do: Enum.reject(body["messages"], &(&1["role"] == "system"))

  defp model_request_images(body) do
    body["messages"]
    |> Enum.flat_map(fn message ->
      if is_list(message["content"]), do: message["content"], else: []
    end)
    |> Enum.count(&(&1["type"] == "image_url"))
  end

  defp vision_request(user) do
    Repo.one!(
      from(r in Request,
        where: r.user_uuid == ^user.uuid and r.request_type == "vision",
        order_by: [desc: r.inserted_at],
        limit: 1
      )
    )
  end
end
