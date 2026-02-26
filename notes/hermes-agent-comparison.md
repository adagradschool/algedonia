# Hermes-Agent vs Algedonia — Comparison & Stealable Ideas

## Architectural Contrast

| Dimension | Hermes-Agent | Algedonia |
|-----------|-------------|-----------|
| **Model** | Single-process Python agent, one user | Server-orchestrated multi-agent with human oversight |
| **Agent relationship** | IS the agent (wraps LLM + tools) | ORCHESTRATES agents (dispatches Claude Code/Codex via daemon) |
| **Execution** | In-process tool calling loop | Remote PTY execution via Phoenix Channels |
| **Decomposition** | LLM decides ad-hoc (todo tool) | First-class maker-checker loop producing a DAG |
| **Verification** | None (single agent, no checker) | Independent checker agent, 5-layer pyramid |
| **Isolation** | task_id scoped sessions | Git worktrees + file-level locking |
| **Memory** | Three-tier (session / persistent / search) | Planned (knowledge.md) but not implemented |
| **Context mgmt** | Auto-compression at 85% | Prior-attempts passed on retry, no compression |
| **State** | SQLite (sessions) + flat files (memory) | PostgreSQL (tickets → DAGs → loops → attempts) |

They solve fundamentally different problems. Hermes is a **personal AI assistant** — one user, one conversation, maximum autonomy. Algedonia is a **coding factory** — multiple agents, human gates, quality verification. But several of Hermes's internal mechanisms solve problems Algedonia will face.

---

## Ideas Worth Stealing

### 1. Context Compression for Retry Attempts (HIGH VALUE)

**The problem in Algedonia:** When a maker fails and retries, the Orchestrator sends prior attempt summaries + full detail of the most recent attempt. As attempts accumulate, this context grows linearly. The SDD says "compressed summaries of old attempts + full detail on most recent" but there's no implementation.

**What Hermes does:** `ContextCompressor` tracks actual token usage from API responses, triggers at 85% of model context limit. It protects the first 3 messages (system prompt + initial task) and last 4 (most recent work), then summarizes everything in between using Gemini Flash (~500 token target). After compression, the TodoStore is re-injected so the plan isn't lost.

**How to steal it:** Build a `ContextBuilder` module in the server that assembles the prompt for each attempt:

```elixir
defmodule Algedonia.Loops.ContextBuilder do
  @doc """
  Build agent context for attempt N of a loop.

  - Attempt 1: system prompt + task + rubric + knowledge
  - Attempt 2+: above + compressed summaries of old attempts +
    full feedback from most recent
  - If total exceeds 80% of model context: summarize oldest
    attempts via auxiliary model (Gemini Flash / Haiku)
  """
  def build(loop, attempt_number, opts \\ [])
end
```

The key insight from Hermes: **use a cheap fast model (Gemini Flash) for summarization**, not the expensive model doing the actual work. This costs almost nothing and keeps context fresh.

### 2. Three-Tier Memory / Knowledge Compounding (HIGH VALUE)

**The problem in Algedonia:** The SDD describes per-loop reflection extracting patterns into `.algedonia/knowledge.md`, included in future agent contexts. But there's no implementation and no design for how this knowledge is structured, bounded, or searched.

**What Hermes does:**

| Tier | Algedonia equivalent | Steal? |
|------|---------------------|--------|
| TodoStore (in-session plan) | Loop's own task tracking within a single agent run | Yes — inject into retries |
| MemoryStore (persistent, bounded) | `.algedonia/knowledge.md` | Yes — directly applicable |
| Session search (FTS5 over all history) | Search across past loop attempts | Yes — for the reflection/knowledge feature |

**Specific patterns to steal:**

