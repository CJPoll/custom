#!/usr/bin/env bash
# worktree-escape-guard.self-test.sh -- the worktree-escape guard's matrix
# (DND-840). Declared in ai/bin/harness-gate. Pipes PreToolUse JSON shaped like
# the payload measured on Claude Code 2.1.283 (session_id, transcript_path,
# cwd, permission_mode, tool_name, tool_input, and agent_id + agent_type inside
# a subagent) into the REAL hook, against throwaway repos under a fake HOME.
#
# The hook under test is ai/hooks/worktree-escape-guard.sh. WEG_HOOK_UNDER_TEST
# overrides it; that exists ONLY so the fail-first evidence can run this suite
# against an allow-everything stub (the behaviour before the hook existed).
#
# Matrix:
#   * a subagent writing a main-checkout path (Edit/Write/MultiEdit/
#     NotebookEdit, a symlink into it, a not-yet-existing file) -> deny, and the
#     Fix: names the worktree its dispatch prompt named;
#   * the same subagent writing its worktree, gitignored runtime state, a .git
#     internal, a repo with no worktrees outside ~/dev, or a non-repo -> allow;
#   * a subagent's mutating git / shell write whose target is the main checkout
#     (cwd, -C, cd, ~, $HOME, a variable set in the same command) -> deny;
#     ff-only publishing, fetch, worktree add, and every read-only command
#     (including quoted payloads and heredoc bodies that MENTION writes) ->
#     allow;
#   * the attended top-level session (the interactive main session) -> allow,
#     always; an unattended top-level session whose project dir is a linked
#     worktree -> deny; one rooted in the main checkout -> allow;
#   * unparseable stdin, an unparseable command, or an unresolvable target ->
#     allow WITH a visible warning / a log line, never a silent pass.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="${WEG_HOOK_UNDER_TEST:-${HERE}/worktree-escape-guard.sh}"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }

for dep in jq python3 git; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "worktree-escape-guard self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -x "${HOOK}" ] || { echo "worktree-escape-guard self-test: FAIL -- ${HOOK} is missing or not executable"; echo "  Fix: restore ai/hooks/worktree-escape-guard.sh (chmod +x)."; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
TMP="$(cd "${TMP}" && pwd -P)"

export HOME="${TMP}/home"
export XDG_STATE_HOME="${TMP}/state"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "${HOME}/dev" "${XDG_STATE_HOME}"
LOG="${XDG_STATE_HOME}/athena/worktree-escape-guard.log"
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# The main checkout under ~/dev, with a linked worktree elsewhere.
MAIN="${HOME}/dev/proj"
WT="${HOME}/.local/worktrees/proj/feat"
mkdir -p "${MAIN}/sub" "$(dirname "${WT}")"
printf 'a\n' > "${MAIN}/a.txt"
printf 'b\n' > "${MAIN}/sub/b.txt"
printf '{}\n' > "${MAIN}/nb.ipynb"
printf 'ai-artifacts/\n' > "${MAIN}/.gitignore"
G -C "${MAIN}" init -q && G -C "${MAIN}" add -A && G -C "${MAIN}" commit -q -m init
G -C "${MAIN}" worktree add -q "${WT}" -b feat
mkdir -p "${MAIN}/ai-artifacts/reports"

# A main checkout under ~/dev with NO worktree (still the owner's shared surface).
SOLO="${HOME}/dev/solo"
mkdir -p "${SOLO}" && printf 's\n' > "${SOLO}/s.txt"
G -C "${SOLO}" init -q && G -C "${SOLO}" add -A && G -C "${SOLO}" commit -q -m init

# A scratch repo outside ~/dev with no worktree (not a shared surface).
SCRATCH="${TMP}/scratch"
mkdir -p "${SCRATCH}" && printf 'x\n' > "${SCRATCH}/x.txt"
G -C "${SCRATCH}" init -q && G -C "${SCRATCH}" add -A && G -C "${SCRATCH}" commit -q -m init

