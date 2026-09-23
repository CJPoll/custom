#!/usr/bin/env bash
# doctor.sh -- the liveness logic behind bin/inbox-doctor.
#
# WHY THIS FILE EXISTS. The Slack -> Athena delivery chain fails by SILENCE: a
# dead client and a quiet Slack look identical from inside a session, the server
# drops an unrouted event without a row, and a config override that names an
# instance the server never sends is looked up, missed, and delivered
# elsewhere with no error. `inbox-doctor` is the one owner-invoked place that
# LOOKS at every link and says which one is dark. This file is its logic.
#
# THE FOUR STATES ARE THE WHOLE POINT (architect D12). A check reports one of:
#
#   ok    -- the link is healthy.
#   warn  -- a fault that is not fatal to the run but the owner should see.
#   fail  -- a fault that makes the exit code non-zero.
#   na    -- COULD NOT RUN. No root, no projects/, no client config, a channel
#            never provisioned, no API token. `na` is NOT `ok`: a doctor that
#            printed `ok` because the root was missing is the lost-input silence
#            wearing a diagnostic's coat. `na` is never counted as `ok` in the
#            summary, and it never sets the exit code.
#
# READ-ONLY, ABSOLUTELY (the ticket's hard constraint). Nothing here acks,
# advances an offset, rotates, sweeps, fixes a mode, or reaps a lock. A dead-pid
# lock is REPORTED as reapable and left exactly where it is. The doctor observes;
# it never repairs.
#
# NEVER A MESSAGE BODY, SUBJECT, SENDER, OR SLUG. The counts-only exemption a
# prompted tool enjoys covers CHANNEL and REGISTRY facts (paths, modes, ages,
# instance names, inbox filenames) -- never the content of a message. The doctor
# lists directories and stats files; it never reads a maildir message or a log
# LINE, so a peer-chosen string cannot reach a finding.
#
# PURE vs. PROBE. The decision helpers (`doctor_state_*`) take facts and return
# a state with no I/O, so every branch is provable with no root on disk. The
# `doctor_check_*` functions gather facts (a stat, a directory listing, one
# curl) and emit findings. Every probe is steerable by an environment override
# so the suite can drive the whole tool against temp dirs and canned JSON
# without opening a socket or touching the live client.
#
# A FINDING is one TAB-separated line on stdout:
#
#     <state>\t<check>\t<message>\t<fix>
#
# `message` and `fix` are single-line (no TAB, no newline) so the record is
# unambiguous. `fix` is empty for `ok`; every warn/fail/na carries one, per the
# repo's guard-message convention.
#
# Source order: err.sh, names.sh, descriptor.sh, logchan.sh, maildir.sh,
# fence.sh, session.sh, fs.sh, lock.sh, inbox.sh, then this file (the full set
# bin/inbox-doctor sources, since doctor_check_* reuse inbox.sh's resolvers).
# Requires jq; curl only when the server check is enabled; ruby only for the
# undeclared-entry cross-check.

# --- defaults / seams -------------------------------------------------------
# Each is overridable so the suite can point the whole tool at temp state.

doctor_client_config_path() {
  printf '%s\n' "${ATHENA_INBOX_CLIENT_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/athena-inbox-client/config.json}"
}
doctor_state_dir() {
  printf '%s\n' "${ATHENA_INBOX_CLIENT_STATE_DIR:-${HOME}/.local/state}"
}
doctor_pidfile()  { printf '%s\n' "$(doctor_state_dir)/athena-inbox-client.pid"; }
doctor_stopfile() { printf '%s\n' "$(doctor_state_dir)/athena-inbox-client.stopped"; }

# --- finding emission -------------------------------------------------------

# doctor_finding <state> <check> <message> [fix]
# A TAB and a NEWLINE would break the record apart, so both are stripped from
# every field -- a message can never inject a phantom finding.
doctor_finding() {
  local state="$1" check="$2" msg="$3" fix="${4:-}"
  msg="$(printf '%s' "${msg}" | tr '\t\n\r' '   ')"
  fix="$(printf '%s' "${fix}" | tr '\t\n\r' '   ')"
  printf '%s\t%s\t%s\t%s\n' "${state}" "${check}" "${msg}" "${fix}"
}

# --- pure state decisions ---------------------------------------------------

# doctor_state_mode <actual-mode> <expected-mode>
# ok when equal, warn when different, na when the mode is unknown (unreadable).
doctor_state_mode() {
  local actual="$1" expected="$2"
  [ -n "${actual}" ] || { printf 'na\n'; return 0; }
  [ "${actual}" = "${expected}" ] && printf 'ok\n' || printf 'warn\n'
}

# doctor_state_future <stamp-epoch> <now-epoch>
# warn when the stamp is in the future (a clock set back, a hand-edit), ok when
# it is not, na when either input is not a plain integer.
doctor_state_future() {
  local ts="$1" now="$2"
  # Plain digits only. Epochs here are non-negative (fs_epoch_of_rfc3339), and
  # allowing a stray `-` let a value like `1-2` past the guard and into `[ -gt ]`,
  # which errors and then falls to the `|| ok` branch -- printing `ok` where
  # `na` is the honest answer.
  case "${ts}" in ''|*[!0-9]*) printf 'na\n'; return 0 ;; esac
  case "${now}" in ''|*[!0-9]*) printf 'na\n'; return 0 ;; esac
  [ "${ts}" -gt "${now}" ] && printf 'warn\n' || printf 'ok\n'
}

# doctor_state_connected <connected-json-bool>
# ok=true, warn=false ("look, not necessarily down"), na otherwise.
doctor_state_connected() {
  case "$1" in
    true)  printf 'ok\n' ;;
    false) printf 'warn\n' ;;
    *)     printf 'na\n' ;;
  esac
}

# doctor_state_override <local-inbox> <server-inbox-name>
# The silent-override rule: a config override's inbox MUST equal the server's
# inbox_name for that instance, or deliveries land somewhere other than where
# the descriptor points. Mismatch is an ERROR (fail); equal is ok.
doctor_state_override() {
  [ "$1" = "$2" ] && printf 'ok\n' || printf 'fail\n'
}

# --- machine-global checks --------------------------------------------------

# doctor_check_root
# The root's own presence and mode. Absent -> na for the WHOLE downstream: a
# root that is not there is not a fault to fix, it is a tool that cannot run.
doctor_check_root() {
  local root mode st
  root="$(fs_inbox_root)"
  if [ ! -e "${root}" ]; then
    doctor_finding na "root" "the inbox root does not exist: ${root}" \
      "if this machine should receive mail, provision the root (a reader creates it at 0700 on first use) or point \$ATHENA_INBOX_ROOT at it; otherwise this machine is not set up and there is nothing to check."
    return 0
  fi
  if [ ! -d "${root}" ]; then
    doctor_finding fail "root" "the inbox root exists but is not a directory: ${root}" \
      "remove or rename whatever sits at ${root}; the root must be a 0700 directory."
    return 0
  fi
  mode="$(stat -c '%a' "${root}" 2>/dev/null)"
  st="$(doctor_state_mode "${mode}" "700")"
  case "${st}" in
    ok)   doctor_finding ok   "root" "${root} is present and mode 0700" ;;
    warn) doctor_finding warn "root" "the inbox root ${root} is mode 0${mode}, expected 0700" \
            "chmod 0700 ${root}; the root and everything under it must be private (it holds message content and the tenancy registry)." ;;
    na)   doctor_finding na   "root" "the inbox root ${root} mode could not be read" \
            "check that ${root} is stat-able by this user." ;;
  esac
}

# doctor_check_projects_dir
# The tenancy directory. Absent -> na (no registry on this machine yet).
doctor_check_projects_dir() {
  local dir mode st
  dir="$(fs_registry_dir)"
  if [ ! -d "${dir}" ]; then
    doctor_finding na "projects" "the tenancy registry directory does not exist: ${dir}" \
      "this is a MACHINE condition, not a project one -- no project has channels while projects/ is missing. A reader or the owner's setup creates it at 0700; check \$ATHENA_INBOX_ROOT points where you expect."
    return 0
  fi
  mode="$(stat -c '%a' "${dir}" 2>/dev/null)"
  st="$(doctor_state_mode "${mode}" "700")"
  case "${st}" in
    ok)   doctor_finding ok   "projects" "${dir} is present and mode 0700" ;;
    warn) doctor_finding warn "projects" "the registry directory ${dir} is mode 0${mode}, expected 0700" \
            "chmod 0700 ${dir}; the registry holds per-tenant configuration and must not be world-readable." ;;
    na)   doctor_finding na   "projects" "the registry directory ${dir} mode could not be read" \
            "check that ${dir} is stat-able by this user." ;;
  esac
}

# doctor_check_client_config
# The client's config.json: present, 0600, parses, and every instance's
# `doorbell` is null (v1). Absent -> na (this machine may only READ mail and not
# run a client). The token is NEVER read out of it.
doctor_check_client_config() {
  local cfg mode st bad
  cfg="$(doctor_client_config_path)"
  if [ ! -e "${cfg}" ]; then
    doctor_finding na "client-config" "no inbox-client config at ${cfg}" \
      "if this machine runs the inbox client, create ${cfg} (0600) from clients/athena-inbox-client/config.example.json; if it only reads mail delivered by another machine, this is expected."
    return 0
  fi
  if [ -L "${cfg}" ] || [ ! -f "${cfg}" ]; then
    doctor_finding fail "client-config" "the client config at ${cfg} is a symlink or not a regular file" \
      "replace ${cfg} with a regular 0600 file; it holds the machine token and must not be redirected."
    return 0
  fi
  mode="$(stat -c '%a' "${cfg}" 2>/dev/null)"
  st="$(doctor_state_mode "${mode}" "600")"
  if [ "${st}" = "warn" ]; then
    doctor_finding fail "client-config" "the client config ${cfg} is mode 0${mode}, expected 0600" \
      "chmod 0600 ${cfg}; it holds the machine token and the client itself refuses to start while it is any other mode."
    return 0
  fi
  if ! jq -e 'type == "object"' <"${cfg}" >/dev/null 2>&1; then
    doctor_finding fail "client-config" "the client config ${cfg} is not a JSON object" \
      "fix the JSON in ${cfg}; the client cannot start with an unparseable config."
    return 0
  fi
  # v1: doorbell is reserved and MUST be null. Name the instances that break it.
  bad="$(jq -r '(.instances // {}) | to_entries | map(select(.value.doorbell != null) | .key) | join(", ")' <"${cfg}" 2>/dev/null)"
  if [ -n "${bad}" ]; then
    doctor_finding warn "client-config" "instance(s) set a non-null doorbell (reserved in v1): ${bad}" \
      "set \"doorbell\": null for instance(s) ${bad} in ${cfg}; a per-instance doorbell is reserved for a future version and the client refuses a non-null one."
    return 0
  fi
  doctor_finding ok "client-config" "${cfg} is present, 0600, parses, doorbell is null"
}

# doctor_check_client_stopped [state-file-content]
# The partial-write stop marker. Its presence means the supervisor stopped the
# client DELIBERATELY and a human is needed -- it does NOT recommend a blind
# restart, because the marker exists precisely because restarting would re-hit a
# partial line. Status 0 (and a warn finding) when the marker is present;
# status 1 and NO finding when it is absent -- the caller uses that to decide
# whether the running check is subsumed. The reason it prints is the marker's
# first line, the supervisor's own text about an inbox file, never message
# content.
doctor_check_client_stopped() {
  local sf reason
  sf="$(doctor_stopfile)"
  [ -e "${sf}" ] || return 1
  reason="$(head -n 1 "${sf}" 2>/dev/null | tr '\t\n\r' '   ')"
  doctor_finding warn "client-stopped" "the client was STOPPED deliberately${reason:+: ${reason}}" \
    "do NOT just restart it -- the supervisor stopped it because an inbox file ends in a partial line. Read ${sf}, delete the trailing partial line from the inbox file it names, then remove ${sf} and re-run scripts/setup-athena-inbox-client."
  return 0
}

# doctor_pid_alive <pid>
# Overridable so the suite never probes a real process. Status 0 = alive.
doctor_pid_alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

