#!/usr/bin/env bash
# Self-test for scripts/athena-shipwright-commit.sh and the yield/lock guards in
# scripts/athena-shipwright-run.sh.
#
# Run: bash scripts/test/athena-shipwright/self-test.sh
#      (or: scripts/athena-shipwright-commit.sh --self-test)
#
# Nothing real is touched:
#   * every case builds a THROWAWAY git repo under a mktemp dir and commits
#     there. The real ~/dev/custom is never the cwd of a case.
#   * the runner is exercised with SHIPWRIGHT_REPO pointing at that throwaway
#     repo and SHIPWRIGHT_CLAUDE pointing at a STUB that records its invocation
#     instead of starting a headless session. No `claude` ever runs, so a case
#     cannot cost tokens or touch the network.
#   * the crontab is never read or written — the schedule is not this change's
#     business.
#
# What these cases protect is invisible from the outside, which is why they are
# worth having: a commit that swept in a bystander's file looks exactly like a
# correct commit until someone reads the diff, and a guard that yields on dirt
# looks exactly like a guard that does not until the hour a human is mid-edit.
#
# NOTE: this suite must never invoke `athena-shipwright-commit.sh --self-test` —
# that is the entry point that runs THIS file, and the pair would recurse.

set -uo pipefail
# DND-1163: the athena:inbox bins resolve the session's project from
# CLAUDE_PROJECT_DIR, then /proc/$CLAUDE_PID/cwd, before the cwd. Scrubbed so
# the fixtures, not the Claude session running this suite, decide the project.
unset CLAUDE_PROJECT_DIR CLAUDE_PID

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
COMMIT="${SCRIPTS}/athena-shipwright-commit.sh"
RUNNER="${SCRIPTS}/athena-shipwright-run.sh"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
RUNNER_PID=""
HOLDER_PID=""

