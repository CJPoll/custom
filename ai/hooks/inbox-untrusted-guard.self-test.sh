#!/bin/sh
# inbox-untrusted-guard.self-test.sh — hermetic suite for inbox-untrusted-guard.sh
#
# Proves BOTH directions the guard exists for:
#   * FIRES: an unattended session that ingested inbox content is DENIED an edit
#     to a harness control surface (CLAUDE.md / settings / hooks / skills);
#   * CLEAN: it does NOT fire when there is no ingested-inbox marker, when the
#     session is attended, when the owner override is set, or when the target is
#     not a control surface — i.e. it never wedges the shipwright's own legit
#     harness editing.
#   * PRODUCER->ENFORCER wiring: a PostToolUse read-inbox Bash command marks the
#     session, and that mark then makes the PreToolUse enforcer fire.
#   * FAIL-OPEN: empty stdin, non-edit tool, and a missing session id all allow.
#
# Deterministic: it controls CLAUDE_CODE_SESSION_ATTENDED / CLAUDE_CODE_SESSION_ID
# and a throwaway ATHENA_INBOX_GUARD_STATE_DIR explicitly, so the ambient session
# environment cannot change a verdict. Reads NOTHING from its own stdin (the gate
# runs it with </dev/null); it feeds the hook its own JSON.

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="${HERE}/inbox-untrusted-guard.sh"

STATE=$(mktemp -d 2>/dev/null) || { echo "self-test: cannot mktemp" >&2; exit 1; }
trap 'rm -rf "${STATE}"' EXIT INT TERM

fail=0
pass_count=0
note() { printf '  %s\n' "$1"; }
ok()   { pass_count=$((pass_count + 1)); }
bad()  { fail=1; printf 'self-test: FAIL — %s\n' "$1" >&2; }

# run_hook <attended: 1|""> <sid-in-env: value|__none__> <stdin-json>
# Emits the hook's stdout. Env is scrubbed of the two vars the guard reads, then
# set explicitly, so the ambient session can never leak in.
run_hook() {
  _att="$1"; _envsid="$2"; _json="$3"
  if [ "${_envsid}" = "__none__" ]; then
    printf '%s' "${_json}" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_SESSION_ATTENDED -u ATHENA_INBOX_GUARD_OFF \
      CLAUDE_CODE_SESSION_ATTENDED="${_att}" ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" \
      sh "${HOOK}"
  else
    printf '%s' "${_json}" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_SESSION_ATTENDED -u ATHENA_INBOX_GUARD_OFF \
      CLAUDE_CODE_SESSION_ID="${_envsid}" CLAUDE_CODE_SESSION_ATTENDED="${_att}" ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" \
      sh "${HOOK}"
  fi
}

denied() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }

pre() { # pre <tool> <path> <sid>
  printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"},"session_id":"%s","cwd":"/home/cjpoll/dev/custom"}' "$1" "$2" "$3"
}
post_bash() { # post_bash <command> <sid>
  printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' "$1" "$2"
}

