# Project structure validation — Claude Code scaffold + project layout.

# Root CLAUDE.md
assert_file_exists "CLAUDE.md"
assert_grep "^# Project Context" "CLAUDE.md" "CLAUDE.md has Project Context heading"
assert_grep "## Tech Stack" "CLAUDE.md" "CLAUDE.md has Tech Stack section"
assert_grep "## Auto-Sync Rules" "CLAUDE.md" "CLAUDE.md has Auto-Sync Rules section"
assert_grep "ADR Mermaid Requirement" "CLAUDE.md" "CLAUDE.md documents the ADR Mermaid requirement"

# Module CLAUDE.md files
assert_file_exists "src/lib/CLAUDE.md"
assert_file_exists "src/lambdas/CLAUDE.md"
assert_file_exists "src/lambdas/pii_guard/CLAUDE.md"
assert_file_exists "src/lambdas/classify/CLAUDE.md"
assert_file_exists "src/lambdas/verify/CLAUDE.md"
assert_file_exists "src/lambdas/persist/CLAUDE.md"
assert_file_exists "src/prompts/CLAUDE.md"
assert_file_exists "tests/CLAUDE.md"
assert_file_exists "infra/CLAUDE.md"

# Docs
assert_file_exists "docs/architecture.md"
assert_file_exists "docs/onboarding.md"
assert_file_exists "docs/decisions/.template.md"
assert_file_exists "docs/runbooks/.template.md"
assert_grep "Architecture Flow" "docs/decisions/.template.md" "ADR template enforces Architecture Flow section"
assert_grep "Mermaid" "docs/decisions/.template.md" "ADR template mentions Mermaid"
assert_grep "mermaid" "docs/decisions/.template.md" "ADR template has mermaid code block placeholder"

# Skills + commands + agents
assert_file_exists ".claude/skills/code-review/SKILL.md"
assert_file_exists ".claude/skills/refactor/SKILL.md"
assert_file_exists ".claude/skills/release/SKILL.md"
assert_file_exists ".claude/skills/sync-docs/SKILL.md"
assert_file_exists ".claude/commands/review.md"
assert_file_exists ".claude/commands/test-all.md"
assert_file_exists ".claude/commands/deploy.md"
assert_file_exists ".claude/agents/code-reviewer.yml"
assert_file_exists ".claude/agents/security-auditor.yml"

# Top-level support files
assert_file_exists ".mcp.json"
assert_file_exists ".env.example"
assert_file_exists ".editorconfig"
assert_file_exists "README.md"
assert_file_exists "CHANGELOG.md"
assert_grep "# English" "README.md" "README.md is bilingual (English section)"
assert_grep "# 한국어" "README.md" "README.md is bilingual (Korean section)"
assert_grep "# English" "CHANGELOG.md" "CHANGELOG.md is bilingual (English section)"
assert_grep "# 한국어" "CHANGELOG.md" "CHANGELOG.md is bilingual (Korean section)"

# Scripts
assert_executable "scripts/setup.sh"
assert_executable "scripts/install-hooks.sh"
assert_executable "tests/run-all.sh"
