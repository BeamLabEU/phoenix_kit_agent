defmodule PhoenixKitAgent.UserConfig do
  @moduledoc """
  The assistant settings of one user (spec §5.4, §7) and how they combine with
  the module's.

  ## What is in effect

  `effective/1` is the one place the turn loop reads a user's settings: the
  user's own value (`PhoenixKitAgent.Schemas.UserSettings`), else the module
  default (`PhoenixKitAgent.Config`). A `nil` field means "the default"; `0` is
  a real limit. A blank prompt is no prompt. The model (`endpoint_uuid`) is read
  when a turn starts, so a change takes effect with the next turn of any chat
  (spec §14, В6).

  ## The three models

  A user has a model for each task: the chat (`endpoint_uuid`), the pictures
  (`vision_endpoint_uuid`) and the speech (`speech_endpoint_uuid`). Every
  reader — a turn, the attachment processor, speech, the dock, Telegram — takes
  the one in effect from `effective/1` (`endpoint_uuid`, `vision_endpoint_uuid`,
  `speech_endpoint_uuid`), or `model/2` for one task; `models` in the result
  says where each came from (`t:model/0`, `resolve/4`):

    * `:default` — the user has none of his own, the module's default is used;
    * `:own` — the user's own, which can be called at all
      (`PhoenixKitAgent.Models.usable_uuids/1`). An own model outside the list of
      those users may choose (`PhoenixKitAgent.Config.selectable_endpoint_uuids/0`)
      stays in effect: only an administrator can have set it, and it is marked
      `outside_list?` so a page can say so;
    * `:fallback` — the user's own model was deleted, switched off or lost its
      credentials, so the default is used instead, and the page can say so.
      This holds for the chat model too: a row whose own `endpoint_uuid` can
      no longer be called is answered by the default, where it used to fail
      with the endpoint-unusable notice. Deleting the endpoint always had that
      effect (the link is set to `NULL`).

  Whether an own model still fits its task is asked when it is chosen, never
  when it is read: the capabilities of a model come and go with a provider's
  catalogue, and a model that was fine must not vanish from a turn for that.

  `enabled?/1` is the user's own switch: `false` only when an admin switched the
  assistant off for them (it never grants the `agent` permission).

  ## Who writes what

    * The user — `put_personal_instructions/3` and `get_personal_instructions/2`,
      for **their own** `personal_instructions` only, and `put_personal_models/3`
      for **their own** three models only. Like
      `PhoenixKitAgent.Conversations` they act for a live browser session and
      need `impersonated: boolean` in the options; an impersonated session, a
      revoked one, a user without `agent` or one switched off is refused. The
      write replaces that one column, so nothing an admin set can change
      through it.
      A linked Telegram chat may read its instructions but not write them
      (`{:error, :not_in_telegram}`): they go into every later prompt.
      The write of the models takes the row of the session's user and never a
      uuid from the caller, and a model only if it is "default" or one of those
      users may choose that fits the task (`PhoenixKitAgent.Models.selection_check/2`).
    * An admin — `admin_update/4`, with the scope of a person who holds
      `agent.manage` (checked again here, so a caller that forgets is refused).
      It writes the switch, the three models (any one that fits the task, on the
      users' list or not), the admin's prompt, the limits and the
      notice flags (`UserSettings.admin_changeset/2`) and records who changed
      which fields for whom in the core Activity log — field names only, never
      a prompt text. An Owner's settings are changed by an Owner only, and a
      form opened before someone else's save does not overwrite it
      (`expected:`).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitAgent.{Config, Conversations, Models}
  alias PhoenixKitAgent.Schemas.UserSettings

  @manage "agent.manage"

  # The three tasks, and the column of the user's row that holds the model of each.
  @model_fields [
    chat: :endpoint_uuid,
    vision: :vision_endpoint_uuid,
    speech: :speech_endpoint_uuid
  ]

  @typedoc "The three tasks that have a model of their own."
  @type task :: :chat | :vision | :speech

  @typedoc """
  The model of one task for one user: the one in effect (`uuid`, `nil` when none
  is set anywhere) and where it came from (see the moduledoc), with the user's
  own (`own_uuid`, as stored) and the module's default (`default_uuid`).
  """
  @type model :: %{
          uuid: String.t() | nil,
          source: :own | :default | :fallback,
          own_uuid: String.t() | nil,
          default_uuid: String.t() | nil,
          outside_list?: boolean()
        }

  @typedoc "The settings in force for a user."
  @type effective :: %{
          user_uuid: String.t(),
          enabled?: boolean(),
          endpoint_uuid: String.t() | nil,
          vision_endpoint_uuid: String.t() | nil,
          speech_endpoint_uuid: String.t() | nil,
          models: %{task() => model()},
          system_prompt: String.t() | nil,
          personal_instructions: String.t() | nil,
          daily_cost_limit_micro_usd: non_neg_integer(),
          monthly_cost_limit_micro_usd: non_neg_integer(),
          daily_turn_limit: non_neg_integer(),
          max_attachment_mb: non_neg_integer(),
          max_attachments_per_message: non_neg_integer(),
          notify_on_limit: boolean(),
          own: [atom()]
        }

  # ── what is in effect ─────────────────────────────────────────────────

  @doc """
  The settings in force for `user_uuid`: their own value, else the module
  default (see the moduledoc). `own` lists the fields (models, prompt, limits)
  the user's row sets itself, whether or not the value can be used (`models`
  says that).
  """
  @spec effective(String.t()) :: effective()
  def effective(user_uuid) when is_binary(user_uuid),
    do: [user_uuid] |> effective_many() |> Map.fetch!(user_uuid)

  @doc """
  `effective/1` for several users with one query and one read of the module
  defaults: `%{user_uuid => effective}`.
  """
  @spec effective_many([String.t()]) :: %{String.t() => effective()}
  def effective_many([]), do: %{}

  def effective_many(user_uuids) when is_list(user_uuids) do
    rows =
      from(s in UserSettings, where: s.user_uuid in ^user_uuids)
      |> repo().all()
      |> Map.new(&{&1.user_uuid, &1})

    models = %{
      defaults:
        Map.new(@model_fields, fn {task, _field} -> {task, Config.default_endpoint_uuid(task)} end),
      selectable: Config.selectable_endpoint_uuids(),
      usable: rows |> Map.values() |> Enum.flat_map(&own_models/1) |> Models.usable_uuids()
    }

    defaults = Config.limit_defaults()

    Map.new(user_uuids, fn uuid ->
      row = Map.get(rows, uuid) || %UserSettings{}
      {uuid, build_effective(uuid, row, defaults, models)}
    end)
  end

  @doc """
  The model in effect for one task of one user (`t:model/0`): `effective/1`'s
  `models` for `task`.
  """
  @spec model(String.t(), task()) :: model()
  def model(user_uuid, task) when is_binary(user_uuid) and task in [:chat, :vision, :speech],
    do: effective(user_uuid).models[task]

  @doc """
  Whether voice input is on for the user: the AI module can write speech down
  and the speech model in effect for him exists (his own, else the default).
  """
  @spec speech?(String.t()) :: boolean()
  def speech?(user_uuid) when is_binary(user_uuid),
    do: Config.transcribe?() and model(user_uuid, :speech).uuid != nil

  @doc """
  How an own model and the module's default make the one in effect (the rules
  of the moduledoc), from what is known about them: `usable?` — the own one can
  be called at all, `listed?` — it is on the list of those users may choose.
  """
  @spec resolve(String.t() | nil, String.t() | nil, boolean(), boolean()) :: model()
  def resolve(nil, default, _usable?, _listed?),
    do: %{
      uuid: default,
      source: :default,
      own_uuid: nil,
      default_uuid: default,
      outside_list?: false
    }

  def resolve(own, default, true, listed?),
    do: %{
      uuid: own,
      source: :own,
      own_uuid: own,
      default_uuid: default,
      outside_list?: not listed?
    }

  def resolve(own, default, false, _listed?),
    do: %{
      uuid: default,
      source: :fallback,
      own_uuid: own,
      default_uuid: default,
      outside_list?: false
    }

  @doc """
  The endpoints the assistant's calls of a task use now: the module default and
  every user's own model of it. It backs the `endpoints` of the `agent.chat`
  (the default `task`), `agent.attachment` (`:vision`) and `agent.speech`
  (`:speech`) AI tasks (`PhoenixKitAgent.ai_tasks/0`).
  """
  @spec endpoint_uuids(task()) :: [String.t()]
  def endpoint_uuids(task \\ :chat) when task in [:chat, :vision, :speech] do
    field = Keyword.fetch!(@model_fields, task)

    own =
      from(s in UserSettings,
        where: not is_nil(field(s, ^field)),
        distinct: true,
        select: field(s, ^field)
      )
      |> repo().all()

    Enum.uniq(List.wrap(Config.default_endpoint_uuid(task)) ++ own)
  end

  # The models the rows name as their own.
  defp own_models(row),
    do: for({_task, field} <- @model_fields, uuid = Map.get(row, field), do: uuid)

  defp build_effective(user_uuid, row, defaults, models) do
    limits =
      Map.new(UserSettings.limit_fields(), fn field ->
        {field, Map.get(row, field) || Map.fetch!(defaults, field)}
      end)

    own =
      (UserSettings.model_fields() ++ [:system_prompt | UserSettings.limit_fields()])
      |> Enum.filter(&(Map.get(row, &1) not in [nil, ""]))

    chosen =
      Map.new(@model_fields, fn {task, field} ->
        own_uuid = Map.get(row, field)

        {task,
         resolve(
           own_uuid,
           models.defaults[task],
           MapSet.member?(models.usable, own_uuid),
           own_uuid in models.selectable
         )}
      end)

    Map.merge(limits, %{
      user_uuid: user_uuid,
      enabled?: row.enabled != false,
      endpoint_uuid: chosen.chat.uuid,
      vision_endpoint_uuid: chosen.vision.uuid,
      speech_endpoint_uuid: chosen.speech.uuid,
      models: chosen,
      system_prompt: present(row.system_prompt),
      personal_instructions: present(row.personal_instructions),
      notify_on_limit: row.notify_on_limit == true,
      own: own
    })
  end

  @doc """
  The people the assistant is for: active users who hold `agent` through a role
  (and the Owners, who hold every permission), by e-mail. The admin screen lists
  these.
  """
  @spec agent_users() :: [User.t()]
  def agent_users do
    owners = "Owner" |> Roles.users_with_role() |> Enum.map(& &1.uuid)
    uuids = Enum.uniq(Permissions.users_with_permission("agent") ++ owners)

    from(u in User,
      where: u.uuid in ^uuids and u.is_active == true,
      order_by: [asc: u.email, asc: u.uuid]
    )
    |> repo().all()
  end

  @doc """
  The people who may be chosen to be told when someone reaches a limit
  (`agent_limit_watchers`, spec §7.4): active users who hold `agent.manage`
  through a role, the Owners, and whoever is a watcher now, by e-mail.
  """
  @spec watcher_candidates() :: [User.t()]
  def watcher_candidates do
    owners = "Owner" |> Roles.users_with_role() |> Enum.map(& &1.uuid)
    managers = Enum.uniq(Permissions.users_with_permission(@manage) ++ owners)
    watchers = Config.limit_watchers()

    from(u in User,
      where: (u.uuid in ^managers and u.is_active == true) or u.uuid in ^watchers,
      order_by: [asc: u.email, asc: u.uuid]
    )
    |> repo().all()
  end

  @doc "Whether `user_uuid` is one of `agent_users/0`."
  @spec agent_user?(term()) :: boolean()
  def agent_user?(user_uuid) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, uuid} -> Enum.any?(agent_users(), &(&1.uuid == uuid))
      :error -> false
    end
  end

  @doc "Whether the assistant is not switched off for the user (see the moduledoc)."
  @spec enabled?(String.t()) :: boolean()
  def enabled?(user_uuid) when is_binary(user_uuid) do
    not repo().exists?(
      from(s in UserSettings, where: s.user_uuid == ^user_uuid and s.enabled == false)
    )
  end

  @doc """
  The user's settings row as it is stored, for the admin's form: an unsaved
  `%UserSettings{}` when they have none. `nil` for a malformed uuid.
  """
  @spec get(term()) :: UserSettings.t() | nil
  def get(user_uuid) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, uuid} -> repo().get(UserSettings, uuid) || %UserSettings{user_uuid: uuid}
      :error -> nil
    end
  end

  # ── the user's own: personal instructions ─────────────────────────────

  @doc """
  The session user's own personal instructions (`nil` when none). Refusals are
  those of `PhoenixKitAgent.Conversations`.
  """
  @spec get_personal_instructions(Conversations.session_ref(), keyword()) ::
          {:ok, String.t() | nil} | {:error, Conversations.refusal()}
  def get_personal_instructions(session_ref, opts) do
    with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts) do
      {:ok, effective(user_uuid).personal_instructions}
    end
  end

  @doc """
  Sets the session user's own personal instructions (a blank text clears them).
  They are the user's, ranked below the module's and the admin's prompt (spec
  §7.1). Only this one column is written, whatever else the row holds; a text
  over 4000 characters, or one that is not text, is `{:error, changeset}` and
  nothing is written.
  """
  @spec put_personal_instructions(Conversations.session_ref(), term(), keyword()) ::
          {:ok, String.t() | nil} | {:error, Conversations.refusal() | Ecto.Changeset.t()}
  def put_personal_instructions(session_ref, text, opts) do
    Conversations.on_the_site(session_ref, fn ->
      with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts) do
        changeset =
          UserSettings.personal_changeset(%UserSettings{user_uuid: user_uuid}, %{
            personal_instructions: text
          })

        if changeset.valid? do
          stored = Ecto.Changeset.get_field(changeset, :personal_instructions)
          write_personal(user_uuid, stored)
        else
          {:error, %{changeset | action: :update}}
        end
      end
    end)
  end

  # An upsert of the one column (and `updated_at`): a row an admin filled in,
  # or one holding a live turn's lock, keeps everything else. `log: false`:
  # Ecto would print the bound values, the user's text among them.
  defp write_personal(user_uuid, text) do
    now = DateTime.utc_now()

    repo().insert!(
      %UserSettings{user_uuid: user_uuid, personal_instructions: text},
      on_conflict: [set: [personal_instructions: text, updated_at: now]],
      conflict_target: :user_uuid,
      log: false
    )

    {:ok, text}
  end

  # ── the user's own: the three models ──────────────────────────────────

  @doc """
  Sets the session user's own models. `attrs` names any of `endpoint_uuid`
  (chat), `vision_endpoint_uuid` and `speech_endpoint_uuid` (atom or string
  keys; anything else in it is ignored): a value is an endpoint uuid, or `nil`
  / blank for "the default". A field `attrs` does not name stays as it is, and
  so does one whose value is what the row holds already (an administrator's
  choice outside the users' list, carried back by a form, is not asked again).

  A new endpoint must be one users may choose that can be called and fits the
  task of its field (`PhoenixKitAgent.Models.selection_check/2`); the first
  field that is not is `{:error, {field, reason}}` with that function's
  reason, and nothing is written. A value that is not a uuid is `{:error,
  changeset}`. The row is the session user's, never named by the caller; only
  these three columns are written, so the admin's fields and a running turn's
  lock stay. Returns `{:ok, changed_fields}`; refusals as `put_personal_instructions/3`.
  """
  @spec put_personal_models(Conversations.session_ref(), map(), keyword()) ::
          {:ok, [atom()]}
          | {:error,
             Conversations.refusal()
             | {atom(), Models.selection_refusal()}
             | Ecto.Changeset.t()}
  def put_personal_models(session_ref, attrs, opts) when is_map(attrs) do
    Conversations.on_the_site(session_ref, fn ->
      with {:ok, user_uuid} <- Conversations.authorize_session(session_ref, opts) do
        save_personal_models(user_uuid, attrs)
      end
    end)
  end

  defp save_personal_models(user_uuid, attrs) do
    result =
      repo().transaction(fn ->
        repo().insert!(%UserSettings{user_uuid: user_uuid},
          on_conflict: :nothing,
          conflict_target: :user_uuid
        )

        row =
          repo().one!(
            from(s in UserSettings, where: s.user_uuid == ^user_uuid, lock: "FOR UPDATE")
          )

        changeset = UserSettings.personal_models_changeset(row, attrs)

        unless changeset.valid?, do: repo().rollback(%{changeset | action: :update})

        with {:error, refusal} <- check_personal_models(changeset), do: repo().rollback(refusal)

        case repo().update(changeset) do
          {:ok, _row} -> changeset.changes |> Map.keys() |> Enum.sort()
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, fields} -> {:ok, fields}
      {:error, refusal} -> {:error, refusal}
    end
  end

  # What a user chose anew: each is one he may choose for that task. A
  # change to "the default" is always allowed.
  defp check_personal_models(changeset) do
    Enum.find_value(@model_fields, :ok, fn {task, field} ->
      with uuid when is_binary(uuid) <- Ecto.Changeset.get_change(changeset, field),
           {:error, reason} <- Models.selection_check(task, uuid) do
        {:error, {field, reason}}
      else
        _not_changed_cleared_or_fit -> nil
      end
    end)
  end

  # ── the admin's ───────────────────────────────────────────────────────

  @doc """
  Saves what an admin sets for `target_user_uuid` (`attrs` as
  `UserSettings.admin_changeset/2` casts them) on behalf of `actor_scope`,
  which must hold `agent.manage` — and be an Owner when the target is one: an
  Owner's assistant is not set by the people an Owner manages. The row is
  created if the user has none, and locked while it is changed.

  `expected: %{field => value}` in `opts` is what the caller's form showed
  when it was opened: when the stored row no longer holds those values (an
  admin saved in between), nothing is written and the answer is `{:error,
  :stale}`, so a stale form never overwrites that change unseen. Fields not
  named there do not count.

  Returns `{:ok, settings, changed_fields}`; when fields changed, the actor,
  the user (as the resource of the entry) and the field names go to the core
  Activity log (action `agent.user_settings_updated`) — no values, and no
  notification for the user. `{:error, :forbidden}` without the permission
  (or for an Owner's settings, to a non-Owner), `{:error, :not_found}` for an
  unknown user, `{:error, changeset}` for an invalid value (nothing is
  written). A newly chosen model must fit the AI task of its field
  (`PhoenixKitAI.Tasks.check_selection/2`; `agent.chat`, `agent.attachment` for
  the pictures, `agent.speech`): one known not to fit is `{:error,
  {:model_unfit, missing}}`, one nobody knows fits `{:error, {:model_unverified,
  unclear}}`, and nothing is written. The chat model's refusal is those
  two-element tuples; that of the pictures' or the speech model has the field
  as a third element (`{:model_unfit, missing, :vision_endpoint_uuid}`). None
  (the module default) and the model already saved are not checked; whether the
  users' list holds the model is no concern of an administrator's.
  """
  @spec admin_update(Scope.t() | nil, term(), map(), keyword()) ::
          {:ok, UserSettings.t(), [atom()]}
          | {:error,
             :forbidden
             | :not_found
             | :stale
             | {:model_unfit | :model_unverified, [atom()]}
             | {:model_unfit | :model_unverified, [atom()], atom()}
             | Ecto.Changeset.t()}
  def admin_update(actor_scope, target_user_uuid, attrs, opts \\ []) when is_map(attrs) do
    with :ok <- authorize_manage(actor_scope),
         {:ok, target} <- existing_user(target_user_uuid),
         :ok <- authorize_target(actor_scope, target) do
      actor_uuid = Scope.user_uuid(actor_scope)

      case save_admin(target.uuid, actor_uuid, attrs, Keyword.get(opts, :expected)) do
        {:ok, row, fields} ->
          log_change(actor_uuid, target.uuid, fields)
          {:ok, row, fields}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Whether `actor_scope` may set the assistant of `target_user_uuid` with
  `admin_update/4`: it holds `agent.manage`, and is an Owner if the target is.
  """
  @spec may_configure?(Scope.t() | nil, term()) :: boolean()
  def may_configure?(actor_scope, target_user_uuid) do
    with :ok <- authorize_manage(actor_scope),
         {:ok, target} <- existing_user(target_user_uuid) do
      authorize_target(actor_scope, target) == :ok
    else
      _refused -> false
    end
  end

  defp authorize_manage(%Scope{} = scope) do
    if Scope.can?(scope, @manage), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_manage(_none), do: {:error, :forbidden}

  defp authorize_target(actor_scope, target) do
    if Roles.user_has_role_owner?(target) and not Scope.owner?(actor_scope),
      do: {:error, :forbidden},
      else: :ok
  end

  defp existing_user(user_uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(user_uuid),
         %User{} = user <- repo().get(User, uuid) do
      {:ok, user}
    else
      _unknown -> {:error, :not_found}
    end
  end

  defp save_admin(target, actor_uuid, attrs, expected) do
    result =
      repo().transaction(fn ->
        repo().insert!(%UserSettings{user_uuid: target},
          on_conflict: :nothing,
          conflict_target: :user_uuid
        )

        row =
          repo().one!(from(s in UserSettings, where: s.user_uuid == ^target, lock: "FOR UPDATE"))

        unless unchanged?(row, expected), do: repo().rollback(:stale)

        changeset = UserSettings.admin_changeset(row, attrs)
        fields = changeset.changes |> Map.keys() |> Enum.sort()

        with {:error, refusal} <- check_models(changeset), do: repo().rollback(refusal)

        changeset =
          if fields == [],
            do: changeset,
            else: Ecto.Changeset.put_change(changeset, :updated_by_uuid, actor_uuid)

        # `log: false`: the bound values hold the admin's prompt.
        case repo().update(changeset, log: false) do
          {:ok, saved} -> {saved, fields}
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, {row, fields}} ->
        {:ok, row, fields}

      {:error, %Ecto.Changeset{}} = error ->
        error

      {:error, :stale} = error ->
        error

      {:error, {:model_unfit, _missing}} = error ->
        error

      {:error, {:model_unverified, _unclear}} = error ->
        error

      {:error, {reason, _needs, _field}} = error
      when reason in [:model_unfit, :model_unverified] ->
        error
    end
  end

  # A newly chosen model must fit the AI task of its field (`agent.chat`,
  # `agent.attachment`, `agent.speech`), whether or not users may choose it.
  # None (the module default) and the model already saved are not checked; an
  # endpoint that does not exist is the changeset's foreign key error. The
  # refusal of the chat model is `{reason, needs}`, as it always was; that of
  # another is `{reason, needs, field}`.
  defp check_models(changeset) do
    Enum.find_value(@model_fields, :ok, fn {task, field} ->
      with uuid when is_binary(uuid) <- Ecto.Changeset.get_change(changeset, field),
           {:error, {reason, needs}} when reason in [:model_unfit, :model_unverified] <-
             PhoenixKitAI.Tasks.check_selection(Models.task_of(task), uuid) do
        {:error, refusal_of(task, reason, needs, field)}
      else
        _fit_none_or_kept -> nil
      end
    end)
  end

  defp refusal_of(:chat, reason, needs, _field), do: {reason, needs}
  defp refusal_of(_task, reason, needs, field), do: {reason, needs, field}

  defp unchanged?(_row, nil), do: true

  defp unchanged?(row, expected) when is_map(expected),
    do: Enum.all?(expected, fn {field, value} -> Map.get(row, field) == value end)

  defp log_change(_actor_uuid, _target, []), do: :ok

  defp log_change(actor_uuid, target, fields) do
    # No `target_uuid`: core would turn the entry into a notification for the
    # user, who did not ask for one and could not switch it off.
    Activity.log("agent", "agent.user_settings_updated",
      actor_uuid: actor_uuid,
      resource_type: "agent_user_settings",
      resource_uuid: target,
      metadata: %{"fields" => Enum.map(fields, &Atom.to_string/1)}
    )

    :ok
  end

  defp present(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp present(_none), do: nil

  defp repo, do: RepoHelper.repo()
end
