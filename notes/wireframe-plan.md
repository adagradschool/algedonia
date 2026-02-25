# Loop Inspector Wireframe — Implementation Plan

Reference: `codex-agent-screen-annotated.png`, `prd.md` (UI Layout), `sdd.md` (Sections 2.1–2.3, 7.4)

## Layout

CSS Grid, three columns. Information flows left to right: DAG → Loop → Artifacts.

```
┌──────────┬──────────┬────────────────────────┬──────────────────────┐
│          │          │                        │  Diff / Rubric /     │
│ Sidebar  │  DAG     │  Terminal              │  Verdict / History   │
│ (220px)  │  Tree    │  (active agent run)    │  (tabbed, 360px)     │
│          │ (240px)  │  (flex)                │                      │
│ Nav top  │          │                        │                      │
│ Collab   │          │                        │                      │
│ bottom   │          │                        │                      │
└──────────┴──────────┴────────────────────────┴──────────────────────┘
```

## Mock Data

Ticket: "Add JWT authentication to API" with 6 loops:

| Loop | Title | Status | Depth | Manual Gate |
|------|-------|--------|-------|-------------|
| 1 | Define JWT schema & config | passed | 0 | no |
| 2 | Implement token signing & verification | passed | 1 | no |
| 3 | Add login endpoint | running_maker | 1 | no |
| 4 | Auth middleware (plug) | pending_approval | 2 | yes |
| 5 | Refresh token rotation | pending | 2 | no |
| 6 | Integration tests for auth flow | pending | 3 | no |

Dependencies: 1→2, 1→3, 2→4, 3→4, 2→5, 4→6, 5→6

## Panels

### Left Sidebar
- Top: Logo + nav links (Tickets, Loop Inspector active, Monitor)
- Bottom: Presence (online users), user settings

### DAG Panel
- Loops grouped by dependency depth, indented 16px per level
- Status icons (Unicode): ○ pending, ◉ running (pulse), ● passed, ✕ failed, ▲ escalated, ? clarification, ◈ pending_approval
- Click node → updates terminal + right panel
- Manual gate shown as lock icon on node

### Terminal Panel
- Dark background (#0d0d0d), monospace font
- Fake agent output with ANSI-like colored spans
- Header: loop title, role badge (maker/checker), status
- Blinking cursor for running loops
- Approval bar (approve/reject) shown for pending_approval loops

### Right Panel (Tabbed)
- **Diff**: Mock unified diff with +/- colored lines
- **Rubric**: Editable textarea in SDD 7.4 format
- **Verdict**: Hard gates as pass/fail badges, weighted scores with bars, threshold indicator
- **History**: Attempt list — maker/checker entries with verdict, duration, token usage

## Interactions (Vanilla JS)
- `selectLoop(id)` — update all panels for selected loop
- `switchTab(name)` — toggle right panel tabs
- `handleApprove()`/`handleReject()` — mock approval flow

## Color Tokens (Dark Theme)
- Surface: #0f1117, Raised: #1a1d27, Sidebar: #13151d
- Border: #2a2d3a
- Text: #e2e4ea (primary), #9ca0b0 (secondary), #5c6070 (muted)
- Status: green #22c55e, red #ef4444, orange #f97316, yellow #eab308, blue #3b82f6, cyan #06b6d4, purple #a855f7

## Build Order
1. HTML skeleton + CSS grid
2. Left sidebar (static)
3. Mock data constants
4. DAG panel with nodes
5. Terminal panel with fake output
6. Right panel tabs + content
7. JS: selectLoop() wiring
8. JS: switchTab() wiring
9. Approval bar logic
10. Polish: animations, hover states
