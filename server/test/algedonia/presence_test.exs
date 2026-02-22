defmodule Algedonia.PresenceTest do
  use ExUnit.Case, async: true

  alias Algedonia.Presence

  setup do
    topic = "presence:test:#{System.unique_integer()}"
    {:ok, topic: topic}
  end

  test "track and list a user", %{topic: topic} do
    Presence.track(self(), topic, "Ada", %{display_name: "Ada"})
    assert %{"Ada" => _} = Presence.list(topic)
  end

  test "untrack removes user", %{topic: topic} do
    Presence.track(self(), topic, "Ada", %{display_name: "Ada"})
    assert %{"Ada" => _} = Presence.list(topic)

    Presence.untrack(self(), topic, "Ada")
    assert Presence.list(topic) == %{}
  end
end
