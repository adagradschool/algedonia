defmodule Algedonia.TrackerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Algedonia.Tracker

  describe "adapter_for/1" do
    test "defaults to NoOp" do
      assert Tracker.adapter_for(%{}) == Algedonia.Tracker.NoOp
    end
  end

  describe "notify_create/2" do
    test "returns :ok with NoOp adapter" do
      assert :ok = Tracker.notify_create(%{}, %{title: "test"})
    end
  end

  describe "notify_update/3" do
    test "returns :ok with NoOp adapter" do
      assert :ok = Tracker.notify_update(%{}, "id", %{title: "updated"})
    end
  end

  describe "notify_delete/2" do
    test "returns :ok with NoOp adapter" do
      assert :ok = Tracker.notify_delete(%{}, "id")
    end
  end

  describe "notify_status/3" do
    test "returns :ok with NoOp adapter" do
      assert :ok = Tracker.notify_status(%{}, "id", :in_progress)
    end
  end

  describe "error logging" do
    test "logs warning when adapter returns error" do
      defmodule FailingAdapter do
        @behaviour Algedonia.Tracker

        def create_ticket(_, _), do: {:error, :boom}
        def update_ticket(_, _, _), do: {:error, :boom}
        def delete_ticket(_, _), do: {:error, :boom}
        def sync_status(_, _, _), do: {:error, :boom}
      end

      original = Application.get_env(:algedonia, :tracker_adapter)
      Application.put_env(:algedonia, :tracker_adapter, FailingAdapter)

      on_exit(fn ->
        if original do
          Application.put_env(:algedonia, :tracker_adapter, original)
        else
          Application.delete_env(:algedonia, :tracker_adapter)
        end
      end)

      log = capture_log(fn -> Tracker.notify_create(%{}, %{}) end)
      assert log =~ "Tracker.create_ticket failed"

      log = capture_log(fn -> Tracker.notify_update(%{}, "id", %{}) end)
      assert log =~ "Tracker.update_ticket failed"

      log = capture_log(fn -> Tracker.notify_delete(%{}, "id") end)
      assert log =~ "Tracker.delete_ticket failed"

      log = capture_log(fn -> Tracker.notify_status(%{}, "id", :done) end)
      assert log =~ "Tracker.sync_status failed"
    end
  end
end
