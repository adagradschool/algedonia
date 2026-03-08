# Algedonia — Product Requirements Document (v5)

*Agentic coding orchestration built on maker-checker loops.*

The name comes from cybernetics (Stafford Beer). Algedonic signals are pain/pleasure signals that bypass normal management channels to alert the system when something is critically right or wrong. In Algedonia, the checker's pass/fail verdict is exactly that signal.

---

## Principles

1. **Loops are the primitive.** The maker-checker loop is the atomic unit of work. A maker generates code. A checker verifies it against a quality rubric. The loop iterates until the checker passes, improvements taper off, or a human is needed. Hard budgets on time, tokens, and retries. "Admit failure" is a first-class outcome.

2. **Meet teams where they are.** Teams track work in Linear, review code in GitHub, communicate in Slack. Algedonia does not replace these tools. It owns what doesn't exist elsewhere: the loop — the structured feedback cycle between "ticket created" and "PR ready." Algedonia is the engine room, not the bridge. (v1 ships with local ticket management; tracker sync is a post-v1 integration layer.)

3. **Humans steer at the right altitude.** Higher than code, lower than tickets. The loop level is where humans see what the agent attempted, what verification found, and where it's stuck. Attention is the only scarce resource: escalations are queued one at a time, circuit breakers prevent failure floods. Each ticket may have different feedback loops — some use UI validation, some use unit tests, some use both. The checker config is the lever humans pull.

4. **Skills are the commodity.** OpenAI's harness engineering team spent months hand-building bespoke feedback loops (Chrome DevTools for UI, per-worktree observability, custom linters as guardrails). This doesn't generalize without similar investment. Algedonia commoditizes these as skills — reusable, composable, shareable units of capability. Run a command, drive a browser, query metrics, ask another agent to review. Skills are the building blocks; planning composes them per-ticket. The platform provides the feedback loops that teams would otherwise build by hand.

5. **Artifacts are the product, reflection is the flywheel.** Users want a codebase, not chats. Every loop produces commits, verdicts, and receipts. When a loop lands, the system reflects: what worked, what didn't, what human nudges were needed. Reflection outputs are actionable — update a guideline, add a skill, tighten a checker. Those outputs become tickets that enter the same system. The platform improves itself through its own primitive.

6. **Anti-entropy.** Tech debt is entropy — once introduced, it spreads. Every commit survives the checker before landing. There is no "clean up later." The checker config is the membrane. Per-loop reflection accumulates codebase knowledge that tightens skills and maker prompts over time. Quality is a pre-condition, not an eventually-consistent property.

7. **Open source daemon, proprietary server.** The daemon runs on the user's machine, with their credentials, touching their code. It is open source (Apache 2.0) with a clean, auditable protocol. The server — loop orchestration, skills, ticket sync, queue/playback, collaboration — is the proprietary SaaS product. The daemon is commodity infrastructure (spawn processes, capture output, manage workspaces); there's nothing defensible about it, and keeping it closed would only invite fragmentation. Open sourcing it controls the protocol, enables community-built agent adapters, skills, and deployment targets, and earns trust through transparency rather than policy.

---

## Core Bet

Two agents in a loop — maker and checker — with commoditized skills and per-ticket planning is the correct fundamental primitive for agentic coding. It beats both fire-and-forget autonomous agents (Symphony) and open-ended LLM prompting. Structured verification produces measurably better output than prompt-based self-review.

### Why Not Reactive Cleanup?

The alternative model — exemplified by OpenAI's harness engineering — accepts that AI-generated code will contain slop and builds reactive mechanisms to catch it: cron jobs that run linters and auto-fix, flaky CI runs treated as follow-up tickets, periodic sweep tasks. Generate first, clean up later.

This is a slippery slope, especially with continuous deployment:

**Cleanup tickets compete with feature work.** They enter the same backlog. Under velocity pressure, they get deprioritized. At 3 agents this is manageable. At 30 agents, the cleanup backlog grows faster than any team can service it. You're running a quality deficit that widens with velocity.

