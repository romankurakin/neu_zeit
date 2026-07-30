defmodule NeuZeitWeb.ProblemAssertions do
  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [json_response: 2]
  import Plug.Conn, only: [get_resp_header: 2]

  alias NeuZeitWeb.Problem

  def assert_problem(conn, status, type, title, extensions \\ %{}) do
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/problem+json")

    response = json_response(conn, status)

    assert response["type"] == Problem.type(type)
    assert response["title"] == title
    assert response["status"] == status

    Enum.each(extensions, fn {key, value} ->
      assert response[key] == value
    end)

    response
  end
end
