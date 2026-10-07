defmodule NeuZeit.Catalog.WorkloadImportTest do
  use NeuZeit.DataCase, async: false
  import NeuZeit.Fixtures
  alias NeuZeit.Catalog
  alias NeuZeit.Catalog.{WorkloadImport, Workloads}

  describe "parse/1" do
    test "reads comma separated lines with the header in any order and case" do
      assert {:ok, [row]} =
               WorkloadImport.parse("""
               Teacher, COURSE , teaching type,groups,hours,duration
               Ivanova, Algorithms, Lecture, CS-1 | CS-2, 32, 2
               """)

      assert row.line == 2
      assert row.course == "Algorithms"
      assert row.teaching_type == "Lecture"
      assert row.teacher == "Ivanova"
      assert row.groups == ["CS-1", "CS-2"]
      assert row.hours == "32"
      assert row.duration == "2"
      assert row.format == ""
    end

    test "detects semicolons, strips the BOM and keeps quoted separators and quotes" do
      content =
        "﻿course;teaching type;teacher;groups;hours;duration;format\r\n" <>
          "\"Algorithms; part 1\";Lecture;\"Ivanova \"\"Anna\"\"\";CS-1;4,5;2;Online\r\n" <>
          "\r\n" <>
          "Algorithms;Seminar;Petrov;CS-1;4;2;\r\n"

      assert {:ok, [first, second]} = WorkloadImport.parse(content)
      assert first.line == 2
      assert first.course == "Algorithms; part 1"
      assert first.teacher == "Ivanova \"Anna\""
      assert first.hours == "4,5"
      assert first.format == "Online"
      assert second.line == 4
      assert second.teacher == "Petrov"
    end

    test "counts lines inside quoted fields for later line numbers" do
      assert {:ok, [first, second]} =
               WorkloadImport.parse(
                 "course,teaching type,teacher,groups,hours,duration\n" <>
                   "\"Algo\nrithms\",Lecture,Ivanova,CS-1,4,2\n" <>
                   "Algorithms,Lecture,Ivanova,CS-1,4,2\n"
               )

      assert first.line == 2
      assert first.course == "Algo\nrithms"
      assert second.line == 4
    end

    test "reports missing columns, empty files and non UTF-8 text" do
      assert {:error, {:missing_columns, ["teacher", "hours"]}} =
               WorkloadImport.parse("course,teaching type,groups,duration\nA,B,C,2\n")

      assert {:error, :empty} = WorkloadImport.parse("")

      assert {:error, :empty} =
               WorkloadImport.parse("course,teaching type,teacher,groups,hours,duration\n\n")

      assert {:error, :invalid_encoding} = WorkloadImport.parse(<<0xFF, 0xFE, "course">>)
    end
  end

  describe "resolve/2" do
    setup do
      term = term_fixture(ends_on: ~D[2026-09-13])
      course = course_fixture(title: "Algorithms")

      {:ok, _} =
        Catalog.create_course_translation(%{
          course_id: course.id,
          locale: "ru",
          title: "Алгоритмы"
        })

      component = component_fixture(course: course)
      teacher = teacher_fixture(name: "Ivanova")
      cohort = cohort_fixture(name: "CS-1")
      other = cohort_fixture(name: "CS-2")

      %{
        term: term,
        course: course,
        component: component,
        teacher: teacher,
        cohort: cohort,
        other: other,
        context: WorkloadImport.context(term)
      }
    end

    test "matches names case-insensitively, by translation and by teaching type id", ctx do
      {:ok, rows} =
        WorkloadImport.parse("""
        course,teaching type,teacher,groups,hours,duration,format
        алгоритмы, lecture, IVANOVA, cs-1|CS-2, 32, 2, ONLINE
        Algorithms, Лекция, Ivanova, CS-1, 4.5, 2
        """)

      assert [first, second] = WorkloadImport.resolve(rows, ctx.context)
      assert first.errors == []

      assert first.attrs == %{
               "course_component_id" => ctx.component.id,
               "teacher_id" => ctx.teacher.id,
               "cohort_ids" => [ctx.cohort.id, ctx.other.id],
               "contact_hours" => "32",
               "duration_slots" => 1,
               "delivery_mode" => "online"
             }

      assert second.errors == []
      assert second.attrs["delivery_mode"] == "in_person"
      assert second.attrs["contact_hours"] == "4.5"
      assert WorkloadImport.valid?([first, second])
    end

    test "reports every reason with the line", ctx do
      {:ok, rows} =
        WorkloadImport.parse("""
        course,teaching type,teacher,groups,hours,duration,format
        Physics, Lecture, Ivanova, CS-1, 4, 2
        Algorithms, Lab, Petrov, CS-9|CS-1, abc, 3, hybrid
        , Lecture,,,,,
        Algorithms, Lecture, Ivanova, CS-1, -1, 0
        """)

      assert [physics, lab, blank, negative] = WorkloadImport.resolve(rows, ctx.context)
      assert physics.line == 2
      assert physics.errors == [{:not_found, :course, "Physics"}]

      assert lab.errors == [
               {:not_found, :teaching_type, "Lab"},
               {:not_found, :teacher, "Petrov"},
               {:not_found, :group, "CS-9"},
               {:invalid_number, :hours, "abc"},
               {:invalid_duration, "3"},
               {:invalid_format, "hybrid"}
             ]

      assert blank.errors == [
               {:blank, :course},
               {:blank, :teacher},
               {:blank, :groups},
               {:blank, :hours},
               {:blank, :duration}
             ]

      assert negative.errors == [
               {:invalid_number, :hours, "-1"},
               {:invalid_number, :duration, "0"}
             ]

      refute WorkloadImport.valid?([physics, lab, blank, negative])
    end

    test "reports names that match several records", ctx do
      teacher_fixture(name: "ivanova")

      {:ok, rows} =
        WorkloadImport.parse("""
        course,teaching type,teacher,groups,hours,duration
        Algorithms, Lecture, Ivanova, CS-1, 4, 2
        """)

      assert [row] = WorkloadImport.resolve(rows, WorkloadImport.context(ctx.term))
      assert row.errors == [{:ambiguous, :teacher, "Ivanova"}]
    end

    test "save writes all rows or none", ctx do
      {:ok, rows} =
        WorkloadImport.parse("""
        course,teaching type,teacher,groups,hours,duration
        Algorithms, Lecture, Ivanova, CS-1, 4, 2
        Algorithms, Lecture, Ivanova, CS-2, 6, 2
        """)

      rows = WorkloadImport.resolve(rows, ctx.context)
      assert {:ok, 2} = WorkloadImport.save(ctx.term.id, rows)
      assert length(Workloads.list(ctx.term.id)) == 2

      {:ok, duplicate} =
        WorkloadImport.parse("""
        course,teaching type,teacher,groups,hours,duration
        Algorithms, Lecture, Ivanova, CS-1|CS-2, 4, 2
        Algorithms, Lecture, Ivanova, CS-1, 8, 2
        """)

      duplicate = WorkloadImport.resolve(duplicate, ctx.context)

      assert {:error, {3, %Ecto.Changeset{} = changeset}} =
               WorkloadImport.save(ctx.term.id, duplicate)

      assert %{course_component_id: [_]} = errors_on(changeset)
      assert length(Workloads.list(ctx.term.id)) == 2
    end
  end
end
