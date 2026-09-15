defmodule NeuZeit.Settings do
  @moduledoc "Institution-wide language settings, initialized from deployment defaults."
  import Ecto.Query
  alias NeuZeit.Repo
  alias NeuZeit.Settings.Institution

  def get do
    Repo.get(Institution, 1) ||
      struct(
        Institution,
        Map.take(NeuZeit.Scheduling.Defaults.policy().institution, [
          :name,
          :timezone,
          :supported_locales,
          :default_locale
        ])
      )
  end

  # One snapshot per request or LiveView avoids a query for every translated label.
  def snapshot, do: Process.get({__MODULE__, :snapshot}) || get()
  def refresh, do: Process.put({__MODULE__, :snapshot}, get())

  def timezones do
    Repo.query!(
      "SELECT name FROM pg_timezone_names WHERE name = 'UTC' OR (name LIKE '%/%' AND name NOT LIKE 'posix/%' AND name NOT LIKE 'right/%' AND name NOT LIKE 'SystemV/%') ORDER BY name"
    ).rows
    |> List.flatten()
  end

  def change(settings, attrs \\ %{}), do: Institution.changeset(settings, attrs)

  def save(attrs) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(72849, 2)")
      settings = Repo.one(from s in Institution, where: s.id == 1, lock: "FOR UPDATE") || get()
      settings |> change(attrs) |> Repo.insert_or_update()
    end)
    |> case do
      {:ok, _} = result ->
        Process.delete({__MODULE__, :snapshot})
        result

      result ->
        result
    end
  end
end
