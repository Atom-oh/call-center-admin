# Runbook: AI PR-Review Panel — Kiro 셀 장애

- **Owner**: repo maintainer (AI Code Review 워크플로 소유자)
- **Severity**: P3 (within 24h) — 리뷰 게이트가 fail-closed 로 PR 머지를 막을 뿐, 프로덕션 영향 없음
- **Last validated**: 2026-09-12 (kiro-cli 2.11.1, 스텁 테스트 `tests/structure/test-pr-review-panel.sh`)

관련 파일: `scripts/pr-review/run-panel.sh`, `scripts/pr-review/synthesize.sh`,
`scripts/pr-review/agents/pr-review-notools.json`, `.github/workflows/pr-review.yml`

## When to Run This Runbook

`AI Code Review` PR 코멘트 상단에 아래 배너 중 하나가 붙고, Actions 로그에 대응하는
`::error::` 줄이 있을 때. 세 배너 모두 lens×model 매트릭스의 Kiro 절반(kiro-opus /
kiro-gpt / kiro-glm)이 기여를 멈췄다는 뜻이다. Codex 셀은 계속 리뷰하지만, Kiro 모델이 전부
죽으면 살아남은 벤더가 1개뿐이라 기존 커버리지 게이트가 `VERDICT: FAIL` 을 강제한다.

| 배너 | 플래그 파일 | 의미 |
|------|-------------|------|
| 🚫 Kiro 월간 요청 한도 소진 | `kiro-quota.flag` | `KIRO_API_KEY` 계정 월간 한도 도달 (Symptom A) |
| 🔓 Kiro 무툴 계약 위반 | `kiro-agent-fallback.flag` | kiro-cli 가 `--agent pr-review-notools` 를 무시함 (Symptom B) |
| 🛑 Kiro 사전 검증 실패 | `kiro-preflight.flag` | 리뷰 시작 전 고정 canary 검사 실패 — PR diff 미전송 (Symptom C) |

이 시그니처들은 **Kiro stderr 에서만** 해석한다. Codex 도 리뷰 대상 diff 를 stderr 에 그대로
출력하므로, diff 가 Kiro 오류 문구를 인용해도(이 스크립트 자신을 고치는 PR 이 그 예) 유효한
Codex 리뷰가 폐기되거나 재시도가 막히지 않는다.

## Prerequisites

- Actions 로그 읽기 권한(public repo — 누구나). 재실행은 `actions: write` 또는 PR 에 push.
- 키 교체가 필요하면 AWS-Demo-Platform 계정의 Secrets Manager
  `/demo-platform/actions/AI-key` 쓰기 권한. 이 repo 코드에서는 아무것도 바꿀 수 없다.
- 로컬 재현: `kiro-cli`(2.11.1 기준), `python3`, `jq`. **키 값을 절대 echo 하지 말 것.**

## 배경 — 사전 검증(preflight)과 무툴 계약

Kiro 리뷰 셀은 어떤 툴도 받지 않는다: diff 는 argv 에 inline 으로 들어가고(`KIRO_DIFF_CAP`
100KB 캡, 커널 MAX_ARG_STRLEN 회피), 각 셀은 빈 격리 cwd(=HOME) 에서 `tools: []` 에이전트로
실행된다. 이전 리비전은 `--trust-tools=read,grep,fs_read` 를 주고 diff **파일 경로**를 읽게
했으며 base 체크아웃까지 읽도록 허용했다 — diff 안의 프롬프트 인젝션이 절대경로 크리덴셜
read 를 유도할 수 있는 잔여 위험이 있었고, `--trust-tools=`(빈 값)은 kiro-cli 2.11.1 에서
무시된다(아래 Background). stacked PR 오탐 차단(BASE CONTEXT 검증)은 툴이 있는 체어와
codex 가 맡는다.

리뷰 전, 로스터의 모든 Kiro 모델이 자기 빈 디렉터리에서 고정 canary 프롬프트를 받는다.
디렉터리엔 무작위(비밀 아님) canary 파일만 있다. 통과 조건: exit 0, 응답이 정확히
`NO_TOOLS`, stderr 에 폴백/한도/툴 사용 시그니처 없음. PR diff 는 프롬프트에도 stdin 에도
없다. **세 모델 모두** 통과해야 하나라도 PR 입력을 받는다. 실행당 최대 3회 모델 호출이
추가되고 각각 `KIRO_PREFLIGHT_TIMEOUT`(기본 60s)에 묶인다. 실패하면 Kiro 리뷰 셀 전부를
건너뛰고 Codex 만 리뷰하며 커버리지 게이트가 항상 FAIL 을 강제한다.

