defmodule PhoenixKitAgent.Config do
  @moduledoc """
  The module settings (`phoenix_kit_settings`, keys `agent_*`) and their
  defaults. A per-user value (`PhoenixKitAgent.Schemas.UserSettings`) wins over
  these; these win over the built-in defaults below.

  | Key | Default |
  |---|---|
  | `agent_enabled` | `false` (see `PhoenixKitAgent.enabled?/0`) |
  | `agent_default_endpoint_uuid` | none — the AI endpoint the assistant uses |
  | `agent_vision_endpoint_uuid` | none — describes images for a model without image input |
  | `agent_system_prompt` | none — the module's system prompt |
  | `agent_daily_cost_limit_micro_usd` | `1_000_000` ($1) |
  | `agent_monthly_cost_limit_micro_usd` | `10_000_000` ($10) |
  | `agent_daily_turn_limit` | `200` |
  | `agent_max_attachment_mb` | `20` |
  | `agent_max_attachments_per_message` | `5` |
  | `agent_limit_watchers` | none (newline-separated user uuids; none = every Owner) |
  | `agent_max_tool_rounds` | `8` |
  | `agent_turn_deadline_s` | `300` |
  | `agent_history_chars` | `24_000` |
  | `agent_tool_result_chars` | `12_000` |
  | `agent_capture_ai_content` | `false` |

  Money is in micro-dollars ($1 = 1_000_000), the unit of
  `phoenix_kit_ai_requests.cost_cents`. A stored value that is not a whole
  number, or is outside its range (below), reads as the default. A limit of `0`
  is a real limit (nothing allowed); a technical value must be positive.

  `agent_capture_ai_content` is on only when it reads exactly `"true"`: then the
  bodies of the assistant's model calls are written to the AI request journal,
  where every holder of the `ai` permission reads them. Only an Owner may switch
  it (that screen is not part of this module yet); this module only reads it.
  """

  import Ecto.Changeset

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Number

  @module "agent"
  @micro_per_usd 1_000_000

  # {field, setting key, default, min, max}
  @limits [
    {:daily_cost_limit_micro_usd, "agent_daily_cost_limit_micro_usd", 1_000_000, 0,
     1_000_000_000_000},
    {:monthly_cost_limit_micro_usd, "agent_monthly_cost_limit_micro_usd", 10_000_000, 0,
     1_000_000_000_000},
    {:daily_turn_limit, "agent_daily_turn_limit", 200, 0, 100_000},
    {:max_attachment_mb, "agent_max_attachment_mb", 20, 0, 1_024},
    {:max_attachments_per_message, "agent_max_attachments_per_message", 5, 0, 50}
  ]

  @technical [
    {:max_tool_rounds, "agent_max_tool_rounds", 8, 1, 50},
    {:turn_deadline_s, "agent_turn_deadline_s", 300, 10, 3_600},
    {:history_chars, "agent_history_chars", 24_000, 1_000, 1_000_000},
    {:tool_result_chars, "agent_tool_result_chars", 12_000, 500, 1_000_000}
  ]

  @money_fields %{
    daily_cost_limit_usd: :daily_cost_limit_micro_usd,
    monthly_cost_limit_usd: :monthly_cost_limit_micro_usd
  }

  @watchers_key "agent_limit_watchers"

  # ── Readers ───────────────────────────────────────────────────────────

  @doc "The module's default per-user limits."
  @spec limit_defaults() :: %{atom() => non_neg_integer()}
  def limit_defaults, do: Map.new(@limits, fn spec -> {elem(spec, 0), read(spec)} end)

  @doc "Most model ↔ tool rounds in one turn."
  @spec max_tool_rounds() :: pos_integer()
  def max_tool_rounds, do: technical(:max_tool_rounds)

  @doc "Deadline of a whole turn, in seconds."
  @spec turn_deadline_s() :: pos_integer()
  def turn_deadline_s, do: technical(:turn_deadline_s)

  @doc "How many characters of earlier messages go into the model's context."
  @spec history_chars() :: pos_integer()
  def history_chars, do: technical(:history_chars)

  @doc "How many characters of one tool result go to the model (and are kept)."
  @spec tool_result_chars() :: pos_integer()
  def tool_result_chars, do: technical(:tool_result_chars)

  @doc "The AI endpoint the assistant uses by default, or `nil`."
  @spec default_endpoint_uuid() :: String.t() | nil
  def default_endpoint_uuid, do: uuid_setting("agent_default_endpoint_uuid")

  @doc "The AI endpoint that describes images for a model without image input, or `nil`."
  @spec vision_endpoint_uuid() :: String.t() | nil
  def vision_endpoint_uuid, do: uuid_setting("agent_vision_endpoint_uuid")

  @doc "The module's system prompt, or `nil`."
  @spec system_prompt() :: String.t() | nil
  def system_prompt do
    case string_setting("agent_system_prompt") do
      nil -> nil
      prompt -> if String.trim(prompt) == "", do: nil, else: prompt
    end
  end

  @doc """
  The users told when someone hits a limit (`agent_limit_watchers`). Empty means
  every Owner; who those are is decided where the notice is sent.
  """
  @spec limit_watchers() :: [String.t()]
  def limit_watchers do
    @watchers_key
    |> string_setting()
    |> parse_uuid_list()
  end

  @doc "Whether the bodies of the assistant's model calls go to the AI journal."
  @spec capture_ai_content?() :: boolean()
  def capture_ai_content? do
    string_setting("agent_capture_ai_content") == "true"
  end

  # ── Writers ───────────────────────────────────────────────────────────

  @doc """
  Takes `user_uuid` out of `agent_limit_watchers`, under the setting's row lock
  (a concurrent change of the list is not lost). `{:ok, :unchanged}` when it was
  not in the list.
  """
  @spec remove_limit_watcher(String.t()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  def remove_limit_watcher(user_uuid) when is_binary(user_uuid) do
    Settings.modify_setting_with_module(@watchers_key, @module, fn stored ->
      uuids = parse_uuid_list(stored)

      if user_uuid in uuids,
        do: uuids |> List.delete(user_uuid) |> Enum.join("\n"),
        else: :unchanged
    end)
  end

  # ── The defaults form (Settings → AI Agent) ──────────────────────────

  @doc """
  The current defaults as the form shows them: string values, money in dollars.
  """
  @spec defaults_form_values() :: %{String.t() => String.t()}
  def defaults_form_values do
    limits = limit_defaults()

    money =
      Map.new(@money_fields, fn {usd_field, micro_field} ->
        {Atom.to_string(usd_field), micro_to_usd(Map.fetch!(limits, micro_field))}
      end)

    integers =
      for {field, _key, _default, _min, _max} <- form_integer_specs(), into: %{} do
        value = Map.get(limits, field) || technical(field)
        {Atom.to_string(field), Integer.to_string(value)}
      end

    Map.merge(money, integers)
  end

  @doc "Validates the defaults form; see `save_defaults/2`."
  @spec defaults_changeset(map()) :: Ecto.Changeset.t()
  def defaults_changeset(params) do
    types =
      Map.merge(
        Map.new(@money_fields, fn {usd_field, _} -> {usd_field, :string} end),
        Map.new(form_integer_specs(), fn spec -> {elem(spec, 0), :string} end)
      )

    values = defaults_form_values()
    data = Map.new(types, fn {field, _} -> {field, values[Atom.to_string(field)]} end)

    {data, types}
    |> cast(stringify(params), Map.keys(types))
    |> validate_required(Map.keys(types))
    |> validate_money()
    |> validate_integers()
    |> Map.put(:action, :validate)
  end

  @doc """
  Saves the defaults form: dollars become micro-dollars; every value is checked
  against its range and nothing is written unless all are valid. Only values
  that differ from what is in effect are written, so an untouched built-in
  default stays unstored (and follows a later change of the default). `opts` go to `PhoenixKit.Settings` (`actor_uuid:`,
  `source:`) so the change is in the settings history with who made it.
  """
  @spec save_defaults(map(), keyword()) :: {:ok, [String.t()]} | {:error, Ecto.Changeset.t()}
  def save_defaults(params, opts) do
    changeset = defaults_changeset(params)

    if changeset.valid? do
      changeset
      |> to_settings()
      |> Enum.reject(fn {key, value} -> effective_value(key) == value end)
      |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, written} ->
        case Settings.update_setting_with_module(key, value, @module, opts) do
          {:ok, _} -> {:cont, {:ok, [key | written]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, changeset}
    end
  end

  defp form_integer_specs do
    Enum.reject(@limits, fn spec -> elem(spec, 0) in Map.values(@money_fields) end) ++
      @technical
  end

  defp validate_money(changeset) do
    Enum.reduce(@money_fields, changeset, fn {usd_field, micro_field}, acc ->
      {_, _, _, min, max} = spec_of(micro_field)

      validate_change(acc, usd_field, fn ^usd_field, value ->
        case usd_to_micro(value) do
          {:ok, micro} when micro >= min and micro <= max -> []
          {:ok, _} -> [{usd_field, "is out of range"}]
          {:error, :fraction} -> [{usd_field, "is finer than a millionth of a dollar"}]
          {:error, _} -> [{usd_field, "is not a valid amount"}]
        end
      end)
    end)
  end

  defp validate_integers(changeset) do
    Enum.reduce(form_integer_specs(), changeset, fn {field, _key, _default, min, max}, acc ->
      validate_change(acc, field, fn ^field, value ->
        case whole_number(value) do
          n when is_integer(n) and n >= min and n <= max -> []
          n when is_integer(n) -> [{field, "must be between #{min} and #{max}"}]
          nil -> [{field, "is not a whole number"}]
        end
      end)
    end)
  end

  defp to_settings(changeset) do
    money =
      Enum.map(@money_fields, fn {usd_field, micro_field} ->
        {:ok, micro} = usd_to_micro(get_field(changeset, usd_field))
        {elem(spec_of(micro_field), 1), Integer.to_string(micro)}
      end)

    integers =
      Enum.map(form_integer_specs(), fn {field, key, _default, _min, _max} ->
        {key, Integer.to_string(whole_number(get_field(changeset, field)))}
      end)

    money ++ integers
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp spec_of(field), do: Enum.find(@limits ++ @technical, &(elem(&1, 0) == field))

  defp effective_value(key) do
    @limits
    |> Kernel.++(@technical)
    |> Enum.find(&(elem(&1, 1) == key))
    |> read()
    |> Integer.to_string()
  end

  defp technical(field), do: field |> spec_of() |> read()

  defp read({_field, key, default, min, max}) do
    case key |> string_setting() |> whole_number() do
      n when is_integer(n) and n >= min and n <= max -> n
      _ -> default
    end
  end

  defp string_setting(key) do
    case Settings.get_setting_cached(key, nil) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp uuid_setting(key) do
    with value when is_binary(value) <- string_setting(key),
         {:ok, uuid} <- Ecto.UUID.cast(String.trim(value)) do
      uuid
    else
      _ -> nil
    end
  end

  defp parse_uuid_list(nil), do: []

  defp parse_uuid_list(value) when is_binary(value) do
    value
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(fn line ->
      case Ecto.UUID.cast(String.trim(line)) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp whole_number(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp whole_number(_), do: nil

  defp usd_to_micro(value) do
    with {:ok, usd} <- Number.parse_decimal(value, min: 0) do
      micro = Decimal.mult(usd, @micro_per_usd)

      if Decimal.equal?(micro, Decimal.round(micro, 0)),
        do: {:ok, Decimal.to_integer(Decimal.round(micro, 0))},
        else: {:error, :fraction}
    end
  end

  defp micro_to_usd(micro) do
    micro
    |> Decimal.new()
    |> Decimal.div(@micro_per_usd)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp stringify(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end
end
