# Code Review Skill

Review changed code with confidence-based scoring to filter false positives. Adapted for the call-center-admin stack (Python 3.12 + Bedrock + Terraform AWS).

## Review Scope

By default, review unstaged changes from `git diff`. The user may specify different files or scope.

## Review Criteria

### Project Guidelines Compliance (CLAUDE.md)
- `from __future__ import annotations` 일관성, PEP 604 union 사용
- xlsx 분류 코드 typo (`NONEY`, `PAYNENT`) 보존 — 절대 "수정" 금지
- `\b` 한글 boundary 회피 패턴 (`(?<!\d)/(?!\d)`)
- Lambda handler module-level adapter 캐시 + `sys.path.insert` 패턴
- Terraform: KMS 데이터 클래스별 분리, S3 lifecycle `filter {}` 명시, GSI 이름·attribute 이름 일치
- DDB attribute 한국어 (`category_대code`) 허용
- per-Lambda staging-dir 패키징 패턴 준수

### Bug Detection
- Bedrock Converse API의 정확한 `cachePoint` 형식
- moto S3 SSE-KMS 한계와 실제 동작 차이
- Step Functions Express payload 256KB 한도, ResultPath/OutputPath 데이터 흐름
- DDB ConditionalCheckFailedException 처리
- KMS Resource scope ("*" vs 특정 ARN)
- PII 누설 (`reason`, `alternativesConsidered.why_rejected`에 정규식 sweep 적용 여부)
- IAM least-privilege (특히 Bedrock model ARN 패턴, log group ARN scope)

### Code Quality
- 모듈 책임 분리: pure helper vs side-effect handler
- pytest `sys.modules.pop` fixture (module-level adapter 캐시 우회)
- moto `mock_aws` decorator + boto3 client patch 일관성
- Terraform 모듈 input의 사용 여부 (reserved comment 또는 실제 wiring)
- 합성 PII 출력 (모델이 만든 예시 전화번호 등) 방지

## Confidence Scoring

각 이슈를 0-100으로 평가:
- **0-24**: false positive 또는 사전 존재 이슈 가능성. 미보고.
- **25-49**: 실재할 수도 있으나 trivial. 미보고.
- **50-74**: 실제 이슈, minor. critical 시에만 보고.
- **75-89**: 검증된 실제 이슈, important. fix 제안과 함께 보고.
- **90-100**: 확정된 critical. 반드시 보고.

**confidence ≥ 75만 보고.**

## Output Format

각 이슈마다:
### [CRITICAL|IMPORTANT] <issue title> (confidence: XX)
**File:** `path/to/file.ext:line`
**Issue:** 명확한 문제 설명
**Guideline:** CLAUDE.md 룰 또는 보안 표준 참조
**Fix:** 구체적인 코드 제안

이슈가 없으면 표준 충족 확인 + 1줄 요약.
