#!/usr/bin/env bash
# Usage: launch.sh <plan-json>
#
# plan-json shape (read from stdin if "-"):
# {
#   "slug": "optional-slug",
#   "panes": [
#     { "id": 1, "cli": "claude",  "model": "sonnet",     "effort": "high",  "role": "implement X" },
#     { "id": 2, "cli": "codex",   "model": "gpt-5.5",    "effort": "xhigh", "role": "verify logic" },
#     { "id": 3, "cli": "gemini",  "model": "gemini-2.5-pro",                "role": "explore alternatives" }
#   ]
# }
#
# Produces a session directory at $CREW_STATE_DIR/<slug>/ with:
#   manifest.json (plan + surface assignments + created_at)
#   slots/ (per-pane output slots, filled later by capture)
# Emits slug and manifest path on stdout.
#
# IMPORTANT: launch only boots each CLI. Prompt injection is a SEPARATE step
# (dispatch.sh) — "완전 분리" 원칙.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

crew_require_mux

PLAN_INPUT="${1:?plan JSON path or - for stdin}"

if [[ "$PLAN_INPUT" == "-" ]]; then
  PLAN="$(cat)"
else
  [[ -f "$PLAN_INPUT" ]] || { echo "error: plan file $PLAN_INPUT missing" >&2; exit 2; }
  PLAN="$(cat "$PLAN_INPUT")"
fi

# Require jq — plan is JSON.
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

USER_SLUG="$(echo "$PLAN" | jq -r '.slug // empty')"
WS_SLUG="$(crew_workspace_slug)"

# 이전 run 의 cleanup 이 구버전이었거나 중간에 실패해 workspace/latest 심링크가
# dangling(삭제된 state dir 을 가리킴) 상태라면 여기서 자가 치유.
# crew_latest_dir 은 dangling 을 감지하면 같은 run_id 의 artifact 디렉터리로
# 심링크를 자동 재바인딩한다. 리턴값은 무시 — 목적은 재바인딩 부수효과.
crew_latest_dir >/dev/null 2>&1 || true
# slug 구조:
#   기본:       ws-<id>/<timestamp>-<pid>-<rand>   ← 같은 workspace 의 모든 run 이 한 폴더 아래
#   user slug:  ws-<id>/<user_slug>-<timestamp>-<rand>   ← 사용자가 이름을 줘도 항상 유일
if [[ -z "$USER_SLUG" ]]; then
  RUN="$(crew_timestamp)-$$-$RANDOM"
else
  RUN="${USER_SLUG}-$(crew_timestamp)-$RANDOM"
fi
SLUG="${WS_SLUG}/${RUN}"

# 혹시라도 동일 경로가 이미 존재하면 추가 접미사로 격리.
if [[ -d "$(crew_session_dir "$SLUG")" ]]; then
  SLUG="${SLUG}-$RANDOM"
fi

N=$(echo "$PLAN" | jq '.panes | length')
if (( N < 1 )); then
  echo "error: plan has no panes" >&2; exit 4
fi

SESSION_DIR="$(crew_session_dir "$SLUG")"
mkdir -p "$SESSION_DIR/slots"

# Initialize live log (report pane tails this)
LOG_FILE="$(crew_log_path "$SLUG")"
: > "$LOG_FILE"
echo "[$(date +%H:%M:%S)] crew session $SLUG starting with $N panes" >> "$LOG_FILE"

CALLER_SURFACE="$(mux_caller_surface)"

# Validate each CLI is installed before spawning any pane
for i in $(seq 0 $((N - 1))); do
  cli="$(echo "$PLAN" | jq -r ".panes[$i].cli")"
  if ! crew_have "$cli"; then
    echo "error: CLI '$cli' not found (pane $((i+1))). Install it or change the cli field in plan." >&2
    exit 5
  fi
done

# #4 detect codex ChatGPT-login and warn about API-only models
if command -v codex >/dev/null 2>&1; then
  codex_login="$(codex login status 2>&1 || true)"
  if echo "$codex_login" | grep -qi "ChatGPT"; then
    # ChatGPT-account allowed: gpt-5.5 and gpt-5.4. Warn if plan uses others.
    for i in $(seq 0 $((N - 1))); do
      cli="$(echo "$PLAN" | jq -r ".panes[$i].cli")"
      [[ "$cli" == "codex" ]] || continue
      model="$(echo "$PLAN" | jq -r ".panes[$i].model // empty")"
      [[ -z "$model" ]] && continue
      case "$model" in
        gpt-5.5|gpt-5.4) ;; # ok
        *)
          echo "warning: pane $((i+1)) codex model '$model' may be rejected — ChatGPT account only supports gpt-5.5 / gpt-5.4. See config/models.yaml" >&2
          ;;
      esac
    done
  fi
fi

# Compute layout plan
mapfile -t LAYOUT < <("$HERE/layout.sh" "$N")

# Track surfaces by index (0 = caller, 1..N = new panes)
declare -a SURFACES
SURFACES[0]="$CALLER_SURFACE"

spawn_pane() {
  local direction="$1" from_surface="$2"
  mux_new_split "$direction" "$from_surface" | crew_parse_surface
}

