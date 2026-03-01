# Desloppify vs Algedonia — Comparison & Stealable Ideas

## Architectural Contrast

| Dimension | Desloppify | Algedonia |
|-----------|-----------|-----------|
| **Model** | Single-user CLI tool, offline scoring harness | Server-orchestrated multi-agent with human oversight |
| **What it does** | Measures and improves codebase quality post-hoc | Produces quality code via verified agent loops |
| **When quality is assessed** | After code exists (scan → score → fix loop) | During code production (maker writes, checker verifies) |
| **Scoring** | Dual-pool: 40% mechanical + 60% subjective, computed deterministically | 5-layer verification pyramid, checker agent evaluates per rubric |
| **Anti-gaming** | Three score modes (lenient/strict/verified_strict), blind LLM review, target-match detection | Checker independence (no maker history), fresh session, rubric-driven |
| **Work decomposition** | Auto-clustering of findings by detector/file/dimension | DAG decomposition via maker-checker loop |
| **Prioritization** | Tier-based ranking with work queue, narrative engine for "what next" | Scheduler with file-level locking, DAG dependency ordering |
| **State** | JSON flat file (`.desloppify/state.json`) | PostgreSQL (tickets → DAGs → loops → attempts) |
| **Execution** | Dispatches to Codex/Claude for review batches, applies fixes locally | Dispatches to Claude Code/Codex/Aider via PTY daemon |
| **Human role** | Runs CLI commands, reviews suggestions | Steers agents live, approves/rejects, edits rubrics |

They operate at different points in the lifecycle. Desloppify is a **quality measurement and remediation tool** — it tells you what's wrong with existing code and guides you toward fixing it. Algedonia is a **quality production system** — it produces verified code through structured agent loops. But desloppify has solved several scoring, anti-gaming, and prioritization problems that Algedonia's checker and orchestrator will face.

---

## Ideas Worth Stealing

### 1. Three-Mode Scoring for Checker Confidence (HIGH VALUE)

**The problem in Algedonia:** The checker produces per-layer scores and a verdict (pass/fail/clarify). But there's no mechanism to distinguish between "genuinely clean code" and "code that superficially satisfies the rubric." The merge gate is a single weighted threshold — it either passes or doesn't. A maker could learn to game rubric wording across attempts.

**What desloppify does:** Three scoring modes that reveal gaming:

| Mode | What it measures | Gaming resistance |
|------|-----------------|-------------------|
| **Lenient** | Best-case interpretation: only confirmed issues count, ties broken favorably | Low — this is the "how good does it look?" score |
| **Strict** | Worst-case interpretation: unreviewed files penalized, confidence dampening applied, placeholder detection | High — this is the "how confident are we that it's actually good?" score |
| **Verified strict** | Only counts files with completed blind LLM review of subjective dimensions | Highest — can't fake this without actual review |

The *gap* between lenient and strict is itself a signal. A large gap means "we think it might be good but we haven't verified it." Desloppify's target is always the strict score, never the lenient one.

Additionally, desloppify applies **confidence dampening**: if only 30% of files in a dimension have been reviewed, the subjective score for that dimension is dampened toward a pessimistic baseline. You can't get a high strict score by reviewing 3 easy files and ignoring 50 hard ones.

**How to steal it:** Add a confidence dimension to checker scores:

```elixir
# In the merge gate function
defmodule Algedonia.Loops.MergeGate do
  def evaluate(scores, rubric) do
    # Layer 1-4: Mechanical (deterministic, same as today)
    mechanical = evaluate_hard_layers(scores)

    # Layer 5 (Semantic): Split into two sub-scores
    semantic_score = scores.semantic.score       # "does the diff satisfy the rubric?"
    semantic_coverage = scores.semantic.coverage  # "what fraction of acceptance criteria were actually tested?"

    # Gap detection: if score is high but coverage is low, flag it
    confidence = semantic_score * semantic_coverage

    %{
      verdict: compute_verdict(mechanical, confidence, rubric.threshold),
      scores: scores,
      confidence: confidence,
      coverage_gap: semantic_score - confidence  # large gap = suspicious
    }
  end
end
```

The key insight: **scoring the score itself**. When the checker says "pass," how much of the rubric did it actually verify vs. assume? Desloppify's strict/lenient gap is exactly this — it measures *verification coverage*, not just *verification outcome*.

For Algedonia's checker agent, this means explicitly prompting the checker to report:
- Which acceptance criteria it verified (with evidence)
- Which acceptance criteria it could not verify (and why)
- What fraction of changed files it actually inspected

Then the merge gate factors coverage into the threshold. A checker that says "pass" but only verified 2 of 8 acceptance criteria gets a lower confidence than one that verified all 8.

