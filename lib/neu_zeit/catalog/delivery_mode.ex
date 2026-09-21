defmodule NeuZeit.Catalog.DeliveryMode do
  @moduledoc "Shared delivery-mode and room rules for teaching sessions."

  @values [:in_person, :online]

  def values, do: @values

  def effective(record, override \\ nil)
  def effective(%{delivery_mode: mode}, override), do: override || mode || :in_person
  def effective(_record, override), do: override || :in_person

  def room_options(:online, _rooms), do: [nil]
  def room_options(:in_person, rooms), do: rooms

  def room_valid?(:online, room_id, _component), do: is_nil(room_id)

  def room_valid?(:in_person, room_id, component) when not is_nil(room_id),
    do: NeuZeit.Catalog.CourseComponent.room_allowed?(component, room_id)

  def room_valid?(:in_person, _room_id, _component), do: false

  def physical?(:in_person), do: true
  def physical?(_mode), do: false
end
