#!/usr/bin/env bash
# Self-test for the athena:inbox domain libraries, the fs adapter, the count
# manager, and bin/inbox-status.  (DND-183's slice: QA cases D-1 … D-19, D-24,
# and the access-control negatives A-4 and A-8.)
#
# Every case here is about a decision that is INVISIBLE in production until it
# corrupts something: a partial final line counted once too often, an offset
# that advanced past bytes nobody read, a registry typo that silently became a
# default, a status line that quietly relays a peer-chosen filename into the
# pre-prompt position, a resolver that shows one project another project's
# channels. Each of those failures looks exactly like the healthy state from
# the outside, which is why they are asserted rather than eyeballed.
#
# The inbox root is ALWAYS a mktemp -d under this test's control: the live
# delivery path (~/.local/share/athena) is never read and never written. No
# network, ever -- nothing here makes one.
#
# Run: bash test/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"
LIB="${ROOT}/lib"
BIN="${ROOT}/bin"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0

ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# assert_eq <claim> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}
# assert_contains <claim> <needle> <haystack>
assert_contains() {
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac
}
# assert_not_contains <claim> <needle> <haystack>
assert_not_contains() {
  case "$3" in *"$2"*) bad "$1" "expected NOT to contain [$2], got [$3]" ;; *) ok "$1" ;; esac
}
# assert_ok <claim> <command...>
assert_ok() {
  local claim="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "${claim}"; else bad "${claim}" "exited non-zero"; fi
}
# assert_refused <claim> <command...>  -- non-zero AND a Fix: clause on stderr.
assert_refused() {
  local claim="$1"; shift
  local err rc
  err="$("$@" 2>&1 >/dev/null)"; rc=$?
  if [ "${rc}" -eq 0 ]; then bad "${claim}" "accepted (exit 0)"
  else assert_contains "${claim}" "Fix:" "${err}"; fi
}

# shellcheck source=/dev/null
. "${LIB}/err.sh"
# shellcheck source=/dev/null
. "${LIB}/names.sh"
# shellcheck source=/dev/null
. "${LIB}/descriptor.sh"
# shellcheck source=/dev/null
. "${LIB}/logchan.sh"
# shellcheck source=/dev/null
. "${LIB}/maildir.sh"
# shellcheck source=/dev/null
. "${LIB}/fs.sh"
# shellcheck source=/dev/null
. "${LIB}/inbox.sh"

# A case directory + a private inbox root + a private registry, per case.
CASE_N=0
setup_case() {
  CASE_N=$((CASE_N + 1))
  CASE_DIR="${TMP}/case-${CASE_N}"
  ATHENA_INBOX_ROOT="${CASE_DIR}/root"
  mkdir -p "${ATHENA_INBOX_ROOT}/projects"
  export ATHENA_INBOX_ROOT
}

# make_repo <name> -> prints its path; a real git repo, so the common-dir
# identity under test is the real one rather than a stub of it.
make_repo() {
  local p="${CASE_DIR}/$1"
  mkdir -p "${p}"
  ( cd "${p}" && git init -q . && git config user.email t@t && git config user.name t )
  printf '%s\n' "${p}"
}

# register <file-stem> <repo-path> <channels-json>
register() {
  local stem="$1" repo="$2" channels="$3" common
  common="$(cd "${repo}" && realpath "$(git rev-parse --git-common-dir)")"
  jq -n --arg r "${common}" --argjson c "${channels}" \
    '{v:1, repo:$r, channels:$c}' > "${ATHENA_INBOX_ROOT}/projects/${stem}.json"
}

echo "== 1. Domain: lib/names.sh =="

# D-1: the ordinary case. If this ever fails the grammar has been tightened
# past the names the deployed writer actually produces.
assert_ok "D-1 a plain <name>.jsonl inbox name is accepted" \
  names_valid_inbox_name "slack-inbox.jsonl"

# D-2: the .jsonl suffix is load-bearing -- state, doorbell and lock paths are
# derived from it by suffix substitution, so a name without it has no derivable
# siblings. The bare string ".jsonl" is a suffix, not a name.
for n in "foo" "foo.json" ".jsonl"; do
  if names_valid_inbox_name "${n}"; then
    bad "D-2 name [${n}] is rejected (suffix is load-bearing)" "accepted"
  else
    ok "D-2 name [${n}] is rejected (suffix is load-bearing)"
  fi
done

# D-3: a name arriving from anywhere is advisory data, never a path. Mirrors
# the deployed Ruby client's valid_name? exactly (bare filename, no separator
# of either flavour, no traversal, no leading dot).
for n in "a/b.jsonl" ".." "../x.jsonl" "a\\b.jsonl" ".hidden.jsonl"; do
  if names_valid_inbox_name "${n}"; then
    bad "D-3 name [${n}] is rejected (separator/traversal/leading dot)" "accepted"
  else
    ok "D-3 name [${n}] is rejected (separator/traversal/leading dot)"
  fi
done
# A NUL cannot traverse a bash variable at all (the assignment drops it), so
# the grammar's NUL arm is unreachable from shell. Assert the reachable claim:
# the name that survives assignment is the NUL-free one. See SABOTAGE_RECORDS.md
# for the measured zero this produces.
# Measured on the ASSIGNMENT, not on `tr` -- piping through `tr -d '\0'`
# would assert a property of tr and prove nothing about bash.
# The redirect wraps the ASSIGNMENT, not the substitution: bash emits the
# "ignored null byte" warning itself, outside the subshell.
{ nulname="$(printf 'a\0b.jsonl')"; } 2>/dev/null
assert_eq "D-3 a NUL cannot survive a bash variable (grammar arm unreachable)" "ab.jsonl" "${nulname}"

# The `..` arm of the grammar is only REACHABLE for a name that has no
# separator and still ends in .jsonl -- every other traversal shape is already
# caught by the separator or suffix arms. Without this case the arm can be
# deleted and the suite stays green (measured: sabotage row S2).
if names_valid_inbox_name "a..b.jsonl"; then
  bad "D-3 an embedded [..] is rejected even with no separator" "accepted"
else ok "D-3 an embedded [..] is rejected even with no separator"; fi

# D-4: 128 bytes is the client's limit; 129 must not slip through.
long129="$(printf 'a%.0s' $(seq 1 123)).jsonl"   # 123 + 6 = 129
long128="$(printf 'a%.0s' $(seq 1 122)).jsonl"   # 122 + 6 = 128
assert_ok "D-4 a 128-byte name is accepted" names_valid_inbox_name "${long128}"
if names_valid_inbox_name "${long129}"; then bad "D-4 a 129-byte name is rejected" "accepted"
else ok "D-4 a 129-byte name is rejected"; fi

# D-5: containment is checked BEFORE any I/O and is lexical, because the file
# it protects legitimately may not exist yet (first run).
got="$(names_resolve_in_root "/tmp/r" "x.jsonl" 2>/dev/null)"
assert_eq "D-5 a relative name resolves inside the root" "/tmp/r/x.jsonl" "${got}"
for esc in "../x.jsonl" "/etc/passwd"; do
  assert_refused "D-5 escaping path [${esc}] is refused with a Fix: clause" \
    names_resolve_in_root "/tmp/r" "${esc}"
done

# D-6: the state and doorbell names are what pair a reader with its own
# channel; a mis-derivation silently reads another channel's offset.
assert_eq "D-6 state path derives by suffix substitution" \
  "slack-inbox.state.json" "$(names_state_name "slack-inbox.jsonl")"
assert_eq "D-6 doorbell path derives by suffix substitution" \
  "slack-inbox.event" "$(names_doorbell_name "slack-inbox.jsonl")"
