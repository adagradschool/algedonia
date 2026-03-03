defmodule AlgedoniaWeb.OnboardingLiveTest do
  use AlgedoniaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Algedonia.Factory

  test "creating a workspace with a duplicate slug shows error instead of crashing", %{conn: conn} do
    user = insert_user!()
    insert_workspace!(%{name: "My Project", slug: "my-project"})

    {:ok, lv, _html} =
      conn
      |> init_test_session(%{user_id: user.id})
      |> live(~p"/onboarding")

    html =
      lv
      |> form("form", workspace: %{name: "My Project"})
      |> render_submit()

    assert html =~ "Could not create workspace"
  end

  test "creating a workspace advances to daemon step", %{conn: conn} do
    user = insert_user!()

    {:ok, lv, _html} =
      conn
      |> init_test_session(%{user_id: user.id})
      |> live(~p"/onboarding")

    html =
      lv
      |> form("form", workspace: %{name: "Fresh Workspace"})
      |> render_submit()

    assert html =~ "Connect your machine"
  end

  test "user with workspace and no tickets resumes at daemon step", %{conn: conn} do
    user = insert_user!()
    workspace = insert_workspace!(%{name: "Existing", slug: "existing"})
    insert_membership!(workspace, user)

    {:ok, _lv, html} =
      conn
      |> init_test_session(%{user_id: user.id})
      |> live(~p"/onboarding")

    assert html =~ "Connect your machine"
  end

  test "user with workspace and tickets redirects to tickets", %{conn: conn} do
    user = insert_user!()
    workspace = insert_workspace!(%{name: "Existing", slug: "existing"})
    insert_membership!(workspace, user)
    insert_ticket!(%{workspace_id: workspace.id, title: "A ticket"})

    {:error, {:live_redirect, %{to: path}}} =
      conn
      |> init_test_session(%{user_id: user.id})
      |> live(~p"/onboarding")

    assert path =~ "/w/existing/tickets"
  end
end
