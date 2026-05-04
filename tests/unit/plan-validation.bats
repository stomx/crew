#!/usr/bin/env bats
# run.sh validates the plan JSON before launching panes. These tests hit
# that validation path without actually touching cmux (the crew_require_cmux
# check will fail fast but we only care about the validation logic here).
#
# Strategy: stub cmux so crew_require_cmux passes, then let run.sh perform
# its JSON validation. We intercept before launch.sh would be invoked by
# making launch.sh a stub that immediately exits (via PATH override).

RUN_SH="${BATS_TEST_DIRNAME}/../../scripts/run.sh"

setup() {
  export TMPD="$(mktemp -d)"
  # Fake cmux binary so crew_require_cmux doesn't exit
  export PATH="$TMPD/bin:$PATH"
  mkdir -p "$TMPD/bin"
  cat > "$TMPD/bin/cmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMPD/bin/cmux"
  export CMUX_WORKSPACE_ID="test-workspace"
}

teardown() {
  rm -rf "$TMPD"
}

make_plan_file() {
  local body="$1"
  local f="$TMPD/plan.json"
  printf '%s' "$body" > "$f"
  echo "$f"
}

make_prompt_file() {
  local f="$TMPD/prompt-$RANDOM.txt"
  echo "test prompt" > "$f"
  echo "$f"
}

@test "plan with invalid share_from ref (out of range) is rejected" {
  local pf
  pf=$(make_prompt_file)
  local plan
  plan=$(make_plan_file "$(cat <<EOF
{"panes":[
{"id":1,"cli":"claude","prompt_file":"$pf","stage":1},
{"id":2,"cli":"codex","prompt_file":"$pf","stage":2,"share_from":[99]}
]}
EOF
)")
  run "$RUN_SH" "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid ref: 99"* ]]
}

@test "plan with self-referencing share_from is rejected" {
  local pf
  pf=$(make_prompt_file)
  local plan
  plan=$(make_plan_file "$(cat <<EOF
{"panes":[
{"id":1,"cli":"claude","prompt_file":"$pf","stage":1,"share_from":[1]}
]}
EOF
)")
  run "$RUN_SH" "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"includes itself"* ]]
}

@test "plan sharing from same-stage pane is rejected" {
  local pf
  pf=$(make_prompt_file)
  local plan
  plan=$(make_plan_file "$(cat <<EOF
{"panes":[
{"id":1,"cli":"claude","prompt_file":"$pf","stage":1},
{"id":2,"cli":"codex","prompt_file":"$pf","stage":1,"share_from":[1]}
]}
EOF
)")
  run "$RUN_SH" "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source stage must be earlier"* ]]
}

@test "plan sharing from later-stage pane is rejected" {
  local pf
  pf=$(make_prompt_file)
  local plan
  plan=$(make_plan_file "$(cat <<EOF
{"panes":[
{"id":1,"cli":"claude","prompt_file":"$pf","stage":2,"share_from":[2]},
{"id":2,"cli":"codex","prompt_file":"$pf","stage":3}
]}
EOF
)")
  run "$RUN_SH" "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source stage must be earlier"* ]]
}

@test "plan with missing prompt_file is rejected" {
  local plan
  plan=$(make_plan_file '{"panes":[{"id":1,"cli":"claude","stage":1}]}')
  run "$RUN_SH" "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing prompt_file"* ]]
}

@test "plan with non-existent prompt_file is rejected" {
  local plan
  plan=$(make_plan_file '{"panes":[{"id":1,"cli":"claude","prompt_file":"/nope/nope","stage":1}]}')
  run "$RUN_SH" "$plan"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}
