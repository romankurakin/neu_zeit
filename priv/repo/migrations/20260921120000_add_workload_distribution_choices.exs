defmodule NeuZeit.Repo.Migrations.AddWorkloadDistributionChoices do
  use Ecto.Migration

  def change do
    alter table(:workloads) do
      add :rounding_mode, :string, null: false, default: "up"
      add :remainder_parity, :string, null: false, default: "odd"
    end

    create constraint(:workloads, :workloads_rounding_mode_check,
             check: "rounding_mode IN ('up', 'down')"
           )

    create constraint(:workloads, :workloads_remainder_parity_check,
             check: "remainder_parity IN ('odd', 'even')"
           )

    # Earlier imports calculated hours through floats. Preserve their accepted
    # integer count when that conversion left a tiny positive remainder. This
    # backfill applies only once; new requirements use exact minute arithmetic.
    execute(
      """
      WITH quantities AS (
        SELECT w.id,
               w.contact_hours * t.academic_hour_minutes AS required_minutes,
               w.duration_slots * extract(epoch FROM (
                 (t.grid->'slots'->0->>'end')::time -
                 (t.grid->'slots'->0->>'start')::time
               )) / 60 AS meeting_minutes,
               CASE WHEN w.automatic_weeks THEN 1 ELSE cardinality(w.week_mask) END AS repeats
        FROM workloads w JOIN terms t ON t.id = w.term_id
      ), legacy_counts AS (
        SELECT *, round(required_minutes / meeting_minutes) AS meeting_count
        FROM quantities
      )
      UPDATE workloads w SET rounding_mode = 'down'
      FROM legacy_counts q
      WHERE w.id = q.id AND q.meeting_count > 0
        AND q.required_minutes > q.meeting_count * q.meeting_minutes
        AND q.required_minutes - q.meeting_count * q.meeting_minutes
              < 0.000001 * q.meeting_minutes * q.repeats
      """,
      "SELECT 1"
    )
  end
end
