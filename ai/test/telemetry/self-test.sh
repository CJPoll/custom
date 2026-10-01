#!/usr/bin/env bash
# self-test.sh -- the telemetry suite (DND-1473): ai/lib/athena_telemetry.rb
# and its CLI ai/bin/telemetry-emit. Discovered by harness-gate (every
# committed `self-test.sh` runs).
#
# Two layers, in TDD order:
#   1. the library suite (telemetry_test.rb), run through `telemetry-emit
#      --self-test` so the CLI's self-test path is exercised too;
#   2. the CLI, end to end, against a temp store (ATHENA_TELEMETRY_DIR) with
#      the clock injected (ATHENA_TELEMETRY_NOW).
# Functional only (DND-1222): no sleeps, no timing, no load. Never the real
# store: every case points ATHENA_TELEMETRY_DIR into a temp dir.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
BIN="${ROOT}/ai/bin/telemetry-emit"
LIB="${ROOT}/ai/lib/athena_telemetry.rb"
REGISTRY="${ROOT}/ai/telemetry/events.json"

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "telemetry self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -x "${BIN}" ] || { echo "telemetry self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/bin/telemetry-emit"; exit 1; }
[ -f "${LIB}" ] || { echo "telemetry self-test: FAIL -- ${LIB} is missing"; echo "  Fix: restore ai/lib/athena_telemetry.rb"; exit 1; }
[ -f "${REGISTRY}" ] || { echo "telemetry self-test: FAIL -- ${REGISTRY} is missing"; echo "  Fix: restore ai/telemetry/events.json"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; echo "  Fix: free space in TMPDIR"; exit 1; }
cleanup() { chmod -R u+rwx "${TMP}" 2>/dev/null; rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

OUT=""; ERR=""; CODE=0
# run DIR ARGS... -- the CLI with the store at DIR and a fixed clock.
run() {
  local dir="$1"; shift
  OUT="$(cd "${TMP}" && ATHENA_TELEMETRY_DIR="${dir}" ATHENA_TELEMETRY_NOW="${NOW:-2026-10-01T05:00:00.000Z}" \
        ATHENA_UNIT= /usr/bin/ruby "${BIN}" "$@" 2>"${TMP}/err" </dev/null)"
  CODE=$?
  ERR="$(cat "${TMP}/err")"
}

echo "== library"
if /usr/bin/ruby "${BIN}" --self-test >"${TMP}/lib.out" 2>&1; then
  ok "telemetry-emit --self-test: $(tail -1 "${TMP}/lib.out")"
else
  bad "telemetry-emit --self-test" "$(cat "${TMP}/lib.out")"
fi

echo "== registry"
reg="$(/usr/bin/ruby -e 'require ARGV[0]; r = AthenaTelemetry::Registry.parse(File.read(ARGV[1])); puts r.event_names.size' "${LIB}" "${REGISTRY}" 2>&1)"
case "${reg}" in
  ''|*[!0-9]*) bad "events.json parses with Registry.parse" "${reg}" ;;
  *) ok "events.json parses with Registry.parse (${reg} events)" ;;
esac

echo "== CLI"

# 1. --help: stdout, exit 0, no write.
S1="${TMP}/s1"
mkdir -p "${S1}"
run "${S1}" --help
eq "--help exits 0" "${CODE}" "0"
has "--help prints usage on stdout" "${OUT}" "Usage: telemetry-emit"
eq "--help writes nothing to stderr" "${ERR}" ""
eq "--help leaves the store empty" "$(find "${S1}" -mindepth 1 | wc -l | tr -d ' ')" "0"

# 2. --event writes a line, exit 0.
S2="${TMP}/s2/telemetry"
run "${S2}" --event harness_gate.run --duration 1.5 --attr jobs=8 --attr ok=true --unit DND-42
eq "--event exits 0" "${CODE}" "0"
eq "--event prints nothing" "${OUT}${ERR}" ""
line="$(cat "${S2}/2026-10-01.jsonl" 2>/dev/null)"
has "--event writes the event" "${line}" '"event":"harness_gate.run"'
has "--event writes the duration" "${line}" '"duration_s":1.5'
has "--event types the attrs" "${line}" '"attrs":{"jobs":8,"ok":true}'
has "--event takes --unit" "${line}" '"unit":"DND-42","unit_source":"explicit"'
has "--event stamps the injected clock" "${line}" '"at":"2026-10-01T05:00:00.000Z"'
eq "--event: dir mode 0700" "$(stat -c %a "${S2}")" "700"
eq "--event: file mode 0600" "$(stat -c %a "${S2}/2026-10-01.jsonl")" "600"

