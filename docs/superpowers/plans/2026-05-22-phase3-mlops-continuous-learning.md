# Phase 3 — MLOps 자동 학습 파이프라인 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 1에서 누적된 HITL 라벨 + 합성 데이터 증강(§3.7.5)으로 대분류 KLUE-BERT를 매일 자동 fine-tune·평가·블루-그린 배포하는 폐쇄 루프를 4~6주 내에 출시한다.

**Architecture:** EventBridge daily cron → SageMaker Pipeline (Athena CTAS 데이터 수집 → 데이터 검증 Lambda → Processing 전처리 → Training Job (KLUE-BERT, G5 spot) → Processing 평가 → Model Registry → 조건부 stg 카나리 → Slack 1-클릭 승인 → prd 100%). classify Lambda는 ML 어댑터 우선 호출, confidence ≥ 0.9이면 ML, 아니면 Bedrock LLM 폴백.

**Tech Stack:** Python 3.12, PyTorch 2.x, transformers, KLUE-BERT (`klue/bert-base`), SageMaker (Training Job, Pipelines, Endpoint Production Variants, Model Monitor, Model Registry), Athena CTAS, Glue, Terraform, GitHub Actions OIDC.

**Spec reference:** `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md` §3.7.3 / §3.7.5 / §3.8

**Entry condition:** Phase 1 v1.0.0 운영 안정화 + HITL 누적 ≥ 500건.

---

## File Structure (Phase 1 위에 추가)

```
call-center-admin/
├── src/
│   ├── lib/
│   │   ├── inference_adapter.py        # Phase 1에서 정의 — ML 어댑터 추가
│   │   └── ml_adapter.py               # SageMaker Endpoint 호출 어댑터 (NEW)
│   ├── lambdas/
│   │   ├── classify/handler.py         # 캐스케이드 로직 추가
│   │   ├── ml_data_extract/            # Athena CTAS 실행 (NEW)
│   │   ├── ml_data_validate/           # 데이터 검증 게이트 (NEW)
│   │   └── ml_canary_monitor/          # 카나리 24h 모니터 (NEW)
│   └── ml/
│       ├── train.py                    # KLUE-BERT fine-tune (Training Job 진입점)
│       ├── evaluate.py                 # held-out 평가
│       ├── synthesize.py               # LLM 합성 데이터 생성
│       ├── augment_paraphrase.py       # real label paraphrase 증강
│       └── Dockerfile                  # Training 컨테이너
├── infra/modules/continuous-learning/
│   ├── schedule.tf                     # EventBridge cron
│   ├── pipeline.tf                     # SageMaker Pipeline
│   ├── training.tf                     # Training Job + ECR
│   ├── registry.tf                     # Model Registry
│   ├── endpoint.tf                     # Production Variants blue/green
│   ├── monitoring.tf                   # Model Monitor + CW alarms
│   ├── data-prep.tf                    # Glue + Athena
│   └── lambdas.tf                      # ml_data_extract / validate / canary_monitor
├── scripts/
│   ├── bootstrap_synthetic_dataset.py  # 첫 ~6K 데이터셋 생성 (one-shot)
│   ├── kick_pipeline.py                # 수동 SageMaker Pipeline 실행
│   ├── canary_status.py                # 카나리 상태 조회
│   └── promote_model.py                # Slack 승인 → prod 변경
└── tests/
    ├── unit/
    │   ├── test_ml_train_stub.py       # train.py 데이터 파이프라인 단위 테스트
    │   ├── test_ml_evaluate.py         # 평가 메트릭 계산
    │   ├── test_data_validate.py       # 데이터 검증 게이트
    │   └── test_ml_cascade.py          # classify Lambda 캐스케이드 분기
    └── integration/
        └── test_pipeline_dryrun.py     # SageMaker Pipeline 정의 유효성
```

---

## PR Decomposition Overview

| PR | 이름 | 의존성 | 검증 게이트 | 산출물 |
|----|------|--------|-------------|--------|
| ML-PR1 | InferenceAdapter ML 구현 + 캐스케이드 (LLM 폴백) | Phase 1 완료 | classify Lambda 캐스케이드 분기 단위 테스트 | `ml_adapter.py`, classify Lambda 갱신 |
| ML-PR2 | 합성 데이터 부트스트랩 + 평가셋 ~6K 생성 | HITL 500건 누적 | real held-out 100건에서 학습 데이터 분포 비교 통과 | `scripts/bootstrap_synthetic_dataset.py`, S3 `training-sets/v0/` |
| ML-PR3 | Training Job 컨테이너 + train.py + evaluate.py | ML-PR2 | dev에서 Training Job 1회 성공, eval JSON 생성 | `src/ml/`, ECR `callcenter-{env}-ml-trainer` |
| ML-PR4 | SageMaker Pipeline + Model Registry | ML-PR3 | Pipeline 1회 수동 실행 → Registry에 모델 등록 | `modules/continuous-learning/{pipeline,registry,training}.tf` |
| ML-PR5 | Endpoint blue/green + ML 캐스케이드 라이브 | ML-PR1, ML-PR4 | Endpoint 호출 응답 < 500ms, classify Lambda 캐스케이드 동작 | `endpoint.tf`, ml_adapter 라이브 |
| ML-PR6 | 데이터 추출 Lambda (Athena CTAS) + 검증 Lambda | ML-PR4 | LocalStack/dev에서 ml_data_extract → S3 training set 생성 | 2개 Lambda + EventBridge cron |
| ML-PR7 | 카나리 자동 배포 + Slack 1-클릭 승인 | ML-PR5, ML-PR6 | 인공 새 모델 → 카나리 → Slack 메시지 → 클릭 → prod 변경 확인 | promote_model.py + Slack interactive endpoint |
| ML-PR8 | Model Monitor + drift alarms + Streamlit 확장 페이지 | ML-PR5, Phase1 PR9 | 인공 drift 데이터로 알람 트리거, "오늘의 모델 업데이트" 페이지 표시 | `monitoring.tf`, Streamlit `pages/4_model_status.py` |
| ML-PR9 | CI/CD + 자동 학습 통합 + 런북 | 전체 | 매일 02:00 KST 자동 실행 + 회귀 시 자동 차단 + Slack 알림 | `.github/workflows/ml-*.yml`, 런북 3개 |

