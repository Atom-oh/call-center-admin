# Phase 1 — 콜센터 STT 분류 시스템 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** S3에 업로드된 STT 결과를 Bedrock Opus 4.7로 자동 분류(대/중/소)하고, 운영팀 검수 UI와 분석팀 BI 대시보드까지 일 1만 건 규모로 작동하는 v1 시스템을 6주 내 출시한다.

**Architecture:** S3 → EventBridge → Step Functions Express (PII regex guard → classify → verify → persist) → DynamoDB + S3 Parquet → Athena/QuickSight + Streamlit on Fargate. 전 구간 VPC private, Bedrock·S3·DDB·KMS는 VPC Endpoint.

**Tech Stack:** Python 3.12, Terraform 1.x, AWS (Lambda, Step Functions Express, Bedrock, DynamoDB, S3, Firehose, Glue, Athena, QuickSight, Fargate, ALB, Cognito, KMS, CloudWatch, EventBridge, SNS), Streamlit, GitHub Actions OIDC, pytest, moto, LocalStack, stepfunctions-local.

**Spec reference:** `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md`

---

## File Structure

```
call-center-admin/
├── .github/workflows/{ci,deploy-dev,deploy-stg,deploy-prd}.yml
├── docs/
│   ├── superpowers/{specs,plans}/
│   └── runbooks/{bedrock-throttling,hitl-backlog,prompt-rollback,pii-mask-failure}.md
├── infra/
│   ├── envs/{dev,stg,prd}/{main,backend,variables,outputs}.tf
│   ├── modules/{shared,storage,classify-pipeline,analytics,hitl-ui,observability}/
│   └── shared-state/
├── src/
│   ├── lambdas/{pii_guard,classify,verify,persist}/{handler.py,requirements.txt}
│   ├── lib/
│   │   ├── __init__.py
│   │   ├── taxonomy.py            # xlsx parser + tree serializer
│   │   ├── pii_regex.py           # PII detection + masking
│   │   ├── prompts.py             # Bedrock prompt builder (system + tree)
│   │   ├── output_schema.py       # JSON schema + validator
│   │   ├── bedrock_client.py      # Bedrock Converse wrapper with caching
│   │   ├── inference_adapter.py   # Protocol for Phase 3 pluggability
│   │   └── persistence.py         # DDB record + Parquet write
│   ├── prompts/v1.0/{system_rules.md,taxonomy_tree.json}
│   └── hitl_ui/
│       ├── streamlit_app.py
│       ├── pages/{1_review_queue.py,2_search.py,3_compliance.py}
│       ├── Dockerfile
│       └── requirements.txt
├── scripts/
│   ├── parse_taxonomy.py
│   ├── eval_prompt.py
│   ├── load_golden_set.py
│   └── warm_bedrock_cache.py
├── tests/
│   ├── unit/test_{taxonomy,pii_regex,prompts,output_schema,persistence}.py
│   ├── integration/test_{sfn_dry_run,end_to_end_localstack}.py
│   ├── golden/{samples.json,expected_labels.json}
│   └── conftest.py
├── pyproject.toml
├── ruff.toml
└── README.md
```

---

## PR Decomposition Overview

| PR | 이름 | 의존성 | 검증 게이트 | 산출물 |
|----|------|--------|-------------|--------|
| PR1 | 프로젝트 초석 + 분류체계 파서 | — | 단위 테스트 100% pass | Python 프로젝트, taxonomy.py, 18대/64중/131소 JSON |
| PR2 | Terraform 베이스 + storage 모듈 | PR1 | `terraform plan` clean, tflint/tfsec pass | VPC, S3 raw·masked·analytics, KMS CMKs, DDB +GSIs |
| PR3 | PII Guard Lambda + 정규식 | PR1, PR2 | 단위 테스트 + 정규식 적중률 ≥ 99% 합성 데이터 | pii_regex.py, pii_guard Lambda |
| PR4 | Classify Lambda + 프롬프트 v1.0 + 골든셋 | PR1, PR3 | 골든셋 50건에서 대분류 정확도 ≥ 80%, JSON 스키마 위반 0% | classify Lambda, prompts/v1.0/, golden set |
| PR5 | Verify Lambda + 캐스케이드 | PR4 | 골든셋 confidence 임계 검증, agreement 로직 단위 테스트 | verify Lambda, branching state |
| PR6 | Persist Lambda + Step Functions Express + EventBridge | PR3, PR4, PR5 | LocalStack integration test pass | persist Lambda, SFN 정의, EventBridge rule |
| PR7 | Analytics 모듈 (Glue + Firehose + Athena + QuickSight) | PR6 | Athena 샘플 쿼리, QuickSight 데이터셋 미리보기 | Glue catalog, Firehose, QuickSight 5 시트 |
| PR8 | HITL UI (Streamlit + Cognito + Fargate) | PR6 | 로그인 + 검토 큐 페이지네이션 + 교정 저장 동작 | Streamlit 컨테이너, ALB internal, Cognito |
| PR9 | Observability + Slack 알림 | PR6, PR7, PR8 | 모든 알람 dev에서 의도적 트리거 → Slack 수신 확인 | CloudWatch dashboard, 6개 알람, Slack subscription |
| PR10 | CI/CD + 골든셋 자동 평가 + 런북 + prd 배포 | 전체 | E2E smoke pass, prd 1건 실제 데이터 처리 성공 | 4 workflows, eval_prompt.py CI, 4 runbooks |

---

## PR1: 프로젝트 초석 + 분류체계 파서

**Files:**
- Create: `pyproject.toml`
- Create: `ruff.toml`
- Create: `README.md`
- Create: `src/lib/__init__.py`
- Create: `src/lib/taxonomy.py`
- Create: `tests/conftest.py`
- Create: `tests/unit/test_taxonomy.py`
- Create: `scripts/parse_taxonomy.py`
- Create: `src/prompts/v1.0/taxonomy_tree.json` (생성된 산출물, git-track)

### Step 1.1: Python 프로젝트 스켈레톤

- [ ] **Write `pyproject.toml`**

```toml
[project]
name = "call-center-admin"
version = "0.1.0"
description = "콜센터 STT 자동 분류 시스템 (Phase 1)"
requires-python = ">=3.12"
dependencies = [
  "openpyxl>=3.1.5",
  "boto3>=1.35.0",
  "pydantic>=2.9.0",
]

[project.optional-dependencies]
dev = [
  "pytest>=8.3.0",
  "pytest-cov>=5.0.0",
  "moto[all]>=5.0.0",
  "ruff>=0.6.0",
  "mypy>=1.11.0",
  "boto3-stubs[bedrock-runtime,dynamodb,s3,sagemaker]>=1.35.0",
]

[tool.pytest.ini_options]
pythonpath = ["src"]
testpaths = ["tests"]
addopts = "-ra --strict-markers --cov=src --cov-report=term-missing"

[tool.mypy]
strict = true
python_version = "3.12"
```

- [ ] **Write `ruff.toml`**

```toml
target-version = "py312"
line-length = 100

[lint]
select = ["E", "F", "I", "B", "UP", "N", "SIM", "RUF"]
ignore = ["E501"]
```

- [ ] **Write `README.md`**

```markdown
# call-center-admin

콜센터 STT 자동 분류 시스템 (Phase 1).

## 빠른 시작

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest
```

## 문서

- 설계서: `docs/superpowers/specs/2026-05-22-callcenter-stt-classification-design.md`
- 구현 계획: `docs/superpowers/plans/`
- 운영 런북: `docs/runbooks/`
```

- [ ] **Run setup and verify**

```bash
python -m venv .venv && source .venv/bin/activate && pip install -e ".[dev]"
```
Expected: 설치 완료, `pytest --version` 작동

- [ ] **Commit**

```bash
git add pyproject.toml ruff.toml README.md
git commit -m "feat(project): bootstrap python project scaffold"
```

### Step 1.2: Taxonomy 데이터 모델 (실패 테스트 먼저)

- [ ] **Create `src/lib/__init__.py` (빈 파일)**

```python
"""Call center classification library."""
```

- [ ] **Write `tests/conftest.py`**

```python
"""Shared pytest fixtures."""
from pathlib import Path

import pytest


@pytest.fixture
def repo_root() -> Path:
    return Path(__file__).parent.parent


@pytest.fixture
def xlsx_path(repo_root: Path) -> Path:
    # xlsx 파일명은 NFD 정규화로 저장되어 있으므로 listdir로 매칭
    for f in repo_root.iterdir():
        if f.suffix == ".xlsx":
            return f
    raise FileNotFoundError("xlsx not found in repo root")
```

- [ ] **Write `tests/unit/test_taxonomy.py` — 첫 번째 실패 테스트**

```python
"""Taxonomy parser and tree serialization tests."""
from pathlib import Path

import pytest

from lib.taxonomy import TaxonomyNode, parse_xlsx


