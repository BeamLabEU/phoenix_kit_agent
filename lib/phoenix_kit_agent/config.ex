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
  | `agent_speech_endpoint_uuid` | none — writes down voice messages and the panel's microphone; none = voice off |
  | `agent_system_prompt` | none — the module's system prompt (JSON `{"text": …}`) |
  | `agent_daily_cost_limit_micro_usd` | `1_000_000` ($1) |
  | `agent_monthly_cost_limit_micro_usd` | `10_000_000` ($10) |
  | `agent_daily_turn_limit` | `200` |
  | `agent_max_attachment_mb` | `20` |
  | `agent_max_attachments_per_message` | `5` |
  | `agent_limit_watchers` | none — JSON `{"uuids": […]}` of user uuids; none = every Owner |
  | `agent_max_tool_rounds` | `8` |
  | `agent_turn_deadline_s` | `300` |
  | `agent_history_chars` | `24_000` |
  | `agent_tool_result_chars` | `12_000` |
  | `agent_capture_ai_content` | `false` |
  | `agent_retention_days` | none — chats are kept without a time limit (`PhoenixKitAgent.Retention`) |
  | `agent_attachment_types` | none — every type the module reads: png, jpg, webp, heic, pdf, xlsx, csv, txt, md |
  | `agent_telegram_enabled` | `false` — answer the linked chats of the site's Telegram bot |
  | `agent_telegram_offset` | none — `"<bot connection uuid>:<last update id>"`, kept by the reader |

  Money is in micro-dollars ($1 = 1_000_000); the AI journal keeps dollars
  (`phoenix_kit_ai_requests.cost`), read through `cost_to_micro/1`. A stored
  value that is not a whole number, or is outside its range (below), reads as
  the default. A limit of `0` is a real limit (nothing allowed); a technical
  value must be positive.

  Core keeps a string setting to 1000 characters, so the two settings that can
  be longer — the module prompt and the watchers — are JSON settings
  (`value_json`), written by `put_system_prompt/2` and `put_limit_watchers/2`.
  The three models are written by `put_default_endpoint/2`,
  `put_vision_endpoint/2` and `put_speech_endpoint/2`, which take only an AI
  endpoint that chats and fits its AI task (`agent.chat`, `agent.attachment`,
  `agent.speech`).

  Every writer records the change with who made it (`actor_uuid:` in `opts`)
  in the core Activity log: through the settings history (`setting.changed`,
  with the values before and after) — except the module prompt, whose text
  must not be kept there (nor in the query log that history's write goes
  to): it is written without that history, and its change is recorded as
  `agent.settings_updated` with the field name only.

  `agent_retention_days` is a whole number of days, `1` to 3650, or empty. Empty
  is the default and means no chat is ever deleted by the module. A value
  that is not a whole number in that range is read as empty, never as a short
  period: a damaged setting must not delete anything.
  `agent_attachment_types` is a comma-separated list of the types of file a
  chat accepts (`PhoenixKitAgent.Attachments.Detect.types/0`); empty, or a
  value with no known type, reads as every type.

  `agent_capture_ai_content` is on only when it reads exactly `"true"`: then the
  bodies of the assistant's model calls are written to the AI request journal,
  where every holder of the `ai` permission reads them. Only an Owner may switch
  it: `put_capture_ai_content/2` does not check that, its caller (the Settings
  page, `PhoenixKitAgent.Web.SettingsLive`) does.
  """

  import Ecto.Changeset

  alias PhoenixKit.Activity
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.History
  alias PhoenixKit.Utils.Number
  alias PhoenixKitAgent.Attachments.Detect
  alias PhoenixKitAgent.Schemas.Message
  alias PhoenixKitAI.Endpoint

  @module "agent"
  @telegram_offset_key "agent_telegram_offset"
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
  @prompt_key "agent_system_prompt"

  # The longest module prompt, in characters.
  @prompt_max 16_000

  @retention_key "agent_retention_days"
  @attachment_types_key "agent_attachment_types"

  # The longest retention a person can set: ten years.
  @retention_max_days 3650

  @typedoc "Why `put_default_endpoint/2`, `put_vision_endpoint/2` or `put_speech_endpoint/2` wrote nothing."
  @type endpoint_refusal ::
          :invalid_endpoint | {:model_unfit | :model_unverified, [atom()]}

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

  @doc "The AI endpoint that writes down speech (voice messages, the panel's microphone), or `nil`."
  @spec speech_endpoint_uuid() :: String.t() | nil
  def speech_endpoint_uuid, do: uuid_setting("agent_speech_endpoint_uuid")

  @doc """
  Whether voice input is on: the AI module can write speech down
  (`PhoenixKitAI.transcribe/3`, which the first releases of `phoenix_kit_ai`
  lack, so it is feature-detected like `writes?/0`) and a speech model is
  chosen. `config :phoenix_kit_agent, :speech_ai` names another module with
  `transcribe/3` in tests.
  """
  @spec speech?() :: boolean()
  def speech?, do: speech_endpoint_uuid() != nil and transcribe?()

  @doc """
  Whether the AI module at hand can write speech down at all
  (`PhoenixKitAI.transcribe/3`, in the releases of `phoenix_kit_ai` after
  0.27.0): the Settings page offers no speech model without it.
  """
  @spec transcribe?() :: boolean()
  def transcribe? do
    ai = speech_ai()
    Code.ensure_loaded?(ai) and function_exported?(ai, :transcribe, 3)
  end

  @doc false
  # The module that writes speech down: `PhoenixKitAI`, unless a test names another.
  @spec speech_ai() :: module()
  def speech_ai, do: Application.get_env(:phoenix_kit_agent, :speech_ai, PhoenixKitAI)

  @doc "The module's system prompt, or `nil`."
  @spec system_prompt() :: String.t() | nil
  def system_prompt do
    case json_setting(@prompt_key) do
      %{"text" => prompt} when is_binary(prompt) ->
        if String.trim(prompt) == "", do: nil, else: prompt

      _none ->
        nil
    end
  end

  @doc """
  After how many days without a message a chat is deleted for good
  (`agent_retention_days`), or `nil`: no chat is deleted (the default). See
  `PhoenixKitAgent.Retention`.
  """
  @spec retention_days() :: pos_integer() | nil
  def retention_days, do: @retention_key |> string_setting() |> retention_value()

  @doc false
  # `retention_days/0` read from the database, not the cache: the nightly
  # deletion must act on the period as it was last saved, and a stale longer
  # or shorter value on another node would delete what the person meant to
  # keep. A read that fails is `nil`: nothing is deleted.
  @spec retention_days_direct() :: pos_integer() | nil
  def retention_days_direct do
    case Settings.get_settings_direct([@retention_key]) do
      %{@retention_key => value} when is_binary(value) -> retention_value(value)
      _none -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc "The longest retention, in days, that can be set."
  @spec retention_max_days() :: pos_integer()
  def retention_max_days, do: @retention_max_days

  @doc """
  The types of file a chat accepts (`agent_attachment_types`), a sublist of
  `PhoenixKitAgent.Attachments.Detect.types/0` in its order. Every type is
  accepted until a site narrows the list. The server checks it on every file
  added (`PhoenixKitAgent.Attachments.add/4`); the panel's file input only
  mirrors it.
  """
  @spec attachment_types() :: [String.t()]
  def attachment_types, do: @attachment_types_key |> string_setting() |> attachment_types_value()

  @doc """
  The users told when someone hits a limit (`agent_limit_watchers`). Empty means
  every Owner; who those are is decided where the notice is sent.
  """
  @spec limit_watchers() :: [String.t()]
  def limit_watchers, do: @watchers_key |> json_setting() |> watcher_uuids()

  @doc "Whether the bodies of the assistant's model calls go to the AI journal."
  @spec capture_ai_content?() :: boolean()
  def capture_ai_content? do
    string_setting("agent_capture_ai_content") == "true"
  end

  @doc """
  Whether the assistant answers the linked chats of the site's Telegram bot
  (`agent_telegram_enabled`; on only when it reads exactly `"true"`).
  """
  @spec telegram_enabled?() :: boolean()
  def telegram_enabled?, do: string_setting("agent_telegram_enabled") == "true"

  @doc """
  Whether the core this module runs on lets a linked Telegram chat hold a
  write for the user's confirmation (`PhoenixKit.API.Executor.link_writes?/0`,
  which the cores that do carry). The one place that asks: `Turns.Runner`
  (the tools offered to a chat), `Prompt`, the help text, the bridge's button
  presses, the reader's `allowed_updates`, `Confirmations` and the edits of a
  card after its outcome all follow it, so on a core without it the module
  works as before: a chat reads only.

  The check can go when the core requirement of this module is raised to the
  first release with it. `config :phoenix_kit_agent, :telegram_link_writes`
  (`true` / `false`) stands in for the core's answer in tests.
  """
  @spec writes?() :: boolean()
  def writes? do
    case Application.get_env(:phoenix_kit_agent, :telegram_link_writes) do
      nil ->
        executor = core(:executor)

        Code.ensure_loaded?(executor) and function_exported?(executor, :link_writes?, 0) and
          executor.link_writes?() == true

      forced ->
        forced == true
    end
  end

  @doc false
  # The core module that answers for `:executor` or `:confirm`: core's own,
  # unless `config :phoenix_kit_agent, :api_modules` names another (a test
  # stands in for a core that lets a chat hold writes while the core at hand
  # does not).
  @spec core(:executor | :confirm) :: module()
  def core(:executor), do: api_module(:executor, PhoenixKit.API.Executor)
  def core(:confirm), do: api_module(:confirm, PhoenixKit.API.Confirm)

  defp api_module(key, default) do
    :phoenix_kit_agent |> Application.get_env(:api_modules, []) |> Keyword.get(key, default)
  end

  @doc """
  The last update id the Telegram reader took from the bot `connection_uuid`,
  or `nil` (none, or kept for another bot). Read from the database, not the
  cache: a node that takes the bot over must see the last node's write.
  """
  @spec telegram_offset(String.t()) :: integer() | nil
  def telegram_offset(connection_uuid) when is_binary(connection_uuid) do
    with %{@telegram_offset_key => stored} when is_binary(stored) <-
           Settings.get_settings_direct([@telegram_offset_key]),
         [^connection_uuid, id] <- String.split(stored, ":", parts: 2),
         {offset, ""} <- Integer.parse(id) do
      offset
    else
      _none_or_another_bot -> nil
    end
  end

  # ── Writers ───────────────────────────────────────────────────────────

  @doc """
  Switches `agent_telegram_enabled`. `opts` go to `PhoenixKit.Settings`
  (`actor_uuid:`, `source:`). The caller checks `agent.manage`.
  """
  @spec put_telegram_enabled(boolean(), keyword()) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def put_telegram_enabled(value, opts) when is_boolean(value) do
    Settings.update_boolean_setting_with_module("agent_telegram_enabled", value, @module, opts)
  end

  @doc false
  # The reader's own write, once per batch: without the settings history,
  # which would fill the Activity log with it.
  @spec put_telegram_offset(String.t(), integer()) :: {:ok, term()} | {:error, term()}
  def put_telegram_offset(connection_uuid, update_id)
      when is_binary(connection_uuid) and is_integer(update_id) do
    Settings.update_setting_with_module(
      @telegram_offset_key,
      "#{connection_uuid}:#{update_id}",
      @module,
      history: false
    )
  end

  @doc """
  Sets `agent_retention_days`: a whole number of days from `1` to
  3650 (an integer, or text a person typed), or `nil` / blank for none
  (chats are kept without a time limit). Anything else is
  `{:error, :invalid_days}` and nothing is written (`{:ok, :unchanged}` for
  none when none was ever set). `opts` go to
  `PhoenixKit.Settings` (`actor_uuid:`, `source:`), so the change is in the
  settings history with who made it. The caller checks that the person is an
  **Owner**: this setting makes the nightly job delete chats for good, which
  `agent.manage` (an Admin holds it) is not enough for.
  """
  @spec put_retention_days(pos_integer() | String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, :invalid_days | Ecto.Changeset.t()}
  def put_retention_days(days, opts) do
    case parse_retention_days(days) do
      {:ok, nil} ->
        store(@retention_key, "", opts)

      {:ok, days} ->
        store(@retention_key, Integer.to_string(days), opts)

      :error ->
        {:error, :invalid_days}
    end
  end

  @doc """
  Sets `agent_attachment_types`: the types of file a chat accepts, each one of
  `PhoenixKitAgent.Attachments.Detect.types/0` (repeats and order do not
  matter). A name that is not one of them, or no type at all, is
  `{:error, :invalid_types}` and nothing is written (to take no files, set the
  attachments per message to `0`). The full list is stored as empty, the
  default, so it follows a type the module learns later. `opts` as for
  `put_retention_days/2`. The caller checks `agent.manage`.
  """
  @spec put_attachment_types([String.t()], keyword()) ::
          {:ok, term()} | {:error, :invalid_types | Ecto.Changeset.t()}
  def put_attachment_types(types, opts) when is_list(types) do
    known = Detect.types()

    if types != [] and Enum.all?(types, &(&1 in known)) do
      chosen = Enum.filter(known, &(&1 in types))
      value = if chosen == known, do: "", else: Enum.join(chosen, ",")
      store(@attachment_types_key, value, opts)
    else
      {:error, :invalid_types}
    end
  end

  def put_attachment_types(_types, _opts), do: {:error, :invalid_types}

  @doc """
  Sets the module's system prompt (`agent_system_prompt`); a blank one means
  none. NUL characters are cut (the database refuses them); a prompt over
  #{@prompt_max} characters is `{:error, changeset}` and nothing is written —
  it goes into every request. A change is recorded in the Activity log as
  `agent.settings_updated` by `actor_uuid:` (in `opts`), with the field name
  and never the text (see the moduledoc). The caller checks `agent.manage`.
  """
  @spec put_system_prompt(String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def put_system_prompt(prompt, opts) when is_binary(prompt) or is_nil(prompt) do
    changeset =
      {%{}, %{text: :string}}
      |> cast(%{text: Message.strip_nul(prompt || "")}, [:text], empty_values: [])
      |> validate_length(:text, max: @prompt_max)

    if changeset.valid? do
      text = get_field(changeset, :text) || ""
      changed? = stored_prompt() != text

      # `history: false`: the settings history would keep the text, and log it.
      with {:ok, setting} <-
             Settings.update_json_setting_with_module(
               @prompt_key,
               %{"text" => text},
               @module,
               history: false
             ) do
        if changed?, do: log_change(["system_prompt"], opts)
        {:ok, setting}
      end
    else
      {:error, %{changeset | action: :update}}
    end
  end

  @doc """
  Sets the AI endpoint the assistant uses by default
  (`agent_default_endpoint_uuid`), or none (`nil`). Only an existing endpoint
  that chats is taken; anything else is `{:error, :invalid_endpoint}` and
  nothing is written. A newly chosen endpoint must fit the `agent.chat` AI
  task (`PhoenixKitAI.Tasks.check_selection/2`): one whose model is known not
  to take tools is `{:error, {:model_unfit, missing}}`, one nobody knows
  takes them `{:error, {:model_unverified, unclear}}`, and nothing is
  written; the endpoint already set is not checked again. `opts` go to
  `PhoenixKit.Settings` (`actor_uuid:`, `source:`). The caller checks
  `agent.manage`.
  """
  @spec put_default_endpoint(String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, endpoint_refusal() | Ecto.Changeset.t()}
  def put_default_endpoint(uuid, opts),
    do: put_endpoint("agent_default_endpoint_uuid", "agent.chat", uuid, opts)

  @doc """
  Sets the AI endpoint that describes pictures for a model that does not see
  them (`agent_vision_endpoint_uuid`), or none (`nil`); as
  `put_default_endpoint/2`, against the `agent.attachment` AI task (its model
  must take pictures).
  """
  @spec put_vision_endpoint(String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, endpoint_refusal() | Ecto.Changeset.t()}
  def put_vision_endpoint(uuid, opts),
    do: put_endpoint("agent_vision_endpoint_uuid", "agent.attachment", uuid, opts)

  @doc """
  Sets the AI endpoint that writes down speech (`agent_speech_endpoint_uuid`),
  or none (`nil`: voice is off); as `put_default_endpoint/2`, against the
  `agent.speech` AI task (its model must take audio).
  """
  @spec put_speech_endpoint(String.t() | nil, keyword()) ::
          {:ok, term()} | {:error, endpoint_refusal() | Ecto.Changeset.t()}
  def put_speech_endpoint(uuid, opts),
    do: put_endpoint("agent_speech_endpoint_uuid", "agent.speech", uuid, opts)

  defp put_endpoint(key, _task, nil, opts),
    do: Settings.update_setting_with_module(key, "", @module, opts)

  defp put_endpoint(key, task, uuid, opts) when is_binary(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Endpoint{} = endpoint <- PhoenixKitAI.get_endpoint(uuid),
         :chat <- Endpoint.kind(endpoint),
         :ok <- fits(key, task, endpoint) do
      Settings.update_setting_with_module(key, uuid, @module, opts)
    else
      {:error, {reason, _needs}} = refusal when reason in [:model_unfit, :model_unverified] ->
        refusal

      _not_a_chat_endpoint ->
        {:error, :invalid_endpoint}
    end
  end

  defp put_endpoint(_key, _task, _other, _opts), do: {:error, :invalid_endpoint}

  # The endpoint already set is not checked again.
  defp fits(key, task, endpoint) do
    if uuid_setting(key) == endpoint.uuid,
      do: :ok,
      else: PhoenixKitAI.Tasks.check_selection(task, endpoint)
  end

  # A blank value clears a setting; one that was never stored has nothing to
  # clear (core takes no new row without a value).
  defp store(key, "", opts) do
    case Settings.get_settings_direct([key]) do
      %{^key => _stored} -> Settings.update_setting_with_module(key, "", @module, opts)
      _never_stored -> {:ok, :unchanged}
    end
  end

  defp store(key, value, opts), do: Settings.update_setting_with_module(key, value, @module, opts)

  defp retention_value(value) do
    case parse_retention_days(value) do
      {:ok, days} -> days
      :error -> nil
    end
  end

  @doc """
  What a period typed by a person means: `{:ok, days}`, `{:ok, nil}` for none
  (blank), `:error` for anything else. The same reading `put_retention_days/2`
  applies, so the Settings page can say what a value would do before it is saved.
  """
  @spec parse_retention_days(term()) :: {:ok, pos_integer() | nil} | :error
  def parse_retention_days(nil), do: {:ok, nil}
  def parse_retention_days(days) when is_integer(days), do: in_retention_range(days)

  def parse_retention_days(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:ok, nil}

      trimmed ->
        case whole_number(trimmed) do
          days when is_integer(days) -> in_retention_range(days)
          nil -> :error
        end
    end
  end

  def parse_retention_days(_other), do: :error

  defp in_retention_range(days) when days >= 1 and days <= @retention_max_days,
    do: {:ok, days}

  defp in_retention_range(_days), do: :error

  defp attachment_types_value(nil), do: Detect.types()

  defp attachment_types_value(value) do
    listed = value |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    case Enum.filter(Detect.types(), &(&1 in listed)) do
      [] -> Detect.types()
      types -> types
    end
  end

  defp stored_prompt do
    case json_setting(@prompt_key) do
      %{"text" => text} when is_binary(text) -> text
      _none -> ""
    end
  end

  defp log_change(fields, opts) do
    Activity.log(@module, "agent.settings_updated",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "agent_settings",
      metadata: %{"fields" => fields}
    )

    :ok
  end

  @doc """
  Switches `agent_capture_ai_content`. `opts` go to `PhoenixKit.Settings`
  (`actor_uuid:`, `source:`). The caller checks that the person is an Owner.
  """
  @spec put_capture_ai_content(boolean(), keyword()) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def put_capture_ai_content(value, opts) when is_boolean(value) do
    Settings.update_boolean_setting_with_module("agent_capture_ai_content", value, @module, opts)
  end

  @doc """
  Sets who is told when someone hits a limit (`agent_limit_watchers`): user
  uuids, repeats dropped; an empty list means every Owner. Anything that is
  not a uuid is `{:error, :invalid_uuid}` and nothing is written. The caller
  checks `agent.manage`.
  """
  @spec put_limit_watchers([String.t()], keyword()) ::
          {:ok, term()} | {:error, :invalid_uuid | Ecto.Changeset.t()}
  def put_limit_watchers(uuids, opts) when is_list(uuids) do
    cast = Enum.map(uuids, &Ecto.UUID.cast/1)

    if Enum.all?(cast, &match?({:ok, _}, &1)) do
      list = cast |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      Settings.update_json_setting_with_module(@watchers_key, %{"uuids" => list}, @module, opts)
    else
      {:error, :invalid_uuid}
    end
  end

  @doc """
  Takes `user_uuid` out of `agent_limit_watchers`, under the setting's row lock
  (a concurrent change of the list is not lost). `{:ok, :unchanged}` when it was
  not in the list.
  """
  @spec remove_limit_watcher(String.t()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  def remove_limit_watcher(user_uuid) when is_binary(user_uuid) do
    result =
      RepoHelper.repo().transaction(fn ->
        stored = History.lock_current(@watchers_key)
        uuids = watcher_uuids(stored && stored.value_json)

        if user_uuid in uuids do
          case Settings.update_json_setting_with_module(
                 @watchers_key,
                 %{"uuids" => List.delete(uuids, user_uuid)},
                 @module
               ) do
            {:ok, setting} -> setting
            {:error, changeset} -> RepoHelper.repo().rollback(changeset)
          end
        else
          :unchanged
        end
      end)

    # The write dropped the cached value before this transaction committed; a
    # reader in between could have cached the old list again.
    PhoenixKit.Cache.invalidate_now(:settings, [@watchers_key])
    result
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
  default stays unstored (and follows a later change of the default). They are
  written in one transaction (`PhoenixKit.Settings.update_settings_batch/2`):
  a write the database refuses leaves every setting as it was and is
  `{:error, :not_saved}`. `opts` go to `PhoenixKit.Settings` (`actor_uuid:`,
  `source:`) so the change is in the settings history with who made it.
  """
  @spec save_defaults(map(), keyword()) ::
          {:ok, [String.t()]} | {:error, Ecto.Changeset.t() | :not_saved}
  def save_defaults(params, opts) do
    changeset = defaults_changeset(params)

    if changeset.valid? do
      changeset
      |> to_settings()
      |> Enum.reject(fn {key, value} -> effective_value(key) == value end)
      |> write_all(opts)
    else
      {:error, changeset}
    end
  end

  defp write_all([], _opts), do: {:ok, []}

  defp write_all(settings, opts) do
    case Settings.update_settings_batch(Map.new(settings), opts) do
      {:ok, _written} -> {:ok, Enum.map(settings, &elem(&1, 0))}
      {:error, _step, _value, _changes} -> {:error, :not_saved}
    end
  rescue
    _db_error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :not_saved}
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

  defp json_setting(key) do
    Settings.get_json_setting_cached(key, nil)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp watcher_uuids(%{"uuids" => uuids}) when is_list(uuids) do
    uuids
    |> Enum.flat_map(fn uuid ->
      case Ecto.UUID.cast(uuid) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp watcher_uuids(_none), do: []

  defp uuid_setting(key) do
    with value when is_binary(value) <- string_setting(key),
         {:ok, uuid} <- Ecto.UUID.cast(String.trim(value)) do
      uuid
    else
      _ -> nil
    end
  end

  defp whole_number(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp whole_number(_), do: nil

  @doc """
  Dollars typed by a person (`"2,5"`, `"0.05"`) as micro-dollars: `{:ok,
  integer}`, `{:error, :fraction}` when finer than a millionth of a dollar,
  `{:error, reason}` for anything that is not a non-negative amount.
  """
  @spec usd_to_micro(term()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def usd_to_micro(value) do
    with {:ok, usd} <- Number.parse_decimal(value, min: 0) do
      micro = Decimal.mult(usd, @micro_per_usd)

      if Decimal.equal?(micro, Decimal.round(micro, 0)),
        do: {:ok, Decimal.to_integer(Decimal.round(micro, 0))},
        else: {:error, :fraction}
    end
  end

  @doc """
  A cost in dollars as the AI journal keeps it (`PhoenixKitAI.Request.cost`,
  a `Decimal`, finer than a micro-dollar at times) as whole micro-dollars,
  rounded half up: `$0.0000025` is `3`. `nil` (no cost known) stays `nil`.
  A sum is rounded once, after it is added up, never row by row.
  """
  @spec cost_to_micro(Decimal.t() | nil) :: non_neg_integer() | nil
  def cost_to_micro(nil), do: nil

  def cost_to_micro(%Decimal{} = usd) do
    usd |> Decimal.mult(@micro_per_usd) |> Decimal.round(0, :half_up) |> Decimal.to_integer()
  end

  @doc "Micro-dollars as dollars for a form field: `1_500_000` is `\"1.5\"`."
  @spec micro_to_usd(non_neg_integer()) :: String.t()
  def micro_to_usd(micro) do
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
