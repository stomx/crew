---
name: crew
description: cmux pane 기반 가시 서브에이전트. 메인 Claude 가 프롬프트 특성 보고 LLM·티어·effort 를 라우팅 결정하고, cmux workspace 에 pane 을 띄워 각 pane 에서 bypass 모드로 CLI(Claude/Codex/Gemini) 를 interactive 실행. 완료되면 결과 합성해 메인에 보고하고 pane 닫음. staged 실행 + pane 간 데이터 공유 지원. pane 배치는 cmux 의 flat 타일링에 맡기므로 정확한 격자는 아님. 트리거 — "crew", "crew 로 나눠줘", "서브패널 위임", "visible delegation", 복잡도가 임계 이상이어서 메인에서 단독 처리 대신 가시 서브 배치가 필요한 작업.
---

# crew — visible multi-pane sub-agent router

메인 Claude 가 복잡한 프롬프트를 받았을 때 **백그라운드 Agent 툴** 대신 **cmux workspace 안의 실제 pane** 에 여러 LLM 을 띄워 가시적으로 병렬 처리하고, 끝나면 합성 후 pane 을 닫는다.

## 왜 있는가

- 기존 Claude Code 의 `Agent` 툴은 서브에이전트가 백그라운드에서 돌아 **사용자가 진행 상황을 볼 수 없음**.
- `crew` 는 pane 에 **bypass 모드** 로 interactive CLI 를 띄우고 `cmux send` 로 프롬프트를 타이핑해서 사용자가 **실시간 관찰·개입 가능**.
- 라우터가 프롬프트 특성에 맞춰 LLM·티어·effort 를 자동 결정 → 작업별 최적 모델 선택.
- 완료되면 메인 패널이 **반드시 취합** (sub pane 끼리는 중간 데이터 공유만 가능, 최종 합성은 메인 독점).

## 사용 조건

- cmux 앱 + `cmux` CLI (`CMUX_WORKSPACE_ID` 세팅된 cmux surface 안)
- `jq`, `perl`, `shasum`
- 필요한 CLI: `claude` 2.1+, `codex` 0.125+, `gemini` 0.40+
- 각 CLI 의 로그인·trust 설정은 이미 완료돼 있다고 가정 (사용자 환경 기준)

## 메인 Claude 실행 프로토콜

### 1. 라우팅 결정 (메인 Claude 가 직접 판단)

프롬프트를 읽고 다음 질문에 답해 pane 구성을 설계한다:

- 작업 성향이 무엇인가? (agentic coding / 백엔드 추론 / 탐색·대안)
- 얼마나 깊게 생각해야 하는가? (사용자 선호: **기본 높은 effort**, deep 부터 시작)
- 병렬 이득이 있는가? (교차검증 / 분업)
- stage 간 의존성이 있는가?

**라우팅 축**:

| LLM | 특화 |
|---|---|
| `claude` | agentic coding, multi-file edit, tool use |
| `codex` | backend correctness, systems reasoning |
| `gemini` | 2M context ingestion, UX/docs/alternatives |

**티어 매트릭스** (2026-05 기준, ChatGPT-로그인 Codex 환경) — `config/models.yaml` 참조, 다음은 요약:

| 티어 | Claude | Codex | Gemini |
|---|---|---|---|
| fast | `haiku` + low | `gpt-5.4` + low | `gemini-2.5-flash-lite` |
| standard | `sonnet` + high | `gpt-5.5` + medium | `gemini-2.5-flash` |
| deep | `opus` + high | `gpt-5.5` + high | `gemini-2.5-pro` |
| frontier | `opus` + max | `gpt-5.5` + xhigh | `gemini-3.1-pro-preview` (폴백: `gemini-2.5-pro`) |

