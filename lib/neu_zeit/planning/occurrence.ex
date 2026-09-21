defmodule NeuZeit.Planning.Occurrence do
  @moduledoc """
  A projected dated meeting. Normal occurrences are not persisted.
  """

  @enforce_keys [:session_id, :date, :day, :slot, :room_id, :source]
  defstruct [
    :session_id,
    :date,
    :day,
    :slot,
    :duration_slots,
    :delivery_mode,
    :room_id,
    :teacher_id,
    :placement_id,
    :exception_id,
    :source,
    :cancelled?
  ]
end
