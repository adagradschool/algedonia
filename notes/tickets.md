# Algedonia — Implementation Tickets (PRD v5 / SDD v4)

Generated from gap analysis between the current codebase and the v5 PRD / v4 SDD.

## What Already Exists (Keep / Adapt)

- Phoenix server with LiveView, PubSub, Presence, auth (GitHub OAuth)
- Go daemon with PTY, agent adapters (Claude Code, Codex, Aider), bare clone + worktree workspace management
- Server-daemon protocol over Phoenix Channels
- Ecto schemas for tickets, loops, daemons, comments, terminals
- TaskLoopOrchestrator (maker-checker execution, needs refactoring)
- Workspace hooks (before_run)
- Terminal streaming pipeline (daemon → chunker → channel → buffer → xterm.js)
- Test suite (50+ modules)

## What Gets Removed

- DAGs, decomposition loops, decompose orchestrator
- File-level locking / LockManager
- Impact analysis
- loop_dependencies table
- Built-in ticket CRUD UI (keep full CRUD, remove decomposition trigger)
- DagLive.Show view
- DecomposeOrchestrator GenServer
- YAML checker strategy files and `.algedonia/checkers/` directory
- Diff/code storage on server (server never sees code)

---

## Phase 0: Clean Up — Remove v4 Primitives

Clear out machinery that v5 replaces.

### T0.1 — Remove DAG and decomposition machinery
**Priority: P0 | Size: M | Depends on: nothing**

Remove:
- `DecomposeOrchestrator` GenServer
- `Algedonia.Dags` context (create_dag_from_output, etc.)
- `dags` Ecto schema and migration
- `loop_dependencies` schema and migration
- `DagLive.Show` LiveView and route
- `decompose.md`, `impact_analysis.md` prompts
- All `role: :decompose` / `:decompose_checker` / `:impact_analysis` handling in daemon channel
- DAG tree panel from `LoopLive.Show` (left panel)
- Related tests

Migration: drop `dags` and `loop_dependencies` tables. Remove `dag_id` FK from `loops`.

### T0.2 — Remove file-level locking
**Priority: P0 | Size: S | Depends on: nothing**

Remove:
- `file_locks` table and schema
- `LockManager` GenServer
- Lock acquire/release calls in scheduler
- `path_prefixes` column from `loops`

### T0.3 — Simplify loop schema for v5
**Priority: P0 | Size: M | Depends on: T0.1, T0.2**

Migrate the `loops` table:
- Remove: `dag_id`, `role`, `path_prefixes`, `rubric`
- Add: `checker_config` (jsonb — ordered list of skill invocations), `land_mode` (text — `auto_land` or `review_gate`), `pr_url` (text, nullable)
- Rename statuses to match v5: remove `running_maker`/`running_checker`/`needs_clarification`/`pending_approval`/`assigned`/`ready`, add `running`/`tapered`/`review_gate`
- Update `Loop` schema, changeset, and all status references

### T0.4 — Clean up ticket UI
**Priority: P0 | Size: S | Depends on: nothing**

Remove stale v4 machinery, keep full CRUD:
- Remove "Start Work" button and decomposition trigger
- Keep create ticket form
- Keep ticket list/board view with drag-to-change-status
- Keep ticket detail panel with editable fields: title, description, acceptance_criteria (planning agent and humans both write to these)
- Inline comments on ticket detail (planning agent posts questions, implementation spec, etc.)

---

## Phase 1: Multi-Tenancy and Data Model

Workspace isolation is foundational — everything else depends on it.

### T1.1 — Users table and GitHub OAuth user records
**Priority: P0 | Size: M | Depends on: nothing**

Create `users` table:
- `id` (uuid), `github_id` (integer, unique), `github_username`, `name`, `email`, `avatar_url`

Update existing GitHub OAuth flow to create/update user records on login. Currently stores profile in session — persist to DB instead.

### T1.2 — Workspaces and membership tables
**Priority: P0 | Size: M | Depends on: T1.1**

