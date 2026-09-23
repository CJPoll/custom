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
for c in slack fresh quiet; do
  printf '' > "${ATHENA_INBOX_ROOT}/p-${c}.jsonl"; : > "${ATHENA_INBOX_ROOT}/p-${c}.event"
  chmod 600 "${ATHENA_INBOX_ROOT}/p-${c}.jsonl" "${ATHENA_INBOX_ROOT}/p-${c}.event"
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
assert_eq "--json: slack age basis"   doorbell "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .age_basis')"
assert_eq "--json: slack threshold"   1800   "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .stale_after_s')"
assert_eq "--json: fresh not stale"   false  "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="fresh") | .stale')"
JA="$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="fresh") | .last_join_age_s')"
if [ "${JA}" -ge 180 ] && [ "${JA}" -le 200 ]; then ok "--json: last join age ~180s"; else bad "--json: last join age ~180s" "got ${JA}"; fi

# The doorbell is the age source; a newer inbox file (late-provisioned bell)
# wins, because the age is of the LAST delivery.
touch -d "@$(( NOW - 30 ))" "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
J="$(cd "${REPO}" && "${SKILL}/bin/inbox-status" --json)"
assert_eq "a newer inbox file wins over an older doorbell" inbox "$(printf '%s' "${J}" | jq -r '.channels[] | select(.name=="slack") | .age_basis')"
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
rm -f "${ATHENA_INBOX_ROOT}/p-slack.state.json"; : > "${ATHENA_INBOX_ROOT}/p-slack.jsonl"
touch -d "@$(( NOW - 94*60 ))" "${ATHENA_INBOX_ROOT}/p-slack.jsonl" "${ATHENA_INBOX_ROOT}/p-slack.event"

# A FAILED freshness measurement must never read as a healthy quiet channel.
# A stat shim fails the mtime read of every .event doorbell (the file exists,
# its age cannot be read).
SHIM="${TMP}/statshim"; mkdir -p "${SHIM}"
REAL_STAT="$(command -v stat)"
cat > "${SHIM}/stat" <<SHIMEOF
#!/usr/bin/env bash
last="\${@: -1}"
case "\$*" in *%Y*) case "\${last}" in *.event) echo "stat: cannot stat" >&2; exit 1 ;; esac ;; esac
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
  bad "liveness_channel_freshness: an existing but unmeasurable doorbell is an error" "status 0"
else
  ok "liveness_channel_freshness: an existing but unmeasurable doorbell is an error (not 'never delivered')"
fi
out="$(cd "${REPO}" && "${SKILL}/bin/read-inbox" --peek fresh 2>&1)"
assert_contains "read-inbox: a fresh channel prints HUMAN ages" "; client last joined 3m ago." "${out}"

printf '\nliveness self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
