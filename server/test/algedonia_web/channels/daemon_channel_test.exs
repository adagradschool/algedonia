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
end