Create `workspaces` table:
- `id`, `name`, `slug` (unique), `github_repo_url`, `playback_config` (jsonb), `defaults` (jsonb), `planning_mode` (text, default `auto`)

Create `workspace_memberships` table:
- `workspace_id`, `user_id`, `role` (owner/member)

Migrate existing workspace data. Update existing workspace CRUD to write to new schema.

### T1.3 — Add workspace_id to all tenant-scoped tables
**Priority: P0 | Size: L | Depends on: T1.2**

Add `workspace_id` FK to: `tickets`, `loops`, `queue_entries`, `events`.
Update all indexes to be workspace-prefixed.
Update all context modules to scope queries by `workspace_id`.

Add Postgres RLS policies as safety net:
- Each table: `USING (workspace_id = current_setting('app.workspace_id')::uuid)`
- Application sets `app.workspace_id` via `SET LOCAL` on each connection

### T1.4 — User-bound daemons
**Priority: P0 | Size: M | Depends on: T1.1, T1.3**

Update `daemon_registrations`:
- Replace `workspace_id` with `user_id` FK
- Add `available_agents` (text[]), `bare_repos` (text[])

Update daemon auth: connect with user token instead of project token. Server resolves which workspaces the user belongs to via `workspace_memberships`.

Update DaemonChannel to authenticate against user, not workspace.

### T1.5 — Workspace-scoped PubSub
**Priority: P0 | Size: S | Depends on: T1.3**

Update all PubSub topics to include workspace:
- `workspace:{id}:loop:{loop_id}`
- `workspace:{id}:queue`
- `workspace:{id}:monitor`

Update all LiveView mounts to subscribe within authenticated workspace only.

### T1.6 — Update tickets schema for v5
**Priority: P0 | Size: M | Depends on: T1.3**

Migrate `tickets` table:
- Add: `labels` (text[]), `blocked_by` (jsonb), `proposed_checker_config` (jsonb), `approved_checker_config` (jsonb)
- Remove: `type`, `assignee`, `coding_agent`, `overview`
- Keep: `title`, `description`, `status`, `priority`, `acceptance_criteria`

---

## Phase 2: Skills and Planning

The core abstraction. Skills replace YAML strategy files. Planning replaces static template matching.

### T2.1 — Skill discovery and parsing
**Priority: P0 | Size: M | Depends on: nothing**

Create `Algedonia.Skills` module:
- Discover skills from `.algedonia/skills/` directory in the repo
- Parse markdown files: extract YAML frontmatter (name, type, run, pass criteria, tools, boot, etc.)
- Return structured `%Skill{name, type, config}` list
- Skill types: `command`, `browser`, `agent_review`
- Skills are read by the daemon when executing checker steps

Daemon side: on `run_checker_step`, resolve skill config from the repo's `.algedonia/skills/` directory, merge with per-ticket params from the command payload.

### T2.2 — Planning agent
**Priority: P0 | Size: L | Depends on: T2.1, T1.6**

When a ticket enters a planning state:

1. Server reads ticket's acceptance criteria and repo's available skills
2. Dispatches planning agent (via `run_maker` with planning-specific prompt)
3. Agent evaluates ticket clarity:
   - Clear ticket: composes checker config, stores as `approved_checker_config`, moves ticket to ready
   - Ambiguous ticket: posts clarifying questions in Algedonia UI, proposes config as `proposed_checker_config`
4. Planning approval controlled by workspace `planning_mode` setting (auto/always_approve/always_review)

### T2.3 — Base pipeline prepend
**Priority: P0 | Size: S | Depends on: T2.1**

When creating a loop, prepend the workspace's `defaults.base_pipeline` skills to the ticket's `approved_checker_config`. Base pipeline (compile, test, lint) runs on every ticket regardless of planning output.

### T2.4 — Checker config editing in steer panel
**Priority: P1 | Size: M | Depends on: T2.1, T4.3**

In the Loop View steer panel, show the current checker config (list of skill invocations with params). Allow editing: add/remove/reorder skills, change params. Edits apply to the next iteration.

---

## Phase 3: Loop Engine

The execution core.