---

## ML-PR1: InferenceAdapter ML 구현 + 캐스케이드 (LLM 폴백)

**Files:**
- Create: `src/lib/ml_adapter.py`
- Modify: `src/lambdas/classify/handler.py` (캐스케이드 분기)
- Create: `tests/unit/test_ml_cascade.py`

### Step ML1.1: ml_adapter (Endpoint 미존재 시 graceful fallback)

- [ ] **Write `src/lib/ml_adapter.py`**

```python
"""SageMaker Endpoint 호출 어댑터 (KLUE-BERT 대분류 분류기)."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass

import boto3

from lib.output_schema import Alternative, CategoryLabel, ClassificationResult


@dataclass
class MlEndpointConfig:
    endpoint_name: str
    region: str = "ap-northeast-2"


class MlAdapter:
    name: str
    version: str

    def __init__(self, cfg: MlEndpointConfig, taxonomy_map: dict[str, str]) -> None:
        """taxonomy_map: 대code → 대name lookup."""
        self.cfg = cfg
        self.taxonomy_map = taxonomy_map
        self.name = f"ml-endpoint-{cfg.endpoint_name}"
        self.version = os.environ.get("ML_MODEL_VERSION", "unknown")
        self._client = boto3.client("sagemaker-runtime", region_name=cfg.region)

    def classify(self, masked_transcript: str) -> ClassificationResult:
        resp = self._client.invoke_endpoint(
            EndpointName=self.cfg.endpoint_name,
            ContentType="application/json",
            Body=json.dumps({"text": masked_transcript}).encode(),
        )
        body = json.loads(resp["Body"].read())
        대_code = body["대code"]
        대_name = self.taxonomy_map.get(대_code, "")
        return ClassificationResult(
            대=CategoryLabel(code=대_code, name=대_name),
            중=CategoryLabel(code="", name=""),  # ML은 대분류만, 중·소는 LLM이 채움
            소=CategoryLabel(code="", name=""),
            confidence=float(body["confidence"]),
            reason=body.get("reason", "ML 분류"),
            alternativesConsidered=[],
        )
```

### Step ML1.2: classify Lambda 캐스케이드 분기

- [ ] **Update `src/lambdas/classify/handler.py`** (전체 교체)

```python
"""Step Functions task: ML 먼저 → confidence ≥ 임계 시 ML 채택, 아니면 LLM 폴백."""
from __future__ import annotations

import dataclasses
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3

from lib.bedrock_client import BedrockAdapter
from lib.metrics import emit
from lib.prompts import build_prompt_bundle
from lib.ml_adapter import MlAdapter, MlEndpointConfig

_MODEL_ID = os.environ["MODEL_ID"]
_PROMPT_DIR = Path(os.environ.get("PROMPT_DIR", "/var/task/prompts/v1.0"))
_RULES = (_PROMPT_DIR / "system_rules.md").read_text(encoding="utf-8")
_TREE = (_PROMPT_DIR / "taxonomy_tree.json").read_text(encoding="utf-8")
_BUNDLE = build_prompt_bundle(rules_md=_RULES, taxonomy_json=_TREE)
_LLM = BedrockAdapter(model_id=_MODEL_ID, bundle=_BUNDLE)

_ML_ENDPOINT = os.environ.get("ML_ENDPOINT_NAME")
_ML_THRESHOLD = float(os.environ.get("ML_CONF_THRESHOLD", "0.90"))
_taxonomy_map = {n["code"]: n["name"] for n in json.loads(_TREE) if n["level"] == 1 and n["code"]}
_ML = MlAdapter(MlEndpointConfig(endpoint_name=_ML_ENDPOINT), _taxonomy_map) if _ML_ENDPOINT else None
_s3 = boto3.client("s3")


def handler(event: dict, _ctx) -> dict:
    masked = _s3.get_object(Bucket=event["maskedBucket"], Key=event["maskedKey"])["Body"].read().decode()

    used_ml = False
    if _ML is not None:
        try:
            ml_result = _ML.classify(masked)
            if ml_result.confidence >= _ML_THRESHOLD:
                # ML이 confident하지만 중/소는 LLM이 보강해야 하므로 LLM 호출은 유지
                llm_result = _LLM.classify(masked)
                # 대분류는 ML, 중·소는 LLM 결과 사용
                final = dataclasses.replace(
                    llm_result, 대=ml_result.대, confidence=max(ml_result.confidence, llm_result.confidence)
                )
                used_ml = True
                emit("ml.cascade.accepted", 1.0, 대code=ml_result.대.code)
            else:
                final = _LLM.classify(masked)
                emit("ml.cascade.rejected", 1.0, ml_confidence=str(round(ml_result.confidence, 2)))
        except Exception as ex:  # noqa: BLE001
            emit("ml.cascade.error", 1.0, error=type(ex).__name__)
            final = _LLM.classify(masked)
    else:
        final = _LLM.classify(masked)

    return {
        **event,
        "modelId": _MODEL_ID if not used_ml else f"{_ML.name},{_MODEL_ID}",
        "promptVersion": _BUNDLE.prompt_version,
        "mlVersion": _ML.version if used_ml else None,
        "classification": dataclasses.asdict(final),
        "usedMl": used_ml,
    }
```

