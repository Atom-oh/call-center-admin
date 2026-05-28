# Runbook — HITL 검토 대기열 적체

알람: `callcenter-${env}-hitl-backlog` (60분 지속 > 100)
관련 ADR: ADR-007 (HITL outside SFN), spec PR8 §2.1

## 증상

- Slack 에 `callcenter-${env}-hitl-backlog` 알람 도착
- 검토 큐 페이지에 `hitl-pending` 행이 계속 누적
- 분석팀이 BI 대시보드에서 `status=hitl-pending` 비율 증가 관측

## 진단

```bash
ENV=${ENV:-dev}
# 1) 큐 깊이 (status-classifiedAt-index GSI 활용)
aws dynamodb query --table-name callcenter-${ENV}-consult-results \
  --index-name status-classifiedAt-index \
  --key-condition-expression "#s = :p" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":p":{"S":"hitl-pending"}}' \
  --select COUNT

# 2) 최근 confidence 분포 (HITL 트리거 = confidence < 0.85)
aws dynamodb scan --table-name callcenter-${ENV}-consult-results \
  --filter-expression "#s = :p" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":p":{"S":"hitl-pending"}}' \
  --projection-expression "confidence" --max-items 50

# 3) HITL 처리율 (corrected + skipped 합계)
aws cloudwatch get-metric-statistics --namespace callcenter/classification \
  --metric-name classification.hitlCorrected \
  --start-time $(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Sum
```

## 즉시 대응 (10분 안)

1. **운영팀 추가 인력 투입 요청** — Slack 채널 `#callcenter-ops` 핑
2. **분류 confidence 임계 임시 상향** — 0.85 → 0.75 로 환경변수 override (Lambda config):
   ```bash
   aws lambda update-function-configuration \
     --function-name callcenter-${ENV}-classify \
     --environment Variables={CONFIDENCE_THRESHOLD=0.75,...}
   ```
   주의: 정확도 ↓ trade-off. 24시간 안에 원복.
3. **dashboard 검토** — `callcenter-${ENV}` 의 "평균 confidence" 위젯이 동시 하락하면 모델 회귀 가능성

## 영구 해결 (1~3일)

1. **골든셋 라벨 확대** — 분석팀에 50~100건 추가 라벨링 요청
2. **프롬프트 v1.1 release** — 자주 mis-classify 되는 카테고리 (HITL 큐에서 가장 많은 카테고리) 를 system_rules.md 에 명시적 hint 로 추가
3. **HITL UI 의 cascade selectbox 개선** — 운영팀 평균 처리 시간 단축 (PR8 후속)
4. **`PROMPT_VERSION` bump** — 새 디렉토리 `src/prompts/v1.1/` 추가 후 deploy

## 회복 후 / 회귀 원인 분석

- 큐 처리 완료 후: 처리된 corrected 행의 카테고리 분포 분석 → 어느 카테고리가 모델에 어려운지 보고
- Phase 3 ML cascade (KLUE-BERT) 진입 조건 충족 시 (HITL real label 500+) trigger
- 알람 threshold 100 이 적절한지 재검토 (운영 부하에 비해 too sensitive / too lax)
