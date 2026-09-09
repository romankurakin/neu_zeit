defmodule NeuZeitWeb.CourseLive.Index do
  @moduledoc """
  Lists and edits courses.

  A course has at most one component per teaching type. Parallel classes are
  separate sessions of that component.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.Course
  alias NeuZeitWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Courses")) |> assign(:deleting, nil) |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = Nav.assign_return(socket, params)
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    assign_form(socket, %Course{}, Catalog.change_course(%Course{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    course = Catalog.get_course!(id)
    assign_form(socket, course, Catalog.change_course(course))
  end

  defp apply_action(socket, :index, _params) do
    socket |> assign(:editing, nil) |> assign(:form, nil)
  end

  defp assign_form(socket, course, changeset) do
    socket |> assign(:editing, course) |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"course" => params}, socket) do
    changeset = Catalog.change_course(socket.assigns.editing, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"course" => params}, socket) do
    result =
      case socket.assigns.editing do
        %Course{id: nil} -> Catalog.create_course(params)
        course -> Catalog.update_course(course, params)
      end

    case result do
      {:ok, course} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved %{name}.", name: course.code))
         |> push_patch(to: ~p"/courses")
         |> load()}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :deleting, Catalog.get_course!(id))}

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, socket) do
    course = socket.assigns.deleting

    case delete(course) do
      {:ok, _course} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> put_flash(:info, gettext("Deleted %{name}.", name: course.code))
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
    end
  end

  # Components cascade with the course, but a component still used by a session
  # is protected, which protects the course too.
  defp delete(course) do
    Catalog.delete_course(course)
  rescue
    Ecto.ConstraintError ->
      {:error, {:conflict, gettext("%{name} still has sessions in a term.", name: course.code)}}
  end

  defp load(socket) do
    courses = Catalog.list_courses()

    socket
    |> assign(:courses, courses)
    |> assign(:usage, Catalog.usage_counts().components)
  end

  defp session_count(course, usage),
    do: Enum.reduce(course.components, 0, &(&2 + Map.get(usage, &1.id, 0)))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={Nav.sections(@navigation_term)} current_path={~p"/courses"} terms={@navigation_terms} current_term={@navigation_term}>
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">{gettext("Return to timetable")}</.link>
      <.page_header title={gettext("Courses")}>
        <:actions>
          <.link patch={~p"/courses/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> {gettext("New course")}
          </.link>
        </:actions>
      </.page_header>

      <div class={["grid gap-4", @editing && "lg:grid-cols-[2fr_1fr]"]}>
        <div class="min-w-0">
          <.empty_state
            :if={@courses == []}
            title={gettext("No courses yet")}
            message={gettext("Add a course and choose allowed rooms for each teaching type.")}
            icon="hero-academic-cap"
          />

          <.table :if={@courses != []} id="courses" rows={@courses} row_id={&"course-#{&1.id}"}>
            <:col :let={course} label={gettext("Code")} class="whitespace-nowrap">
              <.link navigate={Nav.with_return(~p"/courses/#{course}", @return_to)} class="link link-hover font-semibold inline-block">
                {course.code}
              </.link>
            </:col>
            <:col :let={course} label={gettext("Title")}>{course.title}</:col>
            <:col :let={course} label={gettext("Credits")} numeric>{course.credits}</:col>
            <:col :let={course} label={gettext("Teaching types")}>
              <span class="flex gap-1">
                <span :for={component <- course.components} class="badge badge-ghost badge-md">
                  {component_kind_label(component.kind)}
                </span>
                <span :if={course.components == []} class="type-detail text-warning">
                  {gettext("none")}
                </span>
              </span>
            </:col>
            <:col :let={course} label={gettext("Sessions")} numeric>{session_count(course, @usage)}</:col>
            <:action :let={course}>
              <.link patch={~p"/courses/#{course}/edit"} class="btn btn-ghost">
                {gettext("Edit")}
              </.link>
              <button
                class="btn btn-ghost text-error"
                phx-click="delete_prompt"
                phx-value-id={course.id}
              >
                {gettext("Delete")}
              </button>
            </:action>
          </.table>
        </div>

        <.details_panel
          class="order-first lg:order-last"
          :if={@editing}
          title={if @editing.id, do: gettext("Edit course"), else: gettext("New course")}
        >
          <.form for={@form} id="course-form" phx-mounted={JS.focus_first(to: "#course-form")} phx-change="validate" phx-submit="save">
            <.input field={@form[:code]} type="text" label={gettext("Code")} placeholder="INF110" />
            <.input field={@form[:title]} type="text" label={gettext("Title")} />
            <.input field={@form[:credits]} type="number" label={gettext("Credits")} step="0.5" min="0" />
            <div class="flex gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
              <.link patch={~p"/courses"} class="btn btn-ghost">{gettext("Cancel")}</.link>
            </div>
          </.form>
        </.details_panel>
      </div>

      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete %{name}?", name: @deleting.code)}
        message={
          gettext(
            "Teaching types will also be deleted. Courses used by sessions cannot be deleted."
          )
        }
        confirm_label={gettext("Delete")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end
end
