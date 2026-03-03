# Hosting Evaluation

Current setup: Fly.io, `ams` region, **shared CPU / 1 vCPU / 512 MB RAM**, 2 machines minimum. Dog slow.

## Why Fly.io is slow for us

The BEAM (Erlang VM) is hungry at idle. A bare Phoenix release with a few GenServers (`Orchestrator`, `Scheduler`, `LockManager`, `CircuitBreaker`, `DaemonMonitor`) already eats 200-300 MB before any traffic. That leaves almost nothing for:

- WebSocket connections (daemon channels + LiveView sockets)
- ETS tables / process heaps under load
- Terminal output buffering and PubSub fan-out

Shared CPU compounds the problem — BEAM schedulers fight for cycles, and WebSocket latency spikes when the hypervisor throttles. This is the wrong workload for Fly's micro-VM model.

## What we actually need

| Concern | Requirement |
|---------|-------------|
| CPU | Dedicated cores (BEAM schedulers pin to cores) |
| RAM | 2 GB minimum, 4 GB comfortable |
| Network | Low-latency WebSocket, EU presence (current users) |
| Database | Managed Postgres or enough disk/RAM to self-host |
| Deployment | Docker or direct release, CI/CD friendly |
| Cost | < €40/mo for early stage |

## Options

### 1. Hetzner Cloud VPS (recommended to try first)

| Spec | Value |
|------|-------|
| Plan | CPX21 (3 vCPU AMD dedicated, 4 GB RAM, 80 GB NVMe) |
| Price | €8.49/mo |
| Region | Falkenstein / Nuremberg / Helsinki |
| Postgres | Self-host on same box (fine for now) |
| Deploy | Docker Compose or systemd + release tarball |

**Pros:**
- 5-10x the resources for 1/3 the price
- Dedicated CPU cores — no noisy neighbor throttling
- Hetzner network in EU is excellent, low latency
- Simple model: one box, ssh in, done

**Cons:**
- You own the box — updates, backups, firewall, TLS certs (use Caddy)
- No managed Postgres — you run `pg_dump` crons or use Hetzner's managed DB add-on (€11.49/mo extra for the smallest)
- No built-in zero-downtime deploy (but a Phoenix release + rolling restart is ~2s downtime, fine for now)
- Scaling later means migrating to a bigger box or adding a load balancer manually

**Quick setup sketch:**
```
# On Hetzner VPS
apt install caddy postgresql
# Deploy Phoenix release via CI (scp tarball or docker pull)
# Caddy reverse proxy handles TLS automatically
# systemd unit for the release
```

### 2. Fly.io — just scale up

| Spec | Value |
|------|-------|
| Plan | performance-2x (2 dedicated vCPU, 4 GB RAM) |
| Price | ~$62/mo per machine × 2 = ~$124/mo |
| Region | ams (keep current) |
| Postgres | Fly Postgres (already have it?) |

**Pros:**
- No migration, just change `fly.toml` and `fly scale`
- Keep existing CI/CD, managed TLS, health checks
- Multi-region later is trivial

**Cons:**
- Expensive for what you get ($124/mo vs €8.49/mo on Hetzner)
- Fly Postgres is "not managed" — it's a VM you babysit
- Still on Firecracker micro-VMs; some overhead vs bare metal

Worth trying as a quick experiment: bump to `performance-1x` ($31/mo per machine) and see if the speed issue is just resource starvation.

### 3. Railway

| Spec | Value |
|------|-------|
| Plan | Pro ($20/mo base + usage) |
| Price | ~$25-40/mo depending on traffic |
| Region | US/EU |
| Postgres | Managed, included |

**Pros:**
- Managed Postgres out of the box
- Good Docker support, GitHub deploy integration
- Simple scaling UI

**Cons:**
- Usage-based pricing can surprise you
- Less control over VM specs
- Smaller community for Elixir-specific issues
- WebSocket support exists but less battle-tested than Fly

### 4. Render

| Spec | Value |
|------|-------|
| Plan | Standard ($25/mo, 2 GB RAM) or Pro ($85/mo, 4 GB) |
| Price | $25-85/mo |
| Region | US/EU |

**Pros:**
- Managed Postgres ($7/mo starter)
- Zero-config TLS, easy deploys from Docker
- Persistent disks available

