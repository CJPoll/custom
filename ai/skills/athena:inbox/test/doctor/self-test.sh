#!/usr/bin/env bash
# Self-test for inbox-doctor (DND-190) -- the owner-invoked liveness check for
# the whole Slack -> Athena delivery chain.
#
# EVERY PROBE IS STUBBED. No socket is opened, no real pidfile or lock is read,
# the live inbox root (~/.local/share/athena) and live client config/state
# (~/.config, ~/.local/state) are NEVER touched. The inbox root, client config,
# client state dir, cron check, server fetch and committed registry list are all
# pointed at a mktemp -d under this test's control or a stub command. A canned
# JSON file stands in for the server, so nothing here makes a network request.
#
# Each check's ok, warn, fail AND na branch is exercised -- the four-state
# output is the crux of the ticket, and na-conflated-with-ok is the failure it
# guards against. The read-only guarantee (a lock reported reapable is never
# reaped; a channel's bytes and offset never change) is asserted after a full
# run, not assumed.
#
# Run: bash test/doctor/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "${HERE}/../.." && pwd)"
LIB="${SKILL}/lib"
BIN="${SKILL}/bin/inbox-doctor"
REPO="$(cd "${SKILL}/../../.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "expected NOT [$2], got [$3]" ;; *) ok "$1" ;; esac; }

# has_finding <findings> <state> <check> <msg-substr>  -- status 0 if present.
has_finding() {
  printf '%s\n' "$1" | awk -F'\t' -v s="$2" -v c="$3" -v m="$4" \
    '$1==s && $2==c && index($3,m)>0{f=1} END{exit f?0:1}'
}
assert_finding() { local claim="$1"; shift; if has_finding "$@"; then ok "${claim}"; else bad "${claim}" "no [$2/$3] finding matching [$4] in:\n$1"; fi; }
assert_no_finding() { local claim="$1"; shift; if has_finding "$@"; then bad "${claim}" "unexpected [$2/$3] finding [$4]"; else ok "${claim}"; fi; }
# state_of <findings> <check> -- first state for that check name.
state_of() { printf '%s\n' "$1" | awk -F'\t' -v c="$2" '$2==c{print $1; exit}'; }

export DOCTOR_REPO_DIR="${REPO}"
# shellcheck source=/dev/null
for f in err names descriptor logchan maildir fence session fs lock inbox doctor; do . "${LIB}/${f}.sh"; done

# ============================================================================
echo "== pure state helpers =="
assert_eq "mode equal -> ok"        ok   "$(doctor_state_mode 700 700)"
assert_eq "mode differ -> warn"     warn "$(doctor_state_mode 755 700)"
assert_eq "mode empty -> na"        na   "$(doctor_state_mode '' 700)"
assert_eq "future stamp -> warn"    warn "$(doctor_state_future 2000 1000)"
assert_eq "past stamp -> ok"        ok   "$(doctor_state_future 500 1000)"
assert_eq "junk stamp -> na"        na   "$(doctor_state_future abc 1000)"
assert_eq "dash-in-stamp -> na"     na   "$(doctor_state_future 1-2 1000)"
assert_eq "connected true -> ok"    ok   "$(doctor_state_connected true)"
assert_eq "connected false -> warn" warn "$(doctor_state_connected false)"
assert_eq "connected null -> na"    na   "$(doctor_state_connected null)"
assert_eq "override equal -> ok"    ok   "$(doctor_state_override a.jsonl a.jsonl)"
assert_eq "override differ -> fail" fail "$(doctor_state_override a.jsonl b.jsonl)"

echo "== doctor_finding strips delimiters (no phantom finding) =="
LINES="$(doctor_finding warn c "a$(printf '\t')b$(printf '\n')c" "fix")"
assert_eq "one line only" 1 "$(printf '%s\n' "${LINES}" | grep -c .)"

# ============================================================================
echo "== root / projects =="
export ATHENA_INBOX_ROOT="${TMP}/noroot"
assert_eq "root missing -> na"   na   "$(state_of "$(doctor_check_root)" root)"
: > "${TMP}/rootfile"; ATHENA_INBOX_ROOT="${TMP}/rootfile"
assert_eq "root exists but not a directory -> fail" fail "$(state_of "$(doctor_check_root)" root)"
mkdir -p "${TMP}/r755"; chmod 755 "${TMP}/r755"; ATHENA_INBOX_ROOT="${TMP}/r755"
assert_eq "root 0755 -> warn"    warn "$(state_of "$(doctor_check_root)" root)"
mkdir -p "${TMP}/r700"; chmod 700 "${TMP}/r700"; ATHENA_INBOX_ROOT="${TMP}/r700"
assert_eq "root 0700 -> ok"      ok   "$(state_of "$(doctor_check_root)" root)"
assert_eq "projects missing -> na" na "$(state_of "$(doctor_check_projects_dir)" projects)"
mkdir -p "${TMP}/r700/projects"; chmod 755 "${TMP}/r700/projects"
assert_eq "projects 0755 -> warn" warn "$(state_of "$(doctor_check_projects_dir)" projects)"
chmod 700 "${TMP}/r700/projects"
assert_eq "projects 0700 -> ok"  ok   "$(state_of "$(doctor_check_projects_dir)" projects)"

# ============================================================================
echo "== client-config =="
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg-absent.json"
assert_eq "config absent -> na" na "$(state_of "$(doctor_check_client_config)" client-config)"
CFG="${TMP}/cfg.json"; export ATHENA_INBOX_CLIENT_CONFIG="${CFG}"
printf '{"instances":{}}' > "${CFG}"; chmod 644 "${CFG}"
assert_eq "config 0644 -> fail" fail "$(state_of "$(doctor_check_client_config)" client-config)"
chmod 600 "${CFG}"; printf 'not json' > "${CFG}"; chmod 600 "${CFG}"
assert_eq "config non-json -> fail" fail "$(state_of "$(doctor_check_client_config)" client-config)"
printf '{"instances":{"i":{"inbox":"x.jsonl","doorbell":"ring"}}}' > "${CFG}"; chmod 600 "${CFG}"
assert_finding "doorbell non-null -> warn naming instance" "$(doctor_check_client_config)" warn client-config "i"
printf '{"instances":{"i":{"inbox":"x.jsonl","doorbell":null}}}' > "${CFG}"; chmod 600 "${CFG}"
assert_eq "config good -> ok" ok "$(state_of "$(doctor_check_client_config)" client-config)"

# ============================================================================
echo "== client-stopped / client-running =="
export ATHENA_INBOX_CLIENT_STATE_DIR="${TMP}/state"; mkdir -p "${ATHENA_INBOX_CLIENT_STATE_DIR}"
# absent stop marker -> function returns 1 (no finding)
if doctor_check_client_stopped >/dev/null; then bad "no stop marker -> status 1" "returned 0"; else ok "no stop marker -> status 1"; fi
printf 'partial line in walt_ui-slack.jsonl\n' > "${ATHENA_INBOX_CLIENT_STATE_DIR}/athena-inbox-client.stopped"
STOPOUT="$(doctor_check_client_stopped)"; STOPRC=$?
assert_eq "stop marker -> status 0" 0 "${STOPRC}"
assert_finding "stopped -> warn, reason echoed" "${STOPOUT}" warn client-stopped "partial line"
assert_contains "stopped -> does NOT recommend blind restart" "do NOT just restart" "${STOPOUT}"
rm -f "${ATHENA_INBOX_CLIENT_STATE_DIR}/athena-inbox-client.stopped"
# running: config present (from above), pidfile live/dead/missing
PF="${ATHENA_INBOX_CLIENT_STATE_DIR}/athena-inbox-client.pid"
echo $$ > "${PF}"
assert_eq "pidfile live -> ok"   ok   "$(state_of "$(doctor_check_client_running 1)" client-running)"
echo 2147483646 > "${PF}"
assert_eq "pidfile dead -> fail" fail "$(state_of "$(doctor_check_client_running 1)" client-running)"
rm -f "${PF}"
assert_eq "pidfile missing -> fail" fail "$(state_of "$(doctor_check_client_running 1)" client-running)"
assert_eq "stopped subsumes running -> na" na "$(state_of "$(doctor_check_client_running 0)" client-running)"
_SAVED_CFG="${ATHENA_INBOX_CLIENT_CONFIG}"; export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json"
assert_eq "no config -> running na" na "$(state_of "$(doctor_check_client_running 1)" client-running)"
export ATHENA_INBOX_CLIENT_CONFIG="${_SAVED_CFG}"

