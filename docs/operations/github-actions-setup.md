# GitHub Actions Setup (OIDC, Secrets, Environments)

본 문서는 `.github/workflows/` 의 4개 워크플로우를 처음 동작시키기 위해 AWS / GitHub 콘솔에서 한 번만 수행해야 하는 셋업을 정리한다.

## 0. 본 프로젝트의 자동화 개요

| 워크플로우 | 트리거 | runs-on | 권한 | 비용 |
|------------|--------|---------|------|------|
| `pr-review.yml` | `pull_request_target` | `call-center-admin-claude-arm` | Bedrock InvokeModel (read-only) | Claude Opus 4.7 호출당 ~$0.05~0.50 |
| `ci.yml` | `pull_request`, `push:main`, `workflow_dispatch` | `call-center-admin-arm` | 없음 | 러너 시간 |
| `terraform-plan.yml` | `pull_request` infra 변경 | `call-center-admin-x86` | AWS read-only | tfstate S3 GET + 짧은 plan 호출 |
| `terraform-apply.yml` | `push:main` infra 변경 + `workflow_dispatch` | `call-center-admin-x86` | AWS Terraform apply | apply 결과에 따라 |

> **Self-hosted runners**: 본 프로젝트는 aws-fsi-demo와 동일한 self-hosted runner 명명 컨벤션을 사용합니다 (`call-center-admin-{arm,x86,claude-arm}`). 러너 셋업 전에는 워크플로우가 큐에 머물고 실행되지 않으므로 §3.5 의 러너 셋업을 먼저 완료해야 합니다.

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

## 2.5 Self-hosted runners (필수)

본 프로젝트는 GitHub-hosted 러너 대신 EC2 기반 self-hosted runner 3종을 사용한다 (aws-fsi-demo 컨벤션 동일):

| 러너 라벨 | 인스턴스 타입 | 용도 | pre-install |
|-----------|---------------|------|------------|
| `call-center-admin-arm` | Graviton (c7g.medium 이상) | CI: Python lint/test + Terraform validate | Python 3.12, Node 20, Terraform 1.9 |
| `call-center-admin-x86` | x86 (c7i.medium 이상) | Terraform plan/apply | Terraform 1.9, AWS CLI v2 |
| `call-center-admin-claude-arm` | Graviton (c7g.large 이상) | PR 자동 리뷰 | Node 20, `@anthropic-ai/claude-code` 글로벌 |

### 등록 절차

1. **EC2 인스턴스 부팅** — Amazon Linux 2023 ARM/x86 기반. EBS gp3 30GB. SSM Agent 활성 (콘솔 접근 + patching).
2. **IAM Instance Profile** 부여 — `callcenter-runner-instance` role. 권한:
   - `bedrock:InvokeModel` (claude-arm 만; `anthropic.claude-opus-4-*` ARN 패턴)
   - `s3:GetObject` on tfstate 버킷 (x86 만)
   - `ssm:UpdateInstanceInformation` (모든 러너, SSM 관리용)
3. **GitHub Actions Runner 등록** — `gh actions-runner` 또는 Terraform `aws_codebuild` / `ec2-github-runner` 모듈:
   ```bash
   # 토큰은 Settings > Actions > Runners > New self-hosted runner 에서 발급
   ./config.sh --url https://github.com/Atom-oh/call-center-admin \
       --token <TOKEN> \
       --labels call-center-admin-arm \
       --unattended --replace
   sudo ./svc.sh install
   sudo ./svc.sh start
   ```
4. **사전 설치 확인**:
   ```bash
   # arm 러너
   python3 --version    # 3.12.x
   terraform --version  # 1.9.x
   node --version       # v20.x

   # claude-arm 러너 (위 + 다음)
   claude --version     # @anthropic-ai/claude-code 글로벌 설치
   ```
5. **scaling 전략**: 처음에는 라벨당 1대 고정. PR 동시성이 늘면 라벨당 2-3대로 확장. ASG + `philips-labs/terraform-aws-github-runner` 같은 모듈로 ephemeral 러너 자동화 가능.

### Bedrock 호출 (claude-arm 러너)

`pr-review.yml` 의 `claude --print --output-format=json` 호출은 `CLAUDE_CODE_USE_BEDROCK=1` 환경변수에 따라 Anthropic API 대신 Bedrock 을 사용한다. **러너 IAM Instance Profile** 만으로도 동작하지만, 워크플로우는 명시적으로 OIDC role (`callcenter-github-actions-pr-review`) 을 assume 하여 호출함. 두 권한 중 하나라도 `bedrock:InvokeModel` 을 가지면 충분.

## 3. GitHub Variables (organization 또는 repo level)

| Variable | 용도 | 권장 scope |
|----------|------|-----------|
| `AWS_ACCOUNT_ID` | OIDC role ARN 조립용 | repo |

> **Secret 이 아닌 Variable 로 등록** 합니다 (계정 번호는 credential-grade 가 아니며, 워크플로우의 `if:` 조건에서 `vars.AWS_ACCOUNT_ID != ''` 으로 graceful gate 적용을 위해 `vars` context 가 필요). GitHub UI 에서 Settings → Secrets and variables → Actions → **Variables 탭** 에서 추가.
>
> 본 셋업은 정적 AWS 키를 사용하지 않는다. 모든 권한은 OIDC role 로만 부여된다.
>
> **셋업 전 동작**: 모든 워크플로우 job 에 `if: vars.AWS_ACCOUNT_ID != ''` 가 있어 변수 미설정 시 graceful skip 한다. 셋업 완료 후부터 실제 실행.

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