# doctor_check_client_running <stopped:0/1>
# The supervisor pidfile holds a live pid. If the client was stopped
# deliberately (arg 0), running is subsumed by that finding and reported na
# here. No config at all -> na (nothing to run).
doctor_check_client_running() {
  local stopped="${1:-1}" cfg pf pid
  cfg="$(doctor_client_config_path)"
  if [ ! -e "${cfg}" ]; then
    doctor_finding na "client-running" "no client config, so no client is expected to run here" \
      "if this machine should run the inbox client, install its config and cron (scripts/setup-athena-inbox-client); if it only reads delivered mail, this is expected."
    return 0
  fi
  if [ "${stopped}" -eq 0 ]; then
    doctor_finding na "client-running" "the client is deliberately stopped (see client-stopped), so its pidfile is not a liveness signal" \
      "resolve the client-stopped finding first; the running check means nothing while the stop marker is in place."
    return 0
  fi
  pf="$(doctor_pidfile)"
  if [ ! -e "${pf}" ]; then
    doctor_finding fail "client-running" "no supervisor pidfile at ${pf}, so the inbox client is not running" \
      "start it: scripts/setup-athena-inbox-client installs the cron that keeps it alive, or run scripts/athena-inbox-client-run.sh once. A down client loses events silently -- unrouted events are dropped without a row and slack_events prune at 24h."
    return 0
  fi
  pid="$(tr -d '[:space:]' <"${pf}" 2>/dev/null)"
  if doctor_pid_alive "${pid}"; then
    doctor_finding ok "client-running" "the inbox client supervisor is running (pid ${pid})"
  else
    doctor_finding fail "client-running" "the supervisor pidfile ${pf} names pid ${pid:-<empty>}, which is not alive" \
      "the client died without cleaning up. Re-run scripts/athena-inbox-client-run.sh (the */5 cron relaunches it); check ${pf%.pid}.log for why it exited."
  fi
}

# doctor_state_liveness <verdict-state>
# Pure. The client-liveness grade for a liveness_verdict state:
#   progressing / reconnecting -> ok     (connected, or mid-cycle within its allowance)
#   wedged                     -> fail   (the 2026-09-22 15:55Z shape)
#   unknown                    -> warn   (a log that says nothing about the cycle
#                                         is a failed lookup, not a healthy client)
#   absent / anything else     -> na     (no log to read)
doctor_state_liveness() {
  case "$1" in
    progressing|reconnecting) printf 'ok\n' ;;
    wedged)  printf 'fail\n' ;;
    unknown) printf 'warn\n' ;;
    *)       printf 'na\n' ;;
  esac
}

# doctor_check_client_liveness <stopped:0/1>
# DND-316 R1(1a): is the client progressing, or wedged mid-reconnect? PID
# EXISTENCE IS NOT ASKED -- on 2026-09-22 client-running said "ok, pid 759946"
# for 72 minutes of a wedge. The verdict comes from the client log's LAST
# CONNECT-CYCLE LINE (lib/liveness.sh): a reconnect line (reconnecting / a
# reconnect step / connected-but-not-joined) older than its allowance is a
# wedge, and the finding names the step it is stuck in. A connected client that
# is merely quiet logs nothing and stays ok however long the silence.
doctor_check_client_liveness() {
  local stopped="${1:-1}" log v state step age detail
  if [ ! -e "$(doctor_client_config_path)" ]; then
    doctor_finding na "client-liveness" "no client config, so no client is expected to run here" \
      "if this machine should run the inbox client, install it with scripts/setup-athena-inbox-client; if it only reads delivered mail, this is expected."
    return 0
  fi
  if [ "${stopped}" -eq 0 ]; then
    doctor_finding na "client-liveness" "the client is deliberately stopped (see client-stopped), so its log says nothing about liveness" \
      "resolve the client-stopped finding first."
    return 0
  fi
  log="$(liveness_client_log)"
  v="$(liveness_verdict "${log}")"
  IFS=$'\t' read -r state step age detail <<<"${v}"
  case "$(doctor_state_liveness "${state}")" in
    ok)   doctor_finding ok "client-liveness" "the inbox client is ${state}: ${detail}" ;;
    fail) doctor_finding fail "client-liveness" "the inbox client is WEDGED: ${detail} -- a reconnect that never finished, the 2026-09-22 15:55Z shape" \
            "CAPTURE BEFORE RESTART, never the reverse (D35): the */5 supervisor watchdog (scripts/athena-inbox-client-run.sh) captures the wedge with scripts/inbox-client-capture and only then SIGTERMs the client, which the supervisor relaunches. To act now, run scripts/athena-inbox-client-run.sh by hand (it runs that watchdog pass). Never SIGTERM the client first -- that destroys the evidence." ;;
    warn) doctor_finding warn "client-liveness" "the client log ${log} has no connect-cycle line, so liveness cannot be judged (${detail})" \
            "a log with no connected/joined/reconnect line means the supervisor is not writing where this doctor reads, or the client never started. Check ATHENA_INBOX_CLIENT_STATE_DIR and tail ${log}; an unreadable liveness is not a healthy client." ;;
    na)   doctor_finding na "client-liveness" "no client log to judge liveness from (${detail})" \
            "the supervisor writes ${log}; if the client should be running, start it with scripts/athena-inbox-client-run.sh and re-check." ;;
  esac
}

# doctor_check_dump_dir
# DND-316 addition: the LV-1 client writes its SIGQUIT dumps into a directory it
# creates LAZILY, on the first dump -- so before this check "no dumps yet" read
# exactly like "the dump path is broken", and the first time anyone learned the
# difference would be the wedge whose evidence went nowhere. The supervisor now
# creates it (0700) at client start; this asserts it RESOLVES, is a directory,
# and is writable. Derived by liveness_dump_dir, the one derivation the
# supervisor and the capture share with the client ($XDG_STATE_HOME rules).
doctor_check_dump_dir() {
  local dir parent mode
  if [ ! -e "$(doctor_client_config_path)" ]; then
    doctor_finding na "dump-dir" "no client config, so no client dump directory is expected here" \
      "if this machine should run the inbox client, install it with scripts/setup-athena-inbox-client; if it only reads delivered mail, this is expected."
    return 0
  fi
  if ! dir="$(liveness_dump_dir)"; then
    doctor_finding fail "dump-dir" "the client dump directory does not resolve: XDG_STATE_HOME is set to a RELATIVE path (${XDG_STATE_HOME:-})" \
      "set XDG_STATE_HOME to an absolute path, or unset it (the default is ~/.local/state); a relative base resolves differently for the client and for the capture, so a dump would land where nothing looks."
    return 0
  fi
  if [ -L "${dir}" ] || { [ -e "${dir}" ] && [ ! -d "${dir}" ]; }; then
    doctor_finding fail "dump-dir" "the client dump path ${dir} exists but is not a plain directory" \
      "remove whatever sits at ${dir}; the client and the capture need a 0700 directory there, and a wedge dump written to a symlink or a file would be lost."
    return 0
  fi
  if [ ! -d "${dir}" ]; then
    parent="$(dirname "${dir}")"
    while [ ! -e "${parent}" ] && [ "${parent}" != "/" ]; do parent="$(dirname "${parent}")"; done
    if [ -d "${parent}" ] && [ -w "${parent}" ]; then
      # Not a fault: the client creates it on its first dump and the supervisor
      # at the next client start, and the parent is writable -- so a dump would
      # land. What this check exists to separate is THIS state from the one
      # below, where a dump could not be written at all.
      doctor_finding ok "dump-dir" "the client dump directory ${dir} does not exist yet, but CAN be created (the client makes it on its first dump; the supervisor at the next client start)"
    else
      doctor_finding fail "dump-dir" "the client dump directory ${dir} does not exist and cannot be created (nearest existing ancestor ${parent} is not a writable directory)" \
        "make ${parent} writable by this user, or point XDG_STATE_HOME elsewhere; a SIGQUIT dump from a wedged client would otherwise fail to write and the evidence would be lost."
    fi
    return 0
  fi
  if [ ! -w "${dir}" ]; then
    doctor_finding fail "dump-dir" "the client dump directory ${dir} is not writable by this user" \
      "chmod u+rwx ${dir} (it should be 0700); the client writes its wedge dumps there and the capture writes its capture directories beside them."
    return 0
  fi
  mode="$(stat -c '%a' "${dir}" 2>/dev/null)"
  if [ "$(doctor_state_mode "${mode}" "700")" = "warn" ]; then
    doctor_finding warn "dump-dir" "the client dump directory ${dir} is mode 0${mode}, expected 0700" \
      "chmod 0700 ${dir}; dumps hold thread backtraces and socket state of a process holding the machine token."
    return 0
  fi
  doctor_finding ok "dump-dir" "the client dump directory ${dir} exists, is writable, and is mode 0700"
}

# doctor_check_watchdog
# The supervisor's watchdog needs three tools: the liveness library (the wedge
# predicate), scripts/inbox-client-capture (capture before restart, D35) and
# scripts/inbox-client-alert (the harness-alerts message, DND-334). Missing any,
# the supervisor DEGRADES rather than stopping -- the client is still
# supervised -- but a wedge is then restarted with no evidence (no capture
# tool), not detected at all (no liveness library), or captured and never
# reported to the harness session (no alert tool: the watchdog logs ALERT NOT
# SENT, which nobody reads -- DND-367). That is a fault the owner must see, so
# it is a `fail` here, not a log line nobody reads.
doctor_check_watchdog() {
  local repo missing=""
  [ -e "$(doctor_client_config_path)" ] || {
    doctor_finding na "watchdog" "no client config, so no supervisor watchdog is expected here" \
      "if this machine should run the inbox client, install it with scripts/setup-athena-inbox-client; if it only reads delivered mail, this is expected."
    return 0
  }
  repo="${DOCTOR_REPO_DIR:-}"
  if [ -z "${repo}" ]; then
    doctor_finding na "watchdog" "the repo root is unknown, so the watchdog's tools cannot be checked" \
      "run inbox-doctor from the ~/dev/custom checkout (bin/inbox-doctor sets DOCTOR_REPO_DIR itself)."
    return 0
  fi
  [ -r "${repo}/ai/skills/athena:inbox/lib/liveness.sh" ] || missing="ai/skills/athena:inbox/lib/liveness.sh"
  [ -x "${repo}/scripts/inbox-client-capture" ] || missing="${missing:+${missing}, }scripts/inbox-client-capture (executable)"
  [ -x "${repo}/scripts/inbox-client-alert" ] || missing="${missing:+${missing}, }scripts/inbox-client-alert (executable)"
  if [ -n "${missing}" ]; then
    doctor_finding fail "watchdog" "the supervisor watchdog is missing ${missing}: without the capture tool a wedge is restarted with NO evidence; without the liveness library a wedge is not even detected; without the alert tool a captured wedge never reaches the harness session (ALERT NOT SENT)" \
      "restore ${missing} in ${repo} with git (chmod +x the scripts). The supervisor keeps the client running meanwhile, but only a human would notice the next wedge; re-send a missed alert by hand with scripts/inbox-client-alert <capture-dir>."
  else
    doctor_finding ok "watchdog" "the supervisor watchdog's tools are present (liveness library, inbox-client-capture, inbox-client-alert)"
  fi
}

