defmodule NeuZeitWeb.Nav do
  @moduledoc """
  Sidebar sections for global registries and the selected term.
  """
  use NeuZeitWeb, :verified_routes

  use Gettext, backend: NeuZeitWeb.Gettext

  @doc "The same workflow groups remain visible before a term is selected."
  def sections(term \\ nil) do
    return_to = term && ~p"/terms/#{term}"
    [rooms, courses, people] = registry_items(return_to)

    [
      %{
        title: gettext("Institution"),
        items: [
          %{
            label: gettext("Institution settings"),
            path: ~p"/settings",
            icon: "hero-cog-6-tooth"
          },
          rooms,
          people,
          courses
        ]
      },
      %{
        title: gettext("Term"),
        items: [
          %{terms_item() | path: with_return(~p"/terms", return_to)},
          term_item(term, gettext("Overview"), "", "hero-squares-2x2"),
          term_item(term, gettext("Term settings"), "/settings", "hero-cog-6-tooth"),
          term_item(term, gettext("Availability"), "/availability", "hero-clock"),
          term_item(term, gettext("Time profiles"), "/slot-profiles", "hero-table-cells"),
          term_item(term, gettext("Teaching load"), "/workload", "hero-rectangle-stack")
        ]
      },
      %{
        title: gettext("Scheduling"),
        items: [
          term_item(term, gettext("Plans"), "/plans", "hero-clipboard-document-list"),
          term_item(term, gettext("Calendar"), "/calendar", "hero-calendar"),
          term_item(term, gettext("One-off changes"), "/exceptions", "hero-arrows-right-left")
        ]
      }
    ]
  end

  defp term_item(term, label, suffix, icon),
    do: %{label: label, path: term && ~p"/terms/#{term}" <> suffix, icon: icon}

  def active?(nil, _current_path), do: false
  def active?(_path, nil), do: false
  def active?(path, current_path), do: URI.parse(path).path == URI.parse(current_path).path

  def assign_return(socket, params) do
    value = Map.get(params, "return_to", socket.assigns[:return_to])

    safe =
      if is_binary(value) &&
           Regex.match?(
             ~r{\A/(terms|courses|rooms|people|teaching-types|settings)(/|\?|$)},
             value
           ) &&
           !String.contains?(value, "\\"), do: value, else: nil

    Phoenix.Component.assign(socket, :return_to, safe)
  end

  def with_return(path, nil), do: path

  def with_return(path, return_to),
    do:
      path <>
        if(String.contains?(path, "?"), do: "&", else: "?") <>
        URI.encode_query(%{"return_to" => return_to})

  defp terms_item, do: %{label: gettext("Terms"), path: ~p"/terms", icon: "hero-calendar-days"}

  # Global registries: reused across terms, so they sit outside the term scope.
  defp registry_items(return_to) do
    [
      %{label: gettext("Rooms"), path: ~p"/rooms", icon: "hero-building-office-2"},
      %{label: gettext("Courses"), path: ~p"/courses", icon: "hero-academic-cap"},
      %{label: gettext("Teachers and groups"), path: ~p"/people", icon: "hero-users"}
    ]
    |> Enum.map(fn item -> Map.update!(item, :path, &with_return(&1, return_to)) end)
  end
end
