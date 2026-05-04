#!/usr/bin/env bash
# Per-session health check for crew plugin. Runs once at SessionStart.
# Only injects an onboarding hint if the user hasn't run /crew-setup yet.
# Fast-exits when everything looks healthy so we don't nag.

set -euo pipefail

STATE_DIR="${CREW_STATE_DIR:-$HOME/.claude/skills/crew/state}"
FLAG="$STATE_DIR/.setup-done"

# Already onboarded? Nothing to say.
[[ -f "$FLAG" ]] && exit 0

# Only hint inside a cmux surface — outside cmux the plugin can't function
# anyway, so there's no point suggesting setup.
[[ -z "${CMUX_WORKSPACE_ID:-}" ]] && exit 0

# Quick dependency probe
missing=()
for cli in cmux claude codex gemini; do
  command -v "$cli" >/dev/null 2>&1 || missing+=("$cli")
done

if (( ${#missing[@]} > 0 )); then
  msg="[crew] 초기 설정이 필요합니다 (missing: ${missing[*]}). 계속하려면: /crew-setup"
else
  msg="[crew] 설치됨. 처음 쓰는 세션이면 /crew-setup 으로 기본 설정을 확정하세요."
fi

if command -v jq >/dev/null 2>&1; then
  jq -cn --arg ctx "$msg" '{hookSpecificOutput: {additionalContext: $ctx}}'
else
  # jq 없으면 알림만 stdout 에 출력 (hook 포맷 없이 무시됨)
  echo "$msg" >&2
fi
