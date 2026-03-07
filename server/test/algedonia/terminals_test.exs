defmodule Algedonia.TerminalsTest do
  use ExUnit.Case, async: true

  alias Algedonia.Terminals

  defp unique_loop_id do
    Ecto.UUID.generate()
  end

  test "start_buffer/1 creates a buffer" do
    loop_id = unique_loop_id()
    assert {:ok, _pid} = Terminals.start_buffer(loop_id)
    assert Terminals.active?(loop_id)
  end

  test "start_buffer/1 is idempotent" do
    loop_id = unique_loop_id()
    assert {:ok, pid1} = Terminals.start_buffer(loop_id)
    assert {:ok, pid2} = Terminals.start_buffer(loop_id)
    assert pid1 == pid2
  end

  test "append/2 auto-starts buffer" do
    loop_id = unique_loop_id()
    refute Terminals.active?(loop_id)
    Terminals.append(loop_id, "hello")
    assert Terminals.active?(loop_id)
  end

  test "get_scrollback/1 returns empty string for unknown loop" do
    assert Terminals.get_scrollback("ffffffff-ffff-4fff-8fff-ffffffffffff") == ""
  end

  test "append and get_scrollback round-trip" do
    loop_id = unique_loop_id()
    Terminals.append(loop_id, "data1")
    Terminals.append(loop_id, "data2")
    scrollback = Terminals.get_scrollback(loop_id)
    assert scrollback =~ "data1"
    assert scrollback =~ "data2"
  end

  test "subscribe/1 receives terminal_data" do
    loop_id = unique_loop_id()
    Terminals.subscribe(loop_id)
    Terminals.append(loop_id, "subscribed")
    assert_receive {:terminal_data, ^loop_id, "subscribed"}, 1000
  end

  test "stop_buffer/1 removes buffer" do
    loop_id = unique_loop_id()
    {:ok, pid} = Terminals.start_buffer(loop_id)
    assert Terminals.active?(loop_id)
    ref = Process.monitor(pid)
    Terminals.stop_buffer(loop_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

    # Poll until Registry catches up (avoids flaky sleep)
    assert_eventually(fn -> not Terminals.active?(loop_id) end)
  end

  defp assert_eventually(fun, retries \\ 20) do
    if fun.() do
      :ok
    else
      if retries > 0 do
        Process.sleep(5)
        assert_eventually(fun, retries - 1)
      else
        flunk("condition never became true")
      end
    end
  end

  test "active?/1 returns false for unknown loop" do
    refute Terminals.active?("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
  end
end
