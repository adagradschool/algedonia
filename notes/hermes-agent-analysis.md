# Hermes Agent — Deep Dive Analysis

Analysis of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), focusing on harness setup, memory system, and task decomposition/delegation.

---

## 1. Harness Setup (Agent Architecture)

### Core Loop (`run_agent.py` → `AIAgent`)

The harness is a standard OpenAI-spec tool-calling loop, but heavily instrumented with context management, prompt caching, and multi-backend execution environments.

**Initialization chain:**

```
cli.py (HermesCLI)
  → load_cli_config()         # YAML from ~/.hermes/config.yaml
  → AIAgent.__init__()        # Core agent setup
    → OpenAI(base_url=...)    # OpenRouter by default, any OpenAI-compatible endpoint
    → get_tool_definitions()  # Toolset resolution → registry → filtered tool schemas
    → ContextCompressor()     # Auto-compress when approaching context limit
    → TodoStore()             # Per-session in-memory task list
    → MemoryStore.load_from_disk()  # Frozen snapshot for system prompt
```

**The agent loop itself (`_run_agent_loop`):**

```
1. Build system prompt (identity + platform hints + skills index + context files + memory snapshot)
2. Add user message to conversation
3. Call LLM with tools= parameter
4. If tool_calls in response:
   - Intercept agent-level tools (todo, memory, session_search, delegate_task)
   - Dispatch other tools through handle_function_call() → registry.dispatch()
   - Add tool results to conversation
   - Check for context compression (threshold_percent of model context length)
   - Go to step 3
5. If text response: return to user
```

Each tool call goes: `LLM response → AIAgent loop → model_tools.handle_function_call() → registry.dispatch() → specific tool handler`.

### Tool Registry Pattern

The registry (`tools/registry.py`) is a singleton that each tool file self-registers into at import time:

```python
# In tools/memory_tool.py (example):
from tools.registry import registry

registry.register(
    name="memory",
    toolset="memory",
    schema=MEMORY_SCHEMA,          # OpenAI function-calling schema
    handler=lambda args, **kw: memory_tool(...),
    check_fn=check_memory_requirements,  # Dynamic availability gating
    requires_env=["SOME_API_KEY"],       # Required env vars
)
```

Discovery happens in `model_tools._discover_tools()` — just imports each tool module, which triggers the `registry.register()` calls. No central mapping table needed.

**Toolset system (`toolsets.py`):** Named groups of tools that can be composed:

- Leaf toolsets: `web` = ["web_search", "web_extract"], `terminal` = ["terminal", "process"]
- Composite toolsets: `debugging` includes `web` + `file` + adds terminal/process
- Platform toolsets: `hermes-cli`, `hermes-telegram`, `hermes-discord` all share `_HERMES_CORE_TOOLS` (31 tools)
- Special alias: `all` / `*` resolves every tool across every toolset

### System Prompt Assembly (`agent/prompt_builder.py`)

The system prompt is assembled from multiple sources, in order:

1. **Agent identity** — fixed "You are Hermes Agent..." string
2. **Platform hints** — e.g. "You are on WhatsApp. Do not use markdown."
3. **Memory guidance** — "Proactively save important things using the memory tool"
4. **Session search guidance** — "Use session_search to recall past conversations"
5. **Skills guidance** — "After complex tasks, save the approach as a skill"
6. **Skills index** — auto-scanned from `~/.hermes/skills/`, compact category→skill listing
7. **Context files** — AGENTS.md (recursive), .cursorrules, SOUL.md (personality)
8. **Memory snapshot** — frozen MEMORY.md + USER.md content (never mutated mid-session)
9. **Ephemeral system prompt** — optional override (not saved to trajectories)

The frozen memory snapshot is a key design choice: it preserves the Anthropic prompt cache for the entire session. Mid-session memory writes update files on disk immediately but don't change the system prompt until the next session start.

### Terminal Execution Backends (`tools/environments/`)

The terminal tool (`tools/terminal_tool.py`) supports 5 execution backends, all sharing the same tool interface:

