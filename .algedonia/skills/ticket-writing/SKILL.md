---
name: ticket-writing
description:
  Write and refine implementation tickets into loop-friendly, verifier-first
  units for any software project. Use when asked to decompose large
  initiatives, rewrite ticket plans, or review ticket quality for clarity,
  testability, and minimal coupling.
---

# Ticket Writing

## Goals

- Decompose work into verifier-first units that embody maker-checker loops.
- Preserve project intent and documented architecture constraints.
- Maximize independent dispatchability and minimize unnecessary coupling.

## Required Context

1. Read the project's product/design docs and architecture docs before writing or reviewing tickets.
2. Read the current ticket proposal or decomposition document.
3. Treat current architecture constraints as baseline unless the ticket explicitly changes them.

## Decomposition Workflow

1. Define one capability delta in loop behavior, not a subsystem rewrite.
2. Write acceptance criteria before implementation tasks.
3. Define checker evidence for the ticket before decomposition is finalized.
4. Choose the smallest meaningful boundary or vertical slice that can deliver one falsifiable outcome within one agent session budget.
   - Prefer single-boundary tickets by default.
   - Use cross-boundary tickets when they are the smallest meaningful unit (for example contract or end-to-end behavior changes).
   - Avoid splitting purely for size if it creates handoff overhead without improving verifiability.
5. Select the primary owner boundary:
   - `backend/service` only
   - `runtime/worker` only
   - `ui/client` only
   - `data/schema` only
   - `docs/process` only
   - `cross-boundary` only when contract changes require it
6. Add failure semantics: pass, fail, taper/escalate, or clarify behavior when relevant.
7. Add dependencies only when independent verification is impossible.
8. Sequence tickets by hard blockers, not by architectural preference.

## Ticket Quality Gate

Reject or split a ticket if any check fails.

- Exactly one primary capability outcome.
- Acceptance criteria are observable and testable.
- Checker proof is explicit (what command/skill/verdict proves done).
- Boundary choice is explicit and justified for the outcome.
- No "cleanup later" quality debt.
- No hidden cross-system coupling in a supposedly local ticket.
- Scope fits one agent session/loop budget (context, validation, retries) without compaction thrash.

## Cross-Boundary Rule

Do not force every ticket to span all layers.

Use cross-boundary tickets only for:

- Protocol contract additions or payload changes.
- New persisted state that must be surfaced end-to-end.
- User flows that cannot be verified without plumbing across boundaries.

Otherwise keep tickets single-boundary and independently shippable.

## Sizing Tradeoff

Do not optimize for the smallest possible ticket. Optimize for the smallest meaningful, falsifiable delta that can be completed in one focused agent session.

Use this sizing check:

1. One primary outcome.
2. Clear pass/fail evidence.
3. Fits one session budget.
4. Not so small that it creates artificial handoffs or weak progress artifacts.

## Anti-Patterns

- Phase-only tickets such as "Refactor loop engine" with no verifier outcome.
- Component-led breakdown instead of loop-outcome-led breakdown.
- Tickets missing checker config or proof.
- Tickets that silently violate documented architecture constraints.
- Tickets that bundle unrelated outcomes "to save time".

## Ticket Template

Use this template for each ticket.

```md
### <ID> — <Outcome-Focused Title>
Priority: <P0|P1|P2> | Size: <S|M|L> | Owner boundary: <backend|runtime|ui|data|docs|cross-boundary>
Depends on: <ticket ids or none>

Outcome
- <single capability delta in loop behavior>

Acceptance Criteria
1. <observable behavior>
2. <observable behavior>

Checker Proof
- Base pipeline: <compile/test/lint or repo default>
- Ticket-specific checks:
  1. skill: <name>
     params: <if any>
     pass signal: <what passes>

Implementation Notes
- <only essential constraints; avoid prescribing unnecessary internals>

Failure / Escalation Semantics
- <what happens on repeated failure/taper/max attempts if relevant>

Out of Scope
- <explicit non-goals>
```

## Review Mode

When asked to review an existing ticket breakdown:

1. List findings first, ordered by severity.
2. Cite concrete ticket lines/sections causing drift.
3. Call out missing checker proof and oversized coupling first.
4. Propose specific splits or rewrites, not generic feedback.
