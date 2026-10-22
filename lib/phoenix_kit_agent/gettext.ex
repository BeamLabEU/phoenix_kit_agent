defmodule PhoenixKitAgent.Gettext do
  @moduledoc """
  Gettext backend of the agent module's admin pages and permission labels.
  """

  use Gettext.Backend, otp_app: :phoenix_kit_agent
end
