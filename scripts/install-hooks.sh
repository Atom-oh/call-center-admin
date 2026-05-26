#!/usr/bin/env bash
# Install Git hooks that strip AI Co-Authored-By trailers from commit messages.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "Not a git repository: $REPO_ROOT/.git not found."
    exit 1
fi

cat > "$HOOKS_DIR/commit-msg" <<'HOOK'
#!/bin/bash
# Remove Co-Authored-By lines from commit messages.
# Covers variations: Co-Authored-By, Co-authored-by, co-authored-by
sed -i '/^[Cc]o-[Aa]uthored-[Bb]y:.*/d' "$1"
# Remove trailing blank lines left after removal
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$1"
HOOK

chmod +x "$HOOKS_DIR/commit-msg"
echo "Installed: $HOOKS_DIR/commit-msg"
