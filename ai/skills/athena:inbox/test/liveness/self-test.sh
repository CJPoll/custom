#!/usr/bin/env bash
# Self-test for lib/liveness.sh (DND-316) and the surfaces that print it:
# inbox-status / read-inbox freshness and STALE, and descriptor `stale_after_s`.
#
# NOTHING LIVE IS TOUCHED. The client log, the state dir, the inbox root and
# XDG_STATE_HOME all point into a mktemp -d; the client is never probed. Every
# clock is passed in or set with `touch -d @<epoch>`.
#
# The cases that matter are the ones that were silent on 2026-09-22:
#   * the 15:55Z log shape (`reconnecting in 1.0s`, then nothing) -> WEDGED;
#   * a healthy client that reconnected (a lazily-closed prior socket, the
#     CLOSE-WAIT shape) and then sat quiet for hours -> PROGRESSING, never a
#     false alarm, because nothing here reads sockets;
#   * a channel 94 minutes past its last delivery -> STALE, even at zero new.
#
# Run: bash test/liveness/self-test.sh
set -uo pipefail
# DND-1163: the bins resolve the session's project from CLAUDE_PROJECT_DIR,
# then /proc/$CLAUDE_PID/cwd, before the cwd. Scrubbed so the fixtures, not
# the Claude session running this suite, decide the project.
unset CLAUDE_PROJECT_DIR CLAUDE_PID

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "${HERE}/../.." && pwd)"
LIB="${SKILL}/lib"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain [$2], got [$3]" ;; esac; }
assert_not_contains() { case "$3" in *"$2"*) bad "$1" "expected NOT [$2], got [$3]" ;; *) ok "$1" ;; esac; }

# Isolate every default path before anything is sourced.
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export ATHENA_INBOX_CLIENT_STATE_DIR="${TMP}/state"; mkdir -p "${ATHENA_INBOX_CLIENT_STATE_DIR}"
export XDG_STATE_HOME="${TMP}/xdg"
unset ATHENA_INBOX_CLIENT_WEDGE_AFTER

# shellcheck source=/dev/null
for f in err names descriptor logchan maildir fence session fs lock inbox; do . "${LIB}/${f}.sh"; done

field() { printf '%s\n' "$1" | cut -f"$2"; }
epoch() { date -u -d "$1" +%s; }

# ============================================================================
echo "== classify: the LV-1 reconnect sequence =="
L() { printf '2026-09-22T15:55:15Z %s\n' "$1"; }
assert_eq "joined -> connected"            "connected	-	0"          "$(liveness_classify_line "$(L 'INFO joined machine:self; instances: []')")"
assert_eq "appended -> connected"          "connected	-	0"          "$(liveness_classify_line "$(L 'INFO appended Ev1 to walt_ui-slack.jsonl')")"
assert_eq "step joined -> connected"       "connected	-	0"          "$(liveness_classify_line "$(L 'INFO step joined 0ms')")"
assert_eq "reconnecting 1.0s -> sleep, grace 1" "reconnecting	sleep	1" "$(liveness_classify_line "$(L 'INFO reconnecting in 1.0s')")"
assert_eq "reconnecting 4.6s -> grace rounds UP to 5" "reconnecting	sleep	5" "$(liveness_classify_line "$(L 'INFO reconnecting in 4.6s')")"
assert_eq "step sleep_done -> stuck in dns"      "reconnecting	dns	0"         "$(liveness_classify_line "$(L 'INFO step sleep_done 1079ms')")"
assert_eq "step dns -> stuck in tcp_connect"     "reconnecting	tcp_connect	0" "$(liveness_classify_line "$(L 'INFO step dns 2ms')")"
assert_eq "step tcp_connect -> stuck in tls"     "reconnecting	tls	0"         "$(liveness_classify_line "$(L 'INFO step tcp_connect 30ms')")"
assert_eq "step tls -> stuck in ws_upgrade"      "reconnecting	ws_upgrade	0"  "$(liveness_classify_line "$(L 'INFO step tls 42ms')")"
assert_eq "step ws_upgrade -> stuck in join"     "reconnecting	join	0"        "$(liveness_classify_line "$(L 'INFO step ws_upgrade 112ms')")"
assert_eq "connected to -> stuck in join"        "reconnecting	join	0"        "$(liveness_classify_line "$(L 'INFO connected to wss://x/machine/websocket')")"
assert_eq "step join -> stuck in joined"         "reconnecting	joined	0"      "$(liveness_classify_line "$(L 'INFO step join 39ms')")"
assert_eq "failed step -> stuck reconnecting"    "reconnecting	reconnect	0"   "$(liveness_classify_line "$(L 'ERROR step tcp_connect failed after 31ms: Errno::ECONNREFUSED')")"
assert_eq "session ended -> stuck reconnecting"  "reconnecting	reconnect	0"   "$(liveness_classify_line "$(L 'ERROR session ended: ProtocolError: heartbeat unanswered')")"
assert_eq "supervisor start -> start"            "reconnecting	start	0"       "$(liveness_classify_line "$(L 'SUPERVISOR supervising /x/launcher (pid 9)')")"
assert_eq "supervisor restart 10s -> grace 10"   "reconnecting	start	10"      "$(liveness_classify_line "$(L 'SUPERVISOR client exited 1 after 3s; restart 2 in 10s')")"
for neutral in 'INFO diagnostics: wrote /x/y.txt (10 bytes)' 'SUPERVISOR WEDGE: something' 'INFO rotated'; do
  if liveness_classify_line "$(L "${neutral}")" >/dev/null; then bad "neutral line is not lifecycle: ${neutral}" "classified"; else ok "neutral line is not lifecycle: ${neutral}"; fi
