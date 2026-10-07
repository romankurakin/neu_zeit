defmodule NeuZeitWeb.TeachingTypeLive.Index do
  use NeuZeitWeb, :live_view
  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.TeachingType
  alias NeuZeitWeb.Nav

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Teaching types"))
     |> assign(:deleting, nil)
     |> assign(:locales, NeuZeitWeb.Locale.supported())
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = Nav.assign_return(socket, params)

    record =
      case socket.assigns.live_action do
        :new -> %TeachingType{}
        :edit -> Catalog.get_teaching_type!(params["id"])
        :index -> nil
      end

    {:noreply,
     assign(socket,
       editing: record,
       form: record && to_form(Catalog.change_teaching_type(record))
     )}
  end

  @impl true
  def handle_event("validate", %{"teaching_type" => attrs}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Catalog.change_teaching_type(socket.assigns.editing, attrs), action: :validate)
     )}
  end

  def handle_event("save", %{"teaching_type" => attrs}, socket) do
    result =
      if socket.assigns.editing.id,
        do: Catalog.update_teaching_type(socket.assigns.editing, attrs),
        else: Catalog.create_teaching_type(attrs)

    case result do
      {:ok, _record} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, gettext("Teaching type saved."))
         |> push_patch(to: Nav.with_return(~p"/teaching-types", socket.assigns.return_to))}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :deleting, Catalog.get_teaching_type!(id))}

  def handle_event("delete_cancel", _params, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("delete_confirm", _params, %{assigns: %{deleting: nil}} = socket),
    do: {:noreply, socket}

  # The list disables deletion of used types; this catches a concurrent change.
  def handle_event("delete_confirm", _params, socket) do
    case Catalog.delete_teaching_type(socket.assigns.deleting) do
      {:ok, _record} ->
        {:noreply,
         socket
         |> assign(:deleting, nil)
         |> load()
         |> put_flash(:info, gettext("Teaching type deleted."))
         |> push_patch(to: Nav.with_return(~p"/teaching-types", socket.assigns.return_to))}

      {:error, reason} ->
        {:noreply, socket |> assign(:deleting, nil) |> Errors.put(reason)}
    end
  end

  defp load(socket),
    do:
      assign(socket,
        types: Enum.sort_by(Catalog.list_teaching_types(), &teaching_type_label/1),
        usage: Catalog.teaching_type_usage()
      )

  # Names the reference that prevents deletion, or nil when the type is free.
  defp blocker(usage, type) do
    case Map.get(usage, type.id, 0) do
      0 ->
        nil

      count ->
        ngettext("Used by %{count} course", "Used by %{count} courses", count, count: count)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@navigation_term)}
      current_path={~p"/settings"}
      terms={@navigation_terms}
      current_term={@navigation_term}
    >
      <.link :if={@return_to} navigate={@return_to} class="btn mb-4">
        {Nav.return_label(@return_to)}
      </.link>
      <.page_header title={gettext("Teaching types")}>
        <:actions>
          <.link patch={Nav.with_return(~p"/teaching-types/new", @return_to)} class="btn btn-primary">
            <.icon name="hero-plus" class="size-4" /> {gettext("New teaching type")}
          </.link>
        </:actions>
      </.page_header>
      <p class="mb-4">
        {gettext(
          "Use the names your institution uses. Adding a teaching type does not create sessions."
        )}
      </p>
      <div class={["grid gap-4", @editing && "lg:grid-cols-[2fr_1fr]"]}>
        <div class="min-w-0">
          <.empty_state
            :if={@types == []}
            title={gettext("No teaching types yet")}
            message={gettext("Add the teaching types your institution uses.")}
            icon="hero-squares-2x2"
          >
            <:actions>
              <.link
                patch={Nav.with_return(~p"/teaching-types/new", @return_to)}
                class="btn btn-primary"
              >
                {gettext("New teaching type")}
              </.link>
            </:actions>
          </.empty_state>

          <.table
            :if={@types != []}
            id="teaching-types"
            rows={@types}
            row_id={&"teaching-type-#{&1.id}"}
          >
            <:col :let={type} label={gettext("Name")}>{teaching_type_label(type)}</:col>
            <:col :let={type} label={gettext("Courses")} numeric>{Map.get(@usage, type.id, 0)}</:col>
            <:action :let={type}>
              <.link
                patch={Nav.with_return(~p"/teaching-types/#{type.id}/edit", @return_to)}
                class="btn btn-ghost"
              >
                {gettext("Edit")}
              </.link>
              <button
                class="btn btn-ghost text-error"
                phx-click="delete_prompt"
                phx-value-id={type.id}
                disabled={blocker(@usage, type) != nil}
                title={blocker(@usage, type)}
              >
                {gettext("Delete")}
              </button>
            </:action>
          </.table>
        </div>
        <.details_panel
          :if={@editing}
          class="order-first lg:order-last"
          title={
            if @editing.id, do: gettext("Edit teaching type"), else: gettext("New teaching type")
          }
          on_close={JS.patch(Nav.with_return(~p"/teaching-types", @return_to))}
        >
          <.form
            for={@form}
            id="teaching-type-form"
            phx-mounted={JS.focus_first(to: "#teaching-type-form")}
            phx-change="validate"
            phx-submit="save"
            class="flex flex-col gap-3"
          >
            <.name_fields form={@form} locales={@locales} />
            <p :if={@editing.id} class="type-detail">
              {gettext("Name changes apply to every course and timetable using this type.")}
            </p>
            <div class="flex gap-2 pt-2">
              <.button variant="primary" phx-disable-with={gettext("Saving")}>{gettext("Save")}</.button>
              <.link
                patch={Nav.with_return(~p"/teaching-types", @return_to)}
                class="btn btn-ghost"
              >
                {gettext("Cancel")}
              </.link>
            </div>
          </.form>
        </.details_panel>
      </div>
      <.alert_dialog
        :if={@deleting}
        title={gettext("Delete %{name}?", name: teaching_type_label(@deleting))}
        message={
          gettext("Deletes the teaching type %{name}. This cannot be undone.",
            name: teaching_type_label(@deleting)
          )
        }
        confirm_label={gettext("Delete")}
        on_confirm="delete_confirm"
        on_cancel="delete_cancel"
      />
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :locales, :list, required: true

  def name_fields(assigns) do
    ~H"""
    <.input
      :for={locale <- @locales}
      id={"#{@form.id}_names_#{locale}"}
      name={"#{@form.name}[names][#{locale}]"}
      value={(@form[:names].value || %{})[locale]}
      label={gettext("Name (%{language})", language: NeuZeitWeb.Locale.label(locale))}
      errors={name_errors(@form, locale)}
      type="text"
      maxlength="100"
    />
    <p :if={length(@locales) > 1} class="type-detail">
      {gettext("Enter at least one name. If a translation is missing, an available name is shown.")}
    </p>
    """
  end

  defp name_errors(%{source: %{action: nil}}, _locale), do: []

  defp name_errors(form, locale) do
    children = Map.get(form.source.changes, :translations, [])

    errors =
      for child <- children,
          Ecto.Changeset.get_field(child, :locale) == locale,
          {_field, error} <- child.errors,
          do: error

    Enum.map(
      Keyword.get_values(form.source.errors, :names) ++ errors,
      &Errors.translate_validation/1
    )
  end
end
