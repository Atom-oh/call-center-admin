# Runbook — Bedrock Throttling

알람: `callcenter-${env}-bedrock-throttle`
관련 ADR: ADR-001 (InferenceAdapter), ADR-002 (prompt cache), ADR-010 (global CRIS)

## 증상

- Slack 에 `callcenter-${env}-bedrock-throttle` 알람 도착 (classify Lambda Errors > 10 / 1m)
- 사용자 보고: 분류 완료까지 시간 지연
- CloudWatch dashboard `callcenter-${env}` 의 "Lambda Errors (4 functions)" 위젯에서 classify 함수만 spike

## 진단

```bash
# 1) 실패 패턴 확인 — Bedrock 응답 코드 분포
ENV=${ENV:-dev}
aws logs filter-log-events \
  --log-group-name /aws/lambda/callcenter-${ENV}-classify \
  --start-time $(date -d "10 minutes ago" +%s)000 \
  --filter-pattern "Throttling OR ServiceUnavailable" \
  --max-items 50

# 2) SFN execution 통계 (성공/실패 비율)
SFN_ARN=$(terraform -chdir=infra/envs/${ENV} output -raw sfn_arn)
aws stepfunctions list-executions \
  --state-machine-arn ${SFN_ARN} \
  --status-filter FAILED --max-results 20

# 3) Bedrock 호출 빈도
aws cloudwatch get-metric-statistics \
  --namespace AWS/Bedrock \
  --metric-name InvocationThrottles \
  --start-time $(date -u -d "30 minutes ago" +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Sum
```

## 즉시 대응 (10분 안)

1. **SFN execution 일시 중단** — 증상 확산 차단:
   ```bash
   aws events disable-rule --name $(terraform -chdir=infra/envs/${ENV} output -raw sfn_name)-trigger 2>/dev/null || \
   aws events list-rules --query 'Rules[?contains(Name,`callcenter-'${ENV}'`)].Name' --output text
   # 식별된 rule 을 disable
   ```
2. **Bedrock 한도 임시 상향 요청** — Support case (Service Quota: `Anthropic Claude Opus 4` Tokens/min)
3. **DLQ 누적 확인 + Slack 보고** — 운영팀 인지

## 영구 해결 (1~3일)

1. **Provisioned Throughput** 신청 (commit 모델) — Phase 2 cost/SLA trade-off 검토
2. **global. CRIS 라우팅 검증** — ADR-010: 특정 리전 capacity 부족 시 다른 리전으로 자동 fallback 동작 확인
3. **prompt cache hit rate 검증** — ADR-002: 2 cache breakpoint 가 정상 작동하면 input token 비용 ↓ → 분당 request 수 감소 가능

## 회복 후 / 회귀 원인 분석

- CW Logs Insights:
  ```
  fields @timestamp, @message
  | filter @message like /Throttling/
  | stats count() by bin(5m)
  ```
- Slack alert 도착 → 5분 안에 진단 진입한 비율 측정 (운영 SLO)
- 동일 패턴 반복 시 Phase 2 진입 검토
