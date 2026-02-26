defmodule AlgedoniaWeb.Api.WorkspaceController do
  use AlgedoniaWeb, :controller

  alias Algedonia.Accounts

  def index(conn, _params) do
    user = conn.assigns.current_user
    workspaces = Accounts.list_workspaces_for_user(user.id)

    json(conn, %{
      workspaces:
        Enum.map(workspaces, fn w ->
          %{id: w.id, name: w.name, slug: w.slug, prefix: w.prefix}
        end)
    })
  end
end
