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
    delivery_changed? = session.delivery_mode != old_session.delivery_mode

    conflict_fields_changed? =
      mask_changed? or session.teacher_id != old_session.teacher_id or
        session.course_component_id != old_session.course_component_id or duration_changed? or
        session.slot_profile_id != old_session.slot_profile_id or delivery_changed?

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

      with :ok <- protect_archived_delivery_changes(repo, session, delivery_changed?),
           :ok <- protect_locked_delivery_changes(repo, session, delivery_changed?),
           :ok <- validate_resynced_plans(repo, session, plan_ids),
           :ok <-
             validate_active_projection(
               repo,
               session.term_id,
               {session.id, if(session.automatic_weeks, do: nil, else: session.week_mask),
                session.duration_slots, session.delivery_mode}
             ) do
        if mask_changed? or duration_changed? or delivery_changed? do
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          updates = [duration_slots: session.duration_slots, updated_at: now]

          updates =
            if session.automatic_weeks,
              do: updates,
              else: Keyword.put(updates, :week_mask, session.week_mask)

          updates =
            if delivery_changed? and session.delivery_mode == :online,
              do: Keyword.put(updates, :room_id, nil),
              else: updates

          from(p in Placement, where: p.session_id == ^session.id and p.plan_id in ^plan_ids)
          |> repo.update_all(set: updates)
        end

        {:ok, :revalidated}
      end
    end
  end

  defp protect_archived_delivery_changes(_repo, _session, false), do: :ok

  defp protect_archived_delivery_changes(repo, session, true) do
    archived? =
      repo.exists?(
        from p in Placement,
          join: plan in Plan,
          on: plan.id == p.plan_id,
          where: p.session_id == ^session.id and plan.status == "archived"
      )

    if archived? do
      {:error,
       Ecto.Changeset.change(session)
       |> Ecto.Changeset.add_error(
         :delivery_mode,
         "cannot change because an archived plan preserves this session"
       )}
    else
      :ok
    end
  end

  defp protect_locked_delivery_changes(_repo, _session, false), do: :ok

  defp protect_locked_delivery_changes(repo, session, true) do
    if repo.exists?(from p in Placement, where: p.session_id == ^session.id and p.locked == true) do
      {:error,
       Ecto.Changeset.change(session)
       |> Ecto.Changeset.add_error(
         :delivery_mode,
         "cannot change while the session has locked placements"
       )}
    else
      :ok
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
                    automatic_weeks: session.automatic_weeks,
                    delivery_mode: session.delivery_mode
                },
                duration_slots: session.duration_slots,
                room_id: if(session.delivery_mode == :online, do: nil, else: placement.room_id),
                room: if(session.delivery_mode == :online, do: nil, else: placement.room)
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
          where: plan.term_id == ^term_id and plan.status == "active",
          preload: [:session]
      )
      |> override_session_snapshot(session_override)

    exceptions =
      repo.all(
        from e in ScheduleException,
          where: e.term_id == ^term_id and e.status == "active",
          preload: [:session]
      )

    Occurrence.validate(term, placements, exceptions, require_origins: true)
  end

  defp override_session_snapshot(placements, nil), do: placements

  defp override_session_snapshot(
         placements,
         {session_id, week_mask, duration_slots, delivery_mode}
       ) do
    Enum.map(placements, fn placement ->
      if placement.session_id == session_id,
        do: %{
          placement
          | week_mask: week_mask || placement.week_mask,
            duration_slots: duration_slots,
            room_id: if(delivery_mode == :online, do: nil, else: placement.room_id),
            session: %{placement.session | delivery_mode: delivery_mode}
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
