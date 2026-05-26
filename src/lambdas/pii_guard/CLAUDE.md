# `src/lambdas/pii_guard/`

## Role

Step Functions의 첫 단계. S3 `stt-raw` 의 STT JSON을 읽어 정규식 기반 하드 PII (계좌·카드·주민·휴대폰) 를 마스킹하고 S3 `stt-masked` 에 평문 텍스트로 저장한다. Bedrock 호출 전 PII가 외부로 나가지 않게 막는 첫 번째 가드.

## Input / Output

**Input** (EventBridge → SFN → handler):
```json
{ "rawBucket": str, "rawKey": str }
```

**Output**:
```json
{
  "callId": str,
  "agentId": str,
  "startedAt": str,
  "durationSec": int,
  "rawBucket": str,
  "rawKey": str,
  "maskedBucket": str,
  "maskedKey": str,
  "maskStats": {"phone": int, "rrn": int, "account": int, "card": int}
}
```

## Env vars

- `MASKED_BUCKET` — 마스킹 텍스트를 쓸 S3 버킷 이름 (Terraform이 `bucket_masked_id` 로 주입)

## Rules

- 정규식 적용 순서는 `lib/pii_regex.py` 의 `mask()` 함수에서 고정 (card → rrn → phone → account). **순서 변경 금지.**
- 한글 인근 숫자 boundary는 `(?<!\d)/(?!\d)` 사용 (`\b`는 한글 jamo에서 동작 안 함).
- 카드는 Luhn 검증 통과한 13~19 digit만 마스킹. over-greedy 매치 방지를 위해 `\d(?:[ -]?\d){12,18}` 형식 (count digit not iterations).
- transcript 직렬화는 `f"{turn['speaker']}: {turn['text']}"` 한 줄씩 join.
- KMS-CMK 암호화는 S3 bucket-default가 처리 (handler는 `ServerSideEncryption="aws:kms"` 만 명시).
