#!/usr/bin/env bats
# Ensures every crew script parses as valid bash. This alone catches most
# regressions like the ones we hit this session (-n "0" mistake, unclosed
# here-doc, missing quote etc).

SCRIPTS_DIR="${BATS_TEST_DIRNAME}/../../scripts"

@test "all shell scripts exist" {
  [ -d "$SCRIPTS_DIR" ]
  run bash -c "ls '$SCRIPTS_DIR'/*.sh | wc -l | tr -d ' '"
  [ "$status" -eq 0 ]
  [ "$output" -ge 10 ]
}

@test "every .sh file passes bash -n" {
  local failed=0
  for f in "$SCRIPTS_DIR"/*.sh; do
    if ! bash -n "$f" 2>&1; then
      echo "syntax fail: $f"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ]
}

@test "every .sh file is executable" {
  for f in "$SCRIPTS_DIR"/*.sh; do
    [ -x "$f" ] || { echo "not executable: $f"; return 1; }
  done
}

@test "every .sh file starts with bash shebang" {
  for f in "$SCRIPTS_DIR"/*.sh; do
    first_line="$(head -1 "$f")"
    case "$first_line" in
      '#!/usr/bin/env bash'|'#!/bin/bash') ;;
      *) echo "bad shebang in $f: $first_line"; return 1 ;;
    esac
  done
}
