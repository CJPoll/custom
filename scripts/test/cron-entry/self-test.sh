#!/usr/bin/env bash
# Self-test for scripts/lib/cron-entry.sh (DND-1503): which crontab lines are
# ours. Pure text in, text out; no crontab is read or written.
#
# Run: bash scripts/test/cron-entry/self-test.sh

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/cron-entry.sh
. "${HERE}/../../lib/cron-entry.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
expect() { # <claim> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

R="/home/u/dev/custom/scripts/athena-x-run.sh"
SUF="/scripts/athena-x-run.sh"
LIVE="0 * * * * ${R}"
LIVE_TAB="$(printf '0\t*\t*\t*\t*\t%s' "$R")"
LIVE_ARGS="0 * * * * ${R} --flag"
COMMENTED="#0 * * * * ${R}"
INDENTED_COMMENT="   # 0 * * * * ${R}"
BAK="0 * * * * ${R}.bak"
LONGER="0 * * * * /backup${R}"
STALE="0 * * * * /home/u/.local/worktrees/custom/b${SUF}"
OTHER="0 7 * * * /opt/other-job"
BLANK=""
CT="$(printf '%s\n' "$LIVE" "$LIVE_TAB" "$LIVE_ARGS" "$COMMENTED" "$INDENTED_COMMENT" "$BAK" "$BLANK" "$LONGER" "$STALE" "$OTHER")"

printf '\ncron_entry_lines — classes\n'
expect "ours: the exact path as a field, with spaces, tabs or arguments" \
  "$(printf '%s\n' "$LIVE" "$LIVE_TAB" "$LIVE_ARGS")" "$(printf '%s\n' "$CT" | cron_entry_lines "$R" ours)"
expect "notours: comments, <runner>.bak, a longer path, another copy, other jobs and blanks, byte for byte" \
  "$(printf '%s\n' "$COMMENTED" "$INDENTED_COMMENT" "$BAK" "$BLANK" "$LONGER" "$STALE" "$OTHER")" \
  "$(printf '%s\n' "$CT" | cron_entry_lines "$R" notours)"
expect "stale: any other copy of the runner (a longer path included), only when a suffix is given" \
  "$(printf '%s\n' "$LONGER" "$STALE")" "$(printf '%s\n' "$CT" | cron_entry_lines "$R" stale "$SUF")"
expect "stale: empty with no suffix" \
  "" "$(printf '%s\n' "$CT" | cron_entry_lines "$R" stale)"
expect "a line that names the runner AND another copy is ours, not stale" \
  "" "$(printf '0 * * * * %s /x%s\n' "$R" "$SUF" | cron_entry_lines "$R" stale "$SUF")"
expect "a runner path with a backslash is matched literally" \
  '0 * * * * /a\tb/run.sh' "$(printf '%s\n' '0 * * * * /a\tb/run.sh' '0 * * * * /a	b/run.sh' | cron_entry_lines '/a\tb/run.sh' ours)"

printf '\ncron_entry_lines — a wrong key is an error, never an empty result\n'
out="$(printf '%s\n' "$CT" | cron_entry_lines "" ours 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q 'Fix:' <<<"$out" && ! grep -qF "$LIVE" <<<"$out"; then
  ok "an empty runner is exit 2 with Fix:"
else
  bad "an empty runner is exit 2 with Fix:" "rc=$rc out=$out"
fi
out="$(printf '%s\n' "$CT" | cron_entry_lines "scripts/athena-x-run.sh" notours 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q 'not an absolute path' <<<"$out" && ! grep -qF "$OTHER" <<<"$out"; then
  ok "a relative runner is exit 2 with Fix:, and prints no lines"
else
  bad "a relative runner is exit 2 with Fix:, and prints no lines" "rc=$rc out=$out"
fi
out="$(printf '%s\n' "$CT" | cron_entry_lines "/opt/my runner.sh" notours 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q 'contains whitespace' <<<"$out" && grep -q 'Fix:' <<<"$out" && ! grep -qF "$OTHER" <<<"$out"; then
  ok "a runner with whitespace (it can never equal one field) is exit 2 with Fix:, and prints no lines"
else
  bad "a runner with whitespace (it can never equal one field) is exit 2 with Fix:, and prints no lines" "rc=$rc out=$out"
fi
out="$(printf '%s\n' "$CT" | cron_entry_lines "$R" mine 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q 'Fix:' <<<"$out"; then
  ok "an unknown class is exit 2 with Fix:"
else
  bad "an unknown class is exit 2 with Fix:" "rc=$rc out=$out"
fi

printf '\n'
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf 'VERDICT: PASS (%d cases)\n' "$TOTAL"
  exit 0
fi
printf 'VERDICT: FAIL (%d of %d cases)\n' "$FAIL" "$TOTAL"
printf '  Fix: read each FAIL above; repair scripts/lib/cron-entry.sh, then re-run\n'
printf '       bash scripts/test/cron-entry/self-test.sh.\n'
exit 1
