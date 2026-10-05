# shellcheck shell=bash
# forge-identity.sh — which Athena bot acts on a GitLab project (DND-1936).
#
# gitlab.com hosts two namespaces with two different bots: a work group's bot
# and the personal group service account athena-ai-harness-bot for
# athena-ai-harness/ projects. The identity follows the
# project's (host, top-level namespace), never a default. Sourced by
# ai/bin/glab-athena (the normal path, `git` and `refresh`), ai/bin/forge-preflight
# and ai/bin/push-actor-check, so all of them read one map.
#
# The map has two halves, one entry shape:
#   * public  ai/config/forge-identities.json            the personal entries
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
  FID_TOKEN_FILE="" FID_TOKEN_FILE_RAW="" FID_REFRESH="" FID_SOURCE="" FID_PENDING=""
}

# fid_fail <rc> <STATE> <why> <fix> : set the refusal fields, return <rc>.
# A refusal hands out no identity: the bot and token fields are cleared, so a
# caller that ignored the return code still has no token file to read.
fid_fail() {
  FID_STATE="$2" FID_WHY="$3" FID_FIX="$4"
  FID_BOT="" FID_TOKEN_FILE="" FID_TOKEN_FILE_RAW="" FID_REFRESH="" FID_SOURCE=""
  return "$1"
}

# ---- keys (pure) ------------------------------------------------------------

# fid_lower <s> : ASCII-only lower case, the one fold this file uses for a host
# or an endpoint. bash's lower-case expansion and a locale-aware tr fold non-ASCII letters too:
# in a UTF-8 locale it turns gİtlab.com (U+0130) into gitlab.com, while glab
# sends it to another (IDNA) host (DND-2009 measured it; glos_lower in
# ai/lib/glab-outbound-scan.sh is the same rule).
fid_lower() { printf '%s' "$1" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'; }

# fid_non_ascii <s> : 0 when <s> holds a byte outside ASCII.
fid_non_ascii() { [ -n "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\177')" ]; }

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
  if fid_non_ascii "$h"; then
    fid_fail 2 "BAD KEY" "the host '$h' (namespace '$n') is not ASCII; glab sends a non-ASCII host to its IDNA form, another host than the one it looks like" \
      "spell the host in plain ASCII, e.g. gitlab.com. $FID_ESCALATE"
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
  FID_KEY_HOST="$(fid_lower "$FID_KEY_HOST")"
  fid_split_path "$path" "$url"
}

# fid_check_segments <path> <shown> : 2 (BAD KEY) when <path> holds a `.` or
# `..` segment, or an encoded dot: a client collapses those (libcurl does by
# default), so the project reached is not the one the first segment names.
fid_check_segments() {
  local seg segs=()
  case "$1" in
    *%2[Ee]*) fid_fail 2 "BAD KEY" "'$2' has an encoded dot (%2e) in its path" \
      "name the project by its plain <namespace>/<project> path. $FID_ESCALATE"; return ;;
  esac
  IFS=/ read -ra segs <<<"$1"
  for seg in "${segs[@]}"; do
    case "$seg" in
      .|..) fid_fail 2 "BAD KEY" "'$2' has a '$seg' path segment, so the project it reaches is not the one its first segment names" \
        "name the project by its plain <namespace>/<project> path. $FID_ESCALATE"; return ;;
    esac
  done
  return 0
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
  fid_check_segments "$p" "$2"
}

