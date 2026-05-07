# crew

Claude/Codex/Gemini 를 한 명령으로 병렬 실행하고 결과를 자동 합성하는 Claude Code 플러그인.

> 탭 3개 열고 복붙하는 대신 → `/crew <프롬프트>` 한 줄. 모델 선택·실행·수거 자동.

## 설치

```
/plugin marketplace add stomx/crew
/plugin install crew@crew
/crew-setup
```

`/crew-setup` 은 첫 사용 전 필수. CLI 인증 상태를 검증하고 `cli_available` 을 결정함. 미완료 시 라우팅 불가.

## 첫 실행

```
/crew 이 저장소의 README 와 USAGE 를 각각 한 줄씩 요약해줘
```

메인 Claude 가 pane 수·모델을 자동 결정해 실행, 완료 후 합성 보고. `crew 로 나눠줘` 같은 자연어 트리거도 동일.

## 특징

| 항목 | 설명 |
|---|---|
| 자동 라우팅 | 프롬프트 특성 분석 → CLI·모델·티어·effort 자동 결정 |
| 가시 실행 | cmux/tmux pane 에서 진행 실시간 관찰·개입 가능 |
| staged 실행 | 병렬 탐색 → 합성 등 DAG 기반 다단계 파이프라인 |
| share_from | pane 간·run 간 결과 자동 전달. 수동 복붙 제거 |
| 인라인 폴백 | 멀티플렉서 없이도 subprocess 로 동작 |

## 지원 환경

| 모드 | 감지 조건 | 동작 |
|---|---|---|
| cmux | `CMUX_WORKSPACE_ID` 존재 | 탭 분리, 실시간 시각화 |
| tmux | `TMUX` 존재 | pane 분리, capture-pane 기반 |
| inline | 둘 다 없음 | CLI 비대화형 호출 (`-p` / `exec`) |

## 요구사항

- macOS 또는 Linux
- 멀티플렉서 (택 1, 또는 없이 인라인):
  - [cmux](https://cmux.com) — macOS 전용. DMG 설치, CLI 번들 포함
  - [tmux](https://github.com/tmux/tmux) — `brew install tmux` / `apt install tmux`
- 보조 도구: `bash`, `jq`, `perl`, `shasum`
- (선택) `coreutils` — `timeout` 명령 안정화. `brew install coreutils`
- 최소 하나의 CLI:
  - [Claude Code](https://docs.claude.com/code) 2.1+
  - [Codex](https://www.npmjs.com/package/@openai/codex) 0.125+ — `npm i -g @openai/codex`
  - [Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli) 0.40+ — `npm i -g @google/gemini-cli`

## 티어 매트릭스

| 티어 | Claude | Codex | Gemini |
|---|---|---|---|
| fast | haiku / low | gpt-5.4 / low | gemini-2.5-flash-lite |
| standard | sonnet / high | gpt-5.5 / medium | gemini-2.5-flash |
| deep | opus / high | gpt-5.5 / high | gemini-2.5-pro |
| frontier | opus / max | gpt-5.5 / xhigh | gemini-3.1-pro-preview |

기본 티어: deep. 선택 기준은 [USAGE.md — 티어 선택 가이드](./USAGE.md#티어-선택-가이드) 참고.

## 트러블슈팅

**로그 확인**: `~/.crew/state/ws-*/<run_id>/crew.log` — 실패 시 마지막 몇 줄이 단서.

**pane 시각화 없이 실행됨**: cmux/tmux 미감지 시 인라인 모드로 자동 전환. pane 관찰이 필요하면 멀티플렉서 안에서 실행.

**잔여 pane 정리**: `/crew-cleanup` 실행.

**`/crew` 호출 시 crew 미실행**: (1) `/crew-setup` 미완료 (2) 프롬프트가 너무 단순 (3) 멀티플렉서 바깥 + inline 미지원 CLI 조합.

**Gemini "API key not valid"**: `~/.gemini/settings.json` 의 `selectedType` → `oauth-personal` 전환 필요. `/crew-setup` 재실행.

## 참고

- [USAGE.md](./USAGE.md) — Plan JSON·이어가기·환경변수·모드별 상세·FAQ
- [CHANGELOG.md](./CHANGELOG.md) — 버전별 변경 이력

## 라이선스

MIT