# doctor_check_captures
# DND-316 / DND-333: the wedge captures on disk, newest first, with their
# signatures, so a human sees RECURRENCE without a ticket lookup (the same
# signature twice is the same wedge twice). A capture is written by
# scripts/inbox-client-capture into <dump dir>/<utc>-<pid>/, with signature.txt
# and capture.txt beside the evidence. INFORMATIONAL (in INFO_SET): a capture
# is a past wedge already restarted, not a degraded running chain; the live
# state is client-liveness's to grade. Only facts the capture tool wrote are
# read (step, signature, dump status) -- never a dump body.
#
# DND-362: a capture's `trigger:` line (watchdog|manual, written by
# scripts/inbox-client-capture) says WHO captured it. Only a watchdog capture
# is a wedge -- a MANUAL `--now`/direct-pid capture on a healthy client proves
# nothing wedged, so it is listed separately (its own `manual-captures`
# finding) and never counted toward the `captures` wedge count or its
# recurrence signal. A LEGACY capture with no trigger field (written before
# this field existed) is treated as watchdog, the pre-existing behaviour --
# but the listing says `(trigger unrecorded)` for it, never silently folding
# it in as if the field had been read.
doctor_check_captures() {
  local dir names n shown="" mshown="" name sig step dump trigger label wn=0 mn=0
  [ -e "$(doctor_client_config_path)" ] || return 0
  dir="$(liveness_dump_dir 2>/dev/null)" || return 0
  [ -d "${dir}" ] || return 0
  names="$(find "${dir}" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
             -regex '.*/[0-9]{8}T[0-9]{6}Z-[0-9]+(-[0-9]+)?' -printf '%f\n' 2>/dev/null | sort -r)"
  n="$(printf '%s' "${names}" | grep -c .)"
  if [ "${n}" -eq 0 ]; then
    doctor_finding ok "captures" "no wedge captures in ${dir}"
    return 0
  fi
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    sig="$(sed -n 's/^signature: //p' "${dir}/${name}/signature.txt" 2>/dev/null | head -n1 | cut -c1-8)"
    step="$(sed -n 's/^step: //p' "${dir}/${name}/signature.txt" 2>/dev/null | head -n1)"
    dump="$(sed -n 's/^dump: //p' "${dir}/${name}/capture.txt" 2>/dev/null | head -n1 | cut -d' ' -f1)"
    trigger="$(sed -n 's/^trigger: //p' "${dir}/${name}/capture.txt" 2>/dev/null | head -n1)"
    if [ "${trigger}" = "manual" ]; then
      mn=$((mn + 1))
      [ "${mn}" -gt 5 ] || mshown="${mshown:+${mshown}; }${name} sig ${sig:-?} step ${step:-?} dump ${dump:-?}"
    else
      wn=$((wn + 1))
      label=""; [ -n "${trigger}" ] || label=" (trigger unrecorded)"
      [ "${wn}" -gt 5 ] || shown="${shown:+${shown}; }${name} sig ${sig:-?} step ${step:-?} dump ${dump:-?}${label}"
    fi
  done < <(printf '%s\n' "${names}")
  if [ "${wn}" -gt 0 ]; then
    doctor_finding warn "captures" "${wn} wedge capture(s) on disk (newest first): ${shown}" \
      "each is a wedge the watchdog captured and then restarted. The same signature more than once is the same wedge recurring -- read that capture's dump.txt and signature.txt (${dir}/<name>/) and file or bump the [wedge:<sig8>] ticket. Retention keeps the newest ATHENA_INBOX_CAPTURE_KEEP (5), plus any an unread harness-alerts message references, up to ATHENA_INBOX_CAPTURE_HARD_MAX (25); prunes are recorded in ${dir}/pruned-captures.log. '(trigger unrecorded)' means the capture predates the trigger field (DND-362) and is treated as a watchdog capture."
  else
    doctor_finding ok "captures" "no wedge captures in ${dir}"
  fi
  if [ "${mn}" -gt 0 ]; then
    doctor_finding ok "manual-captures" "${mn} manual capture(s) on disk (not wedges, newest first): ${mshown}" \
      "each is a manual inbox-client-capture --now (or a directly-invoked capture) taken on a client that was not judged wedged. These are never counted as wedges, never trip the recurrence signal, and LV-3's wedge-ticket-decide refuses to file or bump a [wedge:<sig8>] ticket from one."
  fi
}

# doctor_check_cron
# `setup-athena-inbox-client --check` reports whether the crontab entries are
# live. The script absent -> na (not this checkout's concern). The command is
# overridable so the suite drives ok/fail without touching the crontab.
doctor_check_cron() {
  local cmd rc
  cmd="${ATHENA_INBOX_DOCTOR_CRON_CHECK:-}"
  # No client config -> this machine only READS mail delivered by another; there
  # is no client to keep alive, so the crontab entries are not expected and
  # their absence is `na`, not a fault. Same reasoning as client-running. The
  # test seam (ATHENA_INBOX_DOCTOR_CRON_CHECK) overrides this so a client-machine
  # cron case can still be driven.
  if [ -z "${cmd}" ] && [ ! -e "$(doctor_client_config_path)" ]; then
    doctor_finding na "cron" "no client config, so the inbox-client crontab entries are not expected here" \
      "if this machine should run the inbox client, install it with scripts/setup-athena-inbox-client; if it only reads delivered mail, this is expected."
    return 0
  fi
  if [ -z "${cmd}" ]; then
    local repo script
    repo="${DOCTOR_REPO_DIR:-}"
    script="${repo:+${repo}/scripts/setup-athena-inbox-client}"
    if [ -z "${script}" ] || [ ! -x "${script}" ]; then
      doctor_finding na "cron" "setup-athena-inbox-client is not present in this checkout, so its crontab entries cannot be checked" \
        "run scripts/setup-athena-inbox-client --check from the main checkout to confirm the @reboot and */5 entries are installed."
      return 0
    fi
    cmd="${script} --check"
  fi
  if ${cmd} >/dev/null 2>&1; then
    doctor_finding ok "cron" "the inbox-client crontab entries are installed"
  else
    rc=$?
    doctor_finding warn "cron" "the inbox-client crontab entries are not installed (--check exit ${rc})" \
      "run scripts/setup-athena-inbox-client --install from the MAIN checkout; without the @reboot and */5 entries nothing relaunches the client if it dies."
  fi
}

# doctor_check_skipped_files
# Contract obligation: report EVERY file under projects/ that is not a usable
# registry entry, BY NAME with the reason. `inbox-status` only counts the failed
# candidates (tenant privacy in the pre-prompt position); the doctor is the
# prompted tool whose job is to look, so naming is legitimate here.
#
# Two kinds, per *Finding the entry*: "not a candidate" (bad name/extension --
# a backup, a swapfile) and "a candidate that failed" (a conformant *.json that
# does not parse or whose repo is missing). The second MIGHT have been the entry
# claiming this session's identity, so it is the more serious of the two.
doctor_check_skipped_files() {
  local dir any=0 base name f
  dir="$(fs_registry_dir)"
  [ -d "${dir}" ] || return 0

  for f in "${dir}"/* "${dir}"/.*; do
    # `-e` FOLLOWS symlinks, so a dangling symlink (entry pointing at a deleted
    # target) is false here and would be skipped silently -- the "a failed
    # lookup must never look like an empty one" trap. `-L` catches it as a
    # present-but-broken entry so the `[ -L ]` branch below reports it by name.
    [ -e "${f}" ] || [ -L "${f}" ] || continue
    base="${f##*/}"
    case "${base}" in .|..) continue ;; esac
    # A well-formed, parseable, repo-bearing *.json is a usable entry -- not a
    # skip. Everything else is reported.
    # NOT-A-CANDIDATE (wrong extension, or a *.json whose stem fails the grammar)
    # vs. A-CANDIDATE-THAT-FAILED (a conformant *.json that does not parse or has
    # no repo). The first kind is a harmless stray -- a backup, a swapfile -- that
    # was never a registry entry; it is reported for hygiene but as an
    # INFORMATIONAL `stray-file`, so it does not flip `healthy` and nag every
    # session. The second kind MIGHT have been a project's own entry, so it is a
    # `fail` and always surfaces.
    case "${base}" in
      *.json) name="${base%.json}" ;;
      *)
        doctor_finding warn "stray-file" "projects/ holds a non-entry file: ${base} (does not end in .json, so it was never a registry entry)" \
          "if ${base} is a stray backup or editor swapfile, remove it; a file in projects/ that is not a *.json entry is ignored but clutters the tenancy directory."
        any=1
        continue
        ;;
    esac
    if ! names_valid_segment "${name}"; then
      doctor_finding warn "stray-file" "projects/ holds a *.json whose name fails the entry grammar: ${base}" \
        "rename ${base} so its stem matches ^[a-z0-9][a-z0-9_-]*$, or remove it; a non-conformant name is never loaded as an entry."
      any=1
      continue
    fi
    if [ -L "${f}" ] || [ ! -f "${f}" ]; then
      doctor_finding fail "skipped-file" "the registry entry ${base} is a symlink or not a regular file" \
        "replace ${base} with a regular 0600 file; an entry is opened with O_NOFOLLOW and a symlink there is refused, so this project would silently have no channels."
      any=1
      continue
    fi
    if ! jq -e . <"${f}" >/dev/null 2>&1; then
      doctor_finding fail "skipped-file" "the registry entry ${base} is not parseable JSON, so it is a FAILED candidate -- it might be a project's own entry" \
        "fix the JSON in ${base}; while it is unparseable the project it names has zero channels and exit 0, indistinguishable from not opting in."
      any=1
      continue
    fi
    if ! jq -e 'type == "object" and (.repo | type == "string")' <"${f}" >/dev/null 2>&1; then
      doctor_finding fail "skipped-file" "the registry entry ${base} has no string \"repo\", so it can never match a session" \
        "add a \"repo\" (the realpath of that project's git common dir) to ${base}; without it the entry is a failed candidate and the project it was meant for is dark."
      any=1
      continue
    fi
  done
  [ "${any}" -eq 1 ] || doctor_finding ok "skipped-file" "every file under $(fs_registry_dir) is a usable registry entry"
}

# doctor_declared_files
# The filenames the COMMITTED source of truth (ai/inbox/registry.json) declares.
# Resolved by INVOKING the tool that owns that knowledge -- ai/inbox's
# InboxRegistry -- never by this skill parsing registry.json itself. That is the
# seam: the skill's reader libraries stay ignorant of the committed list
# (RULE C); inbox-doctor, the cross-checking diagnostic, asks the owner-side
# tool. Empty + status 1 when it cannot be consulted (no ruby, no lib, a broken
# committed file) -- the caller degrades that to `na`, never a false clean.
doctor_declared_files() {
  local repo lib
  repo="${DOCTOR_REPO_DIR:-}"
  [ -n "${repo}" ] || return 1
  lib="${repo}/ai/inbox/lib/registry"
  [ -f "${lib}.rb" ] || return 1
  command -v ruby >/dev/null 2>&1 || return 1
  ruby -r "${lib}" -e 'begin; puts InboxRegistry.declared.map { |p| p["file"] }; rescue StandardError; exit 1; end' 2>/dev/null
}

# doctor_check_undeclared_live
# Admiral obligation 1: a LIVE entry under projects/ that the committed list
# does not declare. The installer merges at the directory level -- it writes
# only declared entries and never removes an undeclared one -- so the committed
# list can silently fall behind reality and nothing notices. INFORMATIONAL: an
# undeclared entry is not broken, it is unrecorded.
doctor_check_undeclared_live() {
  local dir declared any=0 base name
  dir="$(fs_registry_dir)"
  [ -d "${dir}" ] || return 0
  if ! declared="$(doctor_declared_files)"; then
    doctor_finding na "undeclared-entry" "cannot consult the committed registry list, so live entries cannot be reconciled against it" \
      "run ai/bin/check-inbox-registry from the main checkout (it owns the committed source of truth); this cross-check needs ruby and ai/inbox/lib/registry.rb."
    return 0
  fi
  local f
  for f in "${dir}"/*.json; do
    [ -e "${f}" ] || continue
    [ -f "${f}" ] && [ ! -L "${f}" ] || continue
    base="${f##*/}"
    name="${base%.json}"
    names_valid_segment "${name}" || continue
    if ! grep -qxF "${base}" <<<"${declared}"; then
      doctor_finding warn "undeclared-entry" "live registry entry ${base} is not declared in the committed source of truth" \
        "if ${base} is a tenant this machine should keep, add it to ai/inbox/registry.json and re-run scripts/setup-inbox-registry --install; the committed list is what makes a clobbered entry recoverable, and an undeclared one is invisible to that safety net."
      any=1
    fi
  done
  [ "${any}" -eq 1 ] || doctor_finding ok "undeclared-entry" "every live registry entry is declared in the committed source of truth"
}

# doctor_check_collisions
# Architect D12(a): a path/namespace COLLISION across registry entries -- two
# tenants whose log `path` or maildir `namespace` resolve to the same surface.
# Tenancy validates containment, not exclusivity, so a collision resolves for
# both and neither is warned. A DIAGNOSTIC may report it (this is prompted); a
# refusal still must not (that would enumerate a tenant's namespaces on a denial
# path). A collision is ACTIONABLE, not informational -- one tenant's mail lands
# in the other's file -- so it is a `warn` that counts against `healthy` (it is
# deliberately NOT in bin/inbox-doctor's INFO_SET).
doctor_check_collisions() {
  local records surfaces dupes
  records="$(fs_registry_records 2>/dev/null)" || return 0
  [ -n "${records}" ] || return 0

  # For each parseable entry, emit "<resolved-surface>" lines. Same-surface
  # lines from two different files are the collision.
  surfaces="$(
    printf '%s\n' "${records}" | while IFS=$'\t' read -r json src; do
      [ -n "${json}" ] || continue
      case "${json}" in '#unparseable') continue ;; esac
      # `sort -u` PER ENTRY so a surface counts at most once per file. Without
      # it, a single entry declaring two channels on one surface would show up
      # in the cross-file `uniq -d` below and be reported as "more than one
      # registry entry" -- which is the wrong finding. The D12(a) case is a
      # collision ACROSS entries, so the surface must appear in two DIFFERENT
      # files to count.
      printf '%s' "${json}" | jq -r '
        .channels // {} | to_entries[]
        | .value as $c
        | if $c.kind == "log" then $c.path
          elif $c.kind == "maildir" then $c.namespace
          else empty end' 2>/dev/null | sort -u
    done | sort | uniq -d
  )"
  if [ -n "${surfaces}" ]; then
    local s
    while IFS= read -r s; do
      [ -n "${s}" ] || continue
      doctor_finding warn "collision" "more than one registry entry points at the surface \"${s}\"" \
        "give each tenant a distinct path/namespace in \$ATHENA_INBOX_ROOT/projects/; two entries resolving to one surface both read and write it, so one tenant's mail lands in the other's file."
    done <<< "${surfaces}"
  else
    doctor_finding ok "collision" "no two registry entries resolve to the same surface"
  fi
}

