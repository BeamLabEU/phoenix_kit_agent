defmodule PhoenixKitAgent.Web.Dock.MyAssistant do
  @moduledoc """
  The "My assistant" part of the chat panel's settings region
  (`PhoenixKitAgent.Web.Dock`, the button next to the personal instructions):
  the user's three models, and his limits read-only. The LiveView holds the
  state and the events; this module reads what is shown (`load/1`) and draws it.

  Only the session's own user is ever read or written: `load/1` takes the user
  the session names, and a save goes through
  `PhoenixKitAgent.UserConfig.put_personal_models/3`, which takes the row of
  the session and nothing from the browser.

  Each of chat, pictures and speech shows the model in effect and where it
  comes from (`PhoenixKitAgent.UserConfig.effective/1`): the user's own, the
  default, the default because the own one cannot be used, or an own one
  outside the list of models users may choose. While an administrator has not
  listed any model to choose from, the three are shown read-only. Otherwise each
  is a choice of "Default: <name>" and the listed models that fit its task
  (`PhoenixKitAgent.Models.selectable/1`); the model the user has now stays
  among them and stays selected, so keeping it is never a change. The speech
  model is shown only where the AI module can write speech down.

  A user can always go back to the default for a field that holds a model of his
  own, also while the list is empty (`use_default` in the dock): clearing is never
  refused, and it is the only thing that button does.

  The limits are the ones in effect for the user; the administrator sets them.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitAgent.Gettext

  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  alias PhoenixKitAgent.{Config, Models, Spend, UserConfig}

  # The fields of the models form, as they are named in its submit.
  @fields [chat: :endpoint_uuid, vision: :vision_endpoint_uuid, speech: :speech_endpoint_uuid]

  @type t :: %{
          editable?: boolean(),
          fields: [map()],
          limits: map(),
          errors: %{optional(atom()) => String.t()},
          saved?: boolean()
        }

  @doc "What the region shows for this user, read now."
  @spec load(String.t()) :: t()
  def load(user_uuid) when is_binary(user_uuid) do
    settings = UserConfig.effective(user_uuid)
    editable? = Config.selectable_endpoint_uuids() != []

    names =
      settings.models
      |> Map.values()
      |> Enum.flat_map(&[&1.uuid, &1.own_uuid, &1.default_uuid])
      |> Enum.reject(&is_nil/1)
      |> Models.summaries()

    %{
      editable?: editable?,
      fields:
        for {task, field} <- @fields, task != :speech or Config.transcribe?() do
          field(task, field, Map.fetch!(settings.models, task), names, editable?)
        end,
      limits: %{
        daily_cost: settings.daily_cost_limit_micro_usd,
        monthly_cost: settings.monthly_cost_limit_micro_usd,
        daily_turns: settings.daily_turn_limit
      },
      errors: %{},
      saved?: false
    }
  end

  defp field(task, field, info, names, editable?) do
    %{
      task: task,
      field: field,
      name: Atom.to_string(field),
      value: info.own_uuid || "",
      source: info.source,
      outside_list?: info.outside_list?,
      model: Map.get(names, info.uuid),
      default: Map.get(names, info.default_uuid),
      choices: if(editable?, do: choices(task, Map.get(names, info.own_uuid)), else: [])
    }
  end

  # The listed models that fit the task, and the one the user has now.
  defp choices(task, current) do
    listed = Models.selectable(task)

    if current && not Enum.any?(listed, &(&1.uuid == current.uuid)),
      do: listed ++ [current],
      else: listed
  end

  @doc """
  The region after a refused save: each field holds what the user chose (also
  when it is no longer among the choices), and every field whose choice cannot
  be saved is marked, not only the one the write named. `refusal` is that
  first `{field, reason}`.
  """
  @spec refused(t(), map(), {atom(), term()}) :: t()
  def refused(data, attrs, {field, reason}) do
    submitted =
      for f <- data.fields, is_binary(attrs[f.name]), into: %{}, do: {f.field, attrs[f.name]}

    fields = Enum.map(data.fields, &with_submitted(&1, submitted, data.editable?))

    errors =
      for f <- data.fields,
          value = submitted[f.field],
          value not in ["", f.value],
          {:error, why} <- [Models.selection_check(f.task, value)],
          into: %{},
          do: {f.field, refusal_text(why)}

    %{data | fields: fields, errors: Map.put(errors, field, refusal_text(reason))}
  end

  defp with_submitted(field, submitted, true) do
    case Map.fetch(submitted, field.field) do
      {:ok, value} -> %{field | value: value, choices: with_choice(field.choices, value)}
      :error -> field
    end
  end

  defp with_submitted(field, _submitted, false), do: field

  defp with_choice(choices, ""), do: choices

  defp with_choice(choices, uuid) do
    if Enum.any?(choices, &(&1.uuid == uuid)),
      do: choices,
      else: choices ++ Map.values(Models.summaries([uuid]))
  end

  @doc "The fields of the form that a submit may carry, as they are named in it."
  @spec submit_keys() :: [String.t()]
  def submit_keys, do: Enum.map(@fields, fn {_task, field} -> Atom.to_string(field) end)

  @doc "Why a model is refused, for the field it was chosen in."
  @spec refusal_text(term()) :: String.t()
  def refusal_text(reason) when reason in [:model_unfit, :model_unverified],
    do: gettext("does not suit this task")

  def refusal_text({reason, _needs}) when reason in [:model_unfit, :model_unverified],
    do: refusal_text(reason)

  def refusal_text(_not_allowed_or_unusable), do: gettext("is not available")

  attr(:data, :map, required: true)

  def my_assistant(assigns) do
    ~H"""
    <section id="pk-agent-my-assistant" class="border-b border-base-300 p-3 space-y-3">
      <h3 class="text-sm font-semibold">{gettext("My assistant")}</h3>

      <p :if={!@data.editable?} id="pk-agent-models-closed" class="text-xs opacity-70">
        {gettext(
          "The administrator has not opened a choice of models for you: these are the ones in use."
        )}
      </p>

      <.form
        :if={@data.editable?}
        for={%{}}
        as={:models}
        id="pk-agent-models-form"
        phx-submit="save_models"
        class="space-y-3"
      >
        <.model_field :for={field <- @data.fields} field={field} error={@data.errors[field.field]} />
        <div class="flex justify-end">
          <button
            id="pk-agent-models-save"
            type="submit"
            class="btn btn-primary btn-xs pointer-coarse:min-h-11 pointer-coarse:min-w-11"
          >
            {gettext("Save")}
          </button>
        </div>
      </.form>

      <div :if={!@data.editable?} id="pk-agent-models" class="space-y-3">
        <.model_field :for={field <- @data.fields} field={field} />
      </div>

      <p :if={@data.saved?} id="pk-agent-models-saved" role="status" class="text-xs text-success">
        {gettext("Settings saved.")}
      </p>
    </section>

    <section id="pk-agent-limits" class="border-b border-base-300 p-3 space-y-1 text-xs">
      <h3 class="text-sm font-semibold">{gettext("Your limits")}</h3>
      <p id="pk-agent-limit-daily-cost">
        ${Spend.format_usd(@data.limits.daily_cost)} / {gettext("day")}
      </p>
      <p id="pk-agent-limit-monthly-cost">
        ${Spend.format_usd(@data.limits.monthly_cost)} / {gettext("month")}
      </p>
      <p id="pk-agent-limit-turns">
        {@data.limits.daily_turns} {gettext("turns")} / {gettext("day")}
      </p>
      <p class="opacity-70">{gettext("The administrator sets them.")}</p>
    </section>
    """
  end

  attr(:field, :map, required: true)
  attr(:error, :string, default: nil)

  defp model_field(assigns) do
    assigns = assign(assigns, dom: "pk-agent-model-" <> to_string(assigns.field.task))

    ~H"""
    <div id={@dom <> "-field"} class="min-w-0 space-y-1">
      <.select
        :if={editing?(@field)}
        id={@dom}
        aria-describedby={@dom <> "-effective"}
        name={"models[#{@field.name}]"}
        label={label(@field.task)}
        value={@field.value}
        options={options(@field)}
        errors={List.wrap(@error)}
        wrap_label
        class="select-sm text-sm pointer-coarse:min-h-11"
      />
      <div :if={!editing?(@field)}>
        <p class="text-xs font-medium">{label(@field.task)}</p>
        <p id={@dom <> "-model"} class="text-sm break-words">
          {priced_name(@field.model, @field.task)}
          <span
            id={@dom <> "-effective"}
            data-source={@field.source}
            class={["badge badge-sm ml-1", tag_class(@field.source)]}
          >
            {tag_text(@field.source)}
          </span>
        </p>
      </div>
      <p
        :if={editing?(@field)}
        id={@dom <> "-effective"}
        data-source={@field.source}
        class={["text-xs break-words", if(@field.source == :fallback, do: "text-warning", else: "opacity-70")]}
      >
        {note_text(@field)}
      </p>
      <p
        :if={!editing?(@field) and @field.source == :fallback}
        id={@dom <> "-fallback-note"}
        class="text-xs text-warning break-words"
      >
        {fallback_note(@field)}
      </p>
      <p
        :if={@field.source == :own and @field.outside_list?}
        id={@dom <> "-outside-list"}
        class="text-xs opacity-70 break-words"
      >
        {gettext("This model is outside the list of models users may choose.")}
      </p>
      <button
        :if={!editing?(@field) and @field.value != ""}
        id={@dom <> "-use-default"}
        type="button"
        phx-click="use_default"
        phx-value-field={@field.name}
        class="btn btn-ghost btn-xs pointer-coarse:min-h-11 pointer-coarse:min-w-11"
      >
        {gettext("Use the default")}
      </button>
    </div>
    """
  end

  # A choice only where there is something to choose from.
  defp editing?(field), do: field.choices != []

  defp options(field) do
    default =
      case field.default do
        %{} = summary -> gettext("Default: %{name}", name: name(summary))
        nil -> gettext("Default: none set")
      end

    [{default, ""} | Enum.map(field.choices, &{priced_name(&1, field.task), &1.uuid})]
  end

  defp label(:chat), do: gettext("Model")
  defp label(:vision), do: gettext("Vision model")
  defp label(:speech), do: gettext("Speech recognition model")

  defp name(%{name: name, model: model}), do: "#{name} (#{model})"

  defp name(nil), do: gettext("none set")

  # The name, and where money is not counted for that kind of call, a note: the
  # user's own limits in money do not hold for such a model.
  defp priced_name(%{} = summary, task) do
    if Models.reports_cost?(summary, task),
      do: name(summary),
      else: name(summary) <> " — " <> gettext("money is not counted")
  end

  defp priced_name(nil, _task), do: name(nil)

  # Under a select, which already shows the chosen model: only the state, and
  # what is in effect where that is not what is chosen.
  defp note_text(%{source: :own}), do: tag_text(:own)
  defp note_text(%{source: :default}), do: tag_text(:default)
  defp note_text(%{source: :fallback} = field), do: fallback_in_effect(field)

  defp tag_text(:own), do: gettext("own model")
  defp tag_text(:default), do: gettext("default")
  defp tag_text(:fallback), do: gettext("default — the own model cannot be used")

  defp tag_class(:own), do: "badge-primary badge-soft"
  defp tag_class(:default), do: "badge-ghost"
  defp tag_class(:fallback), do: "badge-warning badge-soft"

  defp fallback_in_effect(%{model: nil}),
    do:
      gettext(
        "The own model cannot be used (switched off, without credentials or no longer a chat model) and no default is set."
      )

  defp fallback_in_effect(field),
    do:
      gettext(
        "The own model cannot be used (switched off, without credentials or no longer a chat model), so the default is in effect — %{name}",
        name: name(field.model)
      )

  defp fallback_note(%{model: nil}), do: fallback_in_effect(%{model: nil})

  defp fallback_note(_field),
    do:
      gettext(
        "The own model cannot be used (switched off, without credentials or no longer a chat model), so the default is used."
      )
end
