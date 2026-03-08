# Algedonia Completion Backlog (Loop-Friendly)

This backlog is derived from:
- `notes/prd.md` (v5)
- `notes/sdd.md` (current target model)
- current implementation in `server/` and `daemon/`

It intentionally ignores `notes/tickets.md`.

## Sequencing Rules
- Execute in dependency order.
- Do not start a ticket until its dependencies are merged.
- Every ticket must end with explicit checker proof.

### ALGE-001 — Stabilize Persisted Planning Loops
Priority: P0 | Size: L | Owner boundary: data
Depends on: none

Outcome
- Persisted planning loops are a first-class loop role (`planning`) with deterministic lifecycle, and docs/schema/runtime all agree on that model.

Acceptance Criteria
1. `loops.role` DB/schema/changeset contract explicitly supports `task`, `hook`, and `planning`.
2. Planning sessions always resolve to a persisted planning loop row and step history.
3. SDD and implementation no longer disagree on persisted planning loop behavior.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix ecto.migrate && mix test test/algedonia/tickets_test.exs test/algedonia_web/live/loop_live_test.exs`
     pass signal: planning lifecycle tests pass with persisted planning loops and no schema/changeset drift.

Implementation Notes
- Preserve ticket workflow: `backlog -> planning -> in_progress -> completed`.
- Do not reintroduce DAG/dependency-era schema.

Failure / Escalation Semantics
- If any code path can create a planning session without persisted loop records, fail and block downstream checker-pipeline tickets.

Out of Scope
- Queueing and playback behavior.

### ALGE-002 — Add Skill Registry and Checker Config Validation
Priority: P0 | Size: M | Owner boundary: backend
Depends on: ALGE-001

Outcome
- Server can load, validate, and expose repo-local skills from `.algedonia/skills/` and validate checker configs against that registry.

Acceptance Criteria
1. Skill parsing rejects invalid frontmatter and missing required fields with actionable errors.
2. Checker config validation fails fast on unknown skill names or invalid params shape.
3. Skill registry is available to planning and checker orchestration contexts.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/skills_test.exs`
     pass signal: parser/validation tests cover valid/invalid skills and checker config references.

Implementation Notes
- Keep registry read-only at runtime; skills remain source-controlled markdown files.

Failure / Escalation Semantics
- On parse/validation failures, ticket stays in planning with explicit errors; no silent fallback.

Out of Scope
- Executing skills on daemon.

### ALGE-002A — Fix Maker → Checker Transition Regression
Priority: P0 | Size: M | Owner boundary: backend
Depends on: ALGE-001

Outcome
- Existing task loops reliably transition from maker completion to checker start.

Acceptance Criteria
1. A successful maker completion always creates a checker step and dispatches checker execution.
2. Transition works for first attempt and retry attempts.
3. Regression test fails on current bug and passes with fix.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/task_loop_orchestrator_test.exs`
     pass signal: explicit maker->checker transition regression test passes.

Implementation Notes
- Prefer minimal fix in orchestrator transition/state handling before broader checker-pipeline expansion.

Failure / Escalation Semantics
- If checker start cannot be dispatched after maker success, mark loop failed with explicit transition error.

Out of Scope
- Multi-step checker decomposition.

### ALGE-003 — Orchestrate Multi-Step Checker Pipeline per Loop
Priority: P0 | Size: L | Owner boundary: backend
Depends on: ALGE-002, ALGE-002A

Outcome
- Task loop orchestration runs checker as explicit per-step skill invocations (base pipeline + ticket-specific steps) with structured pass/fail/taper/clarify outcomes.

Acceptance Criteria
1. Checker executes ordered skill steps and records step-level receipts.
2. Loop pass requires all required checker steps to pass.
3. Loop fail/retry path includes structured feedback from failed step(s).

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/task_loop_orchestrator_test.exs`
     pass signal: orchestrator tests demonstrate multi-step checker sequencing and retry behavior.

Implementation Notes
- Preserve maker/checker independence and project-level iteration budget constraints.

Failure / Escalation Semantics
- Repeated checker failures follow project-level iteration budget policy and escalate cleanly to halted/stuck state.

Out of Scope
- Specific runtime implementation of browser/agent-review skill executors.

### ALGE-003A — Add Taper-to-Pass Semantics for Cosmetic-Only Iterations
Priority: P0 | Size: M | Owner boundary: backend
Depends on: ALGE-003

