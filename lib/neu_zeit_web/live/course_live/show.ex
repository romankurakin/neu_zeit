defmodule NeuZeitWeb.CourseLive.Show do
  @moduledoc """
  Edits teaching types, allowed rooms and translated titles for one course.

  Room suitability is entered through allowed-room lists. Capacity and equipment
  are not separate fields in the current model.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.CourseTranslation
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:rooms, Catalog.list_rooms())
     |> assign(:locales, NeuZeitWeb.Locale.supported())
     |> assign(
       :translation_form,
       to_form(Catalog.change_course_translation(%CourseTranslation{}))
     )
     |> assign(:deleting, nil)
     |> load(id)}
  end

  defp load(socket, id) do
    course = Catalog.get_course!(id)
    components = Enum.map(course.components, &Catalog.get_course_component!(&1.id))

    socket
    |> assign(:page_title, course_title(course))
    |> assign(:course, course)
    |> assign(:components, components)
    |> assign(:teaching_types, Catalog.list_teaching_types())
    |> assign(
      :translations,
      Enum.filter(
        Catalog.list_course_translations(course.id),
        &(&1.locale in socket.assigns.locales)
      )
    )
    |> assign(:usage, Catalog.usage_counts().components)
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, Nav.assign_return(socket, params)}

  @impl true
  def handle_event("selection_changed", %{"id" => dom_id, "selected" => room_ids}, socket) do
    component_id =
      String.replace_prefix(dom_id, "component-", "") |> String.replace_suffix("-rooms", "")

    component = Enum.find(socket.assigns.components, &(&1.id == component_id))

    case Catalog.update_course_component(component, %{"allowed_room_ids" => room_ids}) do
      {:ok, _component} ->
        {:noreply, load(socket, socket.assigns.course.id)}

      {:error, reason} ->
        # Show the context error if the room change conflicts with existing placements.
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("add_component", %{"kind" => kind} = params, socket) do
    room_ids = Map.get(params, "room_ids", [])

    attrs = %{
      "course_id" => socket.assigns.course.id,
      "kind" => kind,
      "allowed_room_ids" => room_ids
    }

    case Catalog.create_course_component(attrs) do
      {:ok, component} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Teaching type added: %{kind}.",
             kind: component_kind_label(Catalog.get_course_component!(component.id))
           )
         )
         |> load(socket.assigns.course.id)}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("delete_component_prompt", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :deleting, Catalog.get_course_component!(id))}

  def handle_event("delete_component_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_component_confirm", _params, socket) do
    component = socket.assigns.deleting

    case delete_component(component) do
      {:ok, _component} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> put_flash(
           :info,
           gettext("Teaching type removed: %{kind}.", kind: component_kind_label(component))
         )
         |> load(socket.assigns.course.id)}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
    end
  end

  def handle_event("save_translation", %{"course_translation" => params}, socket) do
    course_id = socket.assigns.course.id
    locale = params["locale"]

    result =
      case Catalog.get_course_translation(course_id, locale) do
        nil ->
          Catalog.create_course_translation(Map.put(params, "course_id", course_id))

        existing ->
          Catalog.update_course_translation(existing, params)
      end

    case result do
      {:ok, _translation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved the %{locale} title.", locale: locale))
         |> assign(
           :translation_form,
           to_form(Catalog.change_course_translation(%CourseTranslation{}))
         )
         |> load(course_id)}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :translation_form)}
    end
  end

  def handle_event("delete_translation", %{"locale" => locale}, socket) do
    course_id = socket.assigns.course.id

    case Catalog.get_course_translation(course_id, locale) do
      nil ->
        {:noreply, socket}

      translation ->
        {:ok, _} = Catalog.delete_course_translation(translation)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Removed the %{locale} title.", locale: locale))
         |> load(course_id)}
    end
  end

  defp delete_component(component) do
    Catalog.delete_course_component(component)
  rescue
    Ecto.ConstraintError ->
      {:error, {:conflict, gettext("Sessions still use this teaching type.")}}
  end

  defp missing_types(teaching_types, components) do
    used = MapSet.new(components, & &1.kind)
    Enum.reject(teaching_types, &MapSet.member?(used, &1.id))
  end

  # Room counts are advice; they do not impose a scheduling constraint.
  defp pool_status(count) when count == 0 or count in 2..5, do: :ok
  defp pool_status(_count), do: :warning

  defp pool_advice(0), do: gettext("Any available room")
  defp pool_advice(1), do: gettext("1 room. Check whether alternatives are available.")

  defp pool_advice(count) when count > 5,
    do:
      ngettext(
        "%{count} room. Check that it is suitable.",
        "%{count} rooms. Check that each is suitable.",
        count,
        count: count
      )

  # Russian uses different plural forms for counts such as 3 and 5.
  defp pool_advice(count),
    do: ngettext("%{count} room", "%{count} rooms", count, count: count)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@navigation_term)}
      current_path={~p"/courses"}
      terms={@navigation_terms}
      current_term={@navigation_term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">{gettext("Return to timetable")}</.link>
      <.page_header title={course_title(@course)} subtitle={@course.code}>
        <:actions>
          <.link navigate={~p"/courses"} class="btn btn-ghost">{gettext("All courses")}</.link>
          <.link patch={~p"/courses/#{@course}/edit"} class="btn">{gettext("Edit course")}</.link>
        </:actions>
      </.page_header>

      <div class="flex flex-col gap-4">
        <.card title={gettext("Teaching types and allowed rooms")}>
          <.link
            navigate={Nav.with_return(~p"/teaching-types", ~p"/courses/#{@course}")}
            class="btn btn-ghost mb-4"
          >
            {gettext("Manage teaching types")}
          </.link>

          <div :if={@components == []} class="mb-4">
            <.empty_state
              title={gettext("No teaching types yet")}
              message={gettext("Add a teaching type. You can restrict its rooms later.")}
              icon="hero-squares-2x2"
            />
          </div>

          <div class="flex flex-col gap-4">
            <div :for={component <- @components} id={"component-#{component.id}"}>
              <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
                <h3 class="flex items-center gap-2 type-heading">
                  {component_kind_label(component)}
                  <span class="badge badge-ghost badge-md">
                    {ngettext(
                      "%{count} session",
                      "%{count} sessions",
                      Map.get(@usage, component.id, 0),
                      count: Map.get(@usage, component.id, 0)
                    )}
                  </span>
                </h3>
                <span class="flex items-center gap-2">
                  <.status_indicator
                    status={pool_status(length(component.allowed_rooms))}
                    label={pool_advice(length(component.allowed_rooms))}
                  />
                  <button
                    class="btn btn-ghost text-error"
                    phx-click="delete_component_prompt"
                    phx-value-id={component.id}
                  >
                    {gettext("Delete teaching type")}
                  </button>
                </span>
              </div>

              <.transfer_list
                id={"component-#{component.id}-rooms"}
                available={room_items(@rooms, component.allowed_rooms, false)}
                selected={room_items(@rooms, component.allowed_rooms, true)}
                available_label={gettext("Other rooms")}
                selected_label={gettext("Allowed rooms")}
              />
            </div>
          </div>

          <form
            :if={missing_types(@teaching_types, @components) != []}
            id="add-component-form"
            phx-submit="add_component"
            class="mt-6 rounded-box border border-dashed border-base-300 p-4"
          >
            <p class="mb-4 type-detail text-base-content">
              {gettext("Leave the room list empty to use any available room.")}
            </p>

            <div class="flex flex-wrap items-start gap-4">
              <label class="form-control">
                <span class="label-text mb-1 block type-detail">{gettext("Kind")}</span>
                <select name="kind" class="select select-bordered">
                  <option :for={type <- missing_types(@teaching_types, @components)} value={type.id}>
                    {teaching_type_label(type)}
                  </option>
                </select>
              </label>

              <fieldset class="min-w-64 flex-1">
                <legend class="label-text mb-1 block type-detail">{gettext("Allowed rooms")}</legend>
                <div class="flex max-h-32 flex-wrap gap-x-4 gap-y-1 overflow-y-auto rounded-field border border-base-300 p-2">
                  <label
                    :for={room <- @rooms}
                    class="flex cursor-pointer items-center gap-1 type-detail"
                  >
                    <input
                      type="checkbox"
                      name="room_ids[]"
                      value={room.id}
                      class="checkbox checkbox-xs"
                    />
                    {room.name}
                  </label>
                </div>
              </fieldset>

              <.button variant="primary" phx-disable-with={gettext("Adding")}>
                {gettext("Add teaching type")}
              </.button>
            </div>
          </form>
        </.card>

        <.card title={gettext("Translated titles")}>
          <p class="mb-4 type-detail text-base-content">
            {gettext("If no translation is entered, the course title above is shown.")}
          </p>

          <.table
            id="translations"
            rows={@translations}
            row_id={&"translation-#{&1.id}"}
            empty_message={gettext("No translations yet.")}
          >
            <:col :let={translation} label={gettext("Language")}>
              <span class="badge badge-ghost badge-md uppercase">{translation.locale}</span>
            </:col>
            <:col :let={translation} label={gettext("Title")}>{translation.title}</:col>
            <:action :let={translation}>
              <button
                class="btn btn-ghost text-error"
                phx-click="delete_translation"
                phx-value-locale={translation.locale}
              >
                {gettext("Delete translation")}
              </button>
            </:action>
          </.table>

          <.form
            for={@translation_form}
            id="translation-form"
            phx-submit="save_translation"
            class="mt-4 flex flex-wrap items-end gap-2"
          >
            <.input
              field={@translation_form[:locale]}
              type="select"
              label={gettext("Language")}
              options={Enum.map(@locales, &{NeuZeitWeb.Locale.label(&1), &1})}
            />
            <div class="min-w-64 flex-1">
              <.input
                field={@translation_form[:title]}
                type="text"
                label={gettext("Translated title")}
              />
            </div>
            <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save title")}</.button>
          </.form>
        </.card>
      </div>

      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete this teaching type?")}
        message={
          gettext(
            "Its allowed room list will also be deleted. Teaching types used by sessions cannot be deleted."
          )
        }
        confirm_label={gettext("Delete teaching type")}
        on_confirm="delete_component_confirm"
        on_cancel="delete_component_cancel"
      />
    </Layouts.app>
    """
  end

  defp room_items(rooms, allowed, selected?) do
    allowed_ids = MapSet.new(allowed, & &1.id)

    rooms
    |> Enum.filter(&(MapSet.member?(allowed_ids, &1.id) == selected?))
    |> Enum.map(&%{id: &1.id, label: &1.name, hint: &1.building.name})
  end
end
