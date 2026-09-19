#!/usr/bin/env bash
#
# athena-shipwright-run.sh — headless entrypoint for the athena-shipwright agent.
#
# Invoked by cron (this machine is OpenRC + cronie; see the crontab entry in
# the repo README/docs). Sets its own PATH because cron starts with a minimal
# environment. Starts a headless Claude Code session in ~/dev/custom and delegates to the
# athena-shipwright agent, which mines the fleet's run artifacts, improves the
# harness, and syncs the repo with GitHub. Coordinating-session-then-delegate
# matches the main-session-policy hook: the top-level session spawns the agent
# rather than doing the work itself.
#
# Single-run: an flock guard skips the run (exit 0) if one is already going, so
# a slow run never overlaps the next timer tick.
#
# Yield-to-a-live-editor: a second guard skips the run (exit 0) when the
# worktree is dirty, because dirt means a human or another agent is mid-change
# in this checkout. See "the yield guard" below for why this is a skip and not
# merely a narrower `git add`. Like the flock, this guard covers the CRON path
# only — a directly-invoked shipwright agent never runs this script. The
# guarantee that holds whichever way the agent starts is
# scripts/athena-shipwright-commit.sh.
#
# Usage:
#   scripts/athena-shipwright-run.sh          # normal (timer) invocation
#   DRY_RUN=1 scripts/athena-shipwright-run.sh  # print the brief and exit
#
# Environment (test seams + the documented override):
#   SHIPWRIGHT_ALLOW_DIRTY=1  run even though the worktree is dirty (see below)
#   SHIPWRIGHT_SKIP_ESCALATE  consecutive dirty-tree skips before a skip exits
#                             non-zero instead of 0 (default 6)
#   SHIPWRIGHT_REPO           repo to operate on   (default ~/dev/custom)
#   SHIPWRIGHT_CLAUDE         claude binary to run (default ~/.local/bin/claude)
#
# Exit codes:
#   0   the session ran and exited 0, OR this tick was skipped (a run already in
#       flight, or a dirty tree) — a skip is not a failure
#   75  EX_TEMPFAIL: skipped, and this was the SKIP_ESCALATE'th consecutive
#       dirty-tree skip. The lane is wedged, not idle.
#   *   whatever the headless session exited with (124 if the 55m timeout fired)

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
# `#!/usr/bin/env ruby` stdlib scripts, so the system ruby at /usr/bin/ruby
# (the eselect default, currently ruby34 / 3.4.10) satisfies them completely.
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
STATE_DIR="${REPO}/ai-artifacts/shipwright"
LOG_DIR="${STATE_DIR}/runs"
LOCK="${STATE_DIR}/run.lock"
SKIP_COUNT="${STATE_DIR}/consecutive-skips"
# How many consecutive dirty-tree skips before a skip becomes a loud failure
# rather than a quiet exit 0. Six = six hourly ticks.
SKIP_ESCALATE="${SHIPWRIGHT_SKIP_ESCALATE:-6}"
# Validate it. A non-numeric value makes the `-ge` test below error out, and
# because that test sits in an `if` condition the error is exempt from `set -e`:
# the script falls straight through to the quiet exit 0, disabling the
# wedged-lane escalation forever with nothing but a shell diagnostic to show for
# it. That is the "a wedged lane must not look like a quiet one" invariant
# defeated by a typo, so fall back to the default loudly rather than degrade
# into silence.
case "${SKIP_ESCALATE}" in
  ''|*[!0-9]*|0)
    echo "athena-shipwright: SHIPWRIGHT_SKIP_ESCALATE='${SKIP_ESCALATE}' is not a positive integer; using 6." >&2
    echo "  Fix: set SHIPWRIGHT_SKIP_ESCALATE to a positive whole number of consecutive skips (or unset it to accept the default 6). Left unfixed, the wedged-lane escalation would never fire." >&2
    SKIP_ESCALATE=6 ;;
esac

mkdir -p "${LOG_DIR}"

BRIEF="You are coordinating; do the work by delegating. Spawn exactly one \
athena-shipwright agent (Agent tool, subagent_type: athena-shipwright) with \
this brief, and do nothing else yourself: 'Run your full retrospective now. \
Sync ~/dev/custom with its remote first (pull), mine every coordination \
artifact newer than your cursor, apply harness improvements per your Method, \
gate, and invariants, commit each change locally, push your commits, and \
update your journal and cursor.' When it finishes, relay its one-line summary \
verbatim and stop."

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

