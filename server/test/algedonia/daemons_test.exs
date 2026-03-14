defmodule Algedonia.DaemonsTest do
  use Algedonia.DataCase, async: false

  alias Algedonia.{Daemons, ReviewLoop}
  alias Algedonia.Factory

  describe "register_daemon/1" do
    test "creates a new daemon registration" do
      user = Factory.insert_user!()
      assert {:ok, daemon} = Daemons.register_daemon(%{name: "test-daemon", user_id: user.id})
      assert daemon.name == "test-daemon"
      assert daemon.user_id == user.id
      assert daemon.status == :online
      assert daemon.connected_at
      assert daemon.last_heartbeat_at
    end

    test "upserts existing daemon to online" do
      user = Factory.insert_user!()
      existing = Factory.insert_daemon!(%{name: "my-daemon", status: :offline, user_id: user.id})

      assert {:ok, daemon} = Daemons.register_daemon(%{name: "my-daemon", user_id: user.id})
      assert daemon.id == existing.id
      assert daemon.status == :online
    end

    test "rejects taking over a daemon name registered to another user" do
      owner = Factory.insert_user!()
      attacker = Factory.insert_user!()
      Factory.insert_daemon!(%{name: "my-daemon", status: :online, user_id: owner.id})

      assert {:error, :name_taken} =
               Daemons.register_daemon(%{name: "my-daemon", user_id: attacker.id})
    end

    test "requeues running task loops on reconnect" do
      user = Factory.insert_user!()

      daemon =
        Factory.insert_daemon!(%{name: "reconnect-daemon", status: :offline, user_id: user.id})

      ticket = Factory.insert_ticket!()

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :running,
          current_attempt: 1,
          assigned_daemon_id: daemon.id
        })

      assert {:ok, _daemon} =
               Daemons.register_daemon(%{name: "reconnect-daemon", user_id: user.id})

      updated_loop = Algedonia.Loops.get_loop!(loop.id)
      assert updated_loop.status == :pending
      assert is_nil(updated_loop.assigned_daemon_id)
    end

    test "reconnect requeue keeps the current step record and marks it interrupted" do
      user = Factory.insert_user!()

      daemon =
        Factory.insert_daemon!(%{
          name: "reconnect-step-daemon",
          status: :offline,
          user_id: user.id
        })

      ticket = Factory.insert_ticket!()

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: ticket.workspace_id,
          role: :task,
          status: :running,
          current_attempt: 1,
          assigned_daemon_id: daemon.id
        })

      {:ok, step} =
        Algedonia.Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      assert {:ok, _daemon} =
               Daemons.register_daemon(%{name: "reconnect-step-daemon", user_id: user.id})

      history = Algedonia.Loops.list_steps_for_loop(loop.id)
      assert length(history) == 1

      [interrupted_step] = history
      assert interrupted_step.id == step.id
      assert interrupted_step.status == "interrupted"
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

    test "persists available_agents and bare_repos arrays" do
      daemon = Factory.insert_daemon!()

      assert {:ok, updated} =
               Daemons.update_heartbeat(daemon, %{
                 available_agents: ["claude_code", "codex"],
                 bare_repos: ["alpha", "beta"]
               })

      assert updated.available_agents == ["claude_code", "codex"]
      assert updated.bare_repos == ["alpha", "beta"]
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
          status: :running,
          current_attempt: 2,
          assigned_daemon_id: daemon.id
        })

      assert {:ok, _updated_daemon} = Daemons.mark_unhealthy(daemon)

      updated_loop = Algedonia.Loops.get_loop!(loop.id)
      assert updated_loop.status == :pending
      assert is_nil(updated_loop.assigned_daemon_id)
      assert updated_loop.current_attempt == 2
    end

    test "fails running planning loops instead of requeuing" do
      daemon = Factory.insert_daemon!(%{status: :online})
      ticket = Factory.insert_ticket!()

      loop =
        Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :planning,
          status: :running,
          current_attempt: 1,
          max_attempts: 1,
          assigned_daemon_id: daemon.id
        })

      assert {:ok, _updated_daemon} = Daemons.mark_unhealthy(daemon)

      updated_loop = Algedonia.Loops.get_loop!(loop.id)
      assert updated_loop.status == :failed
      assert is_nil(updated_loop.assigned_daemon_id)
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
          status: :running,
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

  describe "update_heartbeat/2 recovery" do
    test "promotes unhealthy daemon back to online on heartbeat" do
      daemon = Factory.insert_daemon!(%{status: :unhealthy})

      assert {:ok, updated} = Daemons.update_heartbeat(daemon, %{capacity: 3, running_loops: 0})
      assert updated.status == :online
    end

    test "leaves online daemon as online on heartbeat" do
      daemon = Factory.insert_daemon!(%{status: :online})

      assert {:ok, updated} = Daemons.update_heartbeat(daemon, %{capacity: 3, running_loops: 0})
      assert updated.status == :online
    end
  end

  describe "reconcile_running_loops/2" do
    test "restarts missing review loops when daemon heartbeat reports none running" do
      test_pid = self()

      {:ok, pid} =
        ReviewLoop.start_link(
          push_fn: fn daemon_name, loop_id, opts ->
            send(test_pid, {:push_start_loop, daemon_name, loop_id, opts})
          end,
          name: ReviewLoop
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          GenServer.stop(pid)
        end
      end)

      user = Factory.insert_user!()
      workspace = Factory.insert_workspace!(%{slug: "reconcile-review"})
      Factory.insert_membership!(workspace, user)

      daemon =
        Factory.insert_daemon!(%{
          name: "reconcile-review-daemon",
          status: :online,
          user_id: user.id
        })

      ticket =
        Factory.insert_ticket!(%{
          workspace_id: workspace.id,
          status: :in_review,
          title: "Recover review session"
        })

      loop =
        Factory.insert_loop!(%{
          workspace_id: workspace.id,
          ticket_id: ticket.id,
          role: :review,
          status: :running,
          current_attempt: 1,
          assigned_daemon_id: daemon.id
        })

      assert :ok = Daemons.reconcile_running_loops(daemon, [])

      daemon_name = daemon.name
      loop_id = loop.id
      assert_receive {:push_start_loop, ^daemon_name, ^loop_id, payload}
      assert payload["role"] == "review"
      assert payload["workspace_slug"] == workspace.slug
      assert payload["ticket_id"] == ticket.id
    end
  end

  describe "list_daemons/0" do
    test "returns all daemons" do
      Factory.insert_daemon!(%{name: "d1"})
      Factory.insert_daemon!(%{name: "d2"})
      assert length(Daemons.list_daemons()) == 2
    end
  end

  describe "list_daemons/1" do
    test "returns daemons scoped to workspace memberships" do
      workspace_a = Factory.insert_workspace!(%{slug: "scope-a-#{System.unique_integer()}"})
      workspace_b = Factory.insert_workspace!(%{slug: "scope-b-#{System.unique_integer()}"})
      user_a = Factory.insert_user!()
      user_b = Factory.insert_user!()

      Factory.insert_membership!(workspace_a, user_a)
      Factory.insert_membership!(workspace_b, user_b)

      daemon_a = Factory.insert_daemon!(%{name: "scope-a-daemon", user_id: user_a.id})
      _daemon_b = Factory.insert_daemon!(%{name: "scope-b-daemon", user_id: user_b.id})

      assert [%{id: id}] = Daemons.list_daemons(workspace_a.id)
      assert id == daemon_a.id
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