Outcome
- Loops can end as pass when hard gates are satisfied and iteration deltas are cosmetic-only.

Acceptance Criteria
1. Hard-gate checker steps are explicitly classified and required for pass.
2. Taper detector compares current vs prior iteration and classifies cosmetic-only deltas.
3. Loop can terminate as pass when hard gates pass and only cosmetic deltas remain.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/task_loop_orchestrator_test.exs`
     pass signal: tests cover taper-to-pass behavior and non-cosmetic deltas remaining blocked.

Implementation Notes
- Keep checker output explainable: include why the run tapered to pass.

Failure / Escalation Semantics
- If taper classification confidence is low, do not auto-pass; escalate for human review.

Out of Scope
- ML-based semantic diff scoring.

### ALGE-004 — Implement Runtime Command Skill Execution with Step-Scoped Context
Priority: P0 | Size: M | Owner boundary: runtime
Depends on: ALGE-003

Outcome
- Daemon executes command-type checker skills with minimal step-scoped context (global task + current skill task only), and returns structured step results to server.

Acceptance Criteria
1. Daemon can execute command skills with scoped worktree context.
2. Step result payload includes pass/fail, summary, duration, and exit code.
3. Server transitions checker pipeline based on step result events, not raw terminal heuristics.
4. Checker step execution context is reset between steps and does not carry prior skill-specific prompt baggage.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd daemon && go test ./...`
     pass signal: loop manager tests cover command skill execution and event payload contract.

Implementation Notes
- Keep daemon as executor only; server remains orchestrator/decision-maker.
- Context minimization is mandatory to avoid degraded quality from oversized multi-skill prompts.

Failure / Escalation Semantics
- Non-zero exit must produce deterministic fail result and actionable summary.

Out of Scope
- Browser and agent-review skill types.

### ALGE-004A — Commit Snapshot on Every Maker Run Completion
Priority: P0 | Size: M | Owner boundary: runtime
Depends on: ALGE-004

Outcome
- Daemon creates a commit snapshot after every successful maker run completion before checker execution starts.

Acceptance Criteria
1. Each successful maker completion produces a commit when there are staged/unstaged changes.
2. Commit message includes loop ID and attempt number for traceability.
3. Checker runs against the committed snapshot for that attempt.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd daemon && go test ./...`
     pass signal: tests assert per-attempt commit behavior and metadata format.

Implementation Notes
- Avoid empty commits when no file changes exist.

Failure / Escalation Semantics
- Commit failure marks attempt failed with actionable git error and prevents checker start.

Out of Scope
- Squash/rewrite of per-attempt commits before landing.

### ALGE-004B — Add `pi` Coding Agent Support
Priority: P0 | Size: M | Owner boundary: cross-boundary
Depends on: ALGE-004

Outcome
- `pi` is a first-class coding agent option across ticket model, orchestration, and daemon adapter routing.

Acceptance Criteria
1. Ticket agent enum/config supports `pi` in backend and UI.
2. Daemon setup phase discovers installed agent runtimes and registers only available adapters.
3. Agent-specific setup is conditional (for example, Claude hooks are installed only when Claude runtime is present).
4. Server and UI consume daemon-reported `available_agents`; users can only select/spawn agents available on their daemon.
5. Existing defaults remain stable for current agents.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd daemon && go test ./... && cd ../server && mix test`
     pass signal: adapter + server agent-selection tests pass with `pi`.

Implementation Notes
- Replace any Aider-specific references in docs/config defaults with `pi`.
- Publish discovered `available_agents` in heartbeat payload and use it as the source of truth for agent dropdown options.

Failure / Escalation Semantics
- If a selected agent is unavailable on the target daemon, block dispatch with explicit `agent_unavailable` feedback and setup guidance.
- If setup discovery finds no supported agents, daemon reports degraded/blocked status until an agent runtime is installed.

Out of Scope
- Auto-migration of historical agent metadata.

### ALGE-005 — Implement Runtime Browser Skill Execution (Playwright-First)
Priority: P0 | Size: L | Owner boundary: runtime
Depends on: ALGE-004

Outcome
- Daemon supports browser checker skills (Playwright-backed) with scenario parameters and structured verdict output.

