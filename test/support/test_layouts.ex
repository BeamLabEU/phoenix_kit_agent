defmodule PhoenixKitAgent.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint: an HTML shell, the page
  title the admin layout would show, and the flash.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <h1 :if={assigns[:page_title]}>{@page_title}</h1>
    <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" role="alert">{msg}</div>
    <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error" role="alert">{msg}</div>
    {@inner_content}
    """
  end

  # Phoenix renders "<status>.html" from here when a LiveView raises on mount.
  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
