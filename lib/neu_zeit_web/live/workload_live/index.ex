defmodule NeuZeitWeb.WorkloadLive.Index do
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.Workload
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Teaching load"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:teachers, Catalog.list_teachers())
     |> assign(:cohorts, Catalog.list_cohorts())
     |> assign(:profiles, Catalog.list_slot_profiles(term_id))
     |> assign(:components, Catalog.list_course_components())
     |> assign(:rows, Catalog.list_workload(term_id))
     |> assign(:form, nil)
     |> assign(:editing, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    rows = Catalog.list_workload(socket.assigns.term.id)
    socket = socket |> Nav.assign_return(params) |> assign(:rows, rows)

    case socket.assigns.live_action do
      :new ->
        {:noreply,
         open_form(socket, nil, %Workload{week_mask: all_weeks(socket), automatic_weeks: true})}

      :edit ->
        case Enum.find(rows, fn row ->
               row.id == params["id"] || Enum.any?(row.sessions, &(&1.id == params["id"]))
             end) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("The workload changed. Reload it before saving."))
             |> push_patch(to: ~p"/terms/#{socket.assigns.term}/workload")}

          row ->
            {:noreply,
             open_form(
               socket,
               row,
               Workload.from_row(row, socket.assigns.term.academic_hour_minutes)
             )}
        end

      :index ->
        {:noreply, assign(socket, form: nil, editing: nil)}
    end
  end

  defp open_form(socket, row, workload) do
    socket
    |> assign(:editing, row)
    |> assign(:automatic_weeks, workload.automatic_weeks)
    |> assign(:week_mask, workload.week_mask)
    |> assign(:cohort_ids, workload.cohort_ids)
    |> assign(
      :form,
      to_form(
        Workload.changeset(%{
          workload
          | academic_hour_minutes: socket.assigns.term.academic_hour_minutes
        })
      )
    )
  end

  defp all_weeks(socket), do: Enum.to_list(1..socket.assigns.term.weeks_count)

  @impl true
  def handle_event("week_mask_changed", %{"preset" => preset}, socket) do
    weeks = all_weeks(socket)

    mask =
      case preset do
        "odd" -> Enum.filter(weeks, &(rem(&1, 2) == 1))
        "even" -> Enum.filter(weeks, &(rem(&1, 2) == 0))
        _ -> weeks
      end

    {:noreply, assign(socket, :week_mask, mask)}
  end

  def handle_event("week_mask_changed", %{"week" => week}, socket) do
    week = String.to_integer(week)
    mask = socket.assigns.week_mask

    {:noreply,
     assign(
       socket,
       :week_mask,
       if(week in mask, do: List.delete(mask, week), else: Enum.sort([week | mask]))
     )}
  end

  def handle_event("selection_changed", %{"selected" => ids}, socket),
    do: {:noreply, assign(socket, :cohort_ids, ids)}

  def handle_event("save", %{"workload" => params}, socket) do
    attrs =
      params
      |> Map.put("automatic_weeks", socket.assigns.automatic_weeks)
      |> Map.put("week_mask", socket.assigns.week_mask)
      |> Map.put("cohort_ids", socket.assigns.cohort_ids)
      |> Map.put(
        "sequence_group",
        socket.assigns.editing && socket.assigns.editing.session.sequence_group
      )

    case Catalog.save_workload(socket.assigns.term.id, socket.assigns.editing, attrs) do
      {:ok, :saved} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Teaching load saved."))
         |> push_patch(to: ~p"/terms/#{socket.assigns.term}/workload")}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/workload"}
      terms={@terms}
      current_term={@term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">{gettext("Return to timetable")}</.link>
      <.page_header title={gettext("Teaching load")}>
        <:actions>
          <.link patch={~p"/terms/#{@term}/workload/new"} class="btn">{gettext("Add teaching load")}</.link>
        </:actions>
      </.page_header>

      <div class={["grid gap-4", @form && "lg:grid-cols-[3fr_2fr]"]}>
        <div class="min-w-0">
          <.table
            id="workload"
            rows={@rows}
            row_id={&"workload-#{&1.id}"}
            empty_message={gettext("Add subjects, teachers and groups to the teaching load.")}
          >
            <:col :let={row} label={gettext("Course")}>
              <.link
                navigate={
                  Nav.with_return(
                    ~p"/courses/#{row.session.course_component.course_id}",
                    ~p"/terms/#{@term}/workload"
                  )
                }
                class="link"
              >{row.session.course_component.course.code}</.link>
              <div>{component_kind_label(row.session.course_component.kind)}</div>
            </:col>
            <:col :let={row} label={gettext("Teacher")} class="whitespace-nowrap">
              {row.session.teacher.name}
            </:col>
            <:col :let={row} label={gettext("Groups")} class="whitespace-nowrap">
              {Enum.map_join(row.session.cohorts, ", ", & &1.name)}
            </:col>
            <:col :let={row} label={gettext("Academic hours")} numeric>
              {Workload.hours(row, @term.academic_hour_minutes)}
            </:col>
            <:col :let={row} label={gettext("Consecutive time slots")} numeric>
              {row.session.duration_slots}
            </:col>
            <:col :let={row} label={gettext("Weeks")} class="whitespace-nowrap">
              <span :if={
                row.session.automatic_weeks && length(row.session.week_mask) == @term.weeks_count
              }>{gettext("Automatic")}</span>
              <.teaching_weeks
                :if={
                  !row.session.automatic_weeks || length(row.session.week_mask) != @term.weeks_count
                }
                weeks={row.session.week_mask}
                total={@term.weeks_count}
                compact
              />
            </:col>
            <:col :let={row} label={gettext("Time profile")} class="whitespace-nowrap">
              {if row.session.slot_profile,
                do: slot_profile_label(row.session.slot_profile),
                else: gettext("No restriction")}
            </:col>
            <:action :let={row}>
              <.link patch={~p"/terms/#{@term}/workload/#{row.id}/edit"} class="btn btn-ghost">{gettext(
                "Edit"
              )}</.link>
            </:action>
          </.table>
          <.link navigate={~p"/terms/#{@term}/sessions"} class="link inline-block mt-4">{gettext(
            "Individual sessions"
          )}</.link>
        </div>
        <.details_panel
          :if={@form}
          title={if @editing, do: gettext("Edit teaching load"), else: gettext("Add teaching load")}
          class="order-first lg:order-last"
          on_close={JS.patch(~p"/terms/#{@term}/workload")}
        >
          <.form for={@form} id="workload-form" phx-submit="save" class="flex flex-col gap-4">
            <.input
              field={@form[:course_component_id]}
              type="select"
              label={gettext("Teaching type")}
              prompt={gettext("Choose a teaching type")}
              options={
                Enum.map(
                  @components,
                  &{"#{&1.course.code} #{&1.course.title} / #{component_kind_label(&1.kind)}", &1.id}
                )
              }
            />
            <.input
              field={@form[:teacher_id]}
              type="select"
              label={gettext("Teacher")}
              prompt={gettext("Choose a teacher")}
              options={Enum.map(@teachers, &{&1.name, &1.id})}
            />
            <.input
              field={@form[:contact_hours]}
              type="number"
              label={
                gettext("Academic hours per semester (%{minutes} min)",
                  minutes: @term.academic_hour_minutes
                )
              }
              min="0.01"
              step="any"
              required
            />
            <.input
              field={@form[:duration_slots]}
              type="number"
              label={gettext("Consecutive time slots")}
              min="1"
            />
            <.input
              field={@form[:slot_profile_id]}
              type="select"
              label={gettext("Time profile")}
              prompt={gettext("No restriction")}
              options={Enum.map(@profiles, &{slot_profile_label(&1), &1.id})}
            />
            <details
              id="workload-week-limit"
              class="collapse collapse-arrow bg-base-200"
              open={!@automatic_weeks}
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary class="collapse-title">
                {if @automatic_weeks,
                  do: gettext("Restrict available weeks"),
                  else: gettext("Fixed teaching weeks")}
              </summary>
              <div class="collapse-content">
                <.week_selector
                  id="workload-weeks"
                  weeks={@week_mask}
                  total={@term.weeks_count}
                  parity_presets={!@automatic_weeks}
                />
                <p :for={{message, opts} <- @form[:week_mask].errors} class="text-error">
                  {Errors.translate_validation({message, opts})}
                </p>
              </div>
            </details>
            <fieldset class="fieldset">
              <legend class="fieldset-legend">{gettext("Groups")}</legend>
              <p>{gettext("For a shared session, select all attending groups.")}</p>
              <.transfer_list
                id="workload-cohorts"
                available={cohort_items(@cohorts, @cohort_ids, false)}
                selected={cohort_items(@cohorts, @cohort_ids, true)}
                available_label={gettext("Other groups")}
                selected_label={gettext("Attending")}
              />
              <p :for={{message, opts} <- @form[:cohort_ids].errors} class="text-error">
                {Errors.translate_validation({message, opts})}
              </p>
            </fieldset>
            <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
          </.form>
        </.details_panel>
      </div>
    </Layouts.app>
    """
  end

  defp cohort_items(cohorts, selected, selected?) do
    cohorts
    |> Enum.filter(&(&1.id in selected == selected?))
    |> Enum.map(&%{id: &1.id, label: &1.name})
  end
end