> Codex 는 ChatGPT 계정에서 API 전용 모델(`gpt-5-mini`, `-nano`, `-pro`) 을 허용하지 않음.
> ChatGPT 계정 사용 시 모델은 `gpt-5.5` / `gpt-5.4` 로 고정, 티어 차이는 effort 로 조절.
> API 키 기반 사용자라면 `config/models.yaml` 에서 `gpt-5-mini` 등 복원 가능.

**원칙**: 명백히 가벼운 작업(`simple lookup`, `one-liner`, `format-only`) 만 standard 이하로 내린다. 그 외에는 **deep 이상** 기본.

### 2. Plan JSON 작성

**중요**: 메인 Claude 는 세션마다 `TMP=$(mktemp -d -t crew.XXXXXX)` 로 전용 디렉터리를 만든 뒤 그 안에 `pane-N.txt` 를 쓴다. `/tmp/crew.paneN.txt` 같은 **고정 경로**는 쓰지 말 것 — 같은 프로젝트의 두 Claude Code 세션이 동시에 crew 를 돌리면 서로의 prompt 파일을 덮어쓴다. (run.sh 가 prompt 를 세션 디렉터리로 스냅샷 해주지만, 메인 Claude 가 prompt 파일을 쓰는 순간에는 이미 충돌이 일어날 수 있음.)

```bash
TMP=$(mktemp -d -t crew.XXXXXX)
cat > "$TMP/pane-1.txt" <<'EOF' ... EOF
cat > "$TMP/pane-2.txt" <<'EOF' ... EOF
cat > "$TMP/plan.json" <<EOF
{
  "slug": "$(date +%Y%m%d-%H%M%S)-weather",
  "panes": [
    {
      "id": 1,
      "cli": "claude",
      "model": "opus",
      "effort": "high",
      "role": "pick a topic",
      "prompt_file": "$TMP/pane-1.txt",
      "stage": 1
    },
    {
      "id": 2,
      "cli": "codex",
      "model": "gpt-5.5",
      "effort": "xhigh",
      "role": "use pane-1 topic",
      "prompt_file": "$TMP/pane-2.txt",
      "stage": 2,
      "share_from": [1]
    }
  ]
}
EOF
```

- **`slug`**: 고정값을 쓰면 같은 slug 의 이전 세션 디렉터리를 덮어쓸 위험이 있으니, 접두사 + 타임스탬프로 항상 유일하게 만들 것. 생략하면 launch.sh 가 `YYYYMMDD-HHMMSS-$$-$RANDOM` 으로 자동 부여.
- **`stage`**: 작은 번호부터 순차 실행. 같은 stage 는 병렬. 생략 시 `1`.
- **`prompt_file`**: 프롬프트 본문은 **파일로** 전달 (긴 컨텍스트 안정성). run.sh 는 실행 시 각 prompt 파일을 `~/.crew/state/<slug>/prompts/` 로 스냅샷해 원본 경로 변경이나 삭제에 영향받지 않는다.
- **`share_from`** (선택): 상위 stage pane 의 출력 slot 을 자동으로 이 pane 에 주입한 뒤 본 프롬프트를 실행한다. 예: `"share_from": [1, 3]` 이면 pane-1, pane-3 의 캡처가 순서대로 주입된다.
  - 제약: `share_from` 대상 pane 은 **현재 pane 보다 작은 stage** 여야 함 (검증됨). 자기 자신 금지.
  - 내부적으로 `slot.sh share` 가 자동 호출되고, 이후 pane 이 share 를 처리할 시간을 잠깐 기다린 뒤 본 프롬프트가 dispatch 된다.

### 3. 실행

```bash
~/.claude/skills/crew/scripts/run.sh /path/to/plan.json
```

인자:
1. plan JSON path (또는 `-` 로 stdin)
2. `idle_secs` (기본 8)
3. `max_secs` (기본 300, staged 전체가 아니라 pane 하나당)
4. `--keep` (pane 을 닫지 않음 — follow-up 용)