# ============================================================================
echo "== cron =="
export ATHENA_INBOX_DOCTOR_CRON_CHECK="true"
assert_eq "cron check ok -> ok"   ok   "$(state_of "$(doctor_check_cron)" cron)"
export ATHENA_INBOX_DOCTOR_CRON_CHECK="false"
assert_eq "cron check fail -> warn" warn "$(state_of "$(doctor_check_cron)" cron)"
unset ATHENA_INBOX_DOCTOR_CRON_CHECK
_SAVED_REPO="${DOCTOR_REPO_DIR}"; export DOCTOR_REPO_DIR=""
assert_eq "cron script absent -> na" na "$(state_of "$(doctor_check_cron)" cron)"
export DOCTOR_REPO_DIR="${_SAVED_REPO}"

# ============================================================================
echo "== skipped-file (name every skip) =="
export ATHENA_INBOX_ROOT="${TMP}/sk"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"
P="${ATHENA_INBOX_ROOT}/projects"
: > "${P}/walt_ui.json.bak"                       # not a candidate
printf '{}' > "${P}/UpperCase.json"   # stem fails ^[a-z0-9]... -> not a candidate
ln -s /etc/hosts "${P}/linked.json"               # symlink candidate
printf '{ this is not json' > "${P}/broken.json"  # unterminated JSON (SABOTAGE)
printf '{"v":1,"channels":{}}' > "${P}/norepo.json" # candidate, no repo
ln -s "${TMP}/does-not-exist" "${P}/dangling.json" # DANGLING symlink candidate -- -e is false, must not be skipped silently
printf '{"v":1,"repo":"/x/.git","channels":{}}' > "${P}/good.json"; chmod 600 "${P}/good.json"
SK="$(doctor_check_skipped_files)"
assert_finding "backup named (informational stray-file)" "${SK}" warn stray-file "walt_ui.json.bak"
assert_finding "bad-stem .json named (informational stray-file)" "${SK}" warn stray-file "UpperCase.json"
assert_finding "symlink entry fail"  "${SK}" fail skipped-file "linked.json"
assert_finding "dangling symlink entry fail (not skipped)" "${SK}" fail skipped-file "dangling.json"
assert_finding "unterminated json fail" "${SK}" fail skipped-file "broken.json"
assert_finding "no-repo candidate fail" "${SK}" fail skipped-file "norepo.json"
# a clean projects/ reports ok
export ATHENA_INBOX_ROOT="${TMP}/skclean"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"
printf '{"v":1,"repo":"/x/.git","channels":{}}' > "${ATHENA_INBOX_ROOT}/projects/good.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/good.json"
assert_eq "clean projects -> ok" ok "$(state_of "$(doctor_check_skipped_files)" skipped-file)"

# ============================================================================
echo "== undeclared-entry (admiral obligation 1) =="
export ATHENA_INBOX_ROOT="${TMP}/ud"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"
printf '{"v":1,"repo":"/x/.git","channels":{}}' > "${ATHENA_INBOX_ROOT}/projects/stray.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/stray.json"
# committed list that declares nothing -> stray is undeclared
COMMITTED="${TMP}/committed.json"; printf '{"v":1,"projects":[]}' > "${COMMITTED}"
export ATHENA_INBOX_REGISTRY="${COMMITTED}"
assert_finding "live not in committed -> warn named" "$(doctor_check_undeclared_live)" warn undeclared-entry "stray.json"
# committed list that DOES declare it -> ok
printf '{"v":1,"projects":[{"file":"stray.json","entry":{"v":1,"repo":"/x/.git","channels":{}}}]}' > "${COMMITTED}"
assert_eq "declared -> ok" ok "$(state_of "$(doctor_check_undeclared_live)" undeclared-entry)"
# committed list unreachable (no repo dir) -> na, never a false clean
_SR="${DOCTOR_REPO_DIR}"; export DOCTOR_REPO_DIR="${TMP}/nope"
assert_eq "committed unreachable -> na" na "$(state_of "$(doctor_check_undeclared_live)" undeclared-entry)"
export DOCTOR_REPO_DIR="${_SR}"; unset ATHENA_INBOX_REGISTRY

# ============================================================================
echo "== collision (architect D12a) =="
export ATHENA_INBOX_ROOT="${TMP}/col"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"
printf '{"v":1,"repo":"/a/.git","channels":{"s":{"kind":"log","path":"shared.jsonl"}}}' > "${ATHENA_INBOX_ROOT}/projects/a.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/a.json"
printf '{"v":1,"repo":"/b/.git","channels":{"s":{"kind":"log","path":"shared.jsonl"}}}' > "${ATHENA_INBOX_ROOT}/projects/b.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/b.json"
assert_finding "collision -> warn naming surface" "$(doctor_check_collisions)" warn collision "shared.jsonl"
rm -f "${ATHENA_INBOX_ROOT}/projects/b.json"
assert_eq "no collision -> ok" ok "$(state_of "$(doctor_check_collisions)" collision)"

# ============================================================================
echo "== registry-entry (matched) =="
make_repo() { local d="$1"; mkdir -p "${d}"; ( cd "${d}" && git init -q ); ( cd "${d}" && realpath "$(git rev-parse --git-common-dir)" ); }
export ATHENA_INBOX_ROOT="${TMP}/re"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"
R1="${TMP}/repo1"; C1="$(make_repo "${R1}")"
printf '{"v":1,"repo":"%s","channels":{"slack":{"kind":"log","path":"re-slack.jsonl"}}}' "${C1}" > "${ATHENA_INBOX_ROOT}/projects/re.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/re.json"
DOCTOR_MATCHED_ENTRY=""; EOUT="$(cd "${R1}" && doctor_check_entry ".")"
assert_eq "matched entry -> ok" ok "$(state_of "${EOUT}" registry-entry)"
# cwd in NO repo -> na (git-128 SABOTAGE class)
NOREPO="${TMP}/notrepo"; mkdir -p "${NOREPO}"
NOREPO_OUT="$(cd "${NOREPO}" && doctor_check_entry ".")"
assert_eq "cwd not a repo -> na" na "$(state_of "${NOREPO_OUT}" registry-entry)"
# DND-260 round-6 -- TEST THE MISS at the MESSAGE layer. A cwd genuinely in no
# repo (rk empty, rc 0) and a resolved-but-unmatched repo (rk set, rc 0) are
# both `na`, but they must not read the same: the no-repo case names NO GIT
# REPOSITORY and must NOT claim an identity "found zero" (there was none to
# search with), whose Fix would tell the reader to set "repo" to a git-common-dir
# that does not exist. That is the failed-lookup-looks-empty collapse at the
# message layer, and a state-only assertion cannot catch it.
assert_contains "the no-repo na names that the cwd is in NO GIT REPOSITORY" "NO GIT REPOSITORY" "${NOREPO_OUT}"
assert_not_contains "the no-repo na does NOT read as a resolved identity that found zero" "NO CLIENT CHANNEL DECLARED" "${NOREPO_OUT}"
# invalid entry (unknown kind) -> fail
printf '{"v":1,"repo":"%s","channels":{"slack":{"kind":"bogus"}}}' "${C1}" > "${ATHENA_INBOX_ROOT}/projects/re.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/re.json"
assert_eq "invalid entry -> fail" fail "$(cd "${R1}" && state_of "$(doctor_check_entry ".")" registry-entry)"
# DND-260: a repo with NO entry naming it is the NO CLIENT CHANNEL DECLARED
# state, and the na finding must NAME the resolved repo identity that found zero
# (CLAUDE.md -> "a failed lookup must never look like an empty one"), not read as
# a benign "not opted in".
R3="${TMP}/repo3"; C3="$(make_repo "${R3}")"
NOENT="$(cd "${R3}" && doctor_check_entry ".")"
assert_finding "unmatched repo -> na (NO CLIENT CHANNEL DECLARED)" "${NOENT}" na "registry-entry" "NO CLIENT CHANNEL DECLARED"
assert_contains "the na finding names the resolved repo identity that found zero" "${C3}" "${NOENT}"
# FINDING 3 / DND-260 -- TEST THE MISS. When there is no entry AND the repo
# identity COULD NOT BE COMPUTED (inbox_repo_key exits non-zero: git missing,
# cwd gone, realpath failed, a dubious repo), an uncomputed key must NOT read as
# a benign "no repo, not opted in" na -- it is its own warn finding (CLAUDE.md
# -> "a failed lookup must never look like an empty one"). Stub the two lookups
# so the branch is reached deterministically, then restore them.
_real_ire="$(declare -f inbox_repo_key)"; _real_ie="$(declare -f inbox_entry)"
inbox_repo_key() { return 1; }        # could not tell
inbox_entry() { printf ''; return 0; } # no entry, not the fatal rc=2
NOID="$(doctor_check_entry ".")"
eval "${_real_ire}"; eval "${_real_ie}"; unset _real_ire _real_ie
assert_finding "no entry + uncomputable identity -> warn, not na" "${NOID}" warn "registry-entry" "COULD NOT BE DETERMINED"
assert_no_finding "the uncomputable-identity case does NOT emit the benign na finding" "${NOID}" na "registry-entry" "NO CLIENT CHANNEL DECLARED"

