defmodule Algedonia.Terminals.TerminalBufferTest do
  use ExUnit.Case, async: true

  alias Algedonia.Terminals.TerminalBuffer

  setup do
    loop_id = "test-buffer-#{System.unique_integer([:positive])}"
    {:ok, pid} = TerminalBuffer.start_link(loop_id)
    %{pid: pid, loop_id: loop_id}
  end

  test "append and get_scrollback", %{pid: pid} do
    TerminalBuffer.append(pid, "line1\nline2")
    scrollback = TerminalBuffer.get_scrollback(pid)
    assert scrollback == "line1\nline2"
  end

  test "scrollback accumulates", %{pid: pid} do
    TerminalBuffer.append(pid, "first")
    TerminalBuffer.append(pid, "second")
    scrollback = TerminalBuffer.get_scrollback(pid)
    assert scrollback =~ "first"
    assert scrollback =~ "second"
  end

  test "broadcasts on PubSub", %{pid: pid, loop_id: loop_id} do
    Phoenix.PubSub.subscribe(Algedonia.PubSub, "terminal:#{loop_id}")

    TerminalBuffer.append(pid, "hello")

    assert_receive {:terminal_data, ^loop_id, "hello"}, 1000
  end

  test "caps at max lines", %{pid: pid} do
    # Write more than 10,000 lines
    big_data = Enum.map_join(1..10_005, "\n", &"line#{&1}")
    TerminalBuffer.append(pid, big_data)

    scrollback = TerminalBuffer.get_scrollback(pid)
    lines = String.split(scrollback, "\n")
    assert length(lines) <= 10_000
  end

  test "terminal_ended schedules cleanup", %{pid: pid} do
    ref = Process.monitor(pid)
    send(pid, :terminal_ended)
    # Buffer should still be alive immediately
    assert Process.alive?(pid)

    # Send cleanup directly to test it works
    send(pid, :cleanup)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
  end
end