done
if liveness_classify_line 'rotated' >/dev/null; then bad "an unstamped line is not lifecycle" "classified"; else ok "an unstamped line is not lifecycle"; fi
if liveness_classify_line "athena-inbox-client: stopping, not reconnecting" >/dev/null; then bad "a stderr line is not lifecycle" "classified"; else ok "a stderr line is not lifecycle"; fi

# ============================================================================
echo "== judge: pure verdicts =="
T0="$(epoch 2026-09-22T15:55:15Z)"
v="$(liveness_judge "$(L 'INFO reconnecting in 1.0s')" "$((T0 + 30))" 60)"
assert_eq "30s after 'reconnecting in 1.0s' -> reconnecting" reconnecting "$(field "$v" 1)"
v="$(liveness_judge "$(L 'INFO reconnecting in 1.0s')" "$((T0 + 62))" 60)"
assert_eq "grace+T boundary + 1s -> wedged" wedged "$(field "$v" 1)"
v="$(liveness_judge "$(L 'INFO reconnecting in 1.0s')" "$((T0 + 61))" 60)"
assert_eq "exactly grace+T -> still reconnecting" reconnecting "$(field "$v" 1)"
v="$(liveness_judge "$(L 'INFO reconnecting in 58.0s')" "$((T0 + 100))" 60)"
assert_eq "a long declared backoff is honoured (58s + 60s)" reconnecting "$(field "$v" 1)"
v="$(liveness_judge "$(L 'INFO step tcp_connect 30ms')" "$((T0 + 600))" 60)"
assert_eq "10 min after tcp_connect -> wedged" wedged "$(field "$v" 1)"
assert_eq "... in step tls" tls "$(field "$v" 2)"
assert_eq "... age 600" 600 "$(field "$v" 3)"
v="$(liveness_judge "$(L 'INFO joined machine:self; instances: []')" "$((T0 + 86400))" 60)"
assert_eq "a day after joined -> progressing (idle is healthy)" progressing "$(field "$v" 1)"
v="$(liveness_judge "" "${T0}" 60)"
assert_eq "no lifecycle line -> unknown, never progressing" unknown "$(field "$v" 1)"
v="$(liveness_judge "2026-13-45T99:99:99Z INFO joined x" "${T0}" 60)"
assert_eq "an unparseable stamp -> unknown" unknown "$(field "$v" 1)"
v="$(liveness_judge "$(L 'INFO step dns 2ms')" "abc" 60)"
assert_eq "an unusable clock -> unknown" unknown "$(field "$v" 1)"