### 2. Mechanical → Subjective Staleness Propagation (HIGH VALUE)

**The problem in Algedonia:** When a maker modifies files in loop N, and loop N+1 (which depends on N) runs its checker, the checker evaluates the diff from loop N+1. But loop N's changes may have invalidated assumptions from earlier checker passes in parallel loops. There's no mechanism to flag "this previously-verified code changed underneath you."

**What desloppify does:** `merge.py` has `_mark_stale_on_mechanical_change()`. When a mechanical detector finds new issues in a file, desloppify automatically marks any subjective review findings for that file as stale. The mapping is explicit:

```python
_DETECTOR_SUBJECTIVE_DIMENSIONS = {
    "unused-exports": ["api_surface_design"],
    "circular-deps": ["dependency_architecture"],
    "dead-code": ["api_surface_design"],
    ...
}
```

When `unused-exports` finds something new in `auth.ts`, the `api_surface_design` review for `auth.ts` is marked stale and must be re-reviewed. The strict score drops because stale reviews count as unverified.

**How to steal it:** When a loop passes and its changes are merged, the server should check if any files in the diff overlap with files verified by other loops' checker passes. If they do, mark those checker passes as *degraded* — not invalid, but flagged for re-verification if the downstream loop's checker cares about those files.

```elixir
defmodule Algedonia.Loops.StalenessTracker do
  @doc """
  After loop N passes, check if its changed files overlap with
  files verified by other loops' checker passes.
  """
  def propagate_staleness(passed_loop, changed_files) do
    # Find all loops whose checker verified any of these files
    affected_loops = Loops.with_verified_files(changed_files)

    for loop <- affected_loops, loop.id != passed_loop.id do
      # Don't invalidate — just flag for the next checker run
      Loops.add_staleness_flag(loop, %{
        source_loop: passed_loop.id,
        stale_files: MapSet.intersection(loop.verified_files, changed_files),
        reason: :upstream_change
      })
    end
  end
end
```

This is especially important for Algedonia because loops run in parallel. Loop A and Loop B might both touch `src/auth/`. A passes first and merges. B's checker then runs on code that includes A's changes — but B's checker doesn't know about A's changes unless explicitly told. The staleness flag gives the checker that signal.

### 3. Tiered Work Prioritization with Confidence Ordering (MEDIUM-HIGH VALUE)

**The problem in Algedonia:** The scheduler picks loops based on DAG dependencies and daemon capacity. But when multiple loops are ready simultaneously, there's no intelligence about which one to schedule first. The current logic: ticket creator's daemon if available, otherwise least-loaded daemon. No consideration of which loop would be most impactful.

**What desloppify does:** `ranking.py` implements a multi-factor sort:

```python
def item_sort_key(item):
    return (
        tier,              # T1 (critical) before T2 (important) before T3 before T4
        confidence_rank,   # "high confidence" issues first (more likely to be real)
        -review_weight,    # heavier review findings first
        -count,            # bulk issues first (more bang for buck)
        id,                # stable tiebreaker
    )
```

Additionally, **auto-clusters** sort before individual findings, and within clusters, `auto_fix` actions sort before `reorganize` before `refactor` before `manual_fix`. The logic: do the easy wins first because they unlock score improvements that change the priority of remaining work.

**How to steal it:** When multiple loops are ready, score them:

```elixir
defmodule Algedonia.Scheduler.Priority do
  def score(loop) do
    {
      # Mechanical-first: loops with hard gates (typecheck, lint) are easier to verify
      if has_hard_gates?(loop.rubric), do: 0, else: 1,

      # Smaller scope first: fewer files = faster loop = faster feedback
      -length(loop.estimated_files),

      # Dependency fan-out: loops that unblock the most downstream work go first
      -count_downstream(loop),

      # Stable tiebreaker
      loop.inserted_at
    }
  end
end
```

The desloppify insight that transfers directly: **do the mechanically-verifiable, high-confidence work first.** In Algedonia terms, a loop with a rubric full of hard gates (typecheck passes, tests pass, lint clean) should run before a loop whose rubric is mostly semantic ("code is well-structured"). The mechanical loop is cheaper to verify and more likely to pass on the first attempt.

### 4. Anti-Gaming Patterns for Checker Independence (MEDIUM VALUE)

**The problem in Algedonia:** The SDD says "the checker does NOT receive the maker's conversation history or reasoning." This is good. But there are subtler gaming vectors that desloppify has identified and addressed.

**What desloppify does for anti-gaming:**

