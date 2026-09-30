#!/usr/bin/env bash
# Functional suite for ai/lib/scratch_home_sentinel.rb (DND-1316): a fixture
# suite that runs `ruby` through PATH under a scratch HOME is flagged; one that
# resolves the real binary first passes. No timing verdicts. Discovered by
# ai/bin/harness-gate (any committed self-test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/ruby "${here}/scratch_home_sentinel_test.rb"
