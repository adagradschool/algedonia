defmodule AlgedoniaWeb.DaemonChannelTest do
  use AlgedoniaWeb.ChannelCase

  alias AlgedoniaWeb.DaemonSocket

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
    test "succeeds with matching daemon_id", %{socket: socket} do
      assert {:ok, %{status: "ok"}, _socket} =
               subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})
    end

    test "fails with mismatched daemon_id", %{socket: socket} do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "daemon:wrong-id", %{})
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

  describe "heartbeat" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "updates heartbeat with payload", %{socket: socket} do
      ref = push(socket, "heartbeat", %{"capacity" => 5, "running_loops" => 1})
      assert_reply ref, :ok
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

  describe "loop_result" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "routes loop_result to Orchestrator", %{socket: socket} do
      # The Orchestrator will return :not_found since there's no active decomposition,
      # but the message is still routed correctly (no crash)
      ref =
        push(socket, "loop_result", %{
          "loop_id" => "nonexistent-loop",
          "verdict" => "pass"
        })

      refute_reply ref, _
    end
  end

  describe "error" do
    setup %{socket: socket} do
      {:ok, _reply, socket} =
        subscribe_and_join(socket, "daemon:#{@daemon_id}", %{})

      {:ok, socket: socket}
    end

    test "routes error to Orchestrator", %{socket: socket} do
      ref =
        push(socket, "error", %{
          "loop_id" => "nonexistent-loop",
          "message" => "something went wrong"
        })

      refute_reply ref, _
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
end
