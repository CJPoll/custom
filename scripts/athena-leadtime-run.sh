#!/usr/bin/env bash
#
# athena-leadtime-run.sh — cron entrypoint for the lead-time improver loop
# (DND-1479; design: ai/docs/lead-time-improver.md, Decision 1 and *Where
# things live*).
#
# Each tick starts a headless Claude Code session that spawns ONE
# athena-shipwright in MODE: lead-time, and the shipwright runs the
# athena:lead-time-improve skill once. The operator surface (lock, wedge,
# blocked, alerts, .run records) is modelled on scripts/athena-clustering-run.sh.
# The git lane is modelled on scripts/athena-shipwright-run.sh, because a run
# may land one harness change on main.
#
# Where the run happens. A fresh worktree <git common dir>/leadtime-lanes/
# run-<utc>-<pid> on branch leadtime/run-<utc>-<pid>, cut from origin/main and
# torn down after the run. The session never starts in the main checkout.
# Liveness of a lane is a held flock on <lanes>/<run-id>.lock; a dead lane is
# reaped at the start of a tick by that lock, never by a pid. A lane whose
# commits are not on origin/main is STRANDED: its branch is kept, never
# deleted, and the tick counts as unsuccessful. After the session the main
# checkout is fast-forwarded only to the run's OWN newest commit, once it is on
# origin/main (DND-1008), never forced. The run's own commits are the ones its
# lane's HEAD reflog records it making, never every commit its lane holds: a
# sync down moves the lane onto other fleets' commits too (DND-1507).
#
# MCP. Claude Code resolves local-scope MCP servers from the launch directory,
# and they are registered on the main checkout. The runner copies the one
# server the run needs, notion-personal (an architect files DND tickets
# through it), into a 0600 --mcp-config file beside the lane, and launches with
# --strict-mcp-config, so no other configured server or connector loads. A
# missing notion-personal is a hard failure, never a session without it.
#
# Telemetry. The runner prunes the telemetry store (telemetry-emit --prune) on
# every tick that takes the single-run lock, wedged or not, before anything
# else; the skill does not prune. A prune failure is recorded on the tick's
# record and never fails the tick by itself.
#
# Thresholds. The wedge fires after 3 unsuccessful outcomes: three hourly
# ticks, between the clustering runner's 2 (twice a day) and the shipwright's
# 6. The blocked alert fires after 2 blocked ticks, as clustering's does.
#
# Single-run: an flock on <state>/run.lock. A tick that finds it held exits 0
# and leaves a .locked record.
#
# Usage:
#   scripts/athena-leadtime-run.sh             # the cron invocation
#   scripts/athena-leadtime-run.sh --dry-run   # print this tick's brief; touch nothing
#   scripts/athena-leadtime-run.sh --help      # this text
#   (DRY_RUN=1 is the same as --dry-run.)
#
# State (machine-local; ai-artifacts/ is gitignored): <main checkout>/ai-artifacts/lead-time/
#   runs/<ts>.log       the session's output          runs/<ts>.summary  the skill's summary lines
#   runs/<ts>.receipt   the session reached the model runs/<ts>.failed   an unsuccessful outcome
#   runs/<ts>.blocked   the session never started     runs/<ts>.wedged   a wedged tick
#   runs/<ts>.locked    skipped: a run was in flight  runs/<ts>.git.log  the runner's own git output
#   runs/<ts>.run       every tick that spawned a session: outcome, exit, lane,
#                       main_moved= (origin/main's motion during the run, any
#                       author), own_landed= (the run's own commits on
#                       origin/main: <n> <sha>..., or UNKNOWN), ff= (the
#                       main-checkout fast-forward), the prune result and the
#                       summary
#   consecutive-failures  the wedge counter; `rm` it to re-arm a wedged lane
#   consecutive-blocked   the blocked streak; clears when a session reaches the model
#   ledger.jsonl, experiments.jsonl, journal.md, cursor.<repo>.txt  the skill's own
#
# Environment (test seams and overrides):
#   LEADTIME_REPO             a checkout of the harness repo (default: this script's)
#   LEADTIME_CLAUDE           claude binary (default ~/.local/bin/claude)
#   LEADTIME_CLAUDE_JSON      Claude Code's config holding the MCP servers (default ~/.claude.json)
#   LEADTIME_FAIL_ESCALATE    consecutive unsuccessful outcomes before a tick
#                             refuses to spawn and exits 75 (default 3)
#   LEADTIME_BLOCK_ESCALATE   consecutive blocked ticks before the one blocked
#                             alert (default 2)
#   LEADTIME_TIMEOUT          hard cap on the session, whole minutes as <N>m (default 50m)
#   LEADTIME_NOW              epoch seconds to treat as now: names the tick (tests)
#   LEADTIME_SEND_MAIL        send-mail to use for alerts (tests)
#   LEADTIME_LANES_DIR        where lanes live (default <git common dir>/leadtime-lanes)
#   LEADTIME_TELEMETRY_EMIT   telemetry-emit to prune with (default the main checkout's)
#   ATHENA_INBOX_ROOT         where the wedge and blocked alerts are delivered
#
# Exit codes:
#   0   the run reported, or the tick was skipped (lock held)
#   1   origin/main could not be resolved, so there is no base for a lane: counted
#   2   the repo is not a git checkout
#   64  usage error
#   69  BLOCKED: the session never reached the model (usage limit, auth): no
#       receipt, no summary and no lane commit, with exit 0 or a known limit
#       or auth message. Never counted toward the wedge and never gates a spawn. After
#       LEADTIME_BLOCK_ESCALATE blocked ticks in a row, ONE harness-alert
#       (leadtime-blocked) per episode, since an auth fault never clears
#   70  the session exited 0 but wrote no summary: counted
#   71  flock failed for a reason other than "held" (a fault, never a skip)
#   72  STRANDED: the lane holds commits that are not on origin/main, whatever
#       the session's exit. The branch is kept: counted
#   73  the state directory, lock, lane or MCP config could not be created
#       (a lane or config failure is counted)
#   75  WEDGED: LEADTIME_FAIL_ESCALATE unsuccessful outcomes in a row. No
#       session runs. The tick writes runs/<ts>.wedged, and the first wedged
#       tick of an episode sends ONE harness-alert (leadtime-wedged)
#   78  the athena:lead-time-improve skill or ai/config/lead-time-repos.json is
#       not in the main checkout, or notion-personal is not registered: counted
#   *   the session's own non-zero exit (124 on timeout): counted

set -euo pipefail

export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin${PATH:+:${PATH}}"
export LANG="C.UTF-8" LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
ME="athena-leadtime"

usage() { sed -n '/^# Usage:/,/^#   \*   the session/p' -- "$0" | sed 's/^# \{0,1\}//'; }

DRY=0
[ "${DRY_RUN:-0}" = "1" ] && DRY=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY=1 ;;
    *) echo "${ME}: unknown argument: $1" >&2
       echo "  Fix: run with no arguments (the cron form), --dry-run, or --help." >&2
       exit 64 ;;
  esac
  shift
done

REPO="${LEADTIME_REPO:-${SCRIPT_DIR}/..}"
CLAUDE="${LEADTIME_CLAUDE:-${HOME}/.local/bin/claude}"
CLAUDE_JSON="${LEADTIME_CLAUDE_JSON:-${HOME}/.claude.json}"
REQUIRED_MCP="notion-personal"

