# Tech Debt Recon: Top 10 High-Leverage Items (Ticket #2)

Date: 2026-03-05
Parent ticket: #2
Follow-up tickets: #6, #7, #8, #9, #10, #11, #12, #13, #14, #15

Scoring model: `Priority score = Impact + Leverage + Effort-to-start`.

## Ranked backlog

1. Split TaskLoopOrchestrator God GenServer into role/state coordinators (`#6`)
- Area: server
- Evidence: `server/lib/algedonia/task_loop_orchestrator.ex` (477 LOC), pending branch at lines 214-215, direct `Algedonia.Repo.preload/2` at line 449.
- Rationale: Critical orchestration lifecycle logic is centralized; defects here affect correctness and throughput broadly.
- First remediation slice: Extract cleanup and handoff-repair flows into companion modules with behavior seams; keep API stable.

2. Decompose daemon loopmanager responsibilities (`#7`)
- Area: daemon
- Evidence: `daemon/internal/loopmanager/manager.go` (484 LOC), `daemon/internal/loopmanager/handlers.go` (343 LOC), retry sleeps in `manager.go:113`.
- Rationale: Coupled lifecycle/network/worktree logic increases concurrency regression risk and slows safe iteration.
- First remediation slice: Introduce internal services/interfaces and move diff handling to a dedicated `DiffService` with parity tests.

3. Harden DaemonChannel payload validation and reduce channel surface (`#8`)
- Area: server
- Evidence: `server/lib/algedonia_web/channels/daemon_channel.ex` (274 LOC) with strict key pattern matching and no fallback validation reply path.
- Rationale: Daemon and server boundary is high-frequency; malformed payload handling gaps can cause crashes or inconsistent outcomes.
- First remediation slice: Add event-specific validators and fallback `handle_in` error replies.

4. Remove `time.Sleep`-based daemon test synchronization (`#9`)
- Area: daemon
- Evidence: 22 `time.Sleep(...)` calls across daemon tests (`manager_test.go`, `server_test.go`, `routing_test.go`, `adapter_claude_test.go`).
- Rationale: Fixed sleeps create flaky CI behavior and slower feedback loops.
- First remediation slice: Add shared wait-until helpers and migrate `manager_test.go` first.

5. Break up LiveView god modules and enforce thin event handlers (`#10`)
- Area: server
- Evidence: `onboarding_live.ex` (584 LOC), `loop_live/show.ex` (463 LOC), `automations_component.ex` (309 LOC).
- Rationale: UI-side business logic concentration increases bug risk and slows delivery/review.
- First remediation slice: Extract onboarding side effects into context modules; keep `handle_event` thin.

6. Add missing DB indexes for hot loop query predicates (`#11`)
- Area: server
- Evidence: Query predicates and order in `server/lib/algedonia/dags.ex` (lines 166, 197, 329, 340) use `loops.role` and `loops.inserted_at`; migration `20260222130806_create_dags_and_loops.exs` lacks matching indexes.
- Rationale: Loop status views and orchestration reads are core paths; missing indexes risk latency growth at scale.
- First remediation slice: Add composite indexes and validate target queries with `EXPLAIN`.

7. Consolidate agent command argument construction and remove unsafe default flag duplication (`#12`)
- Area: daemon
- Evidence: `--dangerously-skip-permissions` duplicated in `adapter_claude.go:26`, `handlers.go:67`, `manager.go:368` with separate arg-construction paths.
- Rationale: Argument drift across loop types can produce inconsistent behavior and higher security/correctness risk.
- First remediation slice: Build a shared command-arg builder and migrate all launch paths.

8. Complete `decompose_checker` orchestration path and remove untracked pending marker (`#13`)
- Area: server
- Evidence: `task_loop_orchestrator.ex` has a pending marker at lines 214-215; current fallback effectively no-ops for that role.
- Rationale: Unimplemented role path can silently skip expected transitions in the execution pipeline.
- First remediation slice: Implement explicit success/error handling for `:decompose_checker` with regression tests.

9. Resolve setup and docs drift with role-specific runbooks (`#14`)
- Area: cross-cutting
- Evidence: `server/README.md` is Phoenix boilerplate; root README has monorepo setup; `daemon/` lacks a dedicated README.
- Rationale: Docs drift increases onboarding and incident-response time.
- First remediation slice: Create canonical `server/README.md` and `daemon/README.md` runbooks with verified commands, env vars, and troubleshooting.

10. Modularize `ag` CLI command tree to reduce change risk (`#15`)
- Area: daemon
- Evidence: `daemon/cmd/algedonia-agent/main.go` (589 LOC), `daemon/cmd/algedonia-agent/ticket.go` (611 LOC).
- Rationale: Monolithic command files raise merge conflict rate and accidental regression risk.
- First remediation slice: Split ticket subcommands into per-command modules with shared option structs and help-contract tests.

## Coverage balance

- Execution risk: #1, #2, #3, #4, #6, #8
- Developer experience: #4, #5, #7, #9, #10
- Server: #1, #3, #5, #6, #8
- Daemon: #2, #4, #7, #10
- Cross-cutting: #9
