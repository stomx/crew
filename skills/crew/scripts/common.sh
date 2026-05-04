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

# Wait until a pane's TUI shows its "prompt-ready" marker. Poll interval
# defaults to 0.5s so dispatch fires the instant a CLI is ready — no fixed
# sleep. Returns 0 on detection, 1 on timeout.
# Usage: crew_wait_ready <surface> <cli> [max_wait=30]
crew_wait_ready() {
  local surface="$1" cli="$2" max_wait="${3:-30}"
  local poll="${CREW_POLL_INTERVAL:-0.5}"
  local pattern
  case "$cli" in
    claude) pattern='bypass permissions on|Claude Code v' ;;
    codex)  pattern='/model to change|OpenAI Codex' ;;
    gemini) pattern='Type your message|@path/to/file' ;;
    *)      return 0 ;;
  esac
  local start=$(date +%s)
  while :; do
    local screen
    screen="$(cmux read-screen --surface "$surface" 2>/dev/null || true)"
    if echo "$screen" | grep -qE "$pattern"; then
      return 0
    fi
    # Gemini trust dialog can appear mid-boot — dismiss on the fly.
    if [[ "$cli" == "gemini" ]] && echo "$screen" | grep -qi "trust the files in this folder"; then
      cmux send-key --surface "$surface" Enter >/dev/null 2>&1 || true
    fi
    if (( $(date +%s) - start >= max_wait )); then
      return 1
    fi
    sleep "$poll"
  done
}
