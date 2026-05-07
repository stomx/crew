# crew 사용 가이드

`/crew` 의 기본 사용은 [README.md](./README.md) 를 참고한다. 이 문서는 **plan JSON 직접 작성**, **이어가기**, **환경변수 튜닝** 같은 고급 시나리오를 다룬다.

## Plan JSON

메인 Claude 가 내부적으로 생성하는 plan 을 직접 쓰면 pane 수·모델·stage 를 명시 제어할 수 있다.

### 스키마

```jsonc
{
  "slug": "optional",                    // 선택. 생략 시 자동 생성
  "panes": [
    {
      "id": 1,                           // 1 이상, pane 순번
      "cli": "claude",                   // "claude" | "codex" | "gemini"
      "model": "opus",                   // CLI 별 모델 alias (티어 표 참고)
      "effort": "high",                  // low | medium | high | xhigh | max (gemini 제외)
      "role": "문서 초안",               // pane 탭 라벨에 표시
      "prompt_file": "/tmp/xxx/p1.txt",  // 절대경로. mktemp -d 권장
      "stage": 1,                        // 같은 stage 는 병렬, 작은 번호부터 순차
      "share_from": [1, "prev:2"]        // 같은 run 의 pane 번호 또는 이전 run 참조
    }
  ]
}
```

필드별 상세:

| 필드 | 필수 | 설명 |
|---|---|---|
| `slug` | 아님 | 생략 시 `ws-<workspace>/<timestamp>-<pid>-<rand>` 자동 부여 |
| `panes[].id` | 예 | 1 부터 시작하는 pane 순번. `share_from` 에서 이 번호로 참조 |
| `panes[].cli` | 예 | 부팅할 CLI |
| `panes[].model` | 아님 | 생략 시 CLI 기본 모델. 티어 표의 alias 를 쓴다 |
| `panes[].effort` | 아님 | CLI 별 지원 범위가 다르다. claude: `low \| medium \| high \| xhigh \| max`, codex: `low \| medium \| high \| xhigh` (`max` 미지원, `-c model_reasoning_effort=` 로 전달), gemini: 미지원 |
| `panes[].role` | 아님 | pane 탭 이름에 붙는 역할 문구 |
| `panes[].prompt_file` | 예 | `mktemp -d` 로 세션별 디렉터리에 쓰기. `/tmp/crew.paneN.txt` 같은 고정 경로는 금지 |
| `panes[].stage` | 아님 | 기본 `1`. 같은 stage 병렬, 작은 번호 먼저 |
| `panes[].share_from` | 아님 | 숫자(같은 run pane-N) 또는 `"prev:N"`, `"prev-K:N"` (이전 run 의 pane-N) |

### 최소 예제

```bash
TMP=$(mktemp -d -t crew.XXXXXX)
cat > "$TMP/pane-1.txt" <<'EOF'
Python 3.13 의 주요 새 기능을 한 줄로 요약해줘.
EOF

cat > "$TMP/plan.json" <<EOF
{
  "panes": [
    { "id": 1, "cli": "claude", "model": "sonnet", "effort": "high",
      "role": "요약", "prompt_file": "$TMP/pane-1.txt" }
  ]
}
EOF

# 설치된 crew 중 가장 최신 버전의 run.sh 를 선택
RUN=$(ls -dt ~/.claude/plugins/cache/crew/crew/*/skills/crew/scripts/run.sh | head -1)
bash "$RUN" "$TMP/plan.json"
```

### Staged + share_from 예제

stage 1 에서 3 개 pane 이 각자 다른 관점으로 탐색, stage 2 에서 이를 합쳐 최종 계획을 만든다.

```bash
TMP=$(mktemp -d -t crew.XXXXXX)
cat > "$TMP/pane-1.txt" <<'EOF'
AI 코드 리뷰 봇 MVP 의 요구사항·이해관계자·성공 지표를 한국어로 정리하라.
EOF
cat > "$TMP/pane-2.txt" <<'EOF'
AI 코드 리뷰 봇 MVP 의 시스템 아키텍처 옵션 3 가지를 비교하라.
EOF
cat > "$TMP/pane-3.txt" <<'EOF'
AI 코드 리뷰 봇 MVP 의 보안·운영 리스크 상위 10 개를 리스트업하라.
EOF
cat > "$TMP/pane-4.txt" <<'EOF'
pane-1, pane-2, pane-3 의 결과를 종합해 12 주 Week-by-Week 로드맵을 작성하라.
EOF

cat > "$TMP/plan.json" <<EOF
{
  "panes": [
    { "id": 1, "cli": "claude", "model": "opus", "effort": "high",
      "role": "요구사항", "prompt_file": "$TMP/pane-1.txt", "stage": 1 },
    { "id": 2, "cli": "gemini", "model": "gemini-2.5-pro",
      "role": "아키텍처", "prompt_file": "$TMP/pane-2.txt", "stage": 1 },
    { "id": 3, "cli": "codex", "model": "gpt-5.5", "effort": "high",
      "role": "리스크", "prompt_file": "$TMP/pane-3.txt", "stage": 1 },
    { "id": 4, "cli": "claude", "model": "opus", "effort": "high",
      "role": "로드맵 합성", "prompt_file": "$TMP/pane-4.txt",
      "stage": 2, "share_from": [1, 2, 3] }
  ]
}
EOF
```

