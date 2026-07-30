defmodule NeuZeit.Solver do
  @moduledoc """
  Behaviour for timetable solver adapters.
  """

  @callback solve(spec :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  def solve(spec, opts \\ []) do
    NeuZeit.Solver.Runner.solve(spec, opts)
  end
end