# 2b. --at, --head; a refused attr is counted, the line still written; exit 0.
S2B="${TMP}/s2b"
run "${S2B}" --event merge.landed --at 2026-10-01T04:00:00Z --head 0123456789abcdef0123456789abcdef01234567 \
  --attr via=push --attr pr=notanint --attr nope=1
eq "--event with refused attrs exits 0" "${CODE}" "0"
line="$(cat "${S2B}/2026-10-01.jsonl" 2>/dev/null)"
has "--at is the start" "${line}" '"at":"2026-10-01T04:00:00.000Z"'
has "--head is written" "${line}" '"head":"0123456789abcdef0123456789abcdef01234567"'
has "only the valid attr is kept" "${line}" '"attrs":{"via":"push"}'
counter="$(cat "${S2B}/write-failures" 2>/dev/null)"
has "attr_type is counted" "${counter}" '"attr_type":1'
has "attr_unregistered is counted" "${counter}" '"attr_unregistered":1'

# 2c. An unregistered event: nothing written, counted, exit 0.
S2C="${TMP}/s2c"
run "${S2C}" --event no.such_event
eq "unregistered event exits 0" "${CODE}" "0"
eq "unregistered event writes no day file" "$(find "${S2C}" -name '*.jsonl' | wc -l | tr -d ' ')" "0"
has "unregistered event is counted" "$(cat "${S2C}/write-failures" 2>/dev/null)" '"event_unregistered":1'

# 2d. A malformed --duration drops the event (counted), exit 0.
S2D="${TMP}/s2d"
run "${S2D}" --event telemetry.probe --duration soon
eq "malformed --duration exits 0" "${CODE}" "0"
has "malformed --duration is counted" "$(cat "${S2D}/write-failures" 2>/dev/null)" '"duration_invalid":1'

# 3. An unwritable store: exit 0, stdout unchanged, one athena-telemetry: line.
S3="${TMP}/s3"
mkdir -p "${S3}"
chmod 0500 "${S3}"
run "${S3}" --event telemetry.probe --attr note=x
eq "unwritable store: exit 0" "${CODE}" "0"
eq "unwritable store: stdout empty" "${OUT}" ""
has "unwritable store: one athena-telemetry: line" "${ERR}" "athena-telemetry:"
eq "unwritable store: exactly one stderr line" "$(printf '%s\n' "${ERR}" | wc -l | tr -d ' ')" "1"
chmod 0700 "${S3}"

# 4. --prune with an injected now: removes the old day file, prints the count.
S4="${TMP}/s4"
mkdir -p "${S4}"
for f in 2026-09-30.jsonl 2026-10-01.jsonl write-failures notes.txt; do printf 'x\n' >"${S4}/${f}"; done
NOW=2026-10-31T12:00:00Z run "${S4}" --prune --retain-days 30
eq "--prune exits 0" "${CODE}" "0"
has "--prune prints the count" "${OUT}" "pruned 1 day file(s)"
eq "--prune removed only the expired day file" "$(cd "${S4}" && command ls | sort | tr '\n' ' ')" "2026-10-01.jsonl notes.txt write-failures "

# 4b. --prune default and env retention.
mkdir -p "${TMP}/s4b"
printf 'x\n' >"${TMP}/s4b/2026-10-20.jsonl"
NOW=2026-10-31T12:00:00Z ATHENA_TELEMETRY_RETAIN_DAYS=5 run "${TMP}/s4b" --prune
eq "--prune reads ATHENA_TELEMETRY_RETAIN_DAYS" "$(find "${TMP}/s4b" -name '*.jsonl' | wc -l | tr -d ' ')" "0"
run "${TMP}/s4b" --prune --retain-days 0
eq "--retain-days 0 is a usage error" "${CODE}" "2"
has "--retain-days 0 carries Fix:" "${ERR}" "Fix:"

