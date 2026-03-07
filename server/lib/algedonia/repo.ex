defmodule Algedonia.Repo do
  @moduledoc """
  Repo with automatic workspace scoping for tenant isolation.

  Queries against tenant tables (`tickets`, `loops`, `queue_entries`, `events`)
  are automatically filtered by the workspace stored in the process dictionary
  via `Algedonia.TenantScope`. Pass `skip_workspace_scope: true` to bypass.

  Transactions automatically call `SET LOCAL app.workspace_id` when a workspace
  is set in TenantScope, bridging Ecto-level scoping to PostgreSQL RLS.
  """
  use Ecto.Repo,
    otp_app: :algedonia,
    adapter: Ecto.Adapters.Postgres

  require Logger

  @tenant_sources ~w(tickets loops queue_entries events)

  @impl true
  def default_options(_operation), do: []

  @impl true
  def prepare_query(_operation, query, opts) do
    if opts[:skip_workspace_scope] do
      {query, opts}
    else
      case Algedonia.TenantScope.get_workspace() do
        nil ->
          maybe_warn_unscoped(query)
          {query, opts}

        workspace_id ->
          {scope_query(query, workspace_id), opts}
      end
    end
  end

  @impl true
  def prepare_transaction(fun, opts) do
    case Algedonia.TenantScope.get_workspace() do
      workspace_id when is_binary(workspace_id) ->
        wrapped = fn ->
          set_local_workspace_id!(workspace_id)
          fun.()
        end

        {wrapped, opts}

      _ ->
        {fun, opts}
    end
  end

  defp scope_query(%Ecto.Query{from: %{source: {source, _}}} = query, workspace_id)
       when source in @tenant_sources do
    import Ecto.Query
    where(query, [r], r.workspace_id == ^workspace_id)
  end

  defp scope_query(query, _workspace_id), do: query

  defp maybe_warn_unscoped(%Ecto.Query{from: %{source: {source, _}}})
       when source in @tenant_sources do
    Logger.warning("Unscoped query on tenant table #{source} — TenantScope not set")
  end

  defp maybe_warn_unscoped(_query), do: :ok

  @doc """
  Sets `app.workspace_id` for the current transaction scope.

  Uses Ecto.UUID.cast validation to prevent SQL injection. The UUID is
  interpolated into the SET statement because PostgreSQL SET does not support
  parameterized values ($1), but Ecto.UUID.cast guarantees the value matches
  the strict UUID format `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
  """
  @spec set_local_workspace_id!(binary()) :: any()
  def set_local_workspace_id!(workspace_id) when is_binary(workspace_id) do
    case Ecto.UUID.cast(workspace_id) do
      {:ok, _} ->
        query!("SET LOCAL app.workspace_id = '#{workspace_id}'")

      :error ->
        raise ArgumentError, "invalid workspace_id"
    end
  end
end
