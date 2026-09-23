# shellcheck shell=bash
#
# forge-git-passthrough.sh — the shared `<wrapper> git …` passthrough behind
# `gh-athena git` (DND-389) and `glab-athena git` (DND-393). Sourced, never run.
#
# A bot token reaches git only over HTTPS (an http.https://<host>/.extraheader),
# so everything else about the command must keep the machine owner's identity
# OUT, for that one command, with no git/gh/glab config change:
#
#   * url.https://<host>/.insteadOf=git@<host>:  — an SSH-form remote (the
#     default a `git clone git@<host>:...` leaves) is rewritten to HTTPS, so the
#     plain `<wrapper> git push origin HEAD` is correct by default. Without it
#     the push goes over SSH with the OWNER's key and the forge records the owner.
#   * credential.helper= (empty resets the list, URL-scoped helpers included),
#     core.askPass= , GIT_ASKPASS/SSH_ASKPASS unset, GIT_TERMINAL_PROMPT=0 — no
#     fallback source of the owner's credentials; a bot-auth failure FAILS.
#   * fg_refuse_non_https: before exec, for the network subcommands it knows —
#     push, fetch, pull, ls-remote, clone, remote update, submodule, subtree
#     push/pull/add, and git aliases that expand to them — every URL the command
#     would reach is resolved (rewrite applied, pushurl and pushInsteadOf
#     included, submodule URLs when it recurses) and the command is REFUSED if
#     any still reaches <host> over SSH or another non-HTTPS transport
#     (ssh://, git://, http://, a pushurl override, an insteadOf that forces
#     SSH). A shell alias (`!...`) and a push that recurses into submodules are
#     refused outright. A refusal is exit 3 with a Fix: line.
#
# Residual (NOT checked; each still runs): an ~/.ssh/config Host alias for the
# forge host (`myalias:owner/repo`); ext:: transports; `clone
# --recurse-submodules` (the submodule URLs are unknown until the clone lands);
# git-lfs transfers; third-party `git-<name>` subcommands; any subcommand not
# named above.
#
# Usage: set the variables below, then call `fg_refuse_non_https "$@"` (it
# exits 3 on a refusal) and then `fg_git_exec <basic-user> <token> "$@"` (it
# execs git, or prints under FG_DRY_RUN=1). Both gh-athena and glab-athena do.
# The variables:
#   FG_TOOL      the wrapper's name, for messages (gh-athena / glab-athena)
#   FG_HOST      the forge host (github.com / gitlab.com); subdomains match too
#   FG_BOT       the bot identity pushes must carry (athena-harness[bot] / athena-amby)
#   FG_DRY_RUN   "1" to print the resolved URLs + redacted argv instead of exec
#
# Test seam: FG_DRY_RUN=1 runs the resolution and refusal, then prints the
# resolved URLs and the git argv (token redacted) instead of exec'ing git.

FG_OWNER="the machine OWNER (CJPoll)"
FG_ESCALATE='If it cannot be done as Athena, do not work around this with a plain `git push` or the owner'"'"'s credentials; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'"'"'t be done as Athena").'

fg_rewrite() { printf 'url.https://%s/.insteadOf=git@%s:' "$FG_HOST" "$FG_HOST"; }

# fg_url_host_scheme <url> -> "<scheme> <host>" (lowercased); empty for a local path.
fg_url_host_scheme() {
  local url="$1" scheme rest hostport host
  case "$url" in
    /*|./*|../*|\~*|file://*) return 0 ;;
    *://*)
      scheme="${url%%://*}"; rest="${url#*://}"; hostport="${rest%%/*}"
      host="${hostport##*@}"; host="${host%%:*}" ;;
    *:*)
      # scp-like [user@]host:path — only when no '/' precedes the first ':'.
      hostport="${url%%:*}"
      case "$hostport" in */*) return 0 ;; esac
      scheme=ssh; host="${hostport##*@}" ;;
    *) return 0 ;;
  esac
  printf '%s %s' "$(tr 'A-Z' 'a-z' <<<"$scheme")" "$(tr 'A-Z' 'a-z' <<<"$host")"
}

