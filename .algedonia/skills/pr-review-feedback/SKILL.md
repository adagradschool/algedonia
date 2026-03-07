---
name: pr-review-feedback
description:
  Fetch and summarize active pull request review feedback with `gh` (inline review
  comments, review decisions, and PR discussion comments) for the current branch.
---

# PR Review Feedback

Use this skill when you need the latest reviewer feedback on the active PR.

## Goals

- Detect the PR tied to the current branch.
- Pull all relevant feedback channels with `gh`.
- Summarize unresolved/blocking feedback clearly.

## Workflow

1. Resolve active PR for current branch.
2. Fetch review summary (`reviews`), inline review comments, and issue comments.
3. Identify unresolved/blocking items.
4. Return a concise action list (what to fix, where, and who requested it).

## Commands

```bash
# Resolve active PR for current branch
pr_number=$(gh pr view --json number -q .number 2>/dev/null || true)
if [ -z "$pr_number" ]; then
  echo "No active PR for current branch." >&2
  exit 1
fi

# High-level PR status
gh pr view "$pr_number" --json number,title,url,state,reviewDecision,isDraft

# Review decisions/events (APPROVED / CHANGES_REQUESTED / COMMENTED)
gh api --paginate "repos/{owner}/{repo}/pulls/$pr_number/reviews"

# Inline review comments (code-level feedback)
gh api --paginate "repos/{owner}/{repo}/pulls/$pr_number/comments"

# PR issue comments (discussion thread)
gh api --paginate "repos/{owner}/{repo}/issues/$pr_number/comments"
```

## Optional Filters

```bash
# Show unresolved-style inline comments (no replies)
gh api --paginate "repos/{owner}/{repo}/pulls/$pr_number/comments" \
  --jq '.[] | select(.in_reply_to_id == null) | {id,user:.user.login,path,line,body,created_at}'

# Show latest change requests
gh api --paginate "repos/{owner}/{repo}/pulls/$pr_number/reviews" \
  --jq '.[] | select(.state == "CHANGES_REQUESTED") | {user:.user.login,submitted_at,body}'
```

## Output Expectations

Report:
- PR URL and current review decision.
- Blocking feedback items (if any), grouped by file/thread.
- Non-blocking suggestions separately.
- Suggested next actions in priority order.

## Guardrails

- Do not assume approval means no pending inline feedback.
- Check both review comments and issue comments.
- If no PR exists for the branch, report that explicitly and stop.
