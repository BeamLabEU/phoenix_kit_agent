defmodule PhoenixKitAgent.Models do
  @moduledoc """
  The choice of a model for a user (spec §7.2). The module has no models of its
  own: the choice is among the endpoints of `phoenix_kit_ai` (an endpoint is a
  connection plus a model), and only endpoints that can chat.

  `list_endpoints/1` is the choice; `tools_support/1` says, per endpoint,
  whether its model takes tools — the assistant is useless on one that does
  not, so the screen marks those:

    * `:supported` / `:unsupported` — OpenRouter publishes the parameters of
      each model; `OpenRouterClient.model_supports_parameter?(model, "tools")`
      answers. One listing is fetched per connection (API key and base URL),
      however many endpoints use it;
    * `:unknown` — every other provider (`phoenix_kit_ai` has no capability
      listing for them), a model the listing does not name, and a listing that
      could not be fetched.

  `tools_support/1` makes network requests: call it off the LiveView process.
  """

  alias PhoenixKitAI.{Endpoint, OpenRouterClient}

  @typedoc "Whether a model takes tools."
  @type support :: :supported | :unsupported | :unknown

  @page_size 500

  @doc """
  The endpoints a user can be given: enabled ones that chat (not speech,
  embedding or image models), by name. `include: uuid` adds that endpoint even
  if it can no longer be picked — the one a user has now, so that saving the
  form does not drop it unnoticed.
  """
  @spec list_endpoints(keyword()) :: [Endpoint.t()]
  def list_endpoints(opts \\ []) do
    {endpoints, _total} = PhoenixKitAI.list_endpoints(enabled: true, page_size: @page_size)

    endpoints
    |> Enum.filter(&(Endpoint.kind(&1) == :chat))
    |> add_current(Keyword.get(opts, :include))
    |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.uuid})
  end

  @doc "Whether each endpoint's model takes tools (see the moduledoc): `%{endpoint_uuid => support}`."
  @spec tools_support([Endpoint.t()]) :: %{String.t() => support()}
  def tools_support(endpoints) do
    {openrouter, others} = Enum.split_with(endpoints, &openrouter?/1)

    unknown = Map.new(others, &{&1.uuid, :unknown})

    openrouter
    |> Enum.group_by(&connection/1)
    |> Enum.reduce(unknown, fn {connection, group}, acc ->
      Map.merge(acc, group_support(connection, group))
    end)
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp add_current(endpoints, uuid) when is_binary(uuid) do
    cond do
      Enum.any?(endpoints, &(&1.uuid == uuid)) -> endpoints
      current = PhoenixKitAI.get_endpoint(uuid) -> [current | endpoints]
      true -> endpoints
    end
  end

  defp add_current(endpoints, _none), do: endpoints

  defp openrouter?(%Endpoint{provider: provider}) when is_binary(provider),
    do: Endpoint.base_provider(provider) == "openrouter"

  defp openrouter?(_endpoint), do: false

  defp connection(endpoint) do
    {OpenRouterClient.resolve_api_key(endpoint), blank_to_nil(endpoint.base_url)}
  rescue
    _ -> :unresolved
  end

  defp group_support(connection, group) do
    case models(connection) do
      {:ok, models} ->
        Map.new(group, fn endpoint -> {endpoint.uuid, support(models, endpoint.model)} end)

      :error ->
        Map.new(group, &{&1.uuid, :unknown})
    end
  end

  defp models({api_key, base_url}) when is_binary(api_key) and api_key != "" do
    opts = if base_url, do: [base_url: base_url], else: []

    case OpenRouterClient.fetch_models(api_key, opts) do
      {:ok, models} -> {:ok, Map.new(models, &{&1.id, &1})}
      _failed -> :error
    end
  rescue
    # No part of the request goes to a log: a failed listing is "unknown".
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  defp models(_no_key), do: :error

  defp support(models, model_id) do
    case Map.fetch(models, model_id) do
      {:ok, model} ->
        if OpenRouterClient.model_supports_parameter?(model, "tools"),
          do: :supported,
          else: :unsupported

      :error ->
        :unknown
    end
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_none), do: nil
end
