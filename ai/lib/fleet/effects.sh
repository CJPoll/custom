#!/usr/bin/env bash
# effects.sh -- SIDE EFFECTS. Every outside-world touch fleet-report makes:
# the machine-token config, ~/.claude.json, git, the inbox registry, the
# throttle stamps, and the HTTP POST. Each function returns a status the
# manager maps; none of them decides policy (that is domain.sh).
#
# THE TOKEN NEVER TOUCHES ARGV, THE ENVIRONMENT, OR A FILE WE WRITE. It is read
# by jq from the 0600 client config (jq's argv holds only the path), held in a
# shell variable, and written by the `printf` builtin into a curl config that
# curl reads on STDIN (`--config -`). `ps` and /proc/<pid>/cmdline never see
# it; the suite proves that by scanning /proc while a request is in flight.
#
# Source order: domain.sh, then the athena:inbox libs in inbox-status's order
# ending with inbox.sh (repo identity and the registry are THAT skill's rules,
# reused rather than re-implemented), then this file. The hook, which never
# resolves a repo or sends, may source this file without them.

# fleet_client_config_path -- the inbox client's config, which holds the
# machine token. Same resolution as athena:inbox's doctor.sh.
fleet_client_config_path() {
  printf '%s\n' "${ATHENA_INBOX_CLIENT_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/athena-inbox-client/config.json}"
}

# fleet_claude_json_path -- where Claude Code records MCP registrations.
fleet_claude_json_path() {
  printf '%s\n' "${FLEET_CLAUDE_JSON:-${HOME}/.claude.json}"
}

# fleet_read_token
# Prints the machine token. Statuses, never folded together:
#   1 -- the config file does not exist (this machine has no inbox client);
#   3 -- it exists but is unreadable, not JSON, or has no non-empty `token`.
fleet_read_token() {
  local cfg tok
  cfg="$(fleet_client_config_path)"
  [ -e "${cfg}" ] || return 1
  tok="$(jq -r 'if type == "object" and (.token | type) == "string" then .token else empty end' "${cfg}" 2>/dev/null)" || return 3
  [ -n "${tok}" ] || return 3
  printf '%s\n' "${tok}"
}

# fleet_main_checkout_of <git-common-dir>
# The main checkout that owns a common dir: its parent. The athena MCP server is
# registered in Claude Code's local scope keyed by a main checkout.
fleet_main_checkout_of() {
  printf '%s\n' "${1%/.git}"
}

