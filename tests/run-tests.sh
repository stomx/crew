#!/usr/bin/env bash
# Usage: run-tests.sh
# Runs bats unit tests if bats is installed, otherwise prints install guide.
#
# Design principle: bats is a DEVELOPER tool (needed only when modifying
# crew scripts). Regular crew USERS do not need bats. So we never auto-install
# it — we point the developer at the right command for their environment.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  cat >&2 <<EOF
bats not installed. Pick one:

  macOS (Homebrew):          brew install bats-core
  Node.js users:             npm install -g bats
  Standalone (any *nix):     git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats \\
                             && sudo /tmp/bats/install.sh /usr/local
  User-local (no sudo):      git clone --depth 1 https://github.com/bats-core/bats-core.git ~/.bats \\
                             && ~/.bats/install.sh ~/.local \\
                             && export PATH=~/.local/bin:\$PATH

After install, run:  $0
EOF
  exit 2
fi

UNIT_DIR="$HERE/unit"
if [[ ! -d "$UNIT_DIR" ]] || [[ -z "$(ls -A "$UNIT_DIR"/*.bats 2>/dev/null)" ]]; then
  echo "no unit tests found in $UNIT_DIR" >&2
  exit 3
fi

exec bats "$UNIT_DIR"
