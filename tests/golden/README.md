# Golden Set — STT 분류 평가

이 디렉토리는 프롬프트 v1.0 분류 정확도를 검증하기 위한 골든셋이다.

## 현재 상태 (PR4 스캐폴드)

- `samples.json` — 5행 스캐폴드. **g001만 라벨링 완료**, g002~g005는 `"TBD"` placeholder.
- `expected_labels.json` — 사용하지 않는다. 라벨은 `samples.json`의 각 row에 `expected` 키로 임베드되어 있음.
- `eval-history.csv` — `scripts/eval_prompt.py` 실행 결과 누적 기록 (gitignore되지 않음, 의도된 추적).

## 다음 작업 (W2, 별도 PR)

> Phase 1 plan W2: 골든셋 50~100건 손-라벨링.

1. 운영팀과 협의하여 PII 마스킹이 끝난 실제 STT 50~100건 확보.
2. `samples.json`에 row 추가, 각 row의 `expected.대code/중code/소code`를
   v1.0 taxonomy의 실제 코드로 직접 채운다 (코드 오타 `NONEY`, `PAYNENT`
   그대로 인용).
3. `python3 scripts/eval_prompt.py` 실행 → 대분류 정확도 ≥ 80% 게이트.

## 사용법

```bash
# placeholder row 건너뛰고 평가
python3 scripts/eval_prompt.py --skip-tbd
```

게이트: 대분류 accuracy 80% 미만이면 exit 1.