# fleet_mcp_url <key>...
# The registered `athena` MCP URL: local scope for each absolute key in order,
# then user scope. Statuses:
#   1 -- ~/.claude.json does not exist, or names no athena server anywhere;
#   2 -- a key is not absolute (computed wrongly: an internal error);
#   3 -- the file cannot be parsed, or the athena entry has no string url.
fleet_mcp_url() {
  local cfg k keys='[]' entry url
  cfg="$(fleet_claude_json_path)"
  for k in "$@"; do
    [ -n "${k}" ] || continue
    case "${k}" in /*) ;; *) return 2 ;; esac
    keys="$(jq -c --arg k "${k}" '. + [$k]' <<<"${keys}")"
  done
  [ -e "${cfg}" ] || return 1
  entry="$(jq -c --argjson ks "${keys}" '
      ([ $ks[] as $k | .projects[$k]?.mcpServers?.athena? | select(. != null) ] | first)
      // .mcpServers?.athena? // null' "${cfg}" 2>/dev/null)" || return 3
  [ -n "${entry}" ] || return 3
  [ "${entry}" != "null" ] || return 1
  url="$(jq -r 'if type == "object" and (.url | type) == "string" then .url else empty end' <<<"${entry}" 2>/dev/null)"
  [ -n "${url}" ] || return 3
  printf '%s\n' "${url}"
}

# fleet_resolve_repo <cwd>
# Prints "<project>\t<repo_key>" for the session rooted at <cwd>. It is resolved
# NOW, at the point of capture, never later (athena-inbox.md -> *Repo identity:
# the git common dir*):
#   * repo_key -- the realpath of the git common dir, expanded against <cwd>
#     (athena:inbox's `inbox_repo_key`, its public identity API, which does the
#     DND-183 expansion of the cwd-relative `.git` a main checkout returns). A
#     cwd that git says is DEFINITELY in no work tree keys by its own realpath
#     (contract, *Fleet report kinds and their closed schema* -> `project`).
#   * project  -- the basename of the ONE registry entry whose `repo` equals
#     repo_key; empty (reported as null) when no entry names it.
# Statuses:
#   2 -- <cwd> is not an existing absolute directory;
#   3 -- COULD NOT TELL whether <cwd> is in a repo (no git, dubious ownership,
#        a corrupt .git): never guessed as "not a repo";
#   4 -- two registry files claim this repo (ambiguous; never pick one);
#   5 -- no entry matched AND some registry file was unparseable: the broken
#        one may be this repo's, so "no project" would be a guess.
fleet_resolve_repo() {
  local cwd="$1" key json src match="" matches=0 unparseable=0
  case "${cwd}" in /*) ;; *) return 2 ;; esac
  [ -d "${cwd}" ] || return 2
  key="$(inbox_repo_key "${cwd}")" || return 3
  if [ -z "${key}" ]; then
    key="$(realpath -q -- "${cwd}")" || return 2
  fi
  case "${key}" in /*) ;; *) return 2 ;; esac
  while IFS=$'\t' read -r json src; do
    [ -n "${json}" ] || continue
    if [ "${json}" = "#unparseable" ]; then unparseable="${src}"; continue; fi
    [ "$(descriptor_repo_key "${json}")" = "${key}" ] || continue
    matches=$((matches + 1))
    match="${src##*/}"; match="${match%.json}"
  done < <(fs_registry_records)
  [ "${matches}" -le 1 ] || return 4
  if [ "${matches}" -eq 0 ] && [ "${unparseable}" != "0" ]; then return 5; fi
  printf '%s\t%s\n' "${match}" "${key}"
}

# fleet_post <url> <token> <body-json> -- one POST (fleet_request).
fleet_post() {
  fleet_request POST "$1" "$2" "$3"
}

# fleet_get <url> <token> -- one GET with no body (fleet_request).
fleet_get() {
  fleet_request GET "$1" "$2" ""
}

# fleet_request <method> <url> <token> <body-json-or-empty>
# One request. Sets FLEET_CURL_RC, FLEET_HTTP_CODE and FLEET_RESPONSE (the
# body, at most FLEET_RESPONSE_MAX bytes, default 4 KiB). Returns 0 once curl
# ran (whatever it answered), 1 when the request could not be built (no curl,
# unsafe value, no temp dir): nothing was sent then.
fleet_request() {
  local method="$1" url="$2" token="$3" body="$4" w
  FLEET_CURL_RC=""; FLEET_HTTP_CODE=""; FLEET_RESPONSE=""
  command -v curl >/dev/null 2>&1 || { FLEET_POST_REASON="curl is not on PATH"; return 1; }
  names_safe_curl_config_value "${url}" || { FLEET_POST_REASON="the server URL contains a quote, backslash, whitespace or control character"; return 1; }
  names_safe_curl_config_value "${token}" || { FLEET_POST_REASON="the machine token contains a quote, backslash, whitespace or control character"; return 1; }
  w="$(mktemp -d 2>/dev/null)" || { FLEET_POST_REASON="could not create a private temp dir"; return 1; }
  # The caller's EXIT trap removes this if we are killed mid-request.
  FLEET_POST_TMP="${w}"
  chmod 700 "${w}"
  names_safe_curl_config_value "${w}" || { rm -rf "${w}"; FLEET_POST_REASON="the temp dir path (from \$TMPDIR) is not safe to put in a curl config"; return 1; }
  [ "${method}" = "POST" ] && printf '%s' "${body}" > "${w}/req.json"
  FLEET_HTTP_CODE="$(
    {
      printf 'url = "%s"\n' "${url}"
      printf 'request = "%s"\n' "${method}"
      printf 'header = "Authorization: Bearer %s"\n' "${token}"
      printf 'header = "Accept: application/json"\n'
      if [ "${method}" = "POST" ]; then
        printf 'header = "Content-Type: application/json"\n'
        printf 'data-binary = "@%s/req.json"\n' "${w}"
      fi
      printf 'output = "%s/resp"\n' "${w}"
      printf 'write-out = "%%{http_code}"\n'
      printf 'connect-timeout = %s\n' "$(fleet_seconds "${FLEET_CONNECT_TIMEOUT_S:-}" 5)"
      printf 'max-time = %s\n' "$(fleet_seconds "${FLEET_MAX_TIME_S:-}" 10)"
      printf 'silent\n'
    } | curl --config - 2>/dev/null
  )"
  FLEET_CURL_RC=$?
  FLEET_RESPONSE="$(head -c "${FLEET_RESPONSE_MAX:-4096}" "${w}/resp" 2>/dev/null)"
  rm -rf "${w}"
  FLEET_POST_TMP=""
  return 0
}

