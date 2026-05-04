#!/usr/bin/env bash
# crew common helpers (cmux-native, inspired by ccg-panel)
#
# crew 는 cmux workspace 안에 N 개의 interactive CLI pane 을 띄워서
# 메인 Claude 가 라우팅 결정을 기반으로 각 pane 에 다른 모델/티어를 배정하고
# 완료 후 결과를 합성해 보고하는 스킬.

set -u

# State (per-session manifest/slots) defaults under the user's home.
# Override with CREW_STATE_DIR if you want it elsewhere.
CREW_STATE_DIR="${CREW_STATE_DIR:-$HOME/.crew/state}"
CREW_ARTIFACT_DIR="${CREW_ARTIFACT_DIR:-.omc/artifacts/crew}"

crew_require_cmux() {
  if ! command -v cmux >/dev/null 2>&1; then
    echo "error: cmux CLI not found on PATH" >&2
    echo "  hint: install cmux (macOS: cmux.app), or add its bin dir to PATH." >&2
    return 2
  fi
  if [[ -z "${CMUX_WORKSPACE_ID:-}" ]]; then
    echo "error: CMUX_WORKSPACE_ID not set" >&2
    echo "  hint: run this from inside a cmux workspace pane. Opening Claude Code" >&2
    echo "  in a regular terminal will not work — cmux must be the outer shell." >&2
    return 3
  fi
}

crew_have() {
  command -v "$1" >/dev/null 2>&1
}

crew_timestamp() {
  date +%Y%m%d-%H%M%S
}

# Parse "surface:NN" out of a cmux response line.
crew_parse_surface() {
  awk '/surface:[0-9]+/ { for (i=1; i<=NF; i++) if ($i ~ /^surface:/) { print $i; exit } }'
}

# Session dir lives under state/<slug>/
crew_session_dir() {
  local slug="$1"
  echo "${CREW_STATE_DIR}/${slug}"
}

crew_slot_path() {
  local slug="$1" pane_idx="$2"
  echo "$(crew_session_dir "$slug")/slots/pane-${pane_idx}.md"
}

crew_manifest_path() {
  local slug="$1"
  echo "$(crew_session_dir "$slug")/manifest.json"
}

crew_synthesis_path() {
  local slug="$1"
  echo "${CREW_ARTIFACT_DIR}/${slug}/synthesis.md"
}

crew_log_path() {
  local slug="$1"
  echo "$(crew_session_dir "$slug")/crew.log"
}
