defmodule NeuZeit.PublicationRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import NeuZeit.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias NeuZeit.{Repo, Planning}
  alias NeuZeit.Catalog.{Term, Session, Room, Building, Course, Teacher, Cohort}
  alias NeuZeit.Planning.{Plan, Placement}

  test "concurrent publications on independent connections reserve a shared room only once" do
    # Separate committed transactions are necessary: sandbox savepoints cannot
    # reproduce two independent publishers waiting on PostgreSQL locks.
    data =
      Sandbox.unboxed_run(Repo, fn ->
        room = room_fixture()
        component = component_fixture(rooms: [room])

        rows =
          for name <- ["Concurrent A", "Concurrent B"] do
            term = term_fixture(%{name: name})
            session = session_fixture(term: term, component: component)
            plan = plan_fixture(term: term)

            placement_fixture(%{
              plan_id: plan.id,
              session_id: session.id,
              room_id: room.id,
              day: 1,
              slot: 1
            })

            %{term: term, session: session, plan: plan}
          end

        %{room: room, component: component, rows: rows}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        plans = Enum.map(data.rows, & &1.plan.id)
        sessions = Enum.map(data.rows, & &1.session.id)
        terms = Enum.map(data.rows, & &1.term.id)
        teachers = Enum.map(data.rows, & &1.session.teacher_id)
        cohorts = Enum.flat_map(data.rows, &Enum.map(&1.session.cohorts, fn c -> c.id end))

        Repo.transaction(fn ->
          Planning.SharedResources.lock!()
          Repo.delete_all(from p in Placement, where: p.plan_id in ^plans)
          Repo.delete_all(from p in Plan, where: p.id in ^plans)
          Repo.delete_all(from s in Session, where: s.id in ^sessions)
          Repo.delete_all(from t in Term, where: t.id in ^terms)
          Repo.delete_all(from c in Course, where: c.id == ^data.component.course_id)
          Repo.delete_all(from r in Room, where: r.id == ^data.room.id)
          Repo.delete_all(from b in Building, where: b.id == ^data.room.building_id)
          Repo.delete_all(from t in Teacher, where: t.id in ^teachers)
          Repo.delete_all(from c in Cohort, where: c.id in ^cohorts)
        end)
      end)
    end)

    parent = self()

    tasks =
      for row <- data.rows do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :publish -> Planning.publish_plan(row.plan.id)
            end
          end)
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :publish))
    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert [{:error, %{errors: errors}}] = Enum.filter(results, &match?({:error, _}, &1))
    assert Enum.any?(errors, &(&1.type == "external_room_conflict"))

    Sandbox.unboxed_run(Repo, fn ->
      ids = Enum.map(data.rows, & &1.plan.id)

      assert Repo.aggregate(from(p in Plan, where: p.id in ^ids and p.status == "active"), :count) ==
               1
    end)
  end
end
