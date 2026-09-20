defmodule NeuZeit.Catalog.WorkloadSnapshot do
  @moduledoc "A loaded teaching requirement, its generated sessions and their edit protections."

  @enforce_keys [:id, :requirement, :sessions]
  defstruct [:id, :requirement, :sessions, placed_ids: MapSet.new(), history_ids: MapSet.new()]
end
