# Algedonia — Product Requirements Document (v4)

*Agentic coding orchestration built on maker-checker loops.*

The name comes from cybernetics (Stafford Beer). Algedonic signals are pain/pleasure signals that bypass normal management channels to alert the system when something is critically right or wrong. In Algedonia, the checker's pass/fail verdict is exactly that signal.

---

## Principles

1. **Verification loops and DAGs are the primitives.** The maker-checker loop is the atomic unit of work. Long work is a DAG of loops, not a monolithic sprint. Plans are hypotheses; loops are reality contact. Hard budgets on time, tokens, and retries. "Admit failure" is a first-class outcome.

2. **Coordination via isolation.** Parallel agents work in isolated worktrees on non-overlapping files. Conflicts become a scheduling problem, not a merge problem. Agents are adapters, not the architecture. The UI is a skin over an event/command API.

3. **Humans collaborate, define goals and rubrics, and spot-check.** Agents do execution. Humans do goal selection, architectural decisions, quality bar, and risk acceptance — not strategy or step-by-step instructions. Translate vague requests into measurable constraints (rubrics), not prose instructions. Attention is the only scarce resource: escalations are queued one at a time, circuit breakers prevent failure floods, focus mode hides noise. Replace dopamine loops with verifier-gated loops. Sustainable, audited, compounding throughput.

4. **Artifacts are the product.** Users want a codebase, not chats. Every loop produces commits, diffs, logs, and receipts. Everything is replayable. Per-loop reflection extracts architectural patterns, gotchas, and useful commands into structured codebase knowledge that compounds over time and is injected into future agent contexts.

5. **Anti-entropy.** Tech debt is entropy — once introduced, it spreads. Every commit survives the full verification pyramid before landing. There is no "clean up later." The rubric is the membrane. Per-loop reflection accumulates codebase knowledge that tightens rubrics and maker prompts over time. Each completed loop makes the next one better.

---

## Core Bet

Two agents in a loop — maker and checker — is the correct fundamental primitive for agentic coding. It beats both black-box async agents and open-ended LLM prompting. It also manages context better than single-agent approaches.

---

## The Maker-Checker Loop

The maker-checker loop is the atomic unit of work.

- **Maker** generates code as a diff/patch.
- **Checker** verifies the diff against the original intent and a quality rubric. The checker has no access to the maker's reasoning. This forces independent judgment.
- **Pass** — squash-merge the commit. **Fail** — maker retries with the checker's feedback. **Clarify** — checker halts the loop because critical requirements are missing or ambiguous; escalates to human to update the ticket before the loop can retry. **Max turns reached** — escalate to human.

**Maker context:** Full history of attempts. Compressed summaries of older iterations. Full detail on the current iteration.

**Loop termination conditions:**
- Checker pass (success).
- Max turns exceeded (failure, escalate to human).
- Manual human gate (optional checkpoint).

---

## Verification Pyramid

The checker draws from five layers. Each layer produces pass/fail, a confidence score, and a cost.

1. **Static checks** — lint, typecheck, dead code detection, complexity analysis.
2. **Deterministic tests** — unit, integration, and regression tests.
3. **Generative tests** — property-based tests, fuzz testing, metamorphic testing.
4. **Runtime checks** — performance budgets, flaky test detection, security/SAST.
5. **Semantic/product checks** — contract assertions, API behavior validation, UX constraints, business rules.

**Merge gate:** A weighted threshold across layers, plus mandatory hard gates. Typecheck and critical security findings must always pass, regardless of the weighted score.

**Rubric generation:** The decomposition step generates initial rubrics alongside the DAG, informed by repo context and existing tooling (detecting test frameworks, linters, type checkers already in use). Each loop in the DAG gets a rubric tailored to its task. Humans can edit rubrics at any time, including mid-flight during an active loop.

---

## Task Decomposition

Algedonia uses Hierarchical Task Network (HTN) style decomposition. Decomposition is itself a maker-checker loop — the same primitive used for all other work.

