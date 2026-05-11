#!/usr/bin/env bash
# Usage: dispatch.sh <slug> <pane_idx> <prompt_file>
#
# Sends the contents of <prompt_file> to pane <pane_idx> of session <slug>.
# "완전 분리" — CLI booted separately in launch.sh; dispatch only types prompt.
# Strips trailing whitespace so Enter submits instead of inserting a newline.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

crew_require_mux

SLUG="${1:?slug required}"
PANE_IDX="${2:?pane index required (1-based)}"
PROMPT_FILE="${3:?prompt file required}"

MANIFEST="$(crew_manifest_path "$SLUG")"
[[ -f "$MANIFEST" ]]    || { echo "error: manifest $MANIFEST missing" >&2; exit 2; }
[[ -f "$PROMPT_FILE" ]] || { echo "error: prompt file $PROMPT_FILE missing" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

# surfaces[0] = caller; surfaces[pane_idx] = target
SURFACE="$(jq -r --argjson idx "$PANE_IDX" '.surfaces[$idx] // empty' "$MANIFEST")"
[[ -n "$SURFACE" ]] || { echo "error: pane $PANE_IDX has no surface" >&2; exit 4; }

# Done-signal: append instruction for the LLM to touch a sentinel file on completion.
# The orchestrator watches for this file instead of hash-polling.
SESSION_DIR="$(crew_session_dir "$SLUG")"
DONE_DIR="$SESSION_DIR/done"
mkdir -p "$DONE_DIR"
DONE_FILE="$DONE_DIR/pane-$PANE_IDX"

# Strip trailing whitespace so Enter submits
CLEAN="$(mktemp -t crew-prompt.XXXXXX)"
perl -0777 -pe 's/\s+\z//' "$PROMPT_FILE" > "$CLEAN"

# Detect CLI type for this pane
CLI="$(jq -r --argjson idx "$((PANE_IDX - 1))" '.panes[$idx].cli // ""' "$MANIFEST")"

# done-signal: Claude만 append. Codex/Gemini는 cli_done 패턴으로 감지.
# Codex는 done-signal이 있으면 본문 답변을 생략하고 touch만 실행하는 버그가 있음.
if [[ "$CLI" == "claude" ]]; then
  cat >> "$CLEAN" <<SIGNAL

---
[완료 신호] 위 질문에 대한 답변을 텍스트로 출력한 뒤, 가장 마지막에 실행: touch $DONE_FILE
SIGNAL
fi

PROMPT_TEXT="$(cat "$CLEAN")"
# cmux: focus pane before send to ensure terminal is active
if [[ "$CREW_MUX" == "cmux" ]]; then
  mux_focus_pane "$SURFACE" 2>/dev/null || true
  sleep 1
fi
if [[ "$CLI" == "gemini" ]]; then
  sleep 4
  # cmux: Gemini send는 간헐적으로 실패하므로 retry
  for _try in 1 2 3; do
    [[ "$CREW_MUX" == "cmux" ]] && mux_focus_pane "$SURFACE" 2>/dev/null || true
    sleep 0.5
    mux_send_literal "$SURFACE" "$PROMPT_TEXT"
    sleep 0.4
    mux_send_key "$SURFACE" Enter
    sleep 2
    screen="$(mux_read_screen "$SURFACE" 2>/dev/null || true)"
    if [[ -z "$screen" ]] || echo "$screen" | grep -qF "$(head -1 "$CLEAN" 2>/dev/null | cut -c1-15)"; then
      break
    fi
    sleep 2
  done
else
  mux_send "$SURFACE" "$PROMPT_TEXT"
  sleep 0.4
  mux_send_key "$SURFACE" Enter
fi

BYTES="$(wc -c <"$PROMPT_FILE" | awk '{print $1}')"

# #3 verification: after sending, confirm the prompt actually appeared on the
# pane (fingerprint = a distinctive short substring from the prompt). Retry
# once if not found. If still missing, warn — run may still proceed but
# idle-detection will likely hit timeout, surfacing the failure clearly.
FINGERPRINT="$(head -1 "$CLEAN" | cut -c1-30 | tr -d '\n')"
rm -f "$CLEAN"

# Gemini: send-keys -l 방식이라 paste-buffer retry가 무의미하고
# read-screen 자체도 빈 문자열일 수 있으므로 verification 스킵.
if [[ -n "$FINGERPRINT" && "$CLI" != "gemini" ]]; then
  ok=0
  for attempt in 1 2 3; do
    sleep 1.2
    screen="$(mux_read_screen "$SURFACE" || true)"
    if [[ -z "$screen" ]]; then
      ok=1; break
    fi
    if echo "$screen" | grep -qF "$FINGERPRINT"; then
      ok=1; break
    fi
    if (( attempt == 2 )); then
      perl -0777 -pe 's/\s+\z//' "$PROMPT_FILE" > "${PROMPT_FILE}.retry"
      mux_send "$SURFACE" "$(cat "${PROMPT_FILE}.retry")"
      sleep 0.4
      mux_send_key "$SURFACE" Enter
      rm -f "${PROMPT_FILE}.retry"
    fi
  done
  if (( ok == 0 )); then
    echo "warning: prompt echo not detected on pane $PANE_IDX ($SURFACE) — response may be missing" >&2
  fi
fi

echo "ok: sent $BYTES bytes to pane $PANE_IDX ($SURFACE)"
