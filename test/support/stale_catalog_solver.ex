defmodule NeuZeit.TestSupport.StaleCatalogSolver do
  @behaviour NeuZeit.Solver

  @impl true
  def solve(%{sessions: [session]}, _opts) do
    callback = Application.get_env(:neu_zeit, :stale_solver_callback)

    if is_function(callback, 0) do
      callback.()
    end

    [room_id | _] = session.allowed_rooms

    {:ok,
     %{
       "ok" => true,
       "status" => "OPTIMAL",
       "unplaced" => [],
       "assignment" => %{
         session.id => %{"room" => room_id, "day" => 1, "slot" => 1}
       }
     }}
  end
end