# 4c. --prune with no store: exit 0, says so.
run "${TMP}/absent" --prune
eq "--prune with no store exits 0" "${CODE}" "0"
has "--prune with no store says no store" "${OUT}" "no telemetry store"

# 5. --prune on an unreadable dir: non-zero, Fix:.
S5="${TMP}/s5"
mkdir -p "${S5}"
chmod 0000 "${S5}"
run "${S5}" --prune
chmod 0700 "${S5}"
eq "--prune on an unreadable store exits 1" "${CODE}" "1"
has "--prune on an unreadable store carries Fix:" "${ERR}" "Fix:"

# 6. --stats: no store (exit 3, could not look) vs an empty store (0 events).
run "${TMP}/absent" --stats
eq "--stats with no store exits 3" "${CODE}" "3"
has "--stats with no store says COULD NOT LOOK" "${ERR}" "COULD NOT LOOK"
has "--stats with no store carries Fix:" "${ERR}" "Fix:"
lacks "--stats with no store never says 0 events" "${OUT}${ERR}" "0 events"
mkdir -p "${TMP}/s6"
run "${TMP}/s6" --stats
eq "--stats on an empty store exits 0" "${CODE}" "0"
has "--stats on an empty store says 0 events" "${OUT}" "ok_empty -- 0 events"
run "${S2}" --stats
eq "--stats with events exits 0" "${CODE}" "0"
has "--stats counts per event" "${OUT}" "event harness_gate.run: 1"
has "--stats shows the latest line" "${OUT}" '"event":"harness_gate.run"'
has "--stats reports zero failures" "${OUT}" "write-failures: none"
run "${S2B}" --stats
has "--stats reports the failures counter" "${OUT}" "write-failures: attr_type=1 attr_unregistered=1"
run "${S2}" --stats --since 2026-10-02T00:00:00Z
has "--stats --since filters" "${OUT}" "ok_empty -- 0 events"

# 6b. --stats misses: an unreadable day file and a relative store path.
S6B="${TMP}/s6b"
run "${S6B}" --event telemetry.probe
chmod 0000 "${S6B}/2026-10-01.jsonl"
run "${S6B}" --stats
chmod 0600 "${S6B}/2026-10-01.jsonl"
eq "--stats with an unreadable day file exits 3" "${CODE}" "3"
has "--stats with an unreadable day file says incomplete" "${OUT}" "status: incomplete"
has "--stats with an unreadable day file names it, with Fix:" "${ERR}" "2026-10-01.jsonl"
run relative/telemetry --stats
eq "--stats with a relative store path exits 3" "${CODE}" "3"
has "--stats with a relative store path names the seam" "${ERR}" "ATHENA_TELEMETRY_DIR is not an absolute path"
has "--stats with a relative store path carries Fix:" "${ERR}" "Fix:"

# 7. Usage errors: exit 2, Fix:.
run "${S1}" --event telemetry.probe --attr note=a --attr note=b
eq "a repeated --attr key exits 2" "${CODE}" "2"
run "${S1}" --bogus
eq "an unknown flag exits 2" "${CODE}" "2"
has "an unknown flag carries Fix:" "${ERR}" "Fix:"
run "${S1}"
eq "no mode exits 2" "${CODE}" "2"
run "${S1}" --stats --prune
eq "two modes exit 2" "${CODE}" "2"
run "${S1}" --event telemetry.probe --attr novalue
eq "--attr without = exits 2" "${CODE}" "2"
run "${S1}" --stats --duration 3
eq "a flag from another mode exits 2" "${CODE}" "2"
run "${S1}" --stats --since yesterday
eq "--since that is not ISO 8601 exits 2" "${CODE}" "2"
eq "usage errors write nothing" "$(find "${S1}" -mindepth 1 | wc -l | tr -d ' ')" "0"

echo
echo "telemetry self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read the FAIL lines above; the contract is ai/contracts/athena-telemetry.md."
  exit 1
fi
exit 0