cleanup() {
  # Reap by PID only. A `pkill -f` here could match a real shipwright run or a
  # sibling worktree's suite.
  if [ -n "$RUNNER_PID" ]; then
    kill "$RUNNER_PID" 2>/dev/null
    wait "$RUNNER_PID" 2>/dev/null
  fi
  # The live-lane-never-reaped case holds an flock in a background process; make
  # sure a failed case never leaves it running past the suite.
  if [ -n "$HOLDER_PID" ]; then
    kill "$HOLDER_PID" 2>/dev/null
    wait "$HOLDER_PID" 2>/dev/null
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

# THE INBOX IS PINNED FOR THE WHOLE SUITE (DND-692). A stale-dirt streak makes
# the runner send ONE harness-alert through send-mail, which delivers under
# $ATHENA_INBOX_ROOT. Left unset, a case would write into the machine's LIVE
# harness-alerts channel and wake the real attendant. So the root is a temp dir
# for every case, set before the first runner call, and it carries the
# COMMITTED custom registry entry re-keyed to this checkout's git common dir
# (send-mail resolves a channel from the entry of its cwd's repo). The suite
# refuses to go on if the pin did not take.
export ATHENA_INBOX_ROOT="${TMP}/inbox-root"
# THE POST-LANDING MAIN CHECK IS STUBBED FOR THE WHOLE SUITE (DND-1482). Every
# tick runs ai/bin/main-health check, which fetches and may run a harness gate;
# against a fixture repo that is never wanted. The stub records its argv in
# MH_STUB_LOG and exits MH_STUB_RC (default 0).
MH_STUB="${TMP}/stub-main-health"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${MH_STUB_LOG:-/dev/null}"\nexit "${MH_STUB_RC:-0}"\n' > "$MH_STUB"
chmod +x "$MH_STUB"
export SHIPWRIGHT_MAIN_HEALTH="$MH_STUB"
# THE SLACK ROOTS SNAPSHOT IS STUBBED FOR THE WHOLE SUITE TOO (DND-1502). Every
# tick runs ai/bin/slack-roots-tick, which runs judgment-label --propose against
# the machine's real inbox and labels. The stub records its argv in
# SR_STUB_LOG and exits SR_STUB_RC (default 0).
SR_STUB="${TMP}/stub-slack-roots-tick"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${SR_STUB_LOG:-/dev/null}"\necho "stub-slack-roots-tick stderr" >&2\nexit "${SR_STUB_RC:-0}"\n' > "$SR_STUB"
chmod +x "$SR_STUB"
export SHIPWRIGHT_SLACK_ROOTS="$SR_STUB"
unset CLAUDE_AGENT_ID CLAUDE_AGENT_TYPE
REPO_ROOT="$(cd -- "${SCRIPTS}/.." && pwd -P)"
# The git-stub fixtures below delegate to the REAL git, never the agent PATH
# wrapper (DND-1103). A miss stops the suite: a stub with no git.real would let
# the "broken git" cases pass for the wrong reason.
. "${REPO_ROOT}/ai/lib/agent-free-git.sh"
REAL_GIT="$(agent_free_git)" || exit 1
# DND-1667: a guard right behind each git stub dir below, so a stub that is
# missing or not executable fails the suite instead of reaching the real git
# (ai/lib/forge-stub-guard.sh). fsg_make, not fsg_arm: the fixtures run the
# real git.
. "${REPO_ROOT}/ai/lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
INBOX_REGISTRY="${REPO_ROOT}/ai/inbox/registry.json"
install_inbox_registry() { # <root>
  local common
  common="$(cd -- "${REPO_ROOT}" && realpath -- "$(git rev-parse --git-common-dir)")"
  mkdir -p "$1/projects"; chmod 700 "$1" "$1/projects"
  jq --arg r "${common}" '.projects[] | select(.file == "custom.json") | .entry | .repo = $r' \
    "${INBOX_REGISTRY}" >"$1/projects/custom.json"
  chmod 600 "$1/projects/custom.json"
}
install_inbox_registry "${ATHENA_INBOX_ROOT}"
case "${ATHENA_INBOX_ROOT}" in
  "${TMP}"/*) ;;
  *) echo "self-test: ATHENA_INBOX_ROOT is not under ${TMP}; refusing to run cases that could alert the live channel." >&2
     echo "  Fix: this is a bug in the suite's setup; the pin above must run before any case." >&2
     exit 2 ;;
esac

ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
case_() { printf '\n%s\n' "$1"; }

# A fresh repo with one committed file.
#
# The repo lives in its own case directory and every fixture the suite itself
# writes (the stub binary, the runner's captured output, the fifo) lives BESIDE
# the repo, never inside it. A suite that dropped its own scratch files into the
# tree under test would make every case read as "dirty" and silently invert the
# yield-guard cases below — they would pass for the wrong reason.
#
# new_repo runs inside a command substitution, so ONLY the path may reach
# stdout: a stray line of git chatter would become part of the path the caller
# then cds into, and every later case would silently operate on a directory
# that does not exist. Hence the redirects.
new_repo() {
  local c d
  c="$(mktemp -d -p "$TMP" case.XXXXXX)"
  d="${c}/repo"
  mkdir -p "$d"
  git -C "$d" init -q -b main >&2
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name 'Self Test'
  git -C "$d" config commit.gpgsign false
  # Neutralize the user's MACHINE-LOCAL core.excludesFile
  # (~/.config/git/gitignore, which carries `ai-artifacts/`). The fixture has
  # no copy of the repo .gitignore either (which also carries it since
  # DND-1693), and leaving either in play would silently make the
  # "shipwright's own state does not trip its successor" case pass for the wrong
  # reason — testing that machine's config rather than the runner's own explicit
  # exclusion, and passing on this box while the runner wedges on any checkout
  # without that rule.
  git -C "$d" config core.excludesFile /dev/null
  mkdir -p "$d/ai/agents"
  printf 'original\n' >"$d/ai/agents/ours.md"
  printf 'bystander original\n' >"$d/bystander.conf"
  git -C "$d" add -A >&2
  git -C "$d" commit -qm 'seed' >&2
  printf '%s' "$d"
}

# Aux directory for a repo: where the suite's own fixtures live.
aux() { dirname -- "$1"; }

# Every HEALTHY stub must leave the runner's liveness receipt, exactly as a real
# session does on its first instruction. A stub that does not is — correctly — a
# session that never reported for duty, and the runner classifies it BLOCKED
# (exit 69). stub_claude_blocked below is the stub that deliberately omits it.
stub_claude() {
  # $1 = path to create, $2 = exit code. Records that it ran.
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "\$@" >"\$(dirname "\$0")/claude-was-invoked"
[ -n "\${SHIPWRIGHT_RECEIPT:-}" ] && : >"\$SHIPWRIGHT_RECEIPT"
exit $2
EOF
  chmod +x "$1"
}

# A session that dies before it ever reaches the model: prints whatever the
# provider said, exits 0, and touches NOTHING. This is the 2026-09-19 shape.
# The message goes to a fixture file beside the stub, never into the stub's
# source: expanded inside an unquoted heredoc, a message with double quotes in
# it (a vendor's JSON body) lost them, so the case tested a different string
# from the one it named.
stub_claude_blocked() { # $1 = path, $2 = message
  stub_claude_blocked_rc "$1" "$2" 0
}
stub_claude_blocked_rc() { # $1 = path, $2 = message, $3 = exit code
  printf '%s\n' "$2" >"$1.msg"
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"\$(dirname "\$0")/claude-was-invoked"
cat -- "\$0.msg"
exit $3
EOF
  chmod +x "$1"
}

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-commit.sh — narrow staging'

# The headline regression: the exact shape of ce70e04. Our file and a
# bystander's file are both dirty; we name only ours.
r="$(new_repo)"
printf 'shipwright edit\n' >"$r/ai/agents/ours.md"
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"           # tracked, modified
printf 'x\n%.0s' $(seq 1 230) >"$r/bystander.conf.bak"   # untracked stray
out="$(cd "$r" && "$COMMIT" -m 'harness: narrow' -- ai/agents/ours.md 2>&1)"
rc=$?
files="$(git -C "$r" show --name-only --format= HEAD | sort | tr '\n' ' ')"
if [ "$rc" -eq 0 ] && [ "$files" = "ai/agents/ours.md " ]; then
  ok "commits exactly the named path (got: ${files% })"
else
  bad "commits exactly the named path" "rc=$rc files='$files' out=$out"
fi
if grep -q 'bystander.conf$' <<<"$(git -C "$r" status --porcelain)" \
   && grep -q '?? bystander.conf.bak' <<<"$(git -C "$r" status --porcelain)"; then
  ok "leaves the bystander's modified file AND untracked stray dirty and uncommitted"
else
  bad "leaves the bystander's work alone" "$(git -C "$r" status --porcelain)"
fi
if grep -q 'dirty outside this commit' <<<"$out"; then
  ok "reports foreign dirt instead of silently absorbing it"
else
  bad "reports foreign dirt" "$out"
fi

# Content another session STAGED between our add and our commit must not ride
# along. This is why the pathspec is repeated on `git commit`, not trusted from
# the index; we simulate the race by pre-staging the bystander's file.
r="$(new_repo)"
printf 'shipwright edit\n' >"$r/ai/agents/ours.md"
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
git -C "$r" add bystander.conf >/dev/null
(cd "$r" && "$COMMIT" -m 'harness: narrow' -- ai/agents/ours.md >/dev/null 2>&1)
files="$(git -C "$r" show --name-only --format= HEAD | tr '\n' ' ')"
if [ "$files" = "ai/agents/ours.md " ]; then
  ok "pre-staged foreign content in the index is NOT committed"
else
  bad "pre-staged foreign content is excluded" "files='$files'"
fi
if grep -q 'bystander.conf' <<<"$(git -C "$r" diff --cached --name-only)"; then
  ok "and that foreign content is left staged exactly as the other session had it"
else
  bad "foreign staged content survives untouched" "$(git -C "$r" status --porcelain)"
fi

# The foreign-dirt notice must survive the shape where naive counting breaks:
# `git status --porcelain` collapses an UNTRACKED DIRECTORY into one `?? dir/`
# line, while the same command with a pathspec lists the files inside it. Two
# new files under one new directory therefore cancel a count-based difference
# out, and the one signal saying "someone else is mid-edit here" reads clean
# while a bystander's file is genuinely dirty — a miss that is invisible from
# the outside, which is why it is asserted here.
r="$(new_repo)"
mkdir -p "$r/ai/new-dir"
printf 'one\n' >"$r/ai/new-dir/a.md"
printf 'two\n' >"$r/ai/new-dir/b.md"
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
out="$(cd "$r" && "$COMMIT" -m 'new dir' -- ai/new-dir/a.md ai/new-dir/b.md 2>&1)"
if grep -q 'bystander.conf' <<<"$out"; then
  ok "the foreign-dirt notice names the bystander even when the commit adds a new untracked directory"
else
  bad "foreign-dirt notice survives the untracked-directory shape" "$out"
fi
files="$(git -C "$r" show --name-only --format= HEAD | sort | tr '\n' ' ')"
if [ "$files" = "ai/new-dir/a.md ai/new-dir/b.md " ]; then
  ok "and that commit still contains exactly the two named new files"
else
  bad "new-directory commit is exact" "files='$files'"
fi

# The commit helper must treat ai-artifacts/ the way the runner does. It holds
# the runner's own logs, run.lock and skip records. The repo .gitignore ignores
# it (DND-1693), but the helper must not lean on that — so on a checkout without
# the rule the foreign-dirt notice would list the shipwright's own output
# forever, which is how a real notice gets learned-past. (core.excludesFile is
# neutralised in every fixture, so this case is not vacuous.)
r="$(new_repo)"
mkdir -p "$r/ai-artifacts/shipwright/runs"
printf 'log\n' >"$r/ai-artifacts/shipwright/runs/2026.log"
printf 'edit\n' >"$r/ai/agents/ours.md"
out="$(cd "$r" && "$COMMIT" -m 'narrow' -- ai/agents/ours.md 2>&1)"
if ! grep -q 'ai-artifacts' <<<"$out"; then
  ok "the shipwright's own runtime artifacts are not reported as foreign dirt"
else
  bad "ai-artifacts excluded from the foreign-dirt notice" "$out"
fi
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
printf 'edit2\n' >"$r/ai/agents/ours.md"
out="$(cd "$r" && "$COMMIT" -m 'narrow again' -- ai/agents/ours.md 2>&1)"
if grep -q 'bystander.conf' <<<"$out"; then
  ok "and a real bystander is still reported alongside them"
else
  bad "real dirt still reported with ai-artifacts present" "$out"
fi

# A single-file directory deleted from disk: the count is 1, but it is not the
# path that was written, so an equality check is what catches it (a >1 count
# check alone would let this through).
r="$(new_repo)"
mkdir -p "$r/solo"
printf 'x\n' >"$r/solo/only.txt"
git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm 'solo' >/dev/null 2>&1
rm -rf "$r/solo"
o="$(cd "$r" && "$COMMIT" -m msg -- solo 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'Fix:' <<<"$o"; then
  ok "a deleted directory holding exactly one file is still refused"
else
  bad "single-file deleted directory is refused" "rc=$rc out=$o"
fi
if [ "$(git -C "$r" rev-list --count HEAD)" = "2" ]; then
  ok "and that refusal committed nothing"
else
  bad "no commit from that refusal" "$(git -C "$r" log --oneline)"
fi

# A deletion of a named path is a change like any other.
r="$(new_repo)"
rm "$r/ai/agents/ours.md"
(cd "$r" && "$COMMIT" -m 'harness: drop' -- ai/agents/ours.md >/dev/null 2>&1)
if [ "$(git -C "$r" show --name-status --format= HEAD | tr -d '\n')" = "D	ai/agents/ours.md" ]; then
  ok "commits a deletion of a named path"
else
  bad "commits a deletion" "$(git -C "$r" show --name-status --format= HEAD)"
fi

# Multiple named paths (the .md.in + rebuilt .md pair the shipwright always has).
r="$(new_repo)"
printf 'a\n' >"$r/ai/agents/ours.md"
printf 'b\n' >"$r/ai/agents/ours.md.in"
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
(cd "$r" && "$COMMIT" -m 'pair' -- ai/agents/ours.md ai/agents/ours.md.in >/dev/null 2>&1)
files="$(git -C "$r" show --name-only --format= HEAD | sort | tr '\n' ' ')"
if [ "$files" = "ai/agents/ours.md ai/agents/ours.md.in " ]; then
  ok "commits several named paths together, still excluding the bystander"
else
  bad "commits several named paths" "files='$files'"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-commit.sh — refusals (each with a Fix: line)'

refuses() { # refuses <label> <expected-rc> <args...>
  local label="$1" want="$2"; shift 2
  local o rc
  o="$(cd "$r" && "$COMMIT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    bad "$label" "rc=$rc (want $want) out=$o"; return
  fi
  if ! grep -q 'Fix:' <<<"$o"; then
    bad "$label (no Fix: line — a guard message must tell the agent how to self-correct)" "$o"; return
  fi
  ok "$label"
}

r="$(new_repo)"
printf 'shipwright edit\n' >"$r/ai/agents/ours.md"
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"

refuses "no paths at all is refused (there is no 'everything' mode)" 2 -m msg --
refuses "'.' is refused by name"                                    2 -m msg -- .
refuses "'-A' is refused by name"                                   2 -m msg -- -A

# MAGIC pathspecs are the interesting case, not the plain strings above: each of
# these means "everything" to git, each passes `git ls-files --error-unmatch`,
# and a refusal list that enumerated spellings would let the ones nobody thought
# of straight through.
refuses "':/' (whole repo) is refused"                              2 -m msg -- :/
refuses "':(top)' — the long form of ':/' — is refused"             2 -m msg -- ':(top)'
refuses "':(glob)**' (whole repo by glob) is refused"               2 -m msg -- ':(glob)**'
refuses "':!nothing' (exclude-only, i.e. everything else) is refused" 2 -m msg -- ':!nothing'
refuses "':(exclude)nothing' is refused"                            2 -m msg -- ':(exclude)nothing'
# A GLOB is a catch-all wearing a filename: 'ai/*' is not a literal catch-all,
# is not ':'-prefixed, holds no '..', is not a directory, and satisfies
# 'git ls-files --error-unmatch' — so without a class-level check it stages
# every dirty file under ai/.
refuses "a glob ('ai/*') is refused"                                2 -m msg -- 'ai/*'
refuses "a recursive glob ('ai/**') is refused"                     2 -m msg -- 'ai/**'
refuses "an extension glob ('ai/agents/*.md') is refused"           2 -m msg -- 'ai/agents/*.md'
refuses "a '?' wildcard is refused"                                 2 -m msg -- 'ai/agents/ours.m?'
refuses "a character class ('[abc]') is refused"                    2 -m msg -- 'ai/agents/ours.m[d]'

# A DIRECTORY is the catch-all that looks most like a legitimate path, and the
# one that reproduces the original incident exactly: `git add -- hypr` would
# have staged hyprland.conf and the untracked .bak together.
refuses "a directory argument is refused"                           2 -m msg -- ai
refuses "a nested directory argument is refused"                    2 -m msg -- ai/agents
refuses "a trailing-slash directory is refused"                     2 -m msg -- ai/
refuses "an absolute path is refused"                               2 -m msg -- /etc/passwd

# The directory case that on-disk checks MISS: after the files are removed, the
# path is neither -d nor -e, yet it still resolves to every tracked file
# beneath it, so a bystander's deletions would be staged with ours. This is the
# deletion flow the script explicitly supports, so the miss is reachable.
rm -rf "$r/ai/agents"
refuses "a directory deleted from disk is still refused (it is not -d, but still matches a subtree)" \
                                                                    2 -m msg -- ai/agents
git -C "$r" checkout -- ai/agents 2>/dev/null || git -C "$r" restore ai/agents 2>/dev/null
refuses "a '..' escape is refused"                                  2 -m msg -- ../outside.txt
refuses "an unknown path is refused"                                2 -m msg -- ai/agents/typo.md
refuses "a missing message is refused"                              2 -- ai/agents/ours.md
refuses "a path before '--' is refused"                             2 -m msg ai/agents/ours.md

# Nothing above may have produced a commit.
if [ "$(git -C "$r" rev-list --count HEAD)" = "1" ]; then
  ok "no refusal path ever created a commit"
else
  bad "refusals create no commits" "$(git -C "$r" log --oneline)"
fi
if [ -z "$(git -C "$r" diff --cached --name-only)" ]; then
  ok "no refusal path ever left anything staged"
else
  bad "refusals stage nothing" "$(git -C "$r" diff --cached --name-only)"
fi

# Naming a clean path is an error, not a no-op: it means the agent named the
# wrong path, and a silent success would hide the real change going uncommitted.
r="$(new_repo)"
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
o="$(cd "$r" && "$COMMIT" -m msg -- ai/agents/ours.md 2>&1)"; rc=$?
if [ "$rc" -eq 3 ] && grep -q 'Fix:' <<<"$o"; then
  ok "a path set with no changes exits 3 with a Fix: line (never commits the dirty bystander instead)"
else
  bad "clean path set exits 3" "rc=$rc out=$o"
fi

# Paths are resolved against the CALLER's cwd, not silently against the repo
# root. This repo tracks the same basename at several depths, so a root-relative
# reinterpretation would commit a DIFFERENT real file, exit 0, and say nothing.
r="$(new_repo)"
printf 'root copy\n' >"$r/NOTES.md"
printf 'nested copy\n' >"$r/ai/agents/NOTES.md"
git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm 'two NOTES.md' >/dev/null 2>&1
printf 'ROOT EDITED - not ours\n' >"$r/NOTES.md"
printf 'nested edited - ours\n' >"$r/ai/agents/NOTES.md"
(cd "$r/ai/agents" && "$COMMIT" -m 'from a subdirectory' -- NOTES.md >/dev/null 2>&1)
files="$(git -C "$r" show --name-only --format= HEAD | tr '\n' ' ')"
if [ "$files" = "ai/agents/NOTES.md " ]; then
  ok "a path given from a subdirectory resolves against that subdirectory, not the repo root"
else
  bad "subdirectory-relative paths resolve correctly" "committed '$files' (the root NOTES.md is a different file and must not be the one committed)"
fi
if grep -q 'NOTES.md' <<<"$(git -C "$r" status --porcelain)"; then
  ok "and the root file of the same name is left dirty and untouched"
else
  bad "root file untouched" "$(git -C "$r" status --porcelain)"
fi

# -F is the form the agent template documents as primary, so it gets the same
# scrutiny as -m. git resolves -F against ITS cwd (the repo root), so a relative
# -F from a subdirectory must be resolved against the CALLER's cwd or it reads a
# different file of the same name and commits somebody else's text at exit 0.
r="$(new_repo)"
printf 'ROOT MESSAGE - wrong one\n' >"$r/msg.txt"
printf 'nested message - the right one\n' >"$r/ai/agents/msg.txt"
printf 'edit\n' >"$r/ai/agents/ours.md"
(cd "$r/ai/agents" && "$COMMIT" -F msg.txt -- ours.md >/dev/null 2>&1)
subj="$(git -C "$r" log -1 --format=%s)"
if [ "$subj" = "nested message - the right one" ]; then
  ok "-F resolves against the caller's directory, not the repo root"
else
  bad "-F resolves against the caller's cwd" "commit subject was '$subj'"
fi

# -F from the root, and the multi-paragraph body the shipwright actually writes.
r="$(new_repo)"
printf 'subject line\n\nbody paragraph\n' >"$(aux "$r")/m.txt"
printf 'edit\n' >"$r/ai/agents/ours.md"
(cd "$r" && "$COMMIT" -F "$(aux "$r")/m.txt" -- ai/agents/ours.md >/dev/null 2>&1)
if [ "$(git -C "$r" log -1 --format=%s)" = "subject line" ] \
   && grep -q 'body paragraph' <<<"$(git -C "$r" log -1 --format=%b)"; then
  ok "-F with an absolute path carries subject and body through"
else
  bad "-F absolute path" "$(git -C "$r" log -1 --format='%s|%b')"
fi

# -F - (stdin) is advertised in the usage block, so it must work.
r="$(new_repo)"
printf 'edit\n' >"$r/ai/agents/ours.md"
(cd "$r" && printf 'from stdin\n' | "$COMMIT" -F - -- ai/agents/ours.md >/dev/null 2>&1)
if [ "$(git -C "$r" log -1 --format=%s)" = "from stdin" ]; then
  ok "-F - reads the message from stdin"
else
  bad "-F - reads stdin" "$(git -C "$r" log -1 --format=%s)"
fi

# An unreadable -F is a caller error (exit 2), not a mysterious git failure.
r="$(new_repo)"
printf 'edit\n' >"$r/ai/agents/ours.md"
o="$(cd "$r" && "$COMMIT" -F no-such-message.txt -- ai/agents/ours.md 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'Fix:' <<<"$o"; then
  ok "an unreadable -F file exits 2 with a Fix: line, before git is involved"
else
  bad "unreadable -F is a caller error" "rc=$rc out=$o"
fi

# --help must reach the exit codes. A usage range that stopped at the "Exit
# codes:" header printed the header and none of the codes — the reader most
# likely to run --help is the one who just got a non-zero exit.
o="$("$COMMIT" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Usage:' <<<"$o" \
   && grep -q 'nothing to commit' <<<"$o"; then
  ok "--help prints usage through the last exit code"
else
  bad "--help is complete" "rc=$rc out=$o"
fi
o="$("$RUNNER" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'SHIPWRIGHT_FAIL_ESCALATE' <<<"$o"; then
  ok "the runner's --help lists the environment knobs its Fix: lines mention"
else
  bad "runner --help" "rc=$rc out=$o"
fi

# Ordinary non-canonical spellings must COMMIT, not be refused. `./x` is a form
# an LLM emits routinely, and git C-quotes any path with a non-ASCII byte — a
# guard that compared the raw argument against that output refused correct paths
# with "name each file individually", which the caller had just done. An
# autonomous agent given no way to self-correct falls back to `git commit -a`,
# the exact thing this script exists to remove, so a false refusal here is worse
# than an ordinary bug.
for spelling in './ai/agents/ours.md' 'ai/./agents/ours.md' 'ai//agents/ours.md'; do
  r="$(new_repo)"
  printf 'edit\n' >"$r/ai/agents/ours.md"
  printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
  o="$(cd "$r" && "$COMMIT" -m 'spelling' -- "$spelling" 2>&1)"; rc=$?
  files="$(git -C "$r" show --name-only --format= HEAD 2>/dev/null | tr '\n' ' ')"
  if [ "$rc" -eq 0 ] && [ "$files" = "ai/agents/ours.md " ]; then
    ok "'$spelling' is accepted and commits the one file it names"
  else
    bad "'$spelling' is accepted" "rc=$rc files='$files' out=$o"
  fi
done

# A non-ASCII filename must work too: git C-quotes it under the default
# core.quotePath, so a comparison against un-normalized output refuses it.
r="$(new_repo)"
printf 'x\n' >"$r/ai/agents/naive-café.md"
git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm 'add accented' >/dev/null 2>&1
printf 'edited\n' >"$r/ai/agents/naive-café.md"
o="$(cd "$r" && "$COMMIT" -m 'accented' -- 'ai/agents/naive-café.md' 2>&1)"; rc=$?
# -c core.quotePath=false when READING back too: git quotes the name by default,
# so an assertion against the raw name would fail for the wrong reason.
files="$(git -C "$r" -c core.quotePath=false show --name-only --format= HEAD | tr '\n' ' ')"
if [ "$rc" -eq 0 ] && [ "$files" = "ai/agents/naive-café.md " ]; then
  ok "a path with a non-ASCII byte is accepted (git C-quotes it; the guard must not)"
else
  bad "non-ASCII path accepted" "rc=$rc files='$files' out=$o"
fi

# --dry-run shows the plan and changes nothing.
r="$(new_repo)"
printf 'shipwright edit\n' >"$r/ai/agents/ours.md"
o="$(cd "$r" && "$COMMIT" --dry-run -m msg -- ai/agents/ours.md 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'ai/agents/ours.md' <<<"$o" \
   && [ "$(git -C "$r" rev-list --count HEAD)" = "1" ] \
   && [ -z "$(git -C "$r" diff --cached --name-only)" ]; then
  ok "--dry-run prints the path set and neither stages nor commits"
else
  bad "--dry-run is inert" "rc=$rc out=$o"
fi

# A BROKEN scan must not read as a clean one. The foreign-dirt notice is the
# only signal that says "someone else is mid-edit here", and it was computed
# through `<(status_paths ...)` — process substitution discards the exit status,
# so a `git status` failure delivered an EMPTY stream, `comm` found nothing, and
# the notice silently did not print while a bystander file was genuinely dirty.
# Measured 2026-09-21: exit 0, no notice, the commit proceeding as if the tree
# were quiet. Same class as the `|| true` on a `git ls-files` outside-scope scan
# a captain removed from gen_saas the same day (GS-DND-234 [guardrail]).
#
# The stub passes every git call through EXCEPT the bare (no-pathspec) status,
# which is the one whose failure used to be invisible.
stub_git_bare_status_fails() { # <dir>
  mkdir -p "$1"
  cat >"$1/git" <<'EOS'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = "status" ]; then
    case " $* " in
      *" -- "*) : ;;
      *) echo "fatal: simulated index failure" >&2; exit 128 ;;
    esac
  fi
done
exec git.real "$@"
EOS
  chmod +x "$1/git"
  ln -sf "${REAL_GIT}" "$1/git.real"   # the real git, not the agent wrapper (DND-1103)
}

r="$(new_repo)"; sdir="$(dirname "$r")/gitstub"
stub_git_bare_status_fails "$sdir"
fsg_require_stubs "$sdir" git
printf 'shipwright edit\n' >"$r/ai/agents/ours.md"
printf 'AGENT MID-EDIT\n'  >"$r/bystander.conf"
o="$(cd "$r" && PATH="$sdir:$FSG_DIR:$PATH" "$COMMIT" --dry-run -m msg -- ai/agents/ours.md 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'Fix:' <<<"$o" \
   && grep -q 'nothing was measured' <<<"$o"; then
  ok "a failed whole-tree scan exits 1 naming that nothing was measured, not a silent clean notice"
else
  bad "broken foreign scan must not read as clean" "rc=$rc out=$o"
fi

# ...and the refusal must be DISTINGUISHABLE from the real "nothing to commit"
# (exit 3). Reporting a failed measurement as an empty result is the same defect
# wearing the other exit code: it sends the reader off to name different paths.
if grep -q 'nothing to commit in the named paths' <<<"$o"; then
  bad "a broken scan must not claim 'nothing to commit'" "out=$o"
else
  ok "a broken scan is textually distinct from a genuinely empty one (exit 3)"
fi

# The mirror case: the PATHSPEC scan failing must also refuse loudly rather than
# fall through to exit 3, whose Fix: line ("you named the wrong paths") is wrong
# advice when the truth is that git could not be read at all.
stub_git_pathspec_status_fails() { # <dir>
  mkdir -p "$1"
  cat >"$1/git" <<'EOS'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = "status" ]; then
    case " $* " in
      *" -- "*) echo "fatal: simulated index failure" >&2; exit 128 ;;
    esac
  fi
done
exec git.real "$@"
EOS
  chmod +x "$1/git"
  ln -sf "${REAL_GIT}" "$1/git.real"   # the real git, not the agent wrapper (DND-1103)
}

r="$(new_repo)"; sdir="$(dirname "$r")/gitstub2"
stub_git_pathspec_status_fails "$sdir"
fsg_require_stubs "$sdir" git
printf 'shipwright edit\n' >"$r/ai/agents/ours.md"
o="$(cd "$r" && PATH="$sdir:$FSG_DIR:$PATH" "$COMMIT" --dry-run -m msg -- ai/agents/ours.md 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'nothing was measured' <<<"$o"; then
  ok "a failed pathspec scan exits 1, never the exit-3 'you named the wrong paths'"
else
  bad "broken pathspec scan must not read as nothing-to-commit" "rc=$rc out=$o"
fi

# The healthy path is unchanged: real git, dirty bystander, notice PRINTS.
# Without this the two cases above would pass against a script that had simply
# been broken into always failing.
r="$(new_repo)"
printf 'shipwright edit\n' >"$r/ai/agents/ours.md"
printf 'AGENT MID-EDIT\n'  >"$r/bystander.conf"
o="$(cd "$r" && "$COMMIT" --dry-run -m msg -- ai/agents/ours.md 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'bystander.conf' <<<"$o"; then
  ok "a healthy scan still reports foreign dirt (the notice was not disabled)"
else
  bad "healthy foreign-dirt notice" "rc=$rc out=$o"
fi

# ---------------------------------------------------------------------------
# Shared helpers for the runner (per-invocation-lane) sections below.

run_runner() { # run_runner <repo> [env...] ; echoes rc, out/err beside the repo
  local repo="$1"; shift
  local a; a="$(aux "$repo")"
  env "$@" SHIPWRIGHT_REPO="$repo" SHIPWRIGHT_CLAUDE="${a}/stub-claude" \
    "$RUNNER" >"${a}/runner.out" 2>"${a}/runner.err"
  echo $?
}

# A probe stub that records WHERE it ran, WHICH lane branch it was on, and WHAT
# state directory it was handed. "Where/which" is the whole point of these
# sections: a session started in the main checkout shares an index and working
# files with whoever else is typing there (the class ce70e04 came from), and two
# invocations must never share a lane. claude-was-invoked and claude-branch are
# APPENDED so a case can run the runner more than once and count/compare.
stub_claude_probe() { # $1 = path, $2 = exit code, $3 = extra shell line
  cat >"$1" <<EOF
#!/usr/bin/env bash
d="\$(dirname "\$0")"
echo "\$@" >>"\$d/claude-was-invoked"
pwd -P >"\$d/claude-cwd"
git rev-parse --abbrev-ref HEAD 2>/dev/null >>"\$d/claude-branch"
printf '%s\n' "\${SHIPWRIGHT_STATE_DIR:-<unset>}" >"\$d/claude-state-dir"
[ -n "\${SHIPWRIGHT_RECEIPT:-}" ] && : >"\$SHIPWRIGHT_RECEIPT"
${3:-:}
exit $2
EOF
  chmod +x "$1"
}

real() { ( cd "$1" 2>/dev/null && pwd -P ); }
lanes_dir() { echo "$1/.git/shipwright-lanes"; }
# Registered lane worktrees still present (should be empty after any teardown).
run_worktrees() { git -C "$1" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | grep '/shipwright-lanes/run-' || true; }
# Lane branches still present.
run_branches() { git -C "$1" for-each-ref --format='%(refname:short)' refs/heads/shipwright 2>/dev/null || true; }
# A dead corpse: a real lane worktree + meta (origin) + a FREE lock file.
make_corpse() { # <repo> <run-id> <origin>
  local repo="$1" rid="$2" origin="$3" ld; ld="$(lanes_dir "$repo")"
  mkdir -p "$ld"
  git -C "$repo" worktree add -q -b "shipwright/${rid}" "${ld}/${rid}" HEAD >/dev/null 2>&1
  printf 'origin=%s\n' "$origin" >"${ld}/${rid}.meta"
  : >"${ld}/${rid}.lock"
}

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the yield guard (main-checkout dirt, ECONOMY, decoupled from the wedge counter)'

# A dirty MAIN CHECKOUT yields the tick: a human/agent is mid-change there and
# the end-of-run fast-forward would refuse anyway, so do not spawn a session.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ]; then ok "a dirty main checkout skips the tick with exit 0 (a yield is not a failure)"
else bad "dirty main checkout exits 0" "rc=$rc $(cat "$a/runner.err")"; fi
if [ ! -e "$a/claude-was-invoked" ]; then
  ok "and no headless session is started at all"
else
  bad "no claude on a dirty main checkout" "stub ran: $(cat "$a/claude-was-invoked")"
fi
if grep -q 'Fix:' "$a/runner.err" && grep -q 'bystander.conf' "$a/runner.err"; then
  ok "the skip names the offending paths and carries a Fix: line"
else
  bad "skip message is actionable" "$(cat "$a/runner.err")"
fi
if ls "$r"/ai-artifacts/shipwright/runs/*.skipped >/dev/null 2>&1; then
  ok "and leaves a .skipped record beside the run logs"
else
  bad "skip leaves a record" "$(ls -R "$r/ai-artifacts" 2>&1)"
fi
if [ -z "$(run_worktrees "$r")" ] && [ -z "$(run_branches "$r")" ]; then
  ok "a yield provisions no lane (it happens before any worktree is created)"
else
  bad "yield creates no lane" "worktrees='$(run_worktrees "$r")' branches='$(run_branches "$r")'"
fi

# THE DECOUPLING. The old counter escalated on consecutive dirty-tree skips; the
# new one must NOT — a human editing for hours is economy, not a wedge. Many
# yields in a row stay exit 0 and never write the failure counter.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
codes=""
for _ in 1 2 3 4 5; do codes="${codes}$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2) "; done
if [ "$codes" = "0 0 0 0 0 " ]; then
  ok "consecutive main-checkout yields never escalate (got: ${codes% }) — the yield is decoupled from the wedge counter"
else
  bad "yields do not escalate" "exit codes '${codes% }', want all 0"
fi
if [ ! -e "$r/ai-artifacts/shipwright/consecutive-failures" ]; then
  ok "and a yield never touches the failure counter"
else
  bad "yield leaves the counter untouched" "counter=$(cat "$r/ai-artifacts/shipwright/consecutive-failures")"
fi

# An UNTRACKED stray in the main checkout is dirt too — the .bak in the real
# incident was untracked.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'stray\n' >"$r/somebody.bak"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ ! -e "$a/claude-was-invoked" ]; then
  ok "an untracked-only stray in the main checkout also yields the tick"
else
  bad "untracked stray yields" "rc=$rc"
fi

# The documented override runs anyway.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r" SHIPWRIGHT_ALLOW_DIRTY=1)"
if [ "$rc" -eq 0 ] && [ -e "$a/claude-was-invoked" ]; then
  ok "SHIPWRIGHT_ALLOW_DIRTY=1 overrides the guard (a human escape hatch exists)"
else
  bad "override works" "rc=$rc err=$(cat "$a/runner.err")"
fi

# The shipwright's OWN state in the main checkout must never trip the yield. The
# fixtures carry no ignore rule for ai-artifacts/ (see new_repo), so a runner
# leaning on the machine-local rule would yield forever on any checkout without
# it. A second run after a first is the real shape of this.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
rc="$(run_runner "$r")"
rm -f "$a/claude-was-invoked"
rc2="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -e "$a/claude-was-invoked" ]; then
  ok "a run's own logs/lock/records do not make the NEXT run yield, with no ignore rule in play"
else
  bad "shipwright state does not trip its successor" "rc=$rc rc2=$rc2 err=$(cat "$a/runner.err")"
fi

# DRY_RUN prints the brief without consulting git — it must work from a dirty
# tree, since that is when a human is most likely inspecting it. And the brief
# must name no checkout path (the agent template owns where the run happens).
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
o="$(env DRY_RUN=1 SHIPWRIGHT_REPO="$r" SHIPWRIGHT_CLAUDE="$a/stub-claude" "$RUNNER" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'athena-shipwright agent' <<<"$o" \
   && ! grep -q 'dev/custom' <<<"$o" \
   && grep -q 'Sync your tree' <<<"$o"; then
  ok "DRY_RUN=1 prints the brief from a dirty tree and names no checkout path"
else
  bad "DRY_RUN brief" "rc=$rc out=$o"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the per-invocation lane: unique, in a worktree, torn down'

# A clean tree runs in a FRESH lane worktree (inside .git/shipwright-lanes),
# never the main checkout, and lands its commits on the main checkout by
# fast-forward — then removes the worktree and deletes the (landed) branch.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "run work"'
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r")"
after="$(git -C "$r" rev-parse HEAD)"
if [ "$rc" -eq 0 ] && [ -e "$a/claude-was-invoked" ]; then
  ok "a clean tree runs normally (the guard is not a blanket stop)"
else
  bad "clean tree runs" "rc=$rc err=$(cat "$a/runner.err")"
fi
case "$(cat "$a/claude-cwd" 2>/dev/null)" in
  */.git/shipwright-lanes/run-*) ok "the session runs in a per-invocation lane worktree inside .git, not the main checkout" ;;
  *) bad "session runs in a lane worktree" "cwd=$(cat "$a/claude-cwd" 2>/dev/null)" ;;
