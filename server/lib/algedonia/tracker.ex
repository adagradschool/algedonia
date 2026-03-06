defmodule Algedonia.Tracker do
  @moduledoc """
  Behaviour for bidirectional sync with external issue trackers (Linear, GitHub Issues, etc.).

  The configured adapter is called after successful local DB operations.
  Errors are logged but never fail the local operation.
  """

  @type workspace :: Algedonia.Workspaces.Workspace.t()

  @callback create_ticket(workspace, attrs :: map()) :: {:ok, map()} | {:error, term()}
  @callback update_ticket(workspace, ticket_id :: binary(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback delete_ticket(workspace, ticket_id :: binary()) :: :ok | {:error, term()}
  @callback sync_status(workspace, ticket_id :: binary(), new_status :: atom()) ::
              :ok | {:error, term()}

  require Logger

  @doc """
  Returns the configured tracker adapter for a workspace. Defaults to `Algedonia.Tracker.NoOp`.
  """
  @spec adapter_for(workspace) :: module()
  def adapter_for(_workspace) do
    Application.get_env(:algedonia, :tracker_adapter, Algedonia.Tracker.NoOp)
  end

  @doc """
  Calls the tracker adapter's `create_ticket/2`, logging errors.
  """
  @spec notify_create(workspace, map()) :: :ok
  def notify_create(workspace, attrs) do
    adapter = adapter_for(workspace)

    case adapter.create_ticket(workspace, attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> log_error(:create_ticket, reason)
    end
  end

  @doc """
  Calls the tracker adapter's `update_ticket/3`, logging errors.
  """
  @spec notify_update(workspace, binary(), map()) :: :ok
  def notify_update(workspace, ticket_id, attrs) do
    adapter = adapter_for(workspace)

    case adapter.update_ticket(workspace, ticket_id, attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> log_error(:update_ticket, reason)
    end
  end

  @doc """
  Calls the tracker adapter's `delete_ticket/2`, logging errors.
  """
  @spec notify_delete(workspace, binary()) :: :ok
  def notify_delete(workspace, ticket_id) do
    adapter = adapter_for(workspace)

    case adapter.delete_ticket(workspace, ticket_id) do
      :ok -> :ok
      {:error, reason} -> log_error(:delete_ticket, reason)
    end
  end

  @doc """
  Calls the tracker adapter's `sync_status/3`, logging errors.
  """
  @spec notify_status(workspace, binary(), atom()) :: :ok
  def notify_status(workspace, ticket_id, new_status) do
    adapter = adapter_for(workspace)

    case adapter.sync_status(workspace, ticket_id, new_status) do
      :ok -> :ok
      {:error, reason} -> log_error(:sync_status, reason)
    end
  end

  defp log_error(callback, reason) do
    Logger.warning("Tracker.#{callback} failed: #{inspect(reason)}")
    :ok
  end
end
