#!/usr/bin/env bash
# Self-test for ai/hooks/athena-inbox-poll.sh — the QA Plan's hook section,
# cases F-1 … F-12,
# plus the hardening cases the sabotage run added.
#
# Every case here is about a decision that is INVISIBLE in production until it
# hurts: a body reaching the pre-prompt position, a bare text line into a JSON
# channel, a marker stamped after the work instead of before, one concern's
# marker silencing another's, a "nothing new" line every session until the real
# notice is invisible. None of those look wrong from the outside.
#
# ISOLATION. Every case gets a fake $HOME, a private ATHENA_INBOX_ROOT and a
# real git repo, all under one mktemp -d. The real ~/.claude/settings.json and
# the real ~/.local/share/athena are never read and never written — asserted,
# not assumed (see assert_fake_home). No network, ever; nothing here makes one.
#
# The hook is exercised against the REAL bin/inbox-status, not a stub. A stub
# that answers the way the hook expects cannot test the hook's assumptions about
# its input — that is precisely how DND-183's suite asserted one side of an
# identity equality and missed a real bug. The failing-poll fixture is a real
# failure path (a malformed registry entry, which makes inbox-status exit 1 with
# empty stdout), not a fabricated one.
#
# Ages are set with `touch -t` against LOCAL time (`date -d`), never `date -u`:
# the helper bug that computed stamps in UTC while touch -t read them as local
# made two staleness cases silently measure nothing.
#
# Run: bash ai/hooks/athena-inbox-poll.self-test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "${HERE}/../.." && pwd -P)"
HOOK="${HERE}/athena-inbox-poll.sh"
STATUS_BIN="${REPO_DIR}/ai/skills/athena:inbox/bin/inbox-status"

REAL_HOME="${HOME}"
TMP="$(mktemp -d)"
WRITER_PID=""
cleanup() {
  [ -n "${WRITER_PID}" ] && kill "${WRITER_PID}" 2>/dev/null
  chmod -R u+rwX "${TMP}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# A fingerprint of the real marker family BEFORE anything runs. The whole suite
# is worthless if it silently mutates the live rate-limit state -- and a bug
# that did so would look exactly like a green run.
#
# This fingerprints ONLY the members of the family that the live SessionStart
# poll never writes on a healthy machine: the top-level FALLBACK markers (the
# hook writes athena-inbox-last-success / -warn / -health-warn solely on its
# degraded, hash-unresolvable path, which the real poll on this machine never
# takes because git resolves its repo hash) and settings.json (the hook only
# ever READS it). Three former members are DELIBERATELY excluded --
# athena-inbox-last-poll (the attempt marker, stamped first on every run),
# athena-inbox-poll.log (appended on every run) and the athena-inbox-seen
# DIRECTORY (whose mtime moves whenever the poll adds a marker under the real
# repo's hash). The live poll rewrites all three on EVERY new session, so
# fingerprinting their mtime conflated "the suite leaked into real $HOME" with
# "an unrelated concurrent live poll wrote its own markers": solo the suite
# finished before a live write landed, but inside the sequential harness gate a
# legitimate poll write landed mid-run and the guard cried wolf (DND-224). A
# genuine leak into those files is caught instead by the fake-project-hash check
# at the end of the run, which the live poll can NEVER trip -- a precise
# signature in place of a racy mtime.
real_markers_fingerprint() {
  local f
  for f in athena-inbox-last-success athena-inbox-last-warn \
           athena-inbox-last-health-warn settings.json; do
    printf '%s:%s\n' "${f}" "$(stat -c %Y -- "${REAL_HOME}/.claude/${f}" 2>/dev/null || printf 'absent')"
  done
}
REAL_MARKERS_BEFORE="$(real_markers_fingerprint)"

# The real-$HOME seen dir. The live poll may ADD a marker here keyed to the REAL
# repo hash while the suite runs -- that is allowed and must not fail the guard.
# Only a marker keyed to one of the FAKE project hashes this suite fabricates is
# a leak, which the end-of-suite check (1) looks for by name.
REAL_SEEN_DIR="${REAL_HOME}/.claude/athena-inbox-seen"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
assert_contains()     { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "expected NOT to contain [$2], got [$3]" ;; *) ok "$1" ;; esac; }
assert_file()         { if [ -e "$2" ]; then ok "$1"; else bad "$1" "no such file: $2"; fi; }
assert_no_file()      { if [ -e "$2" ]; then bad "$1" "file exists: $2"; else ok "$1"; fi; }

# ---------------------------------------------------------------------------
# Per-case isolation.
# ---------------------------------------------------------------------------
CASE_N=0
CASE_DIR=""; REPO=""; OUT=""; ERR=""; RC=0

setup_case() {
  CASE_N=$((CASE_N + 1))
  CASE_DIR="${TMP}/case-${CASE_N}"
  HOME="${CASE_DIR}/home"
  ATHENA_INBOX_ROOT="${CASE_DIR}/root"
  REPO="${CASE_DIR}/proj"
  mkdir -p "${HOME}/.claude" "${ATHENA_INBOX_ROOT}/projects" "${REPO}"
  export HOME ATHENA_INBOX_ROOT
  ( cd "${REPO}" && git init -q . && git config user.email t@t && git config user.name t )
  # The staleness windows are six hours; a test cannot wait six hours and must
  # not silently test nothing instead.
  export ATHENA_INBOX_STALE_SECONDS=3600
  export ATHENA_INBOX_WARN_INTERVAL_SECONDS=3600
}