# ~/.claude/skills resolves INTO the main checkout (the live-harness case).
mkdir -p "${MAIN}/skills/foo" "${HOME}/.claude"
printf 's\n' > "${MAIN}/skills/foo/SKILL.md"
G -C "${MAIN}" add -A && G -C "${MAIN}" commit -q -m skills
ln -s "${MAIN}/skills" "${HOME}/.claude/skills"

# Transcripts: the session transcript, and a subagent transcript whose FIRST
# line is the dispatch prompt naming the worktree (the measured layout:
# <dir of transcript_path>/<session_id>/subagents/agent-<agent_id>.jsonl).
SID="11111111-2222-3333-4444-555555555555"
TDIR="${TMP}/projects/p"
TRANSCRIPT="${TDIR}/${SID}.jsonl"
mkdir -p "${TDIR}/${SID}/subagents"
: > "${TRANSCRIPT}"
jq -n -c --arg w "${WT}" '{type: "user", agentId: "a1", message: {role: "user", content: ("You are athena-captain-X. Worktree: " + $w + " (branch feat). Work ONLY there.")}}' \
  > "${TDIR}/${SID}/subagents/agent-a1.jsonl"

# payload <agent_id-or-empty> <tool> <tool_input-json> [cwd]
payload() {
  jq -n -c --arg a "$1" --arg t "$2" --argjson i "$3" --arg c "${4:-${MAIN}}" \
    --arg s "${SID}" --arg tp "${TRANSCRIPT}" '
    {session_id: $s, transcript_path: $tp, cwd: $c, permission_mode: "bypassPermissions",
     hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i, tool_use_id: "t1", prompt_id: "p1"}
    + (if $a == "" then {} else {agent_id: $a, agent_type: "athena-captain"} end)'
}

# run <attended 0|1|unset> <project-dir> <stdin> -> sets OUT
run() {
  local att="$1" proj="$2" in="$3"
  if [ "${att}" = "unset" ]; then
    OUT="$(printf '%s' "${in}" | env -u CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PROJECT_DIR="${proj}" "${HOOK}" 2>/dev/null)"
  else
    OUT="$(printf '%s' "${in}" | CLAUDE_CODE_SESSION_ATTENDED="${att}" CLAUDE_PROJECT_DIR="${proj}" "${HOOK}" 2>/dev/null)"
  fi
  RC=$?
}
decision() { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'unparseable'; }
reason()   { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

# expect <label> <deny|allow> -- after run
expect() {
  local got; got="$(decision)"
  [ -z "${OUT}" ] && got="allow"
  if [ "${RC}" -ne 0 ]; then bad "$1" "hook exited ${RC} (a PreToolUse hook error blocks or noises the call): ${OUT}"; return; fi
  if [ "${got}" = "$2" ]; then ok "$1"; else bad "$1" "expected $2, got ${got}: ${OUT}"; fi
}
# sub <label> <deny|allow> <tool> <input-json> [cwd] -- a captain subagent
sub() { run 0 "${MAIN}" "$(payload a1 "$3" "$4" "${5:-${MAIN}}")"; expect "$1" "$2"; }
# bash_sub <label> <deny|allow> <command> [cwd]
bash_sub() { sub "$1" "$2" Bash "$(jq -n -c --arg c "$3" '{command: $c}')" "${4:-${MAIN}}"; }
w() { jq -n -c --arg p "$1" '{file_path: $p, content: "x"}'; }

echo "== Edit-family tools, captain subagent =="
sub "Write a tracked main-checkout file -> deny (the DND-807 incident)" deny Write "$(w "${MAIN}/a.txt")"
R="$(reason)"
case "${R}" in *"Fix:"*"${WT}/a.txt"*) ok "deny reason carries Fix: naming the worktree copy of the file" ;; *) bad "deny reason names the worktree" "${R}" ;; esac
case "${R}" in *"git checkout --"*) ok "deny reason warns off the git checkout -- revert" ;; *) bad "deny reason warns off git checkout --" "${R}" ;; esac
sub "Edit a main-checkout file -> deny" deny Edit "$(jq -n -c --arg p "${MAIN}/sub/b.txt" '{file_path: $p, old_string: "b", new_string: "c"}')"
sub "MultiEdit a main-checkout file -> deny" deny MultiEdit "$(jq -n -c --arg p "${MAIN}/a.txt" '{file_path: $p, edits: []}')"
sub "NotebookEdit a main-checkout notebook -> deny" deny NotebookEdit "$(jq -n -c --arg p "${MAIN}/nb.ipynb" '{notebook_path: $p, new_source: "x"}')"
sub "Write a NEW file under a not-yet-existing main dir -> deny" deny Write "$(w "${MAIN}/new/deep/f.txt")"
sub "Write through ~/.claude/skills (symlink into main) -> deny" deny Write "$(w "${HOME}/.claude/skills/foo/SKILL.md")"
sub "Write the worktree copy -> allow" allow Write "$(w "${WT}/a.txt")"
sub "Write gitignored runtime state under main/ai-artifacts -> allow" allow Write "$(w "${MAIN}/ai-artifacts/reports/r.md")"
sub "Write a .git internal of main -> allow (not the working tree)" allow Write "$(w "${MAIN}/.git/info/exclude")"
sub "Write a scratch repo outside ~/dev with no worktree -> allow" allow Write "$(w "${SCRATCH}/x.txt")"
sub "Write a non-repo path -> allow" allow Write "$(w "${TMP}/elsewhere/f.txt")"
sub "Write a ~/dev main checkout with no worktree -> deny" deny Write "$(w "${SOLO}/s.txt")"
case "$(reason)" in *"Fix:"*"worktree add"*) ok "no-worktree deny tells how to create one" ;; *) bad "no-worktree deny tells how to create one" "$(reason)" ;; esac

