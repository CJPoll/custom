#!/usr/bin/env bash
# Self-test for scripts/athena-channel-session.sh + scripts/lib/athena-attend-lib.sh
# (DND-283, T3). Hermetic: fake claude, fake tmux, fake dm, fake inbox-status.
# The REAL claude/tmux are never invoked, no session is ever launched, no
# crontab or live state is touched.
#
# Every assertion is about a decision INVISIBLE in production until it costs
# something:
#   * a launcher that passed the skip-permissions bypass would silently drop the
#     deny-by-default posture the whole trust boundary rests on;
#   * one that leaked CLAUDE_CODE_SESSION_ATTENDED would make inbox-untrusted-guard
#     stop enforcing on the very session that reads untrusted mail;
#   * one that treated an uncountable channel as "idle" would rotate mid-reply or
#     go dark reading a broken channel as empty (the failed-lookup class);
#   * one that launched on an unverified Claude Code version would send a blind
#     keypress into an unknown dialog;
#   * a rotation with no idle gate cuts a reply in half; a dark channel with no
#     restart cap masks a wedge as recovery.
#
# Run: bash scripts/test/athena-channel-session/self-test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
LAUNCHER="${SCRIPTS}/athena-channel-session.sh"
LIB="${SCRIPTS}/lib/athena-attend-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "expected NOT [$2], got [$3]" ;; *) ok "$1" ;; esac; }

# shellcheck source=/dev/null
. "${LIB}"

# ==========================================================================
echo "== pure lib: rotation bounds (each fires alone; n/a never fires) =="
assert_eq "rotation: wakes at cap -> max-wakes"  "max-wakes" "$(attend_rotation_reason 30 30 0 262144 0 86400)"
assert_eq "rotation: bytes at cap -> max-bytes"  "max-bytes" "$(attend_rotation_reason 0 30 262144 262144 0 86400)"
assert_eq "rotation: age at cap -> max-age"      "max-age"   "$(attend_rotation_reason 0 30 0 262144 86400 86400)"
assert_eq "rotation: nothing tripped -> empty"   ""          "$(attend_rotation_reason 0 30 0 262144 0 86400)"
assert_eq "rotation: unmeasurable bytes (n/a) NEVER trips on size" "" \
  "$(attend_rotation_reason 0 30 n/a 1 0 86400)"
assert_eq "rotation: n/a bytes still lets wakes trip" "max-wakes" \
  "$(attend_rotation_reason 30 30 n/a 1 0 86400)"

echo "== pure lib: rotation gate (never while unread / uncountable / not idle / permission open) =="
assert_eq "gate: zero+idle+no-perm -> OPEN" OPEN "$(attend_rotation_gate_open zero 1 0 && echo OPEN || echo BLOCKED)"
assert_eq "gate: unread blocks (mail waiting)" BLOCKED "$(attend_rotation_gate_open unread 1 0 && echo OPEN || echo BLOCKED)"
assert_eq "gate: uncountable blocks (never idle)" BLOCKED "$(attend_rotation_gate_open uncountable 1 0 && echo OPEN || echo BLOCKED)"
assert_eq "gate: not idle blocks (turn in flight)" BLOCKED "$(attend_rotation_gate_open zero 0 0 && echo OPEN || echo BLOCKED)"
assert_eq "gate: permission request open blocks (T5 seam)" BLOCKED "$(attend_rotation_gate_open zero 1 1 && echo OPEN || echo BLOCKED)"

echo "== pure lib: counts key on the normalized count; null/absent = uncountable, never 0 =="
assert_eq "counts: all zero -> zero" "zero" \
  "$(attend_counts_state '{"channels":[{"name":"a","count":0},{"name":"b","count":0}]}')"
assert_eq "counts: some >0 -> unread" "unread" \
  "$(attend_counts_state '{"channels":[{"name":"a","count":0},{"name":"b","count":2}]}')"