# The one assertion that makes every other case safe to run.
assert_fake_home() {
  case "${HOME}" in
    "${TMP}"/*) ;;
    *) printf '  FATAL  refusing to run: HOME is %s, not a tmpdir\n' "${HOME}"; exit 1 ;;
  esac
  [ "${HOME}" != "${REAL_HOME}" ] || { printf '  FATAL  HOME is the real HOME\n'; exit 1; }
}

# register <channels-json>  -- a registry entry keyed by this repo's identity,
# built the way the contract says (realpath of the git common dir).
register() {
  local common
  common="$(cd "${REPO}" && realpath "$(git rev-parse --git-common-dir)")"
  jq -n --arg r "${common}" --argjson c "$1" \
    '{v:1, repo:$r, channels:$c}' > "${ATHENA_INBOX_ROOT}/projects/p.json"
}

LOG_CHANNEL='{"slack":{"kind":"log","path":"p-slack.jsonl","dedupe":["event_id","channel+ts"],"schema_v":[1]}}'
BOTH_CHANNELS='{"slack":{"kind":"log","path":"p-slack.jsonl","dedupe":["event_id","channel+ts"],"schema_v":[1]},
                "peer-mail":{"kind":"maildir","namespace":"agent-mail/peer","read":"from-peer","write":"to-peer","identity":"athena"}}'

# run_hook [args...]  -- from inside the repo, stdin from $HOOK_STDIN (default
# empty). Captures stdout, stderr and status separately, because "nothing on
# stdout" is the assertion in half these cases and a merged stream cannot make
# it.
HOOK_STDIN=""
run_hook() {
  assert_fake_home
  OUT="$(cd "${REPO}" && printf '%s' "${HOOK_STDIN}" | "${HOOK}" "$@" 2>"${CASE_DIR}/stderr")"
  RC=$?
  ERR="$(cat "${CASE_DIR}/stderr" 2>/dev/null)"
}

hook_log()  { cat "${HOME}/.claude/athena-inbox-poll.log" 2>/dev/null; }

# pm <suffix> -- this case's PER-PROJECT marker path. The whole marker family
# except the attempt marker and the log is keyed by the project, because the
# poll outcome is per-repo while the hook runs in every repo on the machine.
# Resolved the same way the hook resolves it -- through the skill's public
# --repo-key -- so a divergence between suite and hook cannot hide a bug.
pm() {
  local key hash
  key="$(cd "${REPO}" && "${STATUS_BIN}" --repo-key 2>/dev/null)"
  hash="$(printf '%s' "${key}" | sha256sum | cut -c1-32)"
  mkdir -p "${HOME}/.claude/athena-inbox-seen" 2>/dev/null
  printf '%s\n' "${HOME}/.claude/athena-inbox-seen/${hash}.$1"
}
context_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }

# assert_one_json_object <claim> <stdout>  -- exactly one object, nothing else.
assert_one_json_object() {
  if printf '%s' "$2" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1" "not exactly one JSON object: [$2]"
  fi
}

SENTINEL="ZQXSENTINELDONOTLEAK"
# The registry's project-name grammar is lowercase-only, so a fixture that
# needs the sentinel in a FILENAME under projects/ needs this variant.
SENTINEL_LC="zqxsentineldonotleak"

# plant_log_lines  -- two unread Slack lines, EVERY one carrying the sentinel
# body. The sentinel was originally on the first line only, and the sabotage run
# measured what that costs: a mutation that appended `tail -n1` of the channel
# file to the notice -- a message body in the pre-prompt position, the one thing
# F-2 exists to forbid -- ran GREEN, because the line it leaked was the one
# without the sentinel. A leak test whose canary sits on one row of the fixture
# tests one row, not the claim.
plant_log_lines() {
  printf '{"v":1,"event_id":"Ev1","channel":"D01","ts":"1700000001.1","text":"%s"}\n' "${SENTINEL}" \
    > "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
  printf '{"v":1,"event_id":"Ev2","channel":"D01","ts":"1700000002.1","text":"second %s"}\n' "${SENTINEL}" \
    >> "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
}

# ---------------------------------------------------------------------------
# A stub `inbox-status`, in a copied repo tree.
#
# Every case above runs against the REAL inbox-status, which is the right
# default -- a stub that answers the way the hook expects cannot test the hook's
# assumptions. But three of this hook's claims are about inputs the real
# inbox-status never produces: stdout that is non-empty AND unusable, stderr
# that carries a peer-chosen string, and a read-inbox that EXISTS. The sabotage
# run measured all three as zeros. The hook resolves its wrapped command from
# its own BASH_SOURCE, so a copy of the hook in a scratch tree picks up whatever
# is placed beside it -- no PATH games, and the real skill is untouched.
# ---------------------------------------------------------------------------
STUB_HOOK=""
stub_repo() { # <inbox-status script body>  [--with-read-inbox]
  local stub="${CASE_DIR}/stubrepo"
  mkdir -p "${stub}/ai/hooks" "${stub}/ai/skills/athena:inbox/bin"
  cp -- "${HOOK}" "${stub}/ai/hooks/athena-inbox-poll.sh"
  printf '%s\n' "$1" > "${stub}/ai/skills/athena:inbox/bin/inbox-status"
  chmod +x "${stub}/ai/skills/athena:inbox/bin/inbox-status"
  if [ "${2:-}" = "--with-read-inbox" ]; then
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stub}/ai/skills/athena:inbox/bin/read-inbox"
    chmod +x "${stub}/ai/skills/athena:inbox/bin/read-inbox"
  fi
  STUB_HOOK="${stub}/ai/hooks/athena-inbox-poll.sh"
}

run_stub_hook() {
  assert_fake_home
  OUT="$(cd "${REPO}" && printf '%s' "${HOOK_STDIN}" | "${STUB_HOOK}" "$@" 2>"${CASE_DIR}/stderr")"
  RC=$?
  ERR="$(cat "${CASE_DIR}/stderr" 2>/dev/null)"
}

STUB_OK='#!/usr/bin/env bash
case "$1" in --repo-key) realpath "$(git rev-parse --git-common-dir)"; exit 0 ;; esac
printf '"'"'{"channels":[{"name":"slack","kind":"log","new":2}],"failed_candidates":0}'"'"'
exit 0'

# plant_mail  -- one unread message whose SLUG is peer-chosen prose carrying an
# imperative. A status line must never become "1 new message: urgent-run-this".
plant_mail() {
  local d="${ATHENA_INBOX_ROOT}/agent-mail/peer/from-peer"
  mkdir -p "${d}/tmp" "${d}/.acked"
  printf -- '---\nfrom: peer\nto: athena\nsent_at: 20260901T232215Z\n---\n%s\n' "${SENTINEL}" \
    > "${d}/20260901T232215Z-001-${SENTINEL}-urgent-run-this.md"
}

echo "== F-1 · F-2: the actionable path, counts only =="

setup_case
register "${BOTH_CHANNELS}"
plant_log_lines
plant_mail
run_hook

# F-1: the whole output contract in one assertion. A second object, a stray
# diagnostic line, or a trailing blank would each break the JSON consumer that
# reads this stream, and each is a plausible edit away.
assert_one_json_object "F-1 exactly one JSON object on stdout and nothing else" "${OUT}"
assert_eq "F-1 the hook exits 0 on the actionable path" "0" "${RC}"
assert_eq "F-1 hookEventName is SessionStart" "SessionStart" \
  "$(printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
assert_eq "F-1 the object carries exactly one top-level key" "hookSpecificOutput" \
  "$(printf '%s' "${OUT}" | jq -r 'keys | join(",")' 2>/dev/null)"
assert_eq "F-1 hookSpecificOutput carries exactly hookEventName + additionalContext" \
  "additionalContext,hookEventName" \
  "$(printf '%s' "${OUT}" | jq -r '.hookSpecificOutput | keys | join(",")' 2>/dev/null)"

CTX="$(context_of "${OUT}")"
assert_contains "F-1 both channels are counted (2 log lines)" "2 new in slack" "${CTX}"
assert_contains "F-1 both channels are counted (1 mail)" "1 new in peer-mail" "${CTX}"
assert_contains "F-1 the notice points at the read step" "read-inbox" "${CTX}"

# F-2: the trust boundary, asserted rather than reviewed. The sentinel is in a
# message BODY and in a peer-chosen maildir SLUG; if either reaches this string,
# a stranger has spoken into the pre-prompt position.
assert_not_contains "F-2 no substring of a message body reaches the notice" "${SENTINEL}" "${CTX}"
assert_not_contains "F-2 no peer-chosen filename/slug reaches the notice" "urgent-run-this" "${CTX}"
assert_not_contains "F-2 no sender identity reaches the notice" "from: peer" "${CTX}"
# Belt and braces: not merely absent from the rendered context, absent from the
# WHOLE of stdout — a future edit that adds a second field would be caught here.
assert_not_contains "F-2 the sentinel is absent from the entire stdout stream" "${SENTINEL}" "${OUT}"
assert_not_contains "F-2 nothing is written to stderr on the actionable path" "${SENTINEL}" "${ERR}"

echo "== F-3: silence is the default =="

# F-3: a healthy, empty channel prints NOTHING. Unprompted output that says
# "nothing new" every session is what makes a real notice invisible.
setup_case
register "${LOG_CHANNEL}"
: > "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
run_hook
assert_eq "F-3 zero unread produces no stdout at all" "" "${OUT}"
assert_eq "F-3 zero unread still exits 0" "0" "${RC}"
assert_contains "F-3 the quiet run is still recorded in the log" "nothing to report" "$(hook_log)"

echo "== F-4: every failure path is silent, exit 0, and logged =="

# F-4a: jq missing. PATH is rebuilt from scratch rather than filtered, because a
# filtered PATH still finds jq through any directory the filter forgot.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
NOBIN="${CASE_DIR}/nobin"; mkdir -p "${NOBIN}"
for b in bash dirname date mkdir wc tail mv rm stat sed grep cat timeout; do
  src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${NOBIN}/${b}"
done
OLD_PATH="${PATH}"
PATH="${NOBIN}" run_hook
PATH="${OLD_PATH}"
assert_eq "F-4 missing jq produces no stdout" "" "${OUT}"
assert_eq "F-4 missing jq still exits 0" "0" "${RC}"
assert_contains "F-4 missing jq is logged as a fixed reason" "jq is not on PATH" "$(hook_log)"
assert_not_contains "F-4 the missing-jq log line carries no body" "${SENTINEL}" "$(hook_log)"

# F-4b: unparseable stdin. The payload is the harness's, not a message's, but a
# hook that guesses at a shape it does not recognise is a hook that emits
# garbage into a JSON channel.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
HOOK_STDIN='this is not json'
run_hook
HOOK_STDIN=""
assert_eq "F-4 unparseable stdin produces no stdout" "" "${OUT}"
assert_eq "F-4 unparseable stdin still exits 0" "0" "${RC}"
assert_contains "F-4 unparseable stdin is logged as a fixed reason" "was not a JSON object" "$(hook_log)"

# A WELL-FORMED SessionStart payload must of course still be accepted — the
# guard above is worthless if it also rejects the real thing.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
HOOK_STDIN='{"session_id":"abc","hook_event_name":"SessionStart","cwd":"/tmp"}'
run_hook
HOOK_STDIN=""
assert_one_json_object "F-4 a well-formed SessionStart payload is accepted" "${OUT}"

# F-4c: no registry entry. NOT OPTING IN IS NOT A FAULT — silent, exit 0, and
# no error anywhere.
setup_case
run_hook
assert_eq "F-4 no registry entry produces no stdout" "" "${OUT}"
assert_eq "F-4 no registry entry still exits 0" "0" "${RC}"
assert_eq "F-4 no registry entry is not an error on stderr" "" "${ERR}"

# ...and it is not a SUCCESS either. This is the third state, and F-4c used to
# assert everything about it EXCEPT the one thing it changes: marker state.
# `{"channels":[]}` is the answer in every repo that never opted in, and this
# hook runs in all of them off one shared marker family under $HOME. Stamping
# success here let a session in any unrelated repo refresh SUCCESS_MARKER and
# clear the warn markers, so the six-hour staleness test could never come due --
# the outage warning this hook exists to raise was structurally unreachable, and
# no mutation could show it because no fixture ever asserted these files.
assert_no_file "F-4 a non-opted-in repo does NOT stamp success" \
  "$(pm success)"
assert_file "F-4 a non-opted-in repo still stamps the ATTEMPT marker" \
  "${HOME}/.claude/athena-inbox-last-poll"
assert_contains "F-4 a non-opted-in repo records why it did nothing" \
  "nothing to poll here" "$(hook_log)"

# Nor does it CLEAR what an opted-in session recorded. Same claim from the other
# side: a warning raised by the project that OWNS these markers must survive a
# session in an unrelated repo.
setup_case
touch "$(pm warn)"
touch "$(pm health-warn)"
run_hook
assert_file "F-4 a non-opted-in repo does not clear the outage marker" \
  "$(pm warn)"
assert_file "F-4 a non-opted-in repo does not clear the health marker" \
  "$(pm health-warn)"

# F-4d: an unreadable root. Whatever inbox-status makes of it, the hook's
# contract is unchanged: nothing on stdout, exit 0, one line in the log.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
chmod 000 "${ATHENA_INBOX_ROOT}"
run_hook
chmod 700 "${ATHENA_INBOX_ROOT}"
assert_eq "F-4 an unreadable root produces no stdout" "" "${OUT}"
assert_eq "F-4 an unreadable root still exits 0" "0" "${RC}"
# One line, not two. (What that line SAYS depends on how far inbox-status got,
# which is its business, not this hook's -- the contract here is that a failure
# is recorded once and silently.)
assert_eq "F-4 an unreadable root logs exactly one reason line" "1" \
  "$(hook_log | wc -l | tr -d ' ')"

echo "== F-5 · F-6 · F-9: the stale warning, and its own rate limit =="


# A FAILING poll, built from a real failure: a malformed registry entry makes
# inbox-status exit 1 with empty stdout.
break_registry() { printf 'not json at all' > "${ATHENA_INBOX_ROOT}/projects/p.json"; }

# F-5: a never-working setup warns on the FIRST attempt. Note the reading: a run
# that SUCCEEDS is never stale by construction, so F-5's "success marker absent"
# and F-6's "success marker 7h old" both describe a FAILING poll — otherwise the
# marker's age could not affect the outcome and the case would measure nothing.
setup_case
register "${LOG_CHANNEL}"
break_registry
run_hook
assert_no_file "F-5 the precondition holds: no success marker exists" "$(pm success)"
assert_contains "F-5 a never-successful setup warns on the first attempt" \
  "has not succeeded recently" "$(context_of "${OUT}")"

# F-9: and it travels as the SAME JSON object — never a bare text line into a
# JSON channel, which is the exact malformed stdout the contract refuses.
assert_one_json_object "F-9 the stale warning travels as one well-formed JSON object" "${OUT}"
assert_eq "F-9 the warning object names the SessionStart event like any other" "SessionStart" \
  "$(printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"

# F-6: the warning is itself rate-limited. Without this, an outage that lasts a
# week warns at every single session start until the notice stops being read.
setup_case
register "${LOG_CHANNEL}"
break_registry
touch -t "$(date -d '7 hours ago' +%Y%m%d%H%M)" "$(pm success)"
touch "$(pm warn)"
run_hook
assert_eq "F-6 a stale success plus a FRESH warn marker is silent" "" "${OUT}"
assert_eq "F-6 the rate-limited run still exits 0" "0" "${RC}"

# The other half of the same claim: a stale success and a STALE warn marker does
# warn. A rate limit that never expires is indistinguishable from a broken warning.
setup_case
register "${LOG_CHANNEL}"
break_registry
touch -t "$(date -d '7 hours ago' +%Y%m%d%H%M)" "$(pm success)"
touch -t "$(date -d '7 hours ago' +%Y%m%d%H%M)" "$(pm warn)"
run_hook
assert_contains "F-6 a stale success plus a STALE warn marker warns again" \
  "has not succeeded recently" "$(context_of "${OUT}")"

# And the inverse: a FRESH success marker means a single failed poll is not an
# outage and says nothing. Warning on every transient blip is how a real one
# stops being read.
setup_case
register "${LOG_CHANNEL}"
break_registry
touch "$(pm success)"
run_hook
assert_eq "F-6 a fresh success marker makes one failed poll silent" "" "${OUT}"

# TWO REPOS, ONE $HOME -- the shape every other case in this suite is blind to,
# because every other case has exactly one repo. The marker family is per-$HOME
# and the poll outcome is per-cwd, and this hook is registered with the ""
# matcher, so it runs in every repo on the machine. A stale, broken opted-in
# project must still warn even though the last session was somewhere else
# entirely.
setup_case
register "${LOG_CHANNEL}"
OTHER="${CASE_DIR}/other"
mkdir -p "${OTHER}"
( cd "${OTHER}" && git init -q . && git config user.email t@t && git config user.name t )
OTHER_SAVED="${REPO}"; REPO="${OTHER}"
run_hook                                  # a session in the unrelated repo...
assert_no_file "F-6 an unrelated repo's session leaves no success marker behind" \
  "$(pm success)"
REPO="${OTHER_SAVED}"
break_registry                            # ...and now the opted-in project's poll is broken
run_hook
assert_contains "F-6 a session in another repo does not suppress this project's outage warning" \
  "has not succeeded recently" "$(context_of "${OUT}")"

# A non-numeric window is a typo, and the unguarded form failed in the WRONG
# DIRECTION: `[ "${age}" -ge "abc" ]` errors, marker_is_stale reads the error as
# NOT STALE, and the typo silently suppresses the one mechanism whose job is to
# break a silence. It now falls back to the documented six hours.
setup_case
register "${LOG_CHANNEL}"
break_registry
export ATHENA_INBOX_STALE_SECONDS=not-a-number
run_hook
export ATHENA_INBOX_STALE_SECONDS=3600
assert_contains "F-5 a non-numeric staleness window falls back, it does not silence" \
  "has not succeeded recently" "$(context_of "${OUT}")"

# TWO REGISTERED PROJECTS, ONE $HOME. The case above covers a repo that never
# opted in; this covers the one the suite could not see, and the one that is
# reachable on this machine today -- its registry holds several entries. The
# marker family used to be one file per $HOME while the poll outcome is per
# repo, so a HEALTHY SIBLING refreshing the success marker kept a broken
# project's outage warning six hours away forever. That is the same
# structurally-unreachable warning the OPTED_IN third state was added to close,
# reached from a sibling tenant instead of an unrelated repo.
setup_case
register "${LOG_CHANNEL}"                       # project A, healthy
plant_log_lines
SIB="${CASE_DIR}/sibling"
mkdir -p "${SIB}"
( cd "${SIB}" && git init -q . && git config user.email t@t && git config user.name t )
SIB_COMMON="$(cd "${SIB}" && realpath "$(git rev-parse --git-common-dir)")"
jq -n --arg r "${SIB_COMMON}" --argjson c "${LOG_CHANNEL}" \
  '{v:1, repo:$r, channels:$c}' > "${ATHENA_INBOX_ROOT}/projects/sib.json"
run_hook                                        # a healthy session in A
A_SAVED="${REPO}"; REPO="${SIB}"
printf 'not json at all' > "${ATHENA_INBOX_ROOT}/projects/sib.json"   # B's entry rots
run_hook
assert_contains "F-8 a healthy SIBLING PROJECT does not silence this project's outage warning" \
  "has not succeeded recently" "$(context_of "${OUT}")"
REPO="${A_SAVED}"

# ...and the same for the health warning, which R16 established the principle
# for and only applied to the vanished-entry notice: every health clause but
# failed_candidates is derived from THIS project's own channels.
setup_case
register "${LOG_CHANNEL}"                       # project A, never delivered to
SIB="${CASE_DIR}/sibling"
mkdir -p "${SIB}"
( cd "${SIB}" && git init -q . && git config user.email t@t && git config user.name t )
SIB_COMMON="$(cd "${SIB}" && realpath "$(git rev-parse --git-common-dir)")"
jq -n --arg r "${SIB_COMMON}" --argjson c "${LOG_CHANNEL}" \
  '{v:1, repo:$r, channels:$c}' > "${ATHENA_INBOX_ROOT}/projects/sib.json"
run_hook                                        # A warns, stamping ITS marker
assert_contains "F-8 the precondition: project A raises its health warning" \
  "never received anything" "$(context_of "${OUT}")"
A_SAVED="${REPO}"; REPO="${SIB}"
run_hook                                        # B has the same fault
assert_contains "F-8 project A's health warning does not silence project B's" \
  "never received anything" "$(context_of "${OUT}")"
REPO="${A_SAVED}"

echo "== F-7 · F-8: marker discipline =="

# F-7: stamped BEFORE the work, never after. An after-the-fact stamp turns every
# session into a retry storm (walt_ui S1/S4), and a failure that stamps SUCCESS
# (S17) makes an outage indistinguishable from health forever after.
setup_case
register "${LOG_CHANNEL}"
break_registry
run_hook
assert_file    "F-7 a failing run DOES stamp the attempt marker" "${HOME}/.claude/athena-inbox-last-poll"
assert_no_file "F-7 a failing run does NOT stamp the success marker" "$(pm success)"

# The attempt marker is stamped before the work in the strongest sense: even a
# run that cannot do any work at all has already recorded the attempt.
setup_case
register "${LOG_CHANNEL}"
NOBIN="${CASE_DIR}/nobin"; mkdir -p "${NOBIN}"
for b in bash dirname date mkdir wc tail mv rm stat sed grep cat timeout; do
  src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${NOBIN}/${b}"
done
OLD_PATH="${PATH}"
PATH="${NOBIN}" run_hook
PATH="${OLD_PATH}"
assert_file "F-7 a run that cannot even start stamps the attempt marker first" \
  "${HOME}/.claude/athena-inbox-last-poll"

# F-8: a clean success stamps success AND clears the warn marker, so the NEXT
# outage gets its own warning instead of being rate-limited by a fault that has
# already been fixed (walt_ui S21).
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
touch "$(pm warn)"
run_hook
assert_file    "F-8 a succeeding run stamps the success marker" "$(pm success)"
assert_no_file "F-8 a succeeding run clears the warn marker" "$(pm warn)"

echo "== F-10: a separate marker per concern =="

# F-10: a shared marker once let a fresh CHECK silently suppress a POLL (walt_ui
# S14). Two directions, both asserted.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
touch "$(pm warn)"
touch "${HOME}/.claude/athena-inbox-last-poll"
run_hook
assert_contains "F-10 a fresh WARN marker does not suppress the COUNT" "2 new in slack" \
  "$(context_of "${OUT}")"

# A fresh marker belonging to the OTHER family (athena-slack-*) must not reach
# into this one at all.
setup_case
register "${LOG_CHANNEL}"
break_registry
touch "${HOME}/.claude/athena-slack-last-warn"
touch "${HOME}/.claude/athena-slack-last-success"
run_hook
assert_contains "F-10 the athena-slack-* family does not rate-limit this hook" \
  "has not succeeded recently" "$(context_of "${OUT}")"

# Structural, not behavioural: the hook must not name the other family's markers
# anywhere. A test of behaviour alone would pass a hook that shared a path it
# merely happened not to hit in these fixtures.
if grep -q 'athena-slack-last' "${HOOK}"; then
  bad "F-10 the hook shares no marker path with the athena-slack-* family" "found athena-slack-last in the hook"
else
  ok "F-10 the hook shares no marker path with the athena-slack-* family"
fi
for m in athena-inbox-last-poll athena-inbox-seen '.success' '.warn' \
         '.health-warn' '.seen' '.vanished-warn'; do
  if grep -q "${m}" "${HOOK}"; then ok "F-10 marker [${m}] has its own path"
  else bad "F-10 marker [${m}] has its own path" "not referenced by the hook"; fi
done

echo "== R8: a broken chain is noticed, and the notice still names nothing =="

# A channel that CANNOT be counted is a broken chain, and reporting it as zero
# would read as "no mail". It is surfaced -- as a COUNT. The hook is the
# counts-only surface; inbox-status is the surface that says which.
setup_case
register '{"tenant-private-name":{"kind":"log","path":"p-slack.jsonl","dedupe":["event_id"],"schema_v":[1]}}'
printf 'x\n' > "${CASE_DIR}/elsewhere.jsonl"
ln -s "${CASE_DIR}/elsewhere.jsonl" "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
run_hook
CTX="$(context_of "${OUT}")"
assert_contains "R8 a channel that cannot be counted is surfaced, not shown as zero" \
  "1 declared channel(s) could not be counted" "${CTX}"
assert_not_contains "R8 the health clause counts and does not name the channel" \
  "tenant-private-name" "${CTX}"

# "Nobody ever registered the writer" and "nothing new arrived" are identical on
# disk. They must not be identical in the notice: the first is a broken setup,
# the second is a good morning.
setup_case
register "${LOG_CHANNEL}"
run_hook
assert_contains "R8 a channel that has NEVER received anything is surfaced" \
  "never received anything" "$(context_of "${OUT}")"

# A run that succeeded but found a broken channel must NOT clear the HEALTH warn
# marker: clearing it would defeat the rate limit for the fault that is still
# happening, and re-warn at every session start.
setup_case
register "${LOG_CHANNEL}"
touch -t "$(date -d '7 hours ago' +%Y%m%d%H%M)" "$(pm health-warn)"
run_hook
assert_file "R8 a successful-but-unhealthy run does not clear the health-warn marker" \
  "$(pm health-warn)"

# ...and is itself rate-limited, by that same marker.
setup_case
register "${LOG_CHANNEL}"
touch "$(pm health-warn)"
run_hook
assert_eq "R8 the health warning is rate-limited like any other warning" "" "${OUT}"

# THE TWO WARNINGS DO NOT RATE-LIMIT EACH OTHER. This is the marker-per-concern
# rule applied warn-to-warn rather than poll-to-warn, and it is the one door
# 24 mutations left open: a chronic, benign health fault re-stamps on its own
# six-hour cadence, and an OUTAGE beginning shortly afterwards would be
# swallowed for a whole window by a warning about something else entirely.
setup_case
register "${LOG_CHANNEL}"
touch "$(pm health-warn)"   # health warned just now
break_registry                                          # ...and now the poll breaks
run_hook
assert_contains "R8 a fresh HEALTH warning does not suppress an OUTAGE warning" \
  "has not succeeded recently" "$(context_of "${OUT}")"

# ...and the converse, so the split is not merely one-directional.
setup_case
register "${LOG_CHANNEL}"
touch "$(pm warn)"          # outage warned just now
run_hook
assert_contains "R8 a fresh OUTAGE warning does not suppress a HEALTH warning" \
  "never received anything" "$(context_of "${OUT}")"

# A run that SUCCEEDED clears the outage marker whatever it found downstream: a
# health fault is not evidence that the poll itself is broken, and leaving the
# outage marker stamped through a weeks-long health fault is how the next real
# outage gets rate-limited by one that is already over.
setup_case
register "${LOG_CHANNEL}"
touch "$(pm warn)"
run_hook
assert_no_file "R8 a successful-but-unhealthy run DOES clear the outage marker" \
  "$(pm warn)"

# Private state, by construction. A 0644 marker or reason log under ~/.claude is
# not a disaster, but the inbox family's whole discipline is 0600/0700 and a
# umask this file forgets is how that erodes.
#
# The fixture is the QUIET path (an empty-but-delivered channel), not the
# actionable one: the actionable path has nothing to log -- it says its piece on
# stdout -- so asserting the log's mode there asserts the mode of a file that
# does not exist, which `stat` reports as the empty string and which an
# `assert_eq` against "600" would only ever have caught by luck.
setup_case
register "${LOG_CHANNEL}"
: > "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
run_hook
assert_eq "the attempt marker is created 0600" "600" \
  "$(stat -c %a "${HOME}/.claude/athena-inbox-last-poll" 2>/dev/null)"
assert_eq "the success marker is created 0600" "600" \
  "$(stat -c %a "$(pm success)" 2>/dev/null)"
assert_eq "the reason log is created 0600" "600" \
  "$(stat -c %a "${HOME}/.claude/athena-inbox-poll.log" 2>/dev/null)"

echo "== R13: a maildir awaiting its first message is HEALTHY, not a fault =="

# `never_delivered` means opposite things for the two channel kinds. For a log
# channel it is a real fault: the producer may never have been registered, and
# an unregistered producer looks exactly like an empty channel on disk. For a
# maildir it is NORMAL -- the contract says the read directory is created by the
# tool that SENDS, so a declared peer mailbox nobody has written to yet is a
# healthy channel waiting, and `bin/inbox-status`'s own renderer filters on
# `.kind == "log"` for exactly this reason.
#
# Getting this wrong is not a cosmetic false positive. HEALTH_TEXT would be
# permanently non-empty, so the branch that clears WARN_MARKER on a clean run
# could never execute -- and the next REAL outage would inherit a fresh warn
# marker from a non-fault and be rate-limited into silence by it. The suite
# could not see any of this: its only maildir fixture, plant_mail, CREATES the
# read directory before running, so `never_delivered` was never true for a
# maildir anywhere.
setup_case
register "${BOTH_CHANNELS}"
plant_log_lines
# No agent-mail/peer/from-peer anywhere: the peer has not sent yet.
run_hook
CTX="$(context_of "${OUT}")"
assert_not_contains "R13 an unwritten-to maildir is not announced as a missing producer" \
  "never received anything" "${CTX}"
assert_contains "R13 the log channel's real mail is still counted" "2 new in slack" "${CTX}"
assert_no_file "R13 an unwritten-to maildir does not leave the health-warn marker stamped" \
  "$(pm health-warn)"

# The control, so the case above cannot pass by the clause being dead: the same
# fixture with a LOG channel that has never been delivered to DOES warn.
setup_case
register "${LOG_CHANNEL}"
run_hook
assert_contains "R13 the control: a never-delivered LOG channel is still a fault" \
  "never received anything" "$(context_of "${OUT}")"

echo "== R16: an entry that VANISHED is not the same as one that never existed =="

# The two are byte-identical to inbox-status -- {"channels":[],...}, exit 0 --
# and correctly so: it cannot know a project's history. But a registry entry is
# an untracked file outside git, so its deletion leaves no diff and no undo,
# and every other signal in this hook is silent by design. Somebody has to
# remember that this project once had channels, and the session standing in the
# project is the only one who can.
#
# Round 3 made "not opted in" stamp nothing, which stopped the hook LYING about
# success; it did not make the resulting absence of success SPEAK. Nothing in
# the suite reached the state, because every no-entry fixture builds a repo that
# never had an entry and every case starts from an empty $HOME.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
run_hook                                    # session 1: opted in, mail counted
assert_contains "R16 the precondition: session 1 sees this project's channels" \
  "2 new in slack" "$(context_of "${OUT}")"
rm -f "${ATHENA_INBOX_ROOT}/projects/p.json" # ...and now the entry is gone
run_hook
CTX="$(context_of "${OUT}")"
assert_contains "R16 a vanished entry is announced, not silently treated as opt-out" \
  "had inbox channels on an earlier session and declares none now" "${CTX}"
assert_contains "R16 the Fix names where to restore it" "projects/" "${CTX}"
assert_contains "R16 ...and how to silence it if the project was retired on purpose" \
  "delete" "${CTX}"
assert_contains "R16 ...and names the empty-channels repair, which looks identical on disk" \
  "empty" "${CTX}"

# An entry that is PRESENT but declares no channels is byte-identical to a
# missing one -- descriptor_validate accepts an empty channels object, and
# inbox_status_json then emits the same {"channels":[]}. The hook cannot tell
# them apart, so its Fix must name that repair too rather than sending the
# reader to look for a file that is sitting right there.
setup_case
register "${LOG_CHANNEL}"
run_hook
jq '.channels = {}' "${ATHENA_INBOX_ROOT}/projects/p.json" > "${CASE_DIR}/p.json" \
  && mv "${CASE_DIR}/p.json" "${ATHENA_INBOX_ROOT}/projects/p.json"
run_hook
assert_contains "R16 an entry emptied of channels raises the same notice" \
  "declares none now" "$(context_of "${OUT}")"

# It is rate-limited by a marker of its OWN, beside the project it is about --
# not by the $HOME-level health marker, which another project could hold.
setup_case
register "${LOG_CHANNEL}"
run_hook
rm -f "${ATHENA_INBOX_ROOT}/projects/p.json"
touch "$(pm health-warn)"   # another project warned
run_hook
assert_contains "R16 another project's health warning does not silence this one" \
  "declares none now" "$(context_of "${OUT}")"
run_hook                                                 # ...but its own does
assert_eq "R16 the vanished-entry warning is rate-limited by its own marker" "" "${OUT}"

# ...and a REPAIR re-arms it. Same S21 discipline as the other two markers: an
# entry restored and then clobbered again inside the window must warn again,
# not be silenced by a warning about the fault that was already fixed. This is
# the failure with no diff and no undo, so it is the most expensive place to
# skip the rule -- and the rate-limit case above would pass whether or not the
# repair cleared anything.
register "${LOG_CHANNEL}"                                # the entry is restored
run_hook
assert_no_file "R16 a repair clears the vanished-entry rate limit" \
  "$(pm vanished-warn)"
rm -f "${ATHENA_INBOX_ROOT}/projects/p.json"             # ...and clobbered again
run_hook
assert_contains "R16 a second disappearance warns again rather than being rate-limited" \
  "declares none now" "$(context_of "${OUT}")"

# ABSENT and EMPTY --repo-key are different answers. Empty means "no git
# repository here", which legitimately has nothing to remember. ABSENT means the
# inbox-status beside this hook predates `--repo-key` -- hook/skill version skew,
# which settings.json makes reachable by wiring one tree's hook path while
# STATUS_BIN resolves from that tree. Collapsing the two would fall back to the
# shared $HOME markers silently, putting this project's inbox state back in the
# pool with every other project's -- the defect the per-project keying exists to
# close.
setup_case
register "${LOG_CHANNEL}"
stub_repo '#!/usr/bin/env bash
case "$1" in --repo-key) echo "unknown argument" >&2; exit 2 ;; esac
printf '"'"'{"channels":[{"name":"slack","kind":"log","new":2}],"failed_candidates":0}'"'"'
exit 0'
run_stub_hook
assert_contains "R16 an inbox-status without --repo-key is logged, not silently shared" \
  "could not name this project's repo identity" "$(hook_log)"
assert_contains "R16 ...and the count is still reported" "2 new in slack" \
  "$(context_of "${OUT}")"

# An EMPTY key is the quiet case: a cwd in no git repository has nothing that
# could ever have had channels.
setup_case
register "${LOG_CHANNEL}"
stub_repo '#!/usr/bin/env bash
case "$1" in --repo-key) printf '"'"'\n'"'"'; exit 0 ;; esac
printf '"'"'{"channels":[{"name":"slack","kind":"log","new":2}],"failed_candidates":0}'"'"'
exit 0'
run_stub_hook
assert_not_contains "R16 an EMPTY repo key is the quiet no-git-repo case, not a fault" \
  "could not name this project's repo identity" "$(hook_log)"

# A repo that NEVER opted in must stay silent. Without this, the warning above
# would fire in every unrelated repo on the machine -- the noise this hook
# refuses everywhere else.
setup_case
run_hook
assert_eq "R16 a repo that never opted in says nothing" "" "${OUT}"

echo "== R17: a count known to be inflated is never announced as plain fact =="

# `state_unreadable` means the channel was re-read from offset 0 with empty
# seen-sets, so the number includes messages already acked. The caveat used to
# live in HEALTH_TEXT, which the warn-marker rate limit blanks -- so for up to a
# whole six-hour window the pre-prompt notice read "N new in slack" as fact.
# The caveat now rides the NUMBER, which no rate limit can strip, exactly as
# inbox-status attaches its own per-channel Fix: unconditionally.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
printf 'not json' > "${ATHENA_INBOX_ROOT}/p-slack.state.json"
touch "$(pm health-warn)"    # the warning is silenced...
run_hook
CTX="$(context_of "${OUT}")"
assert_contains "R17 the inflated count still carries its caveat" \
  "not deduped" "${CTX}"
assert_contains "R17 the precondition: the warning itself IS rate-limited here" \
  "2 new in slack" "${CTX}"
assert_not_contains "R17 ...and the rate-limited warning really is absent" \
  "unreadable state file" "${CTX}"

# THE DEGRADED-KEY PATH. Without sha256sum the marker cannot be named, so R16
# is inert -- and an inert detector looks exactly like a healthy project. Every
# other R16 case runs with the tool present, so a change that emptied the hash
# would keep the whole suite green while the round-4 fix did nothing. Closed the
# way F-4a closes the missing-jq path: PATH rebuilt from scratch, not filtered.
setup_case
register "${LOG_CHANNEL}"
run_hook                                    # session 1 records the seen marker
rm -f "${ATHENA_INBOX_ROOT}/projects/p.json"
NOBIN2="${CASE_DIR}/nobin2"; mkdir -p "${NOBIN2}"
for b in bash dirname date mkdir wc tail mv rm stat sed grep cat timeout jq cut git realpath awk; do
  src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${NOBIN2}/${b}"
done
OLD_PATH="${PATH}"
PATH="${NOBIN2}" run_hook
PATH="${OLD_PATH}"
assert_contains "R16 a key that cannot be hashed is LOGGED, not silently shared" \
  "markers cannot be named" "$(hook_log)"
assert_eq "R16 the degraded run still exits 0" "0" "${RC}"

# A TIMEOUT on --repo-key is an expiry, not version skew. The command itself
# cannot fail; the `timeout` wrapping it can, which is why that wrapper exists
# (an inbox root on a slow or stale mount). Diagnosing it as a checkout
# mismatch would send the reader to compare trees over a transient condition.
setup_case
register "${LOG_CHANNEL}"
export ATHENA_INBOX_STATUS_TIMEOUT_SECONDS=1
stub_repo '#!/usr/bin/env bash
case "$1" in --repo-key) sleep 30 ;; esac
printf '"'"'{"channels":[{"name":"slack","kind":"log","new":2}],"failed_candidates":0}'"'"'
exit 0'
run_stub_hook
unset ATHENA_INBOX_STATUS_TIMEOUT_SECONDS
assert_contains "R16 a --repo-key timeout is reported as an expiry" \
  "did not finish within" "$(hook_log)"
assert_not_contains "R16 ...and not misdiagnosed as version skew" \
  "could not name this project's repo identity" "$(hook_log)"

# The THIRD route to an empty hash: sha256sum present but its output unusable
# (here, `cut` removed). It must log like the other two, because the fallback
# it drops into is the shared marker family.
setup_case
register "${LOG_CHANNEL}"
NOCUT="${CASE_DIR}/nocut"; mkdir -p "${NOCUT}"
for b in bash dirname date mkdir wc tail mv rm stat sed grep cat timeout jq git realpath awk sha256sum; do
  src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${NOCUT}/${b}"
done
OLD_PATH="${PATH}"
PATH="${NOCUT}" run_hook
PATH="${OLD_PATH}"
assert_contains "R16 an unhashable identity is LOGGED, not silently shared" \
  "could not be hashed" "$(hook_log)"

# ...and the converse: a cwd in NO git repository has no identity to remember
# and legitimately logs nothing about it, because there is nothing there that
# could ever have had channels.
setup_case
NOGIT="${CASE_DIR}/nogit"
mkdir -p "${NOGIT}"
REPO="${NOGIT}"
run_hook
assert_not_contains "R16 a cwd in no git repo is not reported as a degraded key" \
  "markers cannot be named" "$(hook_log)"
assert_eq "R16 a cwd in no git repo still exits 0" "0" "${RC}"

# GIT ABSENT is "could not tell", NOT "no git repository". inbox-status here is
# the real one and supports --repo-key, but with git off PATH inbox_repo_key
# cannot DETERMINE the identity and exits non-zero -- which the hook must LOG
# (and fall back to shared markers) rather than read an empty key as "no repo,
# nothing to report". The previous `|| printf ''` collapsed the two, so a
# git-less session looked healthy-and-empty. EVERY other degraded-key case above
# keeps git on the stripped PATH, so none of them covered this input class
# (DND-188 merge-round critic). PATH rebuilt from scratch, deliberately WITHOUT
# git, the way F-4a rebuilds it to drop jq.
setup_case
register "${LOG_CHANNEL}"
run_hook                                    # session 1 (git present) opts in
NOGITBIN="${CASE_DIR}/nogitbin"; mkdir -p "${NOGITBIN}"
for b in bash dirname date mkdir wc tail mv rm stat sed grep cat timeout jq cut realpath awk sha256sum; do
  src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${NOGITBIN}/${b}"
done                                        # NOTE: git is intentionally omitted
OLD_PATH="${PATH}"
PATH="${NOGITBIN}" run_hook
PATH="${OLD_PATH}"
assert_contains "R16 git absent is 'could not tell', LOGGED not silently shared" \
  "could not name this project's repo identity" "$(hook_log)"
assert_eq "R16 the git-absent run still exits 0" "0" "${RC}"
# And it must NOT be mislabelled as a project that never opted in: because
# inbox-status --json now REFUSES on could-not-tell (no document), the poll fails
# (POLL_OK=0) instead of reading as OPTED_IN=0, so the false "nothing to poll
# here" line never appears and the failed-poll line does.
assert_not_contains "R16 git absent is not misreported as 'never opted in'" \
  "nothing to poll here" "$(hook_log)"
assert_contains "R16 ...it is recorded as a failed poll instead" \
  "no usable status document" "$(hook_log)"
# The session is NOT silent: a failed poll with a stale success marker surfaces
# the outage warning, so a git-broken environment is visible in-session rather
# than looking like a quiet morning.
assert_contains "R16 git absent surfaces the outage warning, not silence" \
  "has not succeeded recently" "$(context_of "${OUT}")"
# The ticket's binding invariant: a run that could not even name the project is
# a FAILURE and must NEVER stamp success -- here the shared success marker, since
# the per-project one cannot be named.
if [ ! -e "${HOME}/.claude/athena-inbox-last-success" ]; then
  ok "R16 git absent (could-not-tell) stamps no shared success marker"
else
  bad "R16 git absent (could-not-tell) stamps no shared success marker" "shared success marker was stamped on a failed identity resolution"
fi

echo "== R12: a registry entry that could not be read is surfaced, not skipped =="

# The sharpest form of the standing question. `projects/` is multi-tenant: an
# entry that fails to parse is DROPPED from the candidate set, and the session
# whose entry it was then looks exactly like a session that never opted in --
# zero channels, exit 0, nothing wrong. inbox-status reports the drop as
# `failed_candidates`; the hook's job is to SAY it, because the one reader who
# can fix it is the one starting this session. Sabotage S9 (a measured zero)
# deleted the whole clause and the suite stayed green.
#
# The clause counts and does not name: every other entry under projects/ belongs
# to a different tenant.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
# A LOWERCASE name, deliberately: the registry's own name grammar rejects
# uppercase, so an entry called `ZQX....json` is not a failed candidate -- it is
# not a candidate at all, and this case would assert nothing while looking like
# it asserted everything.
printf 'not json at all' > "${ATHENA_INBOX_ROOT}/projects/${SENTINEL_LC}.json"
run_hook
CTX="$(context_of "${OUT}")"
assert_contains "R12 an unreadable registry entry is surfaced" \
  "1 other registry entry(s) could not be parsed" "${CTX}"
assert_contains "R12 ...as somebody else's dark project, which is what it is here" \
  "those projects are dark" "${CTX}"
assert_not_contains "R12 the clause counts and does not name the other tenant" \
  "${SENTINEL_LC}" "${OUT}"
assert_contains "R12 the real mail is still counted alongside the health clause" \
  "2 new in slack" "${CTX}"

# ...and the state the OLD wording described -- NO matching entry plus an
# unparseable candidate, where "one of them may be this project's" really is
# true -- never reaches a health clause at all. `inbox_entry` treats it as a
# HARD REFUSAL, so inbox-status exits 1 with empty stdout and it arrives here as
# a FAILED POLL. That is the correct handling (a possibly-mine unreadable entry
# must not be shrugged off as a healthy machine with someone else's problem),
# and it is why the clause above can honestly say "other". No fixture reached
# this branch before, so nothing contradicted the wording it was written for.
setup_case
printf 'not json at all' > "${ATHENA_INBOX_ROOT}/projects/${SENTINEL_LC}.json"
run_hook
CTX="$(context_of "${OUT}")"
assert_contains "R12 an unreadable candidate with NO match is a failed poll, not a health note" \
  "has not succeeded recently" "${CTX}"
assert_not_contains "R12 ...so it never renders the other-projects clause" \
  "those projects are dark" "${CTX}"
assert_no_file "R12 ...and it does not stamp success" \
  "$(pm success)"
assert_contains "R12 ...and the refusal is recorded" \
  "no usable status document" "$(hook_log)"
assert_not_contains "R12 ...without relaying the refusal's own text" \
  "${SENTINEL_LC}" "$(hook_log)"

echo "== R9: an ANSWER THAT CANNOT BE READ is a failed poll, not an empty one =="

# The standing question for this epic: what happens when the input is MISSING
# rather than wrong? "inbox-status said nothing usable" and "inbox-status said
# zero" are the same silence on stdout, and they must NOT be the same state --
# the first leaves the success marker unstamped so the staleness warning can
# eventually fire, the second stamps it. Every fixture above reaches the failing
# path through EMPTY stdout, so the shape check on a NON-EMPTY answer was, until
# this case, protecting nothing (sabotage S15, a measured zero: replacing the
# whole jq shape test with `true` left the suite green).

setup_case
register "${LOG_CHANNEL}"
stub_repo '#!/usr/bin/env bash
case "$1" in --repo-key) realpath "$(git rev-parse --git-common-dir)"; exit 0 ;; esac
printf "not a status document at all\n"
exit 0'
run_stub_hook
# Not "no stdout": with no success marker at all this is F-5's never-worked
# setup, which warns on the first attempt -- correctly. The claim is that it is
# a WARNING and not a COUNT.
assert_not_contains "R9 non-empty but unparseable output is not a count" \
  "new in" "${OUT}"
assert_contains "R9 non-empty but unparseable output warns instead" \
  "has not succeeded recently" "$(context_of "${OUT}")"
assert_eq "R9 non-empty but unparseable output still exits 0" "0" "${RC}"
assert_no_file "R9 non-empty but unparseable output does NOT stamp success" \
  "$(pm success)"
assert_contains "R9 the unusable answer is logged as a fixed reason" \
  "no usable status document" "$(hook_log)"

# Well-formed JSON is not the same as a status document. An object whose
# `channels` is not an array would make every count expression below it silently
# evaluate to nothing -- the exact shape of a green run that reports no mail.
setup_case
register "${LOG_CHANNEL}"
stub_repo '#!/usr/bin/env bash
case "$1" in --repo-key) realpath "$(git rev-parse --git-common-dir)"; exit 0 ;; esac
printf '"'"'{"channels":{"slack":2}}'"'"'
exit 0'
run_stub_hook
assert_not_contains "R9 a JSON object of the wrong shape is not a count" "new in" "${OUT}"
assert_no_file "R9 a JSON object of the wrong shape does NOT stamp success" \
  "$(pm success)"

# The stub proves the control: the SAME harness with a well-formed document does
# produce a count. Without this, all three assertions above would also hold for
# a stub that simply never ran.
setup_case
register "${LOG_CHANNEL}"
stub_repo "${STUB_OK}"
run_stub_hook
assert_contains "R9 the control: a well-formed document IS counted" "2 new in slack" \
  "$(context_of "${OUT}")"
assert_file "R9 the control: a usable answer stamps success" \
  "$(pm success)"

echo "== R14: the wrapped command is bounded too =="

# This hook has TWO blocking inputs and had a ceiling on only one. The stdin
# read is bounded because an inherited open pipe never sees EOF; inbox-status
# scans channel files with no timeout of its own, so a very large .jsonl or an
# inbox root on a stale mount blocks SessionStart for as long as it takes. An
# expiry is just another failed poll -- the success marker stays unstamped, so
# the staleness warning can still eventually fire.
setup_case
register "${LOG_CHANNEL}"
export ATHENA_INBOX_STATUS_TIMEOUT_SECONDS=1
stub_repo '#!/usr/bin/env bash
case "$1" in --repo-key) realpath "$(git rev-parse --git-common-dir)"; exit 0 ;; esac
sleep 30
printf '"'"'{"channels":[]}'"'"''
START="$(date +%s)"
run_stub_hook
ELAPSED=$(( $(date +%s) - START ))
unset ATHENA_INBOX_STATUS_TIMEOUT_SECONDS
if [ "${ELAPSED}" -lt 10 ]; then
  ok "R14 a hanging inbox-status does not hang session start (${ELAPSED}s)"
else
  bad "R14 a hanging inbox-status does not hang session start" "took ${ELAPSED}s"
fi
assert_eq "R14 the expiry still exits 0" "0" "${RC}"
assert_no_file "R14 an expired poll does NOT stamp success" \
  "$(pm success)"

echo "== R15: a Fix: must answer the question it promises =="

# inbox-status is counts-only for tenant privacy: it can say HOW MANY registry
# entries failed to parse, and by design never WHICH -- naming them would
# enumerate other tenants. So the health warning's generic "run inbox-status to
# see which" is a true instruction for the channel-level clauses and a FALSE one
# for this clause, sending an agent to re-run a command that returns the same
# number. That is the same defect R11 exists to prevent, arriving through the
# guard-message convention instead of the read-step pointer.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
printf 'not json at all' > "${ATHENA_INBOX_ROOT}/projects/${SENTINEL_LC}.json"
run_hook
CTX="$(context_of "${OUT}")"
assert_contains "R15 the unreadable-entry Fix names something actually actionable" \
  "is valid JSON" "${CTX}"
assert_contains "R15 the unreadable-entry Fix admits inbox-status cannot say which" \
  "cannot say which" "${CTX}"
assert_not_contains "R15 and does not point at a command that returns the same number" \
  "inbox-status from this project to see which" "${CTX}"

# The channel-level clauses keep the pointer, because inbox-status CAN answer
# for them -- the fix above must not flatten both into one vague sentence.
setup_case
register "${LOG_CHANNEL}"
run_hook
assert_contains "R15 a channel-level clause still points at inbox-status" \
  "inbox-status from this project to see which" "$(context_of "${OUT}")"

echo "== R10: the wrapped command's stderr is discarded, never relayed =="

# inbox-status refuses on stderr with paths and channel names in the clause.
# None of that belongs in this hook's notice OR in its log, and discarding the
# stream is the structural guarantee rather than a promise. Sabotage S23 (a
# measured zero) relayed that stderr into the log and the suite stayed green,
# because no fixture put anything identifiable on it.
setup_case
register "${LOG_CHANNEL}"
stub_repo '#!/usr/bin/env bash
case "$1" in --repo-key) realpath "$(git rev-parse --git-common-dir)"; exit 0 ;; esac
printf "refusing: '"${SENTINEL}"'\n" >&2
printf '"'"'{"channels":[{"name":"slack","kind":"log","new":2}],"failed_candidates":0}'"'"'
exit 1'
run_stub_hook
assert_not_contains "R10 the wrapped command's stderr does not reach stdout" \
  "${SENTINEL}" "${OUT}"
assert_not_contains "R10 the wrapped command's stderr does not reach this hook's stderr" \
  "${SENTINEL}" "${ERR}"
assert_not_contains "R10 the wrapped command's stderr does not reach the reason log" \
  "${SENTINEL}" "$(hook_log)"
assert_contains "R10 a partial success is still counted (rc is not the signal)" \
  "2 new in slack" "$(context_of "${OUT}")"

echo "== R11: the notice points at a step that EXISTS =="

# An instruction an agent cannot act on is worse than no instruction, and
# read-inbox ships with a later ticket. Both branches are asserted: F-1's
# `contains "read-inbox"` passes on EITHER branch (the not-installed sentence
# names it too), so it was never protecting the switch -- sabotage S16, a
# measured zero.
setup_case
register "${LOG_CHANNEL}"
stub_repo "${STUB_OK}"
run_stub_hook
CTX="$(context_of "${OUT}")"
assert_contains "R11 with read-inbox absent the notice says so" "not installed yet" "${CTX}"
assert_not_contains "R11 with read-inbox absent the notice does not tell anyone to run it" \
  "Run athena:inbox read-inbox" "${CTX}"

setup_case
register "${LOG_CHANNEL}"
stub_repo "${STUB_OK}" --with-read-inbox
run_stub_hook
CTX="$(context_of "${OUT}")"
assert_contains "R11 with read-inbox present the notice names the command" \
  "Run athena:inbox read-inbox" "${CTX}"
assert_not_contains "R11 with read-inbox present the not-installed sentence is gone" \
  "not installed yet" "${CTX}"

echo "== F-11: registration through the registry, never by hand =="

# F-11: the entry exists, on SessionStart, with the all-events matcher — and NO
# UserPromptSubmit entry, which D3 rules out explicitly.
REG="${REPO_DIR}/ai/hooks/registry.json"
assert_eq "F-11 the hook is registered on SessionStart with the \"\" matcher" "SessionStart|" \
  "$(jq -r '.hooks[] | select(.script == "ai/hooks/athena-inbox-poll.sh") | "\(.event)|\(.matcher)"' "${REG}" 2>/dev/null)"
assert_eq "F-11 no UserPromptSubmit entry is registered for any hook" "0" \
  "$(jq -r '[.hooks[] | select(.event == "UserPromptSubmit")] | length' "${REG}" 2>/dev/null)"
# The five hooks that predate this ticket must all still be registered. The
# 2026-09-17 outage was exactly this: entries silently disappearing from a file
# with no diff and no undo.
for s in safe-wait-guard pronoun-guard harness-event notify-idle main-session-policy; do
  assert_eq "F-11 pre-existing hook [${s}] is still in the registry" "1" \
    "$(jq -r --arg s "ai/hooks/${s}.sh" '[.hooks[] | select(.script == $s)] | length' "${REG}" 2>/dev/null)"
done

# The installer is exercised end to end against a TEMP settings file carrying
# unrelated keys. Written out here rather than delegated to
# `setup-hooks --self-test` deliberately: that self-test resolves hook paths
# against the MAIN checkout, where a brand-new hook does not exist until this
# branch merges, so delegating would make this case measure the state of
# ~/dev/custom rather than the state of this change.
setup_case
SET="${CASE_DIR}/settings.json"
printf '{\n  "model": "x",\n  "permissions": {"allow": ["Bash(ls:*)"]}\n}\n' > "${SET}"
( cd "${REPO_DIR}" && HOOKS_SETTINGS_FILE="${SET}" scripts/setup-hooks --install >/dev/null 2>&1 )
R2="$( cd "${REPO_DIR}" && HOOKS_SETTINGS_FILE="${SET}" scripts/setup-hooks --install 2>&1 )"
assert_contains "F-11 a second --install is a no-op (idempotent)" "nothing to do" "${R2}"
assert_eq "F-11 the merge preserves an unrelated scalar key" "x" \
  "$(jq -r '.model' "${SET}" 2>/dev/null)"
assert_eq "F-11 the merge preserves an unrelated nested key" "Bash(ls:*)" \
  "$(jq -r '.permissions.allow[0]' "${SET}" 2>/dev/null)"
assert_eq "F-11 the new hook is wired on SessionStart" "1" \
  "$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | endswith("athena-inbox-poll.sh"))] | length' "${SET}" 2>/dev/null)"
for s in safe-wait-guard pronoun-guard harness-event notify-idle main-session-policy; do
  assert_eq "F-11 the merge leaves pre-existing hook [${s}] wired" "1" \
    "$(jq --arg s "${s}.sh" '[.hooks[]?[]?.hooks[]? | select(.command | endswith($s))] | length' "${SET}" 2>/dev/null)"
done
# HOME is restored for the ruby checks: `ruby` here is an asdf shim that
# resolves its version data under $HOME, so running it with the fake HOME makes
# the checker fail for a reason that has nothing to do with the thing under
# test. (A failure message that fits both "the check failed" and "the
# interpreter could not start" must be told apart before it is believed.)
if ( cd "${REPO_DIR}" && HOME="${REAL_HOME}" HOOKS_SETTINGS_FILE="${SET}" ai/bin/check-hooks-registered >/dev/null 2>&1 ); then
  ok "F-11 check-hooks-registered passes against the installed settings"
else
  bad "F-11 check-hooks-registered passes against the installed settings" \
      "ai/bin/check-hooks-registered reported drift"
fi

echo "== F-12: the guard-message convention =="

# F-12: a counts-only notifier with no deny path is the same species as
# main-session-policy.sh, so EXEMPT is the honest classification. Asserted two
# ways: the checker passes, AND the exemption is actually present with a reason
# (the checker would also pass if a bolted-on `Fix:` line had been added
# instead, which is exactly the dodge the ticket forbids).
if ( cd "${REPO_DIR}" && HOME="${REAL_HOME}" ai/bin/check-guard-messages >/dev/null 2>&1 ); then
  ok "F-12 check-guard-messages passes with the new hook"
else
  bad "F-12 check-guard-messages passes with the new hook" "ai/bin/check-guard-messages failed"
fi
# The checker would ALSO pass if a bolted-on `Fix:` line had been added to the
# hook instead of exempting it -- which is exactly the dodge the ticket forbids.
# So assert the classification itself, with its reason.
if grep -Eq '"athena-inbox-poll\.sh" +=> +"[^"]+"' "${REPO_DIR}/ai/bin/check-guard-messages"; then
  ok "F-12 the hook is EXEMPT with a stated reason, not carrying a fake deny path"
else
  bad "F-12 the hook is EXEMPT with a stated reason, not carrying a fake deny path" \
      "no EXEMPT entry with a reason in ai/bin/check-guard-messages"
fi

echo "== hardening: --dry-run, the log bound, and the stdin guard =="

# --dry-run writes NO markers: a diagnostic run that mutates the rate-limit
# state would suppress the next real session's warning.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
run_hook --dry-run
assert_no_file "--dry-run writes no attempt marker" "${HOME}/.claude/athena-inbox-last-poll"
assert_no_file "--dry-run writes no success marker" "$(pm success)"
assert_no_file "--dry-run writes no log" "${HOME}/.claude/athena-inbox-poll.log"
assert_one_json_object "--dry-run still emits exactly one well-formed object" "${OUT}"
if [ "$(printf '%s' "${OUT}" | wc -l)" -gt 1 ]; then
  ok "--dry-run pretty-prints (more than one line)"
else
  bad "--dry-run pretty-prints (more than one line)" "got a single line: [${OUT}]"
fi

# --dry-run skips the stdin guard: a manual run from a pipe carrying anything at
# all must still produce its diagnostic.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
HOOK_STDIN='not json'
run_hook --dry-run
HOOK_STDIN=""
assert_one_json_object "--dry-run skips the stdin guard" "${OUT}"

# The log is bounded. An unbounded reason log on a machine that starts many
# sessions a day is a slow leak nobody notices until it is large.
setup_case
register "${LOG_CHANNEL}"
: > "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
for _ in $(seq 1 205); do printf 'filler\n' >> "${HOME}/.claude/athena-inbox-poll.log"; done
run_hook
LOGLINES="$(hook_log | wc -l | tr -d ' ')"
if [ "${LOGLINES}" -le 200 ]; then ok "the reason log is bounded to 200 lines (got ${LOGLINES})"
else bad "the reason log is bounded to 200 lines" "got ${LOGLINES}"; fi
assert_contains "the bound keeps the NEWEST lines, not the oldest" "nothing to report" "$(hook_log)"

# The stdin read is BOUNDED. An unbounded `cat` on an inherited open pipe never
# sees EOF and would hang session start forever (walt_ui M8). Asserted by
# holding a pipe open and requiring the hook to finish anyway.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
assert_fake_home
# A FIFO held open by a background writer, not `sleep | hook`: a pipeline waits
# for every member, so the sleep's own duration would be what this measured.
FIFO="${CASE_DIR}/fifo"; mkfifo "${FIFO}"
( exec 9>"${FIFO}"; sleep 20 ) & WRITER_PID=$!
START="$(date +%s)"
OUT="$( cd "${REPO}" && timeout 10 "${HOOK}" < "${FIFO}" 2>/dev/null )"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
kill "${WRITER_PID}" 2>/dev/null; wait "${WRITER_PID}" 2>/dev/null; WRITER_PID=""
if [ "${RC}" -ne 124 ] && [ "${ELAPSED}" -lt 8 ]; then
  ok "the stdin read is bounded — an open pipe does not hang session start (${ELAPSED}s)"
else
  bad "the stdin read is bounded — an open pipe does not hang session start" \
      "rc=${RC} elapsed=${ELAPSED}s"
fi

# An unknown argument is not a reason to interrupt a session, and not a reason
# to emit garbage either.
setup_case
register "${LOG_CHANNEL}"
plant_log_lines
run_hook --no-such-flag
assert_one_json_object "an unrecognised argument is ignored, not fatal" "${OUT}"
assert_contains "an unrecognised argument is noted in the log" "unrecognised argument" "$(hook_log)"

# The help text is the header block, and it states the output contract verbatim
# — the ticket requires the contract to live in the file, where an implementer
# changing this hook will actually read it.
setup_case
run_hook -h
assert_contains "-h prints the output contract verbatim" \
  '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":' "${OUT}"
assert_contains "-h states the counts-only rule" "WHAT IT NEVER PRINTS" "${OUT}"

# inbox-status itself must exist where the hook looks for it. A path typo would
# otherwise degrade into permanent, contract-conformant silence.
if [ -x "${STATUS_BIN}" ]; then ok "the wrapped command exists where the hook resolves it"
else bad "the wrapped command exists where the hook resolves it" "not executable: ${STATUS_BIN}"; fi

# The real HOME was never a target. Two independent checks, because the live
# machine writes into ~/.claude on its own cadence and the guard must tell a
# genuine suite leak apart from an unrelated concurrent live poll write.
HOME="${REAL_HOME}"
export HOME

# (1) The PRECISE leak signature. A genuine suite leak means a case ran the hook
# with HOME pointing at the real $HOME instead of its per-case tmp home; the hook
# then resolves this suite's FAKE repo (every fake project lives under ${TMP}, so
# its repo-key -- and thus the marker hash -- is unique to this run) and writes
# a marker under ${REAL_HOME}/.claude/athena-inbox-seen/<fake-hash>.*. The live
# poll only ever writes under the REAL repo's hash, so this signature is one it
# can NEVER produce. The fake hashes are recomputed the SAME way the hook names
# them -- inbox-status --repo-key, hashed -- so a divergence between suite and
# hook cannot hide a leak.
#
# Every fake repo is enumerated by FINDING every git dir under ${TMP}, not by
# path name: cases fabricate repos at proj/, other/, sibling/ and stubrepo/, so
# a name-based list ("case-*/proj") would silently miss the others. And this
# check refuses to read "found nothing to look at" as "no leak" (the repo's
# "a failed lookup must never look like an empty one" rule): checking zero
# projects, or being unable to compute any fake project's hash, is a FAILURE.
leaked=""
checked=0
uncomputable=""
while IFS= read -r _gitmeta; do
  [ -n "${_gitmeta}" ] || continue
  _proj="$(dirname -- "${_gitmeta}")"
  [ -d "${_proj}" ] || continue
  checked=$((checked + 1))
  if ! _fkey="$(cd "${_proj}" 2>/dev/null && "${STATUS_BIN}" --repo-key 2>/dev/null)"; then
    uncomputable="${uncomputable} ${_proj}(--repo-key exited non-zero)"; continue
  fi
  if [ -z "${_fkey}" ]; then
    uncomputable="${uncomputable} ${_proj}(empty key from a repo with a .git)"; continue
  fi
  _fhash="$(printf '%s' "${_fkey}" | sha256sum 2>/dev/null | cut -c1-32)"
  case "${_fhash}" in
    ''|*[!0-9a-f]*) uncomputable="${uncomputable} ${_proj}(bad hash [${_fhash}])"; continue ;;
  esac
  for _m in "${REAL_SEEN_DIR}/${_fhash}."*; do
    [ -e "${_m}" ] || continue
    leaked="${leaked}
        $(basename -- "${_m}")  (fake project: ${_fkey})"
  done
