defmodule PhoenixKitAgent.Test.Hooks do
  @moduledoc """
  `on_mount` hook of the test endpoint: what core's admin `live_session` does
  for a signed-in user — `:phoenix_kit_current_scope` and
  `:phoenix_kit_current_user` on the socket — from a user uuid the test puts in
  the session (`PhoenixKitAgent.LiveCase.log_in/2`). The scope is the real one
  (`Scope.for_user/1`), so permission checks run as in production.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  def on_mount(:assign_scope, _params, session, socket) do
    case session["test_user_uuid"] && Auth.get_user(session["test_user_uuid"]) do
      %Auth.User{} = user ->
        {:cont,
         socket
         |> assign(:phoenix_kit_current_scope, Scope.for_user(user))
         |> assign(:phoenix_kit_current_user, user)}

      _ ->
        {:cont, socket}
    end
  end
end