OUT="$(attend_counts_state '{"channels":[{"name":"a","count":0},{"name":"b","count":null}]}')"; RC=$?
assert_contains "counts: a null count -> uncountable, names the channel" "uncountable b" "${OUT}"
assert_eq "counts: uncountable returns non-zero" "1" "${RC}"
OUT="$(attend_counts_state '{"channels":[{"name":"a"}]}')"
assert_contains "counts: an ABSENT count is uncountable, not 0" "uncountable a" "${OUT}"
OUT="$(attend_counts_state 'not json')"
assert_contains "counts: unparseable doc is uncountable, never 0" "uncountable (unparseable)" "${OUT}"

echo "== pure lib: a wake is unread->zero (the pre-T4 counter) =="
assert_eq "wake: unread then zero IS a wake" yes "$(attend_wake_completed unread zero && echo yes || echo no)"
assert_eq "wake: zero then zero is NOT a wake" no "$(attend_wake_completed zero zero && echo yes || echo no)"
assert_eq "wake: uncountable then zero is NOT a wake" no "$(attend_wake_completed uncountable zero && echo yes || echo no)"

echo "== pure lib: transcript bytes n/a (never 0) when unmeasurable =="
assert_eq "transcript: missing dir -> n/a" "n/a" "$(attend_transcript_bytes "${TMP}/nope")"
mkdir -p "${TMP}/slug-empty"
assert_eq "transcript: dir with no jsonl -> n/a" "n/a" "$(attend_transcript_bytes "${TMP}/slug-empty")"
mkdir -p "${TMP}/slug"; head -c 5 /dev/zero | tr '\0' x > "${TMP}/slug/s.jsonl"
assert_eq "transcript: a real 5-byte transcript -> 5 (not n/a)" "5" "$(attend_transcript_bytes "${TMP}/slug")"

echo "== pure lib: restart cap 3/hour =="
RL="${TMP}/restarts.log"; : > "${RL}"
attend_restart_allowed "${RL}" 3 3600 1000 && attend_restart_allowed "${RL}" 3 3600 1001 && attend_restart_allowed "${RL}" 3 3600 1002
assert_eq "restart: the first 3 within the window are allowed" 0 "$?"
attend_restart_allowed "${RL}" 3 3600 1003
assert_eq "restart: the 4th within the window is refused (cap hit)" 1 "$?"
# An entry older than the window is pruned, freeing a slot.
printf '%s\n' 100 200 300 > "${RL}"   # all far in the past
attend_restart_allowed "${RL}" 3 3600 100000
assert_eq "restart: entries older than the window are pruned -> allowed again" 0 "$?"

echo "== pure lib: version pin compare, and the channel-state precedence =="
assert_eq "version: exact match ok" ok "$(attend_version_ok 2.1.278 2.1.278 && echo ok || echo no)"
assert_eq "version: mismatch not ok" no "$(attend_version_ok 2.1.279 2.1.278 && echo ok || echo no)"
assert_eq "version: empty actual not ok" no "$(attend_version_ok '' 2.1.278 && echo ok || echo no)"
assert_eq "version: extract from banner" "2.1.278" "$(attend_extract_version 'Claude Code v2.1.278 (foo)')"
SD="${TMP}/cstate"; mkdir -p "${SD}"
assert_eq "state: up + no markers -> registered" registered "$(attend_channel_state "${SD}" 1)"
assert_eq "state: down + no markers -> no-session" no-session "$(attend_channel_state "${SD}" 0)"
attend_write_marker "${SD}" dark x
assert_eq "state: dark marker -> dark (even if up)" dark "$(attend_channel_state "${SD}" 1)"
attend_write_marker "${SD}" wedged x
assert_eq "state: wedged beats dark" wedged "$(attend_channel_state "${SD}" 1)"
assert_not_contains "state: no-session never equals registered" "registered" "no-session"

# ==========================================================================
# Integration with fakes.
# ==========================================================================
FAKES="${TMP}/fakes"; mkdir -p "${FAKES}"

