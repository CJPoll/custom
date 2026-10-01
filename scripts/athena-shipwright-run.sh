#!/usr/bin/env bash
#
# athena-shipwright-run.sh — headless entrypoint for the athena-shipwright agent.
#
# Invoked by cron (this machine is OpenRC + cronie; see the crontab entry in
# the repo README/docs). Sets its own PATH because cron starts with a minimal
# environment. Starts a headless Claude Code session in a PER-INVOCATION
# WORKTREE of ~/dev/custom — never in the main checkout, which is the machine's
# live harness surface and whatever else is being edited in it — and delegates
# to the athena-shipwright agent, which mines the fleet's run artifacts,
# improves the harness, and syncs the repo with GitHub. The run's durable state
# stays anchored to the main checkout; see "where the run happens" below.
# Coordinating-session-then-delegate matches the main-session-policy hook: the
# top-level session spawns the agent rather than doing the work itself.
#
# Later (2026-09-19): earlier versions (PR #10, c8786cb) reused ONE persistent
# worktree, <repo>/.git/athena-shipwright, on a standing branch shipwright/auto.
# Superseded: each cron invocation is its own unit of work and gets its OWN
# short-lived lane — a fresh worktree <repo>/.git/shipwright-lanes/run-<utc>-<pid>
# on branch shipwright/run-<utc>-<pid>, created from origin/main and torn down
# after the run (see "the per-invocation lane" and "teardown" below). There is
# no standing shared lane, so a fresh tree is ALWAYS clean: the wedge-escalation
# signal therefore moved off tree-dirtiness onto consecutive UNSUCCESSFUL cron
# OUTCOMES (see "the failure counter" below), which is a strict superset of what
# the old dirty-tree skip counter caught — it additionally catches a lane whose
# sessions run and FAIL on a clean tree, which the old counter missed entirely.
#
# Single-run: an flock guard skips the run (exit 0) if one is already going, so
# a slow run never overlaps the next timer tick.
#
# Yield-to-a-live-editor: a second guard skips the run (exit 0) when the MAIN
# CHECKOUT is dirty, because dirt there means a human or another agent is
# mid-change in it and the end-of-run fast-forward would fail anyway. This guard
# is ECONOMY (don't spawn a whole session a human's edit will block), NOT safety,
# and is DECOUPLED from the failure counter: a human editing for hours must never
# look like a wedged lane. Like the flock, this guard covers the CRON path only —
# a directly-invoked shipwright agent never runs this script. The guarantee that
# holds whichever way the agent starts is scripts/athena-shipwright-commit.sh.
#
# Usage:
#   scripts/athena-shipwright-run.sh          # normal (timer) invocation
#   DRY_RUN=1 scripts/athena-shipwright-run.sh  # print the brief and exit
#
# Environment (test seams + the documented override):
#   SHIPWRIGHT_ALLOW_DIRTY=1  run even though the main checkout is dirty (below)
#   SHIPWRIGHT_FAIL_ESCALATE  consecutive UNSUCCESSFUL outcomes before a run
#                             exits 75 without spawning a session (default 6)
#   SHIPWRIGHT_BLOCK_ESCALATE how often the full blocked-tick explanation
#                             repeats during a blocked streak (default 3). Mail
#                             volume only: it never changes the exit code and
#                             never silences the class.
#   SHIPWRIGHT_STALE_DIRT_AGE_S  seconds since the newest change to the main
#                             checkout's dirty paths before that dirt is STALE
#                             rather than a live editor (default 21600 = 6h)
#   SHIPWRIGHT_STALE_DIRT_ESCALATE  consecutive STALE skips on one unchanged
#                             dirt signature before ONE harness-alert is sent
#                             (default 3). No repeat until the signature changes.
#   ATHENA_INBOX_ROOT         the inbox root the stale-dirt and wedge alerts are
#                             delivered under (default ~/.local/share/athena)
#   SHIPWRIGHT_REPO           repo to operate on   (default ~/dev/custom)
#   SHIPWRIGHT_CLAUDE         claude binary to run (default ~/.local/bin/claude)
#   SHIPWRIGHT_LANES_DIR      dir the per-run lanes live in
#                             (default <repo>/.git/shipwright-lanes)
#   SHIPWRIGHT_RUN_ID         force this run's lane id (default run-<utc>-<pid>)
#   SHIPWRIGHT_MAIN_HEALTH    the main-health to run each tick (self-test seam)
#   SHIPWRIGHT_SLACK_ROOTS    the slack-roots-tick to run each tick (self-test
#                             seam; DND-1502)
#
# Exported to the session:
#   SHIPWRIGHT_STATE_DIR      the ONE canonical state directory (cursor.txt,
#                             journal.md, runs/, owner-notes.md), always in the
#                             MAIN checkout, never in whichever tree this run
#                             happens to use. ai/bin/owner-notes reads it.
#
# Exit codes:
#   0   the session ran and exited 0, OR this tick was skipped (a run already in
#       flight, or a dirty main checkout) — a skip is not a failure. A dirty
#       skip on STALE dirt (see section 4) is still exit 0; it escalates by
#       ONE harness-alert instead, never through the exit code or the wedge
#   75  EX_TEMPFAIL: refused to spawn because the lane is WEDGED — this was the
#       SHIPWRIGHT_FAIL_ESCALATE'th consecutive UNSUCCESSFUL outcome (a
#       failing session, a stranded push, or reaped dead cron corpses)
#       Every wedged tick leaves <ts>.wedged in runs/ (why, the counter, when
#       it wedged, the re-arm command), and the first wedged tick of an episode
#       sends ONE harness-alert naming it (DND-834). Cron mail is not delivered
#       on every machine, so neither depends on it. The exit stays 75 even when
#       the record or the alert fails; each failure is loud with a Fix: line.
#   69  EX_UNAVAILABLE: the session did NO work — it never left its liveness
#       receipt, so it never reached the model (usually a provider usage limit,
#       credits, or auth). That is any receipt-less, commit-less session that
#       exited 0, or that exited non-zero with a known block signature in its
#       own output (DND-833: `claude -p` exits non-zero on a usage limit).
#       Reported every tick and never silent, but the lane is NOT gated and
#       self-heals; nothing to re-arm. A receipt-less non-zero exit with NO
#       signature is a failure (below) and leaves a <ts>.failed record.
#       Every tick that DID reach the model leaves <ts>.receipt in the state
#       dir's runs/ and it is kept, so `ls runs/*.receipt` answers "which past
#       ticks reported for duty?" directly — do not infer it from a log's size.
#   *   whatever the headless session exited with (124 if the 55m timeout fired);
#       a session that exits non-zero, or one whose commits could not be landed
#       on main (a "stranded" branch), counts as an unsuccessful outcome

set -euo pipefail

# cron starts with a minimal PATH that typically omits /usr/sbin — where this
# box's system tooling lives. Establish a known-good PATH so the gate, git, ssh,
# and any MCP servers Claude spawns resolve reliably from a minimal environment.
#
# This cron MUST NOT depend on asdf or the login shell. Cron does not source
# .zshrc, so the asdf launcher setup is unavailable here; an earlier version
# front-loaded ${HOME}/.asdf/shims (making `ruby` resolve to the asdf shim,
# which does `exec asdf exec ruby` and needs ${HOME}/bin/asdf + .zshrc), and
# cron runs died with "asdf: not found" while the gate/telemetry fail-opened
# and ran blind. The ruby gate tools (build-agents, harness-metrics/signals/eval,
# check-generic-skills, check-guard-messages) are all deliberately gem-free
# stdlib scripts, so the system ruby at /usr/bin/ruby (the eselect default,
# currently ruby34 / 3.4.10) satisfies them completely. Since DND-931 they name
# it directly (`#!/usr/bin/ruby`, enforced by ai/bin/check-ruby-floor), so PATH
# no longer picks their Ruby. A `ruby` called by name (in a spawned session or
# test suite) still uses PATH, which here is /usr/bin/ruby.
# We therefore deliberately EXCLUDE the asdf shims from PATH so `ruby` resolves
# to /usr/bin/ruby. ${HOME}/bin held only the asdf launcher, so it is dropped too.
export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin${PATH:+:${PATH}}"

# Same reason we can't lean on the login shell for PATH, we can't lean on it for
# the locale. Ruby derives a script's default external/internal encoding from
# the locale env vars; cron starts with none, so ruby falls back to US-ASCII and
# every gem-free gate tool blows up with "invalid byte sequence in US-ASCII" the
# instant it reads a UTF-8 agent/skill file — a fresh way for the gate to fail
# and run blind. Pin an explicit UTF-8 locale so `ruby` reads these files as UTF-8.
export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

# The shipwright's real work (mining + subagent) runs in background tasks that a
# headless `claude -p` session waits on. The default background-wait ceiling is
# 600s, after which the parent kills those tasks and exits 0 mid-run — leaving
# commits unpushed and the journal/cursor unwritten (observed on a smoke test).
# Raise the ceiling to a generous but BOUNDED 50 minutes so a normal run
# finishes. We deliberately do NOT use 0 ("wait indefinitely"): with no outer
# timeout and an flock single-run guard, an indefinitely-hung run would hold the
# lock forever and silently wedge every future hourly tick. 50 min sits
# comfortably under the hourly cadence; the `timeout` wrapper on the claude call
# below is the hard backstop that guarantees the lock is released before the
# next tick even if the session itself hangs.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=3000000

REPO="${SHIPWRIGHT_REPO:-${HOME}/dev/custom}"
CLAUDE="${SHIPWRIGHT_CLAUDE:-${HOME}/.local/bin/claude}"

