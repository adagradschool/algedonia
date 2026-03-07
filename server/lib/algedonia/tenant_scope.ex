defmodule Algedonia.TenantScope do
  @moduledoc """
  Central workspace scoping utility for tenant data.

  Stores the current workspace_id in the process dictionary so that
  `Repo.prepare_query/3` can auto-filter tenant table queries. Request-boundary
  code (plugs, on_mount hooks) calls `put_workspace/1` to establish scope.
  """

  @workspace_key :algedonia_current_workspace_id

  @spec put_workspace(binary()) :: binary() | nil
  def put_workspace(workspace_id) when is_binary(workspace_id) do
    Process.put(@workspace_key, workspace_id)
  end

  @spec get_workspace() :: binary() | nil
  def get_workspace, do: Process.get(@workspace_key)

  @spec clear_workspace() :: binary() | nil
  def clear_workspace, do: Process.delete(@workspace_key)
end
