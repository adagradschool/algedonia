# #67: Orchestrate Ordered Checker Skill Pipeline with Step Receipts

| Field | Value |
|-------|-------|
| Status | completed |
| Type | feature |
| Priority | P1 |
| Coding Agent | codex |
| Created | 2026-03-08 10:27 UTC |
| Updated | 2026-03-08 15:00 UTC |

## Description

### ALGE-003 — Orchestrate Ordered Checker Skill Pipeline with Step Receipts

Priority: P0 | Size: L | Owner boundary: backend\
Depends on: ALGE-002, ALGE-002A

Outcome

- Each checker attempt runs a deterministic ordered pipeline (`base pipeline` + `ticket-specific checker steps`) and records structured per-step receipts that drive loop decisions.

Refined Scope

- Build orchestrator-side sequencing and decision logic for multi-step checker execution.
- Persist step-level receipts with enough structure for retry/escalation and operator inspection.
- Enforce pass/fail gating from required checker steps only.

Assumptions

- ALGE-002/ALGE-002A provide validated checker step definitions before loop execution starts.
- Skill execution remains delegated to runtime executors; this ticket orchestrates ordering, gating, and receipt interpretation only.

Implementation Notes

- Preserve maker/checker independence and project-level iteration budget constraints.
- Prefer fail-fast behavior on required-step failure to avoid noisy downstream checker runs.

Failure / Escalation Semantics

- Any required checker-step failure blocks pass for the attempt and feeds structured failure context into retry.
- Repeated checker failures follow project-level iteration budget policy and escalate cleanly to halted/stuck.

Out of Scope

- Runtime implementation details for browser/agent-review executors.
- Taper-to-pass policy logic (covered by ALGE-003A).

## Acceptance Criteria

1. For each checker attempt, orchestrator executes checker steps in strict configured order (`base` then `ticket-specific`) and stores one receipt per executed step with: `step_id`, `skill`, `order_index`, `required`, `verdict`, `summary`, and `attempt`.
2. A checker attempt is marked `pass` only when every required step in that attempt reports `verdict=pass`; any required step with non-pass verdict prevents pass.
3. On required-step failure, orchestrator emits retry payload feedback that includes failed `step_id`, `skill`, `verdict`, and human-readable `summary` from the receipt.
4. When checker failures exhaust iteration budget, loop transitions to halted/stuck escalation state with last failed step receipt retained in loop history.

## Rubric

- Base pipeline: `just lint && just test`

- approved_checker_config (additional, ordered):
  1. skill: command
     params: `cd server && mix test test/algedonia/task_loop_orchestrator_test.exs`
     pass signal: orchestrator tests cover ordered multi-step execution, required-step pass gating, structured retry feedback propagation, and budget-exhaustion escalation.

- Acceptance criteria to verification mapping:
  - AC1 -> `task_loop_orchestrator_test.exs` asserts ordered step sequencing and persisted step receipts with required metadata.
  - AC2 -> `task_loop_orchestrator_test.exs` asserts loop never marks checker pass when any required step is non-pass.
  - AC3 -> `task_loop_orchestrator_test.exs` asserts retry payload includes failed step identity and summary from checker receipt.
  - AC4 -> `task_loop_orchestrator_test.exs` asserts repeated failures transition to halted/stuck with last failed receipt preserved.

- Quality guardrails:
  - Keep orchestration logic inside backend loop orchestrator boundary; do not embed runtime executor specifics.
  - Keep checker decisions receipt-driven (structured fields), not raw log text heuristics.
  - Avoid adding new cross-boundary contracts unless required for receipt schema compatibility.

## Comments

### codex (2026-03-08 13:05 UTC)

Refinement outcome (planning mode: `auto`): requirements are sufficiently concrete to proceed without interview; approved for implementation under explicit assumptions in description.

Implementation plan (loop-ready)
1. Build ordered checker step plan per attempt inside orchestrator.
   - Compose `base pipeline` + `ticket-specific` checker steps into one deterministic sequence.
   - Normalize per-step runtime metadata (`step_id`, `order_index`, `required`, `skill`, params snapshot).
2. Execute checker steps with fail-fast required-step semantics.
   - Run steps in sequence, persisting receipt after each step result.
   - Stop attempt pass path immediately when a required step returns non-pass verdict.
3. Drive loop verdict/retry from receipts, not ad-hoc strings.
   - Derive attempt pass only from required-step pass set.
   - On failure, construct maker retry feedback from failed step receipt (`step_id`, `skill`, `verdict`, `summary`).
4. Apply iteration-budget escalation using structured failure context.
   - If retries exhausted, transition loop to halted/stuck and retain last failed receipt in history for triage.
5. Expand focused tests first, then implementation.
   - Add/adjust orchestrator tests for ordered sequencing, pass gating, retry payload shape, and budget escalation retention.

Likely files
- `server/lib/algedonia/task_loop_orchestrator.ex`
- `server/lib/algedonia/loops/loop.ex` (only if receipt/checker metadata shape needs schema normalization)
- `server/test/algedonia/task_loop_orchestrator_test.exs`
- `server/test/algedonia/loops_test.exs` (only if persistence helpers change)

Key risks / decisions
- Receipt schema drift risk: keep a minimal canonical receipt shape and consume it consistently across pass/fail/escalation paths.
- Scope creep risk into runtime executors: keep execution transport opaque here; orchestrator should consume structured step outcomes only.
- Backward-compatibility risk for existing single-step behavior: preserve single-step as degenerate case of ordered pipeline.

Hard dependencies
- ALGE-002 and ALGE-002A must provide validated checker step definitions before loop run starts.

Proposed ticket split
- None. Current ticket remains one primary capability outcome (ordered checker orchestration + receipt-driven gating/escalation) and is verifier-ready.
