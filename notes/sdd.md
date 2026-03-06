# Algedonia SDD (Current)

## 1. Product Model
- A ticket is the unit of planning and execution.
- A loop is the unit of execution.
- Every persisted execution loop belongs directly to one `ticket_id`.
- The runtime supports maker/checker attempts on a single ticket loop, plus hook loops for automations.

## 2. Workflow
1. Ticket starts in `backlog`.
2. `start_planning` moves ticket to `planning`.
3. `start_work` resolves the first task loop for the ticket:
   - Reuses existing task loop when present.
   - Otherwise creates a single task loop with ticket title/description/rubric.
4. Ticket moves to `in_progress`.
5. Task loop runs maker then checker attempts until pass/fail/max attempts.
6. When all task loops for the ticket are passed, ticket moves to `completed`.

## 3. Roles
- Persisted loop roles:
  - `task`
  - `hook`
- Daemon runtime roles used by adapter prompt loading:
  - `maker`
  - `checker`
  - `planning`
  - `reflect`
  - `hook`

## 4. Server Responsibilities
- Phoenix server is source of truth.
- Stores tickets, loops, comments, daemons, workspace state, and terminal buffers.
- Orchestrates maker/checker transitions through `TaskLoopOrchestrator`.
- Routes daemon callback events in `DaemonChannel`:
  - `attempt_complete`
  - `error`
  - terminal output/diff/worktree commands

## 5. UI
- Ticket board/list is primary navigation.
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
- `current_attempt`, `max_attempts`
- `rubric`, `branch_name`
- `assigned_daemon_id`
- timestamps

Constraints:
- `role IN ('task', 'hook')`

Removed schema surface:
- `dags` table
- `loop_dependencies` table
- `loops.dag_id`

## 7. PubSub Topics
- `tickets`
- `ticket:{ticket_id}` comments
- `ticket_loops:{ticket_id}` loop status/hook-loop events
- `loop:{loop_id}` per-loop updates
- `terminal:{loop_or_step_id}` terminal stream events

## 8. Migration Policy
- DAG/decomposition cleanup is implemented as a clean-start irreversible migration.
- `down/0` raises intentionally.
