#!/usr/bin/env bash
# self-test for ai/bin/contention-census — discovered and run by harness-gate.
# Delegates to the tool's own hermetic --self-test (fixture loadavg/meminfo and
# stub docker; no real docker, no network, no host state read).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../../bin/contention-census"

if [ ! -x "$bin" ]; then
  echo "contention-census self-test: FAIL — $bin missing or not executable" >&2
  echo "Fix: chmod +x ai/bin/contention-census" >&2
  exit 1
fi

exec "$bin" --self-test
