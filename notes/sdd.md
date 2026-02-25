# Algedonia -- System Design Document (v3)

Reference: [PRD v4](prd.md)

---

## 1. Overview

Algedonia is an agentic coding orchestration system. It coordinates AI coding agents (Claude Code, Codex, Aider) through maker-checker loops: one agent writes code, a second agent independently verifies it against a quality rubric, and the loop repeats until verification passes or a human intervenes.

The system has two components: a Phoenix LiveView server that owns all state and UI, and local daemons that run on developer machines to execute agent work. The server decides what to run. The daemons do the running.

Work is organized as tickets that decompose into DAGs of maker-checker loops. Decomposition produces both the DAG and the initial rubric for each loop in a single pass. Loops execute in parallel where possible, coordinated by file-level locking to prevent conflicts. Every passing loop produces a squash-merged commit.

---

## 2. User Interface

Three views, sharing a consistent left sidebar layout. All views update in real time via PubSub. Presence (who is viewing what) is visible in every view. Users provide a display name when connecting (stored in daemon config or browser session). This name is sent on channel join alongside the project token and used for Phoenix Presence tracking. No user accounts -- just a name string.

**Global sidebar (all views):**
- **Top section:** Navigation links to Tickets and Monitor. The Loop Inspector is the default/primary view, accessed by selecting a ticket from Tickets or navigating directly.
- **Bottom section:** User settings and collaboration panel. Shows presence (who is online, who is viewing what). Future: voice calls for real-time team communication (Discord/Slack-style).

### 2.1 Issue Tracker (`/tickets`)

A table of tickets. Each row shows: title, status, priority, type, assignee, and a compact DAG progress indicator (e.g., "4/7 loops passed"). Clicking a ticket opens a detail panel with description, acceptance criteria, rubric, the full DAG preview, and a threaded comment list.

**Interactions:**
- Create a ticket (title, description, acceptance criteria, priority, type).
- Edit any ticket field. Editing acceptance criteria updates the rubric for future attempts.
- "Start Work" button on a ticket: triggers task decomposition (which also generates rubrics), builds the DAG, and begins scheduling loops. Navigates to the Loop Inspector.
- Assign/reassign tickets to team members (determines default daemon for loop execution).
- Filter and sort by status, priority, assignee.
- Post and reply to comments on a ticket. Comments are threaded.

### 2.2 Loop Inspector (`/loops/:loop_id`)

The primary workspace. Three-column layout with information flowing left to right: DAG → Loop → Artifacts. Designed for tickets with 5--10 loops (if a ticket needs more, it should be split).

**Left panel -- DAG Tree:**
A tree view of the current ticket's loops, replacing the standalone DAG Viewer. Loops are displayed as a flat tree grouped by dependency depth. Parallel loops appear as siblings at the same indent level. Each node shows a status icon and loop title.

Status icons by state: pending (gray), running (blue), verifying (yellow), passed (green), failed (red), escalated (orange), needs_clarification (purple), pending_approval (teal).

Manual gates are visible as a property on the loop node. When a loop passes and hits a manual gate, it enters `pending_approval` and the node updates to show the gated state. The main panel shows the approval UI (diff, verdict, approve/reject).

**Interactions:**
- Click a node to load that loop's agent run in the center and right panels.
- Hover a node to see a summary: loop title, current attempt number, file locks held.
- See which loops are blocked and what they're waiting on (blocked nodes show their dependencies).
- Manual retry of a failed loop (right-click or context action).
- Skip a failed loop (marks downstream as unblocked with a warning).

**Center panel -- Terminal:**
A live terminal showing the active agent run (maker or checker). This is a full interactive terminal, not a log viewer. Output streams in near-real-time (sub-second latency target). Multiple users see the same terminal simultaneously.

Steering is native terminal interaction -- no GUI buttons for pause/resume. Users type directly into the terminal to send input to the agent's stdin. Esc to pause, ctrl+c to stop. When multiple users type simultaneously, inputs are delivered to the agent in arrival order with no coordination. This is a deliberate design choice, analogous to SSH shared sessions -- if conflicts arise, users coordinate verbally.

Both maker and checker runs are viewed identically here. The checker is just another agent run with different context (diff + rubric + acceptance criteria instead of a task description). There is no separate "checker UI" -- it is an agent session like any other.

**Approve / Reject:** Visible when a loop is in `pending_approval` status (manual gate). "Approve" triggers the merge. "Reject" sends the user's feedback to the maker for a retry. Any connected user can approve or reject, including controlling an agent running on someone else's daemon.

**Right panel -- Context (tabbed):**
- **Diff:** Current working diff vs. the base branch.
- **Rubric:** Inline editing of the quality rubric. Edits apply to the next attempt, not the current one. Includes a `manual_gate` toggle.
- **Verdict:** Structured checker results. Hard gates shown as pass/fail badges. Weighted checks with individual scores. Overall threshold indicator. This is not a pyramid visualization -- it is a structured summary of the verification layers, displayed in whatever format best communicates the result.
- **History:** Expandable list of all attempts in this loop. Each attempt shows: maker summary, checker verdict, scores, duration, token usage, and agent session ID (clickable to resume/replay the session).

### 2.3 Monitor (`/monitor`)

Operational overview for the whole project.

**Escalation queue:**
Shows one escalation at a time (one-piece flow). The queue is a live query: `SELECT * FROM loops WHERE status IN ('escalated', 'needs_clarification') ORDER BY updated_at ASC`. No separate queue table. The current escalation displays: the failing loop's diff, rejection reason (or clarification request), rubric, and attempt history. Actions: provide feedback (text that feeds into the maker's next attempt), edit rubric, skip, or manually resolve. A count badge shows remaining queued escalations.

**Circuit breaker status:**
Visual state indicator: closed (green, loops spawn freely), open (red, spawning halted), half-open (yellow, testing with one loop). Shows the trigger condition (N consecutive escalations) and a manual resume button.

**Running loops overview:**
A compact table of all currently active loops across all daemons: loop title, daemon, status, current attempt, elapsed time, files locked. Sortable by daemon to see per-machine load.

**Daemon health:**
Connected daemons, their capacity (running/max loops), and last heartbeat time.

---

## 3. System Architecture

Two components. Clear boundary.

