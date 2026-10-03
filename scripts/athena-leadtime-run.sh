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
# deleted, and the tick counts as unsuccessful. So is one whose branch ref git
# cannot read (COULD NOT TELL), which is never read as "no branch". A landed
# lane whose `git branch -D` is refused keeps its branch too, named with the
# delete to run, but that is never an outcome (DND-1715). After the session the main
# checkout is fast-forwarded only to the run's OWN newest commit, once it is on
# origin/main (DND-1008), never forced. The run's own commits are the ones its
# lane's HEAD reflog records it making, never every commit its lane holds: a
# sync down moves the lane onto other fleets' commits too (DND-1507).
#
# Product repos (DND-1540). An improve repo other than custom on this machine's
# list is a product repo R. For each, the runner reaps a dead run's lanes in
# <R common dir>/leadtime-lanes by their lock, reserves this run's lane there
# (<run-id>, its lock held for the whole session, like the custom lane's) and
# writes the manifest runs/<ts>.product.json (exported as
# LEADTIME_PRODUCT_MANIFEST). The session cuts the lane on demand and opens a PR
# as Athena (ai/bin/leadtime-product cut / pr); it never merges one. Before the
# session, ONE sweep reads every open improver PR as it is now and lands at most
# one green PR through R's bar (integration-gate --with-critic, locked-merge,
# confirm-merged); nothing waits on CI or a deploy, so a PR or a deploy still
# running is left for the next tick. After the session the product lanes are
# retired: a tip pushed on a recorded improver PR is "awaiting landing", never
# STRANDED; an unpushed commit is STRANDED (exit 72, branch kept). With no
# product repo and no product-PR store, none of this runs and the brief is
# unchanged.
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
# The observe check (DND-1820). The unmeasurable-phase escalation (DND-1806)
# fires only when the session runs `unmeasurable observe` per improve repo. So
# after a session that reached the model, the runner runs the main checkout's
# `unmeasurable check --repo R --run <run id>` for every improve repo the tick
# covered, lists each result in the .run, and fails the tick on a repo with no
# record (76), a record it cannot read (77), an observe that failed (74), or a
# repo whose ingest failed so it had no summary to observe (79). Each counts
# toward the wedge, so the existing leadtime-wedged alert reaches the owner
# once per episode. It proves observe ran; an observe that ran but could not
# read or promote the hand-off ticket (its exit 3) passes, and its exit=3 is
# on the observe: line.
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
#   scripts/athena-leadtime-run.sh --dry-run   # check the tick's preconditions, then print its brief; touch nothing
#   scripts/athena-leadtime-run.sh --help      # this text
#   (DRY_RUN=1 is the same as --dry-run.)
#
# State (machine-local; ai-artifacts/ is gitignored): <main checkout>/ai-artifacts/lead-time/
#   runs/<ts>.log       the session's output          runs/<ts>.summary  the skill's summary lines
#   runs/<ts>.receipt   the session reached the model runs/<ts>.failed   an unsuccessful outcome
#   runs/<ts>.blocked   the session never started     runs/<ts>.wedged   a wedged tick
#   runs/<ts>.locked    skipped: a run was in flight  runs/<ts>.git.log  the runner's own git output
#   runs/<ts>.run       every tick that spawned a session: outcome, exit,
#                       config=<default|override> repos=<names>
#                       skipped=<name(reason),...|none> and config_file= (the
#                       list ai/bin/lead-time-repos resolved), lane,
#                       main_moved= (origin/main's motion during the run, any
#                       author), own_landed= (the run's own commits on
#                       origin/main: <n> <sha>..., or UNKNOWN), ff= (the
#                       main-checkout fast-forward), product_prs=<open n>
#                       landed=<R#n,...|none> (DND-1540; 0 and none with no
#                       product repo; " unreadable_branches=<n>" when the
#                       sweep kept a landing branch git could not read,
#                       DND-1677) and its product_*: lines, the prune
#                       result, branch_delete=ok or one branch_delete: line
#                       per kept branch (below), the summary, and one
#                       observe: line per improve repo (DND-1820: what
#                       `unmeasurable check` read for this run id: result=
#                       observed, ingest-failed, observe-failed, not-recorded
#                       or could-not-look), or observe=none with no improve
#                       repo, or observe=not checked when the session never
#                       reported for duty
#   runs/<run id>.observe.<repo>.json  the session's observe record (the run
#                       id is run-<ts>), written by
#                       the unmeasurable tool (DND-1820)
#   runs/<ts>.branch-kept  one line per landed lane branch whose `git branch -D`
#                       was refused this tick (a held ref lock, or any other refusal),
#                       with git's exit and the Fix: delete to run. Written at
#                       the refusal, on any exit path. Never counted, never
#                       changes the exit (DND-1715)
#   runs/<ts>.product.json  the product manifest (only with a product repo or store)
#   consecutive-failures  the wedge counter; `rm` it to re-arm a wedged lane
#   consecutive-blocked   the blocked streak; clears when a session reaches the model
#   ledger.jsonl, experiments.jsonl, journal.md, cursor.<repo>.txt  the skill's own
#   product-prs.jsonl, product-line-stopped.<R>  ai/bin/leadtime-product's (DND-1540)
#   product-line-stopped-alerted.<R>  the stopped-line episode already alerted
#                       (slug leadtime-product-line-stopped; removed with the marker)
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
#   LEADTIME_PRODUCT_SWEEP_TIMEOUT  cap on the product-PR sweep, seconds (default 3600)
#   ATHENA_LEADTIME_CONFIG, XDG_CONFIG_HOME  read by ai/bin/lead-time-repos, which
#                             resolves this machine's repo list (see its --help)
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
#   72  STRANDED: the lane holds commits that are not on origin/main, or a
#       product lane holds a commit never pushed to an improver PR, or git
#       cannot read a lane branch's ref (COULD NOT TELL, DND-1662), whatever
#       the session's exit. The branch is kept: counted
#   73  the state directory, lock, lane, product lane or manifest, or MCP
#       config could not be created, or ai/bin/leadtime-product is missing
#       while a product repo is listed or a product-PR store exists (a lane
#       or config failure is counted)
#   74  observe-failed (DND-1820): the session ran `unmeasurable observe` for
#       an improve repo and it failed before counting (a refused summary, or
#       a state file it could not read or write); its record says so, with
#       observe's exit and error: counted
#   75  WEDGED: LEADTIME_FAIL_ESCALATE unsuccessful outcomes in a row. No
#       session runs. The tick writes runs/<ts>.wedged, and the first wedged
#       tick of an episode sends ONE harness-alert (leadtime-wedged)
#   76  observe-missing (DND-1820): the session exited 0 with a summary, but
#       an improve repo the tick covered has no observe record for this run
#       id: the session recorded neither `unmeasurable observe` nor
#       `unmeasurable ingest-failed` (it skipped them, or the tool could not
#       write even a failure record), so the unmeasurable-phase escalation
#       (DND-1806) did not run on it. The .failed record names the repos:
#       counted
#   77  observe-could-not-look (DND-1820): an improve repo's observe record
#       could not be read (not JSON, unreadable, for another run or repo), or
#       the main checkout's `unmeasurable check` is missing, failed, or
#       printed a line that disagrees with its exit. Never read as not
#       recorded, never ok: counted
#   78  the athena:lead-time-improve skill is not in the main checkout, the
#       repo list does not resolve (ai/bin/lead-time-repos is missing or exits
#       non-zero, zero repos included; its line and Fix: go in the .failed
#       record), or notion-personal is not registered or cannot be looked
#       up (scripts/lib/mcp-preflight.sh, the check setup-leadtime-cron
#       shares): counted. --dry-run runs the same checks in the same order
#       and exits 78 on the first that fails, touching nothing (DND-1571).
#       A scripts/lib file the tick needs (mcp-preflight.sh, dbus-env.sh,
#       lead-time-repos.sh) missing, unreadable, unloadable, or lacking a
#       function the tick calls is 78 too, with a .failed record, counted
#       like the rest (DND-1603, DND-1604). --dry-run runs the tick's own lib check, so it refuses
#       on the same faults (DND-1728)
#   79  ingest-failed (DND-1820): every improve repo has a record, and one
#       or more say ingest-failed: the repo had no summary to observe
#       (lead-time-phases --ingest or --summary failed), so the run could not
#       measure it. Neither a pass nor observe-missing; the .run's observe:
#       line names the step, its exit and its error: counted. When several
#       of 74, 76, 77 and 79 apply, the order is 76, 77, 74, 79
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
# The one MCP preflight (DND-1571), shared with --dry-run and the installer. It
# also holds the servers this loop needs (LEADTIME_MCP_REQUIRED), so the list
# checked and the list copied into the session's --mcp-config are one variable.
# It is loaded where it is first used (run_mcp_preflight below), never here: a
# missing library must reach the tick's precondition path, which writes the
# .failed record, counts it toward the wedge and alerts once per episode
# (DND-1603). Exiting here left no trace at all.

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

