#!/usr/bin/env bash
# self-test.sh -- the ticket-provenance-check suite (DND-1354). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Two layers, in TDD order:
#   1. domain_test.rb -- ../../lib/provenance_lines.rb, pure;
#   2. e2e_test.rb -- the script against ../fake-triage-server.py standing in
#      for Notion's reads. Never prod. Functional only (DND-1222).

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for dep in /usr/bin/ruby python3 curl; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "ticket-provenance-check self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done

rc=0
for suite in domain_test.rb e2e_test.rb; do
  /usr/bin/ruby "${HERE}/${suite}" || rc=1
done
if [ "${rc}" -eq 0 ]; then
  echo "ticket-provenance-check self-test: OK"
else
  echo "ticket-provenance-check self-test: FAIL"
  echo "  Fix: read the FAIL lines above; each names the case and what it expected."
fi
exit "${rc}"
