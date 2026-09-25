# lib/slack.sh -- shared Slack Web API plumbing for the athena:slack scripts.
# Sourced, never run. Callers set `set -eu` themselves.
#
# WHY A SHARED LIB. Every script here has the same four ways to go wrong, and
# three of them are silent unless someone writes the check down once:
#
#   1. Slack answers HTTP 200 with {"ok":false,"error":"..."} for almost every
#      failure -- a bad channel, a missing scope, an expired token. A script
#      that trusts the status line reports success for all of them. Every
#      response goes through _slack_request, which checks `.ok` and exits
#      non-zero with the error on stderr.
#   2. The token is a workspace-wide credential. It is NEVER placed in argv
#      (world-readable via ps), never in a URL, never logged. It reaches curl
#      only through a 0600 config file as an Authorization header.
#   3. Rate limits arrive as HTTP 429 with Retry-After. Ignoring them turns a
#      throttle into a failure.
#   4. Paginated methods silently truncate at the first page unless the caller
#      follows response_metadata.next_cursor.

SLACK_API_BASE="${SLACK_API_BASE:-https://slack.com/api}"
SLACK_CACHE_DIR="${SLACK_CACHE_DIR:-$HOME/.cache/athena-slack}"
SLACK_TOKEN_FILE="${SLACK_TOKEN_FILE:-$HOME/.claude/slack-bot-token}"
SLACK_TIMEOUT="${SLACK_TIMEOUT:-20}"
SLACK_MAX_RETRIES="${SLACK_MAX_RETRIES:-3}"
# Cache lifetimes, in minutes. Users and channels change rarely; identity
# essentially never (a new bot token would be a new install).
SLACK_USERS_TTL_MIN="${SLACK_USERS_TTL_MIN:-1440}"
SLACK_CHANNELS_TTL_MIN="${SLACK_CHANNELS_TTL_MIN:-1440}"
SLACK_IDENTITY_TTL_MIN="${SLACK_IDENTITY_TTL_MIN:-10080}"

# ---------------------------------------------------------------- diagnostics

# Every failure path. Exits 1 with a one-line reason on stderr. It must never
# interpolate the token or a message body -- callers pass a fixed reason plus,
# at most, an API method name and Slack's own error code.
slack_die() {
  printf 'athena-slack: %s\n' "$1" >&2
  exit 1
}

# Prints a script's header comment -- its usage block -- on STDOUT. Each bin
# calls it from a `-h|--help` branch placed BEFORE slack_need_tools and any
# argument parsing, so help never touches the token, the network, or stdin
# (DND-508: `post --help` used to take "--help" as the channel and read stdin as
# the message).
slack_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}

slack_need_tools() {
  for _tool in curl jq; do
    command -v "$_tool" >/dev/null 2>&1 || slack_die "missing required tool: $_tool"
  done
}

# ---------------------------------------------------------------------- token

# Sets $SLACK_TOKEN_VALUE in the CURRENT shell. Deliberately not a
# `x="$(slack_token)"` accessor: slack_die inside a command substitution kills
# only the subshell, so a token failure would come back as an empty string and
# the script would sail on and make an unauthenticated request.
slack_load_token() {
  if [ -n "${SLACK_TOKEN_VALUE:-}" ]; then return 0; fi
  SLACK_TOKEN_VALUE="${SLACK_BOT_TOKEN:-}"
  if [ -z "$SLACK_TOKEN_VALUE" ] && [ -f "$SLACK_TOKEN_FILE" ]; then
    SLACK_TOKEN_VALUE="$(head -n1 "$SLACK_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')"
  fi
  if [ -z "$SLACK_TOKEN_VALUE" ]; then
    slack_die "no bot token: set \$SLACK_BOT_TOKEN or put one in $SLACK_TOKEN_FILE (chmod 600)"
  fi
  # The token is interpolated into a QUOTED curl-config value, where " and \
  # are escape characters. Slack tokens are [A-Za-z0-9-] in practice, so this
  # never fires; a token that did contain one would produce a malformed config
  # and a curl error indistinguishable from a network fault. Refuse by name.
  case "$SLACK_TOKEN_VALUE" in
    *'"'*|*\\*) slack_die "bot token contains characters that cannot be passed safely" ;;
  esac
  case "$SLACK_TOKEN_VALUE" in
    xoxb-*) ;;
    *) slack_die "token in $SLACK_TOKEN_FILE is not a bot token (expected xoxb-...)" ;;
  esac
  return 0
}

# ------------------------------------------------------------------ scratch

