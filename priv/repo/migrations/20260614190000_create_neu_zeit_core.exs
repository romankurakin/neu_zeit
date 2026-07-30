defmodule NeuZeit.Repo.Migrations.CreateNeuZeitCore do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist", "DROP EXTENSION IF EXISTS btree_gist"
    execute "CREATE EXTENSION IF NOT EXISTS intarray", "DROP EXTENSION IF EXISTS intarray"

    create table(:terms) do
      add :name, :string, null: false
      add :starts_on, :date, null: false
      add :ends_on, :date, null: false
      add :excluded_dates, {:array, :date}, null: false, default: []
      add :weeks_count, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:terms, :terms_dates_order_ck, check: "ends_on >= starts_on")

    create constraint(:terms, :terms_starts_on_monday_ck,
             check: "EXTRACT(ISODOW FROM starts_on) = 1"
           )

    create constraint(:terms, :terms_weeks_count_positive_ck, check: "weeks_count > 0")

    create table(:buildings) do
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:buildings, [:name])

    create table(:rooms) do
      add :building_id, references(:buildings, on_delete: :restrict), null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:rooms, [:building_id, :name])

    create table(:courses) do
      add :code, :string, null: false
      add :title, :text, null: false
      add :credits, :decimal, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:courses, [:code])
    create constraint(:courses, :courses_credits_positive_ck, check: "credits > 0")

    create table(:course_translations) do
      add :course_id, references(:courses, on_delete: :delete_all), null: false
      add :locale, :string, size: 10, null: false
      add :title, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:course_translations, [:course_id, :locale])
    create index(:course_translations, [:locale])

    create table(:course_components) do
      add :course_id, references(:courses, on_delete: :delete_all), null: false
      add :kind, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:course_components, [:course_id, :kind])

    create constraint(:course_components, :course_components_kind_ck,
             check: "kind IN ('lecture', 'seminar', 'lab')"
           )

    create table(:component_allowed_rooms, primary_key: false) do
      add :component_id, references(:course_components, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :room_id, references(:rooms, on_delete: :restrict), null: false, primary_key: true
    end

    create unique_index(:component_allowed_rooms, [:component_id, :room_id])

    create table(:teachers) do
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:teachers, [:name])

    create table(:cohorts) do
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cohorts, [:name])

    create table(:sessions) do
      add :term_id, references(:terms, on_delete: :restrict), null: false
      add :course_component_id, references(:course_components, on_delete: :restrict), null: false
      add :teacher_id, references(:teachers, on_delete: :restrict), null: false
      add :sequence_group, :string
      add :week_mask, {:array, :integer}, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sessions, [:id, :term_id])
    create index(:sessions, [:term_id])
    create index(:sessions, [:course_component_id])

    create constraint(:sessions, :sessions_week_mask_non_empty_ck,
             check: "array_length(week_mask, 1) > 0"
           )

    create table(:session_cohorts, primary_key: false) do
      add :session_id, references(:sessions, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :cohort_id, references(:cohorts, on_delete: :restrict), null: false, primary_key: true
    end

    create unique_index(:session_cohorts, [:session_id, :cohort_id])

    create table(:plans) do
      add :term_id, references(:terms, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:plans, [:term_id],
             unique: true,
             where: "status = 'active'",
             name: :plans_one_active_per_term
           )

    create unique_index(:plans, [:id, :term_id])

    create constraint(:plans, :plans_status_ck,
             check: "status IN ('draft', 'active', 'archived')"
           )

    create table(:placements) do
      add :plan_id, :uuid, null: false
      add :session_id, :uuid, null: false
      add :term_id, :uuid, null: false
      add :week_mask, {:array, :integer}, null: false
      add :room_id, references(:rooms, on_delete: :restrict), null: false
      add :day, :integer, null: false
      add :slot, :integer, null: false
      add :locked, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:placements, [:plan_id, :session_id])
    create index(:placements, [:term_id])
    create constraint(:placements, :placements_day_positive_ck, check: "day > 0")
    create constraint(:placements, :placements_slot_positive_ck, check: "slot > 0")

    create constraint(:placements, :placements_week_mask_non_empty_ck,
             check: "array_length(week_mask, 1) > 0"
           )

    execute """
            ALTER TABLE placements
              ADD CONSTRAINT placements_plan_term_fkey
              FOREIGN KEY (plan_id, term_id) REFERENCES plans (id, term_id)
              ON DELETE CASCADE
            """,
            "ALTER TABLE placements DROP CONSTRAINT placements_plan_term_fkey"

    execute """
            ALTER TABLE placements
              ADD CONSTRAINT placements_session_term_fkey
              FOREIGN KEY (session_id, term_id) REFERENCES sessions (id, term_id)
              ON DELETE CASCADE
            """,
            "ALTER TABLE placements DROP CONSTRAINT placements_session_term_fkey"

    execute """
            ALTER TABLE placements
              ADD CONSTRAINT placements_no_overlapping_week_room
              EXCLUDE USING gist (
                plan_id WITH =,
                day WITH =,
                slot WITH =,
                room_id WITH =,
                week_mask gist__int_ops WITH &&
              )
            """,
            "ALTER TABLE placements DROP CONSTRAINT placements_no_overlapping_week_room"

    create table(:schedule_exceptions) do
      add :term_id, :uuid, null: false
      add :session_id, :uuid, null: false
      add :kind, :string, null: false
      add :occurrence_date, :date, null: false
      add :new_date, :date
      add :new_slot, :integer
      add :new_room_id, references(:rooms, on_delete: :restrict)
      add :reason, :text, null: false
      add :status, :string, null: false, default: "active"
      add :created_by, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:schedule_exceptions, [:term_id])
    create index(:schedule_exceptions, [:session_id])

    execute """
            ALTER TABLE schedule_exceptions
              ADD CONSTRAINT exceptions_session_term_fkey
              FOREIGN KEY (session_id, term_id) REFERENCES sessions (id, term_id)
              ON DELETE CASCADE
            """,
            "ALTER TABLE schedule_exceptions DROP CONSTRAINT exceptions_session_term_fkey"

    create unique_index(:schedule_exceptions, [:session_id, :occurrence_date],
             where: "status = 'active' AND kind IN ('cancel', 'move')",
             name: :exceptions_one_override_per_occurrence
           )

    create constraint(:schedule_exceptions, :exceptions_kind_ck,
             check: "kind IN ('cancel', 'move', 'add')"
           )

    create constraint(:schedule_exceptions, :exceptions_status_ck,
             check: "status IN ('active', 'reverted')"
           )

    create constraint(:schedule_exceptions, :exceptions_payload_ck,
             check: """
             (kind = 'cancel' AND new_slot IS NULL AND new_room_id IS NULL) OR
             (kind = 'move' AND new_slot IS NOT NULL AND new_room_id IS NOT NULL) OR
             (kind = 'add' AND new_slot IS NOT NULL AND new_room_id IS NOT NULL)
             """
           )
  end
end