echo "== subagent with no readable dispatch transcript =="
run 0 "${MAIN}" "$(payload a-missing Write "$(w "${MAIN}/a.txt")")"
expect "subagent, transcript absent -> still deny" deny
case "$(reason)" in *"Fix:"*"${WT}"*) ok "Fix: falls back to listing the repo's worktrees" ;; *) bad "Fix: lists worktrees when transcript absent" "$(reason)" ;; esac

echo "== top-level sessions =="
run 1 "${MAIN}" "$(payload "" Write "$(w "${MAIN}/a.txt")")"
expect "interactive main session (attended, no agent_id) writes main -> allow" allow
run 1 "${MAIN}" "$(payload "" Bash '{"command":"git reset --hard && git checkout -- a.txt"}')"
expect "interactive main session mutating git in main -> allow" allow
run 1 "${WT}" "$(payload "" Write "$(w "${MAIN}/a.txt")" "${WT}")"
expect "attended human session rooted in a worktree writes main -> allow (human present)" allow
run 0 "${WT}" "$(payload "" Write "$(w "${MAIN}/a.txt")" "${WT}")"
expect "unattended top-level session dispatched into a worktree writes main -> deny" deny
case "$(reason)" in *"Fix:"*"${WT}/a.txt"*) ok "top-level deny names the session's worktree" ;; *) bad "top-level deny names worktree" "$(reason)" ;; esac
run 0 "${MAIN}" "$(payload "" Write "$(w "${MAIN}/a.txt")")"
expect "unattended top-level session rooted in main -> allow (not dispatched into a worktree)" allow
run unset "${WT}" "$(payload "" Write "$(w "${MAIN}/a.txt")" "${WT}")"
expect "attendance unknown, rooted in a worktree -> deny (unknown is not attended)" deny

