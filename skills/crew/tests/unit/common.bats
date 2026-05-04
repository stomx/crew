#!/usr/bin/env bats
# Tests for pure-bash helpers in common.sh. These don't require cmux.

COMMON="${BATS_TEST_DIRNAME}/../../scripts/common.sh"

setup() {
  # Load helpers into the test shell. common.sh uses `set -u` so we guard.
  set +u
  source "$COMMON"
  set -u
}

@test "common.sh sources cleanly" {
  [ -f "$COMMON" ]
}

@test "crew_timestamp produces YYYYMMDD-HHMMSS" {
  run crew_timestamp
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{8}-[0-9]{6}$ ]]
}

@test "crew_parse_surface extracts surface ref" {
  output=$(echo 'OK surface:42 workspace:7' | crew_parse_surface)
  [ "$output" = "surface:42" ]
}

@test "crew_parse_surface returns empty on no match" {
  output=$(echo 'no surface here' | crew_parse_surface)
  [ -z "$output" ]
}

@test "crew_parse_surface ignores leading garbage" {
  output=$(echo 'garbage foo bar surface:99 trailing' | crew_parse_surface)
  [ "$output" = "surface:99" ]
}

@test "crew_session_dir composes correct path" {
  run crew_session_dir my-slug
  [ "$status" -eq 0 ]
  [[ "$output" == "$CREW_STATE_DIR/my-slug" ]]
}

@test "crew_slot_path uses session dir + slots/pane-N.md" {
  run crew_slot_path slug42 3
  [ "$status" -eq 0 ]
  [[ "$output" == "$CREW_STATE_DIR/slug42/slots/pane-3.md" ]]
}

@test "crew_manifest_path uses session dir + manifest.json" {
  run crew_manifest_path slugXYZ
  [ "$status" -eq 0 ]
  [[ "$output" == "$CREW_STATE_DIR/slugXYZ/manifest.json" ]]
}

@test "crew_log_path uses session dir + crew.log" {
  run crew_log_path slugABC
  [ "$status" -eq 0 ]
  [[ "$output" == "$CREW_STATE_DIR/slugABC/crew.log" ]]
}

@test "crew_artifact_path uses artifact dir pattern" {
  # crew_artifact_path is not defined in common.sh anymore; this test was
  # ported from ccg-panel. We use crew_synthesis_path instead which is defined.
  run crew_synthesis_path slugZ
  [ "$status" -eq 0 ]
  [[ "$output" == *.omc/artifacts/crew/slugZ/synthesis.md ]]
}

@test "CREW_STATE_DIR default under ~/.crew" {
  [ -n "${CREW_STATE_DIR:-}" ]
  [[ "$CREW_STATE_DIR" == */.crew/state ]]
}

@test "CREW_ARTIFACT_DIR default uses .omc/artifacts/crew" {
  [ -n "${CREW_ARTIFACT_DIR:-}" ]
  [[ "$CREW_ARTIFACT_DIR" == *.omc/artifacts/crew ]]
}

@test "crew_have detects missing command" {
  run crew_have definitely-does-not-exist-xyz
  [ "$status" -ne 0 ]
}

@test "crew_have detects existing command" {
  run crew_have bash
  [ "$status" -eq 0 ]
}
