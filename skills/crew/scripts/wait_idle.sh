#!/usr/bin/env bash
# Usage: wait_idle.sh <surface> [grace_secs] [max_secs] [cli]
#
# Prints "idle" when CLI completion is detected, "timeout" on max_secs.
#
# Detection: CLI-specific "done" pattern only — response prefix AND
# input-prompt-ready marker both visible in viewport, AND no busy spinner.
# Hash-based idle detection was removed: it caused false positives during
# MCP/hook initialization pauses. The done-file in run.sh is the primary
# signal; this script is the secondary (pattern-based) detector.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

crew_require_mux

SURFACE="${1:?surface ref required}"
GRACE_SECS="${2:-20}"  # ignore cli_done for this many seconds after start
MAX_SECS="${3:-300}"
CLI="${4:-}"
POLL_INTERVAL="${CREW_POLL_INTERVAL:-${POLL_INTERVAL:-0.5}}"


cli_busy() {
  local screen="$1"
  case "$CLI" in
    claude)
      echo "$screen" | grep -qE '^[[:space:]]*●[[:space:]][A-Z][a-zA-Z]+(ing|ed)(…|\.\.\.)? *(\(|for )' && return 0
      echo "$screen" | grep -qE '\([0-9]+[ms]( [0-9]+[ms])? ·|… \([0-9]+[ms]' && return 0
      return 1
      ;;
    codex)
      echo "$screen" | grep -qE 'Working \([0-9]+s|esc to interrupt|Searching the web' && return 0
      return 1
      ;;
    gemini)
      echo "$screen" | grep -qE '\(esc to cancel' && return 0
      echo "$screen" | grep -qE 'Responding with' && return 0
      echo "$screen" | grep -qE 'Queued \(press' && return 0
      return 1
      ;;
  esac
  return 1
}

cli_done() {
  local screen="$1"
  cli_busy "$screen" && return 1
  case "$CLI" in
    claude)
      echo "$screen" | grep -qE '⏺ ' \
        && echo "$screen" | grep -qE 'bypass' \
        && echo "$screen" | grep -qE '^❯|^\s*❯' \
        || return 1
      echo "$screen" | grep -qE '[1-9][0-9]* tokens' || return 1
      return 0
      ;;
    codex)
      echo "$screen" | grep -qE '^• |^\s*• ' \
        && echo "$screen" | grep -qE '^› |^\s*› ' \
        || return 1
      # Reject if MCP servers still connecting
      echo "$screen" | grep -qiE 'Starting MCP|MCP servers' && return 1
      return 0
      ;;
    gemini)
      echo "$screen" | grep -qE '✦ ' \
        && echo "$screen" | grep -qE 'Type your message' \
        || return 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

start_epoch=$(date +%s)

while :; do
  now=$(date +%s)
  if (( now - start_epoch >= MAX_SECS )); then
    echo "timeout"
    exit 1
  fi
  sleep "$POLL_INTERVAL"

  # Grace period: skip cli_done check while CLI is still initializing.
  if [[ -n "$CLI" ]] && (( now - start_epoch >= GRACE_SECS )); then
    screen="$(mux_read_screen "$SURFACE" || true)"
    if cli_done "$screen"; then
      sleep 0.3
      echo "idle"
      exit 0
    fi
  fi
done