```
+-----------------------------------------------------+
|                    Developer Machines                 |
|                                                      |
|  +-------------+  +-------------+  +-------------+   |
|  |  Daemon A   |  |  Daemon B   |  |  Daemon C   |   |
|  | (Go)        |  | (Go)        |  | (Go)        |   |
|  |             |  |             |  |             |   |
|  | - Agents    |  | - Agents    |  | - Agents    |   |
|  | - Worktrees |  | - Worktrees |  | - Worktrees |   |
|  | - PTY       |  | - PTY       |  | - PTY       |   |
|  | - LLM keys  |  | - LLM keys  |  | - LLM keys  |   |
|  +------+------+  +------+------+  +------+------+   |
|         |                |                |           |
+---------|----------------|----------------|----------+
          |                |                |
          | Phoenix Channels (WebSocket)
          |                |                |
+---------v----------------v----------------v----------+
|                                                      |
|              Phoenix LiveView Server                 |
|                                                      |
|  +------------+  +------------+  +---------------+   |
|  | LiveView   |  | Loop       |  | Lock Manager  |   |
|  | (4 views)  |  | Orchestr.  |  |               |   |
|  +------------+  +------------+  +---------------+   |
|  +------------+  +------------+  +---------------+   |
|  | Scheduler  |  | Circuit    |  | PubSub        |   |
|  |            |  | Breaker    |  |               |   |
|  +------------+  +------------+  +---------------+   |
|                                                      |
|  +------------------------------------------------+  |
|  |              PostgreSQL                         |  |
|  +------------------------------------------------+  |
|                                                      |
+------------------------------------------------------+
```

**What lives on the server:**
- All state: tickets, loops, DAGs, events, locks, daemon registrations, comments.
- All UI rendering (LiveView).
- All orchestration decisions: scheduling, assignment, circuit breaker logic.
- PubSub for real-time updates.
- Terminal buffer relay (server receives PTY output from daemons, fans it out to browser clients).

**What lives on the daemon:**
- Agent processes (Claude Code, Codex, Aider).
- Git worktrees.
- PTY management (capture and stream).
- LLM API credentials (environment variables). Never sent to the server.
- Local compute resources.

**The boundary principle:** The server never executes agents or touches LLM APIs. The daemon never makes orchestration decisions. The server says "run this." The daemon runs it and reports back.

**Communication:** Persistent WebSocket connections via Phoenix Channels. Each daemon maintains one connection to the server, authenticated with the project token. The user's display name is sent alongside the token on join. The server pushes commands down; the daemon pushes events and terminal data up.

---

## 4. Server Design

### 4.1 Routes and LiveView Modules

| Route | LiveView Module | Description |
|---|---|---|
| `/tickets` | `TicketLive.Index` | Ticket list with inline detail panel |
| `/tickets/:id` | `TicketLive.Show` | Single ticket detail (redirects to index with panel open) |
| `/loops/:loop_id` | `LoopLive.Show` | Loop inspector with DAG tree, terminal, and context panels |
| `/monitor` | `MonitorLive.Index` | Escalation queue, circuit breaker, overview |

Each LiveView module subscribes to relevant PubSub topics on mount and handles incoming broadcasts to update its assigns.

### 4.2 Database Schema

See Section 9 for full table definitions. Summary of tables:

- `tickets` -- issue tracker state.
- `comments` -- threaded comments on tickets.
- `dags` -- one per ticket, metadata for the decomposition.
- `loops` -- individual maker-checker loops within a DAG.
- `loop_dependencies` -- edges in the DAG (loop A must complete before loop B).
- `loop_attempts` -- each maker-checker round within a loop.
- `file_locks` -- currently held path-prefix locks.
- `events` -- append-only event log for all state transitions.
- `daemon_registrations` -- connected daemons and their capacity.

### 4.3 PubSub Channels

Phoenix PubSub (backed by `Phoenix.PubSub.PG2` for single-node, upgradeable to Redis adapter if needed).

| Topic | Payload | Subscribers |
|---|---|---|
| `ticket:{id}` | Ticket field changes, status transitions, new comments | `TicketLive`, `LoopLive` |
| `dag:{ticket_id}` | Loop status changes within a DAG | `LoopLive` (DAG tree panel) |
| `loop:{id}` | Attempt updates, checker scores, status changes | `LoopLive` |
| `terminal:{loop_id}` | PTY output chunks (binary) | `LoopLive` (terminal component) |
| `monitor` | Escalation events, circuit breaker transitions, daemon health | `MonitorLive` |
| `presence` | User join/leave per view (display name + view) | All views |

Terminal data gets special treatment: it flows daemon -> server Channel -> PubSub -> LiveView -> browser. The server holds a scrollback buffer (configurable, default 10,000 lines) per active terminal so that late-joining viewers see recent history. This buffer is in-memory only.

### 4.4 Key Server-Side Processes

These are OTP processes (GenServers or state machines) supervised under the application tree.

**Loop Orchestrator (`Algedonia.Orchestrator`):**
Owns the lifecycle of every loop. Responds to events (daemon reports attempt complete, checker verdict received) and decides the next action: retry maker, escalate, halt for clarification, hold for manual approval, mark passed, trigger downstream loops. Persists every state transition to the `events` table before acting on it.

**Scheduler (`Algedonia.Scheduler`):**
When a ticket's DAG is created or a loop completes, the scheduler identifies newly-unblocked loops and attempts to assign them. Assignment logic:
1. Check file lock availability (via Lock Manager).
2. Pick daemon: ticket creator's daemon if online and has capacity; otherwise, least-loaded available daemon.
3. If no daemon has capacity or locks conflict, the loop stays in `ready` state and is rechecked on the next scheduling pass (triggered by loop completions or daemon capacity changes).

**Lock Manager (`Algedonia.LockManager`):**
GenServer holding the active lock set (mirrored in PostgreSQL for crash recovery). Operations: `acquire(loop_id, path_prefixes)` and `release(loop_id)`. Acquisition is atomic -- all-or-nothing. Conflict check is prefix overlap: lock `src/auth/` conflicts with `src/auth/jwt.ex` and vice versa.

**Circuit Breaker (`Algedonia.CircuitBreaker`):**
State machine with three states: `closed`, `open`, `half_open`. Transitions:
- `closed -> open`: N consecutive escalations (N configurable, default 3).
- `open -> half_open`: manual resume by a user.
- `half_open -> closed`: the test loop passes.
- `half_open -> open`: the test loop escalates.

When open, the scheduler stops dispatching new loops. In-flight loops continue to completion.

### 4.5 Server-Daemon Communication

Phoenix Channels over WebSocket. One channel per daemon: `daemon:{daemon_id}`.

The server pushes commands to the daemon:

| Command | Payload |
|---|---|
| `start_loop` | loop_id, repo_url, base_branch, task description, rubric, agent config, role (maker, checker, decompose, decompose_checker, impact_analysis, reflect), knowledge_context, prior_attempts, diff (checker/decompose_checker only), prompts_dir |
| `stop_loop` | loop_id, reason |
| `stdin_input` | loop_id, data (user terminal input -- steering, pause via esc, stop via ctrl+c) |
| `squash_and_push` | loop_id, base_branch |

The daemon pushes events to the server:

| Event | Payload |
|---|---|
| `terminal_output` | loop_id, data (binary PTY output) |
| `attempt_complete` | loop_id, attempt_number, result (diff, exit_code, session_id) |
| `loop_result` | loop_id, status (passed/failed/error), scores, feedback, verdict (pass/fail/clarify) |
| `heartbeat` | running_loops, capacity, timestamp |
| `error` | loop_id (optional), error description |

---

## 5. Daemon Design

### 5.1 Language Choice

Go.

Rationale: The daemon is a thin process manager. It spawns subprocesses, manages PTYs, does file operations (git worktrees), and maintains a WebSocket connection. Go's standard library covers all of this without external dependencies. Cross-compilation to Mac and Linux is trivial (`GOOS=darwin/linux`). Single static binary, no runtime dependencies. Goroutines handle concurrent loop execution naturally.

Rust would also work but adds complexity (borrow checker, longer compile times, steeper contributor onboarding) for a component that does not need Rust's performance characteristics. The daemon is I/O-bound, not CPU-bound. Go is the more boring choice.

### 5.2 Connection to Server

On startup, the daemon connects to the server's WebSocket endpoint with the project token and a display name (from daemon config). The connection is persistent. If it drops, the daemon reconnects with exponential backoff. During disconnection, running agents continue (they don't depend on the server connection), and terminal output is buffered locally up to a configurable limit.

The daemon sends a heartbeat every 10 seconds with: number of running loops, max capacity (configurable, default 3 concurrent loops), and system resource snapshot (CPU, memory).

### 5.3 Command Handling

The daemon receives commands on its channel and dispatches them:

- **`start_loop`**: Create a worktree (unless role is `reflect` or `decompose_checker`), configure the agent adapter, spawn the agent process. The role field determines behavior: `maker`, `checker`, `decompose`, `decompose_checker`, `impact_analysis`, or `reflect`. The `decompose` and `decompose_checker` roles form a maker-checker loop for task decomposition (see Section 8.3). Details in 5.4 and 5.5.
- **`stop_loop`**: Send SIGTERM to the agent process, wait for graceful exit (5s timeout), then SIGKILL. Clean up worktree.
- **`stdin_input`**: Write data to the agent's PTY master fd. This is how user steering reaches the agent. All interaction (typing, esc to pause, ctrl+c to stop) flows through this single channel -- there are no separate pause/resume commands.
- **`squash_and_push`**: Squash-rebase the loop's worktree commits onto the specified base branch, push to remote, and clean up the worktree. Reports success or failure back to the server.

### 5.4 Agent Lifecycle

Each loop execution follows this sequence:

1. **Worktree creation**: `git worktree add` from the repo's shared `.git` directory. Base branch is specified by the server. (Skipped for `reflect` role, which needs no worktree.)
2. **Prompt loading**: The daemon reads prompts from `.algedonia/prompts/` in the repo (see Section 10.2). The appropriate system prompt and task template are selected based on the role.
3. **Agent spawn**: The daemon selects the configured agent adapter (Claude Code, Codex, or Aider) and spawns it as a child process inside the worktree directory. The agent is given: the task description, rubric, loaded prompts, and any feedback from previous attempts (all provided by the server in the `start_loop` command). LLM credentials come from the daemon's environment variables.
4. **Monitoring**: The daemon watches the child process. It captures stdout/stderr via PTY and streams it to the server. It detects process exit (normal or crash).
5. **Completion**: When the agent exits, the daemon collects the result: the git diff produced, exit code, agent session ID, and any structured output the agent wrote. It sends `attempt_complete` to the server. The session ID is persisted so the session can later be resumed or replayed via the agent's `--resume` flag.

If the agent crashes, the daemon reports an error to the server. The server decides whether to retry.

### 5.5 Worktree Management

The daemon manages a local clone of the repository. All worktrees branch from this clone.

- **Creation**: `git worktree add /path/to/worktrees/<loop_id> <base_branch>`. Each loop gets a unique directory.
- **During execution**: The agent works freely inside its worktree. Commits are local.
- **On success (squash_and_push command)**: `git rebase <base_branch>` then squash and `git push origin <loop_branch>`. The server separately handles any integration (the actual merge into the main branch is a server-coordinated operation that happens after checker pass).
- **Cleanup**: `git worktree remove <loop_id>`. Pruned on daemon shutdown.
- **Repo sync**: Standard `git fetch` before creating a new worktree to ensure the base branch is current. No custom sync protocol.

### 5.6 Terminal Bridging

The daemon allocates a PTY (pseudo-terminal) for each agent process. This gives full terminal emulation: ANSI codes, cursor movement, interactive prompts.

- The daemon reads from the PTY master fd in a goroutine.
- Output is chunked (by time: flush every 50ms, or by size: flush at 4KB, whichever comes first) and sent to the server as `terminal_output` events.
- User input (from `stdin_input` commands) is written to the PTY master fd, which the agent's process reads as stdin. All steering flows through this channel: typing to direct the agent, esc to pause, ctrl+c to stop. When multiple users send input simultaneously, inputs are delivered in arrival order with no coordination or locking. This mirrors the behavior of SSH shared sessions -- users coordinate verbally if conflicts arise.

### 5.7 Health Reporting

The heartbeat message (every 10 seconds) includes:
- Number of running loops (and their loop IDs).
- Max concurrent loops (from daemon config).
- Available capacity (max minus running).
- Basic system metrics (CPU load, available memory).

If the server doesn't receive a heartbeat for 30 seconds, it marks the daemon as unhealthy. Loops assigned to an unhealthy daemon are not immediately killed -- the server waits for reconnection. After 5 minutes of silence, the server marks the daemon as offline and reassigns its pending (not yet started) loops.

---

## 6. The Maker-Checker Loop (End-to-End Flow)

This walks through the complete lifecycle from button press to merged commit.

**Preconditions:** A ticket exists with title, description, and acceptance criteria. A daemon is connected with available capacity.

### Step 1: Start Work (Decomposition as a Maker-Checker Loop)

User clicks "Start Work" on a ticket in the Issue Tracker view.

Decomposition is a maker-checker loop, not a special one-shot agent call. It uses the same orchestration machinery as every other loop.

