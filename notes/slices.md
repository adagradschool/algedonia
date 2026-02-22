# Algedonia -- Vertical Slices (v2)

Reference: [PRD v4](prd.md), [SDD v3](sdd.md)

---

## Slice Decomposition Rubrics

**Size definitions:**
- **S (Small):** 1-2 days. Single concern, one or two layers, minimal integration risk.
- **M (Medium):** 3-4 days. Multiple concerns or layers, moderate integration surface.

No L-sized slices. Every slice is S or M.

**Decomposition criteria:**
1. Does the slice produce a user-visible or developer-testable outcome?
2. Can it be verified independently of future slices?
3. Does it fit within the M size cap (4 days max)?

If any criterion fails, split further.

---

## Slice 1: Ticket CRUD

**User story:** A user can create, view, edit, and delete tickets in a browser.

**What's new:**
- `tickets` table (id, title, description, status, type, priority, assignee, acceptance_criteria, rubric, inserted_at, updated_at).
- `TicketLive.Index` LiveView at `/tickets` -- table of tickets with create/edit form.
- `TicketLive.Show` route at `/tickets/:id` -- redirects to index with detail panel open.
- Ecto schema, changeset, and context module (`Algedonia.Tickets`).
- Seed data for manual testing.

**Layers touched:** UI / Server

**Depends on:** None.

**Size:** M

**Verification criteria:**
1. User can create a ticket with title, description, type, priority, assignee, and acceptance criteria.
2. Created ticket appears in the ticket list without a page reload.
3. User can click a ticket to open the detail panel showing all fields.
4. User can edit any field on an existing ticket; changes persist after page reload.
5. User can delete a ticket; it disappears from the list.
6. Status field defaults to `backlog`.
7. Tickets are sortable by priority.
8. Tickets are filterable by status and assignee.

---

## Slice 2: Ticket Comments

**User story:** A user can post and reply to threaded comments on a ticket.

**What's new:**
- `comments` table (id, ticket_id, parent_id, author, body, created_at).
- Comment list component in the ticket detail panel.
- Compose form for new comments and replies.
- PubSub on `ticket:{id}` so comments appear in real time for other viewers.

**Layers touched:** UI / Server

**Depends on:** Slice 1.

**Size:** S

**Verification criteria:**
1. User can post a top-level comment on a ticket.
2. Comment appears immediately without page reload.
3. User can reply to an existing comment; the reply renders indented beneath its parent.
4. A second browser tab viewing the same ticket sees new comments in real time.
5. Comments display author name and timestamp.
6. Comments render Markdown body content.

---

## Slice 3: Daemon Connection and Heartbeat

**User story:** A Go daemon connects to the server, sends heartbeats, and appears as "online" in the UI.

**What's new:**
- `daemon_registrations` table (id, name, display_name, status, capacity, running_loops, last_heartbeat_at, connected_at).
- Phoenix Channel `daemon:{daemon_id}` with join authentication (project token).
- Heartbeat handler on the server: updates `last_heartbeat_at`, `capacity`, `running_loops`.
- Server-side GenServer (`Algedonia.DaemonMonitor`) that marks daemons as `unhealthy` after 30s silence, `offline` after 5min.
- Go daemon skeleton: connects via WebSocket, sends heartbeat every 10s with capacity and system metrics, reconnects with exponential backoff on disconnect.
- `MonitorLive.Index` LiveView at `/monitor` -- shows daemon health section only (name, status, capacity, last heartbeat).
- PubSub on `monitor` topic for daemon health changes.

**Layers touched:** UI / Server / Daemon

**Depends on:** None.

**Size:** M

**Verification criteria:**
1. Daemon binary starts and connects to the server using a project token.
2. Server creates a `daemon_registrations` row with status `online`.
3. `/monitor` page shows the daemon name, status "online", capacity, and last heartbeat time.
4. Heartbeat updates are visible in the UI without page reload (last heartbeat time updates).
5. Stopping the daemon causes status to transition to `unhealthy` within 30 seconds, reflected in the UI.
6. After 5 minutes of silence, daemon status becomes `offline`.
7. Restarting the daemon re-establishes the connection and status returns to `online`.
8. An invalid project token is rejected at channel join.

---

## Slice 4: Presence and Real-Time Collaboration

**User story:** Users see who else is viewing the same ticket, DAG, or loop in real time.

