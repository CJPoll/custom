#!/usr/bin/env bash
# Self-test for scripts/setup-athena-inbox-client and
# scripts/athena-inbox-client-run.sh.
#
# Covers the Integration cases labelled I-8 … I-11 in the Athena Inbox epic's QA
# Plan, which lives in Notion (see ticket DND-189), NOT in this repo — so the
# labels are quoted for traceability only, and every case below restates in full
# what it protects rather than leaning on that document.
#
# Nothing real is touched:
#   * the CLIENT is a stub shell script whose exit code, run time and call log
#     the case chooses. The real client opens a WebSocket; this suite must
#     never do that, and never does — `ATHENA_INBOX_CLIENT_LAUNCHER` points at
#     the stub for every case that starts the supervisor.
#   * the CRONTAB is a PATH shim backed by a file in the case's tmpdir. The
#     live crontab carries the shipwright's hourly entry and is never opened.
#     Each case seeds its fake crontab with an unrelated line precisely so
#     "unrelated entries survive" is asserted rather than assumed.
#
# Every assertion here is about a decision that is INVISIBLE from the outside
# in production — which is the whole reason they are worth testing:
#   * a supervisor that relaunches through exit 2 looks perfectly healthy while
#     it corrupts the inbox by appending a re-pushed line after a fragment;
#   * a backoff that never caps looks identical to one that does, until an
#     outage;
#   * an flock that does not hold looks fine until two clients share one inbox,
#     which the delivery contract forbids outright;
#   * an installer that appends instead of replacing looks fine until the
#     crontab has eleven copies of the same line, or has lost the shipwright's.
#
# Run: bash scripts/test/athena-inbox-client/self-test.sh
#      (or: scripts/setup-athena-inbox-client --self-test)
#
# NOTE: this suite must never invoke `setup-athena-inbox-client --self-test` —
# that is the entry point that runs THIS file, and the pair would recurse.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
RUNNER="${SCRIPTS}/athena-inbox-client-run.sh"
INSTALLER="${SCRIPTS}/setup-athena-inbox-client"

PASS=0; FAIL=0
SUPERVISOR_PID=""

TMP="$(mktemp -d)"

# The supervisor creates the client's dump directory under $XDG_STATE_HOME
# (DND-316). Pinned for the WHOLE suite, not per helper: a case that invokes
# the runner directly would otherwise create the live
# ~/.local/state/athena/inbox-client-dumps (measured 2026-09-23 on this suite's
# first DND-316 run). setup_case re-pins it into each case dir.
export XDG_STATE_HOME="${TMP}/xdg"
# The watchdog now SENDS a harness-alerts message (DND-334) through send-mail,
# which resolves the inbox root from ATHENA_INBOX_ROOT (default: the LIVE
# ~/.local/share/athena). Pinned for the whole suite and re-pinned per case, so
# no case can deliver into, or even read, the live inbox.
export ATHENA_INBOX_ROOT="${TMP}/inbox-root"

# Reap anything this suite backgrounded, BY PID. A `pkill -f` here could match
# a real supervisor, or a sibling worktree's test run.
cleanup() {
  if [ -n "$SUPERVISOR_PID" ]; then
    kill "$SUPERVISOR_PID" 2>/dev/null
    wait "$SUPERVISOR_PID" 2>/dev/null
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# The unrelated entry every crontab case must preserve. Deliberately the real
# shipwright line: it is the one a careless read-modify-write would destroy.
UNRELATED='0 * * * * /home/cjpoll/dev/custom/scripts/athena-shipwright-run.sh'

CASE_N=0
CASE_DIR=""; FAKE_CRONTAB=""; STATE_DIR=""; STUB=""; CALLS=""; LOG=""
STOPFILE=""; SHIMBIN=""; STUB_PID=""; EXP_RUNNER_DIR=""; EXP_RUNNER=""

# setup_case <name> — a fresh tmpdir, a fresh fake crontab, a fresh PATH shim.
setup_case() {
  CASE_N=$((CASE_N+1))
  CASE_DIR="${TMP}/$(printf '%02d' "$CASE_N")-$1"
  mkdir -p "${CASE_DIR}"
  export XDG_STATE_HOME="${CASE_DIR}/xdg"
  export ATHENA_INBOX_ROOT="${CASE_DIR}/inbox-root"
  FAKE_CRONTAB="${CASE_DIR}/crontab.txt"
  STATE_DIR="${CASE_DIR}/state"
  STUB="${CASE_DIR}/stub-client"
  CALLS="${CASE_DIR}/calls"
  STUB_PID="${CASE_DIR}/stub.pid"
  LOG="${STATE_DIR}/athena-inbox-client.log"
  STOPFILE="${STATE_DIR}/athena-inbox-client.stopped"
  SHIMBIN="${CASE_DIR}/shimbin"
  # The installer schedules the MAIN CHECKOUT's runner (see the worktree case),
  # which in a pre-merge tree does not exist yet — so the installer would
  # rightly refuse. Point it at a case-local copy instead, and assert the
  # crontab against THAT. The worktree case deliberately does not use this
  # override: it is the one case that must exercise the real resolver.
  EXP_RUNNER_DIR="${CASE_DIR}/bin"
  EXP_RUNNER="${EXP_RUNNER_DIR}/athena-inbox-client-run.sh"
  mkdir -p "${STATE_DIR}" "${SHIMBIN}" "${EXP_RUNNER_DIR}"
  cp "${RUNNER}" "${EXP_RUNNER}"
  : > "${CALLS}"

  cat > "${SHIMBIN}/crontab" <<SHIM
#!/usr/bin/env bash
# crontab(1) shim — reads and writes ${FAKE_CRONTAB}, never the user's spool.
set -u
f='${FAKE_CRONTAB}'
case "\${1:-}" in
  -l) if [ -s "\$f" ]; then cat "\$f"; else echo "no crontab for user" >&2; exit 1; fi ;;
  -)  if [ -n "\${CRONTAB_SHIM_FAIL:-}" ]; then
        echo "crontab: installing new crontab: Permission denied" >&2
        exit 1
      fi
      cat > "\$f" ;;
  -r) rm -f "\$f" ;;
  *)  echo "crontab shim: unsupported invocation: \$*" >&2; exit 64 ;;
esac
SHIM
  chmod +x "${SHIMBIN}/crontab"
}

# make_stub <exit-code> <seconds-to-run>
# Records its own pid as well as the run, so "was the client reaped?" can be
# asked of a specific pid rather than by matching a command line — a `pgrep -f`
# on the stub path would also match the shell asking the question.
make_stub() {
  cat > "${STUB}" <<STUBEOF
#!/usr/bin/env bash
printf 'run\n' >> '${CALLS}'
printf '%s\n' "\$\$" > '${STUB_PID}'
sleep $2
exit $1
STUBEOF
  chmod +x "${STUB}"
}

calls() { wc -l < "${CALLS}" 2>/dev/null | tr -d ' '; }

# Run the installer with the crontab shim first on PATH and the stub standing
# in for the client launcher.
run_installer() {
  PATH="${SHIMBIN}:${PATH}" \
  ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
  ATHENA_INBOX_CLIENT_RUNNER_DIR="${EXP_RUNNER_DIR}" \
    bash "${INSTALLER}" "$@"
}

# Run the supervisor. Backoff/restart knobs are passed by each case so a run
# is bounded in seconds rather than unbounded in principle.
run_supervisor() {
  # XDG_STATE_HOME is pinned into the case dir: the supervisor creates the
  # client's dump directory under it, and the live one must never be touched.
  XDG_STATE_HOME="${CASE_DIR}/xdg" \
  ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
  ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
  ATHENA_INBOX_CLIENT_MIN_BACKOFF="${MIN_BACKOFF:-1}" \
  ATHENA_INBOX_CLIENT_MAX_BACKOFF="${MAX_BACKOFF:-2}" \
  ATHENA_INBOX_CLIENT_BACKOFF_RESET="${BACKOFF_RESET:-120}" \
  ATHENA_INBOX_CLIENT_MAX_RESTARTS="${MAX_RESTARTS:-3}" \
    bash "${RUNNER}" "$@"
}

