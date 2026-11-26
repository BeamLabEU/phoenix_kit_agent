defmodule PhoenixKitAgent.Web.CSP do
  @moduledoc """
  The host's Content-Security-Policy nonce for the module's inline scripts
  (the runtime hooks of `PhoenixKitAgent.Web.Dock.Panel`).

  Core keeps the page's nonces in `PhoenixKitWeb.CSP`. The core versions this
  module supports include ones without it, so every call is feature-detected:
  on such a core `nonce/1` is `nil` (HEEx then renders no attribute, as
  before) and `on_mount/4` does nothing.
  """

  # Absent from the cores below the first release with CSP nonces, so it is
  # only ever called after `exported?/2`: the compiler is told not to
  # look for it.
  @compile {:no_warn_undefined, PhoenixKitWeb.CSP}
  @core PhoenixKitWeb.CSP

  @doc """
  The nonce of the current page for `kind`, or `nil` when the host set none
  or core cannot tell.
  """
  @spec nonce(:script | :style) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style] do
    if exported?(:nonce, 1) do
      case core().nonce(kind) do
        nonce when is_binary(nonce) and nonce != "" -> nonce
        _ -> nil
      end
    end
  end

  @doc """
  `on_mount` hook: restores the page's nonces in the LiveView's process.

  The chat panel is a nested LiveView (`live_render/3` from core's admin
  layout), a process of its own that skips the live session's `on_mount`;
  core hands the nonces over in the widget's session and this puts them back,
  so the scripts of a connected render carry the nonce of the document.
  """
  def on_mount(arg, params, session, socket) do
    if exported?(:on_mount, 4) do
      core().on_mount(arg, params, session, socket)
    else
      {:cont, socket}
    end
  end

  defp core, do: @core

  defp exported?(name, arity) do
    Code.ensure_loaded?(@core) and function_exported?(@core, name, arity)
  end
end
