# `src/lambdas/` — Lambda handlers

## Role

각 서브디렉토리가 하나의 AWS Lambda function. Step Functions Express state machine이 순서대로 호출 (`pii_guard` → `classify` → [`verify` | `MarkAutoHigh`] → `persist`).

## Key Files

```
pii_guard/handler.py    — S3 raw 읽고 정규식 마스킹 후 S3 masked write
classify/handler.py     — Bedrock Opus 4.7 호출, classification dict 반환
verify/handler.py       — Bedrock Sonnet 4.6 cross-verify, status 결정
persist/handler.py      — DDB put_item + (옵션) Firehose Parquet + EMF emit
```

각 디렉토리는 동일한 3종 파일:
- `__init__.py` — docstring only
- `handler.py` — `def handler(event, _ctx) -> dict`
- `requirements.txt` — Lambda 런타임 boto3 사용, deps 비어 있음 (do NOT pin boto3)

## Rules

### Handler shape
- **Module-level boto3 client + adapter** — 콜드 스타트 비용 절약. `_s3 = boto3.client("s3")` 같은 패턴.
- **`sys.path.insert(0, str(Path(__file__).parent.parent.parent))`** — Lambda zip의 `/var/task/`에서 `lib/` import 위해. TODO(phase2)로 Layer 마이그레이션 표시.
- **이벤트 통과**: `return {**event, ...}` 패턴으로 SFN이 다음 state에 데이터를 자연스럽게 전달.
- **예외 처리는 SFN에 위임**: try/except로 silent하게 삼키지 말 것. SFN의 Retry/Catch가 처리한다. 단, ConditionalCheckFailedException 같이 의도된 silent-skip이 필요한 경우는 명시적 `try/except ClientError` + 다른 status 반환.
- **PII는 절대 reason/why_rejected에 넣지 않는다** — system prompt R5 룰 + persist sweep으로 이중 방어.

### Packaging (Terraform 측)
새 Lambda 추가 시 `infra/modules/classify-pipeline/main.tf` 에 다음 패턴 그대로:

```hcl
data "external" "<name>_stage" {
  program = ["bash", "-c", <<-EOT
    set -e
    STAGE_DIR=${path.module}/build/<name>
    SRC_DIR=${path.module}/../../../src
    rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
    cp -R "$SRC_DIR/lib" "$STAGE_DIR/"
    # cp -R "$SRC_DIR/prompts" "$STAGE_DIR/"  # classify/verify만
    mkdir -p "$STAGE_DIR/lambdas"
    cp -R "$SRC_DIR/lambdas/<name>" "$STAGE_DIR/lambdas/"
    find "$STAGE_DIR" -type d -name __pycache__ -exec rm -rf {} + || true
    echo "{\"staged\":\"$STAGE_DIR\"}"
  EOT
  ]
}

data "archive_file" "<name>" {
  type        = "zip"
  source_dir  = data.external.<name>_stage.result.staged
  output_path = "${path.module}/build/<name>.zip"
}
```

IAM role, log group, Lambda function 블록은 기존 4개 (pii_guard, classify, verify, persist)를 참고. Bedrock invoke 권한은 모델 ARN 패턴 (`anthropic.claude-{opus|sonnet}-4-*`)으로 좁힘.

### Testing
- 각 handler.py는 `tests/unit/test_<name>_handler.py` 와 짝.
- moto + `MagicMock` + `patch("lib.bedrock_client.boto3.client", ...)` 패턴.
- module-level adapter 캐시 회피를 위해 fixture에 `sys.modules.pop("lambdas.<name>.handler", None)`.
- 핸들러를 module scope에서 import하면 fixture 효과가 없어지므로, **각 테스트 함수 내부에서** `from lambdas.<name>.handler import handler` 임포트.