# A bounded poll with a real sleep and a hard iteration cap — never a spin.
# Used only to observe another process reaching a state this shell cannot be
# woken for (the stub recording its first run).
wait_for_nonempty() { # wait_for_nonempty <file> [max-tenths]
  local f="$1" max="${2:-100}" i=0
  while [ "$i" -lt "$max" ]; do
    [ -s "$f" ] && return 0
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# I-8 — the installer: idempotency, preservation, --check, --remove, --dry-run
# ---------------------------------------------------------------------------
printf '\nI-8  installer: idempotency, crontab preservation, --check\n'

# 1. Install must ADD both entries and leave the pre-existing unrelated entry
#    byte for byte. The shipwright's hourly line living in the same crontab is
#    the actual production risk: a blind `crontab -` would drop it silently and
#    the cross-session reflection loop would just stop, with no artifact.
setup_case install
make_stub 0 0
printf '%s\n' "$UNRELATED" > "${FAKE_CRONTAB}"
run_installer --install >/dev/null 2>&1
rc=$?
after="$(cat "${FAKE_CRONTAB}" 2>/dev/null)"
if [ "$rc" -eq 0 ] \
   && printf '%s\n' "$after" | grep -qxF -- "$UNRELATED" \
   && printf '%s\n' "$after" | grep -qxF -- "@reboot ${EXP_RUNNER}" \
   && printf '%s\n' "$after" | grep -qxF -- "*/5 * * * * ${EXP_RUNNER}"; then
  ok "install adds @reboot and */5 and preserves the unrelated entry"
else
  bad "install adds @reboot and */5 and preserves the unrelated entry" \
      "rc=$rc crontab now: ${after}"
fi

# 2. A second install must be a byte-identical no-op. Idempotency here is not
#    tidiness: cron runs EVERY matching line, so a duplicated */5 entry is a
#    second supervisor invocation every five minutes forever.
before="$(cat "${FAKE_CRONTAB}")"
run_installer --install >/dev/null 2>&1
again="$(cat "${FAKE_CRONTAB}")"
if [ "$before" = "$again" ]; then
  ok "a second install is a byte-identical no-op (no duplicated entries)"
else
  bad "a second install is a byte-identical no-op (no duplicated entries)" \
      "crontab changed on re-install: ${again}"
fi

# 3. Exactly one of each line, not merely "at least one".
n_reboot="$(grep -cxF -- "@reboot ${EXP_RUNNER}" "${FAKE_CRONTAB}")"
n_relaunch="$(grep -cxF -- "*/5 * * * * ${EXP_RUNNER}" "${FAKE_CRONTAB}")"
if [ "$n_reboot" = "1" ] && [ "$n_relaunch" = "1" ]; then
  ok "each entry appears exactly once after two installs"
else
  bad "each entry appears exactly once after two installs" \
      "@reboot x${n_reboot}, */5 x${n_relaunch}"
fi

# 4. --check is the read-only report an agent or CI is allowed to run.
out="$(run_installer --check 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^OK'; then
  ok "--check reports OK and exits 0 while both entries are installed"
else
  bad "--check reports OK and exits 0 while both entries are installed" \
      "rc=$rc out=${out}"
fi

# 5. --check must not mutate. A "read-only" check that rewrites the crontab is
#    the worst kind of safe-looking command.
if [ "$(cat "${FAKE_CRONTAB}")" = "$again" ]; then
  ok "--check does not modify the crontab"
else
  bad "--check does not modify the crontab" "crontab changed under --check"
fi

# 6. --dry-run must change nothing, on a crontab that does NOT yet have the
#    entries — the case where a broken dry-run would actually write.
setup_case dryrun
make_stub 0 0
printf '%s\n' "$UNRELATED" > "${FAKE_CRONTAB}"
snapshot="$(cat "${FAKE_CRONTAB}")"
out="$(run_installer --install --dry-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && [ "$(cat "${FAKE_CRONTAB}")" = "$snapshot" ] \
   && printf '%s' "$out" | grep -q 'dry-run'; then
  ok "--dry-run previews and changes nothing"
else
  bad "--dry-run previews and changes nothing" \
      "rc=$rc crontab=$(cat "${FAKE_CRONTAB}")"
fi

# 7. Flag order must not matter (repo convention: flags and positionals are
#    order-independent).
out="$(run_installer --dry-run --install 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "${FAKE_CRONTAB}")" = "$snapshot" ]; then
  ok "--dry-run before --install is accepted (options are order-independent)"
else
  bad "--dry-run before --install is accepted (options are order-independent)" \
      "rc=$rc"
fi

# 8. --remove takes OUR entries and only ours.
setup_case remove
make_stub 0 0
printf '%s\n' "$UNRELATED" > "${FAKE_CRONTAB}"
run_installer --install >/dev/null 2>&1
run_installer --remove >/dev/null 2>&1
rc=$?
after="$(cat "${FAKE_CRONTAB}" 2>/dev/null)"
if [ "$rc" -eq 0 ] \
   && printf '%s\n' "$after" | grep -qxF -- "$UNRELATED" \
   && ! printf '%s\n' "$after" | grep -qF -- "${EXP_RUNNER}"; then
  ok "--remove deletes both of our entries and keeps the unrelated one"
else
  bad "--remove deletes both of our entries and keeps the unrelated one" \
      "rc=$rc crontab now: ${after}"
fi

# 9. After removal --check must FAIL LOUDLY with an actionable Fix:. A --check
#    that stayed quiet would let the client sit unscheduled indefinitely, which
#    is the silent-failure mode this whole facility exists to close.
err="$(run_installer --check 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$err" | grep -q 'MISSING' \
   && printf '%s' "$err" | grep -q 'Fix:'; then
  ok "--check exits 1 with MISSING and a Fix: line when the entries are gone"
else
  bad "--check exits 1 with MISSING and a Fix: line when the entries are gone" \
      "rc=$rc stderr=${err}"
fi

# 10. --check on a machine with NO crontab at all must report missing, not
#     crash on crontab(1)'s "no crontab for user" exit 1.
setup_case nocrontab
make_stub 0 0
rm -f "${FAKE_CRONTAB}"
err="$(run_installer --check 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'Fix:'; then
  ok "--check handles an absent crontab as MISSING, with a Fix: line"
else
  bad "--check handles an absent crontab as MISSING, with a Fix: line" \
      "rc=$rc stderr=${err}"
fi

# 11. An unknown flag must be refused with a Fix:, not silently ignored — a
#     typo'd flag that falls through to the default would INSTALL when the
#     operator asked for something else.
setup_case badflag
make_stub 0 0
err="$(run_installer --instal 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'Fix:'; then
  ok "an unknown installer flag exits 1 with a Fix: line"
else
  bad "an unknown installer flag exits 1 with a Fix: line" "rc=$rc stderr=${err}"
fi

# 12. The help text IS the leading comment block. If the awk extractor breaks,
#     --help prints nothing and the script becomes undocumented in place.
out="$(run_installer --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -- '--self-test'; then
  ok "installer --help prints the header block (the awk extractor works)"
else
  bad "installer --help prints the header block (the awk extractor works)" \
      "rc=$rc out=${out}"
fi

out="$(bash "${RUNNER}" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'Exit codes'; then
  ok "runner --help prints the header block"
else
  bad "runner --help prints the header block" "rc=$rc out=${out}"
fi

# 13. The installer must refuse to schedule a launcher that is not there. A
#     crontab entry pointing at a missing client is a job that fails every five
#     minutes and mails the failure — or, with output discipline, says nothing.
setup_case nolauncher
printf '%s\n' "$UNRELATED" > "${FAKE_CRONTAB}"
err="$(PATH="${SHIMBIN}:${PATH}" ATHENA_INBOX_CLIENT_LAUNCHER="${CASE_DIR}/absent" \
        ATHENA_INBOX_CLIENT_RUNNER_DIR="${EXP_RUNNER_DIR}" \
        bash "${INSTALLER}" --install 2>&1 >/dev/null)"; rc=$?
# ...and the message must name the LAUNCHER, so this cannot pass by exiting 2
# for some other missing prerequisite.
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'Fix:' \
   && printf '%s' "$err" | grep -q 'launcher'; then
  ok "install refuses a missing client launcher with exit 2 and a Fix: line"
else
  bad "install refuses a missing client launcher with exit 2 and a Fix: line" \
      "rc=$rc stderr=${err}"
fi

# 14. The scheduled command must name the MAIN CHECKOUT's runner, never the
#     worktree the installer happened to be run from. Captains run from
#     ~/.local/worktrees/custom/<branch>, and `wt` deletes that path on cleanup
#     — cron would then fire a job pointing at a file that no longer exists,
#     silently, with nothing supervising the client. This is the 2026-09-17
#     outage class that `scripts/setup-hooks` already fixed for hook wiring.
#     Exercised against a REAL git repo with a REAL `git worktree`, built in the
#     tmpdir, so the assertion is about the resolver and not about wherever this
#     suite happens to be checked out.
setup_case worktree_path
make_stub 0 0
printf '%s\n' "$UNRELATED" > "${FAKE_CRONTAB}"
MAIN="${CASE_DIR}/main"
mkdir -p "${MAIN}/scripts"
cp "${RUNNER}" "${INSTALLER}" "${MAIN}/scripts/"
git -C "${MAIN}" init -q 2>/dev/null
git -C "${MAIN}" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "${MAIN}" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "${MAIN}" worktree add -q -b wt-branch "${CASE_DIR}/wt" >/dev/null 2>&1
WT_INSTALLER="${CASE_DIR}/wt/scripts/setup-athena-inbox-client"
MAIN_REAL="$(cd -- "${MAIN}" && pwd -P)"
WT_REAL="$(cd -- "${CASE_DIR}/wt" && pwd -P)"

