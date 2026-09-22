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
REPO="$(cd -- "${SCRIPTS}/.." && pwd -P)"
LAUNCHER="${SCRIPTS}/athena-channel-session.sh"
LIB="${SCRIPTS}/lib/athena-attend-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

TMP="$(mktemp -d)"
# Track every backgrounded supervisor so a mid-suite abort never leaves an
# orphaned launcher looping `sleep` (reparented to init) behind.
BG_SUPS=""
cleanup() {
  local p
  for p in ${BG_SUPS}; do kill -TERM "${p}" 2>/dev/null; done
  sleep 1
  for p in ${BG_SUPS}; do kill -9 "${p}" 2>/dev/null; done
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM
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

echo "== pure lib: attend_turn_ended (T4 rotation idle, per-session) + ledger path =="
TE="${TMP}/turnend"; mkdir -p "${TE}"
# all three present, idle NEWER than ack -> the turn ended (rotation may proceed).
touch -d '2020-01-01 00:00:00' "${TE}/ack.sidA"
touch -d '2020-01-01 00:00:05' "${TE}/idle.sidA"
assert_eq "turn: ack + idle.<sid> newer than ack -> ended" yes "$(attend_turn_ended "${TE}" sidA && echo yes || echo no)"
# ack present but NO idle.<sid>: ack_wake was called but the Stop hook has not
# fired -- output may still follow the ack, so it is NOT ended (no rotation).
touch -d '2020-01-01 00:00:00' "${TE}/ack.sidB"
assert_eq "turn: ack but no idle.<sid> -> NOT ended (ack alone never rotates)" no "$(attend_turn_ended "${TE}" sidB && echo yes || echo no)"
# an idle marker for ANOTHER session must NOT satisfy our gate (never a global
# marker -- a wrong-key match is the failed-lookup class).
touch "${TE}/idle.other-sid"
assert_eq "turn: idle.<other-sid> present, none for our sid -> NOT ended" no "$(attend_turn_ended "${TE}" sidB && echo yes || echo no)"
# idle OLDER than ack: a fresh bell arrived after the last turn-end -> NOT ended.
touch -d '2020-01-01 00:00:10' "${TE}/ack.sidC"
touch -d '2020-01-01 00:00:00' "${TE}/idle.sidC"
assert_eq "turn: idle older than ack -> NOT ended" no "$(attend_turn_ended "${TE}" sidC && echo yes || echo no)"
assert_eq "turn: empty sid -> NOT ended" no "$(attend_turn_ended "${TE}" '' && echo yes || echo no)"
assert_eq "ledger: attend_ledger_path appends ledger.log to the state dir" "${TE}/ledger.log" "$(attend_ledger_path "${TE}")"

# CROSS-TURN: after turn N ends (ack_N, then idle_N newer) the markers persist.
# When bell N+1 arrives the shim removes idle.<sid> (server.mjs invalidateTurnEnd);
# in the mid-reply window of turn N+1 (mail drained to zero, ack_wake not yet
# called) the gate MUST read NOT-ended, or it could rotate mid-reply. With idle
# removed and ack_N still present, attend_turn_ended is false -> gate stays closed.
XT="${TMP}/xturn"; mkdir -p "${XT}"
touch -d '2020-01-01 00:00:00' "${XT}/ack.sidX"; touch -d '2020-01-01 00:00:05' "${XT}/idle.sidX"
assert_eq "cross-turn: turn N ended (ack_N, idle_N newer) -> ended" yes "$(attend_turn_ended "${XT}" sidX && echo yes || echo no)"
rm -f "${XT}/idle.sidX"   # the shim's invalidateTurnEnd at bell N+1
assert_eq "cross-turn: bell N+1 removed idle, mid-reply (ack_N present) -> NOT ended (no mid-reply rotation)" no "$(attend_turn_ended "${XT}" sidX && echo yes || echo no)"

echo "== pure lib: the three rotation conditions compose in the gate =="
# all three (counts zero + turn ended) -> OPEN; ack-but-no-idle or other-sid -> BLOCKED.
assert_eq "rot: zero counts + turn ended (all three) -> gate OPEN" OPEN \
  "$(attend_rotation_gate_open zero "$(attend_turn_ended "${TE}" sidA && echo 1 || echo 0)" 0 && echo OPEN || echo BLOCKED)"
assert_eq "rot: ack seen but no idle.<sid> newer -> gate BLOCKED (no rotation)" BLOCKED \
  "$(attend_rotation_gate_open zero "$(attend_turn_ended "${TE}" sidB && echo 1 || echo 0)" 0 && echo OPEN || echo BLOCKED)"

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
  printf 'ATTEND_STATE=[%s] ATTEND_SID=[%s] ATTEND_LEDGER=[%s]\n' \
    "${ATHENA_ATTEND_STATE_DIR:-UNSET}" "${ATHENA_ATTEND_SESSION_ID:-UNSET}" "${ATHENA_ATTEND_LEDGER:-UNSET}"
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

# `mark_owner_not_notified` only re-annotates the `wedged` marker (not `dark`),
# which is only correct because EVERY `dm_owner` call site writes `wedged`
# immediately before calling it -- there is no `dark`+`dm_owner` pairing. Only
# ONE of the three call sites is exercised end-to-end below (version-pin
# mismatch); this static check is the regression guard for the other two, so a
# future call site that pairs `dm_owner` with a `dark` marker (or skips writing
# a marker first) is caught even though it is not separately run.
DM_OWNER_CALLS="$(grep -c '^\s*dm_owner ' "${LAUNCHER}")"
assert_eq "static: exactly 3 dm_owner call sites (matches the reviewed set)" 3 "${DM_OWNER_CALLS}"
WEDGED_THEN_DM="$(awk '
  /attend_write_marker "\$\{STATE_DIR\}" wedged/ { pending=1 }
  /attend_write_marker "\$\{STATE_DIR\}" dark/   { pending=0 }
  /dm_owner "/ && pending { n++ }
  END { print n+0 }
' "${LAUNCHER}")"
assert_eq "static: every dm_owner call is preceded by a wedged (not dark) marker write" 3 "${WEDGED_THEN_DM}"

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

echo "== version pin mismatch, owner id UNSET -> wedged marker says 'owner NOT notified' (DND-288 build 4) =="
CASE="${TMP}/c-ver-noid"; mkdir -p "${CASE}"
launcher_env
unset ATHENA_ATTEND_OWNER_SLACK_ID   # simulate a cron-launched run with no id reaching it
export ATHENA_ATTEND_STATE_DIR="${CASE}/state"; mkdir -p "${ATHENA_ATTEND_STATE_DIR}"
export FAKE_CLAUDE_ENVLOG="${CASE}/envlog"; : > "${FAKE_CLAUDE_ENVLOG}"
export FAKE_TMUX_LOG="${CASE}/tmuxlog"; : > "${FAKE_TMUX_LOG}"
export FAKE_DM_LOG="${CASE}/dmlog"; : > "${FAKE_DM_LOG}"
export FAKE_SESSION_MARKER="${CASE}/session"
export FAKE_PANE="${CASE}/pane"; : > "${FAKE_PANE}"
export FAKE_CLAUDE_VERSION="Claude Code v9.9.9"   # != pin
( cd "${PROJ}" && timeout 20 bash "${LAUNCHER}" --once >/dev/null 2>&1 ); RC=$?
assert_eq "no-id wedge: still exits 75 (wedged)" 75 "${RC}"
assert_eq "no-id wedge: sent NO owner DM (dm bin never called)" "" "$(cat "${FAKE_DM_LOG}")"
assert_contains "no-id wedge: the wedged marker records 'owner NOT notified'" "owner NOT notified" \
  "$(cat "$(attend_marker "${ATHENA_ATTEND_STATE_DIR}" wedged)" 2>/dev/null)"
assert_eq "no-id wedge: the annotation lands on LINE 2 (the line doctor.sh reads)" 2 \
  "$(grep -n 'owner NOT notified' "$(attend_marker "${ATHENA_ATTEND_STATE_DIR}" wedged)" 2>/dev/null | cut -d: -f1)"
# Prove the CONSUMER actually surfaces it, not just that the byte exists in the
# file: run the real doctor_check_channel against this exact marker and assert
# its "channel" finding names "owner NOT notified" -- the claimed mechanism
# (inbox-doctor's channel: line) must be able to fire, per this repo's
# "a claimed mechanism must be able to fire" convention.
DOCTOR_LIB="${SCRIPTS}/../ai/skills/athena:inbox/lib/doctor.sh"
if [ -r "${DOCTOR_LIB}" ]; then
  DOCTOR_OUT="$(
    # shellcheck source=/dev/null
    . "${DOCTOR_LIB}"
    export DOCTOR_REPO_DIR="${SCRIPTS%/*}"
    export ATHENA_INBOX_DOCTOR_CHANNEL_PROJECT="testproj"
    export ATHENA_INBOX_DOCTOR_TMUX_HAS_SESSION=0
    export ATHENA_ATTEND_STATE_DIR="${ATHENA_ATTEND_STATE_DIR}"
    doctor_check_channel
  )"
  assert_contains "no-id wedge: inbox-doctor's channel: finding NAMES 'owner NOT notified' (the consumer this exists for)" \
    "owner NOT notified" "${DOCTOR_OUT}"
  assert_contains "no-id wedge: inbox-doctor still reports the finding as fail (wedged)" "fail" \
    "$(printf '%s\n' "${DOCTOR_OUT}" | cut -f1)"