esac
if [ "$(cat "$a/claude-cwd" 2>/dev/null)" != "$(real "$r")" ]; then
  ok "and that cwd is NOT the main checkout"
else
  bad "lane is not the main checkout" "cwd=$(cat "$a/claude-cwd" 2>/dev/null)"
fi
if [ "$rc" -eq 0 ] && [ "$after" != "$before" ] && [ "$after" = "$(git -C "$r" rev-parse main)" ]; then
  ok "the run's commits reach the main checkout by fast-forward"
else
  bad "main checkout fast-forwards" "rc=$rc before=$before after=$after $(cat "$a/runner.err")"
fi
if [ -z "$(run_worktrees "$r")" ]; then
  ok "and the lane worktree is torn down after the run (no standing shared lane)"
else
  bad "worktree torn down" "$(run_worktrees "$r")"
fi
if [ -z "$(run_branches "$r")" ]; then
  ok "and the landed lane branch is deleted (its commits are on main)"
else
  bad "landed branch deleted" "$(run_branches "$r")"
fi

# THE STATE GOTCHA. ai-artifacts/ is gitignored, so a lane starts with no
# cursor.txt/journal.md. State must resolve to the MAIN checkout however the run
# is invoked, or an absent cursor reads the same as a cursor at epoch.
if [ "$(cat "$a/claude-state-dir" 2>/dev/null)" = "$r/ai-artifacts/shipwright" ]; then
  ok "the session is handed SHIPWRIGHT_STATE_DIR in the MAIN checkout, not its own lane"
else
  bad "state dir is anchored" "got=$(cat "$a/claude-state-dir" 2>/dev/null) wanted=$r/ai-artifacts/shipwright"