if [ -x "${WT_INSTALLER}" ]; then
  PATH="${SHIMBIN}:${PATH}" ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
    bash "${WT_INSTALLER}" --install >/dev/null 2>&1
  after="$(cat "${FAKE_CRONTAB}" 2>/dev/null)"
  if printf '%s\n' "$after" | grep -qF -- "${MAIN_REAL}/scripts/athena-inbox-client-run.sh" \
     && ! printf '%s\n' "$after" | grep -qF -- "${WT_REAL}/scripts/"; then
    ok "installing from a worktree schedules the MAIN checkout's runner path"
  else
    bad "installing from a worktree schedules the MAIN checkout's runner path" \
        "crontab now: ${after}"
  fi
else
  bad "installing from a worktree schedules the MAIN checkout's runner path" \
      "could not create a git worktree fixture at ${CASE_DIR}/wt"
fi

# A FAILED crontab write must fail the install loudly. Without a status check
# the script (which runs without `set -e`) falls through to "installed:" and
# exits 0 — claiming success while leaving the client unscheduled, which is the
# very silent-failure class this facility exists to close. It is also the
# LIKELY failure on this box: the per-user spool dir being missing or wrong,
# which this installer deliberately does not repair (that needs root).
setup_case write_fails
make_stub 0 0
printf '%s\n' "$UNRELATED" > "${FAKE_CRONTAB}"
snapshot="$(cat "${FAKE_CRONTAB}")"
out="$(CRONTAB_SHIM_FAIL=1 run_installer --install 2>/dev/null)"; rc=$?
err="$(CRONTAB_SHIM_FAIL=1 run_installer --install 2>&1 >/dev/null)"
if [ "$rc" -eq 2 ] \
   && printf '%s' "$err" | grep -q 'Fix:' \
   && ! printf '%s' "$out" | grep -q 'installed:' \
   && [ "$(cat "${FAKE_CRONTAB}")" = "$snapshot" ]; then
  ok "a failed crontab write exits 2 with a Fix: and never claims 'installed'"
else
  bad "a failed crontab write exits 2 with a Fix: and never claims 'installed'" \
      "rc=$rc stdout=${out} stderr=${err}"
fi

# ---------------------------------------------------------------------------
# I-9 — exit 2 is a FULL STOP
# ---------------------------------------------------------------------------
printf '\nI-9  supervisor: exit 2 stops permanently and leaves a marker\n'

# 15. THE case this supervisor exists for. Exit 2 is the client's deliberate
#     partial-write stop: bytes landed, the line is a fragment, and the un-acked
#     event is re-pushed IN FULL on reconnect. Relaunching appends that full
#     line after the fragment and corrupts the inbox — the bug PR #18 fixed in
#     the systemd unit with RestartPreventExitStatus=2.
#     MAX_RESTARTS is deliberately 3, not 1: if the exit-2 branch were removed,
#     the generic backoff path would run the stub three times and this case
#     reddens on the count rather than hanging.
setup_case exit2
make_stub 2 0
MIN_BACKOFF=1 MAX_BACKOFF=1 BACKOFF_RESET=120 MAX_RESTARTS=3 \
  run_supervisor >/dev/null 2>&1
rc=$?
n="$(calls)"
if [ "$rc" -eq 0 ] && [ "$n" = "1" ]; then
  ok "exit 2 stops the supervisor after exactly one client run"
else
  bad "exit 2 stops the supervisor after exactly one client run" \
      "rc=$rc client ran ${n} time(s)"
fi

# 16. The stop must leave a durable, human-readable reason. A supervisor that
#     stops silently is indistinguishable from one that was never started.
if [ -s "${STOPFILE}" ] && grep -qi 'partial write' "${STOPFILE}"; then
  ok "exit 2 writes athena-inbox-client.stopped naming the partial write"
else
  bad "exit 2 writes athena-inbox-client.stopped naming the partial write" \
      "stopfile: $(cat "${STOPFILE}" 2>/dev/null || echo '<absent>')"
fi

# 17. The marker must carry the RECOVERY steps, not just the diagnosis —
#     removing the marker alone re-corrupts the file on the next append.
if grep -qi 'fragment' "${STOPFILE}" 2>/dev/null; then
  ok "the stop marker tells the operator to delete the trailing fragment first"
else
  bad "the stop marker tells the operator to delete the trailing fragment first" \
      "stopfile: $(cat "${STOPFILE}" 2>/dev/null || echo '<absent>')"
fi

# 18. The refusal has to SURVIVE the process. The */5 cron entry fires again
#     five minutes later; if the marker is not honoured on a fresh invocation,
#     the permanent stop lasts exactly until the next tick.
MIN_BACKOFF=1 MAX_BACKOFF=1 BACKOFF_RESET=120 MAX_RESTARTS=3 \
  run_supervisor >/dev/null 2>&1
rc=$?
n="$(calls)"
if [ "$rc" -eq 0 ] && [ "$n" = "1" ]; then
  ok "a later invocation refuses to start while the stop marker exists"
else
  bad "a later invocation refuses to start while the stop marker exists" \
      "rc=$rc client ran ${n} time(s) in total"
fi

# A THIRD invocation, which is what makes the rate-limit assertion below
# load-bearing: with only two, there is exactly one refusal opportunity and a
# broken rate limiter counts the same as a working one. (Sabotage S10 measured
# precisely that zero on the first pass.)
MIN_BACKOFF=1 MAX_BACKOFF=1 BACKOFF_RESET=120 MAX_RESTARTS=3 \
  run_supervisor >/dev/null 2>&1

# 19. The refusal is logged with a Fix:, and rate-limited — the */5 entry would
#     otherwise write 288 identical lines a day into the log.
if grep -q 'Fix:' "${LOG}" 2>/dev/null; then
  ok "the refusal is logged with a Fix: line"
else
  bad "the refusal is logged with a Fix: line" "log: $(cat "${LOG}" 2>/dev/null)"
fi
# NOT `$(grep -c … || echo 0)`: with no matches grep -c prints 0 AND exits 1, so
# the fallback appends a second 0 and the diagnostic reads "0\n0 time(s)" — a
# broken-looking test instead of a legible failure.
n_refusals="$(grep -c 'refusing to start' "${LOG}" 2>/dev/null)" || n_refusals=0
if [ "$n_refusals" = "1" ]; then
  ok "the refusal notice is rate-limited to once per marker, not once per tick"
else
  bad "the refusal notice is rate-limited to once per marker, not once per tick" \
      "logged the refusal ${n_refusals} time(s)"
fi

# 20. Clearing the marker must actually restore service. A stop that cannot be
#     undone by the documented recovery is a different bug.
rm -f "${STOPFILE}"
make_stub 0 0
MIN_BACKOFF=1 MAX_BACKOFF=1 BACKOFF_RESET=120 MAX_RESTARTS=3 \
  run_supervisor >/dev/null 2>&1
if [ "$(calls)" = "2" ]; then
  ok "removing the stop marker lets the supervisor start again"
else
  bad "removing the stop marker lets the supervisor start again" \
      "client ran $(calls) time(s) in total"
fi

# ---------------------------------------------------------------------------
# I-10 — a non-2 failure relaunches, with a CAPPED backoff
# ---------------------------------------------------------------------------
printf '\nI-10 supervisor: non-2 exits relaunch with capped exponential backoff\n'

# 21. Any other non-zero exit is a transient fault and must be retried — a
#     supervisor that gives up on the first crash is no supervisor.
setup_case exit1
make_stub 1 0
MIN_BACKOFF=1 MAX_BACKOFF=2 BACKOFF_RESET=120 MAX_RESTARTS=4 \
  run_supervisor >/dev/null 2>&1
rc=$?
n="$(calls)"
if [ "$rc" -eq 0 ] && [ "$n" = "4" ]; then
  ok "exit 1 relaunches the client until the restart bound is reached"
else
  bad "exit 1 relaunches the client until the restart bound is reached" \
      "rc=$rc client ran ${n} time(s), expected 4"
fi

# 22. The delay must GROW — a fixed short retry against a persistently failing
#     dependency is a hot loop wearing a supervisor's clothes.
if grep -q 'restart 1 in 1s' "${LOG}" && grep -q 'restart 2 in 2s' "${LOG}"; then
  ok "the backoff grows exponentially (1s then 2s)"
