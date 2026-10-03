# shellcheck shell=bash
# forge-identity.sh — which Athena bot acts on a GitLab project (DND-1936).
#
# gitlab.com hosts two namespaces with two different bots: a work group's bot
# and the personal bot for cjpoll/ projects. The identity follows the
# project's (host, top-level namespace), never a default. Sourced by
# ai/bin/glab-athena (the normal path, `git` and `refresh`), ai/bin/forge-preflight
# and ai/bin/push-actor-check, so all of them read one map.
#
# The map has two halves, one entry shape:
#   * public  ai/config/forge-identities.json            the personal entry
#   * private overlay/gitlab.json .identities (the private overlay,
#             read through ai/bin/private-overlay)       work entries
# A work value never lands in this public repo (ai/contracts/athena-private-overlay.md).
#
# Entry: {host, namespace, bot, token_file, refresh}
#   host        lowercase host name
#   namespace   top-level namespace, matched EXACTLY (case included)
#   bot         the GitLab username, or null with `pending` saying why
#   token_file  ~/... or absolute; the bot's PAT
#   refresh     self_rotate | group_service_account
#
# A failed lookup must never look like an empty one (~/dev/custom/CLAUDE.md).
# Every function ends in exactly one state, with its own return code, and sets
# FID_STATE, FID_WHY (one sentence naming the key it searched) and FID_FIX:
#   0 FOUND           FID_HOST FID_NS FID_BOT FID_TOKEN_FILE FID_REFRESH FID_SOURCE
#   1 NO ENTRY        the key is well formed and no entry matches it
#   2 BAD KEY         the key is malformed for its type: an SSH remote form, a
#                     subgroup or project path, an empty or upper-case host
#   3 COULD NOT LOOK  the key cannot be computed (no -R and no origin), or the
#                     map cannot be read: an unreadable or malformed public
#                     map, a MALFORMED overlay, two entries for one namespace
#   4 PENDING         the entry exists but names no bot yet
# Nothing here falls back to another entry, to the owner's glab login, or to a
# default namespace. The caller prints the refusal (FID_STATE, FID_WHY, and
# `Fix: FID_FIX`) and exits.
#
# Test seam: ATHENA_FORGE_IDENTITIES_FILE names another public map. The overlay
# half is redirected the overlay's own way (ATHENA_PRIVATE_ROOT).

FID_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
FID_ESCALATE='Never fall back to the owner'"'"'s glab login or to another bot'"'"'s token; if this is a namespace Athena must write to, escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'"'"'t be done as Athena").'
FID_ADD_FIX='if Athena works in this namespace, add its entry: a personal namespace to ai/config/forge-identities.json, a work namespace to the private overlay'"'"'s overlay/gitlab.json .identities (ai/contracts/athena-private-overlay.md -> Keys in use).'

fid_clear() {
  FID_STATE="" FID_WHY="" FID_FIX="" FID_HOST="" FID_NS="" FID_BOT=""
  FID_TOKEN_FILE="" FID_REFRESH="" FID_SOURCE="" FID_PENDING=""
}

# fid_fail <rc> <STATE> <why> <fix> : set the refusal fields, return <rc>.
# A refusal hands out no identity: the bot and token fields are cleared, so a
# caller that ignored the return code still has no token file to read.
fid_fail() {
  FID_STATE="$2" FID_WHY="$3" FID_FIX="$4"
  FID_BOT="" FID_TOKEN_FILE="" FID_REFRESH="" FID_SOURCE=""
  return "$1"
}

# ---- keys (pure) ------------------------------------------------------------

FID_HOST_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'
FID_NS_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]*$'