# ============================================================================
echo "== per-channel checks =="
export ATHENA_INBOX_ROOT="${TMP}/ch"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"
R2="${TMP}/repo2"; C2="$(make_repo "${R2}")"
ENTRY='{"v":1,"repo":"'"${C2}"'","channels":{"slack":{"kind":"log","path":"ch-slack.jsonl"}}}'
printf '%s' "${ENTRY}" > "${ATHENA_INBOX_ROOT}/projects/ch.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/ch.json"
# never delivered (no file) -> NO SERVER PRODUCER REGISTERED
CH="$(cd "${R2}" && doctor_check_channels "${ENTRY}" ".")"
assert_finding "log never delivered -> warn (own check)" "${CH}" warn "never-delivered" "never received"
assert_finding "slack never-delivered names NO SERVER PRODUCER REGISTERED" "${CH}" warn "never-delivered" "NO SERVER PRODUCER REGISTERED"
assert_contains "slack never-delivered Fix names the client-config instance, not athena-events" "client config" "${CH}"
assert_not_contains "slack never-delivered Fix does NOT name athena-events" "athena-events" "${CH}"
# DND-260: a PLATFORM channel that never received distinguishes its Fix -- it
# names the athena-events server producer (a handling rule), not a client
# instance. The three empty-channel states must not read identically.
PENTRY='{"v":1,"repo":"'"${C2}"'","channels":{"flaky":{"kind":"log","path":"ch-flaky.jsonl","producer":"platform"}}}'
PCH="$(cd "${R2}" && doctor_check_channels "${PENTRY}" ".")"
assert_finding "platform never-delivered -> warn naming NO SERVER PRODUCER REGISTERED" "${PCH}" warn "never-delivered" "NO SERVER PRODUCER REGISTERED"
assert_contains "platform never-delivered Fix names the athena-events handling rule" "athena-events" "${PCH}"
# deliver, good mode, fresh
printf '{"v":1,"ts":"1","channel":"c","event_id":"e"}\n' > "${ATHENA_INBOX_ROOT}/ch-slack.jsonl"; chmod 600 "${ATHENA_INBOX_ROOT}/ch-slack.jsonl"
CH="$(cd "${R2}" && doctor_check_channels "${ENTRY}" ".")"
assert_finding "log delivered -> ok freshness" "${CH}" ok "freshness:slack" "last delivery"
# wrong mode -> warn
chmod 644 "${ATHENA_INBOX_ROOT}/ch-slack.jsonl"
CH="$(cd "${R2}" && doctor_check_channels "${ENTRY}" ".")"
assert_finding "log 0644 -> warn" "${CH}" warn "channel:slack" "expected 0600"
chmod 600 "${ATHENA_INBOX_ROOT}/ch-slack.jsonl"
# future rotated_at (SABOTAGE: future timestamp)
STATE="${ATHENA_INBOX_ROOT}/ch-slack.state.json"
printf '{"offset":0,"rotated_at":"2099-01-01T00:00:00Z"}' > "${STATE}"; chmod 600 "${STATE}"
CH="$(cd "${R2}" && doctor_check_channels "${ENTRY}" ".")"
assert_finding "future rotated_at -> warn" "${CH}" warn "channel:slack" "rotated_at in the future"
# .jsonl.1 past 14-day sweep window (D12b)
printf '{"offset":0,"rotated_at":"2020-01-01T00:00:00Z"}' > "${STATE}"; chmod 600 "${STATE}"
printf 'old\n' > "${ATHENA_INBOX_ROOT}/ch-slack.jsonl.1"; chmod 600 "${ATHENA_INBOX_ROOT}/ch-slack.jsonl.1"
CH="$(cd "${R2}" && doctor_check_channels "${ENTRY}" ".")"
assert_finding "overdue .1 -> warn" "${CH}" warn "channel:slack" "past its 14-day sweep window"
rm -f "${STATE}" "${ATHENA_INBOX_ROOT}/ch-slack.jsonl.1"

# A ROTATED, QUIET channel: the live file is gone (rotation renamed it to .1),
# only ch-slack.jsonl.1 remains. It must NOT be reported as "never received",
# and the overdue-.1 and lock checks must still run.
rm -f "${ATHENA_INBOX_ROOT}/ch-slack.jsonl"
printf 'old\n' > "${ATHENA_INBOX_ROOT}/ch-slack.jsonl.1"; chmod 600 "${ATHENA_INBOX_ROOT}/ch-slack.jsonl.1"
printf '{"offset":0,"rotated_at":"2020-01-01T00:00:00Z"}' > "${STATE}"; chmod 600 "${STATE}"
CH="$(cd "${R2}" && doctor_check_channels "${ENTRY}" ".")"
assert_no_finding "rotated+quiet: NOT reported as never-received" "${CH}" warn "channel:slack" "never received"
assert_finding "rotated+quiet: overdue .1 still reported" "${CH}" warn "channel:slack" "past its 14-day sweep window"
# a .1 whose rotated_at is UNKNOWN (older reader, or unparseable) -> na, named,
# never a silent "fine".
printf '{"offset":0}' > "${STATE}"; chmod 600 "${STATE}"   # no rotated_at
CH="$(cd "${R2}" && doctor_check_channels "${ENTRY}" ".")"
assert_finding "unknown rotated_at .1 -> na, named" "${CH}" na "channel:slack" "rotation time is unknown"
rm -f "${STATE}" "${ATHENA_INBOX_ROOT}/ch-slack.jsonl.1"
printf '{"v":1,"ts":"1","channel":"c","event_id":"e"}\n' > "${ATHENA_INBOX_ROOT}/ch-slack.jsonl"; chmod 600 "${ATHENA_INBOX_ROOT}/ch-slack.jsonl"

echo "== lock: dead-pid reapable, READ-ONLY (never reaped) =="
LOCK="${ATHENA_INBOX_ROOT}/ch-slack.consumer.lock"
printf '{"session_id":"s","pid":2147483646,"started_at":"x"}' > "${LOCK}"; chmod 600 "${LOCK}"
LK="$(doctor_check_lock slack "${LOCK}")"
assert_finding "dead-pid lock -> warn reapable" "${LK}" warn "stale-lock" "reapable residue"
[ -f "${LOCK}" ] && ok "lock NOT reaped (still present)" || bad "lock NOT reaped" "file was removed"
# a LIVE recorded pid -> no reapable finding (a live holder). The doctor reads
# the pid; it NEVER acquires the lock, so a real consumer is never denied -- the
# read-only-that-can-deny-a-consumer defect the critic caught.
printf '{"session_id":"s","pid":%s,"started_at":"x"}' "$$" > "${LOCK}"; chmod 600 "${LOCK}"
LK="$(doctor_check_lock slack "${LOCK}")"
assert_no_finding "live-pid lock -> no reapable finding" "${LK}" warn "stale-lock" "reapable residue"
# READ-ONLY PROOF: a real consumer holds the flock (fd 8, separate open) while
# the doctor checks the lock; the consumer must STILL hold it afterward (a
# second, independent open cannot take it), proving the doctor did not acquire.
if command -v flock >/dev/null 2>&1; then
  printf '{"session_id":"s","pid":2147483646,"started_at":"x"}' > "${LOCK}"; chmod 600 "${LOCK}"
  exec 8<>"${LOCK}"; flock -n 8
  doctor_check_lock slack "${LOCK}" >/dev/null 2>&1
  if ( exec 9<>"${LOCK}"; flock -n 9 ) 2>/dev/null; then bad "doctor left the lock free" "an independent open acquired it — the consumer's hold was lost"; else ok "the consumer still holds the lock after the doctor's check"; fi
  exec 8>&-