# fid_parse_repo_arg <-R value> <--hostname or ""> : glab's -R forms. A URL or
# [user@]host:path parses as a remote; OWNER/REPO and GROUP/SUB/REPO take
# their host from --hostname, else gitlab.com (glab's own default).
fid_parse_repo_arg() {
  local v="$1" hn="$2" first
  case "$v" in
    *://*|*@*:*) fid_parse_remote "$v" || return
      if [ -n "$hn" ] && [ "$hn" != "$FID_KEY_HOST" ]; then
        fid_fail 2 "BAD KEY" "-R '$(fid_shown "$v")' names host $FID_KEY_HOST but --hostname names $hn" \
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
  fid_split_path "$v" "-R $(fid_shown "$v")"
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
    3) FID_OV_STATE="ABSENT (no private overlay on this machine; scripts/setup-private-overlay --init creates one)" ;;
    5) FID_OV_STATE="PRESENT, with no gitlab .identities key" ;;
    *) fid_fail 3 "COULD NOT LOOK" "the private overlay's gitlab .identities cannot be read (private-overlay exit $rc: ${err:-no message})" \
         "follow the resolver's Fix: in that message, then retry. $FID_ESCALATE"; return ;;
  esac
  rc=0
  out="$(jq -cn --argjson ov "$ov" --arg pubtxt "$pub" --arg home "$HOME" -f "$FID_LIB_DIR/forge-identity.jq" 2>&1)" || rc=$?
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
      "the reason above says what has to happen first; the owner then names a bot that can write in $h/$n (sets \`bot\`, removes \`pending\`) or removes the entry. Until then nothing runs as a bot in $h/$n. $FID_ESCALATE"
    return
  fi
  FID_BOT="$f2" FID_TOKEN_FILE_RAW="$f3"
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
FID_API_VALUED=" -X --method -F --field -f --raw-field -H --header --input --form --hostname --output -R --repo "

# fid_flag_may_take_value <word> : 0 when <word> is a flag that could take the
# NEXT word as its value (a flag with no `=`, other than `--`). Which glab
# flags are boolean is not known here, so every such flag counts.
fid_flag_may_take_value() {
  case "$1" in
    --|'') return 1 ;;
    -*=*) return 1 ;;
    -*) return 0 ;;
  esac
  return 1
}