done < <(find "${TMP}" -name .git 2>/dev/null)
if [ "${checked}" -eq 0 ]; then
  bad "no fake-project marker leaked into the real \$HOME seen dir" \
"checked ZERO fake projects under ${TMP}, so this check vouches for nothing --
        yet ${CASE_N} cases ran and every one fabricates a git repo. Either find(1)
        failed or the per-case repos are gone. Fix: confirm find is on PATH and
        the fake repos still exist under ${TMP} when this check runs."
elif [ -n "${uncomputable}" ]; then
  bad "no fake-project marker leaked into the real \$HOME seen dir" \
"could not compute the marker hash for fake project(s), so a leak keyed to them
        could not be ruled out (a failed lookup must never read as 'no leak'):${uncomputable}
        Fix: check that ${STATUS_BIN} --repo-key, sha256sum and cut work in this session."
elif [ -z "${leaked}" ]; then
  ok "no fake-project marker leaked into the real \$HOME seen dir (${checked} fake projects checked)"
else
  bad "no fake-project marker leaked into the real \$HOME seen dir" \
"the suite wrote per-project marker(s) into ${REAL_SEEN_DIR} keyed to a FAKE
        project it fabricated under ${TMP} (${checked} projects checked) -- so a
        suite helper built a marker path from \${REAL_HOME} instead of the
        per-case \${HOME}:${leaked}
        Fix: find the helper that wrote under \${REAL_HOME}/.claude/athena-inbox-seen
        (the hook itself cannot -- assert_fake_home FATAL-exits every run_hook /
        run_stub_hook against the real \$HOME); it must build the path from
        \${HOME} beneath ${TMP}. Remove the leaked file(s) named above from ${REAL_SEEN_DIR}."
