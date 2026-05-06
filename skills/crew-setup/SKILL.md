---
name: crew-setup
description: crew plugin 의 초기 온보딩. API key 를 받거나 저장하지 않고, 설치된 CLI(claude/codex/gemini) 의 네이티브 로그인 상태만 검증한 뒤 주력 모델·티어·view_secs·whisper 기본값을 확정하여 ~/.crew/state/ 에 기록한다. 트리거 — "/crew-setup", "/crew:crew-setup", "crew 초기 설정", "crew setup".
---

# crew — 초기 설정 (Setup)

crew plugin 을 처음 쓰거나 CLI 환경이 바뀌었을 때 한 번 실행. 키를 받지 않고, 각 CLI 의 네이티브 인증 상태만 검증한다.

## 절차 개괄

```
진입 → Silent Health Check (3 CLI 병렬, 각 3초 제한)
         ├─ 전부 통과 → "✓ claude / ✓ codex / ✓ gemini" + Step 3 진행
         └─ 일부 실패 → 실패 CLI 만 (a)재연동 안내 / (b)건너뛰기 → Step 3 진행
```

## Step 1 — Silent Health Check

아래 bash 를 `Bash` 툴로 실행한다. 결과를 파싱해 `pass` / `fail` / `missing` 을 판정.

```bash
mkdir -p ~/.crew/state

declare -A RESULT

# --- claude (cmux 번들이므로 바이너리 존재만 확인) ---
if command -v claude >/dev/null 2>&1; then
  RESULT[claude]="pass"
else
  RESULT[claude]="missing"
fi

# --- codex (3초 timeout, "Logged in" 포함 여부) ---
CODEX_OUT=""
if command -v codex >/dev/null 2>&1; then
  CODEX_OUT=$(timeout 3 codex login status 2>&1 || true)
  if echo "$CODEX_OUT" | grep -qi "Logged in"; then
    RESULT[codex]="pass"
  else
    RESULT[codex]="fail"
  fi
else
  RESULT[codex]="missing"
fi

# --- gemini (3초 timeout, settings.json auth 확인) ---
if command -v gemini >/dev/null 2>&1; then
  AUTH_TYPE=""
  if [ -r ~/.gemini/settings.json ]; then
    AUTH_TYPE=$(timeout 3 jq -r '.security.auth.selectedType // "none"' ~/.gemini/settings.json 2>/dev/null || echo "none")
  fi
  case "$AUTH_TYPE" in
    oauth-personal)
      if [ -r ~/.gemini/oauth_creds.json ]; then
        RESULT[gemini]="pass"
      else
        RESULT[gemini]="fail"
      fi
      ;;
    gemini-api-key)
      if [ -n "${GEMINI_API_KEY:-}" ]; then
        RESULT[gemini]="pass"
      else
        RESULT[gemini]="fail"
      fi
      ;;
    *)
      RESULT[gemini]="fail"
      ;;
  esac
else
  RESULT[gemini]="missing"
fi

# --- 결과 출력 (Claude 가 파싱) ---
echo "CREW_HEALTH_CLAUDE=${RESULT[claude]}"
echo "CREW_HEALTH_CODEX=${RESULT[codex]}"
echo "CREW_HEALTH_GEMINI=${RESULT[gemini]}"
echo "CREW_CODEX_RAW=$CODEX_OUT"
echo "CREW_GEMINI_AUTH=${AUTH_TYPE:-none}"
```

**판정 기준 요약**:

| CLI | pass 조건 |
|-----|-----------|
| claude | `command -v claude` 성공 (cmux 번들이라 호스트 세션 인증 공유) |
| codex | `codex login status` 출력에 "Logged in" 포함 |
| gemini | `selectedType=oauth-personal` → `oauth_creds.json` 존재, `gemini-api-key` → `$GEMINI_API_KEY` 비어있지 않음 |

전부 pass 시 한 줄 요약만 출력하고 Step 3 으로 바로 진행:
```
✓ claude / ✓ codex / ✓ gemini — 모두 정상
```

## Step 2 — 실패 CLI 개별 처리

`fail` 또는 `missing` 인 CLI 에 대해서만 AskUserQuestion 으로 아래 2지선다를 제시한다.

**질문 형식** (예: codex 실패 시):
> codex 인증이 확인되지 않습니다.
> (a) 지금 재연동하겠습니다 — 터미널에서 `! codex login` 을 실행하세요
> (b) 건너뛰기 — codex 없이 진행

