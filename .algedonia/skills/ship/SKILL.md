---
name: ship
description:
  Run local gates, open/update a PR with a strong description, verify CI is
  green, then either merge or wait for human review based on config.
---

# Ship

## Workflow

1. Run local gate checks and fix any failures.
2. Push branch and create/update PR with clear title/body (`push` skill).
3. Wait for CI checks to finish and pass.
4. Read landing mode from config:
   - `auto_land` -> squash-merge PR.
   - `review_gate` -> do not merge; leave PR ready for human review.
5. Report outcome with PR URL and current status.

## Commands

```bash
pr_title=$(gh pr view --json title -q .title)
pr_body=$(gh pr view --json body -q .body)

# Wait for CI
if ! gh pr checks --watch; then
  gh pr checks
  gh run list --branch "$(git branch --show-current)"
  exit 1
fi

# Resolve land mode from config (default: review_gate)
land_mode=$(rg -n 'default_land:' .algedonia/config.yml 2>/dev/null | head -n1 | sed -E 's/.*default_land:[[:space:]]*//; s/[[:space:]]+#.*$//' || true)
[ -z "$land_mode" ] && land_mode="review_gate"

if [ "$land_mode" = "auto_land" ]; then
  gh pr merge --squash --subject "$pr_title" --body "$pr_body"
else
  gh pr view --json url,state -q '.url + " (" + .state + ")"'
fi
```

## Guardrails

- Never merge with failing required checks.
- In `review_gate`, do not merge even if CI is green.
- Keep PR description updated to match real shipped scope.
