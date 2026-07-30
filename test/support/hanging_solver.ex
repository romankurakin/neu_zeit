defmodule NeuZeit.TestSupport.HangingSolver do
  @behaviour NeuZeit.Solver

  @impl true
  def solve(_spec, _opts) do
    receive do
      :stop -> {:error, :stopped}
    end
  end
end
