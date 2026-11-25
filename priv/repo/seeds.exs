# Fills an empty database with a fictional demonstration dataset:
#
#     docker compose exec application mix run priv/repo/seeds.exs
#
# All names are invented. The script stops when any course exists, so it never
# duplicates records. It creates the autumn 2026 term, two buildings with
# seven rooms, eight teachers, four groups, twenty courses, the teaching load
# of eight of them and a draft plan ready for a calculation.

alias NeuZeit.{Catalog, Planning, Repo}
alias NeuZeit.Catalog.{Course, Workloads}

created = fn
  {:ok, record} -> record
  {:error, reason} -> raise "seed failed: #{inspect(reason)}"
end

if Repo.exists?(Course) do
  IO.puts("Courses already exist; seeds skipped.")
else
  Repo.transaction(fn ->
    term =
      created.(
        Catalog.create_term(%{
          name: "Осенний семестр 2026",
          starts_on: ~D[2026-09-07],
          ends_on: ~D[2026-12-19],
          excluded_dates: []
        })
      )

    main = created.(Catalog.create_building(%{name: "Главный корпус"}))
    labs = created.(Catalog.create_building(%{name: "Лабораторный корпус"}))

    room = fn building, name ->
      created.(Catalog.create_room(%{building_id: building.id, name: name}))
    end

    halls = [room.(main, "Ауд. 101"), room.(main, "Ауд. 102")]
    classrooms = [room.(main, "Ауд. 201"), room.(main, "Ауд. 202")]
    lab_rooms = [room.(labs, "Лаб. 1"), room.(labs, "Лаб. 2"), room.(labs, "Лаб. 3")]

    teachers =
      for name <- [
            "Абенова Д. К.",
            "Борисов А. М.",
            "Вагнер Е. Ф.",
            "Галиев Р. Т.",
            "Дюсенова С. А.",
            "Ершов П. В.",
            "Жунусов Н. Б.",
            "Зимина О. Л."
          ],
          into: %{},
          do: {name, created.(Catalog.create_teacher(%{name: name}))}

    groups =
      for name <- ["ТЛМ-23-1", "ТЛМ-23-2", "ТЛМ-22-1", "ТЛМ-22-2"],
          into: %{},
          do: {name, created.(Catalog.create_cohort(%{name: name}))}

    rooms_for = %{"lecture" => halls, "seminar" => classrooms, "lab" => lab_rooms}

    # Code, title and the kind of the group classes that follow the lecture.
    courses =
      for {code, title, class_kind} <- [
            {"TLM101", "Введение в телематику", "seminar"},
            {"MAT101", "Математический анализ", "seminar"},
            {"MAT102", "Линейная алгебра", "seminar"},
            {"PHY101", "Физика", "lab"},
            {"PRG101", "Основы программирования", "lab"},
            {"PRG201", "Алгоритмы и структуры данных", "lab"},
            {"NET201", "Компьютерные сети", "lab"},
            {"NET301", "Протоколы маршрутизации", "lab"},
            {"DB201", "Базы данных", "lab"},
            {"OS201", "Операционные системы", "lab"},
            {"WEB301", "Серверная разработка", "lab"},
            {"SEC301", "Информационная безопасность", "seminar"},
            {"SIG201", "Теория сигналов", "seminar"},
            {"TEL301", "Системы мобильной связи", "seminar"},
            {"STA201", "Теория вероятностей и статистика", "seminar"},
            {"EMB301", "Встраиваемые системы", "lab"},
            {"ENG101", "Профессиональный английский язык", "seminar"},
            {"GER101", "Немецкий язык", "seminar"},
            {"ECO101", "Экономика предприятия", "seminar"},
            {"PRJ401", "Проектный практикум", "seminar"}
          ],
          into: %{} do
        course = created.(Catalog.create_course(%{code: code, title: title}))

        components =
          for kind <- ["lecture", class_kind], into: %{} do
            component =
              created.(
                Catalog.create_course_component(%{
                  course_id: course.id,
                  kind: kind,
                  allowed_room_ids: Enum.map(rooms_for[kind], & &1.id)
                })
              )

            {kind, component}
          end

        {code, {components, class_kind}}
      end

    # One 90-minute class is two academic hours, so 16 hours are 8 classes.
    workload = fn component, teacher, group_names ->
      created.(
        Workloads.save(term.id, nil, %{
          "course_component_id" => component.id,
          "teacher_id" => teachers[teacher].id,
          "cohort_ids" => Enum.map(group_names, &groups[&1].id),
          "contact_hours" => "16",
          "duration_slots" => 1,
          "delivery_mode" => "in_person"
        })
      )
    end

    # Both groups of a year attend one lecture; each group has its own classes.
    for {year_groups, load} <- [
          {["ТЛМ-23-1", "ТЛМ-23-2"],
           [
             {"TLM101", "Абенова Д. К."},
             {"MAT101", "Борисов А. М."},
             {"PHY101", "Вагнер Е. Ф."},
             {"PRG101", "Галиев Р. Т."}
           ]},
          {["ТЛМ-22-1", "ТЛМ-22-2"],
           [
             {"NET201", "Дюсенова С. А."},
             {"DB201", "Ершов П. В."},
             {"OS201", "Жунусов Н. Б."},
             {"PRG201", "Зимина О. Л."}
           ]}
        ],
        {code, teacher} <- load do
      {components, class_kind} = courses[code]
      workload.(components["lecture"], teacher, year_groups)
      for group <- year_groups, do: workload.(components[class_kind], teacher, [group])
    end

    created.(Planning.create_plan(%{"term_id" => term.id, "name" => "Черновик 1"}))
  end)
  |> case do
    {:ok, _result} -> IO.puts("Demonstration data created.")
    {:error, reason} -> raise "seeds failed: #{inspect(reason)}"
  end
end
