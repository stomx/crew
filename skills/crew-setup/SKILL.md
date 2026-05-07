---
name: crew-setup
description: crew plugin 의 초기 온보딩. API key 를 받거나 저장하지 않고, 설치된 CLI(claude/codex/gemini) 의 네이티브 로그인 상태만 검증한 뒤 주력 모델·티어·view_secs·whisper 기본값을 확정하여 ~/.crew/state/ 에 기록한다. 트리거 — "/crew-setup", "/crew:crew-setup", "crew 초기 설정", "crew setup".
---

# crew — 초기 설정 (Setup)

crew plugin 을 처음 쓰거나 CLI 환경이 바뀌었을 때 한 번 실행. 키를 받지 않고, 각 CLI 의 네이티브 인증 상태만 검증한다.

## 절차 개괄

```
진입 → Step 1: Silent Health Check (3 CLI)
         ├─ 전부 pass → "✓ claude / ✓ codex / ✓ gemini" + Step 3 진행
         └─ 일부 fail/missing → Step 2: 개별 처리
                                  2-A. 설치 안내 (missing 만)
                                  2-B. 인증 방식 선택 (OAuth vs API Key)
                                  2-C. 연결 어시스트 (단계별 가이드)
                                  2-D. 재검증 (pass → 다음, fail → 재시도/건너뛰기)
       → Step 3: Preference 질문 (4개)
       → Step 4: 저장 (정합성 검사 포함)
```

## Step 1 — Silent Health Check

**반드시 아래 bash 블록을 정확히 그대로 `Bash` 툴로 실행해야 한다. 임의의 감지 루틴(예: `command -v ...; echo ...`) 으로 대체하지 말 것.** 이 블록은 `oauth_creds.json` / `GEMINI_API_KEY` 같은 **실제 credential 유무** 까지 검증한다. `selectedType` 만 보는 간이 감지는 오판을 만든다.

실행 후 출력에서 `CREW_HEALTH_CLAUDE=`, `CREW_HEALTH_CODEX=`, `CREW_HEALTH_GEMINI=` 세 줄만 파싱. 값은 `pass` / `fail` / `missing` 중 하나.

```bash
mkdir -p ~/.crew/state

declare -A RESULT

# --- claude (cmux 번들이므로 바이너리 존재만 확인) ---
if command -v claude >/dev/null 2>&1; then
  RESULT[claude]="pass"
else
  RESULT[claude]="missing"
fi

# --- codex ("Logged in" 또는 OPENAI_API_KEY 존재) ---
CODEX_OUT=""
if command -v codex >/dev/null 2>&1; then
  CODEX_OUT=$(codex login status 2>&1 || true)
  if echo "$CODEX_OUT" | grep -qi "Logged in"; then
    RESULT[codex]="pass"
  elif [ -n "${OPENAI_API_KEY:-}" ]; then
    RESULT[codex]="pass"
    CODEX_OUT="API key"
  else
    RESULT[codex]="fail"
  fi
else
  RESULT[codex]="missing"
fi

# --- gemini (settings.json auth 확인) ---
if command -v gemini >/dev/null 2>&1; then
  AUTH_TYPE=""
  if [ -r ~/.gemini/settings.json ]; then
    AUTH_TYPE=$(jq -r '(.security.auth.selectedType // .selectedType // "none")' ~/.gemini/settings.json 2>/dev/null || echo "none")
  fi
  # oauth_creds.json 위치: ~/.gemini/ 또는 ~/.config/gemini/
  OAUTH_CREDS=""
  for p in ~/.gemini/oauth_creds.json ~/.config/gemini/oauth_creds.json; do
    [ -r "$p" ] && OAUTH_CREDS="$p" && break
  done
  case "$AUTH_TYPE" in
    oauth-personal)
      if [ -n "$OAUTH_CREDS" ]; then
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
| codex | `codex login status` 에 "Logged in" 포함 **또는** `$OPENAI_API_KEY` 가 비어있지 않음 |
| gemini | `selectedType=oauth-personal` → `oauth_creds.json` 존재, `gemini-api-key` → `$GEMINI_API_KEY` 비어있지 않음 |

전부 pass 시 한 줄 요약만 출력하고 Step 3 으로 바로 진행:
```
✓ claude / ✓ codex / ✓ gemini — 모두 정상
```

## Step 2 — 실패 CLI 개별 처리

`fail` 또는 `missing` 인 CLI 에 대해 순서대로 처리한다.

> Claude CLI 는 cmux 번들이므로 재연동 대상이 아님. `command -v claude` 실패 시에만 "crew 는 cmux 환경이 필요합니다" 안내 후 종료.

### 2-A. 설치 여부 확인

**missing 인 경우**: 설치 안내를 먼저 표시한 뒤 AskUserQuestion:

| CLI | 설치 명령 |
|-----|-----------|
| codex | `npm i -g @openai/codex` |
| gemini | `npm i -g @google/gemini-cli` |

> (a) 지금 설치하겠습니다 — 터미널에서 위 명령을 실행하세요 (`! npm i -g ...`)
> (b) 건너뛰기 — 이 CLI 없이 진행

**(a) 선택 후 "완료" (또는 `!` 명령 출력 확인)** → Step 1 의 해당 CLI 검증만 재실행:
- `pass` → "✓ {cli} 설치+인증 완료" 출력, **다음 CLI 로 이동** (2-B 건너뜀)
- `fail` (설치됐으나 인증 안 됨) → **2-B 로 진행**
- `missing` (설치 실패) → 재안내

**(b) 선택** → 해당 CLI 를 `cli_available` 에서 제외, 다음 CLI 로 넘어감.

### 2-B. 인증 방식 선택

`fail` (바이너리는 있으나 인증 안 됨) 인 CLI 에 대해 인증 방식을 묻는다.

**codex 의 경우** — AskUserQuestion:
> codex 인증이 확인되지 않습니다. 어떤 방식으로 로그인하시겠습니까?
> (a) ChatGPT 계정 (OAuth) — 브라우저 로그인. 대부분의 사용자에게 권장
> (b) API Key — OpenAI Platform API 키 사용 (`OPENAI_API_KEY` 환경변수)
> (c) 건너뛰기 — codex 없이 진행

**gemini 의 경우** — AskUserQuestion:
> gemini 인증이 확인되지 않습니다. 어떤 방식으로 연결하시겠습니까?
> (a) Google OAuth (개인 계정) — 브라우저 인증. 권장
> (b) API Key — Google AI Studio 에서 발급한 키 사용 (`GEMINI_API_KEY` 환경변수)
> (c) 건너뛰기 — gemini 없이 진행

### 2-C. 연결 어시스트

사용자가 (a) 또는 (b) 를 선택하면 해당 방식에 맞는 단계별 가이드를 제시하고, 사용자가 완료를 알릴 때까지 대기한다. 가이드 마지막에 항상 다음 안내를 포함:
> 완료되면 "완료", 막히면 "건너뛰기" 또는 "다른 방식"이라고 알려주세요.

**codex — OAuth (a)**:
```
1. 아래 명령을 실행하세요:
   ! codex login
