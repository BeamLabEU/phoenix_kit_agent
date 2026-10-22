defmodule PhoenixKitAgent.Web.Access do
  @moduledoc """
  The permission checks of the module's admin pages, made again on every event.

  A LiveView keeps the scope it got at mount, so a role taken away while the
  page is open, a switch to another role or a logout would still read as the
  rights of the mount. Each check here asks for two scopes and passes only if
  both hold:

    * the socket's (`:phoenix_kit_current_scope`, set by core's `on_mount`);
    * the scope of the **session** as it is now
      (`PhoenixKit.Users.Auth.SessionRef.scope_for_session/2`): the session
      must still be live, its user active and confirmed, and the scope is
      narrowed to the role the session acts as — not the user's default role.

  The page calls `assign_session/2` in its `mount/3`. The session reference is
  read from the signed session only in the connected mount; the static render
  has none and is checked against the socket's scope alone, which core's
  `on_mount` has just built from this session. A connected page without a
  live session is refused everything.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth.{Scope, SessionRef}

  @manage "agent.manage"

  @doc """
  Keeps the reference of the session the page runs in (see the moduledoc):
  read from `session` in the connected mount, `nil` in the static render.
  """
  @spec assign_session(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_session(socket, session) do
    ref =
      with true <- Phoenix.LiveView.connected?(socket),
           {:ok, ref} <- SessionRef.from_session(session) do
        ref
      else
        _none -> nil
      end

    assign(socket, :agent_session_ref, ref)
  end

  @doc "Whether the signed-in session holds `agent.manage` now (see the moduledoc)."
  @spec may_manage?(Phoenix.LiveView.Socket.t()) :: boolean()
  def may_manage?(socket), do: all_scopes?(socket, &Scope.can?(&1, @manage))

  @doc "Whether the signed-in session is an Owner's now (see the moduledoc)."
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
  The scope of the session as it is now (`nil` if it can no longer act, see
  the moduledoc): what a context function that checks a permission itself is
  given.
  """
  @spec session_scope(Phoenix.LiveView.Socket.t()) :: Scope.t() | nil
  def session_scope(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: live_session_scope(socket),
      else: socket.assigns[:phoenix_kit_current_scope]
  end

  defp live_session_scope(socket) do
    with {token_uuid, _user_uuid} <- socket.assigns[:agent_session_ref],
         uuid when is_binary(uuid) <- user_uuid(socket),
         {:ok, %Scope{} = scope} <- SessionRef.scope_for_session(token_uuid, uuid) do
      scope
    else
      _gone -> nil
    end
  rescue
    _db_error -> nil
  end

  defp all_scopes?(socket, check) do
    with %Scope{} = scope <- socket.assigns[:phoenix_kit_current_scope],
         %Scope{} = now <- session_scope(socket) do
      Enum.all?([scope, now], check)
    else
      _ -> false
    end
  end
end