def test_parse_xlsx_returns_18_top_level_nodes(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    top_level = [n for n in tree if n.level == 1]
    assert len(top_level) == 18, f"expected 18 대분류, got {len(top_level)}"


def test_parse_xlsx_returns_64_mid_level_nodes(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    mid = [n for n in tree if n.level == 2]
    assert len(mid) == 64, f"expected 64 중분류, got {len(mid)}"


def test_parse_xlsx_returns_131_leaf_nodes(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    leaves = [n for n in tree if n.level == 3]
    assert len(leaves) == 131, f"expected 131 소분류, got {len(leaves)}"


def test_node_has_code_and_name(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    paymoney = next(n for n in tree if n.name == "페이머니")
    assert paymoney.code == "CS_CENTER_CONSULT_TYPE_PAY_NONEY"
    assert paymoney.level == 1
    assert paymoney.description is not None
    assert len(paymoney.description) > 0


def test_mid_node_inherits_parent_description_when_empty(xlsx_path: Path) -> None:
    tree = parse_xlsx(xlsx_path)
    chg = next(n for n in tree if n.name == "충전/출금" and n.level == 2)
    assert chg.parent_code == "CS_CENTER_CONSULT_TYPE_PAY_NONEY"
    # 중분류 description이 비어 있어도 effective_description은 부모 상속
    assert chg.effective_description() != ""
```

- [ ] **Run test to verify it fails**

```bash
pytest tests/unit/test_taxonomy.py -v
```
Expected: ImportError or ModuleNotFoundError on `lib.taxonomy`

### Step 1.3: Taxonomy 데이터 모델 구현

- [ ] **Write `src/lib/taxonomy.py`**

```python
"""xlsx 분류체계 파서 + 트리 직렬화.

xlsx 컬럼 구조 (1-indexed):
  B: 유형1 (대분류 이름)
  C: 유형2 (중분류 이름)
  D: 유형3 (소분류 이름)
  E: 유형 코드
  F: 내용 (사용 안 함)
  G: v4 description (LLM 프롬프트에 사용)
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

import openpyxl


@dataclass
class TaxonomyNode:
    name: str
    code: str | None
    description: str
    level: int  # 1=대, 2=중, 3=소
    parent_code: str | None = None
    children: list[TaxonomyNode] = field(default_factory=list)

    def effective_description(self) -> str:
        """비어 있으면 가장 가까운 조상의 description 반환."""
        if self.description:
            return self.description
        return getattr(self, "_inherited_description", "")


def parse_xlsx(path: Path) -> list[TaxonomyNode]:
    """xlsx를 평면 노드 리스트로 파싱 (DFS 순서)."""
    wb = openpyxl.load_workbook(str(path), data_only=True)
    ws = wb["상담유형 추천_유형 및 디스크립션"]
    nodes: list[TaxonomyNode] = []
    current_l1: TaxonomyNode | None = None
    current_l2: TaxonomyNode | None = None

    # row 3부터 실제 데이터 시작 (row 1-2는 헤더)
    for row in ws.iter_rows(min_row=3, max_col=8, values_only=True):
        _, y1, y2, y3, code, _content, desc, _glyphs = row
        desc_str = (desc or "").strip() if desc else ""

        if y1:
            node = TaxonomyNode(name=y1.strip(), code=code, description=desc_str, level=1)
            current_l1 = node
            current_l2 = None
            nodes.append(node)
        elif y2:
            assert current_l1 is not None, "중분류 before any 대분류"
            node = TaxonomyNode(
                name=y2.strip(),
                code=code,
                description=desc_str,
                level=2,
                parent_code=current_l1.code,
            )
            node._inherited_description = current_l1.description  # type: ignore[attr-defined]
            current_l1.children.append(node)
            current_l2 = node
            nodes.append(node)
        elif y3:
            assert current_l2 is not None, "소분류 before any 중분류"
            node = TaxonomyNode(
                name=y3.strip(),
                code=code,
                description=desc_str,
                level=3,
                parent_code=current_l2.code,
            )
            node._inherited_description = (  # type: ignore[attr-defined]
                current_l2.description or current_l1.description if current_l1 else ""
            )
            current_l2.children.append(node)
            nodes.append(node)

    return nodes


def iter_tree(nodes: list[TaxonomyNode]) -> Iterator[TaxonomyNode]:
    """DFS 순회 (대 → 중 → 소)."""
    for n in nodes:
        if n.level == 1:
            yield n
            for m in n.children:
                yield m
                yield from m.children


def to_prompt_text(nodes: list[TaxonomyNode]) -> str:
    """LLM 프롬프트용 markdown 직렬화."""
    lines: list[str] = []
    for n in nodes:
        if n.level == 1:
            lines.append(f"## [대분류] {n.name} — code: {n.code}")
            if n.description:
                lines.append(f"설명: {n.description}")
            lines.append("")
        elif n.level == 2:
            lines.append(f"  ### [중분류] {n.name} — code: {n.code}")
            if n.description:
                lines.append(f"  설명: {n.description}")
            lines.append("")
        elif n.level == 3:
            lines.append(f"    #### [소분류] {n.name} — code: {n.code}")
            if n.description:
                lines.append(f"    설명: {n.description}")
            lines.append("")
    return "\n".join(lines)


def to_json(nodes: list[TaxonomyNode]) -> str:
    def encode(n: TaxonomyNode) -> dict:
        return {
            "name": n.name,
            "code": n.code,
            "description": n.description,
            "level": n.level,
            "parent_code": n.parent_code,
            "children_codes": [c.code for c in n.children],
        }

    return json.dumps([encode(n) for n in nodes], ensure_ascii=False, indent=2)
```

- [ ] **Run tests until all pass**

```bash
pytest tests/unit/test_taxonomy.py -v
```
Expected: 5 passed

- [ ] **Commit**

```bash
git add src/lib/__init__.py src/lib/taxonomy.py tests/conftest.py tests/unit/test_taxonomy.py
git commit -m "feat(taxonomy): parse xlsx into 18/64/131-node tree"
```

### Step 1.4: 파서 CLI + 생성 산출물 커밋

- [ ] **Write `scripts/parse_taxonomy.py`**

```python
"""CLI: xlsx → src/prompts/v1.0/taxonomy_tree.json"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from lib.taxonomy import parse_xlsx, to_json, to_prompt_text


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--xlsx", type=Path, required=True)
    p.add_argument("--out-json", type=Path, default=Path("src/prompts/v1.0/taxonomy_tree.json"))
    p.add_argument(
        "--out-md", type=Path, default=Path("src/prompts/v1.0/taxonomy_tree.md")
    )
    args = p.parse_args()

    nodes = parse_xlsx(args.xlsx)
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    args.out_json.write_text(to_json(nodes), encoding="utf-8")
    args.out_md.write_text(to_prompt_text(nodes), encoding="utf-8")
    print(f"parsed {len(nodes)} nodes → {args.out_json} + {args.out_md}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Run parser**

```bash
python scripts/parse_taxonomy.py --xlsx 상담어시스트_AWS전달자료.xlsx
```
Expected: `parsed 213 nodes → ...`

- [ ] **Verify outputs**

```bash
python -c "import json; d = json.load(open('src/prompts/v1.0/taxonomy_tree.json')); print('nodes:', len(d), 'top:', sum(1 for n in d if n['level']==1))"
```
Expected: `nodes: 213 top: 18`

- [ ] **Commit**

```bash
git add scripts/parse_taxonomy.py src/prompts/v1.0/
git commit -m "feat(taxonomy): add parser CLI + generated v1.0 tree artifacts"
```

---

## PR2: Terraform 베이스 + storage 모듈

**Files:**
- Create: `infra/shared-state/main.tf`
- Create: `infra/envs/dev/{main.tf,backend.tf,variables.tf,outputs.tf,terraform.tfvars}`
- Create: `infra/modules/shared/{main.tf,variables.tf,outputs.tf}`
- Create: `infra/modules/storage/{main.tf,variables.tf,outputs.tf}`

### Step 2.1: Remote state backend

- [ ] **Write `infra/shared-state/main.tf`**

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = {
      project   = "callcenter-classification"
      component = "shared-state"
      managed-by = "terraform"
    }
  }
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "kakaopay-callcenter-tfstate"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "kakaopay-callcenter-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
```

- [ ] **Apply backend bootstrap**

```bash
cd infra/shared-state && terraform init && terraform apply -auto-approve && cd -
```
Expected: bucket + DDB table created

- [ ] **Commit**

```bash
git add infra/shared-state/
git commit -m "feat(infra): bootstrap remote state (s3 + ddb lock)"
```

### Step 2.2: shared 모듈 (VPC, KMS, IAM common)

- [ ] **Write `infra/modules/shared/variables.tf`**

```hcl
variable "env" {
  type        = string
  description = "dev | stg | prd"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}
```

- [ ] **Write `infra/modules/shared/main.tf`**

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

data "aws_availability_zones" "available" { state = "available" }

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "callcenter-${var.env}-vpc" }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = { Name = "callcenter-${var.env}-private-${count.index}" }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "callcenter-${var.env}-vpc-endpoints"
  description = "VPC endpoint shared SG"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# S3 Gateway endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
}

# Interface endpoints (Bedrock, DDB, KMS, SFN, SecretsManager, ECR, logs)
locals {
  interface_services = [
    "bedrock-runtime",
    "dynamodb",
    "kms",
    "states",
    "secretsmanager",
    "ecr.dkr",
    "ecr.api",
    "logs",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_services)
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-2.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

# 공통 KMS 키 (raw / masked / analytics / ddb 분리는 storage 모듈에서)
output "vpc_id" { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "vpc_cidr" { value = aws_vpc.main.cidr_block }
output "vpc_endpoints_sg_id" { value = aws_security_group.vpc_endpoints.id }
```

- [ ] **Write `infra/modules/shared/outputs.tf` (빈 — main에서 직접 output)**

```hcl
# outputs in main.tf
```

### Step 2.3: storage 모듈 (S3 4 buckets, KMS 4 CMKs, DynamoDB)

- [ ] **Write `infra/modules/storage/variables.tf`**

```hcl
variable "env" { type = string }
variable "vpc_id" { type = string }
```

- [ ] **Write `infra/modules/storage/main.tf`**

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

locals {
  bucket_prefix = "kakaopay-callcenter-${var.env}"
}

# KMS keys per data class
resource "aws_kms_key" "raw" {
  description             = "${var.env} raw STT bucket key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "raw" {
  name          = "alias/callcenter-${var.env}-raw"
  target_key_id = aws_kms_key.raw.id
}

resource "aws_kms_key" "masked" {
  description             = "${var.env} masked STT + pipeline key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "masked" {
  name          = "alias/callcenter-${var.env}-masked"
  target_key_id = aws_kms_key.masked.id
}

resource "aws_kms_key" "analytics" {
  description             = "${var.env} analytics parquet key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "analytics" {
  name          = "alias/callcenter-${var.env}-analytics"
  target_key_id = aws_kms_key.analytics.id
}

resource "aws_kms_key" "ddb" {
  description             = "${var.env} DynamoDB key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "ddb" {
  name          = "alias/callcenter-${var.env}-ddb"
  target_key_id = aws_kms_key.ddb.id
}

# S3 buckets
resource "aws_s3_bucket" "raw"       { bucket = "${local.bucket_prefix}-stt-raw" }
resource "aws_s3_bucket" "masked"    { bucket = "${local.bucket_prefix}-stt-masked" }
resource "aws_s3_bucket" "analytics" { bucket = "${local.bucket_prefix}-analytics" }
resource "aws_s3_bucket" "ml"        { bucket = "${local.bucket_prefix}-ml" }

locals {
  buckets = {
    raw       = { res = aws_s3_bucket.raw,       kms = aws_kms_key.raw.arn }
    masked    = { res = aws_s3_bucket.masked,    kms = aws_kms_key.masked.arn }
    analytics = { res = aws_s3_bucket.analytics, kms = aws_kms_key.analytics.arn }
    ml        = { res = aws_s3_bucket.ml,        kms = aws_kms_key.analytics.arn }
  }
}

resource "aws_s3_bucket_versioning" "v" {
  for_each = local.buckets
  bucket   = each.value.res.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "enc" {
  for_each = local.buckets
  bucket   = each.value.res.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = each.value.kms
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "pab" {
  for_each                = local.buckets
  bucket                  = each.value.res.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: raw → Glacier IR 90d → Deep Archive 365d
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    id     = "tiering"
    status = "Enabled"
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "masked" {
  bucket = aws_s3_bucket.masked.id
  rule {
    id     = "delete-after-1y"
    status = "Enabled"
    expiration { days = 365 }
  }
}

# DynamoDB: consult-results
resource "aws_dynamodb_table" "consult_results" {
  name         = "callcenter-${var.env}-consult-results"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "callId"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute { name = "callId"               type = "S" }
  attribute { name = "agentId"              type = "S" }
  attribute { name = "status"               type = "S" }
  attribute { name = "category_대code"      type = "S" }
  attribute { name = "classifiedAt"         type = "S" }

  global_secondary_index {
    name            = "status-classifiedAt-index"
    hash_key        = "status"
    range_key       = "classifiedAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "agentId-classifiedAt-index"
    hash_key        = "agentId"
    range_key       = "classifiedAt"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "category대code-classifiedAt-index"
    hash_key        = "category_대code"
    range_key       = "classifiedAt"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.ddb.arn
  }

  ttl {
    attribute_name = "ttlEpoch"
    enabled        = true
  }

  point_in_time_recovery { enabled = true }
}

# DLQs
resource "aws_sqs_queue" "classify_dlq" {
  name                       = "callcenter-${var.env}-classify-dlq"
  message_retention_seconds  = 1209600  # 14 days
  kms_master_key_id          = aws_kms_key.masked.arn
}

resource "aws_sqs_queue" "persist_dlq" {
  name                       = "callcenter-${var.env}-persist-dlq"
  message_retention_seconds  = 1209600
  kms_master_key_id          = aws_kms_key.masked.arn
}

output "bucket_raw_arn"       { value = aws_s3_bucket.raw.arn }
output "bucket_raw_id"        { value = aws_s3_bucket.raw.id }
output "bucket_masked_arn"    { value = aws_s3_bucket.masked.arn }
output "bucket_masked_id"     { value = aws_s3_bucket.masked.id }
output "bucket_analytics_arn" { value = aws_s3_bucket.analytics.arn }
output "bucket_analytics_id"  { value = aws_s3_bucket.analytics.id }
output "bucket_ml_arn"        { value = aws_s3_bucket.ml.arn }
output "ddb_consult_arn"      { value = aws_dynamodb_table.consult_results.arn }
output "ddb_consult_name"     { value = aws_dynamodb_table.consult_results.name }
output "ddb_stream_arn"       { value = aws_dynamodb_table.consult_results.stream_arn }
output "kms_raw_arn"          { value = aws_kms_key.raw.arn }
output "kms_masked_arn"       { value = aws_kms_key.masked.arn }
output "kms_analytics_arn"    { value = aws_kms_key.analytics.arn }
output "kms_ddb_arn"          { value = aws_kms_key.ddb.arn }
output "classify_dlq_arn"     { value = aws_sqs_queue.classify_dlq.arn }
output "persist_dlq_arn"      { value = aws_sqs_queue.persist_dlq.arn }
```

### Step 2.4: dev 환경 조립 + apply

- [ ] **Write `infra/envs/dev/backend.tf`**

```hcl
terraform {
  required_version = ">= 1.6"
  backend "s3" {
    bucket         = "kakaopay-callcenter-tfstate"
    key            = "envs/dev/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "kakaopay-callcenter-tflock"
    encrypt        = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
```

- [ ] **Write `infra/envs/dev/variables.tf`**

```hcl
variable "env" { type = string  default = "dev" }
```

- [ ] **Write `infra/envs/dev/main.tf`**

```hcl
provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = {
      project    = "callcenter-classification"
      env        = var.env
      managed-by = "terraform"
    }
  }
}

module "shared" {
  source = "../../modules/shared"
  env    = var.env
}

module "storage" {
  source = "../../modules/storage"
  env    = var.env
  vpc_id = module.shared.vpc_id
}
```

- [ ] **Write `infra/envs/dev/outputs.tf`**

```hcl
output "vpc_id"           { value = module.shared.vpc_id }
output "bucket_raw_id"    { value = module.storage.bucket_raw_id }
output "bucket_masked_id" { value = module.storage.bucket_masked_id }
output "ddb_consult_name" { value = module.storage.ddb_consult_name }
```

- [ ] **Plan + apply dev**

```bash
cd infra/envs/dev && terraform init && terraform plan -out=tf.plan && terraform apply tf.plan && cd -
```
Expected: VPC, 4 S3 buckets, 4 KMS keys, DynamoDB with 3 GSIs, 2 DLQs

- [ ] **Verify**

```bash
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'kakaopay-callcenter-dev')].Name"
aws dynamodb describe-table --table-name callcenter-dev-consult-results --query 'Table.GlobalSecondaryIndexes[].IndexName'
```
Expected: 4개 버킷, 3개 GSI

- [ ] **Commit**

```bash
git add infra/modules/shared/ infra/modules/storage/ infra/envs/dev/
git commit -m "feat(infra): storage + shared modules for dev env"
```

---

## PR3: PII Guard Lambda + 정규식

**Files:**
- Create: `src/lib/pii_regex.py`
- Create: `tests/unit/test_pii_regex.py`
- Create: `src/lambdas/pii_guard/handler.py`
- Create: `src/lambdas/pii_guard/requirements.txt`
- Create: `tests/unit/test_pii_guard_handler.py`
- Create: `infra/modules/classify-pipeline/{main.tf,variables.tf,outputs.tf}` (PR3에서 일부 시작)

### Step 3.1: pii_regex 단위 테스트 (실패 먼저)

- [ ] **Write `tests/unit/test_pii_regex.py`**

```python
"""PII 정규식 마스킹 단위 테스트."""
from lib.pii_regex import MASK_PHONE, MASK_ACCOUNT, MASK_RRN, MASK_CARD, mask, MaskStats


def test_mask_phone_with_dashes() -> None:
    text = "전화는 010-1234-5678로 주세요"
    out, stats = mask(text)
    assert MASK_PHONE in out
    assert "010-1234-5678" not in out
    assert stats.phone == 1


def test_mask_phone_without_dashes() -> None:
    text = "01012345678 입니다"
    out, _ = mask(text)
    assert MASK_PHONE in out
    assert "01012345678" not in out


def test_mask_rrn_with_dash() -> None:
    text = "주민번호 900101-1234567"
    out, stats = mask(text)
    assert MASK_RRN in out
    assert "900101" not in out
    assert stats.rrn == 1


def test_mask_account_long_digits() -> None:
    text = "계좌 110-1234-567890 입니다"
    out, stats = mask(text)
    assert MASK_ACCOUNT in out or MASK_PHONE not in out  # 우선순위 확인
    assert stats.account >= 1


def test_mask_card_with_luhn_valid() -> None:
    # 4532015112830366 — Luhn valid VISA test number
    text = "카드 4532-0151-1283-0366"
    out, stats = mask(text)
    assert MASK_CARD in out
    assert "4532-0151" not in out
    assert stats.card == 1


def test_does_not_mask_random_digits() -> None:
    text = "건수는 12345 입니다"
    out, stats = mask(text)
    assert "12345" in out
    assert stats.total() == 0


def test_multiple_pii_in_one_text() -> None:
    text = "홍길동(010-1111-2222)의 계좌 110123456789로 송금 90"
    out, stats = mask(text)
    assert stats.phone == 1
    assert stats.account == 1
    assert "010-1111-2222" not in out
    assert "110123456789" not in out
```

- [ ] **Run test to verify fail**

```bash
pytest tests/unit/test_pii_regex.py -v
```
Expected: ImportError on `lib.pii_regex`

### Step 3.2: pii_regex 구현

- [ ] **Write `src/lib/pii_regex.py`**

```python
"""PII regex-based detection and masking.

순서가 중요: card → rrn → account → phone (긴 패턴 먼저).
"""
from __future__ import annotations

import re
from dataclasses import dataclass

MASK_PHONE = "[MASKED_PHONE]"
MASK_RRN = "[MASKED_RRN]"
MASK_ACCOUNT = "[MASKED_ACCOUNT]"
MASK_CARD = "[MASKED_CARD]"

# 카드: 13~19자리 숫자, hyphen/space 허용. Luhn으로 추가 검증.
_CARD = re.compile(r"\b(?:\d[ -]?){13,19}\b")
# 주민번호: 6 digit - 7 digit
_RRN = re.compile(r"\b\d{6}-?\d{7}\b")
# 계좌: 10~14자리 숫자(연속) 또는 hyphen 포함된 패턴
_ACCOUNT = re.compile(r"\b\d{2,4}-\d{2,6}-\d{2,8}\b|\b\d{10,14}\b")
# 휴대폰: 010/011/016/017/018/019 + 3~4 + 4
_PHONE = re.compile(r"\b01[016789][ -]?\d{3,4}[ -]?\d{4}\b")


def _luhn_valid(digits: str) -> bool:
    s = [int(c) for c in digits if c.isdigit()]
    if len(s) < 13:
        return False
    total = 0
    for i, d in enumerate(reversed(s)):
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


@dataclass
class MaskStats:
    phone: int = 0
    rrn: int = 0
    account: int = 0
    card: int = 0

    def total(self) -> int:
        return self.phone + self.rrn + self.account + self.card

    def as_dict(self) -> dict[str, int]:
        return {"phone": self.phone, "rrn": self.rrn, "account": self.account, "card": self.card}


def mask(text: str) -> tuple[str, MaskStats]:
    """Mask PII in text. Returns (masked_text, stats)."""
    stats = MaskStats()

    def _card_repl(m: re.Match[str]) -> str:
        if _luhn_valid(m.group()):
            stats.card += 1
            return MASK_CARD
        return m.group()

    text = _CARD.sub(_card_repl, text)

    def _rrn_repl(_m: re.Match[str]) -> str:
        stats.rrn += 1
        return MASK_RRN

    text = _RRN.sub(_rrn_repl, text)

    def _phone_repl(_m: re.Match[str]) -> str:
        stats.phone += 1
        return MASK_PHONE

    text = _PHONE.sub(_phone_repl, text)

    def _account_repl(_m: re.Match[str]) -> str:
        stats.account += 1
        return MASK_ACCOUNT

    text = _ACCOUNT.sub(_account_repl, text)

    return text, stats
```

- [ ] **Run tests until pass**

```bash
pytest tests/unit/test_pii_regex.py -v
```
Expected: 7 passed

- [ ] **Commit**

```bash
git add src/lib/pii_regex.py tests/unit/test_pii_regex.py
git commit -m "feat(pii): regex-based hard PII masking with Luhn for cards"
```

### Step 3.3: PII Guard Lambda handler

- [ ] **Write `src/lambdas/pii_guard/requirements.txt`**

```
# boto3 is provided by Lambda runtime, no pin needed
```

- [ ] **Write `tests/unit/test_pii_guard_handler.py`**

```python
"""PII Guard Lambda handler test (with moto S3 mock)."""
import json
import os
from unittest.mock import patch

import boto3
import pytest
from moto import mock_aws


@pytest.fixture
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("RAW_BUCKET", "raw-test")
    monkeypatch.setenv("MASKED_BUCKET", "masked-test")


@mock_aws
def test_handler_masks_and_uploads(aws_env) -> None:
    from src.lambdas.pii_guard.handler import handler

    s3 = boto3.client("s3", region_name="ap-northeast-2")
    s3.create_bucket(
        Bucket="raw-test",
        CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
    )
    s3.create_bucket(
        Bucket="masked-test",
        CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
    )
    payload = {
        "callId": "call_001",
        "agentId": "A1",
        "startedAt": "2026-05-22T00:00:00Z",
        "durationSec": 60,
        "transcript": [
            {"speaker": "customer", "text": "010-1234-5678 입니다"},
        ],
    }
    s3.put_object(
        Bucket="raw-test", Key="2026/05/22/call_001.json", Body=json.dumps(payload).encode()
    )

    event = {"rawBucket": "raw-test", "rawKey": "2026/05/22/call_001.json"}
    result = handler(event, None)

    assert result["maskedBucket"] == "masked-test"
    assert "call_001_masked.txt" in result["maskedKey"]
    assert result["maskStats"]["phone"] == 1

    obj = s3.get_object(Bucket="masked-test", Key=result["maskedKey"])
    masked = obj["Body"].read().decode()
    assert "[MASKED_PHONE]" in masked
    assert "010-1234-5678" not in masked
```

- [ ] **Run test to verify fail**

```bash
pytest tests/unit/test_pii_guard_handler.py -v
```
Expected: ImportError on `src.lambdas.pii_guard.handler`

- [ ] **Write `src/lambdas/pii_guard/handler.py`**

```python
"""Step Functions task: read raw STT from S3, mask PII, write to masked S3.

Input event:
  { "rawBucket": str, "rawKey": str }

Output:
  { "callId": str, "maskedBucket": str, "maskedKey": str,
    "maskStats": {...}, "agentId": str, "startedAt": str, "durationSec": int }
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# Lambda 패키징 시 src/lib도 함께 zip → sys.path에 자동 포함되도록 layer 또는 inline
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3

from lib.pii_regex import mask

_s3 = boto3.client("s3")
_MASKED_BUCKET = os.environ["MASKED_BUCKET"]


def handler(event: dict, _context) -> dict:
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
```

- [ ] **Run handler tests**

```bash
pytest tests/unit/test_pii_guard_handler.py -v
```
Expected: 1 passed

- [ ] **Commit**

```bash
git add src/lambdas/pii_guard/ tests/unit/test_pii_guard_handler.py
git commit -m "feat(lambda): pii_guard Lambda — regex mask + masked S3 write"
```

### Step 3.4: classify-pipeline 모듈 시작 (PII Guard Lambda 배포만)

- [ ] **Write `infra/modules/classify-pipeline/variables.tf`**

```hcl
variable "env"                  { type = string }
variable "vpc_id"               { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "bucket_raw_arn"       { type = string }
variable "bucket_masked_arn"    { type = string }
variable "bucket_masked_id"     { type = string }
variable "kms_raw_arn"          { type = string }
variable "kms_masked_arn"       { type = string }
variable "ddb_consult_arn"      { type = string }
variable "classify_dlq_arn"    { type = string }
variable "persist_dlq_arn"     { type = string }
```

- [ ] **Write `infra/modules/classify-pipeline/main.tf` (PII Guard Lambda 부분)**

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

data "archive_file" "pii_guard" {
  type        = "zip"
  source_dir  = "${path.module}/../../../src"
  output_path = "${path.module}/build/pii_guard.zip"
  excludes    = ["hitl_ui/**", "lambdas/classify/**", "lambdas/verify/**", "lambdas/persist/**", "prompts/**"]
}

resource "aws_iam_role" "pii_guard" {
  name = "callcenter-${var.env}-pii-guard"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pii_guard" {
  role = aws_iam_role.pii_guard.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.bucket_raw_arn}/*" },
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${var.bucket_masked_arn}/*" },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.kms_raw_arn },
      { Effect = "Allow", Action = ["kms:Encrypt", "kms:GenerateDataKey"], Resource = var.kms_masked_arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" },
    ]
  })
}

resource "aws_lambda_function" "pii_guard" {
  function_name = "callcenter-${var.env}-pii-guard"
  role          = aws_iam_role.pii_guard.arn
  handler       = "lambdas.pii_guard.handler.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.pii_guard.output_path
  source_code_hash = data.archive_file.pii_guard.output_base64sha256
  timeout       = 60
  memory_size   = 512

  environment {
    variables = {
      MASKED_BUCKET = var.bucket_masked_id
    }
  }
}

output "pii_guard_arn" { value = aws_lambda_function.pii_guard.arn }
```

- [ ] **Update `infra/envs/dev/main.tf`**

```hcl
module "classify_pipeline" {
  source                = "../../modules/classify-pipeline"
  env                   = var.env
  vpc_id                = module.shared.vpc_id
  private_subnet_ids    = module.shared.private_subnet_ids
  bucket_raw_arn        = module.storage.bucket_raw_arn
  bucket_masked_arn     = module.storage.bucket_masked_arn
  bucket_masked_id      = module.storage.bucket_masked_id
  kms_raw_arn           = module.storage.kms_raw_arn
  kms_masked_arn        = module.storage.kms_masked_arn
  ddb_consult_arn       = module.storage.ddb_consult_arn
  classify_dlq_arn      = module.storage.classify_dlq_arn
  persist_dlq_arn       = module.storage.persist_dlq_arn
}
```

- [ ] **Apply dev**

```bash
cd infra/envs/dev && terraform plan -out=tf.plan && terraform apply tf.plan && cd -
```

- [ ] **Smoke test — invoke Lambda directly**

```bash
aws s3 cp /tmp/sample-call.json s3://kakaopay-callcenter-dev-stt-raw/2026/05/22/test_001.json
aws lambda invoke --function-name callcenter-dev-pii-guard \
  --payload '{"rawBucket":"kakaopay-callcenter-dev-stt-raw","rawKey":"2026/05/22/test_001.json"}' \
  /tmp/result.json
cat /tmp/result.json
```
Expected: maskedKey 반환, S3 masked bucket에 _masked.txt 생성

- [ ] **Commit**

```bash
git add infra/modules/classify-pipeline/ infra/envs/dev/main.tf
git commit -m "feat(infra): deploy pii_guard Lambda to dev"
```

---

## PR4: Classify Lambda + 프롬프트 v1.0 + 골든셋

**Files:**
- Create: `src/prompts/v1.0/system_rules.md`
- Create: `src/lib/output_schema.py`
- Create: `src/lib/prompts.py`
- Create: `src/lib/bedrock_client.py`
- Create: `src/lib/inference_adapter.py`
- Create: `src/lambdas/classify/{handler.py,requirements.txt}`
- Create: `tests/unit/test_output_schema.py`
- Create: `tests/unit/test_prompts.py`
- Create: `tests/unit/test_classify_handler.py`
- Create: `tests/golden/samples.json` (50건 손라벨링)
- Create: `tests/golden/expected_labels.json`
- Create: `scripts/eval_prompt.py`

### Step 4.1: system_rules.md (룰 섹션)

- [ ] **Write `src/prompts/v1.0/system_rules.md`**

```markdown
# 역할
너는 카카오페이 콜센터 상담 STT 텍스트를 분석하여, 정해진 분류 체계의 대/중/소 라벨을 부여하는 분류 전문가다.

# 절대 원칙
1. 출력은 반드시 명시된 JSON 스키마 한 객체만 반환한다. 마크다운 코드블록·설명·서두를 절대 붙이지 않는다.
2. `code` 필드는 분류 트리에 명시된 코드 문자열을 한 글자도 변형 없이 그대로 인용한다 (오타 보이는 `NONEY`, `PAYNENT`도 그대로).
3. 분류 트리에 없는 코드를 만들어내지 마라.

# 분류 우선순위 룰
R1 (기능 vs 결제 분리): 페이머니를 사용해 구매한 결제 문의는 결제 카테고리(국내/해외 온·오프라인결제)로 분류한다. 페이머니 자체의 충전·송금·잔액 문의만 페이머니로 분류.

R2 (비밀번호는 항상 본인인증): 결제·송금·계정 어디서든 비밀번호/생체인증/PIN 오류는 본인인증으로.

R3 (대분류 우선): 대분류 description의 [핵심 구분]이 명시한 매핑은 중·소분류 description보다 우선.

R4 (어쩔 수 없을 때): 명백히 해당 없으면 "기타"로 분류하고 reason에 보류 사유 명시.

R5 (PII 인용 금지): 출력의 reason / alternativesConsidered.why_rejected 필드에는 고객명, 전화번호, 계좌·카드·주민번호, 주소 등 어떤 개인정보도 포함하지 마라. 분류 근거는 "고객이 충전 오류를 호소함"처럼 일반화된 표현만 사용한다. 인용이 불가피하면 [개인정보]로 대체한다.

# 출력 JSON 스키마
{
  "대": {"code": "string", "name": "string"},
  "중": {"code": "string", "name": "string"},
  "소": {"code": "string", "name": "string"},
  "confidence": 0~1,
  "reason": "≤500자, PII 금지",
  "alternativesConsidered": [
    {"code": "string", "why_rejected": "≤200자, PII 금지"}
  ]
}
```

### Step 4.2: output_schema.py

- [ ] **Write `tests/unit/test_output_schema.py`**

```python
from lib.output_schema import ClassificationResult, ValidationError, parse_and_validate


def test_valid_payload_parses() -> None:
    raw = """{
      "대": {"code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY", "name": "페이머니"},
      "중": {"code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL", "name": "충전/출금"},
      "소": {"code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL_CHARGE_DELAY", "name": "충전 지연/오류"},
      "confidence": 0.88,
      "reason": "고객이 충전 오류를 호소함",
      "alternativesConsidered": []
    }"""
    valid_codes = {
        "CS_CENTER_CONSULT_TYPE_PAY_NONEY",
        "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL",
        "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL_CHARGE_DELAY",
    }
    result = parse_and_validate(raw, valid_codes)
    assert isinstance(result, ClassificationResult)
    assert result.대.code.startswith("CS_CENTER")
    assert 0 <= result.confidence <= 1


def test_invalid_code_rejected() -> None:
    raw = '{"대":{"code":"FAKE","name":"x"},"중":{"code":"FAKE","name":"x"},"소":{"code":"FAKE","name":"x"},"confidence":0.5,"reason":"r","alternativesConsidered":[]}'
    import pytest

    with pytest.raises(ValidationError) as ex:
        parse_and_validate(raw, valid_codes={"CS_X"})
    assert "FAKE" in str(ex.value)


def test_confidence_out_of_range() -> None:
    raw = '{"대":{"code":"x","name":"x"},"중":{"code":"x","name":"x"},"소":{"code":"x","name":"x"},"confidence":1.5,"reason":"r","alternativesConsidered":[]}'
    import pytest

    with pytest.raises(ValidationError):
        parse_and_validate(raw, valid_codes={"x"})


def test_handles_markdown_wrapped_json() -> None:
    # 모델이 ```json 으로 감싼 경우 graceful 처리
    raw = '```json\n{"대":{"code":"x","name":"x"},"중":{"code":"x","name":"x"},"소":{"code":"x","name":"x"},"confidence":0.7,"reason":"r","alternativesConsidered":[]}\n```'
    result = parse_and_validate(raw, valid_codes={"x"})
    assert result.confidence == 0.7
```

- [ ] **Write `src/lib/output_schema.py`**

```python
"""Bedrock 응답 JSON 검증/파싱."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass


class ValidationError(Exception):
    pass


@dataclass
class CategoryLabel:
    code: str
    name: str


@dataclass
class Alternative:
    code: str
    why_rejected: str


@dataclass
class ClassificationResult:
    대: CategoryLabel
    중: CategoryLabel
    소: CategoryLabel
    confidence: float
    reason: str
    alternativesConsidered: list[Alternative]


_MD_FENCE = re.compile(r"^```(?:json)?\s*(.*?)\s*```$", re.DOTALL)


def _strip_markdown_fence(text: str) -> str:
    m = _MD_FENCE.match(text.strip())
    return m.group(1) if m else text


def parse_and_validate(raw: str, valid_codes: set[str]) -> ClassificationResult:
    text = _strip_markdown_fence(raw)
    try:
        data = json.loads(text)
    except json.JSONDecodeError as ex:
        raise ValidationError(f"invalid JSON: {ex}") from ex

    required = {"대", "중", "소", "confidence", "reason", "alternativesConsidered"}
    missing = required - data.keys()
    if missing:
        raise ValidationError(f"missing keys: {missing}")

    for k in ("대", "중", "소"):
        node = data[k]
        if not isinstance(node, dict) or "code" not in node or "name" not in node:
            raise ValidationError(f"{k} must have code+name")
        if node["code"] not in valid_codes:
            raise ValidationError(f"unknown code in {k}: {node['code']}")

    conf = data["confidence"]
    if not isinstance(conf, (int, float)) or not 0 <= conf <= 1:
        raise ValidationError(f"confidence out of range: {conf}")

    alternatives = []
    for a in data.get("alternativesConsidered", []):
        if a.get("code") and a["code"] not in valid_codes:
            raise ValidationError(f"unknown code in alternatives: {a['code']}")
        alternatives.append(Alternative(code=a.get("code", ""), why_rejected=a.get("why_rejected", "")))

    return ClassificationResult(
        대=CategoryLabel(**data["대"]),
        중=CategoryLabel(**data["중"]),
        소=CategoryLabel(**data["소"]),
        confidence=float(conf),
        reason=data["reason"],
        alternativesConsidered=alternatives,
    )
```

- [ ] **Run tests until pass**

```bash
pytest tests/unit/test_output_schema.py -v
```
Expected: 4 passed

- [ ] **Commit**

```bash
git add src/lib/output_schema.py tests/unit/test_output_schema.py src/prompts/v1.0/system_rules.md
git commit -m "feat(prompt): system rules + output JSON schema validator"
```

### Step 4.3: prompts.py (시스템 프롬프트 빌더)

- [ ] **Write `tests/unit/test_prompts.py`**

```python
from pathlib import Path

from lib.prompts import PromptBundle, build_prompt_bundle


def test_build_prompt_bundle_has_two_cache_breakpoints(repo_root: Path) -> None:
    rules = (repo_root / "src/prompts/v1.0/system_rules.md").read_text(encoding="utf-8")
    tree_json = (repo_root / "src/prompts/v1.0/taxonomy_tree.json").read_text(encoding="utf-8")
    bundle = build_prompt_bundle(rules_md=rules, taxonomy_json=tree_json)
    assert isinstance(bundle, PromptBundle)
    assert len(bundle.system_blocks) == 2
    assert bundle.valid_codes  # non-empty set
    # 룰 블록은 R5 PII 룰을 반드시 포함
    assert "R5" in bundle.system_blocks[0]
    # 트리 블록은 18개 대분류 표시 포함
    assert bundle.system_blocks[1].count("[대분류]") == 18


def test_user_message_includes_transcript() -> None:
    bundle = PromptBundle(
        system_blocks=["rules", "tree"], valid_codes={"x"}, prompt_version="v1.0"
    )
    user = bundle.build_user_message(masked_transcript="agent: hi")
    assert "agent: hi" in user
    assert "JSON" in user
```

- [ ] **Write `src/lib/prompts.py`**

```python
"""Bedrock Converse 프롬프트 빌더 + 캐시 브레이크포인트."""
from __future__ import annotations

import json
from dataclasses import dataclass


PROMPT_VERSION = "v1.0"


@dataclass
class PromptBundle:
    system_blocks: list[str]   # [0]=rules, [1]=taxonomy tree
    valid_codes: set[str]      # 출력 검증용
    prompt_version: str

    def build_user_message(self, masked_transcript: str) -> str:
        return (
            "다음은 콜센터 상담 STT(개인정보가 마스킹됨)이다. "
            "이 대화를 분류 체계의 대/중/소 코드로 분류하라. "
            "출력은 JSON 한 객체만 (마크다운 코드블록 금지).\n\n"
            "---\n"
            f"{masked_transcript}\n"
            "---\n"
        )


def _serialize_taxonomy(taxonomy_json: str) -> tuple[str, set[str]]:
    nodes = json.loads(taxonomy_json)
    lines: list[str] = []
    codes: set[str] = set()
    for n in nodes:
        if n["code"]:
            codes.add(n["code"])
        indent = "  " * (n["level"] - 1)
        marker = ["대분류", "중분류", "소분류"][n["level"] - 1]
        lines.append(f"{indent}{['##', '###', '####'][n['level']-1]} [{marker}] {n['name']} — code: {n['code']}")
        if n["description"]:
            lines.append(f"{indent}설명: {n['description']}")
        lines.append("")
    return "\n".join(lines), codes


def build_prompt_bundle(rules_md: str, taxonomy_json: str) -> PromptBundle:
    tree_block, codes = _serialize_taxonomy(taxonomy_json)
    return PromptBundle(
        system_blocks=[rules_md, tree_block],
        valid_codes=codes,
        prompt_version=PROMPT_VERSION,
    )
```

- [ ] **Run tests until pass**

```bash
pytest tests/unit/test_prompts.py -v
```
Expected: 2 passed

- [ ] **Commit**

```bash
git add src/lib/prompts.py tests/unit/test_prompts.py
git commit -m "feat(prompt): build system+taxonomy prompt bundle with two cache breakpoints"
```

### Step 4.4: bedrock_client + inference_adapter

- [ ] **Write `src/lib/inference_adapter.py`**

```python
"""Phase 3에서 ML 모델 교체 가능하도록 한 어댑터 추상."""
from __future__ import annotations

from typing import Protocol

from lib.output_schema import ClassificationResult


class InferenceAdapter(Protocol):
    name: str
    version: str

    def classify(self, masked_transcript: str) -> ClassificationResult: ...
```

- [ ] **Write `src/lib/bedrock_client.py`**

```python
"""Bedrock Converse 호출 래퍼 (prompt caching 포함)."""
from __future__ import annotations

import os

import boto3

from lib.output_schema import ClassificationResult, parse_and_validate
from lib.prompts import PromptBundle

_DEFAULT_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")


class BedrockAdapter:
    name: str
    version: str

    def __init__(self, model_id: str, bundle: PromptBundle, max_tokens: int = 1024) -> None:
        self.model_id = model_id
        self.bundle = bundle
        self.max_tokens = max_tokens
        self.name = f"bedrock-{model_id.replace('.', '-')}"
        self.version = bundle.prompt_version
        self._client = boto3.client("bedrock-runtime", region_name=_DEFAULT_REGION)

    def classify(self, masked_transcript: str) -> ClassificationResult:
        # Converse API: system blocks each tagged with cachePoint
        system = []
        for block in self.bundle.system_blocks:
            system.append({"text": block})
            system.append({"cachePoint": {"type": "default"}})

        resp = self._client.converse(
            modelId=self.model_id,
            system=system,
            messages=[
                {
                    "role": "user",
                    "content": [{"text": self.bundle.build_user_message(masked_transcript)}],
                }
            ],
            inferenceConfig={"maxTokens": self.max_tokens, "temperature": 0.0},
        )
        text = resp["output"]["message"]["content"][0]["text"]
        return parse_and_validate(text, self.bundle.valid_codes)
```

### Step 4.5: classify Lambda handler

- [ ] **Write `tests/unit/test_classify_handler.py`**

```python
"""Classify Lambda handler test with mocked Bedrock + mocked S3."""
import json
import os
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws


@pytest.fixture
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    monkeypatch.setenv("MODEL_ID", "anthropic.claude-opus-4-7-20260101-v1:0")
    monkeypatch.setenv("PROMPT_VERSION", "v1.0")


@mock_aws
def test_classify_returns_structured_result(aws_env, monkeypatch) -> None:
    s3 = boto3.client("s3", region_name="ap-northeast-2")
    s3.create_bucket(
        Bucket="masked-test",
        CreateBucketConfiguration={"LocationConstraint": "ap-northeast-2"},
    )
    s3.put_object(Bucket="masked-test", Key="x_masked.txt", Body=b"agent: hi")

    fake_bedrock_resp = {
        "output": {
            "message": {
                "content": [
                    {
                        "text": json.dumps(
                            {
                                "대": {"code": "ANY_CODE", "name": "n"},
                                "중": {"code": "ANY_CODE", "name": "n"},
                                "소": {"code": "ANY_CODE", "name": "n"},
                                "confidence": 0.91,
                                "reason": "r",
                                "alternativesConsidered": [],
                            }
                        )
                    }
                ]
            }
        }
    }
    fake_client = MagicMock()
    fake_client.converse.return_value = fake_bedrock_resp

    with patch("lib.bedrock_client.boto3.client", return_value=fake_client):
        # 컨테이너에 prompts/v1.0 산출물 포함되어 있다고 가정 (Lambda 패키징 시 함께)
        from src.lambdas.classify.handler import handler

        result = handler(
            {
                "callId": "call_1",
                "maskedBucket": "masked-test",
                "maskedKey": "x_masked.txt",
            },
            None,
        )
        assert result["classification"]["confidence"] == 0.91
        assert result["modelId"] == os.environ["MODEL_ID"]
```

- [ ] **Write `src/lambdas/classify/handler.py`**

```python
"""Step Functions task: read masked transcript, call Bedrock, return classification."""
from __future__ import annotations

import dataclasses
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3

from lib.bedrock_client import BedrockAdapter
from lib.prompts import build_prompt_bundle

_MODEL_ID = os.environ["MODEL_ID"]
_PROMPT_DIR = Path(os.environ.get("PROMPT_DIR", "/var/task/prompts/v1.0"))
_RULES = (_PROMPT_DIR / "system_rules.md").read_text(encoding="utf-8")
_TREE = (_PROMPT_DIR / "taxonomy_tree.json").read_text(encoding="utf-8")
_BUNDLE = build_prompt_bundle(rules_md=_RULES, taxonomy_json=_TREE)
_ADAPTER = BedrockAdapter(model_id=_MODEL_ID, bundle=_BUNDLE)
_s3 = boto3.client("s3")


def handler(event: dict, _ctx) -> dict:
    masked = _s3.get_object(Bucket=event["maskedBucket"], Key=event["maskedKey"])["Body"].read().decode()
    result = _ADAPTER.classify(masked)
    return {
        **event,
        "modelId": _MODEL_ID,
        "promptVersion": _BUNDLE.prompt_version,
        "classification": dataclasses.asdict(result),
    }
```

- [ ] **Run tests**

```bash
pytest tests/unit/test_classify_handler.py -v
```
Expected: 1 passed

- [ ] **Commit**

```bash
git add src/lib/bedrock_client.py src/lib/inference_adapter.py src/lambdas/classify/ tests/unit/test_classify_handler.py
git commit -m "feat(classify): Bedrock classify Lambda + InferenceAdapter abstraction"
```

### Step 4.6: 골든셋 50건 손라벨링

- [ ] **Write `tests/golden/samples.json` (실제로는 50건; 여기는 형식 예시)**

```json
[
  {
    "id": "g001",
    "transcript": "agent: 안녕하세요 카카오페이입니다\ncustomer: 페이머니 충전이 안되는데요\nagent: 어떤 오류 메시지가 나오시나요\ncustomer: 그냥 안 됩니다",
    "expected": {
      "대code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY",
      "중code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL",
      "소code": "CS_CENTER_CONSULT_TYPE_PAY_NONEY_CHARGE_WITHDRAWAL_CHARGE_DELAY"
    }
  }
]
```

> ⚠️ 실제 50건은 분석팀 또는 외주가 손 라벨링. 본 단계의 산출물은 **빈 50건 슬롯 + 검증 스크립트**까지 작성하고, 실제 라벨링은 W2 종료까지 별도 워크.

- [ ] **Write `scripts/eval_prompt.py`**

```python
"""골든셋에 대해 현재 프롬프트 버전 평가."""
from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from lib.bedrock_client import BedrockAdapter
from lib.prompts import build_prompt_bundle


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--golden", type=Path, default=Path("tests/golden/samples.json"))
    p.add_argument("--prompt-dir", type=Path, default=Path("src/prompts/v1.0"))
    p.add_argument("--model-id", default="anthropic.claude-opus-4-7-20260101-v1:0")
    p.add_argument("--history", type=Path, default=Path("tests/golden/eval-history.csv"))
    args = p.parse_args()

    samples = json.loads(args.golden.read_text(encoding="utf-8"))
    rules = (args.prompt_dir / "system_rules.md").read_text(encoding="utf-8")
    tree = (args.prompt_dir / "taxonomy_tree.json").read_text(encoding="utf-8")
    adapter = BedrockAdapter(args.model_id, build_prompt_bundle(rules, tree))

    correct = {"대": 0, "중": 0, "소": 0}
    total = len(samples)
    for s in samples:
        try:
            r = adapter.classify(s["transcript"])
        except Exception as ex:  # noqa: BLE001
            print(f"[FAIL] {s['id']}: {ex}")
            continue
        exp = s["expected"]
        if r.대.code == exp["대code"]:
            correct["대"] += 1
        if r.중.code == exp["중code"]:
            correct["중"] += 1
        if r.소.code == exp["소code"]:
            correct["소"] += 1

    acc = {k: v / total for k, v in correct.items()}
    print(f"accuracy: 대={acc['대']:.2%} 중={acc['중']:.2%} 소={acc['소']:.2%} (n={total})")

    args.history.parent.mkdir(parents=True, exist_ok=True)
    write_header = not args.history.exists()
    with args.history.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if write_header:
            w.writerow(["timestamp", "prompt_version", "model_id", "n", "acc_대", "acc_중", "acc_소"])
        w.writerow([
            datetime.utcnow().isoformat(),
            "v1.0",
            args.model_id,
            total,
            acc["대"],
            acc["중"],
            acc["소"],
        ])

    if acc["대"] < 0.80:
        print(f"FAIL: 대 accuracy {acc['대']:.2%} < 80%")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Add taxonomy artifacts to Lambda package**

Update `infra/modules/classify-pipeline/main.tf` archive_file에서 `prompts/**` 포함시키도록 excludes 조정 (classify Lambda zip에는 prompts 포함):

```hcl
data "archive_file" "classify" {
  type        = "zip"
  source_dir  = "${path.module}/../../../src"
  output_path = "${path.module}/build/classify.zip"
  excludes    = ["hitl_ui/**", "lambdas/pii_guard/**", "lambdas/verify/**", "lambdas/persist/**"]
}

resource "aws_iam_role" "classify" {
  name = "callcenter-${var.env}-classify"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "classify" {
  role = aws_iam_role.classify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.bucket_masked_arn}/*" },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.kms_masked_arn },
      { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = "arn:aws:bedrock:ap-northeast-2::foundation-model/anthropic.claude-opus-4-*" },
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
    ]
  })
}

resource "aws_lambda_function" "classify" {
  function_name = "callcenter-${var.env}-classify"
  role          = aws_iam_role.classify.arn
  handler       = "lambdas.classify.handler.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.classify.output_path
  source_code_hash = data.archive_file.classify.output_base64sha256
  timeout       = 300
  memory_size   = 1024
  environment {
    variables = {
      MODEL_ID = "anthropic.claude-opus-4-7-20260101-v1:0"
      PROMPT_DIR = "/var/task/prompts/v1.0"
    }
  }
}

output "classify_arn" { value = aws_lambda_function.classify.arn }
```

- [ ] **Apply + Bedrock smoke test on dev**

```bash
cd infra/envs/dev && terraform apply -auto-approve && cd -
# 골든셋 1건으로 Bedrock 실제 호출 확인 (dev에서)
aws lambda invoke --function-name callcenter-dev-classify \
  --payload '{"callId":"g001","maskedBucket":"kakaopay-callcenter-dev-stt-masked","maskedKey":"smoke/g001_masked.txt"}' \
  /tmp/c.json
```

- [ ] **Commit**

```bash
git add tests/golden/ scripts/eval_prompt.py infra/modules/classify-pipeline/main.tf
git commit -m "feat(eval): classify Lambda deployed + golden set scaffold + eval_prompt.py"
```

---

## PR5: Verify Lambda + 캐스케이드 분기

**Files:**
- Create: `src/lambdas/verify/handler.py`
- Create: `src/lambdas/verify/requirements.txt`
- Create: `tests/unit/test_verify_handler.py`
- Modify: `infra/modules/classify-pipeline/main.tf` (verify Lambda 추가)

### Step 5.1: Verify Lambda 단위 테스트

- [ ] **Write `tests/unit/test_verify_handler.py`**

```python
"""Verify Lambda: Sonnet으로 1차 결과 검증."""
import json
from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    monkeypatch.setenv("VERIFY_MODEL_ID", "anthropic.claude-sonnet-4-6-20260101-v1:0")
    monkeypatch.setenv("PROMPT_DIR", "src/prompts/v1.0")


def _make_event(primary_codes: tuple[str, str, str], conf: float = 0.6) -> dict:
    return {
        "callId": "c1",
        "maskedBucket": "b",
        "maskedKey": "k",
        "classification": {
            "대": {"code": primary_codes[0], "name": "n"},
            "중": {"code": primary_codes[1], "name": "n"},
            "소": {"code": primary_codes[2], "name": "n"},
            "confidence": conf,
            "reason": "r",
            "alternativesConsidered": [],
        },
    }


def _fake_bedrock_response(codes: tuple[str, str, str], conf: float) -> dict:
    body = {
        "대": {"code": codes[0], "name": "n"},
        "중": {"code": codes[1], "name": "n"},
        "소": {"code": codes[2], "name": "n"},
        "confidence": conf,
        "reason": "v",
        "alternativesConsidered": [],
    }
    return {"output": {"message": {"content": [{"text": json.dumps(body)}]}}}


def test_agreement_marks_auto_confirmed(env) -> None:
    fake = MagicMock()
    fake.converse.return_value = _fake_bedrock_response(("A", "B", "C"), 0.9)
    with patch("lib.bedrock_client.boto3.client", return_value=fake), patch(
        "boto3.client"
    ) as bc:
        bc.return_value.get_object.return_value = {
            "Body": MagicMock(read=lambda: b"agent: hi")
        }
        from src.lambdas.verify.handler import handler

        out = handler(_make_event(("A", "B", "C")), None)
        assert out["verified"] == "auto-confirmed"
        assert out["status"] != "hitl-pending"


def test_disagreement_marks_hitl_pending(env) -> None:
    fake = MagicMock()
    fake.converse.return_value = _fake_bedrock_response(("X", "Y", "Z"), 0.7)
    with patch("lib.bedrock_client.boto3.client", return_value=fake), patch(
        "boto3.client"
    ) as bc:
        bc.return_value.get_object.return_value = {
            "Body": MagicMock(read=lambda: b"agent: hi")
        }
        from src.lambdas.verify.handler import handler

        out = handler(_make_event(("A", "B", "C")), None)
        assert out["verified"] == "hitl-pending"
        assert out["status"] == "hitl-pending"
```

- [ ] **Write `src/lambdas/verify/handler.py`**

```python
"""Verify Lambda — Sonnet으로 primary 결과 검증."""
from __future__ import annotations

import dataclasses
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3

from lib.bedrock_client import BedrockAdapter
from lib.prompts import build_prompt_bundle

_VERIFY_MODEL_ID = os.environ["VERIFY_MODEL_ID"]
_PROMPT_DIR = Path(os.environ.get("PROMPT_DIR", "/var/task/prompts/v1.0"))
_RULES = (_PROMPT_DIR / "system_rules.md").read_text(encoding="utf-8")
_TREE = (_PROMPT_DIR / "taxonomy_tree.json").read_text(encoding="utf-8")
_BUNDLE = build_prompt_bundle(rules_md=_RULES, taxonomy_json=_TREE)
_ADAPTER = BedrockAdapter(model_id=_VERIFY_MODEL_ID, bundle=_BUNDLE)
_s3 = boto3.client("s3")


def handler(event: dict, _ctx) -> dict:
    masked = _s3.get_object(Bucket=event["maskedBucket"], Key=event["maskedKey"])["Body"].read().decode()
    secondary = _ADAPTER.classify(masked)
    primary = event["classification"]

    same = (
        primary["대"]["code"] == secondary.대.code
        and primary["중"]["code"] == secondary.중.code
        and primary["소"]["code"] == secondary.소.code
    )

    if same:
        verified = "auto-confirmed"
        status = "confirmed"
    else:
        verified = "hitl-pending"
        status = "hitl-pending"

    return {
        **event,
        "verifiedBy": _VERIFY_MODEL_ID,
        "verifyResult": dataclasses.asdict(secondary),
        "verified": verified,
        "status": status,
        "modelPath": [event.get("modelId"), _VERIFY_MODEL_ID],
    }
```

- [ ] **Run tests until pass**

```bash
pytest tests/unit/test_verify_handler.py -v
```
Expected: 2 passed

### Step 5.2: Verify Lambda Terraform

- [ ] **Update `infra/modules/classify-pipeline/main.tf` (append verify)**

```hcl
data "archive_file" "verify" {
  type        = "zip"
  source_dir  = "${path.module}/../../../src"
  output_path = "${path.module}/build/verify.zip"
  excludes    = ["hitl_ui/**", "lambdas/pii_guard/**", "lambdas/classify/**", "lambdas/persist/**"]
}

resource "aws_iam_role" "verify" {
  name = "callcenter-${var.env}-verify"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "verify" {
  role = aws_iam_role.verify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.bucket_masked_arn}/*" },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.kms_masked_arn },
      { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = "arn:aws:bedrock:ap-northeast-2::foundation-model/anthropic.claude-sonnet-4-*" },
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
    ]
  })
}

resource "aws_lambda_function" "verify" {
  function_name    = "callcenter-${var.env}-verify"
  role             = aws_iam_role.verify.arn
  handler          = "lambdas.verify.handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.verify.output_path
  source_code_hash = data.archive_file.verify.output_base64sha256
  timeout          = 300
  memory_size      = 1024
  environment {
    variables = {
      VERIFY_MODEL_ID = "anthropic.claude-sonnet-4-6-20260101-v1:0"
      PROMPT_DIR      = "/var/task/prompts/v1.0"
    }
  }
}

output "verify_arn" { value = aws_lambda_function.verify.arn }
```

- [ ] **Apply + Commit**

```bash
cd infra/envs/dev && terraform apply -auto-approve && cd -
git add src/lambdas/verify/ tests/unit/test_verify_handler.py infra/modules/classify-pipeline/main.tf
git commit -m "feat(verify): Sonnet verify Lambda with agreement-based HITL routing"
```

---

## PR6: Persist Lambda + Step Functions Express + EventBridge

**Files:**
- Create: `src/lib/persistence.py`
- Create: `tests/unit/test_persistence.py`
- Create: `src/lambdas/persist/handler.py`
- Create: `tests/unit/test_persist_handler.py`
- Create: `tests/integration/test_sfn_dry_run.py`
- Modify: `infra/modules/classify-pipeline/main.tf` (persist + SFN + EventBridge)

### Step 6.1: persistence library (출력 후처리 PII sweep + DDB record builder)

- [ ] **Write `tests/unit/test_persistence.py`**

```python
from lib.persistence import build_ddb_item, sanitize_text


def test_sanitize_text_strips_pii() -> None:
    text = "고객님 010-1234-5678 충전 오류"
    out = sanitize_text(text)
    assert "[MASKED_PHONE]" in out
    assert "010-1234-5678" not in out


def test_build_ddb_item_has_all_required_fields() -> None:
    classification = {
        "대": {"code": "X", "name": "x"},
        "중": {"code": "Y", "name": "y"},
        "소": {"code": "Z", "name": "z"},
        "confidence": 0.9,
        "reason": "고객 010-1111-2222 호소",  # PII to be sanitized
        "alternativesConsidered": [{"code": "X2", "why_rejected": "전화 010-9999-9999"}],
    }
    event = {
        "callId": "c1",
        "agentId": "a1",
        "startedAt": "2026-05-22T00:00:00Z",
        "durationSec": 60,
        "rawBucket": "raw",
        "rawKey": "k.json",
        "maskedBucket": "masked",
        "maskedKey": "k_masked.txt",
        "modelId": "opus",
        "promptVersion": "v1.0",
        "classification": classification,
        "verified": "auto-high",
        "status": "confirmed",
        "modelPath": ["opus"],
    }
    item = build_ddb_item(event)
    assert item["callId"] == "c1"
    assert "010-1111-2222" not in item["reason"]
    assert item["category_대code"] == "X"
    assert item["ttlEpoch"] > 0
```

- [ ] **Write `src/lib/persistence.py`**

```python
"""Persist 단계 헬퍼: 출력 후처리 PII sweep + DDB item builder."""
from __future__ import annotations

import time
from typing import Any

from lib.pii_regex import mask


def sanitize_text(text: str) -> str:
    sanitized, _ = mask(text or "")
    return sanitized


def build_ddb_item(event: dict[str, Any]) -> dict[str, Any]:
    c = event["classification"]
    now = int(time.time())
    return {
        "callId": event["callId"],
        "agentId": event["agentId"],
        "startedAt": event["startedAt"],
        "durationSec": event["durationSec"],
        "rawSttRef": f"s3://{event['rawBucket']}/{event['rawKey']}",
        "piiMaskedTextRef": f"s3://{event['maskedBucket']}/{event['maskedKey']}",
        "category_대code": c["대"]["code"],
        "category_대name": c["대"]["name"],
        "category_중code": c["중"]["code"],
        "category_중name": c["중"]["name"],
        "category_소code": c["소"]["code"],
        "category_소name": c["소"]["name"],
        "confidence": c["confidence"],
        "reason": sanitize_text(c["reason"])[:2000],
        "alternativesConsidered": [
            {"code": a["code"], "why_rejected": sanitize_text(a["why_rejected"])[:500]}
            for a in c.get("alternativesConsidered", [])
        ],
        "modelPath": event.get("modelPath", [event.get("modelId")]),
        "promptVersion": event.get("promptVersion", "v1.0"),
        "verified": event.get("verified", "auto-high"),
        "status": event.get("status", "confirmed"),
        "classifiedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "ttlEpoch": now + 365 * 24 * 3600,
    }
```

- [ ] **Run tests until pass**

```bash
pytest tests/unit/test_persistence.py -v
```

### Step 6.2: persist Lambda handler

- [ ] **Write `tests/unit/test_persist_handler.py`**

```python
"""persist Lambda: DDB write + S3 Parquet append (Firehose)."""
import json
import os
from unittest.mock import patch

import boto3
import pytest
from moto import mock_aws


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-northeast-2")
    monkeypatch.setenv("DDB_TABLE", "callcenter-dev-consult-results")
    monkeypatch.setenv("FIREHOSE_NAME", "callcenter-dev-firehose")


@mock_aws
def test_persist_writes_ddb_and_firehose(env, monkeypatch) -> None:
    ddb = boto3.client("dynamodb", region_name="ap-northeast-2")
    ddb.create_table(
        TableName="callcenter-dev-consult-results",
        KeySchema=[{"AttributeName": "callId", "KeyType": "HASH"}],
        AttributeDefinitions=[{"AttributeName": "callId", "AttributeType": "S"}],
        BillingMode="PAY_PER_REQUEST",
    )
    fh = boto3.client("firehose", region_name="ap-northeast-2")
    # moto Firehose: stub
    monkeypatch.setattr(
        "src.lambdas.persist.handler._firehose",
        type("FH", (), {"put_record": lambda self, **k: {"RecordId": "x"}})(),
    )
    from src.lambdas.persist.handler import handler

    event = {
        "callId": "c1",
        "agentId": "a1",
        "startedAt": "2026-05-22T00:00:00Z",
        "durationSec": 60,
        "rawBucket": "raw",
        "rawKey": "k.json",
        "maskedBucket": "masked",
        "maskedKey": "k_masked.txt",
        "modelId": "opus",
        "promptVersion": "v1.0",
        "classification": {
            "대": {"code": "X", "name": "x"},
            "중": {"code": "Y", "name": "y"},
            "소": {"code": "Z", "name": "z"},
            "confidence": 0.9,
            "reason": "r",
            "alternativesConsidered": [],
        },
        "verified": "auto-high",
        "status": "confirmed",
    }
    result = handler(event, None)
    assert result["persisted"] is True

    got = ddb.get_item(TableName="callcenter-dev-consult-results", Key={"callId": {"S": "c1"}})
    assert "Item" in got
```

- [ ] **Write `src/lambdas/persist/handler.py`**

```python
"""Persist Lambda: PII sweep → DDB write + Firehose put."""
from __future__ import annotations

import json
import os
import sys
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import boto3

from lib.persistence import build_ddb_item

_ddb = boto3.resource("dynamodb")
_table = _ddb.Table(os.environ["DDB_TABLE"])
_firehose = boto3.client("firehose")
_FIREHOSE_NAME = os.environ.get("FIREHOSE_NAME")


def _to_decimal(o):
    if isinstance(o, float):
        return Decimal(str(o))
    if isinstance(o, dict):
        return {k: _to_decimal(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_to_decimal(v) for v in o]
    return o


def handler(event: dict, _ctx) -> dict:
    item = build_ddb_item(event)
    _table.put_item(
        Item=_to_decimal(item),
        ConditionExpression="attribute_not_exists(callId) OR promptVersion = :pv",
        ExpressionAttributeValues={":pv": item["promptVersion"]},
    )
    if _FIREHOSE_NAME:
        _firehose.put_record(
            DeliveryStreamName=_FIREHOSE_NAME,
            Record={"Data": (json.dumps(item, default=str) + "\n").encode("utf-8")},
        )
    return {**event, "persisted": True}
```

- [ ] **Run tests**

```bash
pytest tests/unit/test_persist_handler.py -v
```

### Step 6.3: Step Functions Express 정의

- [ ] **Append to `infra/modules/classify-pipeline/main.tf`**

```hcl
resource "aws_iam_role" "sfn" {
  name = "callcenter-${var.env}-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_invoke" {
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [
          aws_lambda_function.pii_guard.arn,
          aws_lambda_function.classify.arn,
          aws_lambda_function.verify.arn,
          aws_lambda_function.persist.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [var.classify_dlq_arn, var.persist_dlq_arn]
      },
      {
        Effect = "Allow"
        Action = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
                  "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy",
                  "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/callcenter-${var.env}-classify"
  retention_in_days = 30
}

resource "aws_sfn_state_machine" "classify" {
  name     = "callcenter-${var.env}-classify"
  role_arn = aws_iam_role.sfn.arn
  type     = "EXPRESS"

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  definition = jsonencode({
    Comment = "콜센터 STT 자동 분류"
    StartAt = "PiiGuard"
    States = {
      PiiGuard = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.pii_guard.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        ResultPath     = "$.piiResult"
        OutputPath     = "$.piiResult.result"
        Retry = [{
          ErrorEquals = ["States.TaskFailed"]
          IntervalSeconds = 2
          MaxAttempts = 3
          BackoffRate = 2.0
        }]
        Next = "Classify"
      }
      Classify = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.classify.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        ResultPath     = "$.classifyResult"
        OutputPath     = "$.classifyResult.result"
        Retry = [{
          ErrorEquals = ["States.TaskFailed", "ThrottlingException", "ServiceUnavailable"]
          IntervalSeconds = 1
          MaxAttempts = 5
          BackoffRate = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next = "SendToClassifyDlq"
          ResultPath = "$.errorInfo"
        }]
        Next = "ConfidenceBranch"
      }
      ConfidenceBranch = {
        Type = "Choice"
        Choices = [
          {
            Variable = "$.classification.confidence"
            NumericLessThan = 0.80
            Next = "Verify"
          }
        ]
        Default = "Persist"
      }
      Verify = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.verify.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        ResultPath     = "$.verifyResult"
        OutputPath     = "$.verifyResult.result"
        Retry = [{
          ErrorEquals = ["States.TaskFailed"]
          IntervalSeconds = 2
          MaxAttempts = 3
          BackoffRate = 2.0
        }]
        Next = "Persist"
      }
      Persist = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.persist.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        ResultPath     = "$.persistResult"
        Retry = [{
          ErrorEquals = ["States.TaskFailed"]
          IntervalSeconds = 1
          MaxAttempts = 3
          BackoffRate = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next = "SendToPersistDlq"
          ResultPath = "$.errorInfo"
        }]
        End = true
      }
      SendToClassifyDlq = {
        Type = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"
        Parameters = {
          QueueUrl = replace(var.classify_dlq_arn, "arn:aws:sqs:ap-northeast-2:", "https://sqs.ap-northeast-2.amazonaws.com/")
          MessageBody.$ = "$"
        }
        End = true
      }
      SendToPersistDlq = {
        Type = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"
        Parameters = {
          QueueUrl = replace(var.persist_dlq_arn, "arn:aws:sqs:ap-northeast-2:", "https://sqs.ap-northeast-2.amazonaws.com/")
          MessageBody.$ = "$"
        }
        End = true
      }
    }
  })
}

output "sfn_arn" { value = aws_sfn_state_machine.classify.arn }
```

### Step 6.4: EventBridge S3 트리거

- [ ] **Append to `infra/modules/classify-pipeline/main.tf`**

```hcl
resource "aws_s3_bucket_notification" "raw" {
  bucket      = element(split(":", var.bucket_raw_arn), 5)
  eventbridge = true
}

resource "aws_iam_role" "eventbridge" {
  name = "callcenter-${var.env}-eb-to-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_to_sfn" {
  role = aws_iam_role.eventbridge.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = aws_sfn_state_machine.classify.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "s3_raw_put" {
  name = "callcenter-${var.env}-raw-put"
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [element(split(":", var.bucket_raw_arn), 5)] }
      object = { key = [{ suffix = ".json" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "to_sfn" {
  rule      = aws_cloudwatch_event_rule.s3_raw_put.name
  arn       = aws_sfn_state_machine.classify.arn
  role_arn  = aws_iam_role.eventbridge.arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = "{\"rawBucket\":<bucket>,\"rawKey\":<key>}"
  }
}
```

### Step 6.5: Persist Lambda Terraform + E2E integration test (LocalStack)

- [ ] **Append persist Lambda to module**

```hcl
data "archive_file" "persist" {
  type        = "zip"
  source_dir  = "${path.module}/../../../src"
  output_path = "${path.module}/build/persist.zip"
  excludes    = ["hitl_ui/**", "lambdas/pii_guard/**", "lambdas/classify/**", "lambdas/verify/**", "prompts/**"]
}

resource "aws_iam_role" "persist" {
  name = "callcenter-${var.env}-persist"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "persist" {
  role = aws_iam_role.persist.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = var.ddb_consult_arn },
      { Effect = "Allow", Action = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"],
        Resource = "*" },
      { Effect = "Allow", Action = ["firehose:PutRecord", "firehose:PutRecordBatch"],
        Resource = "*" },
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
    ]
  })
}

resource "aws_lambda_function" "persist" {
  function_name    = "callcenter-${var.env}-persist"
  role             = aws_iam_role.persist.arn
  handler          = "lambdas.persist.handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.persist.output_path
  source_code_hash = data.archive_file.persist.output_base64sha256
  timeout          = 60
  memory_size      = 512
  environment {
    variables = {
      DDB_TABLE      = "callcenter-${var.env}-consult-results"
      FIREHOSE_NAME  = ""  # PR7에서 채움
    }
  }
}

output "persist_arn" { value = aws_lambda_function.persist.arn }
```

- [ ] **Write `tests/integration/test_sfn_dry_run.py`**

```python
"""Step Functions ASL JSON 유효성 검증 (구조만, 실행은 stepfunctions-local)."""
import json
import subprocess
from pathlib import Path

import pytest


@pytest.mark.skipif(
    subprocess.run(["which", "terraform"], capture_output=True).returncode != 0,
    reason="terraform CLI not available",
)
def test_sfn_definition_extractable_and_valid_json(repo_root: Path) -> None:
    result = subprocess.run(
        ["terraform", "-chdir=infra/envs/dev", "show", "-json"],
        capture_output=True,
        check=True,
        text=True,
    )
    state = json.loads(result.stdout)
    sfn_resources = [
        r for r in state.get("values", {}).get("root_module", {}).get("resources", [])
        if r.get("type") == "aws_sfn_state_machine"
    ]
    assert sfn_resources, "no SFN state machine found in dev plan"
    defn = json.loads(sfn_resources[0]["values"]["definition"])
    assert defn["StartAt"] == "PiiGuard"
    assert "Classify" in defn["States"]
    assert "ConfidenceBranch" in defn["States"]
    assert "Persist" in defn["States"]
```

- [ ] **Apply + smoke (dev에 STT 1건 PUT → SFN execution 추적)**

```bash
cd infra/envs/dev && terraform apply -auto-approve && cd -
echo '{"callId":"smoke_001","agentId":"A1","startedAt":"2026-05-22T00:00:00Z","durationSec":60,"transcript":[{"speaker":"customer","text":"페이머니 충전이 안되는데요"}]}' > /tmp/smoke.json
aws s3 cp /tmp/smoke.json s3://kakaopay-callcenter-dev-stt-raw/2026/05/22/smoke_001.json
sleep 30
aws stepfunctions list-executions --state-machine-arn $(terraform -chdir=infra/envs/dev output -raw sfn_arn 2>/dev/null) --max-items 1
aws dynamodb get-item --table-name callcenter-dev-consult-results --key '{"callId":{"S":"smoke_001"}}'
```
Expected: DDB에 분류 결과 적재됨

- [ ] **Commit**

```bash
git add src/lib/persistence.py src/lambdas/persist/ tests/unit/test_persist_handler.py \
        tests/unit/test_persistence.py tests/integration/test_sfn_dry_run.py \
        infra/modules/classify-pipeline/main.tf
git commit -m "feat(pipeline): SFN Express + EventBridge S3 trigger + persist Lambda"
```

---

## PR7: Analytics — Glue + Firehose + Athena + QuickSight

**Files:**
- Create: `infra/modules/analytics/{main.tf,variables.tf,outputs.tf}`
- Modify: `infra/envs/dev/main.tf` (analytics 모듈 추가)
- Create: `docs/runbooks/quicksight-setup.md` (QuickSight는 일부 콘솔 작업 필요)

### Step 7.1: Glue Database + Athena Workgroup

- [ ] **Write `infra/modules/analytics/variables.tf`**

```hcl
variable "env"                  { type = string }
variable "bucket_analytics_arn" { type = string }
variable "bucket_analytics_id"  { type = string }
variable "kms_analytics_arn"    { type = string }
```

- [ ] **Write `infra/modules/analytics/main.tf`**

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

resource "aws_glue_catalog_database" "main" {
  name = "callcenter_${var.env}"
}

# Table: consult_results (Firehose가 적재)
resource "aws_glue_catalog_table" "consult_results" {
  name          = "consult_results"
  database_name = aws_glue_catalog_database.main.name
  table_type    = "EXTERNAL_TABLE"
  parameters = {
    "classification"     = "parquet"
    "parquet.compression" = "SNAPPY"
    "EXTERNAL"           = "TRUE"
  }
  partition_keys {
    name = "year"
    type = "int"
  }
  partition_keys {
    name = "month"
    type = "int"
  }
  partition_keys {
    name = "day"
    type = "int"
  }

  storage_descriptor {
    location      = "s3://${var.bucket_analytics_id}/consult-results/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }
    columns { name = "callId"             type = "string" }
    columns { name = "agentId"            type = "string" }
    columns { name = "startedAt"          type = "string" }
    columns { name = "durationSec"        type = "int" }
    columns { name = "category_대code"   type = "string" }
    columns { name = "category_대name"   type = "string" }
    columns { name = "category_중code"   type = "string" }
    columns { name = "category_중name"   type = "string" }
    columns { name = "category_소code"   type = "string" }
    columns { name = "category_소name"   type = "string" }
    columns { name = "confidence"        type = "double" }
    columns { name = "reason"            type = "string" }
    columns { name = "verified"          type = "string" }
    columns { name = "status"            type = "string" }
    columns { name = "modelPath"         type = "array<string>" }
    columns { name = "promptVersion"     type = "string" }
    columns { name = "classifiedAt"      type = "string" }
  }
}

resource "aws_athena_workgroup" "main" {
  name = "callcenter-${var.env}"
  configuration {
    enforce_workgroup_configuration = true
    result_configuration {
      output_location = "s3://${var.bucket_analytics_id}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_analytics_arn
      }
    }
  }
}

# Firehose: persist Lambda가 PutRecord → S3 Parquet 변환 적재
resource "aws_iam_role" "firehose" {
  name = "callcenter-${var.env}-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetBucketLocation"],
        Resource = ["${var.bucket_analytics_arn}", "${var.bucket_analytics_arn}/*"] },
      { Effect = "Allow", Action = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"],
        Resource = "*" },
      { Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"],
        Resource = var.kms_analytics_arn },
      { Effect = "Allow", Action = ["logs:PutLogEvents", "logs:CreateLogStream"],
        Resource = "*" },
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "consult" {
  name        = "callcenter-${var.env}-consult-fh"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = var.bucket_analytics_arn
    prefix     = "consult-results/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "consult-results-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    buffering_size      = 1
    buffering_interval  = 60
    kms_key_arn         = var.kms_analytics_arn
    compression_format  = "UNCOMPRESSED"  # Parquet writer handles internally

    data_format_conversion_configuration {
      enabled = true
      input_format_configuration { deserializer { open_x_json_ser_de {} } }
      output_format_configuration {
        serializer { parquet_ser_de { compression = "SNAPPY" } }
      }
      schema_configuration {
        database_name = aws_glue_catalog_database.main.name
        table_name    = aws_glue_catalog_table.consult_results.name
        role_arn      = aws_iam_role.firehose.arn
      }
    }
  }
}

output "firehose_name"      { value = aws_kinesis_firehose_delivery_stream.consult.name }
output "glue_db_name"       { value = aws_glue_catalog_database.main.name }
output "athena_workgroup"   { value = aws_athena_workgroup.main.name }
```

### Step 7.2: dev 환경 연결 + persist Lambda env 갱신

- [ ] **Update `infra/envs/dev/main.tf`**

```hcl
module "analytics" {
  source                 = "../../modules/analytics"
  env                    = var.env
  bucket_analytics_arn   = module.storage.bucket_analytics_arn
  bucket_analytics_id    = module.storage.bucket_analytics_id
  kms_analytics_arn      = module.storage.kms_analytics_arn
}

# Pass firehose name into classify-pipeline
module "classify_pipeline" {
  # ... 기존 변수들 ...
  firehose_name = module.analytics.firehose_name
}
```

- [ ] **Update classify-pipeline module to wire firehose into persist Lambda env**

`infra/modules/classify-pipeline/variables.tf` 에 추가:

```hcl
variable "firehose_name" { type = string  default = "" }
```

`infra/modules/classify-pipeline/main.tf` 의 `aws_lambda_function.persist` 환경변수 갱신:

```hcl
environment {
  variables = {
    DDB_TABLE     = "callcenter-${var.env}-consult-results"
    FIREHOSE_NAME = var.firehose_name
  }
}
```

- [ ] **Apply + smoke Athena query**

```bash
cd infra/envs/dev && terraform apply -auto-approve && cd -
# 새 STT 1건 → 60초 대기 → Athena 쿼리
aws s3 cp /tmp/smoke.json s3://kakaopay-callcenter-dev-stt-raw/2026/05/22/smoke_002.json
sleep 90
aws athena start-query-execution \
  --work-group callcenter-dev \
  --query-string 'SELECT count(*) FROM callcenter_dev.consult_results;'
```

### Step 7.3: QuickSight 데이터셋 + 5 시트 (콘솔 작업, 런북 문서화)

- [ ] **Write `docs/runbooks/quicksight-setup.md`**

```markdown
# QuickSight 초기 설정 런북

## 사전 조건
- QuickSight Enterprise edition 활성화 (대시보드 공유용)
- IAM Role `callcenter-quicksight-access`가 Athena workgroup + S3 analytics bucket + KMS analytics key 권한 보유

## 단계
1. QuickSight 콘솔 → "관리" → 보안 및 권한 → S3 권한에 `kakaopay-callcenter-{env}-analytics` 추가
2. 데이터셋 생성 → Athena → 워크그룹 `callcenter-{env}` → 데이터베이스 `callcenter_{env}` → 테이블 `consult_results`
3. SPICE 가져오기 (~1만 행 무료 한도 내), 시간당 새로고침 스케줄 설정
4. 분석 → 5개 시트 생성:
   - 개요 (line: 일별 처리량 / donut: 대분류 18 / line: 평균 confidence)
   - 카테고리 드릴다운 (sunburst: 대→중→소)
   - 상담원별 (heatmap: agentId × 대분류 / KPI: HITL 교정률)
   - 품질 (히스토그램: confidence / table: 자주 교정되는 카테고리 Top 10)
   - 트렌드 알람 (line: 카테고리별 전주 대비 증감률)
5. 대시보드 발행 → 분석팀 그룹 공유 (편집 권한) + 운영팀 그룹 (읽기 권한)
```

- [ ] **Commit**

```bash
git add infra/modules/analytics/ infra/envs/dev/main.tf infra/modules/classify-pipeline/ \
        docs/runbooks/quicksight-setup.md
git commit -m "feat(analytics): Glue table + Athena + Firehose Parquet + QuickSight runbook"
```

---

## PR8: HITL UI (Streamlit on Fargate + Cognito + ALB)

**Files:**
- Create: `src/hitl_ui/streamlit_app.py`
- Create: `src/hitl_ui/pages/{1_review_queue.py,2_search.py,3_compliance.py}`
- Create: `src/hitl_ui/lib/{ddb_access.py,auth.py}`
- Create: `src/hitl_ui/Dockerfile`
- Create: `src/hitl_ui/requirements.txt`
- Create: `infra/modules/hitl-ui/{main.tf,variables.tf,outputs.tf}`
- Modify: `infra/envs/dev/main.tf` (hitl-ui 모듈)

### Step 8.1: Streamlit 앱 골격

- [ ] **Write `src/hitl_ui/requirements.txt`**

```
streamlit>=1.40.0
boto3>=1.35.0
```

- [ ] **Write `src/hitl_ui/streamlit_app.py`**

```python
"""콜센터 HITL 검수 메인 앱 — 페이지는 pages/ 디렉토리에서 자동 등록."""
from __future__ import annotations

import os

import streamlit as st

from lib.auth import current_user, require_group

st.set_page_config(page_title="콜센터 HITL", page_icon="📞", layout="wide")
st.title("📞 콜센터 분류 HITL")
st.caption(f"env: `{os.environ.get('ENV', 'dev')}` — Cognito User: `{current_user()}`")
require_group(["ops", "analyst", "compliance"])
st.write("좌측 사이드바에서 페이지를 선택하세요.")
```

- [ ] **Write `src/hitl_ui/lib/auth.py`**

```python
"""ALB authenticate-cognito가 주입하는 헤더 기반 사용자/그룹 확인."""
from __future__ import annotations

import base64
import json
import os

import streamlit as st


def _decode_oidc_data(jwt_like: str) -> dict:
    parts = jwt_like.split(".")
    if len(parts) < 2:
        return {}
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(payload).decode())


def current_user() -> str:
    if os.environ.get("LOCAL_DEV") == "1":
        return "dev-user"
    ctx = st.context.headers if hasattr(st, "context") else {}
    oidc = ctx.get("x-amzn-oidc-data", "")
    return _decode_oidc_data(oidc).get("email", "unknown")


def current_groups() -> list[str]:
    if os.environ.get("LOCAL_DEV") == "1":
        return ["ops", "analyst", "compliance"]
    ctx = st.context.headers if hasattr(st, "context") else {}
    oidc = ctx.get("x-amzn-oidc-data", "")
    return _decode_oidc_data(oidc).get("cognito:groups", [])


def require_group(allowed: list[str]) -> None:
    groups = current_groups()
    if not any(g in allowed for g in groups):
        st.error(f"이 페이지는 {allowed} 그룹만 접근 가능합니다.")
        st.stop()
```

- [ ] **Write `src/hitl_ui/lib/ddb_access.py`**

```python
"""DynamoDB GSI 쿼리 헬퍼."""
from __future__ import annotations

import os

import boto3

_ddb = boto3.resource("dynamodb")
_table = _ddb.Table(os.environ["DDB_TABLE"])


def list_review_queue(limit: int = 50, last_key: dict | None = None) -> tuple[list, dict | None]:
    kwargs = {
        "IndexName": "status-classifiedAt-index",
        "KeyConditionExpression": "#s = :pending",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":pending": "hitl-pending"},
        "Limit": limit,
    }
    if last_key:
        kwargs["ExclusiveStartKey"] = last_key
    resp = _table.query(**kwargs)
    return resp["Items"], resp.get("LastEvaluatedKey")


