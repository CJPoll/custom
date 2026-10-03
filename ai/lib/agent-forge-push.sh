# shellcheck shell=bash
# agent-forge-push.sh — the forge-identity check the agent PATH git wrapper
# (ai/agent-bin/git) runs before a `git push` (DND-1803), and before every
# subcommand that is not a builtin, and send-pack (DND-1881). Run, not sourced:
#
#   ATHENA_REAL_GIT=<the real git> bash agent-forge-push.sh <git global options...> <subcommand> <args...>
#
# The wrapper passes the argv it resolved (aliases expanded, global options
# kept). Exit 0: the command may run. Exit 1: refused, one stderr line ending
# in a Fix: (a COULD NOT LOOK on git's command lists is the passthrough's own
# two-line refusal, fg_cmd_list). Exit 10 (not push): git runs no command of
# that name, so the wrapper reads it as an alias. The wrapper refuses on any
# other status, before git runs. `push -h` and
# `push --help` are not judged when -h or --help is the first push argument;
# anywhere else it is judged, since there it may be an option's value
# (DND-1843). The global-option peel below and the push walk it borrows
# (fg_refuse_non_https) read git's own option tables, kept once in the
# passthrough ("git's own argv grammar").
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
# Also refused, to any remote, a local path included: a push that makes git
# run a command itself (--receive-pack, --exec, an ext:: address,
# --exec-path=<dir>, a GIT_EXEC_PATH that is not git's own), by the
# passthrough's "Commands git runs itself" (DND-1844). Otherwise a local path
# or another host is allowed.
#
# WHAT ELSE IS JUDGED (DND-1881). A subcommand other than push, by the
# passthrough's "Remote-ref writers other than push" (DND-1867), so the two
# routes share one classification:
#   * a moved exec-path (--exec-path=<dir>, a GIT_EXEC_PATH that is not
#     git's own) is refused first: every git-<name> in <dir> would read as
#     git's own command (DND-1844);
#   * a name git does not run as its own command (`git --list-cmds=main`):
#     a git-<name> program on PATH (`--list-cmds=others`) is refused, because
#     every git it runs comes from git's exec-path, past this wrapper, and
#     running it by its own name is the Fix; anything else is exit 10;
#   * a remote-ref writer (send-pack, http-push, a remote-<name> transport
#     helper, subtree push in either word order) is refused when it reaches
#     github.com or gitlab.com, by any transport and whatever its credential:
#     no route judges its refs, so the Fix is `gh-athena git push` /
#     `glab-athena git push`. Every word and every --option=value of its argv
#     counts as a possible repository: as written (send-pack applies no
#     insteadOf), and as git resolves it for a push and for a fetch (a
#     remote's URLs and push URLs, pushInsteadOf, insteadOf). A word that
#     cannot be resolved counts as reaching the forge;
#   * a remote-ref writer that makes git run a command (send-pack
#     --receive-pack or --exec, an ext:: address, remote-ext) is refused to
#     any remote (DND-1844), and remote-fd, whose host no argument names, is
#     refused outright. A command that writes no remote ref is not checked
#     for that here (`fetch ext::…`, `subtree add ext::…`): see RESIDUAL;
#   * every other own command runs.
# Accepted false refusals (fail closed): a forge URL written out in the argv
# that the repository's insteadOf sends elsewhere (a remote NAME so rewritten
# passes); a refspec, prefix or other word spelled like a forge URL or named
# like a remote that reaches one; remote-fd; any git-<name> program on PATH,
# whatever it does (git-custom's `git hub`, `git rekt`, …, and `git lfs`
# where git-lfs is installed on PATH: run them as `git-hub`, `git-rekt`,
# `git-lfs`).
#
# WHAT IS ROUTED. A forge push is allowed only when it carries the credential
# isolation the Athena passthrough (fg_git_exec) gives git, for that host:
#   * the last credential helper entry (credential.helper or
#     credential.<url>.helper, in git's config order) is an empty
#     `credential.helper`, which resets the list: no owner helper is consulted;
#   * core.askPass is set and empty, GIT_ASKPASS and SSH_ASKPASS are unset, and
#     GIT_TERMINAL_PROMPT=0: nothing can prompt for the owner's password;
#   * the route's rewrites to its transport in the push's config,
#     url.athena-forge::https://<host>/.insteadOf=git@<host>: and
#     =https://<host>/, and the URL git will use is
#     athena-forge::https://<host>/...;
#   * the route's credential grant for that host: ATHENA_FG_HOST=<host> and
#     ATHENA_FG_CRED_FD naming an open pipe (DND-1868; the passthrough's "The
#     credential grant"). Before DND-1868 the marker was an
#     http.https://<host>/.extraheader entry in the environment config
#     channel, which the route no longer sets: that alone is not routed.
# A plain shell sets none of this. With all of it, the push goes out through
# the route's transport, whose only credential is the bot header it reads from
# the grant: the owner's SSH key, credential helper and keyring are out of
# reach.
#
# RESIDUAL (it is not a sandbox). Defeated by: a caller that builds the whole
# marker by hand, a pipe holding the OWNER's token included (deliberate, and it
# needs the token read out first); git run by absolute path or with a PATH that skips
# the wrapper (the DND-775 residual list in ai/agent-bin/git); a push from a
# process git starts itself (a `!` alias, `rebase -x`, `submodule foreach`,
# `bisect run`, a git hook), which runs with git's exec-path first on PATH,
# where a real `git` sits (the Athena route refuses these forms, DND-1844;
# this check refuses only those named in "WHAT ELSE IS JUDGED", so an ext::
# address outside a remote-ref writer, `fetch ext::…`, runs); a non-git
# client (libgit2, an HTTP call); and a forge host no URL spells as github.com
# or gitlab.com (an ~/.ssh/config Host alias such as `myalias:owner/repo`, an
# IP literal).
# The passthrough's own resolution residuals (its header) apply too.
# A known false refusal: a push the forge CLI runs on a routed call
# (`gh-athena repo create --push`, `glab-athena mr create --push`) carries no
# route grant, so it is refused; push first with `gh-athena git push` /
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
  afp_refuse "this git command: the forge-identity check was not given the real git (ATHENA_REAL_GIT='${AFP_REAL}'), so it cannot tell where the command writes." \
    "run git through ai/agent-bin/git, which sets it; to push to a forge, use ~/dev/custom/ai/bin/gh-athena git push … or ~/dev/custom/ai/bin/glab-athena git push …."
