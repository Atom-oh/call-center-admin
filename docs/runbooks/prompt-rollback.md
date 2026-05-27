# Runbook — Prompt 버전 rollback

관련 ADR: ADR-002 (prompt cache), ADR-004 (xlsx code 보존)

## 증상

- CI eval-prompt job 의 `tests/golden/eval-history.csv` 마지막 row 의 accuracy 가 직전 row 대비 **-2%p 이하** 감소
- 사용자 보고: 특정 카테고리 (예: 송금) 의 분류 정확도 체감 저하
- HITL 큐의 corrected 행 비율이 base 대비 ↑

## 진단

```bash
ENV=${ENV:-dev}
# 1) eval-history 분석
tail -5 tests/golden/eval-history.csv
# (가장 최근 row 가 이전보다 정확도 낮으면 회귀)

# 2) 현재 PROMPT_VERSION 확인
aws lambda get-function-configuration \
  --function-name callcenter-${ENV}-classify \
  --query 'Environment.Variables.PROMPT_DIR'

# 3) 회귀 카테고리 식별 — eval-prompt 의 detailed output (per-row)
python scripts/eval_prompt.py --skip-tbd --output /tmp/eval.json
jq '.[] | select(.match==false)' /tmp/eval.json
```

## 즉시 대응 (10분 안)

1. **이전 PROMPT_VERSION 으로 rollback** — `src/prompts/v<N-1>/` 디렉토리는 항상 보존:
   ```bash
   # Lambda 환경변수 PROMPT_DIR 만 변경 (Lambda 재배포 없이 즉시 효과)
   aws lambda update-function-configuration \
     --function-name callcenter-${ENV}-classify \
     --environment Variables="{PROMPT_DIR=/var/task/prompts/v1.0,MODEL_ID=global.anthropic.claude-opus-4-7,...}"
   ```
   **주의**: 환경변수 override 시 기존 env 모두 명시해야 (AWS API 가 전체 set 으로 처리)
2. **prompt cache invalidation 대기** — ADR-002: 새 system block hash → 5분 안에 자동 갱신
3. **Slack 보고** — `#callcenter-ops` 에 rollback 사유 + version

## 영구 해결 (1~3일)

1. **bisect 로 회귀 룰 식별** — 새 PR 의 system_rules.md diff 를 작은 단위로 분할 → 각각 골든셋 평가 → 회귀 유발 룰 격리
2. **ADR-004 보존 검증** — 새 룰이 NONEY/PAYNENT 같은 xlsx code 식별자를 "fix" 하지 않았는지 확인 (다운스트림 mismatch 위험)
3. **새 prompt v<N+1>** 작성, 회귀 회피 + 원래 의도 모두 충족하도록
4. **`PROMPT_VERSION` bump** — `src/lib/prompts.py` 의 상수 + 새 디렉토리

## 회복 후 / 회귀 원인 분석

- ADR-002 의 2-breakpoint 구조가 새 룰 적용 시점에 cache miss → 비용 증가 확인 (Bedrock 청구 검토)
- 회귀가 system_rules vs taxonomy 분리 (breakpoint 단위) 와 일치하는지 — 일치하면 cache split 재고
- `docs/decisions/ADR-NNN-prompt-revision-policy.md` 신규 ADR 작성 검토
