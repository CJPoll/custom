# shellcheck shell=bash
#
# forge-git-passthrough.sh — the shared `<wrapper> git …` passthrough behind
# `gh-athena git` (DND-389) and `glab-athena git` (DND-393). Sourced, never run.
#
# A bot token reaches only the route's forge transport, over HTTPS (DND-1868;
# "The credential grant" below), so everything else about the command must
# keep the machine owner's identity OUT, for that one command, with no
# git/gh/glab config change:
#
#   * url.athena-forge::https://<host>/.insteadOf=git@<host>: and
#     =https://<host>/ — an SSH-form remote (the default a `git clone
#     git@<host>:...` leaves) and an HTTPS one both go to the route's
#     transport, git-remote-athena-forge, so the plain `<wrapper> git push
#     origin HEAD` is correct by default. Without the first the push goes over
#     SSH with the OWNER's key and the forge records the owner.
#   * credential.helper= (empty resets the list, URL-scoped helpers included),
#     core.askPass= , GIT_ASKPASS/SSH_ASKPASS unset, GIT_TERMINAL_PROMPT=0 — no
#     fallback source of the owner's credentials; a bot-auth failure FAILS.
#   * fg_refuse_non_https: before exec, for the network subcommands it knows —
#     push, fetch, pull, ls-remote, clone, remote update, submodule, subtree
#     pull/add, and git aliases that expand to them — every URL the command
#     would reach is resolved (rewrite applied, pushurl and pushInsteadOf
#     included, submodule URLs when it recurses) and the command is REFUSED if
#     any still reaches <host> over SSH or another non-HTTPS transport
#     (ssh://, git://, http://, a pushurl override, an insteadOf that forces
#     SSH). Refused outright: a shell alias (`!...`), an alias with quotes or
#     backslashes (split differently here than by git), and a push that
#     recurses into submodules: by an explicit flag, or by
#     push.recurseSubmodules / submodule.recurse in a repository that has
#     submodules (fg_push_recurses says what counts). Also refused: a global
#     option, or a push option, that git's grammar does not have, since the
#     word after it could be its value (DND-1843; "git's own argv grammar"
#     below holds the tables, and names the walks that read them). Also
#     refused: any form that makes git run a command the caller chose
#     (submodule foreach, bisect run, rebase --exec, an ext:: address,
#     --exec-path, ...), since any git that command runs is past every
#     check here (DND-1844; "Commands git runs
#     itself" below lists them and the residual). Also refused: a command
#     that writes a remote ref other than `git push` (send-pack, http-push,
#     a remote-<name> transport helper, subtree push), since only a push is
#     judged for its remote, recursion, a red main and the gate; a
#     git-<name> program on PATH that is not git's own; a subcommand git
#     does not know, which help.autocorrect may turn into one; and an alias
#     chain more than 10 deep (DND-1867; "Remote-ref writers other than
#     push" below). A refusal is exit 3 with a Fix: line.
#   * fg_refuse_red_main (DND-1482): a push to main is refused while
#     ai/bin/main-health has recorded origin/main RED, unless it lands a gated
#     fix. Also exit 3 with a Fix: line. See "Red-main refusal" below.
#   * fg_refuse_ungated_main (DND-1690): in a repo that declares a gate, a push
#     to main is refused, on a green main too, unless integration-gate covers
#     the pushed commit. Also exit 3 with a Fix: line. See "Ungated-main
#     refusal" below.
#
# Residual (NOT checked; each still runs): an ~/.ssh/config Host alias for the
# forge host (`myalias:owner/repo`); `clone
# --recurse-submodules` (the submodule URLs are unknown until the clone lands);
# git-lfs transfers from a push (a git-lfs on PATH is refused when called
# directly, like any git-<name> that is not git's own); a push whose recursion comes
# from config, in a repository where
# only the pushed commit (not the index, .gitmodules or config) records a
# populated nested repository as a gitlink (fg_push_recurses).
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

# The route's transport (DND-1868): a directory holding only
# git-remote-athena-forge (and refuse-signing, which it names), put first on
# git's PATH by fg_git_exec.
FG_TRANSPORT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-transport"

# fg_rewrite : the route's URL rewrites, one config entry per line. Both forge
# forms (SSH and HTTPS) go to the route's transport. ai/lib/agent-forge-push.sh
# redefines it to a harmless key (its probes see only the push's own config).
fg_rewrite() {
  printf 'url.athena-forge::https://%s/.insteadOf=git@%s:\n' "$FG_HOST" "$FG_HOST"
  printf 'url.athena-forge::https://%s/.insteadOf=https://%s/\n' "$FG_HOST" "$FG_HOST"
}

# fg_rewrite_args : sets FG_REWRITE_ARGS to `-c <entry>` for each fg_rewrite
# line. Every probe puts them BEFORE the caller's global options, where
# fg_git_exec puts them: of two insteadOf rules with the same prefix git
# applies the one defined first, so the order must match what git will run.
FG_REWRITE_ARGS=()
fg_rewrite_args() {
  local l
  FG_REWRITE_ARGS=()
  while IFS= read -r l; do
    [ -n "$l" ] && FG_REWRITE_ARGS+=( -c "$l" )
  done < <(fg_rewrite)
}

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
# subdomain) over anything but https. The route's own transport,
# athena-forge::https://, is https (DND-1868).
fg_reaches_forge_insecurely() {
  local sh scheme host
  sh="$(fg_url_host_scheme "$1")"
  [ -n "$sh" ] || return 1
  scheme="${sh%% *}"; host="${sh#* }"
  case "$host" in "$FG_HOST"|*."$FG_HOST") ;; *) return 1 ;; esac
  [ "$scheme" != "https" ] && [ "$scheme" != "athena-forge::https" ]
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

