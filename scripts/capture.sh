#!/usr/bin/env bash
# Usage: capture.sh <slug> <pane_idx> [status] [prompt_file]
# Writes pane output into session's slot file (slots/pane-<N>.md).

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

crew_require_cmux
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

SLUG="${1:?slug required}"
PANE_IDX="${2:?pane index required}"
STATUS="${3:-unknown}"
PROMPT_FILE="${4:-}"

MANIFEST="$(crew_manifest_path "$SLUG")"
SURFACE="$(jq -r --argjson idx "$PANE_IDX" '.surfaces[$idx] // empty' "$MANIFEST")"
CLI="$(jq -r     --argjson i "$((PANE_IDX-1))" '.panes[$i].cli // "?"'   "$MANIFEST")"
MODEL="$(jq -r   --argjson i "$((PANE_IDX-1))" '.panes[$i].model // ""'   "$MANIFEST")"
EFFORT="$(jq -r  --argjson i "$((PANE_IDX-1))" '.panes[$i].effort // ""'  "$MANIFEST")"
ROLE="$(jq -r    --argjson i "$((PANE_IDX-1))" '.panes[$i].role // ""'    "$MANIFEST")"

SLOT="$(crew_slot_path "$SLUG" "$PANE_IDX")"
mkdir -p "$(dirname "$SLOT")"

{
  echo "# crew pane-$PANE_IDX capture"
  echo "slug: $SLUG"
  echo "cli: $CLI"
  echo "model: $MODEL"
  [[ -n "$EFFORT" ]] && echo "effort: $EFFORT"
  echo "role: $ROLE"
  echo "surface: $SURFACE"
  echo "status: $STATUS"
  [[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]] && echo "prompt_file: $PROMPT_FILE"
  echo
  if [[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]]; then
    echo '## prompt'
    echo
    echo '```'
    cat "$PROMPT_FILE"
    echo '```'
    echo
  fi
  echo '## pane capture'
  echo
  echo '```'
  cmux read-screen --surface "$SURFACE" --scrollback --lines 6000 2>/dev/null || true
  echo '```'
} > "$SLOT"

echo "$SLOT"
