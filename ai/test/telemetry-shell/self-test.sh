#!/usr/bin/env bash
# self-test.sh -- the shell binding to the telemetry CLI, ai/lib/telemetry-emit.sh
# (DND-1475). Discovered by harness-gate (every committed `self-test.sh` runs).
#
# The binding is what every bash emitter (integration-gate, locked-merge, the
# gh-athena push) calls, so its one promise is checked here: an event is
# written when the writer is there, and the caller's exit code and stdout never
# change when it is not, or when it fails.
#
# Functional only (DND-1222): no sleeps, no timing, no load. Never the real
# store: every case points ATHENA_TELEMETRY_DIR into a temp dir.
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
LIB="${ROOT}/ai/lib/telemetry-emit.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

[ -f "${LIB}" ] || { echo "telemetry-shell self-test: FAIL -- ${LIB} is missing"; echo "  Fix: restore ai/lib/telemetry-emit.sh"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "telemetry-shell self-test: FAIL -- jq is not on PATH"; echo "  Fix: install jq; this suite does not skip."; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; echo "  Fix: free space in TMPDIR"; exit 1; }
cleanup() { chmod -R u+rwx "${TMP}" 2>/dev/null; rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM
export ATHENA_TELEMETRY_DIR="${TMP}/default-store" ATHENA_UNIT=DND-1
unset ATHENA_TELEMETRY_NOW

SHA_A="$(printf 'a%.0s' {1..40})"; SHA_B="$(printf 'b%.0s' {1..40})"
OUT=""; ERR=""; CODE=0
# caller LIB STORE BODY -- a caller script under `set -euo pipefail` that
# sources LIB and runs BODY, then prints "after" (it kept going).
caller() {
  OUT="$(cd "${TMP}" && ATHENA_TELEMETRY_DIR="$2" bash -c 'set -euo pipefail; . "$1"; eval "$2"; echo after' _ "$1" "$3" 2>"${TMP}/err" </dev/null)"
  CODE=$?
  ERR="$(cat "${TMP}/err")"
}
events() { cat "$1"/*.jsonl 2>/dev/null | jq -c "select(.event == \"$2\")"; }

echo "== athena_telemetry_emit"

# 1. The CLI resolves: one line, return 0, nothing on stdout.
S1="${TMP}/s1"
caller "${LIB}" "${S1}" "athena_telemetry_emit --event merge.landed --head ${SHA_B} --attr via=push --attr before=${SHA_A} --attr after=${SHA_B}"
eq "1 the caller exits 0" "${CODE}" "0"
eq "1 the caller's stdout is only its own" "${OUT}" "after"
eq "1 nothing on stderr" "${ERR}" ""
line="$(events "${S1}" merge.landed)"
eq "1 exactly one merge.landed line" "$(printf '%s\n' "${line}" | grep -c .)" "1"
eq "1 the attrs are written typed" "$(jq -c '.attrs' <<<"${line}")" "{\"via\":\"push\",\"before\":\"${SHA_A}\",\"after\":\"${SHA_B}\"}"
eq "1 the head is the one passed" "$(jq -r '.head' <<<"${line}")" "${SHA_B}"
[ -e "${S1}/write-failures" ] && bad "1 no write-failures" "$(cat "${S1}/write-failures")" || ok "1 no write-failures"

# 2. The CLI is missing (the binding copied into a tree with no ai/bin): it
# returns 0, writes nothing, and the caller carries on.
FX="${TMP}/fx2"; mkdir -p "${FX}/ai/lib"; cp "${LIB}" "${FX}/ai/lib/"
S2="${TMP}/s2"
caller "${FX}/ai/lib/telemetry-emit.sh" "${S2}" "athena_telemetry_emit --event merge.landed --attr via=push"
eq "2 missing CLI: the caller exits 0" "${CODE}" "0"
eq "2 missing CLI: the caller's stdout is unchanged" "${OUT}" "after"
eq "2 missing CLI: nothing on stderr" "${ERR}" ""
[ -e "${S2}" ] && bad "2 missing CLI: nothing written" "$(find "${S2}")" || ok "2 missing CLI: nothing written"

# 3. A CLI that fails loudly: exit 7, noise on stdout, two stderr lines. The
# caller's stdout and exit are unchanged; only the writer's one
# `athena-telemetry:` line reaches stderr.
FX="${TMP}/fx3"; mkdir -p "${FX}/ai/lib" "${FX}/ai/bin"; cp "${LIB}" "${FX}/ai/lib/"
printf '#!/bin/sh\necho noise\nprintf "athena-telemetry: could not write. Fix: check the store\\nsecond line\\n" >&2\nexit 7\n' > "${FX}/ai/bin/telemetry-emit"
chmod +x "${FX}/ai/bin/telemetry-emit"
caller "${FX}/ai/lib/telemetry-emit.sh" "${TMP}/s3" "athena_telemetry_emit --event merge.landed --attr via=push"
eq "3 failing CLI: the caller exits 0" "${CODE}" "0"
eq "3 failing CLI: the CLI's stdout never reaches the caller's" "${OUT}" "after"
eq "3 failing CLI: one athena-telemetry: line on stderr, nothing else" "${ERR}" "athena-telemetry: could not write. Fix: check the store"

# 4. A CLI whose stderr is not the writer's line: nothing reaches stderr.
printf '#!/bin/sh\necho "ruby: some crash" >&2\nexit 1\n' > "${FX}/ai/bin/telemetry-emit"
caller "${FX}/ai/lib/telemetry-emit.sh" "${TMP}/s4" "athena_telemetry_emit --event merge.landed"
eq "4 other stderr is dropped, exit 0" "${CODE}:${OUT}:${ERR}" "0:after:"

# 5. An unwritable store, through the real CLI: exit 0, stdout unchanged.
S5="${TMP}/s5-parent"; mkdir -p "${S5}"; chmod 500 "${S5}"
caller "${LIB}" "${S5}/telemetry" "athena_telemetry_emit --event merge.landed --attr via=push"
chmod 700 "${S5}"
eq "5 unwritable store: the caller exits 0" "${CODE}" "0"
eq "5 unwritable store: the caller's stdout is unchanged" "${OUT}" "after"
case "${ERR}" in
  ''|athena-telemetry:*Fix:*) ok "5 unwritable store: at most the one athena-telemetry: line, with Fix:" ;;
  *) bad "5 unwritable store: stderr" "${ERR}" ;;
esac

# 5b. --unit-branch (through the real CLI): the unit resolves from the named
# branch with the one parser, not from the checked-out one (here: none).
S5B="${TMP}/s5b"
OUT="$(cd "${TMP}" && ATHENA_UNIT= ATHENA_TELEMETRY_DIR="${S5B}" bash -c '. "$1"; athena_telemetry_emit --event merge.landed --unit-branch dnd-42-fixture --attr via=pr' _ "${LIB}" 2>&1)"
eq "5b --unit-branch gives the ticket that branch names, source branch" \
  "$(events "${S5B}" merge.landed | jq -r '[.unit, .unit_source] | join(" ")')" "DND-42 branch"

echo "== a TERM-ignoring git under the CLI (DND-1506)"

# 9. The git the writer runs ignores TERM and blocks on a fifo nobody writes
# (an event, never a sleep). It starts a child that also ignores TERM, so the
# check covers its whole process group. Once the binding returns, neither may
# survive: the writer's KILL must land before the binding's outer KILL ends
# Ruby. The wait for each pid is a cap on a hang, not a verdict on speed: a
# killed process is gone at once, an orphan never goes. The fix does rest on
# one margin: the writer's 0.5 s grace against the outer 1 s TERM-to-KILL gap
# (pinned arithmetically in ai/test/telemetry/telemetry_test.rb). A failure
# here on a loaded machine is that margin, not a flake to retry.
FG="${TMP}/fake-git"; mkdir -p "${FG}/bin"
mkfifo "${FG}/never-written"
printf '#!/bin/bash\ntrap "" TERM\nprintf "%%s\\n" "$$" >> "%s"\ncat "%s" &\nprintf "%%s\\n" "$!" >> "%s"\nwait\n' \
  "${FG}/pids" "${FG}/never-written" "${FG}/pids" > "${FG}/bin/git"
chmod +x "${FG}/bin/git"
# DND-1667: a guard right behind the fake git, so a fake that is missing or not
# executable fails the suite instead of reaching the real git
# (ai/lib/forge-stub-guard.sh). fsg_make: only this PATH gets the guard.
. "${ROOT}/ai/lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
fsg_require_stubs "${FG}/bin" git
gone() { timeout 5 tail -s 0.1 --pid="$1" -f /dev/null; }
PATH="${FG}/bin:${FSG_DIR}:${PATH}" caller "${LIB}" "${TMP}/s9" "athena_telemetry_emit --event merge.landed --attr via=push"
eq "9 TERM-ignoring git: the caller exits 0, stdout its own" "${CODE}:${OUT}" "0:after"
mapfile -t FGPIDS < <(cat "${FG}/pids" 2>/dev/null)
eq "9 the fake git and its child both started" "${#FGPIDS[@]}" "2"
SURVIVORS=""
for p in "${FGPIDS[@]}"; do
  [[ "${p}" =~ ^[0-9]+$ ]] || continue
  gone "${p}" || SURVIVORS="${SURVIVORS} ${p}"
done
eq "9 no process of the fake git's group survives the emit" "${SURVIVORS}" ""
# Clean up a regression: the fake git leads its own process group, so KILL
# the group (a member whose pid was never written included), then each pid.
[[ "${FGPIDS[0]:-}" =~ ^[0-9]+$ ]] && kill -KILL -- "-${FGPIDS[0]}" 2>/dev/null
for p in ${SURVIVORS}; do kill -KILL "${p}" 2>/dev/null; done

echo "== the clock helpers"
caller "${LIB}" "${TMP}/s6" 't0=$(athena_telemetry_clock_us); [[ $t0 =~ ^[0-9]{16,}$ ]] && echo clock-ok; d=$(athena_telemetry_seconds_since "$t0"); [[ $d =~ ^[0-9]+\.[0-9]{3}$ ]] && echo dur-ok'
eq "6 clock_us is microseconds and seconds_since is S.mmm" "${OUT}" $'clock-ok\ndur-ok\nafter'
caller "${LIB}" "${TMP}/s7" 'x=$(athena_telemetry_seconds_since ""); y=$(athena_telemetry_seconds_since "abc"); echo "[$x][$y]"'
eq "7 no start or a bad one is no duration, never 0" "${OUT}" $'[][]\nafter'
caller "${LIB}" "${TMP}/s8" 'n=$(athena_telemetry_now); [[ $n =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]] && echo now-ok'
eq "8 now is ISO 8601 UTC with milliseconds" "${OUT}" $'now-ok\nafter'

# DND-1667: no git call may have fallen through past the fake.
if fsg_verify; then ok "no git call fell through past its stub (DND-1667)"
else bad "no git call fell through past its stub (DND-1667)" "see the forge-stub-guard FAIL above"; fi

echo
printf 'telemetry-shell self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
