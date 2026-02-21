defmodule Algedonia.Repo do
  use Ecto.Repo,
    otp_app: :algedonia,
    adapter: Ecto.Adapters.Postgres
end
