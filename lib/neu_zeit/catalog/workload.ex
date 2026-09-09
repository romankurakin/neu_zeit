defmodule NeuZeit.Catalog.Workload do
  @moduledoc "Semester teaching requirements, independent of generated sessions and placements."
  use NeuZeit.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias NeuZeit.Catalog.{Sessions, Term}
  alias NeuZeit.Repo

  schema "workloads" do
    field :term_id, Ecto.UUID
    field :course_component_id, Ecto.UUID
    field :teacher_id, Ecto.UUID
    field :slot_profile_id, Ecto.UUID
    field :cohort_ids, {:array, Ecto.UUID}, virtual: true, default: []
    many_to_many :cohorts, NeuZeit.Catalog.Cohort, join_through: "workload_cohorts"
    field :week_mask, {:array, :integer}, default: []
    field :duration_slots, :integer, default: 1
    field :count, :integer, virtual: true, default: 1
    field :automatic_weeks, :boolean, default: false
    field :contact_hours, :decimal
    field :academic_hour_minutes, :integer, virtual: true, default: 45
    field :sequence_group, :string
    timestamps()
  end

  @fields ~w(course_component_id teacher_id slot_profile_id cohort_ids week_mask duration_slots count sequence_group automatic_weeks)a

  def changeset(workload, attrs \\ %{}) do
    grid = NeuZeit.Config.grid!()

    workload
    |> cast(attrs, @fields ++ [:contact_hours])
    |> update_change(:cohort_ids, &Enum.uniq/1)
    |> count_from_hours()
    |> require_hours()
    |> validate_required([
      :course_component_id,
      :teacher_id,
      :cohort_ids,
      :week_mask,
      :duration_slots,
      :count
    ])
    |> validate_length(:cohort_ids, min: 1)
    |> validate_length(:week_mask, min: 1)
    |> validate_number(:duration_slots,
      greater_than: 0,
      less_than_or_equal_to: length(grid.slots)
    )
    |> validate_quantity(grid)
    |> foreign_key_constraint(:term_id)
    |> foreign_key_constraint(:course_component_id)
    |> foreign_key_constraint(:teacher_id)
    |> foreign_key_constraint(:slot_profile_id)
  end

  defp validate_quantity(changeset, grid) do
    weeks =
      if get_field(changeset, :automatic_weeks),
        do: length(get_field(changeset, :week_mask) || []),
        else: 1

    duration = max(get_field(changeset, :duration_slots) || 1, 1)
    capacity = weeks * length(grid.days) * div(length(grid.slots), duration)

    changeset =
      validate_number(changeset, :count, greater_than: 0, less_than_or_equal_to: capacity)

    if get_field(changeset, :contact_hours) && Keyword.has_key?(changeset.errors, :count) do
      changeset
      |> Map.update!(:errors, &Keyword.delete(&1, :count))
      |> add_error(:contact_hours, "Teaching load exceeds the available time.")
    else
      changeset
    end
  end

  def list(term_id) do
    sessions = Sessions.list_sessions(term_id)

    stored =
      Repo.all(from w in __MODULE__, where: w.term_id == ^term_id, preload: [:cohorts])
      |> Enum.map(&%{&1 | cohort_ids: Enum.map(&1.cohorts, fn c -> c.id end)})

    cohorts = NeuZeit.Catalog.list_cohorts() |> Map.new(&{&1.id, &1})

    requirements =
      Enum.map(stored, fn requirement ->
        generated =
          Enum.filter(sessions, &(&1.workload_id == requirement.id)) |> Enum.sort_by(& &1.id)

        metadata = struct(NeuZeit.Catalog.Session, Map.take(requirement, @fields -- [:count]))

        metadata = %{
          metadata
          | id: (List.first(generated) || requirement).id,
            term_id: term_id,
            workload_id: requirement.id,
            course_component:
              NeuZeit.Catalog.get_course_component!(requirement.course_component_id),
            teacher: NeuZeit.Catalog.get_teacher!(requirement.teacher_id),
            slot_profile:
              if(requirement.slot_profile_id,
                do: NeuZeit.Catalog.get_slot_profile!(requirement.slot_profile_id)
              ),
            cohorts: Enum.map(requirement.cohort_ids, &Map.fetch!(cohorts, &1))
        }

        %{
          id: metadata.id,
          session: metadata,
          sessions: generated,
          count: length(generated),
          requirement: requirement
        }
      end)

    legacy =
      sessions
      |> Enum.filter(&is_nil(&1.workload_id))
      |> Enum.group_by(&key/1)
      |> Enum.map(fn {_key, sessions} ->
        sessions = Enum.sort_by(sessions, & &1.id)

        %{
          id: hd(sessions).id,
          session: hd(sessions),
          sessions: sessions,
          count: length(sessions),
          requirement: nil
        }
      end)

    Enum.sort_by(
      requirements ++ legacy,
      &{&1.session.course_component.course.code, &1.session.course_component.kind, &1.id}
    )
  end

  def from_row(row, academic_hour_minutes \\ 45) do
    row.session
    |> Map.take(@fields -- [:count, :cohort_ids])
    |> Map.merge(%{
      count: row.count,
      contact_hours: hours(row, academic_hour_minutes),
      academic_hour_minutes: academic_hour_minutes,
      cohort_ids: Enum.map(row.session.cohorts, & &1.id)
    })
    |> then(&struct(__MODULE__, &1))
  end

  def save(term_id, original, attrs) do
    Repo.transaction(fn ->
      NeuZeit.Planning.SharedResources.lock!()
      term = Repo.one!(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE")
      base = (original && Map.get(original, :requirement)) || %__MODULE__{}

      base =
        if (Map.has_key?(attrs, :count) || Map.has_key?(attrs, "count")) &&
             !(Map.has_key?(attrs, :contact_hours) || Map.has_key?(attrs, "contact_hours")),
           do: %{base | contact_hours: nil},
           else: base

      changeset =
        changeset(%{base | academic_hour_minutes: term.academic_hour_minutes}, attrs)
        |> put_change(:term_id, term_id)

      workload =
        case apply_action(changeset, :insert) do
          {:ok, workload} -> workload
          {:error, error} -> Repo.rollback(error)
        end

      current = list(term_id)
      sessions = current_sessions!(current, original)
      attrs = workload |> Map.from_struct() |> Map.take(@fields -- [:count])

      changeset =
        if workload.contact_hours,
          do: changeset,
          else:
            put_change(
              changeset,
              :contact_hours,
              generated_hours(workload.count, workload, term.academic_hour_minutes)
            )

      if Enum.any?(current, fn row ->
           row.id != (original && original.id) && key(row.session) == attrs_key(attrs)
         end) do
        Repo.rollback(
          add_error(
            changeset,
            :course_component_id,
            "This workload already exists. Edit its quantity."
          )
        )
      end

      placed_ids =
        Repo.all(
          from p in NeuZeit.Planning.Placement,
            where: p.term_id == ^term_id,
            select: p.session_id,
            distinct: true
        )
        |> MapSet.new()

      sessions = Enum.sort_by(sessions, &{not MapSet.member?(placed_ids, &1.id), &1.id})
      {retained, removed} = Enum.split(sessions, workload.count)

      if Enum.any?(removed, &MapSet.member?(placed_ids, &1.id)) do
        Repo.rollback(
          add_error(
            changeset,
            :contact_hours,
            "Remove placements before reducing this workload."
          )
        )
      end

      requirement = unwrap!(Repo.insert_or_update(changeset), changeset)

      # Remove excess sessions first. A published placement or active exception
      # rejects the whole edit, including earlier deletions in this transaction.
      Enum.each(removed, &unwrap!(Sessions.delete_session(&1), changeset))
      retained = Enum.map(retained, &unwrap!(Sessions.update_session(&1, attrs), changeset))

      created =
        if workload.count > length(retained) do
          for _ <- 1..(workload.count - length(retained)) do
            unwrap!(Sessions.create_session(Map.put(attrs, :term_id, term_id)), changeset)
          end
        else
          []
        end

      ids = Enum.map(retained ++ created, & &1.id)

      Repo.update_all(from(s in NeuZeit.Catalog.Session, where: s.id in ^ids),
        set: [workload_id: requirement.id]
      )

      Repo.delete_all(
        from wc in NeuZeit.Catalog.WorkloadCohort, where: wc.workload_id == ^requirement.id
      )

      Repo.insert_all(
        NeuZeit.Catalog.WorkloadCohort,
        Enum.map(workload.cohort_ids, &%{workload_id: requirement.id, cohort_id: &1})
      )

      :saved
    end)
  end

  def hours(row, academic_hour_minutes \\ 45) do
    if Map.get(row, :requirement),
      do: row.requirement.contact_hours,
      else: generated_hours(row.count, row.session, academic_hour_minutes)
  end

  defp generated_hours(count, session, academic_hour_minutes) do
    repeats = if session.automatic_weeks, do: 1, else: length(session.week_mask)

    Decimal.from_float(
      count * repeats * session.duration_slots * slot_hours(academic_hour_minutes)
    )
  end

  def prepare(term_id) do
    Repo.transaction(fn ->
      NeuZeit.Planning.SharedResources.lock!()
      term = Repo.one!(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE")

      for row <- list(term_id), row.requirement do
        attrs = Map.take(row.requirement, @fields ++ [:contact_hours])
        form = changeset(%__MODULE__{academic_hour_minutes: term.academic_hour_minutes}, attrs)

        case apply_action(form, :insert) do
          {:ok, expected} when expected.count == row.count ->
            :ok

          {:ok, _} ->
            case save(term_id, row, attrs) do
              {:ok, _} -> :ok
              {:error, error} -> Repo.rollback(error)
            end

          {:error, error} ->
            Repo.rollback(error)
        end
      end

      :ready
    end)
  end

  defp slot_hours(academic_hour_minutes) do
    NeuZeit.Config.grid!().slots
    |> Enum.map(fn slot ->
      minutes = fn time ->
        [hours, minutes] = String.split(time, ":") |> Enum.map(&String.to_integer/1)
        hours * 60 + minutes
      end

      minutes.(slot.end) - minutes.(slot.start)
    end)
    |> then(&(Enum.sum(&1) / length(&1) / academic_hour_minutes))
  end

  defp require_hours(changeset) do
    if get_field(changeset, :automatic_weeks),
      do: validate_required(changeset, [:contact_hours]),
      else: changeset
  end

  defp count_from_hours(changeset) do
    hours = get_field(changeset, :contact_hours)
    duration = get_field(changeset, :duration_slots)
    weeks = get_field(changeset, :week_mask) || []
    repeats = if get_field(changeset, :automatic_weeks), do: 1, else: length(weeks)

    if hours && is_integer(duration) && duration > 0 && repeats > 0 do
      quantity =
        Decimal.to_float(hours) /
          (duration * repeats * slot_hours(get_field(changeset, :academic_hour_minutes)))

      if quantity > 0 && abs(quantity - round(quantity)) < 0.000001 do
        put_change(changeset, :count, round(quantity))
      else
        add_error(
          changeset,
          :contact_hours,
          "Hours must cover a whole number of sessions of this duration."
        )
      end
    else
      changeset
    end
  end

  defp current_sessions!(_rows, nil), do: []

  defp current_sessions!(rows, original) do
    current = Enum.find(rows, &(&1.id == original.id))

    if current && fingerprint(current) == fingerprint(original) do
      current.sessions
    else
      Repo.rollback({:conflict, "The workload changed. Reload it before saving."})
    end
  end

  defp fingerprint(row),
    do:
      {Enum.map(row.sessions, &{&1.id, key(&1)}), key(row.session),
       row.requirement && row.requirement.contact_hours}

  defp key(session) do
    session
    |> Map.take(@fields -- [:count, :cohort_ids])
    |> Map.put(:cohort_ids, Enum.map(session.cohorts, & &1.id))
    |> attrs_key()
  end

  defp attrs_key(attrs),
    do:
      {attrs.course_component_id, attrs.teacher_id, attrs.slot_profile_id,
       Enum.sort(attrs.cohort_ids), Enum.sort(attrs.week_mask), attrs.duration_slots,
       attrs.sequence_group, attrs.automatic_weeks}

  defp unwrap!({:ok, result}, _changeset), do: result

  defp unwrap!({:error, %Ecto.Changeset{} = error}, changeset) do
    changeset =
      Enum.reduce(error.errors, changeset, fn {field, {message, opts}}, acc ->
        add_error(acc, field, message, opts)
      end)

    Repo.rollback(%{changeset | action: :insert})
  end

  defp unwrap!({:error, reason}, _changeset), do: Repo.rollback(reason)
end
