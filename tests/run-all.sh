#!/usr/bin/env bash
# Harness test runner for the project-init scaffold (hooks, structure, fixtures).
# Separate from `pytest` — this validates the Claude Code scaffold itself, not the application.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TOTAL=0
PASS=0
FAIL=0
FAILED_NAMES=()

# TAP-style runner. Each tests/<group>/test_*.sh sources lib.sh or defines its own
# `pass()`/`fail()` helpers and prints `ok N - <desc>` / `not ok N - <desc>` lines.

# Shared assertion helpers (sourced by each test script via `source "$REPO_ROOT/tests/run-all.sh"`)
assert_file_exists() {
    local path="$1" desc="${2:-file exists: $1}"
    TOTAL=$((TOTAL + 1))
    if [ -f "$path" ]; then
        PASS=$((PASS + 1))
        echo "ok $TOTAL - $desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$desc")
        echo "not ok $TOTAL - $desc"
    fi
}

assert_executable() {
    local path="$1" desc="${2:-executable: $1}"
    TOTAL=$((TOTAL + 1))
    if [ -x "$path" ]; then
        PASS=$((PASS + 1))
        echo "ok $TOTAL - $desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$desc")
        echo "not ok $TOTAL - $desc"
    fi
}

assert_grep() {
    local pattern="$1" file="$2" desc="${3:-pattern \"$1\" in $2}"
    TOTAL=$((TOTAL + 1))
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo "ok $TOTAL - $desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$desc")
        echo "not ok $TOTAL - $desc"
    fi
}

# assert_eq <desc> <expected> <actual>
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "ok $TOTAL - $desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$desc (expected '$expected', got '$actual')")
        echo "not ok $TOTAL - $desc (expected '$expected', got '$actual')"
    fi
}

# assert_grep_match <desc> <ERE> <string> — a string (not a file) matched with grep -E
assert_grep_match() {
    local desc="$1" pattern="$2" text="$3"
    TOTAL=$((TOTAL + 1))
    if printf '%s\n' "$text" | grep -qE -- "$pattern"; then
        PASS=$((PASS + 1))
        echo "ok $TOTAL - $desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$desc (pattern '$pattern' not matched)")
        echo "not ok $TOTAL - $desc (pattern '$pattern' not matched)"
    fi
}

# assert_grep_no_match <desc> <ERE> <string>
assert_grep_no_match() {
    local desc="$1" pattern="$2" text="$3"
    TOTAL=$((TOTAL + 1))
    if printf '%s\n' "$text" | grep -qE -- "$pattern"; then
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$desc (pattern '$pattern' unexpectedly matched)")
        echo "not ok $TOTAL - $desc (pattern '$pattern' unexpectedly matched)"
    else
        PASS=$((PASS + 1))
        echo "ok $TOTAL - $desc"
    fi
}

# assert_bash_syntax <desc> <file>
assert_bash_syntax() {
    local desc="$1" file="$2"
    TOTAL=$((TOTAL + 1))
    if bash -n "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo "ok $TOTAL - $desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$desc (bash -n failed: $file)")
        echo "not ok $TOTAL - $desc (bash -n failed: $file)"
    fi
}

# assert_json_valid <desc> <file>
assert_json_valid() {
    local desc="$1" file="$2"
    TOTAL=$((TOTAL + 1))
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo "ok $TOTAL - $desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$desc (invalid JSON: $file)")
        echo "not ok $TOTAL - $desc (invalid JSON: $file)"
    fi
}

# skip <desc> <reason> — TAP "ok ... # SKIP" directive (counts toward TOTAL/PASS, never FAIL)
skip() {
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo "ok $TOTAL - $1 # SKIP $2"
}

# Only run the assertion suite if invoked directly. If sourced, do not run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "# Harness — call-center-admin scaffold tests"

    # Run each test group
    for test_script in tests/hooks/test-*.sh tests/structure/test-*.sh; do
        [ -f "$test_script" ] || continue
        echo "# $test_script"
        # shellcheck disable=SC1090
        source "$test_script"
    done

    echo ""
    echo "# ${TOTAL} tests, ${PASS} passed, ${FAIL} failed"
    if [ "$FAIL" -gt 0 ]; then
        echo "# Failed:"
        for name in "${FAILED_NAMES[@]}"; do
            echo "#   - $name"
        done
        exit 1
    fi
fi
