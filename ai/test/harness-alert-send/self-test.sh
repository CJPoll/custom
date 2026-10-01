#!/usr/bin/env bash
# Self-test for ai/lib/harness-alert-send.sh (DND-1513).
#
# The gap this pins: every harness-alerts sender recorded "send-mail exited 0
# but printed no delivered line" as SENT (alert=?, "(delivered; name not
# reported)", "sent ?") and never retried, so an alert could be lost for a
# whole episode. The shared helper reads that case as NOT sent (return 5).
#
# Hermetic: send-mail is a stub script in a temp dir; nothing live is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=../../lib/harness-alert-send.sh
. "${AI_DIR}/lib/harness-alert-send.sh"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# The stub's behaviour is the file ${T}/mode: ok | quiet | fail | busy-then-ok.
cat > "${T}/send-mail" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "${d}/calls"; pwd -P > "${d}/cwd"
n="$(grep -c . "${d}/calls")"
case "$(cat "${d}/mode")" in
  ok)    echo "athena:inbox: path: local -- stub"; echo "athena:inbox: delivered 0001-stub.md" ;;
  quiet) echo "athena:inbox: path: local -- stub" ;;
  fail)  echo "send-mail: simulated refusal" >&2; exit 3 ;;
  busy-then-ok)
    if [ "${n}" -lt 2 ]; then echo "athena:inbox: already sending on harness-alerts" >&2; exit 1; fi
    echo "athena:inbox: delivered 0002-after-busy.md" ;;
esac
EOF
chmod +x "${T}/send-mail"
mkdir -p "${T}/repo"
calls() { [ -f "${T}/calls" ] && grep -c . "${T}/calls" || echo 0; }
send() { # send <attempts> -> OUT ERR RC
  rm -f "${T}/calls"
  OUT="$(harness_alert_deliver "${T}/send-mail" "${T}/repo" 20 "$1" --local harness-alerts-detector slug --to custom 2>"${T}/err")"
  RC=$?; ERR="$(cat "${T}/err")"
}

echo "harness-alert-send self-test"
echo

echo "--- the parse ---"
n="$(harness_alert_delivered_name $'athena:inbox: path: local\nathena:inbox: delivered 0009-x.md')"; rc=$?
[ "${rc}" = 0 ] && [ "${n}" = 0009-x.md ] && ok "1. a delivered line yields its name" || bad "1. parse hit" "rc=${rc} n='${n}'"
n="$(harness_alert_delivered_name 'athena:inbox: path: local')"; rc=$?
[ "${rc}" = 5 ] && [ -z "${n}" ] && ok "2. no delivered line: return 5, no name (never '?')" || bad "2. parse miss" "rc=${rc} n='${n}'"
n="$(harness_alert_delivered_name '')"; rc=$?
[ "${rc}" = 5 ] && [ -z "${n}" ] && ok "3. empty output: return 5" || bad "3. parse empty" "rc=${rc} n='${n}'"

echo "--- the send ---"
echo ok > "${T}/mode"; send 1
[ "${RC}" = 0 ] && [ "${OUT}" = 0001-stub.md ] && [ "$(cat "${T}/cwd")" = "$(cd "${T}/repo" && pwd -P)" ] \
  && [ "$(cat "${T}/calls")" = "--local harness-alerts-detector slug --to custom" ] \
  && ok "4. delivered: exit 0, prints the name, runs from <repo> with the args as given" \
  || bad "4. delivered" "rc=${RC} out='${OUT}' cwd=$(cat "${T}/cwd") calls=$(cat "${T}/calls")"

echo quiet > "${T}/mode"; send 3
[ "${RC}" = 5 ] && [ -z "${OUT}" ] && [[ "${ERR}" == *"no 'athena:inbox: delivered' line"* ]] && [ "$(calls)" = 1 ] \
  && ok "5. exit 0 with no delivered line: return 5, no name, says why, not retried in-call" \
  || bad "5. quiet send" "rc=${RC} out='${OUT}' err='${ERR}' calls=$(calls)"

echo fail > "${T}/mode"; send 3
[ "${RC}" = 3 ] && [ -z "${OUT}" ] && [[ "${ERR}" == *"simulated refusal"* ]] && [ "$(calls)" = 1 ] \
  && ok "6. send-mail fails: its exit code, its words on stderr, no retry for a non-busy failure" \
  || bad "6. failed send" "rc=${RC} out='${OUT}' err='${ERR}' calls=$(calls)"

busy_note() { printf '%s\n' "$1" >> "${T}/busy"; }
echo busy-then-ok > "${T}/mode"; rm -f "${T}/busy"
HARNESS_ALERT_ON_BUSY=busy_note send 3
[ "${RC}" = 0 ] && [ "${OUT}" = 0002-after-busy.md ] && [ "$(calls)" = 2 ] && [ "$(cat "${T}/busy")" = 1/3 ] \
  && ok "7. a sender-lock refusal is retried, and HARNESS_ALERT_ON_BUSY hears each retry" \
  || bad "7. busy retry" "rc=${RC} out='${OUT}' calls=$(calls) busy=$(cat "${T}/busy" 2>&1)"

echo busy-then-ok > "${T}/mode"; send 1
[ "${RC}" = 1 ] && [ "$(calls)" = 1 ] && ok "8. attempts=1: a busy refusal is returned, not retried" \
  || bad "8. attempts 1" "rc=${RC} calls=$(calls)"

OUT="$(harness_alert_deliver "${T}/no-such-send-mail" "${T}/repo" 20 1 x 2>"${T}/err")"; RC=$?
[ "${RC}" = 4 ] && [[ "$(cat "${T}/err")" == *"send-mail is missing"* ]] \
  && ok "9. a missing send-mail: return 4, named" || bad "9. missing" "rc=${RC} err=$(cat "${T}/err")"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