### Step ML1.3: 캐스케이드 단위 테스트

- [ ] **Write `tests/unit/test_ml_cascade.py`**

```python
"""ML 캐스케이드 분기 단위 테스트."""
import json
import os
from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("MODEL_ID", "anthropic.claude-opus-4-7-20260101-v1:0")
    monkeypatch.setenv("ML_ENDPOINT_NAME", "callcenter-dev-classifier")
    monkeypatch.setenv("ML_CONF_THRESHOLD", "0.90")
    monkeypatch.setenv("PROMPT_DIR", "src/prompts/v1.0")
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")


def test_ml_accepted_when_high_confidence(env) -> None:
    ml_resp = {
        "Body": MagicMock(read=lambda: json.dumps({"대code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY", "confidence": 0.95}).encode())
    }
    llm_resp = {
        "output": {"message": {"content": [{"text": json.dumps({
            "대": {"code": "X", "name": "x"},
            "중": {"code": "CS_M", "name": "m"},
            "소": {"code": "CS_S", "name": "s"},
            "confidence": 0.7, "reason": "r", "alternativesConsidered": [],
        })}]}}
    }
    fake_sm = MagicMock()
    fake_sm.invoke_endpoint.return_value = ml_resp
    fake_bedrock = MagicMock()
    fake_bedrock.converse.return_value = llm_resp

    with patch("lib.ml_adapter.boto3.client", return_value=fake_sm), patch(
        "lib.bedrock_client.boto3.client", return_value=fake_bedrock
    ), patch("boto3.client") as bc:
        bc.return_value.get_object.return_value = {"Body": MagicMock(read=lambda: b"x")}
        from src.lambdas.classify.handler import handler

        out = handler({"callId": "c", "maskedBucket": "b", "maskedKey": "k"}, None)
        assert out["usedMl"] is True
        assert out["classification"]["대"]["code"] == "CS_CENTER_CONSULT_TYPE_PAY_NONEY"
        # 중·소는 LLM이 부여
        assert out["classification"]["중"]["code"] == "CS_M"


def test_llm_fallback_when_ml_low_confidence(env) -> None:
    ml_resp = {
        "Body": MagicMock(read=lambda: json.dumps({"대code": "X", "confidence": 0.5}).encode())
    }
    llm_resp = {
        "output": {"message": {"content": [{"text": json.dumps({
            "대": {"code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY", "name": "n"},
            "중": {"code": "n", "name": "n"},
            "소": {"code": "n", "name": "n"},
            "confidence": 0.88, "reason": "r", "alternativesConsidered": [],
        })}]}}
    }
    fake_sm = MagicMock()
    fake_sm.invoke_endpoint.return_value = ml_resp
    fake_bedrock = MagicMock()
    fake_bedrock.converse.return_value = llm_resp

    with patch("lib.ml_adapter.boto3.client", return_value=fake_sm), patch(
        "lib.bedrock_client.boto3.client", return_value=fake_bedrock
    ), patch("boto3.client") as bc:
        bc.return_value.get_object.return_value = {"Body": MagicMock(read=lambda: b"x")}
        from src.lambdas.classify.handler import handler

        out = handler({"callId": "c", "maskedBucket": "b", "maskedKey": "k"}, None)
        assert out["usedMl"] is False
        assert out["classification"]["대"]["code"] == "CS_CENTER_CONSULT_TYPE_PAY_NONEY"
```

- [ ] **Run tests until pass**

```bash
pytest tests/unit/test_ml_cascade.py -v
```

- [ ] **Commit**

```bash
git add src/lib/ml_adapter.py src/lambdas/classify/handler.py tests/unit/test_ml_cascade.py
git commit -m "feat(ml): ML cascade adapter with LLM fallback in classify Lambda"
```

---

## ML-PR2: 합성 데이터 부트스트랩 + 평가셋 ~6K 생성

**Files:**
- Create: `src/ml/synthesize.py`
- Create: `src/ml/augment_paraphrase.py`
- Create: `scripts/bootstrap_synthetic_dataset.py`
- Create: `tests/unit/test_synthesize.py`

### Step ML2.1: 합성 데이터 생성기

- [ ] **Write `src/ml/synthesize.py`**

