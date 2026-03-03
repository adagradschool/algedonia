#!/usr/bin/env bash
# Creates GitHub issues for each software optimization finding.
# Run from repo root: ./scripts/create-optimization-issues.sh
#
# Requires: gh CLI authenticated (gh auth login)

set -euo pipefail

REPO="adagradschool/algedonia"
LABEL="performance"

# Create label if it doesn't exist
gh label create "$LABEL" --description "Performance optimizations" --color "D4C5F9" -R "$REPO" 2>/dev/null || true

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: incremental ticket board updates instead of full re-query" \
  --body "$(cat <<'EOF'
## Problem

Every `ticket_created`, `ticket_updated`, or `ticket_deleted` PubSub broadcast triggers `stream_tickets()` in `TicketLive.Index`, which runs:
- `Tickets.search_tickets_grouped()` — fetches ALL tickets, groups by status, applies filters in Elixir
- `Dags.active_loop_info_for_tickets(ticket_ids)` — queries active loops for every ticket

With 5 users on the ticket board, a single ticket status change = 10 concurrent DB queries.

**File:** `server/lib/algedonia_web/live/ticket_live/index.ex:149-151`

## Fix

Use the broadcast payload for incremental `stream_insert`/`stream_delete`. Only full re-query on mount or filter change.

```elixir
def handle_info({:ticket_created, ticket}, socket) do
  {:noreply, stream_insert(socket, stream_name(ticket.status), ticket)}
end

def handle_info({:ticket_updated, ticket}, socket) do
  socket =
    socket
    |> stream_delete_by_dom_id(ticket_dom_id(ticket))
    |> stream_insert(stream_name(ticket.status), ticket)
  {:noreply, socket}
end

def handle_info({:ticket_deleted, ticket}, socket) do
  {:noreply, stream_delete(socket, stream_name(ticket.status), ticket)}
end
```

## Impact

Eliminates 2 DB queries × N connected users per ticket change. Biggest single optimization.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: batch fallback loop query in active_loop_info_for_tickets" \
  --body "$(cat <<'EOF'
## Problem

The fallback branch in `active_loop_info_for_tickets` calls `Loops.get_loop(lid)` inside a `Map.new` — one DB query per ticket that has no active loop. With 30 completed tickets, that's 30 individual SELECT queries.

**File:** `server/lib/algedonia/dags.ex:207-226`

## Fix

Batch the fallback into a single `WHERE id IN (...)` query.

```elixir
fallback_loop_ids = Map.values(fallback)
fallback_loops =
  from(l in Loop, where: l.id in ^fallback_loop_ids, select: {l.id, l})
  |> Repo.all()
  |> Map.new()

Map.new(fallback, fn {tid, lid} ->
  case Map.get(fallback_loops, lid) do ...
end)
```

## Impact

Up to N individual SELECTs → 1 query.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: use broadcast payload in DagLive instead of re-querying" \
  --body "$(cat <<'EOF'
## Problem

When `{:dag_updated, dag}` or `{:loop_status_changed, loop}` arrives, `DagLive.Show` calls `load_dag_data()` which runs 3 queries:
- `Dags.get_dag_by_ticket(ticket_id)`
- `Dags.list_loops_for_dag(dag.id)`
- `Dags.list_dependencies_for_dag(dag.id)`

The broadcast payload already contains the data needed.

**File:** `server/lib/algedonia_web/live/dag_live/show.ex:52-54, 63-74`

## Fix

For `:loop_status_changed`, update the single loop in existing assigns instead of re-querying.

```elixir
def handle_info({:loop_status_changed, updated_loop}, socket) do
  loops =
    Enum.map(socket.assigns.loops, fn loop ->
      if loop.id == updated_loop.id, do: updated_loop, else: loop
    end)

  graph_data = build_graph_data(loops, socket.assigns.dependencies)

  {:noreply,
   socket
   |> assign(:loops, loops)
   |> assign(:graph_data, graph_data)
   |> push_event("dag_render", graph_data)}
end
```

Only full re-query on structural changes (`:dag_created`).

## Impact

3 queries per loop status change → 0.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: stop re-querying all daemons on every heartbeat in MonitorLive" \
  --body "$(cat <<'EOF'
## Problem

Every `daemon_heartbeat` (every 10s per daemon) and `daemon_status_changed` triggers `Daemons.list_daemons() |> length()` — a full table load just to compute a count. With 5 daemons, that's ~3 full-table queries per second in steady state.

**File:** `server/lib/algedonia_web/live/monitor_live/index.ex:25-36`

## Fix

Track count locally. Only re-count on status changes, not heartbeats.

```elixir
def handle_info({:daemon_status_changed, daemon}, socket) do
  {:noreply,
   socket
   |> stream_insert(:daemons, daemon)
   |> update(:daemon_count, &adjust_count(&1, daemon))}
end

def handle_info({:daemon_heartbeat, daemon}, socket) do
  {:noreply, stream_insert(socket, :daemons, daemon)}
end
```

## Impact

~3 queries/sec steady state → 0 in steady state.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: use comment broadcast payload instead of re-querying" \
  --body "$(cat <<'EOF'
## Problem

Both `LoopLive.Show` and `TicketLive.Index` handle `{:comment_created, comment}` by ignoring the comment payload and re-querying all comments for the ticket.

**Files:**
- `server/lib/algedonia_web/live/loop_live/show.ex:329-331`
- `server/lib/algedonia_web/live/ticket_live/index.ex:154-160`

## Fix

Use the payload for incremental updates.

```elixir
def handle_info({:comment_created, comment}, socket) do
  {:noreply, update(socket, :comments, &(&1 ++ [comment]))}
end

def handle_info({:comment_deleted, comment}, socket) do
  {:noreply, update(socket, :comments, &Enum.reject(&1, fn c -> c.id == comment.id end))}
end

def handle_info({:comment_updated, comment}, socket) do
  {:noreply,
   update(socket, :comments, fn comments ->
     Enum.map(comments, &if(&1.id == comment.id, do: comment, else: &1))
   end)}
end
```

## Impact

1 query × N users per comment event → 0.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: prune TaskLoopOrchestrator task_history on loop completion" \
  --body "$(cat <<'EOF'
## Problem

`TaskLoopOrchestrator` keeps `task_history`, `checker_handoff_repairs`, and `task_run_config` in GenServer state for every loop that has ever run. This state is never cleaned up — after 1000 loop attempts, it's several MB of dead state leaking memory.

**File:** `server/lib/algedonia/task_loop_orchestrator.ex`

## Fix

Prune state when a loop reaches a terminal state (passed/failed).

```elixir
defp cleanup_loop_state(state, loop_id) do
  state
  |> update_in([:task_history], &Map.delete(&1, loop_id))
  |> update_in([:checker_handoff_repairs], &Map.delete(&1, loop_id))
  |> update_in([:task_run_config], &Map.delete(&1, loop_id))
end
```

If history is needed after completion, persist to a `loop_steps` table on each state transition.

## Impact

Prevents unbounded memory growth in long-running instances.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: use join instead of subquery in list_dependencies_for_dag" \
  --body "$(cat <<'EOF'
## Problem

`list_dependencies_for_dag` uses a subquery to get loop IDs, then filters dependencies. A join would let Postgres use indexes more efficiently.

**File:** `server/lib/algedonia/dags.ex:305-311`

## Fix

```elixir
def list_dependencies_for_dag(dag_id) do
  from(d in LoopDependency,
    join: l in Loop, on: d.upstream_loop_id == l.id,
    where: l.dag_id == ^dag_id
  )
  |> Repo.all()
end
```

## Impact

Marginal query plan improvement.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: batch update in requeue_running_task_loops_for_daemon" \
  --body "$(cat <<'EOF'
## Problem

When a daemon disconnects, `requeue_running_task_loops_for_daemon` fetches all running loops, then individually calls `update_loop()` (1 UPDATE) + `Repo.preload(:dag)` (1 SELECT) + `PubSub.broadcast` per loop.

**File:** `server/lib/algedonia/loops.ex:167-193`

## Fix

Batch into a single `update_all` + single `preload`.

```elixir
def requeue_running_task_loops_for_daemon(daemon_id) do
  {_count, loops} =
    from(l in Loop,
      where: l.assigned_daemon_id == ^daemon_id and l.role == :task and
             l.status in [:running_maker, :running_checker],
      select: l
    )
    |> Repo.update_all(set: [status: :pending, assigned_daemon_id: nil])

  loops = Repo.preload(loops, dag: :ticket)

  Enum.each(loops, fn loop ->
    PubSub.broadcast(Algedonia.PubSub, "dag:#{loop.dag.ticket_id}", {:loop_status_changed, loop})
  end)

  loops
end
```

## Impact

N updates + N preloads → 1 update_all + 1 preload.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: cache workspace slug in hook_executor instead of re-fetching per hook" \
  --body "$(cat <<'EOF'
## Problem

`dispatch_hook_loop` calls `Workspaces.get_workspace!(ticket.workspace_id).slug` for every hook execution, even though the workspace is the same for all hooks on the same ticket.

**File:** `server/lib/algedonia/hook_executor.ex:135-138`

## Fix

Fetch workspace once in `fire_hooks` and pass the slug through to `dispatch_hook_loop`.

## Impact

1 query per hook → 1 query total per ticket transition.
EOF
)"

gh issue create -R "$REPO" --label "$LABEL" \
  --title "perf: use Repo.aggregate for counts instead of list |> length()" \
  --body "$(cat <<'EOF'
## Problem

Several places load all records into memory just to count them:
- `OnboardingLive`: `Tickets.list_tickets(workspace_id: ...) |> length()`
- `MonitorLive.Index`: `Daemons.list_daemons() |> length()`

**Files:**
- `server/lib/algedonia_web/live/onboarding_live.ex`
- `server/lib/algedonia_web/live/monitor_live/index.ex`

## Fix

Add count functions using `Repo.aggregate`.

```elixir
def count_tickets(opts) do
  Ticket
  |> filter_by_workspace(Keyword.get(opts, :workspace_id))
  |> Repo.aggregate(:count)
end

def count_daemons do
  Repo.aggregate(DaemonRegistration, :count)
end
```

## Impact

Full table load → single `SELECT COUNT(*)`.
EOF
)"

echo ""
echo "Done! Created 10 issues."
