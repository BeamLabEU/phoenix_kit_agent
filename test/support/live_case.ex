defmodule PhoenixKitAgent.LiveCase do
  @moduledoc """
  Test case for LiveView tests: the test endpoint, `Phoenix.LiveViewTest`, the
  SQL sandbox and the fixtures. Tagged `:integration`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitAgent.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitAgent.Fixtures
      import PhoenixKitAgent.LiveCase

      alias PhoenixKitAgent.Test.Repo
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitAgent.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})}
  end

  @doc "Signs `user` in for the test hook (`PhoenixKitAgent.Test.Hooks`)."
  def log_in(conn, user), do: Plug.Test.init_test_session(conn, %{"test_user_uuid" => user.uuid})
end
