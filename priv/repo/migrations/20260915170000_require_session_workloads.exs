defmodule NeuZeit.Repo.Migrations.RequireSessionWorkloads do
  use Ecto.Migration

  def up do
    # The canonical grid has 90-minute slots. Preserve each existing declaration,
    # including fixed repetitions, session IDs, placements and dated exceptions.
    execute """
    CREATE TEMP TABLE imported_workloads ON COMMIT DROP AS
    WITH grouped AS (
      SELECT s.term_id, s.course_component_id, s.teacher_id, s.slot_profile_id,
             s.week_mask, s.duration_slots, s.automatic_weeks, s.sequence_group,
             ARRAY(SELECT sc.cohort_id FROM session_cohorts sc
                   WHERE sc.session_id = s.id ORDER BY sc.cohort_id) AS cohort_ids,
             array_agg(s.id) AS session_ids,
             sum(s.duration_slots * 90.0 / t.academic_hour_minutes *
                 CASE WHEN s.automatic_weeks THEN 1 ELSE cardinality(s.week_mask) END) AS hours
      FROM sessions s JOIN terms t ON t.id = s.term_id
      WHERE s.workload_id IS NULL
      GROUP BY s.term_id, s.course_component_id, s.teacher_id, s.slot_profile_id,
               s.week_mask, s.duration_slots, s.automatic_weeks, s.sequence_group,
               ARRAY(SELECT sc.cohort_id FROM session_cohorts sc
                     WHERE sc.session_id = s.id ORDER BY sc.cohort_id)
    )
    SELECT g.*, existing.id AS existing_id, coalesce(existing.id, gen_random_uuid()) AS id
    FROM grouped g
    LEFT JOIN LATERAL (
      SELECT w.id FROM workloads w
      WHERE w.term_id = g.term_id AND w.course_component_id = g.course_component_id
        AND w.teacher_id = g.teacher_id
        AND w.slot_profile_id IS NOT DISTINCT FROM g.slot_profile_id
        AND w.sequence_group IS NOT DISTINCT FROM g.sequence_group
        AND w.week_mask = g.week_mask AND w.duration_slots = g.duration_slots
        AND w.automatic_weeks = g.automatic_weeks
        AND ARRAY(SELECT wc.cohort_id FROM workload_cohorts wc
                  WHERE wc.workload_id = w.id ORDER BY wc.cohort_id) = g.cohort_ids
      ORDER BY w.id LIMIT 1
    ) existing ON true
    """

    execute """
    UPDATE workloads w SET contact_hours = w.contact_hours + i.hours
    FROM imported_workloads i WHERE w.id = i.existing_id
    """

    execute """
    INSERT INTO workloads (id, term_id, course_component_id, teacher_id, slot_profile_id,
                           week_mask, duration_slots, automatic_weeks, contact_hours,
                           sequence_group, inserted_at, updated_at)
    SELECT id, term_id, course_component_id, teacher_id, slot_profile_id, week_mask,
           duration_slots, automatic_weeks, hours, sequence_group, now(), now()
    FROM imported_workloads WHERE existing_id IS NULL
    """

    execute """
    INSERT INTO workload_cohorts (workload_id, cohort_id)
    SELECT id, unnest(cohort_ids) FROM imported_workloads ON CONFLICT DO NOTHING
    """

    execute """
    UPDATE sessions s SET workload_id = i.id FROM imported_workloads i
    WHERE s.id = ANY(i.session_ids)
    """

    alter table(:sessions) do
      modify :workload_id, :uuid, null: false
    end
  end
end
