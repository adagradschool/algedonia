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

  @doc """
  Runs a function under a workspace scope and restores the prior scope after.
  """
  @spec with_workspace(binary(), (-> result)) :: result when result: var
  def with_workspace(workspace_id, fun) when is_binary(workspace_id) and is_function(fun, 0) do
    previous = get_workspace()
    put_workspace(workspace_id)

    try do
      fun.()
    after
      restore_workspace(previous)
    end
  end

  defp restore_workspace(nil), do: clear_workspace()
  defp restore_workspace(workspace_id), do: put_workspace(workspace_id)
end