**What's new:**
- Phoenix Presence integration: tracks display name + current view per connected user.
- Presence indicators on all views: shows avatars/names of other users viewing the same page.
- Display name prompt: users provide a name on first visit (stored in browser session).
- PubSub on `presence` topic.

**Layers touched:** UI / Server

**Depends on:** Slices 1, 3.

**Size:** S

**Verification criteria:**
1. User is prompted for a display name on first visit.
2. Viewing `/tickets` shows other users also viewing that page.
3. Viewing `/loops/:id` shows other users viewing that specific loop.
4. When a user navigates away, their presence disappears within a few seconds.
5. Presence works across the ticket list, DAG view, Loop Inspector, and Monitor.

---

## Slice 5: Terminal Streaming

**User story:** A user can see live terminal output from a process running on the daemon, streamed to the browser.

**What's new:**
- Daemon PTY allocation: spawns a subprocess with a PTY, reads output, chunks it (50ms / 4KB), sends `terminal_output` events to the server.
- Server terminal buffer: in-memory scrollback (10,000 lines) per active terminal, keyed by loop_id.
- PubSub on `terminal:{loop_id}` to fan out terminal data to browser clients.
- `LoopLive.Show` LiveView at `/loops/:loop_id` -- left panel with terminal component (xterm.js or similar).
- Daemon `start_loop` command handler (minimal version): spawns a configurable command in a PTY and streams output. No agent adapter logic yet -- just raw process execution.
- Daemon `stop_loop` command handler: SIGTERM, then SIGKILL after 5s.
- Late-joining viewers see scrollback buffer.

**Layers touched:** UI / Server / Daemon

**Depends on:** Slice 3.

**Size:** M

**Verification criteria:**
1. Server sends a `start_loop` command to the daemon; daemon spawns the specified process in a PTY.
2. Terminal output streams to the browser and renders in an interactive terminal widget.
3. ANSI color codes and cursor movement render correctly.
4. A second browser tab opening the same loop sees the scrollback buffer.
5. Stopping the loop (via `stop_loop`) terminates the process and the terminal shows it has ended.
6. Latency from daemon PTY output to browser render is under 200ms.

---

## Slice 6: User Terminal Input (Steering)

**User story:** A user can type into a running terminal session from the browser, and the input reaches the daemon process.

**What's new:**
- Browser terminal component captures keyboard input and sends it to the server.
- Server forwards `stdin_input` command to the daemon channel.
- Daemon writes received data to the PTY master fd.
- Pause/resume: server sends `pause_agent` / `resume_agent`; daemon sends SIGSTOP / SIGCONT to the process group.

**Layers touched:** UI / Server / Daemon

**Depends on:** Slice 5.

**Size:** S

**Verification criteria:**
1. User types in the browser terminal; keystrokes appear in the daemon process's stdin.
2. Interactive prompts (e.g., a shell) respond to user input from the browser.
3. User can pause a running process; terminal freezes and process is stopped.
4. User can resume a paused process; it continues from where it left off.
5. Multiple browser tabs can send input to the same session; inputs arrive in order.

---

## Slice 7: Agent Adapter and Claude Code (Daemon-side)

**User story:** The daemon can spawn and manage a Claude Code agent process through a pluggable adapter interface, and return structured output to the server.

**What's new:**
- Go agent adapter interface: `Start`, `AttachPTY`, `SendInput`, `Wait`, `Kill`, `SessionID`.
- Claude Code adapter (first adapter): constructs CLI invocation, passes task via appropriate mechanism.
- Prompt loading: daemon reads from `.algedonia/prompts/` in the repo (starting with `decompose.md`).
- Daemon `start_loop` handler for `decompose` role: spawns agent with decompose prompt, parses structured output (DAG + rubrics), returns result to server.
- Agent lifecycle management: worktree creation, PTY attachment, exit detection, result collection.

**Layers touched:** Daemon

**Depends on:** Slices 3, 5.

**Size:** M

**Verification criteria:**
1. Daemon receives a `start_loop` command with role `decompose` and spawns Claude Code via the adapter interface.
2. The agent adapter interface is defined as a Go interface type with all six methods.
3. Claude Code adapter constructs the correct CLI invocation and passes the task description.
4. Daemon loads the decompose system prompt from `.algedonia/prompts/decompose.md`.
5. Terminal output from the agent process streams to the server via PTY.
6. On agent exit, the daemon parses structured output and returns the DAG + rubrics to the server.
7. Agent crash is detected and reported as an error event.