else
  bad "the backoff grows exponentially (1s then 2s)" \
      "log: $(grep 'restart' "${LOG}" | tr '\n' '|')"
fi

# 23. …and must CAP. Uncapped doubling reaches hours, so a client that recovers
#     is not picked up until long after the fault cleared — the silent-outage
#     failure mode again.
if grep -q 'restart 3 in 2s' "${LOG}" && ! grep -q 'in 4s' "${LOG}"; then
  ok "the backoff is capped at MAX_BACKOFF and never exceeds it"
else
  bad "the backoff is capped at MAX_BACKOFF and never exceeds it" \
      "log: $(grep 'restart' "${LOG}" | tr '\n' '|')"
fi

# 24. A run that STAYED UP is evidence the fault was transient, so the next
#     failure must start from the short delay rather than the cap. Without
#     this, one bad day pins the retry interval at the cap for the life of the
#     supervisor.
setup_case backoff_reset
make_stub 1 1
MIN_BACKOFF=1 MAX_BACKOFF=8 BACKOFF_RESET=1 MAX_RESTARTS=3 \
  run_supervisor >/dev/null 2>&1
if grep -q 'restart 1 in 1s' "${LOG}" \
   && grep -q 'restart 2 in 1s' "${LOG}" \
   && ! grep -q 'in 2s' "${LOG}"; then
  ok "a run lasting at least BACKOFF_RESET resets the backoff to the minimum"
else
  bad "a run lasting at least BACKOFF_RESET resets the backoff to the minimum" \
      "log: $(grep 'restart' "${LOG}" | tr '\n' '|')"
fi

# 25. A CLEAN exit is not a fault. The client exiting 0 means it was asked to
#     stop; relaunching it would make a deliberate shutdown impossible.
setup_case exit0
make_stub 0 0
MIN_BACKOFF=1 MAX_BACKOFF=2 BACKOFF_RESET=120 MAX_RESTARTS=3 \
  run_supervisor >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "1" ]; then
  ok "a clean exit 0 stops the supervisor instead of relaunching"
else
  bad "a clean exit 0 stops the supervisor instead of relaunching" \
      "rc=$rc client ran $(calls) time(s)"
fi

# 26. Missing prerequisites must be refused with exit 2 and a Fix:, not
#     "supervised" into an endless relaunch of a binary that is not there.
setup_case nolauncher_run
: > "${CALLS}"
err="$(ATHENA_INBOX_CLIENT_LAUNCHER="${CASE_DIR}/absent" \
       ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
       bash "${RUNNER}" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'Fix:'; then
  ok "the runner refuses a missing launcher with exit 2 and a Fix: line"
else
  bad "the runner refuses a missing launcher with exit 2 and a Fix: line" \
      "rc=$rc stderr=${err}"
fi

# 27. The log must stay bounded. This is a @reboot-forever process writing to
#     one file; an unbounded log is a slow disk-filling bug that surfaces months
#     later as something else entirely. The trim replaces the inode, so it is
#     only ever safe BETWEEN client runs — a trim racing a live client's held fd
#     would send the client's output into an unlinked file, which looks exactly
#     like a client that has gone quiet.
setup_case trim_log
make_stub 1 0
for i in $(seq 1 60); do
  printf 'filler line %s\n' "$i" >> "${LOG}"
done
env ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
    ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
    ATHENA_INBOX_CLIENT_MAX_LOG_LINES=20 \
    ATHENA_INBOX_CLIENT_MIN_BACKOFF=1 \
    ATHENA_INBOX_CLIENT_MAX_BACKOFF=1 \
    ATHENA_INBOX_CLIENT_MAX_RESTARTS=2 \
    bash "${RUNNER}" >/dev/null 2>&1
n_lines="$(wc -l < "${LOG}" | tr -d ' ')"
if [ "$n_lines" -lt 60 ]; then
  ok "the log is trimmed to its bound between client runs"
else
  bad "the log is trimmed to its bound between client runs" \
      "log still has ${n_lines} lines with MAX_LOG_LINES=20"
fi

# 28. The trim must not lose the NEWEST lines — a bound that kept the oldest
#     would discard exactly the diagnostics an operator came for.
# Exact-line matches: 'filler line 1' is a substring of 'filler line 10', and a
# substring match here would pass whichever end the trim kept.
if grep -qxF 'filler line 60' "${LOG}" && ! grep -qxF 'filler line 1' "${LOG}"; then
  ok "the trim keeps the tail of the log, not the head"
else
  bad "the trim keeps the tail of the log, not the head" \
      "first log line: $(head -n 1 "${LOG}")"
fi

# 29. cron's PATH is minimal, and losing flock(1) would make the single-instance
#     guarantee fail open under cron while every interactive test still passed
#     — invisible in development, load-bearing in production. The runner pins
#     its own PATH for that reason.
#     Note this case can only be reddened by gutting the pin: usrmerge on this
#     box makes /usr/sbin a symlink to bin, so flock resolves through /usr/bin
#     and /bin too. Dropping /usr/sbin alone changes nothing here — recorded as
#     SABOTAGE_RECORDS S28a, a measured zero.
setup_case minimal_path
make_stub 0 0
out="$(env -i HOME="${HOME}" PATH=/bin:/usr/bin XDG_STATE_HOME="${CASE_DIR}/xdg" ATHENA_INBOX_ROOT="${CASE_DIR}/inbox-root" \
        ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
        ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
        ATHENA_INBOX_CLIENT_MAX_RESTARTS=1 \
        bash "${RUNNER}" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "1" ] \
   && ! printf '%s' "$out" | grep -q 'flock'; then
  ok "the runner finds flock under a cron-like minimal PATH"
else
  bad "the runner finds flock under a cron-like minimal PATH" \
      "rc=$rc ran $(calls) time(s) out=${out}"
fi

# ---------------------------------------------------------------------------
# I-11 — the flock is what keeps ONE writer on the inbox
# ---------------------------------------------------------------------------
printf '\nI-11 supervisor: the flock prevents a duplicate client\n'

# 30. The */5 relaunch entry fires while the client is healthy, every five
#     minutes, forever. If the lock does not hold, that entry is not a safety
#     net — it is a machine for creating a second writer on a file the delivery
#     contract says has exactly one designated consumer.
setup_case flock
make_stub 0 30
# Launched via `env`, NOT via the run_supervisor helper: backgrounding a shell
# FUNCTION forks a subshell, so `$!` would name the subshell and the runner
# would be its child — signalling `$!` would then leave the real supervisor and
# its client alive. `env` execs in place, so `$!` is the supervisor itself.
env ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
    ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
    ATHENA_INBOX_CLIENT_MIN_BACKOFF=1 \
    ATHENA_INBOX_CLIENT_MAX_BACKOFF=2 \
    ATHENA_INBOX_CLIENT_BACKOFF_RESET=120 \
    ATHENA_INBOX_CLIENT_MAX_RESTARTS=5 \
    bash "${RUNNER}" >/dev/null 2>&1 &
SUPERVISOR_PID=$!
# MAX_RESTARTS is 5, not 1, and that is load-bearing for the SIGTERM case
# below ("SIGTERM stops the supervisor without relaunching the client"): with a bound
# of 1 the supervisor stops after reaping its client no matter how the TERM
# handler behaves, so a handler that reaps-and-relaunches would pass. Sabotage
# S7 measured that zero on the first pass. With headroom to restart, only a
# handler that actually EXITS keeps the client count at 1.