fi
# Every git this check runs is the real one, never the wrapper again. None of
# them gets the route's credential grant (DND-1868): the pipe is closed for
# each probe, and its variable emptied, so a command a probe might start
# (core.fsmonitor on an index read) cannot drain it before the push's
# transport does.
AFP_GRANT_FD="${ATHENA_FG_CRED_FD:-}"
case "$AFP_GRANT_FD" in '' | *[!0-9]*) AFP_GRANT_FD="" ;; esac
git() {
  if [ -n "$AFP_GRANT_FD" ]; then ATHENA_FG_CRED_FD= "$AFP_REAL" "$@" {AFP_GRANT_FD}<&-
  else "$AFP_REAL" "$@"; fi
}

AFP_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-git-passthrough.sh"
# shellcheck source=forge-git-passthrough.sh
if ! . "$AFP_LIB" 2>/dev/null || ! declare -F fg_refuse_non_https >/dev/null || ! declare -F fg_push_recurses >/dev/null \
   || ! declare -F fg_global_opt >/dev/null || ! declare -F fg_cmd_known >/dev/null \
   || ! declare -F fg_cmd_list >/dev/null || ! declare -F fg_writes_remote_ref >/dev/null \
   || ! declare -F fg_runs_command >/dev/null; then
  afp_refuse "this git command: cannot load $AFP_LIB, so whether it writes to a forge is unknown." \
    "restore ai/lib/forge-git-passthrough.sh beside ai/lib/agent-forge-push.sh in the checkout that holds ai/agent-bin; to push to a forge meanwhile, use ~/dev/custom/ai/bin/gh-athena git push … or ~/dev/custom/ai/bin/glab-athena git push …."
