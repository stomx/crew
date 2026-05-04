#!/usr/bin/env bash
# crew keyword router — short-name slash commands without the plugin prefix.
#
# Claude Code hook model: UserPromptSubmit hooks receive the user's raw input
# on stdin (JSON: { "prompt": "..." }) and can emit `additionalContext` that
# nudges Claude to invoke a specific skill.
#
# Triggers:
#   /crew [args]         → /crew:crew
#   /crew-setup          → /crew:setup
#   "crew" 키워드 자연어   → /crew:crew (hint only)
#
# Keep this fast — 3s timeout in hooks.json.

set -euo pipefail

# Read stdin JSON; if jq missing or input empty, exit quietly.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

PAYLOAD="$(cat)"
PROMPT="$(echo "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null || true)"

[[ -z "$PROMPT" ]] && exit 0

emit_context() {
  local target="$1" reason="$2"
  # hookSpecificOutput.additionalContext is appended to the model turn
  # so Claude sees the routing hint without disturbing the user's prompt.
  jq -cn \
    --arg ctx "[crew routing] ${reason}
Preferred skill invocation: ${target}
Fallback: open the skill SKILL.md file at \$CLAUDE_PLUGIN_ROOT/skills/<name>/SKILL.md and follow its instructions." \
    '{hookSpecificOutput: {additionalContext: $ctx}}'
}

# Match explicit slash forms first (most specific)
case "$PROMPT" in
  "/crew-setup"*|"/crew setup"*)
    emit_context "/crew:setup" "detected /crew-setup — onboarding skill"
    exit 0
    ;;
  "/crew "*|"/crew")
    emit_context "/crew:crew" "detected /crew — visible multi-pane sub-agent"
    exit 0
    ;;
esac

# Natural-language triggers (kept loose, Claude can still choose not to route).
lower="$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')"
case "$lower" in
  *"crew로 나눠"*|*"crew 로 나눠"*|*"crew 써줘"*|*"crew 로 돌려"*|*"crew 시작"*)
    emit_context "/crew:crew" "natural-language trigger matched crew"
    exit 0
    ;;
esac

exit 0
