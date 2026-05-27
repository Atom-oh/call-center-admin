"""Step Functions task: read raw STT from S3, mask PII, write to masked S3.

Input event:
  { "rawBucket": str, "rawKey": str }

Output:
  { "callId": str, "agentId": str, "startedAt": str, "durationSec": int,
    "rawBucket": str, "rawKey": str,
    "maskedBucket": str, "maskedKey": str,
    "maskStats": {"phone": int, "rrn": int, "account": int, "card": int} }
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

# Lambda 패키징 시 src/lib도 함께 zip. 런타임 zip 루트 = /var/task/, 그 안에 lib/ + lambdas/.
# TODO(phase2): lib/ 를 Lambda Layer로 분리하고 본 sys.path hack 제거.
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3

from lib.metrics import emit
from lib.pii_regex import mask

_s3 = boto3.client("s3")
_MASKED_BUCKET = os.environ["MASKED_BUCKET"]


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    raw_bucket = event["rawBucket"]
    raw_key = event["rawKey"]

    obj = _s3.get_object(Bucket=raw_bucket, Key=raw_key)
    payload = json.loads(obj["Body"].read())

    transcript_text = "\n".join(
        f"{turn['speaker']}: {turn['text']}" for turn in payload["transcript"]
    )
    masked_text, stats = mask(transcript_text)

    masked_key = raw_key.replace(".json", "_masked.txt")
    _s3.put_object(
        Bucket=_MASKED_BUCKET,
        Key=masked_key,
        Body=masked_text.encode("utf-8"),
        ContentType="text/plain; charset=utf-8",
        ServerSideEncryption="aws:kms",
    )

    # PR9: per-PII-type EMF emit. zero-count types are skipped to avoid
    # dimension cardinality bloat in CloudWatch.
    for pii_type, count in stats.as_dict().items():
        if count > 0:
            emit("pii.maskApplied", float(count), pii_type=pii_type)

    return {
        "callId": payload["callId"],
        "agentId": payload["agentId"],
        "startedAt": payload["startedAt"],
        "durationSec": payload["durationSec"],
        "rawBucket": raw_bucket,
        "rawKey": raw_key,
        "maskedBucket": _MASKED_BUCKET,
        "maskedKey": masked_key,
        "maskStats": stats.as_dict(),
    }