# Sets $SLACK_TMPDIR in the CURRENT shell, for the same reason slack_load_token
# does: a `$(...)` accessor would create the dir in a subshell whose EXIT trap
# then deletes it out from under the caller.
slack_tmp_init() {
  if [ -n "${SLACK_TMPDIR:-}" ]; then return 0; fi
  SLACK_TMPDIR="$(mktemp -d 2>/dev/null)" || slack_die "mktemp failed"
  trap 'rm -rf "$SLACK_TMPDIR"' EXIT
  trap 'rm -rf "$SLACK_TMPDIR"; exit 130' INT
  trap 'rm -rf "$SLACK_TMPDIR"; exit 143' TERM
  return 0
}

slack_urlencode() {
  printf '%s' "$1" | jq -sRr @uri
}

# ----------------------------------------------------------------- requesting

# _slack_request <GET|POST> <api.method> [body-file] [query-string]
# Prints the response JSON on stdout. Exits non-zero on transport failure, a
# non-2xx status, or {"ok":false}.
_slack_request() {
  _rq_verb="$1"
  _rq_api="$2"
  _rq_body="${3:-}"
  _rq_query="${4:-}"

  slack_load_token
  slack_tmp_init

  _rq_url="$SLACK_API_BASE/$_rq_api"
  if [ -n "$_rq_query" ]; then
    _rq_url="$_rq_url?$_rq_query"
  fi

  _rq_try=0
  while :; do
    _rq_try=$((_rq_try + 1))
    _rq_out="$SLACK_TMPDIR/resp.json"
    _rq_hdr="$SLACK_TMPDIR/resp.hdr"
    : > "$_rq_out"
    : > "$_rq_hdr"
    (
      umask 077
      {
        printf 'url = "%s"\n' "$_rq_url"
        printf 'request = "%s"\n' "$_rq_verb"
        printf 'header = "Authorization: Bearer %s"\n' "$SLACK_TOKEN_VALUE"
        if [ -n "$_rq_body" ]; then
          printf 'header = "Content-Type: application/json; charset=utf-8"\n'
          printf 'data = @%s\n' "$_rq_body"
        fi
        printf 'output = %s\n' "$_rq_out"
        printf 'dump-header = %s\n' "$_rq_hdr"
        printf 'write-out = "%%{http_code}"\n'
        printf 'max-time = %s\n' "$SLACK_TIMEOUT"
        printf 'silent\n'
      } > "$SLACK_TMPDIR/curlrc"
    ) || slack_die "could not write curl config"

    _rq_http="$(curl --config "$SLACK_TMPDIR/curlrc" 2>/dev/null)" \
      || slack_die "network error calling $_rq_api"

    if [ "$_rq_http" = "429" ]; then
      _rq_wait="$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_rq_hdr" 2>/dev/null | head -n1)"
      if [ -z "$_rq_wait" ]; then _rq_wait=1; fi
      if [ "$_rq_try" -le "$SLACK_MAX_RETRIES" ]; then
        printf 'athena-slack: rate limited on %s, waiting %ss (attempt %s)\n' \
          "$_rq_api" "$_rq_wait" "$_rq_try" >&2
        sleep "$_rq_wait"
        continue
      fi
      slack_die "$_rq_api rate limited after $SLACK_MAX_RETRIES retries"
    fi
    break
  done

  case "$_rq_http" in
    2??) ;;
    *) slack_die "$_rq_api returned HTTP $_rq_http" ;;
  esac

  # The load-bearing check: Slack says 200 and ok:false for nearly every real
  # failure, so a script that stops at the status line reports success.
  if ! jq -e '.ok == true' "$_rq_out" >/dev/null 2>&1; then
    _rq_err="$(jq -r '.error // "unparseable-response"' "$_rq_out" 2>/dev/null)"
    if [ -z "$_rq_err" ]; then _rq_err="unparseable-response"; fi
    _rq_needed="$(jq -r '.needed // empty' "$_rq_out" 2>/dev/null)"
    if [ -n "$_rq_needed" ]; then
      _rq_err="$_rq_err (needed scope: $_rq_needed)"
    fi
    slack_die "$_rq_api failed: $_rq_err"
  fi

  cat "$_rq_out"
}

# slack_post <api.method> <json-string>
slack_post() {
  slack_tmp_init
  printf '%s' "$2" > "$SLACK_TMPDIR/req.json" || slack_die "could not stage request body"
  _slack_request POST "$1" "$SLACK_TMPDIR/req.json" ""
}

# slack_post_empty <api.method>  -- POST with no body (auth.test)
slack_post_empty() {
  _slack_request POST "$1" "" ""
}

# slack_get <api.method> [query-string]
slack_get() {
  _slack_request GET "$1" "" "${2:-}"
}

