defmodule NeuZeitWeb.TermLive.Settings do
  use NeuZeitWeb, :live_view

  alias NeuZeit.Catalog
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"term_id" => id}, _session, socket) do
    term = Catalog.get_term!(id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Settings"))
     |> assign(:terms, Catalog.list_terms())
     |> load(term)}
  end

  defp load(socket, term),
    do: assign(socket, term: term, form: to_form(Catalog.change_term(term)))

  @impl true
  def handle_event("save", %{"term" => params}, socket) do
    case Catalog.update_term(socket.assigns.term, Map.take(params, ["academic_hour_minutes"])) do
      {:ok, term} ->
        {:noreply, socket |> load(term) |> put_flash(:info, gettext("Settings saved."))}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} nav={Nav.sections(@term)} current_path={~p"/terms/#{@term}/settings"} terms={@terms} current_term={@term}>
      <.page_header title={gettext("Settings")} />
      <.card title={gettext("Teaching hours")}>
        <.form for={@form} id="term-settings" phx-submit="save" class="flex flex-col gap-4 max-w-lg">
          <.input field={@form[:academic_hour_minutes]} type="number" label={gettext("Minutes per academic hour")} min="1" max="60" required />
          <p>{gettext("Used for teaching load and hour reports. Session times stay unchanged.")}</p>
          <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
        </.form>
      </.card>
    </Layouts.app>
    """
  end
end
