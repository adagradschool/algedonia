defmodule Algedonia.Tracker.NoOpTest do
  use ExUnit.Case, async: true

  alias Algedonia.Tracker.NoOp

  describe "create_ticket/2" do
    test "returns {:ok, %{}}" do
      assert {:ok, %{}} = NoOp.create_ticket(%{}, %{title: "test"})
    end
  end

  describe "update_ticket/3" do
    test "returns {:ok, %{}}" do
      assert {:ok, %{}} = NoOp.update_ticket(%{}, "some-id", %{title: "updated"})
    end
  end

  describe "delete_ticket/2" do
    test "returns :ok" do
      assert :ok = NoOp.delete_ticket(%{}, "some-id")
    end
  end

  describe "sync_status/3" do
    test "returns :ok" do
      assert :ok = NoOp.sync_status(%{}, "some-id", :in_progress)
    end
  end
end