---

## Slice 8: Decomposition and DAG View (Server/UI)

**User story:** A user clicks "Start Work" on a ticket and sees the ticket decompose into a DAG of loops.

**What's new:**
- `dags` table (id, ticket_id, status, inserted_at, updated_at).
- `loops` table (id, dag_id, title, description, status, manual_gate, assigned_daemon_id, current_attempt, max_attempts, path_prefixes, rubric, branch_name, inserted_at, updated_at).
- `loop_dependencies` table (id, upstream_loop_id, downstream_loop_id).
- "Start Work" button on ticket detail panel. Transitions ticket to `decomposing`.
- Server Orchestrator (`Algedonia.Orchestrator`): sends `start_loop` with role `decompose` to daemon.
- Server receives DAG, creates `dags`, `loops`, and `loop_dependencies` rows.
- `DagLive.Show` LiveView at `/dags/:ticket_id` -- renders the DAG as a graph with color-coded nodes by status.
- PubSub on `dag:{ticket_id}` for DAG creation and loop status changes.
- Ticket detail panel shows a link to the DAG view after decomposition.
- Failure handling: retry decomposition up to 3 times; on final failure, ticket status becomes `decomposition_failed`.

**Layers touched:** UI / Server

**Depends on:** Slices 1, 7.

**Size:** M

**Verification criteria:**
1. Clicking "Start Work" transitions the ticket status to `decomposing`.
2. The decomposition agent runs and its terminal output streams to the Loop Inspector.
3. On success, the DAG view shows the resulting loops as nodes with dependency edges.
4. Each loop has a title, description, and generated rubric.
5. Generated rubrics follow SDD Section 7.4 format: Hard Gates, Weighted Checks, Acceptance Criteria, Threshold, and Options sections.
6. Loop statuses start as `pending`.
7. Ticket status transitions to `in_progress` after successful decomposition.
8. If decomposition fails 3 times, ticket status becomes `decomposition_failed` and the user can retry.
9. The DAG view updates in real time via PubSub.

**Done (backend only):**
- Orchestrator `push_fn` payloads now include full ticket context (`title`, `description`, `acceptance_criteria`, `rubric`, `type`, `priority`) via `ticket_context/1` helper. All three push sites covered: initial decompose, checker, retry decompose.
- `Terminals.unsubscribe/1` added for future terminal switching support.
- Orchestrator tests assert `payload["ticket"]` is present with expected fields.

**Remaining (front-end, not yet implemented):**
- **Split-pane DAG view:** Rewrite `DagLive.Show` as a split-pane layout — terminal (XTerm) on the left, loop list on the right, DAG graph collapsed at the bottom. Merge terminal logic from `LoopLive.Show` (subscribe/unsubscribe, scrollback, stdin forwarding). Key challenge: XTerm needs explicit absolute positioning with pixel offsets (not Tailwind `absolute inset-0`) and the root div needs `h-screen` (not `h-full`) because the app layout's `overflow-auto` wrapper breaks CSS height propagation. Match the working pattern from `LoopLive.Show`: parent `bg-[#1a1b26] p-1 min-h-0 relative`, XTerm div with inline `style="position:absolute;top:4px;left:4px;right:4px;bottom:4px;"`.
- **Loop selection:** Add `selected_loop_id` assign, `select_loop` event handler, `terminal_reset` push on switch. Selection logic must prefer the most recent running loop (reverse list, find `running_maker`/`running_checker`), not the first match — critical when retries create multiple decompose loops.
- **DagGraph node clicks:** Change `window.location = /loops/${id}` to `hook.pushEvent("select_loop", ...)` (capture `const hook = this` before the `querySelectorAll` loop).
- **XTerm hook:** Add `terminal_reset` event handler (`this.term.reset()`).
- **Start Work redirect:** Change `TicketLive.Index` `handle_event("start_work")` from `push_patch(to: ~p"/tickets/#{id}")` to `push_navigate(to: ~p"/dags/#{id}")`.
- **DAG event handling:** Reload ticket assign on `:dag_created` (status changes from `decomposing` to `in_progress`). Auto-select first loop when `selected_loop_id` is nil and loops become available.
- **Tests:** Update `dag_live_test.exs` for terminal container, loop selection, auto-select behavior. Update `ticket_live_test.exs` for redirect change.

---

