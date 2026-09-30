#!/usr/bin/env bash
# Deterministic suites for ai/lib/block_optimize.rb and ai/bin/block-optimize
# (DND-528). No model, no network. Discovered by ai/bin/harness-gate (any
# committed self-test.sh).
#   1. block_optimize_test.rb  the pure domain (Scope/Diff/Evidence/Label/...)
#   2. integration_test.sh     end to end in a throwaway git repo with stub
#                              build/check/variant-eval/claude: never adopts
#                              (refs, HEAD, index, worktree list unchanged; the
#                              candidate is reachable from no ref)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
/usr/bin/ruby "${here}/block_optimize_test.rb"
bash "${here}/integration_test.sh"