else
  echo "  SKIP: ai/skills/athena:inbox/lib/doctor.sh not found at ${DOCTOR_LIB}; consumer-side assertion skipped"
fi
unset FAKE_CLAUDE_VERSION
export ATHENA_ATTEND_OWNER_SLACK_ID="U-OWNER"   # restore for the cases below

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
# Set ALL THREE so `env -u` removing them is proven, not vacuous: a leaked
# CLAUDE_AGENT_* would make the standing session a subagent that can never ack.
export CLAUDE_CODE_SESSION_ATTENDED=1
export CLAUDE_AGENT_ID="agent-leak-probe"
export CLAUDE_AGENT_TYPE="athena-captain"
( cd "${PROJ}" && timeout 20 bash "${LAUNCHER}" --once >/dev/null 2>&1 ); RC=$?
unset CLAUDE_CODE_SESSION_ATTENDED CLAUDE_AGENT_ID CLAUDE_AGENT_TYPE
assert_eq "happy path exits 0" 0 "${RC}"
assert_contains "happy path launched a tmux session named athena-attend-testproj" "athena-attend-testproj" "$(cat "${FAKE_TMUX_LOG}")"
assert_contains "happy path sent one Enter to the pane" "send-keys" "$(cat "${FAKE_TMUX_LOG}")"
assert_contains "the launched claude saw CLAUDE_CODE_SESSION_ATTENDED UNSET (env -u worked)" "ATTENDED=[UNSET]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_contains "the launched claude saw ATHENA_INBOX_EXPECT_PROJECT set to the project" "EXPECT=[testproj]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_contains "the launcher never set CLAUDE_AGENT_ID on the launched session" "AGENT_ID=[UNSET]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_contains "the launcher never set CLAUDE_AGENT_TYPE on the launched session" "AGENT_TYPE=[UNSET]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_eq "happy path left NO dark/wedged marker" "" \
  "$(ls "${ATHENA_ATTEND_STATE_DIR}"/channel.dark "${ATHENA_ATTEND_STATE_DIR}"/channel.wedged 2>/dev/null || true)"