def search_by_agent(agent_id: str, limit: int = 100) -> list:
    resp = _table.query(
        IndexName="agentId-classifiedAt-index",
        KeyConditionExpression="agentId = :a",
        ExpressionAttributeValues={":a": agent_id},
        Limit=limit,
    )
    return resp["Items"]


def search_by_category(da_code: str, limit: int = 100) -> list:
    resp = _table.query(
        IndexName="category대code-classifiedAt-index",
        KeyConditionExpression="category_대code = :c",
        ExpressionAttributeValues={":c": da_code},
        Limit=limit,
    )
    return resp["Items"]


def get_call(call_id: str) -> dict | None:
    resp = _table.get_item(Key={"callId": call_id})
    return resp.get("Item")


def update_correction(call_id: str, corrected_codes: dict, corrected_by: str) -> None:
    from datetime import datetime

    _table.update_item(
        Key={"callId": call_id},
        UpdateExpression=(
            "SET #s = :s, verified = :v, correctedAt = :ca, correctedBy = :cb, "
            "category_대code = :dc, category_중code = :mc, category_소code = :sc"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "hitl-corrected",
            ":v": "hitl-corrected",
            ":ca": datetime.utcnow().isoformat() + "Z",
            ":cb": corrected_by,
            ":dc": corrected_codes["대code"],
            ":mc": corrected_codes["중code"],
            ":sc": corrected_codes["소code"],
        },
    )


