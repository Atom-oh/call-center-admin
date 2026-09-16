#!/usr/bin/env bash
# lens×모델 매트릭스 병렬 fan-out. 인자: <diff> <lenses_dir> <workdir>
# lenses_dir 안의 각 *.txt 가 lens 하나(파일명 stem = lens 태그, 예: L2/L3/L4/L5) — 그 lens
# 전용 리뷰 프롬프트(자체 완결형: "이 lens만 봐"). 각 lens × 각 모델이 독립 에이전트 셀 하나
# (oh-my-cloud-skills 의 lens×model 매트릭스 설계 포팅).
#
# diff 전달은 CLI 별로 다름 — codex 는 stdin(`< "$DIFF"`, 파일이라 TTY 아님 → no-hang)을 그대로 읽지만,
# kiro-cli 는 stdin 을 안 읽고 어떤 툴도 부여받지 않으므로(아래 Kiro 셀 주석 참조) size-capped
# argv 텍스트로 직접 embed 한다(KIRO_DIFF_CAP — 커널 MAX_ARG_STRLEN(128KiB) 아래). timeout 백스톱 +
# 비대화형 플래그로 멈춤 방지. 슬롯이 비거나 종료코드가 0이 아니면 최대 PANEL_RETRIES 회 재시도
# (codex의 gpt-5.6-sol/bedrock-mantle 등 transient 흡수). 매 시도마다 $DIFF 를 다시 연다. 모든
# 셀(모델 수 × lens 수)이 병렬(&+wait) — 벽시계 ≈ 최슬로우 셀 하나, 순차합 아님.
set -uo pipefail
# Kiro 셀은 격리 cwd 로 `cd` 한 뒤에도 $DIFF/$WORK 를 참조하므로 두 경로를 절대화한다 —
# 호출자(워크플로)는 지금도 절대경로를 주지만 코드가 직접 보장하도록.
DIFF="$(realpath "$1" 2>/dev/null)" \
  || { echo "run-panel.sh: realpath failed to resolve diff path: $1" >&2; exit 1; }