stage 2 의 pane 은 `share_from` 에 명시된 상위 pane 의 slot 을 프롬프트 앞에 자동 주입한 뒤 본 프롬프트를 실행한다.

## 같은 workspace 에서 연속 호출

같은 cmux workspace 의 모든 run 은 `~/.crew/state/ws-<id>/` 아래 누적되며 `latest` 심링크가 최신 run 을 가리킨다. 다음 호출의 plan 에서 이전 run 의 pane 결과를 그대로 참조할 수 있다.

```json
{ "share_from": ["prev:3"] }     // latest run 의 pane-3
{ "share_from": ["prev-2:1"] }   // 2 번째 전 run 의 pane-1
```

cleanup 이후 state 가 사라져도 `latest` 는 artifact 경로로 자동 재바인딩된다. `share_from` 에서 `prev:N` 은 항상 유효.

다른 workspace 는 격리된다.

## Staged 실행 전략

staged 는 언제 쓰나:

- **단일 pane 으로 감당 안 되는 긴 작업** — 탐색을 3 pane 으로 병렬화 후 합성 pane 으로 통합.
- **다른 관점의 교차 검증** — 같은 질문을 claude/codex/gemini 에 던져 차이를 합성.
- **단계적 정제** — 초안 → 비평 → 수정.

팁:

- stage 마다 pane 수를 줄이면 시간·비용 모두 절약된다 (예: stage 1 × 3 → stage 2 × 1).
- 합성 pane 은 보통 `opus / high` 로 두면 품질이 안정적이다.
- `share_from` 참조 pane 은 반드시 작은 stage 번호여야 한다 (DAG 검증됨).

## 티어 선택 가이드

| 작업 성격 | 추천 티어 | 이유 |
|---|---|---|
| 단순 조회, 한 줄 답변 | fast | 비용·속도 최우선 |
| 일반 코드 작성·버그 수정 | standard | 품질·비용 균형 |
| 아키텍처 결정·멀티 파일 리팩터링 | deep | 기본 권장. 복잡한 추론 감당 |
| 보안 리뷰·크리티컬 마이그레이션 | frontier | 최상 품질. 비용 2~4× |

frontier 티어의 Gemini 는 `gemini-3.1-pro-preview` 가 1 차. 접근 실패 시 `gemini-2.5-pro` 로 자동 폴백한다.

CLI 별 특성:

- **claude**: agentic coding, multi-file edit, tool use 에 강함
- **codex**: backend correctness, systems reasoning 에 강함
- **gemini**: 2M context ingestion, UX·docs 대안 탐색에 강함

## 저장 위치와 환경변수

```
~/.crew/
├── state/
│   └── ws-<workspace_id_prefix>/
│       ├── latest → <run_id>       # cleanup 후 artifact 로 rebind
│       └── <run_id>/
│           ├── manifest.json
│           ├── prompts/pane-N.txt   # run.sh 가 원본 prompt 를 스냅샷
│           ├── slots/pane-N.md      # pane 응답 캡처
│           └── crew.log
└── artifacts/
    └── <workspace_slug>/
        └── <slug>/
            ├── index.md
            ├── manifest.json
            ├── pane-N.md            # 보존 슬롯
            └── synthesis.md         # 메인 Claude 가 작성
```

| 환경변수 | 기본값 | 효과 |
|---|---|---|
| `CREW_STATE_DIR` | `$HOME/.crew/state` | 세션 state 디렉터리 override |
| `CREW_ARTIFACT_DIR` | `$HOME/.crew/artifacts` | artifact 디렉터리 override |
| `CREW_VIEW_SECS` | `10` | 모든 stage 완료 후 cleanup 전 전체 지연(초). pane 당 값이 아니라 run 종료 시 한 번만 적용 |
| `CREW_WHISPER_MAIN` | `0` | `1` 이면 crew 로그를 메인 pane 에 속삭인다 |
| `CREW_POLL_INTERVAL` | `0.5` | idle/ready 감지 폴링 간격(초) |