# slack_paginate <api.method> <query-string> <jq-array-path>
# Emits the elements of the named array, one compact JSON object per line,
# following response_metadata.next_cursor to the end. Without this, every
# listing silently stops at the first page.
slack_paginate() {
  _pg_api="$1"
  _pg_query="$2"
  _pg_path="$3"
  _pg_cursor=""
  slack_tmp_init
  while :; do
    _pg_q="$_pg_query"
    if [ -n "$_pg_cursor" ]; then
      _pg_q="$_pg_q&cursor=$(slack_urlencode "$_pg_cursor")"
    fi
    slack_get "$_pg_api" "$_pg_q" > "$SLACK_TMPDIR/page.json"
    jq -c "$_pg_path"'[]?' "$SLACK_TMPDIR/page.json"
    _pg_cursor="$(jq -r '.response_metadata.next_cursor // ""' "$SLACK_TMPDIR/page.json")"
    if [ -z "$_pg_cursor" ]; then break; fi
  done
}

# --------------------------------------------------------------------- caches

slack_cache_dir() {
  mkdir -p "$SLACK_CACHE_DIR" 2>/dev/null || slack_die "cannot create $SLACK_CACHE_DIR"
}

# _slack_cache_fresh <file> <ttl-minutes>
_slack_cache_fresh() {
  if [ ! -f "$1" ]; then return 1; fi
  if [ -n "$(find "$1" -mmin -"$2" 2>/dev/null)" ]; then return 0; fi
  return 1
}

# Sets $SLACK_BOT_USER_ID and $SLACK_BOT_TEAM_ID from auth.test, cached.
slack_load_identity() {
  if [ -n "${SLACK_BOT_USER_ID:-}" ] && [ -n "${SLACK_BOT_TEAM_ID:-}" ]; then return 0; fi
  slack_cache_dir
  _id_file="$SLACK_CACHE_DIR/identity.json"
  if ! _slack_cache_fresh "$_id_file" "$SLACK_IDENTITY_TTL_MIN"; then
    slack_post_empty auth.test > "$_id_file.tmp" || slack_die "auth.test failed"
    mv "$_id_file.tmp" "$_id_file"
  fi
  SLACK_BOT_USER_ID="$(jq -r '.user_id // ""' "$_id_file")"
  SLACK_BOT_TEAM_ID="$(jq -r '.team_id // ""' "$_id_file")"
  if [ -z "$SLACK_BOT_USER_ID" ]; then slack_die "cached identity has no user_id"; fi
  return 0
}

_slack_users_file() { printf '%s/users.json' "$SLACK_CACHE_DIR"; }

slack_refresh_users() {
  slack_cache_dir
  _us_file="$(_slack_users_file)"
  # Not a pipeline, for the reason spelled out in inbox.sh: `a | b` exits with
  # b's status, so a failed listing would be written up as an empty cache.
  slack_paginate users.list "limit=200" '.members' > "$_us_file.raw"
  jq -s 'map({key: .id, value: (.profile.display_name // "" | select(. != "")) // .name // .id}) | from_entries' \
    "$_us_file.raw" > "$_us_file.tmp"
  mv "$_us_file.tmp" "$_us_file"
  rm -f "$_us_file.raw"
}

# slack_users_ensure <id> [id...] -- refresh the cache when it is stale or when
# any requested id is unknown to it. One refresh per process, at most: a run
# that mentions a genuinely deleted or foreign id must not re-list the whole
# workspace once per message.
slack_users_ensure() {
  slack_cache_dir
  _ue_file="$(_slack_users_file)"
  _ue_need=0
  if ! _slack_cache_fresh "$_ue_file" "$SLACK_USERS_TTL_MIN"; then
    _ue_need=1
  else
    for _ue_id in "$@"; do
      if [ -z "$_ue_id" ] || [ "$_ue_id" = "null" ]; then continue; fi
      if ! jq -e --arg i "$_ue_id" 'has($i)' "$_ue_file" >/dev/null 2>&1; then
        _ue_need=1
        break
      fi
    done
  fi
  if [ "$_ue_need" = "1" ] && [ "${SLACK_USERS_REFRESHED:-0}" != "1" ]; then
    SLACK_USERS_REFRESHED=1
    slack_refresh_users
  fi
  return 0
}

# slack_user_name <id> -- the cached display name, or the id itself.
slack_user_name() {
  _un_file="$(_slack_users_file)"
  if [ -f "$_un_file" ]; then
    _un_name="$(jq -r --arg i "$1" '.[$i] // ""' "$_un_file" 2>/dev/null)"
    if [ -n "$_un_name" ]; then printf '%s' "$_un_name"; return 0; fi
  fi
  printf '%s' "$1"
}

