#!/usr/bin/env bash
# self-test for ai/lib/gitlab_pipeline_selector.rb (DND-1952) -- discovered by
# harness-gate. Literal pipeline hashes only; no network, no glab.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if ! /usr/bin/ruby "$here/selector_test.rb"; then
  echo "gitlab-pipeline-selector self-test: FAIL" >&2
  echo "Fix: see the failing checks above; a malformed selector must be refused with its text, a selector matching no pipeline must read could-not-measure, and a waiting or running deploy must read busy." >&2
  exit 1
fi
echo "gitlab-pipeline-selector self-test: PASS"
