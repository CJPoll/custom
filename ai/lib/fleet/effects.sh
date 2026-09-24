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
# Source order: domain.sh, then the athena:inbox libs err.sh, names.sh, fs.sh,
# descriptor.sh (repo identity and the registry are THAT skill's rules, reused
# rather than re-implemented), then this file.

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
#     (fs_git_common_dir does the DND-183 expansion of the cwd-relative `.git`
#     a main checkout returns). A cwd in no git repo keys by its own realpath.
#   * project  -- the basename of the ONE registry entry whose `repo` equals
#     repo_key; empty (reported as null) when no entry names it.
# Statuses:
#   2 -- <cwd> is not an existing absolute directory;
#   4 -- two registry files claim this repo (ambiguous; never pick one);
#   5 -- no entry matched AND some registry file was unparseable: the broken
#        one may be this repo's, so "no project" would be a guess.
fleet_resolve_repo() {
  local cwd="$1" key json src match="" matches=0 unparseable=0
  case "${cwd}" in /*) ;; *) return 2 ;; esac
  [ -d "${cwd}" ] || return 2
  if ! key="$(fs_git_common_dir "${cwd}")" || [ -z "${key}" ]; then
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

# fleet_post <url> <token> <body-json>
# One POST. Sets FLEET_CURL_RC, FLEET_HTTP_CODE and FLEET_RESPONSE (the body,
# at most 4 KiB). Returns 0 once curl ran (whatever it answered), 1 when the
# request could not be built (no curl, unsafe value, no temp dir): nothing was
# sent then.
fleet_post() {
  local url="$1" token="$2" body="$3" w
  FLEET_CURL_RC=""; FLEET_HTTP_CODE=""; FLEET_RESPONSE=""
  command -v curl >/dev/null 2>&1 || { FLEET_POST_REASON="curl is not on PATH"; return 1; }
  names_safe_curl_config_value "${url}" || { FLEET_POST_REASON="the server URL contains a quote, backslash, whitespace or control character"; return 1; }
  names_safe_curl_config_value "${token}" || { FLEET_POST_REASON="the machine token contains a quote, backslash, whitespace or control character"; return 1; }
  w="$(mktemp -d 2>/dev/null)" || { FLEET_POST_REASON="could not create a private temp dir"; return 1; }
  chmod 700 "${w}"
  names_safe_curl_config_value "${w}" || { rm -rf "${w}"; FLEET_POST_REASON="the temp dir path (from \$TMPDIR) is not safe to put in a curl config"; return 1; }
  printf '%s' "${body}" > "${w}/req.json"
  FLEET_HTTP_CODE="$(
    {
      printf 'url = "%s"\n' "${url}"
      printf 'request = "POST"\n'
      printf 'header = "Authorization: Bearer %s"\n' "${token}"
      printf 'header = "Content-Type: application/json"\n'
      printf 'header = "Accept: application/json"\n'
      printf 'data-binary = "@%s/req.json"\n' "${w}"
      printf 'output = "%s/resp"\n' "${w}"
      printf 'write-out = "%%{http_code}"\n'
      printf 'connect-timeout = %s\n' "$(fleet_seconds "${FLEET_CONNECT_TIMEOUT_S:-}" 5)"
      printf 'max-time = %s\n' "$(fleet_seconds "${FLEET_MAX_TIME_S:-}" 10)"
      printf 'silent\n'
    } | curl --config - 2>/dev/null
  )"
  FLEET_CURL_RC=$?
  FLEET_RESPONSE="$(head -c 4096 "${w}/resp" 2>/dev/null)"
  rm -rf "${w}"
  return 0
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

# fleet_seen_dir -- the throttle stamps and per-session last-error files. A
# subdirectory, so nothing here can collide with the control cache
# (<fleet>/<claude_session_id>.json, DND-443).
fleet_seen_dir() {
  local d
  d="$(fleet_state_dir)" || return 2
  printf '%s/seen\n' "${d}"
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
