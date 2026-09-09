defmodule NeuZeit.Planning.Solving do
  @moduledoc false
  alias NeuZeit.Planning.WriteSupport
  import Ecto.Query, warn: false
  require Logger
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Repo
  alias NeuZeit.Solver
  alias NeuZeit.Solver.ResultValidator
  alias NeuZeit.Solver.SpecBuilder
  alias NeuZeit.Solver.Snapshot

  def solve_plan(plan_id) do
    with :ok <- WriteSupport.ensure_draft_plan(plan_id),
         {:ok, :ready} <-
           NeuZeit.Catalog.Workload.prepare(NeuZeit.Planning.get_plan!(plan_id).term_id),
         :ok <- validate_solver_input(plan_id),
         spec <- SpecBuilder.build!(plan_id),
         {:ok, result} <- solve_spec(spec),
         {:ok, persisted} <- persist_solver_result(plan_id, result, spec) do
      {:ok, persisted.result}
    end
  end

  defp validate_solver_input(plan_id) do
    case NeuZeit.Planning.check_plan(plan_id) do
      [] ->
        :ok

      errors ->
        blocking = Enum.reject(errors, &String.starts_with?(&1.type, "external_"))
        if blocking == [], do: :ok, else: {:error, %{errors: blocking}}
    end
  end

  defp solve_spec(spec) do
    case Solver.solve(spec) do
      {:ok, result} -> {:ok, result}
      {:error, result} when is_map(result) -> {:error, %{errors: [solver_error(result)]}}
      {:error, reason} -> {:error, %{errors: [solver_error(%{"error" => inspect(reason)})]}}
    end
  end

  defp solver_error(result) do
    status = result["status"] || "failed"

    Logger.error("solver failed with status #{inspect(status)}: #{inspect(result)}")

    %{
      type: "solver_#{status |> to_string() |> String.downcase()}",
      message: result["error"] || "solver could not produce a complete timetable",
      solver_status: status
    }
  end

  defp persist_solver_result(plan_id, result, original_spec) do
    WriteSupport.transaction_result(fn ->
      with {:ok, _term} <- WriteSupport.lock_plan_term(plan_id),
           {:ok, plan} <- WriteSupport.lock_draft_plan(plan_id),
           :ok <- validate_solver_input(plan_id),
           snapshot <- Snapshot.load!(plan_id),
           spec <- SpecBuilder.build(snapshot),
           :ok <- ensure_solver_placements_unchanged(original_spec, spec),
           {:ok, validated} <- ResultValidator.validate_snapshot(snapshot, spec, result),
           :ok <- replace_solver_placements(plan, validated) do
        {:ok, validated}
      end
    end)
  rescue
    error in Ecto.ConstraintError ->
      {:error,
       %{
         errors: [
           %{
             type: "solver_persistence_failed",
             message: Exception.message(error)
           }
         ]
       }}
  end

  # Both snapshots come from the same placement query used to build each spec.
  # Compare under the term lock so an edit cannot slip in before replacement.
  # Catalog changes still go through the existing result revalidation below.
  defp ensure_solver_placements_unchanged(original, current) do
    if original.current == current.current and original.fixed == current.fixed do
      :ok
    else
      {:error,
       {:conflict,
        "The plan changed while the solver was running. Your edits were kept. Run the solver again."}}
    end
  end

  defp replace_solver_placements(plan, %{placements: placements}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(p in Placement, where: p.plan_id == ^plan.id and p.locked == false)
    |> Repo.delete_all()

    rows =
      placements
      |> Enum.map(fn placement ->
        %{
          plan_id: plan.id,
          session_id: placement.session_id,
          term_id: plan.term_id,
          week_mask: placement.week_mask,
          duration_slots: placement.duration_slots,
          room_id: placement.room_id,
          day: placement.day,
          slot: placement.slot,
          locked: placement.locked,
          inserted_at: now,
          updated_at: now
        }
      end)

    rows = Enum.map(rows, &Map.put_new(&1, :id, Ecto.UUID.generate(version: 7)))

    Repo.insert_all(Placement, rows,
      on_conflict:
        {:replace,
         [
           :term_id,
           :week_mask,
           :duration_slots,
           :room_id,
           :day,
           :slot,
           :locked,
           :updated_at
         ]},
      conflict_target: [:plan_id, :session_id]
    )

    :ok
  end
end
