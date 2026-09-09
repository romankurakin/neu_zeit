defmodule NeuZeitWeb.Scheduling.Labels do
  @moduledoc "Labels for teaching types, weekdays and built-in time profiles."
  use NeuZeitWeb, :ui_component

  @doc """
  Translates a teaching-type enum for display. Stored enum values remain unchanged.
  """
  def component_kind_label("lecture"), do: gettext("Lecture")
  def component_kind_label("seminar"), do: gettext("Seminar")
  def component_kind_label("lab"), do: gettext("Lab")
  def component_kind_label(kind), do: kind

  def slot_profile_label(%{preset_key: "weekday_daytime", name: name}) do
    if NeuZeit.Catalog.SlotProfile.daytime_name?(name),
      do: gettext("Weekdays, daytime"),
      else: name
  end

  def slot_profile_label(%{name: name}), do: name

  @doc "Localize weekday labels while preserving custom grid labels."
  def day_label("Mon"), do: gettext("Mon")
  def day_label("Tue"), do: gettext("Tue")
  def day_label("Wed"), do: gettext("Wed")
  def day_label("Thu"), do: gettext("Thu")
  def day_label("Fri"), do: gettext("Fri")
  def day_label("Sat"), do: gettext("Sat")
  def day_label("Sun"), do: gettext("Sun")
  def day_label(label), do: label
end
