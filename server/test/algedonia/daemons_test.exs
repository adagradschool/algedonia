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

    test "requeues running task loops assigned to the daemon" do
      daemon = Factory.insert_daemon!(%{status: :online})
      ticket = Factory.insert_ticket!()

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :running_maker,
          current_attempt: 2,
          assigned_daemon_id: daemon.id
        })

      assert {:ok, _updated_daemon} = Daemons.mark_unhealthy(daemon)

      updated_loop = Algedonia.Loops.get_loop!(loop.id)
      assert updated_loop.status == :pending
      assert is_nil(updated_loop.assigned_daemon_id)
      assert updated_loop.current_attempt == 2
    end
  end

  describe "mark_offline/1" do
    test "sets status to offline and resets running_loops" do
      daemon = Factory.insert_daemon!(%{status: :online, running_loops: 2})
      assert {:ok, updated} = Daemons.mark_offline(daemon)
      assert updated.status == :offline
      assert updated.running_loops == 0
    end

    test "requeues running checker loops assigned to the daemon" do
      daemon = Factory.insert_daemon!(%{status: :unhealthy, running_loops: 1})
      ticket = Factory.insert_ticket!()

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :running_checker,
          current_attempt: 3,
          assigned_daemon_id: daemon.id
        })

      assert {:ok, _updated_daemon} = Daemons.mark_offline(daemon)

      updated_loop = Algedonia.Loops.get_loop!(loop.id)
      assert updated_loop.status == :pending
      assert is_nil(updated_loop.assigned_daemon_id)
      assert updated_loop.current_attempt == 3
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

  describe "repo status" do
    test "set_repo_status/3 stores and retrieves status per workspace" do
      Daemons.set_repo_status("daemon-a", "ws-1", %{"status" => "ready", "path" => "/tmp/repo"})
      status = Daemons.get_repo_status("daemon-a", "ws-1")
      assert status["status"] == "ready"
      assert status["path"] == "/tmp/repo"
    end

    test "get_repo_status/2 returns nil for unknown daemon/workspace" do
      assert Daemons.get_repo_status("unknown-daemon", "ws-1") == nil
    end

    test "get_repo_status/2 distinguishes workspaces for same daemon" do
      Daemons.set_repo_status("daemon-multi", "ws-a", %{"status" => "ready"})
      Daemons.set_repo_status("daemon-multi", "ws-b", %{"status" => "error"})
      assert Daemons.get_repo_status("daemon-multi", "ws-a")["status"] == "ready"
      assert Daemons.get_repo_status("daemon-multi", "ws-b")["status"] == "error"
    end

    test "repo_ready?/2 returns true for ready status" do
      Daemons.set_repo_status("daemon-b", "ws-1", %{"status" => "ready"})
      assert Daemons.repo_ready?("daemon-b", "ws-1")
    end

    test "repo_ready?/2 returns true for not_configured status" do
      Daemons.set_repo_status("daemon-c", "ws-1", %{"status" => "not_configured"})
      assert Daemons.repo_ready?("daemon-c", "ws-1")
    end

    test "repo_ready?/2 returns false for error status" do
      Daemons.set_repo_status("daemon-d", "ws-1", %{"status" => "error"})
      refute Daemons.repo_ready?("daemon-d", "ws-1")
    end

    test "repo_ready?/2 returns false for unknown daemon/workspace" do
      refute Daemons.repo_ready?("no-such-daemon", "no-ws")
    end
  end

  describe "find_online/0" do
    test "returns first online daemon" do
      Factory.insert_daemon!(%{name: "offline-1", status: :offline})
      Factory.insert_daemon!(%{name: "online-1", status: :online})

      assert {:ok, daemon} = Daemons.find_online()
      assert daemon.name == "online-1"
      assert daemon.status == :online
    end

    test "returns error when no daemons are online" do
      Factory.insert_daemon!(%{name: "offline-1", status: :offline})
      Factory.insert_daemon!(%{name: "unhealthy-1", status: :unhealthy})

      assert {:error, :no_online_daemon} = Daemons.find_online()
    end

    test "returns error when no daemons exist" do
      assert {:error, :no_online_daemon} = Daemons.find_online()
    end
  end
end