- **Bounded char limits, not token limits.** Hermes caps MEMORY.md at 2,200 chars, USER.md at 1,375. Model-independent. For Algedonia, cap `knowledge.md` at ~4,000 chars (fits comfortably in any model's context alongside task + rubric + attempts).

- **§ delimiter format with substring matching.** Simple, greppable, no IDs needed. The reflection agent appends entries; old entries can be replaced/removed by providing a unique substring.

- **Atomic file writes via tempfile + rename.** Multiple daemons might run reflection concurrently. `os.Rename()` on Go side, or have the server own the writes.

- **FTS5 search over attempts.** Add a `loop_attempts_fts` virtual table so the reflection step can search for similar past patterns before writing to knowledge.md. Hermes's session search flow (FTS5 match → group by session → summarize with cheap model) maps cleanly to (FTS5 match → group by loop → summarize patterns).

### 3. Frozen Snapshot Pattern for Prompt Cache Stability (MEDIUM VALUE)

**The problem in Algedonia:** Each loop attempt builds its agent context (knowledge + rubric + prior attempts). If knowledge.md changes between attempts of the same loop (because a parallel loop's reflection updated it), the context changes and prompt cache misses.

**What Hermes does:** At session start, memory is read once and frozen into the system prompt. Mid-session writes go to disk immediately but don't change the prompt. Cache hit rate stays high across all turns.

**How to steal it:** When a loop starts (first attempt), snapshot knowledge.md and store it on the loop record (`knowledge_snapshot` field). All attempts of that loop use the snapshot. New loops get the latest version. This gives you cache stability within a loop while still getting knowledge updates between loops.

### 4. Programmatic Tool Calling / Code Execution (MEDIUM VALUE)

**The problem in Algedonia:** The checker needs to run tests, lint, typecheck — the 5-layer verification pyramid. Currently the checker is just another LLM agent prompted to evaluate. It would be more reliable if checks were programmatic.

**What Hermes does:** `execute_code` lets the LLM write a Python script that calls tools via Unix domain socket RPC. The parent generates typed stub functions, spawns the script, and only returns stdout. Up to 50 tool calls, 5-min timeout.

**How to steal it:** The checker doesn't need to be a pure LLM call. Split it:

```
Layer 1-4 (Static + Tests + Perf + Security): Run programmatically
  → daemon runs: lint, typecheck, test suite, security scan
  → structured results (pass/fail per layer, exit codes, output)

Layer 5 (Semantic): LLM checker agent
  → receives: diff + programmatic results + rubric
  → focuses only on semantic evaluation (does this diff match intent?)
  → much more reliable than asking LLM to also run/interpret tests
```

This is basically Hermes's split between `execute_code` (mechanical) and `delegate_task` (reasoning). The pyramid's hard gates (typecheck, security) should be programmatic, not LLM-judged.

### 5. Composable Toolset System for Role Gating (LOW-MEDIUM VALUE)

**The problem in Algedonia:** Different roles (maker, checker, decompose, reflect) should have different tool access. The maker needs terminal + file write. The checker needs terminal (read-only?) + file read. The decomposer needs nothing. Currently there's no toolset restriction per role.

**What Hermes does:** Named composable toolsets with blocked-tool lists for delegation children:

```python
DELEGATE_BLOCKED_TOOLS = frozenset([
    "delegate_task",   # no recursive delegation
    "clarify",         # no user interaction
    "memory",          # no writes to shared state
    "send_message",    # no side effects
])
```

**How to steal it:** Define role-specific adapter configs:

```yaml
roles:
  maker:
    allowed_tools: [terminal, file_write, file_read, web_search]
    blocked_commands: [rm -rf, git push]  # dangerous command gating
  checker:
    allowed_tools: [terminal, file_read]   # read-only
    blocked_commands: [git commit, file_write]
  decompose:
    allowed_tools: []                       # pure reasoning, no tools
  reflect:
    allowed_tools: [file_read]             # can read but not modify
```

This maps to Algedonia's adapter config. The `AgentAdapter.Start()` already accepts a `config map[string]string` — extend it with toolset restrictions that get injected into the agent's system prompt or CLAUDE.md.

### 6. Auxiliary Model for Side Tasks (LOW VALUE, EASY WIN)

**The problem in Algedonia:** Context compression, reflection summarization, impact analysis — these are "side tasks" that don't need the primary model. Using the main model (Claude Opus) for summarization is wasteful.

**What Hermes does:** `agent/auxiliary_client.py` provides a shared cheap/fast model client (Gemini Flash) used for:
- Context compression summaries
- Session search summarization
- Anything that needs text processing but not deep reasoning

**How to steal it:** Add a `auxiliary_model` config to Algedonia that the server uses for:
- Compressing prior attempts for retry context
- Summarizing loop output for DAG status display
- Reflection extraction (could be cheaper model)
- Impact analysis file prediction

### 7. Output Chunker with Idle Detection (ALREADY HAVE, VALIDATE)

Algedonia's `Chunker` (50ms or 4KB) and `typePromptToTUI` (idle detection with 1500ms threshold) are actually very similar to patterns in Hermes's terminal tool. The existing implementation looks solid. One thing Hermes does differently: it has a `process_registry` that tracks background processes per task_id and kills them all on cleanup. Algedonia's `LoopProcess.Done` channel serves a similar purpose but only per-loop. Consider adding a process registry if loops can spawn background processes (e.g., `npm run dev`).

---

## Ideas NOT Worth Stealing

| Hermes Feature | Why Skip |
|---------------|----------|
| **Mixture of Agents (MoA)** | Algedonia already has the maker-checker pattern which is a better version of multi-model synthesis. MoA is brute-force; maker-checker is structured. |
| **Skills system** | Algedonia's `.algedonia/prompts/` directory + knowledge.md serves the same purpose more cleanly. Skills are for a general-purpose assistant; Algedonia agents have focused roles. |
| **Session search for users** | Algedonia's UI (ticket tracker, loop inspector, attempt history) already provides structured access to past work. FTS5 search is useful for the *reflection* system, not for user-facing search. |
| **Clarify tool** | Algedonia has structured escalation + needs_clarification states. Much better than Hermes's ad-hoc clarify tool. |
| **Platform hints (WhatsApp/Discord)** | Irrelevant. Algedonia is a web app. |
| **Prompt caching via OpenRouter** | Algedonia controls its own LLM calls through the daemon. Prompt caching should be handled at the adapter level if using direct API access. |

---

## Priority Ranking

| # | Idea | Effort | Impact | When |
|---|------|--------|--------|------|
| 1 | Context compression for retries | Medium | High | Slice 9-10 (Maker/Checker) |
| 2 | Knowledge.md with bounded entries + FTS5 | Medium | High | Slice 18 (Reflection) |
| 3 | Programmatic checker layers (split pyramid) | Medium | High | Slice 10 (Checker) |
| 4 | Frozen knowledge snapshot per loop | Low | Medium | Slice 18 (Reflection) |
| 5 | Role-specific toolset gating | Low | Medium | Slice 7 (Agent Adapter) |
| 6 | Auxiliary model for side tasks | Low | Low | Any time |