# Skip rather than queue if a run is already in flight.
#
# SCOPE, stated plainly because it was misread once: this lock guards THIS
# SCRIPT, not the repository. It serialises cron-vs-cron. A shipwright agent
# invoked directly — as happened at 21:00 on 2026-09-18, concurrently with the
# cron run — never passes through here and never touches this lock, so
# cron-vs-agent is NOT covered. Do not read a held lock as "nobody else is
# writing to ~/dev/custom". What protects the repo from a concurrent writer is
# entry-point-independent by design: athena-shipwright-commit.sh commits
# pathspec-limited, whichever way the agent was started. A repository-level lock
# (one every writer must take, not one per entry point) is the real fix and is
# deliberately NOT attempted here — a half-measure that looks like it covers the
# agent path would stop people looking for the hole.
#
# The lock FILE legitimately outlives a run: flock(2) lives on the open
# descriptor, so an empty, apparently-stale run.lock sitting there is normal and
# says nothing about whether a run is live. Do not "clean it up" — deleting it
# while a run holds it gives the next invocation a fresh inode and a lock that
# excludes nobody, which is the one way to actually get two cron runs at once.
#
# The lock file also RECORDS ITS HOLDER. It used to be zero-byte with no pid and
# no timestamp, so nothing could tell a live holder from a leftover file — and
# on 2026-09-18 someone reasonably concluded it was stale and deleted it by
# hand. A lock that cannot be validated is a lock that gets deleted by the next
# person who finds it inconvenient, and deleting a HELD one is the one way to
# actually get two runs at once. The contents are advisory (flock(2) lives on
# the descriptor, not the bytes); they exist so a human or agent can answer
# "is this real?" without guessing.
# `9>>` and not `9>`: opening for plain write TRUNCATES, so a contending tick
# would erase the holder record before it could read it — the provenance would
# be write-only and the message below would always come up empty.
exec 9>>"${LOCK}"
if ! flock -n 9; then
  holder="$(cat "${LOCK}" 2>/dev/null || true)"
  echo "athena-shipwright: a run is already in progress; skipping this tick." >&2
  if [ -n "${holder}" ]; then
    echo "  holder: ${holder}" >&2
  fi
  echo "  Fix: nothing to do — the in-flight run finishes on its own and the next tick proceeds. To confirm the holder is alive, check the pid above (or 'fuser -v ${LOCK}'). Do NOT delete the lock file: it is held on an open descriptor, so its presence alone never means stale, and removing it while a run holds it hands the next tick a fresh inode and a lock that excludes nobody." >&2
  exit 0
fi

# Record who holds it, for the message above in the NEXT tick. Written to the
# PATH rather than to fd 9 (which is append-mode now), so each run replaces the
# previous holder's line instead of growing the file forever. We hold the lock,
# so truncating it here races with nobody.
printf 'pid=%s host=%s started=%s\n' "$$" "$(hostname 2>/dev/null || echo '?')" "$(date -Is)" >"${LOCK}"


cd "${REPO}"

ts="$(date +%Y-%m-%dT%H%M%S)"
log="${LOG_DIR}/${ts}.log"