fg_refuse_quoted_alias() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: it is an alias with quotes or backslashes ('$2'), which $FG_TOOL does not split the way git does, so it cannot check which remote it reaches or what it pushes.
  Fix: run the underlying git command directly through the wrapper — \`~/dev/custom/ai/bin/$FG_TOOL git <the expanded command>\`. $FG_ESCALATE
EOF
  exit 3
}

# fg_refuse_alias_depth <alias> : an alias chain longer than this route reads.
fg_refuse_alias_depth() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: it is an alias chain more than 10 aliases deep, which $FG_TOOL does not read to its end, so it cannot check which command it reaches, which remote, or what it pushes.
  Fix: run the underlying git command directly through the wrapper — \`~/dev/custom/ai/bin/$FG_TOOL git <the expanded command>\`. $FG_ESCALATE
EOF
  exit 3
}

# fg_refuse_option <word> <what it is> : an option this wrapper cannot read by
# git's grammar, so which word is the subcommand, repository or refspec is
# unknown (DND-1843). The word is a flag, never a URL, so it is safe to print.
fg_refuse_option() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git … $1 …\`: $2, so $FG_TOOL cannot tell which word git reads as the subcommand, repository or refspec, or whether it reaches $FG_HOST as $FG_OWNER.
  Fix: spell the option in full as \`git -h\` / \`git push -h\` list it (no abbreviation that matches two options), give it the value it needs, or drop it, then run \`~/dev/custom/ai/bin/$FG_TOOL git …\` again. $FG_ESCALATE
EOF
  exit 3
}

# fg_refuse_unchecked <subcommand> <why>
fg_refuse_unchecked() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: $2, so it could reach $FG_HOST as $FG_OWNER unchecked.
  Fix: push with --no-recurse-submodules (or drop the --recurse-submodules / push.recurseSubmodules / submodule.recurse that turns it on), and push each submodule separately from its own directory through \`~/dev/custom/ai/bin/$FG_TOOL git -C <submodule> push …\`. $FG_ESCALATE
EOF
  exit 3
}

# ---- Push recursion into submodules (DND-1803, DND-1841) ---------------------
# One copy, shared: this passthrough judges `push` with it (subtree push is
# refused outright, DND-1867),
# and ai/lib/agent-forge-push.sh (the agent PATH git wrapper's forge-identity check)
# sources this file and calls it too.
#
# fg_push_recurses <probe> [<push args>...] : 0 when the push would also push
# submodules. <probe> is a command (a function name) that runs git with the
# push's own global options (-C, -c, ...), so every config read sees what the
# push will see. Sets FG_RECURSE_SRC to the source that decided it, for the
# refusal message.
#
# How git decides, measured on git 2.54 against real pushes (DND-1841):
#   * A --recurse-submodules flag beats config. The LAST flag wins. Its value
#     may be `=<v>` or the next word; long names may be abbreviated (--recu=).
#     on-demand and only push submodules; check and no do not.
#   * Without a flag, push.recurseSubmodules and submodule.recurse are applied
#     in config order (system, global, local, worktree, -c and the environment
#     config channel), the LAST of either key wins. push.recurseSubmodules
#     contributes its own last value; submodule.recurse true means on-demand.
#
# Conservative, so a parse slip can only over-refuse, never let one through:
#   * any "on" flag anywhere counts, whatever follows it, and is refused in
#     any repository: an explicit flag asks for recursion by name;
#   * an "off" flag, or the `--` or `--end-of-options` that ends the
#     options, counts only when the word before it is not an option that
#     takes a separate value (-o, --push-option, --repo, ...), since there it
#     may be that option's value;
#   * a value that is not a known "off" reads as on (git rejects most of them);
#   * config that cannot be read reads as on.
# Recursion that comes from config is refused only in a repository that has
# submodules (fg_has_submodules), so a global submodule.recurse=true does not
# block every push in a repository with none. Residual, config-sourced only: a
# populated nested repository that only a pushed commit, not the index,
# records as a gitlink.
FG_RECURSE_SRC=""
fg_push_recurses() {
  local probe="$1"; shift
  local a prev="" name val v cli="" on_src="" rc rec k last_push="" state=off cfg_src=""
  FG_RECURSE_SRC=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    if { [ "$a" = -- ] || [ "$a" = --end-of-options ]; } && ! fg_takes_value "$prev"; then break; fi
    case "$a" in
      --no-*)
        name="${a#--no-}"
        if fg_recurse_name "$name" && ! fg_takes_value "$prev"; then cli=off; fi ;;
      --*=*)
        name="${a%%=*}"; name="${name#--}"; val="${a#*=}"
        if fg_recurse_name "$name"; then
          if fg_recurse_off "$val"; then fg_takes_value "$prev" || cli=off
          else on_src="$a"; fi
        fi ;;
      --?*)
        name="${a#--}"
        if fg_recurse_name "$name"; then
          val="${1-}"; [ $# -gt 0 ] && shift
          if [ -n "${val}" ] && fg_recurse_off "$val"; then fg_takes_value "$prev" || cli=off
          else on_src="$a $val"; fi
          prev=""; continue
        fi ;;
    esac
    prev="$a"
  done
  if [ -n "$on_src" ]; then
    FG_RECURSE_SRC="the flag $on_src"
    return 0
  fi
  [ "$cli" = off ] && return 1
  # Config, in git's order. -z: each record is "key\nvalue" (or a bare key for
  # a valueless entry), NUL-terminated, so a value cannot forge a record. The
  # read's own exit status rides in as a last, unterminated record (an && ||
  # list, so a caller's set -e, inherited here, cannot drop it).
  local -a recs=()
  mapfile -d '' -t recs < <("$probe" config -z --get-regexp '^(push\.recursesubmodules|submodule\.recurse)$' 2>/dev/null \
                              && printf 'rc=0' || printf 'rc=%s' "$?")
  rc=""
  if [ "${#recs[@]}" -gt 0 ]; then
    rc="${recs[${#recs[@]}-1]}"
    unset 'recs[${#recs[@]}-1]'
  fi
  case "$rc" in rc=[0-9]*) rc="${rc#rc=}" ;; *) rc="unknown" ;; esac
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *) FG_RECURSE_SRC="git config that cannot be read (exit $rc)"; return 0 ;;
  esac
  for rec in "${recs[@]}"; do
    [ "${rec%%$'\n'*}" = push.recursesubmodules ] || continue
    case "$rec" in *$'\n'*) last_push="${rec#*$'\n'}" ;; *) last_push=$'\001' ;; esac
  done
  for rec in "${recs[@]}"; do
    [ -n "$rec" ] || continue
    k="${rec%%$'\n'*}"
    case "$rec" in *$'\n'*) v="${rec#*$'\n'}" ;; *) v=$'\001' ;; esac
    case "$k" in
      submodule.recurse)
        # git's bool: a valueless key is true.
        if [ "$v" != $'\001' ] && fg_bool_false "$v"; then state=off
        else state=on; cfg_src="submodule.recurse=${v/$'\001'/true} in git config"; fi ;;
      push.recursesubmodules)
        if [ "$last_push" != $'\001' ] && fg_recurse_off "$last_push"; then state=off
        else state=on; cfg_src="push.recurseSubmodules=${last_push/$'\001'/(no value)} in git config"; fi ;;
    esac
  done
  [ "$state" = on ] || return 1
  FG_RECURSE_SRC="$cfg_src"
  fg_has_submodules "$probe"
}

# fg_recurse_name <long option name> : 0 when git reads it as
# --recurse-submodules (the full name, or an abbreviation of at least `recu`;
# `rec` is ambiguous with --receive-pack and git refuses it).
fg_recurse_name() {
  [ "${#1}" -ge 4 ] && [[ recurse-submodules == "$1"* ]]
}

# fg_recurse_off <value> : 0 when a --recurse-submodules / push.recurseSubmodules
# value pushes no submodule (no, check, or git's false). Anything else is on.
fg_recurse_off() {
  [ "${1,,}" = check ] && return 0
  fg_bool_false "$1"
}

# fg_bool_false <value> : 0 when git's bool parse reads it as false.
fg_bool_false() {
  case "${1,,}" in ''|false|no|off|0) return 0 ;; esac
  return 1
}

# fg_takes_value <word> : 0 when <word> is a push option whose value is the
# NEXT word, so that next word is a value, not a flag. Abbreviations count
# (any prefix of the long name), which can only over-refuse.
fg_takes_value() {
  local w="$1" n long
  case "$w" in
    -o|-[!-]*o) return 0 ;;
    --*=*|--) return 1 ;;
    --?*)
      n="${w#--}"
      for long in $FG_PUSH_VALUE_OPTS; do
        [[ "$long" == "$n"* ]] && return 0
      done ;;
  esac
  return 1
}

# ---- git's own argv grammar (DND-1843) ---------------------------------------
# An option VALUE read as a word of its own was a fail-open, in each walk that
# made it: `push -o -h` read as help, `--attr-source HEAD push` read HEAD as
# the subcommand, `push --push-o x` read x as the repository and so never
# judged the default remote, `push --push-o --dry-run … :main` read a dry run.
# So the global-option peels and the push walk behind every refusal here
# (fg_refuse_non_https, the red-main and ungated-main refspec parse, the
# landing telemetry) read argv by git's own tables, measured on git 2.54
# (`git -h`, `git push -h`, and real runs), kept in one place.
# fg_push_recurses keeps its own conservative walk over FG_PUSH_VALUE_OPTS.
# ai/agent-bin/git, a POSIX sh script, keeps its own copy of the global
# tables (its step 2); the two are kept equal by hand.
# Residual: the subtree pull/add and fetch walks in fg_refuse_non_https match
# value options by exact name only.
#
# Global options (git.c handle_options). Value as the next word:
FG_GLOBAL_VALUE_OPTS="-C -c --git-dir --work-tree --namespace --config-env --attr-source --shallow-file"
# Switches:
FG_GLOBAL_SWITCHES="-p -P --paginate --no-pager --bare --no-replace-objects --no-lazy-fetch --literal-pathspecs --no-literal-pathspecs --glob-pathspecs --noglob-pathspecs --icase-pathspecs --no-optional-locks --no-advice"
# Options that print and exit: no subcommand after them runs.
FG_GLOBAL_EXITS="-v --version -h --help --exec-path --html-path --man-path --info-path"
# Plus the --name=value spellings of --git-dir, --work-tree, --namespace,
# --config-env, --attr-source, --exec-path and --list-cmds.
FG_GLOBAL_STICKY="git-dir work-tree namespace config-env attr-source exec-path list-cmds"

# fg_global_opt <word> : 0 a global option whose value is the next word; 1 a
# global option with no separate value; 3 an option that prints and exits, so
# no subcommand runs; 2 an option git does not have (or a word that is no
# option). Exact names only: git does not abbreviate these.
fg_global_opt() {
  local w="$1" o
  for o in $FG_GLOBAL_VALUE_OPTS; do [ "$w" = "$o" ] && return 0; done
  for o in $FG_GLOBAL_SWITCHES; do [ "$w" = "$o" ] && return 1; done
  for o in $FG_GLOBAL_EXITS; do [ "$w" = "$o" ] && return 3; done
  case "$w" in
    --?*=*) for o in $FG_GLOBAL_STICKY; do [ "${w%%=*}" = "--$o" ] && return 1; done ;;
  esac
  return 2
}

# git push's options (`git push -h`). Value as the next word or after `=`:
FG_PUSH_VALUE_OPTS="repo recurse-submodules receive-pack exec push-option"
# A value only after `=`:
FG_PUSH_OPTARG_OPTS="force-with-lease signed"
# No value:
FG_PUSH_SWITCHES="verbose quiet all branches mirror delete tags dry-run porcelain force force-if-includes thin set-upstream progress prune follow-tags atomic"
# Every option above also has a --no- form (no value); these four do not:
FG_PUSH_PLAIN="verify no-verify ipv4 ipv6"
# Short options and their long names. -o takes a value; -h is help.
FG_PUSH_SHORT="v:verbose q:quiet d:delete n:dry-run f:force u:set-upstream 4:ipv4 6:ipv6 o:push-option"

# fg_push_long <name> : sets FG_PL_NAME to the long option git resolves
# --<name> to: an exact name, else the one name it is a prefix of. Returns 1
# when it is none, or a prefix of more than one (git refuses both).
FG_PL_NAME=""
fg_push_long() {
  local want="$1" o x hit="" n=0
  FG_PL_NAME=""
  [ -n "$want" ] || return 1
  for o in $FG_PUSH_VALUE_OPTS $FG_PUSH_OPTARG_OPTS $FG_PUSH_SWITCHES; do
    for x in "$o" "no-$o"; do
      [ "$x" = "$want" ] && { FG_PL_NAME="$x"; return 0; }
      [[ "$x" == "$want"* ]] && { hit="$x"; n=$((n + 1)); }
    done
  done
  for o in $FG_PUSH_PLAIN; do
    [ "$o" = "$want" ] && { FG_PL_NAME="$o"; return 0; }
    [[ "$o" == "$want"* ]] && { hit="$o"; n=$((n + 1)); }
  done
  [ "$n" = 1 ] || return 1
  FG_PL_NAME="$hit"
}

# ---- Commands git runs itself (DND-1844) -------------------------------------
# A command git starts itself inherits this route's environment: git's
# exec-path at the front of PATH, where a real git sits and no wrapper does,
# and, before DND-1868, the bot's header. A push that command makes is judged
# by nothing here: not its remote, its submodule recursion, a red main or the
# gate. So each argv form below, which makes git run a command the caller
# chose, is refused, never run. Measured
# on git 2.54; one walk, run on the alias-expanded argv fg_refuse_non_https
# reads:
#   * submodule foreach (and submodule--helper foreach, which git-submodule
#     calls), bisect run, hook run;
#   * rebase --exec / -x (an abbreviation such as --ex=, or x in a short
#     cluster such as -ix);
#   * grep -O / --open-files-in-pager (its pager is any command);
#   * difftool, mergetool, filter-branch, send-email, instaweb, daemon,
#     for-each-repo and remote-ext, outright: each runs a tool, filter, hook,
#     helper, shell command or git argv of the caller's by design;
#   * push and send-pack --receive-pack / --exec; fetch, pull, ls-remote,
#     clone and fetch-pack --upload-pack (clone -u; ls-remote and fetch-pack
#     --exec); archive --exec: for a local or ext:: remote git runs that
#     value as a local command;
#   * clone and init --template=<dir>: its hooks run (post-checkout during
#     the clone);
#   * an ext:: address in the argv of a subcommand that names a repository
#     (its address is a shell command), and an ext:: URL any remote resolves
#     to (the URL check in fg_refuse_non_https);
#   * --exec-path=<dir>, or a GIT_EXEC_PATH that is not git's own: git runs
#     every helper (git-remote-https included) from there;
#   * a shell alias (`!...`): fg_refuse_shell_alias, above.
# These subcommands are taken as written, never alias-expanded: git ignores
# an alias named for one of its own commands (`alias.bisect=status`), and so
# does the alias walk (fg_cmd_known, DND-1867).
# Conservative, so a parse slip can only over-refuse: a word that may be an
# option's value still counts (`submodule add <url> foreach` is refused).
# Not refused, and since DND-1868 never holding the bot's credential ("The
# credential grant" below): a command named in config, from the repository's
# own config as much as from -c, --config-env or the environment config
# channel (core.sshCommand, core.editor, core.hooksPath, core.fsmonitor, a
# diff, merge, filter or textconv driver, gpg.program, hook.<name>.command,
# remote.<name>.uploadpack / receivepack, submodule.<name>.update=!cmd, ...);
# the same commands from the environment (GIT_SSH_COMMAND, GIT_EDITOR,
# GIT_TEMPLATE_DIR, ...); a git hook already in the repository (pre-push runs
# inside a routed push, and the outbound scan with it); a merge strategy (-s
# <name> runs git-merge-<name>); a transport helper `<name>::` other than
# ext and athena-forge. Each runs, as under plain git, with no bot header in
# its environment and the grant already drained, so a forge push it makes
# fails at the route's transport. A pager never starts (--no-pager; -p is
# refused). Residual: a script outside git's core that takes a program on its
# argv (credential-netrc --gpg, svn --authors-prog, ...), the header's "any
# subcommand not named above", runs that program, also without the header.
FG_RUNS_COMMAND_SUBS="submodule submodule--helper bisect hook rebase grep difftool mergetool filter-branch send-email instaweb daemon for-each-repo remote-ext push send-pack fetch pull ls-remote clone fetch-pack archive init"
# The subcommands whose argv can name a repository, so an ext:: word there
# is an address git may run.
FG_REPO_ARG_SUBS="push send-pack fetch pull ls-remote clone fetch-pack archive remote submodule submodule--helper"
FG_RC_WHAT=""
FG_RC_FIX=""

# fg_short_has <word> <letter> <value letters> : 0 when <word> is a short
# option cluster (-abc) holding <letter> before any letter that takes the
# rest of the cluster as its value.
fg_short_has() {
  local w="$1" c
  case "$w" in --*|-) return 1 ;; -*) w="${w#-}" ;; *) return 1 ;; esac
  while [ -n "$w" ]; do
    c="${w:0:1}"; w="${w:1}"
    [ "$c" = "$2" ] && return 0
    [[ "$3" == *"$c"* ]] && return 1
  done
  return 1
}

# fg_long_is <word> <long name> : 0 when <word> is --<p> or --<p>=<v> and <p>
# is a non-empty prefix of <long name> (git accepts a unique abbreviation; an
# ambiguous one is refused by git, so counting it can only over-refuse).
fg_long_is() {
  local n
  case "$1" in --no-*|--) return 1 ;; --*) n="${1#--}"; n="${n%%=*}" ;; *) return 1 ;; esac
  [ -n "$n" ] && [[ "$2" == "$n"* ]]
}

# fg_runs_command <subcommand> <args...> : 0 when this argv makes git run a
# command the caller chose. Sets FG_RC_WHAT (what runs it) and FG_RC_FIX.
fg_runs_command() {
  local sub="$1" a o plain
  shift
  plain="it needs no forge identity: run it with plain git, outside the Athena route, and push the result afterwards with \`~/dev/custom/ai/bin/$FG_TOOL git push …\`"
  FG_RC_WHAT=""; FG_RC_FIX="$plain"
  if [[ " $FG_REPO_ARG_SUBS " == *" $sub "* ]]; then
    for a in "$@"; do
      case "${a,,}" in
        ext::*|--*=ext::*)
          FG_RC_WHAT="an ext:: address ('$a') is a shell command git runs"
          FG_RC_FIX="name the repository by its https://$FG_HOST/<owner>/<repo>.git URL or a local path"
          return 0 ;;
      esac
    done
  fi
  case "$sub" in
    submodule|submodule--helper)
      for a in "$@"; do
        [ "$a" = foreach ] || continue
        FG_RC_WHAT="submodule foreach runs its command in every submodule"
        FG_RC_FIX="run the command in each submodule yourself, through the route: list them with \`~/dev/custom/ai/bin/$FG_TOOL git submodule status\`, then run \`~/dev/custom/ai/bin/$FG_TOOL git -C <submodule> <git command>\` once per submodule, a push included. A command that reaches no forge needs no Athena route: run it with plain git"
        return 0
      done ;;
    bisect)
      for a in "$@"; do
        [ "$a" = run ] && { FG_RC_WHAT="bisect run runs its command at every step"; return 0; }
      done ;;
    hook)
      for a in "$@"; do
        [ "$a" = run ] && { FG_RC_WHAT="hook run runs a hook script"; return 0; }
      done ;;
    rebase)
      for a in "$@"; do
        # -s, -X and -C take the rest of a cluster as their value; -S a key id.
        if fg_long_is "$a" exec || fg_short_has "$a" x sXCS; then
          FG_RC_WHAT="rebase --exec / -x runs its command after each commit"; return 0
        fi
      done ;;
    grep)
      for a in "$@"; do
        # -A, -B, -C, -m, -e and -f take the rest of a cluster as their value.
        if fg_long_is "$a" open-files-in-pager || fg_short_has "$a" O ABCmef; then
          FG_RC_WHAT="grep -O / --open-files-in-pager runs its pager, which may be any command"; return 0
        fi
      done ;;
    difftool|mergetool)
      FG_RC_WHAT="$sub always launches a tool command (--extcmd, --tool or its config)"; return 0 ;;
    filter-branch)
      FG_RC_WHAT="filter-branch runs its filters as shell commands"; return 0 ;;
    send-email)
      FG_RC_WHAT="send-email runs commands (--to-cmd, --cc-cmd, --header-cmd, --sendmail-cmd, a --smtp-server path)"; return 0 ;;
    instaweb)
      FG_RC_WHAT="instaweb runs a web server and browser command (--httpd, --browser)"; return 0 ;;
    daemon)
      FG_RC_WHAT="daemon runs an access hook (--access-hook) and serves the repository"; return 0 ;;
    for-each-repo)
      FG_RC_WHAT="for-each-repo runs its git argv in every repository a config key names, from git's exec-path, where no refusal here applies"
      FG_RC_FIX="run the git command in each repository yourself, through the route: \`~/dev/custom/ai/bin/$FG_TOOL git -C <repository> <git command>\`"
      return 0 ;;
    remote-ext)
      FG_RC_WHAT="remote-ext, the ext:: transport helper, runs its argument as a shell command"
      FG_RC_FIX="name the repository by its https://$FG_HOST/<owner>/<repo>.git URL or a local path"
      return 0 ;;
    push)
      # By git's push grammar, so an abbreviation (--rece) is read in full.
      fg_push_argv "$@"
      for o in "${FG_PA_OPTS[@]}"; do
        case "$o" in
          --receive-pack=*|--exec=*)
            FG_RC_WHAT="push ${o%%=*} names the receive-pack command, which git runs locally for a local or ext:: remote"
            FG_RC_FIX="drop ${o%%=*}: a push over HTTPS to $FG_HOST never uses it"
            return 0 ;;
        esac
      done ;;
    send-pack)
      for a in "$@"; do
        if fg_long_is "$a" receive-pack || fg_long_is "$a" exec; then
          FG_RC_WHAT="send-pack ${a%%=*} names the receive-pack command, which git runs locally for a local or ext:: remote"
          FG_RC_FIX="drop ${a%%=*}: a push over HTTPS to $FG_HOST never uses it"
          return 0
        fi
      done ;;
    fetch|pull|ls-remote|clone|fetch-pack)
      for a in "$@"; do
        # clone's -o, -b, -c and -j take the rest of a cluster as their value.
        # ls-remote and fetch-pack read a hidden --exec as --upload-pack.
        if fg_long_is "$a" upload-pack || { [ "$sub" = clone ] && fg_short_has "$a" u objc; } \
           || { [[ " ls-remote fetch-pack " == *" $sub "* ]] && fg_long_is "$a" exec; }; then
          FG_RC_WHAT="$sub ${a%%=*} names the upload-pack command, which git runs locally for a local or ext:: remote"
          FG_RC_FIX="drop ${a%%=*}: a $sub over HTTPS from $FG_HOST never uses it"
          return 0
        fi
        if [ "$sub" = clone ] && fg_long_is "$a" template; then
          FG_RC_WHAT="clone --template copies that directory's hooks into the new repository, and post-checkout runs during the clone"
          FG_RC_FIX="drop --template and clone with git's own template"
          return 0
        fi
      done ;;
    init)
      for a in "$@"; do
        if fg_long_is "$a" template; then
          FG_RC_WHAT="init --template copies that directory's hooks into the repository, where git runs them"
          FG_RC_FIX="drop --template, or run the init with plain git, outside the Athena route"
          return 0
        fi
      done ;;
    archive)
      for a in "$@"; do
        if fg_long_is "$a" exec; then
          FG_RC_WHAT="archive --exec names the upload-archive command, which git runs locally for a local remote"
          FG_RC_FIX="drop --exec, or run the archive with plain git, outside the Athena route"
          return 0
        fi
      done ;;
  esac
  return 1
}

# fg_refuse_runs_command <what git was asked> : refuse FG_RC_WHAT with FG_RC_FIX.
fg_refuse_runs_command() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: it runs a command that git starts itself ($FG_RC_WHAT). Any git that command runs comes from git's exec-path, where $FG_TOOL never sees it: a push it makes is not checked for its remote, its submodules, a red main or the gate.
  Fix: $FG_RC_FIX. $FG_ESCALATE
EOF
  exit 3
}

# fg_exec_path_moved <global options...> : 0 when git would run its helpers
# from a directory other than its own: a --exec-path=<dir> global option, or
# a non-empty GIT_EXEC_PATH that differs from git's own exec-path (git exports
# its own to every command it runs, so that value passes). Sets FG_RC_WHAT.
fg_exec_path_moved() {
  local g own
  for g in "$@"; do
    case "$g" in
      --exec-path=*)
        FG_RC_WHAT="--exec-path=${g#--exec-path=} makes git run its helpers, git-remote-https included, from that directory"
        FG_RC_FIX="drop --exec-path=<dir> and run the command again"
        return 0 ;;
    esac
  done
  [ -n "${GIT_EXEC_PATH:-}" ] || return 1
  own="$(env -u GIT_EXEC_PATH git --exec-path 2>/dev/null || true)"
  [ "$GIT_EXEC_PATH" = "$own" ] && return 1
  FG_RC_WHAT="GIT_EXEC_PATH=$GIT_EXEC_PATH makes git run its helpers, git-remote-https included, from that directory, not from git's own ($own)"
  FG_RC_FIX="unset GIT_EXEC_PATH and run the command again"
  return 0
}

# ---- Remote-ref writers other than push (DND-1867) ---------------------------
# Only `git push` is judged for its remote, its submodule recursion, a red main
# and the gate (fg_refuse_red_main, fg_refuse_ungated_main). Every other
# command that writes a remote ref under this route's bot header went
# unjudged: `send-pack <origin> HEAD:refs/heads/main` landed an ungated commit
# on a gated repo's main, measured on git 2.54 against a local bare origin. So
# each is refused, with a Fix: that names the routed `git push`:
#   * send-pack (push's own plumbing) and http-push (the WebDAV push);
#   * a transport helper called directly, remote-<name> (remote-https,
#     remote-http, remote-ftp, remote-ftps, remote-fd, any other): it pushes
#     whatever its stdin asks. remote-ext is refused by "Commands git runs
#     itself" first;
#   * subtree push, in either word order (`subtree -P x push`): its inner
#     `git push` of a split git-subtree computes runs from git's exec-path.
# And, read where the subcommand is taken (fg_cmd_known), so an alias cannot
# carry one past it:
#   * a git-<name> program on PATH that is not one of git's own commands
#     (`git --list-cmds=others`, minus `main`): it runs any code with this
#     route's bot header in its environment, so a push it makes is judged by
#     nothing (on this machine, git-rekt in git-custom/ pushes with -f);
#   * a subcommand git does not know, no command and no alias: under
#     help.autocorrect, from -c or any config file, git runs the closest
#     command instead (`pusj` runs push), and nothing here judged that one;
#   * an alias chain more than 10 deep, read no further.
# A name git runs is never alias-expanded: git runs its own commands and a
# git-<name> on PATH before an alias of that name (`alias.http-push=status`
# still runs http-push). Measured, for each, on git 2.54.
# Conservative, so a parse slip can only over-refuse: any word `push` after
# `subtree` counts, so `subtree split -P push` and a branch named push in
# `subtree pull` are refused too (accepted false refusals).
# Shown unable to write a remote ref, so not refused here: fetch-pack,
# ls-remote, archive --remote and upload-pack (read side); receive-pack and
# update-ref, which write only a repository on this machine. Each other
# subcommand of git's is a local or read-side command, by its manual.
# The agent PATH git wrapper's forge-identity check, ai/lib/agent-forge-push.sh,
# reads the same lists, fg_cmd_known, fg_writes_remote_ref and
# fg_runs_command, in its own words: there a writer is refused when it reaches
# the forge, whatever its credential (DND-1881).
# Residual: the command lists are read once, with the global options before
# the first subcommand; an alias that adds `-C <dir>` with a relative PATH
# entry could reach a git-<name> in <dir> that the lists did not see.
FG_OWN_CMDS=""
FG_PATH_CMDS=""

# fg_cmd_list <kind> : print git's --list-cmds=<kind>, one name per line;
# exit 3 with COULD NOT LOOK when git cannot list them. A caller wraps the
# list in newlines itself: a command substitution strips the trailing one,
# and the last name would then never match.
# A failed listing never reads as "no commands" (every name unknown) or as an
# empty PATH list (every git-<name> allowed).
fg_cmd_list() {
  local out rc=0
  out="$(G --list-cmds="$1" 2>/dev/null)" || rc=$?
  if [ "$rc" != 0 ] || { [ "$1" = main ] && [[ $'\n'"$out"$'\n' != *$'\n'push$'\n'* ]]; }; then
    cat >&2 <<EOF
$FG_TOOL: REFUSING this git command: COULD NOT LOOK which commands git has (\`git --list-cmds=$1\` exited $rc and, for main, must list push), so whether the subcommand is git's own, a program on PATH, or a typo git may autocorrect into another command is unknown.
  Fix: check that \`git --list-cmds=$1\` lists git's commands in this shell (the git on PATH, its exec-path), then retry. $FG_ESCALATE
EOF
    exit 3
  fi
  printf '%s' "$out"
}

# fg_cmd_known <name> : 0 when <name> is one of git's own commands (builtin or
# in its exec-path), which git runs before any alias. Refuses a git-<name> on
# PATH that is not git's own (fg_refuse_path_cmd). 1 otherwise: an alias, or
# a name git does not know.
fg_cmd_known() {
  if [ -z "$FG_OWN_CMDS" ]; then
    FG_OWN_CMDS=$'\n'"$(fg_cmd_list main)"$'\n' || exit 3
    FG_PATH_CMDS=$'\n'"$(fg_cmd_list others)"$'\n' || exit 3
  fi
  [[ "$FG_OWN_CMDS" == *$'\n'"$1"$'\n'* ]] && return 0
  [[ "$FG_PATH_CMDS" == *$'\n'"$1"$'\n'* ]] && fg_refuse_path_cmd "$1"
  return 1
}

# fg_refuse_path_cmd <name> : refuse a git-<name> program that is not git's.
fg_refuse_path_cmd() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: git-$1 is a program on PATH, not one of git's own commands. It would run with this route's bot header in its environment, and a push it makes is not checked for its remote, its submodules, a red main or the gate.
  Fix: run it by its own name, \`git-$1 …\`, outside the Athena route (in an agent session the git it runs is then the agent PATH wrapper, which refuses \`git $1\` too, DND-1881), and push what it makes with \`~/dev/custom/ai/bin/$FG_TOOL git push <repository> <src>:<dst>\`. $FG_ESCALATE
EOF
  exit 3
}

# fg_refuse_unknown_cmd <name> [<why the alias is unknown>] : refuse a
# subcommand git does not know.
fg_refuse_unknown_cmd() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: '$1' is no command git knows and ${2:-no alias}. Under help.autocorrect git runs the closest command in its place (\`pusj\` runs push), and $FG_TOOL never judged that command: a push it makes is not checked for its remote, its submodules, a red main or the gate.
  Fix: spell the subcommand as git names it (\`git help -a\` lists them). $FG_ESCALATE
EOF
  exit 3
}

# fg_writes_remote_ref <subcommand> <args...> : 0 when this argv writes a
# remote ref other than through `git push`. Sets FG_RW_WHAT and FG_RW_FIX.
fg_writes_remote_ref() {
  local sub="$1" a
  shift
  FG_RW_WHAT=""
  FG_RW_FIX="push with \`~/dev/custom/ai/bin/$FG_TOOL git push <repository> <src>:<dst>\` instead, which this route judges"
  case "$sub" in
    send-pack) FG_RW_WHAT="send-pack is push's plumbing" ;;
    http-push) FG_RW_WHAT="http-push pushes over WebDAV" ;;
    remote-*) FG_RW_WHAT="$sub is a transport helper, and it pushes whatever its stdin asks" ;;
    subtree)
      for a in "$@"; do
        [ "$a" = push ] || continue
        FG_RW_WHAT="subtree push runs its own git push of a split, from git's exec-path"
        FG_RW_FIX="split with plain git, which reaches no forge (\`git subtree split -P <prefix> -b <branch>\`), then push that branch through the route: \`~/dev/custom/ai/bin/$FG_TOOL git push <repository> <branch>:<remote-branch>\`"
        return 0
      done
      return 1 ;;
    *) return 1 ;;
  esac
  return 0
}

# fg_refuse_remote_ref <what git was asked> : refuse FG_RW_WHAT with FG_RW_FIX.
fg_refuse_remote_ref() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING \`git $1\`: it writes a remote ref without \`git push\` ($FG_RW_WHAT). $FG_TOOL judges only \`git push\` for its remote, its submodules, a red main and the gate, so this would write a remote ref, main included, with none of those checks.
  Fix: $FG_RW_FIX. $FG_ESCALATE
EOF
  exit 3
}

# fg_push_argv <push args...> : read the args after `push` as git does. Sets
#   FG_PA_OPTS   every option, spelled in full: --<long> or --<long>=<value>
#                (a short option becomes its long name; -h stays -h);
#   FG_PA_POS    the non-option words in order: the repository, then refspecs;
#   FG_PA_BAD    the first word git push would reject as an option (unknown,
#                ambiguous, a value it does not take, a value missing), or "".
# git's rules: a value-taking option takes the next word whatever it looks
# like (`-o --`, `-o -h`); options and words may mix, until a `--` or
# `--end-of-options` in option position, after which every word is a word.
FG_PA_OPTS=()
FG_PA_POS=()
FG_PA_BAD=""
fg_push_argv() {
  local a n v has_v rest c pair long end=0
  FG_PA_OPTS=(); FG_PA_POS=(); FG_PA_BAD=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    if [ "$end" = 1 ]; then FG_PA_POS+=("$a"); continue; fi
    case "$a" in
      -- | --end-of-options) end=1 ;;
      --?*)
        n="${a#--}"; v=""; has_v=0
        case "$n" in *=*) v="${n#*=}"; n="${n%%=*}"; has_v=1 ;; esac
        case "$n" in help | help-all) FG_PA_OPTS+=("--$n"); continue ;; esac
        if ! fg_push_long "$n"; then FG_PA_BAD="${FG_PA_BAD:-$a}"; FG_PA_OPTS+=("$a"); continue; fi
        n="$FG_PL_NAME"
        if [[ " $FG_PUSH_VALUE_OPTS " == *" $n "* ]]; then
          if [ "$has_v" = 0 ]; then
            if [ $# -eq 0 ]; then FG_PA_BAD="${FG_PA_BAD:-$a}"; FG_PA_OPTS+=("--$n"); continue; fi
            v="$1"; shift
          fi
          FG_PA_OPTS+=("--$n=$v")
        elif [ "$has_v" = 1 ] && [[ " $FG_PUSH_OPTARG_OPTS " == *" $n "* ]]; then
          FG_PA_OPTS+=("--$n=$v")
        elif [ "$has_v" = 1 ]; then
          FG_PA_BAD="${FG_PA_BAD:-$a}"; FG_PA_OPTS+=("$a")
        else
          FG_PA_OPTS+=("--$n")
        fi ;;
      -?*)
        rest="${a#-}"
        while [ -n "$rest" ]; do
          c="${rest:0:1}"; rest="${rest:1}"
          if [ "$c" = h ]; then FG_PA_OPTS+=("-h"); continue; fi
          long=""
          for pair in $FG_PUSH_SHORT; do [ "${pair%%:*}" = "$c" ] && long="${pair#*:}"; done
          if [ -z "$long" ]; then FG_PA_BAD="${FG_PA_BAD:-$a}"; FG_PA_OPTS+=("-$c"); continue; fi
          if [ "$long" = push-option ]; then
            # -o takes the rest of the cluster, else the next word.
            if [ -z "$rest" ]; then
              if [ $# -eq 0 ]; then FG_PA_BAD="${FG_PA_BAD:-$a}"; FG_PA_OPTS+=("--$long"); break; fi
              rest="$1"; shift
            fi
            FG_PA_OPTS+=("--$long=$rest"); rest=""
          else
            FG_PA_OPTS+=("--$long")
          fi
        done ;;
      *) FG_PA_POS+=("$a") ;;
    esac
  done
}

# fg_has_submodules <probe> : 0 when the repository has submodules: a
# submodule.<name>.url in config, a modules directory in the git dir, a
# .gitmodules at the top level, or a gitlink in the index. A probe that
# fails reads as "has submodules": could not look is not "none".
fg_has_submodules() {
  local probe="$1" mods inside top idx
  "$probe" config --get-regexp '^submodule\..*\.url$' >/dev/null 2>&1 && return 0
  mods="$("$probe" rev-parse --path-format=absolute --git-path modules 2>/dev/null)" || return 0
  [ -n "$mods" ] || return 0
  [ -d "$mods" ] && return 0
  inside="$("$probe" rev-parse --is-inside-work-tree 2>/dev/null)" || return 0
  # A repository with no work tree has no populated submodule to push.
  [ "$inside" = true ] || return 1
  top="$("$probe" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0
  [ -f "$top/.gitmodules" ] && return 0
  idx="$("$probe" ls-files --stage 2>/dev/null)" || return 0
  [[ $'\n'"$idx" == *$'\n160000 '* ]]
}

# fg_refuse_non_https <git args...> : resolve every URL the network op would
# reach and refuse on the first one that goes to FG_HOST over non-HTTPS.
# Sets FG_RESOLVED_URLS (newline-separated) for the dry-run report, and, for a
# `push`, FG_PUSH_URL (the first URL it pushes to) and FG_PUSH_GLOB (its git
# global options) for the landing telemetry below, and FG_PUSH_ARGS (the
# alias-expanded args after `push`, as fg_push_argv reads them: every option
# in full with its value attached, then `--`, then the repository and
# refspecs) for the red-main and ungated-main refusals and the telemetry.
# It also sets, for the credential grant (DND-1868): FG_URLS_RESOLVED=1 when
# it resolved the command's URL set (a network subcommand it reads), else 0;
# FG_CRED_URLS, the same URLs with a remote's `remote.<n>.vcs` helper as a
# `<vcs>::` prefix; and FG_PAGINATE=1 when a global -p / --paginate is given.
FG_RESOLVED_URLS=""
FG_CRED_URLS=""
FG_URLS_RESOLVED=0
FG_URLS_SUB=""
FG_CMD_GLOB=()
FG_CMD_ARGS=()
FG_PAGINATE=0
FG_PUSH_URL=""
FG_PUSH_GLOB=()
FG_PUSH_ARGS=()
fg_refuse_non_https() {
  local -a glob=() ex=()
  local sub="" mode depth=0 alias_val
  FG_URLS_RESOLVED=0; FG_URLS_SUB=""; FG_CRED_URLS=""; FG_PAGINATE=0; FG_CMD_GLOB=(); FG_CMD_ARGS=()
  fg_rewrite_args

  G() { git "${FG_REWRITE_ARGS[@]}" "${glob[@]}" "$@"; }

  # Peel global options (replayed on every probe), take the subcommand, and
  # expand git aliases (`alias.p=push`) the way git would, so an alias cannot
  # carry a network op past the check. An alias may itself start with global
  # options (`alias.p=-c url...pushInsteadOf=... push`; git accepts -c there),
  # so the peel runs again on every expansion. A shell alias (`!...`) can run
  # anything, so it is refused outright rather than guessed at.
  local grc arc
  while :; do
    while [ $# -gt 0 ]; do
      case "$1" in -*) ;; *) break ;; esac
      grc=0; fg_global_opt "$1" || grc=$?
      case "$grc" in
        0) [ $# -ge 2 ] || return 0; glob+=("$1" "$2"); shift 2 ;;
        1) case "$1" in -p|--paginate) FG_PAGINATE=1 ;; esac
           glob+=("$1"); shift ;;
        3) return 0 ;;   # git prints and exits; no subcommand runs
        # An option git does not have: git refuses it too, but if it took a
        # value, this walk would read that value as the subcommand (DND-1843).
        *) fg_refuse_option "$1" "it is no option git takes before the subcommand (FG_GLOBAL_VALUE_OPTS and FG_GLOBAL_SWITCHES in ai/lib/forge-git-passthrough.sh list them)" ;;
      esac
    done
    [ $# -gt 0 ] || return 0
    sub="$1"; shift
    # git runs its own commands, and a git-<name> on PATH, before an alias of
    # that name (DND-1844, DND-1867): `alias.http-push=status` runs http-push.
    fg_cmd_known "$sub" && break
    # An alias chain this deep is not read to its end, so the command it
    # reaches is unknown (DND-1867: past the old cap, it ran unjudged).
    [ "$depth" -lt 10 ] || fg_refuse_alias_depth "$sub"
    arc=0; alias_val="$(G config --get "alias.$sub" 2>/dev/null)" || arc=$?
    # No command and no alias: help.autocorrect may run another (DND-1867).
    # A config that cannot be read is not "no alias".
    case "$arc" in
      0) ;;
      1) fg_refuse_unknown_cmd "$sub" ;;
      *) fg_refuse_unknown_cmd "$sub" "git config could not read alias.$sub (exit $arc)" ;;
    esac
    [ -n "$alias_val" ] || fg_refuse_unknown_cmd "$sub"
    case "$alias_val" in
      '!'*) fg_refuse_shell_alias "$sub" "$alias_val" ;;
      # git strips quotes and backslashes when it splits an alias; a plain
      # word split here would not, so a quoted flag would pass unread
      # (DND-1841: `push "--recurse-submodules=on-demand"`). Refuse instead.
      *[\"\'\\]*) fg_refuse_quoted_alias "$sub" "$alias_val" ;;
    esac
    read -ra ex <<<"$alias_val"
    set -- "${ex[@]}" "$@"
    depth=$((depth + 1))
  done

  # A git that a command git starts itself runs is past every check below
  # (DND-1844): refuse it, on the alias-expanded argv.
  fg_exec_path_moved "${glob[@]}" && fg_refuse_runs_command "${glob[*]:+${glob[*]} }$sub"
  fg_runs_command "$sub" "$@" && fg_refuse_runs_command "$sub $*"
  # Only `push` is judged below: every other remote-ref writer is refused.
  fg_writes_remote_ref "$sub" "$@" && fg_refuse_remote_ref "$sub $*"

  local recurse=0 a0
  for a0 in "$@"; do
    case "$a0" in --recurse-submodules|--recurse-submodules=yes|--recurse-submodules=on-demand|--recurse-submodules=only) recurse=1 ;; esac
  done
  case "$sub" in
    push)
      mode=push
      # A recursive push pushes each submodule through ITS OWN remote config,
      # from git's exec-path, which this check does not inspect: refuse rather
      # than half-check. Every source git reads (fg_push_recurses).
      fg_push_recurses G "$@" \
        && fg_refuse_unchecked push "it pushes submodules too ($FG_RECURSE_SRC), and each submodule push goes through its own remote, which $FG_TOOL does not inspect"
      # Which word is the repository, and which are refspecs, by git's push
      # grammar (DND-1843). An option git push would reject is refused here.
      fg_push_argv "$@"
      [ -z "$FG_PA_BAD" ] \
        || fg_refuse_option "$FG_PA_BAD" "it is no option of git push, an abbreviation that matches more than one, or an option missing its value or given one it does not take" ;;
    fetch|pull|ls-remote|clone) mode=fetch ;;
    remote) [ "${1:-}" = update ] || return 0; mode=fetch ;;
    submodule) mode=fetch; recurse=1 ;;
    subtree)
      # subtree push was refused above (fg_writes_remote_ref, DND-1867).
      case "${1:-}" in
        pull|add) mode=fetch ;;
        *) return 0 ;;
      esac
      shift ;;
    *) return 0 ;;
  esac
  # The subcommand's own args, alias-expanded, for the red-main refusal
  # (DND-1482): it must parse what git will run, not the raw argv. For a push
  # that is fg_push_argv's reading: every option in full with its value
  # attached, then `--` and the words (DND-1843), so a value spelled like
  # --dry-run is never read as a dry run.
  local -a sub_args=( "$@" )
  [ "$sub" = push ] && sub_args=( "${FG_PA_OPTS[@]}" -- "${FG_PA_POS[@]}" )

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
  if [ "$sub" = push ]; then
    # fg_push_argv read the args by git's push grammar: the first word is the
    # repository, and --repo names it when there is none. An option value
    # that names a remote or mentions the forge host is checked too.
    local o ov
    # git uses the last --repo=<r> / --no-repo; every --repo value is checked.
    for o in "${FG_PA_OPTS[@]}"; do
      case "$o" in
        --repo=*) has_repo=1; targets+=("${o#--repo=}") ;;
        --no-repo) has_repo=0 ;;
        --*=*) ov="${o#*=}"; { is_remote "$ov" || [[ "$ov" == *"$FG_HOST"* ]]; } && targets+=("$ov") ;;
      esac
    done
    for a in "${FG_PA_POS[@]}"; do
      if [ -z "$positional" ]; then positional="$a"; targets+=("$a")
      elif is_remote "$a" || [[ "$a" == *"$FG_HOST"* ]]; then targets+=("$a"); fi
    done
    set --
  fi
  # The fetch-side walk. A push was read by fg_push_argv above, and its args
  # cleared, so this loop sees none of them.
  takes_value='^(-P|--prefix|-m|--message|-o|--upload-pack|-j|--jobs|--depth|--deepen|--shallow-since|--shallow-exclude|--refmap|--server-option|--negotiation-tip|-s|--strategy|-X|--strategy-option|--origin|-b|--branch|-u|--reference|--reference-if-able|--separate-git-dir|-c|--config|--template|--filter|--bundle-uri|--ref-format)$'
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

  local t u vcs ; local -a urls
  for t in "${targets[@]}"; do
    urls=(); vcs=""
    if is_remote "$t"; then
      if [ "$mode" = push ]; then mapfile -t urls < <(G remote get-url --push --all "$t" 2>/dev/null || true)
      else mapfile -t urls < <(G remote get-url --all "$t" 2>/dev/null || true); fi
      # remote.<n>.vcs: git reaches this remote through git-remote-<vcs>,
      # whatever its URL says (DND-1868: it gets no credential).
      vcs="$(G config --get "remote.$t.vcs" 2>/dev/null || true)"
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
      FG_CRED_URLS+="${vcs:+$vcs::}$u"$'\n'
      # A remote whose URL is ext:: runs that address as a shell command (DND-1844).
      case "${u,,}" in
        ext::*) FG_RC_WHAT="'$t' resolves to the ext:: address '$u', a shell command git runs"
                FG_RC_FIX="point the remote at https://$FG_HOST/<owner>/<repo>.git or a local path"
                fg_refuse_runs_command "$sub" ;;
      esac
      fg_reaches_forge_insecurely "$u" && fg_refuse "$sub" "$t" "$u"
    done
  done
  FG_URLS_RESOLVED=1
  FG_URLS_SUB="$sub"
  FG_CMD_GLOB=( "${glob[@]}" )
  FG_CMD_ARGS=( "${sub_args[@]}" )
  if [ "$sub" = push ]; then
    FG_PUSH_URL="${FG_RESOLVED_URLS%%$'\n'*}"
    FG_PUSH_GLOB=( "${glob[@]}" )
    FG_PUSH_ARGS=( "${sub_args[@]}" )
  fi
  return 0
}

# ---- Landing telemetry (DND-1475) -------------------------------------------
# With FG_LANDING_TELEMETRY=1 (gh-athena sets it; glab-athena does not), a
# `push` runs git as a CHILD instead of exec'ing it, so that after a push that
# exits 0 the wrapper can tell whether the remote's default branch moved, and
# record that as one `merge.landed` event (via=push, before, after). That is
# how ~/dev/custom lands (athena:merge-boarding, the no-CI ff push). The event
# is timed (DND-1501): at = when this push began, duration_s = its wall
# through the AFTER read. The lead-time ledger reads its start as the landing
# start of a --with-critic flow, where `queue` ends and `merge` begins.
#
# How "moved" is read: `git ls-remote --symref <url> HEAD refs/heads/main`
# BEFORE the push gives the default branch (HEAD's symref; refs/heads/main when
# the server does not say) and its sha; the same ref read AFTER a push that
# exited 0 gives the new sha. Different (or created), AND the new sha is a
# commit this push sent (fg_push_sent: a refspec's source resolves to it), is
# a landing; a main another actor moved meanwhile is not this push's. A refused
# push, a push to another branch, an up-to-date push and a --dry-run push move
# nothing and emit nothing. If the BEFORE read fails, before is unknown: the
# event is still written when the after read succeeds and the push's own argv
# names the default branch (fg_push_names_default; a --dry-run never), with no
# `before` (null, never a guess). Residual, said out loud: in that state a push
# that names main but was already up to date reads as a landing.
#
# Fails open: both reads are bounded (timeout 10), silent, read-only and authed
# as the bot exactly as the push is; the emit goes through
# ai/lib/telemetry-emit.sh. git's own stdout, stderr and exit code are what the
# caller sees. Differences from exec, said out loud: a git killed by a signal
# reads as exit 128+n from this wrapper rather than as a signal death; a signal
# sent to the wrapper's pid alone (not its process group, as a terminal or
# `timeout` sends) no longer reaches git; and a push that lands main but exits
# non-zero because another refspec was rejected records no landing. Cost: two
# ls-remote round trips per push (each capped at 10 s) plus the emit (capped
# at 2 s), paid also inside the custom ff landing's hand-held lock.
#
# Unit: the event carries head = after. Its unit resolves from the one local
# branch (other than the default branch) whose tip is the pushed commit (the
# Mission branch after the admiral's rebase), else from the checked-out branch.

# fg_probe <git argv...> : run a read-only probe bounded, quiet, never prompting.
fg_probe() { timeout 10 env -u GIT_ASKPASS -u SSH_ASKPASS GIT_TERMINAL_PROMPT=0 "$@" 2>/dev/null </dev/null; }

# fg_push_and_record <git args...> : push as a child, record a landing, exit
# with git's status. Never returns.
fg_push_and_record() {
  # The probes are the wrapper's own: read-only ls-remote, no hooks. They
  # reach the forge over plain https with the header in their environment
  # (an assignment prefix, never argv), never through the route's transport,
  # so they never spend the push's grant (DND-1868).
  local -a probe=( git --no-pager "${FG_PUSH_GLOB[@]}" -c credential.helper= -c core.askPass= )
  local purl="${FG_PUSH_URL#athena-forge::}" hk="http.https://$FG_HOST/.extraheader" n
  local ls="" line name sha ref="" sym="" head_sha="" main_sha="" before="" known=0 rc=0 after=""
  local t0_at="" t0_us=""
  n="${GIT_CONFIG_COUNT:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  # The push start (DND-1501): the lead-time phase ledger reads it as the
  # landing start, ending `queue` and starting `merge` in a --with-critic
  # flow. Taken before the BEFORE read, so the event's wall is the push's.
  if . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/telemetry-emit.sh" 2>/dev/null; then
    t0_at="$(athena_telemetry_now)"; t0_us="$(athena_telemetry_clock_us)"
  fi
  # hprobe <git args...> : a probe with the header appended to the
  # environment config channel, in a subshell (export is a builtin, so the
  # header is on no argv). https is the only protocol it may use, so a
  # config rewrite of the URL cannot hand the header to a helper (`<name>::`),
  # ext::, ssh's command or a local path. A local push URL needs no header
  # and gets none. It runs with the transport's network settings (DND-1899,
  # ai/lib/forge-http-pin.sh): TLS verification on, no proxy, no curl trace;
  # where the caller's config would weaken TLS anyway, or an insteadOf rule
  # would send the probe to another URL than the one pinned, the probe does
  # not run and says why; the push still runs, with no landing record.
  # The remote name pinned is the URL itself: `ls-remote <url>` makes an
  # anonymous remote named after it, so remote.<url>.proxy is what git reads.
  hprobe() (
    case "$purl" in "https://$FG_HOST/"*)
      local pin_lib gu
      pin_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-http-pin.sh"
      skip() {
        printf '%s: the push'"'"'s ls-remote probe of %s did not run, so this push records no landing: %s\n  Fix: %s\n' \
          "$FG_TOOL" "$purl" "$1" "$2" >&2
        exit 1
      }
      # shellcheck source=forge-http-pin.sh
      . "$pin_lib" 2>/dev/null || skip "its network-settings library ($pin_lib) did not load." \
        "check that ai/lib/forge-http-pin.sh exists in this checkout."
      fg_http_pin_args "$purl" "$purl"
      probe+=( "${FG_HTTP_ARGS[@]}" )
      gu="$(fg_probe "${probe[@]}" ls-remote --get-url "$purl")"
      [ "$gu" = "$purl" ] || skip "git config rewrites it to '${gu}' (a url.<base>.insteadOf rule), which the pinned TLS and proxy settings do not cover." \
        "drop the url.<base>.insteadOf rule that matches $purl from the command's -c options and from git config."
      fg_http_check "$purl" "$purl" "${probe[@]}" || skip "$FG_HTTP_WHY." \
        "drop that setting (http.sslVerify, http.proxy, http.<url>.*, remote.<name>.proxy, http.sslCAInfo, http.sslCAPath, http.sslBackend) from the command's -c options and from git config."
      export "GIT_CONFIG_KEY_$n=$hk" "GIT_CONFIG_VALUE_$n=$FG_HEADER" GIT_CONFIG_COUNT="$((n + 1))" \
        GIT_ALLOW_PROTOCOL=https ;;
    esac
    fg_probe "${probe[@]}" "$@"
  )
  if ls="$(hprobe ls-remote --symref "$purl" HEAD refs/heads/main)"; then
    known=1
    while IFS= read -r line; do
      case "$line" in
        "ref: "*) name="${line##*$'\t'}"; line="${line#ref: }"; [ "$name" = HEAD ] && sym="${line%%$'\t'*}" ;;
        *$'\t'*) sha="${line%%$'\t'*}"; name="${line#*$'\t'}"
                 [ "$name" = HEAD ] && head_sha="$sha"
                 [ "$name" = refs/heads/main ] && main_sha="$sha" ;;
      esac
    done <<<"$ls"
  fi
  ref="${sym:-refs/heads/main}"
  if [ "$ref" = refs/heads/main ]; then before="$main_sha"; else before="$head_sha"; fi
  [ "$FG_CRED" = grant ] && fg_open_grant
  env -u GIT_ASKPASS -u SSH_ASKPASS GIT_TERMINAL_PROMPT=0 git "$@" || rc=$?
  fg_close_grant
  if [ "$rc" -eq 0 ] && ls="$(hprobe ls-remote "$purl" "$ref")"; then
    while IFS= read -r line; do
      [ "${line#*$'\t'}" = "$ref" ] && after="${line%%$'\t'*}"
    done <<<"$ls"
    # FG_PUSH_ARGS: the push args as fg_push_argv read them (DND-1843).
    if [[ "$after" =~ ^[0-9a-f]{40}$ ]] && fg_push_sent "$after" "${ref#refs/heads/}" push "${FG_PUSH_ARGS[@]}" \
       && { { [ "$known" -eq 0 ] && fg_push_names_default "${ref#refs/heads/}" "${FG_PUSH_ARGS[@]}"; } || { [ "$known" -eq 1 ] && [ "$after" != "$before" ]; }; }; then
      fg_record_landing "$before" "$after" "${ref#refs/heads/}" "$t0_at" "$t0_us"
    fi
  fi
  exit "$rc"
}

# fg_push_sent <after> <default branch> <git args...> : 0 when THIS push sent
# <after>, i.e. the source of one of its refspecs (HEAD when it names none;
# the local default branch for --all / --mirror) resolves to that commit.
# Without it, another actor moving main between the two reads (a squash
# merge, another fleet's push) would read as this push's landing.
fg_push_sent() {
  local after="$1" def="$2" a src seen_push=0 seen_repo=0 refspecs=0
  local -a cands=()
  shift 2
  while [ $# -gt 0 ]; do
    a="$1"; shift
    if [ "$seen_push" -eq 0 ]; then
      if [ "$a" = push ]; then seen_push=1
      elif fg_global_opt "$a"; then [ $# -gt 0 ] && shift; fi
      continue
    fi
    case "$a" in
      --all|--mirror) cands+=( "refs/heads/$def" ) ;;
      -o|--push-option|--receive-pack|--exec|--repo) [ $# -gt 0 ] && shift ;;
      -*) ;;
      *) if [ "$seen_repo" -eq 0 ]; then seen_repo=1; else
           src="${a#+}"; src="${src%%:*}"; refspecs=1
           [ -n "$src" ] && cands+=( "$src" )
         fi ;;
    esac
  done
  [ "$refspecs" -eq 1 ] || cands+=( HEAD )
  for src in "${cands[@]}"; do
    [ "$(git "${FG_PUSH_GLOB[@]}" rev-parse --verify -q --end-of-options "${src}^{commit}" 2>/dev/null || true)" = "$after" ] && return 0
  done
  return 1
}

# fg_push_names_default <default branch> <git args...> : with no BEFORE read,
# the only evidence the push targeted the default branch is its own argv: a
# refspec whose destination is it (`main`, `x:main`, `x:refs/heads/main`), or
# --all / --mirror; and never a --dry-run / -n push. Anything else is not
# recorded, so an unreadable BEFORE cannot turn a branch push into a landing.
fg_push_names_default() {
  local def="$1" a hit=1
  shift
  for a in "$@"; do
    case "$a" in
      --dry-run|-n) return 1 ;;
      --all|--mirror|"$def"|*:"$def"|refs/heads/"$def"|*:refs/heads/"$def") hit=0 ;;
    esac
  done
  return "$hit"
}

# fg_record_landing <before or ""> <after> <default branch name>
#                   [<start at> <start clock_us>] : one merge.landed event,
# from the pushed repo's top level. With both start values it is timed (at =
# the push start, duration_s = the push's wall, DND-1501); without either, or
# with a clock that cannot be read, it is a point event at now, as before.
# Never fails.
fg_record_landing() {
  local before="$1" after="$2" def="$3" t0_at="${4:-}" t0_us="${5:-}" top="" b n=0 ub="" wall=""
  local -a opt=( --head "$after" )
  if ! . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/telemetry-emit.sh" 2>/dev/null; then
    return 0
  fi
  [ -n "$t0_at" ] && wall="$(athena_telemetry_seconds_since "$t0_us")"
  [ -n "$wall" ] && opt+=( --at "$t0_at" --duration "$wall" )
  [[ "$before" =~ ^[0-9a-f]{40}$ ]] && opt+=( --attr "before=$before" )
  while IFS= read -r b; do
    [ -n "$b" ] && [ "$b" != "$def" ] && { ub="$b"; n=$((n + 1)); }
  done < <(git "${FG_PUSH_GLOB[@]}" for-each-ref --points-at "$after" --format='%(refname:short)' refs/heads 2>/dev/null || true)
  [ "$n" -eq 1 ] && opt+=( --unit-branch "$ub" )
  top="$(git "${FG_PUSH_GLOB[@]}" rev-parse --show-toplevel 2>/dev/null || true)"
  (
    # The telemetry writer needs no credential: no grant reaches it, and the
    # header was never in this environment (DND-1868).
    unset ATHENA_FG_CRED_FD ATHENA_FG_HOST
    [ -n "$top" ] && cd "$top" 2>/dev/null
    athena_telemetry_emit --event merge.landed --attr via=push --attr "after=$after" "${opt[@]}"
  ) || true
  return 0
}

# ---- Red-main refusal (DND-1482) ---------------------------------------------
# A push whose destination is main is REFUSED (exit 3) while ai/bin/main-health
# has recorded origin/main RED in the pushed repo's git common dir, unless the
# pushed commit is a gated fix: it contains the red SHA and integration-gate
# passed exactly it. That is "stop the line" for ~/dev/custom, which has no CI
# and lands by this push (athena:merge-boarding, the no-CI landing). The
# decision and the push-argv parse live in ai/lib/main-health.sh. No marker
# means no red is known, and the push proceeds; a repo main-health never checked
# (gen_saas, walt_ui) has none. A marker that cannot be read refuses (COULD NOT
# LOOK). It runs before the dry-run print, so FG_DRY_RUN=1 exercises it.
#
# Scope: the marker describes origin/main, so only a push whose URL is
# origin's push URL is judged; a push to another remote is not. The refspecs
# judged are FG_PUSH_ARGS, the alias-expanded args, so `alias.p=push` cannot
# carry a push past it. The parse's residuals are in mh_push_main_sources.
fg_refuse_red_main() {
  local common src sha rc origin_url cur
  [ -n "$FG_PUSH_URL" ] || return 0
  common="$(git "${FG_PUSH_GLOB[@]}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [ -n "$common" ] || return 0
  # No marker store at all: no red can be known; skip the rest of the reads.
  [ -e "$common/main-health" ] || return 0
  fg_rewrite_args
  origin_url="$(git "${FG_REWRITE_ARGS[@]}" "${FG_PUSH_GLOB[@]}" remote get-url --push origin 2>/dev/null || true)"
  [ -n "$origin_url" ] && [ "$origin_url" = "$FG_PUSH_URL" ] || return 0
  cur="$(git "${FG_PUSH_GLOB[@]}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  # shellcheck source=main-health.sh
  if ! . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/main-health.sh" 2>/dev/null; then
    printf '%s: REFUSING `git push`: cannot load ai/lib/main-health.sh, so whether main is red is unknown.\n  Fix: run %s from a full ~/dev/custom checkout (ai/bin and ai/lib side by side).\n' "$FG_TOOL" "$FG_TOOL" >&2
    exit 3
  fi
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    sha="$(git "${FG_PUSH_GLOB[@]}" rev-parse --verify -q --end-of-options "${src}^{commit}" 2>/dev/null || true)"
    # An unresolvable source fails in git itself; nothing lands. A source may
    # start with `-` (a refspec after `--`), hence --end-of-options (DND-1843).
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
    rc=0; mh_may_land "$common" "$sha" || rc=$?
    case "$rc" in
      0) [ -n "$MH_NOTE" ] && printf '%s: note: %s\n' "$FG_TOOL" "$MH_NOTE" >&2 ;;
      1) printf '%s: REFUSING `git push` of %s to main: RED MAIN. %s.\n  Stop the line: while main is red, only a gated fix lands.\n  Fix: land the fix first. Rebase the fix branch onto origin/main (it must contain %s), run `integration-gate --with-critic` on it, and push exactly the head its INTEGRATION OK line names. If main was fixed by another landing since, refresh the verdict with `~/dev/custom/ai/bin/main-health check --repo <this checkout>` and retry.\n' \
           "$FG_TOOL" "$sha" "$MH_WHY" "$MH_RED_SHA" >&2
         exit 3 ;;
      *) printf '%s: REFUSING `git push` of %s to main: COULD NOT LOOK whether main is red. %s.\n  Fix: inspect the marker (`~/dev/custom/ai/bin/main-health status --repo <this checkout>`), repair what it names, then refresh it with `~/dev/custom/ai/bin/main-health check --repo <this checkout>` and retry.\n' \
           "$FG_TOOL" "$sha" "$MH_WHY" >&2
         exit 3 ;;
    esac
  done < <(mh_push_main_sources main "$cur" "${FG_PUSH_ARGS[@]}")
  return 0
}

# ---- Ungated-main refusal (DND-1690) -----------------------------------------
# A push whose destination is main, in a repo that DECLARES a gate, is REFUSED
# (exit 3) unless integration-gate covers the pushed commit, on a green main as
# much as a red one. Before this, only a red main was checked (above), and a
# cron lane pushed bcfd66b6 to a green main with no receipt; main went red
# (DND-1685). The decision is ir_push_covered in ai/lib/integration-receipt.sh:
# a receipt for exactly the pushed commit, or a clean rebase (or merge) of a
# gated head onto the landed main (the DND-1463 rule, kept), or nothing new.
# A receipt counts only when its seal verifies (DND-1814): one written by hand
# or by branch code is RECEIPT UNVERIFIED and covers nothing.
#
# The landed main is the PUSHED remote's tracking ref (refs/remotes/<r>/main,
# where <r> is the configured remote whose push URL is the one pushed to). The
# gate is the one declared there, never on the pushed commit, so a diff that
# deletes the gate cannot lift the bar (~/dev/custom/CLAUDE.md -> "A check's
# own bar must not live in the diff it is checking"). With no landed main known
# (a URL push, a first push, a narrowed fetch), the repo counts as gated if the
# pushed commit's history EVER held a declared gate path (ir_gate_ever_declared),
# and then only an exact receipt covers it. A repo that never declared one is
# not judged. A receipt, store, or object it cannot read refuses (COULD NOT
# LOOK). Every remote is judged, not only origin: the receipt is about the
# commit. Like the red-main refusal it runs before the dry-run print, and it
# has no skip flag.
fg_refuse_ungated_main() {
  local common gitdir cur src sha landed="" decl_at gate rc r u
  [ -n "$FG_PUSH_URL" ] || return 0
  common="$(git "${FG_PUSH_GLOB[@]}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [ -n "$common" ] || return 0
  gitdir="$(git "${FG_PUSH_GLOB[@]}" rev-parse --absolute-git-dir 2>/dev/null)" || gitdir="$common"
  cur="$(git "${FG_PUSH_GLOB[@]}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  # shellcheck source=main-health.sh
  if ! . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/main-health.sh" 2>/dev/null; then
    printf '%s: REFUSING `git push`: cannot load ai/lib/main-health.sh (and the integration receipt rules it loads), so whether the push to main was gated is unknown.\n  Fix: run %s from a full ~/dev/custom checkout (ai/bin and ai/lib side by side).\n' "$FG_TOOL" "$FG_TOOL" >&2
    exit 3
  fi
  # The pushed remote's name: the configured remote with FG_PUSH_URL as a push URL.
  fg_rewrite_args
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    while IFS= read -r u; do
      if [ "$u" = "$FG_PUSH_URL" ] && [ -z "$landed" ]; then
        landed="$(git "${FG_PUSH_GLOB[@]}" rev-parse --verify -q "refs/remotes/${r}/main^{commit}" 2>/dev/null || true)"
      fi
    done < <(git "${FG_REWRITE_ARGS[@]}" "${FG_PUSH_GLOB[@]}" remote get-url --push --all "$r" 2>/dev/null || true)
  done < <(git "${FG_PUSH_GLOB[@]}" remote 2>/dev/null || true)
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    sha="$(git "${FG_PUSH_GLOB[@]}" rev-parse --verify -q --end-of-options "${src}^{commit}" 2>/dev/null || true)"
    # An unresolvable source fails in git itself; nothing lands. A source may
    # start with `-` (a refspec after `--`), hence --end-of-options (DND-1843).
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
    decl_at="${landed:-$sha}"
    rc=0
    if [ -n "$landed" ]; then
      gate="$(ir_declared_gate_on "$gitdir" "$landed")" || rc=$?
    else
      gate="$(ir_gate_ever_declared "$gitdir" "$sha")" || rc=$?
    fi
    case "$rc" in
      0) ;;
      1) continue ;;
      *) printf '%s: REFUSING `git push` of %s to main: COULD NOT LOOK whether this repo declares a gate: git cannot read %s under %s.\n  Fix: run `git fetch` for the remote you push to in this checkout and retry. Could not look is not "no gate".\n' \
           "$FG_TOOL" "$sha" "$decl_at" "$common" >&2
         exit 3 ;;
    esac
    rc=0; ir_push_covered "$common" "$sha" "$landed" || rc=$?
    case "$rc" in
      0) case "$IR_COVER" in
           exact)  printf '%s: note: integration-gate passed exactly %s (%s)\n' "$FG_TOOL" "$sha" "$IR_RECEIPT" >&2 ;;
           rebase) printf '%s: note: %s is a clean rebase of the gated head %s onto the landed main %s (%s); it lands with no re-gate (DND-1463)\n' \
                     "$FG_TOOL" "$sha" "$IR_COVER_HEAD" "$landed" "$IR_RECEIPT" >&2 ;;
         esac ;;
      1) printf '%s: REFUSING `git push` of %s to main: %s. This repo declares a gate (%s on %s), and %s.\n  Fix: %srun `~/dev/custom/ai/bin/integration-gate --with-critic --rebase` on the branch you are landing (it records the receipt), then push exactly the head its INTEGRATION OK line names, or a clean rebase of it onto a newer main.\n' \
           "$FG_TOOL" "$sha" "$IR_KIND" "$gate" "$decl_at" "$IR_WHY" "${IR_HOW:+$IR_HOW }" >&2
         exit 3 ;;
      *) printf '%s: REFUSING `git push` of %s to main: COULD NOT LOOK whether integration-gate covers it (%s). %s.\n  Fix: %s run `~/dev/custom/ai/bin/integration-gate --with-critic --rebase` on the branch and push the head its INTEGRATION OK line names.\n' \
           "$FG_TOOL" "$sha" "$IR_KIND" "$IR_WHY" "${IR_HOW:-repair what it names and retry; if the receipt is gone,}" >&2
         exit 3 ;;
    esac
  done < <(mh_push_main_sources main "$cur" "${FG_PUSH_ARGS[@]}")
  return 0
}


# ---- The credential grant (DND-1868) -----------------------------------------
# Before DND-1868 the bot's header sat in git's environment config channel, so
# every command git started for a routed command held it: a pre-push hook, a
# config-defined hook (hook.<name>.*), core.hooksPath, a filter or diff driver,
# an editor, GIT_TEMPLATE_DIR's hooks, and any git those ran, which pushed
# past every check here. Measured on git 2.54 against local bare remotes
# (ai/test/gh-athena/self-test.sh, the DND-1868 cases).
#
# The header never enters git's environment. fg_git_exec rewrites both forge
# URL forms to `athena-forge::https://<host>/` (fg_rewrite), puts
# FG_TRANSPORT_DIR first on git's PATH, and, for a command that reaches
# exactly ONE forge URL, opens a pipe holding two lines, the absolute path of
# git's own git-remote-https and the header, exported as ATHENA_FG_CRED_FD
# with ATHENA_FG_HOST. git starts the transport before any command of the
# caller's: a push connects before the pre-push hook and on-demand submodule
# pushes; a fetch, clone or pull runs its hooks, filters, drivers and editors
# after the transfer. The three exceptions measured on git 2.54 are closed:
# a pager (git --no-pager; -p is refused), core.fsmonitor naming a command,
# and the post-index-change hook of a rebasing pull (each refused,
# fg_refuse_pre_transport). The transport drains the pipe and execs
# git-remote-https with the header. Anything started later finds the pipe
# empty, and its own forge connection fails at the transport, loudly.
#
# Which commands get the grant (fg_cred_decide), on the URL set
# fg_refuse_non_https resolved (FG_CRED_URLS):
#   * exactly one URL, athena-forge::https://<host>/...: granted;
#   * no forge URL (a local path, file://, ssh:// or https to another host,
#     a remote with remote.<n>.vcs, any other `<name>::` URL): no credential,
#     since nothing there needs the bot's;
#   * a subcommand whose URLs the route does not resolve: no credential. An
#     unresolvable set is never read as "forge only";
#   * refused up front, exit 3 with a Fix: line: more than one URL when one
#     of them is the forge (fetch --all or --multiple, remote update, several
#     pushurls, a forge remote beside another); an athena-forge:: URL to any
#     other host (a caller-written rewrite); and a URL that an insteadOf or
#     pushInsteadOf turns into plain https://<host>/, which the route's
#     rewrite never reaches and which would carry no credential; and a
#     command that would start a command of the caller's before the
#     transport (fg_refuse_pre_transport).
# A `submodule` command whose URL set holds several gets no credential
# instead of a refusal: most of its subcommands (status, init, sync) reach
# no forge at all.
# Over-refusals, accepted: a submodule fetch nested under a routed fetch,
# pull or clone, a partial-clone lazy fetch, push.negotiate, and a bundle-URI
# clone each meet a used grant and fail; a signed push fails at
# refuse-signing. One connection per command.
# The wrapper's own ls-remote probes around a push (fg_push_and_record) carry
# the header in their environment, with https as the only protocol git may
# use (GIT_ALLOW_PROTOCOL), so no helper or command a config rewrite names
# can receive it.
# The transport and the probes both run with TLS verification on, no proxy
# and no curl trace, whatever the caller set, and refuse a CA or TLS-backend
# setting (ai/lib/forge-http-pin.sh, DND-1899).
# Residual: same uid is not a boundary (a process that reads the token cache,
# or the transport's /proc/<pid>/environ while it runs, gets the token); and
# the grant rests on fg_refuse_non_https's URL resolution.
FG_CRED=""
FG_CRED_WHY=""
FG_CRED_URL=""
FG_REMOTE_HTTPS=""
FG_HEADER=""

