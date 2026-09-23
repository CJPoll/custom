# wedge-fixture.bash — synthetic capture directories and harness-alerts
# messages for the DND-334 suites (scripts/test/inbox-client-alert/self-test.sh
# and ai/skills/athena:inbox-attend/test/self-test.sh). Sourced, never run.
#
# A synthetic capture has the exact LV-2 layout (capture.txt, dump.txt,
# signature.txt) with an LV-1-shaped dump (the same shape as
# scripts/test/inbox-client-capture/mock-athena-inbox-client.rb writes). Its
# signature is computed through lib/wedge.sh — the one algorithm the capture
# uses (proven against a real capture in the capture suite, case C-1) and the
# verifier recomputes.
#
# Requires: WF_REPO (the checkout root) set by the sourcing suite.

# shellcheck source=ai/skills/athena:inbox/lib/wedge.sh
. "${WF_REPO}/ai/skills/athena:inbox/lib/wedge.sh"

# wf_make_capture <dumps-dir> <name> <step> [top-frame-function]
# Creates <dumps-dir>/<name>/ and prints its path. The capture "finished" now.
wf_make_capture() {
  local dumps="$1" name="$2" step="$3" top="${4:-connect_nonblock}" d frames sig now_ms
  d="${dumps}/${name}"
  mkdir -p "${dumps}" && chmod 700 "${dumps}"
  mkdir -m 700 "${d}" || return 1
  cat >"${d}/dump.txt" <<EOF
== athena-inbox-client diagnostics dump ==
at: 2026-09-23T10:00:00Z
pid: 4242
current_step: ${step}
socket:
  (no active socket)
flight recorder (1 lines):
  2026-09-23T10:00:00.000Z step ${step} begin
threads (2):
  thread 0x100 status="sleep" name=nil
    /home/x/athena-inbox-client.rb:804:in \`join'
    /home/x/athena-inbox-client.rb:549:in \`with_deadline'
  thread 0x200 status="sleep" name=nil
    /home/x/athena-inbox-client.rb:804:in \`${top}'
    /home/x/athena-inbox-client.rb:870:in \`tls_handshake'
    /home/x/athena-inbox-client.rb:804:in \`block in open_transport'
    /home/x/athena-inbox-client.rb:793:in \`block in step'
    /home/x/athena-inbox-client.rb:544:in \`block in with_deadline'
EOF
  frames="$(wedge_frames "${d}/dump.txt")"
  sig="$(wedge_signature "${step}" "${frames}")"
  now_ms="$(date -u +%s%3N)"
  {
    printf 'signature: %s\nstep: %s\nsource: dump\nframes:\n' "${sig}" "${step}"
    printf '%s\n' "${frames}" | sed 's/^/  /'
  } >"${d}/signature.txt"
  {
    printf 'inbox-client-capture (DND-333)\n'
    printf 'pid: 4242\nreason: watchdog: test\nstep: %s\ndump: present\n' "${step}"
    printf 'dump_current_step: %s\nsignature: %s\n' "${step}" "${sig}"
    printf 'redaction: token and its 8-char prefix replaced with [REDACTED]\n'
    printf 'started_ms: %s\nsigquit_ms: %s\nfinished_ms: %s\n' "${now_ms}" "${now_ms}" "${now_ms}"
    printf 'cap_bytes: 4194304 (truncation rounds: 0)\nuptime_s: 3600\n'
    printf 'reconnecting_since: 113 (last restart)\nconnected_since: 42 (last restart)\n'
  } >"${d}/capture.txt"
  chmod 600 "${d}"/*
  printf '%s\n' "${d}"
}

# wf_signature_of <capture-dir> — the signature the capture recorded.
wf_signature_of() { sed -n 's/^signature: //p' "$1/signature.txt" | head -n 1; }

# wf_make_message <dir> <capture-dir> <claimed-signature> [from] [to] [seq]
# Writes a contract-conformant harness-alerts message into <dir>; prints its path.
wf_make_message() {
  local dir="$1" cap="$2" sig="$3" from="${4:-inbox-client-detector}" to="${5:-custom}" seq="${6:-001}"
  local stamp sent name
  stamp="$(date -u +%Y%m%dT%H%M%S)"
  sent="$(date -u -d "$(printf '%s' "${stamp}" | sed -E 's/^(....)(..)(..)T(..)(..)(..)$/\1-\2-\3T\4:\5:\6Z/')" +%Y-%m-%dT%H:%M:%SZ)"
  name="${stamp}Z-${seq}-wedge-${sig:0:8}.md"
  mkdir -p "${dir}"
  {
    printf -- '---\nfrom: %s\nto: %s\nsent_at: %s\nre: %s\n---\n\n' "${from}" "${to}" "${sent}" "${cap}"
    printf 'Inbox client wedge captured by the supervisor watchdog (DND-334).\n\n'
    printf 'signature: %s\nstep: tls\ncapture: %s\n' "${sig}" "${cap}"
  } >"${dir}/${name}"
  printf '%s\n' "${dir}/${name}"
}