| Backend | Isolation | Use Case |
|---------|-----------|----------|
| `local` | None (host machine) | CLI development |
| `docker` | Container | Isolated local execution |
| `ssh` | Remote machine | Distributed execution |
| `singularity` | Container (HPC) | Cluster workloads |
| `modal` | Cloud sandbox | Production RL training |

Each backend implements `BaseEnvironment` ABC. The backend is selected via `TERMINAL_ENV` environment variable or `terminal.backend` in config.yaml. All backends are per-`task_id`, meaning concurrent agents get isolated sessions.

### Context Compression (`agent/context_compressor.py`)

When conversation approaches 85% of the model's context limit:

1. Protect first 3 messages (system prompt + initial exchange)
2. Protect last 4 messages (recent context)
3. Summarize everything in between using a cheap/fast auxiliary model (Gemini Flash)
4. Replace the middle with a `[CONTEXT SUMMARY]` user message
5. If TodoStore has items, re-inject them after compression

The compressor uses actual token counts from API responses (not estimates) and tracks compression count to annotate the system prompt.

### Prompt Caching

Auto-enabled for Claude models via OpenRouter. Uses the `system_and_3` cache strategy (4 breakpoints). The frozen memory snapshot design directly supports this — keeping the system prompt stable across all turns maximizes cache hit rate (~75% input cost reduction).

### RL Training Harness (`environments/`)