# CG : git with the granted command's own global options (alias ones
# included) and the route's rewrites, for the config reads below.
CG() { git "${FG_REWRITE_ARGS[@]}" "${FG_CMD_GLOB[@]}" "$@"; }

# fg_refuse_pre_transport : refuse a granted command that would start a
# command of the caller's before the transport, where it would hold the
# grant. Measured on git 2.54 (each before the remote helper starts):
#   * core.fsmonitor naming a hook command, on fetch and pull (an index read).
#     A bool (git's own fsmonitor daemon, or off) runs no caller command;
#   * the post-index-change hook, on a pull that rebases (its clean-tree
#     check refreshes and writes the index). A pull that merges, or rebases
#     with --autostash, starts nothing before the fetch; this refuses every
#     rebasing pull, which can only over-refuse.
# Push, clone and ls-remote start nothing before the helper.
fg_refuse_pre_transport() {
  local fsm rc=0 a mode="" cur v
  fsm="$(CG config --get core.fsmonitor 2>/dev/null)" || rc=$?
  case "$rc" in
    0|1) ;;
    *) fg_refuse_cred "COULD NOT LOOK whether core.fsmonitor names a command (git config exited $rc)" \
         "repair the git config git cannot read, then retry." ;;
  esac
  if [ -n "$fsm" ] && ! fg_bool_false "$fsm"; then
    case "${fsm,,}" in
      true|yes|on|1) ;;
      *) fg_refuse_cred "core.fsmonitor names a command ($fsm), which git starts before the forge connection, so it would hold the credential" \
           "run it with \`-c core.fsmonitor=false\` (\`~/dev/custom/ai/bin/$FG_TOOL git -c core.fsmonitor=false …\`), or unset core.fsmonitor in this repository." ;;
    esac
  fi
  [ "$FG_URLS_SUB" = pull ] || return 0
  # Does this pull rebase? Read conservatively, so a parse slip can only
  # over-refuse: any long option git may read as --rebase (any prefix of it,
  # since git accepts a unique abbreviation: --reb), with no value or a value
  # that is not false, and any short cluster holding r (-qr), count as
  # rebasing wherever they stand. Only the exact --no-rebase, or a --rebase
  # value that is false, counts as off. With no flag: branch.<cur>.rebase,
  # else pull.rebase. Anything but false rebases.
  local on="" off=0 n
  for a in "${FG_CMD_ARGS[@]}"; do
    case "$a" in
      --) break ;;
      --no-rebase) off=1 ;;
      --?*)
        n="${a#--}"; n="${n%%=*}"
        if [[ rebase == "$n"* ]]; then
          case "$a" in
            *=*) if fg_bool_false "${a#*=}"; then off=1; else on="$a"; fi ;;
            *) on="$a" ;;
          esac
        fi ;;
      -?*) [[ "${a#-}" == *r* ]] && on="$a" ;;
    esac
  done
  if [ -n "$on" ]; then mode="true ($on)"
  elif [ "$off" = 1 ]; then mode=false
  fi
  if [ -z "$mode" ]; then
    cur="$(CG symbolic-ref -q --short HEAD 2>/dev/null || true)"
    [ -n "$cur" ] && mode="$(CG config --get "branch.$cur.rebase" 2>/dev/null || true)"
    [ -n "$mode" ] || mode="$(CG config --get pull.rebase 2>/dev/null || true)"
  fi
  [ -z "$mode" ] && return 0
  fg_bool_false "$mode" && return 0
  v="$mode"
  fg_refuse_cred "this pull rebases (rebase=$v), and a rebasing pull runs the post-index-change hook before its fetch, so the hook would hold the credential" \
    "fetch through the route, then rebase with plain git, which reaches no forge: \`~/dev/custom/ai/bin/$FG_TOOL git fetch <remote>\`, then \`git rebase <remote>/<branch>\`; or pull with --no-rebase."
}

