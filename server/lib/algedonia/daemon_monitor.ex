defmodule Algedonia.DaemonMonitor do
  @moduledoc """
  Periodic health checker for daemon registrations.
  Marks daemons as unhealthy or offline based on heartbeat staleness.
  """
  use GenServer

  alias Algedonia.Daemons

  @check_interval_ms 10_000
  @unhealthy_threshold_s 90
  @offline_threshold_s 300

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    check_daemons()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end

  defp check_daemons do
    now = DateTime.utc_now()

    for daemon <- Daemons.list_daemons(),
        daemon.status in [:online, :unhealthy] do
      staleness = DateTime.diff(now, daemon.last_heartbeat_at, :second)

      cond do
        staleness >= @offline_threshold_s ->
          Daemons.mark_offline(daemon)

        staleness >= @unhealthy_threshold_s && daemon.status == :online ->
          Daemons.mark_unhealthy(daemon)

        true ->
          :ok
      end
    end
  end
end
