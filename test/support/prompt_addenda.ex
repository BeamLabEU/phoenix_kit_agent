defmodule PhoenixKitAgent.Test.Addenda do
  @moduledoc """
  Host prompt addenda for the tests (`config :phoenix_kit_agent, prompt_addendum:
  {Mod, :fun}`, spec §7.1 point 2): one per shape the contract allows or
  refuses.

  `with_context/1` sends the context it got to the process in
  `Application.get_env(:phoenix_kit_agent, :test_addendum_listener)`.
  """

  def plain, do: "HOST-ADDENDUM-PLAIN"

  def with_context(ctx) do
    send(Application.get_env(:phoenix_kit_agent, :test_addendum_listener), {:addendum_ctx, ctx})
    "HOST-ADDENDUM-CTX"
  end

  def nothing, do: nil
  def blank, do: "   \n"
  def raises, do: raise("addendum boom SECRET-ADDENDUM-TEXT")
  def raises_with_context(_ctx), do: raise("addendum boom SECRET-ADDENDUM-TEXT")
  def exits, do: exit(:addendum_exit)
  def not_a_string, do: 42
end