# T4/DND-285: the launched claude gets a per-session --session-id, and the attend
# env the shim's ack_wake + the Stop hook key their markers on.
assert_contains "happy path launched claude with --session-id" "--session-id" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_contains "happy path passed ATHENA_ATTEND_STATE_DIR into the session" "ATTEND_STATE=[${ATHENA_ATTEND_STATE_DIR}]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_not_contains "happy path passed a non-empty ATHENA_ATTEND_SESSION_ID" "ATTEND_SID=[UNSET]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_contains "happy path passed ATHENA_ATTEND_LEDGER (ends in ledger.log)" "ledger.log]" "$(cat "${FAKE_CLAUDE_ENVLOG}")"
assert_eq "happy path stored the session id in session.id" "1" \
  "$([ -s "${ATHENA_ATTEND_STATE_DIR}/session.id" ] && echo 1 || echo 0)"

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
SUP=$!; BG_SUPS="${BG_SUPS} ${SUP}"
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
# `exec` so $! IS the launcher (not a wrapping subshell): otherwise the kill
# below hits the subshell and the launcher orphans to init, looping `sleep`
# forever — an orphan leak on every gate run.
( cd "${PROJ}" && exec bash "${LAUNCHER}" >/dev/null 2>&1 ) &
SUP=$!; BG_SUPS="${BG_SUPS} ${SUP}"
for _ in $(seq 1 50); do [ -f "${ATHENA_ATTEND_STATE_DIR}/session.started" ] && break; sleep 0.2; done
SECOND_LOG="${CASE}/second-tmux"; : > "${SECOND_LOG}"
( cd "${PROJ}" && FAKE_TMUX_LOG="${SECOND_LOG}" timeout 10 bash "${LAUNCHER}" --once >/dev/null 2>&1 ); SRC=$?
assert_eq "the second invocation exits 0 (lock held by the first)" 0 "${SRC}"
assert_eq "the second invocation launched NOTHING (no new-session)" "" "$(grep 'new-session' "${SECOND_LOG}" || true)"
kill -TERM "${SUP}" 2>/dev/null; wait "${SUP}" 2>/dev/null
unset ATHENA_ATTEND_POLL_INTERVAL

# launcher_env (used by earlier cases) exports ATHENA_ATTEND_OWNER_SLACK_ID for
# the LAUNCHER's own tests; unset it here so it does not leak into the
# installer's PATH env and silently get baked into every crontab entry below
# — the owner-id sub-suite further down sets it back explicitly, per case.
unset ATHENA_ATTEND_OWNER_SLACK_ID

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
# The allowlist merge (T4) runs on every --install; seam it at the real committed
# fragment merging into a scratch target/state so the SDK-gate cases exercise a
# real merge without touching any project's settings.
inst_env=(
  "ATHENA_ATTEND_RUNNER_DIR=${SCRIPTS}"
  "ATHENA_ATTEND_INBOX_BIN_DIR=${FAKES}/inbin"
  "ATHENA_ATTEND_CHANNEL_DIR=${CHDIR}"
  "ATHENA_ATTEND_NPM=${FAKES}/npm"
  "ATHENA_ATTEND_NODE=${FAKES}/node"
  "ATHENA_ATTEND_FRAGMENT=${REPO}/ai/skills/athena:inbox/channel/settings.attend.json"
  "ATHENA_ATTEND_SETTINGS_FILE=${INST_TMP}/default-settings.json"
  "ATHENA_ATTEND_STATE_DIR=${INST_TMP}/default-state"
  "PATH=${FAKES}:${PATH}"
)