# fake claude: --version returns $FAKE_CLAUDE_VERSION; a session launch logs its
# env (so we can assert CLAUDE_CODE_SESSION_ATTENDED is unset and CLAUDE_AGENT_*
# never leaked) and exits.
cat > "${FAKES}/claude" <<'EOC'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then printf '%s\n' "${FAKE_CLAUDE_VERSION:-Claude Code v2.1.278}"; exit 0; fi
{
  printf 'ATTENDED=[%s] EXPECT=[%s] AGENT_ID=[%s] AGENT_TYPE=[%s]\n' \
    "${CLAUDE_CODE_SESSION_ATTENDED:-UNSET}" "${ATHENA_INBOX_EXPECT_PROJECT:-UNSET}" \
    "${CLAUDE_AGENT_ID:-UNSET}" "${CLAUDE_AGENT_TYPE:-UNSET}"
  printf 'ARGV=[%s]\n' "$*"
} >> "${FAKE_CLAUDE_ENVLOG}"
exit 0
EOC

# fake tmux: records every call; new-session touches a session marker and runs
# the trailing command (so fake claude logs its env); capture-pane cats a
# seedable pane file; has-session tests the marker; kill-session removes it.
cat > "${FAKES}/tmux" <<'EOT'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${FAKE_TMUX_LOG}"
cmd="${1:-}"; shift || true
case "${cmd}" in
  new-session)
    run=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -d) shift ;;
        -s) shift; shift ;;
        -c) shift; shift ;;
        *) run=("$@"); break ;;
      esac
    done
    : > "${FAKE_SESSION_MARKER}"
    if [ "${#run[@]}" -gt 0 ]; then ( "${run[@]}" >/dev/null 2>&1 & ) ; fi
    ;;
  capture-pane) cat "${FAKE_PANE}" 2>/dev/null || true ;;
  send-keys) : ;;
  has-session) [ -e "${FAKE_SESSION_MARKER}" ] ;;
  kill-session) rm -f "${FAKE_SESSION_MARKER}" 2>/dev/null || true ;;
  *) : ;;
esac
EOT

# fake dm: records the DM so "a wedged attendant must not look like a quiet one"
# is asserted, not assumed.
cat > "${FAKES}/dm" <<'EOD'
#!/usr/bin/env bash
printf 'DM to=%s msg=%s\n' "${1:-}" "${2:-}" >> "${FAKE_DM_LOG}"
EOD

# fake inbox-status: prints $FAKE_STATUS_JSON.
cat > "${FAKES}/inbox-status" <<'EOS'
#!/usr/bin/env bash
printf '%s' "${FAKE_STATUS_JSON:-{\"channels\":[]}}"
EOS