# ============================================================================
echo "== verdict from a log on disk =="
LOG="$(liveness_client_log)"
# THE 2026-09-22 15:55Z SHAPE, replayed verbatim (pre-LV-1: no step lines).
cat > "${LOG}" <<'EOF'
2026-09-22T15:32:56Z INFO appended Ev0C3LF099SS to walt_ui-slack.jsonl
2026-09-22T15:55:15Z ERROR session ended: ProtocolError: heartbeat unanswered
2026-09-22T15:55:15Z INFO reconnecting in 1.0s
EOF
v="$(liveness_verdict "${LOG}" "$(epoch 2026-09-22T17:07:00Z)")"
assert_eq "the 15:55Z incident log -> wedged" wedged "$(field "$v" 1)"
assert_eq "... stuck in the backoff sleep" sleep "$(field "$v" 2)"

# A HEALTHY log with the lazily-closed prior socket (20:25Z / 21:30Z shapes):
# the client reconnected, joined in seconds, then went quiet for hours. The
# CLOSE-WAIT socket that sat beside it is invisible here BY DESIGN.
cat > "${LOG}" <<'EOF'
2026-09-22T21:30:02Z ERROR session ended: ProtocolError: server closed the connection
2026-09-22T21:30:02Z INFO reconnecting in 1.1s
2026-09-22T21:30:04Z INFO step sleep_done 1079ms
2026-09-22T21:30:04Z INFO step dns 10ms
2026-09-22T21:30:04Z INFO step tcp_connect 30ms
2026-09-22T21:30:04Z INFO step tls 48ms
2026-09-22T21:30:04Z INFO step ws_upgrade 111ms
2026-09-22T21:30:04Z INFO connected to wss://athena.example/machine/websocket?vsn=2.0.0
2026-09-22T21:30:04Z INFO step join 38ms
2026-09-22T21:30:04Z INFO step joined 0ms
2026-09-22T21:30:12Z INFO joined machine:self; instances: ["a"]
2026-09-22T21:31:00Z INFO diagnostics: wrote /tmp/x.txt (100 bytes)
EOF
v="$(liveness_verdict "${LOG}" "$(epoch 2026-09-23T01:00:00Z)")"
assert_eq "healthy reconnect then 3.5h quiet -> progressing (no CLOSE-WAIT false alarm)" progressing "$(field "$v" 1)"
assert_eq "last join epoch read from the log" "$(epoch 2026-09-22T21:30:12Z)" "$(liveness_last_join_epoch "${LOG}")"

# Rotation: the live file holds only the RotatingLog's first line; the last
# lifecycle event is in `.1`.
printf 'rotated\n' > "${LOG}"
printf '2026-09-22T21:30:04Z INFO step tls 48ms\n' > "${LOG}.1"
v="$(liveness_verdict "${LOG}" "$(epoch 2026-09-22T21:40:00Z)")"
assert_eq "a fresh rotation falls back to .1 (still sees the wedge)" wedged "$(field "$v" 1)"
rm -f "${LOG}" "${LOG}.1"
v="$(liveness_verdict "${LOG}" "$(epoch 2026-09-22T21:40:00Z)")"
assert_eq "no log at all -> absent (not unknown, not progressing)" absent "$(field "$v" 1)"
: > "${LOG}"
v="$(liveness_verdict "${LOG}" "$(epoch 2026-09-22T21:40:00Z)")"
assert_eq "an empty log -> unknown" unknown "$(field "$v" 1)"
assert_eq "no join line -> empty last-join" "" "$(liveness_last_join_epoch "${LOG}")"

# ============================================================================
echo "== dump dir: one derivation, matching the client =="
assert_eq "XDG_STATE_HOME set" "${TMP}/xdg/athena/inbox-client-dumps" "$(liveness_dump_dir)"
assert_eq "XDG_STATE_HOME empty -> ~/.local/state" "${HOME}/.local/state/athena/inbox-client-dumps" "$(XDG_STATE_HOME='' liveness_dump_dir)"
if out="$(XDG_STATE_HOME='rel/dir' liveness_dump_dir)"; then bad "a relative XDG_STATE_HOME is refused" "got [${out}]"; else ok "a relative XDG_STATE_HOME is refused (a wrongly computed key)"; fi