### T3.1 — Add `run_checker_step` with skills to daemon protocol
**Priority: P0 | Size: M | Depends on: T2.1**

Server side:
- Add `run_checker_step` push to `DaemonChannel`
- Payload: `loop_id`, `workspace_slug`, `iteration_number`, `step_index`, `skill` (name, type, config, params)

Daemon side:
- Handle `run_checker_step`: resolve skill from `.algedonia/skills/`, merge params
- For `command` type: run `bash -lc "<command>"` in worktree, capture stdout/stderr, report exit code
- Send `step_result` event: `loop_id`, `iteration_number`, `step_index`, `skill_name`, `passed`, `summary` (structured, not raw output), `duration_ms`

Server side:
- Handle `step_result` in `DaemonChannel`, persist to `loop_steps`, broadcast to PubSub

### T3.2 — Update `run_maker` for no-code protocol
**Priority: P0 | Size: M | Depends on: T1.4**

Update `run_maker` command payload:
- Add `workspace_id`, `workspace_slug`
- Remove diff from `maker_result` response — daemon sends only `exit_code`, `files_changed` (paths only), `duration_ms`, `token_usage`
- Update `DaemonChannel` handler and `LoopEngine` to work without server-side diffs

### T3.3 — Loop engine: sequential checker step execution
**Priority: P0 | Size: L | Depends on: T3.1, T3.2**

Refactor `TaskLoopOrchestrator` into `Algedonia.LoopEngine`:
- After maker completes: read the loop's `checker_config`, send `run_checker_step` for step 0
- On `step_result`: if passed, send next step. If failed, stop (fail-fast). If last step passed, iteration passes.
- On iteration pass: check land mode → `passed` or `review_gate`
- On iteration fail: increment iteration, assemble feedback from failing step summary, dispatch next maker run
- On max iterations: → `escalated`

### T3.4 — Taper detection
**Priority: P1 | Size: S | Depends on: T3.3**

In `LoopEngine`, after each failed iteration:
- Compare failing step summaries with previous iterations
- Heuristic v1: same step fails with same summary hash for N consecutive iterations (default 3) → `tapered`
- Configurable threshold in workspace defaults
- Tapered loops enter escalation queue

---

## Phase 4: Queue, Playback, and Routing

### T4.1 — Queue entries table and QueueManager GenServer
**Priority: P0 | Size: L | Depends on: T3.3, T1.3**

Create `queue_entries` table:
- `workspace_id`, `ticket_id` (unique per workspace), `position`, `status` (queued/active/paused/skipped), `land_mode`, `pinned`

Create `Algedonia.QueueManager` GenServer:
- State: global play/pause per workspace, concurrency limit per workspace
- On evaluation trigger (slot opens, queue changes, play resumed, blocker completes):
  1. If paused, skip
  2. Calculate effective concurrency: `min(configured, total_daemon_capacity - total_running_loops)`
  3. Walk queue by position, skip paused and blocked entries (ticket `blocked_by` has non-terminal blockers)
  4. Find available daemon via scored routing (T4.2)
  5. Create loop with ticket's `approved_checker_config` (base pipeline prepended)
  6. Dispatch `run_maker`, mark entry `active`
- On loop completion: trigger re-evaluation
- On blocker completion: re-evaluate dependents
- Expose: `play/0`, `pause/0`, `set_concurrency/1`, `reorder/2`, `pin/1`, `skip/1`, `enqueue/1`, `remove/1`

### T4.2 — Daemon routing (scored selection)
**Priority: P0 | Size: M | Depends on: T1.4**

Implement scored daemon selection in `QueueManager`:

Eligibility filter (hard):
- Daemon status `online`
- Daemon's user is member of ticket's workspace
- `running_loops < capacity`
- `available_agents` includes required agent type

Scoring (soft):
- Bare repo locality: +3 if `bare_repos` contains repo URL
- Available capacity: `(capacity - running_loops) / capacity` x 2
- Recency: +1 if daemon ran a loop for same repo in last hour

Highest score wins, ties broken by daemon name.