LENSES_DIR="$2"; WORK="$3"
[ -n "$LENSES_DIR" ] || { echo "run-panel.sh: lenses_dir (\$2) must not be empty" >&2; exit 1; }
[ -n "$WORK" ] || { echo "run-panel.sh: workdir (\$3) must not be empty" >&2; exit 1; }
mkdir -p "$WORK" || { echo "run-panel.sh: failed to create workdir: $WORK" >&2; exit 1; }
WORK="$(realpath "$WORK")" \
  || { echo "run-panel.sh: realpath failed to resolve workdir: $WORK" >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/lib.sh"
ensure_slots "$WORK" || exit 1
SLOT="$WORK/slot"; RESP="$WORK/responded.txt"; : > "$RESP"
# 비-ephemeral 러너에서 $WORK 가 재사용되면 이전 실행이 남긴 severe/truncated/quota 플래그가
# 그대로 살아남아, 이번엔 모든 모델이 정상 응답해도 synthesize.sh 가 잘못된 배너를 붙이거나
# 강제 FAIL 하게 된다 — responded.txt/degraded-models.txt 처럼 매 실행 시작 시 리셋.
rm -f "$WORK/coverage-severe.flag" "$WORK/kiro-diff-truncated.flag" "$WORK/kiro-quota.flag" "$WORK/kiro-agent-fallback.flag" "$WORK/kiro-preflight.flag"
T="${PANEL_TIMEOUT:-300}"
RETRIES="${PANEL_RETRIES:-2}"

# glm-5(kiro-glm) 는 로스터에서 제외 — AWS-Demo-Platform 저장소의 PR#88 리뷰에서 이 모델만
# 4건의 오탐을 냈다(AWS-Demo-Platform 저장소의 ADR-015). 되살릴 때는 오탐률을 먼저 재측정할 것.
# claude-opus-4.8 → claude-opus-5, gpt-5.6-terra → gpt-5.6-sol 로 다른 러너 repo 와 정렬(2026-09-16).
KIRO_MODELS=("claude-opus-5:kiro-opus" "gpt-5.6-sol:kiro-gpt")
# 러너 이미지의 kiro-cli 는 unpinned vendor-latest 라(AWS-Demo-Platform 저장소의
# docker/actions-runner-claude/Dockerfile 참조) 아래 무툴/한도 시그니처 가정(2.11.1 기준)이 어느
# 버전에서 깨졌는지 로그에서 추적할 수 있게 버전을 첫 줄에 찍는다.
command -v kiro-cli >/dev/null 2>&1 && echo "run-panel.sh: $(kiro-cli --version 2>/dev/null | head -1)" >&2

shopt -s nullglob
LENS_FILES=("$LENSES_DIR"/*.txt)
shopt -u nullglob
if [ "${#LENS_FILES[@]}" -eq 0 ]; then
  echo "run-panel.sh: no *.txt lens files found in $LENSES_DIR" >&2
  exit 1
fi

# Kiro 월간 요청 한도 소진(ServiceQuotaExceededException reason=MONTHLY_REQUEST_COUNT)
# 시그니처. v2 엔진(현재 사용)은 stderr 에 "Monthly request limit reached / The limits
# reset on MM/DD" 를 찍고 **rc=0 + 빈 stdout** 으로 끝나 "빈 응답"과 구분이 안 된다;
# `--v3` 엔진은 rc=1 로 끝나되 메시지가 stdout 으로 나온다("You've reached your monthly
# usage limit", stderr 엔 JSON body 의 MONTHLY_REQUEST_COUNT/UsageLimitReachedError).
# 두 경로 모두 잡는다. 2026-09-10 claude-code-usage-dashboard 저장소 PR #31 리뷰에서 Kiro
# 전 셀 전멸의 실제 원인이 이것이었고(같은 KIRO_API_KEY 로 v2/v3 모두 같은 에러 — headless
# 플래그 문제가 아님), 옛 로직은 셀마다 재시도만 태우고 배너엔 "플래그 무효·바이너리 부재·
# 인증 실패 등"이라는 오답 후보만 남겼다.
# stderr 만 스캔한다 — 두 엔진 모두 stderr 에 시그니처를 남기고(v3 는 JSON body 의
# MONTHLY_REQUEST_COUNT), stdout(=슬롯)까지 보면 리뷰 대상 diff 가 이 문구를 인용하는 경우
# (이 스크립트 자신을 고치는 PR 이 그 예) 부분 응답이 한도 소진으로 오분류될 수 있다.
KIRO_QUOTA_RE='Monthly request limit reached|MONTHLY_REQUEST_COUNT|UsageLimitReachedError'

# `--agent` 로드 실패 시그니처. kiro-cli 2.11.1 은 이름 불일치·JSON 파싱 실패 모두에서
# stderr 에 "Error: no agent with name X found. Falling back to user specified default" 를
# 찍고 **rc=0 으로 기본 에이전트(툴 있음)를 그대로 실행**한다. 그대로 두면 무툴 계약이
# 조용히 깨진 채 정상 응답으로 집계되므로(`--trust-tools=` 가 무시되던 것과 같은 실패
# 양식) 시그니처를 잡아 슬롯을 비우고 severe 로 승격한다.
KIRO_AGENT_FALLBACK_RE='no agent with name|Falling back to user specified default|Json supplied at .* is invalid'

# 한 셀을 최대 $RETRIES 회 실행 — 슬롯이 비거나 rc≠0 이면 재시도(transient). 백그라운드로 호출.
#   try_panel <provider> <slot> <err> <cmd...>   (stdin=$DIFF, stdout=slot, stderr=err)
# 한도 소진·에이전트 폴백은 non-transient 라 재시도하지 않고 즉시 중단 — `$slot.quota` /
# `$slot.agentfail` 마커를 남기고 슬롯을 비운다(응답이 있어도 집계에서 제외).
# Codex stderr 에는 입력 diff 도 들어가므로 Kiro 전용 시그니처는 Kiro 프로세스에만 적용한다.
try_panel() {
  local provider="$1" slot="$2" err="$3"; shift 3
  local a rc=1
  for a in $(seq 1 "$RETRIES"); do
    "$@" > "$slot" 2>"$err" < "$DIFF"; rc=$?
    if [ "$provider" = kiro ] && grep -qE "$KIRO_AGENT_FALLBACK_RE" "$err" 2>/dev/null; then
      grep -E "$KIRO_AGENT_FALLBACK_RE" "$err" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | head -2 > "$slot.agentfail"
      : > "$slot"; rc=1
      echo "[agent-fallback] $(basename "$slot" .md) — kiro-cli ignored --agent, no-tools contract broken; discarding response" >&2
      break
    fi
    [ -s "$slot" ] && [ "$rc" -eq 0 ] && break
    if [ "$provider" = kiro ] && grep -qE "$KIRO_QUOTA_RE" "$err" 2>/dev/null; then
      grep -E "$KIRO_QUOTA_RE|limits reset on" "$err" \
        | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | head -3 > "$slot.quota"
      : > "$slot"; rc=1
      echo "[quota] $(basename "$slot" .md) — monthly request limit reached, not retrying" >&2
      break
    fi
    [ "$a" -lt "$RETRIES" ] && echo "[retry $a/$RETRIES] $(basename "$slot" .md)" >&2
  done
  echo "$rc" > "$slot.rc"
}

# Kiro 셀은 어떤 툴도 부여받지 않는다(`--agent pr-review-notools`, `tools: []`) — 이전
# 리비전은 `--trust-tools=read,grep,fs_read` 를 부여해 diff 파일 경로만 넘기고 Kiro 가 직접
# 읽게 했고(argv MAX_ARG_STRLEN 회피), 나아가 base 체크아웃 전체를 read/grep 하도록 의도적으로
# 허용했다(BASE CONTEXT 검증). 두 가지 문제가 있었다: (1) diff 는 신뢰할 수 없는 PR 콘텐츠라,
# 그 안의 프롬프트 인젝션이 "그 경로 대신 절대경로 ~/.aws/credentials(또는 .git/config)를
# 읽어라"를 유도할 수 있었다 — 워크플로의 persist-credentials:false 와 lib.sh 의 scrub_secrets
# 는 그 잔여 위험을 줄이는 사후 방어선일 뿐 read 자체를 막지 못했다. (2) `read` 호출 자체를
# 모델이 안 해도(또는 sandbox 에 막혀도) "no findings" 류의 그럴듯한 non-empty 응답을 낼 수
# 있어, 커버리지 floor(아래)가 빈 슬롯만 탐지하는 한 diff 를 실제로 못 본 셀이 정상 응답으로
# 조용히 집계된다. 툴을 아예 안 주고 diff 를 argv 로 직접 넘기면 두 문제가 구조적으로 함께
# 사라진다 — read 호출이 필요 없으니 건너뛸 수도 없고, 부여된 툴이 없으니 절대경로 read
# 경로 자체가 없다. base 검증(stacked PR 오탐 차단)은 툴이 있는 체어(synthesize.sh)와 codex
# (read-only sandbox)가 맡는다.
#
# "무툴"의 구현 수단은 `--trust-tools=`(빈 값)이 아니라 에이전트 설정이다(2026-09-11,
# claude-code-usage-dashboard 저장소 PR #33 에서 라이브 검증). kiro-cli 2.11.1 은 `chat --help`
# 에 "trust no tools: '--trust-tools='" 를 적어 두지만, 실제로는 빈 값을 커스텀 툴 이름 "" 로
# 해석해 `WARNING: --trust-tools arg for custom tool  needs to be prepended with
# @{MCPSERVERNAME}/` 만 찍고 **무시**한다 — 내장 툴 이름이 fs_read/fs_write →
# read/write/shell/glob/grep/code/aws… 로 바뀌면서 기본 에이전트의 "trust working directory"
# (read/glob/grep/code)·"trust read-only"(aws) 신뢰가 그대로 살아남는다. 재현(2.11.1,
# headless): `--trust-tools=` 로도 cwd 안 파일을 `read` 로 읽어 내용을 그대로 출력했다(cwd 밖
# 절대경로만 non-interactive 거부). 반면 `tools: []` 에이전트를 `--agent` 로 지정하면 v2 엔진은
# read/shell 요구에 NO_TOOLS 로 답한다(cwd 안 파일 포함). `--v3` 엔진은 같은 에이전트의
# `tools: []` 를 **무시**하고 cwd 안 파일을 읽었으므로 v3 는 이 용도에 쓸 수 없다 —
# run-panel.sh 는 v2 엔진(기본)을 유지하고 v3 전용 `--mode default` 도 쓰지 않는다
# (AWS-Demo-Platform 저장소의 ADR-011 `--v3` 드롭 결정과도 일치 — 이 repo 자신의 ADR-011
# (HITL UI Fargate)과는 무관).
# 에이전트 파일은 셀마다 `$CELL_CWD/.kiro/agents/` 로 복사한다 — HOME=$CELL_CWD 이므로
# 전역(~/.kiro/agents)·워크스페이스(.kiro/agents) 탐색 경로가 같은 디렉터리로 모인다.
# 향후 kiro-cli 가 이 시맨틱을 또 바꾸면 이 fail-closed 가정도 재검증 필요.
# 격리는 셀(모델×lens)마다 별도 서브디렉터리로 유지한다 — 툴 제거와 격리는 직교한 두 결정이다:
# 매트릭스의 모든 kiro 셀이 동시(&) 실행되므로, 셀 하나의 cwd/HOME 을 공유하면 kiro-cli
# 의 세션/락 파일이 충돌할 수 있고, `env -i` 로 상속 env 를 비워 러너 env 의 크리덴셜성
# 변수가 셀 프로세스에 보이지 않게 한다(KIRO_API_KEY 만 명시 전달).
KIRO_CWD_BASE="$WORK/kiro-cwd"
[ -L "$KIRO_CWD_BASE" ] && { echo "run-panel.sh: \$KIRO_CWD_BASE is a symlink, refusing (TOCTOU guard)" >&2; exit 1; }
rm -rf "$KIRO_CWD_BASE"; mkdir -p "$KIRO_CWD_BASE"
KIRO_AGENT_NAME="pr-review-notools"
KIRO_AGENT_SRC="$DIR/agents/$KIRO_AGENT_NAME.json"
[ -f "$KIRO_AGENT_SRC" ] || { echo "run-panel.sh: kiro agent config missing: $KIRO_AGENT_SRC" >&2; exit 1; }
# 중복 JSON 키나 기본값 복원으로 툴이 살아나는 구성을 실행 전에 거부한다.
if ! python3 - "$KIRO_AGENT_SRC" "$KIRO_AGENT_NAME" <<'PY'
import json, sys
def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError("duplicate key")
        obj[key] = value
    return obj
try:
    with open(sys.argv[1]) as source:
        agent = json.load(source, object_pairs_hook=unique_object)
    valid = (agent["name"] == sys.argv[2] and agent["tools"] == []
             and agent["allowedTools"] == [] and agent["mcpServers"] == {}
             and agent["resources"] == [] and agent["useLegacyMcpJson"] is False)
    if not valid:
        raise ValueError("tool configuration")
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
PY
then
  echo "run-panel.sh: invalid no-tools agent configuration: $KIRO_AGENT_SRC" >&2
  exit 1
fi
prepare_kiro_agent() {
  local CELL_CWD="$1"
  mkdir -p "$CELL_CWD/.kiro/agents" && cp "$KIRO_AGENT_SRC" "$CELL_CWD/.kiro/agents/"
}
kiro_env() {
  local cell_cwd="$1"; shift
  env -i PATH="$PATH" HOME="$cell_cwd" LANG="${LANG:-}" LC_ALL="${LC_ALL:-}" TMPDIR="${TMPDIR:-/tmp}" \
    ${KIRO_API_KEY:+KIRO_API_KEY="$KIRO_API_KEY"} "$@"
}

# 사후 폴백 감지만으로는 이미 툴 있는 에이전트에 넘어간 diff 를 회수할 수 없다.
# 모든 Kiro 모델을 고정된 무해한 요청으로 먼저 검증한다. try_panel 은 stdin=$DIFF 이므로
# 여기서는 재사용하지 않고 /dev/null 을 넘긴다. 한 모델이라도 실패하면 Kiro 전체를 보류한다.
KIRO_PREFLIGHT_OK=0
KIRO_PREFLIGHT_PASSED=0
KIRO_PREFLIGHT_TIMEOUT="${KIRO_PREFLIGHT_TIMEOUT:-60}"
KIRO_PREFLIGHT_PROMPT="Kiro startup safety check. Read ./preflight-canary.txt using a file-reading tool and return its exact contents. If no file-reading tools are available, reply with exactly NO_TOOLS. Do not run any other tools."
if command -v kiro-cli >/dev/null 2>&1; then
  for entry in "${KIRO_MODELS[@]}"; do
    m="${entry%%:*}"; tag="${entry##*:}"
    PREFLIGHT_CWD="$KIRO_CWD_BASE/preflight/$tag"
    prepare_kiro_agent "$PREFLIGHT_CWD" \
      || { echo "run-panel.sh: failed to prepare Kiro preflight agent" >&2; exit 1; }
    python3 -c 'import secrets; print(secrets.token_hex(24))' > "$PREFLIGHT_CWD/preflight-canary.txt" \
      || { echo "run-panel.sh: failed to create Kiro preflight canary" >&2; exit 1; }
    PREFLIGHT_OUT="$PREFLIGHT_CWD/response.txt"; PREFLIGHT_ERR="$PREFLIGHT_CWD/stderr.txt"
    ( cd "$PREFLIGHT_CWD" && kiro_env "$PREFLIGHT_CWD" timeout "$KIRO_PREFLIGHT_TIMEOUT" \
        kiro-cli chat "$KIRO_PREFLIGHT_PROMPT" --model "$m" --agent "$KIRO_AGENT_NAME" \
        --no-interactive --wrap never ) > "$PREFLIGHT_OUT" 2> "$PREFLIGHT_ERR" < /dev/null
    PREFLIGHT_RC=$?
    if [ "$PREFLIGHT_RC" -eq 0 ] && python3 - "$PREFLIGHT_OUT" "$PREFLIGHT_ERR" \
        "$KIRO_AGENT_FALLBACK_RE" "$KIRO_QUOTA_RE" <<'PY'
import pathlib, re, sys
ansi = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
out, err = [ansi.sub("", pathlib.Path(p).read_text(errors="replace")) for p in sys.argv[1:3]]
reply = re.sub(r"(?m)^\s*> ?", "", out).strip()
blocked = re.search(sys.argv[3] + "|" + sys.argv[4] + "|using tool:", err, re.I)
sys.exit(0 if reply == "NO_TOOLS" and not blocked else 1)
PY
    then
      KIRO_PREFLIGHT_PASSED=$((KIRO_PREFLIGHT_PASSED + 1))
      echo "Kiro preflight passed: $tag (no PR input)" >&2
      continue
    fi
    KIRO_PREFLIGHT_OK=0
    printf '%s\n' "$tag startup check failed (exit $PREFLIGHT_RC); PR input withheld from all Kiro cells." > "$WORK/kiro-preflight.flag"
    : > "$WORK/coverage-severe.flag"
    if grep -qE "$KIRO_QUOTA_RE" "$PREFLIGHT_ERR"; then
      grep -E "$KIRO_QUOTA_RE|limits reset on" "$PREFLIGHT_ERR" | scrub_secrets > "$WORK/kiro-quota.flag"
    fi
    if grep -qE "$KIRO_AGENT_FALLBACK_RE" "$PREFLIGHT_ERR"; then
      grep -E "$KIRO_AGENT_FALLBACK_RE" "$PREFLIGHT_ERR" | scrub_secrets > "$WORK/kiro-agent-fallback.flag"
    fi
    echo "::error::Kiro preflight failed for $tag; no PR input sent to Kiro (see docs/runbooks/pr-review-panel.md)" >&2
    tail -25 "$PREFLIGHT_ERR" | scrub_secrets >&2
    break
  done
  if [ "$KIRO_PREFLIGHT_PASSED" -eq "${#KIRO_MODELS[@]}" ]; then
    KIRO_PREFLIGHT_OK=1
  fi
fi

# diff 는 size-capped argv 텍스트로 직접 embed — 단일 argv 128KiB 커널 한도(MAX_ARG_STRLEN)
# 아래로 캡한다. 이전 리비전이 argv 임베드를 피했던 이유(PR #113 에서 "Argument list too long"
# 으로 슬롯이 비던 것, `ps` 노출)는 여기선 실질적 트레이드오프가 아니다: (1) 캡으로 한도
# 아래를 보장하고, (2) 이 diff 는 PR diff 라 이미 GitHub 에 있는 내용이므로 `ps` 가시성이
# 새로운 기밀 노출이 아니다(공식 secret 이 아님).
KIRO_DIFF_CAP="${KIRO_DIFF_CAP:-100000}"
KIRO_DIFF_TEXT="$(head -c "$KIRO_DIFF_CAP" "$DIFF")"
# truncation 자체는 무해(대형 diff 의 의도된 트레이드오프)하지만, 신호 없이 넘어가면 Kiro
# 셀은 prefix 만 보고도 정상 응답으로 집계돼 "벤더 하나가 diff 일부만 보면 coverage 신호를
# 남긴다"는 계약을 조용히 어긴다 — synthesize.sh 가 리뷰 본문에 명시하도록 플래그 파일로 전달.
if [ "$(wc -c < "$DIFF")" -gt "$KIRO_DIFF_CAP" ]; then
  KIRO_DIFF_TEXT+=$'\n[...TRUNCATED at '"$KIRO_DIFF_CAP"'B — full diff not sent to Kiro...]'
  echo "::warning::diff exceeds KIRO_DIFF_CAP (${KIRO_DIFF_CAP}B) — Kiro cells only see a truncated prefix" >&2
  : > "$WORK/kiro-diff-truncated.flag"
fi

for lens_file in "${LENS_FILES[@]}"; do
  lens="$(basename "$lens_file" .txt)"
  LENS_PROMPT="$(cat "$lens_file")"

  # Codex (Bedrock, config.toml). --skip-git-repo-check 필수. AWS_REGION 강제: gpt-5.6-sol
  # (bedrock-mantle)는 In-Region(us-east-1) 만 지원 — 잡 region 무관하게 고정.
  if command -v codex >/dev/null 2>&1; then
    ( try_panel codex "$SLOT/codex-$lens.md" "$SLOT/codex-$lens.err" \
        env AWS_REGION="${CODEX_AWS_REGION:-us-east-1}" AWS_DEFAULT_REGION="${CODEX_AWS_REGION:-us-east-1}" \
        timeout "$T" codex exec -s read-only --skip-git-repo-check "$LENS_PROMPT" ) &
  else echo "[skip] codex/$lens (binary absent)" >&2; : > "$SLOT/codex-$lens.md"; fi

  # Kiro x2 — model:tag 를 한 배열에서 파생(호출/집계 동기화). Kiro's non-interactive
  # `chat` reads ONLY the prompt arg — it ignores stdin, so diff 는 argv 에 직접 embed(캡됨,
  # 툴 미부여 — 위 KIRO_DIFF_TEXT/`--agent pr-review-notools` 주석 참조). SECURITY data-only
  # guard 는 각 lens 프롬프트($LENS_PROMPT) 자체에 이미 포함되어 있다고 가정(워크플로의 COMMON 블록).
  KIRO_INSTRUCTION="$LENS_PROMPT"$'\n\n'"Review ONLY the diff below; do not read or reference any other files:"$'\n\n'"$KIRO_DIFF_TEXT"
  for entry in "${KIRO_MODELS[@]}"; do
    m="${entry%%:*}"; tag="${entry##*:}"
    if [ "$KIRO_PREFLIGHT_OK" = 1 ] && command -v kiro-cli >/dev/null 2>&1; then
      CELL_CWD="$KIRO_CWD_BASE/$tag-$lens"
      prepare_kiro_agent "$CELL_CWD" \
        || { echo "run-panel.sh: failed to prepare Kiro review agent" >&2; exit 1; }
      ( cd "$CELL_CWD" && try_panel kiro "$SLOT/$tag-$lens.md" "$SLOT/$tag-$lens.err" \
          kiro_env "$CELL_CWD" timeout "$T" kiro-cli chat "$KIRO_INSTRUCTION" --model "$m" \
          --agent "$KIRO_AGENT_NAME" --no-interactive --wrap never ) &
    else echo "[skip] $tag/$lens (binary absent or preflight failed)" >&2; : > "$SLOT/$tag-$lens.md"; fi
  done
done

# NOTE: Antigravity(agy) 는 제거됨 — OAuth 인터랙티브 로그인 전용(API 키 인증 모드 없음)
# 이라 헤드리스 CI 에서 인증 불가. 패널 = Codex + Kiro x2 → Claude 의장.
wait

# 결과 집계 (KIRO_MODELS·LENS_FILES 와 동일 소스에서 태그 파생 → 하드코딩 불일치 방지)
for lens_file in "${LENS_FILES[@]}"; do
  lens="$(basename "$lens_file" .txt)"
  record_result "$SLOT/codex-$lens.md" "codex/$lens" "$RESP"
  for entry in "${KIRO_MODELS[@]}"; do
    tag="${entry##*:}"; record_result "$SLOT/$tag-$lens.md" "$tag/$lens" "$RESP"
  done
done
echo "Panel responded ($(wc -l < "$RESP") / $(( (${#KIRO_MODELS[@]} + 1) * ${#LENS_FILES[@]} )) cells): $(tr '\n' ' ' < "$RESP")"

# 커버리지 floor — 모델 하나(`--agent`/플래그 무효화/바이너리 부재/전면 인증 실패 등)가 lens
# 전부에서 응답 없으면, 매트릭스가 조용히 그 모델 없이 축소된 채 VERDICT: PASS 로 이어질 수 있다.
# 모델별 row 가 완전히 비면 경고 + synthesize.sh 가 리뷰 본문에 명시하도록 파일로 전달.
TOTAL_MODELS=$(( ${#KIRO_MODELS[@]} + 1 ))
: > "$WORK/degraded-models.txt"
for model_tag in codex "${KIRO_MODELS[@]##*:}"; do
  row_count="$(grep -c "^${model_tag}/" "$RESP" 2>/dev/null)"
  if [ "${row_count:-0}" -eq 0 ]; then
    echo "::warning::model '$model_tag' produced zero responses across all ${#LENS_FILES[@]} lenses — coverage degraded" >&2
    echo "$model_tag" >> "$WORK/degraded-models.txt"
  fi
done

# 심각도 상향 — degraded 모델이 (전체-1)개 이상이면 살아남은 벤더가 최대 1개뿐이라, "매트릭스
# 자체가 lens당 교차확인"이라는 warn-only 의 전제가 성립하지 않는다. 이 경우만 severe 로
# 승격해 synthesize.sh 가 VERDICT 를 강제 FAIL 하도록 신호를 남긴다.
DEGRADED_COUNT=$(wc -l < "$WORK/degraded-models.txt")
if [ "$DEGRADED_COUNT" -ge "$((TOTAL_MODELS - 1))" ]; then
  echo "::error::coverage collapsed to ≤1 vendor ($DEGRADED_COUNT/$TOTAL_MODELS models degraded) — forcing VERDICT: FAIL, no cross-model check remains for any lens" >&2
  : > "$WORK/coverage-severe.flag"
fi

# lens 별 floor — 위 모델별 floor는 "이 모델이 모든 lens에서 죽었는가"만 본다. 반대로 한
# lens 전체(모든 모델)가 비어도 모델별 row 는 (다른 lens 응답 덕분에) 0 이 아닐 수 있어
# 위 체크를 통과한다 — 그 lens 는 아무도 리뷰하지 않았는데 매트릭스 상 정상으로 보인다.
: > "$WORK/degraded-lenses.txt"
for lens_file in "${LENS_FILES[@]}"; do
  lens="$(basename "$lens_file" .txt)"
  lens_count="$(grep -c "/${lens}$" "$RESP" 2>/dev/null)"
  if [ "${lens_count:-0}" -eq 0 ]; then
    echo "::warning::lens '$lens' produced zero responses across all models — this lens was not reviewed" >&2
    echo "$lens" >> "$WORK/degraded-lenses.txt"
    : > "$WORK/coverage-severe.flag"
  fi
done

# 에이전트 폴백 가시화 + severe 승격 — try_panel 이 남긴 `$slot.agentfail` 마커가 하나라도
# 있으면 그 러너의 kiro-cli 가 `--agent` 를 무시한 것이라 남은 Kiro 응답도 무툴 보장이 없다.
# 슬롯은 이미 비워져 있으므로(집계 제외) coverage 축으로도 잡히지만, 원인을 "빈 응답"이 아닌
# "계약 위반"으로 명시하고 체어 판정과 무관하게 FAIL 을 강제한다.
shopt -s nullglob
AGENTFAIL_MARKERS=("$SLOT"/*.agentfail)
shopt -u nullglob
if [ "${#AGENTFAIL_MARKERS[@]}" -gt 0 ]; then
  AGENTFAIL_DETAIL="$(cat "${AGENTFAIL_MARKERS[@]}" | scrub_secrets | grep -v '^\s*$' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  AGENTFAIL_CELLS="$(for q in "${AGENTFAIL_MARKERS[@]}"; do basename "$q" .md.agentfail; done | tr '\n' ' ' | sed 's/ *$//')"
  echo "::error::kiro-cli ignored --agent $KIRO_AGENT_NAME (fell back to the default agent WITH tools) in ${#AGENTFAIL_MARKERS[@]} cell(s) [$AGENTFAIL_CELLS]: $AGENTFAIL_DETAIL — responses discarded, forcing VERDICT: FAIL (no-tools contract)" >&2
  printf '%s\n' "$AGENTFAIL_DETAIL" > "$WORK/kiro-agent-fallback.flag"
  : > "$WORK/coverage-severe.flag"
  rm -f "${AGENTFAIL_MARKERS[@]}"
fi

# Kiro 월간 요청 한도 소진 가시화 — try_panel 이 남긴 `$slot.quota` 마커가 하나라도 있으면
# 위 degraded/severe 배너의 "플래그 무효·바이너리 부재·인증 실패 등" 추정 대신 실제 원인
# (KIRO_API_KEY 계정의 MONTHLY_REQUEST_COUNT 한도, 리셋 날짜)을 로그와 리뷰 코멘트에 명시한다.
# 한도는 이 러너 이미지를 공유하는 모든 repo 의 pr-review 가 같은 키로 소비하므로, 해소는
# 코드가 아니라 계정 측(overage 활성화 또는 /demo-platform/actions/AI-key 의 KIRO_API_KEY
# 교체)에서만 가능하다. fail-closed 계약(coverage-severe → 강제 FAIL)은 그대로 둔다.
shopt -s nullglob
QUOTA_MARKERS=("$SLOT"/*.quota)
shopt -u nullglob
if [ "${#QUOTA_MARKERS[@]}" -gt 0 ]; then
  QUOTA_DETAIL="$(cat "${QUOTA_MARKERS[@]}" | scrub_secrets | grep -v '^\s*$' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  QUOTA_CELLS="$(for q in "${QUOTA_MARKERS[@]}"; do basename "$q" .md.quota; done | tr '\n' ' ' | sed 's/ *$//')"
  echo "::error::Kiro monthly request quota exhausted for KIRO_API_KEY — ${#QUOTA_MARKERS[@]} cell(s) [$QUOTA_CELLS]: $QUOTA_DETAIL — enable overages or rotate the key (/demo-platform/actions/AI-key); not a headless-flag failure" >&2
  printf '%s\n' "$QUOTA_DETAIL" > "$WORK/kiro-quota.flag"
  rm -f "${QUOTA_MARKERS[@]}"
fi

# skip 원인 노출: 빈 슬롯인데 stderr 가 있으면 stderr 의 끝(실제 에러)을 로그에 찍는다.
# scrub_secrets 를 거쳐 원시 크리덴셜이 CI 로그로 새는 것을 막는다(record_result 의 [preview]
# 와 같은 방어선).
for e in "$SLOT"/*.err; do
  [ -s "$e" ] || continue
  b="$(basename "$e" .err)"
  [ -s "$SLOT/$b.md" ] && continue   # 응답 성공이면 건너뜀
  echo "--- [$b] skipped; stderr (last 25 lines, scrubbed) ---" >&2
  tail -25 "$e" | scrub_secrets >&2
done
