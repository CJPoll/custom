#!/usr/bin/env bash
# Deterministic suite for ai/lib/eval_subject.rb (DND-529): the per-agent eval
# registry, subject loading and containment argv. No model, no git. Discovered
# by ai/bin/harness-gate (any committed self-test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/ruby "${here}/eval_subject_test.rb"