# fid_endpoint_key <endpoint> : what an `api` endpoint says about its target.
# Sets FID_EP_NS (a namespace it names, or "") and FID_EP_KIND (none |
# project | group | placeholder | graphql). 0, or 2 (BAD KEY) for an endpoint
# this cannot key on: a project or group named by a numeric id, a `.` or `..`
# segment (also once a %2F past the project or group path is read as `/`), any
# %-encoding other than %2F, or an absolute URL. An optional leading api/v4/ is read through.
# `graphql` names its target inside the query, so it is never keyed here.
fid_endpoint_key() {
  local ep="$1" kind seg v rest segs=() s
  FID_EP_NS="" FID_EP_KIND=none
  ep="${ep%%\?*}"
  case "$ep" in
    [A-Za-z]*://*)
      fid_fail 2 "BAD KEY" "the api endpoint '$(fid_shown "$ep")' is an absolute URL, so its host and project are not the ones this resolves" \
        "use the relative endpoint (projects/<namespace>%2F<project>/...). $FID_ESCALATE"; return ;;
  esac
  while [ "${ep#/}" != "$ep" ]; do ep="${ep#/}"; done
  IFS=/ read -ra segs <<<"$ep"
  for s in "${segs[@]}"; do
    case "$s" in
      .|..) fid_fail 2 "BAD KEY" "the api endpoint '$ep' has a '$s' segment, so the route it reaches is not the one it spells" \
        "spell the endpoint plainly (projects/<namespace>%2F<project>/...). $FID_ESCALATE"; return ;;
    esac
  done
  case "$(fid_lower "${segs[0]:-}/${segs[1]:-}")" in
    api/v4) ep="${ep#*/}"; ep="${ep#*/}" ;;
  esac
  case "$(fid_lower "$ep")" in
    graphql|api/graphql) FID_EP_KIND=graphql; return 0 ;;
    projects/*) kind=project ;;
    groups/*) kind=group ;;
    *)
      if [[ "$ep" == *%* ]]; then
        fid_fail 2 "BAD KEY" "the api endpoint '$ep' is %-encoded, so the route it reaches is not the one it spells" \
          "spell the endpoint plainly. $FID_ESCALATE"; return
      fi
      return 0 ;;
  esac
  rest="${ep#*/}"; seg="${rest%%/*}"; rest="${rest#"$seg"}"
  # Past the project or group path only %2F may appear: GitLab's own routes
  # encode a file path or a branch name that way (repository/files/:file_path,
  # repository/branches/:branch), and the bot is picked by the segment before
  # it alone. Decoded, it must still hold no '.' or '..' segment. Any other
  # escape could spell a route word another way, so it stays a refusal.
  rest="${rest//%2F//}"; rest="${rest//%2f//}"
  IFS=/ read -ra segs <<<"$rest"
  for s in "${segs[@]}"; do
    case "$s" in
      .|..) fid_fail 2 "BAD KEY" "the api endpoint '$ep' has a '$s' segment once its %2F separators are read, so the route it reaches is not the one it spells" \
        "spell the path past ${kind}s/<path> with no '.' or '..' segment. $FID_ESCALATE"; return ;;
    esac
  done
  if [[ "$rest" == *%* ]]; then
    fid_fail 2 "BAD KEY" "the api endpoint '$ep' is %-encoded past its $kind path, so the route it reaches is not the one it spells" \
      "spell the route plainly after ${kind}s/<path>. $FID_ESCALATE"; return
  fi
  case "$seg" in
    :*) FID_EP_KIND=placeholder; return 0 ;;
    '') return 0 ;;
  esac
  if [[ "$seg" =~ ^[0-9]+$ ]]; then
    fid_fail 2 "BAD KEY" "the api endpoint '$ep' names its $kind by a numeric id, which says nothing about its namespace" \
      "name it by path (${kind}s/<namespace>%2F<...>), or by the placeholder :id from the project's checkout. $FID_ESCALATE"; return
  fi
  v="${seg//%2F//}"; v="${v//%2f//}"
  if [[ "$v" == *%* ]]; then
    fid_fail 2 "BAD KEY" "the api endpoint's $kind '$seg' is URL-encoded beyond its path separators (%2F)" \
      "name it as ${kind}s/<namespace>%2F<...> with only the separators encoded. $FID_ESCALATE"; return
  fi
  if [ "$kind" = project ] && [[ "$v" != */* ]]; then
    fid_fail 2 "BAD KEY" "the api endpoint's project '$seg' is not a <namespace>%2F<project> path" \
      "name it as projects/<namespace>%2F<project>, or use :id from the project's checkout. $FID_ESCALATE"; return
  fi
  fid_check_segments "$v" "the api endpoint $ep" || return
  FID_EP_NS="${v%%/*}" FID_EP_KIND="$kind"
  return 0
}

