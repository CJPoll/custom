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

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
COMMIT="${SCRIPTS}/athena-shipwright-commit.sh"
RUNNER="${SCRIPTS}/athena-shipwright-run.sh"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
RUNNER_PID=""

cleanup() {
  # Reap by PID only. A `pkill -f` here could match a real shipwright run or a
  # sibling worktree's suite.
  if [ -n "$RUNNER_PID" ]; then
    kill "$RUNNER_PID" 2>/dev/null
    wait "$RUNNER_PID" 2>/dev/null
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

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
  # (~/.config/git/gitignore, which carries `ai-artifacts/`). It is not part of
  # this repository, and leaving it in play would silently make the
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

stub_claude() {
  # $1 = path to create, $2 = exit code. Records that it ran.
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "\$@" >"\$(dirname "\$0")/claude-was-invoked"
exit $2
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
if git -C "$r" status --porcelain | grep -q 'bystander.conf$' \
   && git -C "$r" status --porcelain | grep -q '?? bystander.conf.bak'; then
  ok "leaves the bystander's modified file AND untracked stray dirty and uncommitted"
else
  bad "leaves the bystander's work alone" "$(git -C "$r" status --porcelain)"
fi
if printf '%s' "$out" | grep -q 'dirty outside this commit'; then
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
if git -C "$r" diff --cached --name-only | grep -q 'bystander.conf'; then
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
if printf '%s' "$out" | grep -q 'bystander.conf'; then
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
# the runner's own logs, run.lock and skip records, and is gitignored only by a
# machine-local rule that is not in this repository — so on a checkout without
# that rule the foreign-dirt notice would list the shipwright's own output
# forever, which is how a real notice gets learned-past. (core.excludesFile is
# neutralised in every fixture, so this case is not vacuous.)
r="$(new_repo)"
mkdir -p "$r/ai-artifacts/shipwright/runs"
printf 'log\n' >"$r/ai-artifacts/shipwright/runs/2026.log"
printf 'edit\n' >"$r/ai/agents/ours.md"
out="$(cd "$r" && "$COMMIT" -m 'narrow' -- ai/agents/ours.md 2>&1)"
if ! printf '%s' "$out" | grep -q 'ai-artifacts'; then
  ok "the shipwright's own runtime artifacts are not reported as foreign dirt"
else
  bad "ai-artifacts excluded from the foreign-dirt notice" "$out"
fi
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
printf 'edit2\n' >"$r/ai/agents/ours.md"
out="$(cd "$r" && "$COMMIT" -m 'narrow again' -- ai/agents/ours.md 2>&1)"
if printf '%s' "$out" | grep -q 'bystander.conf'; then
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
if [ "$rc" -eq 2 ] && printf '%s' "$o" | grep -q 'Fix:'; then
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
  if ! printf '%s' "$o" | grep -q 'Fix:'; then
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
if [ "$rc" -eq 3 ] && printf '%s' "$o" | grep -q 'Fix:'; then
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
if git -C "$r" status --porcelain | grep -q 'NOTES.md'; then
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
   && git -C "$r" log -1 --format=%b | grep -q 'body paragraph'; then
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
if [ "$rc" -eq 2 ] && printf '%s' "$o" | grep -q 'Fix:'; then
  ok "an unreadable -F file exits 2 with a Fix: line, before git is involved"
else
  bad "unreadable -F is a caller error" "rc=$rc out=$o"
fi

# --help must reach the exit codes. A usage range that stopped at the "Exit
# codes:" header printed the header and none of the codes — the reader most
# likely to run --help is the one who just got a non-zero exit.
o="$("$COMMIT" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q 'Usage:' \
   && printf '%s' "$o" | grep -q 'nothing to commit'; then
  ok "--help prints usage through the last exit code"
else
  bad "--help is complete" "rc=$rc out=$o"
fi
o="$("$RUNNER" --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q 'SHIPWRIGHT_SKIP_ESCALATE'; then
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
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q 'ai/agents/ours.md' \
   && [ "$(git -C "$r" rev-list --count HEAD)" = "1" ] \
   && [ -z "$(git -C "$r" diff --cached --name-only)" ]; then
  ok "--dry-run prints the path set and neither stages nor commits"
else
  bad "--dry-run is inert" "rc=$rc out=$o"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the yield guard'

run_runner() { # run_runner <repo> [env...] ; echoes rc
  local repo="$1"; shift
  local a; a="$(aux "$repo")"
  env "$@" SHIPWRIGHT_REPO="$repo" SHIPWRIGHT_CLAUDE="${a}/stub-claude" \
    "$RUNNER" >"${a}/runner.out" 2>"${a}/runner.err"
  echo $?
}

r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ]; then ok "a dirty tree skips the tick with exit 0 (a skip is not a failure)"
else bad "dirty tree exits 0" "rc=$rc $(cat "$a/runner.err")"; fi
if [ ! -e "$a/claude-was-invoked" ]; then
  ok "and no headless session is started at all"
else
  bad "no claude on a dirty tree" "stub ran: $(cat "$a/claude-was-invoked")"
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

# An UNTRACKED stray alone is dirt too — the .bak in the real incident was
# untracked, and a guard that only looked at tracked files would have missed it.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'stray\n' >"$r/somebody.bak"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ ! -e "$a/claude-was-invoked" ]; then
  ok "an untracked-only stray also yields the tick"
else
  bad "untracked stray yields" "rc=$rc"
fi

# Clean tree: the run proceeds.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ -e "$a/claude-was-invoked" ]; then
  ok "a clean tree runs normally (the guard is not a blanket stop)"
else
  bad "clean tree runs" "rc=$rc err=$(cat "$a/runner.err")"
fi

# The shipwright's OWN state must never trip its successor. These fixtures carry
# no ignore rule for ai-artifacts/ on purpose (see new_repo): the real repo is
# covered only by a machine-local ~/.config/git/gitignore that is not in the
# repository, so a runner that leaned on it would yield forever — silently, at
# exit 0 — on any checkout without that rule. A second run after a first is the
# real shape of this.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
rc="$(run_runner "$r")"
rm -f "$a/claude-was-invoked"
rc2="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -e "$a/claude-was-invoked" ]; then
  ok "a run's own logs/lock/.skipped records do not make the NEXT run yield, with no ignore rule in play"
else
  bad "shipwright state does not trip its successor" "rc=$rc rc2=$rc2 err=$(cat "$a/runner.err")"
fi
if [ -n "$(git -C "$r" status --porcelain -uall | grep '^?? ai-artifacts/')" ]; then
  ok "and that state really is untracked in the fixture (so the case is not vacuous)"
else
  bad "fixture actually exercises the exclusion" "$(git -C "$r" status --porcelain -uall)"
fi

# A WEDGED lane must not read as a quiet one. A stray file nobody clears stops
# the shipwright indefinitely, and an hourly exit 0 is exactly what a healthy
# idle lane looks like. After the threshold the skip becomes a non-zero exit.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'abandoned stray\n' >"$r/somebody.bak"
codes=""
for _ in 1 2 3; do codes="${codes}$(run_runner "$r" SHIPWRIGHT_SKIP_ESCALATE=3) "; done
if [ "$codes" = "0 0 75 " ]; then
  ok "consecutive skips escalate to a non-zero exit at the threshold (got: ${codes% })"
else
  bad "wedged lane escalates" "exit codes were '${codes% }', want '0 0 75'"
fi
if grep -q 'WEDGED' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "and the escalation says it is wedged, with a Fix: line"
else
  bad "escalation message" "$(cat "$a/runner.err")"
fi
if [ ! -e "$a/claude-was-invoked" ]; then
  ok "and still never started a session on the dirty tree"
else
  bad "escalation does not imply running anyway" "stub ran"
fi

# The counter measures CONSECUTIVE skips: a run that actually starts resets it,
# so an occasional passing editor never accumulates into a false wedge alarm.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'transient\n' >"$r/somebody.bak"
run_runner "$r" SHIPWRIGHT_SKIP_ESCALATE=3 >/dev/null
run_runner "$r" SHIPWRIGHT_SKIP_ESCALATE=3 >/dev/null
rm "$r/somebody.bak"
run_runner "$r" SHIPWRIGHT_SKIP_ESCALATE=3 >/dev/null     # a real run: resets
printf 'transient again\n' >"$r/somebody.bak"
codes=""
for _ in 1 2; do codes="${codes}$(run_runner "$r" SHIPWRIGHT_SKIP_ESCALATE=3) "; done
if [ "$codes" = "0 0 " ]; then
  ok "a successful run resets the counter (two skips after it do not escalate)"
else
  bad "counter counts consecutive skips only" "exit codes '${codes% }', want '0 0'"
fi

# A non-numeric threshold must not silently disable the escalation. The `-ge`
# test sits in an `if` condition, which exempts its error from `set -e`, so the
# script would fall through to the quiet exit 0 forever — the wedged-lane
# invariant defeated by a typo, with only a shell diagnostic to show for it.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'abandoned stray\n' >"$r/somebody.bak"
codes=""
for _ in 1 2 3 4 5 6 7; do
  codes="${codes}$(run_runner "$r" SHIPWRIGHT_SKIP_ESCALATE=notanumber) "
done
if printf '%s' "$codes" | grep -q '75'; then
  ok "a non-numeric SHIPWRIGHT_SKIP_ESCALATE falls back to the default and still escalates (got: ${codes% })"
else
  bad "bad SHIPWRIGHT_SKIP_ESCALATE does not disable escalation" "exit codes '${codes% }' — none was 75"
fi
if grep -q 'not a positive integer' "$a/runner.err" && grep -q 'Fix:' "$a/runner.err"; then
  ok "and says so with a Fix: line rather than degrading silently"
else
  bad "bad threshold is reported" "$(cat "$a/runner.err")"
fi

# The documented override.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
rc="$(run_runner "$r" SHIPWRIGHT_ALLOW_DIRTY=1)"
if [ "$rc" -eq 0 ] && [ -e "$a/claude-was-invoked" ]; then
  ok "SHIPWRIGHT_ALLOW_DIRTY=1 overrides the guard (a human escape hatch exists)"
else
  bad "override works" "rc=$rc err=$(cat "$a/runner.err")"
fi

# The guard must not swallow the session's own failure.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 7
rc="$(run_runner "$r")"
if [ "$rc" -eq 7 ]; then
  ok "a failing session still propagates its exit code (the guard adds no false green)"
else
  bad "session exit code propagates" "rc=$rc"
fi

# DRY_RUN prints the brief without consulting git at all — it must work from a
# dirty tree, since that is when a human is most likely to be inspecting it.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude "$a/stub-claude" 0
printf 'AGENT MID-EDIT\n' >"$r/bystander.conf"
o="$(env DRY_RUN=1 SHIPWRIGHT_REPO="$r" SHIPWRIGHT_CLAUDE="$a/stub-claude" "$RUNNER" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q 'athena-shipwright agent'; then
  ok "DRY_RUN=1 still prints the brief from a dirty tree"
else
  bad "DRY_RUN from a dirty tree" "rc=$rc out=$o"
fi

# The brief must not name a checkout path. The agent template owns where the run
# happens; a path restated in the brief is a second source of truth, and it DID
# drift — after the worktree change landed the brief still said `~/dev/custom`,
# the main checkout the change exists to keep the run out of, and only the
# template's supersession label stopped an agent following it literally.
o="$(env DRY_RUN=1 SHIPWRIGHT_REPO="$r" SHIPWRIGHT_CLAUDE="$a/stub-claude" "$RUNNER" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && ! printf '%s' "$o" | grep -q 'dev/custom' \
   && printf '%s' "$o" | grep -q 'Sync your tree'; then
  ok "the brief names no checkout path (it cannot contradict the template)"
else
  bad "brief names a checkout path" "rc=$rc out=$o"
fi

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the single-run lock still holds'

# Two runs must not interleave: the second skips rather than queueing. The first
# is held open by a stub that blocks on a fifo, so the overlap is deterministic
# rather than timing-dependent.
r="$(new_repo)"; a="$(aux "$r")"
# This stub holds the first run open until the suite releases it, so the overlap
# is deterministic rather than timing-dependent. Its wait is a bounded poll with
# a real sleep (never a spin) and it gives up on its own, so a failed case can
# never leave a stub running past the suite.
cat >"$a/stub-claude" <<'EOF'
#!/usr/bin/env bash
A="$(dirname "$0")"
echo ran >>"$A/claude-was-invoked"
for _ in $(seq 1 300); do
  [ -e "$A/release" ] && exit 0
  sleep 0.1
done
exit 0
EOF
chmod +x "$a/stub-claude"
env SHIPWRIGHT_REPO="$r" SHIPWRIGHT_CLAUDE="$a/stub-claude" "$RUNNER" >/dev/null 2>&1 &
RUNNER_PID=$!
# Wait for the first run to actually hold the lock — bounded, with a real sleep.
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
  # The lock must say WHO holds it. A zero-byte lock with no pid is
  # indistinguishable from a leftover file, and on 2026-09-18 one was deleted by
  # hand for exactly that reason — which is the one way to actually get two runs.
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
else
  bad "first run reached the stub" "$(ls -a "$a")"
fi
: >"$a/release"
wait "$RUNNER_PID" 2>/dev/null
RUNNER_PID=""

# ---------------------------------------------------------------------------
case_ 'athena-shipwright-run.sh — the run happens in a worktree, the memory does not'

# A stub that records where it was run and what state directory it was handed.
# "Where" is the whole point of this section: a session started in the main
# checkout shares an index and a set of working files with whoever else is
# typing there, which is the class ce70e04 came from.
stub_claude_probe() { # $1 = path, $2 = exit code, $3 = extra shell line
  cat >"$1" <<EOF
#!/usr/bin/env bash
d="\$(dirname "\$0")"
echo "\$@" >"\$d/claude-was-invoked"
pwd -P >"\$d/claude-cwd"
printf '%s\n' "\${SHIPWRIGHT_STATE_DIR:-<unset>}" >"\$d/claude-state-dir"
${3:-:}
exit $2
EOF
  chmod +x "$1"
}

real() { ( cd "$1" 2>/dev/null && pwd -P ); }

r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
rc="$(run_runner "$r")"
wt="$r/.git/athena-shipwright"
if [ "$rc" -eq 0 ] && [ -e "$wt/.git" ]; then
  ok "the runner provisions a worktree inside the repo's own .git"
else
  bad "worktree provisioned" "rc=$rc $(cat "$a/runner.err" 2>&1)"
fi
if [ "$(cat "$a/claude-cwd" 2>/dev/null)" = "$(real "$wt")" ]; then
  ok "and starts the session THERE, not in the main checkout"
else
  bad "session runs in the worktree" "cwd=$(cat "$a/claude-cwd" 2>/dev/null) wanted=$(real "$wt")"
fi
# The worktree living inside .git is what makes this hold with no dependence on
# a gitignore rule — the machine-local one is neutralised in this fixture.
if [ -z "$(git -C "$r" status --porcelain -uall | grep -v '^?? ai-artifacts/')" ]; then
  ok "and the main checkout does not see the worktree as dirt (no ignore rule in play)"
else
  bad "main checkout stays clean" "$(git -C "$r" status --porcelain -uall)"
fi
if [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "shipwright/auto" ]; then
  ok "on its own branch, so it never contends for main with the checkout that holds it"
else
  bad "worktree branch" "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>&1)"
fi

# THE STATE GOTCHA. ai-artifacts/ is gitignored, so a worktree starts with no
# cursor.txt and no journal.md. If the state directory were derived from the
# tree the run executes in, every run would see an empty one — and an absent
# cursor reads the same as a cursor at epoch, so the run either re-mines
# everything or mines nothing, and both report success. State must resolve to
# the main checkout however the run is invoked.
if [ "$(cat "$a/claude-state-dir" 2>/dev/null)" = "$r/ai-artifacts/shipwright" ]; then
  ok "the session is handed SHIPWRIGHT_STATE_DIR in the MAIN checkout, not its own tree"
else
  bad "state dir is anchored" "got=$(cat "$a/claude-state-dir" 2>/dev/null) wanted=$r/ai-artifacts/shipwright"
fi
if ls "$r"/ai-artifacts/shipwright/runs/*.log >/dev/null 2>&1 \
   && [ ! -e "$wt/ai-artifacts" ]; then
  ok "and the run log lands there too — no state is written into the worktree"
else
  bad "logs land in the main checkout" "$(ls -R "$r/ai-artifacts" "$wt/ai-artifacts" 2>&1 | head -20)"
fi

# Landing on main: the agent pushes, but the MAIN CHECKOUT must also advance.
# ~/.claude/skills and ~/.claude/hooks resolve into it, so a harness change that
# never reaches it never takes effect — every run would report success while
# nothing on the machine changed.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'git commit --allow-empty -qm "run work"'
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r")"
after="$(git -C "$r" rev-parse HEAD)"
if [ "$rc" -eq 0 ] && [ "$after" != "$before" ] \
   && [ "$after" = "$(git -C "$r/.git/athena-shipwright" rev-parse HEAD)" ]; then
  ok "a run's commits reach the main checkout by fast-forward"
else
  bad "main checkout fast-forwards" "rc=$rc before=$before after=$after $(cat "$a/runner.err" 2>&1)"
fi

# ...but never by overwriting a bystander. --ff-only is what makes the one
# main-checkout action safe: git refuses it rather than clobbering live work.
r="$(new_repo)"; a="$(aux "$r")"
stub_claude_probe "$a/stub-claude" 0 'printf "shipwright\n" > bystander.conf; git commit -qam "conflicting work"'
printf 'HUMAN MID-EDIT\n' >"$r/bystander.conf"
before="$(git -C "$r" rev-parse HEAD)"
rc="$(run_runner "$r" SHIPWRIGHT_ALLOW_DIRTY=1)"
if [ "$(git -C "$r" rev-parse HEAD)" = "$before" ] \
   && [ "$(cat "$r/bystander.conf")" = "HUMAN MID-EDIT" ]; then
  ok "a fast-forward that would overwrite a live edit is refused, and the edit survives"
else
  bad "ff-only protects live work" "rc=$rc head=$(git -C "$r" rev-parse HEAD) file=$(cat "$r/bystander.conf")"
fi
if grep -q 'Fix:' "$a/runner.err" && grep -q 'could not be fast-forwarded' "$a/runner.err"; then
  ok "and the refusal is reported with a Fix:, not swallowed"
else
  bad "ff failure is reported" "$(cat "$a/runner.err")"
fi

# Dirt in the RUN WORKTREE is not a bystander — nobody else works there — so it
# is a previous run that died between editing and committing. It must yield and
# escalate like any other wedge, NEVER be reset away: a lane that discards its
# own tree every tick destroys real work and can never accumulate a skip, so the
# wedge escalation would be unreachable.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
rc="$(run_runner "$r")"              # first run creates the worktree
wt="$r/.git/athena-shipwright"
printf 'LEFTOVER\n' >"$wt/ai/agents/ours.md"
rm -f "$a/claude-was-invoked"
rc="$(run_runner "$r")"
if [ "$rc" -eq 0 ] && [ ! -e "$a/claude-was-invoked" ] \
   && grep -q 'ai/agents/ours.md' "$a/runner.err"; then
  ok "a previous run's leftovers in the worktree yield the tick"
else
  bad "worktree dirt yields" "rc=$rc invoked=$([ -e "$a/claude-was-invoked" ] && echo yes) $(cat "$a/runner.err")"
fi
if [ "$(cat "$wt/ai/agents/ours.md")" = "LEFTOVER" ]; then
  ok "and they are left intact — the runner never resets its own tree out from under a crashed run"
else
  bad "leftovers survive" "$(cat "$wt/ai/agents/ours.md")"
fi
if grep -q "PREVIOUS RUN's leftovers" "$a/runner.err" && grep -q "$wt" "$a/runner.err"; then
  ok "and the message says which tree they are in and whose they are"
else
  bad "dirt message distinguishes the trees" "$(cat "$a/runner.err")"
fi

# There is no fallback to the main checkout. An unusable worktree path must be a
# loud failure, because "run in the main checkout instead" is precisely the
# behaviour this section exists to remove.
r="$(new_repo)"; a="$(aux "$r")"; stub_claude_probe "$a/stub-claude" 0
printf 'not a worktree\n' >"$a/blocked"
rc="$(run_runner "$r" SHIPWRIGHT_WORKTREE="$a/blocked")"
if [ "$rc" -ne 0 ] && [ ! -e "$a/claude-was-invoked" ]; then
  ok "an unusable worktree path fails the run instead of falling back to the main checkout"
else
  bad "no main-checkout fallback" "rc=$rc invoked=$([ -e "$a/claude-was-invoked" ] && echo yes) $(cat "$a/runner.err")"
fi
if grep -q 'Fix:' "$a/runner.err"; then
  ok "and says how to clear it"
else
  bad "worktree failure is actionable" "$(cat "$a/runner.err")"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || {
  printf 'Fix: read each FAIL line above — it names the guarantee that broke. Re-run with: bash scripts/test/athena-shipwright/self-test.sh\n' >&2
  exit 1
}
exit 0
