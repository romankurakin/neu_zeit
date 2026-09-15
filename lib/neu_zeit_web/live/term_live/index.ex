defmodule NeuZeitWeb.TermLive.Index do
  @moduledoc """
  Lists terms and provides term creation and editing forms.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.Term
  alias NeuZeitWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Terms"))
     |> assign(:deleting, nil)
     |> load_terms()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:editing, %Term{})
    |> assign(:form, to_form(Catalog.change_term(%Term{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    term = Catalog.get_term!(id)

    socket
    |> assign(:editing, term)
    |> assign(:form, to_form(Catalog.change_term(term)))
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:editing, nil)
    |> assign(:form, nil)
  end

  @impl true
  def handle_event("validate", %{"term" => params}, socket) do
    changeset = Catalog.change_term(socket.assigns.editing, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"term" => params}, socket) do
    save(socket, socket.assigns.editing, params)
  end

  def handle_event("delete_prompt", %{"id" => id}, socket) do
    {:noreply, assign(socket, :deleting, Catalog.get_term!(id))}
  end

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, socket) do
    case Catalog.delete_term(socket.assigns.deleting) do
      {:ok, term} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> put_flash(:info, gettext("Deleted %{name}.", name: term.name))
         |> load_terms()}

      {:error, reason} ->
        # Explain why a term with sessions or plans cannot be deleted.
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> Errors.put(reason)}
    end
  end

  defp save(socket, %Term{id: nil}, params) do
    case Catalog.create_term(params) do
      {:ok, term} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Created %{name}.", name: term.name))
         |> push_navigate(to: ~p"/terms/#{term}")}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  defp save(socket, term, params) do
    case Catalog.update_term(term, params) do
      {:ok, term} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Updated %{name}.", name: term.name))
         |> push_patch(to: ~p"/terms")
         |> load_terms()}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  defp load_terms(socket), do: assign(socket, :terms, Catalog.list_terms())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@navigation_term)}
      current_path={~p"/terms"}
      terms={@terms}
      current_term={@navigation_term}
    >
      <.page_header title={gettext("Terms")}>
        <:actions>
          <.link patch={~p"/terms/new"} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> {gettext("New term")}
          </.link>
        </:actions>
      </.page_header>

      <div class={["grid gap-4", @editing && "lg:grid-cols-[2fr_1fr]"]}>
        <div class="min-w-0">
          <.empty_state
            :if={@terms == []}
            title={gettext("No terms yet")}
            message={gettext("Set the term dates and non-teaching dates.")}
            icon="hero-calendar-days"
          >
            <:actions>
              <.link patch={~p"/terms/new"} class="btn btn-primary">{gettext("Create the first term")}</.link>
            </:actions>
          </.empty_state>

          <.table :if={@terms != []} id="terms" rows={@terms} row_id={&"term-#{&1.id}"}>
            <:col :let={term} label={gettext("Term")}>
              <.link navigate={~p"/terms/#{term}"} class="link link-hover font-semibold">
                {term.name}
              </.link>
            </:col>
            <:col :let={term} label={gettext("Starts")}><.date value={term.starts_on} /></:col>
            <:col :let={term} label={gettext("Ends")}><.date value={term.ends_on} /></:col>
            <:col :let={term} label={gettext("Weeks")} numeric>{term.weeks_count}</:col>
            <:col :let={term} label={gettext("Non-teaching dates")} numeric>
              {length(term.excluded_dates)}
            </:col>
            <:action :let={term}>
              <.link navigate={~p"/terms/#{term}/settings"} class="btn btn-ghost">{gettext("Edit")}</.link>
              <button
                class="btn btn-ghost text-error"
                phx-click="delete_prompt"
                phx-value-id={term.id}
              >
                {gettext("Delete")}
              </button>
            </:action>
          </.table>
        </div>

        <.details_panel
          :if={@editing}
          class="order-first lg:order-last"
          title={if @editing.id, do: gettext("Edit term"), else: gettext("New term")}
        >
          <.form
            for={@form}
            id="term-form"
            phx-mounted={JS.focus_first(to: "#term-form")}
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-2"
          >
            <.input field={@form[:name]} type="text" label={gettext("Name")} />
            <.date_field
              field={@form[:starts_on]}
              label={gettext("First day (a Monday)")}
              weekday={1}
            />
            <.date_field field={@form[:ends_on]} label={gettext("Last day")} />

            <div class="flex gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
              <.link patch={~p"/terms"} class="btn btn-ghost">{gettext("Cancel")}</.link>
            </div>
          </.form>
        </.details_panel>
      </div>

      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete %{name}?", name: @deleting.name)}
        message={
          gettext("Deletion cannot be undone. Only terms without sessions or plans can be deleted.")
        }
        confirm_label={gettext("Delete term")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end
end
