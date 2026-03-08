---
name: algedonia-zen
description: "Engineering principles for durable fixes: eliminate root causes, prefer simplification, and apply abstractions only when they reduce complexity."
---

# Algedonia Zen

Use these principles to guide implementation and review decisions.

## Principles

1. Avoid bandaid solutions.
   - Find root causes.
   - Fix at the source so the bug class does not recur.

2. Deletion is leverage.
   - A line removed is often more valuable than a line added.
   - Prefer simpler control flow, fewer branches, and fewer moving parts.

3. Abstractions are tools, not defaults.
   - Introduce abstractions when they clearly simplify behavior or remove duplication.
   - If abstraction adds indirection without clear payoff, follow YAGNI.

## Decision Heuristics

- Before adding code, ask: can we remove or restructure existing code instead?
- Before introducing an abstraction, ask: does it reduce total complexity now?
- Prefer local clarity over framework cleverness.
- Validate fixes against regression risk, not just happy path.

## Output Expectations

When proposing or shipping a fix, include:
- Root cause summary.
- Why the chosen solution is minimal and durable.
- What code was removed/simplified.
- Why any new abstraction is justified (or why none was added).
