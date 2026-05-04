#!/usr/bin/env bash
# Usage: layout.sh <N>
# Emits a split plan for N child panes, one line per step.
#
# Line format: <from_idx> <direction>
#   from_idx   = index of existing pane to split (0=caller, 1..i=prior panes)
#   direction  = left | right | up | down
#
# Strategy: "column-major grid".
# - Every 3 children form one vertical column to the right of the caller.
# - Column 1: right of caller, then down, down
# - Column 2: right of column-1 top, then down, down
# - etc.
#
# Gives a consistent grid regardless of N and keeps caller width reasonable.
# The report pane is spawned separately (in launch.sh) as a `down` split from
# the caller, so it always shows as a bottom strip.

set -euo pipefail

N="${1:?number of panes required}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 1 )); then
  echo "error: N must be a positive integer" >&2
  exit 1
fi

COL_HEIGHT=3  # panes per column

col_top_idx=0  # index of pane that starts the current column (0 = caller)

for (( i=1; i<=N; i++ )); do
  # Position within column (0 = top of col, 1..COL_HEIGHT-1 = below)
  pos_in_col=$(( (i - 1) % COL_HEIGHT ))

  if (( pos_in_col == 0 )); then
    # New column: split to the right of the current column's anchor.
    # Column 1's anchor is caller (idx 0). Column 2's anchor is the top of column 1 (idx 1). etc.
    if (( i == 1 )); then
      from=0                  # caller
    else
      from=$(( i - COL_HEIGHT )) # top of previous column
    fi
    echo "$from right"
    col_top_idx=$i
  else
    # Continue current column: split down from previous pane in this column
    echo "$((i - 1)) down"
  fi
done
