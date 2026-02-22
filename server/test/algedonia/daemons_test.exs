defmodule Algedonia.DaemonsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Daemons
  alias Algedonia.Factory

  describe "register_daemon/1" do
    test "creates a new daemon registration" do
      assert {:ok, daemon} = Daemons.register_daemon(%{name: "test-daemon"})
      assert daemon.name == "test-daemon"
      assert daemon.status == :online
      assert daemon.connected_at
      assert daemon.last_heartbeat_at
    end

    test "upserts existing daemon to online" do
      existing = Factory.insert_daemon!(%{name: "my-daemon", status: :offline})

      assert {:ok, daemon} = Daemons.register_daemon(%{name: "my-daemon"})
      assert daemon.id == existing.id
      assert daemon.status == :online
    end
  end

  describe "update_heartbeat/2" do
    test "updates last_heartbeat_at and payload fields" do
      daemon = Factory.insert_daemon!()
      old_heartbeat = daemon.last_heartbeat_at

      Process.sleep(1)

      assert {:ok, updated} = Daemons.update_heartbeat(daemon, %{capacity: 5, running_loops: 2})
      assert updated.capacity == 5
      assert updated.running_loops == 2
      assert DateTime.compare(updated.last_heartbeat_at, old_heartbeat) == :gt
    end
  end

  describe "mark_unhealthy/1" do
    test "sets status to unhealthy" do
      daemon = Factory.insert_daemon!(%{status: :online})
      assert {:ok, updated} = Daemons.mark_unhealthy(daemon)
      assert updated.status == :unhealthy
    end
  end

  describe "mark_offline/1" do
    test "sets status to offline and resets running_loops" do
      daemon = Factory.insert_daemon!(%{status: :online, running_loops: 2})
      assert {:ok, updated} = Daemons.mark_offline(daemon)
      assert updated.status == :offline
      assert updated.running_loops == 0
    end
  end

  describe "list_daemons/0" do
    test "returns all daemons" do
      Factory.insert_daemon!(%{name: "d1"})
      Factory.insert_daemon!(%{name: "d2"})
      assert length(Daemons.list_daemons()) == 2
    end
  end

  describe "get_daemon_by_name/1" do
    test "returns daemon by name" do
      Factory.insert_daemon!(%{name: "findme"})
      assert %{name: "findme"} = Daemons.get_daemon_by_name("findme")
    end

    test "returns nil for unknown name" do
      assert Daemons.get_daemon_by_name("nope") == nil
    end
  end
end
