defmodule AlgedoniaWeb.Plugs.ApiWorkspaceTest do
  use AlgedoniaWeb.ConnCase, async: true

  alias AlgedoniaWeb.Plugs.ApiWorkspace
  import Algedonia.Factory

  describe "call/2" do
    test "assigns workspace for valid slug with membership", %{user: user, workspace: workspace} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:params, %{"workspace" => workspace.slug})
        |> Plug.Conn.assign(:current_user, user)
        |> ApiWorkspace.call([])

      assert conn.assigns.workspace.id == workspace.id
      refute conn.halted
    end

    test "halts with 404 for nonexistent slug", %{user: user} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:params, %{"workspace" => "nonexistent-workspace-slug"})
        |> Plug.Conn.assign(:current_user, user)
        |> ApiWorkspace.call([])

      assert conn.halted
      assert conn.status == 404
    end

    test "halts with 404 when user has no membership", %{workspace: workspace} do
      other_user = insert_user!(%{name: "NoMember"})

      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:params, %{"workspace" => workspace.slug})
        |> Plug.Conn.assign(:current_user, other_user)
        |> ApiWorkspace.call([])

      assert conn.halted
      assert conn.status == 404
    end
  end
end
