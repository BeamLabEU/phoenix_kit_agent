defmodule PhoenixKitAgent.Test.DockHostLive do
  @moduledoc """
  An admin page of the test endpoint that renders the chat panel the way
  core's admin layout does: `live_render/3`, `sticky: true`, the widget's id
  and the session its session function builds from the page's assigns
  (`PhoenixKitAgent.header_widget_session/1`). The session carries no token:
  the panel finds its session itself (the cookie session LiveView merges in).
  """

  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    assigns =
      assign(
        assigns,
        :dock_session,
        PhoenixKitAgent.header_widget_session(%{
          phoenix_kit_current_scope: assigns[:phoenix_kit_current_scope],
          phoenix_kit_current_user: assigns[:phoenix_kit_current_user],
          current_locale_base: "en",
          impersonating?: false
        })
      )

    ~H"""
    <div id="dock-host-page">
      {live_render(@socket, PhoenixKitAgent.Web.Dock,
        id: "pk-agent-dock-widget",
        sticky: true,
        session: @dock_session
      )}
    </div>
    """
  end
end
