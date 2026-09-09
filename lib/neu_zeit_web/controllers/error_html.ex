defmodule NeuZeitWeb.ErrorHTML do
  @moduledoc """
  Formats endpoint errors for HTML requests.
  """
  use NeuZeitWeb, :html

  def render("404.html", _assigns), do: gettext("Page not found. Check the address.")

  def render(_template, _assigns), do: gettext("Could not open this page. Try again.")
end