**Flaky CI as follow-up tickets normalizes failure.** Once "it's probably just flaky" becomes an acceptable merge rationale, CI becomes advisory, not authoritative. Every flaky test is a crack in the foundation. With continuous deployment, you're shipping through those cracks — users see the slop before the cleanup ticket is even triaged.

**Reactive cleanup doesn't scale linearly.** More agents = more commits = more slop per unit time. But cleanup tasks are often harder than the original work (diagnosing root causes vs. generating new code). The ratio of slop-generated to slop-fixed tilts the wrong way as you scale.

**Algedonia's position: quality is a pre-condition, not an eventually-consistent property.** The checker is a gate, not a broom. Nothing lands without passing verification. A flaky test doesn't become a follow-up ticket — it blocks the loop. The maker either fixes the flakiness or the loop escalates to a human *before anything merges*. Entropy is stopped at the boundary, not tolerated and remediated after the fact.

The reactive model works when humans outnumber agents and can absorb the cleanup. It breaks when agents outnumber humans — which is the trajectory of the entire industry. Algedonia is designed for the world where 2 engineers oversee 20 agents, not the world where 3 engineers babysit 1.

---

## The Maker-Checker Loop

The maker-checker loop is the atomic unit of work.

- **Maker** generates code as a diff/patch.
- **Checker** verifies the diff by running the ticket's checker config — a pipeline of skill invocations configured during planning. The checker has no access to the maker's reasoning. This forces independent judgment.
- **Pass** — daemon pushes branch, creates PR, waits for CI. CI passes → merge (auto-land) or wait for human (review gate). CI fails → maker retries with CI output as feedback. **Fail** — maker retries with the checker's structured feedback. **Taper-to-pass** — when hard checker gates are met and diff from the previous iteration is cosmetic-only, checker can pass with taper rationale. **Taper-stall** — improvements taper without meeting hard gates; halt and notify human with context. **Clarify** — checker halts because critical requirements are missing; escalates to human. **Max turns reached** — escalate to human.

**Maker context:** Full history of attempts. Compressed summaries of older iterations. Full detail on the current iteration.
**Maker persistence:** when a maker run completes successfully, daemon creates a commit snapshot for that attempt before checker execution.

**Loop termination conditions:**
- Checker pass (success).
- Taper-to-pass (success with explicit taper rationale).
- Improvement taper without hard-gate completion (halt, notify human with iteration history).
- Max turns exceeded (failure, escalate to human).
- Manual human gate (optional checkpoint).

---

## Skills

Skills are the core abstraction. A skill is a reusable, composable unit of capability — something the daemon knows how to do. Skills serve both sides of the loop: maker skills generate code, checker skills verify it.

### Skill Format

Skills live in `.algedonia/skills/` in the repo as markdown files. Markdown is the format because both agents and humans need to read them. Structured frontmatter declares the interface; the body provides context, examples, and instructions.

```markdown
<!-- .algedonia/skills/test.md -->
---
name: test
type: command
run: "mix test"
pass: exit_code_zero
---
Run the full test suite. Pass = all tests green.
When tests fail, the output includes file paths and line numbers
that the maker can use to locate the issue.
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
Boot the app and drive a headless browser via Playwright.
The scenario is provided per-ticket during planning — it is NOT
defined here. This skill declares the capability; planning
parameterizes it.
```

```markdown
<!-- .algedonia/skills/security-review.md -->
---
name: security-review
type: agent_review
prompt: "Review this diff for security vulnerabilities and OWASP top 10"
criteria: "No critical or high severity findings"
---
Agent-based security review. Uses the same agent adapter interface
as the maker but with a review-specific prompt.
```

### Skill Types

Skills map to execution types on the daemon:

- **Command** — run a shell command. Pass = exit code zero. Feedback = stdout/stderr.
- **Browser** — boot the app, drive a browser via Playwright/CDP, validate UI behavior. The scenario is parameterized per-ticket during planning.
- **Agent review** — a second LLM reviews the diff against a prompt and criteria.
- **Observability** — query metrics/logs endpoints, check thresholds. (Future)

### The Commodity Ladder

Teams adopt skills incrementally:
1. **Command** — everyone has tests and linters. Ship day one.
2. **Agent review** — no infrastructure, just another LLM call. Easy to add.
3. **Browser** — requires a browser on the daemon. High value for UI work.
4. **Observability** — requires external infra integration. Hardest, most valuable for production systems.

### Ecosystem

Skills are the unit of sharing. When the daemon goes open source:
- Community-contributed skills (e.g., `playwright-visual-regression.md`, `terraform-plan-review.md`)
- Teams share skills across repos
- Meta-skills reference other skills (a `fullstack.md` that combines `test`, `lint`, and `browser-check`)

---

## Planning and Checker Configuration

Checker steps are not statically matched from templates. They are configured per-ticket during a planning phase, before the maker starts.

### The Planning Phase

In the kanban workflow, there is an explicit **Planning** state between Backlog and Todo. This is where the checker gets configured for each ticket:

1. **Ticket enters Planning** — it has a title, description, and acceptance criteria from the tracker.
2. **Planning agent runs** — reads the ticket's acceptance criteria, looks at the repo's available skills (`.algedonia/skills/`), and decides what to do:
   - **Straightforward ticket** (clear acceptance criteria, obvious skills): composes the checker config and moves the ticket to Todo automatically. No human gate. "Fix typo in README" → `compile + test + lint`, done.
   - **Ambiguous ticket** (vague acceptance criteria, multiple possible approaches): interviews the user — asks clarifying questions in the tracker (as comments) or in Algedonia's UI. Once clarified, proposes a checker config for review.
3. **Ticket moves to Todo** — now fully specified: what to build (acceptance criteria) AND how to verify it (checker steps with parameterized skills). Planning also injects project-default acceptance criteria (for example, latest-rebase requirement). Ready for the maker.

The planning agent's judgment about when to skip through vs. interview is the intelligence here, not a config toggle. Teams can tune this at the workspace level in Algedonia's settings — a spectrum from "always auto-approve" to "always require human review." The default is to let the agent decide.

### What a Checker Config Looks Like

The checker config is per-ticket data, not a YAML file. It's a list of skill invocations with ticket-specific parameters:

```
Steps:
1. skill: compile       (no params — always "mix compile --warnings-as-errors")
2. skill: test          (no params — always "mix test")
3. skill: lint          (no params — always "mix credo --strict")
4. skill: browser-check (scenario: "navigate to /settings, fill display name, submit, verify toast")
5. skill: security-review (criteria: "no auth bypass, no XSS in form inputs")
```

Steps 1–3 are the **base pipeline** — skills that run on every ticket. They come from the project config and are prepended automatically. Steps 4–5 are ticket-specific, composed during planning.

### Base Pipeline

Every repo has a base pipeline: the skills that should always run regardless of the ticket. These are declared in the project config:

```
base_pipeline: [compile, test, lint]
```

The base pipeline runs first on every loop. Planning adds ticket-specific skills on top. This ensures the immune system (compile + test + lint) is never skipped, even if planning produces an empty config.

### Planning Agent

The planning agent is itself a skill. When a ticket enters Planning, Algedonia can optionally run a planning skill that:
1. Reads the ticket's acceptance criteria
2. Reads the repo's available skills (`.algedonia/skills/`)
3. Proposes a checker config: which skills to use and how to parameterize them
4. The human reviews and approves (or the config auto-applies if the team trusts the planning agent)

This means planning is a loop too — the planning agent proposes, the human reviews. Same pattern all the way up.

### Editing Mid-Loop

