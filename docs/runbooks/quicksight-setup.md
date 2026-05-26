# Runbook: QuickSight Setup for Analyst Dashboards

- **Owner**: 분석팀 + 운영팀
- **Severity**: P3 (within 24h after dev apply success)
- **Last validated**: (작성 시점)

## When to Run This Runbook

PR7 `terraform apply` 가 dev 환경에 Glue + Firehose + Athena 를 만들어준 직후. QuickSight 대시보드는 콘솔에서 5개 시트를 손으로 구성해야 한다 (Terraform 으로 QuickSight 분석/대시보드를 정의할 수는 있으나 Phase 1 에서는 단순화).

## Prerequisites

- QuickSight Enterprise edition 활성 (대시보드 공유 위해 Enterprise 필요)
- IAM role `callcenter-quicksight-access` (또는 콘솔에서 자동 생성)
- 분석팀·운영팀·컴플라이언스 그룹이 Cognito 또는 QuickSight 자체 사용자 그룹으로 존재

## Step 1 — Activate QuickSight + grant S3/Athena access

1. AWS Console → QuickSight 활성화 (subscription type: Enterprise)
2. "Manage QuickSight" → "Security & permissions" → "QuickSight access to AWS services"
3. 다음 추가:
   - S3 bucket: `kakaopay-callcenter-${env}-analytics`
   - Athena workgroup: `callcenter-${env}`
   - AWS KMS: `alias/callcenter-${env}-analytics`

## Step 2 — Create dataset

1. Datasets → New dataset → Athena
2. Workgroup: `callcenter-${env}`
3. Database: `callcenter_${env}` → Table: `consult_results`
4. Import to SPICE (Direct Query 도 가능하나 SPICE 가 비용/속도 측면 권장)
5. Refresh schedule: 시간당 1회 (Phase 1 트래픽 기준 충분)

## Step 3 — Create the 5 sheets

대시보드 이름: `Call Center Classification — ${env}`

### Sheet 1: 개요
- KPI: 일/주/월 처리 건수
- Line chart: 시간대별 처리량 (`classifiedAt` X, count Y)
- Donut: 대분류 18 분포 (`category_대name`)
- Line: 평균 confidence 추이

### Sheet 2: 카테고리 드릴다운
- Sunburst (또는 hierarchical bar): `category_대name` → `category_중name` → `category_소name`
- 클릭 시 시계열로 cross-filter

### Sheet 3: 상담원별
- Heatmap: rows = `agentId`, columns = `category_대name`, value = count
- KPI: 상담원별 HITL 교정률 (`status="hitl-corrected"` / total)

### Sheet 4: 품질
- Histogram: `confidence` 분포
- Table: 자주 교정되는 카테고리 Top 10 (`hitl-corrected` count 기준)
- KPI: 자동 vs 사람 일치율

### Sheet 5: 트렌드 알람
- Line: 카테고리별 전주 대비 증감률
- QuickSight Insight: 급증 카테고리 자동 하이라이트

## Step 4 — Publish & share

1. Publish dashboard
2. 분석팀 그룹: Editor 권한
3. 운영팀 그룹: Reader 권한
4. 컴플라이언스 그룹: Reader 권한

## Step 5 — Verify

- 5분 후 첫 SPICE refresh 완료 확인
- 각 시트가 데이터 표시
- 권한별 그룹 멤버에게 대시보드 URL 공유

## Resolution / Rollback

대시보드 셋업 자체에 실패가 없으면 별다른 rollback 필요 없음. Glue/Athena/Firehose 는 Terraform 으로 관리되므로 `terraform destroy -target=module.analytics` 로 인프라 자체 롤백 가능.

## Escalation

- QuickSight subscription / billing 문제 → AWS Account Owner
- Glue / Athena 권한 누락 → 본 runbook §1 다시
- SPICE 한도 초과 → QuickSight admin → "Capacity" 에서 추가
