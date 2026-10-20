defmodule PhoenixKitAgent.Web.SettingsLive do
  @moduledoc """
  Settings → AI Agent: the module defaults (`PhoenixKitAgent.Config`) — the
  per-user limits a user without settings of their own gets, and the limits of
  one turn.

  Needs `agent.manage`. The tab is registered under that key; the page checks
  it again on mount and before every save, against the socket's scope and
  against the scope of the session as it is now — the role it acts as, not the
  user's default one (`PhoenixKitAgent.Web.Access`): a right taken away, a
  switch to another role or a logout while the page is open stops the next
  save.

  When the default model does not report what a call costs
  (`PhoenixKitAgent.Models.reports_cost?/1`), the limits say that money is not
  counted for it and only the turn limit applies.

  One setting is not for every manager: `agent_capture_ai_content` (whether the
  bodies of the assistant's requests go to the AI journal, where every holder of
  `ai` reads them on `/admin/ai/usage`) is switched by an Owner only. The check
  is `Scope.owner?/1` in the `save_capture` handler, on every event — the tab is
  only gated by `agent.manage`, which an Admin holds — and the switch is not
  rendered for anyone else, who sees the state.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitAgent.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Checkbox, only: [checkbox: 1]
  import PhoenixKitWeb.Components.Core.DecimalInput, only: [decimal_input: 1]

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAgent.{Config, Models}
  alias PhoenixKitAgent.Web.Access

  @impl true
  def mount(_params, session, socket) do
    socket = Access.assign_session(socket, session)

    if Access.may_manage?(socket) do
      {:ok,
       socket
       |> assign(
         page_title: gettext("AI Agent"),
         page_subtitle: gettext("Defaults of the AI assistant"),
         page_section: gettext("Settings"),
         page_section_path: Routes.path("/admin/settings")
       )
       |> assign(money_off?: money_off?())
       |> assign_capture()
       |> assign_form(Config.defaults_changeset(%{}) |> Map.put(:action, nil))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to the AI assistant settings."))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) when is_map(params) do
    {:noreply, assign_form(socket, Config.defaults_changeset(params))}
  end

  def handle_event("save", %{"settings" => params}, socket) when is_map(params) do
    if Access.may_manage?(socket) do
      save(socket, params)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have access to the AI assistant settings."))}
    end
  end

  def handle_event("save_capture", %{"capture" => %{"enabled" => enabled}}, socket)
      when enabled in ["true", "false"] do
    if Access.owner?(socket) and Access.may_manage?(socket) do
      save_capture(socket, enabled == "true")
    else
      {:noreply,
       socket
       |> assign_capture()
       |> put_flash(:error, gettext("Only an Owner can change this setting."))}
    end
  end

  # A crafted event without the form's fields.
  def handle_event(event, _params, socket) when event in ["validate", "save", "save_capture"],
    do: {:noreply, socket}

  defp save(socket, params) do
    case Config.save_defaults(params, actor_uuid: Access.user_uuid(socket), source: "settings") do
      {:ok, _keys} ->
        {:noreply,
         socket
         |> assign_form(Config.defaults_changeset(%{}) |> Map.put(:action, nil))
         |> put_flash(:info, gettext("AI assistant defaults saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_form(changeset)
         |> put_flash(:error, gettext("Nothing was saved: check the highlighted fields."))}

      {:error, :not_saved} ->
        {:noreply,
         socket
         |> assign_form(Config.defaults_changeset(params))
         |> put_flash(:error, gettext("The defaults could not be saved. Nothing was changed."))}
    end
  end

  defp save_capture(socket, value) do
    case Config.put_capture_ai_content(value,
           actor_uuid: Access.user_uuid(socket),
           source: "settings"
         ) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> assign_capture()
         |> put_flash(:info, gettext("AI request journal setting saved."))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign_capture()
         |> put_flash(:error, gettext("The setting could not be saved. Nothing was changed."))}
    end
  end

  # What the capture section shows: the stored state, and whether this person
  # may change it.
  defp assign_capture(socket) do
    assign(socket, capture?: Config.capture_ai_content?(), owner?: Access.owner?(socket))
  end

  # Whether the default model leaves money uncounted (no default: nothing to say).
  defp money_off? do
    with uuid when is_binary(uuid) <- Config.default_endpoint_uuid(),
         %{} = endpoint <- PhoenixKitAI.get_endpoint(uuid) do
      not Models.reports_cost?(endpoint)
    else
      _none -> false
    end
  end

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(changeset, as: :settings))

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full max-w-3xl gap-6 px-4 py-6">
      <.form for={@form} id="agent-settings-form" phx-change="validate" phx-submit="save">
        <section class="card bg-base-100 shadow-sm">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">{gettext("Default limits per user")}</h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Apply to every user without limits of their own. Money is counted from the AI request journal, in US dollars, for endpoints that report a cost."
              )}
            </p>
            <p :if={@money_off?} id="agent-settings-money-off" class="text-sm text-warning">
              {gettext(
                "The default model does not report what a call costs: money is not counted, only the turn limit applies."
              )}
            </p>
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.decimal_input
                field={@form[:daily_cost_limit_usd]}
                label={gettext("Spending per day")}
                unit="$"
              />
              <.decimal_input
                field={@form[:monthly_cost_limit_usd]}
                label={gettext("Spending per month")}
                unit="$"
              />
              <.decimal_input field={@form[:daily_turn_limit]} label={gettext("Turns per day")} />
              <.decimal_input
                field={@form[:max_attachment_mb]}
                label={gettext("Largest attachment")}
                unit="MB"
              />
              <.decimal_input
                field={@form[:max_attachments_per_message]}
                label={gettext("Attachments per message")}
              />
            </div>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm mt-6">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">{gettext("One turn")}</h2>
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.decimal_input
                field={@form[:max_tool_rounds]}
                label={gettext("Tool rounds per turn")}
              />
              <.decimal_input
                field={@form[:turn_deadline_s]}
                label={gettext("Turn deadline")}
                unit="s"
              />
              <.decimal_input
                field={@form[:history_chars]}
                label={gettext("History sent to the model, characters")}
              />
              <.decimal_input
                field={@form[:tool_result_chars]}
                label={gettext("One tool result, characters")}
              />
            </div>
          </div>
        </section>

        <div class="mt-6 flex justify-end">
          <.button type="submit" variant="primary" id="agent-settings-save">
            {gettext("Save")}
          </.button>
        </div>
      </.form>

      <section id="agent-capture" class="card bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="card-title text-base">{gettext("Request content in the AI journal")}</h2>
          <p id="agent-capture-note" class="text-sm text-base-content/70">
            {gettext(
              "When on, the full text of the assistant's requests and answers, with the data its tools returned, is written to the AI request journal, where everyone who holds the AI permission can read it on the AI usage page (/admin/ai/usage). When off, the journal keeps only the counts and the cost."
            )}
          </p>
          <.form
            :if={@owner?}
            for={%{}}
            as={:capture}
            id="agent-capture-form"
            phx-submit="save_capture"
            class="flex items-center justify-between gap-4"
          >
            <.checkbox
              variant="toggle"
              id="agent-capture-enabled"
              name="capture[enabled]"
              checked={@capture?}
              label={gettext("Write request content to the AI journal")}
            />
            <.button type="submit" variant="primary" id="agent-capture-save">
              {gettext("Save")}
            </.button>
          </.form>
          <p :if={!@owner?} id="agent-capture-status" class="text-sm">
            <span class={["badge", if(@capture?, do: "badge-warning", else: "badge-ghost")]}>
              {if @capture?, do: gettext("On"), else: gettext("Off")}
            </span>
            {gettext("Only an Owner can change this setting.")}
          </p>
        </div>
      </section>
    </div>
    """
  end
end
