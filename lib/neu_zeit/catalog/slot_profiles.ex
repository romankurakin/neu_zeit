defmodule NeuZeit.Catalog.SlotProfiles do
  @moduledoc false
  alias NeuZeit.Catalog.ScheduleValidation
  alias NeuZeit.Catalog.WriteSupport
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.SlotProfile
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Repo

  def list_slot_profiles(term_id \\ nil) do
    query =
      from profile in SlotProfile,
        order_by: [asc: profile.term_id, asc: profile.name],
        preload: [:term, :cells]

    query =
      if term_id,
        do: from(profile in query, where: profile.term_id == ^term_id),
        else: query

    Repo.all(query)
  end

  def get_slot_profile!(id, term_id) do
    record = get_slot_profile!(id)
    if record.term_id != term_id, do: raise(Ecto.NoResultsError, queryable: SlotProfile)
    record
  end

  def get_slot_profile!(id),
    do: SlotProfile |> Repo.get!(id) |> Repo.preload([:term, :cells])

  def create_slot_profile(attrs) do
    %SlotProfile{}
    |> SlotProfile.changeset(attrs)
    |> Repo.insert()
    |> WriteSupport.preload_result([:term, :cells])
  end

  def update_slot_profile(%SlotProfile{} = profile, attrs) do
    WriteSupport.transaction_result(fn ->
      Repo.one!(from t in Term, where: t.id == ^profile.term_id, lock: "FOR UPDATE")

      current =
        Repo.one!(from p in SlotProfile, where: p.id == ^profile.id, lock: "FOR UPDATE")
        |> Repo.preload(:cells)

      with {:ok, updated} <- current |> SlotProfile.update_changeset(attrs) |> Repo.update(),
           :ok <- validate_slot_profile_durations(updated),
           :ok <- ScheduleValidation.validate_slot_profile_schedules(updated) do
        {:ok, Repo.preload(updated, [:term, :cells], force: true)}
      end
    end)
  end

  def delete_slot_profile(%SlotProfile{} = profile), do: Repo.delete(profile)

  def change_slot_profile(%SlotProfile{} = profile, attrs \\ %{}),
    do: SlotProfile.changeset(profile, attrs)

  @doc "Adds the weekday daytime profile once. Existing settings are retained."
  def ensure_default_slot_profiles(%Term{} = term) do
    WriteSupport.transaction_result(fn ->
      Repo.one!(from t in Term, where: t.id == ^term.id, lock: "FOR UPDATE")
      profiles = list_slot_profiles(term.id)

      if Enum.any?(profiles, &(&1.preset_key == "weekday_daytime")) do
        {:ok, profiles}
      else
        defaults = daytime_cells()

        existing =
          Enum.find(profiles, fn profile ->
            SlotProfile.daytime_name?(profile.name) &&
              MapSet.new(profile.cells, &{&1.day, &1.slot}) ==
                MapSet.new(defaults, &{&1.day, &1.slot})
          end)

        changeset =
          if existing do
            Ecto.Changeset.change(existing)
          else
            SlotProfile.changeset(%SlotProfile{}, %{
              term_id: term.id,
              name: "Weekdays, daytime",
              cells: defaults
            })
          end

        case changeset
             |> Ecto.Changeset.put_change(:preset_key, "weekday_daytime")
             |> Repo.insert_or_update() do
          {:ok, _profile} -> {:ok, list_slot_profiles(term.id)}
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  defp validate_slot_profile_durations(profile) do
    slots_count = length(NeuZeit.Config.grid!().slots)
    earliest_start = profile.cells |> Enum.map(& &1.slot) |> Enum.min(fn -> slots_count + 1 end)

    impossible_session? =
      Repo.exists?(
        from session in Session,
          where: session.slot_profile_id == ^profile.id,
          where: session.duration_slots > ^(slots_count - earliest_start + 1)
      )

    if impossible_session? do
      {:error,
       WriteSupport.error_changeset(
         profile,
         :cells,
         "must contain a start cell that fits every assigned session duration"
       )}
    else
      :ok
    end
  end

  defp daytime_cells do
    grid = NeuZeit.Config.grid!()

    for day <- 1..min(5, length(grid.days)),
        slot <- 1..min(4, length(grid.slots)),
        do: %{day: day, slot: slot}
  end
end
