defmodule AlgedoniaWeb.ErrorJSONTest do
  use AlgedoniaWeb.ConnCase, async: true

  test "renders 404" do
    assert AlgedoniaWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert AlgedoniaWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
