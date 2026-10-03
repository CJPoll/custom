# shellcheck shell=bash
# agent-forge-push.sh — the forge-identity check the agent PATH git wrapper
# (ai/agent-bin/git) runs before a `git push` (DND-1803). Run, not sourced:
#
#   ATHENA_REAL_GIT=<the real git> bash agent-forge-push.sh <git global options...> push <push args...>
#
# The wrapper passes the argv it resolved (aliases expanded, global options
# kept). Exit 0: the push may run. Exit 1: refused, one stderr line ending in a
# Fix:. The wrapper exits with that status before git runs. `push -h` and
# `push --help` are not judged when -h or --help is the first push argument;
# anywhere else it is judged, since there it may be an option's value
# (DND-1843). Every argv walk here reads git's own option tables, kept once in
# the passthrough ("git's own argv grammar").
#
# WHY. ai/hooks/forge-identity-guard.sh reads the Bash command TEXT. A `git
# push` inside a script run as `bash <script>` is not in that text, and on
# 2026-10-02 one went out with the machine owner's credentials. This check runs
# in the git process tree, on the real argv, wherever the push came from.
#
# WHAT IS A FORGE PUSH. Every URL the push would reach, resolved by the Athena
# passthrough's own resolver, fg_refuse_non_https in
# ai/lib/forge-git-passthrough.sh, run once per forge host (github.com,
# gitlab.com). That covers the default remote (pushRemote, pushDefault,
# branch.<cur>.remote, origin), pushurl, insteadOf and pushInsteadOf, --repo, a
# literal URL, and an SSH-form remote. The resolver's own SSH-to-HTTPS rewrite
# is switched off here (fg_rewrite below), so a URL is rewritten only by the
# push's own config, as git will rewrite it. A URL whose host is the forge host
# or a subdomain of it (a trailing dot ignored) is a forge push. Refused
# outright: a forge push over SSH or another non-HTTPS transport (the owner's
# SSH key would carry it), and a push that recurses into submodules, by an
# explicit flag, or by push.recurseSubmodules or submodule.recurse in a
# repository that has submodules (each submodule push runs through git's
# exec-path, where no wrapper sees it). The recursion rule is the
# passthrough's fg_push_recurses, the one copy both routes share (DND-1841).
# A local path or another host is allowed.
#
# WHAT IS ROUTED. A forge push is allowed only when it carries the credential
# isolation the Athena passthrough (fg_git_exec) gives git, for that host:
#   * the last credential helper entry (credential.helper or
#     credential.<url>.helper, in git's config order) is an empty
#     `credential.helper`, which resets the list: no owner helper is consulted;
#   * core.askPass is set and empty, GIT_ASKPASS and SSH_ASKPASS are unset, and
#     GIT_TERMINAL_PROMPT=0: nothing can prompt for the owner's password;
#   * an http.https://<host>/.extraheader entry in the environment config
#     channel (GIT_CONFIG_KEY_n) whose value is an `AUTHORIZATION: basic`
#     header: the bot's credential.
# A plain shell sets none of this. With all of it, and the URL HTTPS (checked
# on the URL git will use), the push's only credential is the header the
# caller supplied: the owner's SSH key, credential helper and keyring are out
# of reach.
#
# RESIDUAL (it is not a sandbox). Defeated by: a caller that builds the whole
# marker by hand with the OWNER's token in the header (deliberate, and it needs
# the token read out first); git run by absolute path or with a PATH that skips
# the wrapper (the DND-775 residual list in ai/agent-bin/git); a push from a
# process git starts itself (a `!` alias, git-subtree, send-pack, `rebase -x`,
# `submodule foreach`, `bisect run`, a git hook), which runs with git's
# exec-path first on PATH, where a real `git` sits; a non-git client (libgit2,
# an HTTP call); and a forge host no URL spells as github.com or gitlab.com
# (an ~/.ssh/config Host alias such as `myalias:owner/repo`, an IP literal).
# The passthrough's own resolution residuals (its header) apply too.
# A known false refusal: a push the forge CLI runs on a routed call
# (`gh-athena repo create --push`, `glab-athena mr create --push`) carries no
# bot header, so it is refused; push first with `gh-athena git push` /
# `glab-athena git push`, then run the CLI command without --push.