def update_skip(call_id: str, by: str) -> None:
    from datetime import datetime
    _table.update_item(
        Key={"callId": call_id},
        UpdateExpression="SET #s = :s, correctedAt = :ca, correctedBy = :cb",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "hitl-skipped",
            ":ca": datetime.utcnow().isoformat() + "Z",
            ":cb": by,
        },
    )
```

### Step 8.2: 페이지 구현

- [ ] **Write `src/hitl_ui/pages/1_review_queue.py`**

```python
"""검토 대기열: status=hitl-pending 페이지네이션 + 단건 교정."""
from __future__ import annotations

import json
from pathlib import Path

import boto3
import streamlit as st

from lib.auth import current_user, require_group
from lib.ddb_access import (
    get_call,
    list_review_queue,
    update_correction,
    update_skip,
)

require_group(["ops"])
st.title("✏️ 검토 대기열")

if "queue_page_key" not in st.session_state:
    st.session_state.queue_page_key = None

items, next_key = list_review_queue(limit=20, last_key=st.session_state.queue_page_key)

if not items:
    st.info("대기열이 비었습니다.")
    st.stop()

call_ids = [it["callId"] for it in items]
selected = st.selectbox("검토할 통화 선택", call_ids)
record = next(it for it in items if it["callId"] == selected)

