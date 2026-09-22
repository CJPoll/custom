#!/usr/bin/env bash
# athena-channel-session.sh -- launch and supervise the STANDING channel session
# for a project's Athena inbox (design ai/docs/inbox-channels-design.md §4).
#
# WHAT IT IS. An interactive `claude` session in a dedicated tmux session
# (athena-attend-<project>) launched with --dangerously-load-development-channels
# so the athena-inbox channel shim (T2) pushes unread-count wakes straight into
# it. This script is the supervisor the T1 installer (scripts/setup-athena-attend)
# schedules: it holds a per-project flock for its lifetime, answers the one
# full-screen dev-channels dialog, asserts the registration notice, and rotates
# / restarts the session under bounds so a long-lived session never grows an
# unbounded standing bill and a dark channel never sits silent.
#
# ROTATION (activated by T4/DND-285): the wakes/bytes/age rotation is gated on
# THREE conditions together, so a rotation never cuts a reply -- every channel
# counts zero, ack_wake was called (ack.<sid> exists), and this session's Stop
# hook fired AFTER the ack (idle.<sid> newer than ack.<sid>). The wakes counter
# is bumped by the shim's ack_wake tool. Each launched session gets its own
# --session-id UUID (stored in session.id); the gate keys on THAT session's
# markers, never a global one. Pre-T4 only dark-restart was active; T4 wires the
# idle signal (is_idle -> attend_turn_ended) that turns bound-rotation live.
#
# INERT UNTIL INSTALLED. Nothing here runs on its own; `scripts/setup-athena-attend
# --install` adds the @reboot + */5 crontab entries (pointing at the MAIN
# checkout's copy). Shipping this script starts no always-on session.
#
# NEVER the skip-permissions bypass flag (owner decision). The session runs
# --permission-mode default with inbox-untrusted-guard live
# (CLAUDE_CODE_SESSION_ATTENDED unset). The self-test statically asserts the
# forbidden flag literal appears NOWHERE in this file, which is why the flag is
# never spelled out even to say "not this" -- the assertion cannot tell a
# negation from a use.
# Routine attend calls PROMPT until T4 lands the allowlist; the tmux pane is
# where a human answers. The only thing this launcher auto-answers is the
# dev-channels WARNING (not a permission prompt) -- one Enter. It NEVER answers
# the one-time project-trust or MCP-consent dialogs (trust decisions; it detects
# and reports them for the owner to answer at install).
#
# Usage:
#   athena-channel-session.sh                supervise (blocks; the standing form)
#   athena-channel-session.sh --once         launch+confirm + one supervise cycle
#   athena-channel-session.sh --dry-run      resolve + print the plan; run NOTHING
#   athena-channel-session.sh --project DIR  attend DIR instead of the default
#   athena-channel-session.sh --help
#
# Env (all optional; defaults are the production values / test seams):
#   ATHENA_ATTEND_PROJECT_DIR   project whose inbox to attend (default ~/dev/walt_ui)
#   ATHENA_ATTEND_TMUX          tmux binary (default: tmux)
#   ATHENA_ATTEND_CLAUDE        claude binary (default: claude)
#   ATHENA_ATTEND_DM            owner-DM bin (default: athena:slack/bin/dm)
#   ATHENA_ATTEND_OWNER_SLACK_ID  owner Slack id the wedge DM targets
#   ATHENA_INBOX_STATUS_BIN     inbox-status (default: main-checkout copy)
#   ATHENA_ATTEND_RESOLVE_PROJECT resolve-project.sh (default: channel copy)
#   ATHENA_ATTEND_STATE_DIR     per-project state/marker dir (test seam)
#   ATHENA_ATTEND_TRANSCRIPT_DIR ~/.claude/projects/<slug> (test seam)
#   (idle detection is per-session and NOT env-configurable: is_idle keys on
#    ack.<sid>/idle.<sid> in the state dir under this session's own --session-id;
#    ATHENA_ATTEND_SESSION_ID sets that id, ack_wake writes the ack, the Stop
#    hook writes the idle marker)
#   ATHENA_ATTEND_MAX_WAKES     rotate after N wakes (30)
#   ATHENA_ATTEND_MAX_BYTES     rotate at transcript bytes (262144)
#   ATHENA_ATTEND_MAX_AGE       rotate after N seconds (86400)
#   ATHENA_ATTEND_HANDLE_BUDGET dark if unread persists N s after a bell (300)
#   ATHENA_ATTEND_RESTART_CAP   dark-restart cap per window (3)
#   ATHENA_ATTEND_RESTART_WINDOW  cap window seconds (3600)
#   ATHENA_ATTEND_POLL_INTERVAL supervise poll cadence seconds (30)
#   ATHENA_ATTEND_DIALOG_TIMEOUT  wait N s for the warning (60)
#   ATHENA_ATTEND_NOTICE_TIMEOUT  wait N s for the registration notice (30)
#   ATHENA_ATTEND_PANE_POLL     pane poll cadence seconds, <=1 (1)
#   ATHENA_ATTEND_MAX_CYCLES    stop after N supervise cycles; 0=unlimited (0)
#   ATHENA_ATTEND_PINNED_VERSION  override the pinned version (TEST SEAM only)
#
# Exit: 0 ok (supervisor stopped cleanly, another instance holds the lock, or
#       --once handled) · 1 usage/arg · 2 missing prerequisite · 75 wedged
#       (version mismatch, registration never confirmed, or restart cap hit)
#       · 143 terminated (SIGTERM).

