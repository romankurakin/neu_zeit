defmodule NeuZeitWeb.NavigationContext do
  @moduledoc "Keeps the selected term available on registry pages and across navigation."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, get_connect_params: 1, push_navigate: 2]

  def on_mount(:default, _params, _session, socket) do
    saved_id = (get_connect_params(socket) || %{})["navigation_term"]

    {:cont,
     socket
     |> assign(:navigation_term_id, saved_id)
     |> attach_hook(:navigation_context, :handle_params, &assign_context/3)
     |> attach_hook(:navigation_switch, :handle_event, &switch_term/3)}
  end

  defp assign_context(params, uri, socket) do
    terms = NeuZeit.Catalog.list_terms()
    path = URI.parse(uri).path
    id = params["term_id"] || term_id(path) || term_id(params["return_to"])
    selected_id = id || socket.assigns.navigation_term_id
    term = Enum.find(terms, &(&1.id == selected_id)) || List.last(terms)

    {:cont,
     socket
     |> assign(:navigation_section, section(path))
     |> assign(:navigation_terms, terms)
     |> assign(:navigation_term, term)
     |> assign(:navigation_term_id, term && term.id)}
  end

  defp section(path) do
    case String.split(path, "/", trim: true) do
      ["terms", _id, section | _rest]
      when section in ~w(settings availability calendar exceptions workload sessions plans slot-profiles) ->
        "/" <> section

      _ ->
        ""
    end
  end

  defp term_id(path) when is_binary(path) do
    case String.split(URI.parse(path).path || "", "/", trim: true) do
      ["terms", id | _rest] ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> id
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp term_id(_path), do: nil

  defp switch_term("switch_term", %{"term_id" => id}, socket) do
    if Enum.any?(socket.assigns.navigation_terms, &(&1.id == id)) do
      {:halt, push_navigate(socket, to: "/terms/#{id}#{socket.assigns.navigation_section}")}
    else
      {:halt, socket}
    end
  end

  defp switch_term(_event, _params, socket), do: {:cont, socket}
end