The same tool-calling engine is reused for Atropos (NousResearch's RL framework) integration:

- **`HermesAgentBaseEnv`** — abstract Atropos environment that wraps the agent loop
- **`HermesAgentLoop`** — reusable multi-turn engine (same pattern as `run_agent.py` but works with any server)
- **Two-phase operation:**
  - Phase 1 (OpenAI server type): Direct `chat.completions.create()` with native tool calling — good for SFT data gen and evaluation
  - Phase 2 (VLLM ManagedServer): Client-side tool call parsing with exact token IDs + logprobs — full RL training
- **`ToolContext`** — gives reward functions unrestricted access to ALL hermes-agent tools, scoped to the rollout's task_id. Verifiers can run pytest, check files, browse websites — anything needed to score the rollout.

---

## 2. Memory System

Hermes-Agent has a **three-tier** memory architecture:

### Tier 1: In-Session Memory (TodoStore)

**File:** `tools/todo_tool.py`

In-memory task list that lives on the `AIAgent` instance (one per session). Destroyed when the session ends. Used for within-conversation planning.

- Items have `{id, content, status}` where status is `pending | in_progress | completed | cancelled`
- Two write modes: `merge=false` (replace entire list) and `merge=true` (update by ID, append new)
- After context compression, the todo list is re-injected so the agent doesn't lose its plan
- `format_for_injection()` renders it as a human-readable checklist for post-compression injection

### Tier 2: Persistent Curated Memory (MemoryStore)

**File:** `tools/memory_tool.py`

File-backed memory that persists across sessions. Two parallel stores:

| Store | File | Char Limit | Purpose |
|-------|------|------------|---------|
| `memory` | `~/.hermes/memories/MEMORY.md` | 2,200 chars | Agent's personal notes — environment facts, project conventions, tool quirks, things learned |
| `user` | `~/.hermes/memories/USER.md` | 1,375 chars | User profile — name, role, preferences, communication style, pet peeves |

**Key design decisions:**

1. **Frozen snapshot pattern:** At session start, `load_from_disk()` captures the memory state. This snapshot is injected into the system prompt and never changed mid-session. Mid-session writes go to disk immediately but don't alter the system prompt. This preserves prompt cache stability.

2. **Bounded by character count, not tokens:** Makes limits model-independent.

3. **Substring matching for replace/remove:** Instead of IDs, you provide a short unique substring of the entry you want to modify. If the substring matches multiple entries, the operation fails with an error asking for more specificity.

4. **Atomic file writes:** Uses `tempfile.mkstemp()` + `os.replace()` (atomic rename) to prevent partial reads from concurrent access.

5. **Proactive saving is baked into the schema description:** The tool's description tells the model *when* to save (user preferences, environment discoveries, corrections, diary entries) and *what to skip* (trivial/obvious info, easily re-discovered facts).

6. **Configurable nudge interval:** Every N turns (default 10), the agent gets a nudge to consider saving important things to memory. This is configured via `memory.nudge_interval` in config.

**Entry format:**

```
Entry one text here
§
Entry two text here
§
Entry three (can be multiline)
with more lines here
```

The `§` delimiter separates entries. The system prompt shows usage percentage: `MEMORY (your personal notes) [67% — 1,474/2,200 chars]`

### Tier 3: Session Search (Long-Term Recall)

**Files:** `hermes_state.py` (SQLite store) + `tools/session_search_tool.py`

Every conversation (CLI and messaging) is stored in a SQLite database (`~/.hermes/state.db`) with:

- `sessions` table: metadata (source, model, timestamps, token counts, parent chains)
- `messages` table: full message history with FTS5 full-text search virtual table
- WAL mode for concurrent readers + single writer

**Session search flow:**

1. FTS5 search finds matching messages ranked by relevance
2. Groups by session, takes top N unique sessions (default 3)
3. Resolves child sessions to their parent (delegation creates child sessions)
4. Loads each session's conversation, truncates to ~100k chars centered on matches
5. Sends to Gemini Flash with a focused summarization prompt
6. Returns per-session summaries with metadata (when, source, model)

The search supports FTS5 syntax: keywords, phrases (`"exact phrase"`), boolean (`python NOT java`), and prefix (`deploy*`). The tool description instructs the model to use it proactively when users reference past conversations.

### Memory Architecture Interaction

```
Session Start:
  MEMORY.md + USER.md → frozen snapshot → injected into system prompt

During Session:
  memory tool write → disk update (durable) → system prompt unchanged (cache stable)
  todo tool → in-memory only → re-injected after compression
  all messages → SQLite state.db → FTS5 indexed

Session End:
  session metadata → state.db → available for future session_search

Next Session Start:
  MEMORY.md + USER.md re-read → new frozen snapshot with any mid-session writes from last time
  session_search available for long-term recall
```

---

## 3. Task Decomposition and Delegation

### TodoStore — Planning and Tracking

The `todo` tool is the primary mechanism for task decomposition. The LLM breaks complex tasks into items:

```json
{
  "todos": [
    {"id": "1", "content": "Set up project structure", "status": "completed"},
    {"id": "2", "content": "Implement authentication", "status": "in_progress"},
    {"id": "3", "content": "Write tests", "status": "pending"},
    {"id": "4", "content": "Deploy to staging", "status": "pending"}
  ]
}
```

The schema enforces: only ONE item `in_progress` at a time. Items get marked completed immediately when done. Failed items are cancelled and replaced with revised items.

The todo list survives context compression — after the compressor summarizes middle turns, the todo state is re-injected so the agent doesn't lose track of its plan.

### delegate_task — Subagent Spawning

**File:** `tools/delegate_tool.py`

This is the core delegation mechanism. It spawns child `AIAgent` instances with:

**Isolation guarantees per child:**
- Fresh conversation (no parent history)
- Own `task_id` (isolated terminal session, file ops cache)
- Restricted toolset (configurable, with blocked tools always stripped)
- Focused system prompt built from the delegated goal + context
- `skip_context_files=True`, `skip_memory=True` — no SOUL.md, AGENTS.md, or memory injection

**Blocked tools for children:**
- `delegate_task` — no recursive delegation (depth limit = 2: parent→child→rejected)
- `clarify` — children can't interact with the user
- `memory` — no writes to shared MEMORY.md
- `send_message` — no cross-platform side effects
- `execute_code` — children should reason step-by-step, not write scripts

**Two modes:**

1. **Single task:** `delegate_task(goal="...", context="...", toolsets=[...])`
2. **Batch (parallel):** `delegate_task(tasks=[{goal, context, toolsets}, ...])` — up to 3 concurrent children

**Batch execution uses `ThreadPoolExecutor`** with `MAX_CONCURRENT_CHILDREN = 3`. Each child runs in a thread with stdout/stderr suppressed to prevent interleaved output. Results come back sorted by task_index.

**Parent context isolation:** The parent's context only sees the delegation call and the summary result — never the child's intermediate tool calls, reasoning, or tool outputs. This keeps the parent's context window clean.

**Interrupt propagation:** Parent maintains `_active_children` list. When the parent gets interrupted (e.g., user sends a new message), the interrupt propagates to all active children.

**Child system prompt structure:**
```
You are a focused subagent working on a specific delegated task.

YOUR TASK:
{goal}

CONTEXT:
{context}

Complete this task using the tools available to you.
When finished, provide a clear, concise summary of:
- What you did
- What you found or accomplished
- Any files you created or modified
- Any issues encountered
```

### execute_code — Programmatic Tool Calling (PTC)

**File:** `tools/code_execution_tool.py`

An alternative to delegation for mechanical multi-step work. The LLM writes a Python script that calls Hermes tools via RPC:

1. Parent generates a `hermes_tools.py` stub module with typed functions for 7 allowed tools
2. Parent opens a Unix domain socket and starts an RPC listener thread
3. Child process runs the LLM's script
4. When the script calls `hermes_tools.terminal("ls")`, the call travels over UDS back to the parent
5. Parent dispatches through `handle_function_call()` and returns the result
6. Only the script's stdout is returned to the LLM — intermediate tool results never enter the context window

**Allowed tools in sandbox:** `web_search`, `web_extract`, `read_file`, `write_file`, `search_files`, `patch`, `terminal`

**Resource limits:** 5-minute timeout, max 50 tool calls, 50KB stdout cap, 10KB stderr cap.

The schema description makes the distinction clear:
- **delegate_task**: For reasoning-heavy subtasks (debugging, code review, research synthesis)
- **execute_code**: For mechanical multi-step work with no reasoning needed (rename files, run tests, batch operations)
- **Direct tool call**: For single operations that don't need either

### Mixture-of-Agents (MoA)

**File:** `tools/mixture_of_agents_tool.py`

For extremely difficult problems, the `mixture_of_agents` tool runs the query through multiple frontier models in parallel, then aggregates:

1. **Reference models** (Claude Opus, Gemini Pro, GPT-4, DeepSeek) generate diverse initial responses in parallel
2. **Aggregator model** (Claude Opus) synthesizes responses into a single high-quality output

This is exposed as a regular tool that the agent can decide to use when it recognizes a problem needs "intense reasoning."

### Clarify Tool

For tasks where the agent needs user input before proceeding, the `clarify` tool presents multiple-choice or open-ended questions. This is gated by a callback from the platform layer (CLI shows a prompt, messaging platforms show buttons). Children/subagents cannot use this — they must work with the context they're given.

---

## Key Architectural Patterns Worth Noting

### 1. Registry-based tool discovery
No central mapping table. Each tool file is self-contained: schema, handler, availability check, and registration. Adding a new tool is 2 files (tool file + toolsets.py entry).

### 2. Frozen-snapshot memory for cache stability
Memory changes go to disk immediately but don't alter the system prompt mid-session. This is specifically designed to maximize Anthropic prompt cache hit rates.

### 3. task_id isolation everywhere
Every concurrent agent (CLI, messaging, RL rollout, subagent) gets its own task_id. Terminal sessions, browser sessions, file operation caches — all scoped to this ID. Cleanup happens automatically.

### 4. Dual-path RL integration
The same tool-calling engine serves both interactive use and RL training. Phase 1 (OpenAI server) for SFT data gen/eval, Phase 2 (VLLM ManagedServer) for full RL with exact token tracking. The ToolContext gives verifier functions unrestricted tool access for reward computation.

### 5. Skills as on-demand knowledge
Skills are SKILL.md documents with YAML frontmatter, progressively disclosed: categories (~50 tokens) → list with descriptions (~3k tokens) → full content. The agent can also *create* skills via `skill_manage(action='patch')`, making it self-improving.

### 6. Context compression as a first-class concern
Automatic compression at 85% of context limit, with Gemini Flash summarization of middle turns while protecting head and tail. TodoStore state is preserved across compressions. The auxiliary model client is shared with session search summarization.
