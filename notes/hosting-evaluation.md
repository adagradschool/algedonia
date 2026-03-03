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
