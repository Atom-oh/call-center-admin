# GitHub Actions + Atlantis workflow validation.
#
# Terraform plan/apply 는 .github/workflows/ 가 아닌 **Atlantis** (<INFRA_REPO> repo
# 의 EKS hub cluster) 가 처리한다. 본 repo 에는 그래서 `atlantis.yaml` 만 있고
# .github/workflows/terraform-{plan,apply}.yml 은 존재하지 않는다.

assert_file_exists ".github/workflows/pr-review.yml"
assert_file_exists ".github/workflows/ci.yml"
assert_file_exists ".github/pull_request_template.md"
assert_file_exists "docs/operations/github-actions-setup.md"
assert_file_exists "atlantis.yaml"

# Negative: terraform-{plan,apply}.yml 은 제거되어야 (Atlantis 가 대체).
TOTAL=$((TOTAL + 1))
if [ -f ".github/workflows/terraform-plan.yml" ] || [ -f ".github/workflows/terraform-apply.yml" ]; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("terraform-{plan,apply}.yml 은 Atlantis 로 대체되어 제거되어야 한다")
    echo "not ok $TOTAL - terraform GitHub Actions removed (Atlantis takes over)"
else
    PASS=$((PASS + 1))
    echo "ok $TOTAL - terraform GitHub Actions removed (Atlantis takes over)"
fi

# atlantis.yaml — repo-level project config
assert_grep "^version: 3" "atlantis.yaml" "atlantis.yaml is v3 schema"
assert_grep "automerge: false" "atlantis.yaml" "atlantis automerge disabled — human merges"
assert_grep "dir: infra/envs/dev" "atlantis.yaml" "atlantis maps dev project to infra/envs/dev"
assert_grep "apply_requirements" "atlantis.yaml" "atlantis enforces approval + mergeable"
assert_grep "approved" "atlantis.yaml" "atlantis requires PR approval before apply"
assert_grep "mergeable" "atlantis.yaml" "atlantis requires PR to be mergeable before apply"

# pr-review.yml — uses pull_request_target + Bedrock Claude + diff filter
assert_grep "pull_request_target" ".github/workflows/pr-review.yml" "pr-review uses pull_request_target trigger"
assert_grep "CLAUDE_CODE_USE_BEDROCK" ".github/workflows/pr-review.yml" "pr-review uses Bedrock backend"
assert_grep "ANTHROPIC_BEDROCK_BASE_URL" ".github/workflows/pr-review.yml" "pr-review sets Bedrock base URL"
assert_grep "global.anthropic.claude-opus-4-8" ".github/workflows/pr-review.yml" "pr-review uses global cross-region inference profile"
assert_grep "taxonomy_tree" ".github/workflows/pr-review.yml" "pr-review filters generated taxonomy artifacts"
assert_grep "claude -p" ".github/workflows/pr-review.yml" "pr-review invokes claude CLI with -p (system prompt)"
assert_grep "output-format text" ".github/workflows/pr-review.yml" "pr-review uses output-format text (not json)"
assert_grep "VERDICT: " ".github/workflows/pr-review.yml" "pr-review has VERDICT-based gate"
assert_grep "callcenter-pr-review" ".github/workflows/pr-review.yml" "pr-review uses comment marker for upsert"
# Negative: pr-review should NOT use OIDC configure-aws-credentials (Instance Profile pattern)
TOTAL=$((TOTAL + 1))
if grep -qE "aws-actions/configure-aws-credentials" .github/workflows/pr-review.yml; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("pr-review must use Instance Profile, not OIDC")
    echo "not ok $TOTAL - pr-review must use Instance Profile, not OIDC"
else
    PASS=$((PASS + 1))
    echo "ok $TOTAL - pr-review uses runner Instance Profile (no OIDC step)"
fi

# ci.yml — runs pytest + terraform validate, gated by path filters
assert_grep "dorny/paths-filter" ".github/workflows/ci.yml" "ci uses paths-filter"
assert_grep "ruff check" ".github/workflows/ci.yml" "ci runs ruff check"
assert_grep "mypy src" ".github/workflows/ci.yml" "ci runs mypy"
assert_grep "pytest" ".github/workflows/ci.yml" "ci runs pytest"
assert_grep "terraform fmt -recursive -check" ".github/workflows/ci.yml" "ci runs terraform fmt check"
assert_grep "terraform.*validate" ".github/workflows/ci.yml" "ci runs terraform validate"

# PR template — must mention Mermaid for ADRs (project convention)
assert_grep "Mermaid" ".github/pull_request_template.md" "PR template enforces Mermaid for ADRs"
assert_grep "pytest" ".github/pull_request_template.md" "PR template has pytest checklist item"
assert_grep "terraform.*validate" ".github/pull_request_template.md" "PR template has terraform validate checklist item"

# Self-hosted runner labels
assert_grep "call-center-admin-claude-arm" ".github/workflows/pr-review.yml" "pr-review runs on claude-arm runner"
assert_grep "call-center-admin-arm" ".github/workflows/ci.yml" "ci runs on arm runner"
# Negative: no remaining workflow should fall back to ubuntu-latest
TOTAL=$((TOTAL + 1))
if grep -qE "^\s*runs-on:\s*ubuntu" .github/workflows/*.yml; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("workflows must use self-hosted runners (not ubuntu-latest)")
    echo "not ok $TOTAL - workflows must use self-hosted runners (not ubuntu-latest)"
else
    PASS=$((PASS + 1))
    echo "ok $TOTAL - workflows use self-hosted runners (no ubuntu-latest fallback)"
fi

# setup-terraform must disable the node-based wrapper for self-hosted runner safety
assert_grep "terraform_wrapper: false" ".github/workflows/ci.yml" "ci disables setup-terraform node wrapper"

# Setup docs — explain Atlantis flow (new) + Self-hosted runners (kept)
assert_file_exists "docs/operations/atlantis-setup.md"
assert_grep "Atlantis" "docs/operations/github-actions-setup.md" "github-actions-setup notes Atlantis migration"
assert_grep "atlantis-setup" "docs/operations/github-actions-setup.md" "github-actions-setup links to atlantis-setup.md"
assert_grep "<ATLANTIS_IRSA_ROLE>" "docs/operations/atlantis-setup.md" "atlantis-setup names the IRSA role"
assert_grep "AssumeRole" "docs/operations/atlantis-setup.md" "atlantis-setup documents the AssumeRole / IAM chain"
assert_grep "atlantis plan" "docs/operations/atlantis-setup.md" "atlantis-setup documents the plan command"
assert_grep "atlantis apply" "docs/operations/atlantis-setup.md" "atlantis-setup documents the apply command"
assert_grep "Self-hosted runners" "docs/operations/github-actions-setup.md" "setup docs cover self-hosted runner setup"
assert_grep "call-center-admin-claude-arm" "docs/operations/github-actions-setup.md" "setup docs document claude-arm runner"