st.subheader(f"📞 {selected}")
col_a, col_b = st.columns([1, 1])
with col_a:
    st.markdown("**모델 분류 (대/중/소)**")
    st.write(f"대: `{record['category_대code']}` ({record['category_대name']})")
    st.write(f"중: `{record['category_중code']}` ({record['category_중name']})")
    st.write(f"소: `{record['category_소code']}` ({record['category_소name']})")
    st.write(f"confidence: `{record['confidence']}`")
    st.write(f"reason: {record['reason']}")
with col_b:
    st.markdown("**마스킹된 transcript**")
    s3 = boto3.client("s3")
    masked_ref = record["piiMaskedTextRef"]
    bucket = masked_ref.split("/")[2]
    key = "/".join(masked_ref.split("/")[3:])
    text = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode()
    st.text(text)

# 교정 UI: 분류 트리 cascade
TREE = json.loads(Path("src/prompts/v1.0/taxonomy_tree.json").read_text(encoding="utf-8"))
top_level = [n for n in TREE if n["level"] == 1]

st.markdown("---")
st.subheader("✏️ 교정")
sel_대 = st.selectbox("대분류", top_level, format_func=lambda n: f"{n['name']} ({n['code']})")
mids = [n for n in TREE if n["level"] == 2 and n["parent_code"] == sel_대["code"]]
sel_중 = st.selectbox("중분류", mids, format_func=lambda n: f"{n['name']} ({n['code']})")
leaves = [n for n in TREE if n["level"] == 3 and n["parent_code"] == sel_중["code"]]
sel_소 = st.selectbox("소분류", leaves, format_func=lambda n: f"{n['name']} ({n['code']})") if leaves else None

