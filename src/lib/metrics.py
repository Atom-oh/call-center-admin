"""CloudWatch Embedded Metric Format helper.

Lambda가 stdout에 EMF JSON을 찍으면 CloudWatch가 자동으로 메트릭으로 수집.
PR9 (observability) 단계에서 알람·대시보드와 연동된다.
"""
from __future__ import annotations

import json
import os
import sys
import time

_NAMESPACE = "callcenter/classification"
_ENV = os.environ.get("ENV", "dev")


def emit(metric_name: str, value: float, unit: str = "Count", **dims: str) -> None:
    """Emit an EMF metric record. Observability must never break the working path,
    so any serialization failure is swallowed (logged to stderr) instead of raised."""
    try:
        dims_with_env = {"env": _ENV, **dims}
        record = {
            "_aws": {
                "Timestamp": int(time.time() * 1000),
                "CloudWatchMetrics": [
                    {
                        "Namespace": _NAMESPACE,
                        "Dimensions": [list(dims_with_env.keys())],
                        "Metrics": [{"Name": metric_name, "Unit": unit}],
                    }
                ],
            },
            **dims_with_env,
            metric_name: value,
        }
        print(json.dumps(record, ensure_ascii=False), file=sys.stdout, flush=True)
    except Exception as ex:  # observability must never raise — broad except is intentional
        print(f"emit({metric_name}) failed: {ex!r}", file=sys.stderr, flush=True)
