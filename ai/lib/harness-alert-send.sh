# shellcheck shell=bash
# harness-alert-send.sh -- send ONE harness-alerts message and confirm it was
# delivered (DND-1513). Sourced by every harness-alerts sender:
#   ai/bin/main-health, ai/bin/slack-roots-tick, scripts/athena-shipwright-run.sh,
#   scripts/athena-clustering-run.sh, scripts/athena-leadtime-run.sh,
#   scripts/inbox-client-alert.
#
# The rule: a send is DELIVERED only when send-mail exits 0 AND prints its
# `athena:inbox: delivered <name>` line. send-mail's local path prints that line
# on every delivery (ai/skills/athena:inbox/bin/send-mail), so exit 0 with no
# such line is not a delivery we can name: a changed or broken send-mail, a
# wrapper, or lost output. Each sender used to record that case as sent
# (`alert=?`, `(delivered; name not reported)`, `sent ?`) and never retried, so
# an alert could be lost for its whole episode with nothing saying so. A
# duplicate alert is loud; a lost one is silent. So an unconfirmed send is a
# FAILED send, and the caller's episode stays open and retries.
#
# Side-effect code (it runs send-mail). The parse is a separate pure function,
# harness_alert_delivered_name, so it can be tested on its own.

# harness_alert_delivered_name <send-mail output> : prints the delivered
# message name and returns 0, or prints nothing and returns 5 when the output
# carries no `athena:inbox: delivered <name>` line.
harness_alert_delivered_name() {
  local name
  name="$(printf '%s\n' "$1" | sed -n 's/^athena:inbox: delivered //p' | tail -n 1)"
  [ -n "${name}" ] || return 5
  printf '%s\n' "${name}"
}

# harness_alert_deliver <send-mail> <repo> <timeout-secs> <attempts> <send-mail args...>
#
# Runs `<send-mail> <args...>` from <repo> (send-mail resolves the channel from
# the registry entry of its cwd's repo), bounded by <timeout-secs>. A refusal
# because the channel's other writer holds the sender lock ("already sending
# on") is retried, up to <attempts> runs in all, 2 s apart; any other failure
# is not. Before each retry it calls the shell function named by
# HARNESS_ALERT_ON_BUSY, if that names a defined function, with
# "<attempt>/<attempts>". Anything else in it is ignored, never executed.
#
# Prints the delivered message name on stdout. Returns:
#   0  delivered (the name is printed)
#   4  <send-mail> is missing or not executable
#   5  send-mail exited 0 but printed no delivered line: NOT sent
#   n  send-mail's own non-zero exit (124 = the timeout)
# Every non-zero return writes the reason on stderr; the caller prints the
# Fix: that fits its own retry path.
harness_alert_deliver() {
  local sm="$1" repo="$2" secs="$3" attempts="$4" out rc attempt=0
  shift 4
  if [ ! -x "${sm}" ]; then
    echo "send-mail is missing: ${sm}" >&2
    return 4
  fi
  while :; do
    attempt=$(( attempt + 1 )); rc=0
    out="$(cd -- "${repo}" && timeout "${secs}" "${sm}" "$@" 2>&1)" || rc=$?
    if [ "${rc}" -eq 0 ] || [ "${attempt}" -ge "${attempts}" ] || ! grep -q 'already sending on' <<<"${out}"; then
      break
    fi
    if [ -n "${HARNESS_ALERT_ON_BUSY:-}" ] && declare -F "${HARNESS_ALERT_ON_BUSY}" >/dev/null; then
      "${HARNESS_ALERT_ON_BUSY}" "${attempt}/${attempts}"
    fi
    sleep 2
  done
  if [ "${rc}" -ne 0 ]; then
    printf '%s\n' "${out}" | head -n 3 >&2
    return "${rc}"
  fi
  harness_alert_delivered_name "${out}" && return 0
  echo "send-mail exited 0 but printed no 'athena:inbox: delivered' line, so nothing was confirmed sent" >&2
  return 5
}
