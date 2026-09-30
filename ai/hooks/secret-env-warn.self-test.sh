#!/bin/sh
# Self-test for ai/hooks/secret-env-warn.sh (DND-845). Run with stdin closed.
# The check itself is covered by ai/test/machine-secrets/self-test.sh; this
# suite pins the hook's own contract with a stub check (ENV_WARN_CHECK_BIN):
# it passes the check's lines through, prints nothing when clean, turns a
# broken or missing check into ONE line with a Fix, and always exits 0.

HOOK="$(cd -- "$(dirname -- "$0")" && pwd -P)/secret-env-warn.sh"
TMP=$(mktemp -d) || { echo "secret-env-warn.self-test: FAIL -- mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM
FAILED=0
PASSED=0
ok()  { PASSED=$((PASSED+1)); printf '  ok    %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

stub() { # <exit> <line or empty>
  printf '#!/bin/sh\n[ "$1 $2 $3" = "--probe a --brief" ] || { echo "stub: wrong argv: $*"; exit 9; }\n%s\nexit %s\n' \
    "${2:+echo \"$2\"}" "$1" > "$TMP/check"
  chmod +x "$TMP/check"
}
run() { OUT=$(printf '{"hook_event_name":"SessionStart"}' | ENV_WARN_CHECK_BIN="$1" "$HOOK" 2>&1); RC=$?; }

stub 1 "secret-env-warn: SYN_API_KEY is in this process's env Fix: move it"
run "$TMP/check"
[ "$RC" = 0 ] && [ "$OUT" = "secret-env-warn: SYN_API_KEY is in this process's env Fix: move it" ] \
  && ok "a finding is passed through as one line, exit 0" || bad "a finding is passed through as one line, exit 0" "rc=$RC out=$OUT"

stub 0 ""
run "$TMP/check"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "clean: prints nothing, exit 0" || bad "clean: prints nothing, exit 0" "rc=$RC out=$OUT"

stub 3 "secret-env-warn: X could not be verified Fix: y"
run "$TMP/check"
[ "$RC" = 0 ] && [ -n "$OUT" ] && ok "could-not-measure is passed through, exit 0" || bad "could-not-measure is passed through, exit 0" "rc=$RC out=$OUT"

stub 2 "usage garbage"
run "$TMP/check"
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "failed (exit 2).*Fix:" && ! printf '%s' "$OUT" | grep -q garbage \
  && ok "an unexpected exit is one line with a Fix, exit 0" || bad "an unexpected exit is one line with a Fix, exit 0" "rc=$RC out=$OUT"

run "$TMP/no-such-check"
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "missing at .*Fix:" \
  && ok "a missing check is one line with a Fix, exit 0" || bad "a missing check is one line with a Fix, exit 0" "rc=$RC out=$OUT"

OUT=$(ENV_WARN_CHECK_BIN="$TMP/check" "$HOOK" </dev/null 2>&1); RC=$?
[ "$RC" = 0 ] && ok "closed stdin does not hang or fail" || bad "closed stdin does not hang or fail" "rc=$RC"

echo "secret-env-warn.self-test: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
