defmodule PhoenixKitAgent.Spend do
  @moduledoc """
  What users spent on the assistant (spec §7.3), counted from the AI request
  journal (`phoenix_kit_ai_requests`) rather than from the module's own
  messages: a row of the user (`user_uuid`) whose `metadata.source` is
  `"agent"` — every model call of the module passes both, so a call that
  describes an attachment is counted too. The journal is not pruned by age, so
  the month never loses rows. The cost is in micro-dollars ($1 = 1_000_000;
  `cost_cents` of the journal, whatever its name says), and only endpoints that
  report a cost add to it.

  The windows are calendar days and months in the **site time zone**
  (Settings → `time_zone`; `PhoenixKit.Utils.TimeZone`), each from its local
  midnight to the next one — so a day that has 23 or 25 hours is counted right.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitAI.Request

  @typedoc "Half-open: from the first instant, up to but not including the second."
  @type window :: {DateTime.t(), DateTime.t()}

  @type spent :: %{day_micro_usd: non_neg_integer(), month_micro_usd: non_neg_integer()}

  @doc "The local day and month that contain `now`, as UTC windows."
  @spec windows(DateTime.t()) :: %{day: window(), month: window()}
  def windows(now \\ DateTime.utc_now()) do
    zone = Settings.get_setting("time_zone", "0")
    today = TimeZone.local_date(now, zone)
    first = Date.beginning_of_month(today)

    %{
      day: {TimeZone.date_start(today, zone), TimeZone.date_start(Date.add(today, 1), zone)},
      month: {
        TimeZone.date_start(first, zone),
        TimeZone.date_start(Date.add(Date.end_of_month(today), 1), zone)
      }
    }
  end

  @doc """
  What each of `user_uuids` spent today and this month (the windows of `now`):
  `%{user_uuid => %{day_micro_usd:, month_micro_usd:}}`, every user in the
  answer, zero when there is nothing.
  """
  @spec for_users([String.t()], DateTime.t()) :: %{String.t() => spent()}
  def for_users(user_uuids, now \\ DateTime.utc_now())
  def for_users([], _now), do: %{}

  def for_users(user_uuids, now) when is_list(user_uuids) do
    %{day: {day_from, day_to}, month: {month_from, month_to}} = windows(now)

    totals =
      from(r in Request,
        where:
          r.user_uuid in ^user_uuids and fragment("?->>'source' = 'agent'", r.metadata) and
            r.inserted_at >= ^month_from and r.inserted_at < ^month_to,
        group_by: r.user_uuid,
        select: {
          r.user_uuid,
          coalesce(sum(r.cost_cents), 0),
          coalesce(
            filter(sum(r.cost_cents), r.inserted_at >= ^day_from and r.inserted_at < ^day_to),
            0
          )
        }
      )
      |> RepoHelper.repo().all()
      |> Map.new(fn {user_uuid, month, day} ->
        {user_uuid, %{day_micro_usd: to_int(day), month_micro_usd: to_int(month)}}
      end)

    Map.new(user_uuids, fn uuid ->
      {uuid, Map.get(totals, uuid, %{day_micro_usd: 0, month_micro_usd: 0})}
    end)
  end

  defp to_int(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_int(value) when is_integer(value), do: value
end