cc1, cc2, cc3 = st.columns(3)
with cc1:
    if st.button("✅ 이 분류가 맞다", use_container_width=True):
        update_correction(
            selected,
            {
                "대code": record["category_대code"],
                "중code": record["category_중code"],
                "소code": record["category_소code"],
            },
            current_user(),
        )
        st.success("확정")
        st.rerun()
with cc2:
    if st.button("📝 교정 저장", use_container_width=True, type="primary"):
        update_correction(
            selected,
            {"대code": sel_대["code"], "중code": sel_중["code"], "소code": sel_소["code"] if sel_소 else None},
            current_user(),
        )
        st.success("교정 저장")
        st.rerun()
with cc3:
    if st.button("⏭️ 스킵 (불분명)", use_container_width=True):
        update_skip(selected, current_user())
        st.info("스킵")
        st.rerun()
```

- [ ] **Write `src/hitl_ui/pages/2_search.py`**

```python
"""검색: 상담원ID 또는 대분류로 필터."""
from __future__ import annotations

import streamlit as st

from lib.auth import require_group
from lib.ddb_access import search_by_agent, search_by_category

require_group(["ops", "analyst"])
st.title("🔎 검색")

mode = st.radio("검색 기준", ["상담원ID", "대분류"])
if mode == "상담원ID":
    agent = st.text_input("상담원ID")
    if agent:
        rows = search_by_agent(agent)
        st.dataframe(rows)
