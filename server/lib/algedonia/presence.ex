defmodule Algedonia.Presence do
  @moduledoc """
  Tracks which users are viewing each page via Phoenix Presence.
  """
  use Phoenix.Presence,
    otp_app: :algedonia,
    pubsub_server: Algedonia.PubSub
end