TIMEOUT="${LEADTIME_TIMEOUT:-50m}"
case "${TIMEOUT}" in
  [1-9]m|[1-9][0-9]m|[1-9][0-9][0-9]m) ;;
  *) echo "${ME}: LEADTIME_TIMEOUT='${TIMEOUT}' is not whole minutes written <N>m (1m..999m); using 50m." >&2
     echo "  Fix: set it like 50m, or unset it." >&2
     TIMEOUT=50m ;;
esac
FAIL_ESCALATE="${LEADTIME_FAIL_ESCALATE:-3}"
case "${FAIL_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "${ME}: LEADTIME_FAIL_ESCALATE='${FAIL_ESCALATE}' is not a positive integer; using 3." >&2
    echo "  Fix: set it to a positive whole number of consecutive unsuccessful outcomes, or unset it." >&2
    FAIL_ESCALATE=3 ;;
esac
BLOCK_ESCALATE="${LEADTIME_BLOCK_ESCALATE:-2}"
case "${BLOCK_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "${ME}: LEADTIME_BLOCK_ESCALATE='${BLOCK_ESCALATE}' is not a positive integer; using 2." >&2
    echo "  Fix: set it to a positive whole number of consecutive blocked ticks, or unset it." >&2
    BLOCK_ESCALATE=2 ;;
esac
NOW="${LEADTIME_NOW:-$(date +%s)}"
case "${NOW}" in
  ''|*[!0-9]*)
    echo "${ME}: LEADTIME_NOW='${NOW}' is not epoch seconds." >&2
    echo "  Fix: unset LEADTIME_NOW (it is a test seam) or give it a whole number of seconds." >&2
    exit 64 ;;
esac

