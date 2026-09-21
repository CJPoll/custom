#!/usr/bin/env bash
#
# athena-shipwright-commit.sh — the ONLY sanctioned way the athena-shipwright
# agent commits to ~/dev/custom.
#
# WHY THIS EXISTS
#
# The shipwright is an autonomous committer running on an hourly cron in a repo
# a human (or another agent) may be editing at the same moment. On
# 2026-09-18T21:03:07 a run staged the WHOLE worktree and swept a concurrent
# agent's unrelated in-flight work — an edit to hypr/hyprland.conf plus a
# 230-line .bak file — into commit ce70e04, whose message is entirely about
# harness-gate self-tests. Nothing was lost, but only because the other agent
# happened to notice.
#
# The hazard is not the schedule; it is whole-worktree staging. This script
# removes it structurally:
#
#   * it REFUSES to run without an explicit path list (there is no "everything"
#     argument — `-A`, `--all`, `.` and `:/` are rejected outright);
#   * it stages only those paths; and
#   * it commits PATHSPEC-LIMITED (`git commit -- <paths>`), so even content
#     another session staged into the index between our `add` and our `commit`
#     cannot ride along. That ordering race is the reason the pathspec is
#     repeated on the commit rather than trusting the index we just built.
#
# Foreign dirt found at commit time is REPORTED, never touched and never a
# reason to abort: aborting here would throw away a run's real work, while the
# pathspec limit already makes the commit safe. Yielding to a concurrent editor
# is decided one level up, before any work starts, by the preflight in
# athena-shipwright-run.sh.
#
# Usage:
#   athena-shipwright-commit.sh -m <message> -- <path>...
#   athena-shipwright-commit.sh -F <message-file|-> -- <path>...
#   athena-shipwright-commit.sh --dry-run -m <msg> -- <path>...   # show, commit nothing
#   athena-shipwright-commit.sh --self-test
#
# Exit codes:
#   0  committed (or --dry-run printed a plan)
#   1  git itself failed (it refused the commit, e.g. a hook rejected it; or the
#      worktree status could not be read, so neither check below could be run)
#   2  usage / validation error (no paths, a catch-all pathspec, a path outside
#      the repo, a path git does not know and that does not exist)
#   3  the named paths contain nothing to commit
#
# Every non-zero path prints a `Fix:` line: these messages are read by an agent,
# so they say what to do next, not merely what went wrong.

set -uo pipefail

PROG="$(basename -- "$0")"

die() {
  # die <exit-code> <message> <fix>
  printf '%s: %s\n' "$PROG" "$2" >&2
  printf '  Fix: %s\n' "$3" >&2
  exit "$1"
}

usage() {
  # Range ends at the blank comment line AFTER the exit codes, so --help does
  # not stop on a bare "Exit codes:" header with the codes cut off.
  sed -n '/^# Usage:/,/^# Every non-zero path prints/p' -- "$0" | sed 's/^# \{0,1\}//'
}

# --- self-test dispatch ------------------------------------------------------
# First argument only. Scanning all of "$@" would let a message or a path that
# happens to read `--self-test` hijack the run.
if [ "${1:-}" = "--self-test" ]; then
  HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  exec bash "${HERE}/test/athena-shipwright/self-test.sh"
fi

MSG=""
MSG_FILE=""
DRY_RUN=0
PATHS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message)
      [ $# -ge 2 ] || die 2 "-m needs a message." "Pass the commit message: -m 'subject' -- <path>..."
      MSG="$2"; shift 2 ;;
    -F|--file)
      [ $# -ge 2 ] || die 2 "-F needs a file." "Pass a message file (or - for stdin): -F msg.txt -- <path>..."
      MSG_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; PATHS=("$@"); break ;;
    *)
      die 2 "unexpected argument '$1' before '--'." \
        "Put the commit message in -m/-F and every path AFTER a '--' separator: $PROG -m 'msg' -- ai/agents/foo.md.in" ;;
  esac
done

if [ -n "$MSG" ] && [ -n "$MSG_FILE" ]; then
  die 2 "-m and -F are mutually exclusive." "Pass the message one way only: either -m 'subject' or -F msg.txt."
fi
if [ -z "$MSG" ] && [ -z "$MSG_FILE" ]; then
  die 2 "no commit message." "Pass one: -m 'subject line' (or -F msg.txt for a multi-paragraph message)."
fi

if [ "${#PATHS[@]}" -eq 0 ]; then
  die 2 "no paths given — this script never stages the whole worktree." \
    "List every path this concern actually changes, after '--': $PROG -m 'msg' -- ai/agents/x.md.in ai/agents/x.md. If you do not know the list, run 'git status --porcelain' and name the paths YOUR change touched; anything else in that output belongs to someone else."
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || \
  die 2 "not inside a git worktree (cwd: $(pwd))." "cd into the repo the shipwright owns (~/dev/custom) before committing."