echo "== Bash: mutating git, captain subagent (cwd resets to the main checkout) =="
bash_sub "git checkout -- a.txt with cwd=main -> deny (the incident's revert)" deny "git checkout -- a.txt"
bash_sub "git -C MAIN checkout -- a.txt -> deny" deny "git -C ${MAIN} checkout -- a.txt"
bash_sub "git add -A && git commit with cwd=main -> deny" deny "git add -A && git commit -m wip"
bash_sub "git -C MAIN restore a.txt -> deny" deny "git -C ${MAIN} restore a.txt"
bash_sub "git -C MAIN reset --hard -> deny" deny "git -C ${MAIN} reset --hard"
bash_sub "git -C MAIN merge feat (not ff-only) -> deny" deny "git -C ${MAIN} merge feat"
bash_sub "git -C MAIN pull (not ff-only) -> deny" deny "git -C ${MAIN} pull"
bash_sub "git -c k=v -C MAIN commit -> deny" deny "git -c core.pager=cat -C ${MAIN} commit -am x"
bash_sub "env-prefixed git -> deny" deny "GIT_PAGER=cat git -C ${MAIN} add ."
bash_sub "timeout-wrapped git -> deny" deny "timeout 30 git -C ${MAIN} add ."
bash_sub "absolute /usr/bin/git -> deny" deny "/usr/bin/git -C ${MAIN} clean -fd"
bash_sub "git -C ~/dev/proj (tilde) -> deny" deny "git -C ~/dev/proj reset --hard"
bash_sub "git -C \"\$HOME/dev/proj\" -> deny" deny "git -C \"\$HOME/dev/proj\" add ."
bash_sub "cd MAIN/sub && git add . -> deny" deny "cd ${MAIN}/sub && git add ."
bash_sub "git apply patch with cwd=main -> deny" deny "git apply p.diff"
bash_sub "git -C MAIN checkout (no space) after && -> deny" deny "true&&git -C ${MAIN} switch feat"
bash_sub "cd WT && git add -A && git commit -> allow" allow "cd ${WT} && git add -A && git commit -m wip"
bash_sub "git -C WT checkout -- a.txt -> allow" allow "git -C ${WT} checkout -- a.txt"
bash_sub "variable set in the same command: W=WT; cd \$W && git add -> allow" allow "W=${WT}; cd \"\$W\" && git add ."
bash_sub "git -C MAIN merge --ff-only (publishing) -> allow" allow "git -C ${MAIN} merge --ff-only feat"
bash_sub "git -C MAIN pull --ff-only -> allow" allow "git -C ${MAIN} pull --ff-only"
bash_sub "git -C MAIN fetch -> allow" allow "git -C ${MAIN} fetch origin"
bash_sub "git -C MAIN worktree add -> allow" allow "git -C ${MAIN} worktree add ../x -b y origin/main"
bash_sub "git status/log/diff in main -> allow" allow "git status && git log --oneline -3 && git diff HEAD"
bash_sub "git apply --check in main -> allow" allow "git apply --check p.diff"
bash_sub "git clean -n (dry run) in main -> allow" allow "git clean -n"
bash_sub "git commit -n is --no-verify, a real commit -> deny (critic round 3)" deny "git -C ${MAIN} commit -n -am wip"
bash_sub "git add -n (dry run) in main -> allow" allow "git -C ${MAIN} add -n ."
bash_sub "git commit --dry-run in main -> allow" allow "git -C ${MAIN} commit --dry-run"
bash_sub "if/then: a git add inside then -> deny (critic round 4)" deny "cd ${MAIN} && if ! git diff --quiet; then git add -A; fi"
bash_sub "for/do: rm inside do -> deny (critic round 4)" deny "for f in a b; do rm -f ${MAIN}/a.txt; done"
bash_sub "brace group: git reset inside { } -> deny (critic round 4)" deny "{ git -C ${MAIN} reset --hard; }"
bash_sub "while loop reading only -> allow" allow "while read l; do echo \"\$l\"; done < ${MAIN}/a.txt"
bash_sub "unquoted backtick substitution -> deny" deny "echo \`git -C ${MAIN} reset --hard\`"
bash_sub "bash -c SCRIPT with a main write -> deny" deny "bash -c 'git -C ${MAIN} checkout -- a.txt'"
bash_sub "sh -lc SCRIPT reading only -> allow" allow "sh -lc 'git -C ${MAIN} status'"
bash_sub "git submodule update in main -> deny" deny "git -C ${MAIN} submodule update --init"
bash_sub "git submodule status in main -> allow" allow "git -C ${MAIN} submodule status"
bash_sub "git format-patch -o into main -> deny" deny "git -C ${WT} format-patch -o ${MAIN}/patches HEAD~1"
bash_sub "git diff --output into ignored main path -> allow" allow "git -C ${MAIN} diff --output=${MAIN}/ai-artifacts/d.diff"
bash_sub "cmd >& MAIN/file (both streams) -> deny" deny "ls >& ${MAIN}/out.txt"
bash_sub "cd -P WT && git add . -> allow (cd options are not the dir)" allow "cd -P ${WT} && git add ."
bash_sub "commit message MENTIONING git reset/rm (quoted) -> allow" allow "cd ${WT} && git commit -m \"do not git -C ${MAIN} reset --hard; rm ${MAIN}/a.txt\""
bash_sub "heredoc body MENTIONING writes -> allow" allow "$(printf 'cd %s && git commit -F - <<%sEOF%s\nrm -rf %s/a.txt\ngit -C %s reset --hard\necho x > %s/a.txt\nEOF\ngit log -1' "${WT}" "'" "'" "${MAIN}" "${MAIN}" "${MAIN}")"
bash_sub "here-string then a write on the next line -> deny (critic round 2)" deny "$(printf 'read x <<<abc\nrm -f %s/a.txt' "${MAIN}")"
bash_sub "quoted <<EOF in a commit message then a write -> deny (critic round 2)" deny "$(printf 'cd %s && git commit -m "see <<EOF"\ncd %s && git add .' "${WT}" "${MAIN}")"
bash_sub "<<- heredoc with a tab-indented delimiter, write after it -> deny" deny "$(printf 'cat <<-EOF\n\trm -rf %s\n\tEOF\necho x > %s/a.txt' "${MAIN}" "${MAIN}")"
bash_sub "<<- heredoc body only MENTIONS a write -> allow" allow "$(printf 'cat <<-EOF\n\trm -rf %s\n\tEOF\necho done' "${MAIN}")"
bash_sub "pushd WT; popd; git add . (cwd back to main) -> deny" deny "pushd ${WT}; popd; git add ."
bash_sub "comment MENTIONING a write -> allow" allow "git status # then git -C ${MAIN} reset --hard"