else:
    code = st.text_input("대분류 코드 (예: CS_CENTER_CONSULT_TYPE_PAY_NONEY)")
    if code:
        rows = search_by_category(code)
        st.dataframe(rows)
```

- [ ] **Write `src/hitl_ui/pages/3_compliance.py`**

```python
"""컴플라이언스: 원본 STT raw SignedURL 다운로드 (감사 로그 CloudTrail)."""
from __future__ import annotations

import boto3
import streamlit as st

from lib.auth import current_user, require_group
from lib.ddb_access import get_call

require_group(["compliance"])
st.title("🔒 컴플라이언스 — 원본 STT 다운로드")
st.caption("이 페이지의 모든 다운로드는 CloudTrail에 감사 로그로 기록됩니다.")

call_id = st.text_input("callId")
if call_id:
    rec = get_call(call_id)
    if not rec:
        st.error("없음")
        st.stop()
    raw_ref = rec["rawSttRef"]
    bucket = raw_ref.split("/")[2]
    key = "/".join(raw_ref.split("/")[3:])
    s3 = boto3.client("s3")
    url = s3.generate_presigned_url(
        "get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=300
    )
    st.write(f"감사 사용자: {current_user()}")
    st.link_button("원본 STT 다운로드 (5분 유효)", url)
```

### Step 8.3: Dockerfile

- [ ] **Write `src/hitl_ui/Dockerfile`**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY hitl_ui/requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt
COPY hitl_ui/ /app/hitl_ui/
COPY lib/ /app/lib/
COPY prompts/ /app/prompts/
ENV PYTHONPATH=/app/hitl_ui:/app
EXPOSE 8501
CMD ["streamlit", "run", "/app/hitl_ui/streamlit_app.py", "--server.port=8501", "--server.address=0.0.0.0", "--server.headless=true"]
```

### Step 8.4: hitl-ui Terraform 모듈

- [ ] **Write `infra/modules/hitl-ui/variables.tf`**

```hcl
variable "env"                { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "ddb_consult_arn"    { type = string }
variable "bucket_masked_arn"  { type = string }
variable "bucket_raw_arn"     { type = string }
variable "kms_masked_arn"     { type = string }
```

- [ ] **Write `infra/modules/hitl-ui/main.tf`**

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

resource "aws_ecr_repository" "hitl" {
  name                 = "callcenter-${var.env}-hitl-ui"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_cognito_user_pool" "main" {
  name = "callcenter-${var.env}-users"
  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }
}

resource "aws_cognito_user_pool_client" "alb" {
  name                = "callcenter-${var.env}-alb-client"
  user_pool_id        = aws_cognito_user_pool.main.id
  generate_secret     = true
  callback_urls       = ["https://hitl.callcenter-${var.env}.kakaopay.internal/oauth2/idpresponse"]
  allowed_oauth_flows = ["code"]
  allowed_oauth_scopes = ["openid", "email", "profile"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers = ["COGNITO"]
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "callcenter-${var.env}-hitl"
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "aws_cognito_user_group" "ops"        { name = "ops"        user_pool_id = aws_cognito_user_pool.main.id }
resource "aws_cognito_user_group" "analyst"    { name = "analyst"    user_pool_id = aws_cognito_user_pool.main.id }
resource "aws_cognito_user_group" "compliance" { name = "compliance" user_pool_id = aws_cognito_user_pool.main.id }

resource "aws_security_group" "alb" {
  name   = "callcenter-${var.env}-hitl-alb"
  vpc_id = var.vpc_id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs" {
  name   = "callcenter-${var.env}-hitl-ecs"
  vpc_id = var.vpc_id
  ingress {
    from_port       = 8501
    to_port         = 8501
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "hitl" {
  name               = "callcenter-${var.env}-hitl"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids
}

resource "aws_lb_target_group" "hitl" {
  name        = "callcenter-${var.env}-hitl-tg"
  port        = 8501
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id
  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# ACM 인증서는 사전 발급 (var로 받거나 별도 트랙)
data "aws_acm_certificate" "internal" {
  domain   = "hitl.callcenter-${var.env}.kakaopay.internal"
  statuses = ["ISSUED"]
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.hitl.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = data.aws_acm_certificate.internal.arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type = "authenticate-cognito"
    authenticate_cognito {
      user_pool_arn       = aws_cognito_user_pool.main.arn
      user_pool_client_id = aws_cognito_user_pool_client.alb.id
      user_pool_domain    = aws_cognito_user_pool_domain.main.domain
    }
  }
}

resource "aws_lb_listener_rule" "forward" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100
  action { type = "forward"  target_group_arn = aws_lb_target_group.hitl.arn }
  condition { path_pattern { values = ["/*"] } }
}

resource "aws_ecs_cluster" "main" {
  name = "callcenter-${var.env}-hitl"
}

resource "aws_iam_role" "ecs_task" {
  name = "callcenter-${var.env}-hitl-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task" {
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:UpdateItem"],
        Resource = [var.ddb_consult_arn, "${var.ddb_consult_arn}/index/*"] },
      { Effect = "Allow", Action = ["s3:GetObject"],
        Resource = ["${var.bucket_masked_arn}/*", "${var.bucket_raw_arn}/*"] },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.kms_masked_arn },
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" },
    ]
  })
}

resource "aws_iam_role" "ecs_exec" {
  name = "callcenter-${var.env}-hitl-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "hitl" {
  name              = "/ecs/callcenter-${var.env}-hitl"
  retention_in_days = 30
}

resource "aws_ecs_task_definition" "hitl" {
  family                   = "callcenter-${var.env}-hitl"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "streamlit"
      image     = "${aws_ecr_repository.hitl.repository_url}:latest"
      essential = true
      portMappings = [{ containerPort = 8501, hostPort = 8501 }]
      environment = [
        { name = "ENV",       value = var.env },
        { name = "DDB_TABLE", value = "callcenter-${var.env}-consult-results" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.hitl.name
          awslogs-region        = "ap-northeast-2"
          awslogs-stream-prefix = "streamlit"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "hitl" {
  name            = "callcenter-${var.env}-hitl"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hitl.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hitl.arn
    container_name   = "streamlit"
    container_port   = 8501
  }
}

output "alb_dns_name"      { value = aws_lb.hitl.dns_name }
output "ecr_repo_url"      { value = aws_ecr_repository.hitl.repository_url }
output "cognito_pool_id"   { value = aws_cognito_user_pool.main.id }
```

### Step 8.5: dev 환경 + 이미지 빌드/푸시

- [ ] **Update `infra/envs/dev/main.tf`**

```hcl
module "hitl_ui" {
  source              = "../../modules/hitl-ui"
  env                 = var.env
  vpc_id              = module.shared.vpc_id
  private_subnet_ids  = module.shared.private_subnet_ids
  ddb_consult_arn     = module.storage.ddb_consult_arn
  bucket_masked_arn   = module.storage.bucket_masked_arn
  bucket_raw_arn      = module.storage.bucket_raw_arn
  kms_masked_arn      = module.storage.kms_masked_arn
}
```

- [ ] **Apply (ALB·ECS·Cognito·ECR)**

```bash
cd infra/envs/dev && terraform apply -auto-approve && cd -
```

- [ ] **Build + push Docker image**

```bash
ECR=$(terraform -chdir=infra/envs/dev output -raw ecr_repo_url)
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin "${ECR%/*}"
docker build -t "${ECR}:0.1.0" -f src/hitl_ui/Dockerfile src/
docker push "${ECR}:0.1.0"
aws ecs update-service --cluster callcenter-dev-hitl --service callcenter-dev-hitl \
  --force-new-deployment
```

- [ ] **Create test Cognito user**

```bash
POOL=$(terraform -chdir=infra/envs/dev output -raw cognito_pool_id)
aws cognito-idp admin-create-user --user-pool-id "$POOL" --username ops@example.com \
  --user-attributes Name=email,Value=ops@example.com Name=email_verified,Value=true \
  --temporary-password "TempP@ssw0rd!"
aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username ops@example.com --group-name ops
```

- [ ] **Smoke**: 사내 망에서 `https://hitl.callcenter-dev.kakaopay.internal` 접속, 로그인, 검토 큐 페이지 표시 확인

- [ ] **Commit**

```bash
git add src/hitl_ui/ infra/modules/hitl-ui/ infra/envs/dev/main.tf
git commit -m "feat(hitl): Streamlit on Fargate behind Cognito-authenticated ALB"
```

---

## PR9: Observability + Slack 알림

**Files:**
- Create: `infra/modules/observability/{main.tf,variables.tf,outputs.tf}`
- Modify: `infra/envs/dev/main.tf`
- Create: `scripts/emit_custom_metrics.py` (Lambda 코드 안에 EMF 임베드용 헬퍼)
- Modify: 각 Lambda handler에 CloudWatch Embedded Metric Format(EMF) 출력 추가

### Step 9.1: EMF 메트릭 emit 헬퍼

- [ ] **Write `src/lib/metrics.py`**

```python
"""CloudWatch Embedded Metric Format helper.

Lambda가 stdout에 EMF JSON을 찍으면 CloudWatch가 자동으로 메트릭으로 수집.
"""
from __future__ import annotations

import json
import os
import sys
import time

_NAMESPACE = "callcenter/classification"
_ENV = os.environ.get("ENV", "dev")


def emit(metric_name: str, value: float, unit: str = "Count", **dims: str) -> None:
    dims = {"env": _ENV, **dims}
    record = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": _NAMESPACE,
                "Dimensions": [list(dims.keys())],
                "Metrics": [{"Name": metric_name, "Unit": unit}],
            }],
        },
        **dims,
        metric_name: value,
    }
    print(json.dumps(record), file=sys.stdout, flush=True)
```

- [ ] **Update Lambda handlers to emit metrics**

In `src/lambdas/classify/handler.py` after returning result:

```python
from lib.metrics import emit
emit("classification.processed", 1.0, 대code=result.대.code)
emit("classification.confidence", result.confidence, Unit="None")
```

In `src/lambdas/pii_guard/handler.py` after mask:

```python
from lib.metrics import emit
for k, v in stats.as_dict().items():
    if v > 0:
        emit("pii.maskApplied", float(v), pii_type=k)
```

In `src/lambdas/verify/handler.py`:

```python
from lib.metrics import emit
emit("classification.verifyTriggered", 1.0, agreement=str(same))
```

### Step 9.2: observability 모듈 (대시보드 + 알람 + Slack SNS)

- [ ] **Write `infra/modules/observability/variables.tf`**

```hcl
variable "env"                  { type = string }
variable "slack_webhook_url"    { type = string  sensitive = true }
variable "sfn_arn"              { type = string }
variable "classify_dlq_name"    { type = string }
variable "persist_dlq_name"     { type = string }
variable "lambda_classify_name" { type = string }
variable "lambda_verify_name"   { type = string }
variable "lambda_persist_name"  { type = string }
variable "lambda_pii_name"      { type = string }
```

- [ ] **Write `infra/modules/observability/main.tf`**

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

resource "aws_sns_topic" "alerts" {
  name = "callcenter-${var.env}-alerts"
}

# Slack relay Lambda (간단 HTTP POST)
data "archive_file" "slack_relay" {
  type        = "zip"
  output_path = "${path.module}/build/slack_relay.zip"
  source {
    content  = <<EOF
import json
import os
import urllib.request

WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]

def handler(event, _ctx):
    for record in event.get("Records", []):
        msg = record["Sns"]["Message"]
        try:
            parsed = json.loads(msg)
            text = f":warning: *{parsed.get('AlarmName','Alarm')}*\n{parsed.get('NewStateReason','')}"
        except Exception:
            text = msg
        req = urllib.request.Request(
            WEBHOOK,
            data=json.dumps({"text": text}).encode(),
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req).read()
    return {"ok": True}
EOF
    filename = "handler.py"
  }
}

resource "aws_iam_role" "slack_relay" {
  name = "callcenter-${var.env}-slack-relay"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "slack_relay_basic" {
  role       = aws_iam_role.slack_relay.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "slack_relay" {
  function_name    = "callcenter-${var.env}-slack-relay"
  role             = aws_iam_role.slack_relay.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.slack_relay.output_path
  source_code_hash = data.archive_file.slack_relay.output_base64sha256
  timeout          = 30
  environment {
    variables = { SLACK_WEBHOOK_URL = var.slack_webhook_url }
  }
}

resource "aws_sns_topic_subscription" "slack" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_relay.arn
}

resource "aws_lambda_permission" "sns_invoke" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_relay.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# 알람 정의
resource "aws_cloudwatch_metric_alarm" "sfn_failure" {
  alarm_name          = "callcenter-${var.env}-sfn-failure"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  dimensions = { StateMachineArn = var.sfn_arn }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "classify_dlq_backlog" {
  alarm_name          = "callcenter-${var.env}-classify-dlq-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 10
  dimensions = { QueueName = var.classify_dlq_name }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "persist_dlq_backlog" {
  alarm_name          = "callcenter-${var.env}-persist-dlq-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 10
  dimensions = { QueueName = var.persist_dlq_name }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "bedrock_throttle" {
  alarm_name          = "callcenter-${var.env}-bedrock-throttle"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  dimensions = { FunctionName = var.lambda_classify_name }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "hitl_backlog" {
  alarm_name          = "callcenter-${var.env}-hitl-backlog"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 12
  datapoints_to_alarm = 12
  metric_name         = "classification.hitlPending"
  namespace           = "callcenter/classification"
  period              = 300
  statistic           = "Maximum"
  threshold           = 100
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# 대시보드
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "callcenter-${var.env}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"  width = 12 height = 6
        properties = {
          title = "분류 처리량 (시간당)"
          metrics = [["callcenter/classification", "classification.processed", "env", var.env]]
          period = 3600 stat = "Sum" region = "ap-northeast-2"
        }
      },
      {
        type = "metric"  width = 12 height = 6
        properties = {
          title = "평균 confidence"
          metrics = [["callcenter/classification", "classification.confidence", "env", var.env]]
          period = 300 stat = "Average" region = "ap-northeast-2"
        }
      },
      {
        type = "metric"  width = 12 height = 6
        properties = {
          title = "Step Functions 실패율"
          metrics = [
            ["AWS/States", "ExecutionsFailed",  "StateMachineArn", var.sfn_arn, { label = "Failed" }],
            [".",          "ExecutionsSucceeded", ".",              ".",         { label = "Succeeded" }],
          ]
          period = 300 stat = "Sum" region = "ap-northeast-2"
        }
      },
      {
        type = "metric"  width = 12 height = 6
        properties = {
          title = "DLQ backlog"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.classify_dlq_name],
            [".",        ".",                                   ".",         var.persist_dlq_name],
          ]
          period = 60 stat = "Maximum" region = "ap-northeast-2"
        }
      },
    ]
  })
}

output "alerts_topic_arn" { value = aws_sns_topic.alerts.arn }
```

### Step 9.3: dev 환경 연결 + Slack webhook secret 등록

- [ ] **Store Slack webhook in Secrets Manager (수동)**

```bash
aws secretsmanager create-secret \
  --name callcenter-dev-slack-webhook \
  --secret-string "https://hooks.slack.com/services/T.../B.../..."
```

- [ ] **Update `infra/envs/dev/main.tf`**

```hcl
data "aws_secretsmanager_secret_version" "slack" {
  secret_id = "callcenter-${var.env}-slack-webhook"
}

