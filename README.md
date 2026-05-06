# crew

cmux pane 기반 가시 서브에이전트 Claude Code plugin.

메인 Claude 가 프롬프트를 분석해 LLM(Claude / Codex / Gemini)과 티어·effort 를 자동 라우팅하고, cmux workspace 에 pane 을 띄워 각 CLI 를 bypass 모드로 병렬 실행한 뒤 결과를 합성합니다. 사용자는 진행 상황을 workspace 안에서 실시간으로 볼 수 있습니다.

## 왜 있는가

- 단일 Claude 세션에서 여러 LLM 을 동시에 활용 — 각 모델의 장점을 프롬프트 특성에 맞춰 배분
- pane 단위 실시간 가시성 — 서브에이전트가 무엇을 하고 있는지 언제든 확인
- 이전 run 결과를 다음 run 에 주입하는 이어가기(continuation) 지원

## 요구사항

- macOS + [cmux](https://cmux.app) 앱
- `CMUX_WORKSPACE_ID` 가 설정된 cmux surface 안에서 Claude Code 실행
- 하나 이상의 CLI:
  - [Claude Code](https://docs.claude.com/code)
  - [Codex](https://www.npmjs.com/package/@openai/codex): `npm i -g @openai/codex`
  - [Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli): `npm i -g @google/gemini-cli`
- 보조 도구: `bash`, `jq`, `perl`, `shasum`

## 설치

```
/plugin marketplace add stomx/crew
/plugin install crew@crew
/crew-setup
```

`/crew-setup` 은 CLI 감지, 로그인 상태 확인, 주력 모델·티어·view_secs 기본값을 대화형으로 확정합니다.

## 사용

```
/crew
```

Claude 가 현재 프롬프트 컨텍스트를 보고 pane 구성을 스스로 결정합니다. 자연어("crew 로 나눠줘", "crew 써줘")도 라우팅됩니다.

## 동작 흐름

1. **라우팅** — 프롬프트 분석 → CLI·모델·티어·effort 결정
2. **Launch** — per-pane bypass 부팅, 탭 이름을 `crew#N · cli:model — role` 로 설정
3. **Worker** — ready 감지 → dispatch → busy-aware idle 감지 → slot 저장 → 탭에 `✓` 표시
4. **Collect** — 각 pane 결과 수집
5. **합성** — 메인 Claude 가 결과 통합 보고
6. **Cleanup** — `view_secs` 후 pane 자동 정리

## 티어 매트릭스

| CLI | fast | standard | deep | frontier |
|---|---|---|---|---|
| Claude | haiku / low | sonnet / high | opus / high | opus / max |
| Codex | gpt-5.4 / low | gpt-5.5 / medium | gpt-5.5 / high | gpt-5.5 / xhigh |
| Gemini | 2.5-flash-lite | 2.5-flash | 2.5-pro | 3.1-pro-preview |

Codex 는 ChatGPT 계정 기준이며 gpt-5.5 / gpt-5.4 만 허용됩니다. 전체 설정은 `skills/crew/config/models.yaml` 참고.

## 저장 위치와 이어가기

| 대상 | 경로 |
|---|---|
| 세션 state | `~/.crew/state/ws-<workspace_id_prefix>/<run_id>/` |
| 아티팩트 | `~/.crew/artifacts/<slug>/` (`CREW_ARTIFACT_DIR` 로 override 가능) |

같은 cmux workspace 에서 연속 호출하면 `latest` 심링크가 최신 run 을 가리킵니다. plan JSON 에서 이전 run 결과를 주입할 수 있습니다:

```json
{ "share_from": ["prev:2"] }
{ "share_from": ["prev-1:3"] }
```

`prev:N` 은 직전 run 의 pane N, `prev-K:N` 은 K 번째 이전 run 의 pane N 입니다. 다른 workspace 끼리는 격리됩니다.

## 트러블슈팅

| 증상 | 대응 |
|---|---|
| `CMUX_WORKSPACE_ID not set` | cmux surface 안에서 Claude Code 를 실행하세요 |
| Gemini trust modal 이 멈춤 | 자동 dismiss 실패 시 수동으로 한 번 수락 후 재시도 |
| 잔여 pane 정리 | `/crew-cleanup` 실행 (`/crew:cleanup` 도 동일) |

## 개발

```bash
git clone https://github.com/stomx/crew.git
cd crew
./tests/run-tests.sh
```

릴리스 자동화:

```bash
scripts/release.sh 0.5.0
```

plugin.json bump + CHANGELOG.md 생성 + git tag + push + GitHub Release 를 한 번에 수행합니다. 버전은 semver 를 따릅니다.

## 링크

- 저장소: https://github.com/stomx/crew
- 내부 동작 상세: `skills/crew/SKILL.md`
- 변경 이력: `CHANGELOG.md` / [GitHub Releases](https://github.com/stomx/crew/releases)

## 라이선스

MIT
