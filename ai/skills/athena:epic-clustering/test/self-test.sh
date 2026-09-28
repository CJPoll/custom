#!/usr/bin/env bash
# Deterministic suite for athena:epic-clustering (DND-982): the rules, the
# Notion read adapter behind a fake transport, and scripts/epic-clustering end
# to end on --from-json fixtures. No network, no git, no model, no Slack.
# Discovered by ai/bin/harness-gate (any committed self-test.sh);
# scripts/epic-clustering --self-test execs this file.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/ruby "${here}/epic_clustering_test.rb"
