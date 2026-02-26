# cmux vs Algedonia — Comparison & Stealable Ideas

## What cmux Is

cmux is a **native macOS terminal multiplexer** (Swift/AppKit, built on Ghostty's GPU renderer) designed specifically for running parallel AI coding agents. It is not an agent framework — it's the UI layer that wraps agent processes and adds:

- Vertical sidebar tabs with rich metadata (git branch, PR status, listening ports, CWD)
- Notification rings when agents need attention (blue ring on pane, badge on tab)
- In-app browser with a full Playwright-style automation API
- Scriptable socket API (v1 line-based + v2 JSON-RPC) for programmatic control
- Session persistence with scrollback restore
- Port scanning (batched, coalesced across all panels)
- Shell integration that reports CWD, git state, PR status to the sidebar

## Architectural Contrast

| Dimension | cmux | Algedonia |
|-----------|------|-----------|
| **Role** | Terminal UI that wraps agents | Server that orchestrates agents |
| **Agents** | Unmodified Claude Code / Codex / etc. | Claude Code via daemon adapter + PTY |
| **Control** | Socket commands (post-hoc, observational) | Channel commands (pre-emptive, orchestrated) |
| **Verification** | None — human eyeballs | Maker-checker loops with structured verdicts |
| **Parallelism** | Visual (multiple panes/tabs) | Structural (DAG with file-level locking) |
| **State** | Terminal scrollback + session snapshots | PostgreSQL (tickets → DAGs → loops) |
| **Agent awareness** | Agents don't know they're in cmux | Agents are dispatched with role-specific prompts |

cmux is **below the agent** — it wraps processes and observes their output. Algedonia is **above the agent** — it decomposes work and dispatches it. They're complementary layers, not competitors.

---

## Ideas Worth Stealing

### 1. Shell Integration / Socket Telemetry Protocol (HIGH VALUE)

**What cmux does:** Shell integration scripts (`cmux-zsh-integration.zsh`) hook into `precmd`/`preexec` and fire lightweight socket messages reporting:

- **CWD** (`report_pwd`) — on every directory change
- **Git branch + dirty state** (`report_git_branch`) — every 3s or on HEAD file mtime change
- **PR status** (`report_pr`) — every 60s via `gh pr view`
- **Listening ports** (`ports_kick` → batched `ps + lsof`) — on command completion or every 10s
- **TTY name** (`report_tty`) — once per session

All of these fire async (background `&!`) to avoid blocking the prompt, with throttling, dedup, stale-job killing, and HEAD-mtime-based git change detection (no polling `git status` every prompt).

**What Algedonia should steal:** The daemon already streams terminal output to the server. But the server doesn't understand *what the agent is doing* — it just sees raw bytes. Adding a shell integration layer (or parsing the PTY output for OSC sequences) would give the server:

```
loop_id → {
  cwd: "/home/user/project/src",
  git_branch: "feature/auth",
  git_dirty: true,
  listening_ports: [3000, 5432],
  pr: { number: 42, state: "open", url: "..." },
}
```

This is directly useful for the LiveView UI — showing what each loop's agent is actually working on, not just "running_maker" status. The sidebar tab design from cmux maps cleanly to Algedonia's loop list.

**Implementation:** Either:
- (a) Inject cmux-style shell integration into the daemon's spawned shells, reporting via a per-loop socket/pipe back to the daemon, which relays to the server
- (b) Parse OSC sequences from PTY output (Ghostty/cmux's notification model uses `OSC 777;notify;title;body`)

### 2. Agent Hook Injection via CLI Wrapper (HIGH VALUE)

**What cmux does:** `Resources/bin/claude` is a wrapper script that:
1. Intercepts `claude` invocations inside cmux terminals
2. Injects `--settings` with Claude Code hooks for `SessionStart`, `Stop`, `Notification`
3. Injects a `--session-id` (UUID) for session tracking
4. Passes through to the real `claude` binary

The hooks fire `cmux claude-hook <event>` which sends socket commands back to cmux (notifications, status updates, etc.).

**What Algedonia should steal:** The daemon's Claude Code adapter currently passes `-p` (print mode) with the task. It should also inject hooks:

```bash
# Hook injection via adapter config
claude --session-id $LOOP_ID --settings '{
  "hooks": {
    "Notification": [{"matcher":"","hooks":[{
      "type":"command",
      "command":"algedonia-hook notification --loop-id=$LOOP_ID"
    }]}],
    "Stop": [{"matcher":"","hooks":[{
      "type":"command",
      "command":"algedonia-hook stop --loop-id=$LOOP_ID"
    }]}]
  }
}' -p "your task..."
```

This gives the daemon structured events from Claude Code (agent needs input, agent stopped, agent hit permission prompt) rather than trying to parse PTY output. The `algedonia-hook` binary would send events over the daemon's Phoenix channel back to the server.

### 3. Notification Model — Agent Needs Attention (HIGH VALUE)

**What cmux does:** Notifications are created when an agent outputs an OSC 777 sequence or when the Claude Code `Notification` hook fires. Each notification has:

```swift
struct TerminalNotification {
    let tabId: UUID        // workspace
    let surfaceId: UUID?   // pane within workspace
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool
}
```

Auto-read when the user focuses the relevant pane. Auto-reorder to move notifying workspaces to the top. Dock badge with unread count.

**What Algedonia should steal:** Add a notification/escalation concept per loop:

```elixir
# In the Loop schema
field :needs_attention, :boolean, default: false
field :attention_reason, :string  # "permission_prompt", "needs_clarification", "test_failure"
field :attention_since, :utc_datetime_usec
```

When the daemon detects (via hook or PTY parsing) that an agent needs human input, it fires `needs_attention` to the server. The LiveView UI:
- Highlights the loop in the DAG view
- Shows a toast / browser notification
- Auto-focuses on the loop that needs attention
- Tracks time-waiting-for-human as a metric

This is the core UX problem cmux solves (knowing which of N parallel agents needs you), applied to Algedonia's orchestrated model.

### 4. Batched Port Scanning Pattern (MEDIUM VALUE)

**What cmux does:** Per-panel port scanning is expensive (ps + lsof per shell). cmux's `PortScanner` uses a kick → coalesce → burst pattern:

1. Shell sends `ports_kick` (lightweight, just "I exist")
2. PortScanner coalesces kicks across all panels (200ms window)
3. Fires a single batched `ps -t <all_ttys> + lsof -p <all_pids>` covering every panel
4. Burst schedule: 6 scans at [0.5s, 1.5s, 3s, 5s, 7.5s, 10s] offsets

**What Algedonia should steal:** When loops run dev servers (next dev, mix phx.server, etc.), the server needs to know which ports are open for browser preview / health checks. Rather than polling per-loop, use a batched scanner in the daemon that covers all active loops' worktrees simultaneously. Useful for the "Maker starts dev server, Checker can reach it" scenario.

### 5. Session Persistence with Scrollback Restore (LOW-MEDIUM VALUE)

**What cmux does:** Autosaves every 8s: window frames, workspace order, split topology, and truncated scrollback (4000 lines / 400KB per terminal). ANSI-safe truncation (doesn't break mid-escape-sequence). On restart, restores the entire layout with scrollback content.

**What Algedonia should steal:** The daemon already streams output to the server. But if the daemon restarts (crash, upgrade), all running loops lose their context. Adding a scrollback snapshot (stored server-side per loop attempt) would let the daemon resume monitoring a loop that's still running in its PTY after daemon restart.

### 6. v2 Socket API Design (LOW VALUE, but good reference)

cmux's v2 API is a well-designed JSON-RPC-over-Unix-socket protocol with:

- Handle-based resource references (short `workspace:3`, `surface:7` instead of UUIDs)
- `system.capabilities` for feature discovery
- `system.identify` for caller identification
- Focus policy: socket commands don't steal macOS app focus unless explicitly focus-intent
- ~150 methods organized by domain (window, workspace, pane, surface, browser, notification, etc.)

**What Algedonia should steal:** The v2 handle-ref design is worth studying for the daemon's channel protocol. Currently Algedonia uses UUIDs everywhere. Short refs (`loop:3`, `dag:1`) would be more ergonomic for debugging and logging.

---

## Ideas NOT Worth Stealing

| cmux Feature | Why Skip |
|-------------|----------|
| **In-app browser** | Algedonia's agents don't need visual browser automation — they work through CLI tools |
| **Sidebar UI design** | cmux is a macOS app; Algedonia is a web app (Phoenix LiveView). Different UI paradigms |
| **Ghostty integration** | GPU-rendered terminal is irrelevant for Algedonia's PTY-streamed model |
| **Dock badge / menu bar** | Web app has its own notification model |
| **Drag-and-drop tabs** | Different UI paradigm |
| **Skills system** | cmux skills are just markdown docs for agent context; Algedonia has `.algedonia/prompts/` |

---

## Priority Ranking

| # | Idea | Effort | Impact | When |
|---|------|--------|--------|------|
| 1 | Agent hook injection (Claude Code hooks) | Low | High | Slice 7 (Agent Adapter) |
| 2 | Notification / needs-attention model | Medium | High | Slice 9-10 (Maker/Checker loops) |
| 3 | Shell integration telemetry | Medium | High | Slice 7 (Agent Adapter) |
| 4 | Batched port scanning | Low | Medium | Slice 9 (Maker loop needs dev server) |
| 5 | Scrollback persistence for daemon restart | Medium | Medium | Slice 15 (Reliability) |
| 6 | Handle-ref protocol design | Low | Low | Protocol design phase |

---

## Cross-Reference with Hermes Analysis

| Concern | Hermes Solution | cmux Solution | Algedonia Should... |
|---------|----------------|---------------|---------------------|
| Agent state awareness | Tool registry + in-process | Shell integration + socket telemetry | Steal cmux's external observation model |
| Agent needs human | `clarify` tool (in-band) | Notification hooks (out-of-band) | Steal cmux's hook injection + notification model |
| Parallel agent management | `delegate_task` batch (3 concurrent) | Visual tabs with notification rings | Already has DAG scheduler; add cmux-style attention signals |
| Context management | `ContextCompressor` (auto) | Session persistence (scrollback) | Steal Hermes's compression; steal cmux's persistence |
| Memory | 3-tier (session/persistent/search) | None (stateless terminal) | Steal Hermes's memory model |