Acceptance Criteria
1. Browser skill boot/wait/scenario lifecycle is configurable per checker step.
2. Browser checks emit deterministic pass/fail and short summary.
3. Browser artifacts remain daemon-local; server stores only structured receipts.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: browser-check
     params: `scenario=sample workspace smoke flow`
     pass signal: step_result is `pass` for valid scenario and `fail` for broken scenario with reproducible summary.

Implementation Notes
- Use a general Playwright execution path first.
- Treat Claude-in-Chrome extension integration as an optional adapter once the generic browser contract is stable.
- Enforce timeout and cleanup to avoid orphan browser processes.

Failure / Escalation Semantics
- Timeout or boot failure returns fail with cause classification (`boot_timeout`, `scenario_assertion`, `runtime_error`).

Out of Scope
- Visual regression baseline tooling.

### ALGE-006 — Decide and Gate Optional Agent-Review Skill
Priority: P2 | Size: S | Owner boundary: docs
Depends on: ALGE-003

Outcome
- We have a clear product decision on whether dedicated runtime `agent_review` skills add value beyond the checker prompt, and the codepath is either enabled behind a flag or deferred.

Acceptance Criteria
1. Decision record compares current checker prompt capability vs dedicated agent-review step value/cost.
2. If kept: feature-flagged implementation path exists and is off by default.
3. If deferred: backlog and docs explicitly mark it as non-blocking for v1.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd notes && rg -n \"agent-review|agent_review\" prd.md sdd.md`
     pass signal: decision is documented and backlog/docs reflect it consistently.

Implementation Notes
- Do not make this a v1 blocker unless data shows checker-only flow is insufficient.

Failure / Escalation Semantics
- If decision cannot be made with evidence, default to defer (no hidden partial implementation).

Out of Scope
- Building multi-agent ensemble review logic.

### ALGE-007 — Make Planning Produce Verified Checker Configs
Priority: P0 | Size: L | Owner boundary: cross-boundary
Depends on: ALGE-002, ALGE-003

Outcome
- Planning flow generates/updates ticket-level checker config and refined acceptance criteria before work starts.

Acceptance Criteria
1. Planning output persists: refined title/description/acceptance criteria/rubric/checker config.
2. `planning_mode` (`auto`, `always_approve`, `always_review`) is enforced in workflow behavior.
3. `start_work` is blocked when required planning artifacts are missing.
4. Rubrics remain human-readable markdown; machine-readable checker config is stored separately.
5. Existing checker handoff JSON repair mechanism is reused (not duplicated) where handoff validation fails.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: ag
     params: `ag ticket show <id> --json`
     pass signal: ticket JSON includes refined fields and checker config after planning completion.
  2. skill: command
     params: `cd server && mix test test/algedonia/tickets_test.exs test/algedonia_web/live/ticket_live_test.exs`
     pass signal: tests validate planning mode gates and start-work preconditions.

Implementation Notes
- Keep planning outcome machine-readable; avoid burying critical config only in comments.

Failure / Escalation Semantics
- Ambiguous requirements in `always_review`/`auto` modes require clarification state, not implicit approval.

Out of Scope
- External tracker interview comments (handled by tracker-sync tickets).

### ALGE-007A — Enforce Project Default Acceptance Criteria (Latest Rebase)
Priority: P0 | Size: M | Owner boundary: cross-boundary
Depends on: ALGE-007

Outcome
- Project-level default acceptance criteria are applied consistently, including a required “latest rebase” condition.

Acceptance Criteria
1. Workspace/project settings define default acceptance criteria templates.
2. Planning flow injects/merges default criteria into ticket acceptance criteria.
3. Default criteria include “branch rebased to latest default branch before checker/land.”

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: ag
     params: `ag ticket show <id> --json`
     pass signal: acceptance criteria include project default rebase condition after planning.

Implementation Notes
- Keep defaults human-readable and editable in settings.

Failure / Escalation Semantics
- If rebase freshness cannot be verified, loop fails with explicit rebase-required feedback.

Out of Scope
- Git hook scripts in every developer local environment.

### ALGE-007B — Move Iteration Budget from Per-Ticket to Per-Project
Priority: P0 | Size: M | Owner boundary: cross-boundary
Depends on: ALGE-007

Outcome
- `max_iterations`/attempt budget is configured at workspace/project level only (UI + backend), not per ticket.