fi

echo "== maildir channel =="
MENTRY='{"v":1,"repo":"'"${C2}"'","channels":{"mail":{"kind":"maildir","namespace":"agent-mail/x","read":"in","write":"out","identity":"me"}}}'
CH="$(cd "${R2}" && doctor_check_channels "${MENTRY}" ".")"
assert_finding "maildir no incoming yet -> ok" "${CH}" ok "channel:mail" "awaiting the peer"
# ... and with no message files anywhere, message-mode says NOTHING (no dirs to
# judge -- reporting ok here would be noise on an empty channel).
assert_no_finding "no message files -> no message-mode finding at all" "${CH}" ok "message-mode" "message files"
assert_no_finding "no message files -> no message-mode warn either" "${CH}" warn "message-mode" "message files"

# DND-200: a message the PEER wrote under its umask arrives 0644. The writer's
# half sets 0600 at delivery (fs_maildir_deliver); this is the "inbox-doctor
# reports the REST" half of the contract's *Root and permissions* rule, which
# had no maildir counterpart to the log kind's file-mode check.
MREAD="${ATHENA_INBOX_ROOT}/agent-mail/x/in"
mkdir -p -m 700 "${MREAD}"
SLUG="secret-peer-slug"   # a distinctive slug so we can prove it never leaks.
printf -- '---\nfrom: peer\nto: me\nsent_at: 2026-09-01T23:22:15Z\n---\n\nhi\n' \
  > "${MREAD}/20260901T232215Z-001-${SLUG}.md"; chmod 600 "${MREAD}/20260901T232215Z-001-${SLUG}.md"
printf -- '---\nfrom: peer\nto: me\nsent_at: 2026-09-02T00:00:00Z\n---\n\nyo\n' \
  > "${MREAD}/20260902T000000Z-002-${SLUG}.md"; chmod 644 "${MREAD}/20260902T000000Z-002-${SLUG}.md"
CH="$(cd "${R2}" && doctor_check_channels "${MENTRY}" ".")"
assert_finding "a peer-written 0644 message -> warn message-mode" "${CH}" warn "message-mode" "not mode 0600"
assert_contains "message-mode reports a COUNT (one file off-mode)" "1 message file(s)" "${CH}"
# COUNTS ONLY, NEVER THE SLUG. A message filename carries the peer-chosen slug,
# which the doctor never emits -- the same rule the count-only surfaces follow.
assert_not_contains "message-mode NEVER names the peer's slug" "${SLUG}" "${CH}"
# Fix it and the finding turns ok, proving the check tracks real state.
chmod 600 "${MREAD}/20260902T000000Z-002-${SLUG}.md"
CH="$(cd "${R2}" && doctor_check_channels "${MENTRY}" ".")"
assert_finding "all 0600 -> ok message-mode" "${CH}" ok "message-mode" "all mode 0600"
assert_no_finding "... and no message-mode warn remains" "${CH}" warn "message-mode" "not mode 0600"
# .acked/ is judged too (a peer message acked with mv preserves its 0644 mode).
mkdir -p -m 700 "${MREAD}/.acked"
printf -- '---\nfrom: peer\nto: me\nsent_at: 2026-09-03T00:00:00Z\n---\n\nk\n' \
  > "${MREAD}/.acked/20260903T000000Z-003-${SLUG}.md"; chmod 644 "${MREAD}/.acked/20260903T000000Z-003-${SLUG}.md"
CH="$(cd "${R2}" && doctor_check_channels "${MENTRY}" ".")"
assert_finding "a 0644 message in .acked/ is caught too" "${CH}" warn "message-mode" "not mode 0600"
rm -rf "${ATHENA_INBOX_ROOT}/agent-mail"

# ============================================================================
echo "== server (opt-in) =="
unset ATHENA_INBOX_DOCTOR_HEALTH_FILE ATHENA_INBOX_DOCTOR_API_BASE ATHENA_INBOX_DOCTOR_MACHINE_ID ATHENA_INBOX_DOCTOR_API_TOKEN_FILE 2>/dev/null || true
assert_eq "no token -> server na" na "$(state_of "$(cd "${R2}" && doctor_check_server ".")" server)"
# unreachable: base/id/token set but token file missing -> na (not fail)
export ATHENA_INBOX_DOCTOR_API_BASE="https://x" ATHENA_INBOX_DOCTOR_MACHINE_ID="m" ATHENA_INBOX_DOCTOR_API_TOKEN_FILE="${TMP}/no-token"
assert_eq "token file missing -> server na" na "$(state_of "$(cd "${R2}" && doctor_check_server ".")" server)"
unset ATHENA_INBOX_DOCTOR_API_BASE ATHENA_INBOX_DOCTOR_MACHINE_ID ATHENA_INBOX_DOCTOR_API_TOKEN_FILE
# canned health: connected false -> warn
HJ="${TMP}/health.json"; export ATHENA_INBOX_DOCTOR_HEALTH_FILE="${HJ}"
printf '{"data":{"machine":{"connected":false},"instances":[]}}' > "${HJ}"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json"
assert_eq "connected false -> warn" warn "$(state_of "$(cd "${R2}" && doctor_check_server ".")" server)"
# override cross-check: mismatch -> fail, typo -> warn, unclaimed -> warn
CFG2="${TMP}/cfg2.json"; export ATHENA_INBOX_CLIENT_CONFIG="${CFG2}"
printf '{"instances":{"slack":{"inbox":"WRONG.jsonl","doorbell":null},"typo":{"inbox":"y.jsonl","doorbell":null}}}' > "${CFG2}"; chmod 600 "${CFG2}"
printf '{"data":{"machine":{"connected":true},"instances":[{"name":"slack","inbox_name":"ch-slack.jsonl","undelivered":0},{"name":"orphan","inbox_name":"nobody.jsonl","undelivered":0}]}}' > "${HJ}"
SV="$(cd "${R2}" && doctor_check_server ".")"
assert_finding "override mismatch -> fail" "${SV}" fail server-override "WRONG.jsonl"
assert_finding "typo key -> warn"          "${SV}" warn server-override "typo"
assert_finding "unclaimed inbox_name -> informational (server-instance)" "${SV}" warn server-instance "nobody.jsonl"
# undelivered > 0 -> warn ("server holding events")
printf '{"data":{"machine":{"connected":true},"instances":[{"name":"slack","inbox_name":"ch-slack.jsonl","undelivered":2}]}}' > "${HJ}"
printf '{"instances":{}}' > "${CFG2}"; chmod 600 "${CFG2}"
assert_finding "undelivered>0 -> warn" "$(cd "${R2}" && doctor_check_server ".")" warn server "not yet delivered to this machine"
# everything agrees -> server-override ok. The R2 registry entry declares a log
# channel with path ch-slack.jsonl, so the server's inbox_name is claimed; the
# config override matches; no typo.
printf '{"instances":{"slack":{"inbox":"ch-slack.jsonl","doorbell":null}}}' > "${CFG2}"; chmod 600 "${CFG2}"
printf '{"data":{"machine":{"connected":true},"instances":[{"name":"slack","inbox_name":"ch-slack.jsonl","undelivered":0}]}}' > "${HJ}"
assert_eq "all agree -> server-override ok" ok "$(state_of "$(cd "${R2}" && doctor_check_server ".")" server-override)"
unset ATHENA_INBOX_DOCTOR_HEALTH_FILE; export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json"
# --no-server: the hook's flag forces the server check to na (no network),
# whatever the environment holds.
export DOCTOR_NO_SERVER=1
assert_eq "--no-server -> server na (disabled)" na "$(state_of "$(cd "${R2}" && doctor_check_server ".")" server)"
unset DOCTOR_NO_SERVER
# a token file more permissive than 0600 -> warn, and the credential is NOT read
TOKF="${TMP}/apitoken"; printf 'usr-tok' > "${TOKF}"; chmod 644 "${TOKF}"
export ATHENA_INBOX_DOCTOR_API_BASE="https://x" ATHENA_INBOX_DOCTOR_MACHINE_ID="m" ATHENA_INBOX_DOCTOR_API_TOKEN_FILE="${TOKF}"
assert_eq "0644 token file -> server warn (credential not read)" warn "$(state_of "$(cd "${R2}" && doctor_check_server ".")" server)"
# NOTE: the 0600-but-unreachable path (a real curl) is deliberately NOT
# exercised here -- it would open a socket, which this suite forbids. It is the
# same na branch the "token file missing" case above already proves.
unset ATHENA_INBOX_DOCTOR_API_BASE ATHENA_INBOX_DOCTOR_MACHINE_ID ATHENA_INBOX_DOCTOR_API_TOKEN_FILE

