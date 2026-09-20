defmodule NeuZeitWeb.WorkloadLive.Index do
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.{Workload, Workloads}
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
     |> assign(:duration_options, Workloads.duration_options(term))
     |> assign(:rows, Workloads.list(term_id))
     |> assign(:form, nil)
     |> assign(:editing, nil)
     |> assign(:deleting, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    rows = Workloads.list(socket.assigns.term.id)
    socket = socket |> Nav.assign_return(params) |> assign(:rows, rows)

    case socket.assigns.live_action do
      :new ->
        {:noreply, open_form(socket, nil, Workload.new(socket.assigns.term))}

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
               row.requirement
             )}
        end

      :index ->
        {:noreply, assign(socket, form: nil, editing: nil)}
    end
  end

  defp open_form(socket, row, workload) do
    socket
    |> assign(:editing, row)
    |> assign(:workload, workload)
    |> assign(:automatic_weeks, workload.automatic_weeks)
    |> assign(:week_mask, workload.week_mask)
    |> assign(:cohort_ids, workload.cohort_ids)
    |> update_form(%{})
  end

  defp update_form(socket, params, action \\ nil) do
    changeset =
      socket.assigns.workload
      |> Workload.changeset(socket.assigns.term, workload_attrs(socket, params))
      |> Map.put(:action, action)

    socket
    |> assign(:form, to_form(changeset))
    |> assign(
      :preview,
      Workload.preview(changeset, socket.assigns.term, socket.assigns.editing)
    )
  end

  defp workload_attrs(socket, params) do
    params
    |> Map.put("week_mask", socket.assigns.week_mask)
    |> Map.put("cohort_ids", socket.assigns.cohort_ids)
    |> Map.put("sequence_group", socket.assigns.workload.sequence_group)
  end

  defp all_weeks(socket), do: Enum.to_list(1..socket.assigns.term.weeks_count)

  @impl true
  def handle_event("validate", %{"workload" => params}, socket),
    do: {:noreply, update_form(socket, params, :validate)}

  def handle_event("week_mask_changed", %{"preset" => preset}, socket) do
    weeks = all_weeks(socket)

    mask =
      case preset do
        "odd" -> Enum.filter(weeks, &(rem(&1, 2) == 1))
        "even" -> Enum.filter(weeks, &(rem(&1, 2) == 0))
        _ -> weeks
      end

    {:noreply,
     socket |> assign(:week_mask, mask) |> update_form(socket.assigns.form.params, :validate)}
  end

  def handle_event("week_mask_changed", %{"week" => week}, socket) do
    week = String.to_integer(week)
    mask = socket.assigns.week_mask

    {:noreply,
     socket
     |> assign(
       :week_mask,
       if(week in mask, do: List.delete(mask, week), else: Enum.sort([week | mask]))
     )
     |> update_form(socket.assigns.form.params, :validate)}
  end

  def handle_event("selection_changed", %{"selected" => ids}, socket),
    do:
      {:noreply,
       socket |> assign(:cohort_ids, ids) |> update_form(socket.assigns.form.params, :validate)}

  def handle_event("save", %{"workload" => params}, socket) do
    attrs = workload_attrs(socket, params)
    socket = update_form(socket, params)

    case Workloads.save(socket.assigns.term.id, socket.assigns.editing, attrs) do
      {:ok, :saved} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Teaching load saved."))
         |> push_patch(to: ~p"/terms/#{socket.assigns.term}/workload")}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket) do
    row = Enum.find(socket.assigns.rows, &(&1.id == id))
    {:noreply, assign(socket, :deleting, row)}
  end

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, %{assigns: %{deleting: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("delete_confirm", _params, socket) do
    case Workloads.delete(socket.assigns.term.id, socket.assigns.deleting) do
      {:ok, :deleted} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> push_patch(to: ~p"/terms/#{socket.assigns.term}/workload")}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
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
                    ~p"/courses/#{row.requirement.course_component.course_id}",
                    ~p"/terms/#{@term}/workload"
                  )
                }
                class="link"
              >{course_title(row.requirement.course_component.course)}</.link>
              <div>{component_kind_label(row.requirement.course_component)}</div>
            </:col>
            <:col :let={row} label={gettext("Teacher")} class="whitespace-nowrap">
              {row.requirement.teacher.name}
            </:col>
            <:col :let={row} label={gettext("Groups")} class="whitespace-nowrap">
              {Enum.map_join(row.requirement.cohorts, ", ", & &1.name)}
            </:col>
            <:col :let={row} label={gettext("Required hours")} numeric>
              {decimal(Workloads.hours(row))}
            </:col>
            <:col :let={row} label={gettext("Hours from sessions")} numeric>
              {rounded_decimal(Workloads.planned_hours(row, @term))}
            </:col>
            <:col :let={row} label={gettext("Difference")} numeric>
              <span class={if !Decimal.equal?(row_difference(row, @term), 0), do: "text-warning"}>
                {signed_decimal(row_difference(row, @term))}
              </span>
            </:col>
            <:col :let={row} label={gettext("Session duration")}>
              {duration_label(
                Enum.find(@duration_options, &(&1.slots == row.requirement.duration_slots))
              )}
            </:col>
            <:col :let={row} label={gettext("Weekly pattern")}>
              <span :if={row.requirement.automatic_weeks}>{gettext(
                "Weeks selected during calculation"
              )}</span>
              <div :if={!row.requirement.automatic_weeks}>
                <p :for={
                  label <- rhythm_labels(Enum.map(row.sessions, & &1.week_mask), @term.weeks_count)
                }>
                  {label}
                </p>
              </div>
            </:col>
            <:col :let={row} label={gettext("Time profile")} class="whitespace-nowrap">
              {if row.requirement.slot_profile,
                do: slot_profile_label(row.requirement.slot_profile),
                else: gettext("No restriction")}
            </:col>
            <:action :let={row}>
              <button class="btn btn-ghost text-error" phx-click="delete_prompt" phx-value-id={row.id}>{gettext(
                "Delete"
              )}</button>
              <.link patch={~p"/terms/#{@term}/workload/#{row.id}/edit"} class="btn btn-ghost">{gettext(
                "Edit"
              )}</.link>
            </:action>
          </.table>
        </div>
        <.details_panel
          :if={@form}
          title={if @editing, do: gettext("Edit teaching load"), else: gettext("Add teaching load")}
          class="order-first lg:order-last"
          on_close={JS.patch(~p"/terms/#{@term}/workload")}
        >
          <.form
            for={@form}
            id="workload-form"
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-4"
          >
            <div :if={@components == []} id="workload-teaching-types-help" role="status">
              <p>
                {gettext(
                  "No teaching types are assigned to courses. Open a course, add a teaching type and at least one allowed room, then return to teaching load."
                )}
              </p>
              <.link navigate={~p"/courses"} class="link">{gettext("All courses")}</.link>
            </div>
            <.input
              field={@form[:course_component_id]}
              type="select"
              label={gettext("Teaching type")}
              prompt={gettext("Choose a teaching type")}
              options={
                Enum.map(
                  @components,
                  &{"#{course_title(&1.course)} / #{component_kind_label(&1)}", &1.id}
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
              type="select"
              label={gettext("Session duration")}
              options={Enum.map(@duration_options, &{duration_label(&1), &1.slots})}
            />
            <.input
              :if={@preview && @preview.lower_count != @preview.upper_count}
              field={@form[:rounding_mode]}
              type="select"
              label={gettext("Number of sessions")}
              options={rounding_options(@preview)}
            />
            <.input
              :if={!@preview || @preview.lower_count == @preview.upper_count}
              field={@form[:rounding_mode]}
              type="hidden"
            />
            <.input
              :if={@preview && @preview.parity_choice?}
              field={@form[:remainder_parity]}
              type="select"
              label={gettext("Alternating weeks")}
              options={[{gettext("Odd weeks"), "odd"}, {gettext("Even weeks"), "even"}]}
            />
            <.input
              :if={!@preview || !@preview.parity_choice?}
              field={@form[:remainder_parity]}
              type="hidden"
            />
            <div
              :if={@preview}
              id="workload-preview"
              role="status"
              class="rounded-box bg-base-200 p-4"
            >
              <p class="type-heading">{gettext("Proposed distribution")}</p>
              <p id="workload-preview-total">
                {session_total_label(@preview.meeting_count, @preview.planned_hours)}
              </p>
              <p :if={!@preview.within_capacity?} id="workload-capacity-error" class="text-error">
                {Errors.translate_validation({"Teaching load exceeds the available time.", []})}
              </p>
              <p :if={@preview.within_capacity? && @preview.automatic_weeks}>
                {gettext("Weeks selected during calculation")}
              </p>
              <div
                :if={@preview.within_capacity? && !@preview.automatic_weeks}
                id="workload-preview-pattern"
              >
                <p :for={label <- rhythm_labels(@preview.masks, @term.weeks_count)}>{label}</p>
              </div>
              <div
                :if={!Decimal.equal?(@preview.difference, 0)}
                id="workload-hours-difference"
                class="mt-2"
              >
                <p>{difference_label(@preview.difference)}</p>
                <p>
                  {gettext(
                    "Required hours stay at %{hours}. Whole sessions cannot match them exactly at this duration.",
                    hours: decimal(@preview.required_hours)
                  )}
                </p>
              </div>
            </div>
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
              open={length(@week_mask) != @term.weeks_count}
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary class="collapse-title">
                {gettext("Restrict available weeks")}
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
      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete teaching load?")}
        message={gettext("Generated sessions will be deleted. Remove their placements first.")}
        confirm_label={gettext("Delete")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end

  defp cohort_items(cohorts, selected, selected?) do
    cohorts
    |> Enum.filter(&(&1.id in selected == selected?))
    |> Enum.map(&%{id: &1.id, label: &1.name})
  end

  defp decimal(value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp rounded_decimal(value), do: value |> Decimal.round(2) |> decimal()

  defp signed_decimal(value) do
    if Decimal.compare(value, 0) == :gt, do: "+#{decimal(value)}", else: decimal(value)
  end

  defp row_difference(row, term),
    do: Decimal.sub(Workloads.planned_hours(row, term), Workloads.hours(row))

  defp duration_label(nil), do: ""

  defp duration_label(option) do
    gettext("%{minutes} min, %{hours} academic hours",
      minutes: option.minutes,
      hours: rounded_decimal(option.hours)
    )
  end

  defp session_total_label(count, hours) do
    ngettext(
      "%{count} session, %{hours} academic hours",
      "%{count} sessions, %{hours} academic hours",
      count,
      count: count,
      hours: rounded_decimal(hours)
    )
  end

  defp rounding_options(preview) do
    for {mode, count, hours} <- [
          {"up", preview.upper_count, preview.upper_hours},
          {"down", preview.lower_count, preview.lower_hours}
        ] do
      {session_total_label(count, hours), mode}
    end
  end

  defp difference_label(difference) do
    if Decimal.compare(difference, 0) == :gt do
      gettext("Hours above the requirement: %{hours}.", hours: decimal(difference))
    else
      gettext("Hours below the requirement: %{hours}.",
        hours: decimal(Decimal.abs(difference))
      )
    end
  end

  defp rhythm_labels(masks, total) do
    masks
    |> Enum.map(&Enum.sort/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {mask, _count} -> {-length(mask), mask} end)
    |> Enum.map(fn {mask, count} ->
      ngettext("%{weeks}: %{count} session", "%{weeks}: %{count} sessions", count,
        weeks: NeuZeitWeb.Scheduling.TeachingWeeks.weeks_label(mask, total, explicit: true),
        count: count
      )
    end)
  end
end
