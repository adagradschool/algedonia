defmodule AlgedoniaWeb.DaemonChannelTest do
  use AlgedoniaWeb.ChannelCase

  alias Algedonia.{Daemons, Repo, TaskLoopOrchestrator}
  alias Algedonia.PubSub.Topics
  alias AlgedoniaWeb.DaemonSocket
  alias Ecto.Adapters.SQL.Sandbox

  @daemon_id "test-daemon-id"
  @daemon_name "test-daemon"

  setup do
    workspace = Algedonia.Factory.default_workspace!()
    previous_scope = Algedonia.DataCase.put_workspace_scope(workspace)
    on_exit(fn -> Algedonia.DataCase.restore_workspace_scope(previous_scope) end)

    user = Algedonia.Factory.insert_user!()
    token = Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id})

    {:ok, socket} =
      connect(DaemonSocket, %{
        "token" => token,
        "daemon_id" => @daemon_id,
        "daemon_name" => @daemon_name
      })

    {:ok, socket: socket, user: user, workspace: workspace}
  end

  describe "join" do
    test "persists registration with user_id, available_agents, and bare_repos", %{
      socket: socket,
      user: user
    } do
      assert {:ok, %{status: "ok"}, _socket} =
               subscribe_and_join(socket, "daemon:#{@daemon_id}", %{
                 "available_agents" => ["claude_code", "codex"],
                 "bare_repos" => ["alpha", "beta"]
               })

      daemon = Daemons.get_daemon_by_name(@daemon_name)
      assert daemon.user_id == user.id
      assert daemon.available_agents == ["claude_code", "codex"]
      assert daemon.bare_repos == ["alpha", "beta"]
    end

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

    test "rejects expired token" do
      user = Algedonia.Factory.insert_user!()
      signed_at = System.system_time(:second) - 8 * 24 * 3600

      token =
        Phoenix.Token.sign(AlgedoniaWeb.Endpoint, "daemon_auth", %{user_id: user.id},
          signed_at: signed_at
        )

      assert :error =
               connect(DaemonSocket, %{
                 "token" => token,
                 "daemon_id" => @daemon_id,
                 "daemon_name" => @daemon_name
               })
    end

    test "rejects missing params" do
      assert :error = connect(DaemonSocket, %{})
    end
  end

  describe "repo_clone_status" do
    setup %{socket: socket, user: user} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket, user: user}
    end

    test "stores ready status for daemon and workspace", %{socket: socket, user: user} do
      workspace = Algedonia.Factory.insert_workspace!(%{slug: "my-ws"})
      Algedonia.Factory.insert_membership!(workspace, user)

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

    test "stores error status for daemon and workspace", %{socket: socket, user: user} do
      workspace = Algedonia.Factory.insert_workspace!(%{slug: "err-ws"})
      Algedonia.Factory.insert_membership!(workspace, user)

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

    test "stores not_configured status", %{socket: socket, user: user} do
      workspace = Algedonia.Factory.insert_workspace!(%{slug: "nc-ws"})
      Algedonia.Factory.insert_membership!(workspace, user)

      ref =
        push(socket, "repo_clone_status", %{
          "status" => "not_configured",
          "workspace_slug" => "nc-ws"
        })

      refute_reply ref, _

      assert Algedonia.Daemons.repo_ready?(@daemon_name, "nc-ws")
    end

    test "rejects repo status updates for unauthorized workspace", %{socket: socket} do
      ref =
        push(socket, "repo_clone_status", %{
          "status" => "ready",
          "workspace_slug" => "other-user-ws"
        })

      assert_reply ref, :error, %{reason: "invalid_workspace_scope"}
      assert Algedonia.Daemons.get_repo_status(@daemon_name, "other-user-ws") == nil
    end
  end

  describe "heartbeat" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "updates heartbeat with payload and pushes workspace sync", %{socket: socket} do
      ref =
        push(socket, "heartbeat", %{
          "capacity" => 5,
          "running_loops" => 1,
          "available_agents" => ["claude_code", "codex"],
          "bare_repos" => ["my-ws"]
        })

      assert_reply ref, :ok
      assert_push "workspaces_sync", %{workspaces: []}

      daemon = Daemons.get_daemon_by_name(@daemon_name)
      assert daemon.available_agents == ["claude_code", "codex"]
      assert daemon.bare_repos == ["my-ws"]
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
      daemon_id = Ecto.UUID.generate()
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

    test "decodes base64 data and appends to terminal buffer", %{
      socket: socket,
      workspace: workspace,
      user: user
    } do
      Algedonia.Factory.insert_membership!(workspace, user)

      loop_id = Ecto.UUID.generate()
      data = Base.encode64("hello terminal")

      ref =
        push(socket, "terminal_output", %{
          "loop_id" => loop_id,
          "data" => data,
          "workspace_slug" => workspace.slug
        })

      refute_reply ref, _

      scrollback = Algedonia.Terminals.get_scrollback(loop_id)
      assert scrollback =~ "hello terminal"
    end

    test "rejects invalid base64", %{socket: socket, workspace: workspace, user: user} do
      Algedonia.Factory.insert_membership!(workspace, user)

      ref =
        push(socket, "terminal_output", %{
          "loop_id" => "11111111-1111-4111-8111-111111111111",
          "data" => "not!valid!base64!!",
          "workspace_slug" => workspace.slug
        })

      assert_reply ref, :error, %{reason: "invalid_base64"}
    end
  end

  describe "manual_run events" do
    setup %{socket: socket, user: user} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket, user: user}
    end

    test "broadcasts dedicated manual run output and completion on ticket manual-run topic", %{
      socket: socket,
      workspace: workspace,
      user: user
    } do
      Algedonia.Factory.insert_membership!(workspace, user)
      ticket_id = Ecto.UUID.generate()
      run_id = Ecto.UUID.generate()

      Phoenix.PubSub.subscribe(
        Algedonia.PubSub,
        Topics.ticket_manual_run(workspace.id, ticket_id)
      )

      output_ref =
        push(socket, "manual_run_output", %{
          "run_id" => run_id,
          "ticket_id" => ticket_id,
          "data" => Base.encode64("manual stdout"),
          "workspace_slug" => workspace.slug
        })

      refute_reply output_ref, _

      assert_receive {:manual_run_output,
                      %{
                        "run_id" => ^run_id,
                        "ticket_id" => ^ticket_id,
                        "data" => "manual stdout"
                      }},
                     1000

      complete_ref =
        push(socket, "manual_run_complete", %{
          "run_id" => run_id,
          "ticket_id" => ticket_id,
          "workspace_slug" => workspace.slug,
          "status" => "succeeded",
          "exit_code" => 0
        })

      refute_reply complete_ref, _

      assert_receive {:manual_run_complete,
                      %{
                        "run_id" => ^run_id,
                        "ticket_id" => ^ticket_id,
                        "status" => "succeeded",
                        "exit_code" => 0
                      }},
                     1000
    end
  end

  describe "loop_exited" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "broadcasts terminal_ended on PubSub", %{
      socket: socket,
      workspace: workspace,
      user: user
    } do
      Algedonia.Factory.insert_membership!(workspace, user)

      loop_id = Ecto.UUID.generate()
      Phoenix.PubSub.subscribe(Algedonia.PubSub, Topics.terminal(workspace.id, loop_id))

      ref =
        push(socket, "loop_exited", %{
          "loop_id" => loop_id,
          "exit_code" => 0,
          "workspace_slug" => workspace.slug
        })

      refute_reply ref, _

      assert_receive {:terminal_ended, ^loop_id, 0}, 1000
    end
  end

  describe "attempt_complete" do
    setup %{socket: socket, user: user} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket, user: user}
    end

    test "routes hook loop completion to HookExecutor", %{
      socket: socket,
      user: user,
      workspace: workspace
    } do
      Algedonia.Factory.insert_membership!(workspace, user)

      ticket =
        Algedonia.Factory.insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})

      loop =
        Algedonia.Factory.insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: workspace.id,
          role: :hook,
          status: :running
        })

      ref =
        push(socket, "attempt_complete", %{
          "loop_id" => loop.id,
          "role" => "hook",
          "workspace_slug" => workspace.slug,
          "ticket_id" => ticket.id,
          "exit_code" => 0,
          "session_id" => "hook-1"
        })

      refute_reply ref, _
      assert Algedonia.Loops.get_loop!(loop.id).status == :passed
      assert Algedonia.Tickets.get_ticket!(ticket.id).status == :in_progress
    end
  end

  describe "error" do
    setup %{socket: socket, user: user} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket, user: user}
    end

    test "routes unknown maker/checker loop errors to TaskLoopOrchestrator", %{
      socket: socket,
      user: user,
      workspace: workspace
    } do
      Algedonia.Factory.insert_membership!(workspace, user)

      ref =
        push(socket, "error", %{
          "loop_id" => "22222222-2222-4222-8222-222222222222",
          "role" => "maker",
          "workspace_slug" => workspace.slug,
          "ticket_id" => "88888888-8888-4888-8888-888888888888",
          "message" => "something went wrong"
        })

      refute_reply ref, _
    end

    test "routes maker loop errors to TaskLoopOrchestrator", %{
      socket: socket,
      user: user,
      workspace: workspace
    } do
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
      Algedonia.Factory.insert_membership!(workspace, user)

      ticket =
        Algedonia.Factory.insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})

      loop =
        Algedonia.Factory.insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: workspace.id,
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
          "role" => "maker",
          "workspace_slug" => workspace.slug,
          "ticket_id" => ticket.id,
          "message" => "agent exited with code 2",
          "exit_code" => 2,
          "session_id" => "maker-1"
        })

      refute_reply ref, _
      assert_receive {:orch_push, @daemon_name, ^loop_id, %{"role" => "maker"}}, 1000
      assert loop_id == loop.id
      assert Algedonia.Loops.get_loop!(loop.id).current_attempt == 2
    end

    test "routes hook loop errors to HookExecutor", %{
      socket: socket,
      user: user,
      workspace: workspace
    } do
      Algedonia.Factory.insert_membership!(workspace, user)

      ticket =
        Algedonia.Factory.insert_ticket!(%{workspace_id: workspace.id, status: :in_progress})

      loop =
        Algedonia.Factory.insert_loop!(%{
          ticket_id: ticket.id,
          workspace_id: workspace.id,
          role: :hook,
          status: :running
        })

      ref =
        push(socket, "error", %{
          "loop_id" => loop.id,
          "role" => "hook",
          "workspace_slug" => workspace.slug,
          "ticket_id" => ticket.id,
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
        "33333333-3333-4333-8333-333333333333",
        "aGVsbG8="
      )

      assert_push "stdin_input", %{
        "loop_id" => "33333333-3333-4333-8333-333333333333",
        "data" => "aGVsbG8="
      }
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
        "44444444-4444-4444-8444-444444444444",
        %{
          "role" => "maker",
          "agent_type" => "claude_code",
          "task" => "Run task",
          "workspace_slug" => "my-workspace",
          "ticket_id" => "55555555-5555-4555-8555-555555555555",
          "ticket_type" => "feature",
          "ticket_code" => "ALG-555",
          "worktree_bootstrap_script" => "scripts/bootstrap.sh"
        }
      )

      assert_push "start_loop", %{
        "loop_id" => "44444444-4444-4444-8444-444444444444",
        "role" => "maker",
        "agent_type" => "claude_code",
        "task" => "Run task",
        "workspace_slug" => "my-workspace",
        "ticket_id" => "55555555-5555-4555-8555-555555555555",
        "ticket_type" => "feature",
        "ticket_code" => "ALG-555",
        "worktree_bootstrap_script" => "scripts/bootstrap.sh"
      }
    end
  end

  describe "poll_review_pr push" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "forwards poll_review_pr broadcast to daemon", %{socket: _socket} do
      AlgedoniaWeb.DaemonChannel.push_poll_review_pr(
        @daemon_id,
        "88888888-8888-4888-8888-888888888888",
        %{
          "workspace_slug" => "my-workspace",
          "ticket_id" => "99999999-9999-4999-8999-999999999999",
          "pr_number" => 42
        }
      )

      assert_push "poll_review_pr", %{
        "loop_id" => "88888888-8888-4888-8888-888888888888",
        "workspace_slug" => "my-workspace",
        "ticket_id" => "99999999-9999-4999-8999-999999999999",
        "pr_number" => 42
      }
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
        "66666666-6666-4666-8666-666666666666",
        "my-workspace"
      )

      assert_push "cleanup_worktree", %{
        "ticket_id" => "66666666-6666-4666-8666-666666666666",
        "workspace_slug" => "my-workspace"
      }
    end
  end

  describe "run_workspace_script push" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "forwards run_workspace_script broadcast to daemon", %{socket: _socket} do
      run_id = Ecto.UUID.generate()
      ticket_id = Ecto.UUID.generate()

      AlgedoniaWeb.DaemonChannel.push_run_workspace_script(@daemon_id, %{
        "run_id" => run_id,
        "workspace_slug" => "my-workspace",
        "ticket_id" => ticket_id,
        "worktree_run_script" => "bin/verify"
      })

      assert_push "run_workspace_script", %{
        "run_id" => ^run_id,
        "workspace_slug" => "my-workspace",
        "ticket_id" => ^ticket_id,
        "worktree_run_script" => "bin/verify"
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
        "77777777-7777-4777-8777-777777777777",
        "editor-workspace"
      )

      assert_push "open_editor", %{
        "ticket_id" => "77777777-7777-4777-8777-777777777777",
        "workspace_slug" => "editor-workspace"
      }
    end

    test "forwards open_editor broadcast with source_path payload", %{socket: _socket} do
      AlgedoniaWeb.DaemonChannel.push_open_editor(
        @daemon_id,
        "editor-workspace",
        %{"source_path" => ".algedonia/skills/checkpoint/SKILL.md"}
      )

      assert_push "open_editor", %{
        "source_path" => ".algedonia/skills/checkpoint/SKILL.md",
        "workspace_slug" => "editor-workspace"
      }
    end
  end
end
