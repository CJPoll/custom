# forge-http-pin.sh — the network settings a process holding the bot's
# header runs with (DND-1899). Sourced by the forge transport
# (ai/lib/forge-transport/git-remote-athena-forge) and by the route's own
# ls-remote probes around a push (ai/lib/forge-git-passthrough.sh,
# fg_push_and_record). Library: it returns a status; each caller composes the
# refusal that carries Fix:.
#
# git over https honours a caller's -c http.proxy / http.sslVerify /
# http.sslCAInfo, its *_PROXY and GIT_SSL_* environment, and curl tracing
# (GIT_TRACE_CURL, GIT_CURL_VERBOSE). A proxy the caller chose, with TLS
# verification off or its own CA, terminates TLS and reads the Authorization
# header; a curl trace with redaction off writes it to a file. So:
#
#   fg_http_pin <remote-name> <url>
#     appends LAST to GIT_CONFIG_PARAMETERS, where it beats a caller's -c at
#     the same URL specificity: http.sslVerify=true and http.proxy= (empty:
#     no proxy, environment included), each for every URL and for <url> with
#     and without its trailing slash (the most specific key a caller can
#     write), and remote.<remote-name>.proxy= (which overrides http.proxy).
#     Unsets every proxy, TLS-override and curl-trace variable in
#     FG_HTTP_UNSET_ENV.
#   fg_http_pin_args <remote-name> <url>
#     the same pin as `-c` options (FG_HTTP_ARGS), for a git whose own argv
#     carries the caller's -c.
#   fg_http_check <remote-name> <url> <git argv...>
#     reads back what git resolves for <url> with the pin in place (git
#     config --get-urlmatch, the resolver git's http layer uses) and returns
#     1 with FG_HTTP_WHY set if TLS verification is not on, any proxy is set,
#     or a CA or TLS backend setting is present. A CA setting is refused, not
#     reset: git has no value that restores curl's default CA store.
#     A read that fails is a refusal, never a pass.

FG_HTTP_UNSET_ENV=(
  HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy
  GIT_SSL_NO_VERIFY GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_SSL_BACKEND
  CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR SSLKEYLOGFILE
  GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA GIT_CURL_VERBOSE GIT_TRACE_REDACT
)
FG_HTTP_WHY=""

fg_http_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

fg_http_urls() { # <url> : the URL and its other trailing-slash form
  local u="${1%/}"
  printf '%s\n%s/\n' "$u" "$u"
}

FG_HTTP_KVS=()
fg_http_kvs() { # <remote-name> <url> : FG_HTTP_KVS = the pinned key=value list
  local remote="$1" url="$2" u
  FG_HTTP_KVS=( "http.sslVerify=true" "http.proxy=" )
  while IFS= read -r u; do
    FG_HTTP_KVS+=( "http.${u}.sslVerify=true" "http.${u}.proxy=" )
  done < <(fg_http_urls "$url")
  [ -n "$remote" ] && FG_HTTP_KVS+=( "remote.${remote}.proxy=" )
  return 0
}

fg_http_pin() {
  local kv
  fg_http_kvs "$1" "$2"
  for kv in "${FG_HTTP_KVS[@]}"; do
    GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:+${GIT_CONFIG_PARAMETERS} }$(fg_http_sq "${kv%%=*}")=$(fg_http_sq "${kv#*=}")"
  done
  export GIT_CONFIG_PARAMETERS
  unset "${FG_HTTP_UNSET_ENV[@]}"
}

# fg_http_pin_args <remote-name> <url> : the same pin for a git whose OWN argv
# carries the caller's -c (git appends argv -c after GIT_CONFIG_PARAMETERS, so
# a pin in the environment would lose): FG_HTTP_ARGS holds `-c k=v` pairs to
# put after the caller's options; the environment is unset as in fg_http_pin.
FG_HTTP_ARGS=()
fg_http_pin_args() {
  local kv
  fg_http_kvs "$1" "$2"
  FG_HTTP_ARGS=()
  for kv in "${FG_HTTP_KVS[@]}"; do FG_HTTP_ARGS+=( -c "$kv" ); done
  unset "${FG_HTTP_UNSET_ENV[@]}"
}

fg_http_check() {
  local remote="$1" url="$2" u out line key val rp rc
  shift 2
  FG_HTTP_WHY=""
  while IFS= read -r u; do
    rc=0; out="$("$@" config --get-urlmatch http "$u" 2>/dev/null)" || rc=$?
    if [ "$rc" != 0 ]; then
      FG_HTTP_WHY="git config --get-urlmatch http $u failed (exit $rc), so the TLS and proxy settings for it could not be read"
      return 1
    fi
    local verify=""
    while IFS= read -r line; do
      key="${line%% *}"; val=""; [ "$key" != "$line" ] && val="${line#* }"
      case "$key" in
        http.sslverify) verify="$val" ;;
        http.proxy) [ -z "$val" ] || { FG_HTTP_WHY="http.proxy resolves to a proxy for $u"; return 1; } ;;
        http.sslcainfo|http.sslcapath|http.sslbackend)
          FG_HTTP_WHY="$key is set for $u, and git has no value that restores curl's default CA store or TLS backend"; return 1 ;;
      esac
    done <<<"$out"
    [ "$verify" = true ] || { FG_HTTP_WHY="http.sslVerify resolves to '${verify}' for $u, not true"; return 1; }
  done < <(fg_http_urls "$url")
  if [ -n "$remote" ]; then
    rc=0; rp="$("$@" config --get "remote.${remote}.proxy" 2>/dev/null)" || rc=$?
    if [ "$rc" != 0 ] && [ "$rc" != 1 ]; then
      FG_HTTP_WHY="git config --get remote.${remote}.proxy failed (exit $rc)"; return 1
    fi
    [ -z "$rp" ] || { FG_HTTP_WHY="remote.${remote}.proxy resolves to a proxy"; return 1; }
  fi
  return 0
}