assert_eq "D-6 lock path derives by suffix substitution" \
  "slack-inbox.consumer.lock" "$(names_lock_name "slack-inbox.jsonl")"

# A log channel's `path` may carry a namespace prefix (new channels should),
# while the legacy flat names the deployed writer produces stay legal -- but
# every directory segment is checked, so the prefix is not a hole.
assert_ok "a namespaced log path is accepted" names_valid_log_path "agent/x.jsonl"
assert_ok "a legacy flat log path is accepted" names_valid_log_path "x.jsonl"
for p in "../x.jsonl" "a/../x.jsonl" "A/x.jsonl" "a/x.json" "a/.x.jsonl"; do
  if names_valid_log_path "${p}"; then bad "an illegal log path is rejected: [${p}]" "accepted"
  else ok "an illegal log path is rejected: [${p}]"; fi
done

# A glob metacharacter must be judged as a LITERAL. These functions walk their
# segments by parameter expansion rather than `for x in ${var}` precisely
# because an unquoted expansion is pathname-expanded as well as word-split: a
# namespace of `*` would otherwise glob against the caller's cwd, so the
# grammar's verdict would depend on where it was called from and the component
# validated would not be the component returned. Asserted from INSIDE a
# directory that has entries to match, or the case measures nothing.
globdir="${TMP}/globdir"; mkdir -p "${globdir}/abc" "${globdir}/def"
for g in "*" "?" "[a-z]" "a/*" "*/b"; do
  if ( cd "${globdir}" && names_valid_namespace "${g}" ); then
    bad "a glob metacharacter is judged literally, not expanded: [${g}]" "accepted"
  else ok "a glob metacharacter is judged literally, not expanded: [${g}]"; fi
done
# A `*` in the FINAL component is legal and stays legal: the deployed Ruby
# client's valid_name? permits it (it bars only `/`, `\`, NUL, `..` and a
# leading dot), and this slice mirrors that grammar rather than reinventing a
# stricter one. What must hold is that it is treated as a LITERAL character --
# the same verdict from any cwd -- not that it is refused.
if ( cd "${globdir}" && names_valid_log_path "*.jsonl" ) \
  && ( cd "${TMP}" && names_valid_log_path "*.jsonl" ); then
  ok "a glob character in a name is a literal, and its verdict does not vary by cwd"
else bad "a glob character in a name is a literal, and its verdict does not vary by cwd" "verdict varied"; fi
# But it is still a NAME, so it may not carry a namespace segment that the
# segment grammar rejects.
if ( cd "${globdir}" && names_valid_log_path "*/x.jsonl" ); then
  bad "a glob in a log path's NAMESPACE is rejected by the segment grammar" "accepted"
else ok "a glob in a log path's NAMESPACE is rejected by the segment grammar"; fi
got="$(cd "${globdir}" && names_resolve_in_root "/tmp/r" "*.jsonl" 2>/dev/null)"
assert_eq "a resolved path is returned unexpanded, whatever the cwd contains" \
  "/tmp/r/*.jsonl" "${got}"

echo "== 2. Domain: lib/descriptor.sh =="

VALID_DESC='{
  "v": 1,
  "repo": "/home/x/dev/proj/.git",
  "channels": {
    "slack": {"kind": "log", "path": "proj-slack.jsonl", "dedupe": ["event_id", "channel+ts"], "schema_v": [1]},
    "peer-mail": {"kind": "maildir", "namespace": "agent-mail/peer", "read": "from-server", "write": "to-server", "identity": "athena"}
  }
}'

# D-7: the worked example parses, both kinds, in one entry.
assert_ok "D-7 the worked example validates" descriptor_validate "${VALID_DESC}"
assert_eq "D-7 both channels are resolved" "peer-mail
slack" "$(descriptor_channel_names "${VALID_DESC}" | sort)"
assert_eq "D-7 the log channel's kind is read back" "log" \
  "$(descriptor_channel_field "${VALID_DESC}" slack kind)"
assert_eq "D-7 the maildir channel's kind is read back" "maildir" \
  "$(descriptor_channel_field "${VALID_DESC}" peer-mail kind)"

# D-8: an unknown key is a HARD error, at either level. Ignoring it makes a
# typo indistinguishable from a default, and a silently-defaulted channel is
# one nobody is watching. (The deliberate opposite of the maildir frontmatter
# rule, and of an unknown `v` on a log LINE.)
bad_top='{"v":1,"repo":"/r/.git","channels":{},"chanels":{}}'
err="$(descriptor_validate "${bad_top}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "D-8 an unknown TOP-LEVEL key is a hard error" "accepted"
else assert_contains "D-8 an unknown TOP-LEVEL key is a hard error, naming it" "chanels" "${err}"; fi

bad_chan='{"v":1,"repo":"/r/.git","channels":{"slack":{"kind":"log","path":"x.jsonl","dedup":["event_id"]}}}'
err="$(descriptor_validate "${bad_chan}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "D-8 an unknown PER-CHANNEL key is a hard error" "accepted"
else assert_contains "D-8 an unknown PER-CHANNEL key is a hard error, naming it" "dedup" "${err}"; fi

# D-9: a missing required key is rejected NAMING the field, so the fix is one
# edit away rather than a hunt.
miss='{"v":1,"repo":"/r/.git","channels":{"m":{"kind":"maildir","namespace":"agent-mail","identity":"athena"}}}'
err="$(descriptor_validate "${miss}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "D-9 a maildir channel missing read/write is rejected" "accepted"
else
  # The needle is the WHOLE phrase, not the bare field name. A refusal that
  # merely happens to contain the word "read" -- the downstream "illegal
  # read/write directory name" message does -- would let the missing-field
  # check itself be deleted with the suite still green (measured: S14).
  assert_contains "D-9 the refusal names the missing field, as a missing field" \
    'missing required field "read"' "${err}"
  assert_contains "D-9 the refusal carries a Fix: clause" "Fix:" "${err}"
fi
err="$(descriptor_validate '{"v":1,"repo":"/r/.git","channels":{"l":{"kind":"log"}}}' 2>&1)"
assert_contains "D-9 a log channel missing path is rejected naming the field" "path" "${err}"

# D-10 / A-4: a path escaping the root is refused before any I/O is attempted
# -- which is only possible because validation takes TEXT, not a filesystem.
assert_refused "D-10 / A-4 a log path escaping the root is rejected with a Fix: clause" \
  descriptor_validate '{"v":1,"repo":"/r/.git","channels":{"slack":{"kind":"log","path":"../../etc/passwd.jsonl"}}}'
assert_refused "A-4 a maildir namespace escaping the root is rejected too" \
  descriptor_validate '{"v":1,"repo":"/r/.git","channels":{"m":{"kind":"maildir","namespace":"../../etc","read":"a","write":"b","identity":"athena"}}}'

# The path GRAMMAR does work containment does not: these paths stay inside the
# root and are still illegal. Without them the grammar check can be deleted
# and D-10 stays green on the containment check alone (measured: S11).
for p in "x.txt" "Bad/x.jsonl" ".hidden.jsonl"; do
  assert_refused "a contained-but-ungrammatical log path [${p}] is still rejected" \
    descriptor_validate "{\"v\":1,\"repo\":\"/r/.git\",\"channels\":{\"a\":{\"kind\":\"log\",\"path\":\"${p}\"}}}"
done

# An unknown registry `v` is a HARD error -- deliberately the opposite of an
# unknown `v` on a log LINE. A tool cannot partially honour a configuration
# file it does not understand, and there is nothing to "count separately"
# about a config file.
err="$(descriptor_validate '{"v":2,"repo":"/r/.git","channels":{}}' 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "an unknown registry v is a hard error" "accepted"
else assert_contains "an unknown registry v is a hard error naming the version found" "2" "${err}"; fi

