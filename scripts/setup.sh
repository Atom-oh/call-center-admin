#!/usr/bin/env bash
# call-center-admin local setup — bring a new developer to a passing pytest run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Python version check"
PY="python3"
if ! command -v "$PY" >/dev/null 2>&1; then
    echo "Python 3 is required."
    exit 1
fi
PY_VER=$("$PY" -c "import sys; print('{}.{}'.format(sys.version_info[0], sys.version_info[1]))")
echo "    using $PY $PY_VER"
if [ "$("$PY" -c "import sys; print(sys.version_info >= (3, 12))")" != "True" ]; then
    echo "    WARNING: Python 3.12 is the target. 3.9+ works locally thanks to 'from __future__ import annotations'."
fi

echo "==> Create / activate venv"
if [ ! -d .venv ]; then
    "$PY" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

echo "==> Install dev dependencies (editable)"
pip install --upgrade pip >/dev/null
pip install -e ".[dev]"

echo "==> Run unit tests"
pytest --no-cov

echo "==> Terraform validate (offline)"
if command -v terraform >/dev/null 2>&1; then
    terraform fmt -recursive -check infra/ || {
        echo "    terraform fmt drift detected; run 'terraform fmt -recursive infra/' to fix."
    }
    terraform -chdir=infra/envs/dev init -backend=false -reconfigure >/dev/null
    terraform -chdir=infra/envs/dev validate
else
    echo "    terraform not installed locally; skipping. Install 1.9+ before opening infra PRs."
fi

echo "==> Install git hooks"
if [ -x scripts/install-hooks.sh ]; then
    bash scripts/install-hooks.sh
fi

echo ""
echo "Setup complete. Next steps:"
echo "  - Read CLAUDE.md for conventions"
echo "  - Read docs/architecture.md for the system overview"
echo "  - Read STATUS.md for current Phase 1 progress"
echo "  - Pick a remaining PR from docs/superpowers/plans/2026-05-22-phase1-callcenter-classification.md"
