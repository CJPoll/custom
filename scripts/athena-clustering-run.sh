#!/usr/bin/env bash
#
# athena-clustering-run.sh — cron entrypoint for the 12h epic-clustering pass
# (DND-983; design: the scope-growth proposal §7 "Clustering cadence").
#
# Twice a day, cron runs this. It starts a headless Claude Code session that
# spawns ONE athena-architect, and the architect runs one pass of the
# athena:epic-clustering skill. The architect owns epic writes; the shipwright
# cron is harness-only and never writes Notion, so this is a separate runner.
# The morning run (owner timezone America/Denver) also sends the daily digest.
#
# Where the run happens. The pass writes Notion and Slack only. It does no git
# work, so its lane is a private scratch directory, not a worktree:
# <state>/lanes/run-<ts>, created per run and removed after it. The session
# never starts in the main checkout. Claude Code resolves local-scope MCP
# servers from the launch directory, and the Notion and Athena servers are
# registered on the main checkout. So the runner copies that entry's servers
# into a 0600 --mcp-config file in the lane. notion-personal and athena are
# required; a missing one is a hard failure, never a session without them.
#
# Single-run: an flock on <state>/run.lock. A tick that finds it held exits 0
# and leaves a .locked record.
#
# Usage:
#   scripts/athena-clustering-run.sh             # the cron invocation
#   scripts/athena-clustering-run.sh --dry-run   # print this tick's brief; touch nothing
#   scripts/athena-clustering-run.sh --help      # this text
#   (DRY_RUN=1 is the same as --dry-run.)
#
# State (machine-local; ai-artifacts/ is gitignored): <main checkout>/ai-artifacts/clustering/
#   runs/<ts>.log       the session's output         runs/<ts>.summary  the architect's one line
#   runs/<ts>.receipt   the session reached the model runs/<ts>.failed   an unsuccessful outcome
#   runs/<ts>.blocked   the session never started     runs/<ts>.wedged   a wedged tick
#   runs/<ts>.locked    skipped: a run was in flight
#   runs/<ts>.run       every tick that spawned a session: its outcome, and
#                       whether its harness-lane drain request (DND-987) was sent
#   consecutive-failures  the wedge counter; `rm` it to re-arm a wedged lane
#   consecutive-blocked   the blocked streak; clears when a session reaches the model
#   digest-last-day       the America/Denver date the last digest run succeeded
#
# Environment (test seams and overrides):
#   CLUSTERING_REPO           a checkout of the harness repo (default: this script's)
#   CLUSTERING_CLAUDE         claude binary (default ~/.local/bin/claude)
#   CLUSTERING_CLAUDE_JSON    Claude Code's config holding the MCP servers (default ~/.claude.json)
#   CLUSTERING_FAIL_ESCALATE  consecutive unsuccessful outcomes before a tick
#                             refuses to spawn and exits 75 (default 2 = a day)
#   CLUSTERING_BLOCK_ESCALATE consecutive blocked ticks before the one blocked
#                             alert (default 2 = a day)
#   CLUSTERING_TIMEOUT        hard cap on the session (default 120m)
#   CLUSTERING_NOW            epoch seconds to treat as now (tests)
#   CLUSTERING_SEND_MAIL      send-mail to use for alerts and drain requests (tests)
#   ATHENA_INBOX_ROOT         where the wedge alert is delivered
#
# Exit codes:
#   0   the pass ran and reported, or the tick was skipped (lock held)
#   64  usage error
#   69  BLOCKED: the session never reached the model (usage limit, auth).
#       Never counted toward the wedge and never gates a spawn. After
#       CLUSTERING_BLOCK_ESCALATE blocked ticks in a row, ONE harness-alert
#       (clustering-blocked) per episode, since an auth fault never clears
#   70  the session exited 0 but the architect wrote no summary: counted
#   75  WEDGED: CLUSTERING_FAIL_ESCALATE unsuccessful outcomes in a row. No
#       session runs. The tick writes runs/<ts>.wedged, and the first wedged
#       tick of an episode sends ONE harness-alert (clustering-wedged)
#   78  the athena:epic-clustering skill is not in the main checkout, or the
#       MCP servers the pass needs are not registered: counted
#   71  flock failed for a reason other than "held" (a fault, never a skip)
#   73  the state directory, lock or lane could not be created
#   2   the repo is not a git checkout
#   *   the session's own non-zero exit (124 on timeout): counted

