#!/bin/sh
# secret-env-warn.sh -- SessionStart hook (DND-845). Contract:
# ai/contracts/athena-machine-secrets.md -> secret-env-warn.
#
# Runs check-machine-secrets probe (a) only, in this session's env (a hook
# inherits Claude Code's), and prints one context line per secret it finds in
# that env, each with its Fix. It covers sessions that never run the harness
# gate. It NEVER blocks: every path exits 0. It prints names only; the check
# never prints a value.
#
# ROLLOUT: not registered in ai/hooks/registry.json until the migration's final
# step (contract -> Rollout). Wire it only after that row lands.
#
# Seam: ENV_WARN_CHECK_BIN replaces the check (self-test only).
# Tests: ai/hooks/secret-env-warn.self-test.sh.

# Drain the SessionStart payload; nothing in it is needed.
[ -t 0 ] || cat >/dev/null 2>&1

here=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || here=""
check="${ENV_WARN_CHECK_BIN:-${here}/../bin/check-machine-secrets}"

if [ ! -x "$check" ]; then
  echo "secret-env-warn: the secret check is missing at $check, so this session's env was not checked. Fix: restore ai/bin/check-machine-secrets in the custom repo (git checkout origin/main -- ai/bin/check-machine-secrets)."
  exit 0
fi

out=$(timeout 30 "$check" --probe a --brief 2>&1 </dev/null)
rc=$?
case "$rc" in
  0|1|3)
    [ -n "$out" ] && printf '%s\n' "$out"
    ;;
  124)
    echo "secret-env-warn: the secret check timed out after 30s, so this session's env was not checked. Fix: run ~/dev/custom/ai/bin/check-machine-secrets --probe a by hand and read its output."
    ;;
  *)
    echo "secret-env-warn: the secret check failed (exit $rc), so this session's env was not checked. Fix: run ~/dev/custom/ai/bin/check-machine-secrets --probe a by hand and read its output."
    ;;
esac
exit 0