# fid_resolve_glab_args <glab args...> : the identity a glab command acts as.
# The namespace comes from -R/--repo, else from an `api projects/…` or
# `api groups/…` endpoint that names it by path, else from the cwd checkout's
# origin. The host is --hostname when given, else the source's own (gitlab.com
# for a bare OWNER/REPO). BAD KEY when glab could act on a project other than
# the one read here: two -R values; -R or --hostname right after another flag
# (it may be that flag's value); -R combined with other short flags in one word
# (-yR, -fRx/y); -R and the endpoint disagreeing; an endpoint
# naming its target by id, double encoding or an absolute URL; `api graphql`
# with no -R; any other word glab reads as a project naming another namespace
# (fid_check_project_words); an origin checkout with another remote on that
# host that is not this identity (fid_check_other_remotes).
fid_resolve_glab_args() {
  local repos=() hn="" a v prev="" i=0 n="$#" ep="" key_h key_n src c1="" c2="" c2i=-1
  local args=("$@")
  fid_clear
  # The command path: the first two words that are neither flags nor the value
  # of -R/--repo/--hostname (`mr create`, `repo view`, `api`).
  while [ "$i" -lt "$n" ] && [ -z "$c2" ]; do
    a="${args[$i]}"
    case "$a" in
      --) break ;;
      -R|--repo|--hostname) i=$((i + 1)) ;;
      -*) ;;
      *) if [ -z "$c1" ]; then c1="$a"; else c2="$a" c2i="$i"; fi ;;
    esac
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    a="${args[$i]}"
    [ "$a" = -- ] && break
    # glab's flag parser (pflag) reads combined short flags: `-yR x/y` is -y
    # and -R x/y, `-fRx/y` is -f and -Rx/y. This loop keys only on -R (and
    # fid_check_project_words on -H and -g) as its own word, so a combined one
    # is refused rather than read as some flag. -H is mr create's head
    # project (an api header elsewhere); -g a group outside api.
    if fid_combined_project_flag "$a" R \
      || { [ "$c1" = mr ] && [[ "$c2" =~ ^(create|new)$ ]] && fid_combined_project_flag "$a" H; } \
      || { [ "$c1" != api ] && fid_combined_project_flag "$a" g; }; then
      fid_fail 2 "BAD KEY" "'$(fid_shown "$a")' may be a project flag (-R, or -H/-g where glab reads them as a project) combined with other short flags, which names a project this does not read" \
        "write each short flag as its own word (\`mr merge <iid> -y -R <namespace>/<project>\`), and a short flag's value as its own word. $FID_ESCALATE"
      return
    fi
    case "$a" in
      -R|--repo|-R?*|--repo=*|--hostname|--hostname=*)
        if fid_flag_may_take_value "$prev"; then
          fid_fail 2 "BAD KEY" "'$(fid_shown "$a")' comes right after the flag '$prev', so glab may read it as that flag's value and act on another project than the one it names" \
            "put -R/--repo (and --hostname) right after a subcommand or argument word, e.g. \`mr create -R <namespace>/<project> --fill\` or \`mr -R <namespace>/<project> merge <iid>\`. $FID_ESCALATE"
          return
        fi ;;
    esac
    case "$a" in
      -R|--repo) i=$((i + 1)); v="${args[$i]:-}"; repos+=("$v"); prev="$v" ;;
      --repo=*) repos+=("${a#--repo=}"); prev="$a" ;;
      -R?*) v="${a#-R}"; repos+=("${v#=}"); prev="$a" ;;
      --hostname|--hostname=*)
        if [ "$a" = --hostname ]; then i=$((i + 1)); v="${args[$i]:-}"; prev="$v"; else v="${a#--hostname=}"; prev="$a"; fi
        v="$(fid_lower "$v")"
        if [ -n "$hn" ] && [ "$hn" != "$v" ]; then
          fid_fail 2 "BAD KEY" "--hostname is given twice ($hn, $v)" "pass --hostname once. $FID_ESCALATE"; return
        fi
        hn="$v" ;;
      *) prev="$a" ;;
    esac
    i=$((i + 1))
  done
  # The api endpoint: the first word after `api` that is neither a flag nor a
  # flag's value (-R/--repo may sit before `api`, or anywhere after it).
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
        --*=*|-R?*) ;;
        -*) [[ "$FID_API_VALUED" == *" $a "* ]] && i=$((i + 1)) ;;
        *) ep="$a"; break ;;
      esac
      i=$((i + 1))
    done
    fid_endpoint_key "$ep" || return
  else
    FID_EP_NS="" FID_EP_KIND=none
  fi
  if [ "${#repos[@]}" -gt 1 ]; then
    for v in "${repos[@]}"; do
      if [ "$v" != "${repos[0]}" ]; then
        fid_fail 2 "BAD KEY" "-R/--repo is given more than once" "pass one -R. $FID_ESCALATE"; return
      fi
    done
  fi
  if [ "${#repos[@]}" -ge 1 ]; then
    fid_parse_repo_arg "${repos[0]}" "$hn" || return
    key_h="$FID_KEY_HOST" key_n="$FID_KEY_NS" src="-R $(fid_shown "${repos[0]}")"
    if [ -n "$FID_EP_NS" ] && [ "$FID_EP_NS" != "$key_n" ]; then
      fid_fail 2 "BAD KEY" "-R names namespace '$key_n' but the api endpoint names '$FID_EP_NS'" \
        "make -R and the endpoint name the same namespace. $FID_ESCALATE"; return
    fi
  elif [ "$FID_EP_KIND" = graphql ]; then
    fid_fail 2 "BAD KEY" "\`api graphql\` names its target inside the query, which this cannot read, so no bot can be chosen for it" \
      "make the call through the REST endpoint of the project it acts on (glab-athena api projects/<namespace>%2F<project>/...). $FID_ESCALATE"
    return
  elif [ -n "$FID_EP_NS" ]; then
    key_h="${hn:-gitlab.com}" key_n="$FID_EP_NS" src="the api endpoint $ep"
  else
    fid_resolve_origin_key "$hn" || return
    key_h="$FID_KEY_HOST" key_n="$FID_KEY_NS" src="origin"
    [ -z "$hn" ] || src="origin, with the host from --hostname"
  fi
  fid_check_project_words "$key_h" "$key_n" "$src" "$c1" "$c2" "$c2i" "${args[@]}" || return
  fid_lookup "$key_h" "$key_n" || { FID_WHY="$FID_WHY (key from $src)"; return "$(fid_rc)"; }
  if [ "${src%%,*}" = origin ]; then
    fid_check_other_remotes || return
  fi
  return 0
}

