---
description: Build Lambda zips and deploy to AWS following dev/stg/prd promotion runbook
allowed-tools: Read, Bash(terraform fmt:*), Bash(terraform validate:*), Bash(terraform plan:*), Bash(terraform apply:*), Bash(git status:*), Bash(git log:*), Glob
---

# Deploy

Phase 1 의 환경 배포. **사용자 명시 승인 후에만 `terraform apply`**.

## Step 1: Pre-Deploy Checks

1. 워킹 트리 클린: `git status`
2. main 브랜치 확인: `git branch --show-current`
3. 단위 테스트 통과: `pytest --no-cov`
4. terraform fmt/validate 통과
5. 환경 인자 확인: $ARGUMENTS 가 `dev`, `stg`, `prd` 중 하나여야 함

## Step 2: Bedrock + 컴플라이언스 게이트 (prd 한정)

prd 배포 전:
- 사내 컴플라이언스: "Raw STT 외부 송신 (Bedrock 호출)" 허용 확인 (spec §10)
- Bedrock 서울 리전 쿼터: Opus 4.7 RPM 60+, Sonnet 4.6 RPM 30+
- Slack webhook URL이 Secrets Manager에 등록되어 있는지: `aws secretsmanager describe-secret --secret-id callcenter-prd-slack-webhook`

## Step 3: Apply

dev:
```bash
terraform -chdir=infra/envs/dev plan -out=tf.plan
# 사용자 plan 검토 + 승인 후
terraform -chdir=infra/envs/dev apply tf.plan
```

stg/prd:
```bash
terraform -chdir=infra/envs/$ENV plan -out=tf.plan
# 사용자 승인 후
terraform -chdir=infra/envs/$ENV apply tf.plan
```

## Step 4: Verify

apply 후:
- Lambda 함수 모두 ACTIVE: `aws lambda list-functions --query 'Functions[?starts_with(FunctionName, \`callcenter-$ENV-\`)].[FunctionName,State]' --output table`
- SFN state machine 활성: `aws stepfunctions describe-state-machine --state-machine-arn $(terraform -chdir=infra/envs/$ENV output -raw sfn_arn)`
- EventBridge rule 활성: `aws events describe-rule --name callcenter-$ENV-raw-put`
- E2E smoke (1건 STT JSON 업로드 → SFN 실행 → DDB record 확인)

## Step 5: Summary

- 무엇이 어디에 배포되었는지
- 사용된 방법 (Terraform workspace, Lambda runtime)
- 검증 결과
- 운영 런북 위치 (`docs/runbooks/`)

## Error Recovery

### pre-deploy 실패
- `git stash` → main 체크아웃 → 재시도
- terraform validate 실패 시 → `init -backend=false -reconfigure` 후 재검증

### apply 실패
- IAM 권한 부족: 본 프로젝트 deploy는 OIDC role 사용 — role policy에 필요한 액션 누락 의심
- Bedrock 쿼터 초과: Service Quotas 콘솔에서 상향 요청 + 임시 `aws lambda put-function-concurrency` 로 동시성 제한
- KMS 키 정책 충돌: PR2의 별도 CMK 4개가 각자 사용자 IAM 매핑되었는지

### prd 잘못 배포된 경우 — 롤백
```bash
# Lambda 코드 zip 롤백 (이전 버전으로):
terraform -chdir=infra/envs/prd apply -target=aws_lambda_function.<name> -var "<name>_zip=<previous-version-zip>"

# 또는 Terraform state 자체를 이전 커밋으로:
git checkout <previous-sha>
terraform -chdir=infra/envs/prd apply
git checkout main
```

### SFN 실행이 DLQ로 가는 경우
- `aws sqs receive-message --queue-url $(terraform output -raw classify_dlq_url)` 로 메시지 검사
- `docs/runbooks/bedrock-throttling.md`, `docs/runbooks/prompt-rollback.md` 참고
