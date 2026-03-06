---
name: agent-review
type: agent_review
description: LLM-based code review against ticket-specific rubrics and acceptance criteria
params:
  rubrics: []    # required — list of rubric section IDs to evaluate (e.g., ["elixir", "liveview", "ecto"])
  focus: null    # optional — narrow review scope (e.g., "security", "performance", "workspace-isolation")
---

# Agent Review

Spawns a review agent that evaluates the diff against:
- The ticket's acceptance criteria
- The rubric sections specified in `params.rubrics` (from `.algedonia/rubrics.md`)
- Any per-ticket focus params

The planning agent selects which rubric sections are relevant for each ticket. A backend Ecto migration gets `["elixir", "ecto", "database"]`. A LiveView feature gets `["elixir", "liveview", "protocol"]`. Not every ticket needs every rubric.

Returns a structured verdict (pass/fail + comments). Comments reference specific files and lines.

This is an optional skill — added to checker config during planning for tickets that benefit from semantic review beyond compile/test/lint.