# Structural errors are hard errors, each carrying a Fix: clause.
while IFS='@' read -r label doc; do
  [ -n "${label}" ] || continue
  assert_refused "structural error rejected with a Fix: clause: ${label}" descriptor_validate "${doc}"
done <<'CASES'
not json@{oops
top level not an object@[1,2]
channels not an object@{"v":1,"repo":"/r/.git","channels":[]}
channel value not an object@{"v":1,"repo":"/r/.git","channels":{"a":3}}
kind absent@{"v":1,"repo":"/r/.git","channels":{"a":{"path":"x.jsonl"}}}
kind unknown@{"v":1,"repo":"/r/.git","channels":{"a":{"kind":"mbox"}}}
channel name illegal@{"v":1,"repo":"/r/.git","channels":{"Bad Name":{"kind":"log","path":"x.jsonl"}}}
CASES

# The repo key is what binds an entry to a checkout. Absent, the entry can
# never match any session -- a silently dead entry, which is worse than an
# error the author sees at once.
assert_refused "a registry entry with no repo key is refused" \
  descriptor_validate '{"v":1,"channels":{}}'
assert_refused "a registry entry whose repo is not absolute is refused" \
  descriptor_validate '{"v":1,"repo":"dev/proj/.git","channels":{}}'

# A `dedupe` listing an unrecognised member is a hard error: applied as a
# no-op it would silently dedupe on nothing and re-report every duplicate.
err="$(descriptor_validate '{"v":1,"repo":"/r/.git","channels":{"a":{"kind":"log","path":"x.jsonl","dedupe":["message_id"]}}}' 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "an unrecognised dedupe member is a hard error" "accepted"
else assert_contains "an unrecognised dedupe member is a hard error naming it" "message_id" "${err}"; fi

# read and write MUST differ -- equal ones would make every send land in the
# directory this identity reads from, so a sender would ingest its own mail.
assert_refused "maildir read and write must differ" \
  descriptor_validate '{"v":1,"repo":"/r/.git","channels":{"m":{"kind":"maildir","namespace":"a","read":"x","write":"x","identity":"athena"}}}'

# Derived paths, relative to a root. Pure string joining -- nothing is stat-ed.
paths="$(descriptor_resolve "/R" "${VALID_DESC}" slack)"
assert_contains "a log channel resolves its inbox path"    "inbox	/R/proj-slack.jsonl"      "${paths}"
assert_contains "a log channel resolves its state path"    "state	/R/proj-slack.state.json" "${paths}"
assert_contains "a log channel resolves its doorbell path" "doorbell	/R/proj-slack.event"      "${paths}"
mpaths="$(descriptor_resolve "/R" "${VALID_DESC}" peer-mail)"
assert_contains "a maildir channel resolves its read dir"  "read_dir	/R/agent-mail/peer/from-server" "${mpaths}"
assert_contains "a maildir channel resolves its write dir" "write_dir	/R/agent-mail/peer/to-server"   "${mpaths}"
assert_contains "a maildir channel resolves its ack dir"   "ack_dir	/R/agent-mail/peer/from-server/.acked" "${mpaths}"

# Resolution denies by default IN THE DOMAIN, not only in the manager above it.
# Without this case the domain check can be deleted and the suite stays green
# on the manager's copy (measured: S18) -- which would leave the next entry
# point that calls descriptor_resolve directly with no check at all.
assert_refused "an undeclared channel is refused by resolution itself, not just by the manager" \
  descriptor_resolve "/R" "${VALID_DESC}" "not-a-channel"

# Selection is by repo identity and has NO fallback. This is the case that
# separates a correct resolver from one that passes everything else: a
# fallback to "show whatever is in the root" satisfies every other assertion
# in this file and hands one project another project's channels.
# Records are "<json>\t<path>" -- JSON FIRST. With the path first, a registry
# FILENAME containing a tab shifted the JSON into the remainder field and the
# entry was silently dropped: no match, no error, and a project quietly loses
# its channels. jq -c escapes a tab inside a string, so the JSON field can
# never contain one.
RECORDS="$(printf '%s\t%s\n%s\t%s\n' \
  '{"v":1,"repo":"/home/x/dev/a/.git","channels":{"a-chan":{"kind":"log","path":"a.jsonl"}}}' "/reg/a.json" \
  '{"v":1,"repo":"/home/x/dev/b/.git","channels":{"b-chan":{"kind":"log","path":"b.jsonl"}}}' "/reg/b.json")"
sel="$(printf '%s\n' "${RECORDS}" | descriptor_select "/home/x/dev/a/.git")"
assert_eq "an entry is selected by repo identity" "a-chan" "$(descriptor_channel_names "${sel}")"
# A registry filename containing a tab must not silently drop the entry.
tabrec="$(printf '%s\t%s\n' \
  '{"v":1,"repo":"/home/x/dev/a/.git","channels":{"a-chan":{"kind":"log","path":"a.jsonl"}}}' \
  "$(printf '/reg/we\tird.json')")"
assert_eq "a registry filename containing a tab does not silently drop the entry" "a-chan" \
  "$(printf '%s\n' "${tabrec}" | descriptor_select "/home/x/dev/a/.git" | descriptor_channel_names /dev/stdin 2>/dev/null || printf '%s\n' "${tabrec}" | descriptor_select "/home/x/dev/a/.git" | { read -r j; descriptor_channel_names "${j}"; })"
out="$(printf '%s\n' "${RECORDS}" | descriptor_select "/home/x/dev/c/.git" 2>&1)"; rc=$?
assert_eq "A-8 an unregistered repo selects NOTHING -- there is no fallback" "" "${out}"
assert_eq "A-8 an unregistered repo is not a fault, it is simply no match" "1" "${rc}"

# Two entries claiming one repo is a HARD error: ambiguous ownership is the
# one case where picking a winner could hand a session another project's
# channels. The refusal names the FILES and not their channels, because a
# denial must not be usable to enumerate a namespace.
DUPES="$(printf '%s\t%s\n%s\t%s\n' \
  '{"v":1,"repo":"/home/x/dev/a/.git","channels":{"a-chan":{"kind":"log","path":"a.jsonl"}}}' "/reg/a.json" \
  '{"v":1,"repo":"/home/x/dev/a/.git","channels":{"secret-chan":{"kind":"log","path":"s.jsonl"}}}' "/reg/dup.json")"
err="$(printf '%s\n' "${DUPES}" | descriptor_select "/home/x/dev/a/.git" 2>&1 >/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "two entries claiming one repo is a hard error" "accepted"
else
  assert_contains "two entries claiming one repo is a hard error with a Fix: clause" "Fix:" "${err}"
  assert_not_contains "the ambiguity refusal names files, never their channels" "secret-chan" "${err}"
fi
# The status must be DISTINCT from "no entry matched". Sharing status 1 makes
# every caller's "nothing owned, so zero channels, exit 0" branch swallow the
# ambiguity, and ambiguous ownership then presents as "this project has not
# opted in" -- a well-formed empty answer, which is the exact conflation the
# hard error exists to prevent.
printf '%s\n' "${DUPES}" | descriptor_select "/home/x/dev/a/.git" >/dev/null 2>&1; rc=$?
assert_eq "ambiguous ownership has its own status, not 'no match'" "2" "${rc}"

echo "== 3. Domain: lib/logchan.sh =="

L1='{"v":1,"received_at":"2026-09-01T22:10:01Z","channel":"D01","ts":"1788.0001","event_id":"Ev1","text":"one"}'
L2='{"v":1,"received_at":"2026-09-01T22:10:02Z","channel":"D01","ts":"1788.0002","event_id":"Ev2","text":"two"}'
L3='{"v":1,"received_at":"2026-09-01T22:10:03Z","channel":"D01","ts":"1788.0003","event_id":"Ev3","text":"three"}'

# D-12: the baseline. Offset 0, three complete lines, offset lands on EOF.
slice="${L1}
${L2}
${L3}
"
res="$(printf '%s' "${slice}" | logchan_scan 0 "1" "" "")"
assert_eq "D-12 three complete lines count as 3 new" "3" "$(jq -r .new <<<"${res}")"
assert_eq "D-12 the offset advances to EOF" "$(printf '%s' "${slice}" | wc -c)" "$(jq -r .next_offset <<<"${res}")"

# D-13: THE crash-safety guarantee. A writer that died mid-write leaves a
# fragment; parsing it would invent a truncated event, and advancing past it
# would lose the completion. Neither is allowed to happen.
partial="${L1}
${L2}
${L3%\"three\"\}}"
res="$(printf '%s' "${partial}" | logchan_scan 0 "1" "" "")"
assert_eq "D-13 a partial final line is not counted" "2" "$(jq -r .new <<<"${res}")"
complete_bytes="$(printf '%s\n%s\n' "${L1}" "${L2}" | wc -c)"
assert_eq "D-13 the offset does not advance past the partial final line" \
  "${complete_bytes}" "$(jq -r .next_offset <<<"${res}")"

# D-14: and when the fragment is later completed it counts EXACTLY ONCE --
# the whole point of not having advanced.
res2="$(printf '%s' "${L3}
" | logchan_scan "${complete_bytes}" "1" "Ev1
Ev2" "")"
assert_eq "D-14 the completed line counts exactly once" "1" "$(jq -r .new <<<"${res2}")"

# D-15: a schema bump must DEGRADE, not break. An unknown line `v` is counted
# separately and never fails the run -- the opposite of a registry `v`.
mixed="${L1}
$(printf '%s' "${L2}" | jq -c '.v = 2')
${L3}
"
res="$(printf '%s' "${mixed}" | logchan_scan 0 "1" "" "")"; rc=$?
assert_eq "D-15 an unknown line v does not fail the run" "0" "${rc}"
assert_eq "D-15 the readable lines still count" "2" "$(jq -r .new <<<"${res}")"
assert_eq "D-15 the unknown-v line is counted separately as unreadable" "1" "$(jq -r .unreadable <<<"${res}")"

# A line that is not JSON at all is unreadable rather than fatal: one corrupt
# byte range must not take the whole channel down.
res="$(printf '%s\n%s\n' "${L1}" 'not json at all' | logchan_scan 0 "1" "" "")"
assert_eq "an unparseable line is unreadable, not fatal" "1" "$(jq -r .unreadable <<<"${res}")"
assert_eq "an unparseable line does not stop the readable ones counting" "1" "$(jq -r .new <<<"${res}")"

# A line carrying neither dedupe key is unreadable rather than counted: it
# could never be deduped, so counting it would re-report it forever.
res="$(printf '%s\n' '{"v":1,"text":"keyless"}' | logchan_scan 0 "1" "" "")"
assert_eq "a line with no dedupe key at all is unreadable, not counted" "1" "$(jq -r .unreadable <<<"${res}")"
assert_eq "a line with no dedupe key at all is not counted as new" "0" "$(jq -r .new <<<"${res}")"

# A line is JSON written by other people, so nothing guarantees a field has
# the type this reader expects. A non-string `event_id` used directly as a jq
# object key is not a lookup that misses -- it is `Cannot index object with
# number`, a FATAL that aborts the scan of every REMAINING line in the slice.
# One hostile line would cost the whole channel, and the D-15 cases do not
# cover it: they exercise an unparseable line, not well-formed JSON with an
# unexpected value type.
for hostile in \
  '{"v":1,"event_id":123,"channel":"C","ts":"1.1"}' \
  '{"v":1,"event_id":{"a":1},"channel":"C","ts":"1.2"}' \
  '{"v":1,"event_id":"E","channel":{"a":1},"ts":"1.3"}' \
  '{"v":1,"event_id":true,"channel":"C","ts":"1.4"}'; do
  printf '%s\n' "${hostile}" | logchan_scan 0 "1" "" "" >/dev/null 2>&1
  assert_eq "a type-hostile field does not abort the scan: [$(printf '%s' "${hostile}" | cut -c1-34)…]" "0" "$?"
done
# And it must not cost the healthy lines around it either.
res="$(printf '%s\n%s\n%s\n' "${L1}" '{"v":1,"event_id":123,"channel":"C","ts":"1.1"}' "${L2}" | logchan_scan 0 "1" "" "")"
assert_eq "a type-hostile line does not suppress the healthy lines beside it" "3" "$(jq -r .new <<<"${res}")"

# D-16: at-least-once delivery means a re-append of the same event is NORMAL.
# event_id is the intra-file key that absorbs it.
res="$(printf '%s\n' "${L1}" "${L2}" | logchan_scan 0 "1" "Ev1" "")"
assert_eq "D-16 a line whose event_id is already seen is not counted" "1" "$(jq -r .new <<<"${res}")"

# The same event appearing TWICE inside one slice is absorbed too -- a
# re-append lands in the same unread range as the original.
res="$(printf '%s\n' "${L1}" "${L1}" "${L2}" | logchan_scan 0 "1" "" "")"
assert_eq "a duplicate within one slice is counted once" "2" "$(jq -r .new <<<"${res}")"

# D-17: channel:ts is the CROSS-source key -- the Web API backstop carries no
# event_id, so event_id cannot be the key that spans sources.
res="$(printf '%s\n' "${L1}" "${L2}" | logchan_scan 0 "1" "" "D01:1788.0001")"
assert_eq "D-17 a line whose channel:ts is already seen is not counted" "1" "$(jq -r .new <<<"${res}")"
assert_eq "D-17 the cross-source key is channel + \":\" + ts" "D01:1788.0001" \
  "$(logchan_dedupe_key D01 1788.0001)"

# D-18: the seen-sets live in a file rewritten on every ack, so unbounded
# growth is its own failure mode.
many="$(seq 1 600 | sed 's/^/Ev/')"
ring="$(logchan_ring_append 500 "" "${many}")"
assert_eq "D-18 the ring buffer is capped at 500" "500" "$(printf '%s\n' "${ring}" | grep -c .)"
assert_eq "D-18 the oldest entry is evicted" "" "$(printf '%s\n' "${ring}" | grep -x 'Ev1' || true)"
assert_eq "D-18 the newest entry is kept" "Ev600" "$(printf '%s\n' "${ring}" | grep -x 'Ev600')"

# The state file rewritten on ack MUST preserve keys it does not recognise.
# The ack itself lands with DND-184; the merge rule is domain and is settled
# here so the writer above it has the right primitive rather than inventing a
# fixed key set.
#
# This is the deliberate OPPOSITE of the registry rule (D-8, unknown key =
# hard error), and the asymmetry is the point: a registry entry is my own
# hand-written config, where a typo must be shouted about; a state file is
# machine-written by a possibly-NEWER version of this tooling, where
# discarding a key corrupts that writer's data.
#
# Concretely: DND-184's retention adds `rotated_at`. An ack that emitted a
# fixed key set would drop it on the next write, rotation would never fire
# again, the log would grow forever -- the exact defect retention exists to
# fix -- and nothing would report it.
# The first-run case: no state file yet, so the existing document is absent or
# empty. This is the FIRST case the ack ticket's writer will hit, and it was
# broken -- `${1:-\{\}}` defaults to the literal string `\{}`, because inside
# double quotes a backslash before `{` is not an escape.
assert_eq "a merge with no arguments at all yields an empty document" "{}" \
  "$(logchan_state_merge 2>/dev/null)"
assert_eq "a merge onto an ABSENT existing document still applies the update" "1" \
  "$(logchan_state_merge "" '{"offset":1}' 2>/dev/null | jq -r '.offset')"
assert_eq "a merge onto an empty-object existing document applies the update" "1" \
  "$(logchan_state_merge '{}' '{"offset":1}' 2>/dev/null | jq -r '.offset')"

merged="$(logchan_state_merge \
  '{"v":1,"offset":10,"seen_event_ids":["Ev1"],"rotated_at":"2026-09-01T00:00:00Z","future_key":{"a":1}}' \
  '{"offset":42,"seen_event_ids":["Ev1","Ev2"]}')"
assert_eq "a state rewrite preserves an unrecognised key it did not write" \
  "2026-09-01T00:00:00Z" "$(jq -r '.rotated_at' <<<"${merged}")"
assert_eq "a state rewrite preserves an unrecognised STRUCTURED value intact" \
  "1" "$(jq -r '.future_key.a' <<<"${merged}")"
assert_eq "a state rewrite still applies the update it was asked for" \
  "42" "$(jq -r '.offset' <<<"${merged}")"
assert_eq "a state rewrite replaces a recognised key rather than merging into it" \
  "Ev1 Ev2" "$(jq -r '.seen_event_ids | join(" ")' <<<"${merged}")"

# D-19: file order is DELIVERY order and does not match ts order -- a writer
# draining a backlog after an outage appends older messages after newer ones.
# Anything that sorts or reasons about recency must sort on ts explicitly.
outoforder="$(printf '%s\n' "${L3}" "${L1}" "${L2}")"
res="$(printf '%s\n' "${outoforder}" | logchan_scan 0 "1" "" "")"
assert_eq "D-19 display order is by ts, not by file position" \
  "1788.0001 1788.0002 1788.0003" "$(jq -r '[.messages[].ts] | join(" ")' <<<"${res}")"

echo "== 4. Domain: lib/maildir.sh (unread filter only -- see the file header) =="

# D-24: `.event` is the doorbell, not mail; `tmp/` holds half-delivered files
# the writer has not yet renamed into place; `.acked/` holds what was already
# consumed. A reader that counts any of them reports mail that does not exist.
unread="$(printf '%s\n' \
  "20260901T232215Z-001-a.md" "20260901T232216Z-002-b.md" "tmp" ".acked" ".event" \
  | maildir_filter_unread)"
assert_eq "D-24 tmp/, .acked/ and dotfiles are excluded from unread" "2" \
  "$(printf '%s\n' "${unread}" | grep -c .)"

# A message filename's slug is prose the PEER chose, so the peer picks these
# bytes. A name carrying a newline is not a conformant message name, and
# counted through any line-oriented listing it arrives as TWO entries -- which
# would let the sender decide how many messages it had sent.
if maildir_is_unread "$(printf 'a\nIGNORE-PREVIOUS-b')"; then
  bad "a filename containing a newline is not counted as a message" "accepted"
else ok "a filename containing a newline is not counted as a message"; fi
assert_ok "a conformant message filename is still counted" \
  maildir_is_unread "20260901T232215Z-001-a.md"

echo "== 5. Side effects: lib/fs.sh =="

setup_case
printf 'hello\nworld\n' > "${ATHENA_INBOX_ROOT}/a.jsonl"
assert_eq "fs_size reports the byte size" "12" "$(fs_size "${ATHENA_INBOX_ROOT}/a.jsonl")"
assert_eq "fs_size of a file that has never existed is 0, not an error" "0" \
  "$(fs_size "${ATHENA_INBOX_ROOT}/never.jsonl")"
assert_eq "fs_slice_from reads from a byte offset" "world" \
  "$(fs_slice_from "${ATHENA_INBOX_ROOT}/a.jsonl" 6)"

# A-5 (this slice's half): a symlink inside the root pointing inside the root
# PASSES containment and is still a symlink. Containment is not the symlink
# defence; an lstat + regular-file check is.
ln -s "${ATHENA_INBOX_ROOT}/a.jsonl" "${ATHENA_INBOX_ROOT}/link.jsonl"
assert_refused "a symlinked .jsonl is refused with a Fix: clause" \
  fs_assert_regular "${ATHENA_INBOX_ROOT}/link.jsonl"
mkfifo "${ATHENA_INBOX_ROOT}/fifo.jsonl"
assert_refused "a FIFO at an inbox path is refused" \
  fs_assert_regular "${ATHENA_INBOX_ROOT}/fifo.jsonl"

# Containment through the nearest EXISTING ancestor: the target legitimately
# may not exist yet, so realpath on the target itself would fail ENOENT on the
# normal first-run case.
assert_ok "a not-yet-created file inside the root passes containment" \
  fs_assert_contained "${ATHENA_INBOX_ROOT}" "${ATHENA_INBOX_ROOT}/not-yet.jsonl"
assert_refused "a path outside the root fails containment" \
  fs_assert_contained "${ATHENA_INBOX_ROOT}" "${CASE_DIR}/outside.jsonl"

assert_eq "a missing state file reads as empty, it is not created" "{}" \
  "$(fs_read_state "${ATHENA_INBOX_ROOT}/nope.state.json")"
if [ -e "${ATHENA_INBOX_ROOT}/nope.state.json" ]; then
  bad "reading a missing state file does not create it" "it was created"
else ok "reading a missing state file does not create it"; fi

# The repo identity is the same value from the main checkout and from a
# worktree of it. That equality is the entire reason the git common dir was
# chosen over the toplevel, so it is asserted rather than assumed.
repo="$(make_repo mainco)"
( cd "${repo}" && git commit -q --allow-empty -m init )
( cd "${repo}" && git worktree add -q -b wt "${CASE_DIR}/wt" >/dev/null 2>&1 )
assert_eq "the repo identity is identical from a worktree and its main checkout" \
  "$(fs_git_common_dir "${repo}")" "$(fs_git_common_dir "${CASE_DIR}/wt")"
other="$(make_repo otherco)"
if [ "$(fs_git_common_dir "${repo}")" = "$(fs_git_common_dir "${other}")" ]; then
  bad "the repo identity is distinct per repo" "two repos share one identity"
else ok "the repo identity is distinct per repo"; fi
if fs_git_common_dir "${TMP}" >/dev/null 2>&1; then
  bad "a cwd in no git repository has no identity" "one was produced"
else ok "a cwd in no git repository has no identity"; fi

echo "== 6. Manager: lib/inbox.sh =="

# D-11: not opting in is NOT a fault. A repo with no registry entry resolves to
# zero channels and exit 0, silently.
setup_case
proj="$(make_repo proj)"
out="$(cd "${proj}" && inbox_channels 2>&1)"; rc=$?
assert_eq "D-11 a repo with no registry entry exits 0" "0" "${rc}"
assert_eq "D-11 a repo with no registry entry yields zero channels, silently" "" "${out}"

# Not being a git repository is likewise not a fault.
out="$(cd "${TMP}" && inbox_channels 2>&1)"; rc=$?
assert_eq "not a git repository is not a fault either" "0" "${rc}"
assert_eq "not a git repository yields zero channels, silently" "" "${out}"

# E2E step 8, in miniature and automated: another project's entry is present
# in the very same registry directory, and this session must not see it. A
# resolver that scans the root instead of matching the repo identity passes
# every other case in this file and fails here.
setup_case
mine="$(make_repo mine)"
theirs="$(make_repo theirs)"
register mine "${mine}" '{"mine":{"kind":"log","path":"mine.jsonl"}}'
register theirs "${theirs}" '{"slack":{"kind":"log","path":"theirs-slack.jsonl"}}'
assert_eq "E2E-8 a session sees exactly its own project's channels" "mine" \
  "$(cd "${mine}" && inbox_channels)"
assert_not_contains "E2E-8 a session never sees another project's channel" "slack" \
  "$(cd "${mine}" && inbox_channels)"
assert_eq "E2E-8 the other project sees its own, from the same registry directory" "slack" \
  "$(cd "${theirs}" && inbox_channels)"

# A worktree of a registered repo resolves to its parent repo's channels for
# free -- the property the common-dir identity was chosen for.
( cd "${mine}" && git commit -q --allow-empty -m init && git worktree add -q -b wt "${CASE_DIR}/mine-wt" >/dev/null 2>&1 )
assert_eq "a worktree of a registered repo resolves to its parent's channels" "mine" \
  "$(cd "${CASE_DIR}/mine-wt" && inbox_channels)"

# M-6 / A-8: an undeclared channel is UNREACHABLE, the refusal names only
# channels THIS entry declares, and it does not echo the requested name back.
# An error message is a disclosure channel: echoing the name turns the denial
# into an oracle that confirms a guess.
err="$(cd "${mine}" && inbox_resolve_channel "someone-elses-secret-channel" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "M-6 an undeclared channel is refused" "accepted"
else
  assert_contains "M-6 the refusal carries a Fix: clause" "Fix:" "${err}"
  assert_contains "A-8 the refusal names only this entry's channels" "mine" "${err}"
  assert_not_contains "A-8 the refusal does not echo the requested foreign channel name" \
    "someone-elses-secret-channel" "${err}"
  assert_not_contains "A-8 the refusal does not name the other project's channel" \
    "theirs-slack" "${err}"
fi

# A log channel whose inbox file has NEVER existed must not look like "nothing
# new": "nobody registered the writer" and "nothing arrived" are identical on
# disk and must not be identical in the data.
st="$(cd "${mine}" && inbox_status_json)"
assert_eq "a never-delivered log channel is distinguished from 'nothing new'" "true" \
  "$(jq -r '.channels[] | select(.name=="mine") | .never_delivered' <<<"${st}")"

# The contract makes this a MUST, not a nicety: "Declaring a log channel MUST
# be accompanied by registering its producer", and a tool reporting on a log
# channel whose file has never existed MUST say so with a Fix: clause naming
# producer registration. A never-delivered channel is not zero, it is broken,
# so the all-zero silence rule does not cover it.
out="$(cd "${mine}" && "${BIN}/inbox-status" 2>&1)"
assert_contains "a never-delivered log channel is REPORTED, not silently zero" \
  "nothing has EVER been delivered" "${out}"
assert_contains "the never-delivered report carries a Fix: clause" "Fix:" "${out}"
assert_contains "the Fix: clause names producer registration" "producer" "${out}"

# A populated log channel counts POST-dedupe: a pre-dedupe count would announce
# messages the read step then declines to show.
printf '%s\n%s\n' "${L1}" "${L2}" > "${ATHENA_INBOX_ROOT}/mine.jsonl"
st="$(cd "${mine}" && inbox_status_json)"
assert_eq "a populated log channel reports its new count" "2" \
  "$(jq -r '.channels[] | select(.name=="mine") | .new' <<<"${st}")"
assert_eq "a populated log channel is no longer 'never delivered'" "false" \
  "$(jq -r '.channels[] | select(.name=="mine") | .never_delivered' <<<"${st}")"

printf '%s' "$(jq -n --arg e Ev1 '{v:1,offset:0,seen_event_ids:[$e],seen_keys:[]}')" \
  > "${ATHENA_INBOX_ROOT}/mine.state.json"
st="$(cd "${mine}" && inbox_status_json)"
assert_eq "counts are reported POST-dedupe, matching what the read step would show" "1" \
  "$(jq -r '.channels[] | select(.name=="mine") | .new' <<<"${st}")"

# A stale offset is RECOVERED, not trusted: continuing from an offset past EOF
# loses every message in the replacement file, and refusing to read loses them
# just as silently.
printf '%s' '{"v":1,"offset":999999,"seen_event_ids":[],"seen_keys":[]}' \
  > "${ATHENA_INBOX_ROOT}/mine.state.json"
st="$(cd "${mine}" && inbox_status_json)"
assert_eq "an offset past EOF is reset to 0 and the whole file re-read" "2" \
  "$(jq -r '.channels[] | select(.name=="mine") | .new' <<<"${st}")"
assert_eq "the reset is reported rather than hidden" "true" \
  "$(jq -r '.channels[] | select(.name=="mine") | .offset_reset' <<<"${st}")"

# Counting NEVER advances consumption state: inbox-status is a read. (In this
# slice that is structural -- lib/fs.sh contains no state writer at all -- and
# the assertion is what will catch a later ticket wiring one in here.)
before="$(cat "${ATHENA_INBOX_ROOT}/mine.state.json")"
( cd "${mine}" && inbox_status_json >/dev/null )
assert_eq "counting never advances the offset -- status is a read, not a consume" \
  "${before}" "$(cat "${ATHENA_INBOX_ROOT}/mine.state.json")"

# A malformed registry entry is a HARD error, not "this project has no
# channels": the two are indistinguishable downstream and only one is safe.
setup_case
badproj="$(make_repo badproj)"
common="$(cd "${badproj}" && realpath "$(git rev-parse --git-common-dir)")"
jq -n --arg r "${common}" '{v:1, repo:$r, channels:{a:{kind:"log",path:"x.jsonl",typo:1}}}' \
  > "${ATHENA_INBOX_ROOT}/projects/badproj.json"
_in_libs() { printf ". '%s/err.sh' && . '%s/names.sh' && . '%s/descriptor.sh' && . '%s/logchan.sh' && . '%s/maildir.sh' && . '%s/fs.sh' && . '%s/inbox.sh'" "${LIB}" "${LIB}" "${LIB}" "${LIB}" "${LIB}" "${LIB}" "${LIB}"; }
assert_refused "a malformed registry entry is a hard error, not zero channels" \
  bash -c "cd '${badproj}' && $(_in_libs) && inbox_channels"

# An unparseable registry FILE must be fatal to inbox_channels too, not only
# to inbox_status_json. The two use cases each carry their own copy of the
# fatal check, and without this case one of them can be deleted with the suite
# still green (measured: S35) -- leaving a caller that silently sees zero
# channels when the registry is broken, which is exactly "not opted in".
setup_case
uproj2="$(make_repo uproj2)"
printf '%s\n' '{ broken' > "${ATHENA_INBOX_ROOT}/projects/uproj2.json"
assert_refused "an unparseable registry FILE is fatal to inbox_channels, not silent zero" \
  bash -c "cd '${uproj2}' && $(_in_libs) && inbox_channels"

# Ambiguous ownership must be fatal at EVERY entry point, not only in the
# domain. Proven at the domain alone, the manager's "nothing owned, exit 0"
# branch swallowed it and inbox-status printed nothing and exited 0 -- a
# well-formed zero for a registry whose ownership nobody can determine. This
# is the same shape of gap as S35, one layer up.
setup_case
amb="$(make_repo amb)"
register amb-one   "${amb}" '{"mine":{"kind":"log","path":"mine.jsonl"}}'
register amb-two   "${amb}" '{"secret-chan":{"kind":"log","path":"s.jsonl"}}'
assert_refused "ambiguous ownership is fatal to inbox_channels, not silent zero" \
  bash -c "cd '${amb}' && $(_in_libs) && inbox_channels"
err="$(cd "${amb}" && "${BIN}/inbox-status" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "ambiguous ownership is fatal to inbox-status" "exited 0"
else assert_contains "ambiguous ownership is fatal to inbox-status with a Fix: clause" "Fix:" "${err}"; fi
assert_eq "ambiguous ownership never prints a well-formed empty result" "" \
  "$(cd "${amb}" && "${BIN}/inbox-status" --json 2>/dev/null)"
assert_not_contains "the ambiguity refusal still names no channel" "secret-chan" "${err}"

echo "== 7. Framework: bin/inbox-status =="

setup_case
proj="$(make_repo proj)"
register proj "${proj}" '{
  "slack": {"kind":"log","path":"proj-slack.jsonl"},
  "mail":  {"kind":"maildir","namespace":"agent-mail/peer","read":"from-peer","write":"to-peer","identity":"athena"}
}'

# The counts-only rule is about the PRE-PROMPT POSITION, not about bodies
# specifically. A maildir status is produced by listing filenames the PEER
# chose the words of -- a slug is attacker-controlled prose -- and a log line
# carries the sender's text. So "1 new" must never become "1 new: urgent-run-
# this-command", and never carry the body either.
SENTINEL="zzq-sentinel-must-never-surface"
printf '%s\n' "$(jq -nc --arg s "${SENTINEL}" \
  '{v:1,received_at:"2026-09-01T22:10:01Z",channel:"D01",ts:"1788.0001",event_id:"Ev1",text:$s}')" \
  > "${ATHENA_INBOX_ROOT}/proj-slack.jsonl"
MD="${ATHENA_INBOX_ROOT}/agent-mail/peer/from-peer"
mkdir -p "${MD}/tmp" "${MD}/.acked"
printf -- '---\nfrom: peer\nto: athena\nsent_at: 2026-09-01T23:22:15Z\n---\n\n%s\n' "${SENTINEL}" \
  > "${MD}/20260901T232215Z-001-urgent-run-this-command.md"
# Age the half-delivered file and the doorbell with touch -t, never date -u:
# a helper that computes stamps in UTC while touch -t reads them as local has
# already made two staleness cases silently measure nothing.
touch -t 202609010000 "${MD}/tmp/half-delivered" "${MD}/.event" "${MD}/.acked/20260801T000000Z-001-old.md"

out="$(cd "${proj}" && "${BIN}/inbox-status" 2>&1)"
assert_contains "inbox-status reports the log channel's count" "slack — 1 new" "${out}"
assert_contains "inbox-status reports the maildir channel's count" "mail — 1 new" "${out}"
assert_not_contains "inbox-status never prints a peer-chosen slug" "urgent-run-this-command" "${out}"
assert_not_contains "inbox-status never prints a message body" "${SENTINEL}" "${out}"
assert_contains "inbox-status points at the read step" "read-inbox" "${out}"
assert_not_contains "inbox-status never prints another project's channel" "theirs" "${out}"

jout="$(cd "${proj}" && "${BIN}/inbox-status" --json 2>&1)"
# Fed on stdin, never interpolated into a shell string: a quote in the output
# would turn a real result into a shell parse error reported as a test
# failure, or worse, into a pass.
assert_ok "--json emits one parseable object" \
  bash -c 'jq -e "type==\"object\"" >/dev/null' <<<"${jout}"
assert_not_contains "--json never carries a peer-chosen slug either" "urgent-run-this-command" "${jout}"
assert_not_contains "--json never carries a message body either" "${SENTINEL}" "${jout}"

# The sentinel assertions above prove no body leaked TODAY. They cannot prove
# no body can leak TOMORROW, because the per-message record the manager builds
# happens not to carry `text`. So assert the STRUCTURE instead: the status
# object carries counts and nothing per-message at all. A manager that stops
# dropping `messages` reddens here (measured: S31 was a measured zero against
# the sentinel alone, which is what prompted this case).
assert_eq "--json carries counts only -- no per-message data of any kind" "" \
  "$(jq -r '[.channels[] | keys[] | select(. == "messages" or . == "ts" or . == "event_id" or . == "text" or . == "channel")] | join(",")' <<<"${jout}")"
assert_eq "--json counts the maildir unread, excluding tmp/, .acked/ and .event" "1" \
  "$(jq -r '.channels[] | select(.name=="mail") | .unread' <<<"${jout}")"

# A COUNTING failure must be fatal and visible, exactly as a REGISTRY failure
# is. The suite proved the registry path several times over and never proved
# this one, and the gap was real: a failed scan produces no output, feeding
# jq empty input, which emits nothing and exits ZERO -- so the failure
# travelled as a successful count of nothing, took every other channel's count
# with it, and `--json` emitted an unparseable blank line while claiming exit
# 0. Injected before the user has spoken, that reads as "you have no mail" to
# a session that has mail.
setup_case
hproj="$(make_repo hproj)"
register hproj "${hproj}" '{"a":{"kind":"log","path":"a.jsonl"},"b":{"kind":"log","path":"b.jsonl"}}'
printf '%s\n' "${L1}" > "${ATHENA_INBOX_ROOT}/b.jsonl"
# A line this reader genuinely cannot process, planted in the FIRST channel.
printf '%s\n' 'not-json-and-not-recoverable' > "${ATHENA_INBOX_ROOT}/a.jsonl"
jout="$(cd "${hproj}" && "${BIN}/inbox-status" --json 2>/dev/null)"
assert_ok "--json output is parseable even with a hostile line present" \
  bash -c 'jq -e "type==\"object\"" >/dev/null' <<<"${jout}"
assert_eq "a hostile line in one channel does not erase another channel's count" "1" \
  "$(jq -r '.channels[] | select(.name=="b") | .new' <<<"${jout}")"
assert_eq "the hostile line is counted as unreadable, not as a fatal" "1" \
  "$(jq -r '.channels[] | select(.name=="a") | .unreadable' <<<"${jout}")"

# Zero across the board -> print NOTHING and exit 0. Unprompted output that
# says "nothing new" every session is noise, and noise is what makes a real
# notice invisible.
mv "${MD}/20260901T232215Z-001-urgent-run-this-command.md" "${MD}/.acked/"
printf '%s' "$(jq -n '{v:1,offset:0,seen_event_ids:["Ev1"],seen_keys:[]}')" \
  > "${ATHENA_INBOX_ROOT}/proj-slack.state.json"
out="$(cd "${proj}" && "${BIN}/inbox-status" 2>&1)"; rc=$?
assert_eq "zero across the board prints nothing" "" "${out}"
assert_eq "zero across the board exits 0" "0" "${rc}"

# No registry entry at all -> nothing, exit 0. Not opting in is normal.
setup_case
bare="$(make_repo bare)"
out="$(cd "${bare}" && "${BIN}/inbox-status" 2>&1)"; rc=$?
assert_eq "no registry entry prints nothing" "" "${out}"
assert_eq "no registry entry exits 0" "0" "${rc}"

# And a cwd in no git repository at all behaves the same way.
out="$(cd "${TMP}" && "${BIN}/inbox-status" 2>&1)"; rc=$?
assert_eq "a cwd in no git repository prints nothing" "" "${out}"
assert_eq "a cwd in no git repository exits 0" "0" "${rc}"

# A malformed registry entry is a HARD error with a Fix: clause -- partially
# honouring configuration nobody understands is the bug this prevents.
setup_case
mproj="$(make_repo mproj)"
common="$(cd "${mproj}" && realpath "$(git rev-parse --git-common-dir)")"
jq -n --arg r "${common}" '{v:1, repo:$r, channels:{a:{kind:"log",path:"x.jsonl",typo:1}}}' \
  > "${ATHENA_INBOX_ROOT}/projects/mproj.json"
err="$(cd "${mproj}" && "${BIN}/inbox-status" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "a malformed registry entry is a hard error" "exited 0"
else assert_contains "a malformed registry entry is a hard error with a Fix: clause" "Fix:" "${err}"; fi

# An unreadable (non-JSON) registry FILE is likewise a hard error naming the
# file: a registry nobody can parse must not degrade into "no channels".
setup_case
uproj="$(make_repo uproj)"
printf '%s\n' '{ broken' > "${ATHENA_INBOX_ROOT}/projects/uproj.json"
err="$(cd "${uproj}" && "${BIN}/inbox-status" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "an unparseable registry file is a hard error" "exited 0"
else assert_contains "an unparseable registry file is a hard error with a Fix: clause" "Fix:" "${err}"; fi

# An unknown argument is refused rather than ignored: silently ignoring a
# mistyped flag is how a "--json" consumer ends up parsing prose.
assert_refused "an unknown argument is refused with a Fix: clause" \
  "${BIN}/inbox-status" --bodies

echo "== 8. Hardening: failures that must stay visible and contained =="

# ARITHMETIC CONTEXT. `$(( ))` executes a command substitution inside an array
# subscript, so an unvalidated offset reaching one is code execution, not a bad
# read. Both primitives validate their own argument rather than trusting the
# caller that happens to sanitize today.
setup_case
canary="${CASE_DIR}/PWNED"
assert_refused "logchan_scan refuses a non-numeric offset rather than evaluating it" \
  bash -c "cd '${CASE_DIR}' && $(_in_libs) && printf '' | logchan_scan 'a[\$(touch ${canary})]' 1 '' ''"
assert_refused "fs_slice_from refuses a non-numeric offset rather than evaluating it" \
  bash -c "cd '${CASE_DIR}' && $(_in_libs) && fs_slice_from /etc/hostname 'a[\$(touch ${canary})]'"
if [ -e "${canary}" ]; then
  bad "no command substitution is executed by an arithmetic context" "the canary file was created"
else ok "no command substitution is executed by an arithmetic context"; fi

# A NUL in a .jsonl is corruption, and shell CANNOT carry it: a command
# substitution drops it (printing bash's own warning onto the pre-prompt
# stream) and the dropped bytes make the byte count short, so next_offset
# lands before the real complete-line boundary. Refusing is the only option
# that is not a silent miscount.
setup_case
nproj="$(make_repo nproj)"
register nproj "${nproj}" '{"n":{"kind":"log","path":"n.jsonl"}}'
printf '{"v":1,"event_id":"E1","channel":"C","ts":"1.1","text":"a\0b"}\n' > "${ATHENA_INBOX_ROOT}/n.jsonl"
err="$(cd "${nproj}" && "${BIN}/inbox-status" 2>&1 >/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "a NUL byte in a channel file is refused, not miscounted" "exited 0"
else assert_contains "a NUL byte in a channel file is refused with a Fix: clause" "Fix:" "${err}"; fi
assert_not_contains "the NUL refusal does not leak bash's own warning onto the stream" \
  "ignored null byte" "${err}"

# CROSS-TENANT BLAST RADIUS. Every other file in projects/ belongs to a
# DIFFERENT tenant. One of them being broken must not wedge this project, and
# the refusal must never name it -- that is the same disclosure descriptor_select
# refuses by name.
setup_case
mine2="$(make_repo mine2)"
register mine2 "${mine2}" '{"mine":{"kind":"log","path":"mine.jsonl"}}'
printf '%s\n' '{ broken' > "${ATHENA_INBOX_ROOT}/projects/secret-project-b.json"
out="$(cd "${mine2}" && inbox_channels 2>/dev/null)"; rc=$?
assert_eq "another tenant's broken registry file does not wedge this project" "mine" "${out}"
assert_eq "another tenant's broken registry file is not an error for this project" "0" "${rc}"
err="$(cd "${mine2}" && "${BIN}/inbox-status" 2>&1 >/dev/null)"
assert_not_contains "another tenant's registry filename is never disclosed" \
  "secret-project-b" "${err}"
# But when NO entry matched, the broken file may be THIS project's, so it must
# refuse -- still by count, never by name.
unreg="$(make_repo unreg)"
err="$(cd "${unreg}" && "${BIN}/inbox-status" 2>&1 >/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ]; then bad "an unreadable registry file with no match is still fatal" "exited 0"
else
  assert_contains "an unreadable registry file with no match is fatal with a Fix: clause" "Fix:" "${err}"
  assert_not_contains "that refusal names a COUNT, never the file" "secret-project-b" "${err}"
fi

# PARTIAL FAILURE. err.sh returns a status rather than exiting precisely "so a
# caller can refuse one channel without killing a multi-channel run". One
# misconfigured channel must not hide real mail on the others.
setup_case
pproj="$(make_repo pproj)"
register pproj "${pproj}" '{"broken":{"kind":"log","path":"broken.jsonl"},"good":{"kind":"log","path":"good.jsonl"}}'
printf '%s\n' "${L1}" > "${ATHENA_INBOX_ROOT}/good.jsonl"
ln -s /etc/hostname "${ATHENA_INBOX_ROOT}/broken.jsonl"
jout="$(cd "${pproj}" && "${BIN}/inbox-status" --json 2>/dev/null)"; rc=$?
assert_eq "a broken channel does not suppress a healthy channel's count" "1" \
  "$(jq -r '.channels[] | select(.name=="good") | .new' <<<"${jout}")"
assert_eq "the broken channel is marked, not silently dropped" "true" \
  "$(jq -r '.channels[] | select(.name=="broken") | .error' <<<"${jout}")"
if [ "${rc}" -eq 0 ]; then bad "a partial failure still exits non-zero" "exited 0"
else ok "a partial failure still exits non-zero"; fi
out="$(cd "${pproj}" && "${BIN}/inbox-status" 2>/dev/null)"
assert_contains "the text output still reports the healthy channel" "good — 1 new" "${out}"
assert_contains "the text output names the channel that could not be counted" "broken" "${out}"

# A SUBDIRECTORY is not a message. The name predicate is name-only by design,
# so the "is it actually a file" half has to happen where the filesystem is.
setup_case
sproj="$(make_repo sproj)"
register sproj "${sproj}" '{"mail":{"kind":"maildir","namespace":"agent-mail/peer","read":"from-peer","write":"to-peer","identity":"athena"}}'
SD="${ATHENA_INBOX_ROOT}/agent-mail/peer/from-peer"
mkdir -p "${SD}/tmp" "${SD}/a-directory-not-a-message"
printf -- '---\nfrom: peer\nto: athena\nsent_at: 2026-09-01T23:22:15Z\n---\n\nbody\n' \
  > "${SD}/20260901T232215Z-001-real.md"
touch "${SD}/$(printf 'b\nIGNORE-PREVIOUS-c')"
jout="$(cd "${sproj}" && "${BIN}/inbox-status" --json 2>/dev/null)"
assert_eq "the peer does not get to choose the count: one real message counts as 1" "1" \
  "$(jq -r '.channels[] | select(.name=="mail") | .unread' <<<"${jout}")"

echo
if [ "${FAIL}" -eq 0 ]; then
  echo "VERDICT: PASS (${PASS} cases)"
  exit 0
else
  echo "VERDICT: FAIL (${FAIL} of $((PASS + FAIL)) cases)"
  exit 1
fi