fi
if ls "$r"/ai-artifacts/shipwright/runs/*.log >/dev/null 2>&1; then
  ok "and the run log lands in the main checkout too"
else
  bad "logs land in the main checkout" "$(ls -R "$r/ai-artifacts" 2>&1 | head -20)"
fi

# UNIQUE LANE PER INVOCATION. Two runs must never share a branch/worktree — each
# invocation is its own unit of work. The probe records the branch it was on.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "run work"'
run_runner "$r" >/dev/null
run_runner "$r" >/dev/null
n="$(wc -l <"$a/claude-branch" | tr -d ' ')"
u="$(sort -u "$a/claude-branch" | wc -l | tr -d ' ')"
if [ "$n" = "2" ] && [ "$u" = "2" ] && ! grep -qv '^shipwright/run-' "$a/claude-branch"; then
  ok "two invocations get two DIFFERENT lane branches, both shipwright/run-* ($(tr '\n' ' ' <"$a/claude-branch"))"
else
  bad "unique lane per invocation" "branches: $(tr '\n' ' ' <"$a/claude-branch") (n=$n unique=$u)"
fi

# NO-NETWORK FALLBACK. The fixtures have no remote, so `git fetch origin main`
# fails and the lane must fall back to the main checkout HEAD — the run still
# works and still lands locally.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "offline work"'
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ -e "$a/claude-was-invoked" ] \
   && [ "$(git -C "$r" rev-parse HEAD)" != "$before" ] \
   && grep -q 'no-network fallback' "$a/runner.err"; then
  ok "with no reachable remote the lane falls back to HEAD, runs, and lands (says so on stderr)"
else
  bad "no-network fallback" "rc=$rc err=$(cat "$a/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — stranded commits are KEPT, never discarded'

# A session whose commits cannot land on main (here: the fast-forward is refused
# because the main checkout has a conflicting live edit) leaves a STRANDED
# branch. The worktree is removed but the branch is KEPT, with a Fix: line, and
# the outcome counts as unsuccessful.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'printf "shipwright\n" > bystander.conf; git commit -qam "conflicting work"'
printf 'HUMAN MID-EDIT\n' >"$r/bystander.conf"
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r" SHIPWRIGHT_ALLOW_DIRTY=1)"
if [ "$(git -C "$r" rev-parse HEAD)" = "$before" ] && [ "$(cat "$r/bystander.conf")" = "HUMAN MID-EDIT" ]; then
  ok "a fast-forward that would overwrite a live edit is refused, and the edit survives"
else
  bad "ff-only protects live work" "rc=$rc head=$(git -C "$r" rev-parse HEAD) file=$(cat "$r/bystander.conf")"
fi
if grep -q 'could not be fast-forwarded' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "the un-landed fast-forward is reported with a Fix:, not swallowed"
else
  bad "ff failure is reported" "$(cat "$a/runner.err")"
fi
if [ -z "$(run_worktrees "$r")" ]; then
  ok "the lane worktree is still torn down (teardown always removes the tree)"
else
  bad "worktree removed even when stranded" "$(run_worktrees "$r")"
fi
kept="$(run_branches "$r")"
case "$kept" in
  shipwright/run-*) ok "but the STRANDED branch is kept for recovery ($kept)" ;;
  *) bad "stranded branch kept" "branches='$kept'" ;;
esac
if grep -q 'kept stranded branch' "$a/runner.err"; then
  ok "and the stranded branch is announced with how to recover it"
else
  bad "stranded branch announced" "$(cat "$a/runner.err")"
fi
if [ "$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null)" = "1" ]; then
  ok "a stranded push counts as an unsuccessful outcome (failure counter = 1)"
else
  bad "stranded counts as failure" "counter=$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null)"
fi

# A lane branch whose ref is corrupt (DND-1662). `show-ref --verify` answers a
# ref file holding garbage as it answers a missing ref, so teardown read it as
# "no branch" and reported a clean run. It is COULD NOT TELL: named with a
# Fix:, the ref file left as found, and counted as an unsuccessful outcome.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "work"; b="$(git symbolic-ref --short HEAD)"; printf "%s\n" "$b" >"$d/corrupt-branch"; printf "not-a-sha\n" >"$(git rev-parse --path-format=absolute --git-common-dir)/refs/heads/$b"'
rc="$(run_runner "$r")"
cb="$(cat "$a/corrupt-branch" 2>/dev/null)"
cref="$r/.git/refs/heads/$cb"
if [ -n "$cb" ] && [ "$(cat "$cref" 2>/dev/null)" = "not-a-sha" ] \
   && grep -q "COULD NOT TELL whether branch $cb exists" "$a/runner.err" \
   && grep -q "Fix:.*show-ref --exists refs/heads/$cb.*logs/refs/heads/$cb" "$a/runner.err" \
   && grep -q "COULD NOT TELL whether its lane branch holds unlanded work" "$a/runner.err" \
   && ! grep -q "ran clean but its commits did not land" "$a/runner.err" \
   && [ "$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null)" = "1" ]; then
  ok "a corrupt lane branch ref: COULD NOT TELL with a Fix:, the ref file left as found, counted, never called an unlanded push"
else
  bad "corrupt lane branch ref" "rc=$rc branch=$cb ref=$(cat "$cref" 2>&1) counter=$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null) err=$(cat "$a/runner.err")"
fi

# The reaper names a dead lane's unreadable branch too: its COULD NOT TELL line
# and Fix: reach the runner's stderr, never /dev/null.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
make_corpse "$r" "run-corrupt" "spawned"
cref="$r/.git/refs/heads/shipwright/run-corrupt"
printf 'not-a-sha\n' >"$cref"
rc="$(run_runner "$r")"
if [ "$(cat "$cref" 2>/dev/null)" = "not-a-sha" ] && [ ! -e "$(lanes_dir "$r")/run-corrupt/.git" ] \
   && grep -q "COULD NOT TELL whether branch shipwright/run-corrupt exists (reaped dead spawned run)" "$a/runner.err" \
   && grep -q "Fix:.*show-ref --exists refs/heads/shipwright/run-corrupt" "$a/runner.err"; then
  ok "reap: a dead lane whose branch ref is corrupt is named COULD NOT TELL with a Fix:, the ref left as found"
else
  bad "reap corrupt ref" "rc=$rc ref=$(cat "$cref" 2>&1) err=$(cat "$a/runner.err")"
fi

# A landed lane whose `git branch -D` is refused (a held ref lock; DND-1715).
# The exit was dropped (`|| true`), so the branch stayed with nothing past the
# tick log. It is kept and named, with the delete to run, in stderr and the
# tick's own runs/<ts>.branch-kept record. A refused delete is hygiene, never
# an outcome: the tick exits 0 and the failure counter is cleared, not bumped.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'b="$(git symbolic-ref --short HEAD)"; printf "%s\n" "$b" >"$d/refused-branch"; : >"$(git rev-parse --path-format=absolute --git-common-dir)/refs/heads/$b.lock"'
mkdir -p "$r/ai-artifacts/shipwright"; echo 1 >"$r/ai-artifacts/shipwright/consecutive-failures"
rc="$(run_runner "$r")"
rb="$(cat "$a/refused-branch" 2>/dev/null)"
kept="$(find "$r/ai-artifacts/shipwright/runs" -maxdepth 1 -name '*.branch-kept' 2>/dev/null | head -n1)"
if [ "$rc" = 0 ] && [ -n "$rb" ] && git -C "$r" show-ref --verify --quiet "refs/heads/$rb" \
   && [ -z "$(run_worktrees "$r")" ] \
   && [ ! -e "$r/ai-artifacts/shipwright/consecutive-failures" ] \
   && grep -q "could not delete branch $rb" "$a/runner.err" \
   && grep -q "Fix:.*git -C $r branch -D $rb" "$a/runner.err" \
   && [ -n "$kept" ] && grep -q "Fix: git -C $r branch -D $rb" "$kept"; then
  ok "a refused branch -D keeps the branch, names it with a Fix: in stderr and runs/<ts>.branch-kept; exit 0, counter cleared"
else
  bad "own lane delete refused" "rc=$rc branch=$rb counter=$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null) kept=$(cat "$kept" 2>/dev/null) err=$(cat "$a/runner.err")"
fi

# The reaper names a dead lane's refused delete too, and never counts it: a
# dead SPAWNED corpse is not counted, so the counter stays absent.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
make_corpse "$r" "run-heldref" "spawned"
: >"$r/.git/refs/heads/shipwright/run-heldref.lock"
rc="$(run_runner "$r")"
kept="$(find "$r/ai-artifacts/shipwright/runs" -maxdepth 1 -name '*.branch-kept' 2>/dev/null | head -n1)"
if [ "$rc" = 0 ] && git -C "$r" show-ref --verify --quiet refs/heads/shipwright/run-heldref \
   && [ ! -e "$(lanes_dir "$r")/run-heldref/.git" ] \
   && [ ! -e "$r/ai-artifacts/shipwright/consecutive-failures" ] \
   && grep -q "could not delete branch shipwright/run-heldref (reaped dead spawned run)" "$a/runner.err" \
   && grep -q "Fix:.*branch -D shipwright/run-heldref" "$a/runner.err" \
   && [ -n "$kept" ] && grep -q 'shipwright/run-heldref' "$kept"; then
  ok "reap: a refused delete of a dead lane's branch is named with a Fix: in stderr and .branch-kept, and never counted"
else
  bad "reap delete refused" "rc=$rc counter=$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null) kept=$(cat "$kept" 2>/dev/null) err=$(cat "$a/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — with an origin, only LANDED work reaches the main checkout (DND-1008)'

# A repo with a real origin (a bare fixture remote). On 2026-09-27 a run put its
# fix up as a PR branch rather than pushing main; teardown still fast-forwarded
# the main checkout to the lane tip, so the live harness ran unreviewed code
# and local main diverged from origin/main the moment anything else landed.
with_origin() { # <repo> ; adds a bare origin beside it holding main
  local o; o="$(aux "$1")/origin.git"
  git init -q --bare -b main "$o" >&2
  git -C "$1" remote add origin "$o"
  git -C "$1" push -q origin main >&2
  git -C "$1" fetch -q origin >&2
}

# PR-only: the session pushes its commit to a review branch, not main.
r="$(new_repo)"; a="$(aux "$r")"; with_origin "$r"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "pr work"; git push -q origin HEAD:refs/heads/pr-branch'
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r")"
if [ "$(git -C "$r" rev-parse HEAD)" = "$before" ]; then
  ok "a run published only as a PR branch does NOT move the main checkout"
else
  bad "PR-only run leaves main alone" "before=$before after=$(git -C "$r" rev-parse HEAD) $(cat "$a/runner.err")"
fi
if [ "$rc" -eq 0 ] && grep -q 'not landed on origin/main' "$a/runner.err"; then
  ok "and says so: the run succeeded, its work is published for review, not landed"
else
  bad "PR-only run reported" "rc=$rc err=$(cat "$a/runner.err")"
fi
if [ "$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null || echo 0)" = "0" ]; then
  ok "a PR-published run is not a stranded failure (its commits are on origin)"
else
  bad "PR-only is not stranded" "counter=$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null)"
fi

# Landed: the session pushes to origin main. The main checkout follows.
r="$(new_repo)"; a="$(aux "$r")"; with_origin "$r"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "landed work"; git push -q origin HEAD:refs/heads/main'
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ "$(git -C "$r" rev-parse HEAD)" = "$(git -C "$(aux "$r")/origin.git" rev-parse main)" ] \
   && [ "$(git -C "$r" log -1 --format=%s)" = "landed work" ]; then
  ok "a run that landed on origin/main fast-forwards the main checkout to it"
else
  bad "landed run fast-forwards main" "rc=$rc head=$(git -C "$r" log -1 --format=%s) err=$(cat "$a/runner.err")"
fi

# Neither: committed, pushed nowhere. Still stranded, main untouched.
r="$(new_repo)"; a="$(aux "$r")"; with_origin "$r"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "unpushed work"'
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r")"
if [ "$(git -C "$r" rev-parse HEAD)" = "$before" ] && grep -q 'kept stranded branch' "$a/runner.err" \
   && [ "$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null)" = "1" ]; then
  ok "an unpushed run with an origin is stranded: branch kept, main untouched, counted as a failure"
else
  bad "unpushed run stranded" "rc=$rc head-moved=$([ "$(git -C "$r" rev-parse HEAD)" = "$before" ] && echo no || echo yes) err=$(cat "$a/runner.err")"
fi

# A run that commits nothing still publishes what ANOTHER actor landed. The
# lane's base is origin/main, so it is landed by definition (DND-1008 holds).
# Measured 2026-10-01 on the laptop: no-commit ticks never fast-forwarded, so
# the main checkout sat 31 commits behind origin/main and the live runner had
# no main-health backstop (DND-1482) at all.
land_elsewhere() { # <repo> <subject> ; another machine pushes to origin main
  local o; o="$(aux "$1")/other-clone"
  [ -d "$o" ] || git clone -q "$(aux "$1")/origin.git" "$o" >&2
  git -C "$o" pull -q --ff-only origin main >&2
  git -C "$o" -c user.email=t@example.invalid -c user.name=Other -c commit.gpgsign=false \
    commit --allow-empty -qm "$2" >&2
  git -C "$o" push -q origin HEAD:main >&2
}
r="$(new_repo)"; a="$(aux "$r")"; with_origin "$r"
land_elsewhere "$r" "landed elsewhere"
stub_claude_probe "$a/stub-claude" 0 'printf "no harness changes warranted.\n"'
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ "$(git -C "$r" rev-parse HEAD)" = "$(git -C "$a/origin.git" rev-parse main)" ]; then
  ok "a no-commit run fast-forwards the main checkout to what another actor landed on origin/main"
else
  bad "no-commit run catches the main checkout up" "rc=$rc head=$(git -C "$r" log -1 --format=%s) err=$(cat "$a/runner.err")"
fi
if [ "$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null || echo 0)" = "0" ] && [ -z "$(run_branches "$r")" ]; then
  ok "and that catch-up is not a stranded failure (no lane branch kept, counter 0)"
else
  bad "catch-up is not stranded" "branches=$(run_branches "$r") counter=$(cat "$r/ai-artifacts/shipwright/consecutive-failures" 2>/dev/null)"
fi

# The catch-up only ever moves `main`: a main checkout a human left on another
# branch is not fast-forwarded to origin/main.
r="$(new_repo)"; a="$(aux "$r")"; with_origin "$r"
git -C "$r" checkout -q -b side >&2
land_elsewhere "$r" "landed elsewhere"
stub_claude_probe "$a/stub-claude" 0 'printf "no harness changes warranted.\n"'
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ "$(git -C "$r" rev-parse HEAD)" = "$before" ] && [ "$(git -C "$r" symbolic-ref --short HEAD)" = "side" ]; then
  ok "a main checkout on a branch other than main is left where it is"
else
  bad "catch-up moves only main" "rc=$rc branch=$(git -C "$r" symbolic-ref --short HEAD) err=$(cat "$a/runner.err")"
fi

# ff-only still protects a live edit: the landed commit touches a file the main
# checkout has modified, so git refuses, the edit survives, and a Fix: says so.
r="$(new_repo)"; a="$(aux "$r")"; with_origin "$r"
land_elsewhere "$r" "landed elsewhere"
o="$a/other-clone"
printf 'landed\n' >"$o/bystander.conf"
git -C "$o" -c user.email=t@example.invalid -c user.name=Other -c commit.gpgsign=false commit -qam "touch bystander" >&2
git -C "$o" push -q origin HEAD:main >&2
printf 'HUMAN MID-EDIT\n' >"$r/bystander.conf"
stub_claude_probe "$a/stub-claude" 0 'printf "no harness changes warranted.\n"'
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r" SHIPWRIGHT_ALLOW_DIRTY=1)"
if [ "$(git -C "$r" rev-parse HEAD)" = "$before" ] && [ "$(cat "$r/bystander.conf")" = "HUMAN MID-EDIT" ] \
   && grep -q 'could not be fast-forwarded' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "a catch-up that would overwrite a live edit is refused, the edit survives, and a Fix: is printed"
else
  bad "catch-up protects live work" "rc=$rc file=$(cat "$r/bystander.conf") err=$(cat "$a/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the wedge counter escalates on FAILURES (what the old skip counter missed)'

# The headline superset: a session that RUNS and FAILS on a clean tree is
# exactly what the old dirty-tree skip counter never saw. N failing sessions in
# a row must escalate to a refuse-to-spawn (exit 75) BEFORE the (N+1)th session.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
codes=""
for _ in 1 2 3 4; do codes="${codes}$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=3) "; done
if [ "$codes" = "7 7 7 75 " ]; then
  ok "three failing sessions then a refuse-to-spawn at the threshold (got: ${codes% })"
else
  bad "failing sessions escalate" "exit codes '${codes% }', want '7 7 7 75'"
fi
n="$(wc -l <"$a/claude-was-invoked" 2>/dev/null | tr -d ' ')"
if [ "$n" = "3" ]; then
  ok "the escalating 75 run does NOT spawn a session (3 sessions ran, not 4)"
else
  bad "escalation refuses to spawn" "sessions started: $n (want 3)"
fi
if grep -q 'WEDGED' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "and the escalation says it is wedged, with a Fix: line naming the re-arm step"
else
  bad "escalation message" "$(cat "$a/runner.err")"
fi
if [ -z "$(run_worktrees "$r")" ]; then
  ok "and every failing run still tore its lane down (no leftover worktrees)"
else
  bad "failing runs teardown" "$(run_worktrees "$r")"
fi

# A clean landing RESETS the counter: an occasional failure never accumulates
# into a false wedge.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=3 >/dev/null   # fail -> counter 1
run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=3 >/dev/null   # fail -> counter 2
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm ok'
run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=3 >/dev/null   # clean landing -> reset
if [ ! -e "$r/ai-artifacts/shipwright/consecutive-failures" ]; then
  ok "a clean landing resets the failure counter (occasional failures do not accumulate)"
else
  bad "clean landing resets counter" "counter=$(cat "$r/ai-artifacts/shipwright/consecutive-failures")"
fi

# A non-numeric threshold must not silently disable the escalation (the `-ge`
# test sits in an `if`, so its error is exempt from set -e).
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
codes=""
for _ in 1 2 3 4 5 6 7; do codes="${codes}$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=notanumber) "; done
if grep -q '75' <<<"$codes"; then
  ok "a non-numeric SHIPWRIGHT_FAIL_ESCALATE falls back to the default and still escalates"
else
  bad "bad SHIPWRIGHT_FAIL_ESCALATE does not disable escalation" "exit codes '${codes% }' — none was 75"
fi
if grep -q 'not a positive integer' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "and says so with a Fix: line rather than degrading silently"
else
  bad "bad threshold is reported" "$(cat "$a/runner.err")"
fi

# The guard must not swallow the session's own failure code.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 7
rc="$(run_runner "$r")"
if [ "$rc" -eq 7 ]; then
  ok "a failing session still propagates its exit code (no false green)"
else
  bad "session exit code propagates" "rc=$rc"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — crash reaping (liveness by held flock, not pid)'

# DEAD-PREDECESSOR REAP. A crashed run leaves a lane worktree + a FREE lock. The
# next run reaps it (removes the worktree) for hygiene.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
make_corpse "$r" "run-dead" "cron"
ld="$(lanes_dir "$r")"
rc="$(run_runner "$r")"
if [ ! -e "$ld/run-dead/.git" ] && [ ! -e "$ld/run-dead.lock" ]; then
  ok "a dead predecessor lane (free lock) is reaped — worktree and lock removed"
else
  bad "dead predecessor reaped" "wt=$([ -e "$ld/run-dead/.git" ] && echo present) lock=$([ -e "$ld/run-dead.lock" ] && echo present)"
fi
if grep -q 'reaped dead cron lane run-dead' "$a/runner.err"; then
  ok "and the reap is announced"
else
  bad "reap announced" "$(cat "$a/runner.err")"
fi

# THE CRITICAL CASE: a LIVE lane is NEVER reaped. Liveness is a held flock(2), so
# a concurrent run (cron or hand-spawned) that holds its lane lock is left
# strictly alone — reaping only ever removes a lane whose lock it can acquire.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
cat >"$a/holder.sh" <<'EOF'
#!/usr/bin/env bash
# Hold an flock on $1, signal that it is held, then self-terminate after a
# bounded wait (never a spin). The suite kills it well before that.
exec 5>>"$1"
flock 5
: >"$1.held"
sleep 30
EOF
chmod +x "$a/holder.sh"
make_corpse "$r" "run-live" "cron"
ld="$(lanes_dir "$r")"
"$a/holder.sh" "$ld/run-live.lock" &
HOLDER_PID=$!
for _ in $(seq 1 100); do [ -e "$ld/run-live.lock.held" ] && break; sleep 0.1; done
if [ -e "$ld/run-live.lock.held" ]; then
  rc="$(run_runner "$r")"
  if [ -e "$ld/run-live/.git" ] && git -C "$r" show-ref --verify --quiet refs/heads/shipwright/run-live; then
    ok "a LIVE lane (lock held by a concurrent process) is NEVER reaped — worktree and branch survive"
  else
    bad "live lane never reaped" "wt=$([ -e "$ld/run-live/.git" ] && echo present || echo GONE) branch=$(git -C "$r" show-ref --verify --quiet refs/heads/shipwright/run-live && echo present || echo GONE) err=$(cat "$a/runner.err")"
  fi
else
  bad "holder acquired the lock" "no .held marker appeared"
fi
kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""

# ONLY dead CRON corpses count toward the wedge. Three dead cron corpses push the
# counter to the threshold, so the run refuses to spawn (exit 75) at the top.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
make_corpse "$r" "run-c1" "cron"; make_corpse "$r" "run-c2" "cron"; make_corpse "$r" "run-c3" "cron"
rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=3)"
if [ "$rc" -eq 75 ] && [ ! -e "$a/claude-was-invoked" ]; then
  ok "reaped dead CRON corpses count toward the wedge (3 corpses + threshold 3 → refuse to spawn)"
else
  bad "cron corpses count" "rc=$rc invoked=$([ -e "$a/claude-was-invoked" ] && echo yes)"
fi

# ...but dead SPAWNED (hand-invoked agent) corpses are reaped for hygiene and do
# NOT count. Three of them do not wedge the lane; the run proceeds.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
make_corpse "$r" "run-s1" "spawned"; make_corpse "$r" "run-s2" "spawned"; make_corpse "$r" "run-s3" "spawned"
ld="$(lanes_dir "$r")"
rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=3)"
if [ "$rc" -eq 0 ] && [ -e "$a/claude-was-invoked" ]; then
  ok "dead SPAWNED corpses are reaped but NOT counted (3 corpses + threshold 3 → run still proceeds)"
else
  bad "spawned corpses not counted" "rc=$rc invoked=$([ -e "$a/claude-was-invoked" ] && echo yes) err=$(cat "$a/runner.err")"
fi
if [ ! -e "$ld/run-s1/.git" ] && [ ! -e "$ld/run-s2/.git" ] && [ ! -e "$ld/run-s3/.git" ]; then
  ok "and they were still reaped for hygiene"
else
  bad "spawned corpses reaped" "$(run_worktrees "$r")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — a branch-name collision fails LOUD, no fallback to the main checkout'

# `-b` (create), never `-B` (force): if the lane branch already exists, the run
# must fail loudly rather than move an existing branch or run in the main
# checkout. A forced run-id lets us reproduce the collision deterministically.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
git -C "$r" branch "shipwright/run-collide" HEAD >/dev/null 2>&1
rc="$(run_runner "$r" SHIPWRIGHT_RUN_ID=run-collide)"
if [ "$rc" -ne 0 ] && [ ! -e "$a/claude-was-invoked" ]; then
  ok "a branch-name collision fails the run (non-zero) and starts no session"
else
  bad "collision fails loud" "rc=$rc invoked=$([ -e "$a/claude-was-invoked" ] && echo yes) err=$(cat "$a/runner.err")"
fi
if grep -q 'collision' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "and says how to clear it, naming the collision as fatal by design"
else
  bad "collision message is actionable" "$(cat "$a/runner.err")"
fi
if [ "$(cat "$a/claude-cwd" 2>/dev/null)" != "$(real "$r")" ]; then
  ok "and never fell back to running in the main checkout"
else
  bad "no main-checkout fallback on collision" "cwd=$(cat "$a/claude-cwd" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the single-run lock still holds'

# Two runs must not interleave: the second skips rather than queueing. The first
# is held open by a stub that blocks on a marker, so the overlap is
# deterministic. A concurrent LIVE run's lane must also survive (the second run
# skips before reaping; even if it reached the reaper, the live lock protects it).
r="$(new_repo)"; a="$(aux "$r")"
cat >"$a/stub-claude" <<'EOF'
#!/usr/bin/env bash
A="$(dirname "$0")"
echo ran >>"$A/claude-was-invoked"
[ -n "${SHIPWRIGHT_RECEIPT:-}" ] && : >"$SHIPWRIGHT_RECEIPT"
for _ in $(seq 1 300); do
  [ -e "$A/release" ] && exit 0
  sleep 0.1
done
exit 0
EOF
chmod +x "$a/stub-claude"
env SHIPWRIGHT_REPO="$r" SHIPWRIGHT_CLAUDE="$a/stub-claude" "$RUNNER" >/dev/null 2>&1 &
RUNNER_PID=$!
for _ in $(seq 1 100); do
  [ -e "$a/claude-was-invoked" ] && break
  sleep 0.1
done
if [ -e "$a/claude-was-invoked" ]; then
  rc="$(run_runner "$r")"
  second_ran="$(wc -l <"$a/claude-was-invoked" | tr -d ' ')"
  if [ "$rc" -eq 0 ] && [ "$second_ran" = "1" ]; then
    ok "a second run skips (exit 0) while the first holds the flock"
  else
    bad "second run skips" "rc=$rc invocations=$second_ran"
  fi
  if grep -q 'already in progress' "$a/runner.err"; then
    ok "and says so on stderr"
  else
    bad "overlap message" "$(cat "$a/runner.err")"
  fi
  if grep -q "holder: pid=$RUNNER_PID " "$a/runner.err"; then
    ok "and names the holding pid, so a live lock is distinguishable from a stale file"
  else
    bad "lock names its holder" "wanted 'holder: pid=$RUNNER_PID', got: $(cat "$a/runner.err")"
  fi
  if grep -q 'Do NOT delete the lock file' "$a/runner.err"; then
    ok "and says not to delete it"
  else
    bad "lock message warns against deletion" "$(cat "$a/runner.err")"
  fi
  # The skipped tick must leave a record, so that "no artifact at all for an
  # hour" means exactly one thing (cron/the machine did not fire).
  if ls "$r/ai-artifacts/shipwright/runs/"*.locked >/dev/null 2>&1; then
    ok "and the skipped tick leaves a .locked record, so an absent hour has ONE meaning"
  else
    bad "flock skip leaves a record" "no .locked in $(ls "$r/ai-artifacts/shipwright/runs/" 2>&1)"
  fi
else
  bad "first run reached the stub" "$(ls -a "$a")"
fi
: >"$a/release"
wait "$RUNNER_PID" 2>/dev/null
RUNNER_PID=""

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — a session that never reported for duty is BLOCKED, not a clean success'

# THE HEADLINE REGRESSION. On 2026-09-19 nine consecutive ticks (00:00..08:00)
# died instantly on the provider's weekly limit, exited 0, made no commits, and
# were classified as CLEAN SUCCESSES that RESET the wedge counter — zero
# retrospective work, indistinguishable on disk from a healthy quiet run.
sd() { echo "$1/ai-artifacts/shipwright"; }
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked "$a/stub-claude" "You've hit your weekly limit · resets Sep 22, 4am (America/Denver)"
rc="$(run_runner "$r")"
if [ "$rc" -eq 69 ]; then
  ok "the verbatim weekly-limit tick exits 69 (was 0 — a clean success)"
else
  bad "blocked tick exits 69" "rc=$rc err=$(cat "$a/runner.err")"
fi
if ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1; then
  ok "and leaves a .blocked marker"
else
  bad "blocked marker written" "runs/: $(ls "$(sd "$r")/runs/" 2>&1)"
fi
if [ "$(cat "$(sd "$r")/consecutive-blocked" 2>/dev/null)" = "1" ]; then
  ok "and starts its own blocked streak"
else
  bad "blocked streak counted" "got '$(cat "$(sd "$r")/consecutive-blocked" 2>/dev/null)'"
fi
if grep -q 'BLOCKED' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "and reports BLOCKED with an actionable Fix:"
else
  bad "blocked message" "$(cat "$a/runner.err")"
fi

# A blocked tick must not ERASE a real, accumulating failure streak. The old
# code's reset_fail on this path did exactly that — strictly weaker.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
run_runner "$r" >/dev/null; run_runner "$r" >/dev/null
stub_claude_blocked "$a/stub-claude" "You've hit your weekly limit"
run_runner "$r" >/dev/null
if [ "$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)" = "2" ]; then
  ok "a blocked tick leaves an accumulating FAILURE streak intact (it no longer erases it)"
else
  bad "blocked does not reset the wedge counter" "counter='$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)', want 2"
fi

# BLOCKED NEVER WEDGES. The wedge exists to stop a lane burning tokens; a
# blocked tick burns none and self-resolves, so it must never gate the spawn.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked "$a/stub-claude" "You've hit your weekly limit"
codes=""
for _ in 1 2 3 4 5 6 7 8 9; do codes="${codes}$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=3) "; done
n="$(wc -l <"$a/claude-was-invoked" 2>/dev/null | tr -d ' ')"
if [ "$codes" = "69 69 69 69 69 69 69 69 69 " ] && [ "$n" = "9" ] \
   && [ ! -e "$(sd "$r")/consecutive-failures" ]; then
  ok "nine blocked ticks: all 69, a session spawned every single time, lane never wedged"
else
  bad "blocked never wedges" "codes='${codes% }' spawns=$n counter=$([ -e "$(sd "$r")/consecutive-failures" ] && echo present || echo absent)"
fi

# ...and it self-heals with ZERO human action (no counter to delete).
stub_claude_probe "$a/stub-claude" 0
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ ! -e "$(sd "$r")/consecutive-blocked" ]; then
  ok "and the lane recovers by itself the moment the block clears — nothing to re-arm"
else
  bad "blocked self-heals" "rc=$rc streak=$(cat "$(sd "$r")/consecutive-blocked" 2>/dev/null)"
fi

# THE MISS CASE. The vendor reworded its message and NO signature matches. A
# detector that quietly matches nothing must not read as "no problem": the miss
# is LOUDER than a hit, never quieter.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked "$a/stub-claude" "Zorptastic overcapacity glorp"
rc="$(run_runner "$r")"
m="$(cat "$(sd "$r")/runs/"*.blocked 2>/dev/null || true)"
if [ "$rc" -eq 69 ] && grep -q 'UNCLASSIFIED' "$a/runner.err" \
   && grep -q 'Fix:' "$a/runner.err" \
   && grep -q 'BLOCK_PATTERNS' "$a/runner.err" \
   && grep -q 'classification=UNCLASSIFIED' <<<"$m"; then
  ok "an UNMATCHED block signature still exits 69, says UNCLASSIFIED, and names BLOCK_PATTERNS to fix"
else
  bad "detector miss is loud" "rc=$rc err=$(cat "$a/runner.err") marker=$m"
fi

# THE ANTI-FALSE-POSITIVE a size/line-count detector would have failed. The
# blocked log above is 68 bytes / 1 line; this healthy no-op log is 71 bytes /
# 1 line. They differ by three bytes and zero lines — never detect on size.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'printf "Retrospective complete — steady state, no harness changes warranted.\n"'
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1 \
   && [ ! -e "$(sd "$r")/consecutive-failures" ]; then
  ok "a HEALTHY no-op run (71 bytes, 1 line — vs the blocked 68 bytes, 1 line) stays a clean success"
else
  bad "healthy no-op not misread as blocked" "rc=$rc err=$(cat "$a/runner.err")"
fi

# A signature must never be able to DOWNGRADE a real failure: a session that
# left its receipt reached the model, so a failing one that happens to mention a
# rate limit still fails and still feeds the wedge. (Later, DND-833: this used
# to say "only status==0 can be blocked". A receipt-less non-zero tick with a
# signature is now BLOCKED; see the DND-833 cases below.)
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 7 'printf "hit the rate limit\n"'
rc="$(run_runner "$r")"
if [ "$rc" -eq 7 ] && [ "$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)" = "1" ] \
   && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1; then
  ok "a FAILING session mentioning a block signature stays a failure (a signature cannot downgrade it)"
else
  bad "signature cannot downgrade a failure" "rc=$rc counter=$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)"
fi

# --- a usage limit that exits NON-ZERO (DND-833) ----------------------------
#
# `claude -p` exits NON-ZERO on a provider usage limit. Measured on the laptop,
# 2026-09-23 02:00..07:00: six ticks each logged "You've hit your weekly limit",
# left no receipt, and were each counted as a wedge FAILURE because the BLOCKED
# class applied to exit 0 only. The sixth wedged the lane, and every tick since
# has exited 75 without spawning a session: the loop went dark on a provider
# outage that cleared by itself the next morning.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked_rc "$a/stub-claude" "You've hit your weekly limit · resets Sep 24, 8am (America/Denver)" 1
rc="$(run_runner "$r")"
m="$(cat "$(sd "$r")/runs/"*.blocked 2>/dev/null || true)"
if [ "$rc" -eq 69 ] && grep -q 'session_exit=1' <<<"$m" \
   && grep -q 'signature: weekly limit' <<<"$m"; then
  ok "a receipt-less weekly-limit tick that exits 1 is BLOCKED (exit 69, marker records session_exit=1)"
else
  bad "non-zero usage-limit tick is blocked" "rc=$rc marker=$m err=$(cat "$a/runner.err")"
fi
if [ ! -e "$(sd "$r")/consecutive-failures" ] \
   && [ "$(cat "$(sd "$r")/consecutive-blocked" 2>/dev/null)" = "1" ]; then
  ok "and it feeds the blocked streak, never the wedge counter"
else
  bad "non-zero usage limit does not feed the wedge" \
      "failures='$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)' blocked='$(cat "$(sd "$r")/consecutive-blocked" 2>/dev/null)'"
fi

# The five-hour SESSION limit is worded differently from the weekly one.
# Measured on the desktop, 2026-09-30 12:00Z: the tick logged "You've hit your
# session limit · resets 6:30am (America/Denver)", exited 1, matched no
# signature, and was counted as a wedge FAILURE (consecutive-failures=1) for a
# limit that cleared by itself 30 minutes later.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked_rc "$a/stub-claude" "You've hit your session limit · resets 6:30am (America/Denver)" 1
rc="$(run_runner "$r")"
m="$(cat "$(sd "$r")/runs/"*.blocked 2>/dev/null || true)"
if [ "$rc" -eq 69 ] && grep -q 'signature: session limit' <<<"$m" \
   && [ ! -e "$(sd "$r")/consecutive-failures" ]; then
  ok "a receipt-less session-limit tick that exits 1 is BLOCKED, never a wedge failure"
else
  bad "non-zero session-limit tick is blocked" "rc=$rc marker=$m failures='$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)'"
fi

# The laptop's exact shape, end to end: six non-zero usage-limit ticks against a
# threshold of 3 must never wedge, and must spawn a session every tick.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked_rc "$a/stub-claude" "You've hit your weekly limit · resets Sep 24, 8am (America/Denver)" 1
codes=""
for _ in 1 2 3 4 5 6; do codes="${codes}$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=3) "; done
n="$(wc -l <"$a/claude-was-invoked" 2>/dev/null | tr -d ' ')"
if [ "$codes" = "69 69 69 69 69 69 " ] && [ "$n" = "6" ] \
   && [ ! -e "$(sd "$r")/consecutive-failures" ]; then
  ok "six non-zero usage-limit ticks: all 69, six sessions, lane never wedged (the 2026-09-23 shape)"
else
  bad "non-zero usage limit never wedges" "codes='${codes% }' spawns=$n counter='$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)'"
fi

# The signature must not downgrade a failure that REACHED the model: a receipt
# is present, so the session ran and failed. (The receipt, not the signature, is
# still the detector.) Covered above for exit 7; this pins the usage-limit text.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 1 "printf \"You've hit your weekly limit\\n\""
rc="$(run_runner "$r")"
if [ "$rc" -eq 1 ] && [ "$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)" = "1" ] \
   && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1; then
  ok "a session that left its receipt and then hit a limit stays a FAILURE (it reached the model)"
else
  bad "receipt + limit text stays a failure" "rc=$rc counter=$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)"
fi

# A receipt-less non-zero tick with NO known signature is still a failure (a
# missing binary or a crash must still wedge), but it must say so: it never
# reported for duty, nothing matched, and here is the record.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked_rc "$a/stub-claude" "Segmentation fault (core dumped)" 139
rc="$(run_runner "$r")"
f="$(cat "$(sd "$r")/runs/"*.failed 2>/dev/null || true)"
if [ "$rc" -eq 139 ] && [ "$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)" = "1" ] \
   && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1 \
   && grep -q 'never reported for duty' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err" \
   && grep -q 'classification=failure' <<<"$f" && grep -q 'session_exit=139' <<<"$f"; then
  ok "a receipt-less non-zero tick with no signature stays a failure, loudly, with a .failed record"
else
  bad "unsigned receipt-less failure is loud" "rc=$rc record=$f err=$(cat "$a/runner.err")"
fi

# An EMPTY log is its own case: the session printed nothing at all. It must not
# read like a crash that printed something, nor like a usage limit.
r="$(new_repo)"; a="$(aux "$r")"
cat >"$a/stub-claude" <<'EOF'
#!/usr/bin/env bash
echo "$@" >>"$(dirname "$0")/claude-was-invoked"
exit 1
EOF
chmod +x "$a/stub-claude"
rc="$(run_runner "$r")"
f="$(cat "$(sd "$r")/runs/"*.failed 2>/dev/null || true)"
if [ "$rc" -eq 1 ] && grep -q 'session_output=empty' <<<"$f" \
   && grep -q 'printed NOTHING' "$a/runner.err"; then
  ok "a receipt-less failure with an EMPTY log says the session printed nothing (distinct from a limit)"
else
  bad "empty-log failure is named" "rc=$rc record=$f err=$(cat "$a/runner.err")"
fi

# --- only the SESSION's output is classified (DND-739, required by DND-833) -
#
# Teardown appends git's output to the same log after the session ends
# ("Deleted branch shipwright/<run-id> (was <sha>)"). Classifying the whole log
# let teardown text decide the class. After DND-833 the signature decides
# wedge-vs-blocked on a non-zero exit, so a false match there would turn a real
# failure into a lane that never wedges. The run id is chosen so teardown prints
# a block signature ("quota") the session never said.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked_rc "$a/stub-claude" "Segmentation fault (core dumped)" 139
rc="$(run_runner "$r" SHIPWRIGHT_RUN_ID=run-quota-4290)"
if [ "$rc" -eq 139 ] && [ "$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)" = "1" ] \
   && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1; then
  ok "a signature that appears only in TEARDOWN output cannot turn a failure into BLOCKED"
else
  bad "teardown text does not classify" "rc=$rc runs=$(ls "$(sd "$r")/runs/" 2>&1) err=$(cat "$a/runner.err")"
fi
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked "$a/stub-claude" "Zorptastic overcapacity glorp"
rc="$(run_runner "$r" SHIPWRIGHT_RUN_ID=run-quota-4291)"
m="$(cat "$(sd "$r")/runs/"*.blocked 2>/dev/null || true)"
if [ "$rc" -eq 69 ] && grep -q 'classification=UNCLASSIFIED' <<<"$m"; then
  ok "and teardown text cannot CLASSIFY an exit-0 blocked tick either (stays UNCLASSIFIED)"
else
  bad "teardown text does not classify exit-0" "rc=$rc marker=$m"
fi

# --- the session does not truncate the tick's log (DND-1514) -----------------
#
# `>"${log}"` at session launch destroyed every line the runner had written
# earlier in the tick. The session now appends. A line the runner wrote BEFORE
# the session must survive ahead of the session's output, and the "empty
# session" verdict must still read only the session's share of the log.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked_rc "$a/stub-claude" "session said hello" 0
rc="$(run_runner "$r")"
tl="$(cat "$(sd "$r")"/runs/*.log 2>/dev/null || true)"
launch_ln="$(grep -n 'launching the session' <<<"$tl" | head -1 | cut -d: -f1)"
sess_ln="$(grep -n 'session said hello' <<<"$tl" | head -1 | cut -d: -f1)"
if [ -n "$launch_ln" ] && [ -n "$sess_ln" ] && [ "$launch_ln" -lt "$sess_ln" ]; then
  ok "a line the runner wrote before the session survives, ahead of the session's output"
else
  bad "pre-session log line survives" "rc=$rc log=$tl"
fi
r="$(new_repo)"; a="$(aux "$r")"
printf '#!/usr/bin/env bash\nexit 1\n' >"$a/stub-claude"
chmod +x "$a/stub-claude"
rc="$(run_runner "$r")"
f="$(cat "$(sd "$r")/runs/"*.failed 2>/dev/null || true)"
if grep -q 'session_output=empty' <<<"$f"; then
  ok "a silent session still reads empty with the runner's own launch line in the log"
else
  bad "empty verdict ignores runner lines" "rc=$rc record=$f"
fi

# `429` means an HTTP status. As a bare substring it matches pids, paths and
# SHAs the session prints. Fail-first case from DND-739.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked "$a/stub-claude" "worker pid 14290 exited; see /tmp/cache.429/a429bc"
rc="$(run_runner "$r")"
m="$(cat "$(sd "$r")/runs/"*.blocked 2>/dev/null || true)"
if [ "$rc" -eq 69 ] && grep -q 'classification=UNCLASSIFIED' <<<"$m"; then
  ok "a 429 inside a pid, path or SHA is NOT a rate-limit signature"
else
  bad "429 is anchored" "rc=$rc marker=$m"
fi
for msg in 'API Error: 429 {"type":"error"}' 'HTTP 429' 'upstream returned status 429'; do
  r="$(new_repo)"; a="$(aux "$r")"
  stub_claude_blocked_rc "$a/stub-claude" "$msg" 1
  rc="$(run_runner "$r")"
  m="$(cat "$(sd "$r")/runs/"*.blocked 2>/dev/null || true)"
  # The session log must hold the message byte-for-byte, quotes included, or
  # the case is not testing the string it names.
  if [ "$rc" -eq 69 ] && grep -q 'classification=blocked' <<<"$m" \
     && grep -qxF -- "$msg" "$(sd "$r")"/runs/*.log; then
    ok "a real HTTP 429 is still a block signature ('$msg', verbatim in the log)"
  else
    bad "HTTP 429 still matches ('$msg')" "rc=$rc marker=$m log=$(cat "$(sd "$r")"/runs/*.log 2>/dev/null)"
  fi
done

# A session that removes its own log (DND-833 critic round 1). Under
# `set -euo pipefail` the byte count of a missing log used to kill the runner
# on the spot: no teardown, no counter, no record, which is the silent outcome
# DND-833 exists to remove. And teardown's `>>"${log}"` re-creates the file, so
# the log's state must be taken when the session exits, not in section 8.
stub_claude_removes_log() { # $1 = path, $2 = exit code
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"\$(dirname "\$0")/claude-was-invoked"
echo "about to vanish"
rm -f -- "\${SHIPWRIGHT_RECEIPT%.receipt}.log"
exit $2
EOF
  chmod +x "$1"
}
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_removes_log "$a/stub-claude" 3
rc="$(run_runner "$r")"
f="$(cat "$(sd "$r")/runs/"*.failed 2>/dev/null || true)"
if [ "$rc" -eq 3 ] && grep -q 'session_output=missing' <<<"$f" \
   && [ "$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)" = "1" ] \
   && grep -q 'never reported for duty' "$a/runner.err"; then
  ok "a receipt-less failure whose log VANISHED is recorded as session_output=missing, and counted"
else
  bad "missing-log failure is recorded" "rc=$rc record=$f err=$(cat "$a/runner.err")"
fi
if [ -z "$(run_worktrees "$r")" ] && [ -z "$(run_branches "$r")" ]; then
  ok "and the runner survived to tear its lane down"
else
  bad "missing log does not abort teardown" "worktrees='$(run_worktrees "$r")' branches='$(run_branches "$r")'"
fi
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_removes_log "$a/stub-claude" 0
rc="$(run_runner "$r")"
m="$(cat "$(sd "$r")/runs/"*.blocked 2>/dev/null || true)"
if [ "$rc" -eq 69 ] && grep -q 'session_output=missing' <<<"$m" \
   && grep -q 'classification=UNCLASSIFIED' <<<"$m"; then
  ok "an exit-0 tick whose log vanished is BLOCKED, UNCLASSIFIED, and its marker says the log was missing"
else
  bad "missing-log blocked tick is recorded" "rc=$rc marker=$m err=$(cat "$a/runner.err")"
fi

# --- receipt RETENTION ------------------------------------------------------
#
# The receipt is this tick's durable evidence that the session reached the
# model. It used to be unlinked on the success path, which made a healthy past
# tick indistinguishable from a blocked one an hour later (both: no receipt on
# disk) and cost a run a wrong outage report about the outage detector. These
# cases pin retention, and pin that retention did not weaken the detector.

# The exact shape of the 2026-09-19 misreading: a HEALTHY NO-OP — reached the
# model, mined nothing, committed nothing. It must stay unblocked AND leave its
# receipt behind, because a no-commit tick has no other trace of liveness.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'printf "no harness changes warranted.\n"'
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1 \
   && ls "$(sd "$r")/runs/"*.receipt >/dev/null 2>&1; then
  ok "a healthy NO-OP tick RETAINS its receipt (a past healthy tick stays auditable)"
else
  bad "healthy no-op retains its receipt" \
      "rc=$rc runs=$(ls "$(sd "$r")/runs/" 2>&1)"
fi

# Retention must not be a special case of the no-op path.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "run work"'
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && ls "$(sd "$r")/runs/"*.receipt >/dev/null 2>&1; then
  ok "a healthy COMMITTING tick also retains its receipt (retention is unconditional)"
else
  bad "committing tick retains its receipt" \
      "rc=$rc runs=$(ls "$(sd "$r")/runs/" 2>&1)"
fi

# The negative side: a blocked tick must leave NO receipt, or a later reader
# would misread the retained file as evidence of liveness.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked "$a/stub-claude" "You've hit your weekly limit"
rc="$(run_runner "$r")"
if [ "$rc" -eq 69 ] && ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1 \
   && ! ls "$(sd "$r")/runs/"*.receipt >/dev/null 2>&1; then
  ok "a BLOCKED tick leaves no receipt (retention did not blur blocked vs healthy)"
else
  bad "blocked tick leaves no receipt" \
      "rc=$rc runs=$(ls "$(sd "$r")/runs/" 2>&1)"
fi

# Retention must not turn the detector into a directory-wide `ls`. A retained
# receipt from an EARLIER tick is planted directly (no timing dependence), and
# the current blocked tick must still be scored on its OWN ts-keyed path.
r="$(new_repo)"; a="$(aux "$r")"
mkdir -p "$(sd "$r")/runs"
: >"$(sd "$r")/runs/1999-01-01T000000.receipt"
stub_claude_blocked "$a/stub-claude" "You've hit your weekly limit"
rc="$(run_runner "$r")"
if [ "$rc" -eq 69 ] && ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1 \
   && [ -e "$(sd "$r")/runs/1999-01-01T000000.receipt" ]; then
  ok "an earlier tick's retained receipt cannot rescue a later BLOCKED tick (per-tick key)"
else
  bad "receipt is per-tick, not directory-wide" \
      "rc=$rc runs=$(ls "$(sd "$r")/runs/" 2>&1)"
fi

# A receipt must not reach into the failure path and soften a real failure.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 7 'printf "exploded\n"'
rc="$(run_runner "$r")"
if [ "$rc" -eq 7 ] && [ "$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)" = "1" ] \
   && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1; then
  ok "a receipt does not rescue a FAILING session (it still fails and still feeds the wedge)"
else
  bad "receipt cannot rescue a failure" \
      "rc=$rc counter=$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null)"
fi

# No receipt but commits landed => the session plainly did work. The
# conservative tip==BASE_COMMIT guard keeps that a success.
r="$(new_repo)"; a="$(aux "$r")"
cat >"$a/stub-claude" <<'EOF'
#!/usr/bin/env bash
echo "$@" >>"$(dirname "$0")/claude-was-invoked"
git commit --allow-empty -qm "work without a receipt"
exit 0
EOF
chmod +x "$a/stub-claude"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1; then
  ok "a receipt-less session that COMMITTED is not blocked (it demonstrably did work)"
else
  bad "commits override a missing receipt" "rc=$rc err=$(cat "$a/runner.err")"
fi

# A bad threshold fails loudly and still classifies.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_blocked "$a/stub-claude" "You've hit your weekly limit"
rc="$(run_runner "$r" SHIPWRIGHT_BLOCK_ESCALATE=notanumber)"
if [ "$rc" -eq 69 ] && grep -q 'not a positive integer' "$a/runner.err" \
   && grep -q 'Fix:' "$a/runner.err"; then
  ok "a non-numeric SHIPWRIGHT_BLOCK_ESCALATE falls back loudly and the tick still classifies"
else
  bad "bad block threshold" "rc=$rc err=$(cat "$a/runner.err")"
fi

# The marker vocabularies must stay disjoint: a dirty-tree yield precedes the
# session entirely, so it can never look like a blocked tick.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && ls "$(sd "$r")/runs/"*.skipped >/dev/null 2>&1 \
   && ! ls "$(sd "$r")/runs/"*.blocked >/dev/null 2>&1 \
   && [ ! -e "$(sd "$r")/consecutive-blocked" ]; then
  ok "a dirty-tree yield writes .skipped only — never .blocked, and never a blocked streak"
else
  bad "marker vocabularies disjoint" "rc=$rc runs=$(ls "$(sd "$r")/runs/" 2>&1)"
fi

# The brief must still name no checkout path, and must carry the receipt
# instruction UNEXPANDED (an expanded one would leak the path into the brief).
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
o="$(env DRY_RUN=1 SHIPWRIGHT_REPO="$r" SHIPWRIGHT_CLAUDE="$a/stub-claude" "$RUNNER" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'SHIPWRIGHT_RECEIPT' <<<"$o" \
   && ! grep -q 'dev/custom' <<<"$o" \
   && grep -q 'Sync your tree' <<<"$o"; then
  ok "the brief carries the receipt instruction unexpanded and still names no checkout path"
else
  bad "brief receipt instruction" "rc=$rc out=$o"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — stale dirt escalates ONCE to harness-alerts (DND-692)'

# The measured defect (2026-09-22..25): 84 consecutive hourly skips on inert
# leftovers in the main checkout (an abandoned node_modules and an
# erl_crash.dump, both days old). Each skip exited 0 and, by design, never
# counted toward the wedge, so three days of a dark loop produced no alert at
# all. "Yielded to a live editor" and "blocked forever by inert leftovers" read
# the same. These cases pin the difference.

ALERTS="${ATHENA_INBOX_ROOT}/harness-alerts/to-custom"
alert_msgs() { find "${ALERTS}" -maxdepth 1 -type f -name '*-shipwright-stale-dirt.md' 2>/dev/null | sort; }
alert_count() { alert_msgs | grep -c . || true; }
clear_alerts() { find "${ALERTS}" -maxdepth 1 -type f -name '*.md' -delete 2>/dev/null || true; }
old_file() { printf '%s\n' "${3:-leftover}" >"$1/$2"; touch -d '2 days ago' "$1/$2"; }

# Headline (fail-first): one untracked file older than the age threshold, the
# dirty branch run N times (default thresholds). Exactly one alert, naming the
# path, the first-seen tick and the owner's options.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
old_file "$r" erl_crash.dump
codes=""
for _ in 1 2 3; do codes="${codes}$(run_runner "$r") "; done
n="$(alert_count)"
if [ "$codes" = "0 0 0 " ] && [ "$n" = "1" ]; then
  ok "3 consecutive skips on one unchanged STALE signature write exactly one harness-alert (exit codes: ${codes% })"
else
  bad "stale dirt escalates" "codes='${codes% }' alerts=$n err=$(cat "$a/runner.err")"
fi
m="$(alert_msgs | head -n1)"
first="$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.skipped' -printf '%f\n' 2>/dev/null | sort | head -n1)"
first="${first%.skipped}"
if [ -n "$m" ] && grep -q 'erl_crash.dump' "$m" && grep -q '^Fix:' "$m" \
   && grep -qi 'commit' "$m" && grep -qi 'gitignore' "$m" && grep -qi 'remove' "$m" \
   && [ -n "$first" ] && grep -q "first_seen: ${first}" "$m"; then
  ok "the alert names the path, the first-seen tick (${first}) and a Fix: with commit / gitignore / remove"
else
  bad "alert content" "first=$first msg=$( [ -n "$m" ] && cat "$m")"
fi
if [ -n "$m" ] && grep -q '^from: inbox-client-detector' "$m" && grep -q '^to: custom' "$m" \
   && re="$(sed -n 's/^re: //p' "$m" | head -n1)" && [ -f "$re" ] \
   && case "$re" in "$(sd "$r")"/runs/*.skipped) true ;; *) false ;; esac; then
  ok "it is delivered on the harness-alerts maildir, re: the skip record of the alerting tick"
else
  bad "alert channel + re:" "msg=$( [ -n "$m" ] && cat "$m")"
fi
if grep -q 'dirt: STALE' "$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.skipped' | sort | tail -n1)"; then
  ok "every skip record now says whether the dirt was STALE or LIVE"
else
  bad "skip record classifies" "$(cat "$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.skipped' | sort | tail -n1)")"
fi

# The record the alert's re: names is its reader's authority, so it must carry
# the STALE verdict for the very signature the message states.
re="$( [ -n "$m" ] && sed -n 's/^re: //p' "$m" | head -n1)"
msig="$( [ -n "$m" ] && sed -n 's/^signature: //p' "$m" | head -n1)"
if [ -n "$msig" ] && [ -f "$re" ] && grep -q "^dirt: STALE .*signature=${msig}\$" "$re"; then
  ok "the re: record carries dirt: STALE with the message's own signature"
else
  bad "record authority" "sig=$msig re=$re record=$( [ -f "$re" ] && cat "$re")"
fi

# No repeat while the signature is unchanged.
codes=""
for _ in 1 2 3; do codes="${codes}$(run_runner "$r") "; done
if [ "$(alert_count)" = "1" ] && grep -q 'no repeat' "$a/runner.err"; then
  ok "no repeat alert while the signature is unchanged (the stderr says so)"
else
  bad "no repeat" "alerts=$(alert_count) err=$(cat "$a/runner.err")"
fi

# The signature changes (a second inert leftover appears) -> a new streak, and
# after N more skips a second alert naming both paths.
old_file "$r" stray.bak
run_runner "$r" >/dev/null; run_runner "$r" >/dev/null
if [ "$(alert_count)" = "1" ]; then
  ok "a changed signature starts a new streak (no alert before N skips on it)"
else
  bad "new streak waits for N" "alerts=$(alert_count)"
fi
run_runner "$r" >/dev/null
m2="$(alert_msgs | tail -n1)"
if [ "$(alert_count)" = "2" ] && grep -q 'erl_crash.dump' "$m2" && grep -q 'stray.bak' "$m2"; then
  ok "and the changed signature alerts once more after N skips, naming both paths"
else
  bad "changed signature re-alerts" "alerts=$(alert_count) msg=$( [ -n "$m2" ] && cat "$m2")"
fi

# A clean tree ends the streak and drops the state.
rm -f "$r/erl_crash.dump" "$r/stray.bak"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ ! -e "$(sd "$r")/stale-dirt" ]; then
  ok "a clean main checkout clears the stale-dirt state"
else
  bad "clean tree clears state" "rc=$rc state=$(cat "$(sd "$r")/stale-dirt" 2>&1)"
fi

# A LIVE editor never alerts: a fresh-mtime untracked file and a fresh tracked
# edit, skipped many times over.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'mid-edit\n' >"$r/new-draft.md"
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
codes=""
for _ in 1 2 3 4 5 6; do codes="${codes}$(run_runner "$r") "; done
if [ "$codes" = "0 0 0 0 0 0 " ] && [ "$(alert_count)" = "0" ] \
   && grep -q 'dirt: LIVE' "$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.skipped' | sort | tail -n1)"; then
  ok "a fresh-mtime (live) edit never alerts, however many ticks it yields (records say LIVE)"
else
  bad "live edit never alerts" "codes='${codes% }' alerts=$(alert_count)"
fi

# One fresh path among old ones makes the whole tree LIVE: the NEWEST mtime
# decides, because a human touching any dirty path is a live editor.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
old_file "$r" erl_crash.dump
printf 'mid-edit\n' >"$r/new-draft.md"
for _ in 1 2 3 4; do run_runner "$r" >/dev/null; done
if [ "$(alert_count)" = "0" ]; then
  ok "old leftovers beside one fresh edit do not alert (the newest mtime decides)"
else
  bad "newest mtime decides" "alerts=$(alert_count)"
fi

# A deleted tracked file has no mtime of its own. Its age is read from the
# nearest existing ancestor directory (a deletion updates it), never skipped: a
# path whose age cannot be read must not make the tree look fresh or empty.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
rm -f "$r/ai/agents/ours.md"
touch -d '2 days ago' "$r/ai/agents"
for _ in 1 2 3; do run_runner "$r" >/dev/null; done
m="$(alert_msgs | head -n1)"
if [ "$(alert_count)" = "1" ] && grep -q 'ai/agents/ours.md' "$m"; then
  ok "a deletion-only dirty tree is aged by its nearest existing ancestor and still escalates"
else
  bad "deleted path aged" "alerts=$(alert_count) err=$(cat "$a/runner.err")"
fi

# A failed send is LOUD, never marks the signature alerted, and the next tick
# retries. The tick itself still yields with exit 0 (the send is a report; it
# must never turn a yield into a failure or feed the wedge).
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
old_file "$r" erl_crash.dump
empty_root="${TMP}/empty-inbox-root"; mkdir -p "$empty_root"
codes=""
for _ in 1 2 3; do codes="${codes}$(run_runner "$r" ATHENA_INBOX_ROOT="$empty_root") "; done
if [ "$codes" = "0 0 0 " ] && [ "$(alert_count)" = "0" ] \
   && grep -q 'could NOT be sent' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err" \
   && [ ! -e "$(sd "$r")/consecutive-failures" ]; then
  ok "a failed harness-alert send is loud with a Fix:, still exits 0 and never feeds the wedge"
else
  bad "failed send is loud" "codes='${codes% }' alerts=$(alert_count) err=$(cat "$a/runner.err")"
fi
run_runner "$r" >/dev/null
if [ "$(alert_count)" = "1" ]; then
  ok "and the next tick with a working channel sends the alert (a failed send is never recorded as sent)"
else
  bad "retry after failed send" "alerts=$(alert_count) err=$(cat "$a/runner.err")"
fi

# The detector side has a second writer (the inbox-client watchdog) on the
# same identity. send-mail REFUSES while the other holds .sender.lock; the
# runner retries that refusal briefly instead of losing the tick's alert.
# The holder releases only once the runner has recorded a refused attempt, so
# the case always exercises the retry; it gives up after 30s, which fails the
# case rather than passing it.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
old_file "$r" erl_crash.dump
mkdir -p "${ALERTS}"; lockf="${ALERTS}/.sender.lock"; : >"${lockf}"
rm -f "${TMP}/lock-held"
runs="$(sd "$r")/runs"
( exec 7<>"${lockf}"; flock 7; : >"${TMP}/lock-held"
  for _ in $(seq 1 300); do
    grep -qs '^alert: sender lock busy' "${runs}"/*.skipped && break
    sleep 0.1
  done ) &
HOLDER_PID=$!
for _ in $(seq 1 100); do [ -e "${TMP}/lock-held" ] && break; sleep 0.1; done
rc="$(run_runner "$r" SHIPWRIGHT_STALE_DIRT_ESCALATE=1)"
wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""
rec="$(find "${runs}" -maxdepth 1 -name '*.skipped' | sort | tail -n1)"
if [ -e "${TMP}/lock-held" ] && [ "$rc" -eq 0 ] && [ "$(alert_count)" = "1" ] \
   && grep -q '^alert: sender lock busy (attempt 1/3); retrying$' "$rec" \
   && grep -q '^alert: harness-alerts ' "$rec"; then
  ok "a send refused because the other detector-side writer holds the lock is retried (the record shows the refusal) and delivered"
else
  bad "lock contention retried" "held=$([ -e "${TMP}/lock-held" ] && echo yes) rc=$rc alerts=$(alert_count) record=$(cat "$rec" 2>&1) err=$(cat "$a/runner.err")"
fi

# The attendant relays the RECORD's paths to the owner, never the message's.
# The raw list in the record is `status -uall`: an abandoned node_modules is
# every file in it (30k measured). So the record also carries a relay_paths
# block: untracked directories collapsed, at most 20 lines plus an "... and N
# more" tail, indented so no line of it can pass for the runner's dirt: line.
# The message's paths are that same block.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
# The owner's git config must not undo the collapse: showUntrackedFiles=all
# would list every file under node_modules/.
git -C "$r" config status.showUntrackedFiles all
mkdir -p "$r/node_modules/pkg"
for i in $(seq 1 40); do printf 'x\n' >"$r/node_modules/pkg/f$i.js"; done
for i in $(seq 1 24); do printf 'x\n' >"$r/stray-$i.log"; done
find "$r/node_modules" "$r"/stray-*.log -exec touch -h -d '2 days ago' {} +
run_runner "$r" SHIPWRIGHT_STALE_DIRT_ESCALATE=1 >/dev/null
rec="$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.skipped' | sort | tail -n1)"
block="$(sed -n '/^relay_paths:/,$p' "$rec" | sed '1d' | sed -n '/^  /!q;p')"
lines="$(printf '%s\n' "$block" | grep -c .)"
if [ "$lines" = "21" ] && grep -qx '  node_modules/' <<<"$block" \
   && ! grep -q 'node_modules/pkg' <<<"$block" \
   && grep -qx '  \.\.\. and 5 more' <<<"$block"; then
  ok "the skip record carries a collapsed, capped relay_paths block (node_modules/ as one line; 20 + '... and 5 more')"
else
  bad "record relay_paths" "lines=$lines record=$(cat "$rec" 2>&1)"
fi
m="$(alert_msgs | head -n1)"
mblock="$( [ -n "$m" ] && sed -n '/^paths:/,$p' "$m" | sed '1d' | sed -n '/^  /!q;p')"
if [ -n "$block" ] && [ "$mblock" = "$block" ]; then
  ok "the message names exactly the record's relay_paths block"
else
  bad "message paths = record relay_paths" "record=$block message=$mblock"
fi
if [ "$(grep -c '^dirt: ' "$rec")" = "1" ] && grep -q '^dirt: STALE ' "$rec"; then
  ok "the runner's dirt: line is the record's last line starting 'dirt: ' (the relay block is indented)"
else
  bad "last dirt: line" "record=$(cat "$rec" 2>&1)"
fi

# DND-1513: a stale-dirt send that exits 0 with no delivered line is not sent:
# recorded FAILED, never stored as alerted; and a state an older runner wrote
# as alerted=? is retried on the next skip.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'x\n' >"$r/stray.log"; touch -h -d '2 days ago' "$r/stray.log"
printf '#!/usr/bin/env bash\necho x >>"%s/quiet-calls"; exit 0\n' "$a" >"$a/quiet-send-mail"; chmod +x "$a/quiet-send-mail"
run_runner "$r" SHIPWRIGHT_STALE_DIRT_ESCALATE=1 SHIPWRIGHT_SEND_MAIL="$a/quiet-send-mail" >/dev/null
rec="$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.skipped' | sort | tail -n1)"
if [ "$(grep -c . "$a/quiet-calls" 2>/dev/null)" = 1 ] && grep -q '^alert: FAILED to send' "$rec" 2>/dev/null \
   && [ -z "$(sed -n 's/^alerted=//p' "$(sd "$r")/stale-dirt")" ] && [ "$(alert_msgs | grep -c .)" = 0 ]; then
  ok "a stale-dirt send that exits 0 with no delivered line is recorded FAILED and never stored as alerted"
else
  bad "quiet stale-dirt send" "record=$(cat "$rec" 2>&1) state=$(cat "$(sd "$r")/stale-dirt" 2>&1) err=$(cat "$a/runner.err")"
fi
sed -i 's/^alerted=.*/alerted=?/' "$(sd "$r")/stale-dirt"
next_second; run_runner "$r" SHIPWRIGHT_STALE_DIRT_ESCALATE=1 >/dev/null
if [ "$(alert_msgs | grep -c .)" = 1 ] && [ -n "$(sed -n 's/^alerted=//p' "$(sd "$r")/stale-dirt" | grep -v '^?$')" ]; then
  ok "a stale-dirt state stored as alerted=? by an older runner is retried and records the delivered name"
