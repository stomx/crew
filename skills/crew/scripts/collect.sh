#!/usr/bin/env bash
# Usage: collect.sh <slug>
# Gathers all pane slots into a single artifact bundle under
#   .omc/artifacts/crew/<slug>/
# Copies per-pane slots + writes an index.md pointing at them.
# Main Claude then reads the slots and writes synthesis.md on top.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "$HERE/common.sh"

command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 3; }

SLUG="${1:?slug required}"
MANIFEST="$(crew_manifest_path "$SLUG")"
[[ -f "$MANIFEST" ]] || { echo "error: manifest missing: $MANIFEST" >&2; exit 2; }

ARTIFACT_ROOT="${CREW_ARTIFACT_DIR}/${SLUG}"
mkdir -p "$ARTIFACT_ROOT"

N=$(jq '.panes | length' "$MANIFEST")

# Copy slots into artifact root
for i in $(seq 1 "$N"); do
  src="$(crew_slot_path "$SLUG" "$i")"
  if [[ -f "$src" ]]; then
    cp "$src" "$ARTIFACT_ROOT/pane-${i}.md"
  fi
done

# Copy manifest for history
cp "$MANIFEST" "$ARTIFACT_ROOT/manifest.json"

# Write index
INDEX="$ARTIFACT_ROOT/index.md"
{
  echo "# crew session $SLUG"
  echo
  echo "Created: $(jq -r '.created_at' "$MANIFEST")"
  echo "Panes: $N"
  echo
  echo "## Panes"
  for i in $(seq 0 $((N - 1))); do
    pane_idx=$((i + 1))
    cli="$(jq -r --argjson i "$i" '.panes[$i].cli' "$MANIFEST")"
    model="$(jq -r --argjson i "$i" '.panes[$i].model // ""' "$MANIFEST")"
    effort="$(jq -r --argjson i "$i" '.panes[$i].effort // ""' "$MANIFEST")"
    role="$(jq -r --argjson i "$i" '.panes[$i].role // ""' "$MANIFEST")"
    line="- **pane-$pane_idx** — $cli"
    [[ -n "$model" ]]  && line="$line / \`$model\`"
    [[ -n "$effort" ]] && line="$line / effort=$effort"
    [[ -n "$role" ]]   && line="$line — $role"
    echo "$line"
    [[ -f "$ARTIFACT_ROOT/pane-${pane_idx}.md" ]] \
      && echo "  - capture: [pane-${pane_idx}.md](pane-${pane_idx}.md)"
  done
  echo
  echo "## Synthesis"
  echo
  echo "Main Claude writes \`synthesis.md\` in this directory after reading each pane slot."
} > "$INDEX"

echo "artifact_root=$ARTIFACT_ROOT"
echo "index=$INDEX"