# --- per matched-entry checks ----------------------------------------------

# doctor_check_entry [cwd]
# The registry entry that owns THIS session: does it resolve and validate?
# No match (or cwd in no repo) -> na: not opting in is normal, not a fault.
#
# It emits its finding to stdout (the findings stream) and hands the matched,
# VALID entry back through the global DOCTOR_MATCHED_ENTRY -- never through
# stdout, which the findings capture would otherwise swallow. The global is
# empty when there is no usable entry, so the per-channel checks simply do
# nothing.
DOCTOR_MATCHED_ENTRY=""
doctor_check_entry() {
  local entry rc err
  DOCTOR_MATCHED_ENTRY=""
  entry="$(inbox_entry "${1:-.}")"; rc=$?
  if [ "${rc}" -eq 2 ]; then
    doctor_finding fail "registry-entry" "this session's registry lookup is fatal (ambiguous ownership or an unreadable candidate that may be this project's)" \
      "run ai/skills/athena:inbox/bin/inbox-status --json from this project to see the refusal; leave exactly one entry whose \"repo\" matches this repo's git common dir."
    return 0
  fi
  if [ -z "${entry}" ]; then
    # NO CLIENT CHANNEL DECLARED -- one of the three empty-channel states
    # (contract -> "Producer registration extends to platform deliveries"). Name
    # the RESOLVED repo identity the lookup searched under, so "zero channels"
    # says which key found zero rather than reading like a benign "not opted in"
    # (CLAUDE.md -> "A failed lookup must never look like an empty one"). A cwd
    # in no repo yields an empty identity, and the message still reads correctly.
    # inbox_repo_key has THREE outcomes and the exit code is load-bearing: a
    # realpath + exit 0 (a resolved identity), an EMPTY line + exit 0 (a cwd
    # definitively in no git repo), or a NON-ZERO exit (could not tell: git
    # missing, cwd gone, realpath failed, a dubious/corrupt repo). Discarding
    # the rc collapses the last two -- an uncomputed key would read as "no repo,
    # benignly not opted in", which is exactly the failed-lookup-looks-empty
    # collapse this branch exists to prevent (CLAUDE.md -> "A failed lookup must
    # never look like an empty one"). So the rc is captured and the could-not-
    # tell case is its own finding, not folded into the empty one.
    local rk rkrc
    rk="$(inbox_repo_key "${1:-.}" 2>/dev/null)"; rkrc=$?
    if [ "${rkrc}" -ne 0 ]; then
      doctor_finding warn "registry-entry" "this project has no registry entry AND this session's repo identity COULD NOT BE DETERMINED, so whether an entry should name it cannot be checked -- an uncomputed identity is not the same as a cwd that is genuinely in no repo" \
        "ensure git is on PATH, the cwd still exists, and the repository is not flagged for dubious ownership (git config --global --add safe.directory); then re-run inbox-doctor. Until the identity resolves, this is not a benign \"not opted in\"."
      return 0
    fi
    # rc is 0, so inbox_repo_key was DEFINITIVE -- but its two 0-exit answers
    # mean opposite things and must not read the same. A non-empty rk is a
    # resolved identity that no entry names (the lookup searched and found zero);
    # an EMPTY rk is a cwd genuinely in no git repository, where there is no
    # identity to search WITH and the Fix cannot be "set repo to <the git common
    # dir>" -- there is no git common dir. Collapsing the two is this repo's own
    # failed-lookup-looks-empty collapse re-introduced at the message layer, so
    # the discriminator (rk empty vs not) is named rather than papered over with
    # a `${rk:+}` that drops silently.
    if [ -z "${rk}" ]; then
      doctor_finding na "registry-entry" "this project has no registry entry: this session's cwd is in NO GIT REPOSITORY, so there is no repo identity to name and nothing to opt in" \
        "run inbox-doctor from inside a project's git repository; a registry entry's \"repo\" is realpath \"\$(git rev-parse --git-common-dir)\", which cannot be derived from a directory that is in no repo."
    else
      doctor_finding na "registry-entry" "this project has no registry entry (NO CLIENT CHANNEL DECLARED): no entry under projects/ names this session's repo identity (${rk})" \
        "if this project should receive mail, add \$ATHENA_INBOX_ROOT/projects/<project>.json whose \"repo\" is ${rk} -- that is the identity the lookup searched for and found zero."
    fi
    return 0
  fi
  if err="$(descriptor_validate "${entry}" 2>&1 >/dev/null)"; then
    doctor_finding ok "registry-entry" "this project's registry entry is valid and every channel resolves"
    DOCTOR_MATCHED_ENTRY="${entry}"
  else
    doctor_finding fail "registry-entry" "this project's registry entry is invalid: $(printf '%s' "${err}" | head -n1)" \
      "$(printf '%s' "${err}" | sed -n 's/^  Fix: //p' | head -n1)"
  fi
}

# doctor_check_channels <entry> [cwd]
# Per declared channel of the matched entry: permissions, freshness, a
# never-delivered log, a future rotated_at, an over-14-day .jsonl.1, and a
# dead-pid consumer lock. All read-only.
doctor_check_channels() {
  local entry="$1" chan
  [ -n "${entry}" ] || return 0
  while IFS= read -r chan; do
    [ -n "${chan}" ] || continue
    doctor_check_one_channel "${entry}" "${chan}"
  done < <(descriptor_channel_names "${entry}")
}

# Resolution goes through descriptor_resolve on the ALREADY-MATCHED entry, not
# inbox_resolve_channel -- the latter re-derives the entry from the registry by
# cwd, which would ignore the entry this session actually matched.
doctor_check_one_channel() {
  local entry="$1" chan="$2" resolved kind producer
  resolved="$(descriptor_resolve "$(fs_inbox_root)" "${entry}" "${chan}" 2>/dev/null)" || return 0
  kind="$(inbox_field kind "${resolved}")"
  case "${kind}" in
    log)
      # The producer marker (DND-260) decides WHICH server end a never-delivered
      # channel is missing -- an athena-events handling rule (platform) or a
      # server-side agent instance (slack). Absent -> slack.
      producer="$(descriptor_channel_field "${entry}" "${chan}" producer)"
      doctor_check_log_channel "${chan}" "${resolved}" "${producer:-slack}"
      ;;
    maildir) doctor_check_maildir_channel "${chan}" "${resolved}" ;;
  esac
  doctor_check_freshness "${entry}" "${chan}" "${resolved}"
}

# doctor_state_freshness <stale:true/false> <age-or-null>
# Pure. fail when stale; ok when an age is known and not stale; na when there
# is no delivery to age (never delivered -- its own finding says so).
doctor_state_freshness() {
  if [ "$1" = "true" ]; then printf 'fail\n'
  elif [ "$2" = "null" ] || [ -z "$2" ]; then printf 'na\n'
  else printf 'ok\n'; fi
}

# doctor_check_freshness <entry> <chan> <resolved>
# DND-316 R2: a channel whose last delivery is older than its threshold is a
# FAIL. On 2026-09-22 this doctor printed `log channel "slack" last changed
# 5632s ago` and graded it ok through a 96-minute outage; a doctor that turns
# an outage into a clean bill of health is worse than none. The age source is
# the channel's `.event` doorbell mtime (liveness_channel_freshness), and the
# threshold is the entry's `stale_after_s` (default 1800 s for `log`, none for
# `maildir`). Quiet and dark cannot be told apart by age alone, so the Fix
# points at the two checks that CAN: client-liveness and server-reachability.
doctor_check_freshness() {
  local entry="$1" chan="$2" resolved="$3" fresh stale age thr basis join
  fresh="$(liveness_channel_freshness "${entry}" "${chan}" "${resolved}" 2>/dev/null)"
  if [ -z "${fresh}" ]; then
    doctor_finding warn "freshness:${chan}" "channel \"${chan}\" freshness could NOT be measured, so quiet and dark cannot be told apart" \
      "check that the channel's files are stat-able and jq is on PATH; a freshness that cannot be measured is not a fresh channel."
    return 0
  fi
  stale="$(printf '%s' "${fresh}" | jq -r '.stale')"
  age="$(printf '%s' "${fresh}" | jq -r '.last_delivery_age_s')"
  thr="$(printf '%s' "${fresh}" | jq -r '.stale_after_s')"
  basis="$(printf '%s' "${fresh}" | jq -r '.age_basis')"
  join="$(printf '%s' "${fresh}" | jq -r 'if .last_join_age_s == null then "" else "; client last joined \(.last_join_age_s)s ago" end')"
  case "$(doctor_state_freshness "${stale}" "${age}")" in
    fail) doctor_finding fail "freshness:${chan}" "channel \"${chan}\" is STALE: last delivery ${age}s ago (${basis} mtime), threshold ${thr}s${join}" \
            "quiet and dark look identical by age. Read the client-liveness and server-reachability findings: if either is not ok the relay is dark -- capture before restart (never SIGTERM first). If both are ok the channel is only quiet: raise its \"stale_after_s\" in the registry entry (0 or null disables)." ;;
    ok)   doctor_finding ok "freshness:${chan}" "channel \"${chan}\" last delivery ${age}s ago (${basis} mtime)$( [ "${thr}" = "null" ] && printf '; no staleness threshold' || printf ', threshold %ss' "${thr}")${join}" ;;
    na)   doctor_finding na "freshness:${chan}" "channel \"${chan}\" has no delivery to age yet" \
            "nothing has been delivered to this channel, so its freshness cannot be judged; see its never-delivered / channel finding." ;;
  esac
}

