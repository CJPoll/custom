#!/usr/bin/env bash
# err.sh -- the one refusal shape for the whole athena:inbox skill. Domain
# (pure): it writes to stderr and returns, and touches nothing else.
#
# The contract (ai/contracts/athena-inbox.md -> "Conformance language") makes
# this mandatory, not stylistic: EVERY refusal carries a greppable `Fix:`
# clause naming the corrective action, alongside a non-zero exit. A bare
# failure message leaves the agent reading it with nowhere to go, and
# ai/bin/check-guard-messages turns the harness gate red over it.
#
# The `Fix:` text is under the same disclosure limit as the refusal itself: it
# MUST NOT name another tenant's channels or paths.

# inbox_fail <message> <fix-clause> [exit-status]
# Emits the refusal on stderr and RETURNS the status (never exits) so a caller
# can refuse one channel without killing a multi-channel run.
inbox_fail() {
  local msg="$1" fix="$2" status="${3:-1}"
  printf 'athena:inbox: %s\n' "${msg}" >&2
  printf '  Fix: %s\n' "${fix}" >&2
  return "${status}"
}
