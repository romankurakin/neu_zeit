defmodule NeuZeit.Catalog.TeachingTypes do
  @moduledoc false
  import Ecto.Query
  alias NeuZeit.Catalog.{CourseComponent, TeachingType}
  alias NeuZeit.Repo

  def list_teaching_types,
    do: Repo.all(from t in TeachingType, order_by: t.id, preload: :translations)

  def get_teaching_type!(id), do: TeachingType |> Repo.get!(id) |> Repo.preload(:translations)

  def create_teaching_type(attrs) do
    %TeachingType{id: Ecto.UUID.generate()}
    |> TeachingType.changeset(attrs)
    |> Repo.insert()
  end

  def update_teaching_type(teaching_type, attrs) do
    Repo.transact(fn ->
      # Read translations after locking so concurrent edits to different languages survive.
      locked =
        Repo.one!(from t in TeachingType, where: t.id == ^teaching_type.id, lock: "FOR UPDATE")

      locked |> Repo.preload(:translations) |> TeachingType.changeset(attrs) |> Repo.update()
    end)
  end

  def change_teaching_type(teaching_type, attrs \\ %{}),
    do: TeachingType.changeset(teaching_type, attrs)

  def delete_teaching_type(teaching_type) do
    teaching_type
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :course_components_kind_fkey,
      message: "This teaching type is used by courses. Remove it from those courses first."
    )
    |> Repo.delete()
  end

  def teaching_type_usage do
    Repo.all(from c in CourseComponent, group_by: c.kind, select: {c.kind, count(c.id)})
    |> Map.new()
  end
end