echo "== Bash: shell writes =="
bash_sub "echo > MAIN/a.txt -> deny" deny "echo hi > ${MAIN}/a.txt"
bash_sub "echo >> relative file with cwd=main -> deny" deny "echo hi >> notes.txt"
bash_sub "tee into main -> deny" deny "ls 2>&1 | tee ${MAIN}/log.txt"
bash_sub "sed -i on a main file -> deny" deny "sed -i s/a/b/ ${MAIN}/a.txt"
bash_sub "sed -Ei.bak on a main file -> deny" deny "sed -Ei.bak -e s/a/b/ ${MAIN}/a.txt"
bash_sub "cp into main -> deny" deny "cp ${TMP}/x ${MAIN}/a.txt"
bash_sub "mv out of main -> deny (removes a main file)" deny "mv ${MAIN}/a.txt ${TMP}/"
bash_sub "rm a main file -> deny" deny "rm -f ${MAIN}/a.txt"
bash_sub "rm -r on a main dir -> deny (-r takes no value; critic round 1)" deny "rm -r ${MAIN}/skills/foo"
bash_sub "rm -d on a main dir -> deny (-d takes no value; critic round 1)" deny "rm -d ${MAIN}/sub"
bash_sub "touch -d DATE on a main file -> deny (touch -d does take a value)" deny "touch -d 2020-01-01 ${MAIN}/a.txt"
bash_sub "touch relative with cwd=main -> deny" deny "touch a.txt"
bash_sub "a subshell's cd does not leak: (cd WT && git add .); git add . -> deny" deny "(cd ${WT} && git add .); git add ."
bash_sub "cd inside a subshell still counts inside it -> allow" allow "(cd ${WT} && git add -A)"
bash_sub "git bisect start in main -> deny" deny "git -C ${MAIN} bisect start"
bash_sub "git bisect log in main -> allow" allow "git -C ${MAIN} bisect log"
bash_sub "ln into main -> deny" deny "ln -sf ${TMP}/x ${MAIN}/link"
bash_sub "echo > main/ai-artifacts (ignored) -> allow" allow "echo hi > ${MAIN}/ai-artifacts/reports/r.md"
bash_sub "rm -rf main/ai-artifacts subtree (ignored) -> allow" allow "rm -rf ${MAIN}/ai-artifacts/tmp"
bash_sub "cd WT && touch a.txt -> allow" allow "cd ${WT} && touch a.txt"
bash_sub "redirect to /dev/null and 2>&1 -> allow" allow "git status >/dev/null 2>&1"
bash_sub "cp FROM main to elsewhere -> allow" allow "cp ${MAIN}/a.txt ${TMP}/copy.txt"
bash_sub "sed -n (read-only) on main -> allow" allow "sed -n 1p ${MAIN}/a.txt"
bash_sub "awk with braces in a quoted payload -> allow (DND-799/800 class)" allow "awk '{print \$1}' ${MAIN}/a.txt"
bash_sub "jq with braces and brackets -> allow" allow "jq -c '{a: .b[0]}' ${MAIN}/x.json"
bash_sub "grep for write words -> allow" allow "grep -rn 'git checkout -- ' ${MAIN} | head"
bash_sub "cat a main file -> allow" allow "cat ${MAIN}/a.txt"
bash_sub "redirect into the worktree -> allow" allow "echo x > ${WT}/n.txt"

