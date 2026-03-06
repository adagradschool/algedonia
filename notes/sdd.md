# Algedonia -- System Design Document (v4)

Reference: [PRD v5](prd.md)

---

## 1. Overview

Algedonia is an agentic coding orchestration platform. It coordinates AI coding agents (Claude Code, Codex, Aider) through maker-checker loops: one agent writes code, the platform verifies it by running a checker config (test suites, linters, browser checks, agent reviews), and the loop iterates until verification passes, improvements taper, or a human intervenes.

The system has two components: a Phoenix LiveView server (proprietary SaaS) that owns all orchestration, state, and UI, and an open source Go daemon that runs on developer machines to execute agent work. The server decides what to run. The daemon runs it and reports back.

Work flows in from external issue trackers (Linear first). Algedonia watches a tracker project, queues active tickets, runs loops against them, and pushes results back (status updates, PR links, comments). Users stay in their existing tools for planning and review; they visit Algedonia only to observe loops and steer stuck work.

---

## 2. User Interface

Three views, all workspace-scoped. All views update in real time via PubSub. Presence (who is viewing what) is visible in every view. Users authenticate via GitHub OAuth and are associated with one or more workspaces. Every view filters to the current workspace — a user never sees data from a workspace they don't belong to.

### 2.1 Loop View (`/loops/:loop_id`)

The primary workspace. Shows a single loop's iteration history and lets users steer.

**Left panel -- Ticket's Loops:**
List of all loops for the current ticket. Each entry shows: loop title, status icon, current iteration number, checker config name. Clicking a loop loads it in the center and right panels.

Status icons: pending (gray), running (blue), passed (green), failed (red), escalated (orange), tapered (yellow), review_gate (teal).

**Center panel -- Loop Detail:**
- **Current iteration:** The checker's step-by-step verdicts. Each step shows: skill name, pass/fail, duration, and summary. Scrollback (streamed from daemon) available for detailed output.
- **Iteration history:** Collapsible timeline. Each iteration shows the verdict per step and overall pass/fail. Designed to show convergence (or lack thereof) at a glance. No diffs stored server-side — diffs are in git on the daemon.
- **Taper indicator:** When the platform detects diminishing improvements across iterations, a visual signal appears. Shows the delta between iterations to help the human decide whether to intervene or let it continue.

**Right panel -- Steer:**
- **Feedback input:** Free-text field. Submitting feeds the text into the next maker iteration as additional context.
- **Checker config:** View the current skill invocations and their params. Editable -- changes apply to the next iteration.
- **Acceptance criteria:** Synced from the tracker ticket. Editable locally (edits feed into maker/checker context but do not write back to the tracker).

### 2.2 Queue View (`/queue`)

The playback controller. Shows the ordered work queue and global controls.

**Queue list:**
Ordered list of tickets currently queued for work. Each entry shows: ticket identifier, title, priority, loop status (running/passed/stuck), land mode (auto-land or review gate), blocked status. Drag to reorder.