# ============================================================================
echo "== bin: exit code, --json, na-never-ok =="
export ATHENA_INBOX_ROOT="${TMP}/bin"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"
chmod 700 "${ATHENA_INBOX_ROOT}"   # -m 700 above modes only the last component
R3="${TMP}/repo3"; C3="$(make_repo "${R3}")"
printf '{"v":1,"repo":"%s","channels":{"slack":{"kind":"log","path":"bin-slack.jsonl"}}}' "${C3}" > "${ATHENA_INBOX_ROOT}/projects/bin.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/bin.json"
printf '{"v":1,"ts":"1","channel":"c","event_id":"e"}\n' > "${ATHENA_INBOX_ROOT}/bin-slack.jsonl"; chmod 600 "${ATHENA_INBOX_ROOT}/bin-slack.jsonl"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" ATHENA_INBOX_DOCTOR_CRON_CHECK="true"
( cd "${R3}" && bash "${BIN}" >/dev/null 2>&1 ); assert_eq "no fail -> exit 0" 0 "$?"
JSON="$(cd "${R3}" && bash "${BIN}" --json)"
assert_eq "json is one object"     object "$(printf '%s' "${JSON}" | jq -r 'type')"
assert_eq "summary na is its own bucket" true "$(printf '%s' "${JSON}" | jq -r '.summary.na >= 1')"
# na is NOT counted as ok -- the ticket's crux. The summary's ok/na counts MUST
# equal the number of findings actually in each state; a count_state that folded
# na into N_OK (or a summary that miscounted) would make summary.ok exceed the
# ok-findings tally and redden here. (The earlier `state=="ok" and state=="na"`
# check was a tautology -- a state cannot be two values -- and proved nothing;
# the critic's review caught it.)
OK_FINDINGS="$(printf '%s' "${JSON}" | jq -r '[.findings[] | select(.state=="ok")] | length')"
NA_FINDINGS="$(printf '%s' "${JSON}" | jq -r '[.findings[] | select(.state=="na")] | length')"
assert_eq "summary.ok equals the ok-findings tally" "${OK_FINDINGS}" "$(printf '%s' "${JSON}" | jq -r '.summary.ok')"
assert_eq "summary.na equals the na-findings tally" "${NA_FINDINGS}" "$(printf '%s' "${JSON}" | jq -r '.summary.na')"
assert_eq "there ARE na findings to mis-count" true "$([ "${NA_FINDINGS}" -ge 1 ] && echo true || echo false)"
# na alone keeps healthy TRUE -- proven on a fixture with ZERO warnings (the
# entry declared in a committed list so undeclared-entry is ok), where na
# findings (client-config, client-running, server) are the only non-ok states.
# The earlier form (`... else true`) was vacuous whenever the fixture warned.
DECL="${TMP}/bin-committed.json"
jq -n --arg r "${C3}" '{v:1,projects:[{file:"bin.json",entry:{v:1,repo:$r,channels:{slack:{kind:"log",path:"bin-slack.jsonl"}}}}]}' > "${DECL}"
JSON0="$(cd "${R3}" && ATHENA_INBOX_REGISTRY="${DECL}" bash "${BIN}" --json)"
assert_eq "zero-warn fixture really has na findings" true "$(printf '%s' "${JSON0}" | jq -r '.summary.na >= 1')"
assert_eq "zero-warn fixture really has no warnings" 0 "$(printf '%s' "${JSON0}" | jq -r '.summary.warn')"
assert_eq "na alone keeps healthy true" true "$(printf '%s' "${JSON0}" | jq -r '.summary.healthy')"
assert_eq "na alone keeps exit 0" 0 "$( ( cd "${R3}" && ATHENA_INBOX_REGISTRY="${DECL}" bash "${BIN}" >/dev/null 2>&1 ); echo $? )"
# INFORMATIONAL warns (this fixture's entry is undeclared in the committed list)
# are surfaced as warn AND counted in info, but DO NOT flip healthy -- otherwise
# the hook would nag every opted-in repo forever about a benign steady state.
assert_eq "there IS an informational warn here" true "$(printf '%s' "${JSON}" | jq -r '(.summary.info >= 1) and (.summary.warn >= 1)')"
assert_eq "an informational-only chain is healthy" true "$(printf '%s' "${JSON}" | jq -r 'if (.summary.fail==0 and (.summary.warn - .summary.info)==0) then (.summary.healthy==true) else "SKIP" end')"
assert_eq "informational warn does not set exit non-zero" 0 "$( ( cd "${R3}" && bash "${BIN}" >/dev/null 2>&1 ); echo $? )"
# force a fail (invalid entry) -> exit 1
printf '{"v":1,"repo":"%s","channels":{"slack":{"kind":"bogus"}}}' "${C3}" > "${ATHENA_INBOX_ROOT}/projects/bin.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/bin.json"
( cd "${R3}" && bash "${BIN}" >/dev/null 2>&1 ); assert_eq "a fail -> exit 1" 1 "$?"

# read-only guarantee across a full run: the channel bytes are unchanged.
printf '{"v":1,"repo":"%s","channels":{"slack":{"kind":"log","path":"bin-slack.jsonl"}}}' "${C3}" > "${ATHENA_INBOX_ROOT}/projects/bin.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/bin.json"
BEFORE="$(md5sum "${ATHENA_INBOX_ROOT}/bin-slack.jsonl" | cut -d' ' -f1)"
( cd "${R3}" && bash "${BIN}" >/dev/null 2>&1 )
AFTER="$(md5sum "${ATHENA_INBOX_ROOT}/bin-slack.jsonl" | cut -d' ' -f1)"
assert_eq "channel file unchanged by a run" "${BEFORE}" "${AFTER}"
[ ! -e "${ATHENA_INBOX_ROOT}/bin-slack.state.json" ] && ok "no state file written by a run" || bad "no state file written" "state.json created"

