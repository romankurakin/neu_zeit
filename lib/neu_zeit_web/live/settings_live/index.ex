defmodule NeuZeitWeb.SettingsLive.Index do
  use NeuZeitWeb, :live_view
  alias NeuZeit.Settings
  alias NeuZeitWeb.{Locale, Nav}

  def mount(_params, _session, socket) do
    settings = Settings.get()

    {:ok,
     socket
     |> assign(:page_title, gettext("Institution settings"))
     |> assign(:settings, settings)
     |> assign(:timezones, Settings.timezones())
     |> assign(:locales, Gettext.known_locales(NeuZeitWeb.Gettext))
     |> assign(:form, to_form(Settings.change(settings)))}
  end

  def handle_event("validate", %{"institution" => attrs}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Settings.change(socket.assigns.settings, attrs), action: :validate)
     )}
  end

  def handle_event("save", %{"institution" => attrs}, socket) do
    case Settings.save(attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Settings saved."))
         |> push_navigate(to: ~p"/settings")}

      {:error, reason} ->
        {:noreply, Errors.put(socket, reason, as: :form)}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      nav={Nav.sections(@navigation_term)}
      current_path={~p"/settings"}
      terms={@navigation_terms}
      current_term={@navigation_term}
    >
      <.page_header title={gettext("Institution settings")} />
      <.form
        for={@form}
        id="institution-settings"
        phx-change="validate"
        phx-submit="save"
        class="flex flex-col gap-4"
      >
        <div class="grid items-start gap-4 lg:grid-cols-2">
          <.card title={gettext("Institution")}>
            <div class="flex flex-col gap-4">
              <.input
                field={@form[:name]}
                label={gettext("Institution name")}
                required
                maxlength="100"
              />
              <.input
                field={@form[:timezone]}
                label={gettext("Time zone")}
                list="institution-timezones"
                required
              />
              <datalist id="institution-timezones"><option :for={zone <- @timezones} value={zone} /></datalist>
              <p class="type-detail">
                {gettext(
                  "Timetable times are local to this time zone. Changing it keeps the entered times."
                )}
              </p>
            </div>
          </.card>
          <.card title={gettext("Languages")}>
            <div class="flex flex-col gap-4">
              <fieldset>
                <legend class="mb-2 font-semibold">{gettext("Available languages")}</legend>
                <input type="hidden" name="institution[supported_locales][]" value="" />
                <label :for={locale <- @locales} class="flex items-center gap-2 mb-2">
                  <input
                    type="checkbox"
                    class="checkbox"
                    name="institution[supported_locales][]"
                    value={locale}
                    checked={locale in (@form[:supported_locales].value || [])}
                  />
                  {Locale.label(locale)}
                </label>
                <p :for={error <- @form[:supported_locales].errors} class="text-error">
                  {Errors.translate_validation(error)}
                </p>
              </fieldset>
              <.input
                field={@form[:default_locale]}
                type="select"
                label={gettext("Default language")}
                options={Enum.map(@locales, &{Locale.label(&1), &1})}
              />
              <p class="type-detail">
                {gettext(
                  "Only enabled languages appear in the language switcher and translation forms. Saved translations are kept."
                )}
              </p>
            </div>
          </.card>
        </div>
        <.button variant="primary" class="self-start" phx-disable-with={gettext("Saving")}>{gettext(
          "Save"
        )}</.button>
      </.form>
      <.card title={gettext("Teaching types")} class="mt-6">
        <p class="mb-4">
          {gettext("Manage the teaching types and their translated names for all terms.")}
        </p>
        <.link navigate={Nav.with_return(~p"/teaching-types", ~p"/settings")} class="btn">{gettext(
          "Manage teaching types"
        )}</.link>
      </.card>
    </Layouts.app>
    """
  end
end
