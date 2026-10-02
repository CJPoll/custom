#!/usr/bin/env bash
# Self-test for scripts/lib/cron-entry.sh: which crontab lines are ours
# (DND-1503), the crontab reader (DND-1638), the main-checkout resolver
# (DND-1639) and the call of a runner's own --dry-run (DND-1728). The reader
# runs fake crontab commands, the resolver a temp git repo with a linked
# worktree, and the dry-run call stub runners; the real crontab is never read
# or written.
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

printf '\ncron_read_crontab — only "no crontab for" is empty (DND-1638)\n'
# A fake crontab command per case, in a temp dir. The real crontab is never run.
FT="$(mktemp -d)"
trap 'rm -rf -- "$FT"' EXIT
fake() { # <name> <stdout> <stderr> <exit>
  printf '#!/usr/bin/env bash\n[ "$1" = -l ] || exit 9\nprintf %%s %q\nprintf %%s %q >&2\nexit %s\n' "$2" "$3" "$4" >"${FT}/$1"
  chmod +x "${FT}/$1"
}
fake ok-ct "$(printf '%s\n' "$LIVE" "$OTHER")" "" 0
fake none "" "no crontab for u" 1
fake denied "" "/var/spool/cron/crontabs/u: Permission denied" 1
fake denied-out "$OTHER" "crontab: spool fault" 2

out="$(cron_read_crontab who "${FT}/ok-ct" 2>"${FT}/err")"; rc=$?
expect "a readable crontab prints its lines, exit 0" "0|$(printf '%s\n' "$LIVE" "$OTHER")" "${rc}|${out}"
out="$(cron_read_crontab who "${FT}/none" 2>"${FT}/err")"; rc=$?
expect "'no crontab for <user>' is an empty crontab, exit 0, nothing on stderr" "0||" "${rc}|${out}|$(cat "${FT}/err")"
out="$(cron_read_crontab who "${FT}/denied" 2>"${FT}/err")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q '^who: could not read the current crontab' "${FT}/err" \
   && grep -q 'Permission denied' "${FT}/err" && grep -q 'Fix:' "${FT}/err"; then
  ok "a permission error is exit 2, names the error, carries Fix:, and prints no lines"
else
  bad "a permission error is exit 2, names the error, carries Fix:, and prints no lines" "rc=$rc out=$out err=$(cat "${FT}/err")"
fi
out="$(cron_read_crontab who "${FT}/denied-out" 2>"${FT}/err")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q 'exit 2' "${FT}/err" && grep -q 'Fix:' "${FT}/err"; then
  ok "a failed read that printed partial lines prints none of them (exit 2)"
else
  bad "a failed read that printed partial lines prints none of them (exit 2)" "rc=$rc out=$out err=$(cat "${FT}/err")"
fi
out="$(cron_read_crontab who "${FT}/absent-crontab" 2>"${FT}/err")"; rc=$?
if [ "$rc" = 2 ] && [ -z "$out" ] && grep -q 'Fix:' "${FT}/err"; then
  ok "a crontab command that cannot run is exit 2 with Fix:, never an empty crontab"
else
  bad "a crontab command that cannot run is exit 2 with Fix:, never an empty crontab" "rc=$rc out=$out err=$(cat "${FT}/err")"
fi

printf '\ncron_main_checkout — the main checkout, never a linked worktree (DND-1639)\n'
GR="${FT}/repo"; mkdir -p "${GR}/scripts"
git -C "$GR" init -q -b main >&2
git -C "$GR" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m seed >&2
GR="$(cd -- "$GR" && pwd -P)"
git -C "$GR" worktree add -q "${FT}/wt" >&2
mkdir -p "${FT}/wt/scripts"
cron_main_checkout "${GR}/scripts" 2>"${FT}/err"; rc=$?
expect "from the main checkout: the main checkout, not in a worktree" "0|${GR}|0" "${rc}|${CRON_MAIN_CHECKOUT}|${CRON_IN_WORKTREE}"
cron_main_checkout "${FT}/wt/scripts" 2>"${FT}/err"; rc=$?
expect "from a linked worktree: still the MAIN checkout, and in a worktree" "0|${GR}|1" "${rc}|${CRON_MAIN_CHECKOUT}|${CRON_IN_WORKTREE}"
mkdir -p "${FT}/nogit"
CRON_MAIN_CHECKOUT=stale
GIT_CEILING_DIRECTORIES="${FT}" cron_main_checkout "${FT}/nogit" 2>"${FT}/err"; rc=$?
if [ "$rc" = 2 ] && [ -z "${CRON_MAIN_CHECKOUT}" ] && grep -q 'not inside a git checkout' "${FT}/err" && grep -q 'Fix:' "${FT}/err"; then
  ok "outside any git checkout: exit 2 with Fix:, and no main checkout (never a stale or empty one used)"
else
  bad "outside any git checkout: exit 2 with Fix:, and no main checkout" "rc=$rc main=${CRON_MAIN_CHECKOUT} err=$(cat "${FT}/err")"
