defmodule NeuZeitWeb.Stories.Typography do
  use PhoenixStorybook.Story, :example
  use Gettext, backend: NeuZeitWeb.Gettext

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <h1 class="type-display">Page title</h1>
      <h2 class="type-title">Dialog title</h2>
      <h3 class="type-heading">Section or card title</h3>
      <p class="type-body">Body text</p>
      <p class="type-detail">Compact data and form labels</p>
      <p class="type-detail tabular-nums">08:00-09:30, 12:20-13:50</p>
      <div class="grid gap-4 md:grid-cols-3">
        <div :for={{lang, title, text} <- [{"en", "Teaching weeks", "Edit session weeks and duration"}, {"ru", "Учебные недели", "Изменить недели и длительность"}, {"de", "Unterrichtswochen", "Wochen und Dauer ändern"}]} lang={lang}>
          <h3 class="type-heading">{title}</h3><p class="type-detail">{text}</p>
        </div>
      </div>
    </div>
    """
  end
end