# Resolve the caller's paths against the CALLER's cwd before moving to the root.
# Otherwise `-- CLAUDE.md` run from scripts/ would silently commit the ROOT
# CLAUDE.md: this repo tracks that basename at seven different paths, so the
# existence check would pass and the wrong file would be committed with exit 0
# and no warning — a miss the caller cannot see.
PREFIX="$(git rev-parse --show-prefix)"

# The MESSAGE FILE needs the same treatment, for the same reason: git resolves
# `-F` against ITS cwd, which is the repo root after the cd below. A relative
# -F given from a subdirectory would otherwise read a DIFFERENT file if one of
# that name exists at the root — a commit carrying somebody else's text, exit 0
# — or die with a "git commit failed" message pointing at hooks and permissions.
if [ -n "$MSG_FILE" ] && [ "$MSG_FILE" != "-" ]; then
  case "$MSG_FILE" in
    /*) : ;;
    *)  MSG_FILE="$(pwd)/${MSG_FILE}" ;;
  esac
  [ -r "$MSG_FILE" ] || \
    die 2 "message file '$MSG_FILE' is not readable." "Check the path (it is resolved against the directory you ran this from, not the repo root) and re-run."
fi

if [ -n "$PREFIX" ]; then
  resolved=()
  for p in "${PATHS[@]}"; do
    case "$p" in
      -*|:*|/*) resolved+=("$p") ;;   # left as-is; the validator below refuses these
      *)        resolved+=("${PREFIX}${p}") ;;
    esac
  done
  PATHS=("${resolved[@]}")
fi

cd -- "$REPO_ROOT" || die 2 "cannot cd to repo root '$REPO_ROOT'." "Check the repo is readable and re-run."

# --- validate every pathspec -------------------------------------------------
#
# The catch-alls are rejected by name rather than by effect: an agent reaching
# for `.` is reaching for the behaviour this script exists to remove, and a
# message that says so is more useful than a commit that quietly includes
# somebody else's file.
VALIDATED=()
for p in "${PATHS[@]}"; do
  case "$p" in
    ""|.|..|-A|--all|-a|/*|'*'|'./')
      die 2 "refusing catch-all or non-repo-relative pathspec '$p'." \
        "Name the individual files this concern changes, repo-relative (e.g. ai/agents/athena-shipwright.md.in). Whole-worktree staging is exactly the hazard this script removes: it swept an unrelated agent's work into commit ce70e04." ;;
  esac
  # Magic pathspecs are rejected as a CLASS, by their leading ':', not by
  # enumerating spellings. ':/' , ':(top)', ':(glob)**' and the exclude-only
  # ':!x' all mean "everything" to git, and a refusal list naming three of them
  # protects only against the three somebody thought of.
  case "$p" in
    :*)
      die 2 "refusing magic pathspec '$p'." \
        "Pass a plain repo-relative file path, not a git pathspec expression. ':/', ':(top)', ':(glob)**' and ':!x' all resolve to the whole repo, which is the hazard this script exists to remove." ;;
  esac
  case "$p" in
    */../*|../*|*/..)
      die 2 "pathspec '$p' escapes the repo with '..'." \
        "Use a path relative to the repo root ($REPO_ROOT), with no '..' segments." ;;
  esac
  # A GLOB is a catch-all wearing a filename. `ai/*`, `ai/**` and `ai/agents/*.md`
  # pass every other check here — not literal catch-alls, not `:`-prefixed, no
  # `..`, not `-d`, and `git ls-files --error-unmatch -- 'ai/*'` exits 0 — and
  # then `git add -- 'ai/*'` stages every dirty file under ai/, bystander work
  # included. Rejected by the wildcard characters themselves, as a class. (A
  # bare `*` reaching here from a subdirectory has already become `scripts/*`
  # via the prefix rewrite, which is exactly why this check keys on the
  # metacharacters and not on the whole-string spelling.)
  case "$p" in
    *'*'*|*'?'*|*'['*)
      die 2 "refusing glob pathspec '$p' — a glob is a catch-all." \
        "Name each file individually. 'git add -- $p' stages every dirty file the glob matches, including work that is not yours; 'git status --porcelain -- $p' lists what that would be. If a filename genuinely contains one of * ? [, commit it by hand." ;;
  esac
  # A DIRECTORY is a catch-all too, and the dangerous one: `git add -- hypr`
  # would have staged hypr/hyprland.conf AND the untracked .bak in the very
  # incident this script exists to prevent, with the foreign-dirt notice staying
  # silent because those paths are inside the requested set. Rejected as a class
  # (`-d`), not by naming directories — the same reasoning as the magic
  # pathspecs above.
  if [ -d "$p" ]; then
    die 2 "refusing directory pathspec '$p' — a directory is a catch-all." \
      "Name the individual files inside it that this concern changes. 'git add -- $p' would stage everything dirty beneath it, including work that is not yours; 'git status --porcelain -- $p' lists what that would be."
  fi
  # `-d` above reads on-disk state, which is not the same question as what the
  # pathspec MATCHES. A directory whose files have been deleted from disk is not
  # `-d`, is not `-e`, and still resolves to every file tracked beneath it — so
  # `git add -- ai/agents` after an `rm -r` would stage every deletion under it,
  # a bystander's `rm` included, with the foreign-dirt notice silent because
  # those paths sit inside the requested set. Ask git what the pathspec means
  # instead: anything that resolves to tracked content other than exactly itself
  # is a catch-all, whatever it looks like on disk.
  #
  # Read the match with -z and core.quotePath=false: git's default output
  # C-QUOTES any path with a non-ASCII or unusual byte (`"ai/na\303\257ve.md"`),
  # and comparing a raw argument against a quoted path would refuse perfectly
  # ordinary files. Normalize the caller's spelling too — `./x` and `a/./b` are
  # the same file as `x` and `a/b`, and an LLM emits `./x` routinely. A guard
  # that refuses a correct path with "name each file individually", which the
  # caller just did, gives an autonomous agent no way to self-correct; its most
  # likely fallback is the `git commit -a` this whole script exists to remove.
  n=0
  matched=""
  while IFS= read -r -d '' f; do
    n=$(( n + 1 ))
    matched="$f"
  done < <(git -c core.quotePath=false ls-files -z -- "$p")

  norm="$(printf '%s' "$p" | sed -e 's|^\./||' -e 's|/\./|/|g' -e 's|//*|/|g')"

  if [ "$n" -gt 1 ]; then
    die 2 "refusing pathspec '$p' — it matches ${n} tracked files, not one." \
      "Name each file individually. This resolves to a whole subtree (often a directory whose files are deleted from disk, which is why it does not look like a directory); 'git ls-files -- $p' lists exactly what it would take in."
  fi
  if [ "$n" -eq 1 ] && [ "$matched" != "$norm" ]; then
    die 2 "refusing pathspec '$p' — it resolves to '${matched}', which is not the path you wrote." \
      "Pass that file's own path instead: '${matched}'."
  fi
  if [ ! -e "$p" ] && ! git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    die 2 "pathspec '$p' is neither on disk nor tracked by git." \
      "Check the spelling and that it is relative to the repo root ($REPO_ROOT). To commit a deletion, the path must still be tracked ('git ls-files -- $p')."
  fi
  # Carry the NORMALIZED spelling forward, so the status comparisons below and
  # the messages the caller reads all speak git's canonical path rather than
  # whatever './' form was typed.
  VALIDATED+=("$norm")