Blocked tickets are visually distinct (dimmed, with a dependency badge showing what they're waiting on). They stay in their priority position but are skipped during dispatch. When blockers complete, the badge disappears and the ticket becomes dispatchable.

**Controls:**
- Play/Pause toggle (global).
- Concurrency slider.
- Per-ticket actions: pin to top, skip (back to library), pause, change land mode.

**Library section:**
Tickets synced from the tracker that are in active states but not yet in the queue (only visible when `auto_start: false`). Click to add to queue.

### 2.3 Monitor (`/monitor`)

Operational overview.

**Escalation queue:**
One escalation at a time (one-piece flow). Shows the stuck loop's context: iteration history, checker feedback, and the specific step that's failing. Actions: provide feedback, edit checker config, skip, manually resolve. Count badge shows remaining queued escalations.

**Circuit breaker status:**
Visual indicator: closed (green), open (red), half-open (yellow). Manual resume button.

**Active loops:**
Compact table of all running loops across daemons: ticket identifier, loop title, daemon name, iteration number, elapsed time.

**Daemon health:**
Connected daemons with owner (user name + avatar), capacity (running/max), last heartbeat. Filtered to daemons owned by users who are members of the current workspace. Shows which user's machine is contributing capacity.

### 2.4 What We Don't Build
- Ticket list/board views (use Linear).
- Backlog prioritization (use Linear).
- PR review UI (use GitHub).
- Notification center (push to Slack/email instead).

---

## 3. System Architecture

Two components. Clear boundary. The daemon is open source (Apache 2.0). The server is proprietary.

```
+-----------------------------------------------------+
|                    Developer Machines                 |
|                                                      |
|  +-------------+  +-------------+  +-------------+   |
|  |  Daemon A   |  |  Daemon B   |  |  Daemon C   |   |
|  | (Go, OSS)   |  | (Go, OSS)   |  | (Go, OSS)   |   |
|  |             |  |             |  |             |   |
|  | - Agents    |  | - Agents    |  | - Agents    |   |
|  | - Workspace |  | - Workspace |  | - Workspace |   |
|  | - PTY       |  | - PTY       |  | - PTY       |   |
|  | - LLM keys  |  | - LLM keys  |  | - LLM keys  |   |
|  +------+------+  +------+------+  +------+------+   |
|         |                |                |           |
+---------|----------------|----------------|----------+
          |                |                |
          | Phoenix Channels (WebSocket, TLS)
          |                |                |
+---------v----------------v----------------v----------+
|                                                      |
|              Phoenix LiveView Server                 |
|              (Proprietary SaaS)                      |
|                                                      |
|  +------------+  +------------+  +---------------+   |
|  | LiveView   |  | Loop       |  | Tracker Sync  |   |
|  | (3 views)  |  | Engine     |  | (Linear)      |   |
|  +------------+  +------------+  +---------------+   |
|  +------------+  +------------+  +---------------+   |
|  | Queue /    |  | Circuit    |  | PubSub        |   |
|  | Playback   |  | Breaker    |  |               |   |
|  +------------+  +------------+  +---------------+   |
|                                                      |
|  +------------------------------------------------+  |
|  |              PostgreSQL                         |  |
|  +------------------------------------------------+  |
|                                                      |
+------------------------------------------------------+
```

**What lives on the server:**
- All state: tickets (mirror), loops, verdicts, events, daemon registrations. No code or diffs.
- All UI rendering (LiveView).
- All orchestration: loop lifecycle, checker config sequencing, queue/playback, circuit breaker.
- Tracker sync (polling Linear, pushing status/comments back).
- PubSub for real-time updates.

**What lives on the daemon:**
- Agent processes (Claude Code, Codex, Aider).
- Workspace management (clone, hooks, cleanup).
- PTY management (capture and stream).
- LLM API credentials (environment variables). Never sent to the server.
- Checker step execution (run commands, drive browsers, spawn review agents).

**The boundary principle:** The server never executes agents, runs commands, or touches LLM APIs. The daemon never makes orchestration decisions. The server says "run this." The daemon runs it and reports back.

---

## 4. Server Design

### 4.1 Routes and LiveView Modules

| Route | LiveView Module | Description |
|---|---|---|
| `/queue` | `QueueLive.Index` | Playback controls, ordered work queue, library |
| `/loops/:loop_id` | `LoopLive.Show` | Loop viewer with iteration history and steering |
| `/monitor` | `MonitorLive.Index` | Escalation queue, circuit breaker, overview |

Each LiveView module subscribes to relevant PubSub topics on mount.

### 4.2 Database Schema

Summary of tables:

- `tickets` -- lightweight mirror of tracker tickets, including planning state and checker configs.
- `loops` -- maker-checker loops attached to tickets, with checker config (skill invocations).
- `loop_iterations` -- each maker-then-check round within a loop.
- `checker_step_results` -- per-step results within an iteration's checker run.
- `queue_entries` -- the ordered work queue with playback metadata.
- `events` -- append-only event log for all state transitions.
- `daemon_registrations` -- connected daemons and their capacity.

### 4.3 PubSub Topics

Phoenix PubSub (backed by `Phoenix.PubSub.PG2` for single-node).

| Topic | Payload | Subscribers |
|---|---|---|
| `loop:{id}` | Iteration updates, checker step results, status changes | `LoopLive` |
| `queue` | Queue reorder, ticket added/removed, playback state changes | `QueueLive` |
| `monitor` | Escalation events, circuit breaker transitions, daemon health | `MonitorLive` |
| `presence` | User join/leave per view | All views |

### 4.4 Key Server-Side Processes

OTP processes supervised under the application tree.

**Loop Engine (`Algedonia.LoopEngine`):**
Owns the lifecycle of every loop. Responds to events (daemon reports maker complete, checker step results) and decides the next action: run next checker step, retry maker with feedback, detect taper, escalate, hold for review gate, mark passed. Persists every state transition to the `events` table before acting.

**Tracker Sync (`Algedonia.TrackerSync`):**
GenServer that polls the tracker on a configurable cadence. On each tick:
1. Fetch tickets in planning and active states for the configured project.
2. Upsert into `tickets` table.
3. For tickets in planning states: trigger planning if not already done.
4. For tickets that moved to active states with approved checker config: notify Queue Manager.
5. For tickets that moved to terminal states: stop active loops, clean up.
6. Push outbound updates (status changes, comments) back to the tracker.

Reconciliation runs on every tick: if a running loop's ticket has moved to a terminal state in the tracker, stop the loop.

**Queue Manager (`Algedonia.QueueManager`):**
Owns the playback state and work queue. Responsibilities:
- Maintain the ordered queue of tickets to work.
- Respect global play/pause and concurrency limits.
- When a slot opens: dequeue the next ticket, create a loop, dispatch to a daemon.
- Handle per-ticket controls (pin, skip, pause, land mode).
- When `auto_start: true`, automatically enqueue newly synced active tickets sorted by priority.

**Circuit Breaker (`Algedonia.CircuitBreaker`):**
State machine: `closed` → `open` (after N consecutive escalations) → `half_open` (manual resume) → `closed` (test loop passes) or back to `open` (test loop escalates). When open, the Queue Manager stops dispatching new loops.

**Daemon Monitor (`Algedonia.DaemonMonitor`):**
Tracks daemon health via heartbeats (every 10s). Each heartbeat carries `{capacity, running_loops, available_agents, cached_repos}`. Marks daemons unhealthy after 30s silence, offline after 5 minutes. On status transitions, notifies Queue Manager to re-evaluate dispatch (a daemon coming online or recovering opens new routing options).

### 4.5 Server-Daemon Communication

Phoenix Channels over WebSocket (TLS). One channel per daemon: `daemon:{daemon_id}`.

This is the protocol that will be published when the daemon is open sourced. It must be stable, minimal, and fully documented.

**Server → Daemon commands:**

```
run_maker:
  loop_id: string
  workspace_id: string              # which workspace this work belongs to
  workspace_slug: string            # for bare clone directory organization
  repo: {url: string, branch: string, base_branch: string}
  task: {title: string, description: string, acceptance_criteria: string}
  context: {knowledge: string, prior_iterations: [iteration_summary]}
  agent: {type: "claude_code" | "codex" | "aider", config: map}
  prompts_dir: string

run_checker_step:
  loop_id: string
  workspace_slug: string
  iteration_number: integer
  step_index: integer
  skill: {name: string, type: "command" | "browser" | "agent_review", config: map, params: map}

land:
  loop_id: string
  land_mode: "auto_land" | "review_gate"
  branch: string
  base_branch: string

stop:
  loop_id: string
  reason: string

stdin_input:
  loop_id: string
  data: binary
```

**Daemon → Server events:**

```
maker_result:
  loop_id: string
  exit_code: integer
  files_changed: [string]             # file paths only, not content
  duration_ms: integer
  token_usage: {input: integer, output: integer}

step_result:
  loop_id: string
  iteration_number: integer
  step_index: integer
  skill_name: string
  passed: boolean
  summary: string                     # structured summary, not raw output
  duration_ms: integer

land_result:
  loop_id: string
  status: "review_gate" | "landed" | "ci_failed"
  pr_url: string
  merge_sha: string | null            # set when status is "landed"
  ci_output: string | null            # set when status is "ci_failed" — summary for maker feedback

terminal_output:
  loop_id: string
  data: binary
  timestamp: integer (unix ms)

heartbeat:
  daemon_id: string
  running_loops: [string]
  capacity: integer
  available_agents: [string]         # e.g., ["claude_code", "codex"]
  bare_repos: [string]               # repo URLs with existing bare clones
  system: {cpu_percent: float, memory_available_mb: integer}

error:
  loop_id: string | null
  message: string
  recoverable: boolean
```

---

## 5. Daemon Design

### 5.1 Language and Distribution

Go. Single static binary, no runtime dependencies. Cross-compilation to Mac and Linux via `GOOS`.

The daemon ships as a standalone open source repository (Apache 2.0) with its own README, protocol spec, and contribution guidelines. It is not a subdirectory of the server monorepo.

Installation: `brew install algedonia-daemon` or `curl -fsSL https://get.algedonia.dev | sh`.

### 5.2 Connection to Server

On startup, the daemon connects to the server's WebSocket endpoint with a **user token**. The token identifies the user, not a workspace — the daemon can receive work from any workspace the user belongs to. The connection is persistent with exponential backoff on disconnect. During disconnection, running agents continue; terminal output is buffered locally.

Heartbeat every 10 seconds: running loops, max capacity (configurable, default 3), system metrics.

### 5.3 Command Handling

- **`run_maker`**: Set up workspace (ensure bare clone, create worktree, run `before_run` hook), select agent adapter, spawn agent process, stream PTY output to server. On completion, send `maker_result` with exit code, files changed (paths only), duration, and token usage.
- **`run_checker_step`**: Execute a single checker step in the workspace. For `command` type: run the shell command, capture output, report pass/fail. For `browser` type: boot the app, drive Playwright/CDP, capture screenshots/DOM. For `agent_review` type: spawn a review agent, capture verdict. Send `step_result` on completion.
- **`stop`**: SIGTERM → wait 5s → SIGKILL.
- **`stdin_input`**: Write to the agent's PTY master fd.

### 5.4 Workspace Management

Each loop gets its own workspace directory under a configurable root.

**Workspace lifecycle:**
1. `EnsureRepo`: bare-clone the repo if not present, otherwise `git fetch --all`.
2. `EnsureWorktree`: create a worktree at `<workspace>/<slug>/worktrees/<ticket_prefix>`.
3. Run `before_run` hook in the worktree (fetch, rebase, deps install).
4. Execute maker/checker steps in the worktree.
5. On loop completion, run `after_run` hook.
6. On terminal ticket state, run `before_remove` hook and remove the worktree (bare clone stays).

**Hooks** are shell scripts defined in the project config (WORKFLOW.md-style). They run with the workspace as cwd. Hook timeout: 60s default. `after_create` and `before_run` failures are fatal to the current attempt. `after_run` and `before_remove` failures are logged and ignored.

### 5.5 Agent Adapter Interface

```go
type Adapter interface {
    Start(workdir string, task string, config map[string]any) (Process, error)
    AttachPTY(proc Process) (io.Reader, io.Writer, error)
    Wait(proc Process) (ExitResult, error)
    Kill(proc Process) error
    SessionID(proc Process) string
}
```

Each agent type (Claude Code, Codex, Aider) has an adapter that constructs the CLI invocation, passes the task, and collects results. The adapter does not interpret output.

Community-contributed adapters are a primary goal of the open source strategy. The adapter interface must be stable and well-documented.

### 5.6 What the Daemon Never Does

This list is part of the trust contract:

- Never sends LLM API keys to the server.
- Never sends file contents or code to the server. The server sees only verdicts, summaries, and file path lists.
- Never makes network requests except to the Algedonia server and agent LLM APIs.
- Never executes commands not explicitly requested by a server command.
- Never modifies files outside the workspace directory.
- Never persists telemetry or usage data.
- All daemon behavior is fully determined by server commands and local config. No autonomous actions.

---

## 6. The Maker-Checker Loop (End-to-End Flow)

### Step 0: Planning

Tracker Sync polls Linear, finds a ticket in "Planning" state. Upserts into `tickets` table. If `auto_plan: true`, dispatches a planning agent that reads the ticket's acceptance criteria and the repo's available skills, then proposes a checker config. The proposed config is stored on the ticket (`proposed_checker_config`). If `auto_approve: true`, it's immediately copied to `approved_checker_config`. Otherwise, a human reviews and approves it (via Algedonia UI or by moving the ticket to "Todo" in the tracker).

### Step 1: Ticket Ready

Tracker Sync detects a ticket has moved to "Todo" state. Upserts into `tickets` table. If `auto_start: true`, Queue Manager adds it to the queue sorted by priority. The ticket must have an `approved_checker_config` to be dispatchable.

### Step 2: Loop Created and Dispatched

Queue Manager dequeues the next ticket (respecting play/pause, concurrency, dependencies). Creates a `loop` record with the ticket's `approved_checker_config` (base pipeline prepended). Picks a daemon via scored routing. Sends `run_maker` command.

### Step 3: Maker Execution

Daemon sets up workspace (ensure bare clone, create worktree), spawns the agent. Streams terminal output to subscribers in real time. Agent completes. Daemon sends `maker_result` with exit code, files changed (paths only), duration, and token usage. No code or diffs sent to server.

### Step 4: Checker Execution

Server (Loop Engine) receives `maker_result`. Creates a `loop_iteration` record. Reads the loop's `checker_config`. For each step, resolves the skill name to its execution config (from the repo's `.algedonia/skills/`), merges per-ticket params, and sends `run_checker_step` commands sequentially. Each step result is stored in `checker_step_results` and broadcast to subscribers.

