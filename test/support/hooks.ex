defmodule PhoenixKitAgent.Test.Hooks do
  @moduledoc """
  `on_mount` hook of the test endpoint: what core's admin `live_session` does
  for a signed-in user — `:phoenix_kit_current_scope` and
  `:phoenix_kit_current_user` on the socket — from the session token the test
  puts in the session (`PhoenixKitAgent.LiveCase.log_in/2`). Like core, the
  user is loaded through the token (`Auth.get_user_by_session_token/1`), so the
  scope is narrowed to the role the session acts as, and permission checks run
  as in production. A session that names a user by uuid only
  (`"test_user_uuid"`) gets that user's default role.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  def on_mount(:assign_scope, _params, session, socket) do
    # Core's locale hook puts the path's language on the process; a test names it.
    if locale = session["locale"] do
      Gettext.put_locale(PhoenixKitAgent.Gettext, locale)
      Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    end

    case user(session) do
      %Auth.User{} = user ->
        {:cont,
         socket
         |> assign(:phoenix_kit_current_scope, Scope.for_user(user))
         |> assign(:phoenix_kit_current_user, user)}

      _ ->
        {:cont, socket}
    end
  end

  defp user(%{"user_token" => token}) when is_binary(token),
    do: Auth.get_user_by_session_token(token)

  defp user(%{"test_user_uuid" => uuid}) when is_binary(uuid), do: Auth.get_user(uuid)
  defp user(_session), do: nil
end