**Cons:**
- Standard plan is shared CPU (same problem as Fly)
- Pro plan gets expensive
- Cold starts on free/starter tiers
- Health check / deploy model less flexible than Fly

### 5. DigitalOcean / Vultr

Similar to Hetzner but 2-3x the price for equivalent specs. DO's managed Postgres is solid though ($15/mo). Worth considering if you want a managed DB without Hetzner's minimalist approach.

## Per-user resource footprint

Audited every LiveView, channel, GenServer, PubSub topic, and ETS table in the codebase. The architecture is lean — here's what one connected user actually costs:

### What a user creates

| Resource | Per user | Notes |
|----------|----------|-------|
| LiveView process | 1 | One BEAM process per open tab. ~2-5 KB heap. |
| PubSub subscriptions | 6-12 | 3-5 global (`"tickets"`, `"daemons"`) + per-loop (`"terminal:#{id}"`, `"loop:#{id}"`) + per-ticket (`"ticket:#{id}"`) |
| Presence ETS entries | 1 per page | Tracked per workspace page (`presence:tickets:#{slug}`, etc.) |
| Socket assigns | ~1-2 KB | Minimal — filters, IDs, state flags. Collections use streams. |
| DB pool checkout | 0-1 | Temporary from shared pool. No polling — all PubSub-driven. |

### What a user does NOT create

- No per-user GenServers. `TaskLoopOrchestrator`, `DecomposeOrchestrator`, `DaemonMonitor` are all application-level singletons.
- No per-user ETS tables. One shared `daemon_repo_status` table.
- No per-user terminal buffers. `TerminalBuffer` is per-loop (shared across all viewers of that loop), max 8 MB each, cleaned up 5 min after terminal ends.

### What a daemon creates

Each daemon (machine running the Go agent) adds:

| Resource | Per daemon | Notes |
|----------|-----------|-------|
| WebSocket channel | 1 persistent | `"daemon:#{name}"` topic, token-authenticated |
| Heartbeat writes | 1 every 10s | UPDATE `daemon_registrations.last_heartbeat_at` |
| Terminal buffers | 1 per running loop | Up to 8 MB in-memory per loop, `TerminalBuffer` GenServer |
| DB pool checkout | brief, every 10s | Heartbeat write |

Daemon capacity is capped by a `--capacity` flag (default: 3 concurrent loops).

### Scaling math

**Memory per user** (browser): ~10-50 KB (LiveView process + assigns + PubSub listener refs). Negligible.

**Memory per active loop**: up to 8 MB (terminal buffer) + orchestrator history entries. This is the real cost.

**The bottleneck is loops, not users.** 10 concurrent loops = ~80 MB of terminal buffers + CPU for PubSub broadcast fan-out. 100 users watching those same 10 loops barely registers — LiveView streams send DOM diffs, not full page state.

| Scenario | Active loops | Terminal buf. | Users watching | Est. app memory | Fits on |
|----------|-------------|---------------|----------------|-----------------|---------|
| Solo dev | 3 | 24 MB | 1 | ~400 MB total | Fly shared 512 MB (barely) |
| Small team | 5-10 | 40-80 MB | 3-5 | ~500-600 MB | Hetzner CPX21 (4 GB) easily |
| Busy team | 10-20 | 80-160 MB | 10-20 | ~700 MB-1 GB | Hetzner CPX21 still fine |
| Scale concern | 50+ | 400+ MB | 50+ | 1.5-2 GB | Hetzner CPX31 (8 GB, €15/mo) |

### Where it breaks

1. **PubSub fan-out on `"tickets"` topic.** Every ticket update broadcasts to ALL users on the ticket board, each of whom re-queries `search_tickets_grouped()`. With 50 users and frequent ticket churn, that's 50 concurrent DB queries per update. Fix: debounce or batch.

2. **TaskLoopOrchestrator `task_history` grows unbounded.** History entries for every loop attempt accumulate in GenServer state with no visible cleanup. Long-running instances will leak memory here. Fix: prune on loop completion or move to DB.

3. **Terminal buffer cleanup.** 5-minute delay after terminal ends before the 8 MB buffer is freed. A burst of 20 loops finishing close together holds ~160 MB for 5 minutes after they're done. Mostly fine, just be aware.

