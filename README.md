# crew

**cmux pane 기반 가시 서브에이전트 Claude Code plugin.**

메인 Claude 가 프롬프트 특성에 맞춰 LLM (Claude / Codex / Gemini) 과 티어, effort 를 스스로 라우팅 결정하고, cmux workspace 에 pane 을 띄워 각 CLI 를 bypass 모드로 interactive 실행한 뒤 결과를 합성해 메인에 보고합니다. 사용자는 진행 상황을 workspace 안에서 **실시간으로 볼** 수 있습니다.

## 요구사항

- macOS + cmux 앱 (https://cmux.app)
- cmux CLI — `CMUX_WORKSPACE_ID` 세팅된 cmux surface 안에서 Claude Code 실행
- 최소 하나 이상의 CLI:
  - [Claude Code](https://docs.claude.com/code)
  - [Codex](https://www.npmjs.com/package/@openai/codex): `npm i -g @openai/codex`
  - [Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli): `npm i -g @google/gemini-cli`
- 보조 도구: `bash`, `jq`, `perl`, `shasum`

## 설치

Claude Code 에서:

```
/plugin marketplace add stomx/crew
/plugin install crew@crew
```

이후 한 번만:

```
/crew-setup
```

대화형으로 CLI 감지, 로그인 상태 확인, 주력 모델·티어·view_secs 같은 기본값을 확정합니다.

## 사용

- `/crew` — 메인 기능. Claude 가 현재 프롬프트 컨텍스트를 보고 스스로 pane 구성 결정
- 자연어: "crew 로 나눠줘", "crew 써줘" 같은 표현도 라우팅됨
- `/crew-setup` — 초기 설정 또는 환경 변경 후 재설정

## 삭제

```
/plugin uninstall crew@crew
/plugin marketplace remove crew
```

설정·세션 데이터는 `~/.claude/skills/crew/state/` 아래에 남아있으므로 필요 시 수동 삭제.

## 구조

```
crew/
├── .claude-plugin/plugin.json    # 플러그인 매니페스트
├── hooks/
│   ├── hooks.json                # UserPromptSubmit / SessionStart 훅
│   └── scripts/                  # 단축명 라우터, 세션 health check
├── skills/
│   ├── crew/                     # 메인 스킬 (pane 생성·실행·합성)
│   └── setup/                    # 초기 온보딩
└── tests/                        # bats 단위 테스트 (개발자용)
```

## 개발

```bash
git clone https://github.com/stomx/crew.git
cd crew
./tests/run-tests.sh      # bats 있으면 단위 테스트 실행
```

36 개의 단위 테스트가 layout / common / plan-validation / syntax 를 커버.

자세한 내부 동작은 `skills/crew/SKILL.md` 참고.

## 라이선스

MIT