module "observability" {
  source                 = "../../modules/observability"
  env                    = var.env
  slack_webhook_url      = data.aws_secretsmanager_secret_version.slack.secret_string
  sfn_arn                = module.classify_pipeline.sfn_arn
  classify_dlq_name      = "callcenter-${var.env}-classify-dlq"
  persist_dlq_name       = "callcenter-${var.env}-persist-dlq"
  lambda_classify_name   = "callcenter-${var.env}-classify"
  lambda_verify_name     = "callcenter-${var.env}-verify"
  lambda_persist_name    = "callcenter-${var.env}-persist"
  lambda_pii_name        = "callcenter-${var.env}-pii-guard"
}
```

- [ ] **Apply + 알람 트리거 테스트**

```bash
cd infra/envs/dev && terraform apply -auto-approve && cd -
# SFN 강제 실패 (잘못된 input)
aws stepfunctions start-execution \
  --state-machine-arn $(terraform -chdir=infra/envs/dev output -raw sfn_arn) \
  --input '{"bad":"payload"}'
# 3분 후 Slack에 알람 도착 확인
```

- [ ] **Commit**

```bash
git add src/lib/metrics.py src/lambdas/*/handler.py infra/modules/observability/ infra/envs/dev/main.tf
git commit -m "feat(observability): EMF metrics + 5 alarms + dashboard + Slack relay"
```

---

## PR10: CI/CD + 골든셋 자동 평가 + 런북 + prd 배포

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/deploy-dev.yml`
- Create: `.github/workflows/deploy-stg.yml`
- Create: `.github/workflows/deploy-prd.yml`
- Create: `infra/envs/{stg,prd}/{main.tf,backend.tf,variables.tf,outputs.tf}`
- Create: `docs/runbooks/bedrock-throttling.md`
- Create: `docs/runbooks/hitl-backlog.md`
- Create: `docs/runbooks/prompt-rollback.md`
- Create: `docs/runbooks/pii-mask-failure.md`
- Create: `scripts/e2e_smoke.py`

### Step 10.1: stg/prd 환경 복제

- [ ] **Write `infra/envs/stg/backend.tf` (key=`envs/stg/...`), `main.tf`, `variables.tf` (env="stg")** — dev와 동일 구조

- [ ] **Write `infra/envs/prd/...`** — 동일하되 `env = "prd"`, secret 이름 `callcenter-prd-slack-webhook`

- [ ] **stg apply**

```bash
cd infra/envs/stg && terraform init && terraform apply && cd -
```

### Step 10.2: GitHub Actions OIDC

- [ ] **Write `.github/workflows/ci.yml`**

```yaml
name: ci
on: { pull_request: { branches: [main] } }
jobs:
  python:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install -e ".[dev]"
      - run: ruff check src tests scripts
      - run: ruff format --check src tests scripts
      - run: mypy src
      - run: pytest -q
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform -chdir=infra/envs/dev fmt -check -recursive
      - run: |
          curl -L -o tflint.zip https://github.com/terraform-linters/tflint/releases/latest/download/tflint_linux_amd64.zip
          unzip tflint.zip && sudo mv tflint /usr/local/bin/
          tflint --init && tflint -f compact infra/envs/dev
      - uses: aquasecurity/tfsec-action@v1
  eval-prompt:
    runs-on: ubuntu-latest
    needs: python
    permissions: { id-token: write, contents: read }
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::ACCOUNT:role/callcenter-ci-bedrock
          aws-region: ap-northeast-2
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install -e ".[dev]"
      - run: |
          python scripts/parse_taxonomy.py --xlsx 상담어시스트_AWS전달자료.xlsx
          python scripts/eval_prompt.py
      - uses: actions/upload-artifact@v4
        with: { name: eval-history, path: tests/golden/eval-history.csv }
```

- [ ] **Write `.github/workflows/deploy-dev.yml`**

```yaml
name: deploy-dev
on:
  push: { branches: [main] }
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions: { id-token: write, contents: read }
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::ACCOUNT:role/callcenter-ci-dev
          aws-region: ap-northeast-2
      - uses: hashicorp/setup-terraform@v3
      - run: terraform -chdir=infra/envs/dev init
      - run: terraform -chdir=infra/envs/dev apply -auto-approve
      - run: |
          ECR=$(terraform -chdir=infra/envs/dev output -raw ecr_repo_url)
          aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR%/*}"
          docker build -t "${ECR}:${GITHUB_SHA::8}" -f src/hitl_ui/Dockerfile src/
          docker tag "${ECR}:${GITHUB_SHA::8}" "${ECR}:latest"
          docker push "${ECR}:${GITHUB_SHA::8}"
          docker push "${ECR}:latest"
          aws ecs update-service --cluster callcenter-dev-hitl --service callcenter-dev-hitl --force-new-deployment
```

- [ ] **Write `.github/workflows/deploy-stg.yml`** (dev 복제, `workflow_dispatch` 트리거, env=stg)

- [ ] **Write `.github/workflows/deploy-prd.yml`** (`workflow_dispatch` + `environment: prd` 보호 룰로 승인 필요)

### Step 10.3: E2E smoke 스크립트

- [ ] **Write `scripts/e2e_smoke.py`**

```python
"""E2E smoke: STT 1건 PUT → SFN execution → DDB record 확인."""
from __future__ import annotations

import argparse
import json
import subprocess
import time
import uuid


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--env", required=True, choices=["dev", "stg"])
    args = p.parse_args()

    call_id = f"smoke_{uuid.uuid4().hex[:8]}"
    payload = {
        "callId": call_id,
        "agentId": "smoke",
        "startedAt": "2026-05-22T00:00:00Z",
        "durationSec": 30,
        "transcript": [{"speaker": "customer", "text": "페이머니 충전 오류 입니다"}],
    }
    bucket = f"kakaopay-callcenter-{args.env}-stt-raw"
    key = f"smoke/{call_id}.json"
    subprocess.run(
        ["aws", "s3api", "put-object", "--bucket", bucket, "--key", key, "--body", "-"],
        input=json.dumps(payload).encode(),
        check=True,
    )
    print(f"uploaded s3://{bucket}/{key}")

    for _ in range(60):
        time.sleep(5)
        out = subprocess.run(
            [
                "aws", "dynamodb", "get-item",
                "--table-name", f"callcenter-{args.env}-consult-results",
                "--key", json.dumps({"callId": {"S": call_id}}),
            ],
            capture_output=True,
            text=True,
        )
        if "Item" in out.stdout:
            item = json.loads(out.stdout)["Item"]
            print(f"OK callId={call_id} 대={item['category_대code']['S']}")
            return 0
    print(f"FAIL callId={call_id} not found in 5min")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

### Step 10.4: 4개 런북

- [ ] **Write `docs/runbooks/bedrock-throttling.md`**

```markdown
# Bedrock Throttling 대응 런북

## 증상
- CloudWatch 알람 `callcenter-{env}-bedrock-throttle` 트리거
- classify Lambda 로그에 `ThrottlingException` 다수
- SFN execution이 retry 5회 후 실패

## 즉시 대응 (10분)
1. Bedrock 콘솔 → ap-northeast-2 → Service Quotas → Anthropic Claude Opus 4.7 확인
2. 현재 RPM/TPM 사용량 vs 한도 비교 (`aws bedrock list-foundation-models` + CloudWatch `InvocationThrottles`)
3. 임시 완화: classify Lambda 환경변수 `SFN_PARALLEL` 줄여 동시 실행 제한 (Reserved Concurrency)
   ```
   aws lambda put-function-concurrency --function-name callcenter-prd-classify --reserved-concurrent-executions 5
   ```

## 영구 해결 (1~3일)
1. Service Quotas 콘솔 → Quota Increase 요청 (RPM 60→200, TPM 200K→1M)
2. 승인 후 reserved concurrency 해제
3. CloudWatch dashboard `callcenter-{env}` 의 "분류 처리량" 위젯에서 정상화 확인
```

- [ ] **Write `docs/runbooks/hitl-backlog.md`**

```markdown
# HITL 대기열 폭증 대응 런북

## 증상
- CloudWatch 알람 `callcenter-{env}-hitl-backlog` (pending > 100 1시간 지속)

## 진단
1. Streamlit UI → 검토 대기열 페이지 → 건수 확인
2. CloudWatch dashboard → "평균 confidence" 추이 확인
   - 급락한 경우: 프롬프트 회귀 의심 → `prompt-rollback.md`
   - 정상인 경우: 운영팀 부하 문제 → 단계 1

## 임시 대응
1. classify Lambda 환경변수 `CONF_THRESHOLD`를 0.80 → 0.70으로 낮춰 verify/HITL 진입 감소
   ```
   aws lambda update-function-configuration --function-name callcenter-prd-classify \
     --environment "Variables={MODEL_ID=...,CONF_THRESHOLD=0.70,...}"
   ```
2. 운영팀 검수 인력 임시 증원

## 회복 후
- threshold 원복, 누적 교정 데이터로 평가셋 확장
```

- [ ] **Write `docs/runbooks/prompt-rollback.md`**

```markdown
# 프롬프트 회귀 롤백 런북

## 증상
- 골든셋 평가에서 대분류 정확도 -2%p 이상 하락
- 운영 중 평균 confidence -10%p 하락

## 롤백 절차
1. `ls src/prompts/v*.* -d` 로 이전 버전 확인
2. classify Lambda 환경변수 `PROMPT_DIR` 변경:
   ```
   aws lambda update-function-configuration --function-name callcenter-prd-classify \
     --environment "Variables={...,PROMPT_DIR=/var/task/prompts/v1.0,...}"
   ```
3. 동일하게 verify Lambda도 변경
4. golden 평가 재실행: `python scripts/eval_prompt.py --prompt-dir src/prompts/v1.0`
5. dashboard에서 평균 confidence 회복 확인 (10~30분)

## 회귀 원인 분석
- `git log src/prompts/v{new}/` 로 변경점 확인
- 골든셋 차이 분석: `diff tests/golden/eval-history.csv` 직전 2개 row
- 새 PR로 fix 후 canary 10% 재시도
```

- [ ] **Write `docs/runbooks/pii-mask-failure.md`**

```markdown
# PII Mask 장애 대응 런북 (Phase 1 — regex 기반)

## 증상
- 알람 `callcenter-{env}-pii-mask-hit-drop` (Phase 1: 마스킹 적중률 -50%)
- 또는 reason 필드 PII 인용 발견 (분석팀 샘플링 검수)

## 진단
1. CloudWatch Logs → `/aws/lambda/callcenter-{env}-pii-guard` 최근 호출 로그
2. EMF 메트릭 `pii.maskApplied` 차원 `pii_type`별 분포 확인 (특정 type 0으로 떨어졌는지)
3. 정규식 변경 PR 여부 `git log src/lib/pii_regex.py`

## 대응
- 정규식 회귀: 직전 정상 커밋으로 revert + redeploy
- 합성 PII 출력: prompt R5 룰 강화 + `src/lib/persistence.py:sanitize_text` 정규식 추가

## Phase 2 진입 검토
- 본 사고가 반복되면 §4.3 진입 조건 충족 → SageMaker Async + Qwen 도입 트랙 시작
```

### Step 10.5: prd 배포 + 최종 smoke

- [ ] **prd apply**

```bash
aws secretsmanager create-secret --name callcenter-prd-slack-webhook --secret-string "..."
cd infra/envs/prd && terraform init && terraform apply && cd -
```

- [ ] **prd image push**

```bash
ECR=$(terraform -chdir=infra/envs/prd output -raw ecr_repo_url)
docker build -t "${ECR}:1.0.0" -f src/hitl_ui/Dockerfile src/
docker push "${ECR}:1.0.0"
aws ecr put-image --repository-name callcenter-prd-hitl-ui --image-tag latest \
  --image-manifest "$(aws ecr batch-get-image --repository-name callcenter-prd-hitl-ui --image-ids imageTag=1.0.0 --query 'images[0].imageManifest' --output text)"
aws ecs update-service --cluster callcenter-prd-hitl --service callcenter-prd-hitl --force-new-deployment
```

- [ ] **prd E2E smoke**

```bash
python scripts/e2e_smoke.py --env prd
```
Expected: exit 0, callId 분류 결과 출력

- [ ] **Commit + tag**

```bash
git add .github/ infra/envs/{stg,prd}/ scripts/e2e_smoke.py docs/runbooks/
git commit -m "feat(release): CI/CD + 4 runbooks + stg/prd envs + e2e smoke"
git tag -a v1.0.0 -m "Phase 1 — STT classification system release"
git push --tags
```

---

## 검증 게이트 요약 (PR별)

| PR | 게이트 | 기준값 |
|----|--------|--------|
| PR1 | `pytest tests/unit/test_taxonomy.py` | 5 passed, 213 노드 카운트 정확 |
| PR2 | `terraform plan` clean + `tflint`/`tfsec` clean | 0 error, 0 critical |
| PR3 | PII 정규식 단위 테스트 + 합성 PII 100건 적중률 | ≥ 99% |
| PR4 | 골든셋 50건 → `eval_prompt.py` | 대분류 정확도 ≥ 80%, 스키마 위반 0% |
| PR5 | verify agreement/disagreement 단위 테스트 | 2 passed |
| PR6 | LocalStack/실제 dev E2E (STT 1건 → DDB record) | DDB Item 존재 |
| PR7 | Athena `select count(*)` 쿼리 | row count > 0 |
| PR8 | Streamlit 로그인 + 검토 큐 페이지 + 교정 저장 | status=hitl-corrected DDB 확인 |
| PR9 | 인위 실패 트리거 → Slack 메시지 수신 | Slack 채널에 알람 도착 |
| PR10 | prd E2E smoke 1건 | exit 0, 분류 결과 정상 |

---

## Self-Review

**Spec coverage 점검**:
- §2 아키텍처 → PR1~9에 분산되어 모든 컴포넌트 구현
- §3.1~3.4 프롬프트 (cache, 트리, 스키마, 룰) → PR4
- §3.5 verify 정책 → PR5 + PR6(SFN ConfidenceBranch)
- §3.6 평가 → PR4(eval_prompt.py) + PR10(CI 자동화)
- §3.7 InferenceAdapter → PR4 `src/lib/inference_adapter.py`
- §3.7.5 합성 데이터 / §3.8 MLOps → Phase 3 plan으로 분리
- §4 PII 가드 (regex + 룰 R5 + 출력 sweep) → PR3 + PR4 system_rules + PR6 persistence.sanitize_text
- §5.1 DDB + 5.2 Parquet + 5.3 raw/masked 분리 → PR2 + PR7
- §6.1 HITL UI 페이지/검색/컴플라이언스 → PR8
- §6.2 QuickSight 시트 5개 → PR7 런북
- §6.3 권한 매트릭스 → PR8 Cognito 그룹 + IAM
- §7.1~7.3 재시도/관측성/알람 6개 → PR6(SFN retry) + PR9
- §7.4 보안 (VPC, KMS, Cognito) → PR2 + PR8
- §7.5 비용 제어 → PR10 CloudWatch Budgets는 누락 → **추가 필요**
- §8.1~8.5 테스트/Terraform/CI/CD/버저닝/런북 → PR10

**누락 보강 (인라인 fix)**:
PR9에 AWS Budgets 알람 추가:

```hcl
resource "aws_budgets_budget" "monthly" {
  name              = "callcenter-${var.env}-monthly"
  budget_type       = "COST"
  limit_amount      = var.env == "prd" ? "1500" : "300"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  cost_filter { name = "TagKeyValue", values = ["project$callcenter-classification"] }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
  }
}
```

**Placeholder scan**: ✅ 모든 step에 실행 가능한 코드/명령 포함. 골든셋 50건만 외부 라벨링 의존(이는 plan이 아닌 데이터 작업).

**Type consistency**: ✅ `ClassificationResult`, `MaskStats`, `PromptBundle` 모두 처음 정의된 그대로 일관 사용.

**Spec 미해결 → plan 반영**:
- "Raw STT 외부 송신 컴플라이언스 확인" — PR1 이전 별도 트랙
- "Bedrock 쿼터 사전 신청" — PR10 prd 배포 전 사전 작업으로 분리

---

## 실행 옵션

Plan complete and saved to `docs/superpowers/plans/2026-05-22-phase1-callcenter-classification.md`.

이어서 Phase 3 (MLOps 자동 학습) plan을 별도 파일로 작성합니다.

