defmodule NeuZeit.Planning do
  @moduledoc "Draft plans, placements, publication and calendar changes."
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Constraints.Advisory
  alias NeuZeit.Constraints.Hard
  alias NeuZeit.Planning.Plan
  alias NeuZeit.Repo

  @doc """
  Loads sessions, placements and diagnostics for the board outside rendering.
  """
  def board_data(plan_id) do
    plan = NeuZeit.Planning.Plans.get_plan!(plan_id)
    placements = NeuZeit.Planning.Placements.list_placements(plan_id)
    placed = MapSet.new(placements, & &1.session_id)

    unplaced =
      plan.term_id
      |> NeuZeit.Catalog.list_sessions()
      |> Enum.reject(&MapSet.member?(placed, &1.id))

    %{
      plan: plan,
      placements: placements,
      unplaced: unplaced,
      checks:
        Hard.check_placements(placements) ++
          NeuZeit.Planning.SharedResources.errors(
            plan.term,
            placements,
            if(plan.status == "active",
              do: NeuZeit.Planning.Exceptions.active_exceptions(plan.term_id, nil),
              else: []
            )
          ),
      advisories: Advisory.check_placements(placements)
    }
  end

  def check_plan(plan_id) do
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
            course_component: [:allowed_rooms]
          ]
        ]
      )

    term = Repo.get!(Term, plan.term_id)

    exceptions =
      if plan.status == "active",
        do: NeuZeit.Planning.Exceptions.active_exceptions(term.id, nil),
        else: []

    Hard.check_placements(plan.placements) ++
      NeuZeit.Constraints.AutomaticWeeks.errors(term, plan.placements) ++
      NeuZeit.Planning.SharedResources.errors(term, plan.placements, exceptions)
  end

  def plan_advisories(plan_id) do
    plan =
      Plan
      |> Repo.get!(plan_id)
      |> Repo.preload(
        placements: [
          :room,
          session: [
            :cohorts,
            slot_profile: [:cells],
            course_component: [
              :allowed_rooms,
              course: :translations,
              teaching_type: :translations
            ]
          ]
        ]
      )

    Advisory.check_placements(plan.placements)
  end

  defdelegate list_plans(), to: NeuZeit.Planning.Plans
  defdelegate list_plans(term_id), to: NeuZeit.Planning.Plans
  defdelegate get_plan!(id, term_id), to: NeuZeit.Planning.Plans
  defdelegate get_plan!(id), to: NeuZeit.Planning.Plans
  defdelegate create_plan(attrs), to: NeuZeit.Planning.Plans
  defdelegate change_plan(plan, attrs \\ %{}), to: NeuZeit.Planning.Plans
  defdelegate update_plan(plan, attrs), to: NeuZeit.Planning.Plans
  defdelegate delete_plan(plan), to: NeuZeit.Planning.Plans
  defdelegate clone_plan(plan_id, attrs \\ %{}), to: NeuZeit.Planning.Plans
  defdelegate publish_plan(plan_id, opts \\ []), to: NeuZeit.Planning.Plans
  defdelegate publish_plan!(plan_id, opts \\ []), to: NeuZeit.Planning.Plans
  defdelegate validate_publishable!(plan, opts \\ []), to: NeuZeit.Planning.Plans
  defdelegate list_placements(), to: NeuZeit.Planning.Placements
  defdelegate list_placements(plan_id), to: NeuZeit.Planning.Placements
  defdelegate get_placement!(id), to: NeuZeit.Planning.Placements
  defdelegate create_placement(attrs), to: NeuZeit.Planning.Placements
  defdelegate update_placement(placement, attrs), to: NeuZeit.Planning.Placements
  defdelegate delete_placement(placement), to: NeuZeit.Planning.Placements
  defdelegate solve_plan(plan_id), to: NeuZeit.Solver.PlanRuns, as: :solve
  defdelegate project_active_term(term_id), to: NeuZeit.Planning.Calendar
  defdelegate project_plan(plan_id), to: NeuZeit.Planning.Calendar
  defdelegate list_schedule_exceptions(), to: NeuZeit.Planning.Exceptions
  defdelegate list_schedule_exceptions(term_id), to: NeuZeit.Planning.Exceptions
  defdelegate get_schedule_exception!(id, term_id), to: NeuZeit.Planning.Exceptions
  defdelegate get_schedule_exception!(id), to: NeuZeit.Planning.Exceptions
  defdelegate change_schedule_exception(exception, attrs \\ %{}), to: NeuZeit.Planning.Exceptions
  defdelegate create_schedule_exception(attrs), to: NeuZeit.Planning.Exceptions
  defdelegate update_schedule_exception(exception, attrs), to: NeuZeit.Planning.Exceptions
  defdelegate delete_schedule_exception(exception), to: NeuZeit.Planning.Exceptions
end
