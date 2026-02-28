defmodule AlgedoniaWeb.DagLive.Show do
  @moduledoc """
  LiveView for visualizing a ticket's DAG of maker-checker loops.
  """
  use AlgedoniaWeb, :live_view
  use AlgedoniaWeb.WorkspaceLive.NewWorkspaceModal

  alias Algedonia.{Dags, Tickets}

  @status_colors %{
    pending: "#6B7280",
    ready: "#9CA3AF",
    assigned: "#93C5FD",
    running_maker: "#3B82F6",
    running_checker: "#EAB308",
    passed: "#22C55E",
    failed: "#EF4444",
    escalated: "#F97316",
    needs_clarification: "#A855F7",
    pending_approval: "#14B8A6",
    skipped: "#9CA3AF",
    resolved: "#86EFAC"
  }

  @friendly_statuses %{
    passed: "Completed",
    failed: "Failed",
    running_maker: "Running (Maker)",
    running_checker: "Running (Checker)",
    needs_clarification: "Needs Clarification",
    pending_approval: "Pending Approval"
  }

  @impl true
  def mount(%{"ticket_ref" => ticket_ref}, _session, socket) do
    ticket = Tickets.get_ticket_by_ref!(socket.assigns.current_workspace.id, ticket_ref)
    ticket_id = ticket.id

    if connected?(socket) do
      Dags.subscribe(ticket_id)
    end

    socket =
      socket
      |> assign(page_title: "DAG - #{ticket.title}", ticket: ticket)
      |> load_dag_data(ticket_id)

    {:ok, socket}
  end

  @impl true
  def handle_info({event, _}, socket)
      when event in [:dag_created, :dag_updated, :loop_status_changed] do
    socket = load_dag_data(socket, socket.assigns.ticket.id)

    if socket.assigns.graph_data do
      {:noreply, push_event(socket, "dag_render", socket.assigns.graph_data)}
    else
      {:noreply, socket}
    end
  end

  defp load_dag_data(socket, ticket_id) do
    dag = Dags.get_dag_by_ticket(ticket_id)

    if dag do
      loops = Dags.list_loops_for_dag(dag.id)
      deps = Dags.list_dependencies_for_dag(dag.id)
      graph_data = build_graph_data(loops, deps)
      assign(socket, dag: dag, loops: loops, dependencies: deps, graph_data: graph_data)
    else
      assign(socket, dag: nil, loops: [], dependencies: [], graph_data: nil)
    end
  end

  @doc false
  def status_color(status), do: Map.get(@status_colors, status, "#6B7280")

  @doc false
  def friendly_status(status),
    do: Map.get(@friendly_statuses, status, status |> to_string() |> String.capitalize())

  @doc false
  def build_graph_data(loops, deps) do
    nodes =
      Enum.map(loops, fn loop ->
        %{
          id: loop.id,
          title: loop.title,
          status: to_string(loop.status),
          status_label: friendly_status(loop.status),
          role: to_string(loop.role),
          color: Map.get(@status_colors, loop.status, "#6B7280")
        }
      end)

    edges =
      Enum.map(deps, fn dep ->
        %{from: dep.upstream_loop_id, to: dep.downstream_loop_id}
      end)

    %{nodes: nodes, edges: edges}
  end
end
