defmodule NeuZeit.Catalog.CourseComponents do
  @moduledoc false
  alias NeuZeit.Catalog.ScheduleValidation
  alias NeuZeit.Catalog.WriteSupport
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias NeuZeit.Catalog.ComponentAllowedRoom
  alias NeuZeit.Catalog.CourseComponent
  alias NeuZeit.Catalog.Room
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Repo

  def list_course_components do
    Repo.all(
      from c in CourseComponent,
        order_by: [asc: c.course_id, asc: c.kind],
        preload: [:course, :allowed_rooms]
    )
  end

  def get_course_component!(id) do
    CourseComponent |> Repo.get!(id) |> Repo.preload([:course, :allowed_rooms])
  end

  def create_course_component(attrs) do
    with {:ok, allowed_room_ids} <-
           WriteSupport.normalize_existing_ids(
             WriteSupport.attr(attrs, :allowed_room_ids, []),
             :allowed_room_ids,
             %CourseComponent{},
             Room
           ) do
      Multi.new()
      |> Multi.run(:shared_schedule_lock, fn _repo, _changes ->
        {:ok, NeuZeit.Planning.SharedResources.lock!()}
      end)
      |> Multi.insert(:component, CourseComponent.changeset(%CourseComponent{}, attrs))
      |> Multi.run(:allowed_rooms, fn repo, %{component: component} ->
        replace_allowed_rooms(repo, component.id, allowed_room_ids)
      end)
      |> Repo.transaction()
      |> WriteSupport.unwrap_multi(:component)
    end
  end

  def update_course_component(%CourseComponent{} = component, attrs) do
    with {:ok, allowed_room_ids} <-
           WriteSupport.maybe_normalize_existing_ids(
             WriteSupport.attr(attrs, :allowed_room_ids),
             :allowed_room_ids,
             %CourseComponent{},
             Room
           ) do
      WriteSupport.transaction_result(fn ->
        current =
          Repo.one!(
            from c in CourseComponent,
              where: c.id == ^component.id,
              lock: "FOR UPDATE"
          )

        term_ids =
          if is_nil(allowed_room_ids),
            do: [],
            else: lock_component_terms(current.id)

        with {:ok, updated} <- current |> CourseComponent.changeset(attrs) |> Repo.update(),
             {:ok, _count} <- maybe_replace_allowed_rooms(updated.id, allowed_room_ids),
             :ok <- ScheduleValidation.validate_component_schedules(term_ids, updated.id) do
          {:ok, updated}
        end
      end)
    end
  end

  def delete_course_component(%CourseComponent{} = component), do: Repo.delete(component)

  def change_course_component(%CourseComponent{} = component, attrs \\ %{}),
    do: CourseComponent.changeset(component, attrs)

  defp lock_component_terms(component_id) do
    # A session can concurrently move onto this component. Locking the complete
    # ordered term set first makes the subsequent affected-term query stable and
    # preserves the same serialization point used by session and exception edits.
    Repo.all(from t in Term, order_by: t.id, lock: "FOR UPDATE", select: t.id)

    Repo.all(
      from s in Session,
        where: s.course_component_id == ^component_id,
        distinct: true,
        order_by: s.term_id,
        select: s.term_id
    )
  end

  defp maybe_replace_allowed_rooms(_component_id, nil), do: {:ok, :unchanged}

  defp maybe_replace_allowed_rooms(component_id, room_ids) do
    replace_allowed_rooms(Repo, component_id, room_ids)
  end

  defp replace_allowed_rooms(repo, component_id, room_ids) do
    repo.delete_all(from r in ComponentAllowedRoom, where: r.component_id == ^component_id)

    rows =
      Enum.map(room_ids, fn room_id ->
        %{component_id: component_id, room_id: room_id}
      end)

    {count, _} = repo.insert_all(ComponentAllowedRoom, rows)
    {:ok, count}
  end
end