- **Maker** produces a DAG of loops, each with a title, description, dependency edges, and a quality rubric.
- **Checker** verifies the decomposition against a decomposition rubric (see below). The checker has no access to the maker's reasoning.
- **Pass** — the DAG is accepted and execution begins. **Fail** — the maker retries with the checker's feedback. **Clarify** — escalate to the human (e.g., the ticket is too vague to decompose). **Max turns reached** — escalate.

**Decomposition rubric (checked by the checker):**
1. **Scope reduction:** Every subtask is strictly smaller than its parent (fewer files, narrower concern, less estimated context). No subtask may restate the parent task.
2. **Leaf node criteria:** Every leaf node in the DAG satisfies both (a) context fit — the task fits within a single agent context window, and (b) verification constraint — the task has a testable, measurable outcome with a concrete rubric.
3. **Rubric well-formedness:** Every per-loop rubric parses correctly (hard gates, weighted checks, threshold, options per Section 7.4 of the SDD).
4. **DAG validity:** The graph is acyclic. Dependency edges are plausible (a test loop depends on the implementation loop, not vice versa).
5. **Coverage:** The union of all leaf tasks covers the original ticket's acceptance criteria. Nothing is dropped.

Because decomposition uses the standard loop machinery, it gets retry-with-feedback, escalation, circuit breaker protection, and human intervention for free. No special case.

**Execution order:** Dependency-respecting (topological sort), parallelized where no dependencies block.

**Failure propagation:** Downstream loops pause when an upstream loop fails. A human resolves the failure (fix, skip, or redefine). Execution resumes from the resolution point.

---

## File-Level Locking

Coordination overhead is a major source of waste in parallel development. Algedonia ensures parallel workers never overlap on the same files.

- Tickets sit in backlog with no file paths assigned (the codebase is changing).
- When a ticket moves to ready, impact analysis runs: "what files and modules will this touch?" This produces a set of path prefixes.
- The scheduler checks locks before spawning a loop. If another active loop holds overlapping paths, the new loop waits.
- A loop acquires locks on start and releases them on completion.

**Late binding is key:** Impact analysis runs at scheduling time against the current codebase state, not at ticket creation time. Two loops never produce conflicting diffs because they never touch the same files simultaneously.

---

## Isolation

Each loop gets its own git worktree. All worktrees share `.git` objects but have separate working directories.

On success, the loop's work is squash/rebased into the parent branch and the worktree is cleaned up.

Runtime isolation is delegated to agent adapters (containers, sandboxes, etc.). Algedonia orchestrates worktrees only.

---

## Escalation and Circuit Breaker

When a loop exhausts its retries, it escalates to a human.

- **Escalation queue:** Shows one escalation at a time (one-piece flow). Remaining escalations sit in a FIFO queue. The queue does not stop loops from running — it only manages what the human sees.
- **Circuit breaker:** Three states — closed (loops spawn freely), open (stop spawning after N consecutive escalations), half-open (test with one loop before full resume). Manual resume required.
- **Focus mode:** Hides everything except the current escalation.

---

## Ticket Management

Algedonia includes a built-in issue tracker.

**Ticket fields:** title, description, status, type, priority, assignee, acceptance criteria.

Acceptance criteria are parsed and fed to the checker as semantic checks (layer 5 of the verification pyramid).

**Comments:** Tickets support threaded comments. Comments are the primary channel for team discussion, clarification requests from the checker, and human feedback during escalations.

**Ticket lifecycle:** create, decompose into a DAG of loops, loops execute, all loops pass, ticket closes.

---

## UI Layout

The interface is a three-column layout with a consistent left sidebar. Information flows left to right: DAG → Loop → Artifacts.

**Left Sidebar:**
- **Top section:** Navigation between views (Tickets, Monitor). The Loop Inspector is the default/primary view.
- **Bottom section:** User settings and collaboration panel (presence, and in the future, voice calls for real-time team communication).

**Three views:**

**Tickets** — Table or board of tickets showing status, assignee, and DAG progress summary.