Acceptance Criteria
1. Per-ticket max-attempt field is removed from ticket schema/API/UI.
2. Workspace/project settings expose and persist a single default iteration budget.
3. Orchestrator uses project-level budget for all loops unless explicitly overridden by future policy mechanisms.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/tickets_test.exs test/algedonia/task_loop_orchestrator_test.exs`
     pass signal: tests verify no per-ticket max-attempt behavior remains and project-level budget is enforced.

Implementation Notes
- Provide migration strategy for existing `tickets.max_attempts` data.

Failure / Escalation Semantics
- On missing project-level setting, use safe default and emit configuration warning.

Out of Scope
- Per-label or per-agent iteration budget policies.

### ALGE-008 — Support Safe Mid-Loop Checker Config Edits
Priority: P1 | Size: M | Owner boundary: ui
Depends on: ALGE-007

Outcome
- Steer panel edits checker config for next iteration with visible audit trail and validation.

Acceptance Criteria
1. Edits apply only from next iteration onward; in-flight checker steps remain immutable.
2. Invalid edits are rejected with user-facing validation errors.
3. Loop timeline shows when checker config changed and by whom.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: browser-check
     params: `scenario=edit checker config during running loop`
     pass signal: UI shows pending-next-iteration config and history records config revision event.

Implementation Notes
- Use optimistic UI only after server validation succeeds.

Failure / Escalation Semantics
- On validation failure, retain last good config and log rejected edit event.

Out of Scope
- Arbitrary historical replay with prior configs.

### ALGE-009 — Implement Queue Model with Dependencies
Priority: P0 | Size: L | Owner boundary: backend
Depends on: ALGE-001

Outcome
- Queue dispatchability is determined by priority + `blocked_by` dependencies, persisted and queryable.

Acceptance Criteria
1. Tickets can declare blockers (`blocked_by`) and unresolved blockers prevent dispatch.
2. Queue ordering is explicit and mutable without changing ticket identity/state.
3. Unblocking a dependency re-evaluates dependent ticket dispatchability automatically.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/queue_test.exs`
     pass signal: dependency graph tests verify blocked/unblocked dispatch behavior.

Implementation Notes
- Reuse `queue_entries` table surface where possible instead of introducing duplicate queue state.

Failure / Escalation Semantics
- Cycles in dependency graph are rejected with explicit error.

Out of Scope
- Global multi-workspace scheduling.

### ALGE-010 — Add Playback Dispatcher with Concurrency Controls
Priority: P0 | Size: L | Owner boundary: backend
Depends on: ALGE-009, ALGE-003

Outcome
- Workspace-level play/pause and concurrency controls drive automatic dispatch of eligible queued tickets.