# fid_check_key <host> <ns> : 0 when both are well formed for their type,
# else 2 (BAD KEY) naming what is wrong. Rejected where it is produced, so a
# wrongly computed key never reaches the map as a plain miss.
fid_check_key() {
  local h="$1" n="$2" what
  if [ -z "$h" ]; then
    fid_fail 2 "BAD KEY" "the host is empty (namespace '$n')" \
      "resolve the project from an https://<host>/<namespace>/<project>.git remote or -R <namespace>/<project>. $FID_ESCALATE"
    return
  fi
  if ! [[ "$h" =~ $FID_HOST_RE ]]; then
    case "$h" in
      *@*|*:*|*/*) what="a URL or an SSH remote form ('user@host:'), not a host name" ;;
      *[A-Z]*) what="not lower case (host names are compared lower-cased)" ;;
      *) what="not a host name" ;;
    esac
    fid_fail 2 "BAD KEY" "the host '$h' (namespace '$n') is $what" \
      "pass the bare lower-case host, e.g. gitlab.com, as parsed from the remote. $FID_ESCALATE"
    return
  fi
  if [ -z "$n" ]; then
    fid_fail 2 "BAD KEY" "no namespace for host $h: the remote or -R names no <namespace>/<project> path" \
      "name the project as <namespace>/<project> (-R, or an origin like https://$h/<namespace>/<project>.git). $FID_ESCALATE"
    return
  fi
  if ! [[ "$n" =~ $FID_NS_RE ]]; then
    case "$n" in
      */*) what="a subgroup or project path; the map is keyed on the TOP-LEVEL namespace only (its first segment)" ;;
      *@*|*:*) what="an SSH remote form, not a namespace" ;;
      *%*) what="still URL-encoded" ;;
      *) what="not a GitLab namespace path" ;;
    esac
    fid_fail 2 "BAD KEY" "the namespace '$n' on $h is $what" \
      "key the lookup on the top-level namespace, the first path segment of the project (e.g. 'group' for group/sub/project). $FID_ESCALATE"
    return
  fi
  return 0
}

# fid_shown <url> : <url> with any user[:password]@ removed, for a message.
fid_shown() {
  printf '%s' "$1" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1#'
}

# fid_parse_remote <url> : sets FID_KEY_HOST and FID_KEY_NS from an https://,
# ssh:// or scp-like ([user@]host:path) remote. 0, or 2 (BAD KEY). Messages
# name the URL without its credentials.
fid_parse_remote() {
  # Parsed from the shown form too: a URL's user[:password]@ never reaches
  # the host or the path, so dropping it changes no key.
  local url rest hostport path
  url="$(fid_shown "$1")"
  FID_KEY_HOST="" FID_KEY_NS=""
  case "$url" in
    '') fid_fail 2 "BAD KEY" "the remote URL is empty" \
          "run from the project's checkout (it has an origin), or pass -R <namespace>/<project>. $FID_ESCALATE"; return ;;
    [Hh][Tt][Tt][Pp][Ss]://*|[Hh][Tt][Tt][Pp]://*|[Ss][Ss][Hh]://*|[Gg][Ii][Tt]://*|[Gg][Ii][Tt]+[Ss][Ss][Hh]://*)
      rest="${url#*://}"; hostport="${rest%%/*}"
      [ "$hostport" = "$rest" ] && path="" || path="${rest#*/}"
      hostport="${hostport##*@}"; FID_KEY_HOST="${hostport%%:*}" ;;
    /*|./*|../*|\~*|[Ff][Ii][Ll][Ee]://*)
      fid_fail 2 "BAD KEY" "the remote '$url' is a local path, not a forge project" \
        "run from the project's checkout, whose origin is its forge URL, or pass -R <namespace>/<project>. $FID_ESCALATE"; return ;;
    *:*)
      hostport="${url%%:*}"
      case "$hostport" in */*)
        fid_fail 2 "BAD KEY" "the remote '$url' is neither a URL nor a [user@]host:path form" \
          "use https://<host>/<namespace>/<project>.git. $FID_ESCALATE"; return ;;
      esac
      FID_KEY_HOST="${hostport##*@}"; path="${url#*:}" ;;
    *)
      fid_fail 2 "BAD KEY" "the remote '$url' is neither a URL nor a [user@]host:path form" \
        "use https://<host>/<namespace>/<project>.git. $FID_ESCALATE"; return ;;
  esac
  FID_KEY_HOST="$(printf '%s' "$FID_KEY_HOST" | tr '[:upper:]' '[:lower:]')"
  fid_split_path "$path" "$url"
}

