defmodule PhoenixKitAgent.Web.SpendingLive do
  @moduledoc """
  Admin → Agent → Spending: what every user spent on the assistant today and
  this month, and how many turns they started today — everyone who used it
  this month, also a user who no longer holds `agent`. Money comes from the AI
  request journal (`PhoenixKitAgent.Spend`, micro-dollars shown as dollars;
  only endpoints that report a cost add to it), in the day and month of the
  site time zone.

  Needs `agent.manage`: the tab is registered under that key and the page
  checks it again on mount (`PhoenixKitAgent.Web.Access`). It has no events.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitAgent.Gettext

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAgent.Spend
  alias PhoenixKitAgent.Web.Access

  @impl true
  def mount(_params, session, socket) do
    socket = Access.assign_session(socket, session)

    if Access.may_manage?(socket) do
      {:ok,
       socket
       |> assign(
         page_title: gettext("Spending"),
         page_subtitle: gettext("What the AI assistant cost, by user"),
         page_section: gettext("AI Agent"),
         page_section_path: Routes.path("/admin/agent/spending")
       )
       |> load(DateTime.utc_now())}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to the AI assistant spending."))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  defp load(socket, now) do
    uuids = Spend.users_this_month(now)
    money = Spend.for_users(uuids, now)
    turns = Spend.turns_today(uuids, now)

    emails =
      from(u in User, where: u.uuid in ^uuids, select: {u.uuid, u.email})
      |> RepoHelper.repo().all()
      |> Map.new()

    rows =
      uuids
      |> Enum.filter(&Map.has_key?(emails, &1))
      |> Enum.map(fn uuid ->
        %{
          uuid: uuid,
          email: Map.fetch!(emails, uuid),
          day: money[uuid].day_micro_usd,
          month: money[uuid].month_micro_usd,
          turns: turns[uuid]
        }
      end)
      |> Enum.sort_by(&{-&1.month, &1.email})

    assign(socket,
      rows: rows,
      periods: Spend.period_keys(now),
      total_day: rows |> Enum.map(& &1.day) |> Enum.sum(),
      total_month: rows |> Enum.map(& &1.month) |> Enum.sum()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full max-w-5xl gap-6 px-4 py-6">
      <section class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="text-sm text-base-content/60">
              {gettext("Today")} · {@periods.day}
            </div>
            <div id="agent-spending-total-day" class="text-2xl font-semibold tabular-nums">
              ${Spend.format_usd(@total_day)}
            </div>
          </div>
        </div>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="text-sm text-base-content/60">
              {gettext("This month")} · {@periods.month}
            </div>
            <div id="agent-spending-total-month" class="text-2xl font-semibold tabular-nums">
              ${Spend.format_usd(@total_month)}
            </div>
          </div>
        </div>
      </section>

      <section class="card bg-base-100 shadow-sm">
        <div class="overflow-x-auto">
          <table id="agent-spending" class="table">
            <thead>
              <tr>
                <th>{gettext("User")}</th>
                <th class="text-right">{gettext("Today")}</th>
                <th class="text-right">{gettext("This month")}</th>
                <th class="text-right">{gettext("Turns today")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@rows == []} id="agent-spending-empty">
                <td colspan="4" class="text-center text-base-content/60">
                  {gettext("Nobody used the assistant this month.")}
                </td>
              </tr>
              <tr :for={row <- @rows} id={"agent-spending-#{row.uuid}"}>
                <td class="font-medium">{row.email}</td>
                <td id={"agent-spending-#{row.uuid}-day"} class="text-right tabular-nums">
                  ${Spend.format_usd(row.day)}
                </td>
                <td id={"agent-spending-#{row.uuid}-month"} class="text-right tabular-nums">
                  ${Spend.format_usd(row.month)}
                </td>
                <td id={"agent-spending-#{row.uuid}-turns"} class="text-right tabular-nums">
                  {row.turns}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end
end