# fg_refuse_cred <what> <fix> : refuse the whole command up front.
fg_refuse_cred() {
  cat >&2 <<EOF
$FG_TOOL: REFUSING this git command: $1. The route hands the bot's credential to exactly one forge connection per command, through its own transport (DND-1868), so this would fail, or reach $FG_HOST with no credential.
  Fix: $2 $FG_ESCALATE
EOF
  exit 3
}

# fg_cred_decide : sets FG_CRED (grant / none), FG_CRED_WHY and FG_CRED_URL,
# or refuses (exit 3). For a grant it also sets FG_REMOTE_HTTPS.
fg_cred_decide() {
  local u inner sh forge=0 other=0 seen=$'\n' ou="" own
  FG_CRED=none; FG_CRED_URL=""; FG_REMOTE_HTTPS=""
  if [ "$FG_URLS_RESOLVED" != 1 ]; then
    FG_CRED_WHY="the route does not resolve which URLs this command reaches"
    return 0
  fi
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [[ "$seen" == *$'\n'"$u"$'\n'* ]] && continue
    seen+="$u"$'\n'
    case "$u" in
      athena-forge::*)
        inner="${u#athena-forge::}"
        case "$inner" in
          "https://$FG_HOST/"?*) forge=$((forge + 1)); FG_CRED_URL="$inner" ;;
          *) fg_refuse_cred "it reaches $u, an athena-forge:: URL that is not https://$FG_HOST/, so it names the route's transport for another host" \
               "drop the url.athena-forge::<URL>.insteadOf rule that produces it, and name the repository by its https://$FG_HOST/<owner>/<repo>.git URL." ;;
        esac ;;
      *)
        sh="$(fg_url_host_scheme "$u")"
        if [ "${sh%% *}" = https ] && [ "${sh#* }" = "$FG_HOST" ]; then
          fg_refuse_cred "it reaches $u as plain https: an insteadOf or pushInsteadOf rule rewrites it there, past the route's own rewrite to its transport, so no credential would reach it" \
            "remove the pushInsteadOf (or insteadOf) rule for $FG_HOST that rewrites to https://$FG_HOST/ (\`git config --show-origin --get-regexp 'url\\..*insteadof'\` finds it), or push to the https URL directly."
        fi
        other=$((other + 1)); ou="$u" ;;
    esac
  done <<<"$FG_CRED_URLS"
  if [ "$forge" -gt 1 ] || { [ "$forge" = 1 ] && [ "$other" -gt 0 ]; }; then
    # `submodule` lists every URL its subcommands might reach, and most
    # (status, foreach is refused, sync, init) reach none: no credential
    # rather than a refusal. A nested clone or fetch then fails at the
    # transport, loudly.
    if [ "$FG_URLS_SUB" = submodule ]; then
      FG_CRED_WHY="a submodule command that may reach several URLs gets none; run one routed command per submodule"
      return 0
    fi
    fg_refuse_cred "it reaches more than one URL ($forge on $FG_HOST, $other elsewhere${ou:+, e.g. $ou}), and only one connection can hold the credential" \
      "run one \`~/dev/custom/ai/bin/$FG_TOOL git <cmd> <remote>\` per remote: no fetch --all, --multiple or remote update, and one pushurl per remote."
  fi
  if [ "$forge" = 0 ]; then
    FG_CRED_WHY="no URL it reaches is https://$FG_HOST/"
    return 0
  fi
  fg_refuse_pre_transport
  own="$(env -u GIT_EXEC_PATH git --exec-path 2>/dev/null || true)"
  if [ -z "$own" ] || [ ! -x "$own/git-remote-https" ]; then
    fg_refuse_cred "COULD NOT LOOK where git's own git-remote-https is (\`git --exec-path\` gave '${own}')" \
      "check that \`git --exec-path\` names git's exec directory and that it holds git-remote-https, then retry."
  fi
  FG_REMOTE_HTTPS="$own/git-remote-https"
  FG_CRED=grant
  FG_CRED_WHY="one forge URL: $FG_CRED_URL"
}

