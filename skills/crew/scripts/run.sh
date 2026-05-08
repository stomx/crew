#!/usr/bin/env bash
# Usage: run.sh <plan-json-path-or-dash> [_deprecated] [max_secs] [view_secs] [--keep]
#
# End-to-end orchestrator. Reads a plan JSON, launches panes (+ report pane),
# dispatches prompts, waits for completion, captures, collects artifacts, and
# unless --keep closes panes.
#
# Completion detection priority:
#   1. done-file — model executes `touch done/pane-N` (primary, explicit)
#   2. cli_done pattern — TUI shows response prefix + input prompt (secondary)
#   3. max_secs — hard timeout (last resort)
#
# $2 (formerly idle_secs) is accepted but ignored for backward compat.
# view_secs (default: $CREW_VIEW_SECS or 10) — linger time after all panes
# finish so the user can actually see the results on screen before cleanup.
# --keep bypasses cleanup entirely.
#
# plan-json shape: see SKILL.md / launch.sh comments.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

crew_require_mux
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

# 멀티플렉서 없으면 인라인 폴백으로 위임
if [[ "$CREW_MUX" == "inline" ]]; then
  exec "$HERE/inline-run.sh" "$@"
fi

PLAN_INPUT="${1:?plan JSON path (or -) required}"
# $2 formerly idle_secs — ignored, kept for call-site compat
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
    # "prev:N" / "prev-K:N" 는 이전 run 참조 — stage/DAG 검증 대상 아님.
    if [[ "$from" =~ ^prev(-[0-9]+)?:[0-9]+$ ]]; then
      continue
    fi
    if ! [[ "$from" =~ ^[0-9]+$ ]] || (( from < 1 || from > PANE_TOTAL )); then
      echo "error: pane $my_idx share_from has invalid ref: $from (must be 1..$PANE_TOTAL or prev[-K]:N)" >&2
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

# Per-session prompt snapshot — protects against concurrent crew sessions
# overwriting the same /tmp/crew.paneN.txt. We copy every plan.panes[].prompt_file
# into $session/prompts/ and rewrite manifest.json so downstream dispatch reads
# the snapshot, not the shared path.
SESSION_PROMPT_DIR="$(crew_session_dir "$SLUG")/prompts"
mkdir -p "$SESSION_PROMPT_DIR"
NPANES=$(jq '.panes | length' "$MANIFEST")
for i in $(seq 0 $((NPANES - 1))); do
  orig=$(jq -r --argjson i "$i" '.panes[$i].prompt_file' "$MANIFEST")
  [[ -f "$orig" ]] || continue
  snap="$SESSION_PROMPT_DIR/pane-$((i+1)).txt"
  cp -f "$orig" "$snap"
  tmp_manifest="$(mktemp)"
  jq --argjson i "$i" --arg p "$snap" '.panes[$i].prompt_file = $p' "$MANIFEST" > "$tmp_manifest"
  mv -f "$tmp_manifest" "$MANIFEST"
done

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
    mux_send "$MAIN_SURFACE" "$line" 2>/dev/null || true
  fi
}

echo "=== crew run ==="
echo "$LAUNCH_OUT"

PANE_COUNT=$(jq '.panes | length' "$MANIFEST")
report "launched $PANE_COUNT pane(s) for session $SLUG"

# Determine stage ordering
STAGES="$(echo "$PLAN" | jq -r '[.panes[].stage // 1] | unique | sort | .[]')"

