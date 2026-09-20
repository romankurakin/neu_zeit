defmodule NeuZeitWeb.UI.ErrorsTest do
  use ExUnit.Case, async: true

  alias NeuZeit.Planning.Placement
  alias NeuZeitWeb.UI.Errors

  describe "classify/1" do
    test "unwraps the error tuple" do
      assert {:flash, _} = Errors.classify({:error, :not_found})
    end

    test "sorts each context shape to its presentation" do
      changeset = Ecto.Changeset.change(%Placement{})

      assert {:form, ^changeset} = Errors.classify(changeset)
      assert {:flash, "room is taken"} = Errors.classify({:conflict, "room is taken"})
      assert {:flash, _} = Errors.classify(:not_found)

      assert {:diagnostics, [%{type: "room_conflict"}]} =
               Errors.classify(%{errors: [%{type: "room_conflict"}]})
    end

    test "reads solver results by status" do
      assert {:solver, "INFEASIBLE", message} =
               Errors.classify(%{"status" => "INFEASIBLE", "error" => "no solution"})

      assert message =~ "locked placements"
    end

    test "keeps unexpected error details in the log, not in the notice" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:flash, "The action could not be completed. Try again."} =
                   Errors.classify(:something_new)
        end)

      assert log =~ "something_new"
    end

    test "keeps unknown solver details in the log without changing its status" do
      result = %{"status" => "INTERNAL_ERROR", "error" => "worker process exited"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:solver, "INTERNAL_ERROR", "Calculation could not finish. Try again."} =
                   Errors.classify(result)
        end)

      assert log =~ "INTERNAL_ERROR"
      assert log =~ "worker process exited"
    end
  end

  describe "message/1" do
    test "localizes diagnostics while preserving related sessions and dates" do
      entry = %{
        type: "teacher_conflict",
        message: "teacher is already teaching on an overlapping week set",
        related: "MATH, Anna Weber, 101, 1, 2",
        occurrence_dates: ["2026-09-07"]
      }

      for {locale, expected} <- [
            {"ru", "У преподавателя уже есть занятие в это время."},
            {"de", "Die Lehrperson hat zur selben Zeit eine andere Einheit."}
          ] do
        Gettext.with_locale(NeuZeitWeb.Gettext, locale, fn ->
          message = Errors.message(%{errors: [entry]})
          assert message == expected <> ", MATH, Anna Weber, 101, 1, 2, 2026-09-07"
        end)
      end

      assert entry.message == "teacher is already teaching on an overlapping week set"
    end

    test "keeps an unknown diagnostic reason instead of replacing it with generic text" do
      entry = %{type: "future_check", message: "Specific explanation"}

      Gettext.with_locale(NeuZeitWeb.Gettext, "ru", fn ->
        assert Errors.message(%{errors: [entry]}) == "Specific explanation"
      end)
    end

    test "flattens changeset errors so they survive without a form" do
      changeset =
        %Placement{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:room_id, "is not allowed for this component")

      assert Errors.message(changeset) == "Room: Choose a room allowed for this teaching type."
    end

    test "inline and flash validation share translations and preserve numeric limits" do
      error =
        {"must be greater than %{number}", number: 0, validation: :number, kind: :greater_than}

      changeset =
        Ecto.Changeset.add_error(
          Ecto.Changeset.change(%Placement{}),
          :duration_slots,
          elem(error, 0),
          elem(error, 1)
        )

      for {locale, label, expected} <- [
            {"ru", "Длительность", "Введите значение больше 0."},
            {"de", "Dauer", "Geben Sie einen Wert über 0 ein."}
          ] do
        Gettext.with_locale(NeuZeitWeb.Gettext, locale, fn ->
          assert NeuZeitWeb.CoreComponents.translate_error(error) == expected
          assert Errors.message(changeset) == label <> ": " <> expected
        end)
      end

      assert changeset.errors[:duration_slots] == error
    end

    test "localizes legacy interpolated errors without losing limits or exposing internal ids" do
      Gettext.with_locale(NeuZeitWeb.Gettext, "ru", fn ->
        assert Errors.translate_validation(
                 {"term must keep at least 9 weeks; existing sessions or placements use week 9",
                  []}
               ) ==
                 "Сохраните не менее 9 учебных недель. Занятия используют неделю 9."

        assert Errors.translate_validation({"is outside the configured slot grid (1..8)", []}) ==
                 "Занятие должно целиком помещаться в учебный день. Интервалов в дне: 8."

        id = Ecto.UUID.generate()
        explanation = Errors.translate_validation({"leaves no valid start for session #{id}", []})
        assert explanation =~ "Проверьте его длительность и профиль времени."
        refute explanation =~ id
      end)
    end

    test "names workload planning fields in localized validation messages" do
      for {locale, labels, invalid} <- [
            {"ru", ["Требуемые часы", "Количество занятий", "Чередование недель"],
             "Проверьте значение."},
            {"de", ["Sollstunden", "Anzahl der Termine", "Wochenwechsel"],
             "Prüfen Sie diesen Wert."},
            {"en", ["Required hours", "Number of sessions", "Alternating weeks"],
             "Check this value."}
          ] do
        Gettext.with_locale(NeuZeitWeb.Gettext, locale, fn ->
          for {field, label} <-
                Enum.zip([:contact_hours, :rounding_mode, :remainder_parity], labels) do
            changeset =
              %NeuZeit.Catalog.Workload{}
              |> Ecto.Changeset.change()
              |> Ecto.Changeset.add_error(field, "is invalid")

            assert Errors.message(changeset) == label <> ": " <> invalid
          end
        end)
      end
    end

    test "localizes a stale calculation while preserving its original context message" do
      original =
        "The plan changed while the solver was running. Your edits were kept. Run the solver again."

      Gettext.with_locale(NeuZeitWeb.Gettext, "ru", fn ->
        assert Errors.message({:conflict, original}) ==
                 "Расписание изменилось во время расчёта. Ваши правки сохранены. Запустите расчёт заново."
      end)
    end

    test "uses Russian plural forms for validation limits" do
      Gettext.with_locale(NeuZeitWeb.Gettext, "ru", fn ->
        for {count, expected} <- [
              {1, "Введите ровно 1 символ."},
              {2, "Введите ровно 2 символа."},
              {5, "Введите ровно 5 символов."}
            ] do
          assert Errors.translate_validation({"should be %{count} character(s)", count: count}) ==
                   expected
        end

        # "не более" governs the genitive, so its forms differ from a bare numeral.
        for {count, expected} <- [
              {1, "Введите не более 1 символа."},
              {2, "Введите не более 2 символов."},
              {21, "Введите не более 21 символа."},
              {100, "Введите не более 100 символов."}
            ] do
          assert Errors.translate_validation(
                   {"should be at most %{count} character(s)", count: count}
                 ) ==
                   expected
        end
      end)
    end

    test "localizes solver diagnostics without changing the API result" do
      entry = %{
        type: "solver_infeasible",
        solver_status: "INFEASIBLE",
        message: "solver could not produce a complete timetable"
      }

      Gettext.with_locale(NeuZeitWeb.Gettext, "ru", fn ->
        assert Errors.entry_message(entry) =~ "Проверьте закреплённые размещения"

        assert Errors.entry_message(%{
                 type: "invalid_solver_output",
                 message: "room must be a UUID"
               }) ==
                 "Расчёт вернул некорректные данные. Результат не сохранён."
      end)

      assert entry.message == "solver could not produce a complete timetable"
    end

    test "counts hard conflicts" do
      errors = [%{type: "room_conflict"}, %{type: "cohort_conflict"}]
      assert Errors.message(%{errors: errors}) == "2 rule violations must be resolved first."
    end

    test "a single diagnostic states its own reason rather than being counted" do
      errors = [
        %{
          type: "exception_on_excluded_date",
          message: "active exception targets an excluded non-teaching date"
        }
      ]

      assert Errors.message(%{errors: errors}) ==
               "This date is marked as non-teaching. Choose another date."
    end

    test "falls back to counting when a lone diagnostic carries no message" do
      assert Errors.message(%{errors: [%{type: "room_conflict"}]}) =~ "1 rule violation must"
    end
  end
end