# ============================================================================
echo "== stale_after_s: defaults, overrides, validation =="
E='{"v":1,"repo":"/x","channels":{"l":{"kind":"log","path":"l.jsonl"},"m":{"kind":"maildir","namespace":"agent-mail/p","read":"a","write":"b","identity":"i"},"z":{"kind":"log","path":"z.jsonl","stale_after_s":0},"s":{"kind":"log","path":"s.jsonl","stale_after_s":600},"n":{"kind":"log","path":"n.jsonl","stale_after_s":null}}}'
assert_eq "log default 1800"         1800 "$(liveness_stale_after "${E}" l log)"
assert_eq "maildir default none"     null "$(liveness_stale_after "${E}" m maildir)"
assert_eq "explicit 0 disables"      null "$(liveness_stale_after "${E}" z log)"
assert_eq "explicit null disables"   null "$(liveness_stale_after "${E}" n log)"
assert_eq "explicit 600"             600  "$(liveness_stale_after "${E}" s log)"
if descriptor_validate "${E}" 2>/dev/null; then ok "descriptor accepts stale_after_s on both kinds"; else bad "descriptor accepts stale_after_s on both kinds" "$(descriptor_validate "${E}" 2>&1)"; fi
for badv in '"1800"' '-5' '1.5' 'true'; do
  D="{\"v\":1,\"repo\":\"/x\",\"channels\":{\"l\":{\"kind\":\"log\",\"path\":\"l.jsonl\",\"stale_after_s\":${badv}}}}"
  err="$(descriptor_validate "${D}" 2>&1 >/dev/null)"; rc=$?
  if [ "${rc}" -ne 0 ] && grep -q 'Fix:' <<<"${err}"; then ok "stale_after_s ${badv} is refused with a Fix:"; else bad "stale_after_s ${badv} is refused with a Fix:" "rc=${rc} err=${err}"; fi
done

# ============================================================================
echo "== end to end: inbox-status / read-inbox on a 94-min-stale channel =="
export ATHENA_INBOX_ROOT="${TMP}/root"
mkdir -p "${ATHENA_INBOX_ROOT}/projects"; chmod 700 "${ATHENA_INBOX_ROOT}" "${ATHENA_INBOX_ROOT}/projects"
REPO="${TMP}/repo"; git init -q "${REPO}"
KEY="$(cd "${REPO}" && realpath "$(git rev-parse --git-common-dir)")"
jq -n --arg r "${KEY}" '{v:1, repo:$r, channels:{slack:{kind:"log", path:"p-slack.jsonl"}, fresh:{kind:"log", path:"p-fresh.jsonl"}, quiet:{kind:"log", path:"p-quiet.jsonl", stale_after_s:0}}}' \
  > "${ATHENA_INBOX_ROOT}/projects/p.json"
chmod 600 "${ATHENA_INBOX_ROOT}/projects/p.json"
NOW="$(date -u +%s)"
# Each channel holds one DELIVERED line, already read (offset at EOF), so the
# count is zero and the age is the inbox file's -- an empty file is not a
# delivery (DND-937).
LINE0='{"v":1,"received_at":"2026-09-01T22:10:00Z","channel":"D01","ts":"1788.0000","event_id":"Ev0","text":"zero"}'
seed_read() {
  printf '%s\n' "${LINE0}" > "${ATHENA_INBOX_ROOT}/p-$1.jsonl"
  printf '{"offset":%s}\n' "$(wc -c < "${ATHENA_INBOX_ROOT}/p-$1.jsonl" | tr -d ' ')" > "${ATHENA_INBOX_ROOT}/p-$1.state.json"
  chmod 600 "${ATHENA_INBOX_ROOT}/p-$1.jsonl" "${ATHENA_INBOX_ROOT}/p-$1.state.json"
}
for c in slack fresh quiet; do
  seed_read "${c}"; : > "${ATHENA_INBOX_ROOT}/p-${c}.event"
  chmod 600 "${ATHENA_INBOX_ROOT}/p-${c}.event"
done
touch -d "@$(( NOW - 94*60 ))" "${ATHENA_INBOX_ROOT}/p-slack.jsonl" "${ATHENA_INBOX_ROOT}/p-slack.event"
touch -d "@$(( NOW - 94*60 ))" "${ATHENA_INBOX_ROOT}/p-quiet.jsonl" "${ATHENA_INBOX_ROOT}/p-quiet.event"
touch -d "@$(( NOW - 60 ))"    "${ATHENA_INBOX_ROOT}/p-fresh.jsonl" "${ATHENA_INBOX_ROOT}/p-fresh.event"
printf '%s INFO joined machine:self; instances: []\n' "$(date -u -d "@$(( NOW - 180 ))" +%Y-%m-%dT%H:%M:%SZ)" > "${LOG}"