doctor_check_log_channel() {
  local chan="$1" resolved="$2" producer="${3:-slack}" inbox state one now rotated rot_epoch mode st mt age
  inbox="$(inbox_field inbox "${resolved}")"
  state="$(inbox_field state "${resolved}")"
  one="$(fs_rotated_name "${inbox}")"
  now="$(fs_now_epoch)"

  # NEVER DELIVERED is the absence of BOTH the live file AND a rotated
  # generation. A channel that was rotated and has had no delivery SINCE has no
  # <channel>.jsonl (rotation renamed it to .1) but does have <channel>.jsonl.1 --
  # reporting THAT as "never received" is false, and would also skip the
  # sweep-residue and lock checks below, which are exactly what such a quiet,
  # rotated channel needs. So the never-delivered warning fires only when
  # neither file exists.
  if [ ! -e "${inbox}" ] && [ ! -e "${one}" ]; then
    # NEVER DELIVERED -> NO SERVER PRODUCER REGISTERED, one of the three states
    # of an empty channel (contract -> "Producer registration extends to
    # platform deliveries"). The three MUST NOT read identically though all look
    # empty on disk:
    #   * NO CLIENT CHANNEL DECLARED -> the registry-entry finding
    #     (doctor_check_entry), which now names the resolved repo identity that
    #     found zero;
    #   * NO SERVER PRODUCER REGISTERED -> HERE (the file never existed), and the
    #     Fix names WHICH server end must exist -- and that differs by producer:
    #     a "platform" channel is fed by an athena-events handling rule, a
    #     "slack" channel by a server-side agent instance;
    #   * NOTHING ARRIVED -> the live/rotated file exists (handled below): a
    #     quiet channel, not a fault.
    # Its OWN check name, and informational for the hook's verdict (see
    # INFO_SET in bin/inbox-doctor): the count path already surfaces
    # never-delivered via inbox-status's HEALTH_TEXT, so letting THIS finding
    # flip `healthy` too would double-nag one fault on two separate rate limits.
    # A hand run still shows it as a warn with the producer-specific Fix.
    if [ "${producer}" = "platform" ]; then
      doctor_finding warn "never-delivered" "platform log channel \"${chan}\" has never received anything (${inbox##*/} does not exist): NO SERVER PRODUCER REGISTERED" \
        "register this channel's server producer -- an athena-events handling rule whose delivery target is this inbox channel (ai/contracts/athena-events.md). A channel declared producer:\"platform\" with no handling rule feeding it is empty and, on disk, indistinguishable from one that is merely quiet."
    else
      doctor_finding warn "never-delivered" "log channel \"${chan}\" has never received anything (${inbox##*/} does not exist): NO SERVER PRODUCER REGISTERED" \
        "register this channel's producer -- a server-side agent instance mapped to ${inbox##*/} in the client config; an unregistered producer and an empty channel look identical on disk."
    fi
    return 0
  fi

  # Permissions + freshness apply to the LIVE file when it exists.
  if [ -e "${inbox}" ]; then
    mode="$(stat -c '%a' "${inbox}" 2>/dev/null)"
    st="$(doctor_state_mode "${mode}" "600")"
    [ "${st}" = "warn" ] && doctor_finding warn "channel:${chan}" "the channel file ${inbox##*/} is mode 0${mode}, expected 0600" \
      "chmod 0600 ${inbox}; message surfaces under the root are private."
    # The channel's AGE is graded by doctor_check_freshness (freshness:<chan>),
    # which fails a stale channel. This line used to report "last changed Ns
    # ago" as ok whatever N was -- 5632 s during the 2026-09-22 outage.
    doctor_finding ok "channel:${chan}" "log channel \"${chan}\" file is present"
  else
    doctor_finding ok "channel:${chan}" "log channel \"${chan}\" is rotated and quiet (only ${one##*/} remains)"
  fi

  # State-file permissions, regardless of the live file's presence.
  if [ -e "${state}" ]; then
    mode="$(stat -c '%a' "${state}" 2>/dev/null)"
    st="$(doctor_state_mode "${mode}" "600")"
    [ "${st}" = "warn" ] && doctor_finding warn "channel:${chan}" "the state file ${state##*/} is mode 0${mode}, expected 0600" \
      "chmod 0600 ${state}; it records this channel's read offset and dedupe sets."
  fi

  # rotated_at, read once. A FUTURE stamp blocks rotation indefinitely and is
  # otherwise invisible; both checks run whether or not the live file is present,
  # because the rotated case is precisely when the .1 residue check matters.
  rotated="$(fs_read_state "${state}" 2>/dev/null | jq -r '.rotated_at // empty' 2>/dev/null)"
  if [ -n "${rotated}" ]; then
    if rot_epoch="$(fs_epoch_of_rfc3339 "${rotated}" 2>/dev/null)"; then
      [ "$(doctor_state_future "${rot_epoch}" "${now}")" = "warn" ] && \
        doctor_finding warn "channel:${chan}" "channel \"${chan}\" has a rotated_at in the future (${rotated})" \
          "the machine clock was set back or ${state##*/} was hand-edited; rotation will not fire while rotated_at is ahead of now. Correct the clock or reset rotated_at in ${state##*/}."
    fi
  fi
  # A .jsonl.1 is residue the ack-path sweep structurally cannot reach (D12(b))
  # -- the residue a channel whose designated consumer never runs again leaves
  # behind. THREE outcomes, and "could not decide" is not "fine":
  #   * rotated_at absent or unparseable -> na, NAMING the file. `.1` left by an
  #     older reader carries no rotated_at, so the window cannot be judged;
  #     reporting `ok`/nothing here would be exactly the missing-looks-empty
  #     silence this tool exists to break.
  #   * over 14 days past rotated_at -> warn (overdue residue);
  #   * within the window -> nothing (a fresh rotation is healthy).
  if [ -e "${one}" ]; then
    if [ -z "${rot_epoch:-}" ]; then
      doctor_finding na "channel:${chan}" "channel \"${chan}\" has a rotated generation (${one##*/}) whose rotation time is unknown, so its 14-day sweep window cannot be judged" \
        "an older reader left ${one##*/} with no (or an unparseable) rotated_at in ${state##*/}. A read on this channel as the designated consumer stamps rotated_at and starts the clock; the doctor never removes ${one##*/} for you."
    elif [ "$(logchan_should_sweep "${rot_epoch}" "${now}")" = "yes" ]; then
      doctor_finding warn "channel:${chan}" "channel \"${chan}\" has a rotated generation (${one##*/}) past its 14-day sweep window" \
        "the designated consumer has not run since rotation, so the ack-path sweep never fired. Run a read on this channel as the designated consumer, or remove ${one} by hand; the doctor never sweeps."
    fi
  fi

  # The consumer lock: a dead-pid lock is REPORTED reapable, never reaped.
  doctor_check_lock "${chan}" "$(inbox_field lock "${resolved}")"
}

doctor_check_maildir_channel() {
  local chan="$1" resolved="$2" read_dir mt now age
  read_dir="$(inbox_field read_dir "${resolved}")"
  if [ ! -d "${read_dir}" ]; then
    # A missing read directory is NORMAL for a maildir (the peer creates it on
    # first send), so this is a fact, not a fault.
    doctor_finding ok "channel:${chan}" "maildir channel \"${chan}\" has no incoming directory yet (awaiting the peer's first message)"
  else
    if mt="$(fs_mtime_epoch "${read_dir}" 2>/dev/null)"; then
      now="$(fs_now_epoch)"; age=$(( now - mt ))
      doctor_finding ok "channel:${chan}" "maildir channel \"${chan}\" incoming directory last changed ${age}s ago"
    fi
    local mode st
    mode="$(stat -c '%a' "${read_dir}" 2>/dev/null)"
    st="$(doctor_state_mode "${mode}" "700")"
    [ "${st}" = "warn" ] && doctor_finding warn "channel:${chan}" "the maildir directory for \"${chan}\" is mode 0${mode}, expected 0700" \
      "chmod 0700 ${read_dir}; a maildir holds a private conversation."
  fi
  doctor_check_maildir_modes "${chan}" "${resolved}"
  doctor_check_lock "${chan}" "$(inbox_field lock "${resolved}")"
}

# doctor_check_maildir_modes <chan> <resolved>
#
# The contract's "inbox-doctor reports the rest": *Root and permissions* says
# every file under the root MUST be 0600, and that "tooling fixes the mode of
# files IT writes, and inbox-doctor reports the rest". The WRITER's half is
# discharged -- fs_maildir_deliver sets 0600 at delivery -- but a message the
# PEER wrote under its own umask arrives 0644, and nothing surfaced it: the log
# kind's file-mode check has no maildir counterpart, so a peer-written 0644
# message file was invisible. This closes that gap for the maildir kind.
#
# COUNT ONLY, NEVER A FILENAME. A message filename carries the peer-chosen slug,
# and the doctor never emits a body, subject, sender or slug (file header). So
# this reports HOW MANY files are off-mode across the channel's message
# directories and names only the namespace DIRECTORY (a registry fact), never an
# individual file.
#
# INFORMATIONAL, not health-flipping (see INFO_SET in bin/inbox-doctor): a 0644
# message on a single-user box is contract drift, not an incident, and the peer
# that writes it is not something a local session can fix -- so letting it flip
# `healthy` would nag every opted-in repo, every window, about a benign steady
# state the local session cannot change. It is surfaced in a hand run and in the
# --json info count; the durable fix is the peer's writer, tracked separately.
#
# READ-ONLY, like everything in this file: it stats, it never chmods.
doctor_check_maildir_modes() {
  local chan="$1" resolved="$2" label dir ns seen=0 drift=0 n
  for label in read_dir ack_dir write_dir write_ack_dir; do
    dir="$(inbox_field "${label}" "${resolved}")"
    [ -n "${dir}" ] && [ -d "${dir}" ] || continue
    # Non-recursive per directory, regular files only (a symlink is -type l and
    # excluded), and `*.md` so only message files are judged -- never `.event`,
    # a lock, or a `tmp/` staging entry. `! -perm 600` is "not exactly 0600".
    n="$(find "${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.md' -printf 'x\n' 2>/dev/null | wc -l | tr -d ' ')"
    seen=$(( seen + n ))
    n="$(find "${dir}" -mindepth 1 -maxdepth 1 -type f -name '*.md' ! -perm 600 -printf 'x\n' 2>/dev/null | wc -l | tr -d ' ')"
    drift=$(( drift + n ))
  done
  # No message files anywhere yet -> nothing to judge; "awaiting the peer" /
  # freshness has already spoken. Reporting ok here would be noise.
  [ "${seen}" -gt 0 ] || return 0
  ns="$(inbox_field read_dir "${resolved}")"; ns="${ns%/*}"
  if [ "${drift}" -gt 0 ]; then
    doctor_finding warn "message-mode" "maildir channel \"${chan}\" has ${drift} message file(s) not mode 0600 (every file under the root MUST be 0600)" \
      "normalise them: find ${ns} -type f -name '*.md' ! -perm 600 -exec chmod 0600 {} + . A peer that creates a message under its umask leaves it 0644; the mode of files THIS side writes is set at delivery, so this is peer-written drift on a single-user box -- hygiene and contract conformance, not an incident."
  else
    doctor_finding ok "message-mode" "maildir channel \"${chan}\" message files are all mode 0600"
  fi
}

# doctor_check_lock <chan> <lock-path>
#
# READ-ONLY, and it must NEVER acquire the lock -- not even with `flock -n` for
# an instant. An earlier version took the lock in a subshell to test whether
# anyone held it; but the SessionStart hook runs the doctor on EVERY session in
# every opted-in repo, so a real consumer's read/ack landing in that window
# would be refused with a false "another session is the designated consumer",
# naming the wrong holder. That is a side effect that can deny a live reader --
# exactly what "read-only, absolutely" forbids.
#
# So the doctor only READS the recorded pid. That is precisely the ticket's
# signal ("a consumer.lock whose pid is dead -- report it as reapable, do not
# reap"). `flock` stays authoritative for OWNERSHIP (lock.sh), and this is
# consistent with it: the holder writes its own pid on acquire and the kernel
# releases the lock on the holder's death, so a DEAD recorded pid is exactly a
# leftover file that nothing holds. A live recorded pid is reported as nothing
# (a live holder, or at worst a benign stale-but-live pid the doctor will not
# guess about). The pid is diagnostics, and the doctor treats it as such.
doctor_check_lock() {
  local chan="$1" lock="$2" pid
  [ -n "${lock}" ] && [ -e "${lock}" ] || return 0
  [ -f "${lock}" ] && [ ! -L "${lock}" ] || return 0
  pid="$(jq -r '.pid // empty' <"${lock}" 2>/dev/null)"
  [ -n "${pid}" ] || return 0
  doctor_pid_alive "${pid}" && return 0
  # INFORMATIONAL (its own check, in INFO_SET): a dead-pid lock file is the
  # NORMAL steady state, not a fault. lock.sh deliberately LEAVES the file behind
  # on release ("the file is the diagnostics, and an unlink would race a
  # waiter"), so every channel ever read carries a .consumer.lock with the last
  # reader's now-dead pid. The ticket asks the doctor to report it as reapable;
  # it does -- but it must NOT flip `healthy`, or every previously-read channel
  # would nag every session. The kernel already released the flock on that pid's
  # death, so nothing is actually blocked.
  doctor_finding warn "stale-lock" "channel \"${chan}\" has a consumer lock whose recorded pid ${pid} is dead -- it is reapable residue (a normal leftover)" \
    "safe to remove ${lock} by hand; the kernel released the flock when that process died, so it blocks nothing and nothing needs it removed. The doctor never reaps it for you."
}

# --- server checks (opt-in) -------------------------------------------------

# doctor_server_health
# Fetch GET <base>/api/machines/<id>/health as the caller's user API token.
# The token is NEVER in argv and NEVER logged: it reaches curl only through a
# 0600 config file as an Authorization header, exactly as athena:slack does.
# Steerable: ATHENA_INBOX_DOCTOR_HEALTH_FILE feeds canned JSON and skips curl
# entirely, which is the test seam and also lets an owner diagnose from a saved
# response. Prints the response JSON on stdout; status 1 on any failure, 2 not
# configured, 3 token file too permissive, 4 a base/id/token/temp path that
# cannot be written safely into the curl config (never sent).
doctor_server_health() {
  local base id tokfile canned tmp rc
  canned="${ATHENA_INBOX_DOCTOR_HEALTH_FILE:-}"
  if [ -n "${canned}" ]; then
    [ -f "${canned}" ] || return 1
    cat "${canned}"
    return 0
  fi
  base="${ATHENA_INBOX_DOCTOR_API_BASE:-}"
  id="${ATHENA_INBOX_DOCTOR_MACHINE_ID:-}"
  tokfile="${ATHENA_INBOX_DOCTOR_API_TOKEN_FILE:-}"
  [ -n "${base}" ] && [ -n "${id}" ] && [ -n "${tokfile}" ] || return 2
  [ -f "${tokfile}" ] || return 1
  # A token file wider than 0600 is a credential exposure; refuse to read it
  # (status 3 so the caller can warn rather than silently degrade to na).
  case "$(stat -c '%a' "${tokfile}" 2>/dev/null)" in
    600|400) ;;
    *) return 3 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  # Every value below lands in a double-quoted curl config value (the same
  # rule as the MCP client's; names_safe_curl_config_value).
  names_safe_curl_config_value "${base}" && names_safe_curl_config_value "${id}" \
    && names_safe_curl_config_value "$(tr -d '\r\n' <"${tokfile}")" || return 4

  tmp="$(mktemp -d 2>/dev/null)" || return 1
  names_safe_curl_config_value "${tmp}" || { rm -rf "${tmp}"; return 4; }
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  (
    umask 077
    {
      printf 'url = "%s/api/machines/%s/health"\n' "${base%/}" "${id}"
      printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' <"${tokfile}")"
      printf 'output = "%s"\n' "${tmp}/resp.json"
      printf 'write-out = "%%{http_code}"\n'
      printf 'max-time = %s\n' "$(_doctor_http_timeout)"
      printf 'silent\n'
    } >"${tmp}/curlrc"
  ) || return 1
  local http
  http="$(curl --config "${tmp}/curlrc" 2>/dev/null)" || return 1
  case "${http}" in 2??) ;; *) return 1 ;; esac
  cat "${tmp}/resp.json" 2>/dev/null
}