# fg_reaches_forge_insecurely <url> : true when <url> targets FG_HOST (or a
# subdomain) over anything but https.
fg_reaches_forge_insecurely() {
  local sh scheme host
  sh="$(fg_url_host_scheme "$1")"
  [ -n "$sh" ] || return 1
  scheme="${sh%% *}"; host="${sh#* }"
  case "$host" in "$FG_HOST"|*."$FG_HOST") ;; *) return 1 ;; esac
  [ "$scheme" != "https" ]
}

fg_refuse() {
  # $1 subcommand, $2 what (remote name or literal), $3 resolved url
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: '$2' resolves to $3, which reaches $FG_HOST over SSH or another non-HTTPS transport.
  The bot token only authenticates HTTPS, so this would run as $FG_OWNER, not $FG_BOT.
  Fix: push to the HTTPS URL instead — \`~/dev/custom/ai/bin/$FG_TOOL git $1 https://$FG_HOST/<owner>/<repo>.git <refspec>\` — or point the remote at https://$FG_HOST/<owner>/<repo>.git or git@$FG_HOST:<owner>/<repo>.git (the wrapper rewrites that form); drop any ssh:// pushurl override or global insteadOf/pushInsteadOf that forces SSH. $FG_ESCALATE
EOF
  exit 3
}

fg_refuse_shell_alias() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: it is a shell alias ('$2'), which can run any command, so $FG_TOOL cannot check which remote it reaches or which identity it pushes as.
  Fix: run the underlying git command directly through the wrapper — \`~/dev/custom/ai/bin/$FG_TOOL git <the expanded command>\`. $FG_ESCALATE
EOF
  exit 3
}

fg_refuse_unchecked() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: $2, so it could reach $FG_HOST as $FG_OWNER unchecked.
  Fix: push the superproject and each submodule separately, each through \`~/dev/custom/ai/bin/$FG_TOOL git -C <repo> push …\` (drop --recurse-submodules / push.recurseSubmodules). $FG_ESCALATE
EOF
  exit 3
}

# fg_refuse_non_https <git args...> : resolve every URL the network op would
# reach and refuse on the first one that goes to FG_HOST over non-HTTPS.
# Sets FG_RESOLVED_URLS (newline-separated) for the dry-run report.
FG_RESOLVED_URLS=""
fg_refuse_non_https() {
  local -a glob=() ex=()
  local sub="" mode depth=0 alias_val rewrite
  rewrite="$(fg_rewrite)"

  G() { git "${glob[@]}" -c "$rewrite" "$@"; }

  # Peel global options (replayed on every probe), take the subcommand, and
  # expand git aliases (`alias.p=push`) the way git would, so an alias cannot
  # carry a network op past the check. An alias may itself start with global
  # options (`alias.p=-c url...pushInsteadOf=... push`; git accepts -c there),
  # so the peel runs again on every expansion. A shell alias (`!...`) can run
  # anything, so it is refused outright rather than guessed at.
  while :; do
    while [ $# -gt 0 ]; do
      case "$1" in
        -C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix)
          [ $# -ge 2 ] || return 0; glob+=("$1" "$2"); shift 2 ;;
        -*) glob+=("$1"); shift ;;
        *) break ;;
      esac
    done
    [ $# -gt 0 ] || return 0
    sub="$1"; shift
    [ "$depth" -lt 10 ] || break
    case "$sub" in push|fetch|pull|ls-remote|clone|remote|submodule|subtree) break ;; esac
    alias_val="$(G config --get "alias.$sub" 2>/dev/null || true)"
    [ -n "$alias_val" ] || break
    case "$alias_val" in
      '!'*) fg_refuse_shell_alias "$sub" "$alias_val" ;;
    esac
    read -ra ex <<<"$alias_val"
    set -- "${ex[@]}" "$@"
    depth=$((depth + 1))
  done

  local recurse=0 a0
  for a0 in "$@"; do
    case "$a0" in --recurse-submodules|--recurse-submodules=yes|--recurse-submodules=on-demand|--recurse-submodules=only) recurse=1 ;; esac
  done
  case "$sub" in
    push)
      mode=push
      # A recursive push pushes each submodule through ITS OWN remote config,
      # which this check does not inspect: refuse rather than half-check.
      case "$(G config --get push.recurseSubmodules 2>/dev/null || true)" in on-demand|only) recurse=1 ;; esac
      [ "$recurse" = 1 ] && fg_refuse_unchecked push "--recurse-submodules pushes each submodule through its own remote, which $FG_TOOL does not inspect" ;;
    fetch|pull|ls-remote|clone) mode=fetch ;;
    remote) [ "${1:-}" = update ] || return 0; mode=fetch ;;
    submodule) mode=fetch; recurse=1 ;;
    subtree)
      case "${1:-}" in
        push) mode=push ;;
        pull|add) mode=fetch ;;
        *) return 0 ;;
      esac
      shift ;;
    *) return 0 ;;
  esac

  local -a remotes=()
  mapfile -t remotes < <(G remote 2>/dev/null || true)
  is_remote() { local r; for r in "${remotes[@]}"; do [ "$r" = "$1" ] && return 0; done; return 1; }

  # Walk the subcommand's args: options that take a separate value are skipped
  # with it; the first remaining positional is the repository. Independently,
  # EVERY token that names a configured remote or mentions the forge host is
  # also checked, so a mis-parsed option value can only add a check, never drop one.
  local -a targets=() ; local positional="" all=0 has_repo=0 a takes_value
  if [ "$sub" = submodule ]; then
    # Every submodule URL (config after `submodule init`, and .gitmodules).
    # Relative URLs (./ ../) resolve against the superproject's remote, which
    # the default-remote check below covers.
    local top m
    top="$(G rev-parse --show-toplevel 2>/dev/null || true)"
    while read -r _ m; do
      case "$m" in ./*|../*|'') ;; *) targets+=("$m") ;; esac
    done < <({ G config --get-regexp '^submodule\..*\.url$' 2>/dev/null
               [ -n "$top" ] && [ -f "$top/.gitmodules" ] \
                 && G config -f "$top/.gitmodules" --get-regexp '^submodule\..*\.url$' 2>/dev/null; } || true)
    set --   # submodule's own args name paths, not repositories
  fi
  if [ "$mode" = push ]; then
    takes_value='^(-o|--push-option|--receive-pack|--exec|--repo|-P|--prefix|-m|--message)$'
  else
    takes_value='^(-P|--prefix|-m|--message|-o|--upload-pack|-j|--jobs|--depth|--deepen|--shallow-since|--shallow-exclude|--refmap|--server-option|--negotiation-tip|-s|--strategy|-X|--strategy-option|--origin|-b|--branch|-u|--reference|--reference-if-able|--separate-git-dir|-c|--config|--template|--filter|--bundle-uri|--ref-format)$'
  fi
  local dd=0
  while [ $# -gt 0 ]; do
    a="$1"; shift
    if [ "$dd" = 0 ]; then
      case "$a" in
        --) dd=1; continue ;;
        --all|--multiple) [ "$mode" = fetch ] && all=1 ;;
        --repo=*) has_repo=1; targets+=("${a#--repo=}") ;;
      esac
      if [[ "$a" =~ $takes_value ]]; then
        [ "$a" = --repo ] && [ $# -gt 0 ] && { has_repo=1; targets+=("$1"); }
        [ $# -gt 0 ] && { is_remote "$1" || [[ "$1" == *"$FG_HOST"* ]]; } && targets+=("$1")
        [ $# -gt 0 ] && shift
        continue
      fi
      case "$a" in -*) continue ;; esac
    fi
    if [ -z "$positional" ]; then positional="$a"; targets+=("$a")
    elif is_remote "$a" || [[ "$a" == *"$FG_HOST"* ]]; then targets+=("$a"); fi
  done
  [ "$sub" = remote ] && all=1
  [ "$all" = 1 ] && targets+=("${remotes[@]}")
  # fetch/pull --recurse-submodules (or the config that implies it) also
  # fetches every submodule: check their URLs too.
  if [ "$mode" = fetch ] && [ "$sub" != submodule ] && [ "$sub" != clone ]; then
    case "$(G config --get fetch.recurseSubmodules 2>/dev/null || true)$(G config --get submodule.recurse 2>/dev/null || true)" in
      *true*|*yes*|*on-demand*) recurse=1 ;;
    esac
    if [ "$recurse" = 1 ]; then
      local _k m2
      while read -r _k m2; do
        case "$m2" in ./*|../*|'') ;; *) targets+=("$m2") ;; esac
      done < <(G config --get-regexp '^submodule\..*\.url$' 2>/dev/null || true)
    fi
  fi

  if [ -z "$positional" ] && [ "$all" = 0 ] && [ "$has_repo" = 0 ] && [ "$sub" != clone ] && [ "$sub" != subtree ]; then
    # Default remote, as git resolves it: pushRemote / pushDefault (push only),
    # then branch.<cur>.remote, then origin.
    local cur def=""
    cur="$(G symbolic-ref -q --short HEAD 2>/dev/null || true)"
    if [ "$mode" = push ]; then
      [ -n "$cur" ] && def="$(G config --get "branch.$cur.pushRemote" 2>/dev/null || true)"
      [ -n "$def" ] || def="$(G config --get remote.pushDefault 2>/dev/null || true)"
    fi
    [ -n "$def" ] || { [ -n "$cur" ] && def="$(G config --get "branch.$cur.remote" 2>/dev/null || true)"; }
    [ -n "$def" ] || def=origin
    targets+=("$def")
  fi

  local t u ; local -a urls
  for t in "${targets[@]}"; do
    urls=()
    if is_remote "$t"; then
      if [ "$mode" = push ]; then mapfile -t urls < <(G remote get-url --push --all "$t" 2>/dev/null || true)
      else mapfile -t urls < <(G remote get-url --all "$t" 2>/dev/null || true); fi
    else
      # A URL literal (or an unknown name: git treats it as a URL). Apply
      # pushInsteadOf (push only, longest prefix wins), else insteadOf.
      local rewritten="" best=0 key base prefix
      if [ "$mode" = push ]; then
        while read -r key prefix; do
          base="${key#url.}"; base="${base%.pushinsteadof}"
          if [ -n "$prefix" ] && [[ "$t" == "$prefix"* ]] && [ "${#prefix}" -gt "$best" ]; then
            best="${#prefix}"; rewritten="$base${t#"$prefix"}"
          fi
        done < <(G config --get-regexp '^url\..*\.pushinsteadof$' 2>/dev/null || true)
      fi
      [ -n "$rewritten" ] || rewritten="$(G ls-remote --get-url "$t" 2>/dev/null || printf '%s' "$t")"
      urls=("$rewritten")
    fi
    for u in "${urls[@]}"; do
      [ -n "$u" ] || continue
      FG_RESOLVED_URLS+="$u"$'\n'
      fg_reaches_forge_insecurely "$u" && fg_refuse "$sub" "$t" "$u"
    done
  done
  return 0
}

# fg_git_exec <basic-user> <token> <git args...> : run (or, under FG_DRY_RUN=1,
# print) git with the bot's HTTPS basic-auth header for FG_HOST and every owner
# credential source removed. The header reaches git through the environment
# config channel (GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n, git
# >= 2.31), appended after any entries the caller already set — so the token is
# never on any process's argv (visible in `ps`), never in a URL, never in a
# config file.
fg_git_exec() {
  local user="$1" token="$2" header auth_key a n
  shift 2
  auth_key="http.https://$FG_HOST/.extraheader"
  header="AUTHORIZATION: basic $(printf '%s:%s' "$user" "$token" | openssl base64 -A)"
  n="${GIT_CONFIG_COUNT:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  set -- -c credential.helper= -c core.askPass= -c "$(fg_rewrite)" "$@"
  if [ "${FG_DRY_RUN:-}" = 1 ]; then
    printf '%s' "$FG_RESOLVED_URLS" | sed "s/^/$FG_TOOL: dry-run: url /"
    printf '%s: dry-run: env GIT_CONFIG_KEY_%s=[%s] GIT_CONFIG_VALUE_%s=[AUTHORIZATION: basic <%s:REDACTED>]\n' \
      "$FG_TOOL" "$n" "$auth_key" "$n" "$user"
    printf '%s: dry-run: exec git' "$FG_TOOL"
    for a in "$@"; do printf ' [%s]' "$a"; done
    printf '\n'
    exit 0
  fi
  export "GIT_CONFIG_KEY_$n=$auth_key" "GIT_CONFIG_VALUE_$n=$header" \
    GIT_CONFIG_COUNT="$((n + 1))"
  exec env -u GIT_ASKPASS -u SSH_ASKPASS GIT_TERMINAL_PROMPT=0 git "$@"
}
