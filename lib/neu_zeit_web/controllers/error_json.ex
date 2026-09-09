defmodule NeuZeitWeb.ErrorJSON do
  @moduledoc """
  Formats endpoint errors for JSON requests.
  """

  def render(template, _assigns) do
    problem = NeuZeitWeb.Problem.from_template(template)

    if String.ends_with?(template, ".problem") do
      Phoenix.json_library().encode_to_iodata!(problem)
    else
      problem
    end
  end
end
