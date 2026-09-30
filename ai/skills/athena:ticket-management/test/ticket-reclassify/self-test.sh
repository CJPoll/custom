#!/usr/bin/env bash
# self-test.sh -- the ticket-reclassify suite (DND-1056). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Three layers, in TDD order:
#   1. domain_test.rb  -- lib/reclassify.rb, pure (QA Plan eligibility,
#      changes; answers, outcomes, proof comparisons, pacing);
#   2. manager_test.rb -- plan and proof with a fake tracker, a fake server
#      and a fake clock (QA Plan plan 1-7, proof 1-4, the idempotent re-plan);
#   3. e2e_test.rb     -- the script as a process against one loopback fake
#      (fake-server.py) for Notion's reads and the classification endpoint
#      (QA Plan plan 8: only reads reach Notion). Never prod.
# Functional tests only: no load, no timing thresholds (the pacing case runs
# on a fake clock).

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for dep in /usr/bin/ruby python3 curl; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "ticket-reclassify self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done

rc=0
for suite in domain_test.rb manager_test.rb e2e_test.rb; do
  /usr/bin/ruby "${HERE}/${suite}" || rc=1
done
if [ "${rc}" -eq 0 ]; then
  echo "ticket-reclassify self-test: OK"
else
  echo "ticket-reclassify self-test: FAIL"
  echo "  Fix: read the FAIL lines above; each names the case and what it expected."
fi
exit "${rc}"