## Slice 9: Maker Agent Execution

**User story:** After decomposition, a root loop in the DAG is scheduled to a daemon and the maker agent executes, producing a diff.

**What's new:**
- Scheduler (`Algedonia.Scheduler`): identifies unblocked loops after DAG creation, assigns them to daemons (ticket creator's daemon if available, else least-loaded).
- `loop_attempts` table (id, loop_id, attempt_number, role, status, diff, verdict, scores, feedback, session_id, token_usage, duration_ms, inserted_at).
- `events` table (id, entity_type, entity_id, event_type, payload, actor, inserted_at).
- Daemon `start_loop` handler for `maker` role: creates worktree (`git worktree add`), loads prompt from `.algedonia/prompts/maker.md`, spawns agent, streams terminal output.
- Daemon worktree management: creation, cleanup.
- Daemon `attempt_complete` event: sends diff, exit code, files changed, session ID back to server.
- Server records attempt in `loop_attempts`, appends event to `events` table.
- Loop Inspector right panel: diff viewer showing the maker's output, attempt history list.
- DAG view node transitions to `running_maker` (blue) during execution.

**Layers touched:** UI / Server / Daemon

**Depends on:** Slice 8.

**Size:** M

**Verification criteria:**
1. After decomposition, root loops (no upstream dependencies) transition to `ready` then `assigned`.
2. The daemon creates a git worktree for the assigned loop.
3. The maker agent spawns and its terminal output streams to the Loop Inspector.
4. When the agent exits, the diff is captured and sent to the server.
5. The attempt is recorded in `loop_attempts` with diff, exit code, and session ID.
6. A state transition event is recorded in the `events` table.
7. The diff is visible in the Loop Inspector's right panel.
8. The DAG view shows the loop node as `running_maker` during execution.

---

## Slice 10: Checker Agent and Merge Gate

**User story:** After the maker produces a diff, the checker agent independently verifies it and returns a pass/fail/clarify verdict, enforcing both weighted thresholds and hard gates.

**What's new:**
- Daemon `start_loop` handler for `checker` role: spawns checker agent in the same worktree with the diff, task description, rubric, and acceptance criteria. No access to maker's conversation.
- Daemon loads checker system prompt from `.algedonia/prompts/checker.md`.
- Daemon `loop_result` event: sends verdict, scores (per verification pyramid layer), feedback, hard gate failures, and session ID.
- Server Orchestrator verdict routing: handles `pass`, `fail`, and `clarify` outcomes.
- Merge gate logic: hard gates (typecheck, critical security) must pass regardless of weighted score; weighted threshold is applied across pyramid layers; a checker pass with a hard gate failure results in a `fail` verdict; merge gate configuration comes from the rubric (Section 7.4).
- On `pass`: transitions loop to `passed`, records attempt, appends event.
- On `fail` with attempts remaining: transitions loop back to `running_maker` for retry.
- On `fail` with max attempts exhausted: transitions loop to `escalated`, appends event.
- Loop Inspector right panel: checker scores displayed as verification pyramid heatmap (static, deterministic, generative, runtime, semantic). Hard gate failures are visually distinct.
- DAG view node color updates: `running_checker` (yellow), `passed` (green), `escalated` (orange).

**Layers touched:** UI / Server / Daemon

**Depends on:** Slices 2, 9.

**Size:** M

**Verification criteria:**
1. After the maker completes, the server sends a checker `start_loop` to the daemon.
2. The checker agent runs in the same worktree and its terminal output streams to the Loop Inspector.
3. Daemon loads checker system prompt from `.algedonia/prompts/checker.md`.
4. Checker scores per pyramid layer are recorded and displayed in the heatmap.
5. A `pass` verdict with all hard gates passing transitions the loop to `passed`.
6. A `pass` verdict with a hard gate failure (e.g., typecheck fails) is overridden to a `fail` verdict.
7. Weighted threshold is applied across pyramid layers as configured in the rubric.
8. A `fail` verdict with remaining attempts sends checker feedback to the maker for retry.
9. A `fail` verdict at max attempts transitions the loop to `escalated`.
10. The DAG view reflects all status transitions in real time.

---

## Slice 11: Clarify-Resume Flow

**User story:** When the checker determines requirements are missing or ambiguous, the loop halts for clarification and resumes after the user updates the ticket.

**What's new:**
- Checker `clarify` verdict handling in the Orchestrator.
- Loop transitions to `needs_clarification` on `clarify` verdict.
- Auto-comment posted on the parent ticket with the checker's feedback explaining what's missing or ambiguous (via `comments` table, author: `system`).
- Loop appears in the escalation queue in Monitor view (visually distinct from failures -- purple badge).
- DAG view node color: `needs_clarification` (purple).
- "Resume" button on the loop in the Loop Inspector and escalation queue.
- Resume flow: user updates ticket (edits acceptance criteria or description), clicks "Resume" on the halted loop, loop transitions back to `running_maker` with updated ticket context (new acceptance criteria, description, and any reply comments).

**Layers touched:** UI / Server

**Depends on:** Slice 10.

**Size:** S

**Verification criteria:**
1. A `clarify` verdict from the checker transitions the loop to `needs_clarification`.
2. A system comment is automatically posted on the parent ticket with the checker's clarification feedback.
3. The loop appears in the Monitor escalation queue with a distinct visual indicator (purple).
4. The DAG view shows the loop node as `needs_clarification` (purple).
5. User edits the ticket's acceptance criteria or description.
6. User clicks "Resume" on the halted loop.
7. The loop transitions back to `running_maker` with the updated ticket context (new acceptance criteria, description).
8. The resumed maker attempt receives the updated context and produces a new diff.
9. Full round-trip verified: clarify verdict -> needs_clarification -> ticket update -> resume -> running_maker -> checker re-evaluation.

---

## Slice 12: Maker-Checker Loop (Retry, Squash, Merge)

**User story:** A loop retries with compressed context on failure, and on pass, squash-merges the result into the base branch.

**What's new:**
- Retry with context: server sends prior attempts (compressed summaries of older iterations, full detail on most recent) in the `start_loop` payload to the maker.
- Daemon `squash_and_push` command handler: squash-rebases commits onto base branch, pushes to remote, cleans up worktree.
- Server sends `squash_and_push` after a loop passes.
- Scheduler scheduling pass: after a loop passes, check all downstream dependents; unblocked loops become eligible.
- DAG execution: downstream loops start when all upstream dependencies are satisfied.
- Attempt history in Loop Inspector: expandable list showing each attempt's maker summary, checker verdict, scores, duration, token usage, and session ID.

**Layers touched:** UI / Server / Daemon

**Depends on:** Slice 10.

**Size:** M

**Verification criteria:**
1. When a maker attempt fails, the next attempt receives compressed summaries of all prior attempts plus full detail on the most recent.
2. Retry increments the attempt counter and records each attempt separately.
3. On pass, the daemon squash-rebases and pushes to the remote; worktree is cleaned up.
4. After a loop passes, downstream dependent loops transition from `pending` to `ready`.
5. Multiple loops in a DAG execute in the correct dependency order.
6. Parallel loops (no dependency between them) can execute simultaneously on the same or different daemons.
7. Attempt history in the Loop Inspector shows all attempts with their verdicts and feedback.
8. When all loops in a DAG pass, the ticket transitions to `completed`.

---

## Slice 13: Impact Analysis and File Locking

**User story:** Before a loop starts, impact analysis predicts which files it will touch, and locks prevent two loops from working on the same files.

**What's new:**
- Lock Manager (`Algedonia.LockManager`): GenServer with `acquire`, `release`, `check`, `list_active` operations. Prefix-based conflict detection. Mirrored in PostgreSQL.
- `file_locks` table (id, loop_id, path_prefixes, acquired_at).
- Daemon `start_loop` handler for `impact_analysis` role: lightweight agent call that returns path prefixes.
- Daemon loads impact analysis prompt from `.algedonia/prompts/impact_analysis.md`.
- Scheduler integration: before dispatching a loop, runs impact analysis, then calls Lock Manager `acquire`. If conflict, loop stays in `ready`.
- Locks stored on `loops.path_prefixes` field.
- Lock release on loop completion (pass, escalated, needs_clarification, skipped).
- Scheduling pass on every lock release.
- Monitor view: running loops table shows files locked per loop.

**Layers touched:** UI / Server / Daemon

**Depends on:** Slice 12.

**Size:** M

**Verification criteria:**
1. When a loop transitions to `ready`, impact analysis runs and returns path prefixes.
2. Daemon loads impact analysis prompt from `.algedonia/prompts/impact_analysis.md`.
3. Impact analysis reflects the current codebase state at scheduling time, not the state at ticket creation (late binding).
4. Path prefixes are stored on the loop record.
5. Lock Manager acquires locks atomically (all-or-nothing).
6. A second loop with overlapping path prefixes stays in `ready` until the first loop releases its locks.
7. `src/auth/` conflicts with `src/auth/jwt.ex` (prefix overlap detection works).
8. `src/auth/` does not conflict with `src/api/` (non-overlapping prefixes pass).
9. Locks are released when a loop passes, is escalated, needs clarification, or is skipped.
10. After lock release, waiting loops are immediately re-evaluated and dispatched if now conflict-free.
11. Monitor view shows which files each running loop has locked.

---

## Slice 14: Escalation Queue

**User story:** When loops exhaust retries, they appear in an escalation queue in the Monitor view for human intervention.

**What's new:**
- Escalation queue in Monitor view: live query (`loops WHERE status IN ('escalated', 'needs_clarification') ORDER BY updated_at ASC`). FIFO ordering. Shows one escalation at a time with diff, rejection reason (or clarification request), rubric, and attempt history. Count badge for remaining.
- Escalation actions: provide feedback (text feeds into next maker attempt), edit rubric, skip loop, manually resolve.
- Skip action: marks loop as `skipped`, unblocks downstream with `degraded` flag.

**Layers touched:** UI / Server

**Depends on:** Slice 12.

**Size:** M

**Verification criteria:**
1. An escalated loop appears in the Monitor escalation queue.
2. Only one escalation is shown at a time; a badge shows remaining count.
3. Escalations are displayed in FIFO order (oldest first).
4. Providing feedback on an escalation transitions the loop back to `running_maker` with the feedback.
5. Editing the rubric on an escalation applies to the next attempt.
6. Skipping a loop marks it as `skipped` and unblocks downstream dependents with a `degraded` flag.

---

## Slice 15: Circuit Breaker

**User story:** Repeated escalations trigger a circuit breaker that halts new loop dispatch until a human investigates and resumes.

**What's new:**
- Circuit Breaker (`Algedonia.CircuitBreaker`): GenServer state machine with three states -- `closed`, `open`, `half_open`.
- Transitions: `closed -> open` after N consecutive escalations (configurable, default 3); `open -> half_open` on manual resume; `half_open -> closed` if test loop passes; `half_open -> open` if test loop escalates.
- When open, Scheduler stops dispatching new loops. In-flight loops continue to completion.
- Half-open: manual resume dispatches one test loop. Pass -> closed. Escalate -> open.
- Circuit breaker status in Monitor view: color-coded indicator (closed=green, open=red, half_open=yellow), trigger condition, manual resume button.

**Layers touched:** UI / Server

**Depends on:** Slice 14.

**Size:** S

**Verification criteria:**
1. After N consecutive escalations (configurable, default 3), circuit breaker transitions to `open`.
2. When circuit breaker is open, the Scheduler does not dispatch new loops.
3. In-flight loops continue to completion when the breaker is open.
4. Manual resume transitions breaker to `half_open` and dispatches one test loop.
5. If the test loop passes, breaker closes. If it escalates, breaker reopens.
6. Circuit breaker state is visible in the Monitor view with correct color coding.
7. Circuit breaker state updates in real time via PubSub.

---

## Slice 16: Manual Gate and Approval

**User story:** A user can flag a loop for manual approval; after the checker passes, the loop pauses for human review before merging.

**What's new:**
- Rubric editor in Loop Inspector right panel: inline editing of rubric Markdown, including `manual_gate` toggle. Edits apply to the next attempt.
- Orchestrator handles `manual_gate: true` on checker pass: transitions loop to `pending_approval` instead of auto-merging.
- Loop Inspector shows "Approve" and "Reject" buttons when loop is in `pending_approval`.
- Approve: proceeds to squash-merge flow.
- Reject: user provides feedback; loop returns to `running_maker`.

**Layers touched:** UI / Server

**Depends on:** Slice 12.

**Size:** S

**Verification criteria:**
1. User can edit a loop's rubric from the Loop Inspector; changes persist.
2. Setting `manual_gate: true` in the rubric causes a passing loop to enter `pending_approval` instead of auto-merging.
3. The Loop Inspector shows "Approve" and "Reject" buttons for loops in `pending_approval`.
4. Clicking "Approve" triggers the squash-merge flow.
5. Clicking "Reject" with feedback sends the loop back to `running_maker` with that feedback.
6. The DAG view shows `pending_approval` (teal) as a distinct status.

---

## Slice 17: Focus Mode

**User story:** A user can toggle focus mode to hide all UI noise and concentrate on resolving escalations one at a time.

**What's new:**
- Focus mode toggle in Monitor view (button or keyboard shortcut).
- When active, hides all Monitor UI sections except the current escalation (diff, rejection reason, rubric, attempt history, action buttons).
- When the current escalation is resolved, the next escalation is shown automatically.
- When no escalations remain, focus mode exits and the full Monitor view is restored.

**Layers touched:** UI

**Depends on:** Slice 14.

**Size:** S

**Verification criteria:**
1. User can toggle focus mode on and off from the Monitor view.
2. When focus mode is active, only the current escalation is visible; all other Monitor sections are hidden.
3. Resolving an escalation in focus mode automatically shows the next escalation in the queue.
4. When the last escalation is resolved, focus mode exits and the full Monitor view is restored.
5. Focus mode state persists across page reloads (stored in browser session or local storage).

---

## Slice 18: Reflection and Knowledge

**User story:** After a loop passes, a reflection agent extracts lessons learned and appends them to the codebase knowledge file.

**What's new:**
- Daemon `start_loop` handler for `reflect` role: no worktree needed, spawns agent with loop task, final diff, attempt summaries, checker feedback, and current `.algedonia/knowledge.md`.
- Agent returns structured reflection (patterns, gotchas, useful commands, rubric suggestions).
- Daemon commits reflection to `.algedonia/knowledge.md` on the main branch.
- Server includes `knowledge_context` (contents of `.algedonia/knowledge.md`) in all future `start_loop` commands.
- Prompt loading: daemon reads `.algedonia/prompts/reflect.md`.
- Failure handling: retry up to 3 times, then skip (reflection is non-critical).

**Layers touched:** Server / Daemon

**Depends on:** Slice 12.

**Size:** S

**Verification criteria:**
1. After a loop passes, the server triggers a reflection step.
2. The reflection agent runs and produces structured output.
3. The reflection is appended to `.algedonia/knowledge.md` with a timestamp and loop ID tag.
4. The knowledge file follows SDD Section 10.3 structure: Architecture Patterns, Gotchas, Useful Commands, and Rubric Notes sections.
5. Future `start_loop` commands include the updated knowledge context.
6. If the reflection agent fails 3 times, the failure is logged and skipped without affecting the passed loop.
7. The knowledge file is committed to the repo and visible in version control.

---

## Slice 19: Agent Adapter Extensibility (Codex)

**User story:** A second agent adapter (Codex) proves the adapter interface is pluggable by running a loop with a different agent.

**What's new:**
- Codex adapter implementing the same Go agent adapter interface (`Start`, `AttachPTY`, `SendInput`, `Wait`, `Kill`, `SessionID`).
- Agent selection in `start_loop` command: server specifies `agent.type` as `codex`; daemon dispatches to the Codex adapter.
- Codex-specific CLI invocation and task passing.

**Layers touched:** Daemon

**Depends on:** Slice 7.

**Size:** S

**Verification criteria:**
1. Codex adapter implements all six methods of the agent adapter interface.
2. Server can send a `start_loop` command with `agent.type: "codex"`.
3. Daemon dispatches to the Codex adapter and spawns the Codex agent process.
4. Terminal output from Codex streams to the server via PTY, same as Claude Code.
5. A loop configured to use Codex completes and returns results to the server.

---

## Slice 20: Multi-Daemon Scheduling

**User story:** With multiple daemons connected, loops are distributed across them based on capacity.

**What's new:**
- Scheduler daemon selection logic: prefer ticket creator's daemon if online and has capacity; otherwise pick least-loaded available daemon.
- Monitor view: running loops table shows which daemon each loop is assigned to, sortable by daemon.
- Reassignment: if a daemon goes offline, pending (not-yet-started) loops are reassigned after 5 minutes.

**Layers touched:** UI / Server

**Depends on:** Slices 3, 12.

**Size:** S

**Verification criteria:**
1. With two daemons connected, loops are assigned to the daemon with more available capacity.
2. The ticket creator's daemon is preferred when it has capacity.
3. Monitor view shows daemon assignment per running loop.
4. If a daemon goes offline, its pending loops are reassigned to another daemon after 5 minutes.
5. In-progress loops on an offline daemon are not immediately killed; they wait for reconnection.

---

---

## Dependency Graph

```
Slice 1: Ticket CRUD
├── Slice 2: Ticket Comments
│   └── Slice 10: Checker Agent and Merge Gate (also depends on 9)
├── Slice 4: Presence (also depends on 3)
└── Slice 8: Decomposition and DAG View (also depends on 7)
    └── Slice 9: Maker Agent Execution
        └── Slice 10: Checker Agent and Merge Gate (also depends on 2)
            ├── Slice 11: Clarify-Resume Flow
            └── Slice 12: Maker-Checker Loop
                ├── Slice 13: Impact Analysis and File Locking
                ├── Slice 14: Escalation Queue
                │   ├── Slice 15: Circuit Breaker
                │   └── Slice 17: Focus Mode
                ├── Slice 16: Manual Gate and Approval
                ├── Slice 18: Reflection and Knowledge
                └── Slice 20: Multi-Daemon Scheduling (also depends on 3)

Slice 3: Daemon Connection and Heartbeat
├── Slice 4: Presence (also depends on 1)
├── Slice 5: Terminal Streaming
│   ├── Slice 6: User Terminal Input
│   └── Slice 7: Agent Adapter and Claude Code (also depends on 3)
│       ├── Slice 8: Decomposition and DAG View (also depends on 1)
│       └── Slice 19: Agent Adapter Extensibility (Codex)
└── Slice 20: Multi-Daemon Scheduling (also depends on 12)
```

**Flat dependency list:**

| Slice | Depends on |
|---|---|
| 1. Ticket CRUD | -- |
| 2. Ticket Comments | 1 |
| 3. Daemon Connection and Heartbeat | -- |
| 4. Presence and Real-Time Collaboration | 1, 3 |
| 5. Terminal Streaming | 3 |
| 6. User Terminal Input | 5 |
| 7. Agent Adapter and Claude Code | 3, 5 |
| 8. Decomposition and DAG View | 1, 7 |
| 9. Maker Agent Execution | 8 |
| 10. Checker Agent and Merge Gate | 2, 9 |
| 11. Clarify-Resume Flow | 10 |
| 12. Maker-Checker Loop | 10 |
| 13. Impact Analysis and File Locking | 12 |
| 14. Escalation Queue | 12 |
| 15. Circuit Breaker | 14 |
| 16. Manual Gate and Approval | 12 |
| 17. Focus Mode | 14 |
| 18. Reflection and Knowledge | 12 |
| 19. Agent Adapter Extensibility (Codex) | 7 |
| 20. Multi-Daemon Scheduling | 3, 12 |

---

## Size Summary

| Slice | Size |
|---|---|
| 1. Ticket CRUD | M (3-4 days) |
| 2. Ticket Comments | S (1-2 days) |
| 3. Daemon Connection and Heartbeat | M (3-4 days) |
| 4. Presence and Real-Time Collaboration | S (1-2 days) |
| 5. Terminal Streaming | M (3-4 days) |
| 6. User Terminal Input | S (1-2 days) |
| 7. Agent Adapter and Claude Code | M (3-4 days) |
| 8. Decomposition and DAG View | M (3-4 days) |
| 9. Maker Agent Execution | M (3-4 days) |
| 10. Checker Agent and Merge Gate | M (3-4 days) |
| 11. Clarify-Resume Flow | S (1-2 days) |
| 12. Maker-Checker Loop | M (3-4 days) |
| 13. Impact Analysis and File Locking | M (3-4 days) |
| 14. Escalation Queue | M (3-4 days) |
| 15. Circuit Breaker | S (1-2 days) |
| 16. Manual Gate and Approval | S (1-2 days) |
| 17. Focus Mode | S (1-2 days) |
| 18. Reflection and Knowledge | S (1-2 days) |
| 19. Agent Adapter Extensibility (Codex) | S (1-2 days) |
| 20. Multi-Daemon Scheduling | S (1-2 days) |

**Critical path:** 1 -> 8 -> 9 -> 10 -> 12 (with 3 -> 5 -> 7 joining at 8, and 2 joining at 10)

**Parallelizable early work:** Slices 1, 2, 3, 4, 5, 6 can all progress in parallel (1+2 on server side, 3+5+6 on daemon side, 4 once 1+3 are done). Slice 19 (Codex adapter) can be done any time after Slice 7.
