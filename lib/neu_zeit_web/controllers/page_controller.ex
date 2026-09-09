defmodule NeuZeitWeb.PageController do
  use NeuZeitWeb, :controller

  @doc """
  Redirects the home page to the term list.
  """
  def home(conn, _params), do: redirect(conn, to: ~p"/terms")
end
