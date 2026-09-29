#!/usr/bin/env bash
# Deterministic suite for ai/lib/reap_tags.rb's exec-window rule (DND-1016,
# DND-1202): every state /proc shows mid-exec is "cannot tell yet", never
# "untagged". Fixture /proc, injected clock and poll: no real process, no
# wait. Discovered by ai/bin/harness-gate (any committed self-test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/ruby "${here}/reap_tags_test.rb"