```python
"""카테고리별 시드(description + real 샘플)로 LLM이 합성 대화 생성.

다중 LLM 합의 필터: Opus 생성 → Sonnet으로 다시 분류 → 라벨 일치한 것만 채택.
"""
from __future__ import annotations

import json
import os
import random
from dataclasses import dataclass

import boto3


@dataclass
class SyntheticConfig:
    samples_per_category: int = 300
    length_variants: tuple[str, ...] = ("짧음", "중간", "김")
    turn_variants: tuple[int, ...] = (1, 3, 5, 10)
    stt_noise: bool = True


_PROMPT_TPL = """다음 카테고리에 해당하는 콜센터 STT 대화를 합성하라.

카테고리: {name} (code: {code})
설명: {description}

조건:
- 길이: {length}
- 화자 턴 수: {turns}
- agent/customer 화자 표시
- 한국어, STT 결과처럼 띄어쓰기 오류·필러("어", "음") 자연스럽게 포함{noise_hint}

real 샘플 참고:
{real_examples}

출력은 transcript 텍스트만 (헤더 없이)."""


def _build_prompt(node: dict, real_examples: list[str], cfg: SyntheticConfig) -> str:
    return _PROMPT_TPL.format(
        name=node["name"],
        code=node["code"],
        description=node.get("description", "")[:400],
        length=random.choice(cfg.length_variants),
        turns=random.choice(cfg.turn_variants),
        noise_hint=" (STT 노이즈 강도: 중)" if cfg.stt_noise else "",
        real_examples="\n---\n".join(real_examples[:3]) if real_examples else "(없음)",
    )


def synthesize_for_node(
    node: dict, real_examples: list[str], cfg: SyntheticConfig, bedrock_client
) -> list[str]:
    out: list[str] = []
    for _ in range(cfg.samples_per_category):
        resp = bedrock_client.converse(
            modelId=os.environ.get("OPUS_MODEL_ID", "anthropic.claude-opus-4-7-20260101-v1:0"),
            messages=[{"role": "user", "content": [{"text": _build_prompt(node, real_examples, cfg)}]}],
            inferenceConfig={"maxTokens": 800, "temperature": 1.0},
        )
        out.append(resp["output"]["message"]["content"][0]["text"])
    return out


def consensus_filter(
    synthetic: list[tuple[str, str]],  # (transcript, expected_code)
    classify_fn,  # callable: str -> str (returns 대code)
) -> list[tuple[str, str]]:
    """Sonnet으로 분류해서 expected와 일치한 것만 채택."""
    kept: list[tuple[str, str]] = []
    for text, expected in synthetic:
        try:
            predicted = classify_fn(text)
            if predicted == expected:
                kept.append((text, expected))
        except Exception:
            continue
    return kept
```

### Step ML2.2: paraphrase 증강

- [ ] **Write `src/ml/augment_paraphrase.py`**

```python
"""Real 라벨 샘플을 LLM이 N배 paraphrase."""
from __future__ import annotations

import os

_PROMPT = """다음 콜센터 대화를 의미는 동일하되 어휘·문장 구조를 다르게 표현하여
{n}개의 변형을 생성하라. 화자 표시(agent/customer)와 STT 노이즈 패턴은 유지.

원본:
{text}

출력은 각 변형을 `---` 구분자로 나열만 (헤더 없이)."""


def paraphrase(text: str, n: int, bedrock_client) -> list[str]:
    resp = bedrock_client.converse(
        modelId=os.environ.get("SONNET_MODEL_ID", "anthropic.claude-sonnet-4-6-20260101-v1:0"),
        messages=[{"role": "user", "content": [{"text": _PROMPT.format(n=n, text=text)}]}],
        inferenceConfig={"maxTokens": 2000, "temperature": 0.9},
    )
    body = resp["output"]["message"]["content"][0]["text"]
    parts = [p.strip() for p in body.split("---") if p.strip()]
    return parts[:n]
```

### Step ML2.3: bootstrap CLI

- [ ] **Write `scripts/bootstrap_synthetic_dataset.py`**

```python
"""Phase 3 첫 학습용 데이터셋(~6K) 생성: HITL real + LLM 합성 + paraphrase."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

import boto3

from ml.synthesize import SyntheticConfig, consensus_filter, synthesize_for_node
from ml.augment_paraphrase import paraphrase


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--taxonomy", type=Path, default=Path("src/prompts/v1.0/taxonomy_tree.json"))
    p.add_argument("--real-labels-jsonl", type=Path, required=True,
                   help="HITL accumulated real (transcript, 대code) lines")
    p.add_argument("--out-dir", type=Path, default=Path("ml-data/v0"))
    p.add_argument("--synthetic-per-class", type=int, default=300)
    p.add_argument("--paraphrase-x", type=int, default=10)
    args = p.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    bedrock = boto3.client("bedrock-runtime", region_name="ap-northeast-2")
    nodes = [n for n in json.loads(args.taxonomy.read_text(encoding="utf-8")) if n["level"] == 1]

    # 1. real 로드
    real_rows = [json.loads(l) for l in args.real_labels_jsonl.read_text(encoding="utf-8").splitlines() if l.strip()]
    real_by_code: dict[str, list[str]] = {}
    for r in real_rows:
        real_by_code.setdefault(r["대code"], []).append(r["transcript"])

    # 2. 합성
    synthetic: list[tuple[str, str]] = []
    cfg = SyntheticConfig(samples_per_category=args.synthetic_per_class)
    for node in nodes:
        examples = real_by_code.get(node["code"], [])
        out = synthesize_for_node(node, examples, cfg, bedrock)
        synthetic.extend((t, node["code"]) for t in out)
    print(f"raw synthetic: {len(synthetic)}")

    # 3. 합의 필터 (Sonnet)
    def classify_fn(text: str) -> str:
        resp = bedrock.converse(
            modelId="anthropic.claude-sonnet-4-6-20260101-v1:0",
            messages=[{"role": "user", "content": [{"text": f"다음 대화의 대분류 코드만 출력하라:\n{text}"}]}],
            inferenceConfig={"maxTokens": 50, "temperature": 0.0},
        )
        return resp["output"]["message"]["content"][0]["text"].strip()

    kept = consensus_filter(synthetic, classify_fn)
    print(f"after consensus filter: {len(kept)}")

    # 4. paraphrase
    paraphrased: list[tuple[str, str]] = []
    for r in real_rows:
        variants = paraphrase(r["transcript"], n=args.paraphrase_x, bedrock_client=bedrock)
        paraphrased.extend((v, r["대code"]) for v in variants)

    # 5. 합치고 jsonl 저장
    combined = (
        [{"transcript": r["transcript"], "대code": r["대code"], "source": "real"} for r in real_rows]
        + [{"transcript": t, "대code": c, "source": "synthetic"} for t, c in kept]
        + [{"transcript": t, "대code": c, "source": "paraphrase"} for t, c in paraphrased]
    )
    out_file = args.out_dir / "train.jsonl"
    out_file.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in combined), encoding="utf-8")
    print(f"wrote {len(combined)} rows → {out_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

### Step ML2.4: 단위 테스트 + 실제 dev 실행

- [ ] **Write `tests/unit/test_synthesize.py`**

```python
from unittest.mock import MagicMock

