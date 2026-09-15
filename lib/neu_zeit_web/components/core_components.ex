defmodule NeuZeitWeb.CoreComponents do
  @moduledoc """
  Shared form, button, notice and icon components.

  Reuse DaisyUI and `NeuZeitWeb.UI` before adding a component. Keep page-specific
  components beside their LiveView. Custom code must serve behavior or geometry
  the existing components cannot provide.

  Keep the default control size and consistent sizes within each toolbar.
  Use `btn-primary` for the main action and `btn-neutral` for ordinary actions.
  Typography and spacing rules are next to their definitions in `assets/css/app.css`.

  Check component changes in light and dark themes, with keyboard navigation,
  narrow screens and long translations. Storybook includes the typography examples.
  """
  use Phoenix.Component
  use Gettext, backend: NeuZeitWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice.

  ## Example

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :loading, :boolean, default: false
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <% message = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind) %>
    <div
      :if={@title || message}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <span :if={@loading} class="loading loading-spinner loading-sm shrink-0" aria-hidden="true"></span>
        <.icon
          :if={not @loading and @kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0"
        />
        <.icon
          :if={not @loading and @kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0"
        />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p :if={message}>{message}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button or navigation link.

  ## Examples

      <.button phx-click="save" variant="primary">{gettext("Save")}</.button>
      <.button navigate={~p"/"}>{gettext("Terms")}</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form)

  attr :class, :any, default: nil

  attr :variant, :string,
    default: "default",
    values: ~w(default primary secondary ghost outline destructive)

  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "default" => nil,
      "primary" => "btn-primary",
      "secondary" => "btn-neutral",
      "ghost" => "btn-ghost",
      "outline" => "btn-outline",
      "destructive" => "btn-error"
    }

    sizes = %{"xs" => "btn-xs", "sm" => "btn-sm", "md" => "btn-md", "lg" => "btn-lg"}

    assigns =
      assign(assigns, :class, [
        "btn",
        variants[assigns.variant],
        sizes[assigns.size],
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders a labelled input and its validation errors.

  Pass a `Phoenix.HTML.FormField` to derive the name, ID and value.
  You can also pass these attributes explicitly.

  Use `type="select"` with `options` for a dropdown. Use `type="checkbox"`
  for a boolean field. Render radio buttons directly in the template.
  Use `Phoenix.Component.live_file_input/1` for live uploads.

  ## Examples

      <.input field={@form[:name]} type="text" label={gettext("Name")} />
      <.input field={@form[:locale]} type="select" options={@locales} />

  Select options follow `Phoenix.HTML.Form.options_for_select/2`.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset type-detail">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset type-detail">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset type-detail">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "time"} = assigns), do: NeuZeitWeb.UI.TimeField.time_field(assigns)

  # Handles the remaining HTML input types.
  def input(assigns) do
    ~H"""
    <div class="fieldset type-detail">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "Renders a message under the field it belongs to."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1 flex gap-2 items-center type-detail text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders an icon from the bundled Heroicons set.

  The default style is outline. Add `-solid` or `-mini` for another style.
  Use Tailwind classes to set size and colour.
  `assets/vendor/heroicons.ts` includes icons from the `heroicons` npm package in the CSS build.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="size-3" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # Entrances and exits both use ease-out, so an element arrives fast and settles.
  # The motion-safe variant leaves the start and end states, without the travel.
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition:
        {"motion-safe:transition-all ease-out duration-200",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"motion-safe:transition-all ease-out duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error(error), do: NeuZeitWeb.UI.Errors.translate_validation(error)

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