If all steps pass: the iteration passes.
If any step fails: the iteration fails. The step's output becomes structured feedback.

### Step 5: Verdict

**If iteration passes:**
- Server sends `land` command to daemon with the loop's `land_mode`.
- Daemon executes the landing sequence (see Section 10.4).
- Daemon reports back via `land_result` event: PR URL, CI status, merge status.
- Server updates loop record and pushes status to tracker.
- Broadcast to `workspace:{id}:loop:{id}` and `workspace:{id}:queue`.

**If iteration fails, iterations remaining:**
- Increment iteration counter.
- Assemble feedback: the failing step's summary, plus any human feedback from the steer panel.
- Send `run_maker` to daemon with prior iteration context.
- Loop back to Step 3.

**If CI fails during landing:**
- Daemon reports `land_result` with `ci_failed` status and CI output summary.
- Server treats this as an iteration failure: CI output becomes maker feedback, loop continues iterating.
- On the next pass, the daemon pushes an updated branch (the existing PR auto-updates), and waits for CI again.

**If taper detected:**
- Compare improvement deltas across recent iterations. If the delta is below a configurable threshold for N consecutive iterations, halt.
- Loop status: `tapered`. Appears in escalation queue.
- The human sees the iteration history and can: provide feedback (resumes loop), edit checker config, skip, or manually resolve.

