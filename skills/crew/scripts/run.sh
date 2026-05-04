#!/usr/bin/env bash
# Usage: run.sh <plan-json-path-or-dash> [idle_secs] [max_secs] [view_secs] [--keep]
#
# End-to-end orchestrator. Reads a plan JSON, launches panes (+ report pane),
# dispatches prompts, waits for idle, captures, collects artifacts, and unless
# --keep closes panes. Prints a status block on stdout AND live-logs to the
# report pane (tail -f) so the user sees progress as it happens.
#
# view_secs (default: $CREW_VIEW_SECS or 10) — linger time after all panes
# finish so the user can actually see the results on screen before cleanup.
# --keep bypasses cleanup entirely.
#
# plan-json shape: see SKILL.md / launch.sh comments.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

crew_require_cmux
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

PLAN_INPUT="${1:?plan JSON path (or -) required}"
IDLE_SECS="${2:-8}"
MAX_SECS="${3:-300}"
VIEW_SECS="${4:-${CREW_VIEW_SECS:-10}}"

KEEP=0
for a in "$@"; do [[ "$a" == "--keep" ]] && KEEP=1; done

# --- trap: ensure panes are cleaned even on interrupt ---
SLUG=""
cleanup_on_signal() {
  local rc=$?
  if [[ -n "$SLUG" && $KEEP -eq 0 ]]; then
    echo "[$(date +%H:%M:%S)] signal received — cleaning up" >> "$(crew_log_path "$SLUG")" 2>/dev/null || true
    "$HERE/cleanup.sh" "$SLUG" >/dev/null 2>&1 || true
  fi
  exit $rc
}
trap cleanup_on_signal INT TERM

# Read plan
if [[ "$PLAN_INPUT" == "-" ]]; then
  PLAN="$(cat)"
else
  [[ -f "$PLAN_INPUT" ]] || { echo "error: plan file missing" >&2; exit 2; }
  PLAN="$(cat "$PLAN_INPUT")"
fi

# Validate prompt_file presence for every pane
echo "$PLAN" | jq -r '.panes[] | "\(.id // "?") \(.prompt_file // "")"' | while read -r id pf; do
  [[ -z "$pf" ]]    && { echo "error: pane $id missing prompt_file" >&2; exit 4; }
  [[ -f "$pf" ]]    || { echo "error: pane $id prompt_file not found: $pf" >&2; exit 4; }
done

# Validate share_from DAG: every referenced pane must exist AND be in an
# earlier stage than the pane that references it. Self-reference forbidden.
PANE_TOTAL=$(echo "$PLAN" | jq '.panes | length')
for i in $(seq 0 $((PANE_TOTAL - 1))); do
  my_idx=$((i + 1))
  my_stage=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].stage // 1')
  shares=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].share_from // [] | .[]')
  [[ -z "$shares" ]] && continue
  while IFS= read -r from; do
    [[ -z "$from" ]] && continue
    if ! [[ "$from" =~ ^[0-9]+$ ]] || (( from < 1 || from > PANE_TOTAL )); then
      echo "error: pane $my_idx share_from has invalid ref: $from (must be 1..$PANE_TOTAL)" >&2
      exit 7
    fi
    if (( from == my_idx )); then
      echo "error: pane $my_idx share_from includes itself" >&2
      exit 7
    fi
    from_stage=$(echo "$PLAN" | jq -r --argjson j "$((from - 1))" '.panes[$j].stage // 1')
    if (( from_stage >= my_stage )); then
      echo "error: pane $my_idx (stage $my_stage) share_from $from (stage $from_stage) — source stage must be earlier" >&2
      exit 7
    fi
  done <<< "$shares"
done

# Launch panes (booting CLIs + report pane). launch.sh accepts plan on stdin via "-".
LAUNCH_OUT="$(echo "$PLAN" | "$HERE/launch.sh" -)"
SLUG="$(echo "$LAUNCH_OUT" | awk -F= '/^slug=/{print $2}')"
MANIFEST="$(crew_manifest_path "$SLUG")"
LOG_FILE="$(crew_log_path "$SLUG")"
MAIN_SURFACE="$(jq -r '.caller_surface // empty' "$MANIFEST")"

# Helper: emit a timestamped line to both report log and crew's own stdout.
# Optionally also whisper to the main pane's textarea (no Enter, user sees it
# without it being submitted as a message).
report() {
  local line="$1"
  local ts="[$(date +%H:%M:%S)]"
  echo "$ts $line" >> "$LOG_FILE"
  echo "$ts $line"
  # Whisper to main pane is OPT-IN only — set CREW_WHISPER_MAIN=1 to enable.
  # Default OFF because the report pane already shows this live and writing
  # to the main TUI's textarea pollutes the active Claude Code session.
  if [[ "${CREW_WHISPER_MAIN:-0}" == "1" && -n "${MAIN_SURFACE:-}" ]]; then
    cmux send --surface "$MAIN_SURFACE" "$line" >/dev/null 2>&1 || true
  fi
}

