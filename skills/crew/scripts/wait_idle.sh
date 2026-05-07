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

crew_require_mux

SURFACE="${1:?surface ref required}"
IDLE_SECS="${2:-5}"
MAX_SECS="${3:-300}"
CLI="${4:-}"                # optional: claude | codex | gemini
# 기본 폴링 0.5s — 답변 완료 즉시 반응. CREW_POLL_INTERVAL 로 override.
POLL_INTERVAL="${CREW_POLL_INTERVAL:-${POLL_INTERVAL:-0.5}}"

hash_surface() {
  local viewport scrollback
  viewport="$(mux_read_screen "$SURFACE" | shasum -a 256 | awk '{print $1}')"
  scrollback="$(mux_read_scrollback "$SURFACE" 200 | shasum -a 256 | awk '{print $1}')"
  echo "${viewport}-${scrollback}"
}

viewport_text() {
  mux_read_screen "$SURFACE" || true
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
      # claude 는 생성 중 " ● <Word>ing… (Ns ...)" 또는 "✻ <Word>ed for Ns" 같은
      # 상태 라인을 계속 갱신한다. 시간 단위(s, m) 둘 다 포괄.
      # 대표 spinner prefix: "● ", "✻ "
      # ● = 진행 중 (busy). ✻ = 완료 후 소요시간 표시 (not busy).
      echo "$screen" | grep -qE '^[[:space:]]*●[[:space:]][A-Z][a-zA-Z]+(ing|ed)(…|\.\.\.)? *(\(|for )' && return 0
      # 시간 카운터 형태: "(10s · thinking)", "(2m 41s · ...)", "… (Ns"
      echo "$screen" | grep -qE '\([0-9]+[ms]( [0-9]+[ms])? ·|… \([0-9]+[ms]' && return 0
      return 1
      ;;
    codex)
      echo "$screen" | grep -qE 'Working \([0-9]+s|esc to interrupt|Searching the web' && return 0
      return 1
      ;;
    gemini)
      echo "$screen" | grep -qE 'Thinking\.\.\. \(esc to cancel|Responding with' && return 0
      # queue 상태: 이전 프롬프트 처리 중이거나 선행 메시지 대기.
      echo "$screen" | grep -qE 'Queued \(press' && return 0
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
    # Hash 가 IDLE_SECS 동안 고정됐어도 cli_busy 가 true 면 idle 로 단정하지 않는다.
    # 예: claude 의 "(3s)" 타이머가 폴링 간격 사이 업데이트되지 않아 해시가 우연히
    # 안정돼 보이는 경우 — 실제로는 여전히 생성 중.
    if [[ -n "$CLI" ]]; then
      screen="$(viewport_text)"
      if cli_busy "$screen"; then
        continue
      fi
    fi
    sleep 0.3
    echo "idle"
    exit 0
  fi
done
