#!/bin/bash
# Scan staged files for secrets before commit.
# Triggered by PreToolUse event (matcher: Bash).
# Exit 1 to block the commit if secrets are found.

SECRETS_FOUND=0

# Patterns to detect (covers AWS, Anthropic, OpenAI, GitHub, Slack, Stripe, Google, Azure,
# plus generic password/secret/api_key assignments).
PATTERNS=(
    'AKIA[0-9A-Z]{16}'
    '(?<=aws_secret_access_key\s{0,5}[=:]\s{0,5})[A-Za-z0-9/+=]{40}'
    'sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}'
    'sk-ant-[A-Za-z0-9-]{90,}'
    'ghp_[A-Za-z0-9]{36}'
    'gho_[A-Za-z0-9]{36}'
    'github_pat_[A-Za-z0-9_]{82}'
    'xoxb-[0-9]+-[A-Za-z0-9]+'
    'xoxp-[0-9]+-[A-Za-z0-9]+'
    'sk_live_[A-Za-z0-9]{24,}'
    'rk_live_[A-Za-z0-9]{24,}'
    'AIza[A-Za-z0-9_-]{35}'
    'ya29\.[A-Za-z0-9_-]{50,}'
    'DefaultEndpointsProtocol=https;Account'
    'password\s*[:=]\s*["\x27][^"\x27]{8,}'
    'secret\s*[:=]\s*["\x27][^"\x27]{8,}'
    'api[_-]?key\s*[:=]\s*["\x27][^"\x27]{8,}'
)

# Files to skip (examples and lock files won't carry real secrets)
SKIP_PATTERNS=('.env.example' 'secret-scan.sh' '*.md' 'package-lock.json' 'yarn.lock' '*.lock.hcl' 'tests/fixtures/*')

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
[ -z "$STAGED_FILES" ] && exit 0

for file in $STAGED_FILES; do
    skip=false
    for pattern in "${SKIP_PATTERNS[@]}"; do
        [[ "$file" == $pattern ]] && skip=true && break
    done
    $skip && continue
    [ ! -f "$file" ] && continue

    for regex in "${PATTERNS[@]}"; do
        if grep -qP "$regex" "$file" 2>/dev/null; then
            echo "[secret-scan] Potential secret found in $file (pattern: ${regex:0:30}...)"
            SECRETS_FOUND=1
        fi
    done
done

if [ "$SECRETS_FOUND" -eq 1 ]; then
    echo ""
    echo "[secret-scan] BLOCKED: Potential secrets detected in staged files."
    echo "[secret-scan] Review the files above and remove secrets before committing."
    echo "[secret-scan] Use .env files for secrets and .env.example for templates."
    echo "[secret-scan] AWS credentials should be loaded via IAM Roles / OIDC, not committed."
    exit 1
fi
