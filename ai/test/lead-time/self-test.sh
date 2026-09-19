#!/usr/bin/env bash
# self-test for ai/bin/lead-time — discovered and run by harness-gate.
# Delegates to the tool's own pure-logic --self-test (no network, no git).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../../bin/lead-time"

if [ ! -x "$bin" ]; then
  echo "lead-time self-test: FAIL — $bin missing or not executable" >&2
  echo "Fix: chmod +x ai/bin/lead-time" >&2
  exit 1
fi

exec ruby "$bin" --self-test