else
  bad "legacy stale-dirt alerted=?" "alerts=$(alert_msgs | grep -c .) state=$(cat "$(sd "$r")/stale-dirt" 2>&1) err=$(cat "$a/runner.err")"
fi

# A listing git cannot produce must fail, not print an empty list the
# attendant would relay as "no paths". Every git-reading function in the
# classifier is held to that.
nongit="${TMP}/not-a-repo"; mkdir -p "$nongit"
lib_rc() { ( . "${SCRIPTS}/lib/shipwright-stale-dirt.sh"; "$@" >/dev/null 2>&1 ); echo $?; }
if [ "$(lib_rc sd_display_paths "$nongit" 20)" != "0" ] \
   && [ "$(lib_rc sd_measure "$nongit")" != "0" ] \
   && [ "$(lib_rc sd_dirty_paths "$nongit")" != "0" ]; then
  ok "sd_display_paths, sd_measure and sd_dirty_paths each exit non-zero when git cannot read the checkout"
else
  bad "git failure is loud in the lib" "display=$(lib_rc sd_display_paths "$nongit" 20) measure=$(lib_rc sd_measure "$nongit") dirty=$(lib_rc sd_dirty_paths "$nongit")"
fi
r="$(new_repo)"
o="$( . "${SCRIPTS}/lib/shipwright-stale-dirt.sh"; sd_display_paths "$r" 20 )"
if [ -n "$o" ] && grep -q '^(none' <<<"$o"; then
  ok "a clean tree's relay list says (none ...) in words, never an empty block"