# doctor_check_server [cwd]
# The whole server side: the connection verdict, per-instance delivery, and the
# silent-override cross-check. Every branch degrades to `na` when the server
# cannot be reached (no token configured -> opt-out, not a breakage).
doctor_check_server() {
  local cwd="${1:-.}" health rc cfg
  if [ "${DOCTOR_NO_SERVER:-0}" = "1" ]; then
    doctor_finding na "server" "server check not run (disabled for this invocation)" \
      "run inbox-doctor by hand (without --no-server) to include the server side; the unprompted SessionStart path deliberately makes no network request."
    return 0
  fi
  health="$(doctor_server_health)"; rc=$?
  if [ "${rc}" -eq 2 ]; then
    doctor_finding na "server" "server check skipped -- no API token configured (opt-out)" \
      "to enable it, set ATHENA_INBOX_DOCTOR_API_BASE, ATHENA_INBOX_DOCTOR_MACHINE_ID and ATHENA_INBOX_DOCTOR_API_TOKEN_FILE (a 0600 file holding a user API token); the doctor never stores or mints one."
    return 0
  fi
  if [ "${rc}" -eq 3 ]; then
    doctor_finding warn "server" "the API token file is more permissive than 0600, so the server check was not run" \
      "chmod 0600 \$ATHENA_INBOX_DOCTOR_API_TOKEN_FILE; a user API token is a credential and the doctor refuses to read one from a world- or group-readable file."
    return 0
  fi
  if [ "${rc}" -eq 4 ]; then
    doctor_finding na "server" "the server check was not run: ATHENA_INBOX_DOCTOR_API_BASE, ATHENA_INBOX_DOCTOR_MACHINE_ID, the API token, or the temp dir path contains a quote, backslash, whitespace or control character" \
      "correct the value: each is written into a double-quoted curl config value, so it is refused rather than sent malformed. The token itself is never printed."
    return 0
  fi
  if [ "${rc}" -ne 0 ] || [ -z "${health}" ] || ! printf '%s' "${health}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    doctor_finding na "server" "the server health endpoint could not be reached or returned no usable JSON" \
      "check ATHENA_INBOX_DOCTOR_API_BASE/MACHINE_ID and that the token file holds a valid user API token; GET /api/machines/:id/health answers 404 for a machine you may not see."
    return 0
  fi

  # Connection verdict. DND-207 (ordered verdict) has landed, so `connected` is
  # authoritative; the "look, not down" framing survives as the reader's habit.
  # NOT `// empty`: jq's `//` treats boolean false as absent, so `false //
  # empty` yields "" and a genuinely-disconnected machine would read `na`
  # instead of `warn` -- the exact false-clean this tool exists to avoid.
  local connected
  connected="$(printf '%s' "${health}" | jq -r '.data.machine | if has("connected") then (.connected | tostring) else "" end' 2>/dev/null)"
  case "$(doctor_state_connected "${connected}")" in
    ok)   doctor_finding ok   "server" "the server reports this machine's client channel connected" ;;
    warn) doctor_finding warn "server" "the server reports this machine's client channel NOT connected" \
            "look before concluding it is down: a deploy closes every channel and the client rejoins within its backoff. If it stays disconnected, check the client is running (see client-running) and its server_url/token." ;;
    na)   doctor_finding na   "server" "the server health response carried no connection verdict" \
            "the response shape may have changed; GET /api/machines/:id/health should carry .data.machine.connected." ;;
  esac

  # Per-instance delivery: undelivered counts are a fact worth surfacing.
  # `undelivered` is server-side: rows the server has NOT yet delivered to this
  # machine (drained on the client's channel join). A non-zero count means the
  # server is holding events the client has not received -- usually because the
  # client is down or not connected, NOT because a session failed to ack.
  local undel
  undel="$(printf '%s' "${health}" | jq -r '[.data.instances[]? | select((.undelivered // 0) > 0) | "\(.name):\(.undelivered)"] | join(", ")' 2>/dev/null)"
  [ -n "${undel}" ] && doctor_finding warn "server" "the server is holding events not yet delivered to this machine: ${undel}" \
    "these are queued on the server for a client that has not drained them -- check the client is running and connected (see client-running and the connection verdict above); a growing count is the server unable to hand events to this machine."

  # The silent-override cross-check needs the client config's instances map.
  cfg="$(doctor_client_config_path)"
  [ -f "${cfg}" ] || { doctor_finding na "server-override" "no client config, so config instance overrides cannot be cross-checked against the server" \
    "this cross-check compares the client config's instance overrides with the server's live instances; without a config there is nothing to compare."; return 0; }

  doctor_check_overrides "${cfg}" "${health}" "${cwd}"
}

# doctor_check_overrides <config-path> <health-json> <cwd>
# The reason this whole ticket exists. The client resolves a config override by
# the instance name the server sends; a config key that matches no live instance
# is NEVER looked up, silently. So:
#   * a config `instances` key matching no live instance name -> WARN (both sides)
#   * an override's `inbox` != the server's inbox_name          -> ERROR (fail)
#   * a live instance's inbox_name claimed by no registry entry -> INFO
doctor_check_overrides() {
  local cfg="$1" health="$2" cwd="$3"
  local server_names server_inboxes cfgkeys key

  server_names="$(printf '%s' "${health}" | jq -r '.data.instances[]?.name' 2>/dev/null)"
  cfgkeys="$(jq -r '(.instances // {}) | keys[]' <"${cfg}" 2>/dev/null)"

  local any_key_problem=0
  while IFS= read -r key; do
    [ -n "${key}" ] || continue
    if ! grep -qxF "${key}" <<<"${server_names}"; then
      doctor_finding warn "server-override" "config instance \"${key}\" matches no live server instance, so its override is never looked up" \
        "either the server has no instance named \"${key}\" or the config key is a typo; deliveries arrive under the server's own instance name and the override you wrote is inert. Fix the key in ${cfg} to a live instance name, or remove it."
      any_key_problem=1
      continue
    fi
    # The key matches a live instance: its inbox override must equal the
    # server's inbox_name, or delivery lands somewhere other than intended.
    local local_inbox server_inbox
    local_inbox="$(jq -r --arg k "${key}" '.instances[$k].inbox // empty' <"${cfg}" 2>/dev/null)"
    [ -n "${local_inbox}" ] || continue   # no override -> server name is used, fine
    server_inbox="$(printf '%s' "${health}" | jq -r --arg k "${key}" '.data.instances[] | select(.name == $k) | .inbox_name // empty' 2>/dev/null)"
    if [ "$(doctor_state_override "${local_inbox}" "${server_inbox}")" = "fail" ]; then
      doctor_finding fail "server-override" "config override for \"${key}\" writes to \"${local_inbox}\" but the server's instance inbox_name is \"${server_inbox}\"" \
        "these must match or deliveries land in a file the descriptor does not point at. Set instances.${key}.inbox to \"${server_inbox}\" in ${cfg}, or align the server instance."
      any_key_problem=1
    fi
  done <<< "${cfgkeys}"

  # Every live instance's inbox_name should be claimed by some registry entry's
  # log path, or messages are written to a file no session consumes.
  local claimed inbox_name
  claimed="$(doctor_registry_log_paths)"
  local unclaimed=0
  while IFS= read -r inbox_name; do
    [ -n "${inbox_name}" ] || continue
    if ! grep -qxF "${inbox_name}" <<<"${claimed}"; then
      # INFORMATIONAL (its own check name), not an override error: an unclaimed
      # instance is bookkeeping, not a broken running chain, and must not flip
      # the chain's health or nag every session. Same class as an undeclared
      # committed-list entry (a collision, by contrast, IS actionable and
      # counts against healthy).
      doctor_finding warn "server-instance" "server instance inbox_name \"${inbox_name}\" is claimed by no registry entry" \
        "no project declares a log channel with path \"${inbox_name}\", so mail delivered there is consumed by nobody. Declare it in a \$ATHENA_INBOX_ROOT/projects/<project>.json, or retire the server instance."
      unclaimed=1
    fi
  done < <(printf '%s' "${health}" | jq -r '.data.instances[]?.inbox_name // empty' 2>/dev/null)

  [ "${any_key_problem}" -eq 0 ] && [ "${unclaimed}" -eq 0 ] && \
    doctor_finding ok "server-override" "config overrides and server instances agree, and every live inbox_name is claimed"
}

# doctor_registry_log_paths
# Every log-channel `path` declared by any LIVE registry entry, one per line.
# Used only to answer "is this inbox_name claimed by anyone" -- a machine fact,
# not message content.
doctor_registry_log_paths() {
  local records
  records="$(fs_registry_records 2>/dev/null)" || return 0
  printf '%s\n' "${records}" | while IFS=$'\t' read -r json src; do
    [ -n "${json}" ] || continue
    case "${json}" in '#unparseable') continue ;; esac
    printf '%s' "${json}" | jq -r '.channels // {} | to_entries[] | select(.value.kind == "log") | .value.path' 2>/dev/null
  done
}

# --- server reachability via the machine token (DND-316 R6 / R1(1b)) --------
#
# The check above (doctor_check_server) needs a USER API token that is usually
# not configured, so on most machines it reports "skipped" -- and a skipped
# server check read the same as a clean one. This one authenticates with the
# MACHINE token the inbox client already holds (HG-1), and asks the hosted
# `athena` MCP server (HG-3; /mcp on the client's own host) the HG-20 question
# `machine_reachable` for THIS machine (no machine_id = self). The answer is
# three-valued (true | false | "unknown") with the pending-delivery count, the
# last ack, and `unreachable_since`.
#
# FOUR OUTCOMES, AND NONE MAY READ LIKE ANOTHER:
#   skipped      na    -- no client config / no token on this machine (opt-out)
#   disabled     na    -- --no-server (the SessionStart hook's unprompted run)
#   UNAVAILABLE  na    -- we tried and got no answer: network, HTTP, an MCP
#                         error, or the tool is not deployed yet (DND-315). It
#                         says "unavailable", never "skipped", and it never fails
#                         the doctor on its own: an absent server feature is not
#                         a dark relay.
#   checked      ok/warn/fail -- reachable:false is a FAIL (R1(1b)); pending
#                         deliveries > 0 is a warn with the count; "checked, 0
#                         pending" says so in those words.
#
# THE TOKEN IS NEVER IN ARGV, NEVER LOGGED, NEVER PRINTED. It is read from the
# client config into a 0600 curl config inside a 0700 mktemp dir and reaches
# curl as an Authorization header only. The response is parsed, not echoed.
#
# Seams: ATHENA_INBOX_DOCTOR_REACHABLE_FILE holds a canned tool result (a JSON
# object, or `UNAVAILABLE:<reason>`) and skips the network; the suite drives the
# real protocol path through a curl shim on PATH. There is NO endpoint override
# (see doctor_mcp_url).

DOCTOR_MCP_PROTOCOL="2025-03-26"

# _doctor_http_timeout -- ATHENA_INBOX_DOCTOR_HTTP_TIMEOUT when it is a plain
# 1-4 digit number, else 10. It is written into a curl config line, where a
# newline could add a line of its own.
_doctor_http_timeout() {
  case "${ATHENA_INBOX_DOCTOR_HTTP_TIMEOUT:-}" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) printf '%s\n' "${ATHENA_INBOX_DOCTOR_HTTP_TIMEOUT}" ;;
    *) printf '10\n' ;;
  esac
}

# doctor_mcp_url -- the /mcp endpoint on the client's own server host, always
# https. There is deliberately NO override: the machine token goes wherever this
# URL points, so the only place it may point is the server the client itself is
# configured to trust.
doctor_mcp_url() {
  local host
  host="$(jq -r '.server_url // empty' <"$(doctor_client_config_path)" 2>/dev/null | sed -E 's#^[a-z]+://##; s#[/?].*$##')"
  [ -n "${host}" ] || return 1
  # The URL is written into a double-quoted curl config value.
  names_safe_curl_config_value "${host}" || return 2
  printf 'https://%s/mcp\n' "${host}"
}

