defmodule NeuZeit.TestSupport.PartialSolver do
  @behaviour NeuZeit.Solver

  @impl true
  def solve(%{sessions: sessions}, _opts) do
    unplaced = Enum.find(sessions, &(&1.sequence_group == "unplaced"))
    assigned = Enum.find(sessions, &(&1.sequence_group == "assigned"))
    [room_id | _] = assigned.allowed_rooms

    {:ok,
     %{
       "ok" => true,
       "status" => "FEASIBLE",
       "wall_time" => 0.01,
       "unplaced" => [unplaced.id],
       "assignment" => %{
         assigned.id => %{"room" => room_id, "day" => 1, "slot" => 1}
       }
     }}
  end
end
