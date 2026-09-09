defmodule NeuZeit.Catalog.ScheduleValidation do
  @moduledoc false
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Constraints.Hard
  alias NeuZeit.Constraints.Occurrence
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Planning.Plan
  alias NeuZeit.Planning.ScheduleException
  alias NeuZeit.Repo

  def sync_and_revalidate_plans(repo, old_session, session, cohorts_replaced?) do
    mask_changed? =
      session.week_mask != old_session.week_mask or
        session.automatic_weeks != old_session.automatic_weeks

    duration_changed? = session.duration_slots != old_session.duration_slots

    conflict_fields_changed? =
      mask_changed? or session.teacher_id != old_session.teacher_id or
        session.course_component_id != old_session.course_component_id or duration_changed? or
        session.slot_profile_id != old_session.slot_profile_id

    if not conflict_fields_changed? and not cohorts_replaced? do
      {:ok, :unchanged}
    else
      plan_ids =
        repo.all(
          from p in Placement,
            join: plan in assoc(p, :plan),
            where: p.session_id == ^session.id and plan.status in ["draft", "active"],
            distinct: true,
            select: p.plan_id
        )

      with :ok <- validate_resynced_plans(repo, session, plan_ids),
           :ok <-
             validate_active_projection(
               repo,
               session.term_id,
               {session.id, if(session.automatic_weeks, do: nil, else: session.week_mask),
                session.duration_slots}
             ) do
        if mask_changed? or duration_changed? do
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          updates = [duration_slots: session.duration_slots, updated_at: now]

          updates =
            if session.automatic_weeks,
              do: updates,
              else: Keyword.put(updates, :week_mask, session.week_mask)

          from(p in Placement, where: p.session_id == ^session.id and p.plan_id in ^plan_ids)
          |> repo.update_all(set: updates)
        end

        {:ok, :revalidated}
      end
    end
  end

  defp validate_resynced_plans(repo, session, plan_ids) do
    Enum.reduce_while(plan_ids, :ok, fn plan_id, _acc ->
      placements =
        repo.all(
          from p in Placement,
            where: p.plan_id == ^plan_id,
            preload: [
              :room,
              session: [
                :cohorts,
                teacher: [:availability_cells],
                slot_profile: [:cells],
                course_component: [:allowed_rooms]
              ]
            ]
        )
        |> Enum.map(fn placement ->
          if placement.session_id == session.id do
            %{
              placement
              | week_mask:
                  if(session.automatic_weeks, do: placement.week_mask, else: session.week_mask),
                session: %{
                  placement.session
                  | week_mask: session.week_mask,
                    automatic_weeks: session.automatic_weeks
                },
                duration_slots: session.duration_slots
            }
          else
            placement
          end
        end)

      case Hard.validate_placements(placements) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, %{errors: errors}}}
      end
    end)
  end

  def validate_component_schedules(term_ids, component_id) do
    Enum.reduce_while(term_ids, :ok, fn term_id, _acc ->
      with :ok <- validate_component_plans(term_id, component_id),
           :ok <- validate_active_projection(Repo, term_id) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def validate_slot_profile_schedules(profile) do
    plans =
      Repo.all(
        from plan in Plan,
          join: placement in Placement,
          on: placement.plan_id == plan.id,
          join: session in Session,
          on: session.id == placement.session_id,
          where: plan.term_id == ^profile.term_id and plan.status in ["draft", "active"],
          where: session.slot_profile_id == ^profile.id,
          distinct: true,
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

    with :ok <- validate_plans(plans),
         :ok <- validate_active_projection(Repo, profile.term_id) do
      :ok
    end
  end

  defp validate_plans(plans) do
    Enum.reduce_while(plans, :ok, fn plan, _acc ->
      case Hard.validate_placements(plan.placements) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, %{errors: errors}}}
      end
    end)
  end

  defp validate_component_plans(term_id, component_id) do
    Repo.all(
      from plan in Plan,
        join: placement in Placement,
        on: placement.plan_id == plan.id,
        join: session in Session,
        on: session.id == placement.session_id,
        where: plan.term_id == ^term_id and plan.status in ["draft", "active"],
        where: session.course_component_id == ^component_id,
        distinct: true,
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
    |> Enum.reduce_while(:ok, fn plan, _acc ->
      case Hard.validate_placements(plan.placements) do
        :ok -> {:cont, :ok}
        {:error, errors} -> {:halt, {:error, %{errors: errors}}}
      end
    end)
  end

  def validate_active_projection(repo, term_id, session_override \\ nil) do
    term = repo.get!(Term, term_id)

    placements =
      repo.all(
        from p in Placement,
          join: plan in assoc(p, :plan),
          where: plan.term_id == ^term_id and plan.status == "active"
      )
      |> override_session_snapshot(session_override)

    exceptions =
      repo.all(
        from e in ScheduleException,
          where: e.term_id == ^term_id and e.status == "active"
      )

    Occurrence.validate(term, placements, exceptions, require_origins: true)
  end

  defp override_session_snapshot(placements, nil), do: placements

  defp override_session_snapshot(placements, {session_id, week_mask, duration_slots}) do
    Enum.map(placements, fn placement ->
      if placement.session_id == session_id,
        do: %{
          placement
          | week_mask: week_mask || placement.week_mask,
            duration_slots: duration_slots
        },
        else: placement
    end)
  end

  def validate_teacher_availability_schedules(term_id, teacher_id) do
    Repo.all(
      from plan in Plan,
        join: placement in Placement,
        on: placement.plan_id == plan.id,
        join: session in Session,
        on: session.id == placement.session_id,
        where: plan.term_id == ^term_id and plan.status in ["draft", "active"],
        where: session.teacher_id == ^teacher_id,
        distinct: true,
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
    |> validate_plans()
  end
end