# fid_split_path <path> <shown> : FID_KEY_NS from <namespace>[/<sub>...]/<project>.
fid_split_path() {
  local p="$1"
  while [ "${p#/}" != "$p" ]; do p="${p#/}"; done
  while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  p="${p%.git}"
  while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  case "$p" in
    */*) FID_KEY_NS="${p%%/*}" ;;
    *) fid_fail 2 "BAD KEY" "'$2' names no <namespace>/<project> path (host '${FID_KEY_HOST}')" \
         "name the project with its namespace: https://<host>/<namespace>/<project>.git, or -R <namespace>/<project>. $FID_ESCALATE"; return ;;
  esac
  case "$p" in *//*)
    fid_fail 2 "BAD KEY" "'$2' has an empty path segment" "fix the remote or -R value. $FID_ESCALATE"; return ;;
  esac
  return 0
}

# fid_parse_repo_arg <-R value> <--hostname or ""> : glab's -R forms. A URL or
# [user@]host:path parses as a remote; OWNER/REPO and GROUP/SUB/REPO take
# their host from --hostname, else gitlab.com (glab's own default).
fid_parse_repo_arg() {
  local v="$1" hn="$2" first
  case "$v" in
    *://*|*@*:*) fid_parse_remote "$v" || return
      if [ -n "$hn" ] && [ "$hn" != "$FID_KEY_HOST" ]; then
        fid_fail 2 "BAD KEY" "-R '$v' names host $FID_KEY_HOST but --hostname names $hn" \
          "pass one host: drop --hostname or make -R match it. $FID_ESCALATE"; return
      fi
      return 0 ;;
  esac
  FID_KEY_HOST="${hn:-gitlab.com}"
  first="${v%%/*}"
  if [[ "$first" == *.* ]] && [[ "$v" == */*/* ]]; then
    fid_fail 2 "BAD KEY" "-R '$v' could be HOST/OWNER/REPO or GROUP/SUB/REPO" \
      "pass the full URL (-R https://<host>/<namespace>/<project>) or OWNER/REPO with --hostname. $FID_ESCALATE"
    return
  fi
  fid_split_path "$v" "-R $v"
}

# ---- the map (side effects: one file read, one overlay read) ---------------

# fid_load : FID_ENTRIES (compact JSON array, each entry with .source),
# FID_N_PUB, FID_N_OV, FID_OV_STATE. 0, or 3 (COULD NOT LOOK). Cached.
FID_LOADED=""
fid_load() {
  [ "$FID_LOADED" = 1 ] && return 0
  local map="${ATHENA_FORGE_IDENTITIES_FILE:-$FID_LIB_DIR/../config/forge-identities.json}"
  local po="$FID_LIB_DIR/../bin/private-overlay" pub ov="null" err rc=0 out
  command -v jq >/dev/null 2>&1 || {
    fid_fail 3 "COULD NOT LOOK" "jq is not installed, so the identity map cannot be read" "install jq. $FID_ESCALATE"; return; }
  if ! pub="$(cat -- "$map" 2>/dev/null)"; then
    fid_fail 3 "COULD NOT LOOK" "the public identity map $map cannot be read" \
      "restore ai/config/forge-identities.json in the checkout that holds this tool (git checkout -- ai/config/forge-identities.json). $FID_ESCALATE"; return
  fi
  if [ ! -x "$po" ]; then
    fid_fail 3 "COULD NOT LOOK" "the private-overlay resolver $po is missing, so work identities cannot be read" \
      "run from a full ~/dev/custom checkout (ai/bin and ai/lib side by side). $FID_ESCALATE"; return
  fi
  # One stream, no scratch file: on success the resolver writes only the value
  # (stdout); on failure only its one stderr line. Anything else mixed into a
  # success fails the JSON check below, closed.
  out="$("$po" get gitlab .identities 2>&1)" || rc=$?
  [ "$rc" = 0 ] || err="$(printf '%s' "$out" | head -c 600)"
  case "$rc" in
    0) ov="$out"; FID_OV_STATE="PRESENT" ;;
    3) FID_OV_STATE="ABSENT (no private overlay on this machine)" ;;
    5) FID_OV_STATE="PRESENT, with no gitlab .identities key" ;;
    *) fid_fail 3 "COULD NOT LOOK" "the private overlay's gitlab .identities cannot be read (private-overlay exit $rc: ${err:-no message})" \
         "follow the resolver's Fix: in that message, then retry. $FID_ESCALATE"; return ;;
  esac
  rc=0
  out="$(jq -cn --argjson ov "$ov" --arg pubtxt "$pub" -f "$FID_LIB_DIR/forge-identity.jq" 2>&1)" || rc=$?
  if [ "$rc" != 0 ]; then
    fid_fail 3 "COULD NOT LOOK" "the identity map could not be evaluated (jq exit $rc: $(printf '%s' "$out" | head -c 300))" \
      "check ai/lib/forge-identity.jq and the map files are intact. $FID_ESCALATE"; return
  fi
  if [ "$(jq -r '.ok' <<<"$out")" != true ]; then
    fid_fail 3 "COULD NOT LOOK" "the identity map is malformed: $(jq -r '.error' <<<"$out")" \
      "fix the named entry in ai/config/forge-identities.json (public) or the private overlay's overlay/gitlab.json .identities (work); one entry per (host, namespace), case-insensitively, and one token file per bot. $FID_ESCALATE"; return
  fi
  FID_ENTRIES="$(jq -c '.entries' <<<"$out")"
  FID_N_PUB="$(jq -r '.n_pub' <<<"$out")" FID_N_OV="$(jq -r '.n_ov' <<<"$out")"
  FID_LOADED=1
}

# fid_lookup <host> <ns> : the entry for exactly (host, ns). See the header.
fid_lookup() {
  local h="$1" n="$2" row hint
  fid_clear
  fid_check_key "$h" "$n" || return
  fid_load || return
  # One field per line: every value is validated free of newlines (forge-identity.jq).
  local f=()
  mapfile -t f < <(jq -r --arg h "$h" --arg n "$n" -f "$FID_LIB_DIR/forge-identity-lookup.jq" <<<"$FID_ENTRIES")
  local f1="${f[0]:-}" f2="${f[1]:-}" f3="${f[2]:-}" f4="${f[3]:-}" f5="${f[4]:-}" f6="${f[5]:-}"
  if [ "$f1" != FOUND ] && [ "$f1" != MISS ]; then
    fid_fail 3 "COULD NOT LOOK" "the identity map lookup for $h/$n produced no result" \
      "check jq, ai/lib/forge-identity.sh and ai/lib/forge-identity-lookup.jq are intact. $FID_ESCALATE"
    return
  fi
  FID_HOST="$h" FID_NS="$n"
  if [ "$f1" = MISS ]; then
    hint=""
    [ -n "$f2" ] && hint="; an entry exists for $h/$f2, which differs only in case, and the map matches the namespace exactly, so use the canonical path '$f2' in the remote or -R"
    fid_fail 1 "NO ENTRY" "no Athena bot identity for $h/$n: searched ${FID_N_PUB} public entr$( [ "$FID_N_PUB" = 1 ] && echo y || echo ies) (ai/config/forge-identities.json) and the private overlay's gitlab .identities [${FID_OV_STATE}, ${FID_N_OV} entr$( [ "$FID_N_OV" = 1 ] && echo y || echo ies)]; ${f3} of them on host $h$hint" \
      "$FID_ADD_FIX $FID_ESCALATE"
    return
  fi
  FID_SOURCE="$f5" FID_REFRESH="$f4" FID_PENDING="$f6"
  if [ -z "$f2" ]; then
    fid_fail 4 "PENDING" "the Athena bot for $h/$n ($FID_SOURCE map) has no username yet: $f6" \
      "the owner sets \`bot\` for $h/$n (then removes \`pending\`); until then nothing runs as a bot in $h/$n. $FID_ESCALATE"
    return
  fi
  FID_BOT="$f2"
  case "$f3" in "~/"*) FID_TOKEN_FILE="$HOME/${f3#\~/}" ;; *) FID_TOKEN_FILE="$f3" ;; esac
  FID_STATE=FOUND
  return 0
}

# fid_resolve_url <url> : parse a remote URL and look its key up.
fid_resolve_url() {
  fid_clear
  fid_parse_remote "$1" || return
  fid_lookup "$FID_KEY_HOST" "$FID_KEY_NS"
}

# ---- glab's own arguments ---------------------------------------------------

# Value-taking flags of `glab api` (glab 1.92 --help), so the endpoint is the
# first word that is neither a flag nor a flag's value.
FID_API_VALUED=" -X --method -F --field -f --raw-field -H --header --input --form --hostname --output "

# fid_resolve_glab_args <glab args...> : the identity a glab command acts as.
# The namespace comes from -R/--repo, else from an `api projects/<g>%2F<p>/…`
# endpoint, else from the cwd checkout's origin. The host is --hostname when
# given, else the source's own (gitlab.com for a bare OWNER/REPO). Sources that
# disagree, two -R values, and an origin checkout whose other remote on that
# host has a DIFFERENT Athena identity (glab could pick either) are BAD KEY.
fid_resolve_glab_args() {
  local repos=() hn="" a v i=0 n="$#" ep="" ep_ns="" key_h key_n src
  local args=("$@")
  fid_clear
  while [ "$i" -lt "$n" ]; do
    a="${args[$i]}"
    case "$a" in
      --) break ;;
      -R|--repo) i=$((i + 1)); repos+=("${args[$i]:-}") ;;
      --repo=*) repos+=("${a#--repo=}") ;;
      -R?*) v="${a#-R}"; repos+=("${v#=}") ;;
      --hostname) i=$((i + 1)); v="${args[$i]:-}"
        if [ -n "$hn" ] && [ "$hn" != "$v" ]; then
          fid_fail 2 "BAD KEY" "--hostname is given twice ($hn, $v)" "pass --hostname once. $FID_ESCALATE"; return; fi
        hn="$v" ;;
      --hostname=*) v="${a#--hostname=}"
        if [ -n "$hn" ] && [ "$hn" != "$v" ]; then
          fid_fail 2 "BAD KEY" "--hostname is given twice ($hn, $v)" "pass --hostname once. $FID_ESCALATE"; return; fi
        hn="$v" ;;
    esac
    i=$((i + 1))
  done
  if [ -n "$hn" ]; then
    hn="$(printf '%s' "$hn" | tr '[:upper:]' '[:lower:]')"
  fi
  # The api endpoint: the first positional word after the `api` subcommand
  # (only -R/--repo may come before it).
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${args[$i]}" in
      -R|--repo) i=$((i + 2)); continue ;;
      -R?*|--repo=*) i=$((i + 1)); continue ;;
    esac
    break
  done
  if [ "${args[$i]:-}" = api ]; then
    i=$((i + 1))
    while [ "$i" -lt "$n" ]; do
      a="${args[$i]}"
      case "$a" in
        --) ep="${args[$((i + 1))]:-}"; break ;;
        --*=*) ;;
        -*) [[ "$FID_API_VALUED" == *" $a "* ]] && i=$((i + 1)) ;;
        *) ep="$a"; break ;;
      esac
      i=$((i + 1))
    done
  fi
  ep="${ep#/}"
  case "$ep" in
    projects/*)
      v="${ep#projects/}"; v="${v%%/*}"; v="${v%%\?*}"
      case "$v" in *%2[Ff]*)
        v="${v//%2F//}"; v="${v//%2f//}"
        ep_ns="${v%%/*}"
        [[ "$ep_ns" == *%* ]] && {
          fid_fail 2 "BAD KEY" "the api endpoint's project '$v' is still URL-encoded past its namespace separator" \
            "name the project as projects/<namespace>%2F<project>, or pass -R <namespace>/<project>. $FID_ESCALATE"; return; } ;;
      esac ;;
  esac
  if [ "${#repos[@]}" -gt 1 ]; then
    for v in "${repos[@]}"; do
      if [ "$v" != "${repos[0]}" ]; then
        fid_fail 2 "BAD KEY" "-R/--repo is given more than once (${repos[*]})" "pass one -R. $FID_ESCALATE"; return
      fi
    done
  fi
  if [ "${#repos[@]}" -ge 1 ]; then
    fid_parse_repo_arg "${repos[0]}" "$hn" || return
    key_h="$FID_KEY_HOST" key_n="$FID_KEY_NS" src="-R ${repos[0]}"
    if [ -n "$ep_ns" ] && [ "$ep_ns" != "$key_n" ]; then
      fid_fail 2 "BAD KEY" "-R names namespace '$key_n' but the api endpoint names '$ep_ns'" \
        "make -R and the endpoint name the same project. $FID_ESCALATE"; return
    fi
  elif [ -n "$ep_ns" ]; then
    key_h="${hn:-gitlab.com}" key_n="$ep_ns" src="the api endpoint $ep"
  else
    fid_resolve_origin_key "$hn" || return
    key_h="$FID_KEY_HOST" key_n="$FID_KEY_NS" src="origin"
  fi
  fid_lookup "$key_h" "$key_n" || { FID_WHY="$FID_WHY (key from $src)"; return "$(fid_rc)"; }
  if [ "$src" = origin ]; then
    fid_check_other_remotes || return
  fi
  return 0
}

# fid_rc : the return code that matches FID_STATE.
fid_rc() {
  case "$FID_STATE" in
    FOUND) echo 0 ;; "NO ENTRY") echo 1 ;; "BAD KEY") echo 2 ;; "COULD NOT LOOK") echo 3 ;; PENDING) echo 4 ;; *) echo 3 ;;
  esac
}

# fid_resolve_origin_key <hostname or ""> : the key of the cwd checkout's origin.
fid_resolve_origin_key() {
  local hn="$1" url
  if ! url="$(git remote get-url origin 2>/dev/null)" || [ -z "$url" ]; then
    fid_fail 3 "COULD NOT LOOK" "no -R/--repo and no origin remote in $(pwd), so the project's namespace (and its bot) cannot be computed" \
      "run from the project's checkout, or pass -R <namespace>/<project>. $FID_ESCALATE"
    return
  fi
  fid_parse_remote "$url" || { FID_WHY="$FID_WHY (origin of $(pwd))"; return 2; }
  [ -z "$hn" ] || FID_KEY_HOST="$hn"
  return 0
}

# fid_check_other_remotes : with the identity taken from origin, refuse when
# another remote of this checkout on the same host belongs to a DIFFERENT
# Athena identity: glab picks among remotes by its own rules, so either bot's
# token could reach the other bot's project. Remotes with no entry are ignored
# (no bot can be chosen for them).
fid_check_other_remotes() {
  local keep_h="$FID_HOST" keep_n="$FID_NS" keep_b="$FID_BOT" keep_t="$FID_TOKEN_FILE"
  local keep_r="$FID_REFRESH" keep_s="$FID_SOURCE" name url
  while read -r name url; do
    name="${name#remote.}"; name="${name%.url}"
    [ "$name" = origin ] && continue
    fid_parse_remote "$url" 2>/dev/null || continue
    [ "$FID_KEY_HOST" = "$keep_h" ] || continue
    [ "$FID_KEY_NS" = "$keep_n" ] && continue
    if [[ "$FID_KEY_NS" =~ $FID_NS_RE ]] && jq -e --arg h "$keep_h" --arg n "$FID_KEY_NS" \
        'any(.[]; .host == $h and .namespace == $n)' <<<"$FID_ENTRIES" >/dev/null 2>&1; then
      fid_fail 2 "BAD KEY" "this checkout's origin is $keep_h/$keep_n, but its remote '$name' is $keep_h/$FID_KEY_NS, which has its own Athena identity; glab could act on either project" \
        "pass -R <namespace>/<project> to name the project explicitly. $FID_ESCALATE"
      return
    fi
  done < <(git config --get-regexp '^remote\..*\.url$' 2>/dev/null)
  FID_HOST="$keep_h" FID_NS="$keep_n" FID_BOT="$keep_b" FID_TOKEN_FILE="$keep_t"
  FID_REFRESH="$keep_r" FID_SOURCE="$keep_s" FID_STATE=FOUND FID_WHY="" FID_FIX=""
  return 0
}
