# Changelog

이 프로젝트의 모든 주요 변경은 이 파일에 기록됩니다.

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 형식을 따르며, 이 프로젝트는
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) 을 준수합니다.





## [0.4.5] - 2026-05-06

### Added
- setup 이 cli_available 을 기록하고 crew 라우팅의 하드 제약으로 사용

## [0.4.4] - 2026-05-06

### Fixed
- launch 시작 시 dangling latest 자동 복구

## [0.4.3] - 2026-05-06

### Fixed
- cleanup 이 latest 심링크를 artifact 로 재바인딩해 이어가기 보존

## [0.4.2] - 2026-05-06

### Added
- /crew-cleanup 슬래시 커맨드 추가

### Fixed
- release.sh 의 awk 개행 전달 버그 수정

### Other
- 0.4.x 기준으로 README 재작성
- Unreleased 섹션 제거 및 release.sh 를 커밋 기반 자동 생성으로 전환
- CHANGELOG 도입 및 release.sh 자동화 스크립트 추가

## [0.4.1] - 2026-05-06

### Fixed
- artifact 경로를 절대경로 `~/.crew/artifacts/` 로 고정. 이전엔 상대경로라 run.sh 호출
  cwd 에 따라 결과 위치가 달라졌다. `CREW_ARTIFACT_DIR` env 로 override 가능.

## [0.4.0] - 2026-05-06

### Added
- workspace 네임스페이스 도입. 모든 run 이 `~/.crew/state/ws-<workspace_id_prefix>/<run_id>/`
  아래 모이며 `latest` 심링크가 최신 run 을 가리킴.
- `share_from` 에 `prev:N` / `prev-K:N` 표기 지원. 이전 run 의 pane slot 을 현재 pane
  프롬프트 앞에 자동 주입.
- SKILL.md 에 "같은 workspace 연속 호출 (이어가기)" 섹션 추가.

### Changed
- 같은 workspace 에서 crew 호출 간 결과 이어받기 가능. 다른 workspace 는 서로 격리.
- `cleanup.sh all` 이 `ws-xxx/run-yyy` 구조와 과거 평면 구조 모두 재귀로 정리.

## [0.3.3] - 2026-05-05

### Fixed
- 동시 세션 간 state/prompt 덮어쓰기 방지. 두 Claude Code 세션이 같은 `/tmp/crew.paneN.txt`
  경로를 쓰거나 같은 slug 를 고정 지정해도 서로 격리되도록 수정.

### Changed
- 기본 slug 에 `$RANDOM` 접미사 추가 (`timestamp-PID-RANDOM`).
- run.sh 가 launch 직후 모든 `prompt_file` 을 세션 디렉터리로 스냅샷 복사하고 manifest 를
  해당 경로로 rewrite.
- SKILL.md Plan JSON 예시를 `mktemp -d` 기반으로 전환, 고정 경로 금지 명시.

## [0.3.2] - 2026-05-05

### Fixed
- busy spinner 감지로 조기 idle false-positive 차단. 응답 생성 중인 스피너 라인을 각 CLI
  별로 인식해 완료 전 캡처 방지.
- wait_idle.sh 의 claude `(10s · thinking)`, codex `Working Ns · esc to interrupt`,
  gemini `Thinking... (esc to cancel` 패턴을 busy 로 분류.

### Changed
- gemini done 패턴을 `✦ + Type your message` 로 원복 (busy 감지가 spinner 는 이제 커버).
- IDLE_SECS 기본값 3 → 5 (해시 안정 판정이 너무 공격적이었던 것 보정).

## [0.3.1] - 2026-05-05

### Added
- `common.sh` 에 `crew_wait_ready()` helper. 0.5s 폴링으로 CLI prompt-ready 마커 감지,
  gemini trust dialog 자동 dismiss.
- run.sh 에 `pane_worker()` 함수로 per-pane 흐름을 분리해 백그라운드 실행.

