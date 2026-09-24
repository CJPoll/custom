#!/usr/bin/env bash
# Deterministic suite for ai/lib/eval_score.rb (DND-225): the numeric eval score
# and the noise-threshold rule variant-eval consumes. No model, no git. Discovered
# by ai/bin/harness-gate (any committed self-test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "${here}/eval_score_test.rb"
