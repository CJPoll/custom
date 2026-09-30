#!/usr/bin/env bash
# Deterministic suites for ai/lib/tool_sandbox/ and the --prepare-clone path of
# ai/bin/tool-sandbox (DND-1426). No model, no network. Discovered by
# ai/bin/harness-gate (any committed self-test.sh). The escape probes are the
# tool's own inline suite, which harness-gate declares separately.
#   1. policy_test.rb  the pure domain: path validation, the bwrap argv, exits
#   2. clone_test.rb   the pinned throwaway clone + the read-only /origin mirror,
#                      end to end with real git and real bwrap
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
/usr/bin/ruby "${here}/policy_test.rb"
/usr/bin/ruby "${here}/clone_test.rb"
