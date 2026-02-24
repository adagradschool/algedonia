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

  test "creating a workspace succeeds and redirects", %{conn: conn} do
    user = insert_user!()

    {:ok, lv, _html} =
      conn
      |> init_test_session(%{user_id: user.id})
      |> live(~p"/onboarding")

    lv
    |> form("form", workspace: %{name: "Fresh Workspace"})
    |> render_submit()

    {path, _flash} = assert_redirect(lv)
    assert path =~ "/w/fresh-workspace/tickets"
  end
end