Acceptance Criteria
1. Play/pause controls whether new loops start; pause does not kill running loops.
2. Dispatcher enforces configured concurrency ceiling and reports effective limit.
3. Blocked tickets are skipped without losing queue position.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/dispatcher_test.exs`
     pass signal: dispatcher simulation tests verify pause semantics, concurrency caps, and blocked-ticket skipping.

Implementation Notes
- Keep daemon capacity awareness separate from user-configured concurrency.

Failure / Escalation Semantics
- If no daemon capacity is available, tickets remain queued and surfaced as capacity-constrained.

Out of Scope
- Custom scheduling policies beyond priority + dependency constraints.

### ALGE-010A — Build Queue Surface in UI
Priority: P0 | Size: M | Owner boundary: ui
Depends on: ALGE-009

Outcome
- Users can see the executable queue in a dedicated left sidebar in Tickets view (ordered, dispatchability-aware) instead of only status columns.

Acceptance Criteria
1. Tickets page has a dedicated left sidebar queue surface.
2. Each queue item shows blocked/dispatchable state and blocking ticket references.
3. Queue updates in real time when dependencies/statuses change.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: browser-check
     params: `scenario=view queue with blocked and unblocked tickets`
     pass signal: queue panel shows correct order/state and updates after blocker completion.

Implementation Notes
- Keep queue as a focused operational surface; do not turn it into a second full PM board.

Failure / Escalation Semantics
- If queue state cannot load, UI must show explicit degraded-state messaging instead of stale values.

Out of Scope
- Drag-and-drop reorder controls.

### ALGE-010B — Add Queue Controls UI (Play/Pause, Concurrency, Reorder)
Priority: P0 | Size: L | Owner boundary: ui
Depends on: ALGE-010, ALGE-010A

Outcome
- Users can steer queue execution from UI with playback controls and manual ordering controls.

Acceptance Criteria
1. UI exposes play/pause control that maps to dispatcher behavior.
2. UI exposes configurable concurrency control and displays effective concurrency.
3. Users can reorder queue position (including pin-to-top and skip behavior) with immediate visible feedback.
4. Users can remove a ticket from queue back to backlog/library state from queue controls.
5. Users can set a “halt at” ticket so autoplay stops when that ticket reaches terminal state.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: browser-check
     params: `scenario=pause queue, reorder items, resume with new order`
     pass signal: dispatcher picks tickets in updated order and honors pause/concurrency settings.

Implementation Notes
- Use optimistic UI only with authoritative server reconciliation.

Failure / Escalation Semantics
- Failed control updates roll back UI state and show actionable error.

Out of Scope
- Advanced scheduling strategy editors.

### ALGE-011 — Implement Explicit Landing Pipeline (`land`)
Priority: P0 | Size: L | Owner boundary: cross-boundary
Depends on: ALGE-003, ALGE-004

Outcome
- After checker pass, system can push branch, create PR, wait for CI, and either auto-merge or await human review based on land mode.

Acceptance Criteria
1. Loop pass triggers land command with `auto_land` or `review_gate` behavior.
2. CI failure returns actionable feedback to loop retry path.
3. Successful land updates ticket status and stores PR URL/merge metadata.
4. Default merge strategy for auto-land is squash-and-merge (configurable later).

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/landing_test.exs`
     pass signal: tests cover auto-land success, review-gate wait state, and CI-fail retry behavior.

Implementation Notes
- Replace ad-hoc hook-based landing as primary path for task loops.

Failure / Escalation Semantics
- Git/PR/CI API errors mark loop as escalated with classified failure reason.

Out of Scope
- Non-squash default merge policies.

### ALGE-011A — Expose Land Mode Controls in Ticket Detail + Workspace Defaults
Priority: P0 | Size: M | Owner boundary: cross-boundary
Depends on: ALGE-011

Outcome
- Users can set `land_mode` per ticket in ticket detail view, with workspace default selection in settings.

Acceptance Criteria
1. Ticket detail view exposes `land_mode` selector (`review_gate`, `auto_land`).
2. Workspace settings expose default `land_mode` for new/unspecified tickets.
3. Loop creation resolves effective `land_mode` from ticket override or workspace default.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: browser-check
     params: `scenario=set workspace default and per-ticket override land mode`
     pass signal: effective loop land mode matches expected precedence rules.
  2. skill: command
     params: `cd server && mix test test/algedonia/workspaces_test.exs test/algedonia/tickets_test.exs`
     pass signal: settings + override behavior validated in tests.

Implementation Notes
- Show effective mode clearly in loop/ticket UI to avoid ambiguity.

Failure / Escalation Semantics
- Invalid land mode updates are rejected and do not mutate existing loop behavior.

Out of Scope
- Multi-stage merge policy workflows.

### ALGE-012 — Add Escalation Queue and Circuit Breaker Core
Priority: P2 | Size: M | Owner boundary: backend
Depends on: ALGE-010, ALGE-011, ALGE-021

Outcome
- Repeatedly failing/tapered loops enter a one-at-a-time escalation queue, and circuit breaker can halt new dispatches after escalation bursts.