- **Server (Orchestrator):** Transitions ticket status to `decomposing`. Creates a synthetic decomposition loop (not yet part of a DAG -- it *produces* the DAG). Assigns it to the ticket creator's daemon. The loop's rubric is the decomposition rubric (see Section 8.3).
- **Maker phase:** The daemon spawns the decomposition agent with role `decompose`. The agent analyzes the ticket and produces a DAG of loops, each with a title, description, file impact estimate, and rubric. The agent scans the repo to detect existing tooling (test frameworks, linters, type checkers) and uses the ticket's acceptance criteria to generate per-loop rubrics.
- **Checker phase:** The daemon spawns the checker agent with role `decompose_checker`. The checker verifies the proposed DAG against the decomposition rubric: scope reduction (every subtask strictly smaller than parent), leaf node criteria (context fit + verification constraint), rubric well-formedness (parses per Section 7.4), DAG validity (acyclic, plausible edges), and coverage (leaf tasks cover all acceptance criteria). The checker has no access to the maker's reasoning.
- **Verdict routing:** Same as any other loop. On `pass`, the server creates `loops`, `loop_dependencies`, and `dags` rows and transitions the ticket to `in_progress`. On `fail` with attempts remaining, the maker retries with checker feedback. On `clarify`, the checker explains what's ambiguous in the ticket and it escalates to the human. On max attempts exhausted, escalate.
- **Server:** On pass, broadcasts to `ticket:{id}` and `dag:{ticket_id}`.
- **Failure handling:** Standard loop escalation. The decomposition loop appears in the escalation queue like any other failed loop. The user can edit the ticket and retry. The circuit breaker counts decomposition escalations the same as any other.

### Step 2: Impact Analysis and Scheduling

For each loop in the DAG with no unmet dependencies (root nodes):

- **Server (Scheduler):** Transitions loop to `ready`. Triggers impact analysis: sends a `start_loop` command with role `impact_analysis` to the target daemon to run a lightweight agent call that produces path prefixes for the loop's expected file changes. The agent examines the current codebase state (late binding).
- **Daemon:** Runs impact analysis, returns path prefixes.
- **Failure handling:** If the impact analysis agent fails, retry up to 3 times with exponential backoff. On final failure, escalate to the human -- the loop cannot be scheduled without file locks.
- **Server (Lock Manager):** Attempts to acquire locks for the returned path prefixes. If successful, the loop proceeds. If locks conflict with an active loop, the loop stays in `ready` and waits.
- **Server (Scheduler):** Assigns the loop to a daemon. Default: ticket creator's daemon. If offline or at capacity, picks the least-loaded available daemon. Transitions loop to `assigned`.

### Step 3: Maker Execution

- **Server:** Sends `start_loop` command to the assigned daemon with role `maker`. Payload includes: task description, rubric, codebase knowledge context (from `.algedonia/knowledge.md`), prompts directory path, and any prior attempt feedback (empty on first attempt).
- **Daemon:** Loads prompts from `.algedonia/prompts/`, creates worktree, spawns maker agent. Streams terminal output to server.
- **Server:** Relays terminal output to all `LoopLive` subscribers via PubSub. Loop status: `running_maker`. Users see the agent working in the Loop Inspector.
- **Daemon:** Agent completes. Daemon sends `attempt_complete` with the diff, exit status, and agent session ID.

### Step 4: Checker Execution

