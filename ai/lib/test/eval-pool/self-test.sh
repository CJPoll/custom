#!/usr/bin/env bash
# Deterministic suite for ai/lib/eval_pool.rb (DND-1007): the bounded, ordered
# concurrent map the eval runners sample through. No model, no git. Discovered
# by ai/bin/harness-gate (any committed self-test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/ruby "${here}/eval_pool_test.rb"