Acceptance Criteria
1. Escalation queue is FIFO and exposes current + pending escalations.
2. Circuit breaker supports closed/open/half-open with explicit transition rules.
3. Dispatcher respects circuit-breaker open state.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/escalation_test.exs`
     pass signal: state-machine tests validate queue behavior and breaker transitions.

Implementation Notes
- Keep breaker thresholds configurable per workspace defaults.

Failure / Escalation Semantics
- Manual resume is required from open state; no silent auto-close.

Out of Scope
- Notification channel integrations (Slack/email).

### ALGE-013 — Upgrade Monitor UI for Escalation Operations
Priority: P2 | Size: M | Owner boundary: ui
Depends on: ALGE-012, ALGE-021

Outcome
- `/monitor` becomes an operational workspace for escalation handling, circuit-breaker state, and active-loop visibility.

Acceptance Criteria
1. Monitor shows active escalation with enough context to decide next action.
2. Monitor shows circuit-breaker state and manual controls.
3. Monitor displays configured vs effective concurrency and daemon capacity summary.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: browser-check
     params: `scenario=monitor escalation triage flow`
     pass signal: UI renders escalation queue + breaker controls and updates in real time via PubSub.

Implementation Notes
- Keep ticket board as primary navigation; monitor is for operations only.

Failure / Escalation Semantics
- If escalation details cannot load, monitor must show degraded state with retry controls.

Out of Scope
- Full PM dashboard analytics.

### ALGE-014 — Build Reflection Engine that Emits Improvement Tickets
Priority: P0 | Size: L | Owner boundary: backend
Depends on: ALGE-011

Outcome
- Landed loops can trigger reflection that outputs concrete improvement tickets (guidelines, skills, checker refinements, knowledge).

Acceptance Criteria
1. Reflection consumes loop history and human nudges to produce structured suggestions.
2. Approved reflection outputs are created as normal tickets in backlog/planning flow.
3. Reflection can produce zero tickets when no actionable signal exists.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/reflection_test.exs`
     pass signal: tests cover ticket emission, dedupe, and zero-output cases.

Implementation Notes
- Reflection must not bypass normal planning/checker gate by auto-committing changes.

Failure / Escalation Semantics
- Reflection errors never block primary loop completion; they surface as monitor warnings.

Out of Scope
- Auto-accepting reflection recommendations.

### ALGE-015 — Add Reflection Review Controls in UI
Priority: P1 | Size: M | Owner boundary: ui
Depends on: ALGE-014

Outcome
- Users can review, approve, reject, and prioritize reflection-generated tickets from UI.

Acceptance Criteria
1. Reflection suggestions are visible with source loop context.
2. Approve/reject actions are auditable and update suggestion state.
3. Approved suggestions create/queue concrete tickets with preserved context links.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: browser-check
     params: `scenario=approve reflection suggestion into ticket`
     pass signal: approved suggestion appears as new ticket with back-reference to source loop.

Implementation Notes
- Keep approval flow lightweight; no modal-heavy multi-step wizard.

Failure / Escalation Semantics
- Failed suggestion actions roll back UI state and preserve pending suggestion.

Out of Scope
- Cross-workspace suggestion routing.

### ALGE-016 — Implement Linear Tracker Sync Adapter (Post-v1)
Priority: P2 | Size: L | Owner boundary: cross-boundary
Depends on: ALGE-007, ALGE-010

Outcome
- Linear inbound/outbound sync works for ticket lifecycle and loop status/comments.

Acceptance Criteria
1. Inbound sync imports/updates active-state Linear issues into local tickets.
2. Outbound sync updates Linear status/comments with loop outcomes and PR links.
3. Sync respects cancellation/terminal states by stopping local active loops.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/tracker/linear_adapter_test.exs`
     pass signal: adapter tests validate inbound mapping, outbound status transitions, and stop-on-terminal behavior.

Implementation Notes
- Keep adapter boundary strict; do not leak Linear-specific fields into core ticket model.

Failure / Escalation Semantics
- Tracker API failures are logged/retried and never corrupt local source-of-truth state.

Out of Scope
- GitHub Issues sync.

### ALGE-017 — Publish Stable Daemon Protocol Contract and Compatibility Tests
Priority: P1 | Size: M | Owner boundary: docs
Depends on: ALGE-011

Outcome
- Server-daemon protocol is explicitly versioned and tested for backward compatibility.

Acceptance Criteria
1. Protocol spec documents commands/events, payload schemas, and error semantics.
2. Compatibility test suite validates server and daemon against protocol fixtures.
3. Breaking change policy and version negotiation are documented.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd daemon && go test ./... && cd ../server && mix test`
     pass signal: protocol contract tests pass across both runtimes.

Implementation Notes
- Treat protocol as product API, not implementation detail.

Failure / Escalation Semantics
- Contract-test failures block releases until resolved.

Out of Scope
- Third-party daemon certification program.

### ALGE-018 — Enforce Structured-Receipt Retention Boundaries
Priority: P1 | Size: M | Owner boundary: backend
Depends on: ALGE-003

Outcome
- Server retention policy guarantees structured verdict storage only, while daemon artifact access remains stream-only with bounded retention.