**Loop Inspector** — The primary workspace. Three columns:
- *Left panel:* DAG tree for the current ticket. Loops are shown as a flat tree with status icons, grouped by dependency depth. Parallel loops appear as siblings at the same level. Manual gates are visible as a state on the loop node. Clicking a node loads that loop's agent run. Designed for 5–10 loops per ticket — if a ticket needs more, it should be split.
- *Center panel:* Live terminal showing the active agent run (maker or checker). This is a full interactive terminal. Steering is native terminal interaction: type to send input, esc to pause, ctrl+c to stop. No GUI buttons for pause/resume — the terminal is the interface. Both maker and checker runs are viewed identically here; the checker is just another agent run with different context (diff + rubric instead of task description).
- *Right panel:* Tabbed context for the current loop — Diff (working changes vs base), Rubric (editable, changes apply to next attempt), Verdict (structured checker results: hard gate pass/fail, weighted check scores, overall threshold), History (attempt list, each entry showing maker summary, checker verdict, scores, duration, token usage, agent session ID for resume/replay).

**Monitor** — Escalation queue (one-piece flow), circuit breaker status, running loops overview, daemon health.

---

## Live Terminal and Agent Interaction

Users can watch agents work in real-time. Terminal output from the local machine streams to the browser.

Users can intervene by typing directly into a running agent session. Steering is native terminal interaction — no separate control surface. Multiple users can type into the same session simultaneously; inputs arrive in order (like SSH shared sessions, users coordinate verbally).

Both maker and checker agents are viewed the same way: a live terminal with contextual artifacts on the right. The checker is not a special UI — it is an agent run with different inputs (diff, rubric, acceptance criteria instead of a task description).

Multiple users can watch the same loop terminal simultaneously.

---

## Real-Time Collaboration

Multiple users see tickets, loops, escalations, and terminal output in real-time.

Presence is first-class: who is viewing what is always visible. The collaboration panel in the sidebar shows active users and supports team communication (voice calls planned for future).

Collaboration is native to the architecture, not bolted on.

---

## Architecture

**Server application:** Owns the UI, tickets, DAGs, loop orchestration, state, collaboration, and persistence. The server is the source of truth for all state.

**Local daemon ("algedonia-agent"):** A thin process on the user's machine. Connects to the server via a persistent connection. Receives commands: create worktree, spawn agent, run checker. Streams terminal output back to the server. Reports results. The daemon has no opinions — it is a remote executor. The server decides what to run, when to run it, and whether the result passed.

Network connectivity is assumed (agents require it). Local-first offline mode is not a goal.

Collaboration is built into the server's event model, not added as a separate layer.

---

## Agent Adapters

Agents are pluggable adapters. They are not the architecture — they are swappable. Makers and checkers use the same coding agents — the checker needs filesystem access, test execution, and repo context to verify independently, not just LLM reasoning over a diff.

**Supported agents (v1):** Claude Code, Codex, Aider.

---

## Logging and Receipts

Each loop produces:
- A git commit (squashed).
- A structured event log: attempt number, timestamps, scores, decisions.
- Agent session IDs per attempt (sessions can be resumed or replayed via the agent's `--resume` flag).

Prompts are stored per-repo and versioned with the codebase.

---

## User Journeys

### Solo Developer, Feature Build

1. Create a ticket: "Add JWT authentication to API."
2. Write acceptance criteria as markdown checkboxes.
3. Hit "Start Work." Algedonia decomposes the task into loops (schema, auth endpoint, middleware, tests).
4. The Loop Inspector's DAG tree shows progress. Loops execute in parallel where possible.
5. One loop fails the checker and escalates. The developer sees one card: the diff, the rejection reason, and the rubric.
6. The developer provides clarification. The loop retries and passes.
7. All loops green. Squash-merged commits land on the branch.

### Team, Concurrent Workstreams

1. A PM creates tickets and assigns priorities.
2. A developer starts work on multiple tickets. Loops spawn across DAGs.
3. File-level locking ensures no file overlap. No merge conflicts.
4. Two loops escalate. The queue shows one at a time.
5. The circuit breaker fires on one ticket (bad rubric). Its loops pause. The developer fixes the acceptance criteria and resumes.

### Overnight Batch

1. A developer queues tickets before leaving.
2. Algedonia works through them overnight. Some complete, some escalate, some trip the circuit breaker.
3. Morning: the dashboard shows green, amber, and red. A clear queue of decisions to make.