# ============================================================================
echo "== which states flip 'healthy' (the INFO_SET carve-out) =="
# A COLLISION is actionable -> healthy false. Two entries on one surface.
export ATHENA_INBOX_ROOT="${TMP}/hc"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"; chmod 700 "${ATHENA_INBOX_ROOT}"
RH="${TMP}/repohc"; CH2="$(make_repo "${RH}")"
printf '{"v":1,"repo":"%s","channels":{"s":{"kind":"log","path":"dup.jsonl"}}}' "${CH2}" > "${ATHENA_INBOX_ROOT}/projects/hc.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/hc.json"
printf '{"v":1,"repo":"/other/.git","channels":{"s":{"kind":"log","path":"dup.jsonl"}}}' > "${ATHENA_INBOX_ROOT}/projects/other.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/other.json"
printf '{"v":1,"ts":"1","channel":"c","event_id":"e"}\n' > "${ATHENA_INBOX_ROOT}/dup.jsonl"; chmod 600 "${ATHENA_INBOX_ROOT}/dup.jsonl"
DECLHC="${TMP}/hc-committed.json"
jq -n --arg r "${CH2}" '{v:1,projects:[{file:"hc.json",entry:{v:1,repo:$r,channels:{s:{kind:"log",path:"dup.jsonl"}}}},{file:"other.json",entry:{v:1,repo:"/other/.git",channels:{s:{kind:"log",path:"dup.jsonl"}}}}]}' > "${DECLHC}"
JHC="$(cd "${RH}" && ATHENA_INBOX_REGISTRY="${DECLHC}" ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" ATHENA_INBOX_DOCTOR_CRON_CHECK=true bash "${BIN}" --json)"
assert_eq "collision present" true "$(printf '%s' "${JHC}" | jq -r '[.findings[]|select(.check=="collision" and .state=="warn")]|length >= 1')"
assert_eq "collision flips healthy to false" false "$(printf '%s' "${JHC}" | jq -r '.summary.healthy')"
assert_eq "collision is not in the info bucket" 0 "$(printf '%s' "${JHC}" | jq -r '.summary.info')"

# A peer-written 0644 maildir message is the OPPOSITE: contract drift on a
# single-user box the local session cannot fix, so message-mode is a warn that
# is surfaced (info count, findings list) but does NOT flip `healthy`. Proven
# end to end through the bin, the way collision above is.
export ATHENA_INBOX_ROOT="${TMP}/mm"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"; chmod 700 "${ATHENA_INBOX_ROOT}"
RMM="${TMP}/repomm"; CMM="$(make_repo "${RMM}")"
printf '{"v":1,"repo":"%s","channels":{"mail":{"kind":"maildir","namespace":"agent-mail/mm","read":"in","write":"out","identity":"me"}}}' "${CMM}" > "${ATHENA_INBOX_ROOT}/projects/mm.json"; chmod 600 "${ATHENA_INBOX_ROOT}/projects/mm.json"
mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/agent-mail/mm/in"
printf -- '---\nfrom: peer\nto: me\nsent_at: 2026-09-01T23:22:15Z\n---\n\nhi\n' \
  > "${ATHENA_INBOX_ROOT}/agent-mail/mm/in/20260901T232215Z-001-drift.md"; chmod 644 "${ATHENA_INBOX_ROOT}/agent-mail/mm/in/20260901T232215Z-001-drift.md"
DECLMM="${TMP}/mm-committed.json"
jq -n --arg r "${CMM}" '{v:1,projects:[{file:"mm.json",entry:{v:1,repo:$r,channels:{mail:{kind:"maildir",namespace:"agent-mail/mm",read:"in",write:"out",identity:"me"}}}}]}' > "${DECLMM}"
JMM="$(cd "${RMM}" && ATHENA_INBOX_REGISTRY="${DECLMM}" ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" ATHENA_INBOX_DOCTOR_CRON_CHECK=true bash "${BIN}" --json --no-server)"
assert_eq "message-mode warn present" true "$(printf '%s' "${JMM}" | jq -r '[.findings[]|select(.check=="message-mode" and .state=="warn")]|length >= 1')"
assert_eq "message-mode is counted in the info bucket" true "$(printf '%s' "${JMM}" | jq -r '.summary.info >= 1')"
assert_eq "message-mode does NOT flip healthy" true "$(printf '%s' "${JMM}" | jq -r '.summary.healthy')"
assert_eq "message-mode does not set a non-zero exit" 0 "$( ( cd "${RMM}" && ATHENA_INBOX_REGISTRY="${DECLMM}" ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" ATHENA_INBOX_DOCTOR_CRON_CHECK=true bash "${BIN}" --no-server >/dev/null 2>&1 ); echo $? )"
assert_not_contains "the bin output never leaks a message slug" "drift.md" "$(printf '%s' "${JMM}" | jq -r '.findings[]|select(.check=="message-mode")|.message + " " + .fix')"

# ============================================================================
echo "== DND-316: client-liveness (never pid existence) =="
LV="${TMP}/lv"; mkdir -p "${LV}/state" "${LV}/xdg"
LVCFG="${LV}/config.json"
printf '{"server_url":"wss://athena.example/machine/websocket?vsn=2.0.0","token":"SEKRETTOKEN-abcdef-0123456789","instances":{}}' > "${LVCFG}"; chmod 600 "${LVCFG}"
export ATHENA_INBOX_CLIENT_CONFIG="${LVCFG}" ATHENA_INBOX_CLIENT_STATE_DIR="${LV}/state" XDG_STATE_HOME="${LV}/xdg"
LVLOG="${LV}/state/athena-inbox-client.log"
# THE 2026-09-22 15:55Z SHAPE: a reconnect that never finished. Must FAIL.
printf '%s\n' '2026-09-22T15:32:56Z INFO appended Ev0C3LF099SS to walt_ui-slack.jsonl' \
  '2026-09-22T15:55:15Z ERROR session ended: ProtocolError: heartbeat unanswered' \
  '2026-09-22T15:55:15Z INFO reconnecting in 1.0s' > "${LVLOG}"
LO="$(doctor_check_client_liveness 1)"
assert_eq "15:55Z replay -> client-liveness fail" fail "$(state_of "${LO}" client-liveness)"
assert_contains "the wedge finding names the step" "stuck in step sleep" "${LO}"
assert_contains "the wedge Fix says capture before restart" "CAPTURE BEFORE RESTART" "${LO}"
assert_contains "the wedge Fix names the supervisor" "athena-inbox-client-run.sh" "${LO}"
# A HEALTHY log with a lazily-closed prior socket: reconnect, join, then quiet.
printf '%s\n' '2026-09-22T21:30:02Z INFO reconnecting in 1.1s' '2026-09-22T21:30:04Z INFO step tls 48ms' \
  '2026-09-22T21:30:04Z INFO connected to wss://athena.example/machine/websocket' \
  '2026-09-22T21:30:12Z INFO joined machine:self; instances: ["a"]' > "${LVLOG}"
LO="$(doctor_check_client_liveness 1)"
assert_eq "healthy quiet client (CLOSE-WAIT shape) -> ok, no false alarm" ok "$(state_of "${LO}" client-liveness)"
: > "${LVLOG}"
assert_eq "a log with no connect-cycle line -> warn (not ok)" warn "$(state_of "$(doctor_check_client_liveness 1)" client-liveness)"
rm -f "${LVLOG}"
assert_eq "no log -> na" na "$(state_of "$(doctor_check_client_liveness 1)" client-liveness)"
assert_eq "stopped -> na" na "$(state_of "$(doctor_check_client_liveness 0)" client-liveness)"
assert_eq "no client config -> na" na "$(ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" doctor_check_client_liveness 1 | cut -f1)"
assert_eq "pure: wedged -> fail"           fail "$(doctor_state_liveness wedged)"
assert_eq "pure: reconnecting -> ok"       ok   "$(doctor_state_liveness reconnecting)"
assert_eq "pure: unknown -> warn"          warn "$(doctor_state_liveness unknown)"
assert_eq "pure: absent -> na"             na   "$(doctor_state_liveness absent)"

echo "== DND-316: dump-dir resolves and is writable =="
DD="${LV}/xdg/athena/inbox-client-dumps"
DDA="$(doctor_check_dump_dir)"
assert_eq "dump dir not yet created, parent writable -> ok (a dump would land)" ok "$(state_of "${DDA}" dump-dir)"
assert_contains "... and says it does not exist yet but CAN be created" "does not exist yet, but CAN be created" "${DDA}"
mkdir -p -m 700 "${DD}"; chmod 700 "${DD}"
assert_eq "dump dir 0700 writable -> ok" ok "$(state_of "$(doctor_check_dump_dir)" dump-dir)"
chmod 755 "${DD}"
assert_eq "dump dir 0755 -> warn" warn "$(state_of "$(doctor_check_dump_dir)" dump-dir)"
chmod 500 "${DD}"
if [ -w "${DD}" ]; then ok "dump dir unwritable -> fail (skipped: running as a user that bypasses modes)"; else
  assert_eq "dump dir unwritable -> fail" fail "$(state_of "$(doctor_check_dump_dir)" dump-dir)"; fi