4. **DB pool size = 10.** With 10 daemons heartbeating every 10s + user queries + PubSub-triggered re-queries, the pool can saturate. Bump `POOL_SIZE` to 20-30 on anything bigger than solo use.

### Short answer

A browser user costs almost nothing (~50 KB). A daemon costs ~8 MB per running loop. You're bottlenecked by concurrent loops, not concurrent users. The current 512 MB Fly VM can barely fit the BEAM idle + 3 loops. A 4 GB Hetzner box handles a team of 10-20 comfortably for €8.49/mo.

## Software optimizations to reduce compute

Audited all GenServers, PubSub broadcast chains, and query patterns. Found 7 concrete issues — fixing these would meaningfully reduce CPU/memory/DB pressure independent of hosting choice.

### 1. Ticket board re-queries everything on every change (biggest win)

**File:** `ticket_live/index.ex:149-151`

Every `ticket_created`, `ticket_updated`, or `ticket_deleted` broadcast triggers `stream_tickets()`, which runs:
- `Tickets.search_tickets_grouped()` — fetches ALL tickets, groups by status, applies filters in Elixir
- `Dags.active_loop_info_for_tickets(ticket_ids)` — queries active loops for every ticket

With 5 users on the ticket board, a single ticket status change = 5 concurrent full-table re-queries + 5 loop info queries.

**Fix:** Use the broadcast payload for incremental stream updates.

```elixir
# Before (current)
def handle_info({event, _ticket}, socket)
    when event in [:ticket_created, :ticket_updated, :ticket_deleted] do
  {:noreply, stream_tickets(socket)}
end

# After
def handle_info({:ticket_created, ticket}, socket) do
  {:noreply, stream_insert(socket, stream_name(ticket.status), ticket)}
end

def handle_info({:ticket_updated, ticket}, socket) do
  socket =
    socket
    |> stream_delete_by_dom_id(ticket_dom_id(ticket))  # remove from old status stream
    |> stream_insert(stream_name(ticket.status), ticket)
  {:noreply, socket}
end

def handle_info({:ticket_deleted, ticket}, socket) do
  {:noreply, stream_delete(socket, stream_name(ticket.status), ticket)}
end
```

This eliminates the DB round-trips entirely for the common case. Only re-query on mount or filter change.

### 2. N+1 in `active_loop_info_for_tickets` fallback path

**File:** `dags.ex:207-226`

The fallback branch calls `Loops.get_loop(lid)` inside `Map.new(fallback, fn ...)` — one query per ticket that has no active loop. With 30 completed tickets, that's 30 individual `SELECT * FROM loops WHERE id = $1` queries.

**Fix:** Batch the fallback into the query that already fetched the loop IDs.

```elixir
# Before (current — N+1)
Map.new(fallback, fn {tid, lid} ->
  case Loops.get_loop(lid) do ...
end)

# After (single query)
fallback_loop_ids = Map.values(fallback)
fallback_loops =
  from(l in Loop, where: l.id in ^fallback_loop_ids, select: {l.id, l})
  |> Repo.all()
  |> Map.new()

Map.new(fallback, fn {tid, lid} ->
  case Map.get(fallback_loops, lid) do ...
end)
```

### 3. DagLive.Show ignores broadcast payload, re-queries 3 tables

**File:** `dag_live/show.ex:52-54, 63-74`

When `{:dag_updated, dag}` or `{:loop_status_changed, loop}` arrives, the handler calls `load_dag_data()` which runs 3 queries:
- `Dags.get_dag_by_ticket(ticket_id)` — SELECT dag
- `Dags.list_loops_for_dag(dag.id)` — SELECT all loops
- `Dags.list_dependencies_for_dag(dag.id)` — SELECT all deps via subquery

The broadcast payload already contains the DAG or loop data.

**Fix:** For `:loop_status_changed`, update the single loop in the existing assigns instead of re-querying everything.

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

# Only full re-query on structural changes
def handle_info({:dag_created, _dag}, socket) do
  {:noreply, load_dag_data(socket, socket.assigns.ticket.id) |> maybe_push_render()}
