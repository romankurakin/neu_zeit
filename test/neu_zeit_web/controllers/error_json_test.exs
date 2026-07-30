defmodule NeuZeitWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  test "renders a problem map for a standard JSON error template" do
    assert NeuZeitWeb.ErrorJSON.render("404.json", %{}) == %{
             type: "about:blank",
             title: "Not Found",
             status: 404,
             detail: "Not Found"
           }
  end

  test "renders problem templates as encoded JSON" do
    assert "400.problem"
           |> NeuZeitWeb.ErrorJSON.render(%{})
           |> IO.iodata_to_binary()
           |> Jason.decode!() == %{
             "type" => "about:blank",
             "title" => "Bad Request",
             "status" => 400,
             "detail" => "Bad Request"
           }
  end
end