출력 예시:
```
=== crew run ===
slug=20260504-150301-12345
manifest=/Users/searchdoc/.claude/skills/crew/state/20260504-150301-12345/manifest.json
session_dir=/Users/searchdoc/.claude/skills/crew/state/20260504-150301-12345
pane_1_surface=surface:91
pane_2_surface=surface:92
--- stage 1 ---
ok: sent 412 bytes to pane 1 (surface:91)
pane_1_status=idle
pane_1_slot=/Users/searchdoc/.../slots/pane-1.md
--- stage 2 ---
ok: sent 287 bytes to pane 2 (surface:92)
pane_2_status=idle
pane_2_slot=/Users/searchdoc/.../slots/pane-2.md
artifact_root=/Users/you/.crew/artifacts/ws-ABC12345/20260504-150301-12345
index=/Users/you/.crew/artifacts/ws-ABC12345/20260504-150301-12345/index.md
cleaned=yes
```

### 4. 각 pane 의 응답 완료 후 동작 (자동)

한 pane 이 응답을 마치면 run.sh 가 자동으로 다음을 수행한다:

1. **idle 감지** — `wait_idle.sh` 가 뷰포트+스크롤백 SHA 안정 + CLI-specific done 패턴으로 완료 판정 (기본 IDLE_SECS=3s, POLL=0.5s)
2. **slot 저장** — `capture.sh` 가 pane 화면 전체를 `$state_dir/slots/pane-N.md` 로 저장 (프롬프트 + 응답)
3. **탭 rename** — 해당 pane 의 cmux tab 을 `crew#N ✓ claude:opus — role` 형태로 바꿔 완료 표시 (timeout 은 `⏱`)
4. **share_from 전달** — 다음 stage 에서 이 pane 의 결과를 요구하는 pane 이 있으면 `slot.sh share` 가 자동으로 상위 pane 의 slot 을 하위 pane 의 입력으로 주입
5. **로그 이벤트** — report pane (`tail -f crew.log`) 에 `← pane-N status=idle → slot path` 라인 출력
6. **전체 stage 완료 후** — `collect.sh` 가 모든 slot 을 `~/.crew/artifacts/<slug>/` 로 복사하고 메인 Claude 가 synthesis 작성

> **중요**: pane 끼리 직접 통신하지 않는다. 메인이 다리 역할. 최종 합성도 메인 전담.

### 5. 결과 합성 (메인 Claude 가 반드시 수행)

`$artifact_root/pane-*.md` 의 `## pane capture` 섹션을 읽어 각 LLM 의 답변을 추출하고, **합의점 / 대립점 / 최종 방향 / 액션 체크리스트** 형태로 `$artifact_root/synthesis.md` 를 작성한 뒤 사용자에게 보고한다.

### 6. 히스토리

`~/.crew/artifacts/<slug>/` 는 **그대로 보존** — 작업 히스토리 문서화. `CREW_ARTIFACT_DIR` 환경변수로 override 가능.
세션 state(`~/.claude/skills/crew/state/<slug>/`) 는 cleanup 시 삭제.

## 같은 workspace 에서 연속 호출 (이어가기)

같은 cmux workspace 안에서 `/crew:crew` 를 여러 번 호출하면 모든 run 이
`~/.crew/state/ws-<workspace_id_prefix>/` 아래 모이고, 항상 최신 run 을
가리키는 `latest` 심링크가 함께 갱신된다. 이 덕분에 다음 호출에서 이전
run 의 pane 결과를 그대로 참고할 수 있다:

```json
{
  "share_from": ["prev:3"]        // latest run 의 pane-3 결과를 주입
}
// 또는
{
  "share_from": ["prev-2:1"]      // 2번 전 run 의 pane-1 결과를 주입
}
```

메인 Claude 도 이전 run 결과를 직접 읽어 synthesis 에 포함할 수 있다:

```bash
ls ~/.crew/state/ws-*/latest/slots/
cat ~/.crew/state/ws-*/latest/slots/pane-1.md
```