# fg_open_grant : the one-shot pipe for the transport. A pipe, never a file:
# a drained pipe gives every later reader EOF, where a file (or a here-string,
# which may be one) can be reopened at offset 0 through /proc/<pid>/fd/N.
# printf is a builtin, so the header is on no argv.
FG_GRANT_FD=""
fg_open_grant() {
  exec {FG_GRANT_FD}< <(printf '%s\n%s\n' "$FG_REMOTE_HTTPS" "$FG_HEADER")
  export ATHENA_FG_CRED_FD="$FG_GRANT_FD" ATHENA_FG_HOST="$FG_HOST"
}

# fg_close_grant : after git ran as a child (fg_push_and_record), close the
# grant, so nothing the wrapper runs next inherits it.
fg_close_grant() {
  [ -n "$FG_GRANT_FD" ] || return 0
  exec {FG_GRANT_FD}<&-
  FG_GRANT_FD=""
  unset ATHENA_FG_CRED_FD ATHENA_FG_HOST
}

# fg_git_exec <basic-user> <token> <git args...> : run (or, under FG_DRY_RUN=1,
# print) git with every owner credential source removed, git's pager off, and
# the bot's HTTPS basic-auth header for FG_HOST granted to the route's
# transport alone ("The credential grant" above). The token is never on any
# process's argv (visible in `ps`), never in a URL or a config file, and never
# in the environment of the git that runs the command; only the wrapper's own
# https-only ls-remote probes around a push (fg_push_and_record) carry it.
fg_git_exec() {
  local user="$1" token="$2" a
  shift 2
  fg_refuse_red_main
  fg_refuse_ungated_main
  if [ "$FG_PAGINATE" = 1 ]; then
    fg_refuse_cred "it asks for git's pager (-p / --paginate), a command git would start before its forge connection" \
      "drop -p / --paginate; the route runs git with --no-pager."
  fi
  fg_cred_decide
  FG_HEADER="AUTHORIZATION: basic $(printf '%s:%s' "$user" "$token" | openssl base64 -A)"
  fg_rewrite_args
  set -- --no-pager -c credential.helper= -c core.askPass= "${FG_REWRITE_ARGS[@]}" "$@"
  if [ "${FG_DRY_RUN:-}" = 1 ]; then
    printf '%s' "$FG_RESOLVED_URLS" | sed "s/^/$FG_TOOL: dry-run: url /"
    if [ "$FG_CRED" = grant ]; then
      printf '%s: dry-run: cred: granted (%s) to %s as [AUTHORIZATION: basic <%s:REDACTED>]\n' \
        "$FG_TOOL" "$FG_CRED_WHY" "$FG_TRANSPORT_DIR/git-remote-athena-forge" "$user"
    else
      printf '%s: dry-run: cred: none (%s)\n' "$FG_TOOL" "$FG_CRED_WHY"
    fi
    printf '%s: dry-run: exec git' "$FG_TOOL"
    for a in "$@"; do printf ' [%s]' "$a"; done
    printf '\n'
    exit 0
  fi
  # The caller's own grant variables never reach git; ours are set only for
  # a granted command, by fg_open_grant.
  unset ATHENA_FG_CRED_FD ATHENA_FG_HOST
  export PATH="$FG_TRANSPORT_DIR:$PATH"
  if [ "${FG_LANDING_TELEMETRY:-}" = 1 ] && [ -n "$FG_PUSH_URL" ]; then
    fg_push_and_record "$@"
  fi
  [ "$FG_CRED" = grant ] && fg_open_grant
  exec env -u GIT_ASKPASS -u SSH_ASKPASS GIT_TERMINAL_PROMPT=0 git "$@"
}