The checker config is immutable once the loop starts, with one exception: a human can edit it via the steer panel in the Loop View. This is useful when a loop is stuck because the checker is wrong (e.g., the browser scenario doesn't match the actual UI). Edits apply to the next iteration.

---

## Ticket Integration (Not a Ticket Tracker)

Algedonia does not replace Linear, GitHub Issues, or Jira. The long-term vision is bidirectional sync — tickets flow in from the tracker, status and results flow back.

> **v1 scope:** Tracker sync (Linear adapter, polling, bidirectional updates) is deprioritized. v1 ships with local ticket CRUD inside Algedonia — users create and manage tickets directly in the UI. The data model supports future sync (tickets have fields like `labels`, `blocked_by`, checker configs), but no external tracker connection ships in v1. The sections below describe the target architecture for when sync is added.

### How It Works (Post-v1)

Algedonia connects to a tracker project (e.g., a Linear project). Tickets flow through the kanban: Backlog → Planning → Todo → In Progress → Done. Algedonia picks up tickets in "Todo" (checker config already set during Planning). If it's in the project and it's ready, an agent works on it.

### Inbound Sync (Post-v1)
- Poll the tracker API on a fixed cadence.
- Import tickets in active states: ticket ID, title, description, status, acceptance criteria.
- Store as a lightweight mirror record in Postgres.
- Tickets that move to a terminal state (Done, Cancelled) have their active loops stopped and cleaned up.

### Outbound Sync (Post-v1)
- Loop started → update ticket status (e.g., "In Progress").
- Loop passed → update ticket status (e.g., "Ready for Review"), attach PR link.
- Loop stuck → post a comment with what's blocking and iteration context.
- Checker step results are posted as structured comments on the ticket so progress is visible without leaving the tracker.

### What Algedonia Owns
- Loops attached to each ticket (one or more).
- Checker config per loop (skill invocations composed during planning).
- Iteration history (maker output, checker feedback, per-step results).
- Termination state and human feedback thread.

### What the Tracker Owns
- Backlog management, prioritization, sprint planning.
- Ticket CRUD, workflow states, assignments.
- Team-wide views and dashboards.
- The decision of what gets worked on: move a ticket to "Todo" and it gets picked up. Move it to "Cancelled" and the loop stops.

### Adapters (Post-v1)
- **Linear** — first adapter. Proven by Symphony's adoption.
- **GitHub Issues** — second adapter.
- Others as demand requires.

### Playback Controls

Algedonia borrows from music players. The Linear project is the library. Not everything in the library is playing.

**Global controls:**
- **Play / Pause** — globally start or stop picking up new work. Pause doesn't kill running loops; it just stops new ones from starting. Useful for "let me catch up on reviews before more PRs pile up."
- **Concurrency** — how many loops run in parallel. Turn it to 1 for sequential focus, crank it up for overnight batch runs. This is a ceiling — actual parallelism is bounded by daemon capacity. If you set concurrency to 10 but only have 3 daemon slots available, you get 3. The UI shows both the configured limit and the effective limit so the coordinator knows when they're daemon-constrained vs choice-constrained.

**Per-ticket controls (set in Algedonia Ticket Detail; tracker adapters can mirror when enabled):**
- **Auto-land** — checker passes, daemon pushes branch, creates PR, waits for CI. If CI is green, daemon merges the PR. No human in the loop. For low-risk, well-tested changes (dependency bumps, typo fixes, refactors with good test coverage). If CI fails, the loop iterates — CI output becomes maker feedback.
- **Review gate** — same flow, but after CI passes the PR waits for human approval before merging. The default for most feature work.
- **Agent selection** — choose which coding agent runs maker/checker. The dropdown is filtered to agents reported as available by the assigned daemon; unavailable agents cannot be spawned.
- **Queue position** — explicit ordering. Tickets are worked in priority order by default (from Linear's priority field), but the coordinator can drag to reorder in Algedonia's queue view.
- **Skip** — move past a stuck ticket without cancelling it. It goes back to the library.
- **Halt-at checkpoint** — select a ticket where autoplay should stop once that ticket reaches a terminal state.

Landing mode defaults are configured at workspace settings level; each ticket can override mode in Ticket Detail.

**Dependencies:**
Tickets support `blocked_by` relations. When tracker sync is added, these will be synced from the tracker; in v1, they are set manually. Algedonia respects them during dispatch:
- A ticket is **dispatchable** only when all its blockers are in terminal states (Done, Closed, etc.).
- Blocked tickets stay in the queue at their priority position but are skipped during dispatch. They're visually marked as blocked, showing which tickets they're waiting on.
- When a blocking ticket's loop passes and lands, Algedonia re-evaluates its dependents. Newly unblocked tickets become dispatchable immediately.
- This means the queue is not strictly sequential — it's a priority-ordered list with dependency constraints. Multiple non-blocked tickets dispatch in parallel up to the concurrency limit.

Dependencies are read-only from the queue's perspective. Teams manage them in the ticket UI (or in the tracker, once sync lands). Algedonia just respects what's there.

**The queue vs the library:**
The ticket list is the library — everything that could be worked. The queue is the ordered subset that will be worked next. By default, all active-state tickets enter the queue sorted by priority. But the coordinator can:
- Remove a ticket from the queue (back to backlog).
- Pin a ticket to the top of the queue.
- Pause a specific ticket's loop without pausing everything.

In Algedonia's Tickets view, the queue is rendered as a dedicated left sidebar so coordinators can manage dispatch without leaving ticket context.

This gives teams a spectrum from full autopilot ("everything ready gets worked and auto-landed") to careful curation ("I pick what's next, I review every PR").

### Configuration

A project-level config (inspired by Symphony's `WORKFLOW.md`) defines defaults:

```yaml
playback:
  concurrency: 3            # max parallel loops (ceiling; actual WIP ≤ daemon capacity)
  default_land: review_gate # or auto_land
defaults:
  base_pipeline: [compile, test, lint]  # skills that run on every ticket
  max_iterations: 5          # project-level iteration budget (not per-ticket)
```

`max_iterations` is configured at project/workspace level and is not edited on individual tickets.

> **Post-v1** — tracker sync adds `tracker` (kind, project_slug, states) and `polling` (interval_ms) sections, plus `auto_start` to playback for auto-queueing synced tickets.

---

## UI: The Loop Viewer

The UI exists for one purpose: show loops and let humans steer. It is not a project management tool.

Users come to Algedonia only when they want to see work happening or intervene. Everything else stays in their existing tools.

### Loop View (`/loops/:loop_id`)

The primary (and initially only) workspace.

**Left panel — Ticket's Loops:**
List of loops for the current ticket. Each shows status, current iteration, skill names from checker config. Click to load.

**Center panel — Loop Detail:**
- Current iteration: checker's step-by-step verdicts (skill name, pass/fail, summary, duration). Scrollback streamed from daemon for detailed output.
- Iteration history: collapsible timeline showing convergence (or lack thereof). Each iteration shows the verdict per step. Diffs and raw output stay on the daemon.
- Taper indicator: visual signal of whether improvements are diminishing.

**Right panel — Steer:**
- Feedback input: type guidance that feeds into the next maker iteration.
- Checker config: view the skill invocations and their params. Editable — changes apply to the next iteration.
- Acceptance criteria: synced from the ticket, editable.

**No terminal view in v1.** The previous design showed a live agent terminal. This is deferred. The loop viewer shows structured verdict data (pass/fail per step, summaries), not raw terminal output or code. Scrollback is streamed from the daemon for users who want detail. This is the "right altitude" — higher than code scrolling by, lower than ticket status.

### Monitor (`/monitor`)

- Escalation queue: one at a time, one-piece flow. Shows the stuck loop's context, iteration history, and checker feedback.
- Circuit breaker status.
- Active loops overview across all daemons.
- Daemon health: each daemon shows its owner (user name + avatar), capacity, status, and discovered available agents. Daemons are user-bound — one daemon serves all workspaces the user belongs to. The monitor filters to daemons whose users are members of the current workspace.

### What We Don't Build
- Full project management (sprint planning, epics, roadmaps — use Linear once sync lands).
- PR review UI (use GitHub).
- Notification center (use Slack/email — we push notifications there).

---

## Architecture

Two components. Clear boundary.

**Server (Phoenix LiveView)** — the brain. Owns loop orchestration, planning, checker execution, tickets, UI, state, collaboration, persistence. Source of truth for all state.

**Daemon (Go, open source)** — the hands. Runs on the user's machine. Receives commands from the server, executes them, reports back. Thin, auditable, trustworthy.

### The Boundary Principle

The server never executes agents or touches LLM APIs. The daemon never makes orchestration decisions. The server says "run this." The daemon runs it and reports back.

### Why the Daemon is Open Source

The daemon is commodity infrastructure — it spawns processes, captures PTY output, manages workspaces, and reports back. There is nothing defensible about it. The value is in the server: loop orchestration, planning, skills ecosystem, the queue/playback model, collaboration.

Open sourcing the daemon serves four purposes:

1. **Trust.** The daemon runs on the user's machine with their credentials and code. Open source means anyone can audit that it never phones home, exfiltrates data, or takes undocumented actions. The protocol is public. No trust-me-bro.

2. **Ecosystem.** The daemon defines the agent adapter interface. Open source means the community can add adapters for new agents (Cursor, Windsurf, whatever ships next) without waiting on us. Every new adapter makes the server more valuable.

3. **Protocol stability.** A public protocol has a social cost for breaking changes. This pressure forces us to nail the interface before shipping, which is exactly the right discipline.

4. **Long-tail environments.** We can't staff a team to handle every PTY quirk on NixOS, every corporate proxy issue, every agent CLI version mismatch. The community can.

The server remains proprietary — it's the SaaS product. The daemon is the distribution channel.

### Open Source Strategy

- Build the daemon closed-source initially while the interface is unstable.
- Open source once the protocol stabilizes — make it a launch event.
- License: Apache 2.0 (enterprise-friendly, no AGPL fear).
- Ship as a standalone repo with its own docs, README, and protocol spec. Not a subdirectory of the server monorepo.
- The protocol spec is the contract. Third parties can build alternative daemons (in Rust, Python, whatever) as long as they speak the protocol.

### Daemon Interface (the contract to nail first)

The daemon interface is the most important design boundary. It must be:
- **Minimal** — few commands, few events, clear semantics.
- **Auditable** — every command and event is human-readable JSON.
- **Safe** — the daemon never takes destructive action without an explicit command.

**Server → Daemon commands:**
- `run_maker` — spawn an agent to implement a task in a workspace.
- `run_checker_step` — execute one checker skill invocation in a workspace.
- `land` — push branch, create PR, wait for CI, optionally merge.
- `stop` — terminate a running process.
- `stdin_input` — send user input to a running process.

**Daemon → Server events:**
- `maker_result` — maker completed (exit code, files changed, duration, token usage). No code or diffs.
- `step_result` — a checker step completed (skill name, pass/fail, summary, duration).
- `land_result` — landing outcome (PR URL, CI status, merge SHA if auto-landed).
- `terminal_output` — streaming PTY output.
- `heartbeat` — capacity, running loops, available agents (from setup discovery), bare repos, system metrics.
- `error` — something went wrong.

The daemon does not interpret results. It captures and forwards. The server decides what they mean.

### Agent Adapters

Agents are pluggable adapters inside the daemon. The adapter interface:
- `Start(workdir, task, config) → Process`
- `AttachPTY(process) → (reader, writer)`
- `Wait(process) → ExitResult`
- `Kill(process)`
- `SessionID(process) → string`

**Supported agents (v1):** Claude Code, Codex, pi.

Each adapter knows how to construct the CLI invocation, pass the task, and collect results. The adapter does not interpret output.

**Agent setup and availability contract:**
- On daemon startup/reconnect, run an explicit setup phase that discovers which supported agent runtimes are actually installed.
- Register only discovered adapters; do not run agent-specific setup for missing runtimes (for example, no Claude hook installation when Claude is absent).
- Publish discovered availability in daemon heartbeats so the server and UI share one source of truth.
- Server rejects dispatch if a ticket requests an agent not available on the selected daemon, with explicit setup guidance.

---

## Workspace Isolation

Each loop runs in its own workspace — a directory with a full repo checkout. No file-level locking needed; workspaces are isolated by definition.

- On loop start, the daemon ensures a bare clone exists and creates a worktree.
- Project-default acceptance criteria include latest-rebase requirements, and planning injects those defaults into each ticket.
- On loop pass, the daemon pushes the branch, creates a PR, and waits for CI. Merge happens daemon-side (auto-land) or human-side (review gate).
- Workspaces persist across iterations within a loop but are cleaned up after completion.

This is simpler than the file-level locking approach in v4. Multiple loops on the same ticket may touch overlapping files, but they run sequentially (one loop at a time per ticket) or in isolated workspaces with merge-at-the-end semantics.

---

## Escalation and Circuit Breaker

When a loop exhausts its retries or taper is detected, it escalates.

- **Escalation queue:** One at a time (one-piece flow). Remaining escalations sit in FIFO. The queue does not stop loops from running.
- **Circuit breaker:** Three states — closed (loops spawn freely), open (stop spawning after N consecutive escalations), half-open (test with one loop). Manual resume required.
- **Focus mode:** Hides everything except the current escalation.

---

## Real-Time Collaboration

Multiple users can view the same loop simultaneously. Presence shows who is watching what. When a loop is stuck, the team sees the same context and can discuss (in Slack, on a call) while one person types feedback into Algedonia.

Collaboration is about shared visibility into loops, not about replacing team communication tools.

---

## Logging and Receipts

The server stores only structured verdicts — no code, no diffs, no raw output:
- Per-iteration verdict (pass/fail/taper) with duration and token usage.
- Per-step verdict (skill name, pass/fail, summary, duration).
- Human feedback per iteration.

Detailed output (diffs, terminal scrollback, screenshots) stays on the daemon. The Loop View streams scrollback in real time; historical output is available as long as the daemon retains it. This keeps the server code-free — it orchestrates and records outcomes, never sees source code.

---

## Reflection and Process Improvement

When a loop lands, the work isn't done. The system reflects on the loop to extract process improvements. This is the flywheel: every completed ticket makes future tickets cheaper.

### What Reflection Analyzes

The reflection agent has access to the full loop history:
- **Human nudges** — every piece of feedback a human typed into the steer panel. These are the most valuable signal: each nudge means the system was missing context, a guideline, or a skill that would have avoided the intervention.
- **Agent trajectory** — how many iterations, which checker steps failed and why, what the maker tried before converging.
- **Checker verdicts** — which skills caught real issues vs. which were noise.
- **Planning decisions** — was the checker config right? Were skills missing?

### What Reflection Produces

Reflection outputs are **concrete, actionable items** — not notes in a knowledge file. Each output becomes a ticket in the tracker that enters the same system:

- **Guideline updates** — "The maker kept forgetting to mock auth in tests. Add to ARCHITECTURE.md: 'All LiveView tests require a session fixture.'" → ticket → planning → loop → lands as a doc update.
- **New skills** — "Three tickets in a row needed a database migration check. Create a `migration-check` skill that runs `mix ecto.rollback && mix ecto.migrate` to verify reversibility." → ticket → planning → loop → lands as a new `.algedonia/skills/migration-check.md`.
- **Skill refinements** — "The browser-check skill's boot timeout is too short for the app's cold start. Update the skill default from 30s to 60s." → ticket → loop → lands.
- **Codebase knowledge** — "This repo uses a custom auth pattern where sessions are stored in ETS, not cookies. Future makers need to know this." → ticket → loop → lands as a knowledge update that gets injected into maker context.
- **Checker improvements** — "The linter caught 0 real issues across 15 tickets but added 8 seconds per iteration. Consider removing from base pipeline or running only on changed files." → surfaced to the human as a recommendation, not auto-applied.

### The Flywheel

```
Ticket → Planning → Loop → Land → Reflect
                                      ↓
                          Improvement tickets
                                      ↓
                    Planning → Loop → Land → Reflect
                                                ↓
                                    (further improvements)
```

Each cycle tightens the system: makers get better context (updated guidelines, knowledge), checkers get sharper (new skills, refined configs), and humans intervene less (the nudges they made last time are now baked in). The human nudge rate is the key metric — it should trend downward over time.

### What Reflection Does NOT Do

- **Auto-apply changes without a ticket.** Every improvement goes through the same planning → loop → verification flow. No backdoor commits.
- **Create cleanup tickets for code quality.** That's the reactive model we reject. If the code has quality issues, the checker should have caught them before landing. Reflection improves the process, not the code.
- **Generate busywork.** Reflection is selective. If a loop passed on the first iteration with no human nudges, there may be nothing to reflect on. The reflection agent should produce zero tickets when there's nothing actionable.

---

## User Journeys

### Solo Developer, Bug Fix

1. Developer creates a ticket in their Linear project: "Fix onboarding drop-off at step 3."
2. Moves it to "Planning." Algedonia's planning agent reads the acceptance criteria and the repo's skills, proposes checker config: `compile`, `test`, `browser-check` with scenario "navigate to /onboarding, complete steps 1–3, verify no drop-off."
3. Developer reviews the checker config, tweaks the browser scenario, moves to "Todo."
4. Algedonia picks it up. Iteration 1: maker fixes the bug, base pipeline passes, browser check finds a console error.
5. Iteration 2: maker fixes the console error. All steps pass.
6. PR appears on GitHub. Linear ticket moves to "Review."
7. Developer reviews the PR in GitHub as usual.

### Team, Multiple Tickets

1. PM creates and prioritizes tickets in Linear.
2. PM moves tickets to "Planning." For each, the planning agent proposes checker configs based on acceptance criteria and available skills. Engineer reviews and moves to "Todo."
3. Algedonia picks them up automatically. Each ticket has its own checker config — a backend refactor runs `compile + test + lint`, a frontend feature adds `browser-check` with a specific scenario.
4. A loop on ticket A gets stuck — browser check fails repeatedly. Algedonia posts a comment on the Linear ticket: "Loop stuck: browser-check failing on /settings page after 3 iterations. [View loop →]"
5. Engineer clicks through to Algedonia, sees iteration history, types feedback: "The settings page needs auth — mock the session in the test setup."
6. Loop resumes, passes on the next iteration.

### Overnight Batch

1. Engineer plans several tickets (reviews checker configs), moves them to "Todo" before leaving.
2. Algedonia works through them overnight. Some loops complete (PRs appear), some taper (improvements plateau), some escalate (stuck).
3. Morning: Linear tickets show updated statuses. The Monitor view shows a clear queue of decisions to make. PRs are waiting for review on GitHub.

---

## Future Layers (Post-V1)

The loop primitive is general. V1 applies it to coding. Future layers extend upward:

### Smart Orchestration (V2)
The orchestrator decides what to work on next, informed by signals beyond the ticket queue:
- Telemetry data (error rate spike → auto-create ticket → spin up loop).
- CI/CD signals (flaky test detected → create fix ticket).
- Dependency alerts (security advisory → create upgrade ticket).
- Event-driven orchestration policies enable these automations.

### Product Experimentation (V3)
A layer for PMs where product work is treated as a loop of experiments with falsifiability:
- Hypothesis → acceptance criteria → checker config (does the metric move?).
- Interview storage, experiment results, learning accumulation.
- Product decisions feed down into the orchestration and execution layers.

Each layer makes the layers below stickier, but each layer must work standalone first.