2. 브라우저가 열리면 ChatGPT 계정으로 로그인
3. "Logged in" 메시지가 나오면 "완료" 라고 알려주세요
```

**codex — API Key (b)**:
```
1. OpenAI Platform (platform.openai.com) 에서 API key 를 발급하세요
2. 아래 명령으로 환경변수를 설정하세요:
   ! export OPENAI_API_KEY="sk-..."
3. 영구 저장하려면 ~/.zshrc 또는 ~/.bashrc 에도 추가하세요
4. "완료" 라고 알려주세요
```

**gemini — OAuth (a)**:
```
1. 아래 명령을 실행하세요:
   ! gemini
2. gemini CLI 가 뜨면 /auth 를 입력
3. 브라우저에서 Google 계정 인증 완료
4. ~/.gemini/oauth_creds.json 파일이 생성되면 성공
5. gemini CLI 를 /exit 로 종료한 뒤 "완료" 라고 알려주세요
```

**gemini — API Key (b)**:
```
1. Google AI Studio (aistudio.google.com) 에서 API key 를 발급하세요
2. 아래 명령으로 환경변수를 설정하세요:
   ! export GEMINI_API_KEY="AI..."
3. ~/.gemini/settings.json 에서 selectedType 을 확인/수정:
   jq '.security.auth.selectedType = "gemini-api-key"' ~/.gemini/settings.json > /tmp/g.json && mv /tmp/g.json ~/.gemini/settings.json
4. 영구 저장하려면 ~/.zshrc 또는 ~/.bashrc 에도 export 추가
5. "완료" 라고 알려주세요
```

### 2-D. 재검증

사용자가 "완료" 를 알리면, Step 1 의 **해당 CLI health check bash 만** 다시 실행:

- **pass** → "✓ {cli} 연결 완료" 출력, 다음 실패 CLI 로 이동 (또는 모두 처리 완료 시 Step 3 진행)
- **fail** → 원인 힌트 출력 후 재시도 여부 확인:
  > 여전히 인증이 확인되지 않습니다. ({구체적 원인: 파일 미존재 / env 미설정 등})
  > (a) 다시 시도 — 2-C 의 핵심 명령만 요약 재표시 후 재검증
  > (b) 다른 인증 방식으로 변경 → 2-B 로 복귀
  > (c) 건너뛰기

모든 실패 CLI 처리가 끝나면 Step 3 으로 진행한다.

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

**Preference-Available 정합성 검사**: 사용자가 질문 1 에서 **(d) 세 개 고루** 를 선택했으나 Step 1–2 결과로 `cli_available` 에서 빠진 CLI 가 있다면, **해당 CLI 의 health check 만 한 번 더 실행**하여 재검증한다. 재검증에서 `pass` 되면 `cli_available` 에 포함, `fail` 이면 사용자에게 "X 인증이 여전히 안 됩니다. 제외하시겠습니까?" 로 확인.

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
- **timeout 미사용**: macOS 에 `timeout` (coreutils) 이 없는 환경이 흔하므로 로컬 파일 읽기만으로 검증. `codex login status` 는 네트워크 호출 없이 즉시 반환.
- **재실행 허용**: 환경이 바뀌면 `/crew-setup` 을 다시 돌려 `.setup-done` 과 `overrides.yaml` 을 덮어쓴다.
- **plugin 디렉토리 미수정**: plugin 은 git-managed. 사용자별 상태는 `~/.crew/state/` 로 격리.