# --- where the run happens, and where its memory lives ----------------------
#
# The run happens in a WORKTREE, never in the main checkout. The main checkout
# is the machine's live harness surface: ~/.claude/skills and ~/.claude/hooks
# resolve into it, and interactive sessions edit in it. An autonomous committer
# sharing that one tree with whoever else is typing is how, at 21:03 on
# 2026-09-18, this runner swept a concurrent session's hyprland.conf edit and a
# 230-line .bak into ce70e04 — a commit whose message was entirely about
# harness-gate self-tests. A separate tree makes that class unreachable rather
# than caught: there is no shared index and no shared working files to sweep.
#
# The run's MEMORY must not move with the tree. cursor.txt, journal.md and
# runs/ live under ai-artifacts/, which is gitignored, so a worktree starts with
# NONE of it. Deriving the state dir from the tree the run happens in would hand
# each run an empty state directory, and an absent cursor is indistinguishable
# from a cursor at epoch: the run either re-mines every artifact ever written or
# mines nothing, and BOTH look like a healthy run (the silent-success class this
# repo has a convention about — see 8d805c7, "a failed lookup must never look
# like an empty one"). So state is anchored to the MAIN CHECKOUT, resolved
# through git's common dir, and is the same directory whichever tree executes.
# It is exported so the agent reads it rather than deriving it from its cwd.
git_common_dir() { # absolute path to the repo's shared .git, or empty
  local d="$1" out
  out="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 0
  [ -n "$out" ] || return 0
  case "$out" in /*) ;; *) out="$d/$out" ;; esac
  ( cd "$out" 2>/dev/null && pwd -P ) || true
}

GIT_COMMON="$(git_common_dir "${REPO}")"
if [ -n "${GIT_COMMON}" ]; then
  MAIN_CHECKOUT="$(dirname "${GIT_COMMON}")"
else
  # Not a git repo (or git is unavailable). Everything below that needs git
  # fails loudly on its own; do not silently invent a state location.
  MAIN_CHECKOUT="${REPO}"
fi
# The branch the main checkout is on (usually "main"). Used for reachability
# tests when deciding a lane branch is safe to delete. Fall back to "main".
MAIN_BRANCH="$(git -C "${MAIN_CHECKOUT}" symbolic-ref --short HEAD 2>/dev/null || echo main)"

# --- the per-invocation lane -------------------------------------------------
#
# Each invocation gets its OWN short-lived worktree + branch, created from
# origin/main and torn down after the run (see "teardown"). The lanes live
# inside the repo's own .git dir, deliberately:
#   * `git status` in the main checkout never sees them, with no dependence on a
#     gitignore rule that is machine-local and not in this repository;
#   * they cannot be mistaken for one of the human worktrees under
#     ~/.local/worktrees, so nobody starts editing in a robot's tree;
#   * they are created, found and removed with the repository they belong to.
# The name carries a UTC timestamp and the pid, so two invocations never collide
# and a crashed run's corpse is greppable and reap-able.
LANES_DIR="${SHIPWRIGHT_LANES_DIR:-${GIT_COMMON:-${REPO}/.git}/shipwright-lanes}"
RUN_ID="${SHIPWRIGHT_RUN_ID:-run-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
BRANCH="shipwright/${RUN_ID}"
WORKTREE="${LANES_DIR}/${RUN_ID}"
LANE_LOCK="${LANES_DIR}/${RUN_ID}.lock"
LANE_META="${LANES_DIR}/${RUN_ID}.meta"

STATE_DIR="${MAIN_CHECKOUT}/ai-artifacts/shipwright"
export SHIPWRIGHT_STATE_DIR="${STATE_DIR}"
LOG_DIR="${STATE_DIR}/runs"
LOCK="${STATE_DIR}/run.lock"
# The wedge counter. It counts consecutive UNSUCCESSFUL cron OUTCOMES — a
# non-zero session exit, a timeout, a stranded (un-landed) push, plus dead
# cron-origin corpses reaped at the top of a run — and RESETS the moment a run
# lands cleanly. This replaces the old consecutive-skips counter, which counted
# dirty-tree skips and so never saw a clean session failure at all.
FAIL_COUNT="${STATE_DIR}/consecutive-failures"
# How many consecutive unsuccessful outcomes before a run refuses to spawn a
# session and exits 75. Six = six hourly ticks.
FAIL_ESCALATE="${SHIPWRIGHT_FAIL_ESCALATE:-6}"
# Validate it. A non-numeric value makes the `-ge` test below error out, and
# because that test sits in an `if` condition the error is exempt from `set -e`:
# the script falls straight through to the quiet exit path, disabling the
# wedged-lane escalation forever with nothing but a shell diagnostic to show for
# it. That is the "a wedged lane must not look like a quiet one" invariant
# defeated by a typo, so fall back to the default loudly rather than degrade
# into silence.
case "${FAIL_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "athena-shipwright: SHIPWRIGHT_FAIL_ESCALATE='${FAIL_ESCALATE}' is not a positive integer; using 6." >&2
    echo "  Fix: set SHIPWRIGHT_FAIL_ESCALATE to a positive whole number of consecutive unsuccessful outcomes (or unset it to accept the default 6). Left unfixed, the wedged-lane escalation would never fire." >&2
    FAIL_ESCALATE=6 ;;
esac

# The BLOCKED streak. Counts consecutive ticks whose session never reported for
# duty (see "8. classify the outcome"). Deliberately a SEPARATE counter from the
# wedge: a blocked tick must be loud but must never gate the next spawn.
BLOCK_COUNT="${STATE_DIR}/consecutive-blocked"
# How often the full Fix: paragraph repeats during a blocked streak. Mail volume
# only — it never changes the exit code and never silences the class.
BLOCK_ESCALATE="${SHIPWRIGHT_BLOCK_ESCALATE:-3}"
case "${BLOCK_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "athena-shipwright: SHIPWRIGHT_BLOCK_ESCALATE='${BLOCK_ESCALATE}' is not a positive integer; using 3." >&2
    echo "  Fix: set SHIPWRIGHT_BLOCK_ESCALATE to a positive whole number of ticks (or unset it to accept the default 3). It controls only how often the blocked-tick explanation repeats; a blocked tick is reported and exits 69 either way." >&2
    BLOCK_ESCALATE=3 ;;
esac

# The STALE-DIRT escalation (DND-692; section 4). The dirty-tree yield is exit
# 0 and never feeds the wedge, by design. Measured 2026-09-22..25, that let 84
# consecutive hourly skips on days-old inert leftovers go by with no signal at
# all. These two thresholds decide when yielding stops being "a live editor"
# and becomes something the owner has to hear about.
#   AGE 6h: a person or agent mid-change touches some dirty path far more often
#     than every 6 hours; the inbox registry's staleness thresholds use the same
#     6h figure for "longer than any measured healthy quiet". Overnight pauses
#     can cross it; the cost of that false positive is one message.
#   ESCALATE 3: age alone is not enough. Files extracted from an archive or
#     installed by npm keep their packaged mtimes (npm writes 1985), so a
#     brand-new node_modules reads as ancient. Three unchanged hourly ticks
#     prove nobody is working on the tree. Earliest alert: about 8h after the
#     last change for files with honest mtimes; for packaged mtimes the age
#     test passes at once, so about 2h (the third unchanged tick).
STALE_DIRT_STATE="${STATE_DIR}/stale-dirt"
STALE_DIRT_AGE_S="${SHIPWRIGHT_STALE_DIRT_AGE_S:-21600}"
case "${STALE_DIRT_AGE_S}" in
  ''|*[!0-9]*|0)
    echo "athena-shipwright: SHIPWRIGHT_STALE_DIRT_AGE_S='${STALE_DIRT_AGE_S}' is not a positive integer; using 21600." >&2
    echo "  Fix: set SHIPWRIGHT_STALE_DIRT_AGE_S to a positive whole number of seconds (or unset it to accept the default 21600 = 6h). Left unfixed, stale dirt in the main checkout would never be told apart from a live editor." >&2
    STALE_DIRT_AGE_S=21600 ;;
esac
STALE_DIRT_ESCALATE="${SHIPWRIGHT_STALE_DIRT_ESCALATE:-3}"
case "${STALE_DIRT_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "athena-shipwright: SHIPWRIGHT_STALE_DIRT_ESCALATE='${STALE_DIRT_ESCALATE}' is not a positive integer; using 3." >&2
    echo "  Fix: set SHIPWRIGHT_STALE_DIRT_ESCALATE to a positive whole number of consecutive stale skips (or unset it to accept the default 3). Left unfixed, the stale-dirt alert would never fire." >&2
    STALE_DIRT_ESCALATE=3 ;;
esac

# Known block signatures. This list is a CLASSIFIER, NEVER the detector — the
# detector is the missing receipt in section 8. A signature the vendor reworded
# away therefore CANNOT make a blocked tick read as healthy; it can only
# downgrade it to "blocked, UNCLASSIFIED", which prints MORE, not less.
#
# Later (2026-09-26, DND-833): on a NON-ZERO exit this list does decide. A
# receipt-less, commit-less tick that exits non-zero is BLOCKED when a signature
# matches and a wedge FAILURE when none does (section 8). So a false match now
# costs more than a label: it turns a real failure into a lane that never
# wedges. Two rules keep that surface narrow (DND-739):
#   * `429` is anchored to the words that make it an HTTP status ("API Error:
#     429", "HTTP 429", "status 429", "code=429"). A bare 429 matched pids,
#     temp paths and SHAs.
#   * classify_block reads the SESSION's output only, measured before teardown
#     appends git's own chatter to the same log (see section 6).
BLOCK_PATTERNS='usage limit|session limit|weekly limit|daily limit|rate limit|rate_limit|quota|out of credits|credit balance|insufficient_quota|billing|overloaded|Too Many Requests|(http|status|error|code)[^a-z0-9]{0,3}429\b|authentication|unauthorized|invalid api key'
classify_block() { # <log> <bytes> -> the matched signature in the first <bytes> of <log>, or nothing
  [ -r "$1" ] || return 0
  head -c "${2:-0}" -- "$1" 2>/dev/null | grep -m1 -i -E -o "${BLOCK_PATTERNS}" 2>/dev/null || true
}

mkdir -p "${LOG_DIR}"

# --- failure-counter helpers -------------------------------------------------
read_count() { # <path>
  local n=0
  [ -r "$1" ] && n="$(cat "$1" 2>/dev/null || echo 0)"
  case "${n}" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "${n}"
}
bump_count()  { local n; n="$(read_count "$1")"; printf '%s\n' "$(( n + 1 ))" >"$1"; }
reset_count() { rm -f "$1"; }

read_fail()  { read_count  "${FAIL_COUNT}"; }
bump_fail()  { bump_count  "${FAIL_COUNT}"; }
reset_fail() { reset_count "${FAIL_COUNT}"; }

# The brief deliberately says "your tree" and never names a path. The agent
# template owns where the run happens (a per-invocation worktree, never the main
# checkout), and a path restated here is a second source of truth that drifts
# from it — which is exactly what happened once: this string still read
# `~/dev/custom` after the worktree change landed, so the runner handed the agent
# a brief its own template had to override with a supersession label, every hour.
BRIEF="First, before anything else, run exactly this one Bash command: \
touch \"\$SHIPWRIGHT_RECEIPT\" — it is the runner's liveness receipt, and a tick \
with no receipt is reported as BLOCKED. Then you are coordinating; do the work \
by delegating. Spawn exactly one \
athena-shipwright agent (Agent tool, subagent_type: athena-shipwright) with \
this brief, and do nothing else yourself: 'Run your full retrospective now. \
Sync your tree with its remote first (pull, per your own Method), mine every \
coordination artifact newer than your cursor, apply harness improvements per \
your Method, gate, and invariants, commit each change locally, push your \
commits, and update your journal and cursor.' When it finishes, relay its \
one-line summary verbatim and stop."

# A human reading a cron-mailed `Fix:` line is exactly the reader who then runs
# this by hand, so the knobs those messages mention are discoverable here.
case "${1:-}" in
  -h|--help)
    sed -n '/^# Usage:/,/^#   \*   whatever the headless session/p' -- "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

if [ "${DRY_RUN:-0}" = "1" ]; then
  printf '%s\n' "${BRIEF}"
  exit 0
fi

# Everything below needs git. Without it there is nowhere to make a lane, so
# fail loudly rather than invent a location.
if [ -z "${GIT_COMMON}" ]; then
  echo "athena-shipwright: ${REPO} is not a git repository (or git is unavailable); cannot provision a lane." >&2
  echo "  Fix: confirm ${REPO} is a git checkout ('git -C ${REPO} rev-parse --git-common-dir'). The shipwright refuses to run in the main checkout, so a lane worktree is the only place a run can happen." >&2
  exit 2
fi

# --- 1. single-run lock ------------------------------------------------------
#
# Skip rather than queue if a run is already in flight.
#
# SCOPE, stated plainly because it was misread once: this lock guards THIS
# SCRIPT, not the repository. It serialises cron-vs-cron. A shipwright agent
# invoked directly — as happened at 21:00 on 2026-09-18, concurrently with the
# cron run — never passes through here and never touches this lock, so
# cron-vs-agent is NOT covered. Do not read a held lock as "nobody else is
# writing to ~/dev/custom". What protects the repo from a concurrent writer is
# entry-point-independent by design: athena-shipwright-commit.sh commits
# pathspec-limited, whichever way the agent was started.
#
# The lock FILE legitimately outlives a run: flock(2) lives on the open
# descriptor, so an empty, apparently-stale run.lock sitting there is normal and
# says nothing about whether a run is live. Do not "clean it up" — deleting it
# while a run holds it gives the next invocation a fresh inode and a lock that
# excludes nobody, which is the one way to actually get two cron runs at once.
# `9>>` and not `9>`: opening for plain write TRUNCATES, so a contending tick
# would erase the holder record before it could read it.
exec 9>>"${LOCK}"
if ! flock -n 9; then
  holder="$(cat "${LOCK}" 2>/dev/null || true)"
  echo "athena-shipwright: a run is already in progress; skipping this tick." >&2
  if [ -n "${holder}" ]; then
    echo "  holder: ${holder}" >&2
  fi
  echo "  Fix: nothing to do — the in-flight run finishes on its own and the next tick proceeds. To confirm the holder is alive, check the pid above (or 'fuser -v ${LOCK}'). Do NOT delete the lock file: it is held on an open descriptor, so its presence alone never means stale, and removing it while a run holds it hands the next tick a fresh inode and a lock that excludes nobody." >&2
  # Leave a record, so that "no artifact at all for an hour" means exactly one
  # thing — cron or the machine did not fire — instead of three.
  lts="$(date +%Y-%m-%dT%H%M%S)"
  printf 'athena-shipwright: tick %s skipped — a run was already in flight.\nholder: %s\n' \
    "${lts}" "${holder:-unknown}" >"${LOG_DIR}/${lts}.locked"
  exit 0
fi

# --- suppress D-Bus autolaunch, and reap any orphaned daemons ---------------
# cron provides no DBUS_SESSION_BUS_ADDRESS, but a graphical DISPLAY=:0 leaks in
# through the login-shell snapshot Claude Code's Bash tool sources. A dbus
# client (e.g. dunstify in the notify-idle Stop hook) then AUTOLAUNCHES a
# throwaway `dbus-daemon --syslog-only --fork ... --session` that never exits
# and, one per hour, exhausted the inotify instance limit (see
# scripts/lib/dbus-env.sh). Export an address so no descendant `claude`
# autolaunches, and best-effort reap orphans earlier runs left behind. Placed
# after the --help/DRY_RUN early exits and the single-run lock, so it runs only
# for an actual run.
__wrapper_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=scripts/lib/dbus-env.sh
. "${__wrapper_dir}/lib/dbus-env.sh"
athena_dbus_env_setup
# shellcheck source=scripts/lib/shipwright-stale-dirt.sh
. "${__wrapper_dir}/lib/shipwright-stale-dirt.sh"
"${__wrapper_dir}/reap-orphan-dbus" --min-age 300 >/dev/null 2>&1 || true

# Record who holds it, for the message above in the NEXT tick. Written to the
# PATH rather than to fd 9 (which is append-mode now), so each run replaces the
# previous holder's line instead of growing the file forever. We hold the lock,
# so truncating it here races with nobody.
printf 'pid=%s host=%s started=%s\n' "$$" "$(hostname 2>/dev/null || echo '?')" "$(date -Is)" >"${LOCK}"

ts="$(date +%Y-%m-%dT%H%M%S)"
log="${LOG_DIR}/${ts}.log"

# The liveness receipt. The session's FIRST instruction is to touch this; a
# session that dies before reaching the model cannot. Its ABSENCE is the
# detector in section 8 — deliberately NOT the log's size or line count, which
# were measured and cannot separate the two cases: the blocked log of
# 2026-09-19T00:00 is 68 bytes / 1 line and the healthy no-op log of
# 2026-09-17T20:00 is 71 bytes / 1 line.
# The receipt is RETAINED after a healthy tick (see the success path below), so
# `runs/` answers "which past ticks reached the model?" by `ls` rather than by
# inference. The clear below is a key reset for THIS tick only: it guarantees a
# re-run reusing the same second-resolution ts cannot inherit a stale file and
# be scored on its predecessor's liveness.
RECEIPT="${LOG_DIR}/${ts}.receipt"
export SHIPWRIGHT_RECEIPT="${RECEIPT}"
rm -f "${RECEIPT}"

# --- reachability + reaping helpers -----------------------------------------
#
# A commit is "landed" once it is reachable from origin/main. Only a repo with
# NO origin remote (the no-network fixture case) lands locally, and there the
# main checkout's branch is the landing target. With an origin, local main is
# NOT evidence of landing (DND-1008): teardown used to fast-forward it to any
# lane tip, so "reachable from local main" read unreviewed, unpushed work as
# landed. A branch holding commits that are neither landed nor published is
# "stranded" — the push failed — and is KEPT so the work is never silently
# discarded.
has_origin() { git -C "${MAIN_CHECKOUT}" remote get-url origin >/dev/null 2>&1; }
commit_reachable() { # commit-ish
  local c="$1"
  if has_origin; then
    git -C "${MAIN_CHECKOUT}" rev-parse --verify --quiet origin/main >/dev/null 2>&1 || return 1
    git -C "${MAIN_CHECKOUT}" merge-base --is-ancestor "$c" origin/main 2>/dev/null
    return
  fi
  git -C "${MAIN_CHECKOUT}" merge-base --is-ancestor "$c" "${MAIN_BRANCH}" 2>/dev/null
}
# Published for review: not landed, but on some origin branch (a PR). The work
# is safe on the remote, so it is not stranded and its local lane branch may go.
commit_published() { # commit-ish
  has_origin || return 1
  [ -n "$(git -C "${MAIN_CHECKOUT}" for-each-ref --contains "$1" --format='%(refname)' refs/remotes/origin 2>/dev/null)" ]
}

# Remove one lane's worktree, and delete its branch unless the branch is
# stranded (then keep it and say how to recover). Used by both the reaper (for a
# dead predecessor) and normal teardown.
retire_lane() { # run-id worktree-path context-label
  local rid="$1" wt="$2" ctx="$3" br="shipwright/$1" tip=""
  if [ -e "${wt}/.git" ]; then
    tip="$(git -C "${wt}" rev-parse HEAD 2>/dev/null || true)"
  fi
  git -C "${MAIN_CHECKOUT}" worktree remove --force "${wt}" >>"${log}" 2>&1 || rm -rf "${wt}"
  git -C "${MAIN_CHECKOUT}" worktree prune >>"${log}" 2>&1 || true
  if git -C "${MAIN_CHECKOUT}" show-ref --verify --quiet "refs/heads/${br}"; then
    if commit_reachable "${br}" || commit_published "${br}"; then
      git -C "${MAIN_CHECKOUT}" branch -D "${br}" >>"${log}" 2>&1 || true
    else
      echo "athena-shipwright: kept stranded branch ${br} (${ctx}); its commits are neither landed (origin/main; ${MAIN_BRANCH} when there is no origin) nor on any origin branch." >&2
      echo "  Fix: the work is NOT lost. Inspect it ('git -C ${MAIN_CHECKOUT} log ${MAIN_BRANCH}..${br}'), then land it ('git -C ${MAIN_CHECKOUT} merge --ff-only ${br}', or cherry-pick) and delete it ('git -C ${MAIN_CHECKOUT} branch -D ${br}'). It is deliberately not auto-deleted so a failed push never silently discards a run's work." >&2
      return 1
    fi
  fi
  return 0
}

# Reap dead lanes left by crashed predecessors (rate-limit / power-loss killed
# the run before teardown — happened twice in the 18h before this landed).
#
# Liveness is decided by a held flock(2) on the lane's lock file, NEVER by a pid
# check: pids recycle, and a held lock is released by the kernel on SIGKILL or
# power-loss, so acquiring the lock proves the owner is gone. We may reap ONLY a
# lane whose lock we can acquire — so a LIVE concurrent run (cron, or a
# hand-spawned agent that took a lane) is never reaped out from under itself.
# A dead lane whose meta records origin=cron counts toward the failure counter
# (a crashed cron run is an unsuccessful outcome); any other origin is reaped for
# hygiene but NOT counted.
reap_dead_lanes() {
  [ -d "${LANES_DIR}" ] || return 0
  local lock rid wt meta origin got
  # Primary: every lane that advertises a lock file.
  for lock in "${LANES_DIR}"/*.lock; do
    [ -e "${lock}" ] || continue
    rid="$(basename "${lock}" .lock)"
    wt="${LANES_DIR}/${rid}"
    meta="${LANES_DIR}/${rid}.meta"
    origin="spawned"
    [ -r "${meta}" ] && origin="$(sed -n 's/^origin=//p' "${meta}" | head -n1)"
    [ -n "${origin}" ] || origin="spawned"
    # Try to take the lock in a subshell. If we get it, the owner is dead and we
    # reap WHILE HOLDING it, closing the race with a run that might take it next.
    got=""
    if got="$(
      exec 7>>"${lock}"
      if flock -n 7; then
        retire_lane "${rid}" "${wt}" "reaped dead ${origin} run" >/dev/null 2>&1 || true
        printf 'reaped'
      fi
    )"; [ "${got}" = "reaped" ]; then
      rm -f "${lock}" "${meta}"
      [ "${origin}" = "cron" ] && bump_fail
      echo "athena-shipwright: reaped dead ${origin} lane ${rid}." >&2
    fi
    # else: a live run holds the lock — leave it strictly alone.
  done
  # Secondary hygiene: a worktree dir with NO lock file can only be a crash
  # between `worktree add` and lock creation. A concurrent cron run is
  # impossible here (we hold the single-run flock), so this is always safe.
  for wt in "${LANES_DIR}"/run-*; do
    [ -d "${wt}" ] || continue
    rid="$(basename "${wt}")"
    [ -e "${LANES_DIR}/${rid}.lock" ] && continue
    retire_lane "${rid}" "${wt}" "reaped lockless lane" >/dev/null 2>&1 || true
    echo "athena-shipwright: reaped lockless lane ${rid}." >&2
  done
  git -C "${MAIN_CHECKOUT}" worktree prune >>"${log}" 2>&1 || true
}

# --- the harness-alerts send path (DND-692; shared with DND-834) --------------
#
# Two reports leave this runner as ONE local maildir message each on the custom
# entry's harness-alerts-detector channel: stale dirt (section 4) and a wedge
# (section 3). Each names a record in runs/ in its re:, and that record, never
# the message, is what the reader (athena:inbox-attend) verifies. So a record
# is always written BEFORE its send, and a send is never attempted for a record
# that could not be written.

# record_note <record> <line> — append one line to a record. A failed append is
# loud and returns 0, so it can never change a tick's exit code under errexit.
record_note() {
  printf '%s\n' "$2" >>"$1" && return 0
  echo "athena-shipwright: could not append to the record $1: $2" >&2
  echo "  Fix: check that $(dirname -- "$1") is writable and the disk is not full." >&2
  return 0
}

# harness_alert_send <record> <slug> <body-file> — deliver one message, re:
# <record>. Prints the delivered message name. Non-zero (with send-mail's words
# on stderr) when the send failed.
harness_alert_send() {
  local record="$1" slug="$2" body="$3" repo send_mail out rc name attempt=0
  repo="$(cd -- "${__wrapper_dir}/.." && pwd -P)"
  send_mail="${repo}/ai/skills/athena:inbox/bin/send-mail"
  if [ ! -x "${send_mail}" ]; then
    echo "send-mail is missing: ${send_mail}" >&2
    return 4
  fi
  # This channel's detector side has a second writer, the inbox-client
  # watchdog, under the same identity. send-mail serialises the two with the
  # channel's .sender.lock and REFUSES (never collides) when the other holds
  # it, so a refusal is retried briefly here; any other failure is not. Each
  # refusal is noted in the record, so a reader can see the retry happened.
  while :; do
    attempt=$(( attempt + 1 ))
    out="$(cd -- "${repo}" && timeout 20 "${send_mail}" --local harness-alerts-detector "${slug}" \
            --to custom --re "${record}" --body-file "${body}" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ] || [ "${attempt}" -ge 3 ] || ! grep -q 'already sending on' <<<"${out}"; then
      break
    fi
    record_note "${record}" "alert: sender lock busy (attempt ${attempt}/3); retrying"
    sleep 2
  done
  if [ "${rc}" -ne 0 ]; then
    printf '%s\n' "${out}" | head -n 3 >&2
    return "${rc}"
  fi
  name="$(printf '%s\n' "${out}" | sed -n 's/^athena:inbox: delivered //p' | tail -n 1)"
  printf '%s\n' "${name:-?}"
}

# --- the wedge record and its one alert per episode (DND-834) -----------------
#
# Measured on the laptop, 2026-09-23..26: the lane wedged, and every tick after
# that exited 75 leaving only an empty .log. The WEDGED line went to cron mail,
# and that machine's mail spool has been empty since 2025, so the wedge was dark
# for three days. A wedged tick now writes <ts>.wedged in runs/ (why, the
# counter, when it wedged, the re-arm command), and the FIRST wedged tick of an
# EPISODE sends ONE harness-alert naming that record. An episode begins at the
# first wedged tick and ends when the counter drops below the threshold (the
# owner's re-arm, `rm ${FAIL_COUNT}`, or a raised threshold). A later wedge is a
# new episode and alerts again. A record or send that fails is loud and never
# changes the exit code: a wedged tick exits 75 whatever happens here.
#
# The episode state (key=value): episode = the tick that opened it,
# first_wedged = the counter file's mtime at that moment (the counter only
# changes on a failure, so its mtime is when the lane reached the threshold;
# for a lane already wedged when this code landed that predates the episode),
# alerted = the message name once one was delivered.
WEDGE_STATE="${STATE_DIR}/wedged"

# wedge_last_log — the newest run log with output, other than this tick's. On a
# wedged lane that is usually the last session that printed why it failed.
wedge_last_log() {
  local f
  f="$(find "${LOG_DIR}" -maxdepth 1 -type f -name '*.log' -size +0 ! -name "${ts}.log" -printf '%f\n' 2>/dev/null | sort | tail -n 1)" || f=""
  if [ -n "${f}" ]; then printf '%s\n' "${LOG_DIR}/${f}"; else printf '(none)\n'; fi
}

# wedge_send <record> <episode> <first-wedged> <failures> <last-log>
wedge_send() {
  local record="$1" episode="$2" first="$3" failures="$4" last_log="$5" body rc=0
  body="$(mktemp "${TMPDIR:-/tmp}/shipwright-wedged.XXXXXX")" || { echo "cannot create a temporary body file" >&2; return 4; }
  chmod 600 "${body}"
  {
    printf 'The shipwright cron on this machine is WEDGED: every hourly tick exits 75 and spawns no session, so the self-improvement loop is dark (DND-834).\n'
    printf 'This is a report. The wedge record named in re: is the authority.\n\n'
    printf 'checkout: %s\n' "${MAIN_CHECKOUT}"
    printf 'episode: %s\n' "${episode}"
    printf 'first_wedged: %s\n' "${first}"
    printf 'consecutive_failures: %s\n' "${failures}"
    printf 'threshold: %s\n' "${FAIL_ESCALATE}"
    printf 'counter: %s\n' "${FAIL_COUNT}"
    printf 'last_output_log: %s\n' "${last_log}"
    printf '\nFix: read why the runs failed (the .failed and .blocked records and the last_output_log under %s), fix the cause, then re-arm the lane with: rm %s. The next tick then runs. This alert is sent once per wedge episode; the episode ends when the counter is cleared.\n' "${LOG_DIR}" "${FAIL_COUNT}"
  } >"${body}"
  harness_alert_send "${record}" shipwright-wedged "${body}" || rc=$?
  rm -f "${body}"
  return "${rc}"
}

# wedge_track <tick> <failures> — write this tick's wedge record, open or
# continue the episode, and send the episode's one alert when it is due. Always
# returns 0: it reports on the wedge, it never decides it.
wedge_track() {
  local tick="$1" failures="$2" record episode first alerted mt last_log name="" err tmp
  record="${LOG_DIR}/${tick}.wedged"
  episode="$(sd_state_get "${WEDGE_STATE}" episode)"
  first="$(sd_state_get "${WEDGE_STATE}" first_wedged)"
  alerted="$(sd_state_get "${WEDGE_STATE}" alerted)"
  if [ -z "${episode}" ]; then
    episode="${tick}"; alerted=""
    first="unknown"
    if mt="$(stat -c %Y -- "${FAIL_COUNT}" 2>/dev/null)"; then
      first="$(date -u -d "@${mt}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || first="unknown"
    fi
  fi
  [ -n "${first}" ] || first="unknown"
  last_log="$(wedge_last_log)"

  # The record is the alert's authority: if it cannot be written, no alert goes
  # out this tick, and the episode state is left alone so the next tick retries.
  # The positive `if { } >file; then :; else` form is deliberate: bash (5.3
  # measured) does not apply `!` to a compound command whose redirection
  # fails, so `if ! { ... } >file` reads an unwritable record as written.
  if {
    printf 'athena-shipwright: tick %s refused to spawn a session: the lane is WEDGED (exit 75).\n' "${tick}"
    printf 'why: %s consecutive unsuccessful outcomes (failing sessions, stranded pushes, or reaped dead cron corpses) reached the threshold %s. No session runs until the counter is cleared.\n' "${failures}" "${FAIL_ESCALATE}"
    printf 'counter=%s\n' "${FAIL_COUNT}"
    printf 'last_output_log=%s\n' "${last_log}"
    printf 'rearm: rm %s\n' "${FAIL_COUNT}"
    printf 'Fix: read why the runs failed (the .failed and .blocked records and last_output_log above), fix the cause, then re-arm with: rm %s\n' "${FAIL_COUNT}"
    printf 'wedged: consecutive_failures=%s threshold=%s first_wedged=%s episode=%s\n' \
      "${failures}" "${FAIL_ESCALATE}" "${first}" "${episode}"
  } >"${record}" 2>/dev/null; then
    :
  else
    echo "athena-shipwright: could not write the wedge record ${record}; no wedge alert this tick, and the next tick retries." >&2
    echo "  Fix: check that ${LOG_DIR} is writable and the disk is not full. The lane is still WEDGED: re-arm it with 'rm ${FAIL_COUNT}' once the cause is fixed." >&2
    return 0
  fi

  if [ -z "${alerted}" ]; then
    err="$(mktemp)" || err=""
    if name="$(wedge_send "${record}" "${episode}" "${first}" "${failures}" "${last_log}" 2>"${err:-/dev/null}")"; then
      alerted="${name}"
      record_note "${record}" "alert: harness-alerts ${name}"
    else
      name=""
      record_note "${record}" 'alert: FAILED to send'
      echo "athena-shipwright: the wedge harness-alert could NOT be sent: $( [ -n "${err}" ] && tr '\n' ' ' <"${err}" || echo '(send-mail output lost: no temporary file)')" >&2
      echo "  Fix: run inbox-doctor from ${__wrapper_dir%/scripts} (is the custom registry entry installed with its harness-alerts channels? scripts/setup-inbox-registry --install). Nothing was recorded as sent, so the next wedged tick retries on its own." >&2
    fi
    [ -z "${err}" ] || rm -f "${err}"
  else
    record_note "${record}" "alert: already sent for this episode (${alerted})"
  fi

  # A failed state write must not change the exit code, so it is loud instead
  # of tripping errexit. Losing it repeats the alert next tick; it never hides one.
  tmp=""
  if ! { tmp="$(mktemp "${WEDGE_STATE}.XXXXXX" 2>/dev/null)" \
         && printf 'episode=%s\nfirst_wedged=%s\nalerted=%s\n' "${episode}" "${first}" "${alerted}" >"${tmp}" \
         && mv -f "${tmp}" "${WEDGE_STATE}"; }; then
    [ -z "${tmp}" ] || rm -f "${tmp}"
    echo "athena-shipwright: could not save the wedge episode state ${WEDGE_STATE}; the next wedged tick treats this as a new episode and alerts again." >&2
    echo "  Fix: check that ${STATE_DIR} is writable and the disk is not full." >&2
  fi

  if [ -n "${name}" ]; then
    echo "athena-shipwright: wedge ALERTED on harness-alerts (${name}); no repeat until the counter is cleared. Record: ${record}" >&2
  elif [ -n "${alerted}" ]; then
    echo "athena-shipwright: this wedge episode (since ${episode}) was already alerted (${alerted}); no repeat until the counter is cleared. Record: ${record}" >&2
  else
    echo "athena-shipwright: wedge record: ${record}" >&2
  fi
  return 0
}

# An episode ends when the counter is below the threshold. Checked BEFORE the
# reaper runs, so a re-arm followed by enough reaped dead cron corpses to wedge
# again in the same tick opens a NEW episode instead of continuing the old one.
if [ "$(read_fail)" -lt "${FAIL_ESCALATE}" ] && [ -e "${WEDGE_STATE}" ]; then
  if ! rm -f "${WEDGE_STATE}" 2>/dev/null; then
    echo "athena-shipwright: could not remove the ended wedge episode state ${WEDGE_STATE}; a later wedge would not be alerted." >&2
    echo "  Fix: check that ${STATE_DIR} is writable, then 'rm ${WEDGE_STATE}'." >&2
  fi
fi

# --- 2. reap dead predecessors ----------------------------------------------
reap_dead_lanes

# --- 2a. snapshot the Slack roots before the inbox rotates them out (DND-1502)
#
# The slack_routing eval's root snapshot grows only when `judgment-label
# --propose` runs, and an inbox generation is deleted at its second rotation.
# Nothing ran it on a schedule, so a root that rotated out between two manual
# runs was lost for good. ai/bin/slack-roots-tick runs it every tick: it is
# idempotent (the snapshot is append-only, a re-run appends nothing new),
# bounded (--timeout 600), and leaves runs/<tick>.propose under its own state
# dir. It alerts on its own, ONE harness-alerts message (slug
# slack-roots-failing) per failure episode, so its outcome is logged here and
# NEVER changes this tick's exit code. Like main-health it runs before the
# yield and wedge guards: a dirty main checkout or a wedged lane must not stop
# the snapshot. SHIPWRIGHT_SLACK_ROOTS is the self-test's seam.
SLACK_ROOTS="${SHIPWRIGHT_SLACK_ROOTS:-${__wrapper_dir%/scripts}/ai/bin/slack-roots-tick}"
SLACK_ROOTS_STATE="${MAIN_CHECKOUT}/ai-artifacts/slack-roots"
if [ -x "${SLACK_ROOTS}" ]; then
  sr_rc=0
  "${SLACK_ROOTS}" --state-dir "${SLACK_ROOTS_STATE}" --tick "${ts}" --timeout 600 \
    >>"${log}" 2>&1 </dev/null 9>&- || sr_rc=$?
  case "${sr_rc}" in
    0) echo "athena-shipwright: slack roots: judgment-label --propose ran (${SLACK_ROOTS_STATE}/runs/${ts}.propose)" >&2 ;;
    1) echo "athena-shipwright: slack roots: judgment-label --propose FAILED; the tool alerts once per episode (${SLACK_ROOTS_STATE}/runs/${ts}.propose)" >&2 ;;
    *) echo "athena-shipwright: slack roots: slack-roots-tick could not run (exit ${sr_rc}); the next tick retries. See ${log}." >&2
       echo "  Fix: read the slack-roots-tick lines in ${log}; their Fix: line names the cause." >&2 ;;
  esac
else
  echo "athena-shipwright: slack-roots-tick is missing or not executable: ${SLACK_ROOTS}; the Slack roots were NOT snapshotted this tick." >&2
  echo "  Fix: run the runner from a full ~/dev/custom checkout (scripts/ and ai/bin/ side by side)." >&2
fi

# --- 2b. post-landing main check: the backstop (DND-1482) --------------------
#
# ~/dev/custom has no CI, and a clean-rebase landing pushes with no re-gate
# (owner decision D5), so two landings can combine into a red origin/main.
# The admiral runs ai/bin/main-health check after each landing; this tick runs
# it too, for landings made by anyone else. It gates origin/main only when the
# tip has no verdict yet and no integration-gate receipt covers it, queued in
# test-slot, so most ticks cost one fetch. It runs before the yield and wedge
# guards on purpose: a dirty main checkout or a wedged lane must not leave main
# unwatched. Its outcome is logged and NEVER changes this tick's exit code: it
# alerts on its own (harness-alerts, slug main-red), and a check that could not
# measure retries next tick. SHIPWRIGHT_MAIN_HEALTH is the self-test's seam.
MAIN_HEALTH="${SHIPWRIGHT_MAIN_HEALTH:-${__wrapper_dir%/scripts}/ai/bin/main-health}"
mh_log="${LOG_DIR}/${ts}.main-health.log"
if [ -x "${MAIN_HEALTH}" ]; then
  mh_rc=0
  # Bounded so the tick stays inside its hour: 60 s for another check's lock
  # (a held lock means a check is already running), 15 min to queue in
  # test-slot, then the gate's own 1500 s cap. A miss is exit 3 and retries.
  "${MAIN_HEALTH}" check --repo "${MAIN_CHECKOUT}" --wait 60 --slot-wait 900 \
    >"${mh_log}" 2>&1 </dev/null || mh_rc=$?
  case "${mh_rc}" in
    0) echo "athena-shipwright: main-health: origin/main GREEN (${mh_log})" >&2 ;;
    1) echo "athena-shipwright: main-health: origin/main is RED; the check alerted on harness-alerts (${mh_log})" >&2 ;;
    *) echo "athena-shipwright: main-health could not measure origin/main (exit ${mh_rc}); the next tick retries. See ${mh_log}." >&2
       echo "  Fix: read ${mh_log}; its Fix: line names the cause." >&2 ;;
  esac
else
  echo "athena-shipwright: main-health is missing or not executable: ${MAIN_HEALTH}; origin/main was NOT checked this tick." >&2
  echo "  Fix: run the runner from a full ~/dev/custom checkout (scripts/ and ai/bin/ side by side)." >&2
fi

# --- 3. wedge escalation: refuse to spawn if too many failures in a row ------
#
# A WEDGED LANE MUST NOT LOOK LIKE A QUIET ONE. One bad outcome is routine; N in
# a row means the lane is failing every hour, and an hourly exit that looked like
# success would hide that indefinitely. Past the threshold we exit 75 (loud in
# cron mail and to anything watching exit codes) WITHOUT spawning a session, so
# a wedged lane stops burning tokens and starts being visible. A clean landing
# resets the counter.
failures="$(read_fail)"
if [ "${failures}" -ge "${FAIL_ESCALATE}" ]; then
  echo "athena-shipwright: WEDGED — ${failures} consecutive unsuccessful outcomes (failing sessions, stranded pushes, or reaped dead cron corpses). Refusing to spawn another session." >&2
  echo "  Fix: read the recent logs under ${LOG_DIR} to see WHY the runs failed — this is a real fault, not a passing editor. Once the cause is fixed, re-arm the lane by deleting the counter ('rm ${FAIL_COUNT}'); the next tick then runs. Raise SHIPWRIGHT_FAIL_ESCALATE to tolerate more consecutive failures before this fires." >&2
  # Cron mail is not delivered everywhere, so the wedge also leaves a record in
  # runs/ and alerts once per episode (DND-834; see "the wedge record" above).
  wedge_track "${ts}" "${failures}"
  exit 75
fi

# --- 4. yield to a live editor in the MAIN CHECKOUT (economy, not safety) ----
#
# The run fast-forwards the main checkout at the end so the live harness
# (~/.claude/skills, ~/.claude/hooks) advances. If the main checkout is dirty a
# human or another agent is mid-change in it and that fast-forward would fail
# anyway, so there is no point spawning a whole session. This is purely economy
# and is DECOUPLED from the failure counter: a human editing for hours must never
# accumulate into a false wedge. (The RUN's own tree is a fresh lane created from
# origin/main below, so it is always clean — there is nothing of the shipwright's
# own to sample here.)
#
# ai-artifacts/ is excluded EXPLICITLY rather than trusted to an ignore rule: it
# holds this machine's runtime artifacts (the runner's own logs, run.lock, the
# skip records) and is gitignored only by the user's MACHINE-LOCAL
# ~/.config/git/gitignore, which is not in this repository. Leaning on that would
# make the runner's own output count as dirt on any checkout without that rule.
#
# STALE DIRT ESCALATES (DND-692). A yield is exit 0 and never feeds the wedge,
# so a yield that never ends is invisible: measured 2026-09-22..25, 84 hourly
# skips on days-old leftovers and not one signal. So every dirty skip also
# classifies its dirt (scripts/lib/shipwright-stale-dirt.sh): LIVE when some
# dirty path changed within STALE_DIRT_AGE_S, else STALE. After
# STALE_DIRT_ESCALATE consecutive STALE skips on one unchanged signature, ONE
# message goes to the harness-alerts maildir naming the paths, the first-seen
# tick and the owner's options. It is not repeated until the signature changes.
# A failed send is loud and is NOT recorded as sent, so the next tick retries.
# None of this touches the dirt, changes the exit code, or feeds the wedge.

# stale_dirt_send <skip-record> <first-seen> <streak> <newest> <count> <sig> <paths>
# <paths> is the relay list stale_dirt_track already wrote into the record, so
# the message and its authority name the same paths. Prints the delivered
# message name. Non-zero (with send-mail's words on
# stderr) when the send failed.
stale_dirt_send() {
  local record="$1" first="$2" streak="$3" newest="$4" count="$5" sig="$6" paths="$7"
  local body rc=0
  body="$(mktemp "${TMPDIR:-/tmp}/shipwright-stale-dirt.XXXXXX")" || { echo "cannot create a temporary body file" >&2; return 4; }
  chmod 600 "${body}"
  {
    printf 'The shipwright cron has skipped %s consecutive hourly ticks on the same STALE dirt in its main checkout, so the self-improvement loop is dark (DND-692).\n' "${streak}"
    printf 'This is a report. The skip record named in re: is the authority.\n\n'
    printf 'checkout: %s\n' "${MAIN_CHECKOUT}"
    printf 'first_seen: %s\n' "${first}"
    printf 'consecutive_stale_skips: %s\n' "${streak}"
    printf 'newest_change: %s (%sh ago)\n' "$(date -u -d "@${newest}" +%Y-%m-%dT%H:%M:%SZ)" "$(( ( $(date +%s) - newest ) / 3600 ))"
    printf 'dirty_files: %s\n' "${count}"
    printf 'signature: %s\n' "${sig}"
    printf 'paths:\n'
    printf '%s\n' "${paths}" | sed 's/^/  /'
    printf '\nFix: these paths are not the shipwright'"'"'s, and it will never touch them. For each one, the owner picks: commit it, add it to .gitignore, or remove it. Until then every hourly tick yields and no retrospective runs. If the dirt is known inert and one run should proceed anyway, run scripts/athena-shipwright-run.sh with SHIPWRIGHT_ALLOW_DIRTY=1. This alert is not repeated until the dirty paths or their newest mtime change.\n'
  } >"${body}"
  harness_alert_send "${record}" shipwright-stale-dirt "${body}" || rc=$?
  rm -f "${body}"
  return "${rc}"
}

# stale_dirt_track <tick> <skip-record> — classify this skip's dirt, advance the
# streak, send the one alert when due, and say what happened on stderr and in
# the record. Always returns 0: it reports on the yield, it never decides it.
stale_dirt_track() {
  local tick="$1" record="$2" m sig newest count now age stale=0 label paths
  local prev_sig prev_streak first alerted streak name err tmp
  if ! m="$(sd_measure "${MAIN_CHECKOUT}")"; then
    record_note "${record}" 'dirt: UNMEASURED (git status or stat failed mid-scan)'
    echo "athena-shipwright: could not measure the age of the dirt in ${MAIN_CHECKOUT}; this skip is not counted toward the stale-dirt streak." >&2
    echo "  Fix: usually a path changed during the scan, which is a live editor and needs nothing. If every skip says UNMEASURED, run 'git -C ${MAIN_CHECKOUT} status --porcelain -z -uall' by hand: while it fails, stale dirt cannot escalate." >&2
    return 0
  fi
  sig="$(sed -n 1p <<<"${m}")"; newest="$(sed -n 2p <<<"${m}")"; count="$(sed -n 3p <<<"${m}")"
  now="$(date +%s)"; age=$(( now - newest ))
  if [ "${age}" -ge "${STALE_DIRT_AGE_S}" ]; then stale=1; label=STALE; else label=LIVE; fi

  prev_sig="$(sd_state_get "${STALE_DIRT_STATE}" signature)"
  prev_streak="$(sd_state_get "${STALE_DIRT_STATE}" streak)"
  first="$(sd_state_get "${STALE_DIRT_STATE}" first_seen)"
  alerted="$(sd_state_get "${STALE_DIRT_STATE}" alerted)"
  if [ "${prev_sig}" != "${sig}" ] || [ -z "${first}" ]; then first="${tick}"; alerted=""; fi
  streak="$(sd_next_streak "${prev_sig}" "${prev_streak}" "${sig}" "${stale}")"

  # The classification lands in the record BEFORE any send: the record is what
  # the alert's re: names and what its reader verifies, so it must already
  # carry the STALE verdict when the doorbell rings. The relay_paths block is
  # what the reader relays to the owner: the raw list above it is uncapped (an
  # untracked node_modules is every file in it, 30k measured) and unstripped.
  # The block is indented, so no line of it can start "dirt: ". A failed
  # listing is recorded as a failure in words, never as an empty block.
  if ! paths="$(sd_display_paths "${MAIN_CHECKOUT}" 20)"; then
    paths="(could not list the paths: git status failed; the raw list above this block is complete but uncapped)"
    echo "athena-shipwright: could not list the dirty paths for the relay block; the record says so instead." >&2
    echo "  Fix: run 'git -C ${MAIN_CHECKOUT} status --porcelain -unormal' by hand to see git's reason." >&2
  fi
  # The record is the alert's authority: if its classification cannot be
  # written, no alert goes out this tick and the streak does not advance.
  if ! {
    printf 'dirt: %s newest_change=%s age_s=%s stale_streak=%s/%s first_seen=%s signature=%s\n' \
      "${label}" "$(date -u -d "@${newest}" +%Y-%m-%dT%H:%M:%SZ)" "${age}" "${streak}" "${STALE_DIRT_ESCALATE}" \
      "${first}" "${sig}"
    printf 'relay_paths: (untracked directories collapsed, control characters stripped, at most 20)\n'
    printf '%s\n' "${paths}" | sed 's/^/  /'
  } >>"${record}"; then
    echo "athena-shipwright: could not write the dirt classification to ${record}; no stale-dirt alert this tick and the streak is unchanged." >&2
    echo "  Fix: check that $(dirname -- "${record}") is writable and the disk is not full." >&2
    return 0
  fi

  name=""
  if [ "${stale}" -eq 1 ] && [ "${streak}" -ge "${STALE_DIRT_ESCALATE}" ] && [ -z "${alerted}" ]; then
    err="$(mktemp)" || err=""
    if name="$(stale_dirt_send "${record}" "${first}" "${streak}" "${newest}" "${count}" "${sig}" "${paths}" 2>"${err:-/dev/null}")"; then
      alerted="${name}"
    else
      name=""
      record_note "${record}" 'alert: FAILED to send'
      echo "athena-shipwright: the stale-dirt harness-alert could NOT be sent: $( [ -n "${err}" ] && tr '\n' ' ' <"${err}" || echo '(send-mail output lost: no temporary file)')" >&2
      echo "  Fix: run inbox-doctor from ${__wrapper_dir%/scripts} (is the custom registry entry installed with its harness-alerts channels? scripts/setup-inbox-registry --install). Nothing was recorded as sent, so the next tick retries on its own." >&2
    fi
    [ -z "${err}" ] || rm -f "${err}"
  fi

  # A failed state write must stay a yield (exit 0), so it is loud instead of
  # tripping errexit. Losing it only restarts the streak, or repeats an alert.
  if ! { tmp="$(mktemp "${STALE_DIRT_STATE}.XXXXXX")" \
         && printf 'signature=%s\nfirst_seen=%s\nstreak=%s\nalerted=%s\n' "${sig}" "${first}" "${streak}" "${alerted}" >"${tmp}" \
         && mv -f "${tmp}" "${STALE_DIRT_STATE}"; }; then
    [ -z "${tmp:-}" ] || rm -f "${tmp}"
    echo "athena-shipwright: could not save the stale-dirt state ${STALE_DIRT_STATE}; the streak restarts next tick, and an alert already sent may repeat." >&2
    echo "  Fix: check that $(dirname -- "${STALE_DIRT_STATE}") is writable and the disk is not full." >&2
  fi

  [ -z "${name}" ] || record_note "${record}" "alert: harness-alerts ${name}"

  echo "athena-shipwright: the dirt is ${label} (newest change $(( age / 3600 ))h ago; STALE after $(( STALE_DIRT_AGE_S / 3600 ))h); stale streak ${streak}/${STALE_DIRT_ESCALATE} on this signature since ${first}." >&2
  if [ -n "${name}" ]; then
    echo "athena-shipwright: stale dirt ALERTED on harness-alerts (${name}); no repeat until the dirt changes." >&2
  elif [ -n "${alerted}" ]; then
    echo "athena-shipwright: this stale dirt was already alerted (${alerted}); no repeat until the dirt changes." >&2
  fi
  return 0
}

if [ "${SHIPWRIGHT_ALLOW_DIRTY:-0}" != "1" ]; then
  dirty="$(
    git -C "${MAIN_CHECKOUT}" -c core.quotePath=false status --porcelain -uall \
      | cut -c4- | grep -v '^ai-artifacts/' || true
  )"
  if [ -n "${dirty}" ]; then
    skipped="${LOG_DIR}/${ts}.skipped"
    {
      echo "athena-shipwright: skipped run ${ts} — ${MAIN_CHECKOUT} has uncommitted changes."
      printf '%s\n' "${dirty}"
    } >"${skipped}"
    echo "athena-shipwright: skipping run ${ts}; the main checkout ${MAIN_CHECKOUT} is dirty." >&2
    printf '%s\n' "${dirty}" >&2
    echo "  Fix: this is a yield to a live editor, not a failure — commit, gitignore, or remove the paths above (they are not the shipwright's; its own state under ai-artifacts/ is excluded) and the next tick proceeds. The end-of-run fast-forward would refuse to overwrite them anyway. This skip does NOT count toward the wedge escalation; dirt left STALE escalates once, to harness-alerts, instead. To run regardless when you know the dirt is inert, re-run with SHIPWRIGHT_ALLOW_DIRTY=1. Record: ${skipped}" >&2
    stale_dirt_track "${ts}" "${skipped}"
    exit 0
  fi
  # A clean main checkout ends any stale-dirt streak.
  rm -f "${STALE_DIRT_STATE}"
fi

# --- 5. provision this run's lane -------------------------------------------
#
# From origin/main: fetch it, then branch the lane off it, so the run starts
# from the current shared tip and every machine's shipwright builds on the same
# base. No-network fallback: if the fetch fails (offline, or a repo with no
# remote), base the lane on the main checkout's HEAD instead — the run still
# works, it just starts from local state and its commits land locally.
mkdir -p "${LANES_DIR}"
if git -C "${MAIN_CHECKOUT}" fetch --quiet origin main >>"${log}" 2>&1; then
  BASE_COMMIT="$(git -C "${MAIN_CHECKOUT}" rev-parse FETCH_HEAD 2>/dev/null || true)"
  base_desc="origin/main"
else
  BASE_COMMIT="$(git -C "${MAIN_CHECKOUT}" rev-parse HEAD 2>/dev/null || true)"
  base_desc="the main checkout HEAD (no-network fallback — could not fetch origin/main)"
  echo "athena-shipwright: could not fetch origin/main; basing lane ${RUN_ID} on ${base_desc}." >&2
fi
if [ -z "${BASE_COMMIT}" ]; then
  echo "athena-shipwright: could not resolve a base commit for the lane." >&2
  echo "  Fix: confirm ${MAIN_CHECKOUT} has at least one commit ('git -C ${MAIN_CHECKOUT} rev-parse HEAD')." >&2
  exit 1
fi

# `-b` (create), never `-B` (force): a name collision must FAIL LOUD rather than
# move an existing branch under a run that might be using it. The name carries a
# timestamp + pid, so a collision means a genuine leftover to investigate.
if ! git -C "${MAIN_CHECKOUT}" worktree add -q -b "${BRANCH}" "${WORKTREE}" "${BASE_COMMIT}" >>"${log}" 2>&1; then
  echo "athena-shipwright: could not create the per-invocation lane ${WORKTREE} on branch ${BRANCH} (base ${base_desc})." >&2
  echo "  Fix: read ${log} for git's reason. A branch-name collision (${BRANCH} already exists) is FATAL by design — this run neither reuses nor forces an existing branch, and never falls back to the main checkout, which is the hazard the lane exists to remove. Clear a stale registration with 'git -C ${MAIN_CHECKOUT} worktree prune' and delete a leftover branch with 'git -C ${MAIN_CHECKOUT} branch -D ${BRANCH}'." >&2
  exit 1
fi

# Record the lane's origin (for the reaper's counting rule) and take its
# liveness lock. We hold fd 8 for the whole session; a future run's reaper that
# tries this lock while we live will fail to acquire it and leave us alone.
printf 'origin=cron\npid=%s\nrun_id=%s\n' "$$" "${RUN_ID}" >"${LANE_META}"
exec 8>>"${LANE_LOCK}"
if ! flock -n 8; then
  # A brand-new lock file we just created cannot legitimately be held by anyone
  # else; if it is, something is very wrong — do not run.
  echo "athena-shipwright: the fresh lane lock ${LANE_LOCK} is already held; refusing to run." >&2
  echo "  Fix: this should be impossible for a unique run id. Check for a stale process holding it ('fuser -v ${LANE_LOCK}') and for a duplicate SHIPWRIGHT_RUN_ID." >&2
  git -C "${MAIN_CHECKOUT}" worktree remove --force "${WORKTREE}" >>"${log}" 2>&1 || rm -rf "${WORKTREE}"
  git -C "${MAIN_CHECKOUT}" branch -D "${BRANCH}" >>"${log}" 2>&1 || true
  rm -f "${LANE_LOCK}" "${LANE_META}"
  exit 1
fi

RUN_TREE="${WORKTREE}"
cd "${RUN_TREE}"

# --- 6. run the session ------------------------------------------------------
#
# House pattern for unattended Claude Code (see scripts/athena).
# Hard backstop: cap the whole invocation at 55 minutes (under the hourly tick)
# so a hung session is killed and the flock is released before the next run,
# rather than wedging the lane forever. `timeout` exits 124 on expiry; capture
# the status either way instead of letting `set -e` abort before we log it.
if timeout 55m "${CLAUDE}" --dangerously-skip-permissions -p "${BRIEF}" >"${log}" 2>&1; then
  status=0
else
  status=$?
fi

# Measure the SESSION's output now, before anything else writes to ${log}.
# Teardown below appends git's output ("Deleted branch shipwright/<run-id> (was
# <sha>)") to the same file, and that text must never classify the tick: the run
# id and SHA are arbitrary, and after DND-833 a signature decides wedge-vs-
# blocked on a non-zero exit. Everything past these bytes is the runner's own.
#
# The log's STATE is taken here too, not in section 8: teardown's `>>"${log}"`
# re-creates a log the session deleted, so a later look would read git's
# chatter as the session's output. Every command below must survive a missing
# log under `set -euo pipefail`. A bare `x="$(wc -c <"${log}" | ...)"` does not:
# the failed redirect fails the pipeline, errexit kills the runner on the spot,
# and the tick ends with no teardown, no counter and no record (DND-833 critic
# round 1). Hence the `|| true` inside the substitution.
if [ ! -e "${log}" ]; then
  session_output="missing"
elif [ ! -r "${log}" ]; then
  session_output="unreadable"
else
  session_output=""
fi
session_bytes="$( { wc -c <"${log}"; } 2>/dev/null | tr -d ' ' || true)"
case "${session_bytes}" in ''|*[!0-9]*) session_bytes=0 ;; esac
if [ -z "${session_output}" ]; then
  if [ "${session_bytes}" -eq 0 ]; then
    session_output="empty"
  else
    session_output="${session_bytes} bytes"
  fi
fi

# --- 7. teardown: publish on success, then always remove the lane ------------
#
# On a successful session, publish: refresh origin/main and fast-forward the
# main checkout to the lane tip so the machine's live harness advances. --ff-only
# is the whole safety story — it can only move the pointer forward to a commit
# that already contains main's history, it never creates or rewrites a commit,
# and git refuses it outright rather than overwrite a locally-modified file. A
# failure here is reported and NOT retried or forced.
#
# With an origin, only LANDED work is published this way (DND-1008): the tip
# must already be on origin/main. A run that put its work up for review (a PR
# branch) leaves the main checkout alone, so the live harness never runs
# unreviewed code and local main never diverges from origin/main.
tip="$(git -C "${WORKTREE}" rev-parse HEAD 2>/dev/null || true)"
publish_tip=0
if [ "${status}" -eq 0 ] && [ -n "${tip}" ] && [ "${tip}" != "${BASE_COMMIT}" ]; then
  publish_tip=1
  if has_origin; then
    git -C "${MAIN_CHECKOUT}" fetch --quiet origin main >>"${log}" 2>&1 || true
    if ! commit_reachable "${tip}"; then
      publish_tip=0
      if commit_published "${tip}"; then
        echo "athena-shipwright: run ${ts} published ${tip} for review; it is not landed on origin/main, so ${MAIN_CHECKOUT} was left where it is." >&2
      fi
    fi
  fi
fi
if [ "${publish_tip}" -eq 1 ]; then
  if ! git -C "${MAIN_CHECKOUT}" merge --ff-only "${tip}" >>"${log}" 2>&1; then
    echo "athena-shipwright: run ${ts} landed, but ${MAIN_CHECKOUT} could not be fast-forwarded to ${tip}." >&2
    echo "  Fix: the run's commits are already pushed (if the session pushed), so nothing is lost — but this machine's live harness (~/.claude/skills and ~/.claude/hooks resolve into ${MAIN_CHECKOUT}) stays on the older code until it catches up. Run 'git -C ${MAIN_CHECKOUT} merge --ff-only ${tip}' once the blocker is cleared; git's reason is at the end of ${log}. Usual causes: a locally-modified file the fast-forward would overwrite, or main having diverging commits — do NOT force either." >&2
  fi
fi

# Classify before removal: does the lane hold commits that never landed on
# main/origin/main? If so it is stranded — an unsuccessful outcome even if the
# session exited 0, because the harness work never reached the machine.
stranded=0
if [ -n "${tip}" ] && [ "${tip}" != "${BASE_COMMIT}" ] && ! commit_reachable "${tip}" && ! commit_published "${tip}"; then
  stranded=1
fi

# Always remove the worktree; retire_lane keeps the branch iff it is stranded.
if retire_lane "${RUN_ID}" "${WORKTREE}" "run ${ts}"; then
  : # branch deleted (landed) or never had commits
else
  stranded=1  # retire_lane kept a stranded branch and already printed the Fix
fi

# Release + remove this lane's liveness lock and meta.
# NOTE the braces. `exec 8>&- 2>/dev/null` would apply the 2>/dev/null to the
# `exec` BUILTIN ITSELF, and an `exec` with no command makes its redirections
# PERMANENT — silently sending the rest of the script's stderr to /dev/null,
# including every message and Fix: line below. Scope it to a group instead.
{ exec 8>&-; } 2>/dev/null || true
rm -f "${LANE_LOCK}" "${LANE_META}"

# --- 8. classify the outcome: success, BLOCKED, or failure -------------------
#
# THREE outcomes, not two, because of a measured defect. On 2026-09-19 nine
# consecutive ticks (00:00..08:00) died instantly on the provider's weekly usage
# limit, exited 0, made no commits — and were therefore classified as CLEAN
# SUCCESSES that RESET the wedge counter. Zero retrospective work happened and
# nothing on disk could tell those ticks from a healthy run that mined artifacts
# and found nothing worth changing. That is this machine's own "a failed lookup
# must never look like an empty one", reproduced inside the counter whose stated
# job is "A WEDGED LANE MUST NOT LOOK LIKE A QUIET ONE".
#
# SCOPE: a tick is blocked when its session left NO receipt and made NO commits,
# and then EITHER it exited 0 (the receipt alone detects it; the signature only
# labels it) OR it exited non-zero AND its own output matches a known block
# signature. A receipt-less non-zero tick with no signature stays a wedge
# failure — a missing binary or a crash must still wedge — but it is reported
# as one that never reported for duty, with a .failed record (below).
#
# Later (2026-09-26, DND-833): this paragraph said "only status==0 can be
# blocked", on the belief that a usage limit exits 0. Superseded: `claude -p`
# also exits NON-ZERO on a usage limit. Measured on the laptop 2026-09-23
# 02:00..07:00: six ticks each logged "You've hit your weekly limit", left no
# receipt, and each counted as a wedge failure; the sixth wedged the lane and
# every later tick exited 75 without spawning. A provider outage that cleared
# the next morning became a human-gated wedge, the exact outcome the paragraph
# below forbids. A session that DID leave its receipt reached the model, so its
# non-zero exit is still a failure whatever its log says.
#
# BLOCKED NEVER GATES THE NEXT SPAWN. The wedge exists to stop a broken lane
# burning tokens; a blocked tick burns none and the cause is transient and
# self-resolving, so gating would turn a provider outage into a human-gated one.
# Blocked is made LOUD instead (exit 69, a marker, its own streak counter) and
# the lane self-heals with no human action. It also does NOT reset the wedge
# counter: the old reset_fail on this path silently erased a real accumulating
# failure streak, which is strictly weaker than leaving it alone.
blocked=0
unreported=0
block_sig=""
if [ ! -e "${RECEIPT}" ] && [ "${tip}" = "${BASE_COMMIT}" ]; then
  unreported=1
  block_sig="$(classify_block "${log}" "${session_bytes}")"
  if [ "${status}" -eq 0 ] || [ -n "${block_sig}" ]; then
    blocked=1
  fi
fi

if [ "${blocked}" -eq 1 ]; then
  bump_count "${BLOCK_COUNT}"
  streak="$(read_count "${BLOCK_COUNT}")"
  marker="${LOG_DIR}/${ts}.blocked"
  {
    echo "athena-shipwright: run ${ts} did NO retrospective work — the session never reported for duty."
    echo "receipt=${RECEIPT} (absent)"
    echo "session_exit=${status}"
    echo "session_output=${session_output}"
    echo "consecutive_blocked=${streak}"
    if [ -n "${block_sig}" ]; then
      echo "classification=blocked (signature: ${block_sig})"
    else
      echo "classification=UNCLASSIFIED (no known block signature matched)"
    fi
    echo "log=${log}"
  } >"${marker}"

  if [ -n "${block_sig}" ]; then
    echo "athena-shipwright: run ${ts} BLOCKED (${block_sig}) — the session did no work; ${streak} consecutive blocked tick(s). Record: ${marker}" >&2
  else
    echo "athena-shipwright: run ${ts} BLOCKED, UNCLASSIFIED — the session did no work and NO known block signature matched ${log}. The signature list is probably stale. Record: ${marker}" >&2
  fi
  if [ -z "${block_sig}" ] || [ "${streak}" -eq 1 ] || [ $(( streak % BLOCK_ESCALATE )) -eq 0 ]; then
    echo "  Fix: read ${log} (it holds whatever the session managed to print) and ${marker}. This tick did ZERO retrospective work — no artifact mined, no journal entry, no cursor advance — so read the matching gap in ${STATE_DIR}/journal.md as an OUTAGE, not a quiet period. Nothing is wedged and nothing needs re-arming: the lane keeps trying every hour and recovers by itself the moment the block clears; do NOT delete ${FAIL_COUNT} or ${BLOCK_COUNT}. If this says UNCLASSIFIED, the provider reworded its message — add the new wording to BLOCK_PATTERNS in $0 and add a case to scripts/test/athena-shipwright/self-test.sh so the list cannot rot silently again. If ticks stay blocked past the reset time the log states, the cause is NOT transient: check account, billing and auth for ${CLAUDE}. SHIPWRIGHT_BLOCK_ESCALATE only changes how often this paragraph repeats; it never silences the class." >&2
  fi
  echo "athena-shipwright: run ${ts} session exited ${status} but did no work; reporting BLOCKED (exit 69); log: ${log}" >&2
  exit 69
fi

# The receipt is deliberately NOT deleted here. It is retained as this tick's
# durable, per-tick evidence that the session reached the model, sitting beside
# its log. Deleting it on the success path made the detector destroy its own
# evidence: one hour later "did tick N report for duty?" was unanswerable, and
# an absent receipt for a past tick read identically whether the tick was
# healthy (receipt made, then unlinked here) or blocked (receipt never made).
# On 2026-09-19 that cost a shipwright run a confident, WRONG outage report
# about the outage detector itself — it read "only one receipt exists on disk"
# as a prose-disobedience rate rather than as the working system's expected
# output, and only an architect review caught it before it was journaled.
# This is ~/dev/custom/CLAUDE.md's "make every miss observable", owed on the
# HIT side too: a successful probe must leave something a human can read.
#
# Retention cannot weaken the detector. The test above is `[ ! -e "${RECEIPT}" ]`
# against THIS tick's ts-keyed path, and the `rm -f "${RECEIPT}"` at setup
# clears exactly that path before the session starts, so a retained receipt from
# an earlier tick can never answer for a later one. Nothing anywhere globs
# `*.receipt`; the exact-path test is its only consumer.
#
# Growth is one empty file per tick, beside the one log file per tick that
# `runs/` already accumulates. Do not "tidy" these away while keeping the logs:
# that re-creates precisely the blind spot described above.

# A receipt-less, commit-less tick that exited non-zero with NO known signature
# (DND-833). It is a wedge failure, but it is not an ordinary one: the session
# never reached the model, and whether it printed nothing, printed a reworded
# limit message, or crashed are three different faults. Say which, in a record
# that survives when cron mail does not.
if [ "${unreported}" -eq 1 ]; then
  failed="${LOG_DIR}/${ts}.failed"
  {
    echo "athena-shipwright: run ${ts} exited ${status} and never reported for duty (no receipt, no commits)."
    echo "receipt=${RECEIPT} (absent)"
    echo "session_exit=${status}"
    echo "session_output=${session_output}"
    echo "classification=failure (no known block signature in the session's output)"
    echo "log=${log}"
  } >"${failed}"
  if [ "${session_output}" = "empty" ]; then
    echo "athena-shipwright: run ${ts} session exited ${status}, printed NOTHING, and never reported for duty. Counted as an unsuccessful outcome. Record: ${failed}" >&2
  elif [ "${session_output}" = "missing" ] || [ "${session_output}" = "unreadable" ]; then
    echo "athena-shipwright: run ${ts} session exited ${status} and never reported for duty; its log was ${session_output} when it exited, so there was nothing to classify (anything now in ${log} is teardown's). Counted as an unsuccessful outcome. Record: ${failed}" >&2
  else
    echo "athena-shipwright: run ${ts} session exited ${status} and never reported for duty; its output (${session_output}) matched NO known block signature. Counted as an unsuccessful outcome. Record: ${failed}" >&2
  fi
  echo "  Fix: read ${log} and ${failed}. The session died before its first instruction, so this is not a harness change gone wrong. If the log shows a provider limit, credits, or auth message, the vendor reworded it: add the wording to BLOCK_PATTERNS in $0 and a case to scripts/test/athena-shipwright/self-test.sh, and the tick becomes BLOCKED (never wedging). If the log is empty or shows a crash, check that ${CLAUDE} runs by hand ('${CLAUDE} --version'). This outcome feeds the wedge counter ${FAIL_COUNT}." >&2
else
  reset_count "${BLOCK_COUNT}"   # the session reached the model; the streak ends
fi
# A clean landing (session exited 0 AND its commits reached main/origin/main, or
# it made no commits at all) resets the counter. Anything else — a failing/timed
# out session, or a stranded push — is an unsuccessful outcome and increments it.
if [ "${status}" -eq 0 ] && [ "${stranded}" -eq 0 ]; then
  reset_fail
else
  bump_fail
fi

if [ "${stranded}" -eq 1 ] && [ "${status}" -eq 0 ]; then
  echo "athena-shipwright: run ${ts} ran clean but its commits did not land on main; counted as an unsuccessful outcome." >&2
fi
echo "athena-shipwright: run ${ts} exited ${status} (stranded=${stranded}); log: ${log}" >&2
exit "${status}"