else
  bad "empty relay list is explicit" "out=$o"
fi

# The runner's own state under ai-artifacts/ is never dirt, so it can never
# alert on itself.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
mkdir -p "$(sd "$r")"; old_file "$(sd "$r")" leftover.log
for _ in 1 2 3; do run_runner "$r" >/dev/null; done
if [ "$(alert_count)" = "0" ] && [ -e "$a/claude-was-invoked" ]; then
  ok "old files under ai-artifacts/ are the runner's own state: no yield, no alert"
else
  bad "ai-artifacts excluded" "alerts=$(alert_count)"
fi

# Bad thresholds fall back loudly (a typo must never disable the escalation).
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
old_file "$r" erl_crash.dump
for _ in 1 2 3; do run_runner "$r" SHIPWRIGHT_STALE_DIRT_ESCALATE=x SHIPWRIGHT_STALE_DIRT_AGE_S=0 >/dev/null; done
if [ "$(alert_count)" = "1" ] && grep -q 'SHIPWRIGHT_STALE_DIRT_ESCALATE' "$a/runner.err" \
   && grep -q 'SHIPWRIGHT_STALE_DIRT_AGE_S' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "non-numeric/zero stale-dirt thresholds fall back to the defaults loudly and still escalate"
else
  bad "bad stale thresholds" "alerts=$(alert_count) err=$(cat "$a/runner.err")"