fi
# The resolver adds its own SSH-to-HTTPS rewrite to every probe, because the
# passthrough adds the same rewrite to the git it runs. This push carries only
# the rewrites in its own config, so the probes must too: a harmless key here.
fg_rewrite() { printf 'agentforgepush.noop=1'; }

# The git global options before the subcommand, by git's grammar (the options
# that take a separate value), for the config probes below; then the
# subcommand and its own args. The wrapper passes only global options it
# knows, then the subcommand.
AFP_GLOB=()
while [ $# -gt 0 ]; do
  case "$1" in -*) ;; *) break ;; esac
  if fg_global_opt "$1"; then
    [ $# -ge 2 ] || break
    AFP_GLOB+=("$1" "$2"); shift 2
  else
    AFP_GLOB+=("$1"); shift
  fi
done
AFP_SUB="${1:-}"
[ $# -gt 0 ] && shift
AFP_ARGV=("${AFP_GLOB[@]}" push "$@")
# Help goes unjudged only where git always prints it and pushes nothing: -h
# or --help as the FIRST push argument (git.c turns `push --help` into `git
# help push`; parse-options exits on a leading -h). Anywhere else it is judged
# like any push (DND-1843): there it may be an option's value (`-o -h`,
# `--push-option --help`), which git pushes with. Where git would print help
# after all (`push origin -h`, `push -o -- -h`), a refusal costs only the help.
[ "$AFP_SUB" = push ] && case "${1:-}" in -h | --help) exit 0 ;; esac

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
        # athena-forge::https is the route's own transport (DND-1868).
        case "${hs%% *}" in https | athena-forge::https) ;; *) return 3 ;; esac
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
  local host="$1" last askpass rules fd
  [ "${GIT_TERMINAL_PROMPT:-}" = 0 ] || return 1
  [ -z "${GIT_ASKPASS+x}" ] && [ -z "${SSH_ASKPASS+x}" ] || return 1
  last="$(git "${AFP_GLOB[@]}" config --get-regexp '^credential\..*helper$' 2>/dev/null | tail -n 1)"
  [ "$last" = credential.helper ] || [ "$last" = 'credential.helper ' ] || return 1
  askpass="$(git "${AFP_GLOB[@]}" config --get core.askPass 2>/dev/null)" || return 1
  [ -z "$askpass" ] || return 1
  # The route's rewrites to its transport, both forge forms (DND-1868).
  rules=$'\n'"$(git "${AFP_GLOB[@]}" config --get-all "url.athena-forge::https://$host/.insteadof" 2>/dev/null)"$'\n'
  [[ "$rules" == *$'\n'"git@$host:"$'\n'* ]] && [[ "$rules" == *$'\n'"https://$host/"$'\n'* ]] || return 1
  # The URL is the route's transport, and the route's grant is open for this host.
  case "$AFP_URL" in "athena-forge::https://$host/"?*) ;; *) return 1 ;; esac
  [ "${ATHENA_FG_HOST:-}" = "$host" ] || return 1
  fd="${ATHENA_FG_CRED_FD:-}"
  case "$fd" in '' | *[!0-9]*) return 1 ;; esac
  [ -p "/proc/self/fd/$fd" ]
}

# ---- Remote-ref writers other than push (DND-1881) ---------------------------
# Every subcommand but push lands here. The classification is the
# passthrough's "Remote-ref writers other than push" (DND-1867): which names
# git runs as its own commands (fg_cmd_known, from `git --list-cmds`), which
# argv writes a remote ref (fg_writes_remote_ref), and which makes git run a
# command itself (fg_runs_command). Only the refusal wording is this
# wrapper's. See the header's "WHAT ELSE IS JUDGED".

