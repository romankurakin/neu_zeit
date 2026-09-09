defmodule NeuZeit.Planning.Calendar do
  @moduledoc false
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Constraints.Projection
  alias NeuZeit.Planning.Plan
  alias NeuZeit.Planning.ScheduleException
  alias NeuZeit.Repo

  def project_active_term(term_id) do
    term = Repo.get!(Term, term_id)

    plan =
      Repo.one(
        from p in Plan,
          where: p.term_id == ^term_id and p.status == "active",
          preload: [
            placements: [
              :room,
              session: [
                :cohorts,
                teacher: [:availability_cells],
                slot_profile: [:cells],
                course_component: [:allowed_rooms]
              ]
            ]
          ]
      )

    exceptions =
      Repo.all(
        from e in ScheduleException,
          where: e.term_id == ^term_id and e.status == "active",
          preload: [:session]
      )

    placements = if plan, do: plan.placements, else: []
    placed_session_ids = MapSet.new(placements, & &1.session_id)

    unplaced_session_ids =
      Repo.all(from s in Session, where: s.term_id == ^term_id, order_by: s.id, select: s.id)
      |> Enum.reject(&MapSet.member?(placed_session_ids, &1))

    %{
      occurrences: Projection.project(term, placements, exceptions),
      unplaced_session_ids: unplaced_session_ids,
      active_plan_id: plan && plan.id
    }
  end

  @doc """
  Projects a plan onto calendar dates and excludes non-teaching days.

  Draft and archived plans can be projected. One-off changes apply only
  to the active plan.
  """
  def project_plan(plan_id) do
    plan =
      Plan
      |> Repo.get!(plan_id)
      |> Repo.preload(
        placements: [
          :room,
          session: [
            :cohorts,
            teacher: [:availability_cells],
            slot_profile: [:cells],
            course_component: [:course, :allowed_rooms]
          ]
        ]
      )

    term = Repo.get!(Term, plan.term_id)

    exceptions =
      if plan.status == "active" do
        Repo.all(
          from e in ScheduleException,
            where: e.term_id == ^plan.term_id and e.status == "active",
            preload: [:session]
        )
      else
        []
      end

    placed = MapSet.new(plan.placements, & &1.session_id)

    unplaced =
      Repo.all(from s in Session, where: s.term_id == ^plan.term_id, order_by: s.id, select: s.id)
      |> Enum.reject(&MapSet.member?(placed, &1))

    %{
      plan: plan,
      term: term,
      occurrences: Projection.project(term, plan.placements, exceptions),
      unplaced_session_ids: unplaced,
      exceptions_applied: exceptions != []
    }
  end
end