if wait_for_nonempty "${CALLS}" 100; then
  out="$(timeout 10 env \
            ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
            ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
            ATHENA_INBOX_CLIENT_MAX_RESTARTS=1 \
            bash "${RUNNER}" 2>&1)"; rc=$?
  n="$(calls)"
  if [ "$rc" -eq 0 ] && [ "$n" = "1" ]; then
    ok "a second invocation exits 0 without starting a duplicate client"
  else
    bad "a second invocation exits 0 without starting a duplicate client" \
        "rc=$rc client ran ${n} time(s); rc=124 would mean it blocked, 2 means it started"
  fi

  # 31. The no-op path must be SILENT. cron mails any output a job produces, so
  #     a chatty healthy path turns the safety net into 288 mails a day and the
  #     operator stops reading them — including the one that matters.
  if [ -z "$out" ]; then
    ok "the locked-out invocation prints nothing (cron mails any output)"
  else
    bad "the locked-out invocation prints nothing (cron mails any output)" \
        "printed: ${out}"
  fi

  # 32. The pidfile must name the LIVE supervisor, so the documented "kill the
  #     pid in the pidfile" recovery targets the right process.
  recorded="$(cat "${STATE_DIR}/athena-inbox-client.pid" 2>/dev/null | tr -d ' ')"
  if [ "$recorded" = "$SUPERVISOR_PID" ]; then
    ok "the pidfile records the supervisor that holds the lock"
  else
    bad "the pidfile records the supervisor that holds the lock" \
        "pidfile=${recorded} supervisor=${SUPERVISOR_PID}"
  fi

  # 33. SIGTERM must stop the SUPERVISOR, not just its current client. A TERM
  #     handler that reaps the child and falls back into the supervise loop
  #     relaunches the client the operator just stopped — and the operator has
  #     no way to tell, because the pidfile still looks right.
  kill "$SUPERVISOR_PID" 2>/dev/null
  wait "$SUPERVISOR_PID" 2>/dev/null
  SUPERVISOR_PID=""
  # Longer than MIN_BACKOFF, so a supervisor that wrongly fell back into the
  # loop has had time to relaunch and be counted.
  sleep 2
  n="$(calls)"
  if [ "$n" = "1" ]; then
    ok "SIGTERM stops the supervisor without relaunching the client"
  else
    bad "SIGTERM stops the supervisor without relaunching the client" \
        "client ran ${n} time(s) after the supervisor was terminated"
  fi

  # 34. And the child must not outlive it. An orphaned client reparented to
  #     init keeps writing to the inbox with nothing supervising it, and the
  #     next supervisor takes the lock and becomes a second writer (PT-919 is
  #     the same species of failure).
  client_pid="$(cat "${STUB_PID}" 2>/dev/null | tr -d ' ')"
  if [ -n "$client_pid" ] && ! kill -0 "$client_pid" 2>/dev/null; then
    ok "the client is reaped with the supervisor, never orphaned"
  else
    bad "the client is reaped with the supervisor, never orphaned" \
        "client pid ${client_pid:-<unrecorded>} is still alive"
  fi
else
  bad "a second invocation exits 0 without starting a duplicate client" \
      "the backgrounded supervisor never started the stub client"
  kill "$SUPERVISOR_PID" 2>/dev/null; wait "$SUPERVISOR_PID" 2>/dev/null
  SUPERVISOR_PID=""
fi

# 35. SIGTERM must be honoured DURING the backoff sleep, not just while the
#     client is running. Bash defers a trapped signal until the current
#     FOREGROUND command completes, so a plain `sleep "$backoff"` swallows TERM
#     for up to MAX_BACKOFF — 300s in production. The operator's documented
#     recovery would appear to do nothing for five minutes, which reads as a
#     wedged supervisor and invites a kill -9 that skips the reaper entirely.
setup_case term_during_backoff
make_stub 1 0
env ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
    ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
    ATHENA_INBOX_CLIENT_MIN_BACKOFF=30 \
    ATHENA_INBOX_CLIENT_MAX_BACKOFF=30 \
    ATHENA_INBOX_CLIENT_BACKOFF_RESET=120 \
    ATHENA_INBOX_CLIENT_MAX_RESTARTS=9 \
    bash "${RUNNER}" >/dev/null 2>&1 &
SUPERVISOR_PID=$!

# The stub exits 1 immediately, so once it has run once the supervisor is in
# its 30s backoff — the window under test.
if wait_for_nonempty "${CALLS}" 100; then
  sleep 1
  started="$(date +%s)"
  kill "$SUPERVISOR_PID" 2>/dev/null
  # Bounded: if TERM is being swallowed this returns when the timeout lapses
  # rather than hanging the suite.
  timeout 10 tail --pid="$SUPERVISOR_PID" -f /dev/null >/dev/null 2>&1
  elapsed=$(( $(date +%s) - started ))
  if kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
    bad "SIGTERM is honoured during the backoff sleep, not deferred until it ends" \
        "still alive ${elapsed}s after TERM (MIN_BACKOFF was 30s)"
    kill -9 "$SUPERVISOR_PID" 2>/dev/null
  else
    ok "SIGTERM is honoured during the backoff sleep, not deferred until it ends"
  fi
  wait "$SUPERVISOR_PID" 2>/dev/null
  SUPERVISOR_PID=""
else
  bad "SIGTERM is honoured during the backoff sleep, not deferred until it ends" \
      "the backgrounded supervisor never ran the stub client"
  kill "$SUPERVISOR_PID" 2>/dev/null; wait "$SUPERVISOR_PID" 2>/dev/null
  SUPERVISOR_PID=""
fi

# A SIGKILLed supervisor leaves the client running, because SIGKILL skips the
# reaper by design — and `kill -9` is exactly what an operator reaches for when
# a stop appears not to work. Two things must then hold, and they pull against
# each other:
#
#   * the next invocation must NOT be locked out. If the client inherited the
#     lock descriptor it would hold the flock for its whole life, every later
#     cron tick would exit 0 in silence, and nothing would ever supervise
#     again — the unsupervised-client state the facility exists to prevent.
#   * and it must NOT simply start a second client alongside the orphan, which
#     would put two writers on an inbox the contract says has one consumer.
#
# So: the client is started with fd 9 closed, and the orphan is terminated
# before a new one starts.
setup_case orphan_after_sigkill
make_stub 0 30
env ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
    ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
    ATHENA_INBOX_CLIENT_MAX_RESTARTS=1 \
    bash "${RUNNER}" >/dev/null 2>&1 &
SUPERVISOR_PID=$!

if wait_for_nonempty "${STUB_PID}" 100; then
  orphan="$(tr -d '[:space:]' < "${STUB_PID}")"
  kill -9 "$SUPERVISOR_PID" 2>/dev/null
  wait "$SUPERVISOR_PID" 2>/dev/null
  SUPERVISOR_PID=""

  if kill -0 "$orphan" 2>/dev/null; then
    ok "SIGKILLing the supervisor leaves the client orphaned (the premise)"
  else
    bad "SIGKILLing the supervisor leaves the client orphaned (the premise)" \
        "client ${orphan} died with the supervisor; the case proves nothing"
  fi

  # A fresh invocation, exactly as the */5 cron entry would make it. The stub is
  # regenerated to exit at once: the orphan is still running the 30s one, and a
  # second long client would only make this case measure the timeout.
  make_stub 0 0
  out="$(timeout 30 env \
          ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
          ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
          ATHENA_INBOX_CLIENT_MAX_RESTARTS=1 \
          bash "${RUNNER}" 2>&1)"; rc=$?
  new_client="$(tr -d '[:space:]' < "${STUB_PID}" 2>/dev/null)"

  if [ "$rc" -ne 0 ] || [ "$(calls)" = "1" ]; then
    bad "an orphaned client does not lock out the next supervisor forever" \
        "rc=$rc ran $(calls) time(s) — the orphan still holds the lock"
  else
    ok "an orphaned client does not lock out the next supervisor forever"
  fi

  if ! kill -0 "$orphan" 2>/dev/null; then
    ok "the orphaned client is terminated, never left running beside a new one"
  else
    bad "the orphaned client is terminated, never left running beside a new one" \
        "orphan ${orphan} and new client ${new_client} are both alive — two writers"
    kill -9 "$orphan" 2>/dev/null
  fi

  # Asserted against the LOG, not stdout/stderr: `say` only echoes to stderr
  # when a human is watching (`[ -t 2 ]`), and under cron nothing is.
  if grep -q 'orphaned client' "${LOG}" 2>/dev/null; then
    ok "the orphan takeover is recorded in the log rather than done silently"
  else
    bad "the orphan takeover is recorded in the log rather than done silently" \
        "log: $(tail -n 3 "${LOG}" 2>/dev/null | tr '\n' '|')"
  fi
else
  bad "an orphaned client does not lock out the next supervisor forever" \
      "the backgrounded supervisor never recorded a client pid"
  kill -9 "$SUPERVISOR_PID" 2>/dev/null; wait "$SUPERVISOR_PID" 2>/dev/null
  SUPERVISOR_PID=""
fi

# ---------------------------------------------------------------------------
printf '\nI-12 supervisor: client-owned log rotation and the dump directory (DND-316)\n'

# 36. The LV-1 client's size-capped rotation is DORMANT until the supervisor
#     names its log file. Unset, a tight reconnect loop can fill the disk through
#     an unbounded stderr append (the gen_saas LV-1 dependency note).
setup_case client_log_env
cat > "${STUB}" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\${ATHENA_INBOX_CLIENT_LOG:-<unset>}" > '${CASE_DIR}/seen-log'
d="\${XDG_STATE_HOME}/athena/inbox-client-dumps"
if [ -d "\$d" ]; then stat -c '%a' "\$d" > '${CASE_DIR}/seen-dump-mode'; else echo absent > '${CASE_DIR}/seen-dump-mode'; fi
exit 0
STUBEOF
chmod +x "${STUB}"
MAX_RESTARTS=1 run_supervisor >/dev/null 2>&1
if [ "$(cat "${CASE_DIR}/seen-log" 2>/dev/null)" = "${LOG}" ]; then
  ok "the client is started with ATHENA_INBOX_CLIENT_LOG naming the supervised log"
