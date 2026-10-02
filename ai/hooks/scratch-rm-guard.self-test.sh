#!/bin/sh
# Self-test for scratch-rm-guard.sh (DND-1653).
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts deny/allow.
# Functional only (DND-1222): one pass, no load. Hermetic: HOME and
# XDG_STATE_HOME point into one trap-removed temp dir, TMPDIR is unset, and
# nothing is deleted -- the hook only reads command TEXT. Scratchpad paths
# under /tmp are path strings that need not exist; the symlink case builds a
# real tree under CLAUDE_CODE_TMPDIR=<temp dir>.
#
# SRG_HOOK=<path> runs the cases against another hook (used to record the
# regression evidence: with no guard every deny case fails).
#
# Exit 0 iff every case passes.

HOOK="${SRG_HOOK:-$(dirname -- "$(realpath -- "$0")")/scratch-rm-guard.sh}"
[ -x "${HOOK}" ] || { echo "FAIL: hook not executable at ${HOOK}. Fix: chmod +x it, or restore it from git."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is not on PATH. Fix: install jq; the cases are built with it."; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp -d failed. Fix: check /tmp is writable."; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
export HOME="${TMP}/home" XDG_STATE_HOME="${TMP}/state"
mkdir -p "${HOME}"
unset TMPDIR CLAUDE_CODE_TMPDIR

U=$(id -u)
BASE="/tmp/claude-${U}"
SP="${BASE}/-home-x-dev-proj/11111111-2222-3333-4444-555555555555/scratchpad"
SID_DIR="${BASE}/-home-x-dev-proj/11111111-2222-3333-4444-555555555555"

PASS=0
FAIL=0

# run <command> [cwd] [tool] -> OUT, RC
run() {
  _in=$(jq -cn --arg c "$1" --arg d "${2:-/home/x/dev/proj}" --arg t "${3:-Bash}" \
    '{session_id:"s1",hook_event_name:"PreToolUse",tool_name:$t,cwd:$d,tool_input:{command:$c}}')
  OUT=$(printf '%s' "${_in}" | "${HOOK}" 2>/dev/null)
  RC=$?
}
decision() {
  if [ -z "${OUT}" ]; then printf 'allow'; return; fi
  printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'unparseable'
}
reason() { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s -- %s\n' "$1" "$2"; }

# expect <label> <deny|allow> <command> [cwd]
expect() {
  run "$3" "$4"
  _got=$(decision)
  if [ "${RC}" -ne 0 ]; then bad "$1" "hook exited ${RC}: ${OUT}"; return; fi
  if [ "${_got}" != "$2" ]; then bad "$1" "expected $2, got ${_got}: ${OUT}"; return; fi
  if [ "$2" = "deny" ] && ! reason | grep -q 'Fix:'; then bad "$1" "deny carries no Fix: ${OUT}"; return; fi
  # A crash or an unchecked input is an ALLOW with a warning; a clean allow is silent.
  if [ "$2" = "allow" ] && [ -n "${OUT}" ] && [ "${OUT}" != "{}" ]; then bad "$1" "allowed, but not cleanly: ${OUT}"; return; fi
  ok "$1"
}

echo "== glob delete in a scratchpad: denied =="
expect "the DND-1621 incident: rm -f <sp>/dnd-1601-*" deny "rm -f ${SP}/dnd-1601-*"
expect "quoted directory, unquoted glob" deny "rm -f \"${SP}\"/dnd-1601-*"
expect "variable assigned in the same command" deny "S=${SP}; rm -f \"\$S\"/dnd-*"
expect "exported variable" deny "export S=${SP} && rm \$S/*.log"
expect "relative glob after cd" deny "cd ${SP} && rm -f dnd-*"
expect "relative glob, stdin cwd is the scratchpad" deny "rm -f *.log" "${SP}"
expect "bracket glob" deny "rm -f ${SP}/[ab].log"
expect "glob in a per-mission subdirectory" deny "rm -f ${SP}/dnd-1653/*"
expect "glob in a parent component" deny "rm -rf ${BASE}/*/*/scratchpad/x"
expect "** reaches every scratchpad" deny "rm -f /tmp/**/dnd-1601-x"
expect "unlink with a glob" deny "unlink ${SP}/x*"
expect "rm -- glob" deny "rm -f -- ${SP}/x*"

echo "== recursive delete of a scratchpad or above it: denied =="
expect "rm -rf the scratchpad" deny "rm -rf ${SP}"
expect "rm -r the session dir above it" deny "rm -r ${SID_DIR}"
expect "rm -rf the claude tmp root" deny "rm -rf ${BASE}"
expect "rm --recursive /tmp" deny "rm --recursive --force /tmp"
expect "flags after the path (GNU permutes)" deny "rm ${SID_DIR} -rf"
expect "abbreviated --rec" deny "rm --rec ${SID_DIR}"
expect "-- ends options: a later -rf is a path" allow "rm -- ${SID_DIR} -rf"

echo "== find and xargs: denied =="
expect "find -delete in the scratchpad" deny "find ${SP} -name 'dnd-1601-*' -delete"
expect "find -exec rm" deny "find ${SP} -name x -exec rm -f {} +"
expect "find -delete from /tmp reaches every scratchpad" deny "find /tmp -name '*.log' -mtime +1 -delete"
expect "find | xargs rm" deny "find ${SP} -name 'x-*' | xargs rm -f"
expect "ls glob | xargs rm" deny "ls ${SP}/x-* | xargs -n1 rm"

echo "== indirection: denied =="
expect "for loop over a glob" deny "for f in ${SP}/dnd-*; do rm \"\$f\"; done"
expect "sh -c script" deny "sh -c 'rm -f ${SP}/dnd-*'"
expect "bash -lc script" deny "bash -lc \"rm -f ${SP}/dnd-*\""
expect "heredoc fed to bash" deny "bash <<'EOF'
rm -f ${SP}/dnd-*
EOF"
expect "eval" deny "eval \"rm -f ${SP}/x*\""
expect "timeout wrapper" deny "timeout 5 rm -f ${SP}/x*"
expect "sudo -u wrapper" deny "sudo -u me rm -f ${SP}/x*"
expect "env -C wrapper with a relative glob" deny "env -C ${SP} FOO=1 rm -f x*"
expect "test-slot wrapper" deny "test-slot --label t -- rm -f ${SP}/x*"
expect "inside a command substitution" deny "echo \$(rm -f ${SP}/x*)"
expect "after && in a chain" deny "true && rm -f ${SP}/x* || true"

expect "rm of a substitution listing by glob" deny "rm -f \$(ls ${SP}/dnd-1601-*)"
expect "rm of a substitution running find" deny "rm -f \$(find ${SP} -name 'dnd-1601-*')"
expect "rm of a backtick substitution" deny "rm -f \`ls ${SP}/x-*\`"
expect "trap clean-up by glob" deny "trap 'rm -f ${SP}/dnd-1653-*' EXIT"
expect "find -exec sh -c rm" deny "find ${SP} -name 'x*' -exec sh -c 'rm \"\$1\"' _ {} \\;"
expect "find -execdir rm" deny "find ${SP} -name 'x*' -execdir rm {} +"
expect "find -ok shred" deny "find ${SP} -name 'x*' -ok shred -u {} \\;"
expect "xargs -0 rm" deny "find ${SP} -name 'x*' -print0 | xargs -0 rm -f"
expect "xargs -I{} rm" deny "ls ${SP}/x-* | xargs -I{} rm -f {}"
expect "xargs -r rm" deny "ls ${SP}/x-* | xargs -r rm"
expect "dash -c" deny "dash -c 'rm -f ${SP}/x*'"
expect "heredoc with <<- fed to sh" deny "sh <<-EOF
	rm -f ${SP}/x*
	EOF"
expect "nohup wrapper" deny "nohup rm -f ${SP}/x*"
expect "nice -n wrapper" deny "nice -n 5 rm -f ${SP}/x*"
expect "ionice -c wrapper" deny "ionice -c 3 rm -f ${SP}/x*"
expect "setsid wrapper" deny "setsid rm -f ${SP}/x*"
expect "stdbuf -oL wrapper" deny "stdbuf -oL rm -f ${SP}/x*"
expect "doas -u wrapper" deny "doas -u me rm -f ${SP}/x*"
expect "exec wrapper" deny "exec rm -f ${SP}/x*"
expect "builtin/command wrapper" deny "command rm -f ${SP}/x*"
expect "time -o wrapper" deny "time -o /dev/null rm -f ${SP}/x*"
expect "pushd then a relative glob" deny "pushd ${SP} && rm -f x*"
expect "a heredoc commit message does not hide a later rm" deny "git commit -m \"\$(cat <<'EOF'
Don't do it.
EOF
)\" && rm -f ${SP}/dnd-*"

echo '== $TMPDIR is a scratchpad root too =='
export TMPDIR="${TMP}/tmpdir-root"
expect "glob under a TMPDIR scratchpad" deny "rm -f ${TMPDIR}/claude-${U}/slug/sid/scratchpad/x*"
unset TMPDIR

echo "== a path the hook cannot resolve is never 'not the scratchpad' =="
expect "find from an unknown start into xargs rm" deny "find \"\$SRG_SELFTEST_UNSET_VAR\" -name 'dnd-*' | xargs rm -f"
expect "find . after an unresolvable cd into xargs rm" deny "cd \"\$SRG_SELFTEST_UNSET_VAR\" && find . -name 'dnd-*' | xargs rm -f"
expect "ls of an unresolved glob into xargs rm" deny "ls \"\$SRG_SELFTEST_UNSET_VAR\"/dnd-* | xargs rm -f"
expect "for over an unresolved glob" deny "for f in \"\$SRG_SELFTEST_UNSET_VAR\"/dnd-*; do rm \"\$f\"; done"
expect "unknown variable before a glob" deny "rm -f \"\$SRG_SELFTEST_UNSET_VAR\"/dnd-*"
run "rm -f \"\$SRG_SELFTEST_UNSET_VAR\"/dnd-*"
if reason | grep -q 'could not resolve'; then ok "unresolved deny names the miss"; else bad "unresolved deny names the miss" "${OUT}"; fi
expect "relative glob after an unresolvable cd" deny "cd \"\$(git rev-parse --show-toplevel)\" && rm -f *.tmp"
expect "relative glob with no cwd in stdin" deny "rm -f *.tmp" " "
expect "find -delete from an unknown start" deny "find \"\$SRG_SELFTEST_UNSET_VAR\" -name x -delete"

echo "== a symlinked prefix resolves (CLAUDE_CODE_TMPDIR root) =="
ROOT="${TMP}/ctmp"
LSP="${ROOT}/claude-${U}/slug/sid/scratchpad"
mkdir -p "${LSP}" && ln -s "${LSP}" "${TMP}/link"
export CLAUDE_CODE_TMPDIR="${ROOT}"
expect "glob through a symlink to a scratchpad" deny "rm -f ${TMP}/link/dnd-*"
expect "exact path through the symlink" allow "rm -f ${TMP}/link/dnd-1653-a.log"
expect "rm -rf link/ deletes the target's contents" deny "rm -rf ${TMP}/link/"
expect "rm -rf link removes only the link" allow "rm -rf ${TMP}/link"
unset CLAUDE_CODE_TMPDIR
expect "same symlink without that root is not a scratchpad" allow "rm -f ${TMP}/link/dnd-*"

echo "== exact paths and other directories: allowed =="
expect "exact-path rm of own files" allow "rm -f ${SP}/dnd-1653-a.log ${SP}/dnd-1653-b.log"
expect "exact-path rm -rf of own subdirectory" allow "rm -rf ${SP}/dnd-1653"
expect "brace list is exact names" allow "rm -f ${SP}/dnd-1653-{a,b}.log"
expect "quoted glob is a literal name" allow "rm -f \"${SP}/dnd-*\""
expect "glob elsewhere in /tmp" allow "rm -f /tmp/other/*.log"
expect "glob in a build dir" allow "rm -rf /home/x/build/*"
expect "relative glob outside" allow "rm -f ./*.o"
expect "file directly under the claude tmp root" allow "rm -f ${BASE}/x.out"
expect "glob in a session's tasks dir" allow "rm -f ${SID_DIR}/tasks/*.output"
expect "rm -rf a mktemp dir glob" allow "T=\$(mktemp -d) && rm -rf \"\$T\"/*"
expect "rm -rf an unknown var (no glob)" allow "rm -rf \"\$SRG_SELFTEST_UNSET_VAR\""
expect "find without delete" allow "find ${SP} -name 'dnd-*'"
expect "find -delete elsewhere" allow "find /home/x/build -name '*.o' -delete"
expect "find | xargs cat" allow "find ${SP} -name 'x-*' | xargs cat"
expect "find then a separate xargs rm" allow "find ${SP} -name x; printf a | xargs rm -f"
expect "ls a glob, read only" allow "ls ${SP}/*.log"
expect "cd inside a subshell does not leak" allow "(cd ${SP} && ls) && rm -f *.o"
expect "popd restores the directory" allow "pushd ${SP} && ls && popd && rm -f *.o"
expect "rm of a substitution listing elsewhere" allow "rm -f \$(ls /home/x/build/*.o)"
expect "rm -rf of a mktemp substitution" allow "rm -rf \"\$(mktemp -d)\""
expect "trap clean-up by exact path" allow "trap 'rm -f ${SP}/dnd-1653-a.log' EXIT"

echo "== text that only mentions a delete: allowed (no DND-786 false fire) =="
expect "quoted grep pattern" allow "grep 'rm -f ${SP}/*' notes.txt"
expect "grep with [ { ? in quotes" allow "grep -E 'rm -f [a-z]{2}?' ${SP}/dnd-1653-log.txt"
expect "echo of a glob rm" allow "echo rm -f ${SP}/dnd-*"
expect "commit message" allow "git commit -m \"rm -f ${SP}/dnd-*\""
expect "heredoc body to cat" allow "cat <<'EOF' > ${SP}/dnd-1653-note.md
rm -f ${SP}/*
EOF"
expect "commit message from a heredoc substitution" allow "git commit -m \"\$(cat <<'EOF'
Do not rm -f ${SP}/* here.
EOF
)\""
expect "comment" allow "ls # rm -f ${SP}/*"
expect "command -v rm" allow "command -v rm"
expect "printf of a find -delete" allow "printf '%s\n' 'find ${SP} -delete'"

echo "== hook contract =="
run "rm -f ${SP}/x* \"unterminated"
if [ "${RC}" -eq 0 ] && [ "$(decision)" = "allow" ] && printf '%s' "${OUT}" | grep -q 'NOT' && printf '%s' "${OUT}" | grep -q 'Fix:'; then
  ok "an unparsable rm command is allowed loudly with Fix:"
else
  bad "an unparsable rm command is allowed loudly with Fix:" "rc=${RC} ${OUT}"
fi
run "rm -f ${SP}/*" "/home/x" "Edit"
if [ "$(decision)" = "allow" ] && [ "${RC}" -eq 0 ]; then ok "non-Bash tool passes"; else bad "non-Bash tool passes" "${OUT}"; fi
OUT=$(printf 'not json' | "${HOOK}" 2>/dev/null); RC=$?
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -q 'NOT checked' && printf '%s' "${OUT}" | grep -q 'Fix:'; then
  ok "non-JSON stdin is allowed loudly with Fix:"
else
  bad "non-JSON stdin is allowed loudly with Fix:" "rc=${RC} ${OUT}"
fi
if [ -z "${SRG_HOOK:-}" ]; then
  H=$("${HOOK}" --help </dev/null); RC=$?
  if [ "${RC}" -eq 0 ] && printf '%s' "${H}" | grep -q 'scratch-rm-guard'; then ok "--help on stdout, exit 0"; else bad "--help" "rc=${RC}"; fi
  if [ -s "${XDG_STATE_HOME}/athena/scratch-rm-guard.log" ] && grep -q "	deny	" "${XDG_STATE_HOME}/athena/scratch-rm-guard.log"; then
    ok "denies are logged"
  else
    bad "denies are logged" "no deny line in ${XDG_STATE_HOME}/athena/scratch-rm-guard.log"
  fi
fi

echo
echo "scratch-rm-guard self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read each FAIL line above; fix ai/hooks/scratch-rm-guard.sh (or the case, if the case is wrong)."
  exit 1
fi
exit 0