# fake resolve-project: prints a fixed project name.
cat > "${FAKES}/resolve-project.sh" <<'EOR'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PROJECT_NAME:-testproj}"
EOR
chmod +x "${FAKES}"/*

# common env for a launcher run
PROJ="${TMP}/proj"; mkdir -p "${PROJ}"
( cd "${PROJ}" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) 2>/dev/null

launcher_env() {
  export ATHENA_ATTEND_TMUX="${FAKES}/tmux"
  export ATHENA_ATTEND_CLAUDE="${FAKES}/claude"
  export ATHENA_ATTEND_DM="${FAKES}/dm"
  export ATHENA_INBOX_STATUS_BIN="${FAKES}/inbox-status"
  export ATHENA_ATTEND_RESOLVE_PROJECT="${FAKES}/resolve-project.sh"
  export ATHENA_ATTEND_OWNER_SLACK_ID="U-OWNER"
  export ATHENA_ATTEND_PROJECT_DIR="${PROJ}"
  export ATHENA_ATTEND_DIALOG_TIMEOUT=1
  export ATHENA_ATTEND_NOTICE_TIMEOUT=1
  export ATHENA_ATTEND_PANE_POLL=0.2
}

# ==========================================================================
echo "== static: the launcher never contains the skip-permissions bypass literal =="
if grep -q "dangerously-skip-permissions" "${LAUNCHER}"; then
  bad "launcher must NOT contain the skip-permissions bypass flag anywhere" "found it"
else
  ok "launcher never contains the skip-permissions bypass flag (static assertion)"
fi
if grep -q "dangerously-load-development-channels" "${LAUNCHER}"; then
  ok "launcher DOES use --dangerously-load-development-channels (the sanctioned flag)"
else
  bad "launcher should launch with --dangerously-load-development-channels" "missing"
fi

echo "== version pin mismatch -> NO launch + channel.wedged + owner DM =="
CASE="${TMP}/c-ver"; mkdir -p "${CASE}"
launcher_env
export ATHENA_ATTEND_STATE_DIR="${CASE}/state"; mkdir -p "${ATHENA_ATTEND_STATE_DIR}"
export FAKE_CLAUDE_ENVLOG="${CASE}/envlog"; : > "${FAKE_CLAUDE_ENVLOG}"
export FAKE_TMUX_LOG="${CASE}/tmuxlog"; : > "${FAKE_TMUX_LOG}"
export FAKE_DM_LOG="${CASE}/dmlog"; : > "${FAKE_DM_LOG}"
export FAKE_SESSION_MARKER="${CASE}/session"
export FAKE_PANE="${CASE}/pane"; : > "${FAKE_PANE}"
export FAKE_CLAUDE_VERSION="Claude Code v9.9.9"   # != pin
( cd "${PROJ}" && timeout 20 bash "${LAUNCHER}" --once >/dev/null 2>&1 ); RC=$?
assert_eq "version mismatch exits 75 (wedged)" 75 "${RC}"
assert_eq "version mismatch launched NO tmux session" "" "$(grep 'new-session' "${FAKE_TMUX_LOG}" || true)"
assert_contains "version mismatch wrote channel.wedged with a regenerate Fix" "re-run the T0 probe" \
  "$(cat "$(attend_marker "${ATHENA_ATTEND_STATE_DIR}" wedged)" 2>/dev/null)"
assert_contains "version mismatch DM'd the owner once" "U-OWNER" "$(cat "${FAKE_DM_LOG}")"
unset FAKE_CLAUDE_VERSION

echo "== happy path: launches, confirms the notice, sets no ATTENDED / AGENT env =="
CASE="${TMP}/c-happy"; mkdir -p "${CASE}"
launcher_env
export ATHENA_ATTEND_STATE_DIR="${CASE}/state"; mkdir -p "${ATHENA_ATTEND_STATE_DIR}"
export FAKE_CLAUDE_ENVLOG="${CASE}/envlog"; : > "${FAKE_CLAUDE_ENVLOG}"
export FAKE_TMUX_LOG="${CASE}/tmuxlog"; : > "${FAKE_TMUX_LOG}"
export FAKE_DM_LOG="${CASE}/dmlog"; : > "${FAKE_DM_LOG}"
export FAKE_SESSION_MARKER="${CASE}/session"
export FAKE_PANE="${CASE}/pane"
# pane shows BOTH the warning and the registration notice
printf 'WARNING: Loading development channels\nChannels (experimental) messages from server:athena-inbox inject directly in this session\n' > "${FAKE_PANE}"
export FAKE_STATUS_JSON='{"channels":[{"name":"peer","kind":"maildir","count":0}]}'
export CLAUDE_CODE_SESSION_ATTENDED=1   # so we can prove `env -u` removes it
( cd "${PROJ}" && timeout 20 bash "${LAUNCHER}" --once >/dev/null 2>&1 ); RC=$?
unset CLAUDE_CODE_SESSION_ATTENDED
assert_eq "happy path exits 0" 0 "${RC}"
assert_contains "happy path launched a tmux session named athena-attend-testproj" "athena-attend-testproj" "$(cat "${FAKE_TMUX_LOG}")"
assert_contains "happy path sent one Enter to the pane" "send-keys" "$(cat "${FAKE_TMUX_LOG}")"
assert_contains "the launched claude saw CLAUDE_CODE_SESSION_ATTENDED UNSET (env -u worked)" "ATTENDED=[UNSET]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_contains "the launched claude saw ATHENA_INBOX_EXPECT_PROJECT set to the project" "EXPECT=[testproj]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_contains "the launcher never set CLAUDE_AGENT_ID on the launched session" "AGENT_ID=[UNSET]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_contains "the launcher never set CLAUDE_AGENT_TYPE on the launched session" "AGENT_TYPE=[UNSET]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_eq "happy path left NO dark/wedged marker" "" \
  "$(ls "${ATHENA_ATTEND_STATE_DIR}"/channel.dark "${ATHENA_ATTEND_STATE_DIR}"/channel.wedged 2>/dev/null || true)"

echo "== registration notice missing -> dark -> ONE retry -> wedged + DM =="
CASE="${TMP}/c-miss"; mkdir -p "${CASE}"
launcher_env
export ATHENA_ATTEND_STATE_DIR="${CASE}/state"; mkdir -p "${ATHENA_ATTEND_STATE_DIR}"
export FAKE_CLAUDE_ENVLOG="${CASE}/envlog"; : > "${FAKE_CLAUDE_ENVLOG}"
export FAKE_TMUX_LOG="${CASE}/tmuxlog"; : > "${FAKE_TMUX_LOG}"
export FAKE_DM_LOG="${CASE}/dmlog"; : > "${FAKE_DM_LOG}"
export FAKE_SESSION_MARKER="${CASE}/session"
export FAKE_PANE="${CASE}/pane"
# the warning appears but the registration notice NEVER does
printf 'WARNING: Loading development channels\n' > "${FAKE_PANE}"
export FAKE_STATUS_JSON='{"channels":[{"name":"peer","kind":"maildir","count":0}]}'
( cd "${PROJ}" && timeout 30 bash "${LAUNCHER}" --once >/dev/null 2>&1 ); RC=$?
assert_eq "missing notice exits 75 (wedged)" 75 "${RC}"
assert_eq "missing notice launched EXACTLY twice (one retry)" 2 "$(grep -c 'new-session' "${FAKE_TMUX_LOG}")"
assert_contains "missing notice ended in channel.wedged" "never appeared after two launches" \
  "$(cat "$(attend_marker "${ATHENA_ATTEND_STATE_DIR}" wedged)" 2>/dev/null)"
assert_contains "missing notice DM'd the owner" "U-OWNER" "$(cat "${FAKE_DM_LOG}")"

echo "== SIGTERM tears down the tmux session =="
CASE="${TMP}/c-term"; mkdir -p "${CASE}"
launcher_env
export ATHENA_ATTEND_STATE_DIR="${CASE}/state"; mkdir -p "${ATHENA_ATTEND_STATE_DIR}"
export FAKE_CLAUDE_ENVLOG="${CASE}/envlog"; : > "${FAKE_CLAUDE_ENVLOG}"
export FAKE_TMUX_LOG="${CASE}/tmuxlog"; : > "${FAKE_TMUX_LOG}"
export FAKE_DM_LOG="${CASE}/dmlog"; : > "${FAKE_DM_LOG}"
export FAKE_SESSION_MARKER="${CASE}/session"
export FAKE_PANE="${CASE}/pane"
printf 'WARNING: Loading development channels\nChannels (experimental) messages from server:athena-inbox inject directly in this session\n' > "${FAKE_PANE}"
export FAKE_STATUS_JSON='{"channels":[{"name":"peer","kind":"maildir","count":0}]}'
export ATHENA_ATTEND_POLL_INTERVAL=30   # so it blocks in the loop after registering
# `exec` so $! IS the launcher process (not a wrapping subshell); otherwise the
# SIGTERM would hit the subshell and the launcher's teardown trap never fires.
( cd "${PROJ}" && exec bash "${LAUNCHER}" >/dev/null 2>&1 ) &
SUP=$!
# wait (bounded) for it to register, then SIGTERM it
for _ in $(seq 1 50); do [ -f "${ATHENA_ATTEND_STATE_DIR}/session.started" ] && break; sleep 0.2; done
: > "${FAKE_TMUX_LOG}"   # clear so we assert the kill AFTER term
kill -TERM "${SUP}" 2>/dev/null
wait "${SUP}" 2>/dev/null; TRC=$?
assert_eq "SIGTERM exits 143" 143 "${TRC}"
assert_contains "SIGTERM ran tmux kill-session on teardown" "kill-session" "$(cat "${FAKE_TMUX_LOG}")"
unset ATHENA_ATTEND_POLL_INTERVAL

echo "== single instance: a second invocation exits 0 while the first holds the lock (@reboot/*/5 no-op) =="
CASE="${TMP}/c-lock"; mkdir -p "${CASE}"
launcher_env
export ATHENA_ATTEND_STATE_DIR="${CASE}/state"; mkdir -p "${ATHENA_ATTEND_STATE_DIR}"
export FAKE_CLAUDE_ENVLOG="${CASE}/envlog"; : > "${FAKE_CLAUDE_ENVLOG}"
export FAKE_TMUX_LOG="${CASE}/tmuxlog"; : > "${FAKE_TMUX_LOG}"
export FAKE_DM_LOG="${CASE}/dmlog"; : > "${FAKE_DM_LOG}"
export FAKE_SESSION_MARKER="${CASE}/session"
export FAKE_PANE="${CASE}/pane"
printf 'WARNING: Loading development channels\nChannels (experimental) messages from server:athena-inbox inject directly in this session\n' > "${FAKE_PANE}"
export FAKE_STATUS_JSON='{"channels":[{"name":"peer","kind":"maildir","count":0}]}'
export ATHENA_ATTEND_POLL_INTERVAL=30
( cd "${PROJ}" && bash "${LAUNCHER}" >/dev/null 2>&1 ) &
SUP=$!
for _ in $(seq 1 50); do [ -f "${ATHENA_ATTEND_STATE_DIR}/session.started" ] && break; sleep 0.2; done
SECOND_LOG="${CASE}/second-tmux"; : > "${SECOND_LOG}"
( cd "${PROJ}" && FAKE_TMUX_LOG="${SECOND_LOG}" timeout 10 bash "${LAUNCHER}" --once >/dev/null 2>&1 ); SRC=$?
assert_eq "the second invocation exits 0 (lock held by the first)" 0 "${SRC}"
assert_eq "the second invocation launched NOTHING (no new-session)" "" "$(grep 'new-session' "${SECOND_LOG}" || true)"
kill -TERM "${SUP}" 2>/dev/null; wait "${SUP}" 2>/dev/null
unset ATHENA_ATTEND_POLL_INTERVAL