> 다른 workspace 는 서로 격리된다 (워크스페이스 ID 가 접두사로 들어가므로).

## pane 간 데이터 교환 (staged 모드)

stage 1 → stage 2 사이에 `pane-1` 의 결과를 `pane-2` 에 넘기려면:

```bash
# run.sh 단일 호출로는 stage 경계 hook 이 없으므로,
# 메인이 수동으로 stage 를 쪼개 호출한다.
# 1) stage 1 만 plan 으로 먼저 실행 (--keep)
# 2) slot.sh share <slug> 1 2   ← pane-1 캡처를 pane-2 에 주입
# 3) stage 2 plan 으로 동일 slug 재사용
```

> **중요**: pane 끼리 직접 통신하지 않는다. 메인이 다리 역할. 최종 합성도 메인 전담.

## 레이아웃에 대한 주의

cmux 는 tmux 같은 계층적 split tree 가 아니라 **workspace 단위 flat 타일링**을 쓴다.
`new-split right --surface X` 가 "X 옆에" 정확히 붙지 않고 cmux 렌더러가 workspace
전체 레이아웃을 다시 계산한다. 그래서 **pane 배치는 정확히 계산된 격자가 아니라**
cmux 가 알아서 배열하는 형태가 된다. 모든 pane 은 보이고 기능은 동작하지만
미관은 고르지 않을 수 있다. N 이 커질수록 비례가 더 불균형해진다.

- report pane 은 "caller 아래" 를 의도하지만 실제 위치는 cmux 가 결정
- 각 child pane 의 크기 비례는 보장되지 않음
- 기능상 문제는 없음 (프롬프트/응답/캡처 모두 정상)

## 트러블슈팅

### "CMUX_WORKSPACE_ID not set"
cmux surface 바깥에서 실행한 경우. cmux workspace 안에서 Claude Code 띄운 후 재시도.

### Gemini "trust this folder" modal
`launch.sh` 가 8초간 폴링하며 dialog 감지 즉시 Enter 로 자동 수락.

### Gemini frontier(3.1-pro-preview) 접근 권한 없음
403/404 발생 시 메인이 plan 을 수정해 `gemini-2.5-pro` 로 폴백하고 재실행.

### pane 이 지저분하게 남아있음
`/crew-cleanup` (또는 `/crew:cleanup`) 을 실행한다. 내부적으로
`$CLAUDE_PLUGIN_ROOT/skills/crew/scripts/cleanup.sh all` 을 호출한다.

### Claude pane 에 `--effort` 가 안 먹는 느낌
`claude --help` 로 `--effort` 가 존재하는지 확인 (v2.1+ 필요).

## 파일 구조

```
~/.claude/skills/crew/
├── SKILL.md                     # 이 문서
├── config/
│   └── models.yaml              # 티어 매트릭스 (여기만 업데이트하면 됨)
├── scripts/
│   ├── common.sh                # cmux helper
│   ├── layout.sh                # N → split 시퀀스
│   ├── launch.sh                # pane 생성 + bypass CLI 부팅
│   ├── dispatch.sh              # 완전 분리 — TUI 에 프롬프트 send-keys
│   ├── wait_idle.sh             # hash-idle 폴링
│   ├── capture.sh               # pane → slot md
│   ├── slot.sh                  # pane 간 공유 bridge
│   ├── cleanup.sh               # close-surface
│   ├── collect.sh               # slots → artifact bundle
│   └── run.sh                   # end-to-end 오케스트레이터
└── state/<slug>/                # 세션별 manifest + slots
```

아티팩트: `~/.crew/artifacts/<slug>/` 에 manifest·각 pane 캡처·index·synthesis 가 남아 후일 확인에 사용 가능. cwd 와 무관하게 일정한 위치에 쌓인다 (프로젝트 저장소에 커밋해야 하면 수동 복사 필요).
