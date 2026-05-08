#!/usr/bin/env bash
# crew common helpers
#
# crew 는 멀티플렉서(cmux/tmux) 안에 N 개의 interactive CLI pane 을 띄워서
# 메인 Claude 가 라우팅 결정을 기반으로 각 pane 에 다른 모델/티어를 배정하고
# 완료 후 결과를 합성해 보고하는 스킬.

set -u

HERE_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./mux.sh
source "$HERE_COMMON/mux.sh"

# State (per-session manifest/slots) defaults under the user's home.
# Override with CREW_STATE_DIR if you want it elsewhere.
CREW_STATE_DIR="${CREW_STATE_DIR:-$HOME/.crew/state}"
# artifact 는 cwd 에 의존하지 않도록 절대경로로 고정. override 하고 싶으면
# CREW_ARTIFACT_DIR 환경변수로 명시.
CREW_ARTIFACT_DIR="${CREW_ARTIFACT_DIR:-$HOME/.crew/artifacts}"

# 하위 호환: 기존 스크립트가 crew_require_cmux 를 호출해도 동작
crew_require_cmux() { crew_require_mux; }

crew_have() {
  command -v "$1" >/dev/null 2>&1
}

crew_timestamp() {
  date +%Y%m%d-%H%M%S
}

# Workspace 단위 slug 접두사. 같은 멀티플렉서 세션에서 호출된 모든 crew
# run 은 이 접두사 아래 모인다.
crew_workspace_slug() {
  local w
  w="$(mux_workspace_id)"
  local prefix="${w:0:8}"
  echo "ws-${prefix//[^A-Za-z0-9]/-}"
}

# 워크스페이스 디렉터리 (~/.crew/state/ws-XXX/).
crew_workspace_dir() {
  echo "${CREW_STATE_DIR}/$(crew_workspace_slug)"
}

# "latest" 심링크가 실제로 가리키는 디렉터리(존재하는 것). 없으면 빈 문자열.
# cleanup 후에는 state dir 이 사라져도 artifact dir 로 재바인딩된다.
# 끊어진 링크를 발견하면 같은 slug 의 artifact 디렉터리로 자동 복구.
crew_latest_dir() {
  local ws_dir link target
  ws_dir="$(crew_workspace_dir)"
  link="$ws_dir/latest"
  [[ -L "$link" ]] || return 0
  target="$(readlink "$link")"
  [[ -n "$target" ]] || return 0
  # 절대경로면 그대로, 상대경로면 ws_dir 기준으로 해석
  case "$target" in
    /*) : ;;
    *)  target="$ws_dir/$target" ;;
  esac
  if [[ -d "$target" ]]; then
    echo "$target"
    return 0
  fi
  # dangling — 1) 같은 run_id 의 artifact 가 있으면 그걸 우선.
  local run_id="${target##*/}"
  local artifact_ws="${CREW_ARTIFACT_DIR}/$(crew_workspace_slug)"
  local artifact="${artifact_ws}/${run_id}"
  if [[ -d "$artifact" ]]; then
    ln -snf "$artifact" "$link" 2>/dev/null || true
    echo "$artifact"
    return 0
  fi
  # 2) run_id 매치가 없으면 workspace 의 artifact 중 가장 최근으로 fallback.
  local newest
  if [[ -d "$artifact_ws" ]]; then
    newest="$(find "$artifact_ws" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
              | while read -r d; do stat -f "%m %N" "$d" 2>/dev/null; done \
              | sort -rn | awk 'NR==1 {print $2}')"
  fi
  if [[ -n "${newest:-}" && -d "$newest" ]]; then
    ln -snf "$newest" "$link" 2>/dev/null || true
    echo "$newest"
    return 0
  fi
  return 0
}

# 주어진 디렉터리(run dir 일 수도, artifact dir 일 수도) 안에서
# pane-N 의 slot md 경로를 반환. 둘 다 시도, 존재하는 것 선택.
crew_slot_in_dir() {
  local dir="$1" n="$2"
  [[ -d "$dir" ]] || { echo ""; return 1; }
  if   [[ -f "$dir/slots/pane-${n}.md" ]]; then echo "$dir/slots/pane-${n}.md"
  elif [[ -f "$dir/pane-${n}.md" ]];         then echo "$dir/pane-${n}.md"
  else echo ""; return 1
  fi
}

# "prev:N" / "prev-K:N" share 표현을 실제 slot 파일 경로로 해석.
# prev:N    → latest 가 가리키는 run 의 pane-N
# prev-K:N  → K 번째 이전 run (latest 제외) 의 pane-N.
#             state 와 artifact 를 모두 스캔해 최신 K 번째를 선택.
crew_resolve_share_ref() {
  local ref="$1"
  case "$ref" in
    prev:* )
      local n="${ref#prev:}"
      local dir
      dir="$(crew_latest_dir)"
      [[ -n "$dir" ]] || { echo ""; return 1; }
      crew_slot_in_dir "$dir" "$n"
      ;;
    prev-*:* )
      local k_part="${ref%%:*}"         # prev-2
      local k="${k_part#prev-}"         # 2
      local n="${ref##*:}"              # pane index
      local ws_slug state_ws artifact_ws
      ws_slug="$(crew_workspace_slug)"
      state_ws="${CREW_STATE_DIR}/${ws_slug}"
      artifact_ws="${CREW_ARTIFACT_DIR}/${ws_slug}"
      # state + artifact 의 run 디렉터리를 mtime 역순으로 합쳐 K 번째 선택
      local target_run
      target_run="$(
        {
          [[ -d "$state_ws"    ]] && find "$state_ws"    -maxdepth 1 -mindepth 1 -type d ! -name latest 2>/dev/null
          [[ -d "$artifact_ws" ]] && find "$artifact_ws" -maxdepth 1 -mindepth 1 -type d                2>/dev/null
        } | awk '!seen[substr($0, match($0, /[^\/]+$/))]++' \
          | while read -r d; do stat -f "%m %N" "$d" 2>/dev/null; done \
          | sort -rn \
          | awk -v k="$k" 'NR==k {print $2}'
      )"
      [[ -n "$target_run" ]] || { echo ""; return 1; }
      crew_slot_in_dir "$target_run" "$n"
      ;;
    * )
      echo ""
      return 1
      ;;
  esac
}

# Parse surface ID from mux output. cmux: "surface:NN", tmux: "%N" (그대로 통과).
crew_parse_surface() {
  case "$CREW_MUX" in
    cmux) awk '/surface:[0-9]+/ { for (i=1; i<=NF; i++) if ($i ~ /^surface:/) { print $i; exit } }' ;;
    tmux) awk 'NF {print $1; exit}' ;;
    *)    cat ;;
  esac
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
    codex)  pattern='OpenAI Codex|/model to change' ;;
    gemini) pattern='Type your message|@path/to/file|Signed in with Google|gemini-' ;;
    *)      return 0 ;;
  esac
  local start=$(date +%s)
  while :; do
    local screen
    screen="$(mux_read_screen "$surface" || true)"
    if echo "$screen" | grep -qE "$pattern"; then
      sleep 1
      return 0
    fi
    if [[ "$cli" == "gemini" ]]; then
      if echo "$screen" | grep -qi "trust the files in this folder"; then
        mux_send_key "$surface" Enter || true
      fi
      if echo "$screen" | grep -qE "sandbox" && echo "$screen" | grep -qE "no sandbox"; then
        mux_send_key "$surface" Down || true
        sleep 0.3
        mux_send_key "$surface" Enter || true
      fi
    fi
    if (( $(date +%s) - start >= max_wait )); then
      return 1
    fi
    sleep "$poll"
  done
}
