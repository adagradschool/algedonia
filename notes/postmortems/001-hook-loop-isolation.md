# Postmortem 001: Hook Loop Isolation Bug

**Date:** 2026-03-02
**Severity:** High — blocked normal ticket workflow for all users
**Fix PR:** #37 (Fix hook automation isolation, loop transitions, and ticket UI regressions)
**Related ticket:** ALG-40 (Transition hooks / automation agents)

---

## Summary

When ALG-40 added transition hooks (automation that fires when tickets change status), it introduced a new loop role `:hook` alongside the existing `:task` role. Four existing code paths assumed all loops in a DAG were task loops and did not filter by role. This caused hook loops to interfere with task loop orchestration — blocking ticket completion, mis-routing daemon callbacks, polluting the UI with un-startable loops, and returning incorrect "first loop" references for ticket inspection.

Users saw "Unable to start loop" errors and tickets stuck in unexpected states.

---

## Timeline

1. **ALG-40 implementation begins** — Added `TransitionHook` schema, `HookExecutor` module, `:hook` role to loop enum, and `ticket_id` foreign key on loops.
2. **Hook loops created in existing DAGs** — When tickets transitioned status, hook loops were inserted into the same DAGs used by task orchestration.
3. **Bug surfaces** — Task completion checks, auto-start logic, inspection queries, and daemon callback routing all operated on unfiltered loop lists, treating hook loops as task loops.
4. **Symptoms observed** — Tickets could not complete (hook loops not `:passed` blocked the "all passed?" check). LiveView auto-start tried to start hook loops and failed. Daemon callbacks for hook completions were routed to `TaskLoopOrchestrator` instead of `HookExecutor`.
5. **Fix shipped in PR #37** — All four code paths updated to filter by loop role. Hook routing added to daemon channel.

---

## Root Cause Analysis

### Proximate Cause

Four code paths operated on all loops in a DAG without filtering by role. When `:hook` loops were added, they were silently included in queries and logic designed exclusively for `:task` loops.

**Affected code paths:**

1. **`server/lib/algedonia/planning.ex`** — Planning session logic did not distinguish hook loops from task loops when evaluating DAG state.

2. **`server/lib/algedonia/dags.ex` (2 paths):**
   - `first_loop_ids_for_tickets/1` — Returned the first loop per ticket without filtering by role, so a hook loop could be returned instead of the task loop.
   - `first_inspect_loop_ids_for_tickets/1` — Same issue: hook loops included in inspection results, leading to incorrect loop references in the ticket list UI.

3. **`server/lib/algedonia/task_loop_orchestrator.ex`** — `maybe_complete_ticket/1` checked if *all* loops in the DAG were `:passed`. Hook loops (which have their own lifecycle) were included, preventing ticket completion even when all task loops had passed. Additionally, `auto_start_planning_loop/2` could select a hook loop for auto-start.

4. **`server/lib/algedonia_web/live/loop_live/show.ex`** — LiveView auto-start logic (`should_auto_start?/1`) did not check `loop.role`, so it attempted to auto-start hook loops, producing "Unable to start loop" errors.

### Contributing Factors

1. **No isolation invariant documented** — There was no stated rule that "new loop roles must not appear in existing task-only queries." The implicit assumption that all loops are task loops was never written down as an invariant to protect.

2. **No cross-cutting query audit** — Adding a new enum variant (`:hook` to the loop role) is a cross-cutting change. Every `WHERE` clause, `Enum.filter`, and pattern match on loops should have been audited, but no process existed to trigger such an audit.

3. **No blast radius analysis in planning** — The planning phase for ALG-40 focused on the new modules (`HookExecutor`, `TransitionHook`) without systematically examining how existing code would interact with the new role.

4. **Missing interaction tests** — Existing tests for `Dags`, `TaskLoopOrchestrator`, and the LiveView did not include scenarios with mixed-role loops, so the regressions were not caught by the test suite.

---

## What Went Right

- **Fix was contained** — Once identified, the fix was straightforward: add role filters to the four affected paths and add role-based routing in the daemon channel.
- **New test coverage is thorough** — PR #37 added 548 lines of tests covering hook execution, task/hook filtering in DAG queries, daemon channel routing, and ticket update hook triggers.
- **`skip_hooks: true` recursion guard** — The original implementation correctly anticipated hook failure recursion (hook fails → ticket halts → halt transition fires hooks → infinite loop) and built in the `skip_hooks` opt-out. This was a well-designed safety mechanism.
- **Isolation architecture is sound** — The fix established clear boundaries: `TaskLoopOrchestrator` handles `:task` loops, `HookExecutor` handles `:hook` loops, daemon channel routes by role.

---

## What Went Wrong

1. **Schema extension treated as additive-only** — Adding `:hook` to the loop role enum was treated as purely additive ("just a new variant"), without considering that existing code implicitly matched on the full set of variants.

2. **Planning did not include an impact audit** — The plan for ALG-40 listed new modules to create but did not audit existing modules that query loops.

3. **No grep/search for existing loop queries** — A simple `grep -r "list_loops\|Enum.all.*loop\|loop.*status\|loops_for" server/lib/` would have surfaced all four affected paths.

4. **Test gaps in shared data models** — Loops are a shared data model (used by DAGs, orchestrator, LiveView, planning). Tests for these consumers did not cover the scenario where loops of different roles coexist in the same DAG.

---

## Action Items

| # | Action | Owner | Files/Sections |
|---|--------|-------|----------------|
| 1 | Add "Planning Quality" rubric section to `notes/rubrics.md` with criteria for impact audits, blast radius analysis, and cross-cutting query audits when extending schemas. | This PR | `notes/rubrics.md` — new section after Part 1 |
| 2 | Add interaction tests for all DAG query functions with mixed-role loops (`:task` + `:hook` in same DAG). | Follow-up | `server/test/algedonia/dags_test.exs` |
| 3 | Add interaction tests for `TaskLoopOrchestrator` with hook loops present in the DAG. | Follow-up | `server/test/algedonia/task_loop_orchestrator_test.exs` |
| 4 | Add interaction tests for `LoopLive.Show` with hook loops to verify auto-start is skipped. | Follow-up | `server/test/algedonia_web/live/loop_live/show_test.exs` |
| 5 | Document loop role isolation invariant: "Queries in task orchestration, planning, and UI paths must explicitly filter by `role == :task` (or `role != :hook`). New roles must not leak into existing paths." | Follow-up | `notes/sdd.md` — Loops section |
| 6 | Add a checklist item to the slice template: "Cross-cutting query audit: searched for all queries on `<modified schema>` and verified they handle the new variant." | Follow-up | `notes/slices.md` — template section |
