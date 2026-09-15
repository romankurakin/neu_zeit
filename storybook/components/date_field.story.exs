defmodule NeuZeitWeb.Stories.DateField do
  use PhoenixStorybook.Story, :example
  import NeuZeitWeb.UI.DateField

  @impl true
  def mount(_params, _session, socket) do
    term = %NeuZeit.Catalog.Term{
      name: "Autumn 2026",
      starts_on: ~D[2026-09-07],
      ends_on: ~D[2026-12-20]
    }

    {:ok, assign(socket, term: term, form: to_form(NeuZeit.Catalog.change_term(term)))}
  end

  @impl true
  def handle_event("validate", %{"term" => params}, socket) do
    changeset = NeuZeit.Catalog.change_term(socket.assigns.term, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.form for={@form} id="date-field-example" phx-change="validate" class="grid gap-4 sm:grid-cols-2">
      <.date_field field={@form[:starts_on]} label="First day (a Monday)" weekday={1} />
      <.date_field field={@form[:ends_on]} label="Last day" />
    </.form>
    """
  end
end