# The wrapper reads exit 10 as "no command of git's: read the name as an alias".
AFP_NOT_A_COMMAND=10

# G: the probe git the passthrough's command lists run through.
G() { git "${AFP_GLOB[@]}" "$@"; }

# The passthrough refuses a PATH program in its own words, for its route.
fg_refuse_path_cmd() {
  afp_refuse "\`git $1\`: git-$1 is a program on PATH, not one of git's own commands. git runs it with its exec-path first on PATH, so every git it runs is the real git, past this wrapper, and a push it makes is judged by nothing (DND-1881)." \
    "run it by its own name, \`git-$1 …\`: then the git it runs is this wrapper, which judges its pushes. To push to a forge, use ~/dev/custom/ai/bin/gh-athena git push … or ~/dev/custom/ai/bin/glab-athena git push …."
}

# afp_writer_reaches <host> <word> : 0 when <word> names <host> (or a
# subdomain): as written (send-pack and http-push use their URL as written,
# with no insteadOf), or as git resolves it for a push and for a fetch (a
# remote's URLs and push URLs, pushInsteadOf, insteadOf), by the route's own
# resolver (afp_reaches). Sets AFP_URL. A word the resolver refuses or cannot
# resolve counts as reaching it: could not look is not "no forge".
afp_writer_reaches() {
  local host="$1" w="$2" hs h rc kind
  hs="$(fg_url_host_scheme "$w")"
  if [ -n "$hs" ]; then
    h="${hs#* }"
    while [ "${h%.}" != "$h" ]; do h="${h%.}"; done
    case "$h" in "$host" | *."$host") AFP_URL="$w"; return 0 ;; esac
  fi
  for kind in push ls-remote; do
    if [ "$kind" = push ]; then AFP_ARGV=("${AFP_GLOB[@]}" push --no-recurse-submodules -- "$w")
    else AFP_ARGV=("${AFP_GLOB[@]}" ls-remote -- "$w"); fi
    rc=0; afp_reaches "$host" || rc=$?
    # 3: the route's resolver refuses it for <host> (a non-HTTPS forge URL).
    # Anything else: it could not resolve the word, which is no "not a forge".
    case "$rc" in
      0) [ -n "$AFP_URL" ] && return 0 ;;
      3) AFP_URL="${AFP_URL:-$w}"; return 0 ;;
      *) AFP_URL="$w"; AFP_WR_UNSURE="its target could not be resolved (exit $rc), so it may"; return 0 ;;
    esac
  done
  return 1
}

AFP_WR_UNSURE=""

