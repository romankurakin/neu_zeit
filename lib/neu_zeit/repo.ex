defmodule NeuZeit.Repo do
  use Ecto.Repo,
    otp_app: :neu_zeit,
    adapter: Ecto.Adapters.Postgres
end