done
PATHS=("${VALIDATED[@]}")

# --- report (do not touch) anything dirty outside our path set ---------------
#
# This is a SET DIFFERENCE of paths, not a subtraction of two line counts.
# Counting would lie: `git status --porcelain` collapses an untracked directory
# into a single `?? dir/` line, while the same command WITH a pathspec lists the
# files inside it — so two new files under one new directory can drive a count
# difference to zero and silently suppress the notice while a bystander's file
# is genuinely dirty. `-uall` on both sides expands untracked directories
# consistently, and comparing the path sets removes the question entirely.
# The notice is the only signal that says "someone else is mid-edit here", so it
# must not be able to read clean when it is not.
# core.quotePath=false for the same reason the validator uses it: git C-quotes
# a path with an unusual byte, and a quoted path would slip the ai-artifacts
# exclusion below and sit in the notice forever.
status_paths() { git -c core.quotePath=false status --porcelain -uall "$@" | cut -c4- | sort -u; }

#
# ai-artifacts/ is excluded from the FOREIGN side for the same reason the
# runner's yield guard excludes it: it holds this machine's runtime artifacts,
# including the runner's own logs, run.lock, .skipped and consecutive-failures
# files, and it is gitignored only by the user's machine-local
# ~/.config/git/gitignore, which is not in this repository. Without this, every
# commit on a checkout lacking that rule would list the shipwright's own output
# as "dirty outside this commit" — permanent noise in the one signal that is
# supposed to mean "someone else is mid-edit here", which is how a real notice
# gets learned-past. It is excluded from the foreign side only, never from
# `ours_dirty`, so naming such a path still behaves normally rather than
# silently reading as "nothing to commit".
# `status_paths` is the ONLY instrument behind both the foreign-dirt notice and
# the nothing-to-commit refusal, and `set -uo pipefail` above makes it report a
# git failure — but ONLY if the caller looks. Reading it through `<(...)` throws
# that status away: the scan delivers an EMPTY stream, `comm` finds no foreign
# paths, and the notice the comment above calls "the only signal that says
# someone else is mid-edit here" simply does not print. Measured 2026-09-21 with
# a `git status` stubbed to exit 128 — a genuinely dirty bystander file produced
# no notice and exit 0, which is this repo's *A failed lookup must never look
# like an empty one* aimed squarely at this script's own guarantee. (Same class
# as the `|| true` on a `git ls-files` outside-scope scan that a captain removed
# from gen_saas the same day: a broken scan had read as "nothing outside".)
#
# So each scan is run into a VARIABLE and its status is checked, keeping "could
# not look" textually distinct from "found nothing". Note this aborts on a
# BROKEN SCAN, never on foreign dirt — dirt found is still only reported, per
# the header. If git cannot be read, the `add`/`commit` below would fail anyway;
# what this buys is a message carrying a `Fix:` instead of a silent miss.
if ! ours_status="$(status_paths -- "${PATHS[@]}")"; then
  die 1 "could not read the worktree status for the named paths (git failed); neither the foreign-dirt notice nor the nothing-to-commit check could be run." \
    "This is NOT 'nothing to commit' — nothing was measured. Run 'git status --porcelain -uall -- ${PATHS[*]}' here and fix what it reports (a stale index.lock from a concurrent session is the usual cause), then re-run."