chmod 700 "${DD}"; rmdir "${DD}"; : > "${DD}"
DDO="$(doctor_check_dump_dir)"
assert_eq "a FILE where the dump dir should be -> fail" fail "$(state_of "${DDO}" dump-dir)"
assert_contains "... with a Fix:" "remove whatever sits at" "${DDO}"
rm -f "${DD}"
assert_eq "a RELATIVE XDG_STATE_HOME -> fail (wrongly computed key)" fail "$(XDG_STATE_HOME=rel doctor_check_dump_dir | cut -f1)"
assert_eq "no client config -> na" na "$(ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" doctor_check_dump_dir | cut -f1)"

echo "== DND-333: captures on disk, newest first, with signatures (informational) =="
DD2="${LV}/xdg/athena/inbox-client-dumps"; mkdir -p -m 700 "${DD2}"
assert_eq "no captures -> ok" ok "$(state_of "$(doctor_check_captures)" captures)"
for c in 20260922T155515Z-759946 20260923T090000Z-123; do
  mkdir -p "${DD2}/${c}"
  printf 'signature: abcdef0123456789\nstep: tls\nsource: dump\nframes:\n' > "${DD2}/${c}/signature.txt"
  printf 'dump: absent (handler did not respond within 10s)\n' > "${DD2}/${c}/capture.txt"
done
: > "${DD2}/20260923T080000Z-5.txt"
CO="$(doctor_check_captures)"
assert_eq "captures present -> warn" warn "$(state_of "${CO}" captures)"
assert_contains "... newest first, with signature, step and dump status" "2 wedge capture(s) on disk (newest first): 20260923T090000Z-123 sig abcdef01 step tls dump absent; 20260922T155515Z-759946" "${CO}"
assert_contains "captures is informational (in INFO_SET)" " captures " "$(sed -n 's/^INFO_SET=//p' "${BIN}")"
rm -rf "${DD2}"

echo "== DND-333: the watchdog's tools are present =="
assert_eq "tools present in this checkout -> ok" ok "$(state_of "$(doctor_check_watchdog)" watchdog)"
FAKEREPO="${LV}/fakerepo"; mkdir -p "${FAKEREPO}/scripts" "${FAKEREPO}/ai/skills/athena:inbox/lib"
: > "${FAKEREPO}/ai/skills/athena:inbox/lib/liveness.sh"
WO="$(DOCTOR_REPO_DIR="${FAKEREPO}" doctor_check_watchdog)"
assert_eq "capture tool missing -> fail" fail "$(state_of "${WO}" watchdog)"
assert_contains "... naming it, with a Fix:" "scripts/inbox-client-capture (executable)" "${WO}"
# DND-367: the alert tool is the watchdog's too. Missing, the watchdog logs
# ALERT NOT SENT and the harness session never hears of the wedge; the doctor
# must not stay green over that.
printf '#!/bin/sh\n' > "${FAKEREPO}/scripts/inbox-client-capture"; chmod +x "${FAKEREPO}/scripts/inbox-client-capture"
WO="$(DOCTOR_REPO_DIR="${FAKEREPO}" doctor_check_watchdog)"
assert_eq "alert tool missing (capture present) -> fail" fail "$(state_of "${WO}" watchdog)"
assert_contains "... naming the alert tool" "scripts/inbox-client-alert (executable)" "${WO}"
assert_contains "... with a fix naming the tool to restore" "restore" "$(printf '%s\n' "${WO}" | awk -F'\t' '$2=="watchdog"{print $4}')"
printf '#!/bin/sh\n' > "${FAKEREPO}/scripts/inbox-client-alert"; chmod -x "${FAKEREPO}/scripts/inbox-client-alert"
assert_eq "alert tool present but NOT executable -> fail" fail "$(state_of "$(DOCTOR_REPO_DIR="${FAKEREPO}" doctor_check_watchdog)" watchdog)"
chmod +x "${FAKEREPO}/scripts/inbox-client-alert"
assert_eq "all three tools present -> ok" ok "$(state_of "$(DOCTOR_REPO_DIR="${FAKEREPO}" doctor_check_watchdog)" watchdog)"
assert_eq "no client config -> na" na "$(ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" doctor_check_watchdog | cut -f1)"

echo "== DND-316: a stale channel FAILS (never 'last changed Ns ago' ok) =="
export ATHENA_INBOX_ROOT="${TMP}/stale"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"; chmod 700 "${ATHENA_INBOX_ROOT}"
RS="${TMP}/repo-stale"; CS="$(make_repo "${RS}")"
SENTRY='{"v":1,"repo":"'"${CS}"'","channels":{"slack":{"kind":"log","path":"st-slack.jsonl"}}}'
printf '{"v":1,"ts":"1","channel":"c","event_id":"e"}\n' > "${ATHENA_INBOX_ROOT}/st-slack.jsonl"; : > "${ATHENA_INBOX_ROOT}/st-slack.event"
chmod 600 "${ATHENA_INBOX_ROOT}/st-slack.jsonl" "${ATHENA_INBOX_ROOT}/st-slack.event"
touch -d "@$(( $(date -u +%s) - 5632 ))" "${ATHENA_INBOX_ROOT}/st-slack.jsonl" "${ATHENA_INBOX_ROOT}/st-slack.event"
SO="$(cd "${RS}" && doctor_check_channels "${SENTRY}" ".")"
assert_finding "the 5632s-stale channel of 2026-09-22 -> FAIL" "${SO}" fail "freshness:slack" "STALE"
assert_contains "the stale Fix points at client-liveness and server-reachability" "client-liveness and server-reachability" "${SO}"
assert_no_finding "no ok finding grades that age" "${SO}" ok "freshness:slack" "last delivery"
SENTRY0='{"v":1,"repo":"'"${CS}"'","channels":{"slack":{"kind":"log","path":"st-slack.jsonl","stale_after_s":0}}}'
SO="$(cd "${RS}" && doctor_check_channels "${SENTRY0}" ".")"
assert_finding "stale_after_s 0 -> ok, threshold disabled" "${SO}" ok "freshness:slack" "no staleness threshold"

echo "== DND-316: server-reachability with the MACHINE token =="
export DOCTOR_NO_SERVER=0
RF="${LV}/reach.json"
printf '{"reachable":false,"basis":"ack_silence","last_ack_at":"2026-09-22T15:32:56Z","last_joined_at":null,"pending_deliveries":3,"unreachable_since":"2026-09-22T15:40:00Z"}' > "${RF}"
RO="$(ATHENA_INBOX_DOCTOR_REACHABLE_FILE="${RF}" doctor_check_server_reachability)"
assert_eq "reachable:false -> fail" fail "$(state_of "${RO}" server-reachability)"
assert_contains "... names unreachable_since" "UNREACHABLE since 2026-09-22T15:40:00Z" "${RO}"
assert_contains "... reports the pending count" "3 pending" "${RO}"
printf '{"reachable":true,"basis":"recent_ack","last_ack_at":"2026-09-23T08:00:00Z","last_joined_at":"2026-09-23T07:39:06Z","pending_deliveries":0,"unreachable_since":null}' > "${RF}"
RO="$(ATHENA_INBOX_DOCTOR_REACHABLE_FILE="${RF}" doctor_check_server_reachability)"
assert_eq "reachable:true, 0 pending -> ok" ok "$(state_of "${RO}" server-reachability)"
assert_contains "... says 'checked' and '0 pending' in those words" "checked: reachable true, 0 pending" "${RO}"
assert_contains "a canned answer says it is canned, never passing for live" "CANNED answer" "${RO}"
printf '{"reachable":"unknown","basis":"no_traffic","last_ack_at":null,"last_joined_at":null,"pending_deliveries":2,"unreachable_since":null}' > "${RF}"
RO="$(ATHENA_INBOX_DOCTOR_REACHABLE_FILE="${RF}" doctor_check_server_reachability)"
assert_eq "unknown with pending > 0 -> warn with the count" warn "$(state_of "${RO}" server-reachability)"
assert_contains "... the pending count (exhausted-offline counts as pending)" "holds 2 pending" "${RO}"
printf 'UNAVAILABLE:tool machine_reachable not found' > "${RF}"
RO="$(ATHENA_INBOX_DOCTOR_REACHABLE_FILE="${RF}" doctor_check_server_reachability)"
assert_eq "tool not deployed -> na" na "$(state_of "${RO}" server-reachability)"
assert_contains "... reads UNAVAILABLE" "UNAVAILABLE (tried, got no answer)" "${RO}"
assert_not_contains "... never reads SKIPPED" "SKIPPED" "${RO}"
RO="$(ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" doctor_check_server_reachability)"
assert_contains "no client config -> SKIPPED (never UNAVAILABLE)" "SKIPPED" "${RO}"
assert_not_contains "... never reads UNAVAILABLE" "UNAVAILABLE" "${RO}"
RO="$(DOCTOR_NO_SERVER=1 doctor_check_server_reachability)"
assert_contains "--no-server -> disabled, no request" "not run (disabled" "${RO}"