# fid_combined_project_flag <word> <R|H|g> : true when <word> is a cluster of
# short flags (`-yR`, `-fRx/y`, `-fg grp`) that may hold the project flag
# <letter> past its first letter. pflag gives a valued flag the rest of the
# word, and which short flags are boolean differs per command, so this does
# not guess: the letter anywhere in the leading run of letters counts when
# what follows it could be its value. That is nothing (the value is the next
# word), or a word with no whitespace that for R/H names a project (a `/`,
# a `:`, or all digits) and for g is any group name. An attached text value
# such as `-tRefactor the parser` or `-txSYNTH-1` names none, and passes.
fid_combined_project_flag() {
  local w="$1" l="$2" run rest k
  [[ "$w" == -[A-Za-z]* && "$w" != --* && "$w" != "-$l"* ]] || return 1
  run="${w#-}"; run="${run%%[!A-Za-z]*}"
  for ((k = 1; k < ${#run}; k++)); do
    [ "${run:k:1}" = "$l" ] || continue
    rest="${w:k+2}"
    [ -z "$rest" ] && return 0
    [[ "$rest" =~ [[:space:]] ]] && continue
    case "$l" in
      g) return 0 ;;
      *) [[ "$rest" == */* || "$rest" == *:* || "$rest" =~ ^=?[0-9]+$ ]] && return 0 ;;
    esac
  done
  return 1
}

# fid_check_project_words <key host> <key ns> <key source> <c1> <c2> <c2 index>
#   <glab args...> : 0 when every other word glab reads as a project names the
# keyed (host, namespace); else 2 (BAD KEY). Those words, for glab 1.92:
#   * a positional http(s) URL (an MR or issue URL is acted on as its project;
#     a word with whitespace is message text, not a URL);
#   * mr create|new -H/--head (the head project) and --target-project;
#   * -g/--group outside api (a group is a namespace too);
#   * a `repo <sub>` command's first positional (its repository; a bare name
#     is refused, because glab reads it in the bot's own user namespace).
# A project named by numeric id says nothing about its namespace: refused.
# Restores FID_KEY_HOST/FID_KEY_NS for the caller.
fid_check_project_words() {
  local kh="$1" kn="$2" src="$3" c1="$4" c2="$5" c2i="$6" a v i=0 n what rpos=""
  shift 6
  local args=("$@")
  n="${#args[@]}"
  [ "$c1" = repo ] && [ "$c2i" -ge 0 ] && rpos=pending
  while [ "$i" -lt "$n" ]; do
    a="${args[$i]}" v="" what=""
    case "$a" in
      --) break ;;
      -R|--repo|--hostname) i=$((i + 2)); continue ;;
      -R?*|--repo=*|--hostname=*) i=$((i + 1)); continue ;;
    esac
    if [ "$c1" != api ]; then
      case "$a" in
        -g|--group) i=$((i + 1)); v="${args[$i]:-}"; what="group" ;;
        --group=*) v="${a#--group=}"; what="group" ;;
        -g?*) v="${a#-g}"; v="${v#=}"; what="group" ;;
        --target-project) i=$((i + 1)); v="${args[$i]:-}"; what="project" ;;
        --target-project=*) v="${a#--target-project=}"; what="project" ;;
      esac
      if [ -z "$what" ] && [ "$c1" = mr ] && [[ "$c2" =~ ^(create|new)$ ]]; then
        case "$a" in
          -H|--head) i=$((i + 1)); v="${args[$i]:-}"; what="project" ;;
          --head=*) v="${a#--head=}"; what="project" ;;
          -H?*) v="${a#-H}"; v="${v#=}"; what="project" ;;
        esac
      fi
    fi
    if [ -z "$what" ]; then
      shopt -s nocasematch
      case "$a" in
        http://*|https://*) [[ "$a" =~ [[:space:]] ]] || { v="$a" what="url"; } ;;
      esac
      shopt -u nocasematch
    fi
    if [ -z "$what" ] && [ "$rpos" = pending ] && [ "$i" -gt "$c2i" ] && [[ "$a" != -* ]]; then
      v="$a" what="project"; rpos=done
      if [[ "$v" != */* ]] && ! [[ "$v" =~ ^[0-9]+$ ]]; then
        fid_fail 2 "BAD KEY" "\`repo $c2\` names its repository '$(fid_shown "$v")' by a bare name, which glab reads in the bot's own namespace, not $kh/$kn" \
          "name it as <namespace>/<project> (in $kn), first after \`repo $c2\`. $FID_ESCALATE"; return
      fi
    elif [ "$what" = url ] && [ "$rpos" = pending ] && [ "$i" -gt "$c2i" ]; then
      rpos=done
    fi
    if [ -n "$what" ]; then
      fid_check_one_project_word "$kh" "$kn" "$src" "$what" "$v" || return
    fi
    i=$((i + 1))
  done
  FID_KEY_HOST="$kh" FID_KEY_NS="$kn"
  return 0
}

# fid_check_one_project_word <key host> <key ns> <key source> <group|project|url> <value>
fid_check_one_project_word() {
  local kh="$1" kn="$2" src="$3" what="$4" v="$5" h ns shown
  shown="$(fid_shown "$v")"
  if [[ "$v" =~ ^[0-9]+$ ]] || [ -z "$v" ]; then
    fid_fail 2 "BAD KEY" "the $what '${shown}' is empty or a numeric id, which says nothing about its namespace" \
      "name it by path (<namespace>/<project>, in $kn). $FID_ESCALATE"; return
  fi
  case "$what" in
    url)
      v="${v%%[?#]*}"; v="${v%%/-/*}"
      fid_parse_remote "$v" || { FID_WHY="$FID_WHY (the URL argument ${shown})"; return 2; }
      h="$FID_KEY_HOST" ns="$FID_KEY_NS" ;;
    group)
      # milestone --group takes a URL-encoded path: only its %2F separators.
      v="${v//%2F//}"; v="${v//%2f//}"
      if [[ "$v" == *://* || "$v" == *%* || "$v" == */ ]]; then
        fid_fail 2 "BAD KEY" "the group '${shown}' is not a plain <namespace>[/<subgroup>] path" \
          "pass the group as <namespace>[/<subgroup>]. $FID_ESCALATE"; return
      fi
      fid_check_segments "$v" "the group $shown" || return
      h="$kh" ns="${v%%/*}" ;;
    project)
      fid_parse_repo_arg "$v" "" || return
      h="$FID_KEY_HOST" ns="$FID_KEY_NS"
      # A bare OWNER/REPO takes the keyed host, as glab does with --hostname.
      [[ "$v" == *://* || "$v" == *@*:* ]] || h="$kh" ;;
  esac
  # The word's host is a key like any other: malformed (non-ASCII included)
  # is BAD KEY before it is compared, and the compare folds ASCII only.
  fid_check_key "$h" "$ns" || { FID_WHY="$FID_WHY (the $what ${shown})"; return 2; }
  if [ "$(fid_lower "$h")" != "$(fid_lower "$kh")" ] || [ "$ns" != "$kn" ]; then
    fid_fail 2 "BAD KEY" "the $what '${shown}' names namespace '$ns' on $h, but the bot is keyed on $kh/$kn (from $src); glab would act there as that bot" \
      "act on one namespace per call: pass -R <namespace>/<project> for the project the call acts on, and no word naming another. $FID_ESCALATE"
    return
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
# another remote of this checkout on the same host is NOT this identity: glab
# picks among remotes by its own rules (upstream before origin), so origin's
# bot could act on that remote's project. A remote passes only when its
# namespace is origin's, or maps (case-insensitively, as GitLab paths do) to
# the same bot and token file. A remote whose namespace has no entry, maps to
# another bot, or cannot be parsed refuses; a local-path remote is no forge
# project and is skipped. The fix is always -R.
fid_check_other_remotes() {
  local keep_h="$FID_HOST" keep_n="$FID_NS" keep_b="$FID_BOT" keep_t="$FID_TOKEN_FILE"
  local keep_r="$FID_REFRESH" keep_s="$FID_SOURCE" keep_raw="$FID_TOKEN_FILE_RAW" name url why
  while read -r name url; do
    name="${name#remote.}"; name="${name%.url}"
    [ "$name" = origin ] && continue
    if ! fid_parse_remote "$url"; then
      [[ "$FID_WHY" == *"is a local path"* ]] && continue
      why="its URL cannot be parsed ($FID_WHY)"
    else
      [ "$FID_KEY_HOST" = "$keep_h" ] || continue
      [ "$FID_KEY_NS" = "$keep_n" ] && continue
      jq -e --arg h "$keep_h" --arg n "$FID_KEY_NS" --arg b "$keep_b" --arg t "$keep_raw" \
        'any(.[]; .host == $h and (.namespace | ascii_downcase) == ($n | ascii_downcase)
                  and .bot == $b and .token_file == $t)' <<<"$FID_ENTRIES" >/dev/null 2>&1 && continue
      why="it is $keep_h/$FID_KEY_NS, which is not this identity (no entry, or another bot)"
    fi
    fid_fail 2 "BAD KEY" "this checkout's origin is $keep_h/$keep_n (bot $keep_b), but its remote '$name': $why; glab could act on that remote's project with this bot" \
      "pass -R <namespace>/<project> to name the project explicitly. $FID_ESCALATE"
    return
  done < <(git config --get-regexp '^remote\..*\.url$' 2>/dev/null)
  FID_HOST="$keep_h" FID_NS="$keep_n" FID_BOT="$keep_b" FID_TOKEN_FILE="$keep_t"
  FID_TOKEN_FILE_RAW="$keep_raw" FID_REFRESH="$keep_r" FID_SOURCE="$keep_s" FID_STATE=FOUND FID_WHY="" FID_FIX=""
  return 0
}
