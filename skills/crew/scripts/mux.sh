#!/usr/bin/env bash
# mux.sh — multiplexer adapter (cmux / tmux)
#
# 환경 자동 감지 후 통일된 인터페이스를 제공한다.
# common.sh 가 source 하며, 모든 스크립트는 mux_* 함수만 호출한다.

# --- 환경 감지 ---

CREW_MUX=""
if [[ -n "${CMUX_WORKSPACE_ID:-}" ]]; then
  CREW_MUX=cmux
elif [[ -n "${TMUX:-}" ]]; then
  CREW_MUX=tmux
else
  CREW_MUX=inline
fi

# --- 검증 ---

crew_require_mux() {
  case "$CREW_MUX" in
    cmux)
      if ! command -v cmux >/dev/null 2>&1; then
        echo "error: cmux CLI not found on PATH" >&2
        echo "  hint: install cmux (macOS: cmux.com), or add its bin dir to PATH." >&2
        return 2
      fi
      ;;
    tmux)
      if ! command -v tmux >/dev/null 2>&1; then
        echo "error: tmux not found on PATH" >&2
        return 2
      fi
      ;;
    inline)
      return 0
      ;;
    *)
      echo "error: no multiplexer session detected" >&2
      echo "  hint: run from inside a cmux workspace or tmux session." >&2
      return 3
      ;;
  esac
}

# --- caller surface (현재 pane) ---

mux_caller_surface() {
  case "$CREW_MUX" in
    cmux)   echo "${CMUX_SURFACE_ID:-}" ;;
    tmux)   tmux display-message -p '#{pane_id}' 2>/dev/null ;;
    inline) echo "inline:$$" ;;
  esac
}

# --- workspace ID ---

mux_workspace_id() {
  case "$CREW_MUX" in
    cmux)   echo "${CMUX_WORKSPACE_ID:-default}" ;;
    tmux)   tmux display-message -p '#{session_name}' 2>/dev/null || echo "default" ;;
    inline) echo "${CREW_INLINE_WORKSPACE:-inline}" ;;
  esac
}

# --- split (새 pane 생성) ---
# 반환: surface ID (cmux: "surface:NN" 에서 추출, tmux: "%N")

mux_new_split() {
  local direction="$1" from_surface="$2"
  case "$CREW_MUX" in
    cmux)
      cmux new-split "$direction" --surface "$from_surface" 2>&1 \
        | awk '/surface:[0-9]+/ { for (i=1; i<=NF; i++) if ($i ~ /^surface:/) { print $i; exit } }'
      ;;
    tmux)
      local flags=""
      case "$direction" in
        down)  flags="-v" ;;
        up)    flags="-v -b" ;;
        right) flags="-h" ;;
        left)  flags="-h -b" ;;
        *)     flags="-v" ;;
      esac
      tmux split-window $flags -t "$from_surface" -P -F '#{pane_id}' 2>&1
      ;;
  esac
}

# --- send text ---

mux_send() {
  local surface="$1" text="$2"
  case "$CREW_MUX" in
    cmux) cmux send --surface "$surface" "$text" >/dev/null ;;
    tmux) tmux send-keys -t "$surface" -l "$text" >/dev/null ;;
  esac
}

# --- send key (Enter, Escape 등) ---

mux_send_key() {
  local surface="$1" key="$2"
  case "$CREW_MUX" in
    cmux) cmux send-key --surface "$surface" "$key" >/dev/null 2>&1 ;;
    tmux) tmux send-keys -t "$surface" "$key" >/dev/null 2>&1 ;;
  esac
}

# --- read viewport ---

mux_read_screen() {
  local surface="$1"
  case "$CREW_MUX" in
    cmux) cmux read-screen --surface "$surface" 2>/dev/null ;;
    tmux) tmux capture-pane -t "$surface" -p 2>/dev/null ;;
  esac
}

# --- read scrollback ---

mux_read_scrollback() {
  local surface="$1" lines="${2:-200}"
  case "$CREW_MUX" in
    cmux) cmux read-screen --surface "$surface" --scrollback --lines "$lines" 2>/dev/null ;;
    tmux) tmux capture-pane -t "$surface" -p -S "-${lines}" 2>/dev/null ;;
  esac
}

# --- close pane ---

mux_close() {
  local surface="$1"
  case "$CREW_MUX" in
    cmux) cmux close-surface --surface "$surface" >/dev/null 2>&1 ;;
    tmux) tmux kill-pane -t "$surface" >/dev/null 2>&1 ;;
  esac
}

# --- rename tab/pane ---

mux_rename() {
  local surface="$1" name="$2"
  case "$CREW_MUX" in
    cmux) cmux rename-tab --surface "$surface" "$name" >/dev/null 2>&1 ;;
    tmux) tmux select-pane -t "$surface" -T "$name" >/dev/null 2>&1 ;;
  esac
}

# --- list panels (orphan 정리용) ---

mux_list_panels() {
  case "$CREW_MUX" in
    cmux) cmux list-panels 2>/dev/null ;;
    tmux) tmux list-panes -a -F 'surface:#{pane_id} #{pane_current_command} #{pane_title}' 2>/dev/null ;;
  esac
}