AFP_TAG='git (agent wrapper)'
AFP_ESC='If the wrapper refuses or fails, do not work around this; escalate to your admiral with the command and the error (athena:github -> "When a forge write can'"'"'t be done as Athena").'

afp_refuse() {
  printf '%s: REFUSED %s Fix: %s %s\n' "$AFP_TAG" "$1" "$2" "$AFP_ESC" >&2
  exit 1
}

# afp_fix <host> : the Athena route for a push to <host>.
afp_fix() {
  case "$1" in
    github.com) printf 'push through the Athena route, `~/dev/custom/ai/bin/gh-athena git push …` (athena:github -> "Pushing as Athena"), which authenticates as athena-harness[bot] over HTTPS for that one command.' ;;
    *) printf 'push through the Athena route, `~/dev/custom/ai/bin/glab-athena git push …` (athena:gitlab -> "Pushing as Athena"), which authenticates as athena-amby over HTTPS for that one command.' ;;
  esac
}

# afp_shown <url> : the URL with any user:password@ removed, for a message.
afp_shown() {
  local u="$1"
  case "$u" in *://*@*) u="${u%%://*}://${u#*@}" ;; esac
  printf '%s' "$u"
}

AFP_REAL="${ATHENA_REAL_GIT:-}"
if [ -z "$AFP_REAL" ] || [ ! -x "$AFP_REAL" ]; then
  afp_refuse "git push: the forge-identity check was not given the real git (ATHENA_REAL_GIT='${AFP_REAL}'), so it cannot tell where this push goes." \
    "run git through ai/agent-bin/git, which sets it; to push to a forge, use ~/dev/custom/ai/bin/gh-athena git push … or ~/dev/custom/ai/bin/glab-athena git push …."
fi
# Every git this check runs is the real one, never the wrapper again.
git() { "$AFP_REAL" "$@"; }

AFP_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-git-passthrough.sh"
# shellcheck source=forge-git-passthrough.sh
if ! . "$AFP_LIB" 2>/dev/null || ! declare -F fg_refuse_non_https >/dev/null || ! declare -F fg_push_recurses >/dev/null \
   || ! declare -F fg_global_opt >/dev/null; then
  afp_refuse "git push: cannot load $AFP_LIB, so whether this push goes to a forge is unknown." \
    "restore ai/lib/forge-git-passthrough.sh beside ai/lib/agent-forge-push.sh in the checkout that holds ai/agent-bin; to push to a forge meanwhile, use ~/dev/custom/ai/bin/gh-athena git push … or ~/dev/custom/ai/bin/glab-athena git push …."
fi
# The resolver adds its own SSH-to-HTTPS rewrite to every probe, because the
# passthrough adds the same rewrite to the git it runs. This push carries only
# the rewrites in its own config, so the probes must too: a harmless key here.
fg_rewrite() { printf 'agentforgepush.noop=1'; }

# The git global options before `push`, by git's grammar (the options that
# take a separate value), for the config probes below; the push's own args.
AFP_GLOB=()
while [ $# -gt 0 ]; do
  [ "$1" = push ] && break
  if fg_global_opt "$1"; then
    [ $# -ge 2 ] || break
    AFP_GLOB+=("$1" "$2"); shift 2
  else
    AFP_GLOB+=("$1"); shift
  fi
done
AFP_ARGV=("${AFP_GLOB[@]}" "$@")
[ "${1:-}" = push ] && shift
# Help goes unjudged only where git always prints it and pushes nothing: -h
# or --help as the FIRST push argument (git.c turns `push --help` into `git
# help push`; parse-options exits on a leading -h). Anywhere else it is judged
# like any push (DND-1843): there it may be an option's value (`-o -h`,
# `--push-option --help`), which git pushes with. Where git would print help
# after all (`push origin -h`, `push -o -- -h`), a refusal costs only the help.
case "${1:-}" in -h | --help) exit 0 ;; esac

# afp_reaches <host> : sets AFP_URL to the first resolved URL on <host> (or a
# subdomain); returns 3 when the passthrough refuses the push for that host
# (non-HTTPS forge, or recursion it cannot inspect), 2 when it fails otherwise.
afp_reaches() {
  local host="$1" urls rc u hs h
  AFP_URL=""
  urls="$(FG_HOST="$host"; FG_TOOL="$AFP_TAG"; FG_BOT=bot
          fg_refuse_non_https "${AFP_ARGV[@]}" >/dev/null 2>&1 || exit $?
          printf '%s' "$FG_RESOLVED_URLS")" || { rc=$?; [ "$rc" = 3 ] && return 3; return 2; }
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    hs="$(fg_url_host_scheme "$u")"
    [ -n "$hs" ] || continue
    h="${hs#* }"
    while [ "${h%.}" != "$h" ]; do h="${h%.}"; done
    case "$h" in
      "$host" | *."$host")
        AFP_URL="$u"
        [ "${hs%% *}" = https ] || return 3
        return 0 ;;
    esac
  done <<<"$urls"
  return 0
}

