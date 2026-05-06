---
name: crew-cleanup
description: crew 가 띄웠던 잔여 pane 과 끊어진 세션 디렉터리를 정리하는 스킬. 정상 종료되지 않은 run 이후 workspace 에 crew 자식 pane 이 남아있거나, `~/.crew/state/ws-*/run-*/` 이 고아 상태일 때 호출한다. 트리거 — "/crew-cleanup", "/crew:crew-cleanup", "crew 정리", "잔여 pane 정리".
---

# crew — cleanup

crew 는 정상 종료 시 자식 pane 과 세션 디렉터리를 스스로 치우지만, 중간에 강제 중단되거나 cmux RPC 가 잠시 어긋났던 경우 잔여 pane 이 남을 수 있다. 이 스킬은 그 상태를 정리한다.

## 실행

모든 살아있는 crew 세션의 자식 pane 을 닫고 state 디렉터리를 삭제:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/crew/scripts/cleanup.sh" all
```

특정 slug 만:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/crew/scripts/cleanup.sh" <slug>
```

manifest 를 잃어 추적 못 하는 pane 만 훑어 닫기(제스처성 청소):

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/crew/scripts/cleanup.sh" orphan
```

## 유의사항

- 메인 caller pane(이 대화가 열린 pane)은 절대 닫지 않는다.
- 아티팩트(`~/.crew/artifacts/<slug>/`)는 유지된다 — 기록 용도.
- 삭제 전 어떤 세션이 정리될지 먼저 `ls ~/.crew/state/ws-*/` 로 훑어보고 싶으면 `all` 전에 사용자에게 확인을 받아도 된다.
