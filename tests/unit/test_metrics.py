"""metrics.py EMF emit 동작 단위 테스트."""

import json
from io import StringIO
from unittest.mock import patch

from lib.metrics import emit


def test_emit_writes_emf_json_to_stdout() -> None:
    buf = StringIO()
    with patch("sys.stdout", buf):
        emit("classification.processed", 1.0, 대code="CS_X")
    line = buf.getvalue().strip()
    parsed = json.loads(line)
    assert parsed["classification.processed"] == 1.0
    assert parsed["대code"] == "CS_X"
    assert parsed["_aws"]["CloudWatchMetrics"][0]["Namespace"] == "callcenter/classification"
    assert "env" in parsed["_aws"]["CloudWatchMetrics"][0]["Dimensions"][0]


def test_emit_uses_env_var_for_env_dimension(monkeypatch) -> None:
    monkeypatch.setenv("ENV", "stg")
    # Re-import to pick up new env var
    import importlib

    from lib import metrics

    importlib.reload(metrics)

    buf = StringIO()
    with patch("sys.stdout", buf):
        metrics.emit("x", 1.0)
    parsed = json.loads(buf.getvalue().strip())
    assert parsed["env"] == "stg"
