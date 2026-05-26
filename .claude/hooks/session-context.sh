#!/bin/bash
# Load project context at Claude Code session start.
# Outputs key project information for immediate context.

echo "=== Project Context ==="
echo "Project: call-center-admin (Python + Terraform — Bedrock STT 분류 시스템)"

# Recent activity
LAST_COMMIT=$(git log -1 --format="%h %s (%cr)" 2>/dev/null)
[ -n "$LAST_COMMIT" ] && echo "Last commit: $LAST_COMMIT"

BRANCH=$(git branch --show-current 2>/dev/null)
[ -n "$BRANCH" ] && echo "Branch: $BRANCH"

CHANGES=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
[ "$CHANGES" -gt 0 ] && echo "Uncommitted changes: $CHANGES file(s)"

CLAUDE_COUNT=$(find . -name "CLAUDE.md" -not -path "./.git/*" 2>/dev/null | wc -l | tr -d ' ')
echo "CLAUDE.md files: $CLAUDE_COUNT"

# Test + terraform health (cheap checks, no execution)
PYTEST_COUNT=$(find tests -name 'test_*.py' 2>/dev/null | wc -l | tr -d ' ')
TF_FILES=$(find infra -name '*.tf' 2>/dev/null | wc -l | tr -d ' ')
echo "pytest files: $PYTEST_COUNT | terraform files: $TF_FILES"

# Phase progress (parse STATUS.md if present)
if [ -f STATUS.md ]; then
    DONE_PR=$(grep -c "✅" STATUS.md 2>/dev/null || echo 0)
    echo "STATUS.md present: $DONE_PR PR checkpoints marked done"
fi

echo "======================"
