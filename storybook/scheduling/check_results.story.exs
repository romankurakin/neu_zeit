defmodule NeuZeitWeb.Stories.CheckResults do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext
  import NeuZeitWeb.Scheduling.CheckResults

  @impl true
  def render(assigns) do
    ~H"""
    <.check_results id="example-checks">
      <:item status={:ok} label="Session placements" detail="All sessions are placed.">0</:item>
      <:item status={:warning} label="Teacher names" detail="Review abbreviated names.">2</:item>
      <:item status={:unknown} label="Teacher availability" detail="Availability has not been checked.">12</:item>
      <:item status={:error} label="Room conflicts" detail="Two sessions use the same room.">1</:item>
    </.check_results>
    """
  end
end
