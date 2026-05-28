# Runbook — PII 마스킹 회귀 / 누설

관련 ADR: ADR-003 (3-layer PII guard), G2 (EMF leak prevention)

## 증상

- `pii.maskApplied` 메트릭 급감 — 정상 트래픽 대비 평소의 < 10%
- 또는 CloudTrail 감사 (compliance 페이지 다운로드 후) 에서 reason 컬럼에 PII 잔존 발견
- 운영팀이 HITL UI 의 reason 필드에서 휴대폰/계좌번호 patterns 발견

## 진단

```bash
ENV=${ENV:-dev}
# 1) 최근 1시간 pii.maskApplied per-type emit 비율
aws cloudwatch get-metric-statistics --namespace callcenter/classification \
  --metric-name pii.maskApplied --dimensions Name=env,Value=${ENV} Name=pii_type,Value=phone \
  --start-time $(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Sum

# 2) reason 필드에 PII patterns 있는 row 검색 (DDB scan — 비용 주의)
aws dynamodb scan --table-name callcenter-${ENV}-consult-results \
  --filter-expression "contains(#r, :hyphen)" \
  --expression-attribute-names '{"#r":"reason"}' \
  --expression-attribute-values '{":hyphen":{"S":"-"}}' \
  --projection-expression "callId, #r" --max-items 10
# (`010-` 같은 패턴이 reason 에 있으면 Layer-3 sweep 실패)

# 3) 정규식 회귀 테스트 실행
pytest tests/unit/test_pii_regex.py -v
```

## 즉시 대응 (10분 안)

1. **S3 raw → masked 마스킹 결과 sample 확인** — 정규식 패턴이 작동하는지:
   ```bash
   RAW_KEY=$(aws s3api list-objects-v2 --bucket callcenter-${ENV}-stt-raw \
     --max-items 1 --query 'Contents[0].Key' --output text)
   aws s3 cp s3://callcenter-${ENV}-stt-raw/${RAW_KEY} /tmp/raw.json
   # masked 측 동일 경로 확인
   ```
2. **SFN 일시 중단** (PII 가 DDB 에 추가 누설 차단):
   ```bash
   aws events disable-rule --name callcenter-${ENV}-stt-trigger
   ```
3. **Slack 보고** — `#callcenter-compliance` 채널 + Legal 인지

## 영구 해결 (1~3일)

1. **정규식 패턴 보강** — 새 PII format 감지 시 `src/lib/pii_regex.py` 업데이트 + 회귀 테스트 (예: `test_card_not_over_eaten_when_preceded_by_short_digit` 패턴 따라)
2. **Layer-3 sweep 검증** — `src/lib/persistence.py:sanitize_text` 가 동일 정규식 사용하는지 확인 (drift 제거)
3. **Phase 2 진입 검토** — 정규식 한계 도달 시 SageMaker Async + Qwen PII service:
   - 진입 조건: 누설률 > 1% / 1주
   - spec: `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` §4.3
4. **CloudTrail data events 활성화 (Phase 2)** — S3 GetObject 단위 감사 — compliance 페이지 다운로드 추적

## 회복 후 / 회귀 원인 분석

- `pii.maskApplied` 메트릭의 baseline 재설정 (해당 사건 이전 7일 평균)
- 정규식 변경 PR 의 unit test coverage 점검
- ADR-003 의 3-layer 중 어느 layer 가 실패했는지 명시 (Layer 1 regex / Layer 2 R5 prompt / Layer 3 persist sweep)
- 사후 보고서: legal 측 PII handling 문서에 sync