set -uo pipefail

# cron's PATH is minimal; pin a known-good one so losing tmux(1)/flock(1) cannot
# silently defeat a guarantee.
export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/athena-attend-lib.sh"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

# ---- the version P2 was verified against (design §4.3). A MISMATCH is a HARD
# no-launch: a blind keypress into an unknown dialog format is the hazard. The
# literal below is the greppable pin the Fix: line tells an operator to update.
PINNED_CLAUDE_VERSION="2.1.278"

# ---- args (order-independent) ----------------------------------------------
MODE="supervise"
DRY_RUN=0
PROJECT_DIR_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --once)     MODE="once" ;;
    --dry-run)  DRY_RUN=1 ;;
    --project)  shift; PROJECT_DIR_ARG="${1:-}"
                [ -n "${PROJECT_DIR_ARG}" ] || {
                  echo "error: --project needs a directory argument" >&2
                  echo "  Fix: run 'athena-channel-session.sh --project /path/to/project'." >&2
                  exit 1; } ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2
       echo "  Fix: use --once, --dry-run, --project DIR, or --help." >&2
       exit 1 ;;
  esac
  shift
done

# ---- resolve project dir + name --------------------------------------------
PROJECT_DIR="${PROJECT_DIR_ARG:-${ATHENA_ATTEND_PROJECT_DIR:-${HOME}/dev/walt_ui}}"
case "${PROJECT_DIR}" in
  /*) : ;;
  *)  PROJECT_DIR="$(cd -- "${PROJECT_DIR}" 2>/dev/null && pwd -P)" || : ;;
esac

TMUX_BIN="${ATHENA_ATTEND_TMUX:-tmux}"
CLAUDE_BIN="${ATHENA_ATTEND_CLAUDE:-claude}"
DM_BIN="${ATHENA_ATTEND_DM:-${HOME}/.claude/skills/athena:slack/bin/dm}"

# inbox-status + resolve-project default to the MAIN checkout's copies (git
# common dir), like setup-athena-inbox-client -- never a worktree's.
main_checkout_skill_bin() {
  local common parent
  common="$(git -C "${SCRIPT_DIR}" rev-parse --git-common-dir 2>/dev/null)" || { printf '%s' ""; return; }
  [ -n "${common}" ] || { printf '%s' ""; return; }
  case "${common}" in /*) ;; *) common="${SCRIPT_DIR}/${common}" ;; esac
  parent="$(dirname -- "${common}")"
  printf '%s' "${parent}/ai/skills/athena:inbox"
}
SKILL_DIR="$(main_checkout_skill_bin)"
INBOX_STATUS="${ATHENA_INBOX_STATUS_BIN:-${SKILL_DIR}/bin/inbox-status}"
RESOLVE_PROJECT="${ATHENA_ATTEND_RESOLVE_PROJECT:-${SKILL_DIR}/channel/resolve-project.sh}"

resolve_project_name() {
  ( cd -- "${PROJECT_DIR}" 2>/dev/null && "${RESOLVE_PROJECT}" 2>/dev/null )
}
PROJECT_NAME="$(resolve_project_name || true)"
if [ -z "${PROJECT_NAME}" ]; then
  # Fall back to the dir basename ONLY for naming; a truly unresolvable project
  # (no channels) will fail tenancy inside the shim, which is the right place.
  PROJECT_NAME="$(basename -- "${PROJECT_DIR}")"
fi

SESSION="$(attend_session_name "${PROJECT_NAME}")"
STATE_DIR="$(attend_state_dir "${PROJECT_NAME}")"
PIDFILE="${STATE_DIR}/attend.pid"
RESTARTS_LOG="${STATE_DIR}/restarts.log"
STARTED_F="${STATE_DIR}/session.started"
WAKES_F="${STATE_DIR}/wakes"
SESSION_ID_F="${STATE_DIR}/session.id"
LEDGER_F="$(attend_ledger_path "${STATE_DIR}")"
LOG="${STATE_DIR}/attend.log"

# bounds / cadences
PIN="${ATHENA_ATTEND_PINNED_VERSION:-${PINNED_CLAUDE_VERSION}}"
MAX_WAKES="${ATHENA_ATTEND_MAX_WAKES:-30}"
MAX_BYTES="${ATHENA_ATTEND_MAX_BYTES:-262144}"
MAX_AGE="${ATHENA_ATTEND_MAX_AGE:-86400}"
HANDLE_BUDGET="${ATHENA_ATTEND_HANDLE_BUDGET:-300}"
RESTART_CAP="${ATHENA_ATTEND_RESTART_CAP:-3}"
RESTART_WINDOW="${ATHENA_ATTEND_RESTART_WINDOW:-3600}"
POLL_INTERVAL="${ATHENA_ATTEND_POLL_INTERVAL:-30}"
DIALOG_TIMEOUT="${ATHENA_ATTEND_DIALOG_TIMEOUT:-60}"
NOTICE_TIMEOUT="${ATHENA_ATTEND_NOTICE_TIMEOUT:-30}"
PANE_POLL="${ATHENA_ATTEND_PANE_POLL:-1}"
MAX_CYCLES="${ATHENA_ATTEND_MAX_CYCLES:-0}"

# The registration notice whose presence proves the channel registered (P2 /
# design §3.4). Absence is a FAULT, never a quiet channel.
NOTICE='Channels (experimental) messages from server:athena-inbox inject directly in this session'
WARNING='WARNING: Loading development channels'

mkdir -p -- "${STATE_DIR}" 2>/dev/null || {
  echo "error: cannot create state dir: ${STATE_DIR}" >&2
  echo "  Fix: create it or point ATHENA_ATTEND_STATE_DIR at a writable directory." >&2
  exit 2
}

say() {
  local line; line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') CHANNEL $*"
  printf '%s\n' "${line}" >>"${LOG}" 2>/dev/null || true
  [ -t 2 ] && printf '%s\n' "${line}" >&2
  return 0
}

dm_owner() {
  local msg="$1"
  [ -n "${ATHENA_ATTEND_OWNER_SLACK_ID:-}" ] || { say "owner DM skipped (ATHENA_ATTEND_OWNER_SLACK_ID unset): ${msg}"; return 0; }
  [ -x "${DM_BIN}" ] || { say "owner DM skipped (dm bin not executable: ${DM_BIN}): ${msg}"; return 0; }
  "${DM_BIN}" "${ATHENA_ATTEND_OWNER_SLACK_ID}" "${msg}" >/dev/null 2>&1 \
    || say "owner DM failed to send: ${msg}"
}

transcript_dir() {
  if [ -n "${ATHENA_ATTEND_TRANSCRIPT_DIR:-}" ]; then printf '%s' "${ATHENA_ATTEND_TRANSCRIPT_DIR}"; return; fi
  # Claude Code's project-slug maps BOTH '/' and '.' to '-'; mapping only '/'
  # would miss the dir for any dotted path (e.g. a repo under ~/x.y/), so
  # attend_transcript_bytes would return n/a and size-rotation silently no-op --
  # the failed-lookup-looks-empty class. When rotation goes live (idle seam),
  # this is the key that must actually match.
  printf '%s/.claude/projects/%s' "${HOME}" "$(printf '%s' "${PROJECT_DIR}" | sed 's#[/.]#-#g')"
}

get_status_json() { ( cd -- "${PROJECT_DIR}" 2>/dev/null && "${INBOX_STATUS}" --json 2>/dev/null ); }

has_session() { "${TMUX_BIN}" has-session -t "${SESSION}" 2>/dev/null; }
kill_session() { "${TMUX_BIN}" kill-session -t "${SESSION}" 2>/dev/null || true; }

# new_session_id -> a fresh UUID for the claude session about to launch. The
# rotation idle gate keys on THIS session's idle.<sid> marker, so each launched
# session gets its own id (a fresh id per (re)launch), stored in SESSION_ID_F.
new_session_id() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid; return; fi
  if command -v uuidgen >/dev/null 2>&1; then uuidgen; return; fi
  # last resort: a time+pid+random token (still per-launch-unique).
  printf 'attend-%s-%s-%s\n' "$(date +%s)" "$$" "${RANDOM:-0}"
}

launch_session() {
  # A per-launch session id: passed to claude as --session-id AND into the env as
  # ATHENA_ATTEND_SESSION_ID, so ack_wake writes ack.<sid> and the Stop hook
  # writes idle.<sid> under the SAME id the rotation gate reads (validate both
  # sides of the comparison). Stored in SESSION_ID_F for one_cycle to read.
  local sid; sid="$(new_session_id)"
  # A fresh session starts with NO handled-receipt and NO turn-end marker; the
  # gate keys on the current sid so stale ack.<old>/idle.<old> are never read,
  # but clearing them here keeps a long-lived supervisor's state dir from
  # accumulating one pair of tiny files per rotation, unbounded.
  rm -f -- "${STATE_DIR}"/ack.* "${STATE_DIR}"/idle.* 2>/dev/null || true
  printf '%s\n' "${sid}" >"${SESSION_ID_F}" 2>/dev/null || true

  # `env -u` strips CLAUDE_CODE_SESSION_ATTENDED (so inbox-untrusted-guard
  # enforces) AND CLAUDE_AGENT_ID/TYPE. The agent vars must not merely be unset
  # by us -- they must be REMOVED even if the supervisor's own environment
  # carries them (an agent, or an operator's `Start now:` shell during setup,
  # inherits them). If either reached the session, session.sh / server.mjs would
  # classify it a SUBAGENT and the consumer gate would refuse to ack -- the
  # session could never drain its own channel, ending in a silent channel.dark.
  #
  # ATHENA_ATTEND_STATE_DIR / _SESSION_ID / _LEDGER are PASSED IN so the shim's
  # ack_wake records to the dir the supervisor reads, and the attend skill's
  # `tail -n 40 "$ATHENA_ATTEND_LEDGER"` (allowlisted) resolves to the committed
  # ledger path.
  "${TMUX_BIN}" new-session -d -s "${SESSION}" -c "${PROJECT_DIR}" \
    env -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_AGENT_ID -u CLAUDE_AGENT_TYPE \
    "ATHENA_INBOX_EXPECT_PROJECT=${PROJECT_NAME}" \
    "ATHENA_ATTEND_STATE_DIR=${STATE_DIR}" \
    "ATHENA_ATTEND_SESSION_ID=${sid}" \
    "ATHENA_ATTEND_LEDGER=${LEDGER_F}" \
    "${CLAUDE_BIN}" --dangerously-load-development-channels "server:athena-inbox" \
    --permission-mode default --session-id "${sid}"
}

# wait_pane_contains <text> <timeout-s> -- paced, bounded poll (never a spin).
wait_pane_contains() {
  local text="$1" to="$2" pane deadline
  deadline=$(( SECONDS + to ))
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    pane="$("${TMUX_BIN}" capture-pane -p -t "${SESSION}" 2>/dev/null || true)"
    case "${pane}" in *"${text}"*) return 0 ;; esac
    sleep "${PANE_POLL}"
  done
  return 1
}

# Detect (never answer) the one-time trust/consent dialogs, for the owner.
report_trust_dialogs() {
  local pane; pane="$("${TMUX_BIN}" capture-pane -p -t "${SESSION}" 2>/dev/null || true)"
  case "${pane}" in
    *"trust this folder"*|*"Is this a project you created"*)
      say "one-time project-trust dialog is present -- an owner must answer it once ('tmux attach -t ${SESSION}'); the launcher does NOT answer trust decisions." ;;
  esac
  case "${pane}" in
    *"New MCP server found"*)
      say "one-time 'New MCP server found' consent dialog is present -- an owner must answer it once; the launcher does NOT answer MCP-consent." ;;
  esac
}

# confirm_registration -- wait for the warning, send ONE Enter, assert the
# notice within the budget. rc 0 = registered.
confirm_registration() {
  if wait_pane_contains "${WARNING}" "${DIALOG_TIMEOUT}"; then
    "${TMUX_BIN}" send-keys -t "${SESSION}" Enter 2>/dev/null || true
  else
    say "the dev-channels warning did not appear within ${DIALOG_TIMEOUT}s"
  fi
  if wait_pane_contains "${NOTICE}" "${NOTICE_TIMEOUT}"; then
    return 0
  fi
  report_trust_dialogs
  return 1
}

# launch_and_confirm -- launch, confirm; on a miss, dark + kill + ONE retry;
# on a second miss, wedged + owner DM. rc 0 = registered, 1 = wedged.
launch_and_confirm() {
  launch_session
  if confirm_registration; then
    attend_clear_markers "${STATE_DIR}"
    printf '%s\n' "$(date +%s)" >"${STARTED_F}" 2>/dev/null || true
    say "channel session ${SESSION} registered"
    return 0
  fi
  attend_write_marker "${STATE_DIR}" dark \
    "registration notice not observed within ${NOTICE_TIMEOUT}s of launch; killing and retrying once"
  say "registration notice MISSING; killing ${SESSION} and retrying once (channel.dark)"
  kill_session
  launch_session
  if confirm_registration; then
    attend_clear_markers "${STATE_DIR}"
    printf '%s\n' "$(date +%s)" >"${STARTED_F}" 2>/dev/null || true
    say "channel session ${SESSION} registered on retry"
    return 0
  fi
  attend_write_marker "${STATE_DIR}" wedged \
    "the registration notice never appeared after two launches; the dev-channels dialog may have changed. Fix: 'tmux attach -t ${SESSION}' to inspect/answer the pane, re-verify P2 (ai/docs/inbox-channels-probes.md), then 'rm $(attend_marker "${STATE_DIR}" wedged)' and re-run."
  dm_owner "athena channel session for ${PROJECT_NAME} WEDGED: the registration notice never appeared after two launches. Attend the tmux pane (${SESSION})."
  say "registration notice MISSING after retry; channel.wedged + owner DM"
  return 1
}

# check_version -- HARD gate. rc 0 = the running claude matches the pin.
check_version() {
  local out actual
  out="$("${CLAUDE_BIN}" --version 2>/dev/null)"
  actual="$(attend_extract_version "${out}")"
  if attend_version_ok "${actual}" "${PIN}"; then return 0; fi
  attend_write_marker "${STATE_DIR}" wedged \
    "Fix: Claude Code is ${actual:-unknown}, P2 was verified on ${PIN}; re-run the T0 probe on ${actual:-<v>} (ai/docs/inbox-channels-probes.md), then update the pin in scripts/athena-channel-session.sh"
  dm_owner "athena channel session for ${PROJECT_NAME} did NOT launch: Claude Code ${actual:-unknown} != pinned ${PIN}. A blind keypress into an unknown dialog is the hazard. Re-verify P2 and update the pin."
  say "version pin mismatch (${actual:-unknown} != ${PIN}); NOT launching; channel.wedged + owner DM"
  return 1
}

is_idle() {
  # T4/DND-285: the turn has fully ended for THIS session iff ack_wake was called
  # (ack.<sid> exists) AND the Stop hook fired afterwards (idle.<sid> newer than
  # the ack). ack_wake is called "last", but output can still follow it, so the
  # ack alone is NOT proof the turn ended -- the newer idle marker is. Keys on the
  # session's OWN id (SESSION_ID_F), never a global marker (a global one from any
  # other session would read as idle -- the failed-lookup class). Absence of any
  # of these means "cannot confirm idle" -> not idle, so a rotation never cuts a
  # reply (deny-by-default).
  local sid; sid="$(cat "${SESSION_ID_F}" 2>/dev/null || true)"
  attend_turn_ended "${STATE_DIR}" "${sid}"
}

permission_request_open() {
  # T5 seam: a rotation must also not fire while a permission request is open.
  # Pre-T5 there is no such signal, so none is ever open (rc 1). Shaped so T5
  # wires the real check in here with no change to the gate call site.
  return 1
}

read_int() { local v; v="$(cat "$1" 2>/dev/null || true)"; case "${v}" in ''|*[!0-9]*) echo 0 ;; *) echo "${v}" ;; esac; }

rotate_session() {
  say "rotating ${SESSION} ($1)"
  kill_session
  printf '0\n' >"${WAKES_F}" 2>/dev/null || true
  launch_and_confirm
}

# ---- dry-run ---------------------------------------------------------------
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "== channel session plan for ${PROJECT_DIR} =="
  echo "  project name : ${PROJECT_NAME}"
  echo "  tmux session : ${SESSION}"
  echo "  state dir    : ${STATE_DIR}"
  echo "  pinned claude: ${PIN}"
  echo "  ledger       : ${LEDGER_F}"
  echo "  launch       : ${TMUX_BIN} new-session -d -s ${SESSION} -c ${PROJECT_DIR} \\"
  echo "                   env -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_AGENT_ID -u CLAUDE_AGENT_TYPE \\"
  echo "                   ATHENA_INBOX_EXPECT_PROJECT=${PROJECT_NAME} ATHENA_ATTEND_STATE_DIR=${STATE_DIR} \\"
  echo "                   ATHENA_ATTEND_SESSION_ID=<uuid> ATHENA_ATTEND_LEDGER=${LEDGER_F} \\"
  echo "                   ${CLAUDE_BIN} --dangerously-load-development-channels server:athena-inbox --permission-mode default --session-id <uuid>"
  echo "  (dry-run changed nothing and started no session)"
  exit 0
fi

# ---- single instance (flock held for this supervisor's lifetime) -----------
# The */5 relaunch entry hits this while a healthy supervisor holds the lock; a
# second invocation exits 0 in silence, so cron costs nothing.
touch -- "${PIDFILE}" 2>/dev/null || {
  echo "error: cannot write the pidfile: ${PIDFILE}" >&2
  echo "  Fix: ensure ${STATE_DIR} exists and is writable, then re-run." >&2
  exit 2
}
exec 9>>"${PIDFILE}"
if ! flock -n 9; then
  exit 0