fi

# The thresholds are knobs: N=1 alerts on the first stale skip.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
old_file "$r" erl_crash.dump
run_runner "$r" SHIPWRIGHT_STALE_DIRT_ESCALATE=1 >/dev/null
if [ "$(alert_count)" = "1" ]; then
  ok "SHIPWRIGHT_STALE_DIRT_ESCALATE=1 alerts on the first stale skip"
else
  bad "escalate knob" "alerts=$(alert_count) err=$(cat "$a/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — a WEDGED tick leaves a record and alerts ONCE per episode (DND-834)'

# The measured defect (laptop, 2026-09-23..26): the lane wedged, and every
# hourly tick since exited 75 with an empty .log and nothing else in runs/. The
# only signal was the WEDGED line on stderr, which goes to cron mail, and that
# machine's mail spool has been empty since 2025. Nobody saw it for three days.
# So a wedged tick must leave a .wedged record in runs/, and the first tick of a
# wedge EPISODE sends ONE harness-alert. The episode ends when the counter is
# cleared; a later wedge is a new episode and alerts again.

wedge_msgs() { find "${ALERTS}" -maxdepth 1 -type f -name '*-shipwright-wedged.md' 2>/dev/null | sort; }
wedge_count() { wedge_msgs | grep -c . || true; }
newest_wedged() { find "$(sd "$1")/runs" -maxdepth 1 -name '*.wedged' 2>/dev/null | sort | tail -n1; }
# The runner keys records on a second-resolution ts. Two ticks in one second
# share a record path, so wait for the next second where a case compares records.
next_second() { local s; s="$(date +%s)"; for _ in $(seq 1 30); do [ "$(date +%s)" != "$s" ] && return 0; sleep 0.1; done; }
arm_wedge() { mkdir -p "$(sd "$1")"; printf '%s\n' "$2" >"$(sd "$1")/consecutive-failures"; }

# Headline (fail-first): a counter at the threshold. The tick exits 75, spawns
# nothing, and leaves a record naming why, the counter, the first-wedged time
# and the one-command re-arm. One alert, re: that record.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
arm_wedge "$r" 2
rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
rec="$(newest_wedged "$r")"
counter="$(real "$(sd "$r")")/consecutive-failures"
if [ "$rc" -eq 75 ] && [ ! -e "$a/claude-was-invoked" ] && [ -n "$rec" ]; then
  ok "a wedged tick still exits 75 and spawns nothing, and leaves a .wedged record in runs/"
else
  bad "wedged tick leaves a record" "rc=$rc spawned=$([ -e "$a/claude-was-invoked" ] && echo yes) runs=$(find "$(sd "$r")/runs" -maxdepth 1 -printf '%f ' 2>&1)"
fi
if [ -n "$rec" ] && grep -q '^wedged: consecutive_failures=2 threshold=2 first_wedged=[0-9TZ:-]* episode=[0-9T-]*$' "$rec" \
   && grep -qF "rearm: rm ${counter}" "$rec" && grep -q '^Fix: .*rm ' "$rec"; then
  ok "the record names the counter, the threshold, the first-wedged time, the episode and the re-arm command (Fix:)"
else
  bad "wedged record content" "counter=$counter record=$( [ -n "$rec" ] && cat "$rec")"
fi
if grep -qF "${rec:-<none>}" "$a/runner.err"; then
  ok "the WEDGED stderr names the record"
else
  bad "stderr names the record" "$(cat "$a/runner.err")"
fi
m="$(wedge_msgs | head -n1)"
ep="$( [ -n "$rec" ] && sed -n 's/^wedged: .* episode=//p' "$rec" | tail -n1)"
if [ "$(wedge_count)" = "1" ] && grep -q '^from: inbox-client-detector' "$m" && grep -q '^to: custom' "$m" \
   && [ "$(sed -n 's/^re: //p' "$m" | head -n1)" = "$rec" ] \
   && [ -n "$ep" ] && grep -qx "episode: ${ep}" "$m" && grep -qF "rm ${counter}" "$m" && grep -q '^Fix:' "$m"; then
  ok "ONE harness-alert, re: the record, carrying the record's episode and the re-arm command"
else
  bad "wedge alert" "alerts=$(wedge_count) ep=$ep msg=$( [ -n "$m" ] && cat "$m") err=$(cat "$a/runner.err")"