fi
if ! all_status="$(status_paths)"; then
  die 1 "could not read the worktree status for the whole tree (git failed), so the foreign-dirt notice cannot be trusted to be silent." \
    "This is NOT 'no one else is mid-edit' — nothing was measured. Run 'git status --porcelain -uall' here and fix what it reports (a stale index.lock from a concurrent session is the usual cause), then re-run."
fi

# `emit` replays a captured scan as lines. It drops blank lines so that an EMPTY
# capture feeds `comm` an empty stream rather than the single blank line
# `printf '%s\n' ""` would produce — a blank line present on one side only would
# sort ahead of every path and read as a foreign entry named "".
emit() { printf '%s' "$1" | grep -v '^$' || true; }

ours_dirty="$(emit "$ours_status" | grep -c . || true)"
foreign="$(comm -23 <(emit "$all_status" | grep -v '^ai-artifacts/') <(emit "$ours_status"))"

if [ -n "$foreign" ]; then
  printf '%s: note: these paths are dirty outside this commit and are being left alone:\n' "$PROG" >&2
  printf '%s\n' "$foreign" | sed 's/^/    /' >&2
  printf '  Fix: nothing to do here — the commit below is pathspec-limited and cannot include them. If they are YOURS, commit them as their own concern with their own message.\n' >&2
fi

if [ "$ours_dirty" -eq 0 ]; then
  die 3 "nothing to commit in the named paths." \
    "Either the change was already committed, or you named the wrong paths. Run 'git status --porcelain -- ${PATHS[*]}' to see; re-run with the paths that actually differ."
fi

# --- stage, then commit pathspec-limited ------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  printf '%s: would commit exactly these paths:\n' "$PROG"
  # -uall via status_paths, so dry-run is not NARROWER than the real commit (a
  # plain status collapses an untracked directory into one `?? dir/` line).
  status_paths -- "${PATHS[@]}"
  exit 0
fi

# The `add` is REQUIRED, not redundant with the pathspec on the commit below: an
# untracked path is not committable until it is in the index, so removing this
# would break every new-file commit. What it is NOT is the thing that scopes the
# commit — the pathspec on `git commit` does that, and `git commit -- <paths>`
# takes those paths from the WORKTREE regardless of the index. There is
# deliberately no -A/-u here: the pathspec is the scope.
# Exit 1, not 2: validation already passed, so a failure here is git's (a
# permission problem, a hook, a broken index), the same class as the commit
# failure below. Reserving 2 for "the caller passed bad arguments" is what lets
# a wrapper branch on it correctly.
git add -- "${PATHS[@]}" || \
  die 1 "git add failed for the named paths." "Read git's error above. This is a git-level failure, not a bad path list — check permissions, a running index.lock, or a pre-commit hook."

commit_args=()
if [ -n "$MSG_FILE" ]; then
  commit_args=(-F "$MSG_FILE")
else
  commit_args=(-m "$MSG")
fi

# The repeated pathspec is the load-bearing part: `git commit -- <paths>`
# commits ONLY those paths, whatever else is sitting in the index.
if ! git commit "${commit_args[@]}" -- "${PATHS[@]}"; then
  die 1 "git commit failed." "Read git's error above. If a hook rejected the commit, fix the content rather than bypassing the hook."
fi

git --no-pager log -1 --format='%s' | sed "s/^/${PROG}: committed: /" >&2
exit 0