**If max iterations exceeded:**
- Loop status: `escalated`. Appears in escalation queue.
- Circuit breaker increments consecutive escalation counter.

### Step 6: Human Intervention

User sees escalation in Monitor. Options:
- Provide feedback → loop resumes with new maker context.
- Edit checker config → next iteration uses updated config.
- Skip → loop marked skipped, ticket stays in tracker as-is.
- Manually resolve → mark loop passed, proceed with merge flow.

---

## 7. Skills and Checker Execution

### 7.1 Skills

Skills are reusable capability definitions stored as markdown files in `.algedonia/skills/` in the repo. Each skill declares its type, execution config (in frontmatter), and human/agent-readable context (in the body).

```markdown
<!-- .algedonia/skills/test.md -->
---
name: test
type: command
run: "mix test"
pass: exit_code_zero
---
Run the full test suite.
```

```markdown
<!-- .algedonia/skills/browser-check.md -->
---
name: browser-check
type: browser
boot: "mix phx.server --port $PORT"
wait_for: "http://localhost:$PORT/health"
tools: [screenshot, dom_snapshot, console_logs]
---
Boot the app and drive a headless browser. The scenario is
parameterized per-ticket during planning.
```

Skills are read by the daemon when executing checker steps. The daemon parses the frontmatter for execution config and ignores the body (the body is for planning agents and humans).

### 7.2 Checker Config

Each loop has a **checker config** — an ordered list of skill invocations with optional per-ticket parameters. This is composed during the planning phase and stored on the `loops` record as JSON.

Example checker config (stored as `checker_config` on the loop):

```json
{
  "steps": [
    {"skill": "compile"},
    {"skill": "test"},
    {"skill": "lint"},
    {"skill": "browser-check", "params": {"scenario": "navigate to /settings, fill name, submit, verify toast"}},
    {"skill": "security-review", "params": {"criteria": "no auth bypass, no XSS in form inputs"}}
  ]
}
```

Steps 1–3 come from the project's `base_pipeline` config and are prepended automatically. Steps 4–5 are ticket-specific, composed during planning.

### 7.3 Planning Phase

When a ticket enters a planning state (configurable via `planning_states` in project config), the server triggers the planning agent:

1. Server reads the ticket's acceptance criteria and the repo's available skills (`.algedonia/skills/`).
2. Planning agent (dispatched via `run_maker` with a planning-specific prompt) evaluates the ticket:
   - **Clear ticket**: composes a checker config and stores it as `approved_checker_config`. Moves ticket to "Todo" in the tracker automatically.
   - **Ambiguous ticket**: posts clarifying questions (as tracker comments or in Algedonia UI). Once answers arrive, proposes a checker config stored as `proposed_checker_config` for human review.
3. The planning approval behavior is a **workspace setting** (tuned in Algedonia UI, not project config): spectrum from "always auto-approve" to "always require review." Default: let the agent decide based on ticket clarity.
4. When the ticket reaches an active state ("Todo") with an `approved_checker_config`, it's ready for loop creation.

### 7.4 Step Execution Model

Steps run sequentially. If a step fails, remaining steps are skipped (fail-fast). The failing step's output is the primary feedback to the maker.