echo "== installer: SDK conformance gate refuses --install on a live-check failure (1e) =="
INSTALLER="${SCRIPTS}/setup-athena-attend"
# fake crontab (a file shim), fake inbox-wait (channels present), fake npm/node.
cat > "${FAKES}/crontab" <<'EOX'
#!/usr/bin/env bash
CRONFILE="${FAKE_CRONTAB_FILE:?}"
case "${1:-}" in
  -l) cat "${CRONFILE}" 2>/dev/null; exit 0 ;;
  -)  cat > "${CRONFILE}"; exit 0 ;;
  "") cat > "${CRONFILE}"; exit 0 ;;
  *)  exit 0 ;;
esac
EOX
mkdir -p "${FAKES}/inbin"
cat > "${FAKES}/inbin/inbox-wait" <<'EOW'
#!/usr/bin/env bash
[ "${1:-}" = "--dry-run" ] && exit 0
exit 0
EOW
cat > "${FAKES}/npm" <<'EON'
#!/usr/bin/env bash
exit 0
EON
# fake node: exit code chosen by FAKE_NODE_RC; prints a conformance-style line.
cat > "${FAKES}/node" <<'ENO'
#!/usr/bin/env bash
rc="${FAKE_NODE_RC:-0}"
if [ "${rc}" -eq 0 ]; then echo "sdk-conformance: LIVE PASS (sdk 1.30.0)"; else echo "sdk-conformance: FAIL live handshake  Fix: regenerate the golden"; fi
exit "${rc}"
ENO
chmod +x "${FAKES}/crontab" "${FAKES}/inbin/inbox-wait" "${FAKES}/npm" "${FAKES}/node"

