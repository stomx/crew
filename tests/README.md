# crew tests

Developer-facing tests. **Not needed for regular crew users.**

## Unit tests (automated)

Require [bats-core](https://github.com/bats-core/bats-core):

```bash
~/.claude/skills/crew/tests/run-tests.sh
```

If bats isn't installed, the runner prints install options for macOS /
Linux / Node / standalone and exits without error-nagging about it.

Coverage:

- `syntax.bats` — every script passes `bash -n`, is executable, has a proper shebang
- `layout.bats` — `layout.sh` emits a valid column-major split plan for N=1..10
- `common.bats` — pure helpers (timestamp, parse_surface, path composers, CLI presence)

These run in under a second and catch the regressions we actually hit
(unquoted logic, bad here-doc, parse mistakes, default env drift).

## Integration tests (manual)

cmux is a native app with a Unix-socket RPC; we don't mock it. The
following checklist runs end-to-end inside a real cmux workspace.

Run each scenario, confirm the pane appears/answers/closes, and note
the elapsed time:

1. **Single claude pane**: `claude haiku low` → "한 줄로 2+2?"
   - expect: answer "4", pane closes after view_secs
2. **Single codex pane**: `codex gpt-5.5 low` → "한 줄로 3*7?"
   - expect: "• 21"
3. **Single gemini pane**: `gemini 2.5-flash` → "한 줄로 10-6?"
   - expect: "✦ 4"
4. **2-pane parallel**: claude + codex
5. **3-pane parallel**: claude + codex + gemini  (<1min total)
6. **staged**: stage 1 claude → stage 2 codex  (sequential)
7. **slot share**: claude picks animal → codex uses it  (pane-1 answer reaches pane-2)
8. **cleanup**: abort with Ctrl-C mid-run  (trap must close panes)
9. **concurrent runs**: launch two run.sh in parallel  (PID-scoped tmp files)
10. **orphan cleanup**: `scripts/cleanup.sh orphan` removes stray report panes

If any scenario fails, write a failing bats test before fixing the code.
