---
description: Run code review on current changes with confidence-based filtering
allowed-tools: Read, Glob, Grep, Bash(git diff:*), Bash(git log:*), Bash(git status:*)
---

# Code Review

Review the current code changes using confidence-based scoring against this project's CLAUDE.md.

## Step 1: Get Changes

- $ARGUMENTS 가 파일/경로를 지정하면 그것을 리뷰
- 그렇지 않으면 `git diff` (unstaged)
- unstaged가 없으면 `git diff --cached` (staged)

## Step 2: Review

각 변경 파일에 code-review skill 적용:
- CLAUDE.md project guidelines (특히 NONEY 오타 보존, 한글 boundary, Lambda staging-dir 패턴)
- 버그 검출 (Bedrock Converse cachePoint 형식, KMS scope, PII 누설)
- 코드 품질 (모듈 책임, 테스트 보강, Terraform 입력 사용)

## Step 3: Score and Filter

0-100 점수. confidence ≥ 75만 보고.

## Step 4: Output

구조화된 형식으로 출력. file path + line number + fix 제안 포함. 이슈 없으면 표준 충족 확인.

## Error Recovery

### Step 1: 변경 없음
- `git log -1 --oneline` 으로 마지막 커밋 확인
- `git branch --show-current` 로 브랜치 확인
- `/review path/to/file` 로 직접 지정 제안

### Step 2: CLAUDE.md 없음
- `/project-init:init-project` 실행 제안
- 또는 최소 conventions 섹션을 가진 CLAUDE.md 생성

### diff 500줄 초과
1. 보안 민감 파일 (hooks, IAM, Bedrock 호출) 우선
2. 로직 변경
3. docs (낮은 우선순위)