- **(a) 선택 시**: 사용자가 `! codex login` 을 실행 후 "완료" 라고 답하면, Step 1 의 해당 CLI 검증 bash 만 다시 실행하여 재검증.
- **(b) 선택 시**: 해당 CLI 를 `cli_available` 에서 제외.
- **missing 인 경우**: 설치 안내도 함께 표시 (`npm i -g @openai/codex` / `npm i -g @google/gemini-cli`).

재연동 명령 레퍼런스:

| CLI | 명령 |
|-----|------|
| codex | `! codex login` |
| gemini | `! gemini` 실행 후 `/auth` 입력 |

> Claude CLI 는 cmux 번들이므로 재연동 대상이 아님. `command -v claude` 실패 시에만 "crew 는 cmux 환경이 필요합니다" 안내 후 종료.

## Step 3 — Preference 질문

AskUserQuestion 으로 4개를 한 묶음으로 제시:

**질문 1 — 주력 모델 조합**:
> 어떤 CLI 를 주력으로 쓰시겠습니까?
> (a) Claude 위주 (에이전틱 코딩)
> (b) Codex 위주 (백엔드 추론)
> (c) Gemini 위주 (큰 context)
> (d) 세 개 고루 (권장, 기본)

**질문 2 — 기본 티어**:
> 기본 작업에 어느 수준의 모델을 쓰시겠습니까?
> (1) fast (비용 우선)
> (2) standard (균형)
> (3) deep (성능 우선, 기본값)
> (4) frontier (최상)

**질문 3 — pane 체류 시간**:
> pane 응답 후 자동 닫히기 전 몇 초 보여줄까요? (0=즉시, 기본 10)

**질문 4 — 알림 스타일**:
> crew 진행 상황을 메인 Claude 창에도 whisper 할까요? (y/n, 기본 n)

## Step 4 — 저장

검증 결과와 사용자 답변을 아래 두 파일에 기록한다.

```bash
CLI_AVAILABLE=""  # 쉼표 구분 리스트로 조합 (예: "claude, codex, gemini")

cat > ~/.crew/state/.setup-done << 'YEOF'
setup_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
setup_version: 2
cli_preference: <a|b|c|d>
default_tier: <fast|standard|deep|frontier>
default_view_secs: <int>
whisper_main: <true|false>
detected:
  claude: <installed|missing>
  codex: <oauth|chatgpt|apikey|none|missing>
  gemini: <oauth-personal|gemini-api-key|none|missing>
  cmux: ok
YEOF

cat > ~/.crew/state/overrides.yaml << 'YEOF'
cli_available: [claude, codex, gemini]   # 실제 pass 된 것만
preference:
  cli_primary: <a|b|c|d>
  default_tier: <선택값>
run_defaults:
  view_secs: <int>
  whisper_main: <bool>
YEOF
```

실제 저장 시 `<placeholder>` 를 사용자 답변·검증 결과로 치환하여 실행한다.

`cli_available` 는 **crew 라우팅의 하드 제약**. 이 목록에 없는 CLI 는 pane.cli 에 배정되지 않는다.

**detected 분류 기준**:

| CLI | 값 | 조건 |
|-----|---|------|
| codex | `chatgpt` | "ChatGPT" 키워드 포함 |
| codex | `apikey` | "API key" 키워드 포함 |
| codex | `oauth` | 그 외 "Logged in" |
| codex | `none` | 바이너리 있으나 로그인 안됨 |
| gemini | `oauth-personal` | selectedType 이 oauth-personal + creds 존재 |
| gemini | `gemini-api-key` | selectedType 이 gemini-api-key + env 존재 |
| gemini | `none` | 바이너리 있으나 인증 없음 |

## 설계 노트

- **키 저장 금지**: setup 은 API key 를 절대 받지 않고, 저장하지도 않는다. 각 CLI 의 네이티브 인증 시스템(OAuth, credential file, env var) 에 전적으로 위임하고, crew 는 존재·유효성만 읽는다.
- **Claude CLI 는 항상 skip**: cmux workspace 안에서 실행되므로 호스트 세션의 Anthropic 인증을 그대로 공유한다. 별도 로그인 검증이 불필요.
- **3초 timeout**: CLI 가 네트워크 호출을 하거나 hang 걸릴 때 setup 전체가 블록되지 않도록 보호.
- **재실행 허용**: 환경이 바뀌면 `/crew-setup` 을 다시 돌려 `.setup-done` 과 `overrides.yaml` 을 덮어쓴다.
- **plugin 디렉토리 미수정**: plugin 은 git-managed. 사용자별 상태는 `~/.crew/state/` 로 격리.
