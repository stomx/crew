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

crew_require_cmux

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

# Strip trailing whitespace so Enter submits
CLEAN="$(mktemp -t crew-prompt.XXXXXX)"
perl -0777 -pe 's/\s+\z//' "$PROMPT_FILE" > "$CLEAN"

cmux send --surface "$SURFACE" "$(cat "$CLEAN")" >/dev/null
sleep 0.4
cmux send-key --surface "$SURFACE" Enter >/dev/null

BYTES="$(wc -c <"$PROMPT_FILE" | awk '{print $1}')"

# #3 verification: after sending, confirm the prompt actually appeared on the
# pane (fingerprint = a distinctive short substring from the prompt). Retry
# once if not found. If still missing, warn — run may still proceed but
# idle-detection will likely hit timeout, surfacing the failure clearly.
FINGERPRINT="$(head -1 "$CLEAN" | cut -c1-30 | tr -d '\n')"
rm -f "$CLEAN"

if [[ -n "$FINGERPRINT" ]]; then
  ok=0
  for attempt in 1 2 3; do
    sleep 1.2
    screen="$(cmux read-screen --surface "$SURFACE" 2>/dev/null || true)"
    if echo "$screen" | grep -qF "$FINGERPRINT"; then
      ok=1; break
    fi
    # retry: re-inject on attempt 2 (attempt 3 is just a final poll)
    if (( attempt == 2 )); then
      perl -0777 -pe 's/\s+\z//' "$PROMPT_FILE" > "${PROMPT_FILE}.retry"
      cmux send --surface "$SURFACE" "$(cat "${PROMPT_FILE}.retry")" >/dev/null
      sleep 0.4
      cmux send-key --surface "$SURFACE" Enter >/dev/null
      rm -f "${PROMPT_FILE}.retry"
    fi
  done
  if (( ok == 0 )); then
    echo "warning: prompt echo not detected on pane $PANE_IDX ($SURFACE) — response may be missing" >&2
  fi
fi

echo "ok: sent $BYTES bytes to pane $PANE_IDX ($SURFACE)"