fi
if [ -n "$rec" ] && grep -qx "alert: harness-alerts $(basename -- "${m:-none}")" "$rec"; then
  ok "the record says which message the alert went out as"
else
  bad "record names the alert" "record=$( [ -n "$rec" ] && cat "$rec")"
fi

# Later ticks of the same episode: a record each, no second alert.
codes=""
for _ in 1 2; do next_second; codes="${codes}$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2) "; done
rec2="$(newest_wedged "$r")"
if [ "$codes" = "75 75 " ] && [ "$(wedge_count)" = "1" ] \
   && [ "$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.wedged' | grep -c .)" = "3" ] \
   && grep -q '^alert: already sent for this episode' "$rec2" \
   && grep -q "episode=${ep}\$" "$rec2" && grep -q 'already alerted' "$a/runner.err"; then
  ok "every tick of one episode leaves its own record, and no tick after the first alerts again"
else
  bad "one alert per episode" "codes='${codes% }' alerts=$(wedge_count) records=$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.wedged' | grep -c .) last=$(cat "$rec2" 2>&1)"
fi

# Re-arming ends the episode. The next wedge is a new episode and alerts again.
rm -f "$(sd "$r")/consecutive-failures"
next_second; rc1="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
if [ ! -e "$(sd "$r")/wedged" ]; then
  ok "the first tick after the re-arm ends the episode (its state is gone)"
else
  bad "re-arm ends the episode" "rc=$rc1 state=$(cat "$(sd "$r")/wedged" 2>&1)"
fi
next_second; run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2 >/dev/null
next_second; rc3="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
rec3="$(newest_wedged "$r")"
ep3="$(sed -n 's/^wedged: .* episode=//p' "$rec3" 2>/dev/null | tail -n1)"
if [ "$rc1" = "7" ] && [ "$rc3" = "75" ] && [ "$(wedge_count)" = "2" ] && [ -n "$ep3" ] && [ "$ep3" != "$ep" ]; then
  ok "a later wedge is a new episode: a new episode id and a second alert"
else
  bad "new episode alerts" "rc1=$rc1 rc3=$rc3 alerts=$(wedge_count) ep=$ep ep3=$ep3"
fi

# A re-arm followed, in one tick, by enough reaped dead cron corpses to wedge
# again is still a NEW episode: the episode check reads the counter before the
# reaper bumps it.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
arm_wedge "$r" 2
run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2 >/dev/null
rm -f "$(sd "$r")/consecutive-failures"
make_corpse "$r" run-dead-1 cron; make_corpse "$r" run-dead-2 cron
next_second; rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
if [ "$rc" -eq 75 ] && [ "$(wedge_count)" = "2" ]; then
  ok "a re-arm then corpses reaped into a wedge in the same tick is a new episode (second alert)"
else
  bad "re-arm then corpse wedge" "rc=$rc alerts=$(wedge_count) err=$(cat "$a/runner.err")"
fi

# A failed send is loud, keeps exit 75, is never recorded as sent, and the
# next tick of the same episode retries it.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
arm_wedge "$r" 2
empty_root="${TMP}/empty-inbox-root-834"; mkdir -p "$empty_root"
rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2 ATHENA_INBOX_ROOT="$empty_root")"
rec="$(newest_wedged "$r")"
if [ "$rc" -eq 75 ] && [ "$(wedge_count)" = "0" ] && grep -q 'could NOT be sent' "$a/runner.err" \
   && grep -q 'Fix:' "$a/runner.err" && grep -q '^alert: FAILED to send' "$rec" 2>/dev/null; then
  ok "a failed wedge alert is loud with a Fix:, recorded as FAILED, and the tick still exits 75"
else
  bad "failed wedge send is loud" "rc=$rc alerts=$(wedge_count) record=$(cat "$rec" 2>&1) err=$(cat "$a/runner.err")"
fi
next_second; rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
if [ "$rc" -eq 75 ] && [ "$(wedge_count)" = "1" ]; then
  ok "and the next tick of the episode sends it (a failed send is never recorded as sent)"
else
  bad "retry after failed wedge send" "rc=$rc alerts=$(wedge_count) err=$(cat "$a/runner.err")"
fi

# DND-1513: send-mail exits 0 but prints no delivered line. That is not a
# confirmed send: recorded FAILED, never stored as alerted (the old runner
# stored `?`), and the next tick of the episode sends it.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
arm_wedge "$r" 2
printf '#!/usr/bin/env bash\necho x >>"%s/quiet-calls"; exit 0\n' "$a" >"$a/quiet-send-mail"; chmod +x "$a/quiet-send-mail"
rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2 SHIPWRIGHT_SEND_MAIL="$a/quiet-send-mail")"
rec="$(newest_wedged "$r")"
if [ "$rc" -eq 75 ] && [ "$(grep -c . "$a/quiet-calls" 2>/dev/null)" = 1 ] && grep -q '^alert: FAILED to send' "$rec" 2>/dev/null \
   && grep -q "no 'athena:inbox: delivered' line" "$a/runner.err" && [ -z "$(sed -n 's/^alerted=//p' "$(sd "$r")/wedged")" ]; then
  ok "a wedge alert send that exits 0 with no delivered line is recorded FAILED and never stored as alerted"
else
  bad "quiet wedge send" "rc=$rc record=$(cat "$rec" 2>&1) state=$(cat "$(sd "$r")/wedged" 2>&1) err=$(cat "$a/runner.err")"
fi
next_second; rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
if [ "$rc" -eq 75 ] && [ "$(wedge_count)" = "1" ]; then
  ok "and the next tick of the episode sends it with the real send-mail"
else
  bad "retry after quiet wedge send" "rc=$rc alerts=$(wedge_count) err=$(cat "$a/runner.err")"
fi
# A state an older runner wrote as alerted=? is unconfirmed: retried.
clear_alerts
sed -i 's/^alerted=.*/alerted=?/' "$(sd "$r")/wedged"
next_second; rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
if [ "$rc" -eq 75 ] && [ "$(wedge_count)" = "1" ]; then
  ok "a wedge state stored as alerted=? by an older runner is retried"
else
  bad "legacy alerted=?" "rc=$rc alerts=$(wedge_count) state=$(cat "$(sd "$r")/wedged" 2>&1)"
fi

# A record that cannot be written is loud, sends nothing (the record is the
# alert's authority), and the tick still exits 75.
clear_alerts
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
arm_wedge "$r" 2
mkdir -p "$(sd "$r")/runs"; chmod 555 "$(sd "$r")/runs"
if [ -w "$(sd "$r")/runs" ]; then
  ok "(skipped: running as a user who can write a 0555 directory)"
else
  rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
  if [ "$rc" -eq 75 ] && [ "$(wedge_count)" = "0" ] \
     && grep -q 'could not write the wedge record' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
    ok "an unwritable wedge record is loud with a Fix:, sends nothing, and the tick still exits 75"
  else
    bad "unwritable wedge record" "rc=$rc alerts=$(wedge_count) err=$(cat "$a/runner.err")"
  fi
fi
chmod 755 "$(sd "$r")/runs"

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the post-landing main check backstop (DND-1482)'

# Every tick checks origin/main, even one that yields to a dirty main checkout:
# the check runs in its own lane and must not depend on the main checkout.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r" MH_STUB_LOG="$a/mh.log")"
if [ "$rc" -eq 0 ] && [ "$(cat "$a/mh.log" 2>/dev/null)" = "check --repo $(real "$r") --wait 60 --slot-wait 900" ]; then
  ok "a yielding tick still runs main-health check --repo <main checkout>"
else
  bad "main-health runs every tick" "rc=$rc mh='$(cat "$a/mh.log" 2>&1)' err=$(cat "$a/runner.err")"
fi

# A RED main or a check that could not measure never changes the tick's exit
# code, and each is named on stderr with where its log is.
for mrc in 1 3; do
  r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
  printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
  rc="$(run_runner "$r" MH_STUB_LOG="$a/mh.log" MH_STUB_RC="$mrc")"
  if [ "$rc" -eq 0 ] && grep -q 'main-health' "$a/runner.err" && grep -q '\.main-health\.log' "$a/runner.err"; then
    ok "main-health exit ${mrc}: the tick's exit code is unchanged (0) and the outcome is logged with its log path"
  else
    bad "main-health exit ${mrc} is isolated" "rc=$rc err=$(cat "$a/runner.err")"
  fi
done
if grep -q 'Fix:' "$a/runner.err"; then
  ok "a check that could not measure carries a Fix: line"
else
  bad "could-not-measure Fix:" "err=$(cat "$a/runner.err")"
fi

# A missing main-health is loud: origin/main was NOT checked, never silently.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r" SHIPWRIGHT_MAIN_HEALTH="$a/no-such-main-health")"
if [ "$rc" -eq 0 ] && grep -q 'NOT checked' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "a missing main-health says origin/main was NOT checked, with a Fix:"
else
  bad "missing main-health is loud" "rc=$rc err=$(cat "$a/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the scheduled Slack roots snapshot (DND-1502)'

# Every tick runs slack-roots-tick, even one that yields to a dirty main
# checkout: a root that rotates out between two runs is lost for good.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r" SR_STUB_LOG="$a/sr.log")"
sr="$(cat "$a/sr.log" 2>/dev/null)"
sr_want_head="--state-dir $(real "$r")/ai-artifacts/slack-roots --tick "
sr_want_tail=" --timeout 600"
if [ "$rc" -eq 0 ] && [ "$(grep -c . "$a/sr.log" 2>/dev/null)" = 1 ] \
   && [ "${sr#"$sr_want_head"}" != "$sr" ] && [ "${sr%"$sr_want_tail"}" != "$sr" ]; then
  ok "a yielding tick still runs slack-roots-tick once, with the main checkout's ai-artifacts/slack-roots state dir"
else
  bad "slack-roots-tick runs every tick" "rc=$rc sr='$sr' err=$(cat "$a/runner.err")"
fi

# A tick that reaches the session keeps the tool's output: it goes to its own
# runs/<ts>.slack-roots.log, which the session's log write cannot truncate.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
rc="$(run_runner "$r" SR_STUB_LOG="$a/sr.log")"
srl="$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.slack-roots.log' 2>/dev/null | head -n 1)"
if [ "$rc" -eq 0 ] && [ -n "$srl" ] && grep -q 'stub-slack-roots-tick stderr' "$srl" \
   && [ "$(grep -c . "$a/sr.log" 2>/dev/null)" = 1 ]; then
  ok "a tick that ran its session keeps slack-roots-tick's output in runs/<ts>.slack-roots.log"
else
  bad "slack-roots log survives the session" "rc=$rc srl='$srl' content=$(cat "$srl" 2>&1) err=$(cat "$a/runner.err")"
fi

# A skipped tool tick (its lock held) is logged as skipped, not as ran.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
sr_skip_stub="$a/stub-sr-skip"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in --state-dir) d="$2";; --tick) t="$2";; esac; shift; done\nmkdir -p "$d/runs"; : > "$d/runs/$t.skipped"\nexit 0\n' > "$sr_skip_stub"
chmod +x "$sr_skip_stub"
rc="$(run_runner "$r" SHIPWRIGHT_SLACK_ROOTS="$sr_skip_stub")"
if [ "$rc" -eq 0 ] && grep -q 'slack roots: skipped' "$a/runner.err" && ! grep -q 'propose ran' "$a/runner.err"; then
  ok "a slack-roots-tick that skipped on its lock is logged as skipped, not as ran"
else
  bad "skip logged as skip" "rc=$rc err=$(cat "$a/runner.err")"
fi

# A wedged lane still snapshots the roots (the step is before the wedge guard).
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 7
arm_wedge "$r" 2
rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2 SR_STUB_LOG="$a/sr.log")"
if [ "$rc" -eq 75 ] && [ "$(grep -c . "$a/sr.log" 2>/dev/null)" = 1 ]; then
  ok "a wedged tick (exit 75) still runs slack-roots-tick"
else
  bad "wedged tick snapshots" "rc=$rc sr='$(cat "$a/sr.log" 2>&1)'"
fi

# A failed propose or a tool that could not run never changes the tick's exit
# code, and each is named on stderr.
for src in 1 3; do
  r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
  printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
  rc="$(run_runner "$r" SR_STUB_LOG="$a/sr.log" SR_STUB_RC="$src")"
  if [ "$rc" -eq 0 ] && grep -q 'slack roots' "$a/runner.err"; then
    ok "slack-roots-tick exit ${src}: the tick's exit code is unchanged (0) and the outcome is logged"
  else
    bad "slack-roots-tick exit ${src} is isolated" "rc=$rc err=$(cat "$a/runner.err")"
  fi
done
if grep -q 'Fix:' "$a/runner.err"; then
  ok "a slack-roots-tick that could not run carries a Fix: line"
else
  bad "slack-roots could-not-run Fix:" "err=$(cat "$a/runner.err")"
fi

# A missing tool is loud: the roots were NOT snapshotted, never silently.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r" SHIPWRIGHT_SLACK_ROOTS="$a/no-such-slack-roots-tick")"
if [ "$rc" -eq 0 ] && grep -q 'NOT snapshotted' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "a missing slack-roots-tick says the roots were NOT snapshotted, with a Fix:"
else
  bad "missing slack-roots-tick is loud" "rc=$rc err=$(cat "$a/runner.err")"
fi

# ---------------------------------------------------------------------------
# DND-1603: a scripts/lib file the runner sources must not be a silent exit.
# The runner's own libs cannot be removed in place, so each case runs a copy of
# the runner beside a copy of its libs, minus the one under test.
sx_runner() { # <aux dir> [<lib file to omit>...] -> prints the copy's path
  local a="$1" l; shift
  mkdir -p "$a/sx/scripts/lib" "$a/sx/ai/lib"
  cp -- "$RUNNER" "${SCRIPTS}/reap-orphan-dbus" "$a/sx/scripts/"
  cp -- "${SCRIPTS}"/lib/*.sh "$a/sx/scripts/lib/"
  cp -- "${REPO_ROOT}/ai/lib/harness-alert-send.sh" "$a/sx/ai/lib/"
  for l in "$@"; do rm -f -- "$a/sx/scripts/lib/$l"; done
  printf '%s' "$a/sx/scripts/athena-shipwright-run.sh"
}
REAL_RUNNER="$RUNNER"
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
RUNNER="$(sx_runner "$a")"
rc="$(run_runner "$r")"
if [ "$rc" = 0 ] && [ -e "$a/claude-was-invoked" ]; then
  ok "control: the fixture copy with every lib present runs a healthy tick"
else
  bad "control copy" "rc=$rc err=$(cat "$a/runner.err")"
fi
for lib in dbus-env.sh shipwright-stale-dirt.sh; do
  r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
  RUNNER="$(sx_runner "$a" "$lib")"
  rc="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
  rec="$(find "$(sd "$r")/runs" -maxdepth 1 -name '*.failed' 2>/dev/null | sort | tail -n1)"
  if [ "$rc" = 78 ] && [ ! -e "$a/claude-was-invoked" ] && [ "$(cat "$(sd "$r")/consecutive-failures" 2>/dev/null || echo 0)" = 1 ] \
     && [ -n "$rec" ] && grep -q "scripts/lib/$lib" "$rec" && grep -q "scripts/lib/$lib" "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
    ok "$lib missing: exit 78, a .failed record naming it, the wedge counter at 1, Fix:, no session"
  else
    bad "$lib missing" "rc=$rc rec=$( [ -n "$rec" ] && cat "$rec") err=$(cat "$a/runner.err")"
  fi
  next_second; run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2 >/dev/null
  next_second; rc3="$(run_runner "$r" SHIPWRIGHT_FAIL_ESCALATE=2)"
  if [ "$rc3" = 75 ] && [ -n "$(newest_wedged "$r")" ] && [ ! -e "$a/claude-was-invoked" ]; then
    ok "$lib missing: the lane wedges at the threshold like any counted failure"
  else
    bad "$lib wedge" "rc=$rc3 wedged=$(newest_wedged "$r")"
  fi
done
RUNNER="$REAL_RUNNER"

# DND-1667: no git call may have fallen through past a git stub.
if fsg_verify; then ok "no git call fell through past its stub (DND-1667)"
else bad "no git call fell through past its stub (DND-1667)" "see the forge-stub-guard FAIL above"; fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || {
  printf 'Fix: read each FAIL line above — it names the guarantee that broke. Re-run with: bash scripts/test/athena-shipwright/self-test.sh\n' >&2
  exit 1
}
exit 0