For each step, the server resolves the skill name to its execution config (from the repo's `.algedonia/skills/` directory), merges in any per-ticket params, and sends a `run_checker_step` command. The server stores each result and broadcasts it to LiveView subscribers so users see checker progress in real time.

### 7.5 Step Type Details

**Command:**
- Daemon runs `bash -lc "<command>"` in the worktree directory.
- Pass: exit code 0. Fail: non-zero exit code.
- Output: stdout + stderr (truncated to 100KB).

**Browser:**
- Daemon boots the app using the skill's `boot` command.
- Waits for `wait_for` URL to respond (timeout: 30s).
- Drives a headless browser (Playwright) with the scenario from per-ticket params.
- Captures screenshots, DOM snapshots, and console logs as artifacts.
- Pass/fail determined by scenario assertions or by an agent interpreting the results.
- On completion or failure, kills the app process.

**Agent review:**
- Daemon spawns a review agent with the diff, the skill's prompt, and the per-ticket criteria.
- The review agent produces a structured verdict (pass/fail + comments).
- This uses the same agent adapter interface as the maker, with a review-specific prompt.

---

## 8. Ticket Sync

### 8.1 Tracker Adapter Interface

```elixir
@callback fetch_active_tickets(config) :: {:ok, [ticket]} | {:error, term}
  # ticket includes blocked_by: [%{external_id, identifier}]
@callback fetch_ticket_states(config, [ticket_id]) :: {:ok, %{ticket_id => state}} | {:error, term}
@callback update_ticket_status(config, ticket_id, new_status) :: :ok | {:error, term}
@callback post_comment(config, ticket_id, body) :: :ok | {:error, term}
@callback attach_link(config, ticket_id, url, label) :: :ok | {:error, term}
```

### 8.2 Linear Adapter

- Polls via GraphQL API using `tracker.project_slug` to filter.
- Auth via `LINEAR_API_KEY` environment variable on the server.
- Candidate tickets: project filter + state in `active_states`.
- Normalizes Linear issues into internal ticket format (id, identifier, title, description, status, priority, labels, acceptance criteria from description).
- **Dependencies:** Fetches each issue's `relations` (type `blocks`/`blockedBy`) and stores as `blocked_by` on the ticket. Only relations where the blocker is also in the same project are tracked. Blocker refs include `external_id` and `identifier` for display.
- Outbound: updates issue state, posts comments, attaches PR links.
- Pagination: 50 issues per page.
- Network timeout: 30s.

### 8.3 Reconciliation

On every poll tick:
1. Fetch active tickets → upsert into `tickets` table.
2. For all running loops: check if their ticket is still in an active state.
3. If a ticket moved to terminal: stop the loop, clean workspace.
4. If a ticket moved out of active states (e.g., back to Backlog): stop the loop, remove from queue.

### 8.4 Outbound Updates

The server pushes updates to the tracker at specific loop lifecycle points:
- Loop dispatched → move ticket to "In Progress" (configurable target state).
- Loop passed + auto-land → move ticket to "Done" (configurable).
- Loop passed + review gate → move ticket to "Ready for Review" (configurable), attach PR URL.
- Loop stuck (escalated/tapered) → post a structured comment: what's failing, iteration count, link to Algedonia loop view.

---

## 9. Data Model

### Workspace Isolation (Multi-Tenancy)

Algedonia is multi-tenant. Every workspace is fully isolated — a user in workspace A never sees tickets, loops, daemons, or events from workspace B.

**Implementation:** Every tenant-scoped table has a `workspace_id` FK. All queries filter by workspace. Two enforcement layers:

1. **Application-level:** Context modules (the Elixir query layer) scope every query by `workspace_id`. The workspace is derived from the user's session and injected into every context call. No query runs without a workspace scope.

2. **Database-level (RLS):** Postgres Row-Level Security as a safety net. Each table has a policy: `USING (workspace_id = current_setting('app.workspace_id')::uuid)`. The application sets `app.workspace_id` on each connection via `SET LOCAL`. This catches any query that accidentally bypasses the application layer.

Both layers are mandatory. The application layer is the primary enforcement (readable, testable). RLS is the defense-in-depth backstop.

**PubSub:** Topics are workspace-scoped: `workspace:{id}:loop:{loop_id}`, `workspace:{id}:queue`, `workspace:{id}:monitor`. LiveView mounts subscribe only to topics within the authenticated workspace.

**Daemon connections:** Each daemon connects with a **user token**, not a workspace token. The daemon belongs to a user, not a workspace. The user may have access to multiple workspaces. The server dispatches work from any workspace the user belongs to — one daemon, one connection, one shared capacity pool. Work is still workspace-scoped: every `run_maker` command includes a `workspace_id`, and the daemon organizes bare clones by workspace (`~/.algedonia/workspaces/<workspace_slug>/<repo_slug>/root/`). The server only routes workspace A's work to daemons whose user has access to workspace A.

### users

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| github_id | integer | Not null, unique. From OAuth. |
| github_username | text | Not null |
| name | text | Display name |
| email | text | |
| avatar_url | text | |
| inserted_at | timestamptz | |
| updated_at | timestamptz | |

Index: `github_id` (unique).

### workspace_memberships

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| workspace_id | uuid | FK → workspaces. Not null. |
| user_id | uuid | FK → users. Not null. |
| role | text | `owner`, `member`. Default `member`. |
| inserted_at | timestamptz | |

Index: `(workspace_id, user_id)` (unique).

This join table determines which workspaces a user can see and which workspaces a user's daemon can receive work from.

### workspaces

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| name | text | Not null |
| slug | text | URL-safe identifier. Not null, unique. |
| github_repo_url | text | Primary repo URL |
| tracker_config | jsonb | Tracker connection settings (kind, project_slug, states) |
| playback_config | jsonb | Playback settings (auto_start, concurrency, default_land) |
| defaults | jsonb | Base pipeline, max iterations, etc. |
| planning_mode | text | `auto` (agent decides), `always_approve`, `always_review`. Default `auto`. |
| inserted_at | timestamptz | |
| updated_at | timestamptz | |

Index: `slug` (unique).

### tickets

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| workspace_id | uuid | FK → workspaces. Not null. |
| external_id | text | Tracker's internal ID. Not null, unique per workspace. |
| identifier | text | Human-readable key (e.g., "ABC-123"). Not null. |
| title | text | Not null |
| description | text | |
| status | text | Current tracker state |
| priority | integer | Lower = higher priority. Nullable. |
| labels | text[] | Normalized to lowercase |
| acceptance_criteria | text | Extracted from description or custom field |
| proposed_checker_config | jsonb | Checker config proposed by planning agent, pending human review. Nullable. |
| approved_checker_config | jsonb | Approved checker config for loop creation. Nullable until planning completes. |
| blocked_by | jsonb | Array of blocker refs: `[{"external_id": "...", "identifier": "ABC-45"}]`. Empty array when unblocked. |
| tracker_url | text | Link back to the tracker ticket |
| synced_at | timestamptz | Last sync from tracker |
| inserted_at | timestamptz | |
| updated_at | timestamptz | |

Index: `(workspace_id, external_id)` (unique), `(workspace_id, status)`, `(workspace_id, priority)`.

### loops

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| workspace_id | uuid | FK → workspaces. Not null. |
| ticket_id | uuid | FK → tickets |
| status | text | `pending`, `running`, `landing`, `passed`, `failed`, `escalated`, `tapered`, `review_gate`, `skipped`, `resolved` |
| checker_config | jsonb | Ordered list of skill invocations with params. Composed during planning. |
| land_mode | text | `auto_land` or `review_gate` |
| assigned_daemon_id | uuid | FK → daemon_registrations, nullable |
| current_iteration | integer | Default 0 |
| max_iterations | integer | Default from config |
| branch_name | text | Git branch for this loop's work |
| pr_url | text | GitHub PR URL, nullable |
| inserted_at | timestamptz | |
| updated_at | timestamptz | |

Index: `ticket_id`, `status`, `assigned_daemon_id`.

**Loop state machine:**

```
pending → running → [iteration cycle]
                         |
                    [all steps pass] → landing
                         |               |
                         |          [CI passes + auto_land] → passed (done)
                         |          [CI passes + review_gate] → review_gate (wait for human)
                         |          [CI fails] → running (CI output as feedback, retry)
                         |
                    [step fails, iterations remain] → running (retry)
                    [taper detected] → tapered (escalation queue)
                    [max iterations] → escalated (escalation queue)

Human intervention on tapered/escalated:
  → provide feedback → running
  → edit checker config → running
  → skip → skipped
  → manually resolve → resolved → merge flow

Review gate resolution:
  → PR merged by human → passed
  → PR closed with review comments → running (review feedback as context)

Terminal states: passed, skipped, resolved
Halted states: escalated, tapered, review_gate
Transient states: landing
```

### loop_iterations

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| loop_id | uuid | FK → loops |
| iteration_number | integer | 1-based |
| maker_duration_ms | integer | |
| maker_token_usage | jsonb | `{input: int, output: int}` |
| verdict | text | `pass`, `fail`, `taper` |
| human_feedback | text | Feedback from user via steer panel, nullable |
| inserted_at | timestamptz | |

Index: `loop_id`, `(loop_id, iteration_number)`.

The server does **not** store diffs, raw output, or agent session IDs. Diffs live in git on the daemon (the branch). Raw output lives in the daemon's scrollback buffer, streamed to the UI in real time via `terminal_output` events. The server stores only structured verdicts and metadata.

### checker_step_results

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| loop_iteration_id | uuid | FK → loop_iterations |
| step_index | integer | Order within the checker config |
| skill_name | text | Which skill was invoked |
| passed | boolean | |
| summary | text | Short structured summary (e.g., "3 tests failed", "screenshot mismatch on /settings"). Not raw output. |
| duration_ms | integer | |
| inserted_at | timestamptz | |

Index: `loop_iteration_id`.

No artifacts stored server-side. Screenshots, DOM snapshots, and full output stay on the daemon. The Loop View shows the verdict timeline (pass/fail per step per iteration). Detailed output is available via scrollback.

### queue_entries

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| workspace_id | uuid | FK → workspaces. Not null. |
| ticket_id | uuid | FK → tickets. Unique per workspace. |
| position | integer | Sort order in queue |
| status | text | `queued`, `active`, `paused`, `skipped` |
| land_mode | text | Override for this ticket's loops |
| pinned | boolean | Default false |
| inserted_at | timestamptz | |
| updated_at | timestamptz | |

Index: `(workspace_id, position)`, `(workspace_id, status)`.

### events

| Column | Type | Notes |
|---|---|---|
| id | bigserial | PK, monotonically increasing |
| workspace_id | uuid | FK → workspaces. Not null. |
| entity_type | text | `loop`, `iteration`, `queue`, `circuit_breaker`, `daemon`, `ticket_sync` |
| entity_id | uuid | |
| event_type | text | e.g., `loop_started`, `iteration_passed`, `step_failed`, `escalated`, `tapered`, `dispatched` |
| payload | jsonb | Event-specific data |
| actor | text | Display name, daemon_id, or `system` |
| inserted_at | timestamptz | |

Index: `(workspace_id, entity_type, entity_id)`, `(workspace_id, inserted_at)`. Append-only.

### daemon_registrations

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| user_id | uuid | FK → users. Not null. The daemon belongs to a user, not a workspace. |
| name | text | Human-readable (e.g., hostname) |
| status | text | `online`, `unhealthy`, `offline` |
| capacity | integer | Max concurrent loops this daemon can run |
| running_loops | integer | Current count |
| available_agents | text[] | Agent adapters available on this daemon (e.g., `["claude_code", "codex"]`) |
| bare_repos | text[] | Repo URLs with existing bare clones on this daemon. Updated via heartbeat. |
| last_heartbeat_at | timestamptz | |
| connected_at | timestamptz | |

Index: `(user_id, status)`.

Note: daemon_registrations is **not** workspace-scoped. A daemon serves multiple workspaces. The Monitor view filters daemons to those owned by users who belong to the current workspace.

### Cleanup Policy

- **Events:** Retained indefinitely (audit log). Partition by month if needed.
- **Loop iterations and step results:** Retained for life of project. These are lightweight (verdicts and summaries, no code or raw output).
- **Daemon registrations:** Offline daemons older than 30 days soft-deleted.
- **Scrollback and artifacts:** Live on the daemon. Daemon operators manage retention. The server never stores code, diffs, raw output, or binary artifacts.

---

## 10. Queue and Playback

### 10.1 Queue Behavior

The queue is an ordered list of tickets that will be worked. It is separate from the tracker's backlog.

**When `auto_start: true` (default):**
Every active ticket synced from the tracker is automatically added to the queue, sorted by priority (from tracker). New tickets enter at their priority position.

**When `auto_start: false`:**
Tickets appear in the "library" section of the Queue View. The coordinator manually adds tickets to the queue and orders them.

### 10.2 Dispatch Logic

On every queue evaluation (triggered by: slot opens, queue changes, play resumed, blocker completes):
1. If paused, do nothing.
2. Calculate **effective concurrency**: `min(configured_concurrency, total_daemon_capacity - total_running_loops)`. If zero, do nothing. This ensures WIP is bounded by actual daemon capacity, not just a configured number.
3. Count running loops. If at effective concurrency limit, do nothing.
4. Walk the queue in position order, skipping entries that are `paused` or **blocked** (ticket has non-empty `blocked_by` where any blocker is not in a terminal state).
5. Take the first dispatchable entry.
6. Find an available daemon (least-loaded with capacity).
7. Create a loop for the ticket. Dispatch `run_maker` to daemon.
8. Update queue entry status to `active`.

**Dependency re-evaluation:** When a loop reaches a terminal state (passed + landed, skipped, resolved), the Queue Manager queries for tickets that had the completed ticket in their `blocked_by`. For each, it checks whether all remaining blockers are also terminal. Newly unblocked tickets trigger a queue evaluation immediately.

**WIP limits:** The effective concurrency is always `min(configured, available_daemon_capacity)`. The concurrency slider in the UI sets the configured ceiling, but actual parallelism cannot exceed what daemons can handle. Daemon capacity is reported via heartbeats and tracked in `daemon_registrations`. If a daemon goes offline mid-work, its running loops are reassigned or stopped, and effective capacity adjusts accordingly.

### 10.3 Daemon Routing

Step 6 of dispatch ("find an available daemon") is a scored selection, not just least-loaded.

**Eligibility filter (hard requirements):**
- Status is `online` (not `unhealthy` or `offline`).
- Daemon's user is a member of the ticket's workspace (via `workspace_memberships`).
- `running_loops < capacity` (has a free slot).
- `available_agents` includes the agent type required by the loop's config. If no agent type is specified, any daemon qualifies.

If no daemon passes the filter, the ticket stays queued and dispatch is retried on the next evaluation (triggered by heartbeat, slot opening, or daemon connecting).

**Scoring (soft preferences, among eligible daemons):**

| Factor | Weight | Score |
|---|---|---|
| **Bare repo locality** | 3 | +3 if `bare_repos` contains the ticket's repo URL (worktree creation is near-instant from an existing bare clone; a fresh bare clone can take minutes for large repos) |
| **Available capacity** | 2 | `(capacity - running_loops) / capacity` × 2 (prefer daemons with more headroom) |
| **Recency** | 1 | +1 if this daemon ran a loop for the same repo in the last hour (warm OS/filesystem caches) |

Highest score wins. Ties broken by daemon name (deterministic).

**Why these factors:**
- **Bare repo locality dominates** because the daemon uses a bare-clone-plus-worktree model. Each daemon maintains bare clones at `<workspace_root>/<slug>/root/`. Creating a worktree from an existing bare is nearly instant (`git worktree add`). But the initial bare clone of a large repo can take minutes. Routing to a daemon that already has the bare clone avoids this entirely. This naturally creates per-repo daemon affinity without explicit pinning.
- **Capacity** prevents piling all work onto one daemon when others are idle.
- **Recency** is a weak signal for warm OS/filesystem caches.

**Heartbeat payload:** Daemons report `{capacity, running_loops, available_agents, bare_repos}` on each heartbeat (every 10s). `bare_repos` is the list of repo URLs for which the daemon has an existing bare clone in its workspace root. The server updates `daemon_registrations` in place. This is the only source of truth for routing decisions — the server never inspects daemon internals directly.

**Daemon failure mid-loop:** If a daemon goes offline while running a loop, the Daemon Monitor detects it (30s heartbeat timeout). The loop is marked `failed` with a `daemon_lost` reason. The Queue Manager can re-dispatch the ticket to another daemon on the next evaluation. The new daemon creates a worktree from its own bare clone (or bare-clones the repo first if it doesn't have one yet). No state transfer between daemons — the loop starts a new iteration from the branch's last pushed state.

### 10.4 Landing

Landing is daemon-side. The server sends a `land` command; the daemon executes the full sequence using the user's local git and GitHub credentials (`gh` CLI or git credentials).

**Landing sequence (daemon-side):**
1. Squash commits on the branch into a single commit with a structured message.
2. Push branch to remote.
3. Create PR (or update existing PR if branch already has one).
4. Poll for CI status on the PR (GitHub checks API via `gh`).
5. Report `land_result` to server with PR URL and CI outcome.

**Based on land mode:**

**`review_gate` (default):**
- After step 3 (PR created), daemon waits for CI.
- CI passes: daemon reports `land_result` with `{status: "review_gate", pr_url, ci: "passed"}`. Server moves ticket to configured review state in tracker. Loop status: `review_gate`. PR waits for human review.
- CI fails: daemon reports `land_result` with `{status: "ci_failed", ci_output}`. Server treats as iteration failure — CI output becomes maker feedback, loop iterates. On next pass, daemon pushes updated branch (PR auto-updates), waits for CI again.

**`auto_land`:**
- Same as review_gate through CI check.
- CI passes: daemon merges the PR (squash merge). Reports `land_result` with `{status: "landed", pr_url, merge_sha}`. Server moves ticket to terminal state in tracker. Loop status: `passed`.
- CI fails: same as review_gate — iterate.

**Review gate resolution:**
- When a PR in `review_gate` is merged by a human (detected via GitHub webhook or polling), server marks loop `passed` and updates tracker.
- When a PR is closed with review comments, server extracts feedback from the review, resumes the loop with review comments as maker context.

Land mode can be set per-ticket in the Queue View or as a workspace default.

---

## 11. Workspace and Hooks

### 11.1 Workspace Layout

Each daemon maintains a workspace root (configurable, default `~/.algedonia/workspaces`). Repos are stored as bare clones with per-loop worktrees:

```
<workspace_root>/
  <workspace_slug>/
    root/                          # bare clone (git clone --bare)
    worktrees/
      <ticket_prefix_a>/          # git worktree from bare (cheap, fast)
        .git                      # file, not dir — points to bare
        ... (repo contents)
      <ticket_prefix_b>/          # another loop's worktree
        ...
```

**Lifecycle:**
1. **Bare clone** (`EnsureRepo`): On first dispatch for a repo, the daemon runs `git clone --bare <url> <workspace_root>/<slug>/root`. This is the expensive step (minutes for large repos). On subsequent dispatches, it runs `git fetch --all` to update refs. The bare clone is long-lived and shared across all loops for that repo.
2. **Worktree creation** (`EnsureWorktree`): For each loop, the daemon creates a worktree from the bare clone: `git worktree add --detach <path> <default_branch>`. This is nearly instant regardless of repo size.
3. **Worktree cleanup** (`RemoveWorktree`): On loop completion or ticket terminal state, the worktree is removed via `git worktree remove --force`. The bare clone stays.
4. **Bare clone retention**: Bare clones persist indefinitely on the daemon. They're reported in the heartbeat (`bare_repos`) so the server can route future work for the same repo to the same daemon. Manual cleanup is the daemon operator's responsibility.

This model is why **bare repo locality** is the dominant routing factor: dispatching to a daemon that already has the bare clone turns a multi-minute setup into a sub-second worktree add.

### 11.2 Hook Definitions

Hooks are defined in the project config:

```yaml
hooks:
  before_run: |
    git fetch origin main
    git rebase origin/main
    mix deps.get
  after_run: |
    echo "cleanup if needed"
  before_remove: |
    echo "pre-deletion cleanup"
```

Hooks run as `bash -lc <script>` with worktree as cwd. Timeout: `hooks.timeout_ms` (default 60000).

Failure semantics:
- `before_run`: fatal to current attempt.
- `after_run`: logged, ignored.
- `before_remove`: logged, ignored.

---

## 12. Reflection and Process Improvement

### 12.1 Trigger

After a loop reaches a terminal state (passed + landed, or resolved), the server triggers a reflection step. Reflection is skipped if the loop passed on the first iteration with no human nudges (nothing to learn from).

### 12.2 Reflection Input

The reflection agent receives (via `run_maker` with a reflection-specific prompt):
- **Loop verdicts:** per-iteration pass/fail, which skills failed and their summaries.
- **Human nudges:** every feedback message from the steer panel, with the iteration it was applied to.
- **Iteration count and taper data:** how many attempts, whether convergence was smooth or oscillating.
- **Checker config:** which skills were used and whether they were effective (caught real issues vs. noise).
- **Current repo knowledge:** `.algedonia/knowledge.md` contents.
- **Available skills:** list of skills in `.algedonia/skills/`.

The reflection agent does NOT receive code, diffs, or raw output — consistent with the server's no-code principle. It works from verdicts, summaries, and human feedback.

### 12.3 Reflection Output

The reflection agent produces a structured output with zero or more **improvement items**, each categorized:

| Category | Example | Outcome |
|---|---|---|
| `guideline` | "All LiveView tests require a session fixture" | Ticket to update ARCHITECTURE.md or code guidelines |
| `new_skill` | "Add migration-check skill for reversibility" | Ticket to create `.algedonia/skills/migration-check.md` |
| `skill_update` | "Increase browser-check boot timeout to 60s" | Ticket to update existing skill |
| `knowledge` | "This repo uses ETS-backed sessions, not cookies" | Ticket to update `.algedonia/knowledge.md` |
| `recommendation` | "Linter caught 0 issues in 15 loops — consider removing from base pipeline" | Surfaced to human in Monitor view, not auto-ticketed |

Each item (except `recommendation`) is pushed to the tracker as a new ticket. These tickets enter the same system: planning → loop → verification → land. The system improves itself through its own primitive.

### 12.4 Knowledge Consumption

When constructing `run_maker` commands, the server includes current `.algedonia/knowledge.md` contents. Both makers and checker review agents receive it. This creates a compounding loop: each completed loop makes future loops better-informed, and reflection tickets update the knowledge that future loops consume.

### 12.5 Key Metric: Nudge Rate

The human nudge rate — how often humans intervene per loop — is the primary measure of system improvement. Reflection should trend this downward over time. If the nudge rate isn't declining, reflection isn't producing useful improvements.

### 12.6 Guardrails

- Reflection is non-critical. Failure is logged and skipped.
- Improvement tickets go through the same planning/verification flow. No backdoor commits.
- The reflection agent can propose, not apply. No auto-commits to guidelines or skills without a loop verifying the change.
- If a loop passed clean (first iteration, no nudges), reflection produces nothing. No busywork.

---

## 13. Non-Functional Requirements

### Latency
- UI updates (iteration results, checker steps): < 500ms from event to browser render.
- Loop start (queue dispatch to agent running): < 10s excluding workspace setup.
- Terminal streaming (for future terminal view): < 200ms end-to-end.

### Concurrency
- Loops per daemon: default 3, configurable.
- Daemons per server: tested for up to 20.
- Concurrent UI viewers: no hard limit (PubSub fan-out).

### Security Model
- **User auth:** GitHub OAuth (read:user scope). Users are associated with workspaces via `workspace_memberships`.
- **Daemon auth:** User token over TLS. Daemon inherits the user's workspace access.
- **LLM API keys:** Daemon-side only. Never sent to server.
- **Tracker API keys:** Server-side only. Never sent to daemon.
- **Workspace isolation:** Application-level query scoping + Postgres RLS. See Section 9.
- **Daemon trust contract:** See Section 5.6 for the explicit list of things the daemon never does.

---

## 14. Tradeoffs

**Open source daemon, proprietary server.**
The daemon is commodity infrastructure. Open sourcing it controls the protocol, enables community adapters, and earns trust. Risk: someone builds a competing server. Mitigation: the daemon without the server is just a process runner; the value is in orchestration, checker strategies, ticket sync, and the queue model.

**No built-in ticket tracker.**
Depends on external trackers (Linear, GitHub Issues). Limits control over ticket-level state machines and metadata. Mitigation: the loop is the owned primitive, and loop-level state is fully controlled. Ticket sync is adapter-based, so adding tracker features later is an extension, not a rewrite.

**No terminal view in v1.**
Users don't see raw agent output. They see structured iteration data. Risk: less visibility into what the agent is actually doing. Mitigation: the iteration diff and checker step output provide the right altitude of information. Terminal view is wired at the protocol level (the `terminal_output` event exists) and can be added later.

**Per-loop workspaces instead of file locking.**
Each loop gets a full repo checkout. Uses more disk space. Mitigation: workspaces are cleaned up after completion. Disk is cheap. Eliminates the entire locking/scheduling complexity from v3.

**Sequential checker steps (fail-fast).**
A failing early step skips later steps. The maker might miss feedback from multiple failing steps. Mitigation: the most important feedback is usually from the first failure. Running all steps would increase cost for diminishing returns. Can be made configurable later.

**Taper detection is heuristic.**
Comparing iteration deltas to detect diminishing improvements is imprecise. Mitigation: the threshold is configurable. False positives (halting too early) are low-cost — the human sees the history and can resume. False negatives (continuing too long) are bounded by max iterations.

**Single-node server.**
No clustering in v1. Mitigation: server is stateless except for DB and in-memory caches. Restart recovers from PostgreSQL.

**Go daemon, not Elixir.**
Go produces a single static binary with no runtime dependencies. Easier to install, easier for the community to contribute to (larger Go ecosystem than Elixir). The daemon is I/O-bound, not CPU-bound — Go is sufficient.
