defmodule AlgedoniaWeb.DaemonChannelTest do
  use AlgedoniaWeb.ChannelCase

  alias Algedonia.{Daemons, Repo, TaskLoopOrchestrator}
  alias AlgedoniaWeb.DaemonSocket
  alias Ecto.Adapters.SQL.Sandbox

  @daemon_id "test-daemon-id"
  @daemon_name "test-daemon"

  setup do
    {:ok, socket} =
      connect(DaemonSocket, %{
        "token" => "test-token",
        "daemon_id" => @daemon_id,
        "daemon_name" => @daemon_name
      })

    {:ok, socket: socket}
  end

  describe "join" do
    test "succeeds with matching daemon_id and returns workspaces", %{socket: socket} do
      assert {:ok, %{status: "ok", workspaces: workspaces}, _socket} =
               subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      assert is_list(workspaces)
    end

    test "fails with mismatched daemon_id", %{socket: socket} do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "daemon:wrong-id", %{})
    end

    test "includes user's workspaces with repo URLs in join reply" do
      user = Algedonia.Factory.insert_user!()
      token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})

      {:ok, socket} =
        connect(DaemonSocket, %{
          "token" => token,
          "daemon_id" => @daemon_id,
          "daemon_name" => @daemon_name
        })

      workspace =
        Algedonia.Factory.insert_workspace!(%{
          slug: "ws-with-repo",
          github_repo_url: "https://github.com/example/repo"
        })

      Algedonia.Factory.insert_membership!(workspace, user)

      assert {:ok, reply, _socket} =
               subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      assert reply.status == "ok"
      ws = Enum.find(reply.workspaces, &(&1.slug == "ws-with-repo"))
      assert ws
      assert ws.github_repo_url == "https://github.com/example/repo"
    end

    test "includes workspaces without repo URLs" do
      user = Algedonia.Factory.insert_user!()
      token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})

      {:ok, socket} =
        connect(DaemonSocket, %{
          "token" => token,
          "daemon_id" => @daemon_id,
          "daemon_name" => @daemon_name
        })

      workspace = Algedonia.Factory.insert_workspace!(%{slug: "ws-no-repo"})
      Algedonia.Factory.insert_membership!(workspace, user)

      assert {:ok, reply, _socket} =
               subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      assert reply.status == "ok"
      ws = Enum.find(reply.workspaces, &(&1.slug == "ws-no-repo"))
      assert ws
      refute Map.has_key?(ws, :github_repo_url)
    end

    test "returns empty workspaces when user has none", %{socket: socket} do
      assert {:ok, reply, _socket} =
               subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      assert reply.status == "ok"
      assert is_list(reply.workspaces)
    end
  end

  describe "connect" do
    test "rejects invalid token" do
      assert :error =
               connect(DaemonSocket, %{
                 "token" => "bad-token",
                 "daemon_id" => @daemon_id,
                 "daemon_name" => @daemon_name
               })
    end

    test "rejects missing params" do
      assert :error = connect(DaemonSocket, %{})
    end
  end

  describe "repo_clone_status" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "stores ready status for daemon and workspace", %{socket: socket} do
      ref =
        push(socket, "repo_clone_status", %{
          "status" => "ready",
          "workspace_slug" => "my-ws",
          "path" => "/tmp/repos/ws"
        })

      refute_reply ref, _

      status = Algedonia.Daemons.get_repo_status(@daemon_name, "my-ws")
      assert status["status"] == "ready"
      assert status["path"] == "/tmp/repos/ws"
    end

    test "stores error status for daemon and workspace", %{socket: socket} do
      ref =
        push(socket, "repo_clone_status", %{
          "status" => "error",
          "workspace_slug" => "err-ws",
          "message" => "clone failed"
        })

      refute_reply ref, _

      status = Algedonia.Daemons.get_repo_status(@daemon_name, "err-ws")
      assert status["status"] == "error"
      assert status["message"] == "clone failed"
    end

    test "stores not_configured status", %{socket: socket} do
      ref =
        push(socket, "repo_clone_status", %{
          "status" => "not_configured",
          "workspace_slug" => "nc-ws"
        })

      refute_reply ref, _

      assert Algedonia.Daemons.repo_ready?(@daemon_name, "nc-ws")
    end
  end

  describe "heartbeat" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "updates heartbeat with payload and pushes workspace sync", %{socket: socket} do
      ref = push(socket, "heartbeat", %{"capacity" => 5, "running_loops" => 1})
      assert_reply ref, :ok
      assert_push "workspaces_sync", %{workspaces: []}
    end

    test "pushes user workspaces on heartbeat" do
      user = Algedonia.Factory.insert_user!()

      workspace =
        Algedonia.Factory.insert_workspace!(%{
          slug: "heartbeat-ws",
          github_repo_url: "https://github.com/example/heartbeat-repo"
        })

      Algedonia.Factory.insert_membership!(workspace, user)

      token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})
      daemon_id = "test-heartbeat-daemon-#{System.unique_integer([:positive])}"
      daemon_name = "test-heartbeat-name-#{System.unique_integer([:positive])}"

      {:ok, socket} =
        connect(DaemonSocket, %{
          "token" => token,
          "daemon_id" => daemon_id,
          "daemon_name" => daemon_name
        })

      {:ok, _reply, socket} = subscribe_and_join(socket, "daemon:#{daemon_id}", %{})

      ref = push(socket, "heartbeat", %{"capacity" => 5, "running_loops" => 1})
      assert_reply ref, :ok

      assert_push "workspaces_sync", %{workspaces: workspaces}
      ws = Enum.find(workspaces, &(&1.slug == "heartbeat-ws"))
      assert ws
      assert ws.github_repo_url == "https://github.com/example/heartbeat-repo"
    end
  end

  describe "terminal_output" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "decodes base64 data and appends to terminal buffer", %{socket: socket} do
      loop_id = "test-loop-#{System.unique_integer([:positive])}"
      data = Base.encode64("hello terminal")

      ref = push(socket, "terminal_output", %{"loop_id" => loop_id, "data" => data})
      refute_reply ref, _

      scrollback = Algedonia.Terminals.get_scrollback(loop_id)
      assert scrollback =~ "hello terminal"
    end

    test "rejects invalid base64", %{socket: socket} do
      ref = push(socket, "terminal_output", %{"loop_id" => "x", "data" => "not!valid!base64!!"})
      assert_reply ref, :error, %{reason: "invalid_base64"}
    end
  end

  describe "loop_exited" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "broadcasts terminal_ended on PubSub", %{socket: socket} do
      loop_id = "test-exit-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Algedonia.PubSub, "terminal:#{loop_id}")

      ref = push(socket, "loop_exited", %{"loop_id" => loop_id, "exit_code" => 0})
      refute_reply ref, _

      assert_receive {:terminal_ended, ^loop_id, 0}, 1000
    end
  end

  describe "attempt_complete" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "routes hook loop completion to HookExecutor", %{socket: socket} do
      ticket = Algedonia.Factory.insert_ticket!(%{status: :in_progress})

      loop =
        Algedonia.Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :hook,
          status: :running
        })

      ref =
        push(socket, "attempt_complete", %{
          "loop_id" => loop.id,
          "exit_code" => 0,
          "session_id" => "hook-1"
        })

      refute_reply ref, _
      assert Algedonia.Loops.get_loop!(loop.id).status == :passed
      assert Algedonia.Tickets.get_ticket!(ticket.id).status == :in_progress
    end
  end

  describe "error" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "routes unknown loop errors to TaskLoopOrchestrator", %{socket: socket} do
      ref =
        push(socket, "error", %{
          "loop_id" => "nonexistent-loop",
          "message" => "something went wrong"
        })

      refute_reply ref, _
    end

    test "routes task loop errors to TaskLoopOrchestrator", %{socket: socket} do
      test_pid = self()

      push_fn = fn daemon_name, loop_id, opts ->
        send(test_pid, {:orch_push, daemon_name, loop_id, opts})
        :ok
      end

      {:ok, orch} = TaskLoopOrchestrator.start_link(name: TaskLoopOrchestrator, push_fn: push_fn)
      on_exit(fn -> if Process.alive?(orch), do: GenServer.stop(orch) end)
      Sandbox.allow(Repo, self(), orch)

      daemon = Daemons.get_daemon_by_name(@daemon_name)
      assert daemon
      ticket = Algedonia.Factory.insert_ticket!(%{status: :in_progress})

      loop =
        Algedonia.Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :task,
          status: :running,
          current_attempt: 1,
          max_attempts: 3,
          assigned_daemon_id: daemon.id
        })

      {:ok, _step} =
        Algedonia.Loops.create_step(%{
          loop_id: loop.id,
          role: "maker",
          attempt: 1,
          status: "running",
          started_at: DateTime.utc_now()
        })

      loop_id = loop.id

      ref =
        push(socket, "error", %{
          "loop_id" => loop.id,
          "message" => "agent exited with code 2",
          "exit_code" => 2,
          "session_id" => "maker-1"
        })

      refute_reply ref, _
      assert_receive {:orch_push, @daemon_name, ^loop_id, %{"role" => "maker"}}, 1000
      assert loop_id == loop.id
      assert Algedonia.Loops.get_loop!(loop.id).current_attempt == 2
    end

    test "routes hook loop errors to HookExecutor", %{socket: socket} do
      ticket = Algedonia.Factory.insert_ticket!(%{status: :in_progress})

      loop =
        Algedonia.Factory.insert_loop!(%{
          ticket_id: ticket.id,
          role: :hook,
          status: :running
        })

      ref =
        push(socket, "error", %{
          "loop_id" => loop.id,
          "message" => "hook failed",
          "exit_code" => 2,
          "session_id" => "hook-err"
        })

      refute_reply ref, _
      assert Algedonia.Loops.get_loop!(loop.id).status == :failed
      assert Algedonia.Tickets.get_ticket!(ticket.id).status == :halted
    end
  end

  describe "stdin_input push" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "forwards stdin_input broadcast to daemon", %{socket: _socket} do
      AlgedoniaWeb.DaemonChannel.push_stdin_input(
        @daemon_id,
        "loop-stdin-test",
        "aGVsbG8="
      )

      assert_push "stdin_input", %{"loop_id" => "loop-stdin-test", "data" => "aGVsbG8="}
    end
  end

  describe "start_loop push" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "forwards start_loop broadcast to daemon", %{socket: _socket} do
      AlgedoniaWeb.DaemonChannel.push_start_loop(
        @daemon_id,
        "loop-push-test",
        %{"command" => "echo"}
      )

      assert_push "start_loop", %{"loop_id" => "loop-push-test", "command" => "echo"}
    end
  end

  describe "cleanup_worktree push" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "forwards cleanup_worktree broadcast to daemon", %{socket: _socket} do
      AlgedoniaWeb.DaemonChannel.push_cleanup_worktree(
        @daemon_id,
        "ticket-123",
        "my-workspace"
      )

      assert_push "cleanup_worktree", %{
        "ticket_id" => "ticket-123",
        "workspace_slug" => "my-workspace"
      }
    end
  end

  describe "open_editor push" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "forwards open_editor broadcast to daemon", %{socket: _socket} do
      AlgedoniaWeb.DaemonChannel.push_open_editor(
        @daemon_id,
        "ticket-456",
        "editor-workspace"
      )

      assert_push "open_editor", %{
        "ticket_id" => "ticket-456",
        "workspace_slug" => "editor-workspace"
      }
    end
  end
end