echo "=== crew run ==="
echo "$LAUNCH_OUT"

PANE_COUNT=$(jq '.panes | length' "$MANIFEST")
report "launched $PANE_COUNT pane(s) for session $SLUG"

# Determine stage ordering
STAGES="$(echo "$PLAN" | jq -r '[.panes[].stage // 1] | unique | sort | .[]')"

for stage in $STAGES; do
  report "stage $stage starting"
  PIDS=()
  TARGETS=()

  for i in $(seq 0 $((PANE_COUNT - 1))); do
    pane_stage=$(jq -r --argjson i "$i" '.panes[$i].stage // 1' "$MANIFEST")
    [[ "$pane_stage" == "$stage" ]] || continue
    pane_idx=$((i + 1))
    prompt_file=$(jq -r --argjson i "$i" '.panes[$i].prompt_file' "$MANIFEST")
    cli=$(jq -r  --argjson i "$i" '.panes[$i].cli'          "$MANIFEST")
    model=$(jq -r --argjson i "$i" '.panes[$i].model // ""' "$MANIFEST")

    # Auto-share upstream pane slots before dispatching this pane's prompt.
    # Each share injects the referenced pane's captured slot as a preamble,
    # then this pane's own prompt follows. (slot.sh share writes and submits,
    # so we send the share first, let it settle, then send the main prompt.)
    shares=$(jq -r --argjson i "$i" '.panes[$i].share_from // [] | .[]' "$MANIFEST")
    if [[ -n "$shares" ]]; then
      while IFS= read -r from_idx; do
        [[ -z "$from_idx" ]] && continue
        report "  ⇢ sharing pane-$from_idx → pane-$pane_idx"
        "$HERE/slot.sh" share "$SLUG" "$from_idx" "$pane_idx" >> "$LOG_FILE" 2>&1 || {
          report "  ! share pane-$from_idx → pane-$pane_idx failed (continuing)"
        }
        sleep 0.5
      done <<< "$shares"
      # Give the receiving CLI a beat to process the shared context before
      # we send the actual prompt on top.
      surface=$(jq -r --argjson idx "$pane_idx" '.surfaces[$idx]' "$MANIFEST")
      "$HERE/wait_idle.sh" "$surface" 4 60 "$cli" >/dev/null 2>&1 || true
    fi

    "$HERE/dispatch.sh" "$SLUG" "$pane_idx" "$prompt_file" >> "$LOG_FILE" 2>&1
    report "  → pane-$pane_idx ($cli $model) prompt dispatched"

    # Start idle wait in background (PID in filename to avoid concurrent run collisions)
    status_file="/tmp/crew-$SLUG-$$-pane-$pane_idx.status"
    surface=$(jq -r --argjson idx "$pane_idx" '.surfaces[$idx]' "$MANIFEST")
    "$HERE/wait_idle.sh" "$surface" "$IDLE_SECS" "$MAX_SECS" "$cli" > "$status_file" &
    PIDS+=($!)
    TARGETS+=("$pane_idx:$status_file:$cli:$model")
  done

  # Wait for all panes in this stage
  for p in "${PIDS[@]:-}"; do
    [[ -n "$p" ]] && wait "$p" || true
  done

  # Capture each pane
  for tgt in "${TARGETS[@]:-}"; do
    [[ -z "$tgt" ]] && continue
    IFS=':' read -r pane_idx status_file cli model <<< "$tgt"
    status="$(cat "$status_file" 2>/dev/null || echo unknown)"
    rm -f "$status_file"
    prompt_file=$(jq -r --argjson i "$((pane_idx - 1))" '.panes[$i].prompt_file' "$MANIFEST")
    slot="$("$HERE/capture.sh" "$SLUG" "$pane_idx" "$status" "$prompt_file")"
    report "  ← pane-$pane_idx ($cli $model) status=$status → $slot"
  done
  report "stage $stage complete"
done

# Collect into artifact bundle
COLLECT_OUT="$("$HERE/collect.sh" "$SLUG")"
echo "$COLLECT_OUT"
ARTIFACT_ROOT=$(echo "$COLLECT_OUT" | awk -F= '/^artifact_root=/{print $2}')
report "artifacts → $ARTIFACT_ROOT"
report "✓ all panes done — main Claude will now read slots and synthesize"

# Cleanup unless --keep
if (( KEEP == 0 )); then
  if (( VIEW_SECS > 0 )); then
    report "closing in ${VIEW_SECS}s…"
    echo "view_secs=$VIEW_SECS (panes remain visible before cleanup)"
    sleep "$VIEW_SECS"
  fi
  "$HERE/cleanup.sh" "$SLUG" >/dev/null 2>&1 || true
  echo "cleaned=yes"
else
  echo "cleaned=no (--keep)"
fi

trap - INT TERM