- **Server (Orchestrator):** Receives maker result. Transitions loop to `running_checker`. Sends `start_loop` command to the same daemon (to reuse the existing worktree) with role `checker`. Payload includes: the diff produced by the maker, the original task description, the quality rubric, and acceptance criteria. Crucially, the checker does NOT receive the maker's conversation history or reasoning.
- **Daemon:** Spawns checker agent in the same worktree (maker's changes are present). The checker runs the verification pyramid: static checks, tests, generative tests, runtime checks, semantic checks. Each layer produces pass/fail and confidence.
- **Daemon:** Checker completes. Sends `loop_result` with scores per layer, overall verdict (`pass`, `fail`, or `clarify`), feedback text, and agent session ID.

### Step 5: Verdict

- **Server (Orchestrator):** Evaluates the checker's result against the merge gate (weighted threshold plus hard gates).

**If verdict is `pass`:**
- Check if the loop's rubric has `manual_gate: true`.
  - **If manual gate is set:** Transition loop to `pending_approval`. Broadcast to `loop:{id}` and `monitor`. The loop holds here until a human reviews it in the Loop Inspector and clicks "Approve" or "Reject."
    - **Approve:** Proceed with the merge flow below.
    - **Reject:** The human provides feedback. Transition loop back to `running_maker` with the feedback. Return to Step 3.
  - **If no manual gate:** Proceed immediately.
- Transition loop to `passed`.
- Record the attempt in `loop_attempts` (including agent session ID).
- Append a `loop_passed` event.
- Release file locks (Lock Manager).
- Send `squash_and_push` command to daemon with `{loop_id, base_branch}`.
- **Daemon:** Squash-rebases commits onto base branch, pushes to remote, cleans up worktree.
- **Server:** Trigger per-loop reflection (see Section 10). Check if all loops in the DAG are passed; if so, transition ticket to `completed`.
- **Server (Scheduler):** Run a scheduling pass -- newly unblocked downstream loops and waiting loops may now proceed.

**If verdict is `fail`, attempts remaining:**
- Record the attempt (including agent session ID). Append a `checker_rejected` event.
- Increment attempt counter. Transition loop to `running_maker` for the next attempt.
- Send `start_loop` to daemon with role `maker`, including the checker's feedback and full attempt history (compressed summaries of older attempts, full detail on the most recent).
- Return to Step 3.

**If verdict is `fail`, max attempts exhausted:**
- Transition loop to `escalated`.
- Record the attempt. Append an `escalated` event.
- Release file locks (the loop is not actively running).
- **Server (Circuit Breaker):** Increment consecutive escalation counter. If threshold reached, transition to `open`.
- Broadcast to `monitor` topic.
- The loop waits for human intervention.

**If verdict is `clarify`:**
- Transition loop to `needs_clarification`.
- Record the attempt (including agent session ID). Append a `needs_clarification` event.
- Release file locks (the loop is halted).
- The checker's feedback explains what requirements are missing or ambiguous. The server automatically posts this as a comment on the parent ticket (via the `comments` table).
- Broadcast to `loop:{id}`, `ticket:{ticket_id}`, and `monitor` topics.
- The loop halts. It appears in the escalation queue alongside regular escalations but is visually distinct (clarification request vs. failure).
- **Human response:** The user reads the clarification comment, updates the ticket (adds requirements, fixes acceptance criteria), and optionally replies with a comment. When the ticket is updated, the user clicks "Resume" on the halted loop. The loop transitions back to `running_maker` with the updated ticket context.

### Step 6: Human Intervention (on escalation)

User sees the escalation in the Monitor view. Options:
- **Provide feedback:** Text goes into the next maker attempt. Loop transitions back to `running_maker`.
- **Edit rubric:** Updated rubric applies to the next attempt.
- **Skip:** Loop marked as `skipped`. Downstream loops are unblocked with a warning flag.
- **Manually resolve:** User fixes the code themselves. Loop marked as `resolved`.

After resolution, the scheduler runs again to pick up unblocked work.

---

## 7. Key Interfaces

These are the stable contracts that allow internals to be swapped.

### 7.1 Server-Daemon Protocol

All messages are JSON over Phoenix Channels. The channel topic is `daemon:{daemon_id}`.

**Server -> Daemon commands:**

```
start_loop:
  loop_id: string
  role: "maker" | "checker" | "decompose" | "decompose_checker" | "impact_analysis" | "reflect"
  repo_url: string
  base_branch: string
  task: {description: string, acceptance_criteria: string}
  rubric: string (markdown)
  knowledge_context: string
  prior_attempts: [{attempt_number, summary, checker_feedback, session_id}]
  agent: {type: "claude_code" | "codex" | "aider", config: map}
  diff: string (only for checker/decompose_checker role)
  proposed_dag: object (only for decompose_checker role -- the DAG produced by the decompose maker)
  prompts_dir: string (path to .algedonia/prompts/ in the repo)

stop_loop:
  loop_id: string
  reason: string

stdin_input:
  loop_id: string
  data: binary  # all user interaction: typing, esc (pause), ctrl+c (stop)

squash_and_push:
  loop_id: string
  base_branch: string
```

**Daemon -> Server events:**

```
terminal_output:
  loop_id: string
  data: binary
  timestamp: integer (unix ms)

attempt_complete:
  loop_id: string
  attempt_number: integer
  diff: string
  exit_code: integer
  files_changed: [string]
  session_id: string (agent session ID for resume/replay)

loop_result:
  loop_id: string
  verdict: "pass" | "fail" | "clarify" | "error"
  scores: {static: score, deterministic: score, generative: score,
           runtime: score, semantic: score}
  feedback: string
  hard_gate_failures: [string]
  session_id: string

heartbeat:
  daemon_id: string
  running_loops: [string]
  capacity: integer
  system: {cpu_percent: float, memory_available_mb: integer}

error:
  loop_id: string | null
  message: string
  recoverable: boolean
```

Where `score` is `{passed: boolean, confidence: float, details: string}`.

### 7.2 Agent Adapter Interface

The daemon must be able to drive any supported coding agent. The adapter interface (implemented in Go as an interface type):

- `Start(workdir string, task string, config map) -> Process`
- `AttachPTY(process Process) -> (reader, writer)`
- `SendInput(process Process, data []byte)`
- `Wait(process Process) -> ExitResult`
- `Kill(process Process)`
- `SessionID(process Process) -> string`

Each agent type (Claude Code, Codex, Aider) has an adapter that knows how to:
1. Construct the correct CLI invocation.
2. Pass the task description via the appropriate mechanism (CLI args, stdin, config file).
3. Load and apply the appropriate system prompt from `.algedonia/prompts/`.
4. Collect the result (diff, exit code, session ID, structured output if available).

The adapter does not interpret the agent's output. It captures it and forwards it. The server decides what the output means.

### 7.3 Lock Manager Interface

Internal Elixir interface (GenServer calls):

- `acquire(loop_id, [path_prefix]) -> :ok | {:conflict, conflicting_loop_id}`
- `release(loop_id) -> :ok`
- `check(loop_id, [path_prefix]) -> :available | {:conflict, conflicting_loop_id}`
- `list_active() -> [{loop_id, [path_prefix]}]`

Atomicity guarantee: `acquire` either locks all requested prefixes or none.

### 7.4 Rubric Format

Rubrics are Markdown documents with a specific structure:

```
## Hard Gates
- [ ] Typechecks pass (typecheck)
- [ ] No critical security findings (security)

## Weighted Checks
- [ ] All existing tests pass (weight: 3) (deterministic)
- [ ] New code has test coverage (weight: 2) (deterministic)
- [ ] No lint warnings introduced (weight: 1) (static)
- [ ] Performance within budget (weight: 2) (runtime)

## Acceptance Criteria
- [ ] JWT tokens expire after 24 hours (semantic)
- [ ] Refresh token rotation works (semantic)

## Threshold
Weighted score >= 0.8

## Options
manual_gate: false
```

Parenthetical tags map checks to verification pyramid layers. The checker agent parses this format. Hard gates must all pass regardless of weighted score. The `manual_gate` option, when set to `true`, causes the loop to enter `pending_approval` status after a checker pass instead of auto-merging.

---

## 8. Coordination Mechanisms

### 8.1 File-Level Locking

Locks use path prefixes, not exact file paths. A lock on `src/auth/` covers all files under that directory.

**Conflict detection:** Two sets of path prefixes conflict if any prefix from set A is a prefix of any prefix in set B, or vice versa. Example: `src/auth/` conflicts with `src/auth/jwt.ex` and with `src/`. It does not conflict with `src/api/`.

**Lifecycle:**
1. Impact analysis produces path prefixes for a loop.
2. Scheduler calls Lock Manager `acquire` before dispatching the loop.
3. If conflict, the loop stays in `ready` state. The scheduler retries on every scheduling pass.
4. On loop completion (pass, fail-and-escalated, skip, needs_clarification), locks are released.
5. Scheduling pass runs after every lock release to unblock waiting loops.

**Persistence:** Active locks are stored in the `file_locks` table. On server restart, locks are reconstructed from this table. Locks for loops whose daemons are confirmed offline are released during recovery.

### 8.2 Impact Analysis

Triggered when a loop transitions to `ready`. The server sends a `start_loop` command with role `impact_analysis` to the target daemon. The daemon runs a lightweight agent call: given the task description and current codebase, predict which files/directories will be modified.

The agent returns a list of path prefixes (e.g., `["src/auth/", "test/auth/", "config/auth.exs"]`). These are stored on the loop record and used for lock acquisition.

**Late binding:** Impact analysis runs against the codebase as it exists at scheduling time, not at ticket creation time. This accounts for files that have been created, moved, or deleted by previously completed loops.

**Accuracy tradeoff:** Impact analysis is a prediction. It may be wrong -- an agent might touch files outside its predicted set. This is acceptable in v1 because: (a) each loop works in an isolated worktree so unexpected file changes don't corrupt other loops, and (b) the squash-rebase step will surface conflicts if two loops touched the same file despite non-overlapping predictions. The risk is a merge conflict at push time, not data corruption. The mitigation is that agents are instructed to stay within scope, and the checker verifies scope adherence.

### 8.3 Task Decomposition

Decomposition is a maker-checker loop. It uses the same loop machinery as all other work -- retry with feedback, escalation, circuit breaker, human intervention. There is no special-case orchestration for decomposition.

The decomposition maker receives the ticket (title, description, acceptance criteria) and the current repository state. It produces a DAG of loops and an initial rubric for each loop.

**Decomposition rubric (verified by the checker):**

The decomposition checker evaluates the proposed DAG against five criteria:

1. **Scope reduction:** Every subtask is strictly smaller than its parent -- fewer files, narrower concern, less estimated context. No subtask may restate or be equivalent to the parent task. This is a structural termination guarantee: because each level of decomposition must strictly reduce scope, the recursion is well-founded and must bottom out regardless of depth. (Inspired by scope-reduction invariants in recursive agent architectures.)
2. **Leaf node criteria:** Every leaf node satisfies both:
   - **Context fit:** The task fits within a single agent context window.
   - **Verification constraint:** The task has a testable, measurable outcome with a concrete rubric.
3. **Rubric well-formedness:** Every per-loop rubric parses correctly against the format in Section 7.4 (hard gates, weighted checks, threshold, options).
4. **DAG validity:** The graph is acyclic. Dependency edges are plausible (e.g., a test loop depends on the implementation loop, not vice versa).
5. **Coverage:** The union of all leaf tasks covers the original ticket's acceptance criteria. Nothing is dropped or invented.

**Rubric generation during decomposition:**

The decomposition maker scans the repository to detect:
- Test frameworks in use (e.g., ExUnit, pytest, Jest).
- Linters and formatters (e.g., Credo, ESLint, mix format).
- Type checkers (e.g., Dialyzer, mypy, TypeScript).
- CI configuration that reveals quality gates.

It combines this repo context with the ticket's acceptance criteria to generate a tailored rubric for each loop. The rubric follows the format in Section 7.4. Humans can review and edit these rubrics at any time, including before execution begins.

**Output:** A list of loops (title, description, rubric) and a list of dependency edges, forming a DAG.

**Why a loop, not a one-shot call:** Decomposition is the highest-leverage step -- a bad DAG wastes all downstream work. Making it a loop means (a) the checker catches structural problems (missing coverage, scope violations, malformed rubrics) before any code-writing begins, (b) the maker gets feedback and retries, and (c) on persistent failure, the human sees a clear escalation with the checker's explanation of what's wrong, rather than a generic "decomposition failed" error.

### 8.4 DAG Execution

Each ticket's loop DAG is a directed acyclic graph stored as nodes (`loops` table) and edges (`loop_dependencies` table).

**Topological execution:**
- When a DAG is created, all root nodes (no incoming edges) are immediately eligible for scheduling.
- When a loop completes (passes or is skipped), the scheduler checks all its dependents. A dependent loop becomes eligible when all of its dependencies are satisfied.
- Eligible loops are dispatched in parallel, constrained by daemon capacity and file lock availability.

**Failure propagation:**
- When a loop escalates or needs clarification, its downstream dependents are *not* automatically failed. They remain in `pending` state, blocked.
- The human resolves the escalation (retry, skip, or fix). Once resolved, dependents become eligible.
- If a loop is skipped, its dependents proceed but carry a `degraded` flag indicating an upstream skip. The checker for downstream loops is informed of this.

### 8.5 Circuit Breaker

A finite state machine tracked in memory (GenServer) and persisted to the database for crash recovery.

```
         N consecutive
         escalations
 CLOSED ──────────────> OPEN
   ^                      |
   |   test loop          | manual
   |   passes             | resume
   |                      v
   +─────────────── HALF_OPEN
         test loop
         escalates -> back to OPEN
```

**When open:** The scheduler stops dispatching new loops. Already-running loops finish naturally. The Monitor view prominently displays the open state and the triggering escalations.

**Manual resume:** A user reviews the situation (likely a bad rubric or systemic issue) and clicks "Resume." One loop is dispatched as a test.

**Scope:** The circuit breaker is global (project-wide). A per-ticket circuit breaker is a future consideration.

---

## 9. Data Model

### tickets

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| title | text | Not null |
| description | text | |
| status | text | `backlog`, `decomposing`, `decomposition_failed`, `in_progress`, `completed`, `archived` |
| type | text | `feature`, `bug`, `chore`, `spike` |
| priority | integer | 1 (highest) to 5 (lowest) |
| assignee | text | Username or identifier |
| acceptance_criteria | text | Markdown checkboxes |
| rubric | text | Markdown (see Section 7.4) |
| inserted_at | timestamptz | |
| updated_at | timestamptz | |

Index: `status`, `priority`, `assignee`.

### comments

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| ticket_id | uuid | FK -> tickets. Not null |
| parent_id | uuid | FK -> comments. Nullable. Null = top-level comment |
| author | text | Display name of user or `system` for auto-generated comments |
| body | text | Markdown content |
| created_at | timestamptz | |

Index: `ticket_id`, `created_at`, `parent_id`.

Comments are displayed in the Issue Tracker's ticket detail view as a threaded list, ordered by `created_at`. When a checker issues a `clarify` verdict, the system automatically posts a comment on the ticket with the checker's feedback explaining what requirements are missing. Users reply to clarify. This comment thread serves as the discussion record for clarification requests.

### dags

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| ticket_id | uuid | FK -> tickets. Unique (one DAG per ticket). |
| status | text | `running`, `completed`, `failed` |
| inserted_at | timestamptz | |
| updated_at | timestamptz | |

Index: `ticket_id` (unique).

### loops

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| dag_id | uuid | FK -> dags |
| title | text | Short description of this loop's task |
| description | text | Full task for the maker |
| status | text | `pending`, `ready`, `assigned`, `running_maker`, `running_checker`, `passed`, `failed`, `escalated`, `needs_clarification`, `pending_approval`, `skipped`, `resolved` |
| manual_gate | boolean | Default false. When true, checker pass enters `pending_approval` instead of auto-merging |
| assigned_daemon_id | uuid | FK -> daemon_registrations, nullable |
| current_attempt | integer | Default 0 |
| max_attempts | integer | Default 3 |
| path_prefixes | text[] | PostgreSQL array, set by impact analysis |
| rubric | text | Generated by decomposition, may be overridden per-loop |
| branch_name | text | Git branch for this loop's worktree |
| inserted_at | timestamptz | |
| updated_at | timestamptz | |

Indexes: `dag_id`, `status`, `assigned_daemon_id`.

**Loop state machine:**

```
pending -> ready -> assigned -> running_maker -> running_checker
                                     ^                |
                                     |                v
                                     |         [verdict routing]
                                     |           /    |    \
                                     |        pass   fail  clarify
                                     |         |      |      |
                                     |         v      |      v
                                     |  pending_approval |  needs_clarification
                                     |    |       |    |
                                     |  approve reject |
                                     |    |       |    |
                                     |    v       +----+----> running_maker (retry)
                                     |  passed         |
                                     |                 v
                                     +---- fail (attempts remaining) -> running_maker
                                                       |
                                             fail (max attempts) -> escalated

Terminal states: passed, skipped, resolved
Halted states (await human): escalated, needs_clarification, pending_approval
```

### loop_dependencies

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| upstream_loop_id | uuid | FK -> loops |
| downstream_loop_id | uuid | FK -> loops |

Index: unique on `(upstream_loop_id, downstream_loop_id)`. Index on `downstream_loop_id` for "what blocks me?" queries.

### loop_attempts

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| loop_id | uuid | FK -> loops |
| attempt_number | integer | |
| role | text | `maker` or `checker` |
| status | text | `running`, `completed`, `error` |
| diff | text | The code diff produced (maker) or reviewed (checker) |
| verdict | text | `pass`, `fail`, `clarify`, `error` (checker only) |
| scores | jsonb | Verification pyramid scores |
| feedback | text | Checker feedback to maker |
| session_id | text | Agent session ID for resume/replay via `--resume` flag |
| token_usage | jsonb | `{input: int, output: int}` |
| duration_ms | integer | |
| inserted_at | timestamptz | |

Indexes: `loop_id`, `(loop_id, attempt_number)`.

No raw terminal transcripts are stored. The `session_id` is the handle for replaying or resuming an agent session. Sessions are managed by the agent itself (e.g., Claude Code stores session data locally). The daemon invokes `--resume <session_id>` to replay.

### events

| Column | Type | Notes |
|---|---|---|
| id | bigserial | PK, monotonically increasing |
| entity_type | text | `ticket`, `loop`, `attempt`, `circuit_breaker`, `daemon` |
| entity_id | uuid | |
| event_type | text | e.g., `status_changed`, `assigned`, `escalated`, `needs_clarification`, `lock_acquired`, `approved`, `rejected` |
| payload | jsonb | Event-specific data |
| actor | text | Display name, daemon_id, or `system` |
| inserted_at | timestamptz | |

Index: `(entity_type, entity_id)`, `inserted_at`. This is append-only. No updates, no deletes. Used for audit trail and replay.

### file_locks

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| loop_id | uuid | FK -> loops. Unique (one lock set per loop). |
| path_prefixes | text[] | PostgreSQL array |
| acquired_at | timestamptz | |

Index: `loop_id` (unique).

### daemon_registrations

| Column | Type | Notes |
|---|---|---|
| id | uuid | PK |
| name | text | Human-readable daemon name (e.g., hostname) |
| display_name | text | User's display name for Presence tracking |
| status | text | `online`, `unhealthy`, `offline` |
| capacity | integer | Max concurrent loops |
| running_loops | integer | Current count |
| last_heartbeat_at | timestamptz | |
| connected_at | timestamptz | |

Index: `status`.

### Cleanup Policy

- **Worktrees:** Cleaned up by the daemon after loop completion (via `squash_and_push` response) or on daemon restart (prune orphans).
- **Events:** Retained indefinitely (they are the audit log). Partition by month if table grows large.
- **Loop attempts:** Retained for the life of the project. Diffs may be large; consider moving raw diffs to blob storage in a future version.
- **Daemon registrations:** Rows for `offline` daemons older than 30 days are soft-deleted.
- **Agent sessions:** Stored locally on the daemon by the agent runtime. Not managed by Algedonia. Session IDs in `loop_attempts` are references, not copies.
- **Terminal scrollback buffers:** In-memory only on the server (not persisted to DB). Lost on server restart. This is acceptable -- the agent session ID in `loop_attempts` provides the durable handle for replay. The event log and attempt records are the durable audit trail.

---

## 10. Reflection, Knowledge, and Prompts

### 10.1 Reflection Flow

After each loop passes, the server triggers a reflection step.

1. **Server** sends a `start_loop` command to the daemon with role `reflect` (a lightweight variant -- no worktree needed, just an agent call).
2. **Daemon** spawns an agent with context: the loop's task, the final diff, all attempt summaries, checker feedback from failed attempts, and the current contents of `.algedonia/knowledge.md`.
3. **Agent** produces a structured reflection: what patterns worked, what pitfalls were encountered, any useful commands or configurations discovered, and any rubric tightening suggestions.
4. **Daemon** returns the reflection text.
5. **Server** appends the reflection to the `.algedonia/knowledge.md` file in the repository via a commit on the main branch. The commit is made by the daemon (it has repo access).

**Failure handling:** If the reflection agent fails, retry up to 3 times with exponential backoff. On final failure, log a warning and skip reflection. Reflection is non-critical -- the loop has already passed and merged. Missing a reflection entry is acceptable; losing the loop's work is not.

### 10.2 Prompt Storage (Per-Repo)

Prompts live in `.algedonia/prompts/` in the repository, versioned with the codebase. The daemon reads them when spawning agents.

**Directory structure:**

```
.algedonia/
  prompts/
    maker.md               -- system prompt for maker agents
    checker.md             -- system prompt for checker agents
    decompose.md           -- system prompt for the decomposition maker
    decompose_checker.md   -- system prompt for the decomposition checker (verifies DAG against decomposition rubric)
    impact_analysis.md     -- system prompt for impact analysis
    reflect.md             -- system prompt for reflection
    task_template.md       -- template for task descriptions sent to agents
  knowledge.md        -- accumulated codebase knowledge (from reflections)
```

**What "prompts" means:**
- **System prompts:** Role-specific instructions that set the agent's behavior, constraints, and output format. For example, `checker.md` instructs the checker to evaluate independently, run the verification pyramid, and return a structured verdict.
- **Task description templates:** `task_template.md` defines how the task, rubric, prior feedback, and knowledge context are assembled into the final prompt sent to the agent.
- **Rubric templates:** The default rubric structure (Section 7.4) that the decomposition agent uses as a starting point when generating per-loop rubrics.

Prompts are versioned with the codebase so that prompt changes are tracked, reviewable, and rollback-able. Different branches can have different prompts. The daemon reads the prompts from the worktree's `.algedonia/prompts/` directory at agent spawn time.

### 10.3 Knowledge File Structure

`.algedonia/knowledge.md` is a Markdown file with sections:

```
# Codebase Knowledge

## Architecture Patterns
- [accumulated entries from reflections]

## Gotchas
- [things that caused checker failures]

## Useful Commands
- [test commands, build commands, etc.]

## Rubric Notes
- [suggestions for rubric improvements]
```

Each entry is timestamped and tagged with the loop ID that produced it.

### 10.4 Consumption

When the server constructs a `start_loop` command, it includes the current contents of `.algedonia/knowledge.md` as `knowledge_context`. Both makers and checkers receive it. This creates a compounding knowledge loop: each completed loop makes future loops better-informed.

The file lives in the repo and is version-controlled. Developers can read, edit, or reorganize it. It is not a black box.

---

## 11. Non-Functional Requirements

### Latency

- **Terminal streaming:** < 200ms end-to-end (daemon PTY -> server -> browser render). Target: 100ms. The 50ms flush interval on the daemon is the main knob.
- **UI updates (loop status, scores):** < 500ms from event occurrence to browser update. LiveView PubSub handles this natively.
- **Loop start (button press to agent running):** < 10 seconds for the scheduling + worktree creation + agent spawn path. Impact analysis may add 15-30 seconds (it's an agent call).

### Concurrency

- **Loops per daemon:** Default 3, configurable. Bounded by the machine's CPU/memory and the agent's resource usage.
- **Daemons per server:** Tested for up to 20. At this scale, PubSub and Channel overhead is negligible.
- **Concurrent terminal viewers:** No hard limit. Phoenix PubSub fan-out handles this. At >50 viewers on one terminal, consider throttling update frequency.

### Database Sizing

- **Events table:** Largest table. Estimate 50-100 events per loop, ~1KB per event. 1,000 loops = 50-100MB. Manageable for years without partitioning for small-to-medium teams.
- **Loop attempts:** Diffs can be large (10-100KB). 1,000 loops x 3 attempts x 50KB avg = 150MB. Acceptable.
- **Comments table:** Lightweight. Estimate 5-20 comments per ticket. Negligible storage.
- **Terminal data:** Not stored in the database. In-memory scrollback only. Agent session IDs provide replay capability.

### Security Model

- **Project token:** A shared secret that authenticates daemons and web UI users. Transmitted over TLS (HTTPS/WSS). Stored as an environment variable on daemons and passed as a cookie/header in the browser.
- **No per-user auth in v1.** The project token is the only credential. Anyone with the token has full access. This is a deliberate simplification for small, trusted teams. Users provide a display name for Presence tracking, but this is not authentication.
- **LLM API keys:** Live exclusively on daemons as environment variables. The server never receives, stores, or proxies them. Agent processes inherit them from the daemon's environment.
- **No server-side LLM calls.** The server makes zero calls to any LLM API. All LLM interaction happens on daemons.
- **Network:** All server-daemon and server-browser communication over TLS. The server should be deployed behind HTTPS.

---

## 12. Tradeoffs

**Shared project token instead of per-user auth.**
Simpler to implement and operate. Downside: no per-user audit trail, no access control granularity. Acceptable for small trusted teams. Will need replacement for larger teams. Display names provide informal identity for Presence but are not verified.

**Global circuit breaker instead of per-ticket.**
Simpler state machine. Downside: one bad ticket's repeated failures can halt all work. Mitigation: the human can skip or fix the offending ticket quickly since the Monitor view surfaces what triggered the breaker.

**Impact analysis is a prediction, not a guarantee.**
Avoids the need for a static analysis tool that understands every language. Downside: predictions can be wrong, leading to unexpected file overlap. Mitigation: worktree isolation prevents corruption; merge conflicts at push time surface the overlap.

**Session IDs instead of stored transcripts.**
Agent session IDs are lightweight references (~50 bytes each) instead of full terminal transcripts (potentially megabytes). Replay is delegated to the agent's own `--resume` mechanism. Downside: replay requires the original daemon machine (sessions are stored locally by the agent runtime). Mitigation: the event log and attempt diffs are the durable audit trail; terminal replay is a debugging convenience.

**Terminal scrollback is in-memory only.**
Keeps the database lean. Downside: scrollback is lost on server restart. Mitigation: the event log, attempt diffs, and agent session IDs are the durable record. Terminal history is a debugging convenience, not a source of truth.

**Decomposition as a maker-checker loop.**
Decomposition uses the same loop machinery as all other work. The decomposition checker verifies scope reduction, rubric well-formedness, DAG validity, and coverage. Downside: decomposition takes longer (multiple attempts possible) compared to a single-pass agent call. Mitigation: decomposition is the highest-leverage step -- a bad DAG wastes all downstream work. The extra cost of verification is small relative to the cost of executing a flawed DAG. The checker catches structural problems (missing coverage, scope violations, malformed rubrics) before any code-writing begins.

**Multi-user stdin with no coordination.**
Multiple users can type into the same agent session. Inputs arrive in order with no locking or turn-taking. Downside: conflicting inputs can confuse the agent. Mitigation: this mirrors SSH shared sessions -- users coordinate verbally. The feature is for collaborative debugging, not adversarial input.

**Escalation queue as a live query, not a separate table.**
`SELECT * FROM loops WHERE status IN ('escalated', 'needs_clarification') ORDER BY updated_at ASC`. Downside: slightly more expensive than reading a pre-materialized queue. Mitigation: the query is indexed on `status` and the number of escalated loops at any time is small (single digits in normal operation).

**Single-node Phoenix server (no clustering in v1).**
Dramatically simplifies deployment and PubSub. Downside: single point of failure. Mitigation: the server is stateless except for the database and in-memory caches (terminal buffers, lock manager state). A restart recovers from PostgreSQL. Acceptable for v1 scale.

**Go over Rust for the daemon.**
Faster development, easier contributor onboarding, sufficient performance for an I/O-bound process manager. Downside: no memory safety guarantees from the type system, slightly higher memory footprint per process. Mitigated by the daemon's simple architecture (no complex data structures, no shared mutable state beyond the process table).

**Checker runs in the same worktree as the maker.**
Avoids duplicating the worktree. Downside: the checker could theoretically be influenced by artifacts the maker left beyond the diff (temp files, build caches). Mitigation: the checker agent is instructed to evaluate only the diff and run the verification pyramid. The checker is a fresh agent session with no access to the maker's conversation.

**Rubric edits apply to the next attempt, not the current one.**
Prevents disrupting a running agent mid-execution. Downside: the user must wait for the current attempt to finish before their rubric change takes effect. This is usually seconds to minutes, acceptable.

**No offline mode.**
Agents require network connectivity (for LLM APIs). The daemon requires a server connection for orchestration. Offline-first would add significant complexity for a scenario that contradicts the core use case. Not worth it.

---

## 13. Future Considerations

Explicitly deferred from v1:

- **Batch tuning:** End-of-day analysis across all completed loops to extract patterns and systematically improve rubrics and prompts. Currently only per-loop reflection exists.
- **Multi-repo support:** v1 assumes one repository per Algedonia project. Supporting polyrepo setups would require cross-repo DAGs and lock coordination.
- **Per-user authentication:** Replace the shared project token with individual user accounts, roles, and permissions.
- **Clustered server deployment:** Multi-node Phoenix with distributed PubSub (Redis adapter or Partisan) for high availability.
- **Per-ticket circuit breaker:** More granular failure isolation so one bad ticket doesn't halt all work.
- **Persistent terminal history:** Store terminal output in blob storage for replay after server restart.
- **Cost tracking and budgets:** Token-level cost tracking per loop, per ticket, per day. Budget limits that pause work.
- **Custom agent adapters:** A plugin system for adding new coding agents beyond the initial three.
- **Webhooks and external integrations:** Notify external systems (Slack, Linear, GitHub Issues) of ticket and loop events.
- **Advanced DAG operations:** Mid-flight DAG restructuring (add/remove/reorder loops while the DAG is executing).
- **Session migration:** Allow agent session replay across machines (currently sessions are local to the daemon that ran them).
