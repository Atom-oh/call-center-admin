# GitHub Actions workflows validation — 4 workflows + PR template + setup docs.

assert_file_exists ".github/workflows/pr-review.yml"
assert_file_exists ".github/workflows/ci.yml"
assert_file_exists ".github/workflows/terraform-plan.yml"
assert_file_exists ".github/workflows/terraform-apply.yml"
assert_file_exists ".github/pull_request_template.md"
assert_file_exists "docs/operations/github-actions-setup.md"

# pr-review.yml — must use pull_request_target + Bedrock Claude + diff filter
assert_grep "pull_request_target" ".github/workflows/pr-review.yml" "pr-review uses pull_request_target trigger"
assert_grep "CLAUDE_CODE_USE_BEDROCK" ".github/workflows/pr-review.yml" "pr-review uses Bedrock backend"
assert_grep "claude-opus-4-7" ".github/workflows/pr-review.yml" "pr-review pins Opus 4.7 model"
assert_grep "taxonomy_tree" ".github/workflows/pr-review.yml" "pr-review filters generated taxonomy artifacts"
assert_grep "claude --print" ".github/workflows/pr-review.yml" "pr-review invokes claude CLI"

# ci.yml — must run pytest + terraform validate, gated by path filters
assert_grep "dorny/paths-filter" ".github/workflows/ci.yml" "ci uses paths-filter"
assert_grep "ruff check" ".github/workflows/ci.yml" "ci runs ruff check"
assert_grep "mypy src" ".github/workflows/ci.yml" "ci runs mypy"
assert_grep "pytest" ".github/workflows/ci.yml" "ci runs pytest"
assert_grep "terraform fmt -recursive -check" ".github/workflows/ci.yml" "ci runs terraform fmt check"
assert_grep "terraform.*validate" ".github/workflows/ci.yml" "ci runs terraform validate"

# terraform-plan.yml — must trigger on PR, post comment, NOT apply
assert_grep "pull_request" ".github/workflows/terraform-plan.yml" "terraform-plan triggers on PR"
assert_grep "terraform plan" ".github/workflows/terraform-plan.yml" "terraform-plan runs plan"
assert_grep "gh pr comment" ".github/workflows/terraform-plan.yml" "terraform-plan posts result as PR comment"
assert_grep "callcenter-github-actions-tf-plan" ".github/workflows/terraform-plan.yml" "terraform-plan uses dedicated OIDC role"
# Negative: terraform-plan MUST NOT run apply
TOTAL=$((TOTAL + 1))
if grep -qE "terraform apply" ".github/workflows/terraform-plan.yml"; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("terraform-plan must not run apply")
    echo "not ok $TOTAL - terraform-plan must not run apply"
else
    PASS=$((PASS + 1))
    echo "ok $TOTAL - terraform-plan does not run apply"
fi

# terraform-apply.yml — must be gated to main push + workflow_dispatch with environment
assert_grep "branches: \[main\]" ".github/workflows/terraform-apply.yml" "terraform-apply gated to main branch"
assert_grep "workflow_dispatch" ".github/workflows/terraform-apply.yml" "terraform-apply allows manual dispatch"
assert_grep "environment:" ".github/workflows/terraform-apply.yml" "terraform-apply uses environment protection"
assert_grep "callcenter-github-actions-tf-apply" ".github/workflows/terraform-apply.yml" "terraform-apply uses dedicated OIDC role"
assert_grep "terraform apply" ".github/workflows/terraform-apply.yml" "terraform-apply runs apply"

# PR template — must mention Mermaid for ADRs (project convention) + branch workflow
assert_grep "Mermaid" ".github/pull_request_template.md" "PR template enforces Mermaid for ADRs"
assert_grep "pytest" ".github/pull_request_template.md" "PR template has pytest checklist item"
assert_grep "terraform.*validate" ".github/pull_request_template.md" "PR template has terraform validate checklist item"

