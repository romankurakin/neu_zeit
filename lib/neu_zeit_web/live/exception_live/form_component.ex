defmodule NeuZeitWeb.ExceptionLive.FormComponent do
  @moduledoc """
  The form for one one-off change.

  The parent gives an exception record, new or existing, and prefill params in
  the shape of the URL params of the one-off changes page. On success the
  component sends `{__MODULE__, :saved, exception}` to the parent, which
  reloads its data and closes the form.
  """
  use NeuZeitWeb, :live_component

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeit.Planning.ScheduleException

  @prefill_keys ~w(kind new_date new_slot new_room_id new_delivery_mode)

  @impl true
  def update(assigns, socket) do
    fresh? =
      socket.assigns[:exception] != assigns.exception or
        socket.assigns[:params] != assigns.params

    socket = assign(socket, assigns)

    socket =
      if fresh?,
        do:
          socket
          |> assign(:form, to_form(initial_changeset(assigns.exception, assigns.params)))
          |> assign(:error, nil),
        else: socket

    {:ok, socket}
  end

  @doc """
  Builds a new exception from prefill params: the session, the date, the kind
  and the position of a move or an addition.
  """
  def new_exception(term_id, params) do
    kind = params["kind"] || "cancel"

    %ScheduleException{
      term_id: term_id,
      kind: kind,
      session_id: params["session_id"],
      occurrence_date: parse_date(params["date"]),
      new_date: if(kind in ["move", "add"], do: parse_date(params["new_date"])),
      new_slot: if(kind in ["move", "add"], do: parse_slot(params["new_slot"])),
      new_room_id: if(kind in ["move", "add"], do: params["new_room_id"]),
      new_teacher_id: if(kind != "cancel", do: params["new_teacher_id"])
    }
  end

  defp initial_changeset(%ScheduleException{id: nil} = exception, params) do
    Planning.change_schedule_exception(
      exception,
      normalize_payload(Map.take(params, ["kind", "new_delivery_mode"]))
    )
  end

  defp initial_changeset(%ScheduleException{} = exception, params) do
    attrs =
      params
      |> Map.take(@prefill_keys)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()
      |> normalize_payload()

    # Dragging an addition edits its date in the same record.
    attrs =
      if (attrs["kind"] || exception.kind) == "add" do
        Map.merge(attrs, %{
          "occurrence_date" =>
            attrs["new_date"] || exception.new_date || exception.occurrence_date,
          "new_date" => nil
        })
      else
        attrs
      end

    Planning.change_schedule_exception(exception, attrs)
  end

  defp normalize_payload(%{"kind" => "cancel"} = attrs),
    do:
      Map.merge(attrs, %{
        "new_date" => nil,
        "new_slot" => nil,
        "new_room_id" => nil,
        "new_teacher_id" => nil,
        "new_delivery_mode" => nil
      })

  defp normalize_payload(%{"kind" => "substitute"} = attrs),
    do:
      Map.merge(attrs, %{
        "new_date" => nil,
        "new_slot" => nil,
        "new_room_id" => nil,
        "new_delivery_mode" => nil
      })

  defp normalize_payload(attrs), do: attrs

  defp normalize_delivery_payload(attrs, assigns) do
    session_id = attrs["session_id"] || assigns.exception.session_id
    session = Enum.find(assigns.sessions, &(&1.id == session_id))
    mode = attrs["new_delivery_mode"]
    mode = if mode in [nil, ""], do: session && session.delivery_mode, else: mode

    if attrs["kind"] in ["move", "add"] && mode in [:online, "online"],
      do: Map.put(attrs, "new_room_id", nil),
      else: attrs
  end

  defp effective_delivery_mode(form, sessions) do
    case form[:new_delivery_mode].value do
      mode when mode in [nil, ""] ->
        case Enum.find(sessions, &(&1.id == form[:session_id].value)) do
          nil -> :in_person
          session -> session.delivery_mode
        end

      mode ->
        mode
    end
  end

  defp parse_slot(nil), do: nil

  defp parse_slot(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _invalid -> nil
    end
  end

  @impl true
  def handle_event("validate", %{"schedule_exception" => params}, socket) do
    params = normalize_payload(params) |> normalize_delivery_payload(socket.assigns)
    params = if params["kind"] == "add", do: Map.put(params, "new_date", nil), else: params
    changeset = Planning.change_schedule_exception(socket.assigns.exception, params)

    {:noreply,
     socket |> assign(:form, to_form(changeset, action: :validate)) |> assign(:error, nil)}
  end

  def handle_event("save", %{"schedule_exception" => params}, socket) do
    attrs = Map.put(params, "term_id", socket.assigns.term.id)
    attrs = normalize_payload(attrs) |> normalize_delivery_payload(socket.assigns)
    attrs = if attrs["kind"] == "add", do: Map.put(attrs, "new_date", nil), else: attrs

    result =
      if socket.assigns.exception.id do
        Planning.update_schedule_exception(
          socket.assigns.exception,
          Map.drop(attrs, ["term_id", "session_id"])
        )
      else
        if Enum.any?(socket.assigns.sessions, &(&1.id == attrs["session_id"])),
          do: Planning.create_schedule_exception(attrs),
          else:
            {:error,
             Catalog.error_changeset(
               %ScheduleException{},
               :session_id,
               "must belong to this term"
             )}
      end

    case result do
      {:ok, exception} ->
        send(self(), {__MODULE__, :saved, exception})
        {:noreply, socket}

      {:error, reason} ->
        # Field errors go to the form. Other reasons, such as a rejected date,
        # are shown inside the form because a flash would sit behind the dialog.
        case Errors.classify(reason) do
          {:form, changeset} ->
            {:noreply,
             socket |> assign(:form, to_form(changeset, action: :validate)) |> assign(:error, nil)}

          _other ->
            {:noreply, assign(socket, :error, Errors.message(reason))}
        end
    end
  end

  @doc """
  Labels every session of the term by its id.

  Sessions that read the same get the day and time of their placement in the
  active plan, when they have one.
  """
  def session_labels(sessions, total, placements, grid) do
    base =
      Map.new(sessions, fn session ->
        {session.id, base_label(session, total, placements)}
      end)

    duplicates =
      base
      |> Map.values()
      |> Enum.frequencies()
      |> Enum.filter(fn {_label, count} -> count > 1 end)
      |> Map.new()

    Map.new(sessions, fn session ->
      label = base[session.id]
      placement = Map.get(placements, session.id)

      label =
        if Map.has_key?(duplicates, label) && placement,
          do:
            label <>
              ", " <>
              day_label(Enum.at(grid.days, placement.day - 1)) <>
              " " <>
              NeuZeitWeb.Scheduling.SessionCard.time_range(
                grid,
                placement.slot,
                session.duration_slots
              ),
          else: label

      {session.id, label}
    end)
  end

  defp base_label(session, total, placements) do
    weeks =
      case Map.get(placements, session.id) do
        nil -> if(session.automatic_weeks, do: [], else: session.week_mask)
        placement -> placement.week_mask
      end

    [
      course_title(session.course_component.course),
      component_kind_label(session.course_component),
      session.teacher.name,
      Enum.map_join(session.cohorts, ", ", & &1.name),
      if(weeks != [], do: weeks_label(weeks, total)),
      ngettext("%{count} time slot", "%{count} time slots", session.duration_slots,
        count: session.duration_slots
      )
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  attr :id, :string, required: true
  attr :term, :map, required: true
  attr :grid, :map, required: true
  attr :sessions, :list, required: true
  attr :rooms, :list, required: true
  attr :teachers, :list, required: true
  attr :placements, :map, required: true, doc: "active placements by session id"
  attr :exception, ScheduleException, required: true
  attr :params, :map, required: true, doc: "prefill in the shape of URL params"

  attr :on_cancel, :any,
    required: true,
    doc: "phx-click of the cancel button: a JS command or a parent event"

  @impl true
  def render(assigns) do
    labels =
      session_labels(assigns.sessions, assigns.term.weeks_count, assigns.placements, assigns.grid)

    assigns =
      assign(assigns, :session_options, Enum.map(assigns.sessions, &{labels[&1.id], &1.id}))

    ~H"""
    <div id={@id}>
      <.form
        for={@form}
        id="exception-form"
        phx-target={@myself}
        phx-mounted={JS.focus_first(to: "#exception-form")}
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-2"
      >
        <.combobox
          field={@form[:session_id]}
          disabled={@exception.id != nil}
          label={gettext("Session")}
          prompt={gettext("Choose a session")}
          options={@session_options}
        />
        <.input
          field={@form[:kind]}
          type="select"
          label={gettext("Change")}
          options={[
            {gettext("Cancel dated session"), "cancel"},
            {gettext("Change date, time or format"), "move"},
            {gettext("Add a dated session"), "add"},
            {gettext("Replace teacher"), "substitute"}
          ]}
        />
        <.date_field
          field={@form[:occurrence_date]}
          label={gettext("Date")}
          min={@term.starts_on}
          max={@term.ends_on}
        />

        <div :if={to_string(@form[:kind].value) in ["move", "add"]} class="flex flex-col gap-2">
          <.input
            field={@form[:new_delivery_mode]}
            type="select"
            label={gettext("Delivery format")}
            prompt={gettext("Use the series format")}
            options={delivery_mode_options()}
          />
          <p :if={to_string(@form[:kind].value) == "move"} class="type-detail">
            {gettext("To change only the format, keep the same date and time.")}
          </p>
          <.date_field
            :if={to_string(@form[:kind].value) == "move"}
            field={@form[:new_date]}
            label={gettext("New date")}
            min={@term.starts_on}
            max={@term.ends_on}
            disallowed={@term.excluded_dates || []}
          />
          <.input
            field={@form[:new_slot]}
            type="select"
            label={
              if to_string(@form[:kind].value) == "move",
                do: gettext("New time"),
                else: gettext("Time")
            }
            prompt={gettext("Choose a time")}
            options={slot_options(@grid)}
          />
          <.input
            :if={effective_delivery_mode(@form, @sessions) not in [:online, "online"]}
            field={@form[:new_room_id]}
            type="select"
            label={
              if to_string(@form[:kind].value) == "move",
                do: gettext("New room"),
                else: gettext("Room")
            }
            prompt={gettext("Choose a room")}
            options={Enum.map(@rooms, &{"#{&1.name}, #{&1.building.name}", &1.id})}
          />
        </div>

        <.input
          :if={to_string(@form[:kind].value) in ["move", "add", "substitute"]}
          field={@form[:new_teacher_id]}
          type="select"
          label={gettext("Substitute teacher")}
          prompt={
            if to_string(@form[:kind].value) == "substitute",
              do: gettext("Choose a teacher"),
              else: gettext("Keep the assigned teacher")
          }
          options={Enum.map(@teachers, &{&1.name, &1.id})}
          required={to_string(@form[:kind].value) == "substitute"}
        />
        <.input field={@form[:reason]} type="text" label={gettext("Reason")} required />
        <.input
          field={@form[:created_by]}
          type="text"
          label={gettext("Author")}
          required
          phx-hook=".RememberValue"
          data-remember-key="exception-author"
        />

        <p class="type-detail font-semibold">
          {gettext("Applies only to this date. The semester template stays the same.")}
        </p>
        <p :if={@error} role="alert" class="type-detail text-error">{@error}</p>
        <div class="flex flex-wrap gap-2 pt-2">
          <.button variant="primary" phx-disable-with={gettext("Saving")}>
            {gettext("Save change")}
          </.button>
          <button type="button" class="btn btn-ghost" phx-click={@on_cancel}>
            {gettext("Cancel")}
          </button>
        </div>
      </.form>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RememberValue">
        import { defineHook } from "@/js/hook-dom";

        /** @param {HTMLInputElement} input @param {string} key */
        const restore = (input, key) => {
          try {
            const stored = globalThis.localStorage.getItem(key);
            if (typeof stored === "string" && stored !== "") {
              input.value = stored;
              input.dispatchEvent(new Event("input", { bubbles: true }));
            }
          } catch {
            // Storage may be blocked. The input then starts empty.
          }
        };

        /** @param {HTMLInputElement} input @param {string} key */
        const remember = (input, key) => {
          try {
            globalThis.localStorage.setItem(key, input.value);
          } catch {
            // Storage may be blocked. The value is still submitted.
          }
        };

        /** Keeps the last value of an input in this browser, so the author types it once. */
        export default defineHook({
          mounted() {
            const input = this.el;
            if (!(input instanceof HTMLInputElement)) {
              throw new TypeError("RememberValue needs an input");
            }
            const key = `remember:${input.dataset.rememberKey ?? input.id}`;
            if (input.value === "") {
              restore(input, key);
            }
            input.addEventListener("change", () => remember(input, key));
          },
        });
      </script>
    </div>
    """
  end

  defp slot_options(grid) do
    grid.slots
    |> Enum.with_index(1)
    |> Enum.map(fn {slot, index} -> {"#{index}, #{slot.start}", index} end)
  end
end
