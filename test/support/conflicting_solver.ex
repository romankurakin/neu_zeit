defmodule NeuZeit.TestSupport.ConflictingSolver do
  @behaviour NeuZeit.Solver

  @impl true
  def solve(%{sessions: [first, second | _sessions]}, _opts) do
    [room_id | _] = first.allowed_rooms

    {:ok,
     %{
       "ok" => true,
       "status" => "OPTIMAL",
       "unplaced" => [],
       "assignment" => %{
         first.id => %{"room" => room_id, "day" => 1, "slot" => 1},
         second.id => %{"room" => room_id, "day" => 1, "slot" => 1}
       }
     }}
  end
end
