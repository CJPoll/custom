#!/usr/bin/env bash
# Deterministic suite for the next-mission selector (DND-985): tier logic,
# the Notion read adapter behind a fake transport, and ai/bin/next-mission end
# to end on --from-json fixtures. No network, no git, no model. Discovered by
# ai/bin/harness-gate (any committed self-test.sh); ai/bin/next-mission
# --self-test execs this file.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/ruby "${here}/next_mission_test.rb"