# Setup docs — must explain OIDC + environment protection
assert_grep "open-id-connect-provider" "docs/operations/github-actions-setup.md" "setup docs explain OIDC provider"
assert_grep "callcenter-github-actions-pr-review" "docs/operations/github-actions-setup.md" "setup docs define pr-review role"
assert_grep "callcenter-github-actions-tf-plan" "docs/operations/github-actions-setup.md" "setup docs define tf-plan role"
assert_grep "callcenter-github-actions-tf-apply" "docs/operations/github-actions-setup.md" "setup docs define tf-apply role"
assert_grep "Branch Protection" "docs/operations/github-actions-setup.md" "setup docs cover branch protection"

# Self-hosted runner labels — workflows must use call-center-admin-{arm,x86,claude-arm}
assert_grep "call-center-admin-claude-arm" ".github/workflows/pr-review.yml" "pr-review runs on claude-arm runner"
assert_grep "call-center-admin-arm" ".github/workflows/ci.yml" "ci runs on arm runner"
assert_grep "call-center-admin-x86" ".github/workflows/terraform-plan.yml" "terraform-plan runs on x86 runner"
assert_grep "call-center-admin-x86" ".github/workflows/terraform-apply.yml" "terraform-apply runs on x86 runner"
# Negative: no workflow should fall back to ubuntu-latest
TOTAL=$((TOTAL + 1))
if grep -qE "^\s*runs-on:\s*ubuntu" .github/workflows/*.yml; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("workflows must use self-hosted runners (not ubuntu-latest)")
    echo "not ok $TOTAL - workflows must use self-hosted runners (not ubuntu-latest)"
else
    PASS=$((PASS + 1))
    echo "ok $TOTAL - workflows use self-hosted runners (no ubuntu-latest fallback)"
fi
assert_grep "Self-hosted runners" "docs/operations/github-actions-setup.md" "setup docs cover self-hosted runner setup"
assert_grep "call-center-admin-claude-arm" "docs/operations/github-actions-setup.md" "setup docs document claude-arm runner"

# AWS_ACCOUNT_ID must be a repository VARIABLE (not secret), so workflows can graceful-skip
assert_grep "vars.AWS_ACCOUNT_ID" ".github/workflows/pr-review.yml" "pr-review uses vars.AWS_ACCOUNT_ID (graceful gate)"
assert_grep "vars.AWS_ACCOUNT_ID" ".github/workflows/terraform-plan.yml" "terraform-plan uses vars.AWS_ACCOUNT_ID"
assert_grep "vars.AWS_ACCOUNT_ID" ".github/workflows/terraform-apply.yml" "terraform-apply uses vars.AWS_ACCOUNT_ID"
# Negative: no workflow should fall back to secrets.AWS_ACCOUNT_ID
TOTAL=$((TOTAL + 1))
if grep -qE "secrets\.AWS_ACCOUNT_ID" .github/workflows/*.yml; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("workflows must use vars.AWS_ACCOUNT_ID not secrets")
    echo "not ok $TOTAL - workflows must use vars.AWS_ACCOUNT_ID not secrets"
else
    PASS=$((PASS + 1))
    echo "ok $TOTAL - workflows use vars.AWS_ACCOUNT_ID (no secrets fallback)"
fi

# setup-terraform must disable the node-based wrapper for self-hosted runner safety
assert_grep "terraform_wrapper: false" ".github/workflows/ci.yml" "ci disables setup-terraform node wrapper"
assert_grep "terraform_wrapper: false" ".github/workflows/terraform-plan.yml" "terraform-plan disables setup-terraform node wrapper"
assert_grep "terraform_wrapper: false" ".github/workflows/terraform-apply.yml" "terraform-apply disables setup-terraform node wrapper"

# Each AWS-using job must have if: vars.AWS_ACCOUNT_ID != '' graceful gate
assert_grep "if: vars.AWS_ACCOUNT_ID != ''" ".github/workflows/pr-review.yml" "pr-review job gated by vars.AWS_ACCOUNT_ID"
assert_grep "if: vars.AWS_ACCOUNT_ID != ''" ".github/workflows/terraform-plan.yml" "terraform-plan job gated by vars.AWS_ACCOUNT_ID"
assert_grep "if: vars.AWS_ACCOUNT_ID != ''" ".github/workflows/terraform-apply.yml" "terraform-apply job gated by vars.AWS_ACCOUNT_ID"