# doctor_mcp_post <workdir> <url> <session-id-or-empty> <json-body>
# One POST. Writes <workdir>/hdr and <workdir>/body, prints the HTTP status.
# The bearer comes from <workdir>/token (0600), placed there by the caller; it
# is written into the curl config here and never touches argv.
doctor_mcp_post() {
  local w="$1" url="$2" sid="$3" body="$4"
  command -v curl >/dev/null 2>&1 || return 1
  printf '%s' "${body}" >"${w}/req.json"
  (
    umask 077
    {
      printf 'url = "%s"\n' "${url}"
      printf 'request = "POST"\n'
      printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' <"${w}/token")"
      printf 'header = "Content-Type: application/json"\n'
      printf 'header = "Accept: application/json, text/event-stream"\n'
      [ -n "${sid}" ] && printf 'header = "mcp-session-id: %s"\n' "${sid}"
      printf 'data-binary = "@%s/req.json"\n' "${w}"
      printf 'dump-header = "%s/hdr"\n' "${w}"
      printf 'output = "%s/body"\n' "${w}"
      printf 'write-out = "%%{http_code}"\n'
      printf 'max-time = %s\n' "$(_doctor_http_timeout)"
      printf 'silent\n'
    } >"${w}/curlrc"
  ) || return 1
  curl --config "${w}/curlrc" 2>/dev/null
}

# _doctor_mcp_json <body-file> -- the JSON-RPC message in a body that may be
# plain JSON or a Streamable-HTTP SSE stream (last `data:` line wins).
_doctor_mcp_json() {
  local f="$1"
  if grep -q '^data:' "${f}" 2>/dev/null; then
    grep '^data:' "${f}" | tail -n 1 | sed 's/^data: \{0,1\}//'
  else
    cat "${f}"
  fi
}

# doctor_mcp_tool_call <tool> <arguments-json> <canned-file-or-empty>
# One authenticated MCP tool call on the machine token: initialize -> session
# id -> notifications/initialized -> tools/call <tool>. Prints the tool result
# (a JSON value) on success. Status: 0 answered · 2 skipped (no config / no
# token) · 4 unavailable, with the one-line reason on stdout instead. A canned
# file (a JSON value, or `UNAVAILABLE:<reason>`) skips the network.
doctor_mcp_tool_call() {
  local tool="$1" args="$2" canned="$3" cfg url w http sid msg res tool_err
  # A malformed arguments value would make the jq below fail inside a nested
  # $(...) and POST an empty body; refuse it here instead.
  jq -e 'type == "object"' <<<"${args}" >/dev/null 2>&1 || { printf 'doctor_mcp_tool_call: arguments for %s are not a JSON object\n' "${tool}"; return 4; }
  if [ -n "${canned}" ]; then
    [ -f "${canned}" ] || { printf 'the canned %s file %s does not exist\n' "${tool}" "${canned}"; return 4; }
    case "$(head -c 12 "${canned}")" in
      UNAVAILABLE:*) sed -n '1s/^UNAVAILABLE://p' "${canned}"; return 4 ;;
    esac
    cat "${canned}"; return 0
  fi
  cfg="$(doctor_client_config_path)"
  [ -f "${cfg}" ] || return 2
  jq -e '(.token // "") | length > 0' <"${cfg}" >/dev/null 2>&1 || return 2
  url="$(doctor_mcp_url)"; local urc=$?
  if [ "${urc}" -eq 2 ]; then printf 'the client config server_url host contains a quote, backslash, whitespace or control character\n'; return 4; fi
  if [ "${urc}" -ne 0 ]; then printf 'the client config has no server_url to derive the /mcp endpoint from\n'; return 4; fi

  w="$(mktemp -d 2>/dev/null)" || { printf 'could not create a private temp dir\n'; return 4; }
  chmod 700 "${w}"
  # Its path goes into curl config lines (data-binary, dump-header, output).
  names_safe_curl_config_value "${w}" || { rm -rf "${w}"; printf 'the temp dir path (from $TMPDIR) contains a quote, backslash, whitespace or control character\n'; return 4; }
  # shellcheck disable=SC2064
  trap "rm -rf '${w}'; trap - RETURN" RETURN
  ( umask 077; jq -r '.token' <"${cfg}" | tr -d '\r\n' >"${w}/token" ) || { printf 'could not stage the machine token\n'; return 4; }
  # The token is written into a double-quoted curl config value, so a quote,
  # backslash or whitespace in it would corrupt the header. Refuse such a token
  # (UNAVAILABLE, never silently sent malformed); the token is never printed.
  if ! names_safe_curl_config_value "$(cat "${w}/token")"; then printf 'the machine token contains a quote, backslash, whitespace or control character and cannot be sent safely\n'; return 4; fi

  http="$(doctor_mcp_post "${w}" "${url}" "" "$(jq -n -c --arg v "${DOCTOR_MCP_PROTOCOL}" \
    '{jsonrpc:"2.0", id:1, method:"initialize", params:{protocolVersion:$v, capabilities:{}, clientInfo:{name:"inbox-doctor", version:"1"}}}')")" \
    || { printf 'the MCP endpoint %s could not be reached\n' "${url}"; return 4; }
  case "${http}" in
    2??) ;;
    401|403) printf 'the MCP endpoint refused the machine token (HTTP %s)\n' "${http}"; return 4 ;;
    *) printf 'the MCP initialize at %s answered HTTP %s\n' "${url}" "${http:-none}"; return 4 ;;
  esac
  sid="$(tr -d '\r' <"${w}/hdr" 2>/dev/null | awk 'tolower($1)=="mcp-session-id:"{print $2; exit}')"
  [ -n "${sid}" ] || { printf 'the MCP initialize returned no session id\n'; return 4; }
  # It is sent back inside a double-quoted curl config value. A Hermes session
  # id is base64 (`+`, `/`, `=` are legal and safe there); only what would
  # change the config line's meaning is refused. Unchecked, a server-sent `"`
  # or newline would have injected a config line.
  names_safe_curl_config_value "${sid}" 256 || { printf 'the MCP initialize returned a session id that cannot be sent back safely (a quote, backslash, whitespace or control character, or over 256 bytes)\n'; return 4; }
  doctor_mcp_post "${w}" "${url}" "${sid}" '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >/dev/null || true

  http="$(doctor_mcp_post "${w}" "${url}" "${sid}" "$(jq -n -c --arg t "${tool}" --argjson a "${args}" \
    '{jsonrpc:"2.0", id:2, method:"tools/call", params:{name:$t, arguments:$a}}')")" \
    || { printf 'the %s call to %s failed in transport\n' "${tool}" "${url}"; return 4; }
  case "${http}" in 2??) ;; *) printf 'the %s call answered HTTP %s\n' "${tool}" "${http:-none}"; return 4 ;; esac
  msg="$(_doctor_mcp_json "${w}/body")"
  # A JSON-RPC error, or a tool result flagged isError -- a tool not deployed
  # yet lands here. Report the server's own words, which are server text about
  # a tool, never message content.
  tool_err="$(printf '%s' "${msg}" | jq -r '
      if .error then (.error.message // "an MCP error")
      elif (.result.isError // false) then ((.result.content[0].text // "a tool error") | tostring)
      else empty end' 2>/dev/null | head -c 200 | tr '\t\n\r' '   ')"
  if [ -n "${tool_err}" ]; then printf '%s is not available from the server: %s\n' "${tool}" "${tool_err}"; return 4; fi
  res="$(printf '%s' "${msg}" | jq -c '(.result.structuredContent // (.result.content[0].text | fromjson))' 2>/dev/null)"
  [ -n "${res}" ] || { printf 'the %s answer carried no result\n' "${tool}"; return 4; }
  printf '%s\n' "${res}"
}

# doctor_machine_reachable
# Prints the machine_reachable tool result (a JSON object) on success.
# Status: 0 answered · 2 skipped (no config / no token) · 4 unavailable, with
# the one-line reason on stdout instead.
doctor_machine_reachable() {
  local out rc
  out="$(doctor_mcp_tool_call machine_reachable '{}' "${ATHENA_INBOX_DOCTOR_REACHABLE_FILE:-}")"; rc=$?
  [ "${rc}" -eq 0 ] || { printf '%s\n' "${out}"; return "${rc}"; }
  if ! printf '%s' "${out}" | jq -e 'type == "object" and has("reachable")' >/dev/null 2>&1; then
    printf 'the machine_reachable answer was not a verdict object\n'; return 4
  fi
  printf '%s\n' "${out}"
}

# doctor_state_reachable <reachable> <pending>
# Pure. false -> fail · pending > 0 -> warn · true/"unknown" with 0 pending -> ok
# · anything else -> na (an answer with no usable verdict).
doctor_state_reachable() {
  local r="$1" p="$2"
  case "${p}" in ''|*[!0-9]*) p=0 ;; esac
  case "${r}" in
    false) printf 'fail\n' ;;
    true|unknown) [ "${p}" -gt 0 ] && printf 'warn\n' || printf 'ok\n' ;;
    *) printf 'na\n' ;;
  esac
}

# doctor_check_server_reachability
doctor_check_server_reachability() {
  local out rc r basis pending last_ack since joined facts now ack_age ack_epoch
  DOCTOR_REACHABLE="not-asked"
  if [ "${DOCTOR_NO_SERVER:-0}" = "1" ]; then
    doctor_finding na "server-reachability" "server reachability check not run (disabled for this invocation)" \
      "run inbox-doctor by hand (without --no-server) to ask the server whether it can reach this machine; the unprompted SessionStart path deliberately makes no network request."
    return 0
  fi
  out="$(doctor_machine_reachable)"; rc=$?
  # A canned answer is a diagnostic/test seam; say so on every finding it
  # produces, so a canned "reachable" can never pass for a live one.
  local canned_note=""
  [ -n "${ATHENA_INBOX_DOCTOR_REACHABLE_FILE:-}" ] && canned_note=" [CANNED answer from ATHENA_INBOX_DOCTOR_REACHABLE_FILE, not the live server]"
  case "${rc}" in
    2) DOCTOR_REACHABLE="skipped-no-token"
       doctor_finding na "server-reachability" "server reachability check SKIPPED -- no client config or machine token on this machine" \
         "this check authenticates with the inbox client's machine token (~/.config/athena-inbox-client/config.json); a machine that only reads delivered mail has none, and this is expected there."
       return 0 ;;
    4) DOCTOR_REACHABLE="unavailable"
       doctor_finding na "server-reachability" "server reachability check UNAVAILABLE (tried, got no answer): $(printf '%s' "${out}" | head -n 1)${canned_note}" \
         "this is not a skip and not a clean bill: the server was asked and could not answer. If machine_reachable is not deployed yet (DND-315), this is expected until it is; otherwise check the network, the /mcp endpoint, and that the machine token in the client config is current."
       return 0 ;;
    0) ;;
    *) DOCTOR_REACHABLE="unavailable"
       doctor_finding na "server-reachability" "server reachability check UNAVAILABLE (unexpected status ${rc})" \
         "re-run inbox-doctor; if it persists, check doctor_machine_reachable in lib/doctor.sh."
       return 0 ;;
  esac
  r="$(printf '%s' "${out}" | jq -r '.reachable | tostring')"
  case "${r}" in true|false|unknown) DOCTOR_REACHABLE="${r}" ;; *) DOCTOR_REACHABLE="unavailable" ;; esac
  basis="$(printf '%s' "${out}" | jq -r '.basis // "unknown"')"
  pending="$(printf '%s' "${out}" | jq -r '(.pending_deliveries // 0) | tostring')"
  last_ack="$(printf '%s' "${out}" | jq -r '.last_ack_at // "never"')"
  since="$(printf '%s' "${out}" | jq -r '.unreachable_since // ""')"
  joined="$(printf '%s' "${out}" | jq -r '.last_joined_at // ""')"
  ack_age=""
  if [ "${last_ack}" != "never" ] && ack_epoch="$(date -u -d "${last_ack}" +%s 2>/dev/null)"; then
    now="$(date -u +%s)"; ack_age=" ($(( now - ack_epoch ))s ago)"
  fi
  facts="basis ${basis}; ${pending} pending deliver(y/ies) for this machine; server last ack ${last_ack}${ack_age}${joined:+; server last join ${joined}}"
  case "$(doctor_state_reachable "${r}" "${pending}")" in
    fail) doctor_finding fail "server-reachability" "the server reports this machine UNREACHABLE${since:+ since ${since}}: ${facts}${canned_note}" \
            "the relay is dark from the server's side. Read client-liveness: a wedged client is captured and restarted by the */5 supervisor watchdog (run scripts/athena-inbox-client-run.sh by hand to act now -- capture first, never SIGTERM first). Pending deliveries, including exhausted-offline ones, are held server-side and re-delivered on the next join." ;;
    warn) doctor_finding warn "server-reachability" "checked: the server holds ${pending} pending deliver(y/ies) for this machine (reachable: ${r}; ${facts})${canned_note}" \
            "a pending count that does not drain means the client is not acking. Check client-liveness and the client log; exhausted-offline deliveries count here as evidence of a dark relay, not as resolved failures." ;;
    ok)   doctor_finding ok "server-reachability" "checked: reachable ${r}, 0 pending (${facts})${canned_note}" ;;
    na)   doctor_finding na "server-reachability" "the server answered machine_reachable with no usable verdict (reachable: ${r})" \
            "the answer shape may have changed; machine_reachable should return reachable true|false|\"unknown\"." ;;
  esac
}