## Diagnosis

Actions 로그의 "Run panel + synthesize" 스텝 첫 줄이 `run-panel.sh: kiro-cli X.Y.Z` 다 —
러너 이미지의 kiro-cli 는 pin 되지 않은 vendor-latest 라, 아래 시그니처 가정(2.11.1 기준)이
어느 버전에서 깨졌는지 이 줄로 추적한다.

| 증상 | 로그 시그니처 | 다음 단계 |
|------|---------------|-----------|
| 🚫 한도 소진 배너, `[quota] kiro-…` 줄, 재시도 없음 | `::error::Kiro monthly request quota exhausted for KIRO_API_KEY — … reset on MM/DD` | Symptom A |
| 🔓 계약 위반 배너, `[agent-fallback] kiro-…` 줄 | `::error::kiro-cli ignored --agent pr-review-notools (fell back to the default agent WITH tools)` | Symptom B |
| 🛑 사전 검증 실패 배너, Kiro 셀 전부 `[skip] … preflight failed` | `::error::Kiro preflight failed for <tag>; no PR input sent to Kiro` | Symptom C |
| 스텝이 시작 직후 exit 1 | `invalid no-tools agent configuration` / `failed to prepare Kiro … agent` | 에이전트 파일 손상(중복 키·툴 설정) 또는 `cp` 실패 — 스텝 로그에 직접 표시 |

## Resolution

### Symptom A — `🚫 Kiro 월간 요청 한도 소진`

원인: `KIRO_API_KEY` 뒤의 Kiro 계정이 `ServiceQuotaExceededException
reason=MONTHLY_REQUEST_COUNT` 를 반환. 키는 AWS-Demo-Platform 저장소가 관리하는 Secrets
Manager `/demo-platform/actions/AI-key`(ExternalSecret `ai-panel-keys`)에 있고,
`actions-runner-claude` 이미지로 PR 리뷰를 돌리는 **모든 repo 가 공유**한다 — 한 달 동안
어느 repo 든 많이 쓰면 전부에서 소진된다. headless 플래그 문제가 아니다: 소진되지 않은
로그인으로는 같은 호출이 성공하고, `--v3` 도 같은 한도에 걸린다.

해소(계정 측만 가능 — 이 repo 에서 할 수 있는 코드 변경은 없다):
1. 키를 소유한 Kiro 계정에 overage 를 활성화하거나, 잔여 한도가 있는 계정에서 키를 발급해
   `/demo-platform/actions/AI-key` 의 `KIRO_API_KEY` 를 갱신한다(ESO 가 러너 시크릿을
   갱신하고 새 러너 파드가 집어 간다).
2. 실패한 `AI Code Review` 워크플로를 재실행(또는 PR 에 push). Kiro 셀이 다시 응답하면
   배너가 사라진다.
3. 아무것도 하지 않으면 배너에 찍힌 날짜에 한도가 리셋된다.

로컬 확인(CI 분 소모 없이, 키는 절대 출력하지 않음):
```bash
K=$(aws secretsmanager get-secret-value --secret-id /demo-platform/actions/AI-key \
      --region ap-northeast-2 --query SecretString --output text | jq -r .KIRO_API_KEY)
d=$(mktemp -d); ( cd "$d" && env -i PATH="$PATH" HOME="$d" KIRO_API_KEY="$K" \
  kiro-cli chat "Reply PONG." --model gpt-5.6-terra --no-interactive --wrap never )
# 소진 → stderr "Monthly request limit reached", 빈 stdout, exit 0
```

### Symptom B — `🔓 Kiro 무툴 계약 위반`

원인: kiro-cli 가 `Error: no agent with name pr-review-notools found. Falling back to user
specified default` 를 찍고(에이전트 파일 부재, JSON 파싱 실패, 러너의 kiro-cli 버전이 거부하는
스키마 모두 같은 메시지) 기본 에이전트로 계속 실행했다. 기본 에이전트는 cwd 의
`read`/`glob`/`grep`/`code` 와 read-only `aws` 를 신뢰한다. 패널은 이를 보안 계약 위반으로
취급한다 — PR diff 는 신뢰할 수 없는 입력이고 Kiro 셀은 툴이 0개여야 한다. 응답이 비어 있지
않아도 폐기된다.

