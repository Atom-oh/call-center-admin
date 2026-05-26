# Hook scaffold validation — existence, permissions, registration in settings.json.

assert_file_exists ".claude/hooks/check-doc-sync.sh"
assert_file_exists ".claude/hooks/secret-scan.sh"
assert_file_exists ".claude/hooks/session-context.sh"
assert_file_exists ".claude/hooks/notify.sh"

assert_executable ".claude/hooks/check-doc-sync.sh"
assert_executable ".claude/hooks/secret-scan.sh"
assert_executable ".claude/hooks/session-context.sh"
assert_executable ".claude/hooks/notify.sh"

assert_grep "PostToolUse" ".claude/settings.json" "settings.json registers PostToolUse hook"
assert_grep "PreToolUse" ".claude/settings.json" "settings.json registers PreToolUse hook"
assert_grep "SessionStart" ".claude/settings.json" "settings.json registers SessionStart hook"
assert_grep "Notification" ".claude/settings.json" "settings.json registers Notification hook"
assert_grep "deny" ".claude/settings.json" "settings.json deny list present"
assert_grep "terraform apply" ".claude/settings.json" "deny list blocks terraform apply"