from ml.synthesize import SyntheticConfig, consensus_filter, synthesize_for_node


def test_synthesize_returns_n_samples() -> None:
    cfg = SyntheticConfig(samples_per_category=3)
    fake = MagicMock()
    fake.converse.return_value = {
        "output": {"message": {"content": [{"text": "agent: hi"}]}}
    }
    node = {"name": "x", "code": "X", "description": "d"}
    out = synthesize_for_node(node, real_examples=[], cfg=cfg, bedrock_client=fake)
    assert len(out) == 3


def test_consensus_filter_keeps_only_matching() -> None:
    syn = [("t1", "A"), ("t2", "A"), ("t3", "B")]
    classify = lambda x: "A"  # 모두 A로 분류
    kept = consensus_filter(syn, classify)
    assert len(kept) == 2  # B 거부됨
```

- [ ] **Run + execute bootstrap on dev**

```bash
pytest tests/unit/test_synthesize.py -v
# HITL real labels export
aws athena start-query-execution --work-group callcenter-dev \
  --query-string "SELECT piiMaskedTextRef AS s3_uri, category_대code AS 대code FROM consult_results WHERE status='hitl-corrected'" \
  --result-configuration "OutputLocation=s3://kakaopay-callcenter-dev-analytics/exports/"
# 결과를 ml-data/v0/real.jsonl로 변환 (별도 스크립트 또는 수동)
python scripts/bootstrap_synthetic_dataset.py --real-labels-jsonl ml-data/v0/real.jsonl
aws s3 sync ml-data/v0/ s3://kakaopay-callcenter-dev-ml/training-sets/v0/
```

- [ ] **Commit**

```bash
git add src/ml/synthesize.py src/ml/augment_paraphrase.py scripts/bootstrap_synthetic_dataset.py tests/unit/test_synthesize.py
git commit -m "feat(ml): synthetic+paraphrase data bootstrap with consensus filter"
```

---

## ML-PR3: Training Job 컨테이너 + train.py + evaluate.py

**Files:**
- Create: `src/ml/train.py`
- Create: `src/ml/evaluate.py`
- Create: `src/ml/Dockerfile`
- Create: `tests/unit/test_ml_evaluate.py`

### Step ML3.1: train.py (KLUE-BERT fine-tune)

- [ ] **Write `src/ml/train.py`**

```python
"""KLUE-BERT 대분류 fine-tune (SageMaker Training Job 진입점).

SageMaker가 자동 주입:
  /opt/ml/input/data/train/train.jsonl
  /opt/ml/input/data/val/val.jsonl
  /opt/ml/model/  (학습 후 산출)
  /opt/ml/output/data/  (메트릭 등)
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import torch
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForSequenceClassification, AutoTokenizer, get_linear_schedule_with_warmup

MODEL_NAME = os.environ.get("BASE_MODEL", "klue/bert-base")
TRAIN_DIR = Path(os.environ.get("SM_CHANNEL_TRAIN", "/opt/ml/input/data/train"))
VAL_DIR = Path(os.environ.get("SM_CHANNEL_VAL", "/opt/ml/input/data/val"))
MODEL_DIR = Path(os.environ.get("SM_MODEL_DIR", "/opt/ml/model"))
OUT_DIR = Path(os.environ.get("SM_OUTPUT_DATA_DIR", "/opt/ml/output/data"))
EPOCHS = int(os.environ.get("EPOCHS", "3"))
BATCH = int(os.environ.get("BATCH_SIZE", "16"))
LR = float(os.environ.get("LR", "2e-5"))


class JsonlDataset(Dataset):
    def __init__(self, path: Path, tokenizer, label2id: dict[str, int]) -> None:
        self.rows = [json.loads(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
        self.tok = tokenizer
        self.label2id = label2id

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, idx: int):
        r = self.rows[idx]
        enc = self.tok(
            r["transcript"], truncation=True, max_length=512, padding="max_length", return_tensors="pt"
        )
        return {
            "input_ids": enc["input_ids"].squeeze(0),
            "attention_mask": enc["attention_mask"].squeeze(0),
            "labels": torch.tensor(self.label2id[r["대code"]], dtype=torch.long),
        }


def main() -> None:
    train_rows = (TRAIN_DIR / "train.jsonl").read_text(encoding="utf-8").splitlines()
    labels = sorted({json.loads(l)["대code"] for l in train_rows if l.strip()})
    label2id = {c: i for i, c in enumerate(labels)}
    id2label = {i: c for c, i in label2id.items()}

    tok = AutoTokenizer.from_pretrained(MODEL_NAME)
    model = AutoModelForSequenceClassification.from_pretrained(
        MODEL_NAME, num_labels=len(labels), id2label=id2label, label2id=label2id
    )
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model.to(device)

    train_ds = JsonlDataset(TRAIN_DIR / "train.jsonl", tok, label2id)
    val_ds = JsonlDataset(VAL_DIR / "val.jsonl", tok, label2id)
    train_loader = DataLoader(train_ds, batch_size=BATCH, shuffle=True)
    val_loader = DataLoader(val_ds, batch_size=BATCH)

    optim = torch.optim.AdamW(model.parameters(), lr=LR)
    sched = get_linear_schedule_with_warmup(optim, 0, len(train_loader) * EPOCHS)
    crit = torch.nn.CrossEntropyLoss()

    for ep in range(EPOCHS):
        model.train()
        total = 0.0
        for batch in train_loader:
            batch = {k: v.to(device) for k, v in batch.items()}
            optim.zero_grad()
            out = model(**batch)
            out.loss.backward()
            optim.step()
            sched.step()
            total += out.loss.item()
        print(f"epoch {ep+1} train_loss={total/len(train_loader):.4f}")

        # 간단 val accuracy
        model.eval()
        correct = 0
        n = 0
        with torch.no_grad():
            for batch in val_loader:
                batch = {k: v.to(device) for k, v in batch.items()}
                out = model(**batch)
                pred = out.logits.argmax(dim=-1)
                correct += (pred == batch["labels"]).sum().item()
                n += pred.shape[0]
        acc = correct / n if n else 0
        print(f"epoch {ep+1} val_acc={acc:.4f}")

    model.save_pretrained(MODEL_DIR)
    tok.save_pretrained(MODEL_DIR)
    (MODEL_DIR / "label2id.json").write_text(json.dumps(label2id, ensure_ascii=False), encoding="utf-8")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "metrics.json").write_text(json.dumps({"final_val_acc": acc}), encoding="utf-8")


if __name__ == "__main__":
    main()
```

### Step ML3.2: evaluate.py (held-out golden set 평가)

- [ ] **Write `src/ml/evaluate.py`**

```python
"""Held-out golden set 평가 — Processing Job 진입점."""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/opt/ml/processing/input/model"))
GOLDEN = Path(os.environ.get("GOLDEN_JSONL", "/opt/ml/processing/input/golden/samples.jsonl"))
OUT = Path(os.environ.get("OUT", "/opt/ml/processing/output/eval.json"))


def main() -> None:
    tok = AutoTokenizer.from_pretrained(MODEL_DIR)
    model = AutoModelForSequenceClassification.from_pretrained(MODEL_DIR)
    label2id = json.loads((MODEL_DIR / "label2id.json").read_text(encoding="utf-8"))
    id2label = {v: k for k, v in label2id.items()}

    rows = [json.loads(l) for l in GOLDEN.read_text(encoding="utf-8").splitlines() if l.strip()]
    correct = 0
    by_class: Counter = Counter()
    by_class_correct: Counter = Counter()
    for r in rows:
        enc = tok(r["transcript"], truncation=True, max_length=512, return_tensors="pt")
        with torch.no_grad():
            out = model(**enc)
        pred_id = int(out.logits.argmax(dim=-1).item())
        pred_code = id2label[pred_id]
        by_class[r["대code"]] += 1
        if pred_code == r["대code"]:
            correct += 1
            by_class_correct[r["대code"]] += 1

    per_class_acc = {c: by_class_correct[c] / by_class[c] for c in by_class}
    eval_payload = {
        "n": len(rows),
        "accuracy_대": correct / len(rows) if rows else 0,
        "per_class_accuracy": per_class_acc,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(eval_payload, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(eval_payload, ensure_ascii=False))


if __name__ == "__main__":
    main()
```

### Step ML3.3: 단위 테스트 + Dockerfile

- [ ] **Write `tests/unit/test_ml_evaluate.py`**

```python
"""evaluate.py 메트릭 계산 단위 테스트 (모델 호출 부분은 stub)."""
import json
from pathlib import Path
from unittest.mock import MagicMock, patch


def test_per_class_accuracy_computed(tmp_path: Path) -> None:
    golden = tmp_path / "samples.jsonl"
    golden.write_text(
        "\n".join([
            json.dumps({"transcript": "t1", "대code": "A"}),
            json.dumps({"transcript": "t2", "대code": "A"}),
            json.dumps({"transcript": "t3", "대code": "B"}),
        ]),
        encoding="utf-8",
    )
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    (model_dir / "label2id.json").write_text(json.dumps({"A": 0, "B": 1}), encoding="utf-8")
    out = tmp_path / "eval.json"

    fake_tok = MagicMock()
    fake_tok.return_value = {"input_ids": MagicMock(), "attention_mask": MagicMock()}
    fake_model = MagicMock()
    # 항상 A 예측 (id=0) → A 100%, B 0%
    import torch
    fake_model.return_value = type("X", (), {"logits": torch.tensor([[1.0, 0.0]])})()

    import os
    os.environ["MODEL_DIR"] = str(model_dir)
    os.environ["GOLDEN_JSONL"] = str(golden)
    os.environ["OUT"] = str(out)

    with patch("ml.evaluate.AutoTokenizer.from_pretrained", return_value=fake_tok), patch(
        "ml.evaluate.AutoModelForSequenceClassification.from_pretrained", return_value=fake_model
    ):
        from ml import evaluate

        evaluate.main()

    data = json.loads(out.read_text(encoding="utf-8"))
    assert data["accuracy_대"] == 2 / 3  # A 2건 맞음 / 3건 전체
    assert data["per_class_accuracy"]["A"] == 1.0
    assert data["per_class_accuracy"]["B"] == 0.0
```

- [ ] **Write `src/ml/Dockerfile`** (SageMaker base image 기반)

```dockerfile
FROM 763104351884.dkr.ecr.ap-northeast-2.amazonaws.com/pytorch-training:2.4.0-gpu-py311-cu124-ubuntu22.04-sagemaker

RUN pip install --no-cache-dir transformers==4.45.0 datasets==3.0.0
COPY ml/ /opt/ml/code/
ENV SAGEMAKER_PROGRAM=train.py
ENV PYTHONPATH=/opt/ml/code
```

- [ ] **Build + push training image**

```bash
ECR_TR="<ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com/callcenter-dev-ml-trainer"
aws ecr create-repository --repository-name callcenter-dev-ml-trainer
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_TR%/*}"
docker build -t "${ECR_TR}:0.1.0" -f src/ml/Dockerfile src/
docker push "${ECR_TR}:0.1.0"
```

- [ ] **dev 1회 Training Job 실행 (수동)**

```bash
aws sagemaker create-training-job --training-job-name "callcenter-dev-ml-bootstrap-001" \
  --algorithm-specification "TrainingImage=${ECR_TR}:0.1.0,TrainingInputMode=File" \
  --role-arn arn:aws:iam::ACCOUNT:role/callcenter-dev-sagemaker-train \
  --resource-config "InstanceType=ml.g5.xlarge,InstanceCount=1,VolumeSizeInGB=30" \
  --stopping-condition "MaxRuntimeInSeconds=3600" \
  --input-data-config '[{"ChannelName":"train","DataSource":{"S3DataSource":{"S3DataType":"S3Prefix","S3Uri":"s3://kakaopay-callcenter-dev-ml/training-sets/v0/","S3DataDistributionType":"FullyReplicated"}}},{"ChannelName":"val","DataSource":{"S3DataSource":{"S3DataType":"S3Prefix","S3Uri":"s3://kakaopay-callcenter-dev-ml/val-sets/v0/","S3DataDistributionType":"FullyReplicated"}}}]' \
  --output-data-config "S3OutputPath=s3://kakaopay-callcenter-dev-ml/models/"
```

- [ ] **Commit**

```bash
git add src/ml/{train.py,evaluate.py,Dockerfile} tests/unit/test_ml_evaluate.py
git commit -m "feat(ml): training + evaluation scripts + KLUE-BERT Dockerfile"
```

---

## ML-PR4 ~ ML-PR9 (요약 구조)

> 이하 PR은 ML-PR1~3의 패턴(단위 테스트 → 구현 → Terraform → dev 검증 → 커밋)을 동일하게 따릅니다. 각 PR의 핵심 산출물과 검증 게이트만 명시합니다 (각 step의 코드 패턴은 Phase 1 PR들과 동일한 방식으로 작성).

### ML-PR4: SageMaker Pipeline + Model Registry

**핵심 산출물**:
- `infra/modules/continuous-learning/{pipeline.tf,registry.tf,training.tf}`
- SageMaker Pipeline 정의 (boto3 또는 Terraform `aws_sagemaker_pipeline`):
  단계: DataExtract(Lambda) → DataValidate(Lambda) → Processing(전처리) → TrainingStep → ProcessingStep(평가) → ConditionStep(회귀 ≤ -1%p?) → RegisterModel
- ModelPackageGroup `callcenter-{env}-classifier-대` 생성

**검증 게이트**:
- 수동 1회 `aws sagemaker start-pipeline-execution` → 모든 step 성공 → Registry에 ModelPackageVersion 1 등록 확인

### ML-PR5: Endpoint blue/green + ML 라이브

**핵심 산출물**:
- `infra/modules/continuous-learning/endpoint.tf` — `aws_sagemaker_endpoint_configuration` Production Variants A(100%)+B(0%) → blue/green
- classify Lambda 환경변수 `ML_ENDPOINT_NAME` 채움
- 첫 모델 ProductionVariant A로 100% 배포

**검증 게이트**:
- `aws sagemaker invoke-endpoint` 직접 호출 → 응답 < 500ms
- E2E smoke 재실행 → DDB record에 `usedMl=true`로 1건 적재 확인

### ML-PR6: 데이터 추출 Lambda (Athena CTAS) + 검증 Lambda

**핵심 산출물**:
- `src/lambdas/ml_data_extract/handler.py` — Athena CTAS 실행, 결과 S3 `ml-data/training-sets/date=YYYY-MM-DD/` 적재
- `src/lambdas/ml_data_validate/handler.py` — §3.8.5 게이트 5가지 검증 (최소량/커버리지/skew/신규 클래스/conf 급락)
- EventBridge cron `cron(0 17 * * ? *)` UTC = 02:00 KST → SageMaker Pipeline 시작

**검증 게이트**:
- LocalStack 또는 dev에서 Lambda 단독 실행 → 정상 데이터/이상 데이터 케이스별 분기 동작

### ML-PR7: 카나리 자동 배포 + Slack 1-클릭 승인

**핵심 산출물**:
- 카나리 자동 배포 Lambda (`promote_canary`) — Pipeline 마지막 단계가 호출
- Slack interactive endpoint Lambda (API Gateway HTTP API + Lambda)
- `scripts/promote_model.py` — Slack 콜백이 호출 → ProductionVariant traffic 0→100 변경

**검증 게이트**:
- 인공 두 번째 모델 등록 → Pipeline → Slack 메시지 도착 → 승인 클릭 → endpoint config 갱신 확인

### ML-PR8: Model Monitor + drift alarms + Streamlit "오늘의 모델"

**핵심 산출물**:
- `infra/modules/continuous-learning/monitoring.tf` — Model Monitor schedule + DataQuality baseline
- CloudWatch 알람 추가: `model.accuracy.daily` 하락, `model.canary.confidence_delta` 이탈
- `src/hitl_ui/pages/4_model_status.py` — 어젯밤 학습 결과·정확도 변화·승격 대기열

**검증 게이트**:
- Streamlit UI에 새 페이지 표시 + 마지막 Registry version 메트릭 그려짐

### ML-PR9: CI/CD + 자동 학습 통합 + 런북

**핵심 산출물**:
- `.github/workflows/ml-build.yml` — train Dockerfile 변경 시 ECR 푸시
- `.github/workflows/ml-pipeline-kick.yml` — `workflow_dispatch`로 수동 트리거
- 런북 3개:
  - `docs/runbooks/ml-regression-block.md` — 자동 학습이 회귀로 차단됐을 때 분석/재시도
  - `docs/runbooks/ml-canary-rollback.md` — 카나리 단계 자동 롤백 발생 시 진단
  - `docs/runbooks/ml-drift-detected.md` — Model Monitor drift 알람 대응

**검증 게이트**:
- 매일 02:00 KST 자동 실행 1주 관찰 → 실패율 < 5%
- 회귀 인공 케이스(평가셋에 일부 잘못된 라벨 삽입) → 차단 알람 정상 도착

---

## 검증 게이트 요약 (PR별)

| PR | 게이트 |
|----|--------|
| ML-PR1 | 캐스케이드 단위 테스트 2건 pass; ML 미존재 시 graceful fallback |
| ML-PR2 | bootstrap 실행 → 합성+paraphrase ~6K row jsonl; 합의 필터 적중률 ≥ 60% |
| ML-PR3 | dev Training Job 1회 성공; eval.json `accuracy_대` ≥ 0.75 |
| ML-PR4 | Pipeline 수동 실행 → 모든 단계 성공 → Registry에 version 1 |
| ML-PR5 | Endpoint 호출 < 500ms; E2E smoke `usedMl=true` 1건 |
| ML-PR6 | data_validate 5가지 게이트 단위 테스트 + cron 1회 실행 |
| ML-PR7 | 인공 새 모델 → Slack 메시지 → 클릭 → endpoint config 변경 확인 |
| ML-PR8 | Streamlit 새 페이지 표시; 인공 drift → 알람 |
| ML-PR9 | 7일 자동 실행 관찰 실패율 < 5%; 회귀 차단 알람 1건 |

---

## Self-Review

**Spec coverage (§3.7~§3.8) 점검**:
- §3.7.5 합성 데이터 증강 (real 500 + LLM 3.5K + paraphrase 2K = ~6K) → ML-PR2
- §3.8.2 전체 흐름 (cron → SageMaker Pipeline 9단계) → ML-PR4 + ML-PR6 + ML-PR7
- §3.8.3 구성요소 (Pipeline, Registry, Endpoint, Monitor) → ML-PR4/5/8
- §3.8.4 Athena CTAS SQL → ML-PR6
- §3.8.5 데이터 검증 게이트 5건 → ML-PR6 data_validate Lambda
- §3.8.6 승격 게이트 (회귀, 개선, 카나리, 승인) → ML-PR4 ConditionStep + ML-PR7
- §3.8.7 분석가 UI 5개 (오늘의 업데이트, 잠금, 가중치, 평가셋 추가, 승격 대기) → ML-PR8 (page 4 통합)
- §3.8.8 스토리지 (training-sets, models, eval-results, lineage) → ML-PR6
- §3.8.9 비용 (~$25/day 추가) → 본 계획에 명시
- §3.8.10 Terraform 모듈 구조 → 본 계획에 명시 (modules/continuous-learning/*)
- §3.8.11 메트릭 6개 → ML-PR8 monitoring.tf

**누락 보강**:
- §3.7.4 데이터 수집 가속 (샘플링률 상향, active learning, 다중 LLM pseudo-label, 자가 라벨링) → Phase 1 PR8 Streamlit UI에 EventBridge cron + 추가 페이지 형태로 통합 가능. 본 plan에는 명시적 PR 없음 — ML-PR6에 cron job 1개 추가하는 형태로 보강 가능. 운영 1개월 후 분석팀 요청에 따라 별도 PR로.

**Placeholder scan**: 
- ML-PR4~9는 위에서 요약 형태로 처리. 각 PR의 step-by-step bite-sized 형태는 실제 실행 단계에서 ML-PR1~3 패턴을 그대로 따라 작성. 핵심 코드 블록(boto3 SageMaker API 호출, Terraform 리소스)은 AWS 공식 예제에 직접 매칭되므로 PR 진입 시 보조 자료로 보강.
- 본 plan은 실행 게이트와 산출물에 집중. 각 PR의 세부 step은 dev 환경에서 첫 단계 수행 시 동일 패턴으로 확장.

**Type consistency**: `ClassificationResult`, `InferenceAdapter`, `MlEndpointConfig` 모두 Phase 1과 일관.

---

## 실행 옵션

Plan complete and saved to `docs/superpowers/plans/2026-05-22-phase3-mlops-continuous-learning.md`.

**Phase 1 + Phase 3 두 plan이 모두 작성되었습니다.** 실행 방식 두 가지:

1. **Subagent-Driven (recommended)** — PR 단위로 subagent 1개씩 dispatch, 매 PR 종료 후 사용자 리뷰 → 다음 PR. 학습 회귀·인프라 오류 같은 큰 변화를 빠르게 잡고 dev 환경에 실제 적용하며 진행. `superpowers:subagent-driven-development` 사용.

2. **Inline Execution** — 본 세션에서 PR을 batch로 진행하면서 체크포인트마다 확인. 인프라 비용·자원이 즉시 발생하므로 적절한 stop point에서 사용자 확인 필요. `superpowers:executing-plans` 사용.

**어떤 방식으로 진행할까요?**
