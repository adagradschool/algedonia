defmodule Algedonia.DaemonMonitorTest do
  use Algedonia.DataCase, async: false

  alias Algedonia.DaemonMonitor
  alias Algedonia.Daemons
  alias Algedonia.Factory

  setup do
    {:ok, pid} = DaemonMonitor.start_link(name: :"monitor_#{System.unique_integer()}")
    %{monitor: pid}
  end

  describe "health checks" do
    test "marks daemon unhealthy after 90s without heartbeat", %{monitor: pid} do
      daemon =
        Factory.insert_daemon!(%{
          status: :online,
          last_heartbeat_at: DateTime.add(DateTime.utc_now(), -95, :second)
        })

      send(pid, :check)
      Process.sleep(50)

      updated = Daemons.get_daemon!(daemon.id)
      assert updated.status == :unhealthy
    end

    test "marks daemon offline after 5min without heartbeat", %{monitor: pid} do
      daemon =
        Factory.insert_daemon!(%{
          status: :online,
          last_heartbeat_at: DateTime.add(DateTime.utc_now(), -301, :second)
        })

      send(pid, :check)
      Process.sleep(50)

      updated = Daemons.get_daemon!(daemon.id)
      assert updated.status == :offline
    end

    test "marks unhealthy daemon offline after 5min total", %{monitor: pid} do
      daemon =
        Factory.insert_daemon!(%{
          status: :unhealthy,
          last_heartbeat_at: DateTime.add(DateTime.utc_now(), -301, :second)
        })

      send(pid, :check)
      Process.sleep(50)

      updated = Daemons.get_daemon!(daemon.id)
      assert updated.status == :offline
    end

    test "leaves healthy daemon alone", %{monitor: pid} do
      daemon =
        Factory.insert_daemon!(%{
          status: :online,
          last_heartbeat_at: DateTime.utc_now()
        })

      send(pid, :check)
      Process.sleep(50)

      updated = Daemons.get_daemon!(daemon.id)
      assert updated.status == :online
    end
  end
end