# Per-pane worker. Runs in background so fast panes don't wait for slow ones:
#   ready-poll → share_from inject → dispatch → idle-poll → capture → rename.
# Emits the status line as its final stdout, which is consumed by the capture
# loop after `wait`.
pane_worker() {
  local pane_idx="$1"
  local i=$((pane_idx - 1))
  local cli model prompt_file role surface shares from_idx status slot mark new_label
  cli=$(jq -r          --argjson i "$i"        '.panes[$i].cli'               "$MANIFEST")
  model=$(jq -r        --argjson i "$i"        '.panes[$i].model // ""'       "$MANIFEST")
  prompt_file=$(jq -r  --argjson i "$i"        '.panes[$i].prompt_file'       "$MANIFEST")
  role=$(jq -r         --argjson i "$i"        '.panes[$i].role // empty'     "$MANIFEST")
  surface=$(jq -r      --argjson idx "$pane_idx" '.surfaces[$idx]'            "$MANIFEST")

  # Block until this CLI shows its prompt-ready marker. Polls at 0.5s so the
  # first-ready pane fires immediately without waiting on slower siblings.
  if ! crew_wait_ready "$surface" "$cli" 45; then
    # Retry: re-focus pane (may need terminal runtime init) and try once more
    mux_focus_pane "$surface" 2>/dev/null || true
    sleep 2
    if ! crew_wait_ready "$surface" "$cli" 20; then
      echo "[$(date +%H:%M:%S)]   ✕ pane-$pane_idx ($cli) not ready after retry — skipping" >> "$LOG_FILE"
      status="not_ready"
      slot="$("$HERE/capture.sh" "$SLUG" "$pane_idx" "$status" "$prompt_file")"
      mux_rename "$surface" "crew#$pane_idx ✕ $cli${model:+:$model} — not ready" || true
      sleep 2
      mux_close "$surface" 2>/dev/null || true
      echo "[$(date +%H:%M:%S)]   ✕ pane-$pane_idx closed (not ready)" >> "$LOG_FILE"
      return 0
    fi
  fi
  echo "[$(date +%H:%M:%S)]   • pane-$pane_idx ($cli) ready" >> "$LOG_FILE"

  # share_from 처리 (stage 순서는 외부에서 이미 보장됨)
  shares=$(jq -r --argjson i "$i" '.panes[$i].share_from // [] | .[]' "$MANIFEST")
  if [[ -n "$shares" ]]; then
    while IFS= read -r from_idx; do
      [[ -z "$from_idx" ]] && continue
      echo "[$(date +%H:%M:%S)]   ⇢ sharing pane-$from_idx → pane-$pane_idx" >> "$LOG_FILE"
      "$HERE/slot.sh" share "$SLUG" "$from_idx" "$pane_idx" >> "$LOG_FILE" 2>&1 \
        || echo "[$(date +%H:%M:%S)]   ! share pane-$from_idx → pane-$pane_idx failed" >> "$LOG_FILE"
    done <<< "$shares"
    "$HERE/wait_idle.sh" "$surface" 4 60 "$cli" >/dev/null 2>&1 || true
  fi

  "$HERE/dispatch.sh" "$SLUG" "$pane_idx" "$prompt_file" >> "$LOG_FILE" 2>&1
  echo "[$(date +%H:%M:%S)]   → pane-$pane_idx ($cli $model) prompt dispatched" >> "$LOG_FILE"

  # Wait for completion: done-file check runs concurrently with wait_idle.sh.
  # whichever fires first wins.
  local done_file="$(crew_session_dir "$SLUG")/done/pane-$pane_idx"
  mkdir -p "$(dirname "$done_file")"

  # Start wait_idle.sh in background (cli_done pattern detection)
  local grace=10
  [[ "$cli" == "gemini" ]] && grace=5
  "$HERE/wait_idle.sh" "$surface" "$grace" "$MAX_SECS" "$cli" >/dev/null 2>&1 &
  local idle_pid=$!

  status="timeout"
  local wait_start=$(date +%s)
  while (( $(date +%s) - wait_start < MAX_SECS )); do
    # Check done-file first
    if [[ -f "$done_file" ]]; then
      status="idle"
      kill "$idle_pid" 2>/dev/null || true
      wait "$idle_pid" 2>/dev/null || true
      break
    fi
    # Check if wait_idle.sh already exited (idle detected)
    if ! kill -0 "$idle_pid" 2>/dev/null; then
      status="idle"
      break
    fi
    sleep 1
  done
  # Cleanup if still running
  kill "$idle_pid" 2>/dev/null || true
  wait "$idle_pid" 2>/dev/null || true
  slot="$("$HERE/capture.sh" "$SLUG" "$pane_idx" "$status" "$prompt_file")"
  mark="✓"; [[ "$status" == "timeout" ]] && mark="⏱"
  new_label="crew#$pane_idx $mark $cli${model:+:$model}${role:+ — $role}"
  mux_rename "$surface" "$new_label" || true
  echo "[$(date +%H:%M:%S)]   ← pane-$pane_idx ($cli $model) status=$status → $slot" >> "$LOG_FILE"

  # Close pane individually as soon as it finishes
  sleep 2
  mux_close "$surface" 2>/dev/null || true
  echo "[$(date +%H:%M:%S)]   ✕ pane-$pane_idx closed" >> "$LOG_FILE"
}

for stage in $STAGES; do
  report "stage $stage starting"
  PIDS=()

  for i in $(seq 0 $((PANE_COUNT - 1))); do
    pane_stage=$(jq -r --argjson i "$i" '.panes[$i].stage // 1' "$MANIFEST")
    [[ "$pane_stage" == "$stage" ]] || continue
    pane_idx=$((i + 1))
    pane_worker "$pane_idx" &
    PIDS+=($!)
  done

  for p in "${PIDS[@]:-}"; do
    [[ -n "$p" ]] && wait "$p" || true
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
