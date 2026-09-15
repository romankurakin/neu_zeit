defmodule NeuZeitWeb.TeachingTypeControllerTest do
  use NeuZeitWeb.ConnCase, async: true
  import NeuZeit.Fixtures
  alias NeuZeit.Catalog

  test "CRUD supports custom translated types and enforces course references", %{conn: conn} do
    result =
      post(conn, ~p"/api/teaching_types",
        teaching_type: %{names: %{"en" => "Workshop", "ru" => "Мастерская", "de" => "Werkstatt"}}
      )
      |> json_response(201)

    id = result["data"]["id"]
    assert get(conn, ~p"/api/teaching_types/#{id}") |> json_response(200)
    assert get(conn, ~p"/api/teaching_types") |> json_response(200)
    component = component_fixture(kind: id)
    assert delete(conn, ~p"/api/teaching_types/#{id}") |> json_response(422)

    assert patch(conn, ~p"/api/teaching_types/#{id}",
             teaching_type: %{names: %{"ru" => "Практикум"}}
           )
           |> json_response(200)

    assert label(Catalog.get_course_component!(component.id).teaching_type, "ru") == "Практикум"
    {:ok, _} = Catalog.delete_course_component(component)
    assert response(delete(conn, ~p"/api/teaching_types/#{id}"), 204) == ""
    assert get(conn, ~p"/api/teaching_types/#{id}") |> json_response(404)
  end

  defp label(type, locale), do: NeuZeit.Catalog.Translation.text(type.translations, locale, :name)
end