# The REAL protocol path through a curl shim: initialize -> session id ->
# notifications/initialized -> tools/call machine_reachable. The shim records its
# argv and the curl config so the suite can assert the token never reaches argv.
SHIM="${LV}/shimbin"; mkdir -p "${SHIM}"
cat > "${SHIM}/curl" <<'SHIMEOF'
#!/usr/bin/env bash
# curl shim for the doctor suite: reads --config, answers like the Athena /mcp.
printf '%s\n' "$*" >> "${SHIM_LOG}.argv"
cfg=""; while [ $# -gt 0 ]; do [ "$1" = "--config" ] && cfg="$2"; shift; done
stat -c '%a' "${cfg}" >> "${SHIM_LOG}.cfgmode"
val() { sed -n "s/^$1 = \"\\(.*\\)\"\$/\\1/p" "${cfg}" | head -n1; }
hdr="$(val dump-header)"; out="$(val output)"; data="$(val data-binary)"; data="${data#@}"
auth="$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' "${cfg}")"
[ "${auth}" = "${SHIM_EXPECT_TOKEN}" ] || { printf 'HTTP/1.1 401\r\n' > "${hdr}"; : > "${out}"; printf '401'; exit 0; }
method="$(jq -r '.method' < "${data}")"
case "${method}" in
  initialize) printf 'HTTP/1.1 200 OK\r\nmcp-session-id: sess-42\r\n\r\n' > "${hdr}"; printf '{"jsonrpc":"2.0","id":1,"result":{}}' > "${out}"; printf '200' ;;
  notifications/initialized) printf 'HTTP/1.1 202\r\n' > "${hdr}"; : > "${out}"; printf '202' ;;
  tools/call)
    grep -q 'mcp-session-id: sess-42' "${cfg}" || { printf 'HTTP/1.1 400\r\n' > "${hdr}"; : > "${out}"; printf '400'; exit 0; }
    printf 'HTTP/1.1 200 OK\r\n' > "${hdr}"
    if [ "${SHIM_MODE:-ok}" = "notool" ]; then
      printf '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Tool not found: machine_reachable"}}' > "${out}"
    else
      jq -n -c --arg t "${SHIM_RESULT}" '{jsonrpc:"2.0",id:2,result:{content:[{type:"text",text:$t}],isError:false}}' > "${out}"
    fi
    printf '200' ;;
  *) printf '400' ;;
esac
SHIMEOF
chmod +x "${SHIM}/curl"
export SHIM_LOG="${LV}/shim" SHIM_EXPECT_TOKEN="SEKRETTOKEN-abcdef-0123456789"
export SHIM_RESULT='{"reachable":true,"basis":"recent_ack","last_ack_at":"2026-09-23T08:00:00Z","last_joined_at":null,"pending_deliveries":0,"unreachable_since":null}'
RO="$(PATH="${SHIM}:${PATH}" doctor_check_server_reachability)"
assert_eq "protocol path: initialize/session/tools/call -> ok" ok "$(state_of "${RO}" server-reachability)"
assert_contains "... 'checked, 0 pending'" "0 pending" "${RO}"
assert_not_contains "the live protocol path is not marked canned" "CANNED" "${RO}"
assert_not_contains "the machine token is never in curl's argv" "SEKRETTOKEN" "$(cat "${SHIM_LOG}.argv")"
assert_not_contains "the machine token is never in a finding" "SEKRETTOKEN" "${RO}"
assert_eq "every curl config was 0600" "600" "$(sort -u "${SHIM_LOG}.cfgmode")"
RO="$(PATH="${SHIM}:${PATH}" SHIM_MODE=notool doctor_check_server_reachability)"
assert_contains "protocol path: tool missing (DND-315 not deployed) -> UNAVAILABLE" "UNAVAILABLE" "${RO}"
assert_contains "... with the server's own words" "Tool not found" "${RO}"
RO="$(PATH="${SHIM}:${PATH}" SHIM_EXPECT_TOKEN=other doctor_check_server_reachability)"
assert_contains "protocol path: a refused token -> UNAVAILABLE naming the refusal" "refused the machine token" "${RO}"
printf '{"server_url":"wss://athena.example/machine/websocket","token":"bad\\"tok","instances":{}}' > "${LV}/badtok.json"; chmod 600 "${LV}/badtok.json"
: > "${SHIM_LOG}.argv"
RO="$(PATH="${SHIM}:${PATH}" ATHENA_INBOX_CLIENT_CONFIG="${LV}/badtok.json" doctor_check_server_reachability)"
assert_contains "a token that cannot be quoted safely -> UNAVAILABLE, never sent" "cannot be sent safely" "${RO}"
assert_eq "... and curl was never invoked" "" "$(cat "${SHIM_LOG}.argv")"
unset DOCTOR_NO_SERVER ATHENA_INBOX_CLIENT_STATE_DIR XDG_STATE_HOME SHIM_LOG SHIM_EXPECT_TOKEN SHIM_RESULT
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json"

# ============================================================================
echo "== repo-root resolves through a symlinked skills dir (bin uses -P) =="
# SKILL.md tells a session to run the tool from ~/.claude/skills/athena:inbox/bin,
# and ~/.claude/skills is a symlink to ~/dev/custom/ai/skills. The bin must
# resolve its OWN real location (cd -P / pwd -P) so DOCTOR_REPO_DIR is the repo,
# not $HOME. With a plain `cd && pwd`, `bin/../../../..` walks the symlinked path
# and lands in $HOME, so doctor_check_undeclared_live goes `na "cannot consult
# the committed registry list"` on a wrongly computed root -- the
# missing-looks-empty trap. We invoke through a symlink that replaces the
# `skills` segment, with DOCTOR_REPO_DIR UNSET so the bin must compute it.
if command -v ruby >/dev/null 2>&1 && [ -f "${REPO}/ai/inbox/lib/registry.rb" ]; then
  export ATHENA_INBOX_ROOT="${TMP}/slroot"; mkdir -p -m 700 "${ATHENA_INBOX_ROOT}/projects"; chmod 700 "${ATHENA_INBOX_ROOT}"
  SLINK="${TMP}/skills"; ln -sfn "${REPO}/ai/skills" "${SLINK}"
  SLCOMMIT="${TMP}/sl-committed.json"; printf '{"v":1,"projects":[]}' > "${SLCOMMIT}"
  SLOUT="$( env -u DOCTOR_REPO_DIR ATHENA_INBOX_REGISTRY="${SLCOMMIT}" ATHENA_INBOX_CLIENT_CONFIG="${TMP}/none.json" bash "${SLINK}/athena:inbox/bin/inbox-doctor" --json --no-server 2>/dev/null )"
  assert_not_contains "symlinked-skills run: root resolved (no 'cannot consult' na)" \
    "cannot consult the committed registry list" "${SLOUT}"
  assert_eq "symlinked-skills run: undeclared-entry is not na (declared list was consulted)" 0 \
    "$(printf '%s' "${SLOUT}" | jq -r '[.findings[]|select(.check=="undeclared-entry" and .state=="na")]|length')"
  export DOCTOR_REPO_DIR="${REPO}"
else
  ok "symlinked-skills root test skipped (no ruby or no registry.rb in this checkout)"
fi

printf '\n'
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0
else echo "VERDICT: FAIL (${FAIL} failed, ${PASS} passed)"; exit 1; fi
