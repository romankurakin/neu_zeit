defmodule NeuZeitWeb.Scheduling.Labels do
  @moduledoc "Labels for teaching types, weekdays and built-in time profiles."
  use NeuZeitWeb, :ui_component

  @doc "Uses the selected language, falling back to an available registry name."
  def component_kind_label(%{teaching_type: teaching_type}),
    do: teaching_type_label(teaching_type)

  def teaching_type_label(type) do
    NeuZeit.Catalog.Translation.text(
      type.translations,
      Gettext.get_locale(NeuZeitWeb.Gettext),
      :name,
      nil,
      NeuZeitWeb.Locale.default()
    )
  end

  def course_title(course) do
    NeuZeit.Catalog.Translation.text(
      course.translations,
      Gettext.get_locale(NeuZeitWeb.Gettext),
      :title,
      course.title
    )
  end

  def delivery_mode_label(mode) when mode in [:online, "online"], do: gettext("Online")
  def delivery_mode_label(_mode), do: gettext("In person")

  def delivery_mode_options,
    do: [{gettext("In person"), "in_person"}, {gettext("Online"), "online"}]

  def room_label(nil), do: gettext("Online")
  def room_label(room), do: room.name

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
