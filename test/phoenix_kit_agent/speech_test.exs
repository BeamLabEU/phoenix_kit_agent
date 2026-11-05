defmodule PhoenixKitAgent.SpeechTest do
  @moduledoc """
  A recording written down for a user (`PhoenixKitAgent.Speech`): who may ask,
  what is checked before the paid call, how the model's answer and its
  refusals become codes, and where the money goes. The model is stubbed behind
  `phoenix_kit_ai` (the real `PhoenixKitAI.transcribe/3` runs).
  """

  use PhoenixKitAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKitAgent.{Config, Speech, Spend}
  alias PhoenixKitAgent.Schemas.UserSettings
  alias PhoenixKitAgent.Test.LogProbe

  @stub __MODULE__
  @model "google/gemini-2.5-flash"
  @words "Hello, this is my order"

  setup do
    {:ok, _} = PhoenixKitAgent.enable_system()
    {:ok, _} = PhoenixKitAI.enable_system()

    Req.Test.set_req_test_to_shared()
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, @stub}, retry: false)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      Req.Test.set_req_test_to_private()
    end)

    user = user_with(["agent"], "speaker")
    {ref, _token} = session_fixture(user)
    %{user: user, ref: ref, endpoint: speech_endpoint()}
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp speech_endpoint(audio \\ "yes") do
    endpoint =
      endpoint_fixture(%{
        model: @model,
        provider_settings: %{"capabilities" => %{"audio_input" => audio, "model" => @model}}
      })

    {:ok, _} = Settings.update_setting("agent_speech_endpoint_uuid", endpoint.uuid)
    endpoint
  end

  defp heard(json) do
    %{
      "model" => @model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => Jason.encode!(json)}}],
      "usage" => %{"prompt_tokens" => 30, "completion_tokens" => 8, "total_tokens" => 38}
    }
  end

  defp model_hears(json) do
    test = self()

    Req.Test.expect(@stub, fn conn ->
      send(test, :model_called)
      Req.Test.json(conn, heard(json))
    end)
  end

  defp model_not_called do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, :model_called)
      Req.Test.json(conn, heard(%{"text" => "no", "language" => "en"}))
    end)
  end

  defp transcribe(ref, bytes \\ "RIFF-not-really-audio", format \\ "wav"),
    do: Speech.transcribe(ref, bytes, format, impersonated: false)

  # ── the answer ──────────────────────────────────────────────────────

  describe "transcribe/4" do
    test "writes the recording down", %{ref: ref} do
      model_hears(%{"text" => "  #{@words}\n", "language" => "en"})

      assert {:ok, @words} = transcribe(ref)
      assert_received :model_called
    end

    test "the journal row is the user's, of the agent, and holds no words", %{
      ref: ref,
      user: user,
      endpoint: endpoint
    } do
      model_hears(%{"text" => @words, "language" => "en"})
      assert {:ok, @words} = transcribe(ref)

      [request] =
        Repo.all(from(r in PhoenixKitAI.Request, where: r.endpoint_uuid == ^endpoint.uuid))

      assert request.user_uuid == user.uuid
      assert request.metadata["source"] == "agent"
      refute inspect(request.metadata) =~ @words
    end

    test "a recording with no speech is :no_speech", %{ref: ref} do
      model_hears(%{"text" => "  ", "language" => nil})
      assert {:error, :no_speech} = transcribe(ref)
    end

    test "an empty recording is :no_speech and the model is not asked", %{ref: ref} do
      model_not_called()
      assert {:error, :no_speech} = transcribe(ref, "")
      refute_received :model_called
    end

    test "a recording over the limit is :too_long and the model is not asked", %{ref: ref} do
      model_not_called()
      assert {:error, :too_long} = transcribe(ref, :binary.copy(<<0>>, Speech.max_bytes() + 1))
      refute_received :model_called
    end

    test "a model that cannot take audio is :unfit", %{ref: ref} do
      _ = speech_endpoint("no")
      model_not_called()

      assert {:error, :unfit} = transcribe(ref)
      refute_received :model_called
    end

    test "a provider that fails is :failed, and nothing of the audio or text is logged", %{
      ref: ref
    } do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => @words}})
      end)

      {result, events} = LogProbe.capture(fn -> transcribe(ref, "SECRET-AUDIO-BYTES") end)

      assert {:error, :failed} = result
      refute Enum.any?(events, &(&1 =~ "SECRET-AUDIO-BYTES" or &1 =~ @words))
    end

    test "money lands in the journal where the user's spending counts it", %{
      ref: ref,
      user: user,
      endpoint: endpoint
    } do
      model_hears(%{"text" => @words, "language" => "en"})
      assert {:ok, _} = transcribe(ref)

      cost = Decimal.new("0.0004")

      Repo.update_all(
        from(r in PhoenixKitAI.Request, where: r.endpoint_uuid == ^endpoint.uuid),
        set: [cost: cost]
      )

      assert %{day_micro_usd: 400} = Spend.for_users([user.uuid])[user.uuid]
    end
  end

  describe "before the paid call" do
    test "no speech model chosen is :speech_off", %{ref: ref} do
      {:ok, _} = Config.put_speech_endpoint(nil, [])
      model_not_called()

      assert {:error, :speech_off} = transcribe(ref)
      refute_received :model_called
    end

    test "a user who may not use the assistant is refused", %{} do
      outsider = user_with(["dashboard"], "outsider")
      {ref, _token} = session_fixture(outsider)
      model_not_called()

      assert {:error, :forbidden} = transcribe(ref)
      refute_received :model_called
    end

    test "a borrowed session is refused", %{ref: ref} do
      model_not_called()

      assert {:error, :impersonated} =
               Speech.transcribe(ref, "audio", "wav", impersonated: true)

      refute_received :model_called
    end

    test "an ended session is refused", %{user: user} do
      {ref, token} = session_fixture(user)
      PhoenixKit.Users.Auth.delete_user_session_token(token)
      model_not_called()

      assert {:error, :session_gone} = transcribe(ref)
      refute_received :model_called
    end

    test "a user over a limit is refused and nothing is paid", %{ref: ref, user: user} do
      Repo.insert!(%UserSettings{user_uuid: user.uuid, daily_cost_limit_micro_usd: 0})
      model_not_called()

      assert {:error, {:limit_reached, kind}} = transcribe(ref)
      assert kind == :daily_cost
      refute_received :model_called
    end

    test "a linked Telegram chat is a session too, if it holds agent.telegram" do
      user = user_with(["agent", "agent.telegram"], "tg")
      ref = telegram_link_fixture(user, UUIDv7.generate(), 4242)
      model_hears(%{"text" => @words, "language" => "en"})

      assert {:ok, @words} = Speech.transcribe(ref, "ogg-bytes", "ogg", impersonated: false)
    end

    test "a linked chat without agent.telegram is refused" do
      user = user_with(["agent"], "tg-no")
      ref = telegram_link_fixture(user, UUIDv7.generate(), 4243)
      model_not_called()

      assert {:error, :forbidden} =
               Speech.transcribe(ref, "ogg-bytes", "ogg", impersonated: false)

      refute_received :model_called
    end
  end

  describe "the AI module without transcribe/3" do
    defmodule NoSpeech do
    end

    test "voice is off", %{ref: ref} do
      Application.put_env(:phoenix_kit_agent, :speech_ai, NoSpeech)
      on_exit(fn -> Application.delete_env(:phoenix_kit_agent, :speech_ai) end)

      refute Config.speech?()
      assert {:error, :speech_off} = transcribe(ref)
    end
  end
end