# The main checkout, through git's common dir, so state is one place whichever
# tree the script runs from. Never a relative path.
common="$(git -C "${REPO}" rev-parse --git-common-dir 2>/dev/null || true)"
case "${common}" in ''|/*) ;; *) common="${REPO}/${common}" ;; esac
GIT_COMMON=""
[ -n "${common}" ] && GIT_COMMON="$(cd -- "${common}" 2>/dev/null && pwd -P || true)"
if [ -z "${GIT_COMMON}" ]; then
  echo "${ME}: ${REPO} is not a git checkout, so there is no main checkout to anchor state to." >&2
  echo "  Fix: point LEADTIME_REPO at a checkout of ~/dev/custom, or run the script from one." >&2
  exit 2
fi
MAIN_CHECKOUT="$(dirname -- "${GIT_COMMON}")"

STATE_DIR="${MAIN_CHECKOUT}/ai-artifacts/lead-time"
LOG_DIR="${STATE_DIR}/runs"
LOCK="${STATE_DIR}/run.lock"
FAIL_COUNT="${STATE_DIR}/consecutive-failures"
WEDGE_STATE="${STATE_DIR}/wedged"
BLOCK_COUNT="${STATE_DIR}/consecutive-blocked"
BLOCK_STATE="${STATE_DIR}/blocked"
SKILL_FILE="${MAIN_CHECKOUT}/ai/skills/athena:lead-time-improve/SKILL.md"
CONFIG_FILE="${MAIN_CHECKOUT}/ai/config/lead-time-repos.json"
TELEMETRY_EMIT="${LEADTIME_TELEMETRY_EMIT:-${MAIN_CHECKOUT}/ai/bin/telemetry-emit}"

ts="$(date -u -d "@${NOW}" +%Y%m%dT%H%M%SZ)-$$"
LANES_DIR="${LEADTIME_LANES_DIR:-${GIT_COMMON}/leadtime-lanes}"
RUN_ID="run-${ts}"
BRANCH="leadtime/${RUN_ID}"
LANE="${LANES_DIR}/${RUN_ID}"
LANE_LOCK="${LANES_DIR}/${RUN_ID}.lock"
LANE_META="${LANES_DIR}/${RUN_ID}.meta"
MCP_FILE="${LANES_DIR}/${RUN_ID}.mcp.json"
log="${LOG_DIR}/${ts}.log"
GIT_LOG="${LOG_DIR}/${ts}.git.log"
RECEIPT="${LOG_DIR}/${ts}.receipt"
SUMMARY="${LOG_DIR}/${ts}.summary"

# --- the brief ----------------------------------------------------------------
# The outer session only delegates. The shipwright writes the summary file
# itself (the skill's *Reporting*); the outer session never writes it, so a
# shipwright that did not finish reads as exit 70, never as a green run.
BRIEF="First, before anything else, run exactly this one Bash command: \
touch \"\$LEADTIME_RECEIPT\" — it is the runner's liveness receipt. Then you are \
coordinating; do the work by delegating. Spawn exactly one athena-shipwright \
agent (Agent tool, subagent_type: athena-shipwright) with this brief, and do \
nothing else yourself: 'MODE: lead-time. This is the scheduled lead-time \
improver run from the cron runner scripts/athena-leadtime-run.sh, with no human \
present. Run the athena:lead-time-improve skill and nothing else, for every repo \
in your lane copy of ai/config/lead-time-repos.json. Your lane is the cron lane \
the runner made for you: the worktree ${LANE} on branch ${BRANCH}, cut from \
origin/main. Work only there, starting every Bash command with cd ${LANE}; never \
edit the main checkout ${MAIN_CHECKOUT}. You are on the cron path: land only \
as athena:lead-time-improve (Landing) directs, the full bar and the push it \
cites, with your lane HEAD pushed to main by refspec (athena:shipwright-lane, \
Sync up). Open no PR. If a gate or the critic \
refuses your change, do what athena:lead-time-improve (Landing) says for a \
refusal on the cron path: journal it and reset your lane, so it holds no \
unlanded commit. The runner fast-forwards \
the main checkout after you exit. State dir: ${STATE_DIR} (LEAD_TIME_STATE_DIR \
is already exported with it). The runner does the telemetry prune; do not prune. \
Write your summary lines to exactly this file: ${SUMMARY}. Your hard constraint \
is your block Speed a safety check up; never weaken it (ai/blocks/ops/safety-checks.md). \
End with your summary lines.' When it finishes, print the contents of ${SUMMARY} \
and stop. Never write to that file yourself."

if [ "${DRY}" -eq 1 ]; then
  printf '%s\n' "${BRIEF}"
  exit 0
fi

# --- 1. single-run lock --------------------------------------------------------
# The lock file outlives a run by design: flock(2) lives on the descriptor.
# Never delete it. `>>` so a contending tick cannot truncate the holder line.
if ! { mkdir -p "${LOG_DIR}" && exec 9>>"${LOCK}"; } 2>/dev/null; then
  echo "${ME}: cannot create the state directory ${STATE_DIR} or open its lock; no run, and no record could be written." >&2
  echo "  Fix: check that ${MAIN_CHECKOUT}/ai-artifacts is writable and the disk is not full." >&2
  exit 73
fi
# Only exit 1 means "held". Anything else (flock missing, a bad descriptor) is a
# fault, never a silent skip that would read as a run in flight forever.
lock_rc=0
flock -n 9 || lock_rc=$?
if [ "${lock_rc}" -ne 0 ] && [ "${lock_rc}" -ne 1 ]; then
  printf '%s: tick %s could not take the lock (flock exit %s).\n' "${ME}" "${ts}" "${lock_rc}" >"${LOG_DIR}/${ts}.failed" 2>/dev/null || true
  echo "${ME}: flock failed with exit ${lock_rc} on ${LOCK}; no run." >&2
  echo "  Fix: confirm util-linux flock is installed ('command -v flock') and ${LOCK} is a regular writable file." >&2
  exit 71
fi
if [ "${lock_rc}" -eq 1 ]; then
  holder="$(cat "${LOCK}" 2>/dev/null || true)"
  printf '%s: tick %s skipped; a run was already in flight.\nholder: %s\n' "${ME}" "${ts}" "${holder:-unknown}" \
    >"${LOG_DIR}/${ts}.locked"
  echo "${ME}: a run is already in progress (${holder:-holder unknown}); skipping this tick." >&2
  echo "  Fix: nothing to do; the in-flight run finishes on its own. Do NOT delete ${LOCK}: it is held on an open descriptor." >&2
  exit 0
fi
printf 'pid=%s host=%s started=%s\n' "$$" "$(hostname 2>/dev/null || echo '?')" "$(date -Is)" >"${LOCK}"

# --- suppress D-Bus autolaunch (after arg parsing and the lock) ----------------
# See ~/dev/custom/CLAUDE.md -> "Cron D-Bus autolaunch leak".
# shellcheck source=scripts/lib/dbus-env.sh
. "${SCRIPT_DIR}/lib/dbus-env.sh"
athena_dbus_env_setup
"${SCRIPT_DIR}/reap-orphan-dbus" --min-age 300 >/dev/null 2>&1 || true
# The athena MCP authenticates through its headersHelper; never an env token.
unset ATHENA_MCP_BEARER
export LEADTIME_RECEIPT="${RECEIPT}" LEADTIME_SUMMARY="${SUMMARY}" LEAD_TIME_STATE_DIR="${STATE_DIR}"
export GIT_TERMINAL_PROMPT=0

# --- counter helpers -----------------------------------------------------------
read_count() { # <file>
  local n=0
  [ -r "$1" ] && n="$(cat "$1" 2>/dev/null || echo 0)"
  case "${n}" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "${n}"
}
bump_count() { printf '%s\n' "$(( $(read_count "$1") + 1 ))" >"$1"; }
read_fail()  { read_count "${FAIL_COUNT}"; }
bump_fail()  { bump_count "${FAIL_COUNT}"; }
reset_fail() { rm -f "${FAIL_COUNT}"; }
state_get()  { [ -r "$1" ] && sed -n "s/^$2=//p" "$1" | head -n1 || true; }

# record_failure <why> <detail-line>... — write runs/<ts>.failed and count it.
record_failure() {
  local why="$1"; shift
  {
    printf '%s: run %s was an unsuccessful outcome: %s\n' "${ME}" "${ts}" "${why}"
    printf '%s\n' "$@"
    printf 'prune=%s\n' "${PRUNE_RESULT:-not run}"
    printf 'log=%s\n' "${log}"
  } >"${LOG_DIR}/${ts}.failed" || true
  bump_fail
}

# --- one harness-alert per episode (the clustering runner's pattern) -----------
# Two streaks alert: the WEDGE (failures; the lane stops spawning) and a BLOCKED
# streak (the session never reaches the model; nothing gates, but a lasting
# auth or account fault would otherwise be silent, because cron mail is not
# read on this machine). An episode opens at the streak's first alerting-state
# tick and ends when its counter clears. The record, never the message, is the
# authority the reader verifies.

harness_alert_send() { # <record> <slug> <body-file>; prints the delivered name
  local record="$1" slug="$2" body="$3" repo send_mail out rc=0 attempt=0
  repo="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
  send_mail="${LEADTIME_SEND_MAIL:-${repo}/ai/skills/athena:inbox/bin/send-mail}"
  [ -x "${send_mail}" ] || { echo "send-mail is missing: ${send_mail}" >&2; return 4; }
  while :; do
    attempt=$(( attempt + 1 )); rc=0
    out="$(cd -- "${repo}" && timeout 20 "${send_mail}" --local harness-alerts-detector "${slug}" \
            --to custom --re "${record}" --body-file "${body}" 2>&1)" || rc=$?
    if [ "${rc}" -eq 0 ] || [ "${attempt}" -ge 3 ] || ! grep -q 'already sending on' <<<"${out}"; then
      break
    fi
    sleep 2
  done
  if [ "${rc}" -ne 0 ]; then printf '%s\n' "${out}" | head -n 3 >&2; return "${rc}"; fi
  # A delivery whose name send-mail did not print is still a delivery: never an
  # empty name, which the episode state would read as "not yet sent".
  local name
  name="$(printf '%s\n' "${out}" | sed -n 's/^athena:inbox: delivered //p' | tail -n 1)"
  printf '%s\n' "${name:-(delivered; name not reported)}"
}

# episode_load <state> <counter> — sets ep_id, ep_first, ep_alerted. A new
# episode's id is this tick; its first time is when the counter last changed.
episode_load() {
  local mt
  ep_id="$(state_get "$1" episode)"; ep_first="$(state_get "$1" first)"; ep_alerted="$(state_get "$1" alerted)"
  if [ -z "${ep_id}" ]; then
    ep_id="${ts}"; ep_alerted=""; ep_first="unknown"
    if mt="$(stat -c %Y -- "$2" 2>/dev/null)"; then ep_first="$(date -u -d "@${mt}" +%Y-%m-%dT%H:%M:%SZ)"; fi
  fi
  [ -n "${ep_first}" ] || ep_first="unknown"
}

# episode_alert <kind> <record> <state> <body-file> — send the episode's one
# alert (slug leadtime-<kind>) if not yet sent, note it in the record, save the
# state. A failed send is loud and not recorded as sent, so the next tick
# retries. Always returns 0 and removes <body-file>.
episode_alert() {
  local kind="$1" record="$2" state="$3" body="$4" name err tmp=""
  if [ -n "${ep_alerted}" ]; then
    printf 'alert: already sent for this episode (%s)\n' "${ep_alerted}" >>"${record}"
    echo "${ME}: this ${kind} episode (since ${ep_id}) was already alerted (${ep_alerted}). Record: ${record}" >&2
  else
    err="$(mktemp)" || err=/dev/null
    if name="$(harness_alert_send "${record}" "leadtime-${kind}" "${body}" 2>"${err}")"; then
      ep_alerted="${name}"
      printf 'alert: harness-alerts %s\n' "${name}" >>"${record}"
      echo "${ME}: ${kind} ALERTED on harness-alerts (${name}). Record: ${record}" >&2
    else
      printf 'alert: FAILED to send\n' >>"${record}"
      echo "${ME}: the ${kind} harness-alert could NOT be sent: $(tr '\n' ' ' <"${err}" 2>/dev/null)" >&2
      echo "  Fix: run inbox-doctor from ${MAIN_CHECKOUT} (is the custom registry entry installed with its harness-alerts channels? scripts/setup-inbox-registry --install). The next ${kind} tick retries." >&2
    fi
    [ "${err}" = /dev/null ] || rm -f "${err}"
  fi
  [ -z "${body}" ] || rm -f "${body}"
  if ! { tmp="$(mktemp "${state}.XXXXXX" 2>/dev/null)" \
         && printf 'episode=%s\nfirst=%s\nalerted=%s\n' "${ep_id}" "${ep_first}" "${ep_alerted}" >"${tmp}" \
         && mv -f "${tmp}" "${state}"; }; then
    [ -z "${tmp}" ] || rm -f "${tmp}"
    echo "${ME}: could not save the ${kind} episode state ${state}; the next ${kind} tick alerts again." >&2
    echo "  Fix: check that ${STATE_DIR} is writable and the disk is not full." >&2
  fi
  return 0
}

# new_body — a private temp file for an alert body, or empty.
new_body() { local b; b="$(mktemp "${TMPDIR:-/tmp}/leadtime-alert.XXXXXX")" && chmod 600 "${b}" && printf '%s' "${b}"; }

# The newest run log with output: usually the last session that said why.
last_output_log() {
  local f
  f="$(find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' ! -name '*.git.log' -size +0 -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -n1 | cut -d' ' -f2- || true)"
  printf '%s' "${f:-(none)}"
}

# wedge_track <failures> — write runs/<ts>.wedged; alert once per episode.
wedge_track() {
  local failures="$1" record="${LOG_DIR}/${ts}.wedged" body
  episode_load "${WEDGE_STATE}" "${FAIL_COUNT}"
  if {
    printf '%s: tick %s refused to spawn a session: the lane is WEDGED (exit 75).\n' "${ME}" "${ts}"
    printf 'why: %s consecutive unsuccessful outcomes reached the threshold %s. No lead-time run happens until the counter is cleared.\n' "${failures}" "${FAIL_ESCALATE}"
    printf 'counter=%s\n' "${FAIL_COUNT}"
    printf 'last_output_log=%s\n' "$(last_output_log)"
    printf 'rearm: rm %s\n' "${FAIL_COUNT}"
    printf 'prune=%s\n' "${PRUNE_RESULT:-not run}"
    printf 'Fix: read why the runs failed (the .failed and .run records and logs in %s), fix the cause, then re-arm with: rm %s\n' "${LOG_DIR}" "${FAIL_COUNT}"
    printf 'wedged: consecutive_failures=%s threshold=%s first_wedged=%s episode=%s\n' \
      "${failures}" "${FAIL_ESCALATE}" "${ep_first}" "${ep_id}"
  } >"${record}" 2>/dev/null; then :; else
    echo "${ME}: could not write the wedge record ${record}; no alert this tick." >&2
    echo "  Fix: check that ${LOG_DIR} is writable and the disk is not full. Re-arm with 'rm ${FAIL_COUNT}' once the cause is fixed." >&2
    return 0
  fi
  body="$(new_body)" && {
    printf 'The lead-time improver cron on this machine is WEDGED: every tick exits 75 and spawns no session, so no lead-time run happens (DND-1479).\n'
    printf 'This is a report. The wedge record named in re: is the authority.\n\n'
    printf 'checkout: %s\nepisode: %s\nfirst_wedged: %s\nconsecutive_failures: %s\nthreshold: %s\ncounter: %s\n' \
      "${MAIN_CHECKOUT}" "${ep_id}" "${ep_first}" "${failures}" "${FAIL_ESCALATE}" "${FAIL_COUNT}"
    printf '\nFix: read the .failed records and logs under %s, fix the cause, then re-arm the lane with: rm %s. This alert is sent once per wedge episode.\n' "${LOG_DIR}" "${FAIL_COUNT}"
  } >"${body}"
  episode_alert wedged "${record}" "${WEDGE_STATE}" "${body:-}"
}

# blocked_track <exit> <signature> — the session never reached the model. Write
# runs/<ts>.blocked; from BLOCK_ESCALATE in a row, alert once per episode. Never
# gates a spawn and never touches the wedge counter.
blocked_track() {
  local status="$1" sig="$2" record="${LOG_DIR}/${ts}.blocked" streak body
  bump_count "${BLOCK_COUNT}"
  streak="$(read_count "${BLOCK_COUNT}")"
  episode_load "${BLOCK_STATE}" "${BLOCK_COUNT}"
  if {
    printf '%s: run %s did no work; the session never reported for duty.\n' "${ME}" "${ts}"
    printf 'session_exit=%s\nclassification=%s\nlog=%s\n' "${status}" "${sig:-UNCLASSIFIED}" "${log}"
    printf 'Fix: read the log. A usage limit clears on its own; an auth, billing or account fault does not: check %s by hand. Nothing to re-arm.\n' "${CLAUDE}"
    printf 'blocked: consecutive_blocked=%s threshold=%s first_blocked=%s episode=%s\n' \
      "${streak}" "${BLOCK_ESCALATE}" "${ep_first}" "${ep_id}"
  } >"${record}" 2>/dev/null; then :; else
    echo "${ME}: could not write the blocked record ${record}; no alert this tick." >&2
    echo "  Fix: check that ${LOG_DIR} is writable and the disk is not full." >&2
    return 0
  fi
  echo "${ME}: run ${ts} BLOCKED (${sig:-unclassified}); no run happened; ${streak} blocked tick(s) in a row. Record: ${record}" >&2
  echo "  Fix: read ${log}. A usage limit clears on its own and the next tick runs. If it persists, check account, billing and auth for ${CLAUDE}." >&2
  if [ "${streak}" -lt "${BLOCK_ESCALATE}" ]; then
    # Keep the episode open without alerting yet.
    printf 'episode=%s\nfirst=%s\nalerted=%s\n' "${ep_id}" "${ep_first}" "${ep_alerted}" >"${BLOCK_STATE}" 2>/dev/null || true
    return 0
  fi
  body="$(new_body)" && {
    printf 'The lead-time improver cron on this machine is BLOCKED: %s ticks in a row never reached the model, so no lead-time run happened (DND-1479). It keeps trying every tick; nothing is wedged.\n' "${streak}"
    printf 'This is a report. The blocked record named in re: is the authority.\n\n'
    printf 'checkout: %s\nepisode: %s\nfirst_blocked: %s\nconsecutive_blocked: %s\nthreshold: %s\nclassification: %s\nlog: %s\n' \
      "${MAIN_CHECKOUT}" "${ep_id}" "${ep_first}" "${streak}" "${BLOCK_ESCALATE}" "${sig:-UNCLASSIFIED}" "${log}"
    printf '\nFix: read the log. A usage limit clears on its own. An auth, billing or account fault does not: check the claude login on this machine. This alert is sent once per blocked episode; the episode ends when a session reaches the model.\n'
  } >"${body}"
  episode_alert blocked "${record}" "${BLOCK_STATE}" "${body:-}"
}

# --- lane helpers (adapted from the shipwright runner) --------------------------
# A commit is LANDED once it is reachable from origin/main. Local main is never
# evidence of landing (DND-1008).
commit_landed() { # commit-ish
  git -C "${MAIN_CHECKOUT}" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 || return 1
  git -C "${MAIN_CHECKOUT}" merge-base --is-ancestor "$1" refs/remotes/origin/main 2>/dev/null
}

# retire_lane <run-id> <context> — remove one lane's worktree, and delete its
# branch unless its commits are not on origin/main (then keep it, say how to
# recover, and return 1). The branch is never deleted while it holds work.
retire_lane() {
  local rid="$1" ctx="$2" wt="${LANES_DIR}/$1" br="leadtime/$1"
  git -C "${MAIN_CHECKOUT}" worktree remove --force "${wt}" >>"${GIT_LOG}" 2>&1 || rm -rf -- "${wt}"
  git -C "${MAIN_CHECKOUT}" worktree prune >>"${GIT_LOG}" 2>&1 || true
  if git -C "${MAIN_CHECKOUT}" show-ref --verify --quiet "refs/heads/${br}"; then
    if commit_landed "${br}"; then
      git -C "${MAIN_CHECKOUT}" branch -D "${br}" >>"${GIT_LOG}" 2>&1 || true
    else
      echo "${ME}: kept STRANDED branch ${br} (${ctx}); its commits are not on origin/main." >&2
      echo "  Fix: the work is NOT lost. Inspect it with 'git -C ${MAIN_CHECKOUT} log origin/main..${br}', then land it through the custom landing (athena:merge-boarding -> The merge bar) or drop it, and delete it with 'git -C ${MAIN_CHECKOUT} branch -D ${br}'. It is never auto-deleted." >&2
      return 1
    fi
  fi
  return 0
}

# reap_dead_lanes — a lane whose lock nobody holds belongs to a run that died
# before its teardown. Liveness is the held flock, NEVER a pid (pids recycle,
# and the kernel releases a lock on SIGKILL or power loss). Reap only a lane
# whose lock we can take, and reap while holding it. A reaped lane never
# reported, so it counts as an unsuccessful outcome: an every-run crash must
# still reach the wedge.
reap_dead_lanes() {
  [ -d "${LANES_DIR}" ] || return 0
  local lock rid wt got
  for lock in "${LANES_DIR}"/run-*.lock; do
    [ -e "${lock}" ] || continue
    rid="$(basename -- "${lock}" .lock)"
    got=""
    if got="$(
      exec 7>>"${lock}"
      if flock -n 7; then
        retire_lane "${rid}" "reaped dead run" >/dev/null || true
        printf 'reaped'
      fi
    )"; [ "${got}" = "reaped" ]; then
      rm -f -- "${lock}" "${LANES_DIR}/${rid}.meta" "${LANES_DIR}/${rid}.mcp.json"
      bump_fail
      echo "${ME}: reaped dead lane ${rid} (a run that died before teardown); counted as an unsuccessful outcome." >&2
    fi
    # else: a live process holds the lock; leave the lane strictly alone.
  done
  # A worktree dir with no lock file is a crash between `worktree add` and the
  # lock. We hold the single-run lock, so no concurrent tick can own it.
  for wt in "${LANES_DIR}"/run-*; do
    [ -d "${wt}" ] || continue
    rid="$(basename -- "${wt}")"
    [ -e "${LANES_DIR}/${rid}.lock" ] && continue
    retire_lane "${rid}" "reaped lockless lane" >/dev/null || true
    rm -f -- "${LANES_DIR}/${rid}.meta" "${LANES_DIR}/${rid}.mcp.json"
    bump_fail
    echo "${ME}: reaped lockless lane ${rid}; counted as an unsuccessful outcome." >&2
  done
  return 0
}

# --- 2. prune telemetry (the runner's job, not the skill's) ----------------------
# Every tick that holds the lock prunes, wedged or not, so retention holds while
# the lane is down. Recorded on the tick's record; a failure is loud and never
# fails the tick.
prune_rc=0
prune_out="$(timeout 120 "${TELEMETRY_EMIT}" --prune 2>&1 </dev/null)" || prune_rc=$?
if [ "${prune_rc}" -eq 0 ]; then
  PRUNE_RESULT="ok: $(printf '%s\n' "${prune_out}" | tail -n1)"
else
  PRUNE_RESULT="FAILED exit=${prune_rc}: $(printf '%s\n' "${prune_out}" | grep -v '^[[:space:]]*$' | tail -n1 || true)"
  echo "${ME}: telemetry-emit --prune failed (exit ${prune_rc}); the tick goes ahead and its record says so." >&2
  echo "  Fix: run '${TELEMETRY_EMIT} --prune' by hand from ${MAIN_CHECKOUT} and follow its own Fix: line. Old day files stay until a prune succeeds." >&2
fi

# --- 3. fetch origin/main -----------------------------------------------------------
# Before the reaper, so it judges a dead lane's work against a current
# origin/main. A failed fetch (no network, or no ssh-agent under cron) falls
# back to the origin/main this checkout last fetched: the session syncs down
# first anyway (athena:shipwright-lane).
FETCH_NOTE="fetched"
if ! timeout 120 git -C "${MAIN_CHECKOUT}" fetch --quiet origin main </dev/null >>"${GIT_LOG}" 2>&1; then
  FETCH_NOTE="fetch FAILED; based on the last-fetched origin/main"
  echo "${ME}: could not fetch origin/main; using the last-fetched origin/main. The session syncs down itself." >&2
  echo "  Fix: nothing needed for this tick. If every tick says so, read ${GIT_LOG} for git's reason." >&2
fi

# An episode ends once its counter clears: the wedge below the threshold (the
# owner's re-arm), checked before the reaper can bump it, so a re-arm then a
# corpse opens a new episode.
if [ "$(read_fail)" -lt "${FAIL_ESCALATE}" ] && [ -e "${WEDGE_STATE}" ]; then
  rm -f "${WEDGE_STATE}"
fi

# --- 4. reap dead lanes ---------------------------------------------------------
reap_dead_lanes

# --- 5. the wedge ----------------------------------------------------------------
failures="$(read_fail)"
if [ "${failures}" -ge "${FAIL_ESCALATE}" ]; then
  echo "${ME}: WEDGED — ${failures} consecutive unsuccessful outcomes. Refusing to spawn a session." >&2
  echo "  Fix: read the .failed records and logs under ${LOG_DIR}, fix the cause, then re-arm with 'rm ${FAIL_COUNT}'." >&2
  wedge_track "${failures}"
  exit 75
fi

# --- 6. preconditions: the skill, the config, the MCP server ----------------------
# precondition_fail <why> <fix> — the run cannot happen without these.
precondition_fail() {
  record_failure "$1" "fix=$2"
  echo "${ME}: $1" >&2
  echo "  Fix: $2" >&2
  exit 78
}
# Without the skill or the config the shipwright can only report that it did
# nothing, and that summary would read as a green run.
if [ ! -r "${SKILL_FILE}" ]; then
  precondition_fail "the athena:lead-time-improve skill is not in the main checkout (${SKILL_FILE}), so there is no run to do; counted as an unsuccessful outcome." \
    "land the skill (DND-1478) on main and fast-forward ${MAIN_CHECKOUT}; the next tick runs."
fi
if [ ! -r "${CONFIG_FILE}" ]; then
  precondition_fail "the repo config ${CONFIG_FILE} is not in the main checkout, so no repo has a mode; counted as an unsuccessful outcome." \
    "land ai/config/lead-time-repos.json (DND-1477) on main and fast-forward ${MAIN_CHECKOUT}; the next tick runs."
fi
if ! command -v jq >/dev/null 2>&1; then
  precondition_fail "jq is not on PATH, so the MCP servers in ${CLAUDE_JSON} cannot be read." \
    "install jq."
fi
if [ ! -r "${CLAUDE_JSON}" ]; then
  precondition_fail "cannot read ${CLAUDE_JSON}, where Claude Code keeps the MCP servers registered for ${MAIN_CHECKOUT}." \
    "confirm Claude Code has run on this machine and ${CLAUDE_JSON} is readable, or set LEADTIME_CLAUDE_JSON."
fi
# A file jq cannot parse is its own fault, never "no servers registered".
if ! jq empty "${CLAUDE_JSON}" >/dev/null 2>&1; then
  precondition_fail "${CLAUDE_JSON} is not valid JSON (corrupt, or read mid-write), so its MCP servers cannot be read." \
    "run 'jq empty ${CLAUDE_JSON}' to see the parse error. If it was a mid-write read, the next tick succeeds; do NOT re-register the servers."
fi
servers="$(jq -c --arg p "${MAIN_CHECKOUT}" '.projects[$p].mcpServers // empty | select(type == "object")' \
  "${CLAUDE_JSON}" 2>/dev/null || true)"
if [ -z "${servers}" ]; then
  precondition_fail "no local-scope MCP servers are registered under the key '${MAIN_CHECKOUT}' in ${CLAUDE_JSON} ($(jq '[.projects[]? | select(.mcpServers? | type == "object" and length > 0)] | length' "${CLAUDE_JSON}" 2>/dev/null || echo '?') project(s) have any)." \
    "from ${MAIN_CHECKOUT}, run scripts/add-notion --personal, then re-run this script by hand."
fi
missing=""
for s in ${REQUIRED_MCP}; do
  jq -e --arg s "${s}" 'has($s)' <<<"${servers}" >/dev/null 2>&1 || missing="${missing} ${s}"
done
if [ -n "${missing}" ]; then
  precondition_fail "the MCP server(s)${missing} are not registered for ${MAIN_CHECKOUT} in ${CLAUDE_JSON}; an architect the run spawns files DND tickets through notion-personal." \
    "from ${MAIN_CHECKOUT}, run scripts/add-notion --personal."
fi
# Only the servers the run needs; --strict-mcp-config below keeps every other
# configured server and connector out of the session.
mcp_config="$(jq -c --arg names "${REQUIRED_MCP}" \
  '($names | split(" ")) as $want | {mcpServers: with_entries(select(.key as $k | $want | index($k)))}' \
  <<<"${servers}")"

# --- 7. the lane ------------------------------------------------------------------
# Cut from origin/main. No origin/main at all is a counted failure, never a
# lane cut from something else.
BASE="$(git -C "${MAIN_CHECKOUT}" rev-parse --verify --quiet refs/remotes/origin/main 2>/dev/null || true)"
if [ -z "${BASE}" ]; then
  record_failure "there is no origin/main in ${MAIN_CHECKOUT}, so there is no base for a lane" "fetch=${FETCH_NOTE}" "git_log=${GIT_LOG}"
  echo "${ME}: no origin/main to cut lane ${RUN_ID} from; no session spawned. Counted as an unsuccessful outcome." >&2
  echo "  Fix: confirm the origin remote exists and has main ('git -C ${MAIN_CHECKOUT} fetch origin main'); git's reason is in ${GIT_LOG}." >&2
  exit 1
fi
if ! { mkdir -p "${LANES_DIR}" && chmod 700 "${LANES_DIR}"; } 2>/dev/null \
   || ! git -C "${MAIN_CHECKOUT}" worktree add -q -b "${BRANCH}" "${LANE}" "${BASE}" >>"${GIT_LOG}" 2>&1; then
  record_failure "could not create the lane ${LANE} on branch ${BRANCH}" "lane=${LANE}" "git_log=${GIT_LOG}"
  echo "${ME}: could not create the lane ${LANE} on branch ${BRANCH}; no session spawned. Counted as an unsuccessful outcome." >&2
  echo "  Fix: read ${GIT_LOG} for git's reason. A branch-name collision is fatal by design (never reused or forced); clear a stale registration with 'git -C ${MAIN_CHECKOUT} worktree prune'." >&2
  exit 73
fi
# The lane's liveness lock, held on fd 8 for the whole run and inherited by the
# session (as the shipwright runner does): a runner killed mid-session leaves
# the lock held by the live session, so the next tick never reaps a lane in use.
# Teardown removes the lock file, so a child that outlives teardown pins nothing.
printf 'origin=cron\npid=%s\nrun_id=%s\n' "$$" "${RUN_ID}" >"${LANE_META}"
exec 8>>"${LANE_LOCK}"
if ! flock -n 8; then
  retire_lane "${RUN_ID}" "lane lock already held" >/dev/null || true
  { exec 8>&-; } 2>/dev/null || true
  rm -f -- "${LANE_META}"
  record_failure "the fresh lane lock ${LANE_LOCK} was already held" "lane=${LANE}"
  echo "${ME}: the fresh lane lock ${LANE_LOCK} is already held; refusing to run. Counted as an unsuccessful outcome." >&2
  echo "  Fix: this should be impossible for a unique run id. Check for a process holding it ('fuser -v ${LANE_LOCK}')." >&2
  exit 73
fi
trap 'rm -f -- "${MCP_FILE}"' EXIT
if ! ( umask 077; printf '%s\n' "${mcp_config}" >"${MCP_FILE}" ) 2>/dev/null; then
  retire_lane "${RUN_ID}" "no MCP config" >/dev/null || true
  { exec 8>&-; } 2>/dev/null || true
  rm -f -- "${LANE_LOCK}" "${LANE_META}"
  record_failure "could not write the session's MCP config ${MCP_FILE}" "lane=${LANE}"
  echo "${ME}: could not write ${MCP_FILE}; no session spawned. Counted as an unsuccessful outcome." >&2
  echo "  Fix: check that ${LANES_DIR} is writable and the disk is not full." >&2
  exit 73
fi

# --- 8. run the session -------------------------------------------------------------
# A headless session kills background tasks after 600s by default; the
# shipwright runs as one. Bound the ceiling three minutes under the hard
# timeout so a hung run still releases the lock before the next tick. `-k`
# kills a session that ignores SIGTERM. `9>&-`: nothing the session starts may
# inherit the run lock, or a surviving child would make every later tick skip
# as "in flight".
timeout_min="${TIMEOUT%m}"
if [ "${timeout_min}" -gt 3 ]; then
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$(( (timeout_min - 3) * 60000 ))"
else
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$(( timeout_min * 30000 ))"
fi
rm -f "${RECEIPT}" "${SUMMARY}"
status=0
( cd -- "${LANE}" && exec timeout -k 60s "${TIMEOUT}" "${CLAUDE}" --dangerously-skip-permissions \
    --mcp-config "${MCP_FILE}" --strict-mcp-config -p "${BRIEF}" 9>&- ) </dev/null >"${log}" 2>&1 || status=$?

# --- 9. teardown: what landed, the fast-forward, the lane ---------------------------
AFTER_FETCH=""
if ! timeout 120 git -C "${MAIN_CHECKOUT}" fetch --quiet origin main </dev/null >>"${GIT_LOG}" 2>&1; then
  # The run's own push still updates origin/main's tracking ref; a landing it
  # made another way (a push to a URL) is only seen once origin/main is fetched.
  AFTER_FETCH=" (origin/main NOT re-fetched after the run: as of the last fetch or the run's own push)"
fi
AFTER="$(git -C "${MAIN_CHECKOUT}" rev-parse --verify --quiet refs/remotes/origin/main 2>/dev/null || true)"
# How far origin/main moved during the run, whoever moved it: other fleets'
# merges count here too, so this is never the run's own landings (DND-1507).
MAIN_MOVED="origin/main ${BASE}..${AFTER:-unknown}"
if [ -n "${AFTER}" ]; then
  MAIN_MOVED="${MAIN_MOVED} commits=$(git -C "${MAIN_CHECKOUT}" rev-list --count "${BASE}..${AFTER}" 2>/dev/null || echo '?')"
fi
MAIN_MOVED="${MAIN_MOVED}${AFTER_FETCH}"

# landed_rc <commit> — 0 on origin/main, 1 not on it, 2 could not tell (no
# origin/main, or git failed). commit_landed folds 2 into "not landed", which is
# right for keeping a branch; a record must not read an error as a miss.
landed_rc() {
  git -C "${MAIN_CHECKOUT}" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 || return 2
  local rc=0
  git -C "${MAIN_CHECKOUT}" merge-base --is-ancestor "$1" refs/remotes/origin/main 2>/dev/null || rc=$?
  case "${rc}" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}
tip="$(git -C "${LANE}" rev-parse HEAD 2>/dev/null || true)"

# own_commits — print the run's own commits still on the lane, newest first.
# A lane that moved off BASE is not evidence of its own work: a sync down
# (athena:shipwright-lane) fast-forwards or rebases it onto other fleets'
# commits. A commit is the run's own when the lane's HEAD reflog records it
# being MADE there (a commit, cherry-pick, revert, rebase pick, am, or a merge
# that made a commit) and it is still in BASE..tip. A sync, reset or checkout
# only moves HEAD, so it never credits a commit. A lookup that cannot be done
# returns non-zero (1: no readable HEAD reflog; 2: it does not start at BASE;
# 3: rev-list failed), so nothing is credited and it never reads as "no own
# commits" (a failed lookup is not an empty one).
# The sequencer's step label is the stable part of a rebase entry; the action
# before it is the caller's argv ("rebase", "pull -q --rebase https://... main"),
# which may itself hold a colon. A cherry-pick --ff that only moved HEAD
# ("cherry-pick: fast-forward") made nothing (OWN_MOVED_ONLY).
OWN_MADE='^(commit|cherry-pick|revert|am)( \([a-z]+\))?: |^(rebase|pull)( [^(]*)? \((pick|reword|edit|squash|fixup|continue|merge)\): |: Merge made by '
OWN_MOVED_ONLY=': fast-forward$'
own_commits() {
  local reflog first made log_path range
  # With no HEAD reflog git silently shows the branch's reflog instead, which
  # records a rebase only as its finish and so would under-credit: require the
  # file itself.
  log_path="$(git -C "${LANE}" rev-parse --git-path logs/HEAD 2>/dev/null)" || return 1
  case "${log_path}" in /*) ;; *) log_path="${LANE}/${log_path}" ;; esac
  [ -s "${log_path}" ] || return 1
  reflog="$(git -C "${LANE}" reflog show --format='%H %gs' HEAD -- 2>/dev/null)" || return 1
  [ -n "${reflog}" ] || return 1
  first="$(printf '%s\n' "${reflog}" | tail -n1 | cut -d' ' -f1)"
  [ "${first}" = "${BASE}" ] || return 2
  made="$(printf '%s\n' "${reflog}" | while read -r sha gs; do
            if grep -q -E -- "${OWN_MADE}" <<<"${gs}" && ! grep -q -E -- "${OWN_MOVED_ONLY}" <<<"${gs}"; then
              printf '%s\n' "${sha}"
            fi
          done | sort -u)"
  [ -n "${made}" ] || return 0
  # Capture the range first: a failed rev-list must not read as "no own commits".
  range="$(git -C "${LANE}" rev-list --topo-order "${BASE}..${tip}" 2>/dev/null)" || return 3
  [ -n "${range}" ] || return 0
  printf '%s\n' "${range}" | grep -F -x -f <(printf '%s\n' "${made}") || true
}

# Fast-forward the main checkout only to the run's newest own commit that is on
# origin/main, so the live harness advances to landed
# work and never to unreviewed work, and the run never ff's to (or claims)
# another fleet's commit. Only when the main checkout is on main; never forced.
OWN_LANDED="0"
FF="none (the run made no commits of its own)"
own=""
own_rc=0
if [ -n "${tip}" ]; then own="$(own_commits)" || own_rc=$?; else own_rc=4; fi
if [ "${own_rc}" -ne 0 ]; then
  catch_up="Any work the run landed is on origin/main: 'git -C ${MAIN_CHECKOUT} merge --ff-only origin/main' picks it up."
  case "${own_rc}" in
    1) own_why="the lane's HEAD reflog is missing or unreadable"
       own_fix="check core.logAllRefUpdates is not false for ${MAIN_CHECKOUT} ('git -C ${MAIN_CHECKOUT} config core.logAllRefUpdates')." ;;
    2) own_why="the lane's HEAD reflog does not start at BASE ${BASE}"
       own_fix="the reflog was rewritten or expired during the run (git reflog expire, gc), or the lane was not created by this runner; read ${GIT_LOG}." ;;
    3) own_why="git rev-list ${BASE}..${tip} failed in the lane"
       own_fix="read ${GIT_LOG} and check the lane repository is intact ('git -C ${MAIN_CHECKOUT} fsck')." ;;
    *) own_why="the lane's HEAD could not be resolved"
       own_fix="the lane ${LANE} was removed or broken during the run; read ${GIT_LOG}." ;;
  esac
  OWN_LANDED="UNKNOWN (${own_why})"
  FF="none (own commits UNKNOWN: ${own_why})"
  echo "${ME}: run ${ts}: ${own_why}, so the run's own commits cannot be told from a sync; the main checkout was not fast-forwarded." >&2
  echo "  Fix: ${own_fix} ${catch_up}" >&2
elif [ -n "${own}" ]; then
  # Newest first (topo order), so the first landed one is the ff target.
  landed_own=""; landed_n=0; own_tip=""; newest_own=""; land_err=""
  for oc in ${own}; do
    [ -n "${newest_own}" ] || newest_own="${oc}"
    lrc=0; landed_rc "${oc}" || lrc=$?
    case "${lrc}" in
      0) landed_own="${landed_own} ${oc}"; landed_n=$(( landed_n + 1 )); [ -n "${own_tip}" ] || own_tip="${oc}" ;;
      1) ;;
      *) land_err="${oc}" ;;
    esac
  done
  main_ref="$(git -C "${MAIN_CHECKOUT}" symbolic-ref -q HEAD 2>/dev/null || true)"
  if [ -n "${land_err}" ]; then
    OWN_LANDED="UNKNOWN (could not tell whether ${land_err} is on origin/main)"
    FF="none (own landings UNKNOWN: git could not compare ${land_err} with origin/main)"
    echo "${ME}: run ${ts}: git could not tell whether the run's own commit ${land_err} is on origin/main; the main checkout was not fast-forwarded." >&2
    echo "  Fix: check origin/main resolves ('git -C ${MAIN_CHECKOUT} rev-parse origin/main') and read ${GIT_LOG}. Any work the run landed is on origin/main: 'git -C ${MAIN_CHECKOUT} merge --ff-only origin/main' picks it up." >&2
    own_tip=""
  else
    OWN_LANDED="${landed_n}${landed_own}"
  fi
  if [ -n "${land_err}" ]; then
    :
  elif [ -z "${own_tip}" ]; then
    FF="none (the run's own commit ${newest_own} is not on origin/main)"
  elif [ "${main_ref}" != "refs/heads/main" ]; then
    FF="REFUSED (the main checkout is on ${main_ref:-a detached HEAD}, not main)"
    echo "${ME}: run ${ts}: the run's own commit ${own_tip} is on origin/main, but ${MAIN_CHECKOUT} is not on main, so it was not fast-forwarded." >&2
    echo "  Fix: switch ${MAIN_CHECKOUT} back to main when its owner is done, then 'git -C ${MAIN_CHECKOUT} merge --ff-only origin/main'." >&2
  elif git -C "${MAIN_CHECKOUT}" merge --ff-only "${own_tip}" >>"${GIT_LOG}" 2>&1; then
    FF="${own_tip}"
    if [ "${own_tip}" != "${newest_own}" ]; then
      FF="${own_tip} (the newest own landed commit; the run's newer own commit ${newest_own} is not on origin/main)"
    fi
  else
    FF="REFUSED (see ${GIT_LOG})"
    echo "${ME}: run ${ts}: the run's own commit ${own_tip} is on origin/main, but ${MAIN_CHECKOUT} could not be fast-forwarded to it." >&2
    echo "  Fix: nothing is lost; the work is on origin/main. Clear what blocks it (usually a locally-modified file, or local commits on main; never force either), then run 'git -C ${MAIN_CHECKOUT} merge --ff-only ${own_tip}'. git's reason is at the end of ${GIT_LOG}." >&2
  fi
fi

STRANDED=0
LANE_RESULT="removed"
if ! retire_lane "${RUN_ID}" "run ${ts}"; then
  STRANDED=1
  LANE_RESULT="branch ${BRANCH} KEPT (stranded: commits not on origin/main)"
fi
{ exec 8>&-; } 2>/dev/null || true
rm -f -- "${LANE_LOCK}" "${LANE_META}" "${MCP_FILE}"

# --- 10. classify, then finish -----------------------------------------------------
# finish <exit> <outcome> — every tick that spawned a session ends here and
# writes runs/<ts>.run.
finish() {
  local rc="$1" outcome="$2" run="${LOG_DIR}/${ts}.run"
  if ! {
    printf '%s: run %s outcome=%s exit=%s\n' "${ME}" "${ts}" "${outcome}" "${rc}"
    printf 'lane=%s branch=%s (%s)\n' "${LANE}" "${BRANCH}" "${LANE_RESULT}"
    printf 'base=%s (%s)\n' "${BASE}" "${FETCH_NOTE}"
    printf 'main_moved=%s\n' "${MAIN_MOVED}"
    printf 'own_landed=%s\n' "${OWN_LANDED}"
    printf 'ff=%s\n' "${FF}"
    printf 'prune=%s\n' "${PRUNE_RESULT}"
    if [ -s "${SUMMARY}" ]; then
      sed 's/^/summary: /' -- "${SUMMARY}"
    else
      printf 'summary: (none: %s absent or empty)\n' "${SUMMARY}"
    fi
    printf 'log=%s\n' "${log}"
  } >"${run}" 2>/dev/null; then
    echo "${ME}: could not write the run record ${run}." >&2
    echo "  Fix: check that ${LOG_DIR} is writable and the disk is not full." >&2
  fi
  exit "${rc}"
}

# Did the session reach the model? The receipt says so, but it rests on the
# outer session obeying the brief's first line. A summary (only the shipwright
# writes it) or a lane that moved off its base proves it too, so a working run
# that skipped the touch is never read as BLOCKED.
REACHED=0
if [ -e "${RECEIPT}" ] || [ -s "${SUMMARY}" ] || { [ -n "${tip}" ] && [ "${tip}" != "${BASE}" ]; }; then
  REACHED=1
fi
# A session that never reached the model, with exit 0 or a known block
# signature on a non-zero exit, is BLOCKED: never counted toward the wedge (a
# usage limit clears on its own), but BLOCK_ESCALATE in a row send one alert
# (an auth or account fault does not clear). Anything else is a failure (a
# missing binary or a crash must still wedge). The clustering runner's rule;
# the log holds only the session's output.
BLOCK_PATTERNS='usage limit|session limit|weekly limit|daily limit|rate limit|rate_limit|quota|out of credits|credit balance|insufficient_quota|billing|overloaded|Too Many Requests|(http|status|error|code)[^a-z0-9]{0,3}429\b|authentication|unauthorized|invalid api key'
if [ "${REACHED}" -eq 0 ]; then
  sig="$(grep -m1 -i -E -o "${BLOCK_PATTERNS}" -- "${log}" 2>/dev/null || true)"
  if [ "${status}" -eq 0 ] || [ -n "${sig}" ]; then
    blocked_track "${status}" "${sig}"
    finish 69 blocked
  fi
  record_failure "the session exited ${status} and never reported for duty (no receipt, no summary, no lane commit)" "session_exit=${status}"
  echo "${ME}: run ${ts} exited ${status} and never reported for duty. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log}; check that ${CLAUDE} runs by hand ('${CLAUDE} --version'). If the log shows a provider limit, add its wording to BLOCK_PATTERNS in $0." >&2
  finish "${status}" failed
fi
# The session reached the model: any blocked streak and its episode end here.
rm -f "${BLOCK_COUNT}" "${BLOCK_STATE}"
# Stranded first, whatever the session's exit: the kept branch is the thing
# the owner has to act on.
if [ "${STRANDED}" -eq 1 ]; then
  record_failure "the lane holds commits that are not on origin/main" "branch=${BRANCH} (kept)" "tip=${tip}" "session_exit=${status}"
  echo "${ME}: run ${ts} is STRANDED: ${BRANCH} holds commits not on origin/main (session exit ${status}). Counted as unsuccessful. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: inspect with 'git -C ${MAIN_CHECKOUT} log origin/main..${BRANCH}'; land it through the custom landing or drop it, then 'git -C ${MAIN_CHECKOUT} branch -D ${BRANCH}'. The journal (${STATE_DIR}/journal.md) says why it did not land." >&2
  finish 72 stranded
fi
if [ "${status}" -ne 0 ]; then
  record_failure "the session exited ${status}" "session_exit=${status}"
  echo "${ME}: run ${ts} exited ${status}. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log} for why the run failed (124 is the ${TIMEOUT} timeout). ${FAIL_ESCALATE} in a row wedge the lane." >&2
  finish "${status}" failed
fi
if [ ! -s "${SUMMARY}" ]; then
  record_failure "the session exited 0 but wrote no summary, so the run cannot be shown to have happened" "session_exit=0" "summary=${SUMMARY} (absent or empty)"
  echo "${ME}: run ${ts} exited 0 with no summary; counted as unsuccessful. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log}; the shipwright should write its summary lines to ${SUMMARY} (athena:lead-time-improve -> Reporting)." >&2
  finish 70 failed
fi

reset_fail
echo "${ME}: run ${ts} ok: $(head -n1 "${SUMMARY}")" >&2
finish 0 ok
