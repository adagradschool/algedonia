defmodule AlgedoniaWeb.HelpersTest do
  use ExUnit.Case, async: true

  alias AlgedoniaWeb.Helpers

  describe "aggregate_daemon_status/1" do
    test "returns offline when list is empty" do
      assert Helpers.aggregate_daemon_status([]) == :offline
    end

    test "prioritizes online over unhealthy and offline" do
      assert Helpers.aggregate_daemon_status([:offline, :unhealthy, :online]) == :online
    end

    test "returns unhealthy when no daemon is online but at least one is unhealthy" do
      assert Helpers.aggregate_daemon_status([%{status: :offline}, %{status: :unhealthy}]) ==
               :unhealthy
    end
  end
end