fi
printf '%s\n' "$$" >"${PIDFILE}" 2>/dev/null || true

# ---- signal handling: SIGTERM tears down the tmux session ------------------
teardown() { kill_session; }
trap 'teardown; say "terminated by signal; tearing down ${SESSION}"; exit 143' TERM
trap 'teardown; say "interrupted; tearing down ${SESSION}"; exit 130' INT

# ---- version pin BEFORE any launch -----------------------------------------
check_version || exit 75

# ---- one supervise cycle ---------------------------------------------------
# Reads counts, maintains the wake counter, detects runtime dark (unread that
# does not clear within the handle budget), restarts on dark (bounded), and
# rotates when a bound has tripped AND the gate is open.
UNREAD_SINCE=""
one_cycle() {
  local doc token word now bytes age wakes reason
  doc="$(get_status_json)"
  token="$(attend_counts_state "${doc}")"; word="${token%% *}"

  # wake counter: the wakes file is bumped by the shim's ack_wake tool
  # (server.mjs recordAck) each time the session handles a wake -- "rotation
  # counts ack_wake calls" (DND-285). The supervisor no longer infers wakes from
  # an unread->zero count transition; it just READS the counter below.

  now="$(date +%s)"

  # runtime dark detection: unread persisting past the handle budget after a
  # bell. An uncountable poll is NOT dark (it is a count fault) -- but it is
  # also never idle, so it blocks rotation below.
  if [ "${word}" = "unread" ]; then
    [ -n "${UNREAD_SINCE}" ] || UNREAD_SINCE="${now}"
    if [ "$(( now - UNREAD_SINCE ))" -ge "${HANDLE_BUDGET}" ]; then
      attend_write_marker "${STATE_DIR}" dark \
        "unread did not clear within ${HANDLE_BUDGET}s of a wake (channels: ${token#* }). Fix: confirm the pane shows the registration notice, or the session will be restarted; if this recurs it wedges. See design §3.4."
      say "runtime channel.dark: unread persisted ${HANDLE_BUDGET}s"
    fi
  else
    UNREAD_SINCE=""
  fi

  # restart on a dark marker, bounded (design §3.4).
  if [ -e "$(attend_marker "${STATE_DIR}" dark)" ]; then
    if attend_restart_allowed "${RESTARTS_LOG}" "${RESTART_CAP}" "${RESTART_WINDOW}" "${now}"; then
      say "channel.dark present; restarting ${SESSION} (within cap)"
      kill_session
      launch_and_confirm || return 75
      UNREAD_SINCE=""
    else
      attend_write_marker "${STATE_DIR}" wedged \
        "the channel went dark and was restarted ${RESTART_CAP} times within ${RESTART_WINDOW}s without recovering. Fix: 'tmux attach -t ${SESSION}' to see why the session is not consuming; then clear $(attend_marker "${STATE_DIR}" wedged) and re-run."
      dm_owner "athena channel session for ${PROJECT_NAME} WEDGED: dark ${RESTART_CAP}x in an hour; the session is not consuming. Attend ${SESSION}."
      say "restart cap hit; channel.wedged + owner DM"
      return 75
    fi
  fi

  # rotation: a tripped bound AND an open gate (idle, all counts zero, no
  # permission request open).
  bytes="$(attend_transcript_bytes "$(transcript_dir)")"
  age=0; [ -f "${STARTED_F}" ] && age=$(( now - $(read_int "${STARTED_F}") ))
  wakes="$(read_int "${WAKES_F}")"
  reason="$(attend_rotation_reason "${wakes}" "${MAX_WAKES}" "${bytes}" "${MAX_BYTES}" "${age}" "${MAX_AGE}")"
  if [ -n "${reason}" ]; then
    local idle=0 perm=0
    is_idle && idle=1
    permission_request_open && perm=1
    if attend_rotation_gate_open "${word}" "${idle}" "${perm}"; then
      rotate_session "${reason}" || return 75
      UNREAD_SINCE=""
    else
      say "rotation deferred (${reason}): counts=${word} idle=${idle} permission_open=${perm} -- never cut a reply / an uncountable channel"
    fi
  fi
  return 0
}

# ---- run -------------------------------------------------------------------
say "attending ${PROJECT_DIR} as ${SESSION} (pid $$)"
launch_and_confirm || exit 75

if [ "${MODE}" = "once" ]; then
  one_cycle; rc=$?
  [ "${rc}" -eq 75 ] && exit 75
  exit 0
fi

cycles=0
while :; do
  # bounded, paced external poll of a state the harness cannot observe.
  sleep "${POLL_INTERVAL}"
  one_cycle; rc=$?
  [ "${rc}" -eq 75 ] && exit 75
  cycles=$(( cycles + 1 ))
  if [ "${MAX_CYCLES}" -gt 0 ] && [ "${cycles}" -ge "${MAX_CYCLES}" ]; then
    say "reached MAX_CYCLES ${MAX_CYCLES}; supervisor stopping"
    exit 0
  fi
done
