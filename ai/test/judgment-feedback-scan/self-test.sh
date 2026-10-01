#!/usr/bin/env bash
# self-test.sh -- the `judgment-feedback scan-tickets` suite (DND-1469).
# Discovered by harness-gate (every committed `self-test.sh` runs).
#
# Two layers, in TDD order:
#   1. domain_test.rb -- ai/lib/judgment_feedback_scan.rb, pure;
#   2. e2e_test.rb -- the bin against a loopback fake of Notion's reads and the
#      Athena feedback POST (fake-scan-server.py). Never prod. Functional only
#      (DND-1222): it blocks on the fake's port line and each exit, never a sleep.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for dep in /usr/bin/ruby python3 curl; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "judgment-feedback-scan self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done

rc=0
for suite in domain_test.rb e2e_test.rb; do
  /usr/bin/ruby "${HERE}/${suite}" || rc=1
done
if [ "${rc}" -eq 0 ]; then
  echo "judgment-feedback-scan self-test: OK"
else
  echo "judgment-feedback-scan self-test: FAIL"
  echo "  Fix: read the FAIL lines above; each names the case and what it expected."
fi
exit "${rc}"
