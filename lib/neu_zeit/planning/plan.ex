defmodule NeuZeit.Planning.Plan do
  use NeuZeit.Schema

  import Ecto.Changeset

  @statuses ~w(draft active archived)

  schema "plans" do
    field :name, :string
    field :status, :string, default: "draft"
    field :published_at, :utc_datetime

    belongs_to :term, NeuZeit.Catalog.Term
    has_many :placements, NeuZeit.Planning.Placement

    timestamps()
  end

  def statuses, do: @statuses

  def create_changeset(plan, attrs) do
    plan
    |> change()
    |> reject_fields(attrs, [:status, :published_at])
    |> cast(attrs, [:term_id, :name])
    |> validate_required([:term_id, :name, :status])
    |> validate_length(:name, min: 1, max: 100)
    |> foreign_key_constraint(:term_id)
  end

  def update_changeset(plan, attrs) do
    plan
    |> change()
    |> reject_fields(attrs, [:term_id, :status, :published_at])
    |> cast(attrs, [:name])
    |> validate_required([:term_id, :name, :status])
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:term_id, :name, :status, :published_at])
    |> validate_required([:term_id, :name, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:term_id)
    |> unique_constraint(:term_id, name: :plans_one_active_per_term)
  end

  defp reject_fields(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      if has_attr?(attrs, field) do
        add_error(changeset, field, "is read-only")
      else
        changeset
      end
    end)
  end

  defp has_attr?(attrs, field) do
    Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field))
  end
end