set -euo pipefail

export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin${PATH:+:${PATH}}"
export LANG="C.UTF-8" LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
ME="athena-clustering"

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

REPO="${CLUSTERING_REPO:-${SCRIPT_DIR}/..}"
CLAUDE="${CLUSTERING_CLAUDE:-${HOME}/.local/bin/claude}"
CLAUDE_JSON="${CLUSTERING_CLAUDE_JSON:-${HOME}/.claude.json}"
TIMEOUT="${CLUSTERING_TIMEOUT:-120m}"
OWNER_TZ="America/Denver"
REQUIRED_MCP="notion-personal athena"

FAIL_ESCALATE="${CLUSTERING_FAIL_ESCALATE:-2}"
case "${FAIL_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "${ME}: CLUSTERING_FAIL_ESCALATE='${FAIL_ESCALATE}' is not a positive integer; using 2." >&2
    echo "  Fix: set it to a positive whole number of consecutive unsuccessful outcomes, or unset it." >&2
    FAIL_ESCALATE=2 ;;
esac
NOW="${CLUSTERING_NOW:-$(date +%s)}"
case "${NOW}" in
  ''|*[!0-9]*)
    echo "${ME}: CLUSTERING_NOW='${NOW}' is not epoch seconds." >&2
    echo "  Fix: unset CLUSTERING_NOW (it is a test seam) or give it a whole number of seconds." >&2
    exit 64 ;;
esac