INST_TMP="${TMP}/inst"; mkdir -p "${INST_TMP}"
export FAKE_CRONTAB_FILE="${INST_TMP}/crontab.txt"; : > "${FAKE_CRONTAB_FILE}"
CHDIR="${INST_TMP}/channel"; mkdir -p "${CHDIR}/test"   # run_sdk_conformance only needs the dir to exist
inst_env=(
  "ATHENA_ATTEND_RUNNER_DIR=${SCRIPTS}"
  "ATHENA_ATTEND_INBOX_BIN_DIR=${FAKES}/inbin"
  "ATHENA_ATTEND_CHANNEL_DIR=${CHDIR}"
  "ATHENA_ATTEND_NPM=${FAKES}/npm"
  "ATHENA_ATTEND_NODE=${FAKES}/node"
  "PATH=${FAKES}:${PATH}"
)

# FAILURE: the live check exits 1 -> install refused (exit 2), NO crontab
# entries written, and a Fix line printed.
: > "${FAKE_CRONTAB_FILE}"
OUT="$( env "${inst_env[@]}" FAKE_NODE_RC=1 bash "${INSTALLER}" --install --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "installer: a failed live SDK check refuses --install (exit 2)" 2 "${RC}"
assert_contains "installer: the refusal carries a Fix line" "Fix:" "${OUT}"
assert_eq "installer: NOTHING was written to the crontab on a refused install" "" "$(cat "${FAKE_CRONTAB_FILE}")"

