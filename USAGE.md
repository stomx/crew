# crew 사용 가이드

기본 사용은 [README.md](./README.md) 참고. 이 문서는 Plan JSON 직접 작성, 이어가기, 모드별 상세, 환경변수 튜닝을 다룸.

## 목차

- [동작 흐름](#동작-흐름)
- [Plan JSON](#plan-json)
- [모드별 동작](#모드별-동작)
- [같은 workspace 에서 연속 호출](#같은-workspace-에서-연속-호출)
- [Staged 실행 전략](#staged-실행-전략)
- [티어 선택 가이드](#티어-선택-가이드)
- [저장 위치와 환경변수](#저장-위치와-환경변수)
- [수동 실행 레퍼런스](#수동-실행-레퍼런스)
- [FAQ](#faq)

## 동작 흐름

```
라우팅 → Launch → Worker → Collect → 합성 → Cleanup
```

| 단계 | 설명 |
|---|---|
| 라우팅 | 프롬프트 분석 → CLI·모델·티어·effort 결정 |
| Launch | pane 부팅 (자동 승인 모드), 탭 이름 `crew#N · cli:model — role` |
| Worker | ready 감지 → dispatch → busy-aware idle 감지 → slot 저장 → 탭 `✓` |
| Collect | 모든 slot 을 artifact 디렉터리로 수집 |
| 합성 | 메인 Claude 가 artifact 를 읽고 최종 보고 |
| Cleanup | `view_secs` 후 pane 정리, `latest` 심링크를 artifact 로 rebind |

인라인 모드에서는 Launch/Worker 대신 subprocess 직접 호출 (`claude -p`, `codex exec`, `gemini -p`).

## Plan JSON

메인 Claude 가 자동 생성하는 plan 을 직접 작성하면 pane 수·모델·stage 명시 제어 가능.

### 스키마

```jsonc
{
  "slug": "optional",
  "panes": [
    {
      "id": 1,
      "cli": "claude",
      "model": "opus",
      "effort": "high",
      "role": "문서 초안",
      "prompt_file": "/tmp/xxx/p1.txt",
      "stage": 1,
      "share_from": [1, "prev:2"]
    }
  ]
}
```

### 필드 레퍼런스

| 필드 | 필수 | 설명 |
|---|---|---|
| `slug` | 아님 | 생략 시 `ws-<workspace>/<timestamp>-<pid>-<rand>` 자동 부여 |
| `panes[].id` | 예 | 1 부터 시작. `share_from` 참조용 |
| `panes[].cli` | 예 | `claude` \| `codex` \| `gemini` |
| `panes[].model` | 아님 | 생략 시 CLI 기본값. 티어 매트릭스의 alias 사용 |
| `panes[].effort` | 아님 | claude: `low`~`max`, codex: `low`~`xhigh`, gemini: 미지원 |
| `panes[].role` | 아님 | pane 탭 라벨 |
| `panes[].prompt_file` | 예 | 절대경로. `mktemp -d` 기반 세션별 디렉터리 권장. 고정 경로 금지 |
| `panes[].stage` | 아님 | 기본 `1`. 같은 stage 병렬, 작은 번호부터 순차 |
| `panes[].share_from` | 아님 | 숫자 (같은 run pane-N) 또는 `"prev:N"` / `"prev-K:N"` (이전 run) |

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

RUN=$(ls -dt ~/.claude/plugins/cache/crew/crew/*/skills/crew/scripts/run.sh | head -1)
bash "$RUN" "$TMP/plan.json"
```

### Staged + share_from 예제

stage 1 에서 3 pane 병렬 탐색, stage 2 에서 합성.

```bash
TMP=$(mktemp -d -t crew.XXXXXX)
cat > "$TMP/pane-1.txt" <<'EOF'
AI 코드 리뷰 봇 MVP 의 요구사항·이해관계자·성공 지표를 정리하라.
EOF
cat > "$TMP/pane-2.txt" <<'EOF'
AI 코드 리뷰 봇 MVP 의 시스템 아키텍처 옵션 3 가지를 비교하라.
EOF
cat > "$TMP/pane-3.txt" <<'EOF'
AI 코드 리뷰 봇 MVP 의 보안·운영 리스크 상위 10 개를 리스트업하라.
EOF
cat > "$TMP/pane-4.txt" <<'EOF'
pane-1, pane-2, pane-3 의 결과를 종합해 12 주 로드맵을 작성하라.
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

stage 2 pane 은 `share_from` 에 명시된 상위 pane slot 을 프롬프트 앞에 자동 주입 후 본 프롬프트 실행.

## 멀티플렉서 설정

### cmux 설정

1. [cmux.com](https://cmux.com) 에서 DMG 다운로드 후 설치
2. cmux 앱 실행 → workspace 생성
3. workspace 내 터미널에서 Claude Code 실행

확인: `echo $CMUX_WORKSPACE_ID` — 값이 출력되면 정상.

### tmux 설정

```bash
# 설치
brew install tmux        # macOS
# 또는
sudo apt install tmux    # Ubuntu/Debian

# 세션 생성 + 진입
tmux new-session -s work

# 이미 세션이 있으면
tmux attach -t work
```

확인: `echo $TMUX` — 경로가 출력되면 정상.

tmux 안에서 Claude Code 를 실행하면 crew 가 자동으로 tmux 모드로 동작.

> cmux 와 tmux 모두 설치된 경우 cmux 가 우선. tmux 만 쓰려면 cmux workspace 바깥에서 실행.

## 모드별 동작

### cmux 모드

- 감지: `CMUX_WORKSPACE_ID` 환경변수 존재
- `cmux new-split` → pane 생성, `cmux read-screen` → 화면 캡처
- 실시간 시각화 + 탭 이름 부여 + report pane (`tail -f crew.log`)
- macOS 전용

### tmux 모드

- 감지: `TMUX` 환경변수 존재, `CMUX_WORKSPACE_ID` 없음
- `tmux split-window` → pane 생성, `tmux capture-pane -p` → 화면 캡처
- cmux 와 동일한 흐름. pane ID 가 `%N` 형태
- macOS / Linux

### 인라인 모드

- 감지: cmux/tmux 모두 없음
- pane 생성 없이 CLI 의 비대화형 모드를 subprocess 로 직접 호출:
  - `claude -p - --model X --effort Y`
  - `codex exec - -m X -c model_reasoning_effort=Y`
  - `gemini -p - -m X`
- staged 실행 + `share_from` 동일 지원
- stderr 분리 (에러 시 `[stderr]` 프리픽스로 slot 에 포함)
- gemini 출력 JSON 에서 `.response` 필드 자동 추출
- 시각화 없음. 진행 관찰 불가

## 같은 workspace 에서 연속 호출

같은 멀티플렉서 세션의 모든 run 이 `~/.crew/state/ws-<id>/` 아래 누적. `latest` 심링크가 최신 run 을 가리킴.

```json
{ "share_from": ["prev:3"] }     // latest run 의 pane-3
{ "share_from": ["prev-2:1"] }   // 2 번째 전 run 의 pane-1
```

cleanup 후 state 삭제되어도 `latest` 는 artifact 경로로 자동 재바인딩. `prev:N` 항상 유효.

다른 workspace 는 격리됨.

## Staged 실행 전략

적합한 경우:

- 단일 pane 으로 부족한 대규모 작업 → 병렬 탐색 후 합성
- 교차 검증 → 같은 질문을 서로 다른 CLI 에 던져 차이 분석
- 단계적 정제 → 초안 → 비평 → 수정

규칙:

- stage 마다 pane 수를 줄이면 시간·비용 절감 (예: stage 1 × 3 → stage 2 × 1)
- 합성 pane 은 `opus / high` 가 안정적
- `share_from` 참조 대상은 반드시 작은 stage 번호 (DAG 검증됨)
- 4 pane 이상은 초기화 경쟁으로 실패율 증가. 3 이하 권장

## 티어 선택 가이드

| 작업 성격 | 추천 티어 | 이유 |
|---|---|---|
| 단순 조회, 한 줄 답변 | fast | 비용·속도 최우선 |
| 일반 코드 작성·버그 수정 | standard | 품질·비용 균형 |
| 아키텍처 결정·멀티 파일 리팩터링 | deep | 기본 권장. 복잡한 추론 감당 |
| 보안 리뷰·크리티컬 마이그레이션 | frontier | 최상 품질. 비용 2~4× |

CLI 별 강점:

- **claude** — agentic coding, multi-file edit, tool use
- **codex** — backend correctness, systems reasoning
- **gemini** — 2M context ingestion, UX·docs 대안 탐색

frontier Gemini: `gemini-3.1-pro-preview` 우선, 접근 실패 시 `gemini-2.5-pro` 폴백.

## 저장 위치와 환경변수

```
~/.crew/
├── state/
│   └── ws-<workspace_id_prefix>/
│       ├── latest → <run_id>       # cleanup 후 artifact 로 rebind
│       └── <run_id>/
│           ├── manifest.json
│           ├── prompts/pane-N.txt
│           ├── slots/pane-N.md
│           └── crew.log
└── artifacts/
    └── <workspace_slug>/
        └── <slug>/
            ├── index.md
            ├── manifest.json
            ├── pane-N.md
            └── synthesis.md
```

| 환경변수 | 기본값 | 효과 |
|---|---|---|
| `CREW_STATE_DIR` | `$HOME/.crew/state` | 세션 state 디렉터리 override |
| `CREW_ARTIFACT_DIR` | `$HOME/.crew/artifacts` | artifact 디렉터리 override |
| `CREW_VIEW_SECS` | `10` | 전체 stage 완료 후 cleanup 전 대기(초) |
| `CREW_WHISPER_MAIN` | `0` | `1` 이면 crew 로그를 메인 pane 에 whisper |
| `CREW_POLL_INTERVAL` | `0.5` | idle/ready 감지 폴링 간격(초) |

`~/.crew/state/overrides.yaml` — `/crew-setup` 이 `cli_available` 과 `preference` 를 기록. crew 라우팅의 **하드 제약**.

## 수동 실행 레퍼런스

### run.sh

```bash
run.sh <plan-json-path-or-dash> [idle_secs] [max_secs] [view_secs] [--keep]
```

| 인자 | 기본 | 설명 |
|---|---|---|
| plan-json | 필수 | 파일 경로 또는 `-` (stdin) |
| idle_secs | 5 | 해시 안정으로 idle 판정하는 시간 |
| max_secs | 300 | pane 당 최대 대기 (초과 시 timeout) |
| view_secs | 10 | 완료 후 cleanup 전 대기 |
| `--keep` | 꺼짐 | cleanup 하지 않음 (디버깅용) |

멀티플렉서 미감지 시 자동으로 `inline-run.sh` 로 위임.

### cleanup.sh

```bash
cleanup.sh <slug>     # 특정 세션 정리
cleanup.sh all        # 모든 세션 정리
cleanup.sh orphan     # manifest 잃은 고아 pane 만 정리
```

스크립트 경로: `~/.claude/plugins/cache/crew/crew/<version>/skills/crew/scripts/`

## FAQ

**Q. `/crew` 호출 시 crew 미실행, Claude 가 직접 답함**
원인:
1. `/crew-setup` 미완료 — `~/.crew/state/overrides.yaml` 없으면 라우팅 불가
2. 프롬프트가 너무 짧거나 단순 — `crew 로 나눠줘` 명시 또는 `/crew <프롬프트>` 사용
3. `CMUX_WORKSPACE_ID` / `TMUX` 없음 + 인라인 라우팅 조건 미충족

**Q. pane 답변 도중 잘림**
`idle_secs` 증가 필요 (`run.sh plan.json 30`). 0.4.6+ 에서 busy-pattern 가드가 대부분 방지하나, 분 단위 thinking 시 안전마진 필요.

**Q. Gemini "API key not valid"**
`~/.gemini/settings.json` 의 `selectedType` 이 `gemini-api-key` 인 경우. `/crew-setup` 재실행 또는 수동으로 `oauth-personal` 전환 후 `gemini` → `/auth`.

**Q. artifact 삭제 시점**
crew 가 자동 삭제하지 않음. `rm -rf ~/.crew/artifacts/ws-*/<old-slug>/` 로 수동 정리.

**Q. `share_from` 에 숫자와 `prev:N` 혼합 가능 여부**
가능. 예: `"share_from": [1, "prev:2"]` — 같은 run 의 pane-1 + 직전 run 의 pane-2 모두 주입.

**Q. 병렬 pane 이 많을수록 빠른가**
아님. 4 이상이면 MCP 초기화 경쟁으로 실패율 증가. 3 이하 권장.

**Q. pane 멈춤 (답 없음)**
1. 해당 CLI 단독 실행 (`! claude`, `! codex`, `! gemini`) 하여 인증·MCP 오류 확인
2. `/crew-cleanup` 으로 잔여 pane 정리 후 재시도
3. `~/.crew/state/ws-*/<run_id>/crew.log` 마지막 라인 확인
