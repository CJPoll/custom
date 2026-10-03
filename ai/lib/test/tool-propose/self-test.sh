#!/usr/bin/env bash
# Deterministic suites for ai/bin/tool-propose (DND-176). No model, no network.
# Discovered by ai/bin/harness-gate (any committed self-test.sh). The manager
# and containment suite is the tool's own inline --self-test, which
# harness-gate declares separately.
#   1. tool_propose_test.rb  the pure domain (Target/Candidate/Label/OutDir)
#   2. integration_test.rb   end to end in a throwaway repo with the real
#                            tool-sandbox, variant-eval and harness-eval and a
#                            stub harness-gate: RECOMMENDED for a correct tool,
#                            NOT for a no-op or deceptive one, an escaping one
#                            reaches nothing, the host repo is unchanged
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
/usr/bin/ruby "${here}/tool_propose_test.rb"
/usr/bin/ruby "${here}/integration_test.rb"
