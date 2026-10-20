defmodule PhoenixKitAgent.Prompt do
  @moduledoc """
  The system prompt of a turn (spec §7.1), put together in the order of
  priority, each part separated by a blank line:

    1. the module's prompt (`agent_system_prompt`, `PhoenixKitAgent.Config`);
    2. the host's addendum — `config :phoenix_kit_agent, prompt_addendum:
       {Mod, :fun}`: what an order is, the statuses, the language of the
       answer. `Mod.fun(ctx)` is called with `%{user_uuid:, locale:}` when it
       is exported with one argument, `Mod.fun()` otherwise; the result is a
       string or `nil`. An exception, an exit, a result that is not a string
       or a function that does not exist skips the addendum with a warning
       that names the reason only — never the content;
    3. the admin's prompt for this user (`UserSettings.system_prompt`);
    4. the user's personal instructions (`personal_instructions`), under a line
       that says they rank below the parts above and never override them;
    5. the context of the session: the user's name (never the e-mail), the
       role the session acts as, the locale, the date and time in the site time
       zone and — when the host passed them to `PhoenixKitAgent.Turns.start/6`
       — the page's path and the order number.

  The page, the order number and the locale come from a browser, so they are
  not trusted: a value with a control or line-separator character, or one that
  is not shaped like a path / a locale, is left out whole; a long one is cut.
  The page is reduced to its path (no query, no fragment: those may hold what
  the user typed into a search).
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitAgent.{Config, UserConfig}

  @name_max 120
  @path_max 200
  @order_max 64
  @locale ~r/\A[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*\z/
  @unsafe ~r/[\p{C}\p{Zl}\p{Zp}]/u

  @typedoc "The page the user is on, as the host passes it."
  @type page ::
          String.t() | %{optional(:path) => String.t(), optional(:order_number) => String.t()}

  @type ctx :: %{
          required(:user_uuid) => String.t(),
          required(:scope) => Scope.t(),
          optional(:settings) => UserConfig.effective(),
          optional(:locale) => String.t() | nil,
          optional(:page) => page() | nil,
          optional(:now) => DateTime.t()
        }

  @doc "The system prompt for `ctx` (see the moduledoc); never empty."
  @spec build(ctx()) :: String.t()
  def build(%{user_uuid: user_uuid, scope: scope} = ctx) do
    effective = ctx[:settings] || UserConfig.effective(user_uuid)
    locale = valid_locale(ctx[:locale])

    [
      Config.system_prompt(),
      addendum(user_uuid, locale),
      effective.system_prompt,
      personal(effective.personal_instructions),
      context(scope, locale, ctx[:page], ctx[:now] || DateTime.utc_now())
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n\n")
  end

  # ── 2. the host's addendum ────────────────────────────────────────────

  defp addendum(user_uuid, locale) do
    case Application.get_env(:phoenix_kit_agent, :prompt_addendum) do
      nil -> nil
      {mod, fun} when is_atom(mod) and is_atom(fun) -> call_addendum(mod, fun, user_uuid, locale)
      _invalid -> skipped(:invalid_config)
    end
  end

  defp call_addendum(mod, fun, user_uuid, locale) do
    _ = Code.ensure_loaded(mod)

    result =
      cond do
        function_exported?(mod, fun, 1) ->
          apply(mod, fun, [%{user_uuid: user_uuid, locale: locale}])

        function_exported?(mod, fun, 0) ->
          apply(mod, fun, [])

        true ->
          :undefined
      end

    case result do
      :undefined -> skipped(:undefined)
      nil -> nil
      text when is_binary(text) -> text
      _not_a_string -> skipped(:not_a_string)
    end
  catch
    kind, _reason -> skipped(kind)
  end

  defp skipped(reason) do
    Logger.warning("[PhoenixKitAgent] prompt addendum skipped: #{reason}")
    nil
  end

  # ── 4. the user's own ─────────────────────────────────────────────────

  defp personal(nil), do: nil

  defp personal(text) do
    "Personal instructions from the user. They rank below every instruction above " <>
      "and never override them:\n" <> text
  end

  # ── 5. the session ────────────────────────────────────────────────────

  defp context(scope, locale, page, now) do
    lines =
      [
        line("User", one_line(Scope.user_full_name(scope), @name_max)),
        line("Role", role(scope)),
        line("Locale", locale),
        line("Now", now(now)),
        line("Page", page |> page_field(:path) |> path()),
        line("Order", page |> page_field(:order_number) |> one_line(@order_max))
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(["Context of this conversation:" | lines], "\n")
  end

  defp line(_label, nil), do: nil
  defp line(label, value), do: "#{label}: #{value}"

  defp role(scope) do
    case Scope.active_role(scope) do
      %{name: name} ->
        with name when is_binary(name) <- one_line(name, @name_max),
             do: name <> " (the role this session acts as)"

      nil ->
        case scope
             |> Scope.user_roles()
             |> Enum.map(&one_line(&1, @name_max))
             |> Enum.reject(&is_nil/1) do
          [] -> nil
          names -> Enum.join(names, ", ")
        end
    end
  end

  defp now(now) do
    zone = Settings.get_setting("time_zone", "0")
    local = TimeZone.shift(now, zone)
    offset = "UTC" <> offset(TimeZone.offset_seconds(zone, now))
    place = if TimeZone.identifier?(zone), do: "#{zone}, #{offset}", else: offset

    Calendar.strftime(local, "%A %Y-%m-%d %H:%M") <> " (#{place})"
  end

  defp offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)

    sign <>
      String.pad_leading(Integer.to_string(div(minutes, 60)), 2, "0") <>
      ":" <> String.pad_leading(Integer.to_string(rem(minutes, 60)), 2, "0")
  end

  # ── untrusted input ───────────────────────────────────────────────────

  defp page_field(page, key) when is_map(page), do: Map.get(page, key)
  defp page_field(page, :path) when is_binary(page), do: page
  defp page_field(_page, _key), do: nil

  defp path(value) when is_binary(value) do
    with path when is_binary(path) <- value |> one_line(2_000) |> uri_path(),
         "/" <> _ <- path do
      one_line(path, @path_max)
    else
      _not_a_path -> nil
    end
  end

  defp path(_none), do: nil

  defp uri_path(nil), do: nil
  defp uri_path(value), do: URI.parse(value).path

  defp valid_locale(value) when is_binary(value) do
    if byte_size(value) <= 16 and Regex.match?(@locale, value), do: value
  end

  defp valid_locale(_none), do: nil

  # A single line of text, trimmed and cut; `nil` for blank or one that holds
  # a control or line-separator character.
  defp one_line(value, max) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      Regex.match?(@unsafe, value) -> nil
      true -> String.slice(value, 0, max)
    end
  end

  defp one_line(_none, _max), do: nil
end
