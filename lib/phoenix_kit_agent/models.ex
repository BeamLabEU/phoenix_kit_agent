defmodule PhoenixKitAgent.Models do
  @moduledoc """
  The choice of a model for a user (spec §7.2). The module has no models of its
  own: the choice is among the endpoints of `phoenix_kit_ai` (an endpoint is a
  connection plus a model), and only endpoints that can chat.

  `list_endpoints/1` is the choice; `tools_support/1` says, per endpoint,
  whether its model takes tools — the assistant is useless on one that does
  not, so the screens mark those. `image_input_support/1` is the same question
  about images in; the attachments (spec §9) use it to decide whether a
  picture goes to the model as pixels or as a description. Both read
  `PhoenixKitAI.Capabilities.for_endpoint/1` — the provider's catalogue as
  `phoenix_kit_ai` keeps it, with what an admin declared on the endpoint where
  the catalogue says nothing — from its cache only, never the network:

    * `:supported` / `:unsupported` — the model is known to take it, or not;
    * `:unknown` — nobody knows: a provider without a catalogue whose
      endpoint declares nothing, a model the catalogue does not list, a
      catalogue not read yet.

  Only `:supported` lets pixels go to a model (`image_input/1`).

  `reports_cost?/2` says whether a call on an endpoint gets what it cost in
  the AI journal — the money limits count only such calls (spec §7.3).

  A user's own model of a task (`PhoenixKitAgent.UserConfig`) is judged twice
  over. `usable_uuids/1` is what a turn, a picture or a recording asks of the
  one a user already has: it can be called at all (it exists, is on, names a
  model, has a credential), so one that cannot is left for the default.
  `selection_check/2` and `selectable/1` are what a user's new choice must
  pass: the endpoint is on the list of those users may choose
  (`PhoenixKitAgent.Config.selectable_endpoint_uuids/0`), can be called, and
  fits the task's needs (`PhoenixKitAI.Tasks.check_selection/2`, as the
  default of that task does).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Integrations
  alias PhoenixKit.RepoHelper
  alias PhoenixKitAgent.Config
  alias PhoenixKitAI.{Capabilities, Endpoint, TaskLimits, Tasks}

  @typedoc "Whether a model takes tools."
  @type support :: :supported | :unsupported | :unknown

  @typedoc """
  What a page shows of an endpoint: never the endpoint itself, which carries
  its API key. `reports_cost?` is `reports_cost?/2` of a chat call on it and
  `costs` the same for each kind of call; `enabled?` is whether the endpoint is on.
  """
  @type summary :: %{
          uuid: String.t(),
          name: String.t(),
          model: String.t(),
          provider: String.t(),
          reports_cost?: boolean(),
          costs: %{call_kind() => boolean()},
          enabled?: boolean()
        }

  @typedoc """
  What a call on an endpoint is: a model call of a turn, or a picture
  described by the vision model.
  """
  @type call_kind :: :chat | :vision | :speech

  @typedoc "Why a model is not one a user may choose for a task."
  @type selection_refusal ::
          :not_allowed | :unusable | {:model_unfit | :model_unverified, [atom()]}

  # The AI task each of a user's three models is judged against.
  @tasks %{chat: "agent.chat", vision: "agent.attachment", speech: "agent.speech"}

  # What `reports_cost?/2` reads of an endpoint, its key left out.
  @cost_fields [:uuid, :name, :model, :provider, :base_url, :provider_settings, :enabled]

  @kinds [:chat, :vision, :speech]

  @page_size 500

  @doc """
  The endpoints a user can be given: enabled ones that chat (not speech,
  embedding or image models), by name. `include: uuid` (or a list of uuids)
  adds that endpoint even if it can no longer be picked — the one a user has
  now, so that saving the form does not drop it unnoticed.
  """
  @spec list_endpoints(keyword()) :: [Endpoint.t()]
  def list_endpoints(opts \\ []) do
    {endpoints, _total} = PhoenixKitAI.list_endpoints(enabled: true, page_size: @page_size)

    endpoints
    |> Enum.filter(&(Endpoint.kind(&1) == :chat))
    |> add_current(opts |> Keyword.get(:include) |> List.wrap())
    |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.uuid})
  end

  @doc "The key of the AI task a model of this kind is judged against (`agent.chat`, …)."
  @spec task_of(call_kind()) :: String.t()
  def task_of(kind), do: Map.fetch!(@tasks, kind)

  @doc """
  Which of these endpoint uuids can be called at all (see the moduledoc), as a
  set. One read, whatever the number; a uuid that is not an endpoint is not in it.
  """
  @spec usable_uuids([String.t()]) :: MapSet.t(String.t())
  def usable_uuids([]), do: MapSet.new()

  def usable_uuids(uuids) when is_list(uuids) do
    from(e in Endpoint, where: e.uuid in ^Enum.uniq(uuids))
    |> RepoHelper.repo().all()
    |> Enum.filter(&callable?/1)
    |> MapSet.new(& &1.uuid)
  end

  @doc """
  Whether `uuid` is one a user may choose for a task of `kind` now: `:ok`, or
  why not — `:not_allowed` (not on the list of what users may choose, or no
  such endpoint), `:unusable` (cannot be called), `{:model_unfit, missing}` /
  `{:model_unverified, unclear}` (does not fit the task, or nobody knows).
  """
  @spec selection_check(call_kind(), term()) :: :ok | {:error, selection_refusal()}
  def selection_check(kind, uuid) when is_binary(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         true <- uuid in Config.selectable_endpoint_uuids(),
         %Endpoint{} = endpoint <- PhoenixKitAI.get_endpoint(uuid) do
      check_fit(kind, endpoint)
    else
      _not_allowed -> {:error, :not_allowed}
    end
  end

  def selection_check(_kind, _other), do: {:error, :not_allowed}

  defp check_fit(kind, endpoint) do
    if callable?(endpoint) do
      case Tasks.check_selection(task_of(kind), endpoint) do
        :ok ->
          :ok

        {:error, {reason, _needs}} = refusal when reason in [:model_unfit, :model_unverified] ->
          refusal

        {:error, _other} ->
          {:error, :unusable}
      end
    else
      {:error, :unusable}
    end
  end

  @doc """
  The endpoints a user is offered for a task of `kind`: those of the list users
  may choose from that pass `selection_check/2`, as `t:summary/0`, by name.
  """
  @spec selectable(call_kind()) :: [summary()]
  def selectable(kind) do
    uuids = Config.selectable_endpoint_uuids()

    from(e in Endpoint, where: e.uuid in ^uuids)
    |> RepoHelper.repo().all()
    |> Enum.filter(&(check_fit(kind, &1) == :ok))
    |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.uuid})
    |> Enum.map(&summary/1)
  end

  @doc "An endpoint as a page keeps it (`t:summary/0`)."
  @spec summary(Endpoint.t()) :: summary()
  def summary(%Endpoint{} = endpoint) do
    costs = Map.new(@kinds, &{&1, reports_cost?(endpoint, &1)})

    %{
      uuid: endpoint.uuid,
      name: endpoint.name,
      model: endpoint.model,
      provider: endpoint.provider,
      reports_cost?: costs.chat,
      costs: costs,
      enabled?: endpoint.enabled != false
    }
  end

  @doc """
  The endpoints with these uuids as `t:summary/0`: `%{uuid => summary}`. A value
  that is not a uuid names no endpoint.
  """
  @spec summaries([term()]) :: %{String.t() => summary()}
  def summaries(uuids) when is_list(uuids) do
    valid =
      for uuid <- uuids,
          is_binary(uuid),
          {:ok, uuid} <- [Ecto.UUID.cast(uuid)],
          uniq: true,
          do: uuid

    from(e in Endpoint, where: e.uuid in ^valid, select: struct(e, ^@cost_fields))
    |> RepoHelper.repo().all()
    |> Map.new(&{&1.uuid, summary(&1)})
  end

  @doc """
  `tools_support/1` for the endpoints with these uuids, read again from the
  database (one that is gone is left out).
  """
  @spec tools_support_of([String.t()]) :: %{String.t() => support()}
  def tools_support_of(uuids) when is_list(uuids) do
    from(e in Endpoint, where: e.uuid in ^Enum.uniq(uuids))
    |> RepoHelper.repo().all()
    |> tools_support()
  end

  @doc """
  `image_input_support/1` for the endpoints with these uuids, read again from
  the database (one that is gone is left out).
  """
  @spec image_input_support_of([String.t()]) :: %{String.t() => support()}
  def image_input_support_of(uuids) when is_list(uuids) do
    from(e in Endpoint, where: e.uuid in ^Enum.uniq(uuids))
    |> RepoHelper.repo().all()
    |> image_input_support()
  end

  @doc """
  `audio_input_support/1` for the endpoints with these uuids, read again from
  the database (one that is gone is left out).
  """
  @spec audio_input_support_of([String.t()]) :: %{String.t() => support()}
  def audio_input_support_of(uuids) when is_list(uuids) do
    from(e in Endpoint, where: e.uuid in ^Enum.uniq(uuids))
    |> RepoHelper.repo().all()
    |> audio_input_support()
  end

  @doc "Whether each endpoint's model takes tools (see the moduledoc): `%{endpoint_uuid => support}`."
  @spec tools_support([Endpoint.t()]) :: %{String.t() => support()}
  def tools_support(endpoints), do: capability(endpoints, :tools)

  @doc """
  Whether each endpoint's model takes images as input (see the moduledoc):
  `%{endpoint_uuid => support}`. A model that can only produce images does not.
  """
  @spec image_input_support([Endpoint.t()]) :: %{String.t() => support()}
  def image_input_support(endpoints), do: capability(endpoints, :vision)

  @doc """
  Whether each endpoint's model takes audio as input (see the moduledoc):
  `%{endpoint_uuid => support}`.
  """
  @spec audio_input_support([Endpoint.t()]) :: %{String.t() => support()}
  def audio_input_support(endpoints), do: capability(endpoints, :audio_input)

  @doc """
  `image_input_support/1` for the one endpoint with this uuid, read again from
  the database. `:unknown` for no endpoint (`nil`) and for one that does not
  exist.
  """
  @spec image_input(String.t() | nil) :: support()
  def image_input(endpoint_uuid) when is_binary(endpoint_uuid) do
    case PhoenixKitAI.get_endpoint(endpoint_uuid) do
      %Endpoint{} = endpoint ->
        endpoint |> List.wrap() |> image_input_support() |> Map.fetch!(endpoint.uuid)

      _none ->
        :unknown
    end
  end

  def image_input(_none), do: :unknown

  defp capability(endpoints, flag),
    do: Map.new(endpoints, &{&1.uuid, &1 |> Capabilities.for_endpoint() |> support(flag)})

  defp support(%Capabilities{} = caps, flag), do: flag_support(caps, flag)
  defp support(:unknown, _flag), do: :unknown

  @doc false
  # What one flag of the capabilities says. A flag the `phoenix_kit_ai` at hand
  # does not know (`audio_input` before its first release with it) is `:unknown`,
  # never a crash that would take the other flags with it.
  @spec flag_support(map(), atom()) :: support()
  def flag_support(caps, flag) do
    case Map.get(caps, flag) do
      :yes -> :supported
      :no -> :unsupported
      _unknown_or_absent -> :unknown
    end
  end

  @doc """
  Whether a call on the endpoint gets what it cost in the AI journal, as
  `phoenix_kit_ai` prices it. On an endpoint where it does not, money is not
  counted and only the turn limit applies.

    * `:chat` (a model call of a turn) — `PhoenixKitAI.reports_cost?/1`: the
      provider reports the cost (OpenRouter), or the operator's catalogue, a
      manual price on the endpoint or Anthropic's list price prices its model.
    * `:vision` (a picture described, `PhoenixKitAI.describe_image/3`) —
      `PhoenixKitAI.TaskLimits.money_counted?/2` with `:vision`, which is the
      chat rule: `phoenix_kit_ai` prices a description like a chat call (the
      provider's cost, a catalogue, a manual or a list price).
    * `:speech` (a recording written down, `PhoenixKitAI.transcribe/3`) — the
      same rule (`TaskLimits.money_counted?/2` with `:audio_input`).

  A `t:summary/0` carries the answer for each kind (`costs`). The answer is the
  one a call is limited by (`PhoenixKitAgent.Limits`): `phoenix_kit_ai` has no
  third answer such as "not known"; a price source that is not loaded (a
  catalogue not read yet) counts as no price, as it does for the limit.
  """
  @spec reports_cost?(Endpoint.t() | summary() | nil, call_kind()) :: boolean()
  def reports_cost?(endpoint, call \\ :chat)

  def reports_cost?(%Endpoint{} = endpoint, :chat), do: PhoenixKitAI.reports_cost?(endpoint)

  def reports_cost?(%Endpoint{} = endpoint, :vision),
    do: TaskLimits.money_counted?(endpoint, [:vision])

  def reports_cost?(%Endpoint{} = endpoint, :speech),
    do: TaskLimits.money_counted?(endpoint, [:audio_input])

  def reports_cost?(%{costs: costs}, call) when is_map_key(costs, call),
    do: Map.fetch!(costs, call)

  def reports_cost?(%{reports_cost?: reports?}, :chat) when is_boolean(reports?), do: reports?

  def reports_cost?(_endpoint, _call), do: false

  # ── internals ─────────────────────────────────────────────────────────

  # Can a call be made on it at all: the checks a call itself starts with
  # (`PhoenixKitAI`'s own are private): on, a model named, and a credential — an
  # integration, the provider's, or the endpoint's own key.
  defp callable?(%Endpoint{} = endpoint) do
    endpoint.enabled != false and Endpoint.kind(endpoint) == :chat and
      present?(endpoint.model) and credential?(endpoint)
  end

  defp credential?(endpoint) do
    present?(endpoint.api_key) or connected?(endpoint.integration_uuid) or
      connected?(endpoint.provider)
  end

  # Through the cache `PhoenixKitAI` itself asks (a settings read and a decrypt
  # otherwise), so the answer is the one a call would get, and `effective/1`,
  # which asks on every turn, does not pay for it each time.
  defp connected?(key) do
    present?(key) and
      match?(
        {:ok, _credentials},
        PhoenixKitAI.Cache.credentials(key, fn -> Integrations.get_credentials(key) end)
      )
  end

  defp present?(text), do: is_binary(text) and text != ""

  defp add_current(endpoints, uuids) do
    Enum.reduce(uuids, endpoints, fn
      uuid, acc when is_binary(uuid) ->
        cond do
          Enum.any?(acc, &(&1.uuid == uuid)) -> acc
          current = PhoenixKitAI.get_endpoint(uuid) -> [current | acc]
          true -> acc
        end

      _none, acc ->
        acc
    end)
  end
end
