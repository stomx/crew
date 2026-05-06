---
name: crew-setup
description: crew plugin 의 초기 온보딩. 설치된 CLI(claude/codex/gemini) 와 cmux 를 감지하고 로그인 상태를 확인, 주력 모델·티어·view_secs 같은 기본값을 사용자와 대화형으로 확정한 뒤 ~/.crew/state/.setup-done 플래그와 ~/.crew/state/overrides.yaml(cli_available 포함) 을 남긴다. cli_available 은 crew 라우팅의 하드 제약. 트리거 — "/crew-setup", "/crew:crew-setup", "crew 초기 설정", "crew setup".
---

# crew — 초기 설정 (Setup)

이 스킬은 처음 `crew` plugin 을 설치한 사용자가 한 번 돌리면 됩니다. Claude 가 아래 절차를 순차적으로 수행하면서 필요한 지점에서 사용자에게 질문을 던지고 답을 받아 설정을 확정합니다.

## 절차

### 1. 환경 감지 (진단만, 수정 없음)

다음을 **한번에 병렬 Bash** 로 확인:

```bash
echo "=== cmux workspace ==="
echo "CMUX_WORKSPACE_ID=${CMUX_WORKSPACE_ID:-(not set)}"
command -v cmux && cmux --version || echo "cmux: MISSING"

echo "=== CLI tools ==="
for cli in claude codex gemini; do
  if command -v "$cli" >/dev/null; then
    echo "$cli: $(command -v $cli)"
  else
    echo "$cli: MISSING"
  fi
done

echo "=== CLI 로그인 상태 ==="
# claude
test -r ~/.claude/.credentials.json && echo "claude: credentials.json 있음" || echo "claude: credentials 없음 (claude /auth 필요할 수 있음)"
# codex
codex login status 2>&1 | head -2
# gemini (auth 섹션 확인)
test -r ~/.gemini/settings.json && jq -r '.security.auth.selectedType // "unknown"' ~/.gemini/settings.json 2>/dev/null | sed 's/^/gemini auth: /' || echo "gemini: settings.json 없음"

echo "=== 보조 도구 ==="
for t in jq perl shasum; do
  command -v "$t" >/dev/null && echo "$t: ok" || echo "$t: MISSING"
done
```

### 2. 결과 해석 + 사용자 안내

출력을 보고 각 항목을 판정:

- **cmux 없음 / CMUX_WORKSPACE_ID 없음** → 치명적. "cmux 를 설치하고 cmux surface 안에서 Claude Code 를 띄운 뒤 다시 실행하세요" 안내 후 종료
- **claude/codex/gemini 모두 없음** → crew 를 못 씀. 최소 하나는 필요. 설치 방법 안내:
  - claude: https://docs.claude.com/code
  - codex: `npm i -g @openai/codex`
  - gemini: `npm i -g @google/gemini-cli`
- **일부만 있음** → 동작은 가능하지만 해당 CLI 를 요구하는 plan 은 skip. 사용자에게 "설치된 것만 쓸 건지, 나머지도 설치할 건지" 질문
- **codex: Logged in using ChatGPT** → `config/models.yaml` 의 codex 티어를 `gpt-5.5`/`gpt-5.4` 로 유지 (API 전용 모델 사용 불가). 이 결과를 사용자에게 알림
- **codex: API key** → API 전용 모델(`gpt-5-mini`, `gpt-5-pro` 등)도 허용. 질문: "더 가벼운/무거운 모델 허용되는데 활성화할까요?"
- **gemini: oauth-personal** → 개인 계정 OAuth. 정상
- **로그인 없는 CLI** → 사용자에게 수동 로그인 요청:
  - `! claude` 실행해 로그인 마법사 진입
  - `! codex login` 로 OAuth/API key 선택
  - `! gemini /auth` 로 계정 선택

### 3. 사용자 선호 확정 (대화형 질문)

