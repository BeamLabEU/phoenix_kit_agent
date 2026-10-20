defmodule PhoenixKitAgent.Test.Router do
  @moduledoc """
  Minimal router of the LiveView tests, at the paths the module's tabs get in
  a host (`PhoenixKit.Utils.Routes.path/1` writes admin paths with the default
  locale, `/en/admin/...`).
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitAgent.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/settings", PhoenixKitAgent.Web do
    pipe_through(:browser)

    live_session :agent_test,
      layout: {PhoenixKitAgent.Test.Layouts, :app},
      on_mount: {PhoenixKitAgent.Test.Hooks, :assign_scope} do
      live("/agent", SettingsLive, :index)
    end
  end
end