### T4.3 — Dependency-aware dispatch
**Priority: P1 | Size: M | Depends on: T4.1**

During queue walk, check each ticket's `blocked_by`:
- Query blocker tickets by ID, check if all are in terminal states
- Skip blocked tickets (visually marked in queue UI)
- When a loop lands: query tickets with this ticket in `blocked_by`, re-evaluate

### T4.4 — Queue LiveView (`/queue`)
**Priority: P1 | Size: L | Depends on: T4.1**

Build `QueueLive.Index`:
- Play/Pause toggle (global per workspace)
- Concurrency slider — shows both configured ceiling and effective limit (daemon-constrained indicator)
- Ordered list of queue entries, drag-to-reorder
- Each entry: ticket identifier, title, priority, loop status, land mode toggle, blocked badge
- Blocked entries visually dimmed with dependency badge
- Per-entry actions: pin, skip, pause, change land mode
- Library section (when `auto_start: false`): synced tickets not in queue
- Subscribe to `workspace:{id}:queue` PubSub topic

### T4.5 — Wire queue as landing page
**Priority: P1 | Size: S | Depends on: T4.4**

- Add `/queue` route
- Make `/queue` the default landing page
- Update sidebar: Queue, Monitor. Loop view accessed from queue entries.

---

## Phase 5: Loop Viewer Refactor

### T6.1 — Replace DAG panel with ticket loops list
**Priority: P1 | Size: M | Depends on: T0.1**

Left panel of `LoopLive.Show`:
- Remove DAG tree
- Replace with flat list of loops for current ticket
- Each entry: status icon, iteration number, skill names from checker config
- Click to load in center/right panels

### T6.2 — Verdict timeline and checker step results UI
**Priority: P1 | Size: L | Depends on: T3.3**

Center panel of `LoopLive.Show`:
- Current iteration: checker step-by-step verdicts (skill name, pass/fail, summary, duration)
- No diffs or raw output — scrollback streamed from daemon for detail
- Iteration history timeline: collapsible list, each showing per-step verdicts
- Taper indicator: visual signal when taper detected

### T6.3 — Steer panel
**Priority: P1 | Size: M | Depends on: T3.3**

Right panel of `LoopLive.Show`:
- Feedback input (textarea + submit). Stored in `loop_iterations.human_feedback`, fed to next maker
- Checker config viewer: show skill invocations and params. Editable — saves to loop record, applies next iteration (T2.4)
- Acceptance criteria (synced from ticket, editable locally)

---

## Phase 6: Circuit Breaker and Escalation

### T7.1 — Circuit breaker GenServer
**Priority: P1 | Size: M | Depends on: T3.3**

Create `Algedonia.CircuitBreaker` (per workspace):
- State machine: `closed` → `open` (N consecutive escalations) → `half_open` (manual resume) → `closed`/`open`
- When open: QueueManager stops dispatching
- Persist state, broadcast to `workspace:{id}:monitor`

### T7.2 — Escalation queue in Monitor view
**Priority: P1 | Size: M | Depends on: T7.1, T6.2**

Extend `MonitorLive.Index`:
- Escalated/tapered loops, one-piece flow
- Display: verdict history, failing step, human feedback trail
- Actions: provide feedback, edit checker config, skip, manually resolve
- Count badge, circuit breaker status with resume button
- Daemon health section: each daemon shows owner (user name + avatar), capacity, status. Filtered to daemons whose users are workspace members.

---

## Phase 7: Landing (Daemon-Side)

Landing is fully daemon-side. The daemon has the user's git credentials and `gh` CLI.

### T8.1 — `land` command and daemon landing sequence
**Priority: P1 | Size: L | Depends on: T3.3**

Server side:
- Add `land` command to protocol: `loop_id`, `land_mode`, `branch`, `base_branch`
- Send after all checker steps pass
- Handle `land_result` event: update loop record (pr_url, status)

Daemon side:
- Handle `land` command:
  1. Squash commits on branch
  2. Push branch to remote
  3. Create PR via `gh pr create` (or update existing)
  4. Poll CI status via `gh pr checks`
  5. Send `land_result` with status, pr_url, ci outcome
