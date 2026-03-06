---
name: browser
type: browser
boot: just server
health: http://localhost:4000/healthz
description: Visual verification via headless browser
params:
  scenario: null  # required — Playwright scenario to execute
  timeout: 30000  # ms to wait for health endpoint
---

# Browser

Boots the application, waits for the health endpoint, then drives a headless browser (Playwright/CDP) to verify UI behavior.

Per-ticket `params.scenario` defines what to check (e.g., "navigate to /queue, verify ticket list renders, drag a ticket to a new status column").

Artifacts (screenshots, DOM snapshots, console logs) stay on the daemon — only a pass/fail summary is reported to the server.

This is an optional skill — added to checker config during planning for tickets with UI-facing changes.
