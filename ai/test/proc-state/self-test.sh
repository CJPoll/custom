#!/usr/bin/env bash
# Deterministic suite for ai/lib/proc_state.rb (DND-1550): a SIGKILLed process
# that is still a zombie reads as gone, which Process.kill(0) does not.
# Discovered by ai/bin/harness-gate (any committed self-test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/ruby "${here}/proc_state_test.rb"
