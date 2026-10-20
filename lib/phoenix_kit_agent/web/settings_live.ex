defmodule PhoenixKitAgent.Web.SettingsLive do
  @moduledoc """
  Settings → AI Agent: the module defaults (`PhoenixKitAgent.Config`) — the
  per-user limits a user without settings of their own gets, and the limits of
  one turn.

  Needs `agent.manage`. The tab is registered under that key; the page checks
  it again on mount and before every save, against the session's scope and
  against the user's current rights (a right taken away while the page is open
  stops the next save).
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitAgent.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.DecimalInput, only: [decimal_input: 1]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAgent.Config

  @manage "agent.manage"

  @impl true
  def mount(_params, _session, socket) do
    if may_manage?(socket) do
      {:ok,
       socket
       |> assign(
         page_title: gettext("AI Agent"),
         page_subtitle: gettext("Defaults of the AI assistant"),
         page_section: gettext("Settings"),
         page_section_path: Routes.path("/admin/settings")
       )
       |> assign_form(Config.defaults_changeset(%{}) |> Map.put(:action, nil))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to the AI assistant settings."))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    {:noreply, assign_form(socket, Config.defaults_changeset(params))}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    if may_manage?(socket) do
      save(socket, params)
    else
      {:noreply,
       put_flash(socket, :error, gettext("You do not have access to the AI assistant settings."))}
    end
  end

  defp save(socket, params) do
    case Config.save_defaults(params, actor_uuid: user_uuid(socket), source: "settings") do
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
    end
  end

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(changeset, as: :settings))

  # The session's scope (its active role) and the user as they are now: both
  # must hold the key.
  defp may_manage?(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    with %Scope{} <- scope,
         uuid when is_binary(uuid) <- user_uuid(socket),
         %Auth.User{} = user <- Auth.get_user(uuid) do
      Enum.all?([scope, Scope.for_user(user)], &Scope.can?(&1, @manage))
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %Scope{user: %{uuid: uuid}} -> uuid
      _ -> nil
    end
  end

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
    </div>
    """
  end
end