# The main checkout, through git's common dir, so state is one place whichever
# tree the script runs from.
common="$(git -C "${REPO}" rev-parse --git-common-dir 2>/dev/null || true)"
case "${common}" in ''|/*) ;; *) common="${REPO}/${common}" ;; esac
MAIN_CHECKOUT=""
[ -n "${common}" ] && MAIN_CHECKOUT="$(dirname -- "$(cd -- "${common}" 2>/dev/null && pwd -P)")"
if [ -z "${common}" ] || [ "${MAIN_CHECKOUT}" = "." ]; then
  echo "${ME}: ${REPO} is not a git checkout, so there is no main checkout to anchor state to." >&2
  echo "  Fix: point CLUSTERING_REPO at a checkout of ~/dev/custom, or run the script from one." >&2
  exit 2
fi

STATE_DIR="${MAIN_CHECKOUT}/ai-artifacts/clustering"
LOG_DIR="${STATE_DIR}/runs"
LANES_DIR="${STATE_DIR}/lanes"
LOCK="${STATE_DIR}/run.lock"
FAIL_COUNT="${STATE_DIR}/consecutive-failures"
WEDGE_STATE="${STATE_DIR}/wedged"
BLOCK_COUNT="${STATE_DIR}/consecutive-blocked"
BLOCK_STATE="${STATE_DIR}/blocked"
BLOCK_ESCALATE="${CLUSTERING_BLOCK_ESCALATE:-2}"
case "${BLOCK_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "${ME}: CLUSTERING_BLOCK_ESCALATE='${BLOCK_ESCALATE}' is not a positive integer; using 2." >&2
    echo "  Fix: set it to a positive whole number of consecutive blocked ticks, or unset it." >&2
    BLOCK_ESCALATE=2 ;;
esac
DIGEST_DAY="${STATE_DIR}/digest-last-day"

# --- the brief ----------------------------------------------------------------
# The morning run is any run before noon in the owner's timezone. The digest
# goes out once per owner day: a re-run the same morning does not repeat it.
owner_hour="$(TZ="${OWNER_TZ}" date -d "@${NOW}" +%H)"
owner_day="$(TZ="${OWNER_TZ}" date -d "@${NOW}" +%Y-%m-%d)"
last_digest="$(cat "${DIGEST_DAY}" 2>/dev/null || true)"
DIGEST=0
if [ "${owner_hour#0}" -lt 12 ] && [ "${last_digest}" != "${owner_day}" ]; then
  DIGEST=1
fi
if [ "${DIGEST}" -eq 1 ]; then
  digest_clause="This is the morning run (${OWNER_TZ}, ${owner_day}): after the pass's moves, also send the daily digest the skill defines."
elif [ "${owner_hour#0}" -lt 12 ]; then
  digest_clause="The daily digest for ${owner_day} (${OWNER_TZ}) was already sent today. Do NOT send the daily digest."
else
  digest_clause="This is NOT the morning run (${OWNER_TZ}, ${owner_day}). Do NOT send the daily digest."
fi
BRIEF="First, before anything else, run exactly this one Bash command: \
touch \"\$CLUSTERING_RECEIPT\" — it is the runner's liveness receipt. Then you \
are coordinating; do the work by delegating. Spawn exactly one athena-architect \
agent (Agent tool, subagent_type: athena-architect) with this brief, and do \
nothing else yourself: 'Run one clustering pass now: load the \
athena:epic-clustering skill and follow it. This is the scheduled 12h pass from \
the clustering cron, with no human present. ${digest_clause} Your writes are \
Notion and Slack, as the skill directs: make no commits, pushes or file edits in \
any repository. Finish with ONE line: what moved, merged, and closed, and \
whether the digest was sent.' When it finishes, write its one line verbatim to \
the file named by \$CLUSTERING_SUMMARY with one Bash command, print it, and stop."

if [ "${DRY}" -eq 1 ]; then
  printf '%s\n' "${BRIEF}"
  exit 0
fi

# --- 1. single-run lock --------------------------------------------------------
# The lock file outlives a run by design: flock(2) lives on the descriptor.
# Never delete it. `>>` so a contending tick cannot truncate the holder line.
if ! { mkdir -p "${LOG_DIR}" "${LANES_DIR}" && chmod 700 "${LANES_DIR}" && exec 9>>"${LOCK}"; } 2>/dev/null; then
  echo "${ME}: cannot create the state directory ${STATE_DIR} or open its lock; no run, and no record could be written." >&2
  echo "  Fix: check that ${MAIN_CHECKOUT}/ai-artifacts is writable and the disk is not full." >&2
  exit 73
fi
ts="$(date -u +%Y%m%dT%H%M%SZ)-$$"
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

log="${LOG_DIR}/${ts}.log"
RECEIPT="${LOG_DIR}/${ts}.receipt"
SUMMARY="${LOG_DIR}/${ts}.summary"
export CLUSTERING_RECEIPT="${RECEIPT}" CLUSTERING_SUMMARY="${SUMMARY}"


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
    printf 'log=%s\n' "${log}"
  } >"${LOG_DIR}/${ts}.failed" || true
  bump_fail
}

# --- one harness-alert per episode (the shipwright's DND-834 pattern) -----------
# Two streaks alert: the WEDGE (failures; the lane stops spawning) and a BLOCKED
# streak (the session never reaches the model; nothing gates, but a lasting
# auth or account fault would otherwise be silent, because cron mail is not
# read on this machine). An episode opens at the streak's first alerting-state
# tick and ends when its counter clears. Each tick writes its own record; only
# the first tick of an episode that can send, sends. The record, never the
# message, is the authority the reader verifies.

# Prints the delivered name. Exit 0 with no delivered line is NOT sent (exit 5):
# the episode stays unalerted and the next tick retries (DND-1513,
# ai/lib/harness-alert-send.sh).
harness_alert_send() { # <record> <slug> <body-file>
  local record="$1" slug="$2" body="$3" repo
  repo="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
  # shellcheck source=ai/lib/harness-alert-send.sh
  . "${repo}/ai/lib/harness-alert-send.sh" || { echo "cannot load ${repo}/ai/lib/harness-alert-send.sh" >&2; return 4; }
  harness_alert_deliver "${CLUSTERING_SEND_MAIL:-${repo}/ai/skills/athena:inbox/bin/send-mail}" "${repo}" 20 3 \
    --local harness-alerts-detector "${slug}" --to custom --re "${record}" --body-file "${body}"
}

# episode_load <state> <counter> — sets ep_id, ep_first, ep_alerted. A new
# episode's id is this tick; its first time is when the counter last changed.
episode_load() {
  local mt
  ep_id="$(state_get "$1" episode)"; ep_first="$(state_get "$1" first)"; ep_alerted="$(state_get "$1" alerted)"
  # An older runner stored "exit 0, no delivered line" as sent under this
  # placeholder. It was never confirmed, so the episode retries (DND-1513).
  [ "${ep_alerted}" != '(delivered; name not reported)' ] || ep_alerted=""
  if [ -z "${ep_id}" ]; then
    ep_id="${ts}"; ep_alerted=""; ep_first="unknown"
    if mt="$(stat -c %Y -- "$2" 2>/dev/null)"; then ep_first="$(date -u -d "@${mt}" +%Y-%m-%dT%H:%M:%SZ)"; fi
  fi
  [ -n "${ep_first}" ] || ep_first="unknown"
}

# episode_alert <kind> <record> <state> <body-file> — send the episode's one
# alert (slug clustering-<kind>) if not yet sent, note it in the record, save
# the state. A failed send is loud and not recorded as sent, so the next tick
# retries. Always returns 0 and removes <body-file>.
episode_alert() {
  local kind="$1" record="$2" state="$3" body="$4" name err tmp=""
  if [ -n "${ep_alerted}" ]; then
    printf 'alert: already sent for this episode (%s)\n' "${ep_alerted}" >>"${record}"
    echo "${ME}: this ${kind} episode (since ${ep_id}) was already alerted (${ep_alerted}). Record: ${record}" >&2
  else
    err="$(mktemp)" || err=/dev/null
    if name="$(harness_alert_send "${record}" "clustering-${kind}" "${body}" 2>"${err}")"; then
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
new_body() { local b; b="$(mktemp "${TMPDIR:-/tmp}/clustering-alert.XXXXXX")" && chmod 600 "${b}" && printf '%s' "${b}"; }

# The newest run log with output: usually the last session that said why.
last_output_log() {
  local f
  f="$(find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' -size +0 -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -n1 | cut -d' ' -f2- || true)"
  printf '%s' "${f:-(none)}"
}

# wedge_track <failures> — write runs/<ts>.wedged; alert once per episode.
wedge_track() {
  local failures="$1" record="${LOG_DIR}/${ts}.wedged" body
  episode_load "${WEDGE_STATE}" "${FAIL_COUNT}"
  if {
    printf '%s: tick %s refused to spawn a session: the lane is WEDGED (exit 75).\n' "${ME}" "${ts}"
    printf 'why: %s consecutive unsuccessful outcomes reached the threshold %s. No clustering pass runs until the counter is cleared.\n' "${failures}" "${FAIL_ESCALATE}"
    printf 'counter=%s\n' "${FAIL_COUNT}"
    printf 'last_output_log=%s\n' "$(last_output_log)"
    printf 'rearm: rm %s\n' "${FAIL_COUNT}"
    printf 'Fix: read why the runs failed (the .failed records and logs in %s), fix the cause, then re-arm with: rm %s\n' "${LOG_DIR}" "${FAIL_COUNT}"
    printf 'wedged: consecutive_failures=%s threshold=%s first_wedged=%s episode=%s\n' \
      "${failures}" "${FAIL_ESCALATE}" "${ep_first}" "${ep_id}"
  } >"${record}" 2>/dev/null; then :; else
    echo "${ME}: could not write the wedge record ${record}; no alert this tick." >&2
    echo "  Fix: check that ${LOG_DIR} is writable and the disk is not full. Re-arm with 'rm ${FAIL_COUNT}' once the cause is fixed." >&2
    return 0
  fi
  body="$(new_body)" && {
    printf 'The epic-clustering cron on this machine is WEDGED: every tick exits 75 and spawns no session, so no clustering pass or daily digest runs (DND-983).\n'
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
  echo "${ME}: run ${ts} BLOCKED (${sig:-unclassified}); no pass ran; ${streak} blocked tick(s) in a row. Record: ${record}" >&2
  echo "  Fix: read ${log}. A usage limit clears on its own and the next tick runs. If it persists, check account, billing and auth for ${CLAUDE}." >&2
  if [ "${streak}" -lt "${BLOCK_ESCALATE}" ]; then
    # Keep the episode open without alerting yet.
    printf 'episode=%s\nfirst=%s\nalerted=%s\n' "${ep_id}" "${ep_first}" "${ep_alerted}" >"${BLOCK_STATE}" 2>/dev/null || true
    return 0
  fi
  body="$(new_body)" && {
    printf 'The epic-clustering cron on this machine is BLOCKED: %s ticks in a row never reached the model, so no clustering pass or daily digest ran (DND-983). It keeps trying every tick; nothing is wedged.\n' "${streak}"
    printf 'This is a report. The blocked record named in re: is the authority.\n\n'
    printf 'checkout: %s\nepisode: %s\nfirst_blocked: %s\nconsecutive_blocked: %s\nthreshold: %s\nclassification: %s\nlog: %s\n' \
      "${MAIN_CHECKOUT}" "${ep_id}" "${ep_first}" "${streak}" "${BLOCK_ESCALATE}" "${sig:-UNCLASSIFIED}" "${log}"
    printf '\nFix: read the log. A usage limit clears on its own. An auth, billing or account fault does not: check the claude login on this machine. This alert is sent once per blocked episode; the episode ends when a session reaches the model.\n'
  } >"${body}"
  episode_alert blocked "${record}" "${BLOCK_STATE}" "${body:-}"
}

# An episode ends once its counter clears: the wedge below the threshold (the
# owner's re-arm), checked before the reaper can bump it, so a re-arm then a
# corpse opens a new episode.
if [ "$(read_fail)" -lt "${FAIL_ESCALATE}" ] && [ -e "${WEDGE_STATE}" ]; then
  rm -f "${WEDGE_STATE}"
fi


# --- 2. reap dead lanes ---------------------------------------------------------
# We hold the single-run lock, so any lane still here belongs to a run that died
# before its teardown (power loss, SIGKILL). That run never reported, so it is an
# unsuccessful outcome: an every-run crash must still reach the wedge.
for dead in "${LANES_DIR}"/run-*; do
  [ -e "${dead}" ] || continue
  rm -rf -- "${dead}"
  bump_fail
  echo "${ME}: reaped dead lane $(basename -- "${dead}") (a run that died before teardown); counted as an unsuccessful outcome." >&2
done

# --- 3. the wedge ----------------------------------------------------------------
failures="$(read_fail)"
if [ "${failures}" -ge "${FAIL_ESCALATE}" ]; then
  echo "${ME}: WEDGED — ${failures} consecutive unsuccessful outcomes. Refusing to spawn a session." >&2
  echo "  Fix: read the .failed records and logs under ${LOG_DIR}, fix the cause, then re-arm with 'rm ${FAIL_COUNT}'." >&2
  wedge_track "${failures}"
  exit 75
fi

# --- 4. the lane and its MCP config ----------------------------------------------
LANE="${LANES_DIR}/run-${ts}"
if ! mkdir -m 700 "${LANE}" 2>/dev/null; then
  record_failure "could not create the lane ${LANE}" "lane=${LANE}"
  echo "${ME}: could not create the lane ${LANE}; no session spawned. Counted as an unsuccessful outcome." >&2
  echo "  Fix: check that ${LANES_DIR} is writable and the disk is not full." >&2
  exit 73
fi
trap 'rm -rf -- "${LANE}"' EXIT

# mcp_fail <why> <fix> — the pass cannot run without these servers.
mcp_fail() {
  record_failure "$1" "fix=$2"
  echo "${ME}: $1" >&2
  echo "  Fix: $2" >&2
  exit 78
}
# The skill the architect runs. Without it the architect can only report that
# it did nothing, and that summary would read as a green run.
SKILL_FILE="${MAIN_CHECKOUT}/ai/skills/athena:epic-clustering/SKILL.md"
if [ ! -r "${SKILL_FILE}" ]; then
  record_failure "the athena:epic-clustering skill is not in the main checkout (${SKILL_FILE}), so there is no pass to run" "skill=${SKILL_FILE} (absent)"
  echo "${ME}: ${SKILL_FILE} is missing; no session spawned. Counted as an unsuccessful outcome." >&2
  echo "  Fix: land the athena:epic-clustering skill (DND-982) on main and fast-forward ${MAIN_CHECKOUT}; the next tick runs." >&2
  exit 78
fi
if ! command -v jq >/dev/null 2>&1; then
  mcp_fail "jq is not on PATH, so the MCP servers in ${CLAUDE_JSON} cannot be read." \
    "install jq (the athena MCP headersHelper needs it too)."
fi
if [ ! -r "${CLAUDE_JSON}" ]; then
  mcp_fail "cannot read ${CLAUDE_JSON}, where Claude Code keeps the MCP servers registered for ${MAIN_CHECKOUT}." \
    "confirm Claude Code has run on this machine and ${CLAUDE_JSON} is readable, or set CLUSTERING_CLAUDE_JSON."
fi
# A file jq cannot parse is its own fault, never "no servers registered".
if ! jq empty "${CLAUDE_JSON}" >/dev/null 2>&1; then
  mcp_fail "${CLAUDE_JSON} is not valid JSON (corrupt, or read mid-write), so its MCP servers cannot be read." \
    "run 'jq empty ${CLAUDE_JSON}' to see the parse error. If it was a mid-write read, the next tick succeeds; do NOT re-register the servers."
fi
servers="$(jq -c --arg p "${MAIN_CHECKOUT}" '.projects[$p].mcpServers // empty | select(type == "object")' \
  "${CLAUDE_JSON}" 2>/dev/null || true)"
if [ -z "${servers}" ]; then
  mcp_fail "no local-scope MCP servers are registered under the key '${MAIN_CHECKOUT}' in ${CLAUDE_JSON} ($(jq '[.projects[]? | select(.mcpServers? | type == "object" and length > 0)] | length' "${CLAUDE_JSON}" 2>/dev/null || echo '?') project(s) have any)." \
    "from ${MAIN_CHECKOUT}, run scripts/add-notion --personal and scripts/add-athena-mcp, then re-run this script by hand."
fi
missing=""
for s in ${REQUIRED_MCP}; do
  jq -e --arg s "${s}" 'has($s)' <<<"${servers}" >/dev/null 2>&1 || missing="${missing} ${s}"
done
if [ -n "${missing}" ]; then
  mcp_fail "the MCP server(s)${missing} are not registered for ${MAIN_CHECKOUT} in ${CLAUDE_JSON}; the pass needs Notion (notion-personal) and Slack (athena)." \
    "from ${MAIN_CHECKOUT}, run scripts/add-notion --personal (notion-personal) and/or scripts/add-athena-mcp (athena)."
fi
if ! ( umask 077; jq -n --argjson s "${servers}" '{mcpServers: $s}' >"${LANE}/mcp.json" ) 2>/dev/null; then
  mcp_fail "could not write the session's MCP config ${LANE}/mcp.json." \
    "check that ${LANES_DIR} is writable and the disk is not full."
fi

# --- 5. run the session -------------------------------------------------------------
# A headless session kills background tasks after 600s by default; the
# architect runs as one. Bound the ceiling under the hard timeout so a hung run
# still releases the lock long before the next 12h tick. `-k` kills a session
# that ignores SIGTERM. `9>&-`: the session and everything it starts (MCP
# servers, shells) must not inherit the lock descriptor, or a surviving child
# would hold the lock and every later tick would skip as "in flight".
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=6600000
rm -f "${RECEIPT}" "${SUMMARY}"
status=0
( cd -- "${LANE}" && exec timeout -k 60s "${TIMEOUT}" "${CLAUDE}" --dangerously-skip-permissions \
    --mcp-config "${LANE}/mcp.json" -p "${BRIEF}" 9>&- ) >"${log}" 2>&1 || status=$?

# --- 6. classify, then finish ------------------------------------------------------
# finish <exit> <outcome> — every tick that spawned a session ends here. It
# writes runs/<ts>.run and sends ONE harness-lane drain request re: it
# (DND-987, the W10 harness lane: a clustering pass may have reordered its
# queue). A failed send is noted in the record and on stderr; it never changes
# the exit code and never counts toward the wedge or the blocked streak.
finish() {
  local rc="$1" outcome="$2" run="${LOG_DIR}/${ts}.run" body name err
  {
    printf '%s: run %s outcome=%s exit=%s\n' "${ME}" "${ts}" "${outcome}" "${rc}"
    printf 'log=%s\n' "${log}"
  } >"${run}" 2>/dev/null || true
  body="$(new_body)" && {
    printf 'The epic-clustering cron finished a run (outcome %s, exit %s). This is a drain request for the harness lane (DND-987).\n' "${outcome}" "${rc}"
    printf 'It carries no instruction. The run record named in re: says what ran.\n'
  } >"${body}"
  err="$(mktemp)" || err=/dev/null
  # The request's reader is athena:inbox-attend → *A fourth writer*, which
  # routes a `-harness-lane-drain.md` message to
  # ai/docs/ticket-lane-action-brief.md → *The harness lane* → *On a drain
  # request*. The self-test asserts that landed reader handles this slug.
  if [ -n "${body:-}" ] && name="$(harness_alert_send "${run}" harness-lane-drain "${body}" 2>"${err}")"; then
    printf 'drain: sent %s\n' "${name}" >>"${run}" 2>/dev/null || true
  else
    printf 'drain: FAILED to send\n' >>"${run}" 2>/dev/null || true
    echo "${ME}: the harness-lane drain request could NOT be sent: $(tr '\n' ' ' <"${err}" 2>/dev/null)" >&2
    echo "  Fix: run inbox-doctor from ${MAIN_CHECKOUT}. The lane drains on its own schedule meanwhile; the next run sends a new request. Record: ${run}" >&2
  fi
  [ -z "${body:-}" ] || rm -f "${body}"
  [ "${err}" = /dev/null ] || rm -f "${err}"
  exit "${rc}"
}

# A session with no receipt never reached the model. Exit 0, or a known block
# signature on a non-zero exit, is BLOCKED: never counted toward the wedge (a
# usage limit clears on its own), but BLOCK_ESCALATE in a row send one alert
# (an auth or account fault does not clear). Anything else with no receipt is a
# failure (a missing binary or a crash must still wedge).
BLOCK_PATTERNS='usage limit|session limit|weekly limit|daily limit|rate limit|rate_limit|quota|out of credits|credit balance|insufficient_quota|billing|overloaded|Too Many Requests|(http|status|error|code)[^a-z0-9]{0,3}429\b|authentication|unauthorized|invalid api key'
if [ ! -e "${RECEIPT}" ]; then
  sig="$(grep -m1 -i -E -o "${BLOCK_PATTERNS}" -- "${log}" 2>/dev/null || true)"
  if [ "${status}" -eq 0 ] || [ -n "${sig}" ]; then
    blocked_track "${status}" "${sig}"
    finish 69 blocked
  fi
  record_failure "the session exited ${status} and never reported for duty (no receipt)" "session_exit=${status}"
  echo "${ME}: run ${ts} exited ${status} and never reported for duty. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log}; check that ${CLAUDE} runs by hand ('${CLAUDE} --version'). If the log shows a provider limit, add its wording to BLOCK_PATTERNS in $0." >&2
  finish "${status}" failed
fi
# The session reached the model: any blocked streak and its episode end here.
rm -f "${BLOCK_COUNT}" "${BLOCK_STATE}"
if [ "${status}" -ne 0 ]; then
  record_failure "the session exited ${status}" "session_exit=${status}"
  echo "${ME}: run ${ts} exited ${status}. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log} for why the pass failed (124 is the ${TIMEOUT} timeout). ${FAIL_ESCALATE} in a row wedge the lane." >&2
  finish "${status}" failed
fi
if [ ! -s "${SUMMARY}" ]; then
  record_failure "the session exited 0 but wrote no summary, so the pass cannot be shown to have run" "session_exit=0" "summary=${SUMMARY} (absent or empty)"
  echo "${ME}: run ${ts} exited 0 with no summary; counted as unsuccessful. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log}; the architect should finish with one line that the session writes to \$CLUSTERING_SUMMARY." >&2
  finish 70 failed
fi

reset_fail
if [ "${DIGEST}" -eq 1 ]; then
  printf '%s\n' "${owner_day}" >"${DIGEST_DAY}"
fi
echo "${ME}: run ${ts} ok: $(head -n1 "${SUMMARY}")" >&2
finish 0 ok