_slack_channels_file() { printf '%s/channels.json' "$SLACK_CACHE_DIR"; }

slack_refresh_channels() {
  slack_cache_dir
  _ch_file="$(_slack_channels_file)"
  slack_paginate conversations.list \
    "limit=200&exclude_archived=true&types=public_channel%2Cprivate_channel" '.channels' \
    > "$_ch_file.raw"
  jq -s 'map({id, name, is_member: (.is_member // false)})' "$_ch_file.raw" > "$_ch_file.tmp"
  mv "$_ch_file.tmp" "$_ch_file"
  rm -f "$_ch_file.raw"
}

# slack_resolve_channel <#name|name|ID> -- prints a channel id.
# An argument that already looks like an id is passed straight through, so a
# script never pays a listing call for the common case.
slack_resolve_channel() {
  _rc_arg="$1"
  case "$_rc_arg" in
    C[A-Z0-9]*|G[A-Z0-9]*|D[A-Z0-9]*)
      printf '%s' "$_rc_arg"
      return 0
      ;;
  esac
  _rc_name="${_rc_arg#\#}"
  slack_cache_dir
  _rc_file="$(_slack_channels_file)"
  if ! _slack_cache_fresh "$_rc_file" "$SLACK_CHANNELS_TTL_MIN"; then
    slack_refresh_channels
  fi
  _rc_id="$(jq -r --arg n "$_rc_name" 'map(select(.name == $n)) | .[0].id // ""' "$_rc_file")"
  if [ -z "$_rc_id" ] && [ "${SLACK_CHANNELS_REFRESHED:-0}" != "1" ]; then
    SLACK_CHANNELS_REFRESHED=1
    slack_refresh_channels
    _rc_id="$(jq -r --arg n "$_rc_name" 'map(select(.name == $n)) | .[0].id // ""' "$_rc_file")"
  fi
  if [ -z "$_rc_id" ]; then
    slack_die "no channel named #$_rc_name is visible to this bot (is it invited?)"
  fi
  printf '%s' "$_rc_id"
}

# slack_permalink <channel> <ts> -- best effort; prints nothing on failure, so
# a permalink lookup can never turn a delivered message into a reported error.
slack_permalink() {
  slack_get chat.getPermalink "channel=$(slack_urlencode "$1")&message_ts=$(slack_urlencode "$2")" 2>/dev/null \
    | jq -r '.permalink // ""' 2>/dev/null || printf ''
}

# slack_read_text <arg...> -- the trailing text argument, or stdin when absent.
slack_read_text() {
  if [ "$#" -gt 0 ] && [ -n "$1" ]; then
    printf '%s' "$1"
  else
    cat
  fi
}

# --------------------------------------------------------------- rendering

# slack_render_messages <jsonl-file> <true|false as-json>
#
# Reads Slack message objects (one per line, newest-first as the API returns
# them) and prints them oldest-first, because a transcript read top to bottom
# is the only order a conversation makes sense in.
#
# Every id it is about to print is resolved through the users cache in ONE
# batch: a per-message lookup would refresh the whole workspace listing on each
# unknown id.
slack_render_messages() {
  _rm_file="$1"
  _rm_json="${2:-false}"
  if [ ! -s "$_rm_file" ]; then
    if [ "$_rm_json" != "true" ]; then printf '(no messages)\n'; fi
    return 0
  fi
  # shellcheck disable=SC2046
  slack_users_ensure $(jq -r '(.user // empty)' "$_rm_file" | sort -u | tr '\n' ' ')
  _rm_users="$(_slack_users_file)"
  if [ ! -f "$_rm_users" ]; then printf '{}' > "$_rm_users"; fi

  # sed '1!G;h;$!d' is the portable line reverse -- `tac` is GNU-only and
  # absent on macOS, where these scripts also have to run.
  if [ "$_rm_json" = "true" ]; then
    jq -c --slurpfile u "$_rm_users" '
      {ts, user: (.user // .bot_id // "unknown"),
       name: ($u[0][(.user // "")] // .username // .user // "unknown"),
       thread_ts: (.thread_ts // .ts), text: (.text // ""),
       subtype: (.subtype // null)}' "$_rm_file" | sed '1!G;h;$!d'
    return 0
  fi

  jq -r --slurpfile u "$_rm_users" '
    [ .ts,
      ($u[0][(.user // "")] // .username // .user // "unknown"),
      ((.text // "") | gsub("\n"; " ⏎ ")),
      (if (.thread_ts // .ts) != .ts then "(in thread " + .thread_ts + ")" else "" end)
    ] | @tsv' "$_rm_file" | sed '1!G;h;$!d'
}