for i in $(seq 0 $((N - 1))); do
  step="${LAYOUT[$i]}"
  from_idx="$(echo "$step" | awk '{print $1}')"
  direction="$(echo "$step" | awk '{print $2}')"

  from_surface="${SURFACES[$from_idx]:-$CALLER_SURFACE}"
  new_surface="$(spawn_pane "$direction" "$from_surface" || true)"

  if [[ -z "$new_surface" ]]; then
    echo "error: could not spawn pane $((i+1))" >&2
    # Cleanup what we already made
    for s in "${SURFACES[@]:1}"; do
      [[ -n "$s" ]] && mux_close "$s" || true
    done
    exit 6
  fi

  SURFACES[$((i+1))]="$new_surface"

  # Rename the new tab/surface to reflect the pane's role/model so the user
  # can identify each pane at a glance in the workspace tab bar.
  pane_role="$(echo "$PLAN" | jq -r ".panes[$i].role // empty")"
  pane_cli="$(echo  "$PLAN" | jq -r ".panes[$i].cli // empty")"
  pane_model="$(echo "$PLAN" | jq -r ".panes[$i].model // empty")"
  label="crew#$((i+1))"
  [[ -n "$pane_cli" ]]   && label="$label · $pane_cli"
  [[ -n "$pane_model" ]] && label="$label:$pane_model"
  [[ -n "$pane_role" ]]  && label="$label — $pane_role"
  mux_rename "$new_surface" "$label" || true
done

# Activate terminal runtime: cmux requires focus-pane to initialize Ghostty PTY
for i in $(seq 1 "$N"); do
  mux_focus_pane "${SURFACES[$i]}"
  sleep 0.3
done
mux_focus_pane "$CALLER_SURFACE"
sleep 1

# Boot each CLI inside its pane with bypass flags
for i in $(seq 0 $((N - 1))); do
  pane_idx=$((i+1))
  surface="${SURFACES[$pane_idx]}"
  cli="$(echo "$PLAN" | jq -r ".panes[$i].cli")"
  model="$(echo "$PLAN" | jq -r ".panes[$i].model // empty")"
  effort="$(echo "$PLAN" | jq -r ".panes[$i].effort // empty")"

  cmd=""
  case "$cli" in
    claude)
      cmd="DISABLE_OMC=1 OMC_SKIP_HOOKS=all ENABLE_PROMPT_CACHING_1H=0 FORCE_PROMPT_CACHING_5M=0 claude --dangerously-skip-permissions"
      [[ -n "$model" ]]  && cmd="$cmd --model $model"
      [[ -n "$effort" ]] && cmd="$cmd --effort $effort"
      ;;
    codex)
      cmd="codex --dangerously-bypass-approvals-and-sandbox -c mcp_servers={}"
      [[ -n "$model" ]]  && cmd="$cmd -m $model"
      [[ -n "$effort" ]] && cmd="$cmd -c model_reasoning_effort=$effort"
      ;;
    gemini)
      cmd="gemini --approval-mode=yolo --allowed-mcp-server-names filesystem"
      [[ -n "$model" ]]  && cmd="$cmd -m $model"
      ;;
    *)
      echo "warning: unknown cli '$cli' for pane $pane_idx" >&2
      continue
      ;;
  esac

  mux_send "$surface" "$cmd"
  mux_send_key "$surface" Enter
done

# Ready-wait is deferred to run.sh: it polls each pane right before dispatching
# the prompt, so fast CLIs fire immediately without being blocked by slow ones
# (no fixed sleep, no serial max_wait).

# Spawn a report pane (below the caller) running `tail -f <log>` so the user
# sees a live stream of crew events — launch, idle, capture, done.
REPORT_SURFACE=""
REPORT_SURFACE="$(mux_new_split down "$CALLER_SURFACE" | crew_parse_surface || true)"
if [[ -n "$REPORT_SURFACE" ]]; then
  mux_rename "$REPORT_SURFACE" "crew · report ($SLUG)" || true
  sleep 0.5
  mux_send "$REPORT_SURFACE" "tail -f $LOG_FILE"
  mux_send_key "$REPORT_SURFACE" Enter
else
  echo "warning: report pane could not be spawned" >&2
fi

# Write manifest.json
MANIFEST="$(crew_manifest_path "$SLUG")"
{
  echo "$PLAN" | jq --arg slug "$SLUG" --arg caller "$CALLER_SURFACE" \
    --argjson surfaces "$(printf '%s\n' "${SURFACES[@]}" | jq -R . | jq -s .)" \
    --arg report "$REPORT_SURFACE" \
    --arg log "$LOG_FILE" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + { slug: $slug, caller_surface: $caller, surfaces: $surfaces, report_surface: $report, log_file: $log, created_at: $created }'
} > "$MANIFEST"

# workspace/latest 심링크를 이번 run 으로 갱신. share_from "prev:N" 이
# 여기를 따라간다.
WS_DIR="$(crew_workspace_dir)"
mkdir -p "$WS_DIR"
# SLUG = "ws-xxx/run-yyy" 형태이므로 run 부분만 추출해 심링크 타겟으로 쓴다
# (상대 심링크로 남겨 둬야 workspace 이동 시에도 깨지지 않음).
RUN_REL="${SLUG#${WS_SLUG}/}"
ln -snf "$RUN_REL" "$WS_DIR/latest"

echo "slug=$SLUG"
echo "workspace=$WS_SLUG"
echo "manifest=$MANIFEST"
echo "session_dir=$SESSION_DIR"
echo "report_surface=$REPORT_SURFACE"
echo "log_file=$LOG_FILE"
for i in $(seq 1 "$N"); do
  echo "pane_${i}_surface=${SURFACES[$i]}"
done