# The main checkout, through scripts/lib/main-checkout.sh (DND-1722), so state
# is one place whichever tree the script runs from. A non-git directory and a
# --separate-git-dir repo are refused there, naming the cause, never answered
# with a directory that is not the main checkout. The lib loads before
# --dry-run, so a green dry run means it loads. A missing lib cannot reach the
# precondition path: with no main checkout there is nowhere to write a record.
MAIN_CHECKOUT_LIB="${SCRIPT_DIR}/lib/main-checkout.sh"
# shellcheck source=scripts/lib/main-checkout.sh
if ! { [ -r "${MAIN_CHECKOUT_LIB}" ] && . "${MAIN_CHECKOUT_LIB}" && declare -F main_checkout >/dev/null; }; then
  echo "${ME}: ${MAIN_CHECKOUT_LIB} is missing, unreadable, or does not define main_checkout, so the main checkout cannot be resolved." >&2
  echo "  Fix: restore scripts/lib/main-checkout.sh in this checkout (git checkout -- scripts/lib), or fast-forward it to main." >&2
  exit 2
fi
if ! main_checkout "${REPO}" "${ME}"; then
  echo "  Fix: or point LEADTIME_REPO at a checkout of ~/dev/custom whose git dir is its own .git." >&2
  exit 2
fi
GIT_COMMON="${MAIN_CHECKOUT}/.git"

STATE_DIR="${MAIN_CHECKOUT}/ai-artifacts/lead-time"
LOG_DIR="${STATE_DIR}/runs"
LOCK="${STATE_DIR}/run.lock"
FAIL_COUNT="${STATE_DIR}/consecutive-failures"
WEDGE_STATE="${STATE_DIR}/wedged"
BLOCK_COUNT="${STATE_DIR}/consecutive-blocked"
BLOCK_STATE="${STATE_DIR}/blocked"
SKILL_FILE="${MAIN_CHECKOUT}/ai/skills/athena:lead-time-improve/SKILL.md"
RESOLVER="${MAIN_CHECKOUT}/ai/bin/lead-time-repos"
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

# --- the repo list ------------------------------------------------------------
# This machine's repos come from ai/bin/lead-time-repos (DND-1526), the one
# resolver: the tracked ai/config/lead-time-repos.json, or this machine's
# override, which the session's lane copy of the tracked file cannot see. It is
# read-only, so it runs here, before the brief that names its result; a list
# that does not resolve is acted on at the preconditions (6), or by --dry-run.
# Any non-zero exit (2 refused, 3 could not look, 4 no repo checked out here,
# 1 internal) and a missing resolver are all faults: never an empty run.
# Its --json is read by scripts/lib/lead-time-repos.sh, the one reader this
# runner and setup-leadtime-cron share (DND-1604); this runner keeps only its
# own wording. RES_RAN is "exit <n>" once the resolver ran, else "not run";
# RES_FIX is the runner's own Fix: for a fault of its own (the reader lib, the
# resolver or jq missing), preferred over the resolver's.

# check_lib <lib> <fn>... — the ONE check of a scripts/lib file the tick needs,
# shared by the tick and --dry-run (DND-1603, DND-1728). Sets LIB_REASON to the
# fault ("is missing", "is unreadable", "could not be loaded", "loaded but does
# not define <fn>"), or to "" when the lib is usable. Loading only defines
# functions while the lib stays definition-only at top level, so --dry-run
# stays read-only. The caller decides what a fault means.
LIB_REASON=""
check_lib() {
  local lib="$1" fn absent=""; shift
  LIB_REASON=""
  if [ ! -e "${lib}" ]; then
    LIB_REASON="is missing"
  elif [ ! -r "${lib}" ]; then
    LIB_REASON="is unreadable"
  # shellcheck disable=SC1090 # the lib named by the caller
  elif ! . "${lib}"; then
    LIB_REASON="could not be loaded"
  else
    for fn in "$@"; do
      declare -F "${fn}" >/dev/null || absent="${absent:+${absent} }${fn}"
    done
    [ -z "${absent}" ] || LIB_REASON="loaded but does not define ${absent}"
  fi
}
# lib_fix <lib> — the Fix: for a faulty scripts/lib file.
lib_fix() {
  printf '%s' "see what changed first (git -C ${SCRIPT_DIR%/scripts} status -- scripts/lib), then restore it (git checkout -- scripts/lib discards uncommitted edits there), restore read permission on an unreadable one (chmod u+r $1), or fast-forward this checkout to main when the runner is newer than its libs."
}

REPOS_LIB="${SCRIPT_DIR}/lib/lead-time-repos.sh"
RES_RC=0; RES_RAN="not run"; RES_FIX=""; RES_ERR=""; RES_SOURCE=""; RES_PATH=""
RES_NAMES=""; RES_DESC=""; RES_SKIPPED=""; RES_SKIPPED_RUN=""; RES_REPOS=""
resolve_repos() {
  check_lib "${REPOS_LIB}" lt_repos_resolve
  if [ -n "${LIB_REASON}" ]; then
    RES_RC=127; RES_ERR="${REPOS_LIB} ${LIB_REASON}, so the resolver's --json cannot be read"
    RES_FIX="$(lib_fix "${REPOS_LIB}")"
    return 0
  fi
  lt_repos_resolve "${RESOLVER}"
  RES_RC="${LT_RES_RC}"; RES_RAN="${LT_RES_RAN}"; RES_ERR="${LT_RES_ERR}"
  case "${LT_RES_FAULT}" in
    resolver-missing)
      RES_ERR="${RESOLVER} is absent or not executable in the main checkout"
      RES_FIX="land ai/bin/lead-time-repos (DND-1526) on main and fast-forward ${MAIN_CHECKOUT}; the next tick runs." ;;
    jq-missing)
      RES_ERR="jq is not on PATH, so the resolver's --json cannot be read"
      RES_FIX="install jq." ;;
    mktemp)
      RES_ERR="mktemp failed, so the resolver could not be run"
      RES_FIX="check that \${TMPDIR:-/tmp} is writable and the disk is not full." ;;
    unreadable)
      RES_ERR="the resolver exited 0 but its --json is unreadable or lists no repo (${LT_RES_DETAIL})"
      RES_FIX="run ${RESOLVER} --json by hand and compare it with its --help; this is a resolver or runner bug." ;;
  esac
  [ "${RES_RC}" -eq 0 ] || return 0
  RES_SOURCE="${LT_RES_SOURCE}"; RES_PATH="${LT_RES_PATH}"; RES_NAMES="${LT_RES_NAMES}"
  RES_DESC="${LT_RES_DESC}"; RES_SKIPPED="${LT_RES_SKIPPED}"; RES_SKIPPED_RUN="${LT_RES_SKIPPED_RUN}"
  RES_REPOS="${LT_RES_REPOS}"
}
resolve_repos

