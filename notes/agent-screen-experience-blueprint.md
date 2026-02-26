# Task Completion Spec (Terminal-First, Minimal Scope)

Date: 2026-02-26

## Objective

Detect one thing reliably across agents:

- `task_done`

Everything else (reasoning deltas, item timelines, rich structured rendering) is out of scope for this phase.

## Product Decision

Use each provider's strongest native completion signal.

- Codex: TUI in PTY for UX, `notify` for completion signal.
- Claude: TUI in PTY for UX, hook callback for completion signal.
- Other TUI agents: provider hook if available; otherwise explicit fallback policy.

## Core Architecture

Two channels only:

1. `PTY channel` (visual)
- Raw terminal stream to frontend.
- No semantic parsing required for completion.
- Transport: direct binary WebSocket from browser hook to Go daemon PTY endpoint.
- Do not route terminal byte stream through Phoenix LiveView events/channels.

2. `Completion channel` (control)
- Tiny normalized event from provider adapter.
- Drives the run state (`running` -> `done` / `failed`).
- Transport: existing daemon -> Phoenix event path is fine for control/status.

## Phoenix + Go Boundary

- LiveView owns page lifecycle, auth, UI chrome, stop/start controls, maker/checker state.
- xterm hook owns direct daemon WebSocket for terminal I/O.
- LiveView passes short-lived signed token + run/session id to hook.
- Daemon verifies token before spawning/attaching PTY.
- Prefer one origin in prod via reverse proxy path (for example `/ws/terminal`).

## Unified Completion Contract

```ts
type TaskCompletionEvent = {
  run_id: string;
  provider: 'codex' | 'claude' | string;
  status: 'done' | 'failed';
  source:
    | 'provider_notify'
    | 'provider_hook'
    | 'structured_event'
    | 'process_exit'
    | 'manual'
    | 'manual_stop';
  occurred_at: string; // ISO timestamp
  provider_run_id?: string; // thread/session id when available
  message?: string; // optional summary
  raw?: unknown; // provider payload for debugging
};
```

Only this contract is required for UI state.

## Completion Reliability Tiers

- Tier A: Provider-native callback (`notify`/hook/structured completion event).
- Tier B: Non-interactive process exit (for one-shot modes like `exec`).
- Tier C: Manual user confirmation (`Mark done`).

Do not use terminal text regex as source of truth for done.

## Escape Hatch: Stop And Continue

Add a `Stop` button while a run is `running`.

- Button action: `Stop current agent and continue to next role`.
- Daemon behavior:
1. Send graceful stop to provider process.
2. Wait short timeout.
3. Force kill if still alive.
4. Emit `TaskCompletionEvent(status='failed', source='manual_stop', message='stopped by user')`.
- Loop behavior:
1. Mark current agent attempt terminal.
2. Immediately start next maker/checker agent per loop policy.

`Stop` is the explicit recovery path when an agent is stuck.

## Codex Plan (TUI + notify)

## Why

Codex exposes `notify` for `agent-turn-complete`, which is the right minimal completion primitive for TUI mode.

## Implementation

1. Add a small notifier bridge executable in this repo.
- Input: one JSON arg from Codex `notify`.
- Filter: `type == "agent-turn-complete"`.
- Emit `TaskCompletionEvent(status='done', source='provider_notify')` to daemon.

2. Launch Codex TUI with notify configured.
- Preferred: pass config override at launch (`-c notify=[...]`) so no permanent user config mutation.
- Fallback: documented one-time user setup in `~/.codex/config.toml`.

3. Map `thread-id` from notify payload to internal `run_id`.
- Persist mapping at run start.
- Use mapping to emit the correct completion event.

4. Failure handling.
- If notifier bridge is not reachable, log the error.
- Keep run active, allow manual completion.

## Codex Payload Used

```json
{
  "type": "agent-turn-complete",
  "thread-id": "...",
  "turn-id": "...",
  "cwd": "...",
  "input-messages": ["..."],
  "last-assistant-message": "..."
}
```

## Claude Plan

- Keep current hook-based completion path.
- Normalize to the same `TaskCompletionEvent` contract.

## OpenCode / Pi / Other TUI Agents

- If native hook exists: wire to `TaskCompletionEvent`.
- If no hook exists:
  - use Tier B only for one-shot non-interactive mode (if supported), or
  - use Tier C manual `Mark done`.

Default policy for interactive TUI without hooks: no auto-done.

## UI Scope (Minimal)

Single run status model:

- `idle`
- `running`
- `done`
- `failed`

Primary UI behavior:

- Show terminal as the main surface.
- Show a small status pill bound to `TaskCompletionEvent`.
- Optional manual action: `Mark done`.
- Escape hatch action: `Stop`.

## Data Ownership

Own only:

- provider adapter launch
- completion bridge
- run-id mapping
- normalized completion event

Do not own:

- provider terminal rendering logic
- semantic parsing of terminal text for done
- provider-specific timeline schemas

## Rollout Plan

## Phase 1 (Codex only)

1. Build notifier bridge.
2. Wire Codex launch with `notify` config.
3. Map `thread-id` -> `run_id`.
4. Emit normalized `task_done`.
5. Add `Stop` button kill path and next-agent handoff.
6. Add manual fallback button.

Acceptance:

- In 20/20 local runs, Codex completion flips run to `done` within 2s of turn completion.
- If notifier fails, run remains `running` until manual completion.
- In 20/20 stop tests, pressing `Stop` kills current process and starts next maker/checker agent.

## Phase 2 (Claude parity)

1. Normalize existing Claude hook output to same contract.
2. Verify identical UI behavior.

Acceptance:

- Same status transitions and payload shape as Codex.

## Phase 3 (Other providers)

1. Capability audit per provider: hook vs non-interactive vs manual.
2. Add adapter configs only where Tier A/B is possible.

Acceptance:

- Every provider explicitly classified with a completion tier.

## Risks and Mitigations

- Risk: Codex `notify` not configured correctly.
- Mitigation: pass launch-time config override; health-check bridge; manual completion fallback.

- Risk: Completion corresponds to turn, while user expects larger "task" scope.
- Mitigation: define task scope as current active run attempt; each steer restarts the completion latch.

- Risk: Hook payload lost due bridge crash.
- Mitigation: append raw notify payloads to local JSONL journal before forwarding.

- Risk: provider process ignores graceful stop.
- Mitigation: enforce timeout and force kill, then emit `manual_stop`.

## Out of Scope

- Realtime turn/item timeline.
- Rich approvals/task graph UI.
- Terminal-output-based semantic classifiers for completion.

## Final Recommendation

Ship terminal-first with side-channel completion signals now.

- Codex: TUI + `notify`.
- Claude: TUI + hooks.
- Others: hook if available, else manual fallback.

This is the smallest architecture that is reliable for `task_done` and keeps multi-agent compatibility clean.
