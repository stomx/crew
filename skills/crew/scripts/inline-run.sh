#!/usr/bin/env bash
# inline-run.sh — 멀티플렉서 없이 CLI 를 subprocess 로 직접 호출하는 폴백 실행기.
#
# Usage: inline-run.sh <plan-json-path-or-dash> [max_secs]
#
# pane 을 띄우지 않고 각 CLI 의 비대화형 모드를 사용:
#   claude -p "prompt" --model X --effort Y
#   codex exec "prompt" -m X
#   gemini -p "prompt" -m X
#
# staged 실행과 share_from 을 지원하며, 같은 stage 의 pane 은 백그라운드 병렬.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

# macOS 에 timeout 이 없을 수 있으므로 polyfill
if ! command -v timeout >/dev/null 2>&1; then
  timeout() {
    local secs="$1"; shift
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  }
fi

crew_require_mux
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

PLAN_INPUT="${1:?plan JSON path (or -) required}"
MAX_SECS="${2:-300}"

# Read plan
if [[ "$PLAN_INPUT" == "-" ]]; then
  PLAN="$(cat)"
else
  [[ -f "$PLAN_INPUT" ]] || { echo "error: plan file missing" >&2; exit 2; }
  PLAN="$(cat "$PLAN_INPUT")"
fi

# Validate prompt files
echo "$PLAN" | jq -r '.panes[] | "\(.id // "?") \(.prompt_file // "")"' | while read -r id pf; do
  [[ -z "$pf" ]]    && { echo "error: pane $id missing prompt_file" >&2; exit 4; }
  [[ -f "$pf" ]]    || { echo "error: pane $id prompt_file not found: $pf" >&2; exit 4; }
done

# Validate share_from DAG
PANE_TOTAL=$(echo "$PLAN" | jq '.panes | length')
for i in $(seq 0 $((PANE_TOTAL - 1))); do
  my_idx=$((i + 1))
  my_stage=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].stage // 1')
  shares=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].share_from // [] | .[]')
  [[ -z "$shares" ]] && continue
  while IFS= read -r from; do
    [[ -z "$from" ]] && continue
    [[ "$from" =~ ^prev(-[0-9]+)?:[0-9]+$ ]] && continue
    if ! [[ "$from" =~ ^[0-9]+$ ]] || (( from < 1 || from > PANE_TOTAL )); then
      echo "error: pane $my_idx share_from invalid ref: $from" >&2; exit 7
    fi
    (( from == my_idx )) && { echo "error: pane $my_idx share_from includes itself" >&2; exit 7; }
    from_stage=$(echo "$PLAN" | jq -r --argjson j "$((from - 1))" '.panes[$j].stage // 1')
    (( from_stage >= my_stage )) && { echo "error: pane $my_idx share_from $from — source stage must be earlier" >&2; exit 7; }
  done <<< "$shares"
done

# Setup session
USER_SLUG="$(echo "$PLAN" | jq -r '.slug // empty')"
WS_SLUG="$(crew_workspace_slug)"
crew_latest_dir >/dev/null 2>&1 || true

if [[ -z "$USER_SLUG" ]]; then
  RUN="$(crew_timestamp)-$$-$RANDOM"
else
  RUN="${USER_SLUG}-$(crew_timestamp)-$RANDOM"
fi
SLUG="${WS_SLUG}/${RUN}"
[[ -d "$(crew_session_dir "$SLUG")" ]] && SLUG="${SLUG}-$RANDOM"

SESSION_DIR="$(crew_session_dir "$SLUG")"
mkdir -p "$SESSION_DIR/slots" "$SESSION_DIR/prompts"
LOG_FILE="$(crew_log_path "$SLUG")"
: > "$LOG_FILE"

log() { echo "[$(date +%H:%M:%S)] $1" >> "$LOG_FILE"; echo "[$(date +%H:%M:%S)] $1"; }
log "inline session $SLUG starting with $PANE_TOTAL panes"

# Snapshot prompts
for i in $(seq 0 $((PANE_TOTAL - 1))); do
  orig=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].prompt_file')
  [[ -f "$orig" ]] || continue
  cp -f "$orig" "$SESSION_DIR/prompts/pane-$((i+1)).txt"
done

# Write manifest (no surfaces in inline mode)
MANIFEST="$(crew_manifest_path "$SLUG")"
echo "$PLAN" | jq --arg slug "$SLUG" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + { slug: $slug, mode: "inline", surfaces: [], caller_surface: "inline", report_surface: "", log_file: "'"$LOG_FILE"'", created_at: $created }' \
  > "$MANIFEST"

# Update latest symlink
WS_DIR="$(crew_workspace_dir)"
mkdir -p "$WS_DIR"
RUN_REL="${SLUG#${WS_SLUG}/}"
ln -snf "$RUN_REL" "$WS_DIR/latest"

# --- CLI 실행 함수 ---