Acceptance Criteria
1. Server persistence excludes raw diffs/code blobs/large terminal logs beyond allowed structured receipts.
2. Daemon artifact retention policy is configurable and documented.
3. Loop view can stream required detail without violating storage boundary.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/retention_policy_test.exs`
     pass signal: tests fail if disallowed artifact payloads are persisted server-side.

Implementation Notes
- Keep evidence useful for debugging while preserving source-code boundary guarantee.

Failure / Escalation Semantics
- On retention enforcement errors, reject persistence and emit operational alert.

Out of Scope
- Enterprise external archive integrations.

### ALGE-019 — Add End-to-End User Journey Gate Suite
Priority: P1 | Size: M | Owner boundary: cross-boundary
Depends on: ALGE-011, ALGE-014

Outcome
- CI includes deterministic end-to-end gates for core user journeys: solo bug fix, team parallel tickets, overnight batch.

Acceptance Criteria
1. Automated journey tests cover planning -> loop -> checker -> land path.
2. Tests cover reflection-ticket emission path after successful land.
3. Failures produce actionable diagnostics (which stage regressed).

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `just test`
     pass signal: dedicated E2E journey suite passes in CI and local reproducible environment.

Implementation Notes
- Prefer fixture-driven deterministic tests over flaky live external integrations.

Failure / Escalation Semantics
- Journey gate failures block release.

Out of Scope
- Load/perf benchmarking.

### ALGE-020 — Build Skills Catalog and Management UI
Priority: P1 | Size: M | Owner boundary: cross-boundary
Depends on: ALGE-002

Outcome
- Workspace users can inspect and manage available skills and checker-skill usage from UI.

Acceptance Criteria
1. UI shows parsed skill catalog with name, type, source path, and validation status.
2. Invalid skills are surfaced with actionable parse/validation errors.
3. Planning and checker views can reference cataloged skills without requiring file-system spelunking.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: browser-check
     params: `scenario=open skills screen and inspect validation state`
     pass signal: skill list renders, invalid skills are flagged, and metadata matches backend registry.

Implementation Notes
- Start read-only; mutation flows (create/edit skill files) can come later.

Failure / Escalation Semantics
- If skill catalog cannot load, planning UI must show degraded mode with explicit error.

Out of Scope
- In-browser markdown editor for writing skill files.

### ALGE-021 — Build Notification Layer Foundation
Priority: P1 | Size: M | Owner boundary: backend
Depends on: ALGE-010, ALGE-011

Outcome
- Core notification pipeline exists for loop pass/fail/stuck/needs-human events, enabling later escalation and monitor-heavy workflows.

Acceptance Criteria
1. Notification domain events are persisted and queryable (status, type, target, created_at, delivered_at).
2. At least one delivery channel exists (in-app feed) with retry-safe delivery semantics.
3. Escalation/circuit-breaker tickets can consume notification events instead of inventing parallel signaling.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd server && mix test test/algedonia/notifications_test.exs`
     pass signal: event creation/delivery/idempotency tests pass.

Implementation Notes
- Keep channel abstraction minimal so Slack/email providers can be added later.

Failure / Escalation Semantics
- Delivery failures move notification to retryable failed state with reason code.

Out of Scope
- Full Slack/email integration.

### ALGE-022 — Extract Daemon to OSS Repository and Consume as Module
Priority: P1 | Size: L | Owner boundary: cross-boundary
Depends on: ALGE-017

Outcome
- Daemon is split into a standalone open-source repository and linked back into this monorepo as a versioned dependency/module.

Acceptance Criteria
1. Daemon source, build/test, and release docs live in dedicated repository with Apache-2.0 licensing.
2. Monorepo consumes daemon via explicit module/version reference (not copy-pasted source mirror).
3. CI validates server-daemon protocol compatibility across repository boundary.

Checker Proof
- Base pipeline: `just lint && just test`
- Ticket-specific checks:
  1. skill: command
     params: `cd daemon && go test ./... && cd ../server && mix test`
     pass signal: both repos build/test cleanly and integration contract tests pass.

Implementation Notes
- Keep protocol fixtures in one source of truth to avoid spec drift.

Failure / Escalation Semantics
- If repo split introduces protocol drift, block release until compatibility tests are green.

Out of Scope
- Public marketplace/distribution channels beyond GitHub releases.