# SUCCESS: the live check passes -> the two entries are installed, pointing at
# the MAIN-checkout launcher (never a worktree copy is the installer's own job;
# here RUNNER_DIR is seamed).
: > "${FAKE_CRONTAB_FILE}"
OUT="$( env "${inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --install --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "installer: a passing live SDK check allows --install (exit 0)" 0 "${RC}"
CRON="$(cat "${FAKE_CRONTAB_FILE}")"
assert_contains "installer: the @reboot entry points at athena-channel-session.sh" "@reboot ${SCRIPTS}/athena-channel-session.sh" "${CRON}"
assert_contains "installer: the */5 relaunch entry is installed" "*/5 * * * * ${SCRIPTS}/athena-channel-session.sh" "${CRON}"

echo "== dry-run: prints the plan, launches nothing =="
CASE="${TMP}/c-dry"; mkdir -p "${CASE}"
launcher_env
export ATHENA_ATTEND_STATE_DIR="${CASE}/state"; mkdir -p "${ATHENA_ATTEND_STATE_DIR}"
export FAKE_TMUX_LOG="${CASE}/tmuxlog"; : > "${FAKE_TMUX_LOG}"
DRY="$( cd "${PROJ}" && timeout 10 bash "${LAUNCHER}" --dry-run 2>&1 )"
assert_contains "dry-run names the tmux session" "athena-attend-testproj" "${DRY}"
assert_contains "dry-run names the sanctioned launch flag" "dangerously-load-development-channels" "${DRY}"
assert_eq "dry-run launched nothing" "" "$(cat "${FAKE_TMUX_LOG}")"

# ==========================================================================
echo
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0
else echo "VERDICT: FAIL (${FAIL} of $((PASS+FAIL)) cases)"; exit 1; fi