run_cli() {
  local pane_idx="$1"
  local i=$((pane_idx - 1))
  local cli model effort prompt_file prompt status output slot_path

  cli=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].cli')
  model=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].model // ""')
  effort=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].effort // ""')
  prompt_file="$SESSION_DIR/prompts/pane-${pane_idx}.txt"
  [[ -f "$prompt_file" ]] || prompt_file="$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].prompt_file')"

  # share_from: prepend referenced slots to prompt
  local shares shared_content=""
  shares=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].share_from // [] | .[]')
  if [[ -n "$shares" ]]; then
    while IFS= read -r ref; do
      [[ -z "$ref" ]] && continue
      local ref_path=""
      if [[ "$ref" =~ ^prev(-[0-9]+)?:[0-9]+$ ]]; then
        ref_path="$(crew_resolve_share_ref "$ref" || true)"
      elif [[ "$ref" =~ ^[0-9]+$ ]]; then
        ref_path="$(crew_slot_path "$SLUG" "$ref")"
      fi
      if [[ -n "$ref_path" && -f "$ref_path" ]]; then
        shared_content+="--- shared from pane-${ref} ---"$'\n'
        shared_content+="$(cat "$ref_path")"$'\n\n'
      fi
    done <<< "$shares"
  fi

  prompt="${shared_content}$(cat "$prompt_file")"

  log "  → pane-$pane_idx ($cli ${model:-default}) dispatching inline"

  # Execute CLI non-interactively (stdin 으로 프롬프트 전달)
  local cmd_output="" exit_code=0
  local prompt_tmp
  prompt_tmp="$(mktemp -t crew-inline-prompt.XXXXXX)"
  printf '%s' "$prompt" > "$prompt_tmp"

  case "$cli" in
    claude)
      local cmd_args=(-p -)
      [[ -n "$model" ]]  && cmd_args+=(--model "$model")
      [[ -n "$effort" ]] && cmd_args+=(--effort "$effort")
      cmd_output="$(timeout "$MAX_SECS" claude "${cmd_args[@]}" < "$prompt_tmp" 2>&1)" || exit_code=$?
      ;;
    codex)
      local cmd_args=(exec -)
      [[ -n "$model" ]]  && cmd_args+=(-m "$model")
      [[ -n "$effort" ]] && cmd_args+=(-c "model_reasoning_effort=$effort")
      cmd_output="$(timeout "$MAX_SECS" codex "${cmd_args[@]}" < "$prompt_tmp" 2>&1)" || exit_code=$?
      ;;
    gemini)
      local cmd_args=(-p -)
      [[ -n "$model" ]] && cmd_args+=(-m "$model")
      cmd_output="$(timeout "$MAX_SECS" gemini "${cmd_args[@]}" < "$prompt_tmp" 2>&1)" || exit_code=$?
      ;;
    *)
      cmd_output="error: unknown cli '$cli'"
      exit_code=1
      ;;
  esac
  rm -f "$prompt_tmp"

  if (( exit_code == 124 )); then
    status="timeout"
  elif (( exit_code == 0 )); then
    status="idle"
  else
    status="error"
  fi

  # Write slot
  slot_path="$(crew_slot_path "$SLUG" "$pane_idx")"
  {
    echo "# crew pane-$pane_idx capture (inline)"
    echo "slug: $SLUG"
    echo "cli: $cli"
    echo "model: $model"
    [[ -n "$effort" ]] && echo "effort: $effort"
    echo "status: $status"
    echo
    echo '## prompt'
    echo
    echo '```'
    cat "$prompt_file"
    echo '```'
    echo
    echo '## response'
    echo
    echo "$cmd_output"
  } > "$slot_path"

  log "  ← pane-$pane_idx ($cli ${model:-default}) status=$status"
}

# --- Staged 실행 ---

STAGES="$(echo "$PLAN" | jq -r '[.panes[].stage // 1] | unique | sort | .[]')"

for stage in $STAGES; do
  log "stage $stage starting"
  PIDS=()

  for i in $(seq 0 $((PANE_TOTAL - 1))); do
    pane_stage=$(echo "$PLAN" | jq -r --argjson i "$i" '.panes[$i].stage // 1')
    [[ "$pane_stage" == "$stage" ]] || continue
    pane_idx=$((i + 1))
    run_cli "$pane_idx" &
    PIDS+=($!)
  done

  for p in "${PIDS[@]:-}"; do
    [[ -n "$p" ]] && wait "$p" || true
  done
  log "stage $stage complete"
done

# Collect artifacts
COLLECT_OUT="$("$HERE/collect.sh" "$SLUG")"
echo "$COLLECT_OUT"
ARTIFACT_ROOT=$(echo "$COLLECT_OUT" | awk -F= '/^artifact_root=/{print $2}')
log "artifacts → $ARTIFACT_ROOT"
log "✓ all panes done (inline mode) — main Claude will now read slots and synthesize"

echo "=== crew inline run ==="
echo "slug=$SLUG"
echo "mode=inline"
echo "manifest=$MANIFEST"
echo "artifact_root=$ARTIFACT_ROOT"