out="$(cd "${REPO}" && "${SKILL}/bin/inbox-status" 2>&1)"; rc=$?
assert_eq "inbox-status exits 0" 0 "${rc}"
assert_contains "the 94-min-stale channel prints STALE (acceptance)" "slack — STALE: last delivery 94m ago (threshold 30m); client last joined 3m ago." "${out}"
assert_contains "the STALE line carries a Fix:" "Fix: quiet and dark look the same" "${out}"
assert_not_contains "a fresh quiet channel still prints nothing" "fresh" "${out}"
assert_not_contains "stale_after_s 0 disables STALE for that channel" "quiet —" "${out}"

J="$(cd "${REPO}" && "${SKILL}/bin/inbox-status" --json)"
assert_eq "--json: slack stale"       true   "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .stale')"
assert_eq "--json: slack age basis"   inbox "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .age_basis')"
assert_eq "--json: slack threshold"   1800   "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .stale_after_s')"
assert_eq "--json: fresh not stale"   false  "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="fresh") | .stale')"
JA="$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="fresh") | .last_join_age_s')"
if [ "${JA}" -ge 180 ] && [ "${JA}" -le 200 ]; then ok "--json: last join age ~180s"; else bad "--json: last join age ~180s" "got ${JA}"; fi

# The age is the inbox file's (its last append), never the doorbell's
# (DND-937): a doorbell touched NOW leaves the stale channel stale, and a new
# append makes it fresh.
touch -d "@${NOW}" "${ATHENA_INBOX_ROOT}/p-slack.event"
J="$(cd "${REPO}" && "${SKILL}/bin/inbox-status" --json)"
assert_eq "a doorbell touched now does not freshen a stale channel" true "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .stale')"
touch -d "@$(( NOW - 94*60 ))" "${ATHENA_INBOX_ROOT}/p-slack.event"
touch -d "@$(( NOW - 30 ))" "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
J="$(cd "${REPO}" && "${SKILL}/bin/inbox-status" --json)"
assert_eq "a recent append is the age source" inbox "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .age_basis')"
assert_eq "... and the channel is no longer stale" false "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .stale')"
touch -d "@$(( NOW - 94*60 ))" "${ATHENA_INBOX_ROOT}/p-slack.jsonl"

out="$(cd "${REPO}" && "${SKILL}/bin/read-inbox" --peek slack 2>&1)"
assert_contains "read-inbox: nothing new; STALE (R2)" "slack — nothing new; STALE: last delivery 94m ago (threshold 30m); client last joined 3m ago." "${out}"
out="$(cd "${REPO}" && "${SKILL}/bin/read-inbox" --peek fresh 2>&1)"
assert_contains "read-inbox: a fresh channel prints its ages" "fresh — nothing new. Last delivery" "${out}"
assert_not_contains "read-inbox: a fresh channel is not STALE" "STALE" "${out}"

# A STALE line must not swallow the warnings a channel already had: new mail
# with an unreadable line, and an unreadable state file, keep their notes.
printf '%s\n%s\n' '{"v":1,"received_at":"2026-09-01T22:10:01Z","channel":"D01","ts":"1788.0001","event_id":"Ev1","text":"one"}' 'not json' \
  > "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
printf 'not-json-state' > "${ATHENA_INBOX_ROOT}/p-slack.state.json"; chmod 600 "${ATHENA_INBOX_ROOT}/p-slack.state.json"
touch -d "@$(( NOW - 94*60 ))" "${ATHENA_INBOX_ROOT}/p-slack.jsonl" "${ATHENA_INBOX_ROOT}/p-slack.event"
out="$(cd "${REPO}" && "${SKILL}/bin/inbox-status" 2>/dev/null)"
assert_contains "STALE with new mail keeps the (+N unreadable) note" "slack — 1 new (+1 unreadable), STALE" "${out}"
assert_contains "STALE with new mail keeps the unreadable-state Fix:" "counts are NOT deduped" "${out}"
seed_read slack
touch -d "@$(( NOW - 94*60 ))" "${ATHENA_INBOX_ROOT}/p-slack.jsonl" "${ATHENA_INBOX_ROOT}/p-slack.event"