# --- product repos (DND-1540) ---------------------------------------------------
# An improve repo other than custom (the harness, by its name in the list) is a
# PRODUCT repo: the run may change it through a per-run lane in its own git
# common dir, a PR opened as Athena, and a landing by a LATER run
# (ai/bin/leadtime-product). With none, nothing below runs and the brief, the
# lane and the exits are what they were before DND-1540. The lane is also off
# unless the skill names "leadtime-product pr" (DND-1542; see below).
PRODUCT_NAMES=(); PRODUCT_PATHS=(); PRODUCT_IDLE=()
if [ "${RES_RC}" -eq 0 ]; then
  while IFS=$'\x1f' read -r pn pm pp pw; do
    [ -n "${pn}" ] && [ "${pm}" = improve ] && [ "${pn}" != custom ] || continue
    PRODUCT_NAMES+=("${pn}"); PRODUCT_PATHS+=("${pp}"); PRODUCT_IDLE+=("${pw}")
  done <<<"${RES_REPOS}"
fi
SWEEP_TIMEOUT="${LEADTIME_PRODUCT_SWEEP_TIMEOUT:-3600}"
case "${SWEEP_TIMEOUT}" in
  ''|*[!0-9]*) SWEEP_TIMEOUT=bad ;;
esac
if [ "${SWEEP_TIMEOUT}" = bad ] || [ "${SWEEP_TIMEOUT}" -le 300 ]; then
  echo "${ME}: LEADTIME_PRODUCT_SWEEP_TIMEOUT='${LEADTIME_PRODUCT_SWEEP_TIMEOUT:-}' is not whole seconds above 300; using 3600." >&2
  echo "  Fix: set it to the product sweep's budget in seconds (above 300), or unset it." >&2
  SWEEP_TIMEOUT=3600
fi
export LEADTIME_PRODUCT_SWEEP_TIMEOUT="${SWEEP_TIMEOUT}"
PRODUCT_TOOL="${MAIN_CHECKOUT}/ai/bin/leadtime-product"
PRODUCT_LINE="product_prs=0 landed=none"
PRODUCT_DETAIL=""
# The product lane is OFF unless the skill the session runs carries its
# procedure (athena:lead-time-improve -> The product lane, DND-1542). A skill
# without it says a product repo is never the session's to commit, and a
# brief saying the opposite would give the session two contradictory orders.
# The skill opts in by naming the command
# "leadtime-product pr" in the main checkout's SKILL.md. While OFF, a listed
# repo gets no lane and no product text in the brief, and .run says so.
if [ "${#PRODUCT_NAMES[@]}" -gt 0 ] && ! grep -qF 'leadtime-product pr' -- "${SKILL_FILE}" 2>/dev/null; then
  PRODUCT_DETAIL="product_lane=OFF repos=${PRODUCT_NAMES[*]}: ${SKILL_FILE} has no product-lane procedure (DND-1542), so these improve repos get no lane, no PR and no product text in the brief"
  PRODUCT_NAMES=(); PRODUCT_PATHS=(); PRODUCT_IDLE=()
fi
PRODUCT_SWEEP_TEXT="not run (dry run)"
SKIP_BRIEF=""
if [ -n "${RES_SKIPPED}" ]; then
  SKIP_BRIEF="Skipped on this machine, so not run: ${RES_SKIPPED}. Write one summary line \
repo=<R> skipped=\"<reason>\" for each. "
fi

# --- the brief ----------------------------------------------------------------
# The outer session only delegates. The shipwright writes the summary file
# itself (the skill's *Reporting*); the outer session never writes it, so a
# shipwright that did not finish reads as exit 70, never as a green run.
# PRODUCT_BRIEF is empty unless this machine has a product repo (DND-1540), so
# with none the brief is byte-for-byte what it was before.
# product_brief — the product repos, the tool that works them, and this tick's
# sweep result. Single quotes are dropped: the shipwright brief is quoted.
product_brief() {
  PRODUCT_BRIEF=""
  [ "${#PRODUCT_NAMES[@]}" -gt 0 ] || return 0
  local i list="" sweep
  for i in "${!PRODUCT_NAMES[@]}"; do
    list="${list:+${list}; }${PRODUCT_NAMES[$i]} (${PRODUCT_PATHS[$i]})"
  done
  # Only the runner's own summary and the stopped lines reach the prompt; the
  # per-PR lines (which quote forge and tool output) stay in .run and the journal.
  sweep="${PRODUCT_LINE}${PRODUCT_SWEEP_TEXT:+ (${PRODUCT_SWEEP_TEXT})}"
  PRODUCT_BRIEF="Product repos (improve, other than custom) on this machine: ${list}. Unlike your \
custom lane, a change to a product repo goes in that repo's own product lane and a PR: run \
${PRODUCT_TOOL} cut --repo <name> --phase <phase> --metric <metric> (it prints the lane and the \
trailer line; work only there), commit there with that trailer line in the message, then ${PRODUCT_TOOL} pr --repo <name> --title <title> --body-file <your evidence file>, which \
pushes as Athena and opens the PR (LEADTIME_PRODUCT_MANIFEST is already exported). Never merge, land \
or wait on a product PR or its CI: a later run lands it through that repo's own bar. An unpushed \
commit left in a product lane is STRANDED. Product PRs this tick: ${sweep}. "
  PRODUCT_BRIEF="${PRODUCT_BRIEF//\'/}"
}
build_brief() {
product_brief
BRIEF="First, before anything else, run exactly this one Bash command: \
touch \"\$LEADTIME_RECEIPT\" — it is the runner's liveness receipt. Then you are \
coordinating; do the work by delegating. Spawn exactly one athena-shipwright \
agent (Agent tool, subagent_type: athena-shipwright) with this brief, and do \
nothing else yourself: 'MODE: lead-time. This is the scheduled lead-time \
improver run from the cron runner scripts/athena-leadtime-run.sh, with no human \
present. Run the athena:lead-time-improve skill and nothing else, for exactly \
these repos, which ai/bin/lead-time-repos resolved for this machine \
(config=${RES_SOURCE} ${RES_PATH}): ${RES_DESC}. ${SKIP_BRIEF}Never take the repo \
list from your lane copy of ai/config/lead-time-repos.json: it cannot see this \
machine's override. Your lane is the cron lane \
the runner made for you: the worktree ${LANE} on branch ${BRANCH}, cut from \
origin/main. Work only there, starting every Bash command with cd ${LANE}; never \
edit the main checkout ${MAIN_CHECKOUT}. You are on the cron path: land only \
as athena:lead-time-improve (Landing) directs, the full bar and the push it \
cites, with your lane HEAD pushed to main by refspec (athena:shipwright-lane, \
Sync up). Open no PR. If a gate or the critic \
refuses your change, do what athena:lead-time-improve (Landing) says for a \
refusal on the cron path: journal it and reset your lane, so it holds no \
unlanded commit. The runner fast-forwards \
the main checkout after you exit. ${PRODUCT_BRIEF}State dir: ${STATE_DIR} (LEAD_TIME_STATE_DIR \
is already exported with it). Your run id is ${RUN_ID} (unmeasurable observe --run). \
After you exit the runner checks that this run id has an observe record for every improve \
repo: unmeasurable observe, or unmeasurable ingest-failed for a repo with no summary; a repo \
with neither fails the tick (athena:lead-time-improve, Escalate what stays unmeasurable). \
The runner does the telemetry prune; do not prune. \
Write your summary lines to exactly this file: ${SUMMARY}. Your hard constraint \
is your block Speed a safety check up; never weaken it (ai/blocks/ops/safety-checks.md). \
End with your summary lines.' When it finishes, print the contents of ${SUMMARY} \
and stop. Never write to that file yourself."
}

