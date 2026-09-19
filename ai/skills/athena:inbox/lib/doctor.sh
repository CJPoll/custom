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
# Source order: err.sh, names.sh, descriptor.sh, logchan.sh, fs.sh, inbox.sh,
# then this file. Requires jq; curl only when the server check is enabled.

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
  case "${ts}" in ''|*[!0-9-]*) printf 'na\n'; return 0 ;; esac
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
# partial line. Returns 0 always; prints the reason it carries (its first line),
# which is the supervisor's own text about an inbox file, never message content.
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
    [ -e "${f}" ] || continue
    base="${f##*/}"
    case "${base}" in .|..) continue ;; esac
    # A well-formed, parseable, repo-bearing *.json is a usable entry -- not a
    # skip. Everything else is reported.
    case "${base}" in
      *.json) name="${base%.json}" ;;
      *)
        doctor_finding warn "skipped-file" "projects/ holds a non-entry file: ${base} (does not end in .json, so it was never a registry entry)" \
          "if ${base} is a stray backup or editor swapfile, remove it; a file in projects/ that is not a *.json entry is ignored but clutters the tenancy directory."
        any=1
        continue
        ;;
    esac
    if ! names_valid_segment "${name}"; then
      doctor_finding warn "skipped-file" "projects/ holds a *.json whose name fails the entry grammar: ${base}" \
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
      "run ai/bin/check-inbox-registry from the main checkout (it owns the committed source of truth); this cross-check needs ruby and ai/inbox/registry.rb."
    return 0
  fi
  local f
  for f in "${dir}"/*.json; do
    [ -e "${f}" ] || continue
    [ -f "${f}" ] && [ ! -L "${f}" ] || continue
    base="${f##*/}"
    name="${base%.json}"
    names_valid_segment "${name}" || continue
    if ! printf '%s\n' "${declared}" | grep -qxF "${base}"; then
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
# path). INFORMATIONAL.
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
    doctor_finding na "registry-entry" "this project has no registry entry (not in a repo, or none names this repo)" \
      "if this project should receive mail, add \$ATHENA_INBOX_ROOT/projects/<project>.json whose \"repo\" is realpath \"\$(git rev-parse --git-common-dir)\"."
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
  local entry="$1" chan="$2" resolved kind
  resolved="$(descriptor_resolve "$(fs_inbox_root)" "${entry}" "${chan}" 2>/dev/null)" || return 0
  kind="$(inbox_field kind "${resolved}")"
  case "${kind}" in
    log)     doctor_check_log_channel "${chan}" "${resolved}" ;;
    maildir) doctor_check_maildir_channel "${chan}" "${resolved}" ;;
  esac
}

doctor_check_log_channel() {
  local chan="$1" resolved="$2" inbox state one now rotated rot_epoch mode st mt age
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
    doctor_finding warn "channel:${chan}" "log channel \"${chan}\" has never received anything (${inbox##*/} does not exist)" \
      "register this channel's producer -- a server-side agent instance mapped to ${inbox##*/} in the client config; an unregistered producer and an empty channel look identical on disk."
    return 0
  fi

  # Permissions + freshness apply to the LIVE file when it exists.
  if [ -e "${inbox}" ]; then
    mode="$(stat -c '%a' "${inbox}" 2>/dev/null)"
    st="$(doctor_state_mode "${mode}" "600")"
    [ "${st}" = "warn" ] && doctor_finding warn "channel:${chan}" "the channel file ${inbox##*/} is mode 0${mode}, expected 0600" \
      "chmod 0600 ${inbox}; message surfaces under the root are private."
    if mt="$(fs_mtime_epoch "${inbox}" 2>/dev/null)"; then
      age=$(( now - mt ))
      doctor_finding ok "channel:${chan}" "log channel \"${chan}\" last changed ${age}s ago"
    fi
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
  doctor_check_lock "${chan}" "$(inbox_field lock "${resolved}")"
}

# doctor_check_lock <chan> <lock-path>
# READ-ONLY. A held lock (flock -n fails) means a live designated consumer -- ok.
# A lock file whose recorded pid is DEAD and which nothing holds is REAPABLE
# residue: reported, NEVER reaped (the ticket's hard constraint). flock is the
# authority; the pid inside is diagnostics only.
doctor_check_lock() {
  local chan="$1" lock="$2" pid
  [ -n "${lock}" ] && [ -e "${lock}" ] || return 0
  [ -f "${lock}" ] && [ ! -L "${lock}" ] || return 0
  if ! command -v flock >/dev/null 2>&1; then
    return 0
  fi
  # A NON-BLOCKING probe in a SUBSHELL so the descriptor closes immediately and
  # this probe never becomes the holder. If flock -n fails, a live consumer
  # holds it -> healthy.
  if ( exec 9<>"${lock}" && flock -n 9 ) 2>/dev/null; then
    # Nobody holds it. Is its recorded pid dead? Then it is leftover diagnostics.
    pid="$(jq -r '.pid // empty' <"${lock}" 2>/dev/null)"
    if [ -n "${pid}" ] && ! doctor_pid_alive "${pid}"; then
      doctor_finding warn "channel:${chan}" "channel \"${chan}\" has a consumer lock whose recorded pid ${pid} is dead and which nothing holds -- it is reapable residue" \
        "safe to remove ${lock} by hand; the kernel already released the flock when that process died, so it blocks nothing. The doctor never reaps it for you."
    fi
  fi
}

# --- server checks (opt-in) -------------------------------------------------

# doctor_server_health
# Fetch GET <base>/api/machines/<id>/health as the caller's user API token.
# The token is NEVER in argv and NEVER logged: it reaches curl only through a
# 0600 config file as an Authorization header, exactly as athena:slack does.
# Steerable: ATHENA_INBOX_DOCTOR_HEALTH_FILE feeds canned JSON and skips curl
# entirely, which is the test seam and also lets an owner diagnose from a saved
# response. Prints the response JSON on stdout; status 1 on any failure.
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

  tmp="$(mktemp -d 2>/dev/null)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  (
    umask 077
    {
      printf 'url = "%s/api/machines/%s/health"\n' "${base%/}" "${id}"
      printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\r\n' <"${tokfile}")"
      printf 'output = %s\n' "${tmp}/resp.json"
      printf 'write-out = "%%{http_code}"\n'
      printf 'max-time = %s\n' "${ATHENA_INBOX_DOCTOR_HTTP_TIMEOUT:-10}"
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
    if ! printf '%s\n' "${server_names}" | grep -qxF "${key}"; then
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
    if ! printf '%s\n' "${claimed}" | grep -qxF "${inbox_name}"; then
      # INFORMATIONAL (its own check name), not an override error: an unclaimed
      # instance is bookkeeping, not a broken running chain, and must not flip
      # the chain's health or nag every session. Same class as an undeclared
      # committed-list entry and a collision.
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
