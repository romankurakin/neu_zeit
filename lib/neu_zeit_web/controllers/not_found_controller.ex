defmodule NeuZeitWeb.NotFoundController do
  use NeuZeitWeb, :controller

  alias NeuZeitWeb.Problem

  def not_found(conn, _params) do
    Problem.send(conn, :not_found, Problem.type(:not_found), "Not Found", "API route not found")
  end
end
