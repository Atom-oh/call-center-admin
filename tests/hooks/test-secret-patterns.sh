# Secret-scan pattern validation against true-positive / false-positive fixtures.

TP="tests/fixtures/secret-samples.txt"
FP="tests/fixtures/false-positives.txt"

assert_file_exists "$TP"
assert_file_exists "$FP"
assert_file_exists ".claude/hooks/secret-scan.sh"

# True positives — should trigger
for pat in 'AKIA[0-9A-Z]{16}' 'ghp_[A-Za-z0-9]{36}' 'sk-ant-[A-Za-z0-9-]{90,}'; do
    TOTAL=$((TOTAL + 1))
    if grep -qP "$pat" "$TP" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo "ok $TOTAL - true-positive pattern triggers: ${pat:0:20}..."
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("true-positive missing: ${pat:0:20}...")
        echo "not ok $TOTAL - true-positive pattern missing: ${pat:0:20}..."
    fi
done

# False positives — should NOT trigger (these are AWS account ARNs, example IDs, etc.)
for pat in 'AKIA[0-9A-Z]{16}' 'ghp_[A-Za-z0-9]{36}'; do
    TOTAL=$((TOTAL + 1))
    if grep -qP "$pat" "$FP" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("false-positive triggered: ${pat:0:20}...")
        echo "not ok $TOTAL - false-positive triggered: ${pat:0:20}..."
    else
        PASS=$((PASS + 1))
        echo "ok $TOTAL - false-positive correctly skipped: ${pat:0:20}..."
    fi
done
