defmodule NeuZeitWeb.UI.LoadingState do
  @moduledoc "Inline progress for a running operation."
  use NeuZeitWeb, :ui_component

  @doc """
  Shows inline progress with elapsed time and the configured limit.
  """
  attr :label, :string, default: nil
  attr :elapsed_seconds, :integer, default: nil
  attr :limit_seconds, :integer, default: nil

  def loading_state(assigns) do
    ~H"""
    <div
      role="status"
      aria-live="polite"
      class="card card-border items-center gap-4 border-base-300 bg-base-100 p-6"
    >
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="type-heading">{@label || gettext("Working")}</p>
      <p :if={@elapsed_seconds} class="type-detail text-base-content">
        {if @limit_seconds,
          do:
            gettext("Elapsed: %{elapsed} s. Limit: %{limit} s.",
              elapsed: @elapsed_seconds,
              limit: @limit_seconds
            ),
          else: gettext("Elapsed: %{elapsed} s.", elapsed: @elapsed_seconds)}
      </p>
      <progress
        :if={@elapsed_seconds && @limit_seconds}
        class="progress progress-primary w-full max-w-64"
        value={min(@elapsed_seconds, @limit_seconds)}
        max={@limit_seconds}
        aria-label={@label || gettext("Working")}
      ></progress>
    </div>
    """
  end
end