# afp_g <git args...> : the real git with the push's own global options; the
# probe fg_push_recurses runs every config read through.
afp_g() { git "${AFP_GLOB[@]}" "$@"; }

# afp_routed <host> : 0 when the push carries the passthrough's isolation for <host>.
afp_routed() {
  local host="$1" last askpass i k v found=0
  [ "${GIT_TERMINAL_PROMPT:-}" = 0 ] || return 1
  [ -z "${GIT_ASKPASS+x}" ] && [ -z "${SSH_ASKPASS+x}" ] || return 1
  last="$(git "${AFP_GLOB[@]}" config --get-regexp '^credential\..*helper$' 2>/dev/null | tail -n 1)"
  [ "$last" = credential.helper ] || [ "$last" = 'credential.helper ' ] || return 1
  askpass="$(git "${AFP_GLOB[@]}" config --get core.askPass 2>/dev/null)" || return 1
  [ -z "$askpass" ] || return 1
  case "${GIT_CONFIG_COUNT:-0}" in '' | *[!0-9]*) return 1 ;; esac
  i=0
  while [ "$i" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
    k="GIT_CONFIG_KEY_$i"; v="GIT_CONFIG_VALUE_$i"
    if [ "${!k:-}" = "http.https://$host/.extraheader" ]; then
      case "${!v:-}" in "AUTHORIZATION: basic "?*) found=1 ;; esac
    fi
    i=$((i + 1))
  done
  [ "$found" = 1 ]
}

# Push recursion: the passthrough's fg_push_recurses, the one copy both routes
# share (DND-1841). It reads every source git does, in git's order.
if fg_push_recurses afp_g "$@"; then
  afp_refuse "this git push: it pushes submodules too ($FG_RECURSE_SRC), and each submodule push runs through git's exec-path, where no check sees which forge it reaches or as whom (DND-1803, DND-1841)." \
    "push with --no-recurse-submodules, and push each submodule separately from its own directory; a push to github.com or gitlab.com goes through ~/dev/custom/ai/bin/gh-athena git push … or ~/dev/custom/ai/bin/glab-athena git push …."
fi
for host in github.com gitlab.com; do
  rc=0; afp_reaches "$host" || rc=$?
  case "$rc" in
    0) ;;
    3) afp_refuse "this git push${AFP_URL:+ to $(afp_shown "$AFP_URL")}: it would reach $host over SSH or another non-HTTPS transport, or recurse into submodules, or it carries an option or alias the check cannot read by git's grammar, so it can go out with the machine owner's SSH key, not Athena's (DND-1803, DND-1843)." \
         "$(afp_fix "$host") Point the remote at https://$host/<owner>/<repo>.git (or git@$host:<owner>/<repo>.git, which the route rewrites), push each submodule separately, and spell every option in full as \`git push -h\` lists it." ;;
    *) afp_refuse "this git push: its remote could not be resolved (exit $rc), so whether it goes to $host as the machine owner is unknown (DND-1803)." \
         "run it again from inside the repository with a configured remote; to push to a forge, $(afp_fix "$host")" ;;
  esac
  [ -n "$AFP_URL" ] || continue
  afp_routed "$host" && continue
  afp_refuse "a plain git push to $host ($(afp_shown "$AFP_URL")): it authenticates with the machine owner's SSH key or credential helper, so the forge records the owner, not Athena (DND-1803)." \
    "$(afp_fix "$host")"
done
exit 0