# FAILURE: the live check exits 1 -> install refused (exit 2), NO crontab
# entries written, and a Fix line printed. --no-owner-dm is passed so this
# case tests the SDK-conformance refusal specifically, not the (separately
# tested, below) owner-id deny-by-default refusal.
: > "${FAKE_CRONTAB_FILE}"
OUT="$( env "${inst_env[@]}" FAKE_NODE_RC=1 bash "${INSTALLER}" --install --no-owner-dm --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "installer: a failed live SDK check refuses --install (exit 2)" 2 "${RC}"
assert_contains "installer: the refusal carries a Fix line" "Fix:" "${OUT}"
assert_eq "installer: NOTHING was written to the crontab on a refused install" "" "$(cat "${FAKE_CRONTAB_FILE}")"

# SUCCESS: the live check passes -> the two entries are installed, pointing at
# the MAIN-checkout launcher (never a worktree copy is the installer's own job;
# here RUNNER_DIR is seamed). --no-owner-dm again, since this case is about the
# SDK gate, not the owner-id gate (covered in its own sub-suite below).
: > "${FAKE_CRONTAB_FILE}"
OUT="$( env "${inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --install --no-owner-dm --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "installer: a passing live SDK check allows --install (exit 0)" 0 "${RC}"
CRON="$(cat "${FAKE_CRONTAB_FILE}")"
assert_contains "installer: the @reboot entry points at athena-channel-session.sh" "@reboot ${SCRIPTS}/athena-channel-session.sh" "${CRON}"
assert_contains "installer: the */5 relaunch entry is installed" "*/5 * * * * ${SCRIPTS}/athena-channel-session.sh" "${CRON}"

# --check is READ-ONLY: it reports the live conformance result but must NOT run
# `npm ci` (a network install that rewrites node_modules in the main checkout).
# A recording fake npm proves it is never invoked on the --check path.
cat > "${FAKES}/npm-rec" <<EON
#!/usr/bin/env bash
printf 'npm %s\n' "\$*" >> "${INST_TMP}/npm-calls"
exit 0
EON
chmod +x "${FAKES}/npm-rec"
: > "${INST_TMP}/npm-calls"
OUT="$( env "${inst_env[@]}" ATHENA_ATTEND_NPM="${FAKES}/npm-rec" FAKE_NODE_RC=0 bash "${INSTALLER}" --check --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "installer: --check exits 0 when entries are present" 0 "${RC}"
assert_eq "installer: --check is READ-ONLY -- it never runs npm ci" "" "$(cat "${INST_TMP}/npm-calls")"

# ==========================================================================
# T3-followup: the owner Slack id must reach a CRON-launched (empty-env)
# session, not just live in the operator's interactive shell at install time.
# A fake "runner" stands in for athena-channel-session.sh: it only echoes
# whether ATHENA_ATTEND_OWNER_SLACK_ID reached it, so running the crontab
# line's exact text under `env -i` proves what cron itself would see —
# nothing about the real launcher needs faking for that question.
# ==========================================================================
echo "== owner id: baked into the crontab entries + proven to reach a cron-shaped (empty-env) run =="
FAKE_RUNNER_DIR="${INST_TMP}/runnerdir"; mkdir -p "${FAKE_RUNNER_DIR}"
cat > "${FAKE_RUNNER_DIR}/athena-channel-session.sh" <<'EOF'
#!/usr/bin/env bash
printf 'OWNER_SLACK_ID=[%s]\n' "${ATHENA_ATTEND_OWNER_SLACK_ID:-UNSET}"
EOF
chmod +x "${FAKE_RUNNER_DIR}/athena-channel-session.sh"
owner_inst_env=(
  "ATHENA_ATTEND_RUNNER_DIR=${FAKE_RUNNER_DIR}"
  "ATHENA_ATTEND_INBOX_BIN_DIR=${FAKES}/inbin"
  "ATHENA_ATTEND_CHANNEL_DIR=${CHDIR}"
  "ATHENA_ATTEND_NPM=${FAKES}/npm"
  "ATHENA_ATTEND_NODE=${FAKES}/node"
  "PATH=${FAKES}:${PATH}"
)

# -- with an owner id set at install: baked in, and reaches an empty-env run --
: > "${FAKE_CRONTAB_FILE}"
OUT="$( env "${owner_inst_env[@]}" ATHENA_ATTEND_OWNER_SLACK_ID=UOWNERPERSIST9 FAKE_NODE_RC=0 \
  bash "${INSTALLER}" --install --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "owner id: --install with the id set exits 0" 0 "${RC}"
CRON="$(cat "${FAKE_CRONTAB_FILE}")"
assert_contains "owner id: baked into the @reboot line" \
  "@reboot ATHENA_ATTEND_OWNER_SLACK_ID=UOWNERPERSIST9 ${FAKE_RUNNER_DIR}/athena-channel-session.sh --project ${PROJ}" "${CRON}"
assert_contains "owner id: baked into the */5 line" \
  "*/5 * * * * ATHENA_ATTEND_OWNER_SLACK_ID=UOWNERPERSIST9 ${FAKE_RUNNER_DIR}/athena-channel-session.sh --project ${PROJ}" "${CRON}"
REBOOT_ACTUAL="$(printf '%s\n' "${CRON}" | grep -F '@reboot ')"
CRONRUN_OUT="$(env -i /bin/sh -c "${REBOOT_ACTUAL#@reboot }" 2>&1)"
assert_contains "owner id: reaches the launcher under a cron-shaped EMPTY environment" \
  "OWNER_SLACK_ID=[UOWNERPERSIST9]" "${CRONRUN_OUT}"

# -- --check, run with a DIFFERENT (or no) id in ITS OWN env, still reports
# persisted (proves --check matches by substring, not by re-deriving the line
# from its own env) — and shows the id MASKED to its first 3 chars, never in full.
OUT="$( env "${owner_inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --check --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "owner id: --check exits 0 when persisted (even with no id in ITS OWN env)" 0 "${RC}"
assert_contains "owner id: --check reports the id as persisted" "owner DM: persisted" "${OUT}"
assert_contains "owner id: --check masks the id to its first 3 chars" "id UOW..." "${OUT}"
assert_not_contains "owner id: --check does NOT warn when the id is persisted" "WARNING" "${OUT}"

# -- --remove still matches and drops a persisted-id line (idempotency held,
# no orphan even though the line now carries a VAR=value prefix) --
OUT="$( env "${owner_inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --remove --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "owner id: --remove exits 0" 0 "${RC}"
assert_eq "owner id: --remove drops the persisted-id entries" "" \
  "$(grep -F -- "${FAKE_RUNNER_DIR}/athena-channel-session.sh --project ${PROJ}" "${FAKE_CRONTAB_FILE}" || true)"

echo "== owner id: deny by default -- --install REFUSES without a valid id or --no-owner-dm =="
# -- unset id, no --no-owner-dm -> exit 2, Fix line, crontab left BYTE-IDENTICAL --
: > "${FAKE_CRONTAB_FILE}"; printf 'PRE-EXISTING-LINE\n' > "${FAKE_CRONTAB_FILE}"
BEFORE="$(cat "${FAKE_CRONTAB_FILE}")"
OUT="$( env "${owner_inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --install --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "deny-by-default: unset id with no --no-owner-dm refuses (exit 2)" 2 "${RC}"
assert_contains "deny-by-default: the refusal carries a Fix line" "Fix:" "${OUT}"
assert_eq "deny-by-default: the crontab is left BYTE-IDENTICAL on refusal" "${BEFORE}" "$(cat "${FAKE_CRONTAB_FILE}")"

# -- malformed ids (test the MISS, not just the hit): lowercase, empty-ish,
# whitespace, and simply not matching ^U[A-Z0-9]{8,}$ -- each rejected --
for BAD_ID in 'u0123abcd' 'U123' 'U ABCDEFGH' 'not-a-slack-id'; do
  : > "${FAKE_CRONTAB_FILE}"
  OUT="$( env "${owner_inst_env[@]}" "ATHENA_ATTEND_OWNER_SLACK_ID=${BAD_ID}" FAKE_NODE_RC=0 \
    bash "${INSTALLER}" --install --project "${PROJ}" 2>&1 )"; RC=$?
  assert_eq "deny-by-default: malformed id '${BAD_ID}' refuses (exit 2)" 2 "${RC}"
  assert_eq "deny-by-default: malformed id '${BAD_ID}' writes nothing" "" "$(cat "${FAKE_CRONTAB_FILE}")"
done

# -- --no-owner-dm must bypass the refusal for a MALFORMED id too, not just an
# unset one: an earlier version only checked $NO_OWNER_DM in the unset branch,
# so a malformed id + --no-owner-dm still refused (exit 2) while its own Fix:
# line told the caller to pass --no-owner-dm -- which they already had. Caught
# by review; this proves the fix and guards the regression.
: > "${FAKE_CRONTAB_FILE}"
OUT="$( env "${owner_inst_env[@]}" "ATHENA_ATTEND_OWNER_SLACK_ID=not-a-slack-id" FAKE_NODE_RC=0 \
  bash "${INSTALLER}" --install --no-owner-dm --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "deny-by-default: malformed id + --no-owner-dm together exits 0 (bypass works)" 0 "${RC}"
assert_contains "deny-by-default: malformed id + --no-owner-dm warns the id was discarded" \
  "malformed ATHENA_ATTEND_OWNER_SLACK_ID" "${OUT}"
CRON="$(cat "${FAKE_CRONTAB_FILE}")"
assert_not_contains "deny-by-default: the malformed id is NOT baked into the @reboot line" \
  "not-a-slack-id" "$(printf '%s\n' "${CRON}" | grep -F '@reboot ')"
assert_contains "deny-by-default: the malformed-id-bypass line still carries the no-owner-dm marker" \
  "ATHENA-NO-OWNER-DM" "${CRON}"
env "${owner_inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --remove --project "${PROJ}" >/dev/null 2>&1

echo "== owner id: --no-owner-dm is the only explicit way past the refusal =="
: > "${FAKE_CRONTAB_FILE}"
OUT="$( env "${owner_inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --install --no-owner-dm --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "no-owner-dm: --install --no-owner-dm exits 0" 0 "${RC}"
assert_contains "no-owner-dm: prints a loud WARNING" "WARNING" "${OUT}"
CRON="$(cat "${FAKE_CRONTAB_FILE}")"
assert_not_contains "no-owner-dm: the @reboot line has no OWNER_SLACK_ID=" "ATHENA_ATTEND_OWNER_SLACK_ID=" \
  "$(printf '%s\n' "${CRON}" | grep -F '@reboot ')"
assert_contains "no-owner-dm: the choice is recorded IN the crontab entry itself" "ATHENA-NO-OWNER-DM" "${CRON}"
REBOOT_ACTUAL="$(printf '%s\n' "${CRON}" | grep -F '@reboot ')"
CRONRUN_OUT="$(env -i /bin/sh -c "${REBOOT_ACTUAL#@reboot }" 2>&1)"
assert_contains "no-owner-dm: the cron-shaped run sees it UNSET (distinct from the persisted case)" \
  "OWNER_SLACK_ID=[UNSET]" "${CRONRUN_OUT}"

OUT="$( env "${owner_inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --check --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "no-owner-dm: --check exits 0 (entries present; disabled is an explicit choice, not a fault)" 0 "${RC}"
assert_contains "no-owner-dm: --check reports it as DISABLED, not as NOT PERSISTED" "owner DM: disabled" "${OUT}"
assert_not_contains "no-owner-dm: --check does not raise a WARNING for an explicit no-owner-dm choice" "WARNING" "${OUT}"

# -- --remove drops a --no-owner-dm-marked line too (no orphan) --
OUT="$( env "${owner_inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --remove --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "no-owner-dm: --remove exits 0" 0 "${RC}"
assert_eq "no-owner-dm: --remove drops the marked-disabled entries (no orphan)" "" \
  "$(grep -F -- "${FAKE_RUNNER_DIR}/athena-channel-session.sh --project ${PROJ}" "${FAKE_CRONTAB_FILE}" || true)"

echo "== owner id: a T3-era BARE line (installed before DND-288) reads NOT PERSISTED, distinctly =="
# Simulate the pre-DND-288 installed state directly (bare, no prefix, no
# marker) rather than via --install, which can no longer produce it.
: > "${FAKE_CRONTAB_FILE}"
printf '@reboot %s --project %s\n*/5 * * * * %s --project %s\n' \
  "${FAKE_RUNNER_DIR}/athena-channel-session.sh" "${PROJ}" \
  "${FAKE_RUNNER_DIR}/athena-channel-session.sh" "${PROJ}" > "${FAKE_CRONTAB_FILE}"
OUT="$( env "${owner_inst_env[@]}" FAKE_NODE_RC=0 bash "${INSTALLER}" --check --project "${PROJ}" 2>&1 )"; RC=$?
assert_eq "T3-era bare line: --check STILL exits 0 (entries present; this is a warning, not a failure)" 0 "${RC}"
assert_contains "T3-era bare line: --check reports NOT PERSISTED, naming DND-288" \
  "owner DM: NOT PERSISTED (installed before DND-288)" "${OUT}"
assert_contains "T3-era bare line: --check's warning carries a Fix line" "Fix:" "${OUT}"
assert_contains "T3-era bare line: the Fix line names re-running --install with the id set" \
  "re-run --install with ATHENA_ATTEND_OWNER_SLACK_ID set" "${OUT}"
assert_not_contains "T3-era bare line: NOT PERSISTED never reads as 'disabled'" "owner DM: disabled" "${OUT}"
assert_not_contains "T3-era bare line: NOT PERSISTED never reads as 'persisted'" "owner DM: persisted" "${OUT}"
# clean up this sub-suite's crontab so it doesn't leak into anything after it
: > "${FAKE_CRONTAB_FILE}"
echo "== committed allowlist fragment is deny-by-default (static QA; T4/DND-285) =="
REPO="$(cd -- "${SCRIPTS}/.." && pwd -P)"
FRAG="${REPO}/ai/skills/athena:inbox/channel/settings.attend.json"
if [ ! -f "${FRAG}" ]; then
  bad "the committed allowlist fragment must exist" "${FRAG} not found"
else
  FRAGALLOW="$(jq -r '.permissions.allow[]' "${FRAG}" 2>/dev/null)"
  assert_eq "fragment has exactly 7 allow entries" "7" "$(jq '.permissions.allow | length' "${FRAG}")"
  # EXACT-SET assertion (not just count + denylist): the ticket says the entries
  # are EXACTLY the 7 routine calls, so a future diff cannot swap one of the
  # unpinned slots for a non-forbidden-but-dangerous entry while keeping count 7.
  EXPECT_ALLOW='["Bash(/home/cjpoll/dev/custom/ai/skills/athena:inbox/bin/inbox-status*)","Bash(/home/cjpoll/dev/custom/ai/skills/athena:inbox/bin/read-inbox*)","Bash(/home/cjpoll/dev/custom/ai/skills/athena:slack/bin/reply*)","Bash(/home/cjpoll/dev/custom/ai/skills/athena:slack/bin/dm*)","Bash(/home/cjpoll/dev/custom/ai/skills/athena:slack/bin/read-thread*)","Bash(tail -n * __ATTEND_LEDGER__)","mcp__athena-inbox__ack_wake"]'
  assert_eq "fragment allow is EXACTLY the 7 routine entries (no swap surface)" "${EXPECT_ALLOW}" "$(jq -c '.permissions.allow' "${FRAG}")"
  assert_not_contains "fragment allows NO Edit tool" "Edit(" "${FRAGALLOW}"
  assert_not_contains "fragment allows NO Write tool" "Write(" "${FRAGALLOW}"
  assert_not_contains "fragment allows NO MultiEdit tool" "MultiEdit" "${FRAGALLOW}"
  assert_not_contains "fragment allows NO NotebookEdit tool" "NotebookEdit" "${FRAGALLOW}"
  assert_not_contains "fragment allows NO git write" "git " "${FRAGALLOW}"
  assert_not_contains "fragment allows NO gh-athena" "gh-athena" "${FRAGALLOW}"
  assert_not_contains "fragment allows NO send-mail" "send-mail" "${FRAGALLOW}"
  assert_not_contains "fragment has NO Bash(*) wildcard" "Bash(*)" "${FRAGALLOW}"
  assert_not_contains "fragment names NO worktree path (main-checkout absolute only)" "/.local/worktrees/" "${FRAGALLOW}"
  assert_contains "fragment allows ack_wake" "mcp__athena-inbox__ack_wake" "${FRAGALLOW}"
  assert_contains "fragment bin paths are main-checkout absolute (/home/cjpoll/dev/custom)" \
    "/home/cjpoll/dev/custom/ai/skills/athena:inbox/bin/read-inbox" "${FRAGALLOW}"
fi

echo "== installer: allowlist merges into settings.json (merge, never clobber; idempotent) =="
MERGE_STATE="${INST_TMP}/mstate"; mkdir -p "${MERGE_STATE}"
TARGET="${INST_TMP}/proj-claude/settings.json"; mkdir -p "$(dirname "${TARGET}")"
# a pre-existing settings.json with an unrelated key AND a pre-existing allow entry.
printf '%s\n' '{"model":"opus","permissions":{"allow":["Bash(ls*)"]}}' > "${TARGET}"
: > "${FAKE_CRONTAB_FILE}"
env "${inst_env[@]}" FAKE_NODE_RC=0 \
  ATHENA_ATTEND_FRAGMENT="${FRAG}" \
  ATHENA_ATTEND_SETTINGS_FILE="${TARGET}" \
  ATHENA_ATTEND_STATE_DIR="${MERGE_STATE}" \
  bash "${INSTALLER}" --install --project "${PROJ}" >/dev/null 2>&1; RC=$?
assert_eq "installer: --install with a mergeable allowlist exits 0" 0 "${RC}"
assert_contains "merge kept the pre-existing unrelated key (model)" '"model": "opus"' "$(cat "${TARGET}")"
MALLOW="$(jq -r '.permissions.allow[]' "${TARGET}" 2>/dev/null)"
assert_contains "merge kept the pre-existing allow entry" "Bash(ls*)" "${MALLOW}"
assert_contains "merge added ack_wake" "mcp__athena-inbox__ack_wake" "${MALLOW}"
assert_contains "merge added the read-inbox main-checkout entry" "/home/cjpoll/dev/custom/ai/skills/athena:inbox/bin/read-inbox" "${MALLOW}"
assert_contains "merge substituted the per-project ledger path" "tail -n * ${MERGE_STATE}/ledger.log" "${MALLOW}"
assert_not_contains "no unsubstituted __ATTEND_LEDGER__ placeholder remains" "__ATTEND_LEDGER__" "${MALLOW}"
assert_not_contains "the fragment's _note key never reaches the merged settings" "_note" "$(cat "${TARGET}")"
# idempotent: a second --install adds nothing.
BEFORE_N="$(jq '.permissions.allow | length' "${TARGET}")"
: > "${FAKE_CRONTAB_FILE}"
env "${inst_env[@]}" FAKE_NODE_RC=0 ATHENA_ATTEND_FRAGMENT="${FRAG}" ATHENA_ATTEND_SETTINGS_FILE="${TARGET}" ATHENA_ATTEND_STATE_DIR="${MERGE_STATE}" bash "${INSTALLER}" --install --project "${PROJ}" >/dev/null 2>&1
AFTER_N="$(jq '.permissions.allow | length' "${TARGET}")"
assert_eq "merge is idempotent (allow length unchanged on re-run)" "${BEFORE_N}" "${AFTER_N}"
# --remove un-merges the attend entries but keeps the pre-existing one.
: > "${FAKE_CRONTAB_FILE}"
env "${inst_env[@]}" ATHENA_ATTEND_FRAGMENT="${FRAG}" ATHENA_ATTEND_SETTINGS_FILE="${TARGET}" ATHENA_ATTEND_STATE_DIR="${MERGE_STATE}" bash "${INSTALLER}" --remove --project "${PROJ}" >/dev/null 2>&1
RALLOW="$(jq -r '.permissions.allow[]' "${TARGET}" 2>/dev/null)"
assert_not_contains "--remove dropped the attend ack_wake entry" "mcp__athena-inbox__ack_wake" "${RALLOW}"
assert_contains "--remove kept the pre-existing unrelated allow entry" "Bash(ls*)" "${RALLOW}"

echo "== athena:inbox-attend skill: ack_wake wiring + consumer-lock note (T4/DND-285) =="
SKILL_MD="${REPO}/ai/skills/athena:inbox-attend/SKILL.md"
if [ ! -f "${SKILL_MD}" ]; then
  bad "the athena:inbox-attend skill must exist" "${SKILL_MD} not found"
else
  SKILLTXT="$(cat "${SKILL_MD}")"
  assert_contains "skill's final wake step calls mcp__athena-inbox__ack_wake" "mcp__athena-inbox__ack_wake" "${SKILLTXT}"
  # consumer-lock refusal -> not the designated consumer -> call ack_wake + end
  # the turn (design 3.2a; the refusal itself is proven by the inbox suite's
  # M-2/A-6 lock test).
  assert_contains "skill tells a non-consumer (lock refused, --peek) to not peek/reply" "not** the designated consumer" "${SKILLTXT}"
  assert_contains "skill routes a lock-refused session to ack_wake + end the turn" "call \`ack_wake\` (final step) and end the turn" "${SKILLTXT}"
  # DoD: the #47 receipt env var is gone from the skill (the operational grep is
  # clean; the only ATHENA_ATTEND_RECEIPT left in ai/ is the design doc's dated
  # T6-sweep-list token, which is an immutable dated record).
  assert_not_contains "skill contains no ATHENA_ATTEND_RECEIPT (receipt step is gone)" "ATHENA_ATTEND_RECEIPT" "${SKILLTXT}"
fi

echo "== notify-idle Stop hook writes idle.<sid> for attend sessions only (T4/DND-285) =="
NIH="${REPO}/ai/hooks/notify-idle.sh"
NI_STATE="${TMP}/ni-state"; mkdir -p "${NI_STATE}"
# An attend session: ATHENA_ATTEND_STATE_DIR set. The marker keys on the env
# ATHENA_ATTEND_SESSION_ID (the launcher UUID the gate reads), NOT the stdin
# .session_id -- anchoring to the single source the gate keys on. Feed a
# DIFFERENT stdin session_id to prove the env wins.
printf '%s' '{"session_id":"stdin-sid","hook_event_name":"Stop"}' \
  | ATHENA_ATTEND_STATE_DIR="${NI_STATE}" ATHENA_ATTEND_SESSION_ID="env-sid" bash "${NIH}" >/dev/null 2>&1
assert_eq "attend Stop wrote idle.<env-sid> (anchored to the gate's source, not stdin)" "1" \
  "$([ -e "${NI_STATE}/idle.env-sid" ] && echo 1 || echo 0)"
assert_eq "attend Stop did NOT write idle.<stdin-sid> (env wins over the Stop payload)" "0" \
  "$([ -e "${NI_STATE}/idle.stdin-sid" ] && echo 1 || echo 0)"
# stdin .session_id is used only as a FALLBACK when the env var is absent.
NI_STATE2="${TMP}/ni-state2"; mkdir -p "${NI_STATE2}"
printf '%s' '{"session_id":"fallback-sid","hook_event_name":"Stop"}' \
  | ATHENA_ATTEND_STATE_DIR="${NI_STATE2}" bash "${NIH}" >/dev/null 2>&1
assert_eq "attend Stop falls back to the stdin .session_id when the env var is unset" "1" \
  "$([ -e "${NI_STATE2}/idle.fallback-sid" ] && echo 1 || echo 0)"
# A NON-attend session (no ATHENA_ATTEND_STATE_DIR) writes NO marker anywhere.
NI_STATE3="${TMP}/ni-state3"; mkdir -p "${NI_STATE3}"
printf '%s' '{"session_id":"whatever","hook_event_name":"Stop"}' \
  | ATHENA_ATTEND_SESSION_ID="x" bash "${NIH}" >/dev/null 2>&1
assert_eq "a non-attend session writes no idle marker" "0" \
  "$(find "${NI_STATE3}" -name 'idle.*' 2>/dev/null | wc -l | tr -d ' ')"

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
