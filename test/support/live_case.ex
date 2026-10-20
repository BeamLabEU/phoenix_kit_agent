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
  alias PhoenixKit.Users.{ActiveRole, Auth}
  alias PhoenixKitAgent.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})}
  end

  @doc """
  Signs `user` in with a real browser session (`PhoenixKitAgent.Fixtures.session_fixture/1`):
  its token goes into the session as core's login puts it there, for the test hook
  (`PhoenixKitAgent.Test.Hooks`) and for the pages that read the session reference.
  Returns the conn; `log_in_session/2` also returns the token.
  """
  def log_in(conn, user), do: conn |> log_in_session(user) |> elem(0)

  @doc """
  Makes the session of `token` act as `role` (core's role switcher, which must
  be on: `role_switcher_enabled`).
  """
  def act_as(token, role) do
    user = Auth.get_user_by_session_token(token)
    {:ok, _} = ActiveRole.switch(user, token, role.uuid)
    :ok
  end

  @doc "`log_in/2`, and the raw session token (to switch its role or revoke it with)."
  def log_in_session(conn, user) do
    {_ref, token} = PhoenixKitAgent.Fixtures.session_fixture(user)
    {Plug.Test.init_test_session(conn, %{"user_token" => token}), token}
  end
end