fi
# The resolver lives in main-checkout.sh beside this lib (DND-1720). A copy of
# cron-entry.sh without it must refuse, never resolve to nothing quietly.
mkdir -p "${FT}/lonelib"
cp "${HERE}/../../lib/cron-entry.sh" "${FT}/lonelib/"
out="$(bash -c '. "$1/cron-entry.sh"; cron_main_checkout "$2" who; echo "rc=$? main=[${CRON_MAIN_CHECKOUT}]"' _ "${FT}/lonelib" "${GR}/scripts" 2>"${FT}/err")"
if [ "$out" = "rc=2 main=[]" ] && grep -q 'main-checkout.sh' "${FT}/err" && grep -q 'Fix:' "${FT}/err"; then
  ok "without scripts/lib/main-checkout.sh beside it: exit 2 with Fix:, and no main checkout"
else
  bad "without scripts/lib/main-checkout.sh beside it: exit 2 with Fix:" "out=$out err=$(cat "${FT}/err")"
fi

printf '\ncron_runner_dry_run — the runner'"'"'s own --dry-run (DND-1728)\n'
# Stub runners: each logs its argv, prints a brief on stdout, and exits as named.
DR="${FT}/dry"; mkdir -p "$DR"
stub() { # <name> <exit> [<stderr line>...]
  local f="${DR}/$1" code="$2" l; shift 2
  printf '#!/usr/bin/env bash\necho "$*" >>%q\necho "BRIEF on stdout"\n' "${f}.args" >"$f"
  for l in "$@"; do printf 'echo %q >&2\n' "$l" >>"$f"; done
  printf 'exit %s\n' "$code" >>"$f"; chmod +x "$f"
}
stub ok 0
CRON_DRY_WHY=stale; CRON_DRY_FIX=stale
cron_runner_dry_run "${DR}/ok"; rc=$?
expect "a runner whose --dry-run passes: 0, called with --dry-run, nothing set" \
  "0|--dry-run||" "${rc}|$(cat "${DR}/ok.args")|${CRON_DRY_WHY}|${CRON_DRY_FIX}"
stub refuse 78 "r: lib/x.sh could not be loaded; a tick would exit 78 and spawn no session." "  Fix: restore lib/x.sh."
cron_runner_dry_run "${DR}/refuse"; rc=$?
expect "a refusal: 1, its reason without the runner's own 'a tick would exit 78' suffix, its Fix:" \
  "1|the runner's own --dry-run refuses (${DR}/refuse --dry-run, exit 78): r: lib/x.sh could not be loaded|restore lib/x.sh." \
  "${rc}|${CRON_DRY_WHY}|${CRON_DRY_FIX}"
if ! grep -q 'BRIEF' <<<"${CRON_DRY_WHY}${CRON_DRY_FIX}"; then
  ok "the brief the runner prints on stdout is discarded, never quoted as a reason"
else
  bad "the brief on stdout is discarded" "why=${CRON_DRY_WHY} fix=${CRON_DRY_FIX}"
fi
stub warned 2 "r: LEADTIME_TIMEOUT='x' is not whole minutes; using 50m." "  Fix: set it like 50m." "r: not a git checkout." "  Fix: point it at a checkout."
cron_runner_dry_run "${DR}/warned"; rc=$?
expect "a warning before the refusal: the reason and Fix: are the last ones" \
  "1|the runner's own --dry-run refuses (${DR}/warned --dry-run, exit 2): r: not a git checkout.|point it at a checkout." \
  "${rc}|${CRON_DRY_WHY}|${CRON_DRY_FIX}"
stub silent 3
cron_runner_dry_run "${DR}/silent"; rc=$?
expect "a refusal with nothing on stderr says so, and its Fix: says how to see why" \
  "1|the runner's own --dry-run refuses (${DR}/silent --dry-run, exit 3): no reason on stderr|run ${DR}/silent --dry-run by hand to see why." \
  "${rc}|${CRON_DRY_WHY}|${CRON_DRY_FIX}"
# timeout's own exit for a hang is 124; a stub exiting 124 stands in for it,
# so no case waits out the cap.
stub hung 124
cron_runner_dry_run "${DR}/hung"; rc=$?
expect "exit 124 with nothing on stderr reads as a hang, never as no reason" \
  "1|the runner's own --dry-run refuses (${DR}/hung --dry-run, exit 124): it did not finish within 300s" \
  "${rc}|${CRON_DRY_WHY}"
cron_runner_dry_run "${DR}/absent"; rc=$?
if [ "$rc" = 1 ] && grep -q 'exit 127' <<<"${CRON_DRY_WHY}" && [ -n "${CRON_DRY_FIX}" ]; then
  ok "a runner that is not there is a refusal (exit 127), never a pass"
else
  bad "a missing runner is a refusal" "rc=$rc why=${CRON_DRY_WHY}"
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
