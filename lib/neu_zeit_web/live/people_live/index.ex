defmodule NeuZeitWeb.PeopleLive.Index do
  @moduledoc """
  Edits teachers and student groups.

  Flags possible abbreviated names and aggregate groups for review.
  The data cannot verify a person's identity or actual student membership.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.{Cohort, Teacher}
  alias NeuZeitWeb.Nav

  # Legacy DKU language subgroups, the same shape `Constraints.Advisory` treats
  # as a subgroup when it reports unverified overlaps.
  @subgroup ~r/^(?:D|E|KZ|BS)[\s_-]*\d+$/iu

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Teachers and groups"))
     |> assign(:tab, "teachers")
     |> assign(:editing, nil)
     |> assign(:form, nil)
     |> assign(:kind, nil)
     |> assign(:deleting, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = Nav.assign_return(socket, params)
    {:noreply, socket |> assign(:tab, params["tab"] || "teachers") |> apply_action(params)}
  end

  defp apply_action(socket, %{"new" => "1"}) do
    case socket.assigns.tab do
      "cohorts" -> assign_form(socket, %Cohort{}, Catalog.change_cohort(%Cohort{}), :cohort)
      _teachers -> assign_form(socket, %Teacher{}, Catalog.change_teacher(%Teacher{}), :teacher)
    end
  end

  defp apply_action(socket, %{"edit" => id}) do
    case socket.assigns.tab do
      "cohorts" ->
        cohort = Catalog.get_cohort!(id)
        assign_form(socket, cohort, Catalog.change_cohort(cohort), :cohort)

      _teachers ->
        teacher = Catalog.get_teacher!(id)
        assign_form(socket, teacher, Catalog.change_teacher(teacher), :teacher)
    end
  end

  defp apply_action(socket, _params),
    do: socket |> assign(:editing, nil) |> assign(:form, nil) |> assign(:kind, nil)

  defp assign_form(socket, record, changeset, kind) do
    socket |> assign(:editing, record) |> assign(:form, to_form(changeset)) |> assign(:kind, kind)
  end

  @impl true
  def handle_event("validate", %{"teacher" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Catalog.change_teacher(socket.assigns.editing, params), action: :validate)
     )}
  end

  def handle_event("validate", %{"cohort" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Catalog.change_cohort(socket.assigns.editing, params), action: :validate)
     )}
  end

  def handle_event("save", %{"teacher" => params}, socket) do
    case socket.assigns.editing do
      %Teacher{id: nil} -> persist(socket, Catalog.create_teacher(params))
      teacher -> persist(socket, Catalog.update_teacher(teacher, params))
    end
  end

  def handle_event("save", %{"cohort" => params}, socket) do
    case socket.assigns.editing do
      %Cohort{id: nil} -> persist(socket, Catalog.create_cohort(params))
      cohort -> persist(socket, Catalog.update_cohort(cohort, params))
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket) do
    record =
      case socket.assigns.tab do
        "cohorts" -> Catalog.get_cohort!(id)
        _teachers -> Catalog.get_teacher!(id)
      end

    {:noreply, assign(socket, :deleting, record)}
  end

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, socket) do
    record = socket.assigns.deleting

    case delete(socket.assigns.tab, record) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> put_flash(:info, gettext("Deleted %{name}.", name: record.name))
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
    end
  end

  defp persist(socket, {:ok, record}) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Saved %{name}.", name: record.name))
     |> push_patch(to: ~p"/people?tab=#{socket.assigns.tab}")
     |> load()}
  end

  defp persist(socket, {:error, reason}), do: {:noreply, Errors.put(socket, reason, as: :form)}

  # The list disables deletion of used records; this catches a concurrent change.
  defp delete("cohorts", cohort) do
    Catalog.delete_cohort(cohort)
  rescue
    Ecto.ConstraintError ->
      {:error, {:conflict, gettext("%{name} still attends a session.", name: cohort.name)}}
  end

  defp delete(_teachers, teacher) do
    Catalog.delete_teacher(teacher)
  rescue
    Ecto.ConstraintError ->
      {:error, {:conflict, gettext("%{name} still teaches a session.", name: teacher.name)}}
  end

  defp load(socket) do
    usage = Catalog.usage_counts()

    socket
    |> assign(:teachers, Catalog.list_teachers())
    |> assign(:cohorts, Catalog.list_cohorts())
    |> assign(:teacher_usage, usage.teachers)
    |> assign(:teacher_exceptions, Catalog.teacher_exception_usage())
    |> assign(:cohort_usage, usage.cohorts)
  end

  # Names the reference that prevents deletion, or nil when the record is free.
  defp teacher_blocker(assigns, teacher) do
    sessions = Map.get(assigns.teacher_usage, teacher.id, 0)
    changes = Map.get(assigns.teacher_exceptions, teacher.id, 0)

    cond do
      sessions > 0 ->
        sessions_blocker(sessions)

      changes > 0 ->
        ngettext("Named in %{count} one-off change", "Named in %{count} one-off changes", changes,
          count: changes
        )

      true ->
        nil
    end
  end

  defp cohort_blocker(assigns, cohort) do
    case Map.get(assigns.cohort_usage, cohort.id, 0) do
      0 -> nil
      count -> sessions_blocker(count)
    end
  end

  defp sessions_blocker(count),
    do: ngettext("Used by %{count} session", "Used by %{count} sessions", count, count: count)

  # Flag short single-token names as possible abbreviations.
  defp placeholder?(%{name: name}) do
    not String.contains?(name, " ") and String.length(name) <= 4
  end

  defp subgroup?(%{name: name}), do: Regex.match?(@subgroup, name)

  # Aggregate names may represent independent sections incorrectly assigned to one group.
  defp aggregate?(%{name: name}), do: String.contains?(name, "(")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@navigation_term)}
      current_path={~p"/people"}
      terms={@navigation_terms}
      current_term={@navigation_term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">
        {Nav.return_label(@return_to)}
      </.link>
      <.page_header title={gettext("Teachers and groups")}>
        <:actions>
          <.link patch={~p"/people?tab=#{@tab}&new=1"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" />
            {if @tab == "cohorts", do: gettext("New group"), else: gettext("New teacher")}
          </.link>
        </:actions>
      </.page_header>

      <.tabs
        active={~p"/people?tab=#{@tab}"}
        items={[
          %{label: gettext("Teachers"), path: ~p"/people?tab=teachers"},
          %{label: gettext("Groups"), path: ~p"/people?tab=cohorts"}
        ]}
      />

      <div class={["grid gap-4", @editing && "lg:grid-cols-[2fr_1fr]"]}>
        <div class="min-w-0">
          <.empty_state
            :if={@tab == "teachers" and @teachers == []}
            title={gettext("No teachers yet")}
            message={gettext("Add the teachers who give sessions.")}
            icon="hero-users"
          >
            <:actions>
              <.link patch={~p"/people?tab=teachers&new=1"} class="btn btn-primary">
                {gettext("New teacher")}
              </.link>
            </:actions>
          </.empty_state>

          <.table
            :if={@tab == "teachers" and @teachers != []}
            id="teachers"
            rows={@teachers}
            row_id={&"teacher-#{&1.id}"}
          >
            <:col :let={teacher} label={gettext("Name")}>
              <span class="font-semibold">{teacher.name}</span>
            </:col>
            <:col :let={teacher} label={gettext("Sessions")} numeric>
              {Map.get(@teacher_usage, teacher.id, 0)}
            </:col>
            <:col :let={teacher} label={gettext("Review")}>
              <span :if={placeholder?(teacher)}>{gettext("Check full name")}</span>
            </:col>
            <:action :let={teacher}>
              <.link patch={~p"/people?tab=teachers&edit=#{teacher.id}"} class="btn btn-ghost">
                {gettext("Edit")}
              </.link>
              <button
                class="btn btn-ghost text-error"
                phx-click="delete_prompt"
                phx-value-id={teacher.id}
                disabled={teacher_blocker(assigns, teacher) != nil}
                title={teacher_blocker(assigns, teacher)}
              >
                {gettext("Delete")}
              </button>
            </:action>
          </.table>

          <.empty_state
            :if={@tab == "cohorts" and @cohorts == []}
            title={gettext("No groups yet")}
            message={gettext("Add the groups that attend sessions.")}
            icon="hero-users"
          >
            <:actions>
              <.link patch={~p"/people?tab=cohorts&new=1"} class="btn btn-primary">
                {gettext("New group")}
              </.link>
            </:actions>
          </.empty_state>

          <.table
            :if={@tab == "cohorts" and @cohorts != []}
            id="cohorts"
            rows={@cohorts}
            row_id={&"cohort-#{&1.id}"}
          >
            <:col :let={cohort} label={gettext("Name")}>
              <span class="font-semibold">{cohort.name}</span>
            </:col>
            <:col :let={cohort} label={gettext("Sessions")} numeric>
              {Map.get(@cohort_usage, cohort.id, 0)}
            </:col>
            <:col :let={cohort} label={gettext("Review")}>
              <span :if={aggregate?(cohort)}>{gettext("Check group membership")}</span>
              <span :if={subgroup?(cohort)}>{gettext("Language subgroup")}</span>
            </:col>
            <:action :let={cohort}>
              <.link patch={~p"/people?tab=cohorts&edit=#{cohort.id}"} class="btn btn-ghost">
                {gettext("Edit")}
              </.link>
              <button
                class="btn btn-ghost text-error"
                phx-click="delete_prompt"
                phx-value-id={cohort.id}
                disabled={cohort_blocker(assigns, cohort) != nil}
                title={cohort_blocker(assigns, cohort)}
              >
                {gettext("Delete")}
              </button>
            </:action>
          </.table>
        </div>

        <.details_panel
          :if={@editing}
          class="order-first lg:order-last"
          title={inspector_title(@kind, @editing)}
          on_close={JS.patch(~p"/people?tab=#{@tab}")}
        >
          <.form
            :if={@kind == :teacher}
            for={@form}
            id="teacher-form"
            phx-mounted={JS.focus_first(to: "#teacher-form")}
            phx-change="validate"
            phx-submit="save"
          >
            <.input field={@form[:name]} type="text" label={gettext("Full name")} />
            <div class="flex gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
              <.link patch={~p"/people?tab=teachers"} class="btn btn-ghost">{gettext("Cancel")}</.link>
            </div>
          </.form>

          <.form
            :if={@kind == :cohort}
            for={@form}
            id="cohort-form"
            phx-mounted={JS.focus_first(to: "#cohort-form")}
            phx-change="validate"
            phx-submit="save"
          >
            <.input field={@form[:name]} type="text" label={gettext("Group name")} />
            <div class="flex gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
              <.link patch={~p"/people?tab=cohorts"} class="btn btn-ghost">{gettext("Cancel")}</.link>
            </div>
          </.form>
        </.details_panel>
      </div>

      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete %{name}?", name: @deleting.name)}
        message={delete_message(@deleting)}
        confirm_label={gettext("Delete")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end

  defp delete_message(%Cohort{name: name}),
    do: gettext("Deletes the group %{name}. This cannot be undone.", name: name)

  defp delete_message(%Teacher{name: name}),
    do: gettext("Deletes the teacher %{name}. This cannot be undone.", name: name)

  defp inspector_title(:cohort, %Cohort{id: nil}), do: gettext("New group")
  defp inspector_title(:cohort, _record), do: gettext("Edit group")
  defp inspector_title(_teacher, %Teacher{id: nil}), do: gettext("New teacher")
  defp inspector_title(_teacher, _record), do: gettext("Edit teacher")
end
