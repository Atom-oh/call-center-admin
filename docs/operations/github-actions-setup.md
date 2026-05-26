# GitHub Actions Setup (OIDC, Secrets, Environments)

본 문서는 `.github/workflows/` 의 4개 워크플로우를 처음 동작시키기 위해 AWS / GitHub 콘솔에서 한 번만 수행해야 하는 셋업을 정리한다.

## 0. 본 프로젝트의 자동화 개요

| 워크플로우 | 트리거 | 권한 | 비용 |
|------------|--------|------|------|
| `pr-review.yml` | `pull_request_target` | Bedrock InvokeModel (read-only) | Claude Opus 4.7 호출당 ~$0.05~0.50 |
| `ci.yml` | `pull_request`, `push:main`, `workflow_dispatch` | 없음 (GitHub-hosted runner) | 무료 (public)/ minute당 (private) |
| `terraform-plan.yml` | `pull_request` infra 변경 | AWS read-only | tfstate S3 GET + 짧은 plan 호출 |
| `terraform-apply.yml` | `push:main` infra 변경 + `workflow_dispatch` | AWS Terraform apply | apply 결과에 따라 |

## 1. AWS Identity Provider (한 번만)

각 AWS 계정 (dev/stg/prd) 에 GitHub OIDC provider를 생성:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --tags Key=project,Value=callcenter-classification
```

## 2. IAM Roles (계정별, 한 번만)

세 개 role 필요. 각 role 의 trust policy 는 본 저장소(`Atom-oh/call-center-admin`) 의 특정 이벤트만 허용.

### 2.1 `callcenter-github-actions-pr-review`

목적: PR 리뷰 워크플로우의 Bedrock InvokeModel.

**Trust policy**:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:Atom-oh/call-center-admin:pull_request"
      }
    }
  }]
}
```

**Permission policy** (inline):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["bedrock:InvokeModel"],
    "Resource": "arn:aws:bedrock:ap-northeast-2::foundation-model/anthropic.claude-opus-4-*"
  }]
}
```

### 2.2 `callcenter-github-actions-tf-plan`

목적: PR 단계에서 `terraform plan` (read-only).

**Trust policy**: 위와 동일 패턴, sub = `repo:Atom-oh/call-center-admin:pull_request`.

**Permission policy**: `ReadOnlyAccess` AWS managed policy + tfstate S3 GetObject (DDB lock GetItem). 권장:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*",
      "Condition": { "Bool": { "aws:ViaAWSService": "false" } },
      "NotAction": [
        "s3:DeleteObject", "s3:PutObject",
        "dynamodb:DeleteItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
        "ec2:*Create*", "ec2:*Delete*", "ec2:*Modify*",
        "lambda:Create*", "lambda:Delete*", "lambda:Update*", "lambda:Publish*",
        "iam:Create*", "iam:Delete*", "iam:Attach*", "iam:Detach*", "iam:Put*",
        "kms:Create*", "kms:Delete*", "kms:Schedule*",
        "states:Create*", "states:Delete*", "states:Update*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::kakaopay-callcenter-tfstate", "arn:aws:s3:::kakaopay-callcenter-tfstate/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:ap-northeast-2:ACCOUNT:table/kakaopay-callcenter-tflock"
    }
  ]
}
```

> NOTE: `terraform plan` 은 lock 을 잡았다 풀기 때문에 DDB PutItem/DeleteItem 까지 허용해야 한다.

### 2.3 `callcenter-github-actions-tf-apply-{dev,stg,prd}`

목적: main 머지/`workflow_dispatch` 후 `terraform apply`. 환경별로 분리해 prd 키를 dev workflow가 잡지 못하도록.

**Trust policy** (dev 예시):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::ACCOUNT_DEV:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:Atom-oh/call-center-admin:environment:dev"
      }
    }
  }]
}
```

stg / prd 는 `sub` 의 `environment:dev` 를 `environment:stg` / `environment:prd` 로 교체.

**Permission policy**: 본 프로젝트가 사용하는 AWS 리소스 종류 (VPC + S3 + KMS + DynamoDB + Lambda + IAM + SFN + EventBridge + SQS + Firehose + Glue + Athena + Cognito + Fargate + Bedrock invoke) 에 대한 CRUD. 운영 안정화 시점에 좁혀 나갈 예정.

## 3. GitHub Secrets (organization 또는 repo level)

| Secret | 용도 | 권장 scope |
|--------|------|-----------|
| `AWS_ACCOUNT_ID` | OIDC role ARN 조립용 | repo |

> 본 셋업은 정적 AWS 키를 사용하지 않는다. 모든 권한은 OIDC role 로만 부여된다.

> Slack webhook 같은 운영 알림용 secret 은 PR9에서 `secretsmanager` 로 옮기고 GH secret 사용 안 함.

## 4. GitHub Environments (보호 룰)

GitHub → Settings → Environments 에서 다음 3개 environment 생성:

| Environment | Protection rule | Reviewers |
|-------------|----------------|----------|
| `dev` | required reviewers = 0 (자동 머지 OK) | — |
| `stg` | required reviewers = 1 (PR 머지 1명) | 분석팀 + 운영팀 그룹 |
| `prd` | required reviewers = 2 (대기 5분) | 분석팀 + 운영팀 + 보안팀 |

`environment` 보호 룰이 `terraform-apply.yml` 의 `environment: ${{ inputs.environment }}` 에 적용되어 manual approval 게이트가 된다.

## 5. Branch Protection Rule

GitHub → Settings → Branches → `main` 에 다음 룰 추가:

- [x] Require pull request reviews before merging — at least 1
- [x] Require status checks to pass before merging
  - 필수 checks: `Python — lint, mypy, pytest`, `Terraform — fmt + validate (offline)`, `terraform plan — dev`
- [x] Require branches to be up to date before merging
- [x] Include administrators (no bypass)
- [x] Restrict pushes — main 으로 직접 push 금지 (PR only)

## 6. 첫 PR 으로 동작 확인

1. 본 PR (`feat/github-actions-workflow`) 머지 후 모든 룰이 활성화됨
2. 다음 변경부터는 반드시 새 브랜치 → PR → CI 통과 → Claude 리뷰 코멘트 → terraform plan 코멘트 → 사람 리뷰어 승인 → main 머지 → terraform apply (dev 자동, stg/prd 수동)

## 7. 트러블슈팅

| 증상 | 가능 원인 | 조치 |
|------|----------|------|
| PR review 워크플로우 `AccessDeniedException` from Bedrock | OIDC role policy 에 `bedrock:InvokeModel` 누락 또는 ARN 패턴 불일치 | role policy 의 Bedrock model ARN 패턴 확인 |
| terraform plan `Error acquiring the state lock` | 이전 plan/apply 가 lock 을 풀지 않음 | DDB `kakaopay-callcenter-tflock` 의 LockID 항목 수동 삭제 |
| Claude 리뷰가 truncated 메시지로 끝남 | diff 가 3000줄 초과 | `MAX_LINES` 조정 (워크플로우) 또는 PR 분할 |
| terraform apply 가 `environment: prd` 에서 대기 | reviewer 승인 대기 | GitHub UI 에서 해당 환경 reviewer 가 승인 |
| Bedrock `ThrottlingException` | 동시 호출이 쿼터 초과 | docs/runbooks/bedrock-throttling.md 참조 (PR10에서 작성 예정) |