end
```

### 4. MonitorLive re-queries all daemons to count them on every heartbeat

**File:** `monitor_live/index.ex:25-36`

Every `daemon_heartbeat` (every 10s per daemon) and `daemon_status_changed` triggers `Daemons.list_daemons() |> length()`. With 5 daemons heartbeating every 10s = ~3 full-table queries per second just to compute a count.

**Fix:** Track the count locally.

```elixir
# On :daemon_status_changed — count actually might change
def handle_info({:daemon_status_changed, daemon}, socket) do
  {:noreply,
   socket
   |> stream_insert(:daemons, daemon)
   |> update(:daemon_count, &adjust_count(&1, daemon))}
end

# On :daemon_heartbeat — count never changes, just update the row
def handle_info({:daemon_heartbeat, daemon}, socket) do
  {:noreply, stream_insert(socket, :daemons, daemon)}
end
```

### 5. Comment handlers discard payload and re-query full list

**Files:** `loop_live/show.ex:329-331`, `ticket_live/index.ex:154-160`

Both LiveViews handle `{:comment_created, comment}` by ignoring the comment and re-querying all comments for the ticket.

**Fix:** Use the payload.

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

### 6. TaskLoopOrchestrator `task_history` leaks memory

**File:** `task_loop_orchestrator.ex` — `task_history` map

History entries accumulate for every loop that has ever run. Each entry contains strings (session_id, feedback, verdict) — a few KB each. After 1000 loop attempts, this is several MB of dead state that's never cleaned up.

**Fix:** Prune completed loop history from GenServer state. The history is only needed for the UI while the loop is active.

```elixir
# In the handler where a loop reaches terminal state (passed/failed):
defp cleanup_loop_state(state, loop_id) do
  state
  |> update_in([:task_history], &Map.delete(&1, loop_id))
  |> update_in([:checker_handoff_repairs], &Map.delete(&1, loop_id))
  |> update_in([:task_run_config], &Map.delete(&1, loop_id))
end
```

If you need history after loop completion, persist to a `loop_steps` table on each state transition and query from DB on demand.

### 7. `list_dependencies_for_dag` uses a subquery instead of a join

**File:** `dags.ex:305-311`

```elixir
# Current — subquery for loop IDs, then filter deps
loop_ids = from(l in Loop, where: l.dag_id == ^dag_id, select: l.id)
LoopDependency
|> where([d], d.upstream_loop_id in subquery(loop_ids))
```

This misses deps where only the downstream loop is in the DAG (unlikely but possible), and uses a subquery where a join would let Postgres use indexes better.

**Fix:** Join through the DAG directly, or since `list_loops_for_dag` is always called right before, pass the loop IDs in.

```elixir
def list_dependencies_for_dag(dag_id) do
  from(d in LoopDependency,
    join: l in Loop, on: d.upstream_loop_id == l.id,
    where: l.dag_id == ^dag_id
  )
  |> Repo.all()
end
```

### Impact summary

| Fix | Queries eliminated per event | CPU saved | Effort |
|-----|------------------------------|-----------|--------|
| #1 Incremental ticket streams | 2 queries × N users | High | Medium |
| #2 Batch fallback loop query | Up to N individual SELECTs | Medium | Small |
| #3 Use payload in DagLive | 3 queries per status change | Medium | Small |
| #4 Drop daemon count re-query | ~3 queries/sec steady state | Medium | Tiny |
| #5 Use comment payload | 1 query × N users per comment | Low | Tiny |
| #6 Prune orchestrator history | Memory leak prevention | Low (ongoing) | Small |
| #7 Join instead of subquery | Marginal query improvement | Low | Tiny |

Fixes #1-4 are the high-value targets. Together they'd cut DB queries by roughly 70-80% during normal operation.

## Recommendation

**Short term (this week):** Try bumping Fly to `performance-1x` (change `fly.toml` vm section). If that fixes the speed, the problem was just resource starvation and you can decide whether $62/mo is acceptable.

```toml
[[vm]]
  cpu_kind = "performance"
  cpus = 1
  memory_mb = 2048
```

**Medium term:** Migrate to **Hetzner CPX21**. For an early-stage project with 1-5 concurrent daemons, a single 4 GB VPS with Postgres on the same box is more than enough. The €8.49/mo price point is hard to beat, and you get dedicated CPU cores that the BEAM will love.

**When to reconsider:** When you need multi-region, >10 concurrent daemon connections, or HA Postgres — then look at Hetzner managed DB + a second VPS, or go back to a PaaS.
