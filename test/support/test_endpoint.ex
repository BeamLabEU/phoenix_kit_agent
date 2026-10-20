defmodule PhoenixKitAgent.Test.Endpoint do
  @moduledoc """
  Minimal endpoint for `Phoenix.LiveViewTest`. In production the module runs
  in the host's endpoint and router.
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_agent

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_agent_test_key",
    signing_salt: "agent-test-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(PhoenixKitAgent.Test.Router)
end