# A FAILED freshness measurement must never read as a healthy quiet channel.
# A stat shim fails the mtime read of every .jsonl inbox file (the delivered
# content exists, its age cannot be read).
SHIM="${TMP}/statshim"; mkdir -p "${SHIM}"
REAL_STAT="$(command -v stat)"
cat > "${SHIM}/stat" <<SHIMEOF
#!/usr/bin/env bash
last="\${@: -1}"
case "\$*" in *%Y*) case "\${last}" in *.jsonl) echo "stat: cannot stat" >&2; exit 1 ;; esac ;; esac
exec "${REAL_STAT}" "\$@"
SHIMEOF
chmod +x "${SHIM}/stat"
out="$(cd "${REPO}" && PATH="${SHIM}:${PATH}" "${SKILL}/bin/inbox-status" 2>&1)"
assert_contains "inbox-status: a failed freshness measurement prints a fault line, even at zero new" "fresh — freshness could NOT be determined" "${out}"
assert_contains "... with a Fix: naming the doctor" "Fix: run inbox-doctor (freshness:fresh)" "${out}"
J="$(cd "${REPO}" && PATH="${SHIM}:${PATH}" "${SKILL}/bin/inbox-status" --json 2>/dev/null)"
assert_eq "--json: freshness_error true" true "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="fresh") | .freshness_error')"
out="$(cd "${REPO}" && PATH="${SHIM}:${PATH}" "${SKILL}/bin/read-inbox" --peek fresh 2>&1)"
assert_contains "read-inbox: a failed freshness measurement says so, never a bare 'nothing new'" "nothing new (freshness could not be determined; run inbox-doctor)" "${out}"
BADE='{"v":1,"repo":"/x","channels":{"l":{"kind":"log","path":"l.jsonl"}}}'
RES="$(printf 'kind\tlog\ninbox\t%s\ndoorbell\t%s\n' "${ATHENA_INBOX_ROOT}/p-fresh.jsonl" "${ATHENA_INBOX_ROOT}/p-fresh.event")"
if PATH="${SHIM}:${PATH}" liveness_channel_freshness "${BADE}" l "${RES}" >/dev/null 2>&1; then
  bad "liveness_channel_freshness: an existing but unmeasurable inbox file is an error" "status 0"
else
  ok "liveness_channel_freshness: an existing but unmeasurable inbox file is an error (not 'never delivered')"
fi
out="$(cd "${REPO}" && "${SKILL}/bin/read-inbox" --peek fresh 2>&1)"
assert_contains "read-inbox: a fresh channel prints HUMAN ages" "; client last joined 3m ago." "${out}"


# ============================================================================
echo "== DND-937: a doorbell is never a delivery; age comes from delivered content =="
# On 2026-09-26 inbox-doctor graded `ok freshness:slack ... last delivery
# 257090s ago (doorbell mtime)` while custom-slack.jsonl did not exist: inbox-wait
# had PROVISIONED the .event, and its creation read as a delivery. Every case
# below pins a doorbell touched NOW, so a doorbell-based age would read fresh.
FR="${TMP}/fr"; mkdir -p "${FR}/md/in/.acked" "${FR}/md/out"; chmod 700 "${FR}"
NOW="$(date -u +%s)"
M94=$(( NOW - 5640 ))
E1='{"v":1,"repo":"/x","channels":{"l":{"kind":"log","path":"l.jsonl"},"m":{"kind":"maildir","read":"in","write":"out","stale_after_s":3600}}}'
LRES="$(printf 'kind\tlog\ninbox\t%s\nstate\t%s\ndoorbell\t%s\n' "${FR}/l.jsonl" "${FR}/l.state.json" "${FR}/l.event")"
MRES="$(printf 'kind\tmaildir\nread_dir\t%s\nack_dir\t%s\nread_doorbell\t%s\n' "${FR}/md/in" "${FR}/md/in/.acked" "${FR}/md/in/.event")"
fr_field() { printf '%s' "$1" | jq -r "$2"; }
: > "${FR}/l.event"; touch -d "@${NOW}" "${FR}/l.event"

# (1) THE ACCEPTANCE CASE: a touched doorbell, no channel file at all.
F="$(liveness_channel_freshness "${E1}" l "${LRES}" "${NOW}")"; rc=$?
assert_eq "doorbell only, no inbox file: measured (status 0)" 0 "${rc}"
assert_eq "doorbell only, no inbox file: NO delivery age (never fresh)" null "$(fr_field "${F}" .last_delivery_age_s)"
assert_eq "doorbell only, no inbox file: basis none" none "$(fr_field "${F}" .age_basis)"