fi

# (2) The daemon-UNTOUCHED members of the family, byte-for-byte unmoved. These
# are the top-level FALLBACK markers (written only on the hook's degraded,
# hash-unresolvable path, which this machine's live poll never takes) and
# settings.json (only ever read). last-poll, poll.log and the seen DIRECTORY are
# NOT here: the live poll rewrites all three every session, so an mtime assertion
# on them races the daemon (that was the DND-224 false positive). Their leak
# coverage is check (1) for the seen dir and check (3) for the log.
assert_eq "the suite left the real \$HOME marker family untouched" \
  "${REAL_MARKERS_BEFORE}" "$(real_markers_fingerprint)"

# (3) poll.log is SHARED (not project-keyed) and the live poll appends to it on
# every session, so its mtime/length cannot be fingerprinted without racing.
#
# WHO could write to the real poll.log at all? Not the hook: every hook
# invocation in this suite goes through run_hook / run_stub_hook, each of which
# calls assert_fake_home FIRST, and assert_fake_home FATAL-exits the whole suite
# the instant HOME is the real home. So a hook run against the real $HOME is
# structurally impossible -- it never reaches the log write -- which is why the
# dropped mtime fingerprint on last-poll / poll.log was a backstop for an event
# assert_fake_home already prevents, not primary coverage, and racy against the
# daemon besides. The remaining writer is a suite HELPER that hardcodes
# ${REAL_HOME}. Check (3) guards that vector by CONTENT: the live poll only ever
# logs fixed real-repo reason strings (see log_reason), never a path under
# ${TMP} nor the suite's sentinel, so either string in the real log is a trace
# only a suite helper could have left, and a concurrent live write can never trip
# it. (athena-inbox-last-poll -- a 0-byte attempt marker a helper could touch
# with no ${TMP}/sentinel signature -- is the one residual, and it changes no
# rate-limit decision; see SABOTAGE_RECORDS.md Z-DND224-1.)
real_log="${REAL_HOME}/.claude/athena-inbox-poll.log"
if [ -f "${real_log}" ] && \
   { grep -qF -- "${TMP}" "${real_log}" 2>/dev/null || grep -qF -- "${SENTINEL}" "${real_log}" 2>/dev/null; }; then
  bad "the suite left no trace in the real \$HOME poll log" \
"the real poll log ${real_log} contains this suite's tmp root (${TMP}) or its
        sentinel -- the live poll never logs either, so a suite helper appended to
        the real log. Fix: a write reached \${REAL_HOME}/.claude/athena-inbox-poll.log
        instead of \${HOME}/.claude/athena-inbox-poll.log; every log write must land
        under the per-case \${HOME} beneath ${TMP}. Remove the offending lines from ${real_log}."
else
  ok "the suite left no trace in the real \$HOME poll log"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "${FAIL}" -eq 0 ]; then
  echo "VERDICT: PASS (${TOTAL} cases)"
  exit 0
else
  echo "VERDICT: FAIL (${FAIL} of ${TOTAL} cases)"
  exit 1
fi
