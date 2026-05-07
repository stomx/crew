# crew

cmux workspace 안에 여러 LLM pane 을 띄워 병렬 실행하고 결과를 합성해 보고하는 Claude Code 플러그인.

## 왜 있는가

- 메인 Claude 가 프롬프트 특성에 맞춰 Claude / Codex / Gemini 와 티어·effort 를 자동 라우팅한다.
- 각 pane 은 cmux workspace 안에서 직접 보이므로 진행을 실시간 관찰·개입할 수 있다.
- staged 실행과 `share_from` 으로 pane 간 결과를 다음 단계에 이어 넘길 수 있다.

## 요구사항

- 터미널 멀티플렉서 (택 1, 또는 없이 인라인):
  - [cmux](https://cmux.app) (macOS, 권장) — DMG 설치. `cmux` CLI 번들 포함. cmux workspace surface 안에서 Claude Code 를 실행해야 한다.
  - [tmux](https://github.com/tmux/tmux) — `brew install tmux` / `apt install tmux`. tmux 세션 안에서 Claude Code 를 실행해야 한다.
  - **인라인 폴백** — 멀티플렉서 없이도 동작. 각 CLI 의 비대화형 모드(`claude -p`, `codex exec`, `gemini -p`)를 subprocess 로 호출한다. pane 시각화는 없지만 staged 실행과 `share_from` 은 동일하게 지원.
- 보조 도구: `bash`, `jq`, `perl`, `shasum`
- (선택) `coreutils` — `/crew-setup` 의 `timeout` 명령을 안정화한다. `brew install coreutils`
- 최소 하나 이상의 CLI:
  - [Claude Code](https://docs.claude.com/code) 2.1+
  - [Codex](https://www.npmjs.com/package/@openai/codex) 0.125+ — `npm i -g @openai/codex`
  - [Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli) 0.40+ — `npm i -g @google/gemini-cli`

## 설치

```
/plugin marketplace add stomx/crew
/plugin install crew@crew
/crew-setup
```

`/crew-setup` 은 첫 `/crew` 사용 전에 반드시 완료해야 한다. 이 과정에서 사용 가능한 CLI 목록(`cli_available`)이 결정되며, setup 을 건너뛰면 crew 가 라우팅할 CLI 를 알 수 없어 실행되지 않는다.

인식되지 않으면 `/reload-plugins` 를 한 번 실행한 후 재시도한다. setup 은 각 CLI 의 네이티브 로그인 상태를 확인하고, 실패한 CLI 만 재연동을 안내한다. API key 를 묻거나 저장하지 않는다.

## Hello World

```
/crew 이 저장소의 README 와 USAGE 를 각각 한 줄씩 요약해줘
```

메인 Claude 가 pane 수·모델을 스스로 결정해 실행하고, 완료 후 결과를 합성해 보고한다. 자연어 트리거(`crew 로 나눠줘`, `crew 로 돌려줘`) 도 동일하게 작동하지만, 첫 사용 시에는 `/crew <프롬프트>` 명시 호출이 가장 확실하다. 짧거나 단순한 질문은 메인 Claude 가 crew 를 거치지 않고 직접 답할 수 있다.

pane 구성이나 모델을 직접 지정하고 싶으면 [USAGE.md — Plan JSON](./USAGE.md#plan-json) 참고.

## 동작 흐름

1. 라우팅 — 프롬프트 분석 후 CLI·모델·티어·effort 결정
2. Launch — 각 pane 을 bypass 모드(자동 승인)로 부팅, 탭 이름을 `crew#N · cli:model — role` 로 지정
3. Worker — ready 감지 → dispatch → busy-aware idle 감지 → slot 저장 → 탭에 `✓`
4. Collect — 모든 pane slot 을 artifact 로 모음
5. 합성 — 메인 Claude 가 artifact 를 읽고 최종 보고
6. Cleanup — `view_secs` 후 자식 pane 정리, `latest` 심링크는 artifact 로 재바인딩

## 티어 매트릭스

| 티어 | Claude | Codex | Gemini |
|---|---|---|---|
| fast | haiku / low | gpt-5.4 / low | gemini-2.5-flash-lite |
| standard | sonnet / high | gpt-5.5 / medium | gemini-2.5-flash |
| deep | opus / high | gpt-5.5 / high | gemini-2.5-pro |
| frontier | opus / max | gpt-5.5 / xhigh | gemini-3.1-pro-preview |

ChatGPT 계정 Codex 는 `gpt-5.5` / `gpt-5.4` 만 허용. 티어 선택 기준은 [USAGE.md](./USAGE.md#티어-선택-가이드) 참고.

## 저장 위치

- 세션 state: `~/.crew/state/ws-<workspace_id_prefix>/<run_id>/` (cleanup 시 `latest` 를 artifact 로 rebind 후 삭제)
- 아티팩트: `~/.crew/artifacts/<workspace_slug>/<slug>/` (보존)

환경변수 override 및 상세 구조는 [USAGE.md](./USAGE.md#저장-위치와-환경변수) 참고.

## 트러블슈팅

**먼저 로그부터**: `~/.crew/state/ws-*/<run_id>/crew.log` 에 각 run 의 stage 진행이 기록된다. 실패 시 가장 마지막 몇 줄이 원인 단서다.

**pane 시각화 없이 실행됨**
cmux/tmux 가 감지되지 않으면 자동으로 인라인 모드(subprocess)로 폴백한다. pane 을 직접 보며 개입하고 싶다면 cmux 또는 tmux 안에서 실행.

**잔여 pane 정리**
`/crew-cleanup` 실행. 세부 옵션은 [USAGE.md](./USAGE.md#수동-실행-레퍼런스) 참고.

**Gemini API key not valid 에러**
`~/.gemini/settings.json` 의 `selectedType` 이 `gemini-api-key` 로 박혀 있는 경우 OAuth 가 저장되지 않는다. `/crew-setup` 을 다시 돌려 설정을 `oauth-personal` 로 전환하거나, `gemini` 실행 후 `/auth` 로 재로그인.

**Gemini `trust this folder` modal 이 뜬 채 멈춤**
`launch.sh` 가 자동 수락을 시도하지만 드물게 실패한다. 해당 pane 에서 수동 Enter 한 번.

## 다음 단계

- [USAGE.md](./USAGE.md) — plan JSON·이어가기·환경변수·FAQ
- [CHANGELOG.md](./CHANGELOG.md) — 버전별 변경 이력
- [skills/crew/SKILL.md](./skills/crew/SKILL.md) — 메인 Claude 의 라우팅 지침 (AI 실행용)

## 라이선스

MIT