else
  bad "the client is started with ATHENA_INBOX_CLIENT_LOG naming the supervised log" \
      "client saw: $(cat "${CASE_DIR}/seen-log" 2>/dev/null)"
fi

# 37. The dump directory exists, 0700, BEFORE the client runs. The client makes
#     it lazily on its first dump, so until then "no dumps" and "dump path
#     broken" read the same.
if [ "$(cat "${CASE_DIR}/seen-dump-mode" 2>/dev/null)" = "700" ]; then
  ok "the dump directory exists (0700) before the client starts"
else
  bad "the dump directory exists (0700) before the client starts" \
      "client saw: $(cat "${CASE_DIR}/seen-dump-mode" 2>/dev/null)"
fi

# 38. A missing liveness library DEGRADES the supervisor, it never stops it:
#     delivery outranks diagnostics, so a missing diagnostic tool must not be
#     the reason the relay goes dark. The client is still started, and the gap
#     is said loudly — on stderr (cron mails it) with a Fix:, and in the log.
setup_case no_liveness_lib
make_stub 0 0
mkdir -p "${CASE_DIR}/lonely/scripts"
cp "${RUNNER}" "${CASE_DIR}/lonely/scripts/athena-inbox-client-run.sh"
cp "${SCRIPTS}/inbox-client-capture" "${CASE_DIR}/lonely/scripts/inbox-client-capture"
err="$(XDG_STATE_HOME="${CASE_DIR}/xdg" ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
  ATHENA_INBOX_CLIENT_MAX_RESTARTS=1 bash "${CASE_DIR}/lonely/scripts/athena-inbox-client-run.sh" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" = "1" ] && printf '%s' "$err" | grep -q 'liveness library is missing' \
   && printf '%s' "$err" | grep -q 'Fix:' && grep -q 'DEGRADED: the liveness library is missing' "${LOG}"; then
  ok "a missing liveness library still supervises the client, and says so (stderr Fix: + log)"
else
  bad "a missing liveness library still supervises the client, and says so (stderr Fix: + log)" "rc=$rc calls=$(calls) err=${err}"
fi

# 38b. Same for the capture tool: the client is still supervised and the gap is
#      loud. A watchdog pass on a WEDGED client follows the one no-capture rule
#      (a dark relay outranks the evidence): it says NO CAPTURE POSSIBLE and
#      still restarts it, identity-checked. The stub is not ruby, so here the
#      identity check refuses and nothing is signalled -- which is also asserted.
setup_case no_capture_tool
make_stub 0 30
mkdir -p "${CASE_DIR}/lonely/scripts" "${CASE_DIR}/lonely/ai/skills/athena:inbox/lib"
cp "${RUNNER}" "${CASE_DIR}/lonely/scripts/athena-inbox-client-run.sh"
cp "${SCRIPTS}/../ai/skills/athena:inbox/lib/liveness.sh" "${CASE_DIR}/lonely/ai/skills/athena:inbox/lib/"
env XDG_STATE_HOME="${CASE_DIR}/xdg" ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
    ATHENA_INBOX_CLIENT_MAX_RESTARTS=1 bash "${CASE_DIR}/lonely/scripts/athena-inbox-client-run.sh" >/dev/null 2>"${CASE_DIR}/err" &
SUPERVISOR_PID=$!
if wait_for_nonempty "${CALLS}" 100; then
  printf '%s INFO step dns 2ms\n' "$(date -u -d "@$(( $(date -u +%s) - 600 ))" +%Y-%m-%dT%H:%M:%SZ)" >> "${LOG}"
  timeout 30 env XDG_STATE_HOME="${CASE_DIR}/xdg" ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
      bash "${CASE_DIR}/lonely/scripts/athena-inbox-client-run.sh" >/dev/null 2>&1
  if grep -q 'inbox-client-capture is missing' "${CASE_DIR}/err" && grep -q 'Fix:' "${CASE_DIR}/err" \
     && grep -q 'is missing — NO CAPTURE POSSIBLE; restarting anyway' "${LOG}" \
     && grep -q 'WATCHDOG: could not identify the client — pid .* is not the ruby client' "${LOG}" && kill -0 "$(cat "${STUB_PID}")" 2>/dev/null; then
    ok "a missing capture tool still supervises; the watchdog says NO CAPTURE POSSIBLE and still identity-checks before any signal"
  else
    bad "a missing capture tool still supervises; the watchdog says NO CAPTURE POSSIBLE and still identity-checks before any signal" "err=$(cat "${CASE_DIR}/err") log=$(grep -E 'WATCHDOG|DEGRADED' "${LOG}" | tr '\n' '|')"
  fi
else
  bad "a missing capture tool still supervises; the watchdog says NO CAPTURE POSSIBLE and still identity-checks before any signal" "the client never started"
fi
# The stub's own `sleep 30` first, by parent pid, so nothing is orphaned.
pkill -P "$(cat "${STUB_PID}" 2>/dev/null)" 2>/dev/null
kill "$(cat "${STUB_PID}" 2>/dev/null)" 2>/dev/null
kill "${SUPERVISOR_PID}" 2>/dev/null; timeout 15 tail --pid="${SUPERVISOR_PID}" -f /dev/null 2>/dev/null
SUPERVISOR_PID=""

# ---------------------------------------------------------------------------
printf '\nI-13 watchdog: a wedge is CAPTURED, then restarted; a progressing client is never touched (DND-316/333)\n'
#
# The client here is the capture suite's ruby mock (mock-athena-inbox-client.rb)
# started through a launcher that execs it, so the supervisor's child IS the
# ruby process and inbox-client-capture's identity check is the production
# one. The wedge is the LOG's last connect-cycle line — exactly what the
# watchdog reads — backdated past its allowance.
MOCK="${SCRIPTS}/test/inbox-client-capture/mock-athena-inbox-client.rb"
WD_PIDS=()
if ! command -v ruby >/dev/null 2>&1; then
  bad "the watchdog cases need ruby for the mock client" "no ruby on PATH"
else