### Changed
- ready-polled per-pane dispatch. 이전엔 launch.sh 가 `sleep 4 + 직렬 wait_for_ready`
  로 가장 느린 pane 에 전체가 블로킹됐다. 이제 각 pane 이 독립적으로 ready → share →
  dispatch → idle → capture → rename 을 수행해 빠른 CLI 부터 즉시 프롬프트 발사.

## [0.3.0] - 2026-05-05

### Added
- pane 생성 후 `cmux rename-tab` 으로 `crew#N · cli:model — role` 라벨 주입.
- report pane 도 `crew · report (slug)` 로 명명. 완료 시 `crew#N ✓ cli:model — role`
  (timeout 은 `⏱`) 로 업데이트.
- SKILL.md 에 "각 pane 응답 완료 후 동작" 섹션(6단계 자동 동작) 추가.

### Changed
- codex 부팅 시 `--dangerously-bypass-approvals-and-sandbox` 공식 flag 사용.
  (사용자 config 의 `approval_policy=never` 의존 제거.)
- 폴링 주기 2s → 0.5s (`CREW_POLL_INTERVAL` 로 override 가능), 기본 `IDLE_SECS` 8 → 3,
  cli_done grace sleep 1s → 0.3s.
- gemini done 패턴을 `Type your message + footer(? for shortcuts|YOLO)` 조합으로 완화.

## [0.2.1] - 2026-05-05

### Changed
- 버전 bump. 0.2.0 과 동일 버전으론 Claude Code 가 플러그인 캐시를 재다운로드하지 않아
  0.2.0 의 `hooks` 필드 중복 에러가 계속 뜨던 문제 해결을 위한 강제 갱신.

## [0.2.0] - 2026-05-04

### Added
- 초기 crew 스킬 구현. cmux pane 기반 가시 서브에이전트, 메인 Claude 가 프롬프트 특성에
  따라 LLM(Claude/Codex/Gemini)·티어·effort 를 라우팅 결정.
- `scripts/`: `launch.sh` (pane 부팅), `dispatch.sh` (TUI 프롬프트 주입), `wait_idle.sh`
  (idle 감지), `capture.sh` (slot 저장), `slot.sh` (pane 간 공유), `cleanup.sh`,
  `collect.sh`, `run.sh` (end-to-end orchestrator).
- `config/models.yaml`: 2026-05 기준 모델 티어 매트릭스 (ChatGPT 계정 Codex 포함).
- `tests/unit/*.bats`: bats 단위 테스트 36 건 (syntax, layout, common helpers, plan 검증).
- staged 실행 + `share_from` 으로 pane 간 데이터 자동 전달.
- viewport+scrollback 결합 해시 + CLI-specific 완료 패턴으로 idle 감지.
- dispatch fingerprint 검증 + 재전송으로 프롬프트 유실 자동 복구.
- report pane (`tail -f crew.log`) 로 진행 상황 실시간 가시화.
- 중단 시 자동 cleanup, PID-scoped tmp 파일로 동시 실행 지원.
- `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` 으로 Claude Code
  plugin 규격 지원. `/plugin marketplace add stomx/crew → /plugin install crew@crew` 설치.
- hooks: `/crew`, `/crew-setup` 단축 slash 라우팅 (`UserPromptSubmit` 훅 + 자연어 트리거).

### Fixed
- hook 출력에 `hookEventName` 필드 추가 (Claude Code 공식 hook 스펙 준수).
- `plugin.json` 의 `hooks` 필드 제거 (자동 로드 경로와 중복 에러 회피).

[0.4.1]: https://github.com/stomx/crew/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/stomx/crew/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/stomx/crew/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/stomx/crew/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/stomx/crew/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/stomx/crew/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/stomx/crew/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/stomx/crew/releases/tag/v0.2.0
[0.4.2]: https://github.com/stomx/crew/compare/v0.4.1...v0.4.2
[0.4.3]: https://github.com/stomx/crew/compare/v0.4.2...v0.4.3
[0.4.4]: https://github.com/stomx/crew/compare/v0.4.3...v0.4.4
[0.4.5]: https://github.com/stomx/crew/compare/v0.4.4...v0.4.5
