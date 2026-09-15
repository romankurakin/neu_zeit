defmodule NeuZeit.Repo.Migrations.CreateTeachingTypes do
  use Ecto.Migration

  def up do
    create table(:teaching_types, primary_key: false) do
      add :id, :string, primary_key: true
      timestamps(type: :utc_datetime)
    end

    create table(:teaching_type_translations) do
      add :teaching_type_id, references(:teaching_types, type: :string, on_delete: :delete_all),
        null: false

      add :locale, :string, size: 10, null: false
      add :name, :string, size: 100, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:teaching_type_translations, [:teaching_type_id, :locale])

    create unique_index(:teaching_type_translations, [:locale, "lower(name)"],
             name: :teaching_type_translations_locale_name_index
           )

    create constraint(:teaching_type_translations, :teaching_type_translations_name_required_ck,
             check: "trim(name) <> ''"
           )

    for {id, names} <- [
          {"lecture", [{"en", "Lecture"}, {"ru", "Лекция"}, {"de", "Vorlesung"}]},
          {"seminar", [{"en", "Seminar"}, {"ru", "Семинар"}, {"de", "Seminar"}]},
          {"lab", [{"en", "Lab"}, {"ru", "Лабораторная"}, {"de", "Labor"}]},
          {"exam", [{"en", "Exam"}, {"ru", "Экзамен"}, {"de", "Prüfung"}]}
        ] do
      execute "INSERT INTO teaching_types (id, inserted_at, updated_at) VALUES ('#{id}', now(), now())"

      for {locale, name} <- names do
        execute """
        INSERT INTO teaching_type_translations (id, teaching_type_id, locale, name, inserted_at, updated_at)
        VALUES ('#{Ecto.UUID.generate()}', '#{id}', '#{locale}', '#{name}', now(), now())
        """
      end
    end

    drop constraint(:course_components, :course_components_kind_ck)

    execute """
    ALTER TABLE course_components ADD CONSTRAINT course_components_kind_fkey
      FOREIGN KEY (kind) REFERENCES teaching_types(id) ON DELETE RESTRICT
    """
  end
end