**질문 1 — 주력 모델 조합**:
> 어떤 CLI 를 주력으로 쓰시겠습니까?
> (a) Claude 위주 (에이전틱 코딩)
> (b) Codex 위주 (백엔드 추론)
> (c) Gemini 위주 (큰 context)
> (d) 세 개 고루 (권장, 기본)

**질문 2 — 기본 티어**:
> 기본 작업에 어느 수준의 모델을 쓰시겠습니까?
> (1) fast (비용 우선, haiku/gpt-5.4/flash-lite)
> (2) standard (균형)
> (3) deep (성능 우선, 기본값)
> (4) frontier (최상, opus+max / gpt-5.5+xhigh / 3.1-pro)

**질문 3 — pane 체류 시간**:
> pane 이 응답 후 자동 닫히기 전 몇 초 보여줄까요? (0 = 즉시 닫음, 기본 10)

**질문 4 — 알림 스타일**:
> crew 진행 상황을 메인 Claude 창에도 띄울까요? (whisper — 기본 off, 권장 off)

### 4. 설정 저장

답변과 감지 결과를 `$HOME/.crew/state/` 아래 두 파일로 기록:

**(a) `~/.crew/state/.setup-done`** — 마커 + YAML 로 선택값 저장 (session-start hook 이 이 파일을 보고 재안내 여부 결정):

```yaml
setup_at: <ISO8601>
setup_version: 1
cli_preference: <a|b|c|d>
default_tier: <fast|standard|deep|frontier>
default_view_secs: <int>
whisper_main: <true|false>
detected:
  claude: <installed|missing>
  codex: <installed-chatgpt|installed-apikey|missing>
  gemini: <installed|missing>
  cmux: <ok|missing>
```

**(b) 선택값 + 감지된 CLI 목록을 `$HOME/.crew/state/overrides.yaml` 에 저장**

```yaml
# ~/.crew/state/overrides.yaml
cli_available: [claude, codex, gemini]   # 실제 설치·로그인 확인된 것만
preference:
  default_tier: <사용자 선택>
run_defaults:
  view_secs: <int>
  whisper_main: <bool>
```

`cli_available` 는 **crew 라우팅의 하드 제약**. crew:crew SKILL.md 가 plan 을 짤 때 이 목록에 있는 CLI 만 pane.cli 로 쓴다. 파일이 없거나 `cli_available` 키가 없으면 **claude 만 있다고 간주**한다 (안전 기본값).

감지 규칙:
- **claude**: `command -v claude` 성공 + `claude --version` 정상 출력 → 포함
- **codex**: `command -v codex` 성공 + `codex login status` 가 "Logged in" 포함 → 포함
- **gemini**: `command -v gemini` 성공 + `~/.gemini/settings.json` 의 auth 설정 존재 → 포함

사용자가 "세 개 고루 쓰겠다" 고 해도 실제 로그인 안 된 CLI 는 **제외**한다. 로그인 안내 후 `/crew-setup` 재실행을 권장.

### 5. 마무리

사용자에게 한 줄 요약:

```
✓ crew setup 완료
  · CLI: claude ✓  codex (ChatGPT) ✓  gemini ✓
  · default tier: deep
  · view_secs: 10
  · 이제 /crew 로 써보세요.
```

## 설계 노트

- **이 스킬은 로그인 명령을 직접 실행하지 않음**. 사용자가 `! codex login` 같이 본인 터미널에서 실행하도록 안내만 함. 이유: OAuth 리다이렉트·토큰 저장 등이 사용자 개입 없이 안전하게 자동화되지 않음.
- **plugin 디렉토리 자체를 수정하지 않음**. plugin 은 git-managed 이므로 사용자별 override 는 `state/overrides.yaml` 로 격리.
- **재실행 허용**. 사용자가 환경 바뀌면 `/crew-setup` 을 다시 돌려 `.setup-done` 을 덮어씀.
