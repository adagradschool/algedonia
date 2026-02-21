defmodule AlgedoniaWeb.PageController do
  use AlgedoniaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