# afp_writer <subcommand> <args...> : judge a subcommand other than push, and
# exit: 0 it may run; 1 refused; AFP_NOT_A_COMMAND when git runs no command of
# that name (an alias, or a name git does not know: the wrapper decides).
afp_writer() {
  local sub="$1" a w host
  shift
  FG_TOOL="$AFP_TAG"
  # A moved exec-path (--exec-path=<dir>, a GIT_EXEC_PATH that is not git's
  # own) makes every git-<name> in <dir> read as git's own command, and git
  # runs its helpers from there: the push refuses it (DND-1844), so does this.
  if fg_exec_path_moved "${AFP_GLOB[@]}"; then
    afp_refuse "\`git $sub …\`: $FG_RC_WHAT, so a program there reads as one of git's own commands and any git it runs is past this wrapper (DND-1844, DND-1881)." \
      "$FG_RC_FIX."
  fi
  # git's command lists, read once here; fg_cmd_list refuses, COULD NOT LOOK,
  # when git cannot list them, and a failed list is never an empty one.
  FG_OWN_CMDS=$'\n'"$(fg_cmd_list main)"$'\n' || exit 1
  FG_PATH_CMDS=$'\n'"$(fg_cmd_list others)"$'\n' || exit 1
  fg_cmd_known "$sub" || exit "$AFP_NOT_A_COMMAND"
  fg_writes_remote_ref "$sub" "$@" || exit 0
  if fg_runs_command "$sub" "$@"; then
    afp_refuse "\`git $sub …\`: it makes git run a command itself ($FG_RC_WHAT), and any git that command runs comes from git's exec-path, past this wrapper, so a push it makes is judged by nothing (DND-1844, DND-1881)." \
      "drop that option or address. To write a remote ref, use \`git push\`, which this wrapper judges; to push to a forge, ~/dev/custom/ai/bin/gh-athena git push … or ~/dev/custom/ai/bin/glab-athena git push …."
  fi
  [ "$sub" = remote-fd ] && afp_refuse "\`git remote-fd …\`: a transport helper that pushes over descriptors its caller opened, to a host no argument names, so whether it reaches github.com or gitlab.com as the machine owner is unknown (DND-1881)." \
    "write the ref with \`git push\`, which this wrapper judges; to push to a forge, ~/dev/custom/ai/bin/gh-athena git push … or ~/dev/custom/ai/bin/glab-athena git push …."
  # Every word, and every --option=value, is a possible repository: a word
  # that is a refspec or a prefix can only add a check (fails closed).
  for a in "$@"; do
    case "$a" in
      --*=*) w="${a#*=}" ;;
      -*) continue ;;
      *) w="$a" ;;
    esac
    [ -n "$w" ] || continue
    for host in github.com gitlab.com; do
      afp_writer_reaches "$host" "$w" || continue
      case "$host" in github.com) FG_TOOL=gh-athena ;; *) FG_TOOL=glab-athena ;; esac
      fg_writes_remote_ref "$sub" "$@"
      afp_refuse "\`git $sub …\` to $(afp_shown "$AFP_URL"): ${AFP_WR_UNSURE:-it} writes a remote ref on $host without \`git push\` ($FG_RW_WHAT), so it goes out with the machine owner's SSH key or credential helper, never as Athena: only \`git push\` is judged for its remote and identity, so only a push can go out as Athena (DND-1881)." \
        "$FG_RW_FIX."
    done
  done
  exit 0
}

[ "$AFP_SUB" = push ] || afp_writer "$AFP_SUB" "$@"

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
    3) afp_refuse "this git push${AFP_URL:+ to $(afp_shown "$AFP_URL")}: the Athena route's resolver refuses it, for one of these reasons: it would reach $host over SSH or another non-HTTPS transport, so it can go out with the machine owner's SSH key, not Athena's (DND-1803); it recurses into submodules, or carries an option or alias the check cannot read by git's grammar, so where it goes is unknown (DND-1841, DND-1843); or it makes git run a command itself (--receive-pack, --exec, an ext:: address, --exec-path=<dir>, a GIT_EXEC_PATH that is not git's own), which runs past every check (DND-1844); or it could not list git's commands (git --list-cmds, DND-1867)." \
         "$(afp_fix "$host") Point the remote at https://$host/<owner>/<repo>.git (or git@$host:<owner>/<repo>.git, which the route rewrites), push each submodule separately, spell every option in full as \`git push -h\` lists it, drop --receive-pack, --exec and --exec-path, and unset a GIT_EXEC_PATH you set. The route's own refusal names the reason: run the same push through it to see it." ;;
    *) afp_refuse "this git push: its remote could not be resolved (exit $rc), so whether it goes to $host as the machine owner is unknown (DND-1803)." \
         "run it again from inside the repository with a configured remote; to push to a forge, $(afp_fix "$host")" ;;
  esac
  [ -n "$AFP_URL" ] || continue
  afp_routed "$host" && continue
  afp_refuse "a plain git push to $host ($(afp_shown "$AFP_URL")): it authenticates with the machine owner's SSH key or credential helper, so the forge records the owner, not Athena (DND-1803)." \
    "$(afp_fix "$host")"
done
exit 0
