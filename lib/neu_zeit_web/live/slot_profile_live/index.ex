defmodule NeuZeitWeb.SlotProfileLive.Index do
  @moduledoc """
  Edits profiles of allowed session start times.

  The complete session must fit within the teaching day and teacher availability.
  A start in the final time slot cannot hold a two-slot session.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.SlotProfile
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Time profiles"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:grid, NeuZeit.Config.grid!())
     |> assign(:deleting, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = Nav.assign_return(socket, params)
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    profile = Catalog.get_slot_profile!(id, socket.assigns.term.id)

    socket
    |> assign(:selected, profile)
    |> assign(
      :form,
      to_form(Catalog.change_slot_profile(profile, %{name: slot_profile_label(profile)}))
    )
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:selected, %SlotProfile{term_id: socket.assigns.term.id, cells: []})
    |> assign(:form, to_form(Catalog.change_slot_profile(%SlotProfile{})))
  end

  defp apply_action(socket, :index, _params),
    do: socket |> assign(:selected, nil) |> assign(:form, nil)

  @impl true
  def handle_event("create_defaults", _params, socket) do
    case Catalog.ensure_default_slot_profiles(socket.assigns.term) do
      {:ok, _profiles} ->
        {:noreply, socket |> put_flash(:info, gettext("Weekday profile is ready.")) |> load()}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
    end
  end

  # Applies one grid event to the starts the profile allows.
  def handle_event("grid_changed", params, socket) do
    profile = socket.assigns.selected
    attrs = %{"cells" => apply_cells(profile.cells, params)}

    case Catalog.update_slot_profile(profile, attrs) do
      {:ok, profile} ->
        {:noreply, socket |> assign(:selected, Catalog.get_slot_profile!(profile.id)) |> load()}

      {:error, reason} ->
        # The assigns still hold the stored profile, so a refusal renders it again.
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("save", %{"slot_profile" => params}, socket) do
    profile = socket.assigns.selected

    params =
      if profile.id && params["name"] == slot_profile_label(profile),
        do: Map.put(params, "name", profile.name),
        else: params

    result =
      case profile do
        %SlotProfile{id: nil} ->
          # A new profile starts with all cells selected and can then be restricted.
          Catalog.create_slot_profile(
            Map.merge(params, %{
              "term_id" => socket.assigns.term.id,
              "cells" => whole_grid(socket)
            })
          )

        _existing ->
          Catalog.update_slot_profile(profile, params)
      end

    case result do
      {:ok, profile} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved %{name}.", name: slot_profile_label(profile)))
         |> push_patch(to: ~p"/terms/#{socket.assigns.term}/slot-profiles/#{profile}/edit")
         |> load()}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket),
    do:
      {:noreply, assign(socket, :deleting, Catalog.get_slot_profile!(id, socket.assigns.term.id))}

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, socket) do
    case delete(socket.assigns.deleting) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> put_flash(:info, gettext("Deleted %{name}.", name: slot_profile_label(profile)))
         |> push_patch(to: ~p"/terms/#{socket.assigns.term}/slot-profiles")
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
    end
  end

  defp delete(profile) do
    Catalog.delete_slot_profile(profile)
  rescue
    Ecto.ConstraintError ->
      {:error,
       {:conflict,
        gettext("%{name} is still assigned to a session.", name: slot_profile_label(profile))}}
  end

  defp whole_grid(socket) do
    grid = socket.assigns.grid

    for day <- 1..length(grid.days), slot <- 1..length(grid.slots) do
      %{"day" => day, "slot" => slot}
    end
  end

  defp load(socket) do
    socket
    |> assign(:profiles, Catalog.list_slot_profiles(socket.assigns.term.id))
    |> then(fn socket ->
      assign(
        socket,
        :has_weekday_profile,
        Enum.any?(socket.assigns.profiles, &(&1.preset_key == "weekday_daytime"))
      )
    end)
    |> assign(:usage, Catalog.usage_counts(socket.assigns.term.id).slot_profiles)
  end

  # The longest session a profile can still hold: the largest duration for which
  # some start leaves enough room in the day.
  defp longest_fit(profile, grid) do
    slots = length(grid.slots)

    profile.cells
    |> Enum.map(&(slots - &1.slot + 1))
    |> Enum.max(fn -> 0 end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/slot-profiles"}
      terms={@terms}
      current_term={@term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">{gettext("Return to timetable")}</.link>
      <.page_header
        title={gettext("Time profiles")}
        subtitle={gettext("Sessions with this profile can start only at the selected times.")}
      >
        <:actions>
          <button
            :if={!@has_weekday_profile}
            id="create-default-profiles"
            class="btn"
            phx-click="create_defaults"
          >
            {gettext("Add weekday profile")}
          </button>
          <.link
            patch={~p"/terms/#{@term}/slot-profiles/new"}
            class="btn btn-primary"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("New profile")}
          </.link>
        </:actions>
      </.page_header>

      <div class={["grid gap-4", @selected && "lg:grid-cols-[1fr_2fr]"]}>
        <div class="min-w-0">
          <.empty_state
            :if={@profiles == []}
            title={gettext("No profiles yet")}
            icon="hero-table-cells"
          />

          <.table
            :if={@profiles != []}
            id="slot-profiles"
            rows={@profiles}
            row_id={&"profile-#{&1.id}"}
          >
            <:col :let={profile} label={gettext("Profile")}>
              <.link
                patch={~p"/terms/#{@term}/slot-profiles/#{profile}/edit"}
                class="link link-hover font-semibold"
              >
                {slot_profile_label(profile)}
              </.link>
            </:col>
            <:col :let={profile} label={gettext("Starts")} numeric>{length(profile.cells)}</:col>
            <:col :let={profile} label={gettext("Longest session")}>
              {ngettext("%{count} time slot", "%{count} time slots", longest_fit(profile, @grid),
                count: longest_fit(profile, @grid)
              )}
            </:col>
            <:col :let={profile} label={gettext("Sessions")} numeric>
              {Map.get(@usage, profile.id, 0)}
            </:col>
            <:action :let={profile}>
              <button
                class="btn btn-ghost text-error"
                phx-click="delete_prompt"
                phx-value-id={profile.id}
              >
                {gettext("Delete")}
              </button>
            </:action>
          </.table>
        </div>

        <.details_panel
          :if={@selected}
          class="order-first lg:order-last"
          title={slot_profile_label(@selected) || gettext("New profile")}
          subtitle={gettext("Select allowed start times.")}
          on_close={JS.patch(~p"/terms/#{@term}/slot-profiles")}
        >
          <.form
            for={@form}
            id="profile-form"
            phx-mounted={JS.focus_first(to: "#profile-form")}
            phx-submit="save"
            class="mb-4"
          >
            <div class="flex items-end gap-2">
              <div class="flex-1">
                <.input field={@form[:name]} type="text" label={gettext("Name")} />
              </div>
              <.button variant="primary" phx-disable-with={gettext("Saving")}>
                {gettext("Save")}
              </.button>
            </div>
          </.form>

          <div :if={@selected.id}>
            <.time_grid
              id={"profile-grid-#{@selected.id}"}
              cells={@selected.cells}
              grid={@grid}
              legend={
                ngettext(
                  "%{count} allowed start time",
                  "%{count} allowed start times",
                  length(@selected.cells),
                  count: length(@selected.cells)
                )
              }
            />

            <div :if={longest_fit(@selected, @grid) <= 1} class="alert alert-warning mt-4">
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <span>
                {gettext(
                  "Only the last time slot is selected. Sessions longer than one slot will not fit."
                )}
              </span>
            </div>
          </div>

          <p :if={is_nil(@selected.id)} class="type-detail text-base-content">
            {gettext("Save the name to select start times. All times are allowed initially.")}
          </p>
        </.details_panel>
      </div>

      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete %{name}?", name: slot_profile_label(@deleting))}
        message={gettext("A profile used by a session cannot be deleted.")}
        confirm_label={gettext("Delete profile")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end
end
