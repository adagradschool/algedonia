defmodule AlgedoniaWeb.DagLiveTest do
  use AlgedoniaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Algedonia.Factory

  describe "DagLive.Show" do
    test "renders graph container when DAG exists", %{conn: conn} do
      dag = insert_dag!()
      insert_loop!(%{dag_id: dag.id, title: "Setup env"})
      insert_loop!(%{dag_id: dag.id, title: "Write code"})

      {:ok, _view, html} = live(conn, ~p"/dags/#{dag.ticket_id}")

      assert html =~ "dag-graph"
      assert html =~ "Setup env"
      assert html =~ "Write code"
    end

    test "shows decomposition in progress when ticket is decomposing", %{conn: conn} do
      ticket = insert_ticket!(%{status: :decomposing})

      {:ok, _view, html} = live(conn, ~p"/dags/#{ticket.id}")

      assert html =~ "Decomposition in progress"
    end

    test "shows no DAG message for backlog ticket", %{conn: conn} do
      ticket = insert_ticket!(%{status: :backlog})

      {:ok, _view, html} = live(conn, ~p"/dags/#{ticket.id}")

      assert html =~ "No DAG available"
    end

    test "lists loops with status and links", %{conn: conn} do
      dag = insert_dag!()
      loop = insert_loop!(%{dag_id: dag.id, title: "Test loop", status: :running_maker})

      {:ok, _view, html} = live(conn, ~p"/dags/#{dag.ticket_id}")

      assert html =~ "Test loop"
      assert html =~ "running_maker"
      assert html =~ "/loops/#{loop.id}"
    end

    test "updates on PubSub dag_created", %{conn: conn} do
      ticket = insert_ticket!(%{status: :decomposing})

      {:ok, view, html} = live(conn, ~p"/dags/#{ticket.id}")
      assert html =~ "Decomposition in progress"

      # Create a DAG externally
      dag = insert_dag!(%{ticket_id: ticket.id})
      insert_loop!(%{dag_id: dag.id, title: "New loop"})

      # Broadcast dag_created
      dag = Algedonia.Repo.preload(dag, :loops)
      Phoenix.PubSub.broadcast(Algedonia.PubSub, "dag:#{ticket.id}", {:dag_created, dag})

      assert render(view) =~ "New loop"
    end

    test "shows back link to ticket", %{conn: conn} do
      dag = insert_dag!()
      insert_loop!(%{dag_id: dag.id, title: "A loop"})

      {:ok, _view, html} = live(conn, ~p"/dags/#{dag.ticket_id}")

      assert html =~ "/tickets/#{dag.ticket_id}"
    end
  end
end
