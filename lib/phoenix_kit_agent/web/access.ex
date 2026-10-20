defmodule PhoenixKitAgent.Web.Access do
  @moduledoc """
  The permission checks of the module's admin pages, made again on every event.

  A LiveView keeps the scope it got at mount, so a role taken away while the
  page is open would still read as held. Each check here asks for two scopes —
  the socket's (which carries the role the session acts as) and one rebuilt
  from the user as they are now — and passes only if both hold.
  """

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @manage "agent.manage"

  @doc "Whether the signed-in user holds `agent.manage` now (see the moduledoc)."
  @spec may_manage?(Phoenix.LiveView.Socket.t()) :: boolean()
  def may_manage?(socket), do: all_scopes?(socket, &Scope.can?(&1, @manage))

  @doc "Whether the signed-in user is an Owner now (see the moduledoc)."
  @spec owner?(Phoenix.LiveView.Socket.t()) :: boolean()
  def owner?(socket), do: all_scopes?(socket, &Scope.owner?/1)

  @doc "The uuid of the signed-in user, or `nil`."
  @spec user_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %Scope{user: %{uuid: uuid}} -> uuid
      _ -> nil
    end
  end

  @doc """
  The scope of the signed-in user rebuilt from the database (`nil` if they are
  gone): what a context function that checks a permission itself is given.
  """
  @spec fresh_scope(Phoenix.LiveView.Socket.t()) :: Scope.t() | nil
  def fresh_scope(socket) do
    with uuid when is_binary(uuid) <- user_uuid(socket),
         %Auth.User{} = user <- Auth.get_user(uuid) do
      Scope.for_user(user)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp all_scopes?(socket, check) do
    with %Scope{} = scope <- socket.assigns[:phoenix_kit_current_scope],
         %Scope{} = fresh <- fresh_scope(socket) do
      Enum.all?([scope, fresh], check)
    else
      _ -> false
    end
  end
end
