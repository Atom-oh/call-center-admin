#!/bin/bash
# Detect documentation sync needs after file changes.
# Triggered by PostToolUse (Write|Edit) events.
# Walks parent directories to find CLAUDE.md before warning.

FILE_PATH="${1:-}"
[ -z "$FILE_PATH" ] && exit 0

# Source roots specific to this Python + Terraform Lambda project
SOURCE_ROOTS="src infra tests scripts"

for ROOT in $SOURCE_ROOTS; do
    if [[ "$FILE_PATH" == ${ROOT}/* ]]; then
        DIR=$(dirname "$FILE_PATH")
        FOUND_CLAUDE=false
        CHECK_DIR="$DIR"
        while [ "$CHECK_DIR" != "$ROOT" ] && [ "$CHECK_DIR" != "." ]; do
            if [ -f "$CHECK_DIR/CLAUDE.md" ]; then
                FOUND_CLAUDE=true
                break
            fi
            CHECK_DIR=$(dirname "$CHECK_DIR")
        done
        if ! $FOUND_CLAUDE && [ "$DIR" != "$ROOT" ]; then
            echo "[doc-sync] $DIR/CLAUDE.md is missing. Create module documentation."
        fi
        break
    fi
done

# Alert if no ADRs exist when source or architecture files change
IS_SOURCE=false
for ROOT in $SOURCE_ROOTS; do
    [[ "$FILE_PATH" == ${ROOT}/* ]] && IS_SOURCE=true && break
done
if $IS_SOURCE || [[ "$FILE_PATH" == docs/architecture.md ]]; then
    ADR_COUNT=$(find docs/decisions -name 'ADR-*.md' -not -name '.template.md' 2>/dev/null | wc -l)
    if [ "$ADR_COUNT" -eq 0 ]; then
        echo "[doc-sync] No ADRs found. Record architectural decisions in docs/decisions/."
    fi
fi

# Alert if no runbooks exist when infrastructure files change
if [[ "$FILE_PATH" == */*.tf ]] || [[ "$FILE_PATH" == Dockerfile* ]] || [[ "$FILE_PATH" == infra/* ]]; then
    RUNBOOK_COUNT=$(find docs/runbooks -name '*.md' -not -name '.template.md' 2>/dev/null | wc -l)
    if [ "$RUNBOOK_COUNT" -eq 0 ]; then
        echo "[doc-sync] No runbooks found. Create operational runbooks for deployment/recovery."
    fi
fi

# Project-specific: prompt version + DDB schema co-change reminder
if [[ "$FILE_PATH" == src/lib/prompts.py ]] || [[ "$FILE_PATH" == src/prompts/* ]]; then
    echo "[doc-sync] Prompt changed: bump PROMPT_VERSION in src/lib/prompts.py and create a new src/prompts/v<N>.<M>/ if structural."
fi
if [[ "$FILE_PATH" == infra/modules/storage/main.tf ]]; then
    echo "[doc-sync] Storage module changed: confirm src/lib/persistence.py:build_ddb_item still matches the DDB schema (especially GSI keys)."
fi