- CI polling: check every 30s, timeout after configurable max (default 30min)

### T8.2 — Auto-land merge
**Priority: P1 | Size: M | Depends on: T8.1**

When `land_mode` is `auto_land` and CI passes:
- Daemon merges PR via `gh pr merge --squash`
- Reports `land_result` with `{status: "landed", merge_sha}`
- Server marks loop `passed`

When CI fails:
- Daemon reports `land_result` with `{status: "ci_failed", ci_output}`
- Server treats as iteration failure — CI output becomes maker feedback
- On next pass, daemon pushes updated branch (PR auto-updates), waits for CI again

### T8.3 — Review gate resolution
**Priority: P2 | Size: M | Depends on: T8.1**

When `land_mode` is `review_gate` and CI passes:
- Daemon reports `land_result` with `{status: "review_gate", pr_url}`
- Server moves ticket to review state, loop status: `review_gate`

Resolution (server-side polling or webhook):
- PR merged by human → mark loop `passed`
- PR closed with review comments → extract feedback, resume loop with review as maker context

---

## Phase 8: Reflection and Process Improvement

### T9.1 — Reflection agent
**Priority: P2 | Size: L | Depends on: T3.3**

After a loop lands (passed + merged or resolved):
- Skip if loop passed on first iteration with no human nudges
- Dispatch reflection agent with: loop verdicts, human nudges, iteration count, checker config, current `.algedonia/knowledge.md`, available skills
- Agent produces structured output: zero or more improvement items categorized as `guideline`, `new_skill`, `skill_update`, `knowledge`, `recommendation`
- Each item (except `recommendation`) → create ticket in Algedonia
- Recommendations surfaced in Monitor view
- Non-critical: failure logged and skipped

### T9.2 — Nudge rate tracking
**Priority: P2 | Size: S | Depends on: T9.1**

Track human nudge rate per workspace:
- Count of human_feedback entries per loop
- Aggregate: nudges per loop over time (rolling 30 days)
- Surface in Monitor view as a trend line
- This is the primary metric for whether reflection is working

### T9.3 — Knowledge consumption in maker context
**Priority: P2 | Size: S | Depends on: T9.1**

When constructing `run_maker` commands, include current `.algedonia/knowledge.md` contents from the repo. Both makers and review agents receive it. Updated knowledge (from reflection tickets that land) feeds into future loops automatically.

---

## Phase 9: Advanced Checker Steps

### T10.1 — Browser checker step in daemon
**Priority: P2 | Size: L | Depends on: T3.1**

Extend daemon `run_checker_step` for `browser` skill type:
- Boot app using skill's `boot` command
- Wait for health endpoint
- Drive Playwright/CDP with scenario from per-ticket params
- Capture screenshots, DOM snapshots, console logs (stay on daemon)
- Report `step_result` with summary (not raw artifacts)
- Kill app on completion

### T10.2 — Agent review checker step in daemon
**Priority: P2 | Size: M | Depends on: T3.1**

Extend daemon `run_checker_step` for `agent_review` skill type:
- Spawn review agent (same adapter interface) with diff + skill prompt + per-ticket criteria
- Capture structured verdict (pass/fail + comments)
- Report `step_result` with summary

---

## Phase 10: Configuration and Polish

### T11.1 — Workspace settings UI
**Priority: P2 | Size: M | Depends on: T1.2, T4.1**

Workspace settings page:
- Playback defaults (concurrency, default_land)
- Planning mode (auto/always_approve/always_review)
- Base pipeline (list of skill names)
- Max iterations

### T11.2 — Project config file (WORKFLOW.md style)
**Priority: P2 | Size: M | Depends on: T11.1**

Parse `.algedonia/config.yml` from the repo as an alternative to UI settings:
- `playback`, `defaults` sections
- File overrides workspace settings where specified
- Dynamic reload on change

---

## Phase 11: Open Source Daemon Prep

### T12.1 — Extract daemon protocol spec
**Priority: P2 | Size: M | Depends on: T3.1, T3.2**

