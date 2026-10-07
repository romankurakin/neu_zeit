defmodule NeuZeitWeb.Stories.Combobox do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.UI.Combobox, only: [combobox: 1]

  @teachers [
    {"Anna Weber", "weber"},
    {"Boris Petrov", "petrov"},
    {"Chen Li", "chen"},
    {"Dana Ivanova", "ivanova"},
    {"Emil Schmidt", "schmidt"}
  ]

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, form: to_form(%{"teacher_id" => "chen"}), teachers: @teachers)}

  @impl true
  def handle_event("validate", params, socket),
    do: {:noreply, assign(socket, :form, to_form(params))}

  @impl true
  def render(assigns) do
    ~H"""
    <form id="combobox-story" phx-change="validate" class="max-w-sm">
      <.combobox
        field={@form[:teacher_id]}
        label={gettext("Teacher")}
        prompt={gettext("Choose a teacher")}
        options={@teachers}
      />
      <p class="mt-2 type-detail">{gettext("Chosen")}: {@form[:teacher_id].value}</p>
    </form>
    """
  end
end
