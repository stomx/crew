#!/usr/bin/env bats
# layout.sh emits an N-line plan. Each line: "<from_idx> <direction>".
# Column-major grid: 3 panes per column, right then down-down-down.

LAYOUT="${BATS_TEST_DIRNAME}/../../scripts/layout.sh"

@test "layout.sh exists" {
  [ -x "$LAYOUT" ]
}

@test "layout rejects non-numeric N" {
  run "$LAYOUT" abc
  [ "$status" -ne 0 ]
}

@test "layout rejects zero" {
  run "$LAYOUT" 0
  [ "$status" -ne 0 ]
}

@test "layout rejects missing arg" {
  run "$LAYOUT"
  [ "$status" -ne 0 ]
}

@test "N=1 emits exactly 1 line" {
  run "$LAYOUT" 1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "0 right" ]
}

@test "N=3 fills first column" {
  run "$LAYOUT" 3
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "0 right" ]
  [ "${lines[1]}" = "1 down" ]
  [ "${lines[2]}" = "2 down" ]
}

@test "N=4 starts second column" {
  run "$LAYOUT" 4
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[3]}" = "1 right" ]
}

@test "N=6 fills two full columns" {
  run "$LAYOUT" 6
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[3]}" = "1 right" ]
  [ "${lines[4]}" = "4 down" ]
  [ "${lines[5]}" = "5 down" ]
}

@test "N=7 opens third column from pane 4" {
  run "$LAYOUT" 7
  [ "${#lines[@]}" -eq 7 ]
  [ "${lines[6]}" = "4 right" ]
}

@test "N=10 produces exactly 10 steps" {
  run "$LAYOUT" 10
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 10 ]
}

@test "every line is '<int> <direction>'" {
  for n in 1 2 3 4 5 6 7 8 9 10; do
    run "$LAYOUT" "$n"
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
      [[ "$line" =~ ^[0-9]+\ (left|right|up|down)$ ]] || {
        echo "bad line for N=$n: '$line'"
        return 1
      }
    done <<< "$output"
  done
}

@test "from_idx is always < current pane index" {
  # Split cannot reference a pane that doesn't exist yet.
  # (Note: ((i++)) returns 0's exit status when i was 0, which bats reads as
  #  failure under -e. Use i=$((i+1)) instead.)
  for n in 1 2 3 4 5 6 7 8 9 10; do
    run "$LAYOUT" "$n"
    local i=0
    while IFS= read -r line; do
      local from
      from=$(echo "$line" | awk '{print $1}')
      # After step i, new pane has index i+1. Allowed parents: 0..i
      if (( from > i )); then
        echo "N=$n step $i references future pane $from"
        return 1
      fi
      i=$((i+1))
    done <<< "$output"
  done
}
