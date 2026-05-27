# Atlantis Setup

본 문서는 `call-center-admin` 의 Terraform 배포 파이프를 [Atlantis](https://www.runatlantis.io/) 로 운영하기 위한 일회성 셋업을 정리합니다. Atlantis 서버는 별도 리포(`Atom-oh/AWS-Demo-Platform`) 의 EKS hub 클러스터에서 호스팅됩니다.

## 개요

| 항목 | 값 |
|---|---|
| Atlantis 서버 | `https://atlantis.atomai.click` |
| GitHub App | `atomoh-atlantis` (webhook 인증) |
| Repo allowlist | `github.com/Atom-oh/*` (이미 적용) |
| Atlantis IRSA | `AtlantisIRSARole` (AWS 계정 `180294183052`) |
| 본 리포 설정 | `atlantis.yaml` (저장소 루트) |
| tfstate 버킷 | `atom-oh-atlantis-tfstate-apne2` (ap-northeast-2, 공유) |
| tfstate lock | `atom-oh-atlantis-tfstate-locks-apne2` (DynamoDB, ap-northeast-2, 공유) |

## 통합 tfstate 정책

Atlantis 가 관리하는 신규 프로젝트들은 ap-northeast-2 의 단일 S3 버킷 `atom-oh-atlantis-tfstate-apne2` 를 공유합니다. 프로젝트별 격리는 **key prefix** 로 합니다:

| 프로젝트 | key prefix 예시 |
|---|---|
| call-center-admin | `call-center-admin/envs/dev.tfstate` |
| (향후 프로젝트) | `<project-slug>/<...>.tfstate` |

버킷은 `infra/shared-state/` 스택이 **Atlantis 를 통해 1회 부트스트랩** 합니다 (local state). 이후 모든 프로젝트가 이 버킷을 backend 로 사용.

> 참고: 기존 `multi-region-mall-terraform-state` 버킷 (us-east-1) 은 AWS-Demo-Platform 과 multi-region-architecture 가 계속 사용. 향후 같은 새 버킷으로 마이그레이션 가능 (별도 작업).

## 운영 흐름

1. PR을 열고 `infra/**` 를 변경 → Atlantis 가 자동으로 `terraform plan` 실행 후 PR 코멘트로 결과 게시.
2. PR 코멘트로 재실행:
   - `atlantis plan` — 전체 프로젝트 다시 plan
   - `atlantis plan -p dev` — `dev` 프로젝트만 plan
3. 검토 후 PR 코멘트로 적용:
   - `atlantis apply -p dev` — 승인된(reviewed) + mergeable 한 PR 에서만 가능 (`apply_requirements` 설정).
4. apply 성공 후 PR 머지.

`stg`/`prd` 환경은 `infra/envs/{stg,prd}/` 디렉터리를 생성한 시점에 `atlantis.yaml` 의 해당 블록 주석을 해제하면 활성화됩니다.

## IAM 사전 설정 (필수)

Atlantis pod 은 `AtlantisIRSARole` 로 동작하며, 본 리포의 Terraform 이 사용하는 IAM 역할을 직접 갖고 있지 않습니다. 두 가지 방법 중 하나를 선택합니다.

### 옵션 A — 기존 OIDC role 재사용 (권장)

`callcenter-github-actions-tf-plan` / `callcenter-github-actions-tf-apply-dev` 의 trust policy 에 `AtlantisIRSARole` 을 추가합니다:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": { ... 기존 조건 그대로 ... }
    },
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::180294183052:role/AtlantisIRSARole"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

이후 `infra/envs/dev/main.tf` 의 `provider "aws"` 에 `assume_role` 블록을 추가합니다:

```hcl
provider "aws" {
  region = "ap-northeast-2"
  assume_role {
    role_arn = "arn:aws:iam::<callcenter-account>:role/callcenter-github-actions-tf-apply-dev"
  }
  default_tags { ... }
}
```

`plan` 전용이면 `tf-plan` role, `apply` 전용이면 `tf-apply-dev` role 입니다. Atlantis 는 plan/apply 단계가 별도라 동일한 `apply` role 을 plan 에도 쓰면 단순합니다 (plan 권한이 read-only 인 한).

### 옵션 B — AtlantisIRSARole 정책 확장

`AtlantisIRSARole` 의 IAM policy 에 본 프로젝트가 다루는 리소스(Bedrock, Lambda, SFN, S3, DynamoDB, KMS, SQS, EventBridge, IAM 등)에 대한 권한을 직접 추가합니다. trust policy 수정 없이 끝나지만 권한이 한 role 에 집중되어 blast radius 가 커집니다.

옵션 A 가 권장됩니다.

## Branch protection

`main` 브랜치 보호 룰:

- Require pull request reviews before merging (>= 1 approver)
- Require status checks: `ci`, `atlantis/plan: dev`
- Require linear history (선택)
- Restrict who can push: 없음 (모두 PR 경유)

`atlantis.yaml` 의 `apply_requirements: [approved, mergeable]` 가 reviewer 승인 + mergeable 상태를 강제하므로, 위 status check 가 모두 green 인 PR 에서만 `atlantis apply` 가 동작합니다.

## 폐기된 워크플로

`.github/workflows/terraform-plan.yml` / `terraform-apply.yml` 은 본 변경에서 제거되었습니다. `docs/operations/github-actions-setup.md` 의 §1, §2 (OIDC provider + role) 는 여전히 본 문서의 옵션 A 에 필요합니다.

## 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| PR 에 `Ran Plan...` 코멘트가 안 옴 | webhook 미도달 | GitHub App `atomoh-atlantis` Installation 에 본 리포가 포함되어 있는지 확인 |
| `Error: No valid credential sources` | IAM 미설정 | 위 §IAM 사전 설정 옵션 A 또는 B 적용 |
| `Error: AccessDenied: ... not authorized to perform: sts:AssumeRole` | trust 누락 | 옵션 A의 trust statement 추가 확인 |
| plan 은 되는데 apply 가 실패 | apply role 권한 부족 | `tf-apply-dev` role 의 inline policy 에 누락 리소스 권한 추가 |
| `atlantis apply` 가 reject 됨 | `apply_requirements` 위반 | PR 이 approved 되었고 mergeable 한지 확인 |