# --- the yield guard: never start a run on top of someone else's dirt --------
#
# On 2026-09-18T21:03:07 a run fired while another agent was mid-edit in this
# checkout and swept its unrelated work (hyprland.conf + a 230-line .bak) into
# commit ce70e04, a commit whose message is entirely about harness-gate
# self-tests. athena-shipwright-commit.sh now makes each commit
# pathspec-limited, which removes that sweep. This guard addresses the SECOND,
# independent hazard that narrowing the staging does not touch: the run's first
# act is `git pull --rebase --autostash`, which stashes and re-applies a
# concurrent editor's uncommitted work underneath them, and can fail to re-apply
# it cleanly. An autonomous committer has no business rebasing a tree somebody
# else is typing in.
#
# So: dirt of ANY kind (tracked modifications or untracked files — the .bak was
# untracked) means a human or another agent is active here, and this hourly loop
# yields the tick. Skipping costs an hour; the alternative cost is somebody
# else's uncommitted work.
#
# ai-artifacts/ is excluded EXPLICITLY rather than trusted to an ignore rule.
# It holds this machine's runtime artifacts — including the runner's own logs,
# run.lock and the .skipped records written below — and it is gitignored only by
# the user's MACHINE-LOCAL ~/.config/git/gitignore, which is not in this
# repository. Leaning on that would mean the runner's own output counts as dirt
# wherever that rule is absent (a fresh clone, another machine, a worktree with
# a different exclude file), and then every tick yields at exit 0 forever with
# nobody able to tell a wedged lane from a quiet one: the same invisible-failure
# class as the settings.json clobber this repo documents. The exclusion is
# asserted by the self-test, in a fixture that deliberately has no ignore rule.
#
# Sampling caveat, stated so nobody over-trusts this: the check happens once, at
# run start. Someone who begins editing AFTER the sample and before the agent's
# `git pull --rebase --autostash` is not protected by it. The guarantee that
# does not depend on timing is athena-shipwright-commit.sh's pathspec limit.
#
# A long-lived stray file will wedge the lane until it is dealt with. That is
# intended, and it is made VISIBLE rather than left to be inferred: each skip
# goes to stderr (cron mails it) and leaves a .skipped record beside the run
# logs, and after SHIPWRIGHT_SKIP_ESCALATE consecutive skips the script exits
# non-zero so a wedged lane stops looking like a quiet one. Environment:
# SHIPWRIGHT_ALLOW_DIRTY=1 is the deliberate override for a human who knows the
# dirt is inert.
if [ "${SHIPWRIGHT_ALLOW_DIRTY:-0}" != "1" ]; then
  # -uall so an untracked directory is listed as its files (and so the
  # ai-artifacts exclusion below cannot be defeated by a collapsed `?? dir/`
  # line); paths only, since that is what the message needs.
  # core.quotePath=false so a path with a non-ASCII byte is emitted raw rather
  # than C-quoted as "ai-artifacts/..." — a quoted path would slip the exclusion
  # below and wedge the lane on the shipwright's own output.
  dirty="$(git -c core.quotePath=false status --porcelain -uall | cut -c4- | grep -v '^ai-artifacts/' || true)"
  if [ -n "${dirty}" ]; then
    skipped="${LOG_DIR}/${ts}.skipped"
    {
      echo "athena-shipwright: skipped run ${ts} — ${REPO} has uncommitted changes."
      echo "${dirty}"
    } >"${skipped}"
    echo "athena-shipwright: skipping run ${ts}; ${REPO} is dirty, so a human or another agent is working in it." >&2
    printf '%s\n' "${dirty}" >&2
    echo "  Fix: commit, stash, or remove the paths listed above (they are not the shipwright's — its own state under ai-artifacts/ is excluded from this check), and the next hourly tick proceeds on its own. To run anyway when you know the dirt is inert, re-run with SHIPWRIGHT_ALLOW_DIRTY=1. Record: ${skipped}" >&2

    # A WEDGED LANE MUST NOT LOOK LIKE A QUIET ONE. One skip is routine; N in a
    # row means a stray file (an editor swap file, an abandoned .bak) has
    # stopped the shipwright indefinitely, and the only evidence of that is a
    # quiet stderr line an hour apart. Past the threshold we exit NON-ZERO, so
    # the failure is loud in cron mail and to anything watching exit codes,
    # instead of an exit 0 that is indistinguishable from a healthy lane with
    # nothing to do. The counter resets the moment a run actually starts.
    skips=0
    [ -r "${SKIP_COUNT}" ] && skips="$(cat "${SKIP_COUNT}" 2>/dev/null || echo 0)"
    case "${skips}" in ''|*[!0-9]*) skips=0 ;; esac
    skips=$(( skips + 1 ))
    printf '%s\n' "${skips}" >"${SKIP_COUNT}"

    if [ "${skips}" -ge "${SKIP_ESCALATE}" ]; then
      echo "athena-shipwright: WEDGED — ${skips} consecutive ticks skipped on a dirty tree. The lane has not run since the first of them." >&2
      echo "  Fix: this is no longer a passing editor — deal with the paths above (commit, stash or delete them). They are most likely an abandoned stray rather than live work. Then the next tick runs on its own; nothing here needs restarting. Raise SHIPWRIGHT_SKIP_ESCALATE to tolerate more consecutive skips before this fires." >&2
      exit 75
    fi
    exit 0
  fi
fi

# A run is actually starting: the lane is not wedged.
rm -f "${SKIP_COUNT}"

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

echo "athena-shipwright: run ${ts} exited ${status}; log: ${log}" >&2
exit "${status}"
