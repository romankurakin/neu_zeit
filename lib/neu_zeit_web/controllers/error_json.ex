defmodule NeuZeitWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
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
