defmodule NeuZeitWeb.PlanLive.Index do
  @moduledoc """
  Lists draft, active and archived plans for a term.

  To restore an archived variant, create a draft copy and publish it.
  A term can have only one active plan.
  """
  use NeuZeitWeb, :live_view

  alias NeuZeit.{Catalog, Planning}
  alias NeuZeitWeb.Nav

  @impl true
  def mount(%{"term_id" => term_id}, _session, socket) do
    term = Catalog.get_term!(term_id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Plans"))
     |> assign(:term, term)
     |> assign(:terms, Catalog.list_terms())
     |> assign(:deleting, nil)
     |> assign(:editing, nil)
     |> assign(:form, nil)
     |> load()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    plan = Planning.get_plan!(id, socket.assigns.term.id)

    {:noreply,
     socket
     |> assign(:editing, plan)
     |> assign(:form, to_form(Planning.change_plan(plan)))}
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> assign(:form, nil)}

  @impl true
  def handle_event("create", _params, socket) do
    name = gettext("Draft %{n}", n: length(socket.assigns.plans) + 1)

    case Planning.create_plan(%{"term_id" => socket.assigns.term.id, "name" => name}) do
      {:ok, plan} ->
        {:noreply, push_navigate(socket, to: ~p"/terms/#{socket.assigns.term}/plans/#{plan}")}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("clone", %{"id" => id}, socket) do
    plan = Planning.get_plan!(id, socket.assigns.term.id)

    case Planning.clone_plan(plan.id) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Copy created: %{name}.", name: plan.name))
         |> push_navigate(to: ~p"/terms/#{socket.assigns.term}/plans/#{plan}")}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason)}
    end
  end

  def handle_event("validate", %{"plan" => params}, socket) do
    changeset = Planning.change_plan(socket.assigns.editing, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"plan" => params}, socket) do
    case Planning.update_plan(socket.assigns.editing, params) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved %{name}.", name: plan.name))
         |> push_patch(to: ~p"/terms/#{socket.assigns.term}/plans")
         |> load()}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :deleting, Planning.get_plan!(id, socket.assigns.term.id))}

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, socket) do
    case Planning.delete_plan(socket.assigns.deleting) do
      {:ok, plan} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> put_flash(:info, gettext("Deleted %{name}.", name: plan.name))
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
    end
  end

  defp load(socket), do: assign(socket, :plans, Planning.list_plans(socket.assigns.term.id))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@term)}
      current_path={~p"/terms/#{@term}/plans"}
      terms={@terms}
      current_term={@term}
    >
      <.page_header
        title={gettext("Plans")}
      >
        <:actions>
          <button class="btn btn-primary" phx-click="create">
            <.icon name="hero-plus" class="size-4" /> {gettext("New draft")}
          </button>
        </:actions>
      </.page_header>

      <.details_panel
        :if={@editing}
        title={gettext("Rename plan")}
        on_close={JS.patch(~p"/terms/#{@term}/plans")}
      >
        <.form for={@form} id="plan-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:name]} type="text" label={gettext("Name")} />
          <div class="flex gap-2 pt-2">
            <.button variant="primary" phx-disable-with={gettext("Saving")}>
              {gettext("Save")}
            </.button>
            <.link patch={~p"/terms/#{@term}/plans"} class="btn btn-ghost">
              {gettext("Cancel")}
            </.link>
          </div>
        </.form>
      </.details_panel>

      <.empty_state
        :if={@plans == []}
        title={gettext("No plans yet")}
        message={gettext("Create a draft to generate or edit a timetable.")}
        icon="hero-clipboard-document-list"
      />

      <.table :if={@plans != []} id="plans" rows={@plans} row_id={&"plan-#{&1.id}"}>
        <:col :let={plan} label={gettext("Plan")}>
          <.link navigate={~p"/terms/#{@term}/plans/#{plan}"} class="link link-hover font-semibold">
            {plan.name}
          </.link>
        </:col>
        <:col :let={plan} label={gettext("Status")}><.status_indicator status={plan.status} /></:col>
        <:col :let={plan} label={gettext("Published")}>
          {plan.published_at && Calendar.strftime(plan.published_at, "%Y-%m-%d %H:%M")}
        </:col>
        <:action :let={plan}>
          <.link patch={~p"/terms/#{@term}/plans/#{plan}/rename"} class="btn btn-ghost">
            {gettext("Rename")}
          </.link>
          <button class="btn btn-ghost" phx-click="clone" phx-value-id={plan.id}>
            {gettext("Copy to draft")}
          </button>
          <button
            :if={plan.status != "active"}
            class="btn btn-ghost text-error"
            phx-click="delete_prompt"
            phx-value-id={plan.id}
          >
            {gettext("Delete")}
          </button>
        </:action>
      </.table>

      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete %{name}?", name: @deleting.name)}
        message={gettext("Deleting this plan also deletes its placements. The active plan cannot be deleted.")}
        confirm_label={gettext("Delete plan")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end
end
