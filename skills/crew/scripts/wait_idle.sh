#!/usr/bin/env bash
# Usage: wait_idle.sh <surface> [idle_secs] [max_secs] [cli]
#
# Prints "idle" on idle-detection success, "timeout" on max_secs.
#
# Detection uses TWO signals in parallel:
#   (a) Hash stability — viewport+scrollback hash unchanged for idle_secs,
#       after at least one change was seen (activity gate).
#   (b) CLI-specific "done" pattern — when the known response-prefix AND
#       the input-prompt-ready marker both appear in the viewport.
# Whichever fires first wins. (a) is the fallback for any CLI; (b) lets us
# skip the long idle-wait for CLIs that have a clear end marker.
#
# Pattern references are intentionally permissive to survive minor TUI
# rewrites. If both fail we still hit max_secs → "timeout".

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

crew_require_cmux

SURFACE="${1:?surface ref required}"
IDLE_SECS="${2:-5}"
MAX_SECS="${3:-300}"
CLI="${4:-}"                # optional: claude | codex | gemini
# 기본 폴링 0.5s — 답변 완료 즉시 반응. CREW_POLL_INTERVAL 로 override.
POLL_INTERVAL="${CREW_POLL_INTERVAL:-${POLL_INTERVAL:-0.5}}"

hash_surface() {
  local viewport scrollback
  viewport="$(cmux read-screen --surface "$SURFACE" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  scrollback="$(cmux read-screen --surface "$SURFACE" --scrollback --lines 200 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  echo "${viewport}-${scrollback}"
}

viewport_text() {
  cmux read-screen --surface "$SURFACE" 2>/dev/null || true
}

# Per-CLI "response complete" detector. Returns 0 if viewport shows both a
# recent answer prefix AND a ready-for-next-input marker. Keep patterns
# loose: match on substrings that survive wraparound.
# "현재 생각 중" 스피너가 화면에 있으면 아직 완료가 아님.
# 각 CLI 의 "Xxx-ing... Ns" 형태 (Claude: thinking/Undulating/Cooking/Seasoning 등
# 랜덤 단어 + 뒤에 's · ' 또는 '(Ns'; Codex: "Working Ns" 또는 "Searching";
# Gemini: "Thinking... Ns") 를 포괄하는 정규식.
cli_busy() {
  local screen="$1"
  case "$CLI" in
    claude)
      # 시간 카운터가 붙는 동적 상태 라인: "(10s · thinking)", "(11s · ↓ 222 tokens)",
      # "Cooked for 12s", "Working… 5s". 완료 후엔 이 라인이 사라진다.
      echo "$screen" | grep -qE '\([0-9]+s ·|… \([0-9]+s' && return 0
      return 1
      ;;
    codex)
      echo "$screen" | grep -qE 'Working \([0-9]+s|esc to interrupt|Searching the web' && return 0
      return 1
      ;;
    gemini)
      echo "$screen" | grep -qE 'Thinking\.\.\. \(esc to cancel|Responding with' && return 0
      return 1
      ;;
  esac
  return 1
}

cli_done() {
  local screen="$1"
  # busy spinner 가 보이면 절대 done 아님 (False-positive 차단)
  cli_busy "$screen" && return 1
  case "$CLI" in
    claude)
      # 답변 prefix ⏺ + 입력 footer + 빈 ❯ 프롬프트 모두 존재.
      echo "$screen" | grep -qE '⏺ ' \
        && echo "$screen" | grep -qE 'bypass permissions on' \
        && echo "$screen" | grep -qE '^❯|^\s*❯' \
        && return 0
      return 1
      ;;
    codex)
      # 답변 prefix • + 입력 prompt › 둘 다 있고 busy 아님.
      echo "$screen" | grep -qE '^• |^\s*• ' \
        && echo "$screen" | grep -qE '^› |^\s*› ' \
        && return 0
      return 1
      ;;
    gemini)
      # 답변 prefix ✦ + 입력 footer 둘 다.
      echo "$screen" | grep -qE '✦ ' \
        && echo "$screen" | grep -qE 'Type your message' \
        && return 0
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

start_epoch=$(date +%s)
initial_hash="$(hash_surface || echo init)"
last_hash="$initial_hash"
last_change_epoch=$start_epoch
seen_activity=0

while :; do
  now=$(date +%s)
  if (( now - start_epoch >= MAX_SECS )); then
    echo "timeout"
    exit 1
  fi
  sleep "$POLL_INTERVAL"

  # Signal (b): CLI-specific pattern — fires as soon as answer shows AND
  # the input prompt is ready. Skips the idle_secs wait.
  if [[ -n "$CLI" ]] && (( seen_activity == 1 )); then
    screen="$(viewport_text)"
    if cli_done "$screen"; then
      # Small grace period so trailing frames finish rendering
      sleep 0.3
      echo "idle"
      exit 0
    fi
  fi

  # Signal (a): hash stability
  cur="$(hash_surface || echo err)"
  if [[ "$cur" != "$last_hash" ]]; then
    last_hash="$cur"
    last_change_epoch=$(date +%s)
    seen_activity=1
    continue
  fi
  if (( seen_activity == 1 )) && (( $(date +%s) - last_change_epoch >= IDLE_SECS )); then
    echo "idle"
    exit 0
  fi
done