# res_fix — the runner's own Fix: for its own fault, else the resolver's, else
# how to see why.
res_fix() {
  local f="${RES_FIX}"
  [ -n "${f}" ] || f="$(printf '%s\n' "${RES_ERR}" | sed -n 's/^Fix: //p' | head -n1)"
  printf '%s' "${f:-run ${RESOLVER} by hand to see why the repo list does not resolve.}"
}
res_why() {
  printf 'the repo list did not resolve (ai/bin/lead-time-repos %s): %s' "${RES_RAN}" \
    "$(printf '%s\n' "${RES_ERR}" | grep -v '^Fix: ' | grep -v '^[[:space:]]*$' | head -n1)"
}

# The skill's absence, said once for --dry-run and the preconditions (6).
SKILL_WHY="the athena:lead-time-improve skill is not in the main checkout (${SKILL_FILE}), so there is no run to do"
SKILL_FIX="land the skill (DND-1478) on main and fast-forward ${MAIN_CHECKOUT}; the next tick runs."
# run_mcp_preflight — this runner's call of the one MCP preflight
# (scripts/lib/mcp-preflight.sh, DND-1571); sets MCP_PF_*.
# A library that is not there is a failed preflight like any other: it sets
# MCP_PF_WHY and MCP_PF_FIX and returns 1, so --dry-run and the tick's
# precondition path (which records and counts) both handle it (DND-1603).
run_mcp_preflight() {
  local lib="${SCRIPT_DIR}/lib/mcp-preflight.sh"
  if ! declare -F leadtime_mcp_preflight >/dev/null 2>&1; then
    if [ ! -e "${lib}" ]; then
      MCP_PF_WHY="${lib} is missing, so the MCP servers cannot be checked; no session."
      MCP_PF_FIX="restore scripts/lib/mcp-preflight.sh in this checkout (git checkout -- scripts/lib), or fast-forward it to main."
      return 1
    fi
    if [ ! -r "${lib}" ]; then
      MCP_PF_WHY="${lib} is unreadable, so the MCP servers cannot be checked; no session."
      MCP_PF_FIX="restore read permission on it (chmod u+r ${lib})."
      return 1
    fi
    # shellcheck source=scripts/lib/mcp-preflight.sh
    . "${lib}" || {
      MCP_PF_WHY="${lib} could not be loaded, so the MCP servers cannot be checked; no session."
      MCP_PF_FIX="read the error above; restore scripts/lib/mcp-preflight.sh (git checkout -- scripts/lib), or fast-forward it to main."
      return 1
    }
    if ! declare -F leadtime_mcp_preflight >/dev/null 2>&1; then
      MCP_PF_WHY="${lib} loaded but does not define leadtime_mcp_preflight, so the MCP servers cannot be checked; no session."
      MCP_PF_FIX="restore scripts/lib/mcp-preflight.sh in this checkout (git checkout -- scripts/lib), or fast-forward it to main."
      return 1
    fi
  fi
  leadtime_mcp_preflight "${CLAUDE_JSON}" "${MAIN_CHECKOUT}"
}

# load_dbus_lib — the check of scripts/lib/dbus-env.sh, shared by the tick and
# --dry-run, so a green dry run means the tick can load it (DND-1603,
# DND-1728). It is check_lib (above, shared with the repo-list reader lib) over
# every function in DBUS_LIB_FNS (each one the tick calls). Sets DBUS_LIB_WHY
# to the fault, or to "" when the lib is usable. It never calls the lib. The
# caller decides what a fault means (the tick records and counts it; --dry-run
# refuses).
DBUS_LIB="${SCRIPT_DIR}/lib/dbus-env.sh"
DBUS_LIB_FNS="athena_dbus_env_setup"
DBUS_LIB_FIX="$(lib_fix "${DBUS_LIB}")"
DBUS_LIB_WHY=""
load_dbus_lib() {
  # shellcheck disable=SC2086 # one word per function name
  check_lib "${DBUS_LIB}" ${DBUS_LIB_FNS}
  DBUS_LIB_WHY=""
  [ -z "${LIB_REASON}" ] || DBUS_LIB_WHY="${DBUS_LIB} ${LIB_REASON}, so D-Bus autolaunch cannot be suppressed"
}

# load_own_lib — the check of scripts/lib/lane-own-commits.sh, the one own-commit
# test the shipwright runner shares (DND-1507, DND-1541). Same shape as
# load_dbus_lib: sets OWN_LIB_WHY to the fault, or "" when the lib is usable.
OWN_LIB="${SCRIPT_DIR}/lib/lane-own-commits.sh"
OWN_LIB_FNS="lane_own_commits"
OWN_LIB_FIX="$(lib_fix "${OWN_LIB}")"
OWN_LIB_WHY=""
load_own_lib() {
  # shellcheck disable=SC2086 # one word per function name
  check_lib "${OWN_LIB}" ${OWN_LIB_FNS}
  OWN_LIB_WHY=""
  [ -z "${LIB_REASON}" ] || OWN_LIB_WHY="${OWN_LIB} ${LIB_REASON}, so the run's own commits cannot be told from a sync"
}

# --dry-run checks what the tick's preconditions (6) check, in the same order,
# so a rendered brief means a tick can start (DND-1571).
if [ "${DRY}" -eq 1 ]; then
  dry_refuse() { # <why> <fix>
    echo "${ME}: $1; a tick would exit 78 and spawn no session." >&2
    echo "  Fix: $2" >&2
    exit 78
  }
  [ -r "${SKILL_FILE}" ] || dry_refuse "${SKILL_WHY}" "${SKILL_FIX}"
  [ "${RES_RC}" -eq 0 ] || dry_refuse "$(res_why)" "$(res_fix)"
  load_dbus_lib
  [ -z "${DBUS_LIB_WHY}" ] || dry_refuse "${DBUS_LIB_WHY}" "${DBUS_LIB_FIX}"
  load_own_lib
  [ -z "${OWN_LIB_WHY}" ] || dry_refuse "${OWN_LIB_WHY}" "${OWN_LIB_FIX}"
  run_mcp_preflight || dry_refuse "${MCP_PF_WHY%.}" "${MCP_PF_FIX}"
  build_brief
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
# A faulty library is not fatal here: the tick has no record machinery yet, so
# load_dbus_lib (the check --dry-run runs) notes it and precondition (6) records
# it, counts it and exits 78 (DND-1603).
load_dbus_lib
if [ -z "${DBUS_LIB_WHY}" ]; then
  athena_dbus_env_setup
else
  # Without the library, still suppress autolaunch for what runs before the
  # tick exits (an unconnectable address, as the library's own fallback does).
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/nonexistent/athena-dbus-suppressed}"
fi
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