echo "== fail loud, not silent =="
: > "${LOG}" 2>/dev/null || { mkdir -p "$(dirname "${LOG}")"; : > "${LOG}"; }
bash_sub "unresolvable cd target then git add -> allow" allow "cd \"\$SOMEWHERE_UNSET\" && git add ."
grep -q 'unresolved' "${LOG}" && ok "unresolvable target is logged as unresolved" || bad "unresolvable target is logged" "$(cat "${LOG}")"
bash_sub "unparseable command (unclosed quote) with a write -> allow" allow "echo 'oops > ${MAIN}/a.txt"
grep -q 'unparsed' "${LOG}" && ok "unparseable command is logged" || bad "unparseable command is logged" "$(cat "${LOG}")"
run 0 "${MAIN}" "not json at all"
expect "unparseable stdin -> allow (never wedge every session)" allow
case "${OUT}" in *systemMessage*worktree-escape-guard*) ok "unparseable stdin carries a visible warning" ;; *) bad "unparseable stdin warns" "${OUT}" ;; esac
run 0 "${MAIN}" ""
expect "empty stdin -> allow" allow
bash_sub "a deny after the log was truncated -> deny" deny "rm -f ${MAIN}/a.txt"
grep -q 'deny' "${LOG}" && ok "denials are logged" || bad "denials are logged" "$(cat "${LOG}")"

echo "== --help =="
HELP="$("${HOOK}" --help </dev/null)"; HRC=$?
[ "${HRC}" -eq 0 ] && case "${HELP}" in *worktree-escape-guard*) true ;; *) false ;; esac && ok "--help prints usage on stdout, exit 0" || bad "--help" "rc=${HRC} ${HELP}"

echo
echo "worktree-escape-guard self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || { echo "Fix: the hook's decision diverged from the matrix above; fix ai/hooks/worktree-escape-guard.sh, not the expectation."; exit 1; }
exit 0
