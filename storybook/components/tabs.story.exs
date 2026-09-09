defmodule NeuZeitWeb.Stories.Tabs do
  use PhoenixStorybook.Story, :page
  import NeuZeitWeb.UI.Tabs

  def render(assigns) do
    assigns = assign(assigns, :view, if(assigns.tab == "groups", do: "groups", else: "teachers"))

    ~H"""
    <.tabs label="People" active={"/dev/storybook/components/tabs?tab=#{@view}"} items={[
      %{label: "Teachers", path: "/dev/storybook/components/tabs?tab=teachers"},
      %{label: "Groups", path: "/dev/storybook/components/tabs?tab=groups", badge: 2}
    ]} />
    <p>{if @view == "teachers", do: "Anna Weber", else: "WI-26-01, WI-26-02"}</p>
    """
  end
end
