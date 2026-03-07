defmodule Algedonia.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Algedonia.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Algedonia.TenantScope
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Algedonia.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Algedonia.DataCase
    end
  end

  setup tags do
    Algedonia.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    TenantScope.clear_workspace()
    pid = Sandbox.start_owner!(Algedonia.Repo, shared: not tags[:async])

    on_exit(fn ->
      TenantScope.clear_workspace()
      Sandbox.stop_owner(pid)
    end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Sets TenantScope to the given workspace (struct with `:id` or binary UUID).

  Returns the previous workspace scope so callers can restore it.
  """
  def put_workspace_scope(workspace_or_id) do
    previous = TenantScope.get_workspace()
    TenantScope.put_workspace(workspace_id!(workspace_or_id))
    previous
  end

  @doc """
  Restores TenantScope from a value previously returned by `put_workspace_scope/1`.
  """
  def restore_workspace_scope(nil), do: TenantScope.clear_workspace()

  def restore_workspace_scope(workspace_id) when is_binary(workspace_id),
    do: TenantScope.put_workspace(workspace_id)

  @doc """
  Runs `fun` under the given workspace TenantScope and restores prior scope after.
  """
  def with_workspace_scope(workspace_or_id, fun) when is_function(fun, 0) do
    previous = put_workspace_scope(workspace_or_id)

    try do
      fun.()
    after
      restore_workspace_scope(previous)
    end
  end

  @doc """
  Clears TenantScope for the current process.
  """
  def clear_workspace_scope, do: TenantScope.clear_workspace()

  defp workspace_id!(%{id: workspace_id}) when is_binary(workspace_id), do: workspace_id
  defp workspace_id!(workspace_id) when is_binary(workspace_id), do: workspace_id

  defp workspace_id!(value) do
    raise ArgumentError,
          "workspace scope must be a workspace struct with binary :id or a binary workspace_id, got: #{inspect(value)}"
  end
end
