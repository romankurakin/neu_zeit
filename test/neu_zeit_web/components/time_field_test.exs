defmodule NeuZeitWeb.TimeFieldTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "time picker labels follow the interface language" do
    for {locale, choose, hours, minutes, done, cancel, invalid} <- [
          {"en", "Choose time", "Hours", "Minutes", "Done", "Cancel", "Enter time as HH:MM."},
          {"ru", "Выбрать время", "Часы", "Минуты", "Готово", "Отмена",
           "Введите время в формате ЧЧ:ММ."},
          {"de", "Uhrzeit wählen", "Stunden", "Minuten", "Fertig", "Abbrechen",
           "Uhrzeit im Format HH:MM eingeben."}
        ] do
      html =
        Gettext.with_locale(NeuZeitWeb.Gettext, locale, fn ->
          render_component(&NeuZeitWeb.CoreComponents.input/1,
            id: "starts-at",
            name: "starts_at",
            type: "time",
            value: "08:00"
          )
        end)

      for {key, label} <- [
            choose: choose,
            hours: hours,
            minutes: minutes,
            done: done,
            cancel: cancel,
            invalid: invalid
          ] do
        assert html =~ ~s(data-label-#{key}="#{label}")
      end

      assert html =~ ~s(aria-label="#{choose}")
      assert html =~ ~s(type="text")
      refute html =~ ~s(type="time")
    end
  end
end