`~/.crew/state/overrides.yaml` 도 영향을 준다. `/crew-setup` 이 이 파일에 `cli_available` 과 `preference` 를 기록하며, crew 는 라우팅 시 이 값을 **하드 제약**으로 본다.

## 수동 실행 레퍼런스

### `run.sh`

```bash
run.sh <plan-json-path-or-dash> [idle_secs] [max_secs] [view_secs] [--keep]
```

| 인자 | 기본 | 설명 |
|---|---|---|
| plan-json | 필수 | 파일 경로 또는 `-` (stdin) |
| `idle_secs` | 5 | pane 해시 안정으로 idle 판정하는 시간 |
| `max_secs` | 300 | pane 당 최대 대기 (초과 시 timeout) |
| `view_secs` | 10 | stage 전체 완료 후 cleanup 전 대기 |
| `--keep` | 꺼짐 | 지정 시 cleanup 하지 않음 (디버깅·연쇄 호출) |

### `cleanup.sh`

```bash
cleanup.sh <slug>     # 특정 세션 정리
cleanup.sh all        # 모든 세션 정리
cleanup.sh orphan     # manifest 를 잃은 고아 pane 만 정리
```

스크립트 실제 경로: `$CLAUDE_PLUGIN_ROOT/skills/crew/scripts/` (보통 `~/.claude/plugins/cache/crew/crew/<version>/skills/crew/scripts/`).

## FAQ

**Q. 병렬 pane 이 많을수록 빠른가?**
아니다. 4 개 이상이면 cmux 와 각 CLI 의 MCP 초기화가 경쟁해 오히려 실패 확률이 오른다. 3 개 이하를 권장.

**Q. claude pane 이 답변 도중 잘린다.**
`idle_secs` 를 늘려 보라 (`run.sh plan.json 30`). 긴 thinking 중 spinner 가 멈춘 프레임을 idle 로 오판하는 경우가 있다. 0.4.6 이후로는 busy-pattern 가드가 이를 막지만 분 단위 생각이 길면 여전히 안전마진이 필요하다.

**Q. gemini 가 "API key not valid" 로 실패한다.**
`~/.gemini/settings.json` 의 `selectedType` 이 `gemini-api-key` 로 박혀 있으면 OAuth 가 저장되지 않는다. `/crew-setup` 을 돌리거나, 수동으로 `oauth-personal` 로 바꾼 뒤 `gemini` → `/auth` → Google 로그인.

**Q. artifact 는 언제 지워지나?**
crew 가 자동 삭제하지 않는다. 수동으로 `rm -rf ~/.crew/artifacts/ws-*/<old-slug>/` 가능.

**Q. `share_from` 에 숫자와 `prev:N` 을 섞을 수 있나?**
가능. 예: `"share_from": [1, "prev:2"]` 는 같은 run 의 pane-1 과 직전 run 의 pane-2 를 모두 주입한다.

**Q. plan.slug 를 고정하면 같은 디렉터리를 재사용할 수 있나?**
아니다. 같은 slug 가 이미 존재하면 crew 가 자동으로 접미사를 붙여 격리한다. 이어가기는 `share_from` 의 `prev:N` 을 사용.

**Q. `/crew` 를 호출했는데 crew 가 실행되지 않고 Claude 가 직접 답한다.**
원인 후보:
1. `/crew-setup` 미완료 — `~/.crew/state/overrides.yaml` 이 없으면 라우팅 불가. `/crew-setup` 실행.
2. 프롬프트가 너무 짧거나 단순 — 메인 Claude 가 crew 없이 답할 수 있다고 판단. "crew 로 나눠줘" 를 명시하거나 `/crew <프롬프트>` 형태로 호출.
3. cmux 바깥 환경 — `CMUX_WORKSPACE_ID` 가 없으면 pane 을 띄울 수 없다.

**Q. pane 이 멈춰서 답이 안 오면?**
1. 해당 CLI 를 터미널에서 단독 실행 (`! claude`, `! codex`, `! gemini`) 하고 MCP 경고나 로그인 오류가 없는지 확인.
2. 이상 없으면 `/crew-cleanup` 으로 잔여 pane 정리 후 재시도.
3. 같은 증상이 반복되면 `~/.crew/state/ws-*/<run_id>/crew.log` 의 마지막 라인을 확인해 어느 단계에서 멈췄는지 파악한다.
