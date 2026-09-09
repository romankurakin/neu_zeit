defmodule NeuZeit.Solver.Snapshot do
  @moduledoc false
  import Ecto.Query
  alias NeuZeit.Catalog.{Room, Session}
  alias NeuZeit.Config
  alias NeuZeit.Planning.{Placement, Plan, SharedResources}
  alias NeuZeit.Repo

  def load(plan_id) do
    case Repo.get(Plan, plan_id) do
      nil -> {:error, :not_found}
      plan -> {:ok, load_plan(plan)}
    end
  end

  def load!(plan_id), do: Plan |> Repo.get!(plan_id) |> load_plan()

  defp load_plan(plan) do
    config = Config.load!()

    plan = Repo.preload(plan, :term)

    rooms = Repo.all(from r in Room, order_by: r.id, preload: [:building])

    sessions =
      Repo.all(
        from s in Session,
          where: s.term_id == ^plan.term_id,
          order_by: s.id,
          preload: [
            :cohorts,
            teacher: [:availability_cells],
            slot_profile: [:cells],
            course_component: [:allowed_rooms]
          ]
      )

    placements =
      Repo.all(
        from p in Placement,
          where: p.plan_id == ^plan.id,
          preload: [:session]
      )

    %{
      plan: plan,
      rooms: rooms,
      sessions: sessions,
      placements: placements,
      external: SharedResources.external_index(plan.term),
      config: config
    }
  end
end