# --- the two send paths (HG-19 / DND-314) -----------------------------------
#
# `send-mail` has two paths: the LOCAL maildir (a link(2) into a directory on
# this machine, no server) and the ROUTED server path (the athena MCP's
# session_send). The per-channel checks above already report each maildir
# channel's health and the session log channel's; this finding says what a
# SENDER from this project can do right now, and what the no-flag default
# would pick -- so "routed is broken" never has to be discovered by a send.
#
# DOCTOR_REACHABLE is the machine_reachable verdict doctor_check_server_
# reachability recorded (true | false | unknown | unavailable | not-asked |
# skipped-no-token); it
# must run first, in the same shell.
DOCTOR_REACHABLE="not-asked"

# doctor_state_send_paths <registration> <session> <reachable> <bearer> <maildir-count>
#   registration  registered | unregistered | broken | error
#   session       declared | missing | invalid
#   bearer        set | unset  (ATHENA_MCP_BEARER in THIS shell)
# Pure. It grades exactly what routed_default_path would decide for a
# server-addressed no-flag send, so the doctor can never say "routes" where
# send-mail refuses:
#   ok   the routed path is ready (registered, session inbox declared, bearer
#        set, this machine reachable) -- the no-flag default routes;
#   warn the routed path is configured but not usable right now (no bearer in
#        this shell, this machine not confirmed reachable, no valid session
#        inbox), or its registration cannot be read or looked up: a no-flag
#        server-addressed send will be REFUSED;
#   na   routed is not configured for this project (not registered) or the
#        reachability was not asked (--no-server): nothing to grade.
# An unreadable maildir count (the local path's fact) is a warn of its own; it
# never changes what the routed inputs grade, and is never printed as 0.
doctor_state_send_paths() {
  local reg="$1" session="$2" reach="$3" bearer="$4" maildirs="$5"
  local routed
  # The ROUTED grade, from the routed inputs alone.
  case "${reg}" in
    broken|error) routed=warn ;;
    registered)
      if [ "${session}" != "declared" ] || [ "${bearer}" != "set" ]; then routed=warn
      else
        case "${reach}" in
          true) routed=ok ;;
          not-asked|skipped-no-token) routed=na ;;
          *) routed=warn ;;
        esac
      fi ;;
    *) routed=na ;;
  esac
  # The LOCAL path's fact cannot change the routed grade, but a count that could
  # not be read is its own fault: warn, never "0 channels" and never na.
  case "${maildirs}" in ''|*[!0-9]*) printf 'warn\n'; return 0 ;; esac
  printf '%s\n' "${routed}"
}

# doctor_check_send_paths <entry> [cwd]
doctor_check_send_paths() {
  local entry="$1" cwd="${2:-.}" rc reg session maildirs names state facts dflt bearer lookup_err
  [ -n "${entry}" ] || return 0
  # A lookup that could not be MADE (status 2: a key computed wrongly, no
  # repository) is its own state with its own words -- never "not registered".
  lookup_err="$(inbox_mcp_registration "${cwd}" 2>&1 >/dev/null)"; rc=$?
  case "${rc}" in 0) reg=registered ;; 1) reg=unregistered ;; 3) reg=broken ;; *) reg=error ;; esac
  if [ -n "${ATHENA_MCP_BEARER:-}" ]; then bearer=set; else bearer=unset; fi
  session="$(inbox_session_state_of_entry "${entry}")"
  names="$(printf '%s' "${entry}" | jq -r '[.channels // {} | to_entries[] | select(.value.kind == "maildir") | .key] | join(", ")' 2>/dev/null)"
  maildirs="$(printf '%s' "${entry}" | jq -r '[.channels // {} | to_entries[] | select(.value.kind == "maildir")] | length' 2>/dev/null)"
  state="$(doctor_state_send_paths "${reg}" "${session}" "${DOCTOR_REACHABLE}" "${bearer}" "${maildirs}")"
  case "${state}" in
    ok) dflt="a server-addressed send ROUTES" ;;
    *)  if [ "${reg}" = "registered" ] && [ "${session}" = "declared" ] && [ "${bearer}" = "set" ] \
             && { [ "${DOCTOR_REACHABLE}" = "not-asked" ] || [ "${DOCTOR_REACHABLE}" = "skipped-no-token" ]; }; then
          dflt="a server-addressed send routes only if machine_reachable answers true when it is sent"
        else
          dflt="a server-addressed send is REFUSED (use --routed for another machine, --local for this one)"
        fi ;;
  esac
  facts="routed: athena MCP ${reg}$( [ "${reg}" = "error" ] && printf ' (the registration lookup itself failed: %s)' "$(printf '%s' "${lookup_err}" | head -n 1)") for this project, session inbox ${session}, ATHENA_MCP_BEARER ${bearer} in this shell, this machine reachable: ${DOCTOR_REACHABLE} (asked with the client config's machine token; send-mail asks with ATHENA_MCP_BEARER, the same token when the session was launched through scripts/athena); local: $(case "${maildirs}" in ''|*[!0-9]*) printf 'maildir channel count UNREADABLE (the registry entry could not be counted)' ;; *) printf '%s maildir channel(s)%s' "${maildirs}" "${names:+ (${names})}" ;; esac); no-flag default: a maildir-addressed send goes LOCAL, ${dflt}. Neither path carries authority."
  case "${state}" in
    ok)   doctor_finding ok "send-paths" "${facts}" ;;
    warn) doctor_finding warn "send-paths" "${facts}" \
            "if the maildir channel count is UNREADABLE, run inbox-status and check this project's registry entry parses; if ATHENA_MCP_BEARER is unset, launch the session through scripts/athena (it exports it for that launch only); if the registration cannot be read, inspect ~/.claude.json's athena entry for this project by hand; if the session inbox is missing or invalid, declare the \"session\" log channel (ai/inbox/registry.json, scripts/setup-inbox-registry --install); if this machine is not reachable, read client-liveness and server-reachability above. Until then send cross-machine mail with --routed (the server holds it pending) and same-machine mail with --local." ;;
    *)    doctor_finding na "send-paths" "${facts}" \
            "routed sending is not configured or not checked here. To enable it: scripts/add-athena-mcp from the main checkout, launch through scripts/athena, declare the \"session\" channel. If reachability was not asked: run inbox-doctor without --no-server (not-asked), or install the inbox client's machine token (skipped-no-token) -- send-mail itself asks at send time with ATHENA_MCP_BEARER. The local maildir path does not depend on any of this." ;;
  esac
}

# --- unread failed-delivery records via the machine token (DND-373) ---------
#
# The server records every terminal delivery failure, and every machine-
# unreachable transition, in its failed-delivery store and emails the owner once
# per new/re-opened record. Until the owner marks a record read it stays unread,
# and this check says so: it asks the `failed_deliveries` MCP tool (same /mcp,
# same machine token, same four outcomes as server-reachability above) for the
# account's UNREAD records.
#
#   skipped / disabled / UNAVAILABLE  na -- exactly as server-reachability;
#                         "unavailable" never reads like "0 unread".
#   checked, 0 unread     ok -- says "0 unread" in those words.
#   checked, N > 0 unread warn -- NOT ok, with each record's cause/count/id and a
#                         Fix naming mark_read.
#
# Seam: ATHENA_INBOX_DOCTOR_FAILED_DELIVERIES_FILE holds a canned tool result
# (a JSON object, or `UNAVAILABLE:<reason>`) and skips the network.

# doctor_failed_deliveries
# Prints the failed_deliveries tool result (a JSON object with a numeric
# unread_count) on success. Status as doctor_mcp_tool_call.
doctor_failed_deliveries() {
  local out rc
  out="$(doctor_mcp_tool_call failed_deliveries '{}' "${ATHENA_INBOX_DOCTOR_FAILED_DELIVERIES_FILE:-}")"; rc=$?
  [ "${rc}" -eq 0 ] || { printf '%s\n' "${out}"; return "${rc}"; }
  if ! printf '%s' "${out}" | jq -e 'type == "object" and (.unread_count | type == "number")' >/dev/null 2>&1; then
    printf 'the failed_deliveries answer carried no numeric unread_count\n'; return 4
  fi
  printf '%s\n' "${out}"
}

# doctor_state_failed_deliveries <unread-count>
# Pure. 0 -> ok · a positive integer -> warn · anything else -> na, including a
# digit string too large for a shell integer: an unmeasurable count must never
# fall through to "0 unread".
doctor_state_failed_deliveries() {
  case "$1" in
    ''|*[!0-9]*) printf 'na\n'; return 0 ;;
  esac
  if [ "$1" -gt 0 ] 2>/dev/null; then printf 'warn\n'
  elif [ "$1" -eq 0 ] 2>/dev/null; then printf 'ok\n'
  else printf 'na\n'
  fi
}

# doctor_check_server_failed_deliveries
doctor_check_server_failed_deliveries() {
  local out rc n records first_id shown canned_note=""
  if [ "${DOCTOR_NO_SERVER:-0}" = "1" ]; then
    doctor_finding na "server-failed-deliveries" "server failed-deliveries check not run (disabled for this invocation)" \
      "run inbox-doctor by hand (without --no-server) to ask the server for your unread failed-delivery records; the unprompted SessionStart path deliberately makes no network request."
    return 0
  fi
  out="$(doctor_failed_deliveries)"; rc=$?
  [ -n "${ATHENA_INBOX_DOCTOR_FAILED_DELIVERIES_FILE:-}" ] && canned_note=" [CANNED answer from ATHENA_INBOX_DOCTOR_FAILED_DELIVERIES_FILE, not the live server]"
  case "${rc}" in
    2) doctor_finding na "server-failed-deliveries" "server failed-deliveries check SKIPPED -- no client config or machine token on this machine" \
         "this check authenticates with the inbox client's machine token (~/.config/athena-inbox-client/config.json); a machine that only reads delivered mail has none, and this is expected there."
       return 0 ;;
    4) doctor_finding na "server-failed-deliveries" "server failed-deliveries check UNAVAILABLE (tried, got no answer; this is NOT 0 unread): $(printf '%s' "${out}" | head -n 1)${canned_note}" \
         "the server was asked and could not answer, so the unread count is unknown. If failed_deliveries is not deployed yet (DND-373), this is expected until it is; otherwise check the network, the /mcp endpoint, and that the machine token in the client config is current."
       return 0 ;;
    0) ;;
    *) doctor_finding na "server-failed-deliveries" "server failed-deliveries check UNAVAILABLE (unexpected status ${rc})" \
         "re-run inbox-doctor; if it persists, check doctor_failed_deliveries in lib/doctor.sh."
       return 0 ;;
  esac
  n="$(printf '%s' "${out}" | jq -r '.unread_count | tostring')"
  records="$(printf '%s' "${out}" | jq -r '[(.failed_deliveries // [])[:5][] | "\(.cause) x\(.count) (id \(.id))"] | join("; ")' 2>/dev/null)"
  shown="$(printf '%s' "${out}" | jq -r '[(.failed_deliveries // [])[:5][]] | length' 2>/dev/null)"
  first_id="$(printf '%s' "${out}" | jq -r '(.failed_deliveries // [])[0].id // "<id>"' 2>/dev/null)"
  case "$(doctor_state_failed_deliveries "${n}")" in
    ok)   doctor_finding ok "server-failed-deliveries" "checked: 0 unread failed-delivery records on the server${canned_note}" ;;
    warn) doctor_finding warn "server-failed-deliveries" "checked: the server holds ${n} UNREAD failed-delivery record(s) for your account (showing ${shown:-0} of ${n}): ${records:-none listed}${canned_note}" \
            "triage each record (the failed_deliveries MCP tool returns its report: what failed and where), then clear it with the failed_deliveries MCP tool and mark_read: \"${first_id}\" (one call per id). The server emailed the owner once when each record was new or re-opened." ;;
    na)   doctor_finding na "server-failed-deliveries" "the server answered failed_deliveries with no usable count (unread_count: ${n})" \
            "the answer shape may have changed; failed_deliveries should return a numeric unread_count." ;;
  esac
}
