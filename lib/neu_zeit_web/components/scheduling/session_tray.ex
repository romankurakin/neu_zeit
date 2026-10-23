defmodule NeuZeitWeb.Scheduling.SessionTray do
  @moduledoc "Unplaced sessions available for placement."
  use NeuZeitWeb, :ui_component
  import NeuZeitWeb.Scheduling.SessionCard

  attr :id, :string, required: true
  attr :sessions, :list, required: true
  attr :weeks_count, :integer, required: true
  attr :selected_session_id, :string, default: nil
  attr :on_select, :any, default: nil
  attr :empty_message, :string, default: nil

  def session_tray(assigns) do
    ~H"""
    <div
      id={@id}
      data-dropzone="tray"
      class="min-h-12 grid grid-cols-[repeat(auto-fill,minmax(14rem,1fr))] items-start gap-2 rounded-box border border-base-300 bg-base-100 p-2"
    >
      <p :if={@sessions == []} class="col-span-full type-detail text-base-content">
        {@empty_message || gettext("Everything is placed.")}
      </p>
      <.session_card
        :for={session <- @sessions}
        id={"#{@id}-session-#{session.id}"}
        session={session}
        weeks_count={@weeks_count}
        selected={@selected_session_id == session.id}
        on_select={@on_select}
      />
    </div>
    """
  end
end
