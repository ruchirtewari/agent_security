#!/bin/bash
# Nightly next-steps advisor for ClaudeCertifiedArchitect.
# Run via cron: 0 8 * * * /Users/ruchirtewari/ClaudeCertifiedArchitect/.claude/hooks/nightly-suggestions.sh

REPO="/Users/ruchirtewari/ClaudeCertifiedArchitect"
LOG="$REPO/.claude/nightly-report.md"

RECENT_COMMITS=$(git -C "$REPO" log --oneline -10 2>/dev/null)
GIT_STATUS=$(git -C "$REPO" status --short 2>/dev/null)
HOOKS=$(ls "$REPO/.claude/hooks/" 2>/dev/null)
SKILLS=$(ls "$REPO/.claude/skills/" 2>/dev/null)

REPORT=$(claude -p --allowedTools "" \
"You are a development advisor for the ClaudeCertifiedArchitect project.

Context:
- Recent commits:
$RECENT_COMMITS

- Uncommitted changes:
$GIT_STATUS

- Installed hooks:
$HOOKS

- Available skills:
$SKILLS

Produce a concise next-steps report with these sections:

## $(date '+%Y-%m-%d') – Nightly Report

### Recent Progress
One sentence on what changed based on git log.

### Security Posture
Which hooks are installed, what coverage they provide, what gaps remain.

### Suggested Next Steps
3–5 concrete prioritised actions. Name specific files, commands, or skills.
Focus on: open security gaps, skills to build, cert exam practice, uncommitted work.

Under 250 words total." 2>/dev/null)

echo "$REPORT" > "$LOG"
echo "$REPORT"