# mark a session id directly through the guard's own --mark (same formula path).
mark() { ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}" --mark --session "$1" >/dev/null 2>&1; }
clearmarks() { rm -f "${STATE}"/*.marker 2>/dev/null; }

# ---- 1. FIRES: unattended + marker + CLAUDE.md -> deny --------------------
clearmarks; mark "S1"
out=$(run_hook "" "__none__" "$(pre Edit /home/cjpoll/.claude/CLAUDE.md S1)")
if denied "${out}"; then ok; else bad "unattended+marker+CLAUDE.md was not denied"; fi

# ---- 2. CLEAN: no marker -> allow (no false positive on harness editing) --
clearmarks
out=$(run_hook "" "__none__" "$(pre Edit /home/cjpoll/.claude/CLAUDE.md S1)")
if denied "${out}"; then bad "edit with NO ingested-inbox marker was denied (false positive)"; else ok; fi

# ---- 3. CLEAN: attended -> allow -----------------------------------------
clearmarks; mark "S1"
out=$(run_hook "1" "__none__" "$(pre Edit /home/cjpoll/.claude/CLAUDE.md S1)")
if denied "${out}"; then bad "attended session was denied (should defer to owner + permission prompt)"; else ok; fi

# ---- 4. CLEAN: owner override -> allow ------------------------------------
clearmarks; mark "S1"
out=$(printf '%s' "$(pre Edit /home/cjpoll/.claude/CLAUDE.md S1)" | env -u CLAUDE_CODE_SESSION_ATTENDED \
  ATHENA_INBOX_GUARD_OFF=1 ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}")
if denied "${out}"; then bad "ATHENA_INBOX_GUARD_OFF=1 did not allow the edit"; else ok; fi

# ---- 5. CLEAN: non-sensitive path -> allow --------------------------------
clearmarks; mark "S1"
out=$(run_hook "" "__none__" "$(pre Edit /home/cjpoll/dev/gen_saas/lib/foo.rb S1)")
if denied "${out}"; then bad "an edit to a non-control-surface file was denied"; else ok; fi

# ---- 6. FIRES: hooks surface (Write) -------------------------------------
clearmarks; mark "S1"
out=$(run_hook "" "__none__" "$(pre Write /home/cjpoll/dev/custom/ai/hooks/x.sh S1)")
if denied "${out}"; then ok; else bad "unattended+marker edit to ai/hooks was not denied"; fi

# ---- 7. FIRES: settings surface ------------------------------------------
clearmarks; mark "S1"
out=$(run_hook "" "__none__" "$(pre Edit /home/cjpoll/.claude/settings.json S1)")
if denied "${out}"; then ok; else bad "unattended+marker edit to settings.json was not denied"; fi

# ---- 7b. FIRES: skills surface -------------------------------------------
clearmarks; mark "S1"
out=$(run_hook "" "__none__" "$(pre Edit /home/cjpoll/dev/custom/ai/skills/foo/SKILL.md S1)")
if denied "${out}"; then ok; else bad "unattended+marker edit to ai/skills was not denied"; fi

# ---- 8. PRODUCER: PostToolUse read-inbox writes a marker; no deny ---------
clearmarks
out=$(run_hook "" "S2" "$(post_bash 'read-inbox slack' S2)")
if denied "${out}"; then bad "PostToolUse emitted a deny (must never)"; fi
mp=$(ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}" --marker-path --session S2)
if [ -f "${mp}" ]; then ok; else bad "PostToolUse read-inbox did not write the session marker"; fi

# ---- 9. PRODUCER: a non-read-inbox Bash command marks nothing -------------
clearmarks
run_hook "" "S3" "$(post_bash 'ls -la' S3)" >/dev/null
mp=$(ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}" --marker-path --session S3)
if [ -f "${mp}" ]; then bad "a non-read-inbox command wrote a marker"; else ok; fi

# ---- 9b. PRODUCER: MENTIONING read-inbox (grep/cat/pipe) marks nothing -----
# The exact false positive the DND-201 diff-critic demonstrated: an unattended
# session that merely inspects inbox code must NOT be marked (else its next
# harness edit wedges). Uses direct --mark? No — must go through the real
# PostToolUse detection, so build the command JSON by hand (avoid quoting the
# path chars through post_bash's printf).
producer_marks() { # producer_marks <command-json-escaped> <sid> ; echoes yes/no
  _c="$1"; _s="$2"
  clearmarks
  printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' "${_c}" "${_s}" \
    | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_SESSION_ATTENDED ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}" >/dev/null 2>&1
  _mp=$(ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}" --marker-path --session "${_s}")
  [ -f "${_mp}" ] && echo yes || echo no
}
[ "$(producer_marks 'grep -rn read-inbox ai/hooks/' S9a)" = no ] && ok || bad "grep -rn read-inbox marked the session (false positive)"
[ "$(producer_marks 'cat /home/cjpoll/dev/custom/ai/skills/athena:inbox/bin/read-inbox' S9b)" = no ] && ok || bad "cat .../read-inbox marked the session (false positive)"
[ "$(producer_marks 'git log | grep read-inbox' S9c)" = no ] && ok || bad "git log | grep read-inbox marked the session (false positive)"
[ "$(producer_marks 'echo read-inbox' S9d)" = no ] && ok || bad "echo read-inbox marked the session (false positive)"
# ...and the real invocations DO mark:
[ "$(producer_marks 'read-inbox slack' S9e)" = yes ] && ok || bad "real read-inbox invocation did not mark"
[ "$(producer_marks 'bin/read-inbox slack --peek' S9f)" = yes ] && ok || bad "bin/read-inbox invocation did not mark"
[ "$(producer_marks 'FOO=1 read-inbox gen_saas-mail' S9g)" = yes ] && ok || bad "VAR=val read-inbox invocation did not mark"

# ---- 9c. WEDGE PREVENTION end-to-end: grep read-inbox then edit a hook -----
# An unattended session that greps for read-inbox and then edits ai/hooks must
# be ALLOWED (the critic's exact stuck-session scenario).
clearmarks
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn read-inbox ai/hooks/"},"session_id":"S9h"}' \
  | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_SESSION_ATTENDED ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}" >/dev/null 2>&1
out=$(run_hook "" "S9h" "$(pre Edit /home/cjpoll/dev/custom/ai/hooks/foo.sh S9h)")
if denied "${out}"; then bad "an unattended session that only GREPPED for read-inbox was wedged from editing a hook"; else ok; fi

# ---- 10. WIRING end-to-end: producer mark -> enforcer denies --------------
clearmarks
run_hook "" "S4" "$(post_bash 'bin/read-inbox gen_saas-mail --peek' S4)" >/dev/null
out=$(run_hook "" "S4" "$(pre Edit /home/cjpoll/dev/custom/ai/CLAUDE.md S4)")
if denied "${out}"; then ok; else bad "producer marker did not make the enforcer deny (wiring broken)"; fi

# ---- 11. FAIL-OPEN: empty stdin / non-edit tool / missing session id ------
clearmarks; mark "S1"
out=$(printf '' | env -u CLAUDE_CODE_SESSION_ATTENDED ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}")
if denied "${out}"; then bad "empty stdin produced a deny"; else ok; fi

out=$(run_hook "" "__none__" '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"S1"}')
if denied "${out}"; then bad "a non-edit tool produced a deny"; else ok; fi

# marker present under some OTHER id, but this request carries no session id at
# all (no stdin .session_id, no env) -> fail open.
out=$(run_hook "" "__none__" '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/home/cjpoll/.claude/CLAUDE.md"},"cwd":"/home/cjpoll/dev/custom"}')
if denied "${out}"; then bad "a request with no resolvable session id produced a deny"; else ok; fi

# ---- 12. marker-path is deterministic and under the state dir -------------
a=$(ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}" --marker-path --session ZZ)
b=$(ATHENA_INBOX_GUARD_STATE_DIR="${STATE}" sh "${HOOK}" --marker-path --session ZZ)
if [ "${a}" = "${b}" ] && [ -n "${a}" ] && [ "${a}" != "${a#${STATE}/}" ]; then ok; else bad "--marker-path is not deterministic or not under the state dir (${a} vs ${b})"; fi

# ---- 13. env session id is used when stdin omits it -----------------------
clearmarks; mark "S5"
out=$(run_hook "" "S5" '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/home/cjpoll/.claude/CLAUDE.md"},"cwd":"/x"}')
if denied "${out}"; then ok; else bad "env CLAUDE_CODE_SESSION_ID was not used to resolve the marker"; fi

if [ "${fail}" -eq 0 ]; then
  printf 'inbox-untrusted-guard: self-test OK (%s checks)\n' "${pass_count}"
  exit 0
else
  note "Fix: repair ai/hooks/inbox-untrusted-guard.sh so an unattended session with an ingested-inbox marker is DENIED edits to CLAUDE.md/settings/hooks/skills, while no-marker / attended / override / non-sensitive-path / fail-open cases ALLOW; and so a PostToolUse read-inbox Bash command marks the session."
  printf 'inbox-untrusted-guard: self-test FAILED\n' >&2
  exit 1
fi