# (2) a touched doorbell with an EMPTY channel file -- still nothing delivered.
: > "${FR}/l.jsonl"; touch -d "@${NOW}" "${FR}/l.jsonl" "${FR}/l.event"
F="$(liveness_channel_freshness "${E1}" l "${LRES}" "${NOW}")"
assert_eq "touched doorbell + EMPTY channel file: NO delivery age" null "$(fr_field "${F}" .last_delivery_age_s)"
assert_eq "touched doorbell + EMPTY channel file: basis none" none "$(fr_field "${F}" .age_basis)"

# (3) a real delivery 94 minutes ago and a doorbell re-provisioned NOW: the
# doorbell must not hide the staleness.
printf '{"v":1}\n' > "${FR}/l.jsonl"; touch -d "@${M94}" "${FR}/l.jsonl"; touch -d "@${NOW}" "${FR}/l.event"
F="$(liveness_channel_freshness "${E1}" l "${LRES}" "${NOW}")"
assert_eq "delivered 94m ago, doorbell touched now: age is the inbox file's" 5640 "$(fr_field "${F}" .last_delivery_age_s)"
assert_eq "... basis inbox" inbox "$(fr_field "${F}" .age_basis)"
assert_eq "... STALE (the re-provisioned doorbell does not rescue it)" true "$(fr_field "${F}" .stale)"
assert_eq "... an exact age, not a lower bound" false "$(fr_field "${F}" .age_is_lower_bound)"

# (4) rotated, nothing since: the last delivery predates rotated_at, so the age
# is a LOWER BOUND from the rotation, never the (fresh) doorbell.
rm -f "${FR}/l.jsonl"; printf '{"v":1}\n' > "${FR}/l.jsonl.1"; touch -d "@${NOW}" "${FR}/l.jsonl.1" "${FR}/l.event"
printf '{"offset":0,"rotated_at":"%s"}\n' "$(date -u -d "@$(( NOW - 7200 ))" +%Y-%m-%dT%H:%M:%SZ)" > "${FR}/l.state.json"
F="$(liveness_channel_freshness "${E1}" l "${LRES}" "${NOW}")"
assert_eq "rotated, nothing since: age from rotated_at" 7200 "$(fr_field "${F}" .last_delivery_age_s)"
assert_eq "... basis rotation" rotation "$(fr_field "${F}" .age_basis)"
assert_eq "... flagged a lower bound" true "$(fr_field "${F}" .age_is_lower_bound)"
assert_eq "... STALE past the threshold" true "$(fr_field "${F}" .stale)"
# and with an empty live file beside it (nothing since the rotation)
: > "${FR}/l.jsonl"; touch -d "@${NOW}" "${FR}/l.jsonl"
F="$(liveness_channel_freshness "${E1}" l "${LRES}" "${NOW}")"
assert_eq "rotated + EMPTY live file: still the rotation lower bound" rotation "$(fr_field "${F}" .age_basis)"

# (5) rotated but no usable rotated_at: content exists and cannot be aged --
# "could not look" (status 1), never "never delivered".
printf '{"offset":0}\n' > "${FR}/l.state.json"
if liveness_channel_freshness "${E1}" l "${LRES}" "${NOW}" >/dev/null 2>&1; then
  bad "rotated with no rotated_at is a failed measurement (status 1)" "status 0"
else
  ok "rotated with no rotated_at is a failed measurement (status 1), not 'never delivered'"
fi
rm -f "${FR}/l.jsonl" "${FR}/l.jsonl.1" "${FR}/l.state.json"

# (6) an unsearchable channel directory is "could not look", not "found nothing".
LRX="$(printf 'kind\tlog\ninbox\t%s\nstate\t%s\ndoorbell\t%s\n' "${FR}/locked/l.jsonl" "${FR}/locked/l.state.json" "${FR}/locked/l.event")"
mkdir -p "${FR}/locked"; chmod 000 "${FR}/locked"
if [ -x "${FR}/locked" ]; then
  ok "unsearchable channel dir: skipped (running with CAP_DAC_OVERRIDE)"
