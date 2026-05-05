#!/usr/bin/env bash
# crew common helpers (cmux-native, inspired by ccg-panel)
#
# crew 는 cmux workspace 안에 N 개의 interactive CLI pane 을 띄워서
# 메인 Claude 가 라우팅 결정을 기반으로 각 pane 에 다른 모델/티어를 배정하고
# 완료 후 결과를 합성해 보고하는 스킬.

set -u

# State (per-session manifest/slots) defaults under the user's home.
# Override with CREW_STATE_DIR if you want it elsewhere.
CREW_STATE_DIR="${CREW_STATE_DIR:-$HOME/.crew/state}"
# artifact 는 cwd 에 의존하지 않도록 절대경로로 고정. override 하고 싶으면
# CREW_ARTIFACT_DIR 환경변수로 명시.
CREW_ARTIFACT_DIR="${CREW_ARTIFACT_DIR:-$HOME/.crew/artifacts}"

crew_require_cmux() {
  if ! command -v cmux >/dev/null 2>&1; then
    echo "error: cmux CLI not found on PATH" >&2
    echo "  hint: install cmux (macOS: cmux.app), or add its bin dir to PATH." >&2
    return 2
  fi
  if [[ -z "${CMUX_WORKSPACE_ID:-}" ]]; then
    echo "error: CMUX_WORKSPACE_ID not set" >&2
    echo "  hint: run this from inside a cmux workspace pane. Opening Claude Code" >&2
    echo "  in a regular terminal will not work — cmux must be the outer shell." >&2
    return 3
  fi
}

crew_have() {
  command -v "$1" >/dev/null 2>&1
}

crew_timestamp() {
  date +%Y%m%d-%H%M%S
}

# Workspace 단위 slug 접두사. 같은 cmux workspace 에서 호출된 모든 crew
# run 은 이 접두사 아래 모인다. CMUX_WORKSPACE_ID 가 없으면 'default'.
crew_workspace_slug() {
  local w="${CMUX_WORKSPACE_ID:-default}"
  # UUID 앞 8자만 (가독성). 특수 문자는 '-' 로 치환.
  local prefix="${w:0:8}"
  echo "ws-${prefix//[^A-Za-z0-9]/-}"
}

# 워크스페이스 디렉터리 (~/.crew/state/ws-XXX/).
crew_workspace_dir() {
  echo "${CREW_STATE_DIR}/$(crew_workspace_slug)"
}

# "latest" 심링크가 가리키는 run slug (없으면 빈 문자열).
crew_latest_run() {
  local link="$(crew_workspace_dir)/latest"
  [[ -L "$link" ]] || return 0
  local target
  target="$(readlink "$link")"
  # latest 는 "run-<timestamp>..." 같은 상대경로 한 조각이어야 함.
  echo "$(crew_workspace_slug)/${target}"
}

# "prev:N" / "prev-2:N" 같은 share 표현을 실제 slot 파일 경로로 해석.
# "prev:N" → latest 의 pane-N
# "prev-K:N" → K 번 전 run 의 pane-N
# 숫자만 → 현재 run 의 pane-N (기존 표현, 그대로 반환해 호출측이 처리)
# 반환: 성공시 절대경로, 실패시 공문자 + stderr 경고.
crew_resolve_share_ref() {
  local ref="$1"
  case "$ref" in
    prev:* )
      local n="${ref#prev:}"
      local latest
      latest="$(crew_latest_run)"
      [[ -n "$latest" ]] || { echo "" ; return 1; }
      echo "${CREW_STATE_DIR}/${latest}/slots/pane-${n}.md"
      ;;
    prev-*:* )
      local k_part="${ref%%:*}"         # prev-2
      local k="${k_part#prev-}"         # 2
      local n="${ref##*:}"              # pane index
      local ws_dir runs
      ws_dir="$(crew_workspace_dir)"
      # runs 디렉터리의 모든 서브폴더를 mtime 역순으로 나열, K 번째를 고름.
      # latest 심링크 자체는 제외.
      local target_run
      target_run="$(find "$ws_dir" -maxdepth 1 -mindepth 1 -type d -print0 \
                    2>/dev/null | xargs -0 -n1 -I{} bash -c 'stat -f "%m %N" "$1"' _ {} \
                    | sort -rn | awk -v k="$k" 'NR==k {print $2}')"
      [[ -n "$target_run" ]] || { echo "" ; return 1; }
      echo "${target_run}/slots/pane-${n}.md"
      ;;
    * )
      echo ""
      return 1
      ;;
  esac
}

# Parse "surface:NN" out of a cmux response line.
crew_parse_surface() {
  awk '/surface:[0-9]+/ { for (i=1; i<=NF; i++) if ($i ~ /^surface:/) { print $i; exit } }'
}

# Session dir lives under state/<slug>/
crew_session_dir() {
  local slug="$1"
  echo "${CREW_STATE_DIR}/${slug}"
}

crew_slot_path() {
  local slug="$1" pane_idx="$2"
  echo "$(crew_session_dir "$slug")/slots/pane-${pane_idx}.md"
}

crew_manifest_path() {
  local slug="$1"
  echo "$(crew_session_dir "$slug")/manifest.json"
}

crew_synthesis_path() {
  local slug="$1"
  echo "${CREW_ARTIFACT_DIR}/${slug}/synthesis.md"
}

crew_log_path() {
  local slug="$1"
  echo "$(crew_session_dir "$slug")/crew.log"
}

# Wait until a pane's TUI shows its "prompt-ready" marker. Poll interval
# defaults to 0.5s so dispatch fires the instant a CLI is ready — no fixed
# sleep. Returns 0 on detection, 1 on timeout.
# Usage: crew_wait_ready <surface> <cli> [max_wait=30]
crew_wait_ready() {
  local surface="$1" cli="$2" max_wait="${3:-30}"
  local poll="${CREW_POLL_INTERVAL:-0.5}"
  local pattern
  case "$cli" in
    claude) pattern='bypass permissions on|Claude Code v' ;;
    codex)  pattern='/model to change|OpenAI Codex' ;;
    gemini) pattern='Type your message|@path/to/file' ;;
    *)      return 0 ;;
  esac
  local start=$(date +%s)
  while :; do
    local screen
    screen="$(cmux read-screen --surface "$surface" 2>/dev/null || true)"
    if echo "$screen" | grep -qE "$pattern"; then
      return 0
    fi
    # Gemini trust dialog can appear mid-boot — dismiss on the fly.
    if [[ "$cli" == "gemini" ]] && echo "$screen" | grep -qi "trust the files in this folder"; then
      cmux send-key --surface "$surface" Enter >/dev/null 2>&1 || true
    fi
    if (( $(date +%s) - start >= max_wait )); then
      return 1
    fi
    sleep "$poll"
  done
}
