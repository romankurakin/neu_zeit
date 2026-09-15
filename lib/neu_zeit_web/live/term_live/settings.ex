defmodule NeuZeitWeb.TermLive.Settings do
  use NeuZeitWeb, :live_view
  alias NeuZeit.Catalog
  alias NeuZeit.Scheduling.Grid
  alias NeuZeitWeb.Nav

  def mount(%{"term_id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Term settings"))
     |> assign(:terms, Catalog.list_terms())
     |> assign(:editing, false)
     |> load(Catalog.get_term!(id))}
  end

  defp load(socket, term) do
    assign(socket,
      term: term,
      form: to_form(Catalog.change_term(term)),
      grid: term.grid,
      dates_form: to_form(Catalog.change_term(term)),
      locked: Catalog.Term.time_settings_locked?(term.id)
    )
  end

  def handle_event("edit", _params, socket),
    do: {:noreply, assign(socket, :editing, !socket.assigns.locked)}

  def handle_event("cancel", _params, socket),
    do:
      {:noreply,
       socket |> assign(:editing, false) |> load(Catalog.get_term!(socket.assigns.term.id))}

  def handle_event("validate", %{"term" => params}, socket) do
    {:noreply, set_form(socket, params, :validate)}
  end

  def handle_event("save", %{"term" => params}, socket) do
    case Catalog.update_term(socket.assigns.term, settings_params(params, socket.assigns.grid)) do
      {:ok, term} ->
        {:noreply,
         socket
         |> load(term)
         |> assign(:editing, false)
         |> put_flash(:info, gettext("Settings saved."))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:locked, Catalog.Term.time_settings_locked?(socket.assigns.term.id))
         |> Errors.put(reason, as: :form)}
    end
  end

  def handle_event("add_slot", _, socket) do
    grid = %{socket.assigns.grid | slots: socket.assigns.grid.slots ++ [%{start: "", end: ""}]}

    {:noreply,
     set_form(
       socket,
       %{
         "grid" => grid,
         "academic_hour_minutes" => socket.assigns.form[:academic_hour_minutes].value
       },
       nil
     )}
  end

  def handle_event("remove_slot", %{"index" => index}, socket) do
    grid = %{
      socket.assigns.grid
      | slots: List.delete_at(socket.assigns.grid.slots, String.to_integer(index))
    }

    {:noreply,
     set_form(
       socket,
       %{
         "grid" => grid,
         "academic_hour_minutes" => socket.assigns.form[:academic_hour_minutes].value
       },
       nil
     )}
  end

  def handle_event("toggle_excluded_date", %{"date" => iso}, socket) do
    date = Date.from_iso8601!(iso)
    term = socket.assigns.term

    result =
      if date in term.excluded_dates do
        Catalog.remove_excluded_date(term, date)
      else
        Catalog.add_excluded_date(term, date)
      end

    case result do
      {:ok, term} ->
        {:noreply,
         socket
         |> assign(:term, term)
         |> load(term)}

      {:error, reason} ->
        # Show the context error when a dated change prevents excluding the date.
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("validate_dates", %{"term" => params}, socket) do
    form =
      to_form(
        Catalog.change_term(
          socket.assigns.term,
          Map.take(params, ["name", "starts_on", "ends_on"])
        ),
        action: :validate
      )

    {:noreply, assign(socket, :dates_form, form)}
  end

  def handle_event("save_dates", %{"term" => params}, socket) do
    case Catalog.update_term(
           socket.assigns.term,
           Map.take(params, ["name", "starts_on", "ends_on"])
         ) do
      {:ok, term} ->
        {:noreply, socket |> load(term) |> put_flash(:info, gettext("Settings saved."))}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :dates_form)}
    end
  end

  defp set_form(socket, params, action) do
    changeset =
      Catalog.change_term(socket.assigns.term, settings_params(params, socket.assigns.grid))

    assign(socket,
      form: to_form(changeset, action: action),
      grid: Ecto.Changeset.get_field(changeset, :grid)
    )
  end

  defp settings_params(params, grid) do
    days =
      case Integer.parse(to_string(params["teaching_days"] || length(grid.days))) do
        {count, ""} when count in 1..7 -> Enum.take(Grid.days(), count)
        _ -> []
      end

    grid =
      case Map.get(params, "grid", grid) do
        value when is_map(value) -> value
        _ -> %{}
      end

    # Normalize outer keys from either a rendered form or the local row editor.
    grid = %{days: days, slots: Map.get(grid, :slots, grid["slots"])}
    params |> Map.take(["academic_hour_minutes"]) |> Map.put("grid", grid)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/settings"}
      terms={@terms}
      current_term={@term}
    >
      <.page_header title={gettext("Term settings")} subtitle={@term.name} />
      <div class="grid items-start gap-4 xl:grid-cols-2">
        <.card title={gettext("Term dates")}>
          <.form
            for={@dates_form}
            id="term-dates"
            phx-change="validate_dates"
            phx-submit="save_dates"
            class="flex flex-col gap-4"
          >
            <.input field={@dates_form[:name]} label={gettext("Name")} required />
            <div class="grid gap-4 sm:grid-cols-2">
              <.date_field
                field={@dates_form[:starts_on]}
                label={gettext("First day (a Monday)")}
                weekday={1}
              />
              <.date_field field={@dates_form[:ends_on]} label={gettext("Last day")} />
            </div>
            <.button variant="primary" class="self-start" phx-disable-with={gettext("Saving")}>{gettext(
              "Save"
            )}</.button>
          </.form>
        </.card>
        <.card title={gettext("Days and times")}>
          <p class="mb-4">
            {gettext(
              "New terms start with the default timetable grid. Changes here apply only to this term."
            )}
          </p>
          <div :if={!@editing}>
            <p class="mb-3">
              {gettext("Academic hour: %{minutes} minutes", minutes: @term.academic_hour_minutes)}
            </p>
            <p class="mb-3">{Enum.map_join(@grid.days, ", ", &day_label/1)}</p>
            <ol class="mb-4 grid gap-2 sm:grid-cols-3">
              <li :for={{slot, i} <- Enum.with_index(@grid.slots, 1)}>
                {i}. {slot.start} - {slot.end}
              </li>
            </ol>
            <p :if={@locked} class="type-detail">
              {gettext(
                "Time settings are fixed because teaching load, availability or time profiles have been entered."
              )}
            </p>
            <button :if={!@locked} class="btn" phx-click="edit">{gettext("Change for this term")}</button>
          </div>
          <.form
            :if={@editing}
            for={@form}
            id="term-settings"
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-4 max-w-2xl"
          >
            <.input
              id="teaching-days"
              name="term[teaching_days]"
              value={length(@grid.days)}
              type="select"
              label={gettext("Teaching days per week, starting on Monday")}
              options={Enum.map(1..7, &{to_string(&1), &1})}
            />
            <p :for={error <- @form[:grid].errors} class="text-error">
              {Errors.translate_validation(error)}
            </p>
            <div
              :for={{slot, i} <- Enum.with_index(@grid.slots)}
              class="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] items-end gap-2"
            >
              <.input
                id={"slot-#{i}-start"}
                name={"term[grid][slots][#{i}][start]"}
                value={slot.start}
                label={gettext("Start")}
                type="time"
                required
              />
              <.input
                id={"slot-#{i}-end"}
                name={"term[grid][slots][#{i}][end]"}
                value={slot.end}
                label={gettext("End")}
                type="time"
                required
              />
              <button
                type="button"
                class="btn btn-ghost"
                phx-click="remove_slot"
                phx-value-index={i}
                aria-label={gettext("Remove time slot")}
              >{gettext("Remove")}</button>
            </div>
            <button
              type="button"
              class="btn btn-ghost self-start"
              phx-click="add_slot"
              disabled={length(@grid.slots) >= 24}
            >{gettext("Add time slot")}</button>
            <details>
              <summary class="cursor-pointer">{gettext("Hour conversion")}</summary>
              <div class="mt-3 flex flex-col gap-2">
                <.input
                  field={@form[:academic_hour_minutes]}
                  type="number"
                  label={gettext("Minutes per academic hour")}
                  min="1"
                  max="60"
                  required
                />
                <p class="type-detail">
                  {gettext(
                    "One hour unit applies to all teaching load in this term. Timetable start and end times are set separately."
                  )}
                </p>
              </div>
            </details>
            <div class="flex gap-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
              <button type="button" class="btn btn-ghost" phx-click="cancel">{gettext("Cancel")}</button>
            </div>
          </.form>
        </.card>
      </div>
      <.card id="teaching-calendar" class="mt-4" title={gettext("Teaching calendar")}>
        <p class="mb-4 type-detail text-base-content">
          {gettext(
            "Select non-teaching dates. Dated sessions on these dates are omitted. You cannot add or move dated sessions to them."
          )}
        </p>

        <.term_calendar term={@term} />

        <p class="mt-4 flex items-center gap-2 type-detail text-base-content">
          <span class="inline-block h-3 w-6 rounded-field bg-error/15"></span>
          {gettext("Non-teaching dates")}
        </p>
      </.card>
    </Layouts.app>
    """
  end
end