elif liveness_channel_freshness "${E1}" l "${LRX}" "${NOW}" >/dev/null 2>&1; then
  bad "an unsearchable channel directory is a failed measurement" "status 0"
else
  ok "an unsearchable channel directory is a failed measurement, not 'never delivered'"
fi
chmod 700 "${FR}/locked"

# (7) maildir: the read-side doorbell touched now, no message -> no age.
: > "${FR}/md/in/.event"; touch -d "@${NOW}" "${FR}/md/in/.event"
F="$(liveness_channel_freshness "${E1}" m "${MRES}" "${NOW}")"
assert_eq "maildir, doorbell only: NO delivery age" null "$(fr_field "${F}" .last_delivery_age_s)"
# a message acked 2h ago is the newest delivery; the doorbell does not count.
printf 'x\n' > "${FR}/md/in/.acked/20260901T000000Z-001-a.md"; touch -d "@$(( NOW - 7200 ))" "${FR}/md/in/.acked/20260901T000000Z-001-a.md"
F="$(liveness_channel_freshness "${E1}" m "${MRES}" "${NOW}")"
assert_eq "maildir: age is the newest message file's (acked counts)" 7200 "$(fr_field "${F}" .last_delivery_age_s)"
assert_eq "... basis message" message "$(fr_field "${F}" .age_basis)"
assert_eq "... STALE past its 3600s threshold" true "$(fr_field "${F}" .stale)"
printf 'y\n' > "${FR}/md/in/20260901T000100Z-002-b.md"; touch -d "@$(( NOW - 60 ))" "${FR}/md/in/20260901T000100Z-002-b.md"
F="$(liveness_channel_freshness "${E1}" m "${MRES}" "${NOW}")"
assert_eq "maildir: an unread message 60s old is the newest" 60 "$(fr_field "${F}" .last_delivery_age_s)"


# (8) end to end: a rotated channel with nothing since prints its age as a
# FLOOR, and a channel with nothing on disk prints no delivery age at all.
rm -f "${ATHENA_INBOX_ROOT}/p-fresh.jsonl"; printf '%s\n' "${LINE0}" > "${ATHENA_INBOX_ROOT}/p-fresh.jsonl.1"
printf '{"offset":0,"rotated_at":"%s"}\n' "$(date -u -d "@$(( NOW - 7200 ))" +%Y-%m-%dT%H:%M:%SZ)" > "${ATHENA_INBOX_ROOT}/p-fresh.state.json"
chmod 600 "${ATHENA_INBOX_ROOT}/p-fresh.jsonl.1" "${ATHENA_INBOX_ROOT}/p-fresh.state.json"
touch -d "@${NOW}" "${ATHENA_INBOX_ROOT}/p-fresh.event"
out="$(cd "${REPO}" && "${SKILL}/bin/inbox-status" 2>&1)"
assert_contains "inbox-status: a rotated channel's age is a floor" "fresh — STALE: last delivery at least 2h0m ago (threshold 30m)" "${out}"
# An EMPTY live file beside the `.1`: read-inbox (like inbox-status's count)
# still flags an ABSENT live file as never-delivered even when `.1` exists --
# a separate defect, proposed as its own ticket in the DND-937 report.
: > "${ATHENA_INBOX_ROOT}/p-fresh.jsonl"; chmod 600 "${ATHENA_INBOX_ROOT}/p-fresh.jsonl"
out="$(cd "${REPO}" && "${SKILL}/bin/read-inbox" --peek fresh 2>&1)"
assert_contains "read-inbox: a rotated channel's age is a floor" "fresh — nothing new; STALE: last delivery at least 2h0m ago" "${out}"
: > "${ATHENA_INBOX_ROOT}/p-quiet.jsonl"; rm -f "${ATHENA_INBOX_ROOT}/p-quiet.state.json"; touch -d "@${NOW}" "${ATHENA_INBOX_ROOT}/p-quiet.event"
out="$(cd "${REPO}" && "${SKILL}/bin/read-inbox" --peek quiet 2>&1)"
assert_contains "read-inbox: no delivery on disk -> no delivery age, a clean join clause" "quiet — nothing new. Client last joined 3m ago." "${out}"
assert_not_contains "read-inbox: the doorbell touched now is never a delivery age" "Last delivery" "${out}"

printf '\nliveness self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
