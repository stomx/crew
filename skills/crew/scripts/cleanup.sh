#!/usr/bin/env bash
# Usage:
#   cleanup.sh <slug>       Close all panes for the session and remove state dir.
#   cleanup.sh all          Close every tracked crew session.
#
# Artifacts under .omc/artifacts/crew/<slug>/ are KEPT (history documentation).
# Only session state (panes + manifest under ~/.claude/skills/crew/state/) is removed.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

crew_require_cmux
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

close_from_manifest() {
  local slug="$1"
  local manifest
  manifest="$(crew_manifest_path "$slug")"
  if [[ ! -f "$manifest" ]]; then
    echo "manifest missing: $manifest" >&2
    return 0
  fi

  # NOTE: We do NOT touch the main (caller) surface during cleanup. Previous
  # versions sent Escape to clear whisper-text residue, but that blocked the
  # cmux RPC when main was running a tool call. If CREW_WHISPER_MAIN was on
  # and left text in the main textarea, the user can press Escape themselves.

  # surfaces[0] is caller — DO NOT close. Close surfaces[1..N] (child panes).
  local surfaces
  surfaces="$(jq -r '.surfaces[1:] | .[]' "$manifest")"
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if cmux close-surface --surface "$s" >/dev/null 2>&1; then
      echo "closed child: $s"
    else
      echo "could not close child: $s (already gone?)"
    fi
  done <<< "$surfaces"

  # Close report pane if present
  local report_surface
  report_surface="$(jq -r '.report_surface // empty' "$manifest")"
  if [[ -n "$report_surface" ]]; then
    if cmux close-surface --surface "$report_surface" >/dev/null 2>&1; then
      echo "closed report: $report_surface"
    else
      echo "could not close report: $report_surface (already gone?)"
    fi
  fi

  # Rebind workspace "latest" symlink to the artifact copy of this run before
  # we remove the state dir. prev:N share references keep working after cleanup.
  # slug format: "ws-xxx/run-yyy" → ws = "ws-xxx", run = "run-yyy"
  local ws_slug run_id ws_dir target
  if [[ "$slug" == */* ]]; then
    ws_slug="${slug%%/*}"
    run_id="${slug#*/}"
    ws_dir="${CREW_STATE_DIR}/${ws_slug}"
    target="${CREW_ARTIFACT_DIR}/${ws_slug}/${run_id}"
    if [[ -d "$target" ]]; then
      # Point latest at the artifact dir (absolute path). crew_resolve_share_ref
      # already treats latest as a general slot-source pointer.
      ln -snf "$target" "$ws_dir/latest" 2>/dev/null || true
    fi
  fi

  # Remove session state dir (artifact dir under ~/.crew/artifacts/ is kept)
  rm -rf "$(crew_session_dir "$slug")"
}

# Fallback for when state dir is lost but panes still exist:
# close any surface that looks like a crew-tracked one (tail -f of crew.log,
# or spawned with known CLIs as first process). Best-effort.
close_orphan_panes() {
  # Close any pane whose visible process is `tail -f .../crew.log` — that's a
  # stray report pane.
  cmux list-panels 2>/dev/null | awk '/tail -f .*\/crew\.log/ { for (i=1; i<=NF; i++) if ($i ~ /^surface:/) { print $i; exit } }' \
    | while read -r s; do
        [[ -z "$s" ]] && continue
        if cmux close-surface --surface "$s" >/dev/null 2>&1; then
          echo "closed orphan report: $s"
        fi
      done
}

TARGET="${1:-}"
case "$TARGET" in
  ""|-h|--help)
    echo "usage: cleanup.sh <slug|all|orphan>" >&2
    exit 1
    ;;
  all)
    # state/<ws-slug>/<run-id>/manifest.json 구조를 훑는다. 과거 평면 구조
    # (state/<slug>/manifest.json) 도 같은 find 로 모두 잡힘.
    any=0
    while IFS= read -r -d '' manifest; do
      any=1
      # manifest 경로에서 state/ 이후의 slug 를 추출 ("ws-xxx/run-yyy").
      relpath="${manifest#$CREW_STATE_DIR/}"
      slug="${relpath%/manifest.json}"
      echo "--- $slug ---"
      close_from_manifest "$slug"
    done < <(find "$CREW_STATE_DIR" -type f -name manifest.json -print0 2>/dev/null)
    close_orphan_panes
    if (( any == 0 )); then
      echo "no crew sessions found (orphan scan done)"
    fi
    ;;
  orphan)
    close_orphan_panes
    ;;
  *)
    close_from_manifest "$TARGET"
    ;;
esac