1. **Blind review**: The LLM reviewer doesn't see previous scores or the project's target score. It evaluates each dimension independently. If it knew the target was 95 and the current score was 93, it might unconsciously inflate scores to "help."

2. **Target-match detection**: If a score lands exactly on the configured target, desloppify flags it as suspicious. Real improvement almost never lands exactly on target.

3. **Placeholder detection**: If a subjective dimension has a score of exactly 0% or 100%, it's treated as a placeholder, not a real assessment. Strict scoring penalizes these.

4. **Holistic integrity checking**: `subjective_review_open_breakdown()` separately tracks whether *holistic* review signals (project-wide patterns, cross-file consistency) have been assessed. File-level reviews alone aren't sufficient — you also need "does the codebase *as a whole* make sense?"

**How to steal it for Algedonia's checker:**

- **Blind checker context**: The checker already doesn't get maker history. Go further: don't tell the checker what attempt number this is. Don't tell it how many attempts are left. Don't include previous checker scores. Each checker evaluation should be independent and blind to its own history. If the checker knows "this is attempt 4 of 5," it might lower its standards to avoid escalation.

- **Score consistency detection**: Track checker scores across attempts within a loop. If the checker gives wildly different scores for similar diffs, flag it. If the checker always gives the same score regardless of diff quality, flag it. Both patterns suggest the checker isn't actually evaluating carefully.

- **Cross-loop integrity**: After a batch of loops complete for a ticket, run a lightweight "holistic check" — does the combined diff across all loops make sense as a coherent change? Individual loops might each pass their narrow rubric but produce an incoherent whole. This maps to desloppify's holistic subjective review.

### 5. Narrative Engine for Human Communication (MEDIUM VALUE)

**The problem in Algedonia:** The Monitor view shows escalation queue, circuit breaker status, and running loops. But there's no intelligence about *overall progress* or *what's going wrong systemically*. A human looking at the monitor sees individual loop statuses but can't quickly answer "how is this ticket going?" or "what should I pay attention to?"

**What desloppify does:** The narrative engine (`intelligence/narrative/`) computes:

- **Phase detection**: Maps overall state to a human phase: "initial scan," "early fixes," "deep refactoring," "polish," "target reached"
- **Milestone tracking**: "You've fixed 40 of 60 findings. Last 5 minutes gained 3.2 points."
- **Action recommendations**: Computes the highest-impact next action using fixer leverage estimation. "Running `fix unused-vars` would resolve ~18 findings and gain ~4.5 points."
- **Strategy computation**: Groups related fixes by file overlap (using union-find), suggests parallel execution, estimates total remaining effort.

The narrative is written to `query.json` after every state-changing command — a structured summary that an LLM or human can consume.

**How to steal it:** Add a `TicketNarrative` module that computes progress summaries:

```elixir
defmodule Algedonia.Tickets.Narrative do
  def compute(ticket) do
    dag = ticket.dag
    loops = dag.loops

    %{
      phase: detect_phase(loops),           # :decomposing | :early_execution | :mostly_done | :stuck | :complete
      progress: "#{passed_count}/#{total_count} loops passed",
      blockers: identify_blockers(loops),    # loops that are stuck/escalated and blocking downstream
      velocity: compute_velocity(loops),     # loops/hour over last N hours
      risk: assess_risk(loops),              # :on_track | :slowing | :stuck | :circuit_broken
      suggestion: next_action(loops),        # "Review escalated loop 'auth middleware' — it's blocking 3 downstream loops"
    }
  end
end
```

This is particularly valuable for the Monitor view. Instead of showing a flat list of running/escalated loops, show a ticket-level narrative: "Ticket #42: 7/12 loops passed, 1 escalated (blocking 3 downstream), velocity 2.1 loops/hour, ETA ~2 hours."

### 6. Dual-Pool Scoring (Mechanical + Subjective Split) (LOW-MEDIUM VALUE)

**The problem in Algedonia:** The checker's verification pyramid has 5 layers, but they're weighted uniformly (or by rubric configuration). There's no structural separation between "things a machine can verify deterministically" and "things that require judgment."

**What desloppify does:** Explicit 40/60 split:

- **Mechanical pool (40%)**: Unused vars, dead code, circular deps, file length — all deterministic detectors. No LLM involved. Score is computed from detection results.
- **Subjective pool (60%)**: Error handling quality, naming conventions, API surface design, dependency architecture — all assessed by blind LLM review against dimension-specific rubrics.

Each pool has its own dimension weights. The final score is the weighted average. This means a codebase can't score high by only being mechanically clean (max 40%) or only having good architecture (max 60%). You need both.

**How to steal it:** Formalize the pyramid layers into pools:

```
Mechanical pool (hard-gated, deterministic):
  Layer 1 — Static: lint, typecheck, format (MUST PASS — hard gate)
  Layer 2 — Deterministic: existing tests pass (MUST PASS — hard gate)

Judgment pool (weighted, LLM-evaluated):
  Layer 3 — Generative: does the agent write new tests for new code?
  Layer 4 — Runtime: performance, resource usage
  Layer 5 — Semantic: does the code match intent?
```

The merge gate already has hard gates, so the mechanical/judgment split is partially implemented. The steal here is making it explicit in the scoring model and tracking the two pools independently. Benefits:
- Dashboard can show "mechanical: 100%, judgment: 72%" — tells you immediately that the code is clean but the semantic review was lukewarm.
- Trends over time: if the judgment score keeps declining across loops, the rubrics may need tuning.
- Different thresholds per pool: mechanical must be 100% (hard gate), judgment might be 70% (soft gate).

---

## Ideas NOT Worth Stealing

| Desloppify Feature | Why Skip |
|-------------------|----------|
| **Flat-file JSON state** | Algedonia already has PostgreSQL. Flat-file state is a limitation of desloppify's single-user CLI design, not a feature. |
| **CLI-driven workflow** | Algedonia's LiveView UI with real-time collaboration is strictly better. `desloppify next` guidance is cool but Algedonia's scheduler automates this entirely. |
| **Auto-fix system** | Desloppify's fixers (unused-vars, dead-code, unused-imports) are language-specific AST transforms. Algedonia's maker agent already handles these — it doesn't need a separate fixer infrastructure. |
| **Detector plugin system** | 25+ detectors with per-language specialization. Algedonia doesn't need this because the checker IS the detector — it's an LLM that evaluates against a rubric. Adding static detectors would duplicate what the checker already does. |
| **Score quartet display** | Four scores (overall/objective/strict/verified) is UI complexity that serves desloppify's anti-gaming design. Algedonia should steal the *concept* (confidence-adjusted scoring) but not the four-score display. The checker heatmap is a better visualization. |
| **Cascading import cleanup** | After fixing dead code, desloppify automatically removes orphaned imports. This is a nice fixer-chain feature, but Algedonia's maker agent handles this naturally — it understands the full file context. |
| **Batch review with external runners** | Desloppify dispatches to Codex/Claude for batch review. Algedonia's daemon architecture already does this better with real-time streaming, pause/steer, and worktree isolation. |
| **Finding reopen tracking** | `reopen_count` tracks how many times a finding was fixed then reappeared. Useful for a scan-based tool where regressions happen between scans. Algedonia's maker-checker loop prevents regressions by verifying before merge. |

---

## Priority Ranking

| # | Idea | Effort | Impact | When |
|---|------|--------|--------|------|
| 1 | Three-mode scoring (confidence-adjusted checker verdicts) | Medium | High | Slice 10 (Checker Agent and Merge Gate) |
| 2 | Mechanical → subjective staleness propagation | Medium | High | Slice 10-11 (Checker + DAG orchestration) |
| 3 | Tiered prioritization for ready loops | Low | Medium-High | Slice 11 (Parallel Execution) |
| 4 | Anti-gaming patterns (blind checker, score consistency) | Low | Medium | Slice 10 (Checker) |
| 5 | Narrative engine for ticket progress | Medium | Medium | Slice 16 (Manual Gates & Rubric Editing) or later |
| 6 | Dual-pool scoring (mechanical vs judgment) | Low | Low-Medium | Slice 10 (Checker) |

### Cross-reference with hermes-agent stealable ideas

Some ideas compound across both analyses:

| Combined Insight | From Hermes | From Desloppify |
|-----------------|-------------|-----------------|
| **Split mechanical and judgment checks** | Programmatic checker layers (#4) | Dual-pool scoring (#6) |
| **Track verification coverage** | — | Three-mode scoring (#1) |
| **Smart scheduling** | — | Tiered prioritization (#3) |
| **Knowledge compounding** | Three-tier memory (#2) | Staleness propagation (#2) |
| **Context for humans** | — | Narrative engine (#5) |
| **Cheap auxiliary model** | Auxiliary model for side tasks (#6) | — (desloppify uses LLMs for review only) |

The strongest combined recommendation: **build the checker as a two-phase pipeline** — programmatic verification (hermes insight) with confidence-adjusted scoring (desloppify insight). Phase 1 runs lint/typecheck/tests deterministically. Phase 2 runs the LLM semantic checker, which receives Phase 1 results. The merge gate factors in both the LLM's verdict and the coverage of what the LLM actually verified (not just what it claimed to verify).