1. 패널 스텝 첫 줄의 kiro-cli 버전(`run-panel.sh: kiro-cli X.Y.Z`)을 에이전트 파일이 검증된
   버전(2.11.1)과 비교한다.
2. 그 버전으로 에이전트 파일을 검증한다(2.11.1 에서 확인된 명령):
   `kiro-cli agent validate --path scripts/pr-review/agents/pr-review-notools.json`
3. 다른 것을 바꾸기 전에 무툴 동작을 재확인한다:
   ```bash
   d=$(mktemp -d); mkdir -p "$d/.kiro/agents"
   cp scripts/pr-review/agents/pr-review-notools.json "$d/.kiro/agents/"
   echo CANARY > "$d/notes.txt"
   ( cd "$d" && kiro-cli chat "Read ./notes.txt and print it. If you have no tools, reply NO_TOOLS." \
       --agent pr-review-notools --model gpt-5.6-terra --no-interactive --wrap never )
   # 기대: NO_TOOLS, "using tool: read" 없음, CANARY 없음
   ```
4. 우회하려고 `--v3` / `--agent-engine v3` 로 **바꾸지 말 것**: v3 엔진은 에이전트의
   `tools: []` 를 무시하고 cwd 파일을 읽는다(AWS-Demo-Platform 저장소의 ADR-011 `--v3` 드롭
   결정과 일치; 이 repo 의 ADR-011 은 별개 주제다).

### Symptom C — `🛑 Kiro 사전 검증 실패`

고정 canary 검사가 요구 동작을 확인하지 못했다. PR 입력은 Kiro 에 전달되지 않았다. Actions
로그의 preflight stderr(스텝에 마지막 25줄이 스크럽되어 찍힘)를 본다: 한도·에이전트 폴백은
각자의 배너도 함께 남기고, 그 외 타임아웃·인증 오류·예상 밖 응답·툴 사용도 검사를 실패시킨다.
보고된 원인을 해소한 뒤 CI 를 재실행한다. preflight 를 우회하지 말 것.

잘못된 에이전트 JSON(중복 키 포함), 비어 있지 않은 tool/resource/MCP 설정, 에이전트 파일
복사 실패는 해당 모델을 시작하기 전에 패널 스텝을 중단시킨다. 이 구성 실패는 실패한 스텝
로그에 직접 나타난다.

러너 이미지와 CLI 버전은 AWS-Demo-Platform 저장소의 `docker/actions-runner-claude/Dockerfile`
이 관리한다 — 이미지를 pin 하거나 재빌드하는 것은 이 repo 의 리뷰 스크립트와 별개 변경이다.

## Verification

- 다음 PR 리뷰 코멘트 상단에 배너가 없고, `_Cells (model/lens):_` 줄에 `kiro-opus/…`,
  `kiro-gpt/…`, `kiro-glm/…` 셀이 다시 보인다.
- Actions 로그에 `Kiro preflight passed: kiro-opus / kiro-gpt / kiro-glm (no PR input)` 3줄.
- 로컬: `bash tests/run-all.sh` 의 `tests/structure/test-pr-review-panel.sh` 그룹이 모두 `ok`
  (모델 호출은 전부 스텁 — 실제 크레딧 소모 없음).

## Background

`--trust-tools=`(빈 값)이 무툴 수단으로 통용됐었다. kiro-cli 2.11.1 은 `chat --help` 에
여전히 그렇게 적어 두지만, 빈 값을 커스텀 툴 이름으로 해석해 `WARNING: --trust-tools arg for
custom tool  needs to be prepended with @{MCPSERVERNAME}/` 만 찍고 무시한다 — 셀이 cwd 파일을
읽을 수 있었다. 이 repo 는 한 걸음 더 나가 `--trust-tools=read,grep,fs_read` 로 base 체크아웃
읽기를 의도적으로 허용했었다(BASE CONTEXT 검증). 이번 변경(claude-code-usage-dashboard
저장소 PR #33 포팅)으로 Kiro 는 무툴 + inline diff 로 바뀌었고, base 검증은 체어/codex 로
옮겼다. `tests/structure/test-pr-review-panel.sh` 가 현재 메커니즘과 위 시그니처들을 핀한다.