Standalone protocol specification:
- All server→daemon commands with payload schemas
- All daemon→server events with payload schemas
- Auth flow (user token)
- Reconnection, heartbeat, version negotiation

### T12.2 — Daemon trust contract enforcement
**Priority: P2 | Size: S | Depends on: nothing**

Audit daemon against trust contract (SDD Section 5.6):
- No file contents or code sent to server (only verdicts, summaries, file paths)
- No network requests except to server and agent LLM APIs
- No file modifications outside worktree
- No telemetry persistence
- Integration tests verifying invariants

### T12.3 — Separate daemon into standalone repo
**Priority: P3 | Size: L | Depends on: T12.1, T12.2**

- Extract `daemon/` into its own repo
- README, LICENSE (Apache 2.0), CONTRIBUTING.md
- Protocol spec doc, adapter development guide
- CI pipeline
- Update server to reference as external dependency

---

## Dependency Graph

```
Phase 0 (cleanup)             Phase 1 (multi-tenancy)
  T0.1 T0.2 T0.4 (parallel)    T1.1 ── T1.2 ── T1.3 ── T1.5
  └─ T0.3                      T1.1 ──────────── T1.4
                                T1.3 ── T1.6

Phase 2 (skills/planning)     Phase 3 (loop engine)
  T2.1 ── T2.2                  T2.1 ── T3.1 ──┐
  T2.1 ── T2.3                  T1.4 ── T3.2 ──┼── T3.3 ── T3.4

Phase 4 (queue/routing)       Phase 5 (loop viewer)
  T3.3 + T1.3 ── T4.1          T0.1 ── T6.1
  T1.4 ── T4.2                 T3.3 ── T6.2 ── T6.3
  T4.1 ── T4.3
  T4.1 ── T4.4 ── T4.5

Phase 6 (circuit breaker)     Phase 7 (landing)
  T3.3 ── T7.1 ──┐             T3.3 ── T8.1 ── T8.2
  T6.2 ──────────── T7.2                  └── T8.3

Phase 8 (reflection)          Phase 9 (advanced checkers)
  T3.3 ── T9.1 ── T9.2         T3.1 ── T10.1
  T9.1 ── T9.3                 T3.1 ── T10.2

Phase 10 (config)             Phase 11 (open source)
  T1.2 + T4.1 ── T11.1         T3.1 + T3.2 ── T12.1 ── T12.3
  T11.1 ── T11.2                              T12.2 ──┘
```

## Recommended Execution Order

**Sprint 1: Foundation** (parallel tracks)
- Track A: T0.1, T0.2, T0.3, T0.4 (cleanup)
- Track B: T1.1, T1.2 (users, workspaces)

**Sprint 2: Multi-Tenancy + Schema**
- T1.3, T1.4, T1.5 (workspace isolation, user-bound daemons, scoped PubSub)
- T1.6 (tickets schema)

**Sprint 3: Skills + Protocol**
- T2.1, T2.3 (skill discovery, base pipeline)
- T3.1, T3.2 (daemon protocol updates)

**Sprint 4: Core Engine**
- T3.3 (loop engine — the big one)
- T2.2 (planning agent)
- T4.1, T4.2 (queue manager, daemon routing)

**Sprint 5: UI**
- T4.3, T4.4, T4.5 (dependency dispatch, queue view)
- T6.1, T6.2, T6.3 (loop viewer refactor)
- T3.4 (taper detection)

**Sprint 6: Reliability + Landing**
- T7.1, T7.2 (circuit breaker, escalation UI)
- T8.1 (GitHub PR creation)
- T2.4 (checker config editing in steer panel)

**Sprint 7: Polish + Advanced**
- T8.2, T8.3 (auto-land, review gate)
- T9.1, T9.2, T9.3 (reflection, nudge rate, knowledge)
- T10.1, T10.2 (browser + agent review checker steps)
- T11.1, T11.2 (workspace settings, config file)

**Sprint 8: Open Source**
- T12.1, T12.2, T12.3 (protocol spec, trust audit, standalone repo)