# Prints the delivered name. Exit 0 with no delivered line is NOT sent (exit 5):
# the episode stays unalerted and the next tick retries (DND-1513,
# ai/lib/harness-alert-send.sh).
harness_alert_send() { # <record> <slug> <body-file>
  local record="$1" slug="$2" body="$3" repo
  repo="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
  # shellcheck source=ai/lib/harness-alert-send.sh
  . "${repo}/ai/lib/harness-alert-send.sh" || { echo "cannot load ${repo}/ai/lib/harness-alert-send.sh" >&2; return 4; }
  harness_alert_deliver "${LEADTIME_SEND_MAIL:-${repo}/ai/skills/athena:inbox/bin/send-mail}" "${repo}" 20 3 \
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

# delete_lane_branch <branch> <context> — `git branch -D` a lane branch whose
# work is on origin/main. A ref git cannot read never gets here (retire_lane's
# COULD NOT TELL comes first). A refused delete (a held ref lock, or any other
# refusal) used to be dropped (`|| true`), so the branch stayed with nothing past the git log
# and lane branches piled up unseen (DND-1715). Now the branch is KEPT and named,
# with the delete to run, in stderr and in this tick's runs/<ts>.branch-kept,
# which finish copies into the .run. The record is written at once, so it
# survives a reap in a subshell and every early exit. A refused delete is
# hygiene, never an outcome: it returns 0, never changes the exit and never
# feeds the wedge (owner rule: never pause the lead-time cron).
# LAST_DELETE_REFUSED says whether the last retire_lane's delete was refused;
# retire_lane resets it first, so a branch it never tried to delete reads 0.
LAST_DELETE_REFUSED=0
delete_lane_branch() {
  local br="$1" ctx="$2" rc=0 fix reflock
  git -C "${MAIN_CHECKOUT}" branch -D "${br}" >>"${GIT_LOG}" 2>&1 || rc=$?
  [ "${rc}" -eq 0 ] && return 0
  LAST_DELETE_REFUSED=1
  fix="git -C ${MAIN_CHECKOUT} branch -D ${br}"
  reflock="$(git -C "${MAIN_CHECKOUT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "<git common dir>")/refs/heads/${br}.lock"
  if ! printf '%s: branch %s KEPT: git branch -D exit %s; the reason is in %s. Fix: %s\n' \
      "${ctx}" "${br}" "${rc}" "${GIT_LOG}" "${fix}" >>"${LOG_DIR}/${ts}.branch-kept" 2>/dev/null; then
    echo "${ME}: could not write ${LOG_DIR}/${ts}.branch-kept; this stderr is the only record of the kept branch." >&2
  fi
  echo "${ME}: could not delete branch ${br} (${ctx}): git branch -D exit ${rc}. Its commits are on origin/main, so nothing is lost; the branch is KEPT. Not counted as a failure. Record: ${LOG_DIR}/${ts}.branch-kept" >&2
  echo "  Fix: read the end of ${GIT_LOG} for the reason (for a held ref lock, confirm nothing is writing to ${MAIN_CHECKOUT} and remove the stale ${reflock}), then run '${fix}'." >&2
  return 0
}

# retire_lane <run-id> <context> — remove one lane's worktree, and delete its
# branch unless its commits are not on origin/main (then keep it, say how to
# recover, and return 1). The branch is never deleted while it holds work. A
# branch ref git cannot read is COULD NOT TELL: kept as found, named, return 2.
retire_lane() {
  local rid="$1" ctx="$2" wt="${LANES_DIR}/$1" br="leadtime/$1"
  LAST_DELETE_REFUSED=0
  git -C "${MAIN_CHECKOUT}" worktree remove --force "${wt}" >>"${GIT_LOG}" 2>&1 || rm -rf -- "${wt}"
  git -C "${MAIN_CHECKOUT}" worktree prune >>"${GIT_LOG}" 2>&1 || true
  # `show-ref --exists` (git >= 2.43): 0 exists, 2 absent, anything else is a
  # ref git could not look up. `--verify` reads a corrupt ref as absent
  # (DND-1662), so a broken branch passed as "no branch" with nothing said.
  local exists=0
  git -C "${MAIN_CHECKOUT}" show-ref --exists "refs/heads/${br}" >>"${GIT_LOG}" 2>&1 || exists=$?
  [ "${exists}" = 2 ] && return 0
  if [ "${exists}" != 0 ]; then
    echo "${ME}: COULD NOT TELL whether branch ${br} exists (${ctx}): git show-ref --exists exit ${exists}; the branch is KEPT as found." >&2
    echo "  Fix: inspect the ref with 'git -C ${MAIN_CHECKOUT} show-ref --exists refs/heads/${br}' (git's reason is in ${GIT_LOG}; exit 129 means this git predates --exists: upgrade to git >= 2.43). The branch's last tip is in its reflog ('git -C ${MAIN_CHECKOUT} rev-parse --git-path logs/refs/heads/${br}'); recover it, then repair or delete the ref by hand. It is never auto-deleted." >&2
    return 2
  fi
  if commit_landed "${br}"; then
    delete_lane_branch "${br}" "${ctx}"
    return 0
  fi
  echo "${ME}: kept STRANDED branch ${br} (${ctx}); its commits are not on origin/main." >&2
  echo "  Fix: the work is NOT lost. Inspect it with 'git -C ${MAIN_CHECKOUT} log origin/main..${br}', then land it through the custom landing (athena:merge-boarding -> The merge bar) or drop it, and delete it with 'git -C ${MAIN_CHECKOUT} branch -D ${br}'. It is never auto-deleted." >&2
  return 1
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
# precondition_fail <why> <fix> [<detail-line>...] — the run cannot happen
# without these.
precondition_fail() {
  local why="$1" fix="$2"; shift 2
  record_failure "${why}" "fix=${fix}" "$@"
  echo "${ME}: ${why}" >&2
  echo "  Fix: ${fix}" >&2
  exit 78
}
# Without the skill or a resolved repo list the shipwright can only report that
# it did nothing, and that summary would read as a green run.
if [ ! -r "${SKILL_FILE}" ]; then
  precondition_fail "${SKILL_WHY}; counted as an unsuccessful outcome." "${SKILL_FIX}"
fi
if [ "${RES_RC}" -ne 0 ]; then
  # The resolver's own lines go into the .failed record, its Fix: included.
  mapfile -t res_lines < <(printf '%s\n' "${RES_ERR}" | grep -v '^[[:space:]]*$' | sed 's/^/resolver: /' || true)
  precondition_fail "$(res_why); no repo has a mode, so no session; counted as an unsuccessful outcome." \
    "$(res_fix)" "${res_lines[@]}"
fi
# The cron-environment library, its fault noted at the lock by load_dbus_lib (DND-1603, DND-1728).
if [ -n "${DBUS_LIB_WHY}" ]; then
  precondition_fail "${DBUS_LIB_WHY}; no session." "${DBUS_LIB_FIX}"
fi
# The own-commit library, loaded here so the teardown can call it (DND-1541).
load_own_lib
if [ -n "${OWN_LIB_WHY}" ]; then
  precondition_fail "${OWN_LIB_WHY}; no session." "${OWN_LIB_FIX}"
fi
# The MCP servers, through the one preflight --dry-run and the installer share
# (scripts/lib/mcp-preflight.sh, DND-1571).
if ! run_mcp_preflight; then
  precondition_fail "${MCP_PF_WHY}" "${MCP_PF_FIX}"
fi
servers="${MCP_PF_SERVERS}"
# Only the servers the run needs; --strict-mcp-config below keeps every other
# configured server and connector out of the session.
mcp_config="$(jq -c --arg names "${LEADTIME_MCP_REQUIRED}" \
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

# --- 7b. product lanes (DND-1540) ----------------------------------------------------
# Only with a product repo, or a product-PR store from an earlier run (its PRs
# are still swept, or reported as not swept, never forgotten). For each product
# repo R: reap a dead run's lanes in R by their lock, then RESERVE this run's
# lane, <R common dir>/leadtime-lanes/<run-id>: its lock is taken here and held
# on its own descriptor for the whole session, as fd 8 is for the custom lane;
# the session cuts the worktree on demand (leadtime-product cut). Then one
# sweep of every open improver PR, read ONCE as it is now: nothing here waits
# on CI or a deploy, so a PR whose CI is still running is left for the next tick.
PRODUCT_MANIFEST="${LOG_DIR}/${ts}.product.json"
PRODUCT_FDS=(); PRODUCT_LOCKS=(); PRODUCT_STRANDED=0
product_release() { # close every reserved lane lock and remove the lock files
  local f
  for f in "${PRODUCT_FDS[@]}"; do { exec {f}>&-; } 2>/dev/null || true; done
  PRODUCT_FDS=()
  [ "${#PRODUCT_LOCKS[@]}" -eq 0 ] || rm -f -- "${PRODUCT_LOCKS[@]}"
  PRODUCT_LOCKS=()
}
product_abort() { # <why> <fix> — before the session: undo the lanes, count it, exit 73
  product_release
  retire_lane "${RUN_ID}" "product lane setup failed" >/dev/null || true
  { exec 8>&-; } 2>/dev/null || true
  rm -f -- "${LANE_LOCK}" "${LANE_META}" "${MCP_FILE}"
  record_failure "$1" "lane=${LANE}" "fix=$2"
  echo "${ME}: $1; no session spawned. Counted as an unsuccessful outcome." >&2
  echo "  Fix: $2" >&2
  exit 73
}
product_note() { PRODUCT_DETAIL="${PRODUCT_DETAIL:+${PRODUCT_DETAIL}$'\n'}$1"; }
# product_run <argv> — run a product-lane command with none of the runner's
# lock descriptors: not the run lock (9), not the custom lane's (8), not a
# product lane's. A child it starts that outlives the tick (a gate, a
# bootstrap) must never pin a lock, or every later tick skips or never reaps.
product_run() {
  (
    for f in "${PRODUCT_FDS[@]}"; do { exec {f}>&-; } 2>/dev/null || true; done
    { exec 8>&- 9>&-; } 2>/dev/null || true
    exec "$@"
  )
}
# product_alert_stopped — ONE harness-alert per stopped-line episode of a
# product repo (the marker's content names the episode; rm of the marker is
# the owner's re-arm). A failed send is not recorded, so the next tick retries.
product_alert_stopped() {
  local f repo sent cur seen body name
  for f in "${STATE_DIR}"/product-line-stopped-alerted.*; do
    [ -e "${f}" ] || continue
    [ -e "${STATE_DIR}/product-line-stopped.${f##*/product-line-stopped-alerted.}" ] || rm -f -- "${f}"
  done
  for f in "${STATE_DIR}"/product-line-stopped.*; do
    [ -e "${f}" ] || continue
    repo="${f##*/product-line-stopped.}"
    sent="${STATE_DIR}/product-line-stopped-alerted.${repo}"
    cur="$(cat -- "${f}" 2>/dev/null || true)"
    seen="$(cat -- "${sent}" 2>/dev/null || true)"
    [ "${cur}" != "${seen}" ] || continue
    body="$(new_body)" || continue
    {
      printf 'The lead-time improver STOPPED THE LINE in the product repo %s: nothing more lands there until the owner re-arms it (DND-1540).\n' "${repo}"
      printf 'This is a report. The marker named in re: is the authority.\n\nwhy: %s\n' "${cur}"
      printf '\nFix: land the fix or the revert it names (a revert is owed when a deploy failed), then re-arm with: rm %s\n' "${f}"
    } >"${body}"
    if name="$(harness_alert_send "${f}" leadtime-product-line-stopped "${body}" 2>/dev/null)"; then
      printf '%s\n' "${cur}" >"${sent}" 2>/dev/null || true
      product_note "product_line_alert=${repo} sent ${name}"
    else
      product_note "product_line_alert=${repo} FAILED to send (the next tick retries)"
      echo "${ME}: the stopped-line alert for ${repo} could NOT be sent; the next tick retries." >&2
      echo "  Fix: run inbox-doctor from ${MAIN_CHECKOUT} (is the custom registry entry installed with its harness-alerts channels? scripts/setup-inbox-registry --install)." >&2
    fi
    rm -f -- "${body}"
  done
}
if [ "${#PRODUCT_NAMES[@]}" -gt 0 ] || [ -e "${STATE_DIR}/product-prs.jsonl" ]; then
  if [ ! -x "${PRODUCT_TOOL}" ]; then
    product_abort "the product-lane tool ${PRODUCT_TOOL} is absent or not executable in the main checkout (a product repo is listed, or a product-PR store exists)" \
      "land ai/bin/leadtime-product (DND-1540) on main and fast-forward ${MAIN_CHECKOUT}; the next tick runs."
  fi
  pm_entries="[]"
  for i in "${!PRODUCT_NAMES[@]}"; do
    pn="${PRODUCT_NAMES[$i]}"; pp="${PRODUCT_PATHS[$i]}"; pw="${PRODUCT_IDLE[$i]}"
    pc="$(git -C "${pp}" rev-parse --git-common-dir 2>/dev/null || true)"
    case "${pc}" in ''|/*) ;; *) pc="${pp}/${pc}" ;; esac
    [ -n "${pc}" ] && pc="$(cd -- "${pc}" 2>/dev/null && pwd -P || true)"
    [ -n "${pc}" ] || product_abort "cannot resolve the git common dir of the product repo ${pn} (${pp})" \
      "check that ${pp} is a git checkout ('git -C ${pp} rev-parse --git-common-dir')."
    pm_entries="$(jq -c --arg n "${pn}" --arg p "${pp}" --arg c "${pc}" --arg id "${RUN_ID}" --arg w "${pw}" \
      '. + [{name: $n, path: $p, common: $c, lanes_dir: ($c + "/leadtime-lanes"),
             lane: ($c + "/leadtime-lanes/" + $id), lock: ($c + "/leadtime-lanes/" + $id + ".lock")}
            + (if $w == "" then {} else {idle_workflow: $w} end)]' <<<"${pm_entries}")" \
      || product_abort "could not build the product manifest entry for ${pn}" "run jq by hand; this is a runner bug."
  done
  if ! ( umask 077; jq -n --arg id "${RUN_ID}" --arg s "${STATE_DIR}" --argjson r "${pm_entries}" \
           '{run_id: $id, state_dir: $s, repos: $r}' >"${PRODUCT_MANIFEST}" ) 2>/dev/null; then
    product_abort "could not write the product manifest ${PRODUCT_MANIFEST}" "check that ${LOG_DIR} is writable and the disk is not full."
  fi
  export LEADTIME_PRODUCT_MANIFEST="${PRODUCT_MANIFEST}"
  if [ "${#PRODUCT_NAMES[@]}" -gt 0 ]; then
    reap_rc=0
    reap_out="$(product_run "${PRODUCT_TOOL}" reap 2>&1 </dev/null)" || reap_rc=$?
    [ -z "${reap_out}" ] || product_note "${reap_out}"
    [ "${reap_rc}" -eq 0 ] || product_note "product_reap=FAILED exit=${reap_rc}"
  fi
  while IFS= read -r plock; do
    [ -n "${plock}" ] || continue
    pdir="$(dirname -- "${plock}")"
    { mkdir -p "${pdir}" && chmod 700 "${pdir}"; } 2>/dev/null \
      || product_abort "could not create the product lanes dir ${pdir}" "check that ${pdir} can be created."
    { printf 'origin=cron\npid=%s\nrun_id=%s\n' "$$" "${RUN_ID}" >"${plock%.lock}.meta"; } 2>/dev/null \
      || product_abort "could not write ${plock%.lock}.meta" "check that ${pdir} is writable and the disk is not full."
    if ! { exec {pfd}>>"${plock}"; } 2>/dev/null; then
      product_abort "could not open the product lane lock ${plock}" "check that ${pdir} is writable and the disk is not full."
    fi
    PRODUCT_FDS+=("${pfd}"); PRODUCT_LOCKS+=("${plock}")
    flock -n "${pfd}" || product_abort "the fresh product lane lock ${plock} was already held" \
      "this should be impossible for a unique run id. Check for a process holding it ('fuser -v ${plock}')."
  done < <(jq -r '.repos[].lock' "${PRODUCT_MANIFEST}")
  # The tool keeps its own budget 120s under SWEEP_TIMEOUT and never starts a
  # step it has no time for; this outer cap is only the backstop.
  sweep_rc=0; sweep_err="$(mktemp)" || sweep_err=/dev/null
  sweep_out="$(product_run timeout -k 60 "$(( SWEEP_TIMEOUT + 300 ))" "${PRODUCT_TOOL}" sweep 2>"${sweep_err}" </dev/null)" || sweep_rc=$?
  if [ "${sweep_rc}" -eq 0 ] && [ -n "${sweep_out}" ]; then
    PRODUCT_LINE="$(head -n1 <<<"${sweep_out}")"
    PRODUCT_SWEEP_TEXT="$(grep '^product_line=STOPPED ' <<<"${sweep_out}" | paste -sd ';' - | sed 's/;/; /g' || true)"
    [ "$(wc -l <<<"${sweep_out}")" -le 1 ] || product_note "$(tail -n +2 <<<"${sweep_out}")"
  else
    PRODUCT_LINE="product_prs=UNKNOWN landed=UNKNOWN (sweep exit ${sweep_rc})"
    PRODUCT_SWEEP_TEXT="the sweep failed (exit ${sweep_rc}); open product PRs were not checked this tick"
    product_note "product_sweep=FAILED exit=${sweep_rc}: $(tr '\n' ' ' <"${sweep_err}" 2>/dev/null || true)"
    echo "${ME}: leadtime-product sweep exited ${sweep_rc}; open product PRs were not checked this tick. The session still runs." >&2
    echo "  Fix: run '${PRODUCT_TOOL} sweep --manifest ${PRODUCT_MANIFEST}' by hand and follow its own Fix: line." >&2
  fi
  [ "${sweep_err}" = /dev/null ] || rm -f -- "${sweep_err}"
  product_alert_stopped
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
build_brief
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

# Fast-forward the main checkout only to the run's newest own commit that is on
# origin/main, so the live harness advances to landed
# work and never to unreviewed work, and the run never ff's to (or claims)
# another fleet's commit. Only when the main checkout is on main; never forced.
OWN_LANDED="0"
FF="none (the run made no commits of its own)"
own=""
own_rc=0
if [ -n "${tip}" ]; then own="$(lane_own_commits "${LANE}" "${BASE}" "${tip}")" || own_rc=$?; else own_rc=4; fi
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
LANE_UNREADABLE=0
LANE_RESULT="removed"
lane_rc=0
retire_lane "${RUN_ID}" "run ${ts}" || lane_rc=$?
case "${lane_rc}" in
  0) [ "${LAST_DELETE_REFUSED}" -eq 0 ] \
       || LANE_RESULT="branch ${BRANCH} KEPT (delete REFUSED: its commits are on origin/main; see branch_delete)" ;;
  2) STRANDED=1; LANE_UNREADABLE=1
     LANE_RESULT="branch ${BRANCH} KEPT (COULD NOT TELL: git cannot read its ref)" ;;
  *) STRANDED=1
     LANE_RESULT="branch ${BRANCH} KEPT (stranded: commits not on origin/main)" ;;
esac
{ exec 8>&-; } 2>/dev/null || true
rm -f -- "${LANE_LOCK}" "${LANE_META}" "${MCP_FILE}"

# The product lanes (DND-1540), with their locks still held: work on R's
# origin/main is removed; a tip pushed on a recorded improver PR is awaiting
# landing, never STRANDED; anything else is STRANDED and its branch kept. A
# teardown that cannot tell keeps the branch and counts as stranded too.
if [ "${#PRODUCT_LOCKS[@]}" -gt 0 ]; then
  td_rc=0
  td_out="$(product_run "${PRODUCT_TOOL}" teardown 2>&1 </dev/null)" || td_rc=$?
  [ -z "${td_out}" ] || product_note "${td_out}"
  if [ "${td_rc}" -ne 0 ]; then
    PRODUCT_STRANDED=1; STRANDED=1
    [ "${td_rc}" -eq 72 ] || product_note "product_teardown=FAILED exit=${td_rc}: the teardown could not finish, so every product branch is kept and counted STRANDED"
  fi
  while IFS= read -r plock; do rm -f -- "${plock%.lock}.meta"; done < <(printf '%s\n' "${PRODUCT_LOCKS[@]}")
  product_release
fi

# --- 9b. the observe check (DND-1820) ----------------------------------------------
# The unmeasurable-phase escalation (DND-1806) fires only on a run whose
# session calls `unmeasurable observe` per improve repo, so after the session
# the runner asks the main checkout's tool what this run recorded for each
# improve repo the tick covered (`unmeasurable check`, read-only). Its exit and
# its line must agree: 0 observed, 4 ingest-failed (the repo had no summary to
# observe), 6 observe-failed (the session called observe and it failed),
# 5 not-recorded, 3 could-not-look. Any other exit, a missing tool, or a line
# that disagrees with its exit is COULD NOT LOOK, never "not recorded" and
# never ok. Only a tick whose session reached the model is checked, and only
# with a resolved repo list (an unresolved one never reaches a session).
UNMEASURABLE_TOOL="${MAIN_CHECKOUT}/ai/skills/athena:lead-time-improve/scripts/unmeasurable"
OBSERVE_LINES="observe=not checked (the session never reported for duty)"
OBSERVE_MISSING=""; OBSERVE_UNREADABLE=""; OBSERVE_FAILED=""; OBSERVE_INGEST=""
observe_check() {
  local name mode rest out rc err want why head
  local -a names=()
  OBSERVE_LINES=""
  if [ "${RES_RC}" -ne 0 ]; then
    OBSERVE_LINES="observe=not checked (the repo list did not resolve)"
    return 0
  fi
  while IFS=$'\x1f' read -r name mode rest; do
    [ -n "${name}" ] && [ "${mode}" = improve ] || continue
    names+=("${name}")
  done <<<"${RES_REPOS}"
  if [ "${#names[@]}" -eq 0 ]; then
    OBSERVE_LINES="observe=none (no improve repo this tick)"
    return 0
  fi
  for name in "${names[@]}"; do
    rc=0; out=""; why=""
    if [ ! -x "${UNMEASURABLE_TOOL}" ]; then
      rc=127; why="${UNMEASURABLE_TOOL} is absent or not executable, so this run's observe record cannot be read"
    else
      err="$(mktemp 2>/dev/null)" || err=/dev/null
      out="$(timeout 120 "${UNMEASURABLE_TOOL}" check --repo "${name}" --run "${RUN_ID}" 2>"${err}" </dev/null 9>&-)" || rc=$?
      out="${out%%$'\n'*}"
      why="unmeasurable check exited ${rc}: $(grep -v '^Fix: ' "${err}" 2>/dev/null | head -n1 | tr -d '"' || true)"
      [ "${err}" = /dev/null ] || rm -f -- "${err}"
    fi
    head="observe: repo=${name} run=${RUN_ID} result="
    case "${rc}" in
      0) want=observed ;;
      4) want=ingest-failed ;;
      6) want=observe-failed ;;
      5) want=not-recorded ;;
      3) want=could-not-look ;;
      *) want="" ;;
    esac
    # The line must name this repo, this run and the result its exit means.
    if [ -n "${want}" ] && { [ "${out}" = "${head}${want}" ] || [ "${out#"${head}${want} "}" != "${out}" ]; }; then
      :
    elif [ -n "${want}" ]; then
      why="unmeasurable check exited ${rc} but printed '${out//\"/}', not ${head}${want}"
      want=""
    else
      want=""
    fi
    case "${want}" in
      observed) ;;
      ingest-failed) OBSERVE_INGEST="${OBSERVE_INGEST:+${OBSERVE_INGEST},}${name}" ;;
      observe-failed) OBSERVE_FAILED="${OBSERVE_FAILED:+${OBSERVE_FAILED},}${name}" ;;
      not-recorded) OBSERVE_MISSING="${OBSERVE_MISSING:+${OBSERVE_MISSING},}${name}" ;;
      could-not-look) OBSERVE_UNREADABLE="${OBSERVE_UNREADABLE:+${OBSERVE_UNREADABLE},}${name}" ;;
      *) OBSERVE_UNREADABLE="${OBSERVE_UNREADABLE:+${OBSERVE_UNREADABLE},}${name}"
         out="${head}could-not-look reason=\"${why}\"" ;;
    esac
    OBSERVE_LINES="${OBSERVE_LINES:+${OBSERVE_LINES}$'\n'}${out}"
  done
}

# --- 10. classify, then finish -----------------------------------------------------
# finish <exit> <outcome> — every tick that spawned a session ends here and
# writes runs/<ts>.run.
finish() {
  local rc="$1" outcome="$2" run="${LOG_DIR}/${ts}.run"
  if ! {
    printf '%s: run %s outcome=%s exit=%s\n' "${ME}" "${ts}" "${outcome}" "${rc}"
    printf 'lane=%s branch=%s (%s)\n' "${LANE}" "${BRANCH}" "${LANE_RESULT}"
    printf 'config=%s repos=%s skipped=%s\n' "${RES_SOURCE}" "${RES_NAMES}" "${RES_SKIPPED_RUN}"
    printf 'config_file=%s\n' "${RES_PATH}"
    printf 'base=%s (%s)\n' "${BASE}" "${FETCH_NOTE}"
    printf 'main_moved=%s\n' "${MAIN_MOVED}"
    printf 'own_landed=%s\n' "${OWN_LANDED}"
    printf 'ff=%s\n' "${FF}"
    printf '%s\n' "${PRODUCT_LINE}"
    [ -z "${PRODUCT_DETAIL}" ] || printf '%s\n' "${PRODUCT_DETAIL}"
    printf 'prune=%s\n' "${PRUNE_RESULT}"
    if [ -s "${LOG_DIR}/${ts}.branch-kept" ]; then
      sed 's/^/branch_delete: /' -- "${LOG_DIR}/${ts}.branch-kept"
    else
      printf 'branch_delete=ok\n'
    fi
    if [ -s "${SUMMARY}" ]; then
      sed 's/^/summary: /' -- "${SUMMARY}"
    else
      printf 'summary: (none: %s absent or empty)\n' "${SUMMARY}"
    fi
    printf '%s\n' "${OBSERVE_LINES}"
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
# What it recorded per improve repo (DND-1820), listed in the .run whatever
# the outcome; it decides the outcome only once nothing below fails first.
observe_check
mapfile -t observe_lines < <(printf '%s\n' "${OBSERVE_LINES}")
# Stranded first, whatever the session's exit: the kept branch is the thing
# the owner has to act on.
if [ "${STRANDED}" -eq 1 ] && [ "${PRODUCT_STRANDED}" -eq 1 ] && [ "${LANE_RESULT}" = removed ]; then
  # Only a product lane is stranded (DND-1540): a commit never pushed to an
  # improver PR. A pushed one is awaiting landing and never reaches here.
  mapfile -t pd_lines < <(printf '%s\n' "${PRODUCT_DETAIL}" | grep -E '^product_(lane|teardown)' || true)
  record_failure "a product lane holds a commit that was never pushed to an improver PR" "${pd_lines[@]}" "session_exit=${status}"
  echo "${ME}: run ${ts} is STRANDED in a product repo (session exit ${status}); its branch is kept. Counted as unsuccessful. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: the product_lane line in the record names the repo and branch. Push it and open its PR (leadtime-product pr), or drop it with 'git -C <repo> branch -D <branch>'. It is never auto-deleted." >&2
  finish 72 stranded
fi
if [ "${LANE_UNREADABLE}" -eq 1 ]; then
  record_failure "COULD NOT TELL: git cannot read the lane branch's ref, so whether it holds unlanded commits is unknown" "branch=${BRANCH} (kept as found)" "session_exit=${status}"
  echo "${ME}: run ${ts} COULD NOT TELL whether ${BRANCH} holds unlanded work: git cannot read its ref (session exit ${status}). The branch is kept as found. Counted as unsuccessful. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: inspect it with 'git -C ${MAIN_CHECKOUT} show-ref --exists refs/heads/${BRANCH}' (git's reason is in ${GIT_LOG}); its last tip is in its reflog ('git -C ${MAIN_CHECKOUT} rev-parse --git-path logs/refs/heads/${BRANCH}'). Recover it, then repair or delete the ref by hand." >&2
  finish 72 stranded
fi
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
# The observe check (9b, DND-1820). A skipped observe first: it is the
# definite finding, and it silently re-creates the re-noting DND-1806 ended.
if [ -n "${OBSERVE_MISSING}" ]; then
  record_failure "the session recorded neither unmeasurable observe nor ingest-failed for improve repo(s) ${OBSERVE_MISSING} (skipped, or the tool could not write even a failure record), so the unmeasurable-phase escalation (DND-1806) did not run on them" \
    "repos=${OBSERVE_MISSING}" "${observe_lines[@]}" "session_exit=0"
  echo "${ME}: run ${ts} has no observe record for ${OBSERVE_MISSING}; counted as unsuccessful (observe-missing). Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read ${log} and the journal for why the shipwright did not run athena:lead-time-improve -> Escalate what stays unmeasurable on it (every run observes every improve repo, or records ingest-failed for one with no summary); if observe ran, its stderr there says why no record was written. ${FAIL_ESCALATE} in a row wedge the lane." >&2
  finish 76 observe-missing
fi
if [ -n "${OBSERVE_UNREADABLE}" ]; then
  record_failure "COULD NOT LOOK at this run's observe record for improve repo(s) ${OBSERVE_UNREADABLE}, so whether the session observed them is unknown" \
    "repos=${OBSERVE_UNREADABLE}" "${observe_lines[@]}" "session_exit=0"
  echo "${ME}: run ${ts} COULD NOT LOOK at the observe record for ${OBSERVE_UNREADABLE}; counted as unsuccessful (observe-could-not-look). Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: read the observe: lines in the .run record (each names its reason); restore ${UNMEASURABLE_TOOL} by fast-forwarding ${MAIN_CHECKOUT}, or read and move aside the record it names by hand. It is never read as not recorded." >&2
  finish 77 observe-could-not-look
fi
if [ -n "${OBSERVE_FAILED}" ]; then
  record_failure "the session ran unmeasurable observe for improve repo(s) ${OBSERVE_FAILED} and it failed before counting (a refused summary, or a state file it could not read or write), so the escalation did not run on them" \
    "repos=${OBSERVE_FAILED}" "${observe_lines[@]}" "session_exit=0"
  echo "${ME}: run ${ts}: unmeasurable observe failed for ${OBSERVE_FAILED}; counted as unsuccessful (observe-failed). Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: the observe: line in the .run record names observe's exit and error. Fix what it refused or could not read or write (unmeasurable.json in ${STATE_DIR} is never read as empty); the next run observes again. ${FAIL_ESCALATE} in a row wedge the lane." >&2
  finish 74 observe-failed
fi
if [ -n "${OBSERVE_INGEST}" ]; then
  record_failure "improve repo(s) ${OBSERVE_INGEST} had no summary to observe: the session recorded ingest-failed (lead-time-phases --ingest or --summary failed), so the run could not measure them" \
    "repos=${OBSERVE_INGEST}" "${observe_lines[@]}" "session_exit=0"
  echo "${ME}: run ${ts} could not measure ${OBSERVE_INGEST}: its ingest or summary failed (ingest-failed); counted as unsuccessful. Record: ${LOG_DIR}/${ts}.failed" >&2
  echo "  Fix: run '${MAIN_CHECKOUT}/ai/bin/lead-time-phases --ingest --repo <repo>' by hand and follow its own Fix: line (the observe: line names the step, its exit and its error). ${FAIL_ESCALATE} in a row wedge the lane." >&2
  finish 79 ingest-failed
fi

reset_fail
echo "${ME}: run ${ts} ok: $(head -n1 "${SUMMARY}")" >&2
finish 0 ok
