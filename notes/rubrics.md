# Rubrics (Current)

## Elixir Quality
- E8: No compiler warnings.
- E9: `mix format --check-formatted` passes.
- E10: `mix credo --strict` passes.

## Workflow Correctness
- W1: `start_work/1` only accepts `planning` and `halted` tickets.
- W2: Work loop resolution is ticket-scoped by `ticket_id` only.
- W3: Existing task loop is reused; otherwise a new task loop is created.
- W4: No runtime dependence on DAG/dependency graph structures.

## Orchestration
- O1: Task loops run maker -> checker with persisted history.
- O2: Checker handoff validation handles pass/fail/error paths.
- O3: Ticket completes when all task loops for the ticket are `passed`.
- O4: Hook loops do not block task-loop completion criteria.

## Daemon Channel
- D1: `attempt_complete` routes by loop role (`task` vs `hook`).
- D2: `error` routes by loop role (`task` vs `hook`).
- D3: No `loop_result`/decomposition callback surface remains.

## Database / Ecto
- EQ1: `loops` uses `ticket_id` as required association.
- EQ2: Role constraint only allows `task` and `hook`.
- EQ3: Cleanup migration is explicit `up/down`; `down` raises with irreversible rationale.
- EQ4: Graph tables/columns removed (`dags`, `loop_dependencies`, `loops.dag_id`).

## UI
- U1: No DAG route exists.
- U2: No DAG LiveView exists.
- U3: Loop inspector remains functional in single-loop mode.
- U4: Ticket navigation resolves to first inspectable loop by `ticket_id`.

## Tests
- T1: Public workflow functions have happy/error path coverage.
- T2: Hook and task role routing are covered in channel/orchestrator tests.
- T3: `mix test` passes.
- T4: `go test ./...` passes.

## Verification Checklist
1. `rg` confirms no references to removed DAG/decomposition runtime paths.
2. Run `mix format --check-formatted`.
3. Run `mix credo --strict`.
4. Run `mix test`.
5. Run `go test ./...`.
