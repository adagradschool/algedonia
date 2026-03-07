---
name: ag
description:
  Use the `ag` CLI to inspect and mutate workspace/ticket state from terminal.
---

# AG CLI

## Goals

- Query ticket/workspace state quickly.
- Perform safe, explicit ticket updates and comments.

## Core Commands

```bash
# Workspace context
ag workspace list
ag workspace use <workspace-slug>

# Ticket reads
ag ticket list --json
ag ticket show <number-or-id> --json
ag ticket comments <number-or-id> --json

# Ticket writes
ag ticket comment <number-or-id> --author "<author>" --body "<markdown>"
ag ticket update <number-or-id> --title "<title>" --description "<desc>" \
  --acceptance-criteria "<criteria>" --rubric "<rubric>"
```

## Workflow

1. Confirm active workspace.
2. Read current ticket state before any mutation.
3. Apply minimal changes needed.
4. Re-read in `--json` mode to verify result.

## Guardrails

- Prefer UUIDs or exact ticket numbers over fuzzy matching.
- Do not overwrite long fields blindly; read before write.
- Keep comments concise and actionable.
