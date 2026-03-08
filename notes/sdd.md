# Algedonia SDD (Current)

## 1. Product Model
- A ticket is the unit of planning and execution.
- A loop is the unit of execution.
- Every persisted execution loop belongs directly to one `ticket_id`.
- Persisted loop roles are `task`, `hook`, and `planning`.
- Workspace/project defaults define:
  - `base_pipeline`
  - `max_iterations` (project-level iteration budget)
  - default `land_mode`
  - default acceptance criteria templates (including latest-rebase requirement)
- Tickets do not own per-ticket iteration budget.

## 2. Workflow
0. On daemon connect/startup, daemon runs setup discovery:
   - probes supported agent runtimes installed locally
   - performs agent-specific setup only for discovered runtimes (for example, Claude hooks only when Claude exists)
   - reports `available_agents` in heartbeat/registration payload
1. Ticket starts in `backlog`.
2. `start_planning` moves ticket to `planning`.
3. Planning uses a persisted planning loop to refine title/description/acceptance criteria/rubric/checker config, and injects project-default acceptance criteria.
4. `start_work` resolves the first task loop for the ticket:
   - Reuses existing task loop when present.
   - Otherwise creates a single task loop with ticket title/description/rubric.
5. Ticket moves to `in_progress`.
6. Each task-loop iteration runs:
   - maker attempt
   - commit snapshot on successful maker completion
   - checker pipeline steps (hard-gate aware, step-scoped context)
7. Loop outcomes:
   - `pass`
   - `taper-to-pass` (hard gates met + diff vs prior iteration is cosmetic)
   - `fail` / `clarify` / retry until project `max_iterations` is reached
8. If retries exhaust or human intervention is required, ticket may move to `halted`.
9. When all task loops for the ticket are passed, ticket moves to `completed`.

## 3. Roles and Agents
- Persisted loop roles:
  - `task`
  - `hook`
  - `planning`
- Daemon/runtime roles used by adapter prompt loading:
  - `maker`
  - `checker`
  - `planning`
  - `reflect`
  - `hook`
- Supported coding agents (v1):
  - `claude_code`
  - `codex`
  - `pi`
- Agent availability is daemon-scoped, discovered at setup time, and exposed as `available_agents`.
- Tickets can only dispatch maker/checker runs with agents present in the assigned daemon's `available_agents`.

## 4. Server Responsibilities
- Phoenix server is source of truth.
- Stores tickets, loops, comments, queue state, daemons, workspace state, and terminal buffers.
- Orchestrates maker/checker transitions through `TaskLoopOrchestrator`.
- Resolves effective `land_mode` from workspace default + ticket override.
- Treats daemon-reported `available_agents` as the source of truth for agent availability.
- Rejects run dispatch when selected agent is unavailable on target daemon with explicit `agent_unavailable` error.
- Routes daemon callback events in `DaemonChannel`:
  - `attempt_complete`
  - `error`
  - terminal output/diff/worktree commands

## 5. UI
- Ticket board/list is primary navigation.
- Tickets page includes a dedicated left queue sidebar.
- Queue controls include:
  - play/pause
  - concurrency
  - reorder/pin/skip
  - remove from queue back to backlog
  - halt-at checkpoint ticket
- Ticket detail view includes per-ticket `land_mode` selector and coding-agent selector filtered by daemon `available_agents`.
- Workspace settings include default `land_mode`, project-level `max_iterations`, and default acceptance criteria templates.
- Inspect flow is ticket -> loop (`/w/:workspace/tickets/:ticket_ref/loops/:loop_ref`).
- Loop view is single-loop mode with maker/checker history and terminal.
- No standalone DAG view or DAG route.

## 6. Database
### loops
- `id` (uuid, pk)
- `ticket_id` (uuid fk -> tickets)
- `title`, `description`
- `status`, `role`
- `manual_gate`
- `current_attempt`, resolved iteration budget
- `rubric`, `branch_name`
- `land_mode`
- `assigned_daemon_id`
- timestamps

Constraints:
- `role IN ('task', 'hook', 'planning')`

### daemons
- `id` (uuid, pk)
- `user_id` (uuid fk -> users)
- `status`
- `capacity`
- `available_agents` (jsonb/text array)
- `last_seen_at`, `last_setup_at`

Removed schema surface:
- `dags` table
- `loop_dependencies` table
- `loops.dag_id`
- per-ticket iteration budget fields

## 7. PubSub Topics
- `tickets`
- `ticket:{ticket_id}` comments
- `ticket_loops:{ticket_id}` loop status/hook-loop events
- `loop:{loop_id}` per-loop updates
- `terminal:{loop_or_step_id}` terminal stream events
- `queue:{workspace_id}` queue/playback updates

## 8. Migration Policy
- DAG/decomposition cleanup is implemented as a clean-start irreversible migration.
- Per-ticket iteration-budget removal is implemented as an irreversible migration.
- `down/0` raises intentionally.