# fleet_read_file <path> -- a readable regular file's contents; status 1 if not.
fleet_read_file() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  cat -- "$1"
}

# fleet_state_dir
# $XDG_STATE_HOME/athena/fleet (default ~/.local/state/athena/fleet). A set
# but non-absolute XDG_STATE_HOME is refused (status 2), never resolved against
# whatever the cwd happens to be (contract, *Unknown control state* ->
# invalid-cache-path; the same rule for this directory's other tenant).
fleet_state_dir() {
  local base="${XDG_STATE_HOME:-${HOME}/.local/state}"
  case "${base}" in /*) ;; *) return 2 ;; esac
  printf '%s/athena/fleet\n' "${base}"
}

# fleet_seen_dir -- the throttle stamps. A
# subdirectory, so nothing here can collide with the control cache
# (<fleet>/<claude_session_id>.json, DND-443).
fleet_seen_dir() {
  local d
  d="$(fleet_state_dir)" || return 2
  printf '%s/seen\n' "${d}"
}

# --- the failure log ----------------------------------------------------------
# A report the hook sends in the background has nobody to print to: hook stderr
# on exit 0 reaches neither the model nor, outside verbose mode, the human. So
# every such failure is APPENDED to one machine-wide log, which is never
# truncated by being read. The SessionStart hook announces lines it has not
# announced before (a marker holds the last announced epoch) on its stdout,
# which Claude Code adds to the new session's context.
#
# Line format: <epoch-ns>\t<iso-utc>\t<session_id or ->\t<kind>\t<message with Fix:>
# The first field is NANOSECONDS so the announcement marker cannot skip a line
# logged in the same second as the last one it announced.

FLEET_FAILURE_LOG_MAX_BYTES=262144

# fleet_failure_log_path -- <fleet>/report-failures.log (status 2 if the state
# dir is unusable).
fleet_failure_log_path() {
  local d
  d="$(fleet_state_dir)" || return 2
  printf '%s/report-failures.log\n' "${d}"
}

# fleet_record_failure <session_id> <kind> <message>
# Appends one line under an flock, rotating the log to `.1` (one generation)
# past FLEET_FAILURE_LOG_MAX_BYTES. Status 2 when the log cannot be written.
fleet_record_failure() {
  local sid="${1:--}" kind="$2" msg="$3" log now size
  log="$(fleet_failure_log_path)" || return 2
  mkdir -p -- "${log%/*}" 2>/dev/null || return 2
  msg="$(printf '%s' "${msg}" | tr '\t\n' '  ')"
  (
    exec 8>>"${log}.lock" || exit 2
    flock -w 5 8 || exit 2
    size="$(stat -c %s -- "${log}" 2>/dev/null || echo 0)"
    if [ "${size}" -gt "${FLEET_FAILURE_LOG_MAX_BYTES}" ]; then mv -f -- "${log}" "${log}.1" || exit 2; fi
    # Stamped under the lock, so the ns values are strictly increasing in file order.
    now="$(date +%s%N)"
    printf '%s\t%s\t%s\t%s\t%s\n' "${now}" "$(date -u -d "@${now%?????????}" +%Y-%m-%dT%H:%M:%SZ)" "${sid}" "${kind}" "${msg}" >> "${log}" || exit 2
  )
}

# fleet_failures_since <epoch-ns>
# Prints every logged failure line newer than <epoch-ns>, oldest first, across
# the rotated generation and the live log. The comparison is on digit strings
# (longer is larger, then lexical): a 19-digit ns value exceeds awk's exact
# float range, so a numeric compare could call two different values equal.
fleet_failures_since() {
  local log since="${1:-0}"
  log="$(fleet_failure_log_path)" || return 2
  cat -- "${log}.1" "${log}" 2>/dev/null | awk -F'\t' -v m="${since}" '
    $1 ~ /^[0-9]+$/ && (length($1) > length(m) || (length($1) == length(m) && ($1 "") > (m "")))'
}

# fleet_surfaced_marker_path -- the epoch of the last failure line announced.
fleet_surfaced_marker_path() {
  local d
  d="$(fleet_state_dir)" || return 2
  printf '%s/report-failures.surfaced\n' "${d}"
}

# fleet_read_surfaced_marker -- the last announced epoch-ns, or 0 when absent
# or not digits (status 2 when the state dir is unusable).
fleet_read_surfaced_marker() {
  local p v
  p="$(fleet_surfaced_marker_path)" || return 2
  v="$(cat -- "${p}" 2>/dev/null)"
  case "${v}" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s\n' "${v}"
}

# fleet_write_surfaced_marker <epoch-ns> -- atomic replace.
fleet_write_surfaced_marker() {
  local p
  p="$(fleet_surfaced_marker_path)" || return 2
  printf '%s\n' "$1" > "${p}.tmp" && mv -f -- "${p}.tmp" "${p}"
}

# fleet_delete_stale_stamps <minutes> -- remove throttle stamps older than that.
fleet_delete_stale_stamps() {
  local d
  d="$(fleet_seen_dir)" || return 2
  find "${d}" -maxdepth 1 -name '*.stamp' -mmin "+$1" -delete 2>/dev/null
}

# fleet_mtime <path> -- epoch mtime, or nothing when absent.
fleet_mtime() {
  stat -c %Y -- "$1" 2>/dev/null
}

# fleet_throttle_claim <key> <now-epoch>
# Status 0 = this caller claimed the report and stamped it; 1 = not due (or a
# concurrent caller holds the claim). The check and the stamp happen under an
# flock on the stamp, so two parallel tool calls in one agent cannot both pass.
# Status 2 = the stamp directory cannot be resolved or created.
fleet_throttle_claim() {
  local key="$1" now="$2" dir stamp rc
  dir="$(fleet_seen_dir)" || return 2
  mkdir -p -- "${dir}" 2>/dev/null || return 2
  stamp="${dir}/${key}.stamp"
  (
    exec 9>>"${stamp}" || exit 2
    flock -n 9 || exit 1
    # An EMPTY stamp was just created by the `>>` above: not a prior report.
    if [ -s "${stamp}" ]; then
      fleet_seen_due "${now}" "$(fleet_mtime "${stamp}")" || exit 1
    fi
    printf '%s\n' "${now}" > "${stamp}" || exit 2
    exit 0
  )
  rc=$?
  return "${rc}"
}
