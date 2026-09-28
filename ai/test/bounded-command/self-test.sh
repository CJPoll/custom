#!/usr/bin/env bash
# Deterministic suite for ai/lib/bounded_command.rb (DND-1088): a command past
# its bound returns timed_out and its whole process group is killed. Real
# child processes, no network. Discovered by ai/bin/harness-gate (any committed
# self-test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "${here}/bounded_command_test.rb"