# start_wd_supervisor <mode> — a supervised mock client. Sets SUPERVISOR_PID
# and CLIENT_PID (the ruby child). Launched via env so $! is the supervisor.
start_wd_supervisor() {
  cat > "${STUB}" <<STUBEOF
#!/bin/sh
exec ruby '${MOCK}'
STUBEOF
  chmod +x "${STUB}"
  rm -f "${CASE_DIR}/ready"
  env XDG_STATE_HOME="${CASE_DIR}/xdg" \
      ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
      ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
      ATHENA_INBOX_CLIENT_CONFIG="${CASE_DIR}/config.json" \
      ATHENA_INBOX_CLIENT_MIN_BACKOFF=1 ATHENA_INBOX_CLIENT_MAX_BACKOFF=1 \
      ATHENA_INBOX_CLIENT_MAX_RESTARTS=3 \
      MOCK_MODE="$1" MOCK_DUMP_DIR="${CASE_DIR}/xdg/athena/inbox-client-dumps" MOCK_LOG="${LOG}" \
      MOCK_READY="${CASE_DIR}/ready" MOCK_TERM_FILE="${CASE_DIR}/term" MOCK_TOKEN="SEKRETtok-watchdog-0123456789" \
      MOCK_IGNORE_TERM="${WD_IGNORE_TERM:-0}" \
      bash "${RUNNER}" >/dev/null 2>&1 &
  SUPERVISOR_PID=$!
  WD_PIDS+=("${SUPERVISOR_PID}")
  CLIENT_PID=""
  if wait_for_nonempty "${CASE_DIR}/ready" 100; then CLIENT_PID="$(cat "${CASE_DIR}/ready")"; WD_PIDS+=("${CLIENT_PID}"); fi
  printf '{"token":"SEKRETtok-watchdog-0123456789"}' > "${CASE_DIR}/config.json"
}
run_watchdog() {
  timeout 60 env XDG_STATE_HOME="${WD_XDG:-${CASE_DIR}/xdg}" \
      ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" \
      ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
      ATHENA_INBOX_CLIENT_CONFIG="${CASE_DIR}/config.json" \
      ATHENA_INBOX_CAPTURE_DUMP_WAIT="${1:-5}" \
      bash "${RUNNER}" >/dev/null 2>&1
}
stop_wd_supervisor() {
  kill "${SUPERVISOR_PID}" 2>/dev/null
  timeout 15 tail --pid="${SUPERVISOR_PID}" -f /dev/null 2>/dev/null
  # Children first (a stub's `sleep` would be orphaned to PID 1), then the pids.
  local p; for p in "${WD_PIDS[@]}"; do [ -n "${p}" ] && pkill -9 -P "${p}" 2>/dev/null; done
  for p in "${WD_PIDS[@]}"; do [ -n "${p}" ] && kill -9 "${p}" 2>/dev/null; done
  SUPERVISOR_PID=""
}
# install_alert_registry — the COMMITTED custom registry entry (both
# harness-alerts sides), re-keyed to this checkout's git common dir, installed
# into the CASE's inbox root only. Without it the alert send fails (the
# ALERT NOT SENT case relies on that).
REPO_ROOT="$(cd -- "${SCRIPTS}/.." && pwd -P)"
install_alert_registry() {
  local root="${ATHENA_INBOX_ROOT}" common
  common="$(cd -- "${REPO_ROOT}" && realpath -- "$(git rev-parse --git-common-dir)")"
  mkdir -p "${root}/projects"; chmod 700 "${root}" "${root}/projects"
  jq --arg r "${common}" '.projects[] | select(.file == "custom.json") | .entry | .repo = $r' \
    "${REPO_ROOT}/ai/inbox/registry.json" >"${root}/projects/custom.json"
  chmod 600 "${root}/projects/custom.json"
}
alerts() { find "${ATHENA_INBOX_ROOT}/harness-alerts/to-custom" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort; }
line_of() { grep -n "$1" "${LOG}" | head -n1 | cut -d: -f1; }
backdated() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
caps() { find "${CASE_DIR}/xdg/athena/inbox-client-dumps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort; }

# 39. A PROGRESSING client — connected, quiet for an hour — is never captured
#     and never signalled. A watchdog that killed idle healthy clients would be
#     worse than none.
setup_case wd_progressing
start_wd_supervisor dump
printf '%s INFO joined machine:self; instances: []\n' "$(backdated 3600)" >> "${LOG}"
run_watchdog
if [ -n "${CLIENT_PID}" ] && kill -0 "${CLIENT_PID}" 2>/dev/null && [ ! -e "${CASE_DIR}/term" ] && [ -z "$(caps)" ]; then
  ok "a connected, quiet client is neither captured nor killed"
else
  bad "a connected, quiet client is neither captured nor killed" "client=${CLIENT_PID} term=$(cat "${CASE_DIR}/term" 2>/dev/null) caps=$(caps)"
fi
stop_wd_supervisor

# 40-43. THE WEDGE: captured FIRST, then SIGTERM, then relaunched.
setup_case wd_wedge
install_alert_registry
start_wd_supervisor dump
FIRST_CLIENT="${CLIENT_PID}"
printf '%s INFO step tcp_connect 30ms\n' "$(backdated 600)" >> "${LOG}"
# Clear the ready file BEFORE the watchdog, never after: the watchdog now
# sends its alert after the SIGTERM (DND-334), so the relaunched client can
# write its ready file while run_watchdog is still returning -- an rm after it
# would delete the very evidence of the relaunch (measured: one red under load).
rm -f "${CASE_DIR}/ready"
run_watchdog
CAPDIR="$(caps | tail -n 1)"
if [ -n "${CAPDIR}" ] && [ -s "${CAPDIR}/dump.txt" ] && [ -s "${CAPDIR}/socket.txt" ] && [ -s "${CAPDIR}/fds.txt" ] \
   && [ -s "${CAPDIR}/log-tail.txt" ] && [ -s "${CAPDIR}/signature.txt" ] && grep -q '^step: tls$' "${CAPDIR}/signature.txt"; then
  ok "a wedged client is captured: dump + sockets + fds + log tail + signature (step tls)"
else
  bad "a wedged client is captured: dump + sockets + fds + log tail + signature (step tls)" "cap=${CAPDIR} $(command ls "${CAPDIR}" 2>/dev/null | tr '\n' ' ')"
fi
FIN="$(sed -n 's/^finished_ms: //p' "${CAPDIR}/capture.txt" 2>/dev/null)"
TERM_AT="$(cat "${CASE_DIR}/term" 2>/dev/null)"
if [ -n "${FIN}" ] && [ -n "${TERM_AT}" ] && [ "${FIN}" -le "${TERM_AT}" ]; then
  ok "the capture FINISHED before the client received SIGTERM (${FIN} <= ${TERM_AT} ms) — never restart first"
else
  bad "the capture FINISHED before the client received SIGTERM — never restart first" "finished_ms=${FIN:-none} term_ms=${TERM_AT:-none}"
fi
if grep -q 'WATCHDOG: client pid .* WEDGED' "${LOG}" && grep -q 'WATCHDOG: captured ' "${LOG}" && grep -q 'WATCHDOG: SIGTERM client pid' "${LOG}" \
   && [ "$(grep -n 'WATCHDOG: captured ' "${LOG}" | head -n1 | cut -d: -f1)" -lt "$(grep -n 'WATCHDOG: SIGTERM' "${LOG}" | head -n1 | cut -d: -f1)" ]; then
  ok "the log records wedge -> captured -> SIGTERM, in that order, with the signature"
else
  bad "the log records wedge -> captured -> SIGTERM, in that order" "$(grep WATCHDOG "${LOG}" | tr '\n' '|')"
fi
if wait_for_nonempty "${CASE_DIR}/ready" 100 && [ "$(cat "${CASE_DIR}/ready")" != "${FIRST_CLIENT}" ] && kill -0 "${SUPERVISOR_PID}" 2>/dev/null; then
  WD_PIDS+=("$(cat "${CASE_DIR}/ready")")
  ok "the owning supervisor relaunched a NEW client after the SIGTERM"
else
  bad "the owning supervisor relaunched a NEW client after the SIGTERM" "ready=$(cat "${CASE_DIR}/ready" 2>/dev/null) first=${FIRST_CLIENT}"
fi
if grep -rqF 'SEKRETtok' "${CAPDIR}" 2>/dev/null; then bad "the watchdog's capture carries no machine token" "token found"; else ok "the watchdog's capture carries no machine token"; fi
# DND-334: step 5, the harness-alerts message — AFTER the restart, ONE of it.
if grep -q '^uptime_s: [0-9]' "${CAPDIR}/capture.txt" && grep -q '^reconnecting_since: [0-9]* (' "${CAPDIR}/capture.txt" \
   && grep -q '^connected_since: [0-9]* (' "${CAPDIR}/capture.txt"; then
  ok "the capture manifest records uptime and the reconnecting/connected counts (DND-334)"
else bad "the capture manifest records uptime and the counts" "$(cat "${CAPDIR}/capture.txt")"; fi
AL="$(alerts)"
if [ "$(printf '%s\n' "${AL}" | grep -c .)" -eq 1 ] && grep -qx 'from: inbox-client-detector' "${AL}" && grep -qx "re: ${CAPDIR}" "${AL}" \
   && ! grep -qF 'SEKRETtok' "${AL}"; then
  ok "the watchdog dropped ONE harness-alerts message from inbox-client-detector, re: the capture, no token"
else bad "the watchdog dropped ONE harness-alerts message" "alerts=${AL} log=$(grep WATCHDOG "${LOG}" | tr '\n' '|')"; fi
if [ -n "$(line_of 'WATCHDOG: alert sent on harness-alerts')" ] && [ "$(line_of 'WATCHDOG: SIGTERM')" -lt "$(line_of 'WATCHDOG: alert sent on harness-alerts')" ]; then
  ok "the alert is sent only AFTER the SIGTERM: a send can never delay the restart"
else bad "the alert is sent only after the SIGTERM" "$(grep WATCHDOG "${LOG}" | tr '\n' '|')"; fi
printf '[]' >"${CASE_DIR}/none.json"
D="$(bash "${REPO_ROOT}/ai/skills/athena:inbox-attend/bin/wedge-ticket-decide" --message "${AL}" --tickets "${CASE_DIR}/none.json" 2>&1)"
if printf '%s\n' "${D}" | grep -qx 'decision	create' && printf '%s\n' "${D}" | grep -qx "sig8	$(sed -n 's/^signature: //p' "${CAPDIR}/signature.txt" | cut -c1-8)"; then
  ok "end to end: a REAL capture's alert verifies against the capture and resolves create"
else bad "end to end: a real capture's alert verifies and resolves create" "${D}"; fi
stop_wd_supervisor

# 44. A client that IGNORES SIGQUIT: the capture records the absent dump and
#     the client is STILL restarted — an absent dump is evidence, not a reason
#     to leave a wedged client up.
setup_case wd_ignore
start_wd_supervisor ignore
printf '%s INFO reconnecting in 1.0s\n' "$(backdated 600)" >> "${LOG}"
rm -f "${CASE_DIR}/ready"   # before the watchdog: see case 40-43
run_watchdog 2
CAPDIR="$(caps | tail -n 1)"
if [ -n "${CAPDIR}" ] && grep -q '^dump: absent (handler did not respond within 2s)$' "${CAPDIR}/capture.txt" && [ -s "${CASE_DIR}/term" ]; then
  ok "an ignored SIGQUIT is recorded as 'dump: absent', and the client is still restarted"
else
  bad "an ignored SIGQUIT is recorded as 'dump: absent', and the client is still restarted" "cap=${CAPDIR} term=$(cat "${CASE_DIR}/term" 2>/dev/null)"
fi
# DND-334: this case's inbox root has NO registry entry, so the alert send
# fails. It must be loud (with a Fix:) and must not have held up the restart.
if [ -n "$(line_of 'WATCHDOG: ALERT NOT SENT')" ] && grep -q 'SUPERVISOR   Fix: .*inbox-client-alert' "${LOG}" \
   && [ "$(line_of 'WATCHDOG: SIGTERM')" -lt "$(line_of 'WATCHDOG: ALERT NOT SENT')" ] && [ -s "${CASE_DIR}/term" ] && [ -z "$(alerts)" ]; then
  ok "a failed alert send is logged loudly with a Fix:, after the restart, which it never blocked"
else bad "a failed alert send is logged loudly with a Fix:, after the restart" "$(grep -A1 'WATCHDOG' "${LOG}" | tr '\n' '|')"; fi

# 45. The same wedge line is acted on ONCE. The restart writes new lines, so a
#     new wedge has a new last line; re-seeing the old one must not capture and
#     kill the fresh client.
n_before="$(caps | wc -l)"
rm -f "${CASE_DIR}/term"
wait_for_nonempty "${CASE_DIR}/ready" 100 && WD_PIDS+=("$(cat "${CASE_DIR}/ready")")
rm -f "${CASE_DIR}/ready"
tail -n 1 "${LOG}" >/dev/null
grep 'INFO reconnecting in 1.0s' "${LOG}" | head -n 1 >> "${LOG}"
run_watchdog 2
if [ "$(caps | wc -l)" = "${n_before}" ] && [ ! -e "${CASE_DIR}/term" ]; then
  ok "the same wedge line is not captured or killed twice"
else
  bad "the same wedge line is not captured or killed twice" "caps ${n_before} -> $(caps | wc -l), term=$(cat "${CASE_DIR}/term" 2>/dev/null)"
fi
stop_wd_supervisor

# 45b. The client DIES during the capture window. Its supervisor relaunches a
#      new client (a new pid) — or its pid is reused. Identity is re-asserted
#      right before the signal, so the watchdog signals NOTHING rather than
#      TERMing the fresh client or an unrelated process.
setup_case wd_dies_mid_capture
install_alert_registry
start_wd_supervisor exit
printf '%s INFO step tls 48ms\n' "$(backdated 600)" >> "${LOG}"
run_watchdog 3
if grep -q 'no longer the supervised client after the capture; not signalling' "${LOG}" && [ ! -e "${CASE_DIR}/term" ] \
   && ! grep -q 'WATCHDOG: SIGTERM' "${LOG}"; then
  ok "a client that died mid-capture is not signalled: identity is re-checked before SIGTERM"
else
  bad "a client that died mid-capture is not signalled: identity is re-checked before SIGTERM" "$(grep WATCHDOG "${LOG}" | tr '\n' '|') term=$(cat "${CASE_DIR}/term" 2>/dev/null)"
fi
# DND-334: nothing was restarted, but a wedge WAS captured -- so it still alerts.
CAPDIR="$(caps | tail -n 1)"; AL="$(alerts)"
if [ -n "${CAPDIR}" ] && [ "$(printf '%s\n' "${AL}" | grep -c .)" -eq 1 ] && grep -qx "re: ${CAPDIR}" "${AL}" \
   && [ "$(line_of 'not signalling')" -lt "$(line_of 'WATCHDOG: alert sent on harness-alerts')" ]; then
  ok "the not-signalling path still sends ONE alert for its capture, after the decision"
else bad "the not-signalling path still sends ONE alert for its capture" "cap=${CAPDIR} alerts=${AL} $(grep WATCHDOG "${LOG}" | tr '\n' '|')"; fi
[ -s "${CASE_DIR}/ready" ] && WD_PIDS+=("$(cat "${CASE_DIR}/ready")")
stop_wd_supervisor

# 45c. A client that IGNORES SIGTERM is escalated to SIGKILL after 10s — and
#      only after its identity is re-checked.
setup_case wd_sigkill
WD_IGNORE_TERM=1 start_wd_supervisor dump
STUBBORN="${CLIENT_PID}"
printf '%s INFO step ws_upgrade 111ms\n' "$(backdated 600)" >> "${LOG}"
run_watchdog 3
if [ -s "${CASE_DIR}/term" ] && grep -q "WATCHDOG: client ${STUBBORN} ignored SIGTERM for 10s; sending SIGKILL" "${LOG}" \
   && ! kill -0 "${STUBBORN}" 2>/dev/null; then
  ok "a client that ignores SIGTERM is SIGKILLed after 10s (identity re-checked first)"
else
  bad "a client that ignores SIGTERM is SIGKILLed after 10s (identity re-checked first)" "$(grep WATCHDOG "${LOG}" | tr '\n' '|') alive=$(kill -0 "${STUBBORN}" 2>/dev/null && echo y || echo n)"
fi
[ -s "${CASE_DIR}/ready" ] && WD_PIDS+=("$(cat "${CASE_DIR}/ready")")
stop_wd_supervisor

# 45d. The capture itself FAILS (no dump directory can be made). The client is
#      still restarted — a dark relay outranks the evidence — but only after
#      the attempt, and the failure is in the log where the capture would be.
setup_case wd_capture_fails
start_wd_supervisor dump
mkdir -p "${CASE_DIR}/badxdg"; : > "${CASE_DIR}/badxdg/athena"
printf '%s INFO step dns 2ms\n' "$(backdated 600)" >> "${LOG}"
WD_XDG="${CASE_DIR}/badxdg" run_watchdog 2
if grep -q 'WATCHDOG: capture FAILED (exit 2' "${LOG}" && grep -q 'restarting anyway' "${LOG}" && [ -s "${CASE_DIR}/term" ] \
   && [ "$(grep -n 'capture FAILED' "${LOG}" | head -n1 | cut -d: -f1)" -lt "$(grep -n 'WATCHDOG: SIGTERM' "${LOG}" | head -n1 | cut -d: -f1)" ]; then
  ok "a failed capture is logged, and only THEN is the client restarted"
else
  bad "a failed capture is logged, and only THEN is the client restarted" "$(grep WATCHDOG "${LOG}" | tr '\n' '|')"
fi
[ -s "${CASE_DIR}/ready" ] && WD_PIDS+=("$(cat "${CASE_DIR}/ready")")
stop_wd_supervisor

# 46. Could not identify the client (the supervisor's child is not the ruby
#     client): NOTHING is captured or signalled, and the log says so in words
#     that are not a capture outcome.
setup_case wd_unidentified
make_stub 0 30
env XDG_STATE_HOME="${CASE_DIR}/xdg" ATHENA_INBOX_CLIENT_LAUNCHER="${STUB}" ATHENA_INBOX_CLIENT_STATE_DIR="${STATE_DIR}" \
    ATHENA_INBOX_CLIENT_MAX_RESTARTS=1 bash "${RUNNER}" >/dev/null 2>&1 &
SUPERVISOR_PID=$!; WD_PIDS+=("${SUPERVISOR_PID}")
wait_for_nonempty "${CALLS}" 100
printf '%s INFO step dns 2ms\n' "$(backdated 600)" >> "${LOG}"
run_watchdog
if grep -q 'could not identify the client' "${LOG}" && [ -z "$(caps)" ] && [ "$(calls)" = "1" ] && kill -0 "$(cat "${STUB_PID}")" 2>/dev/null; then
  ok "an unidentifiable client: 'could not identify', nothing captured, nothing killed"
else
  bad "an unidentifiable client: 'could not identify', nothing captured, nothing killed" "$(grep WATCHDOG "${LOG}" | tr '\n' '|') caps=$(caps)"
fi
WD_PIDS+=("$(cat "${STUB_PID}" 2>/dev/null)")
pkill -9 -P "$(cat "${STUB_PID}" 2>/dev/null)" 2>/dev/null
stop_wd_supervisor

fi

# ---------------------------------------------------------------------------
printf '\n'
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf 'VERDICT: PASS (%d cases)\n' "$TOTAL"
  exit 0
fi
printf 'VERDICT: FAIL (%d of %d cases)\n' "$FAIL" "$TOTAL"
printf '  Fix: read each FAIL above — the claim string names the behaviour it\n'
printf '       protects. Repair scripts/athena-inbox-client-run.sh or\n'
printf '       scripts/setup-athena-inbox-client, then re-run\n'
printf '       scripts/setup-athena-inbox-client --self-test.\n'
exit 1
