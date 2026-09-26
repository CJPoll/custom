# shellcheck shell=bash
# forge-cli-isolation.sh — run glab/gh as the Athena identity with NO route back
# to the owner's login (DND-725). Sourced by ai/bin/glab-athena and
# ai/bin/gh-athena for every path that runs the forge CLI itself. (The `git`
# passthrough does not run the CLI; ai/lib/forge-git-passthrough.sh covers it.)
#
# The defect: glab-athena exported GITLAB_TOKEN from a token file after checking
# only that the file was READABLE. An empty or whitespace-only file exported
# GITLAB_TOKEN="", and glab treats an empty token as no token: it read its own
# config and keyring and answered as the OWNER (cjpoll). gh does the same with
# an empty GH_TOKEN (answers as CJPoll). Nothing failed and nothing said so.
#
# Two independent layers, so neither alone has to be perfect:
#   1. fci_require_token: refuse a token that is empty or holds whitespace or a
#      control character, with a Fix:, before the CLI runs.
#   2. fci_isolate: give the CLI a fresh, empty, mode-0700 config dir and scrub
#      every inherited variable it reads for identity or host. With no config
#      the CLI has no host entry, so it never looks up a stored token or the OS
#      keyring. An empty token then yields 401, not the owner.
#
# Lookup order MEASURED 2026-09-25 (glab 1.112.0, gh 2.83.2; `api user` with
# fixtures in a scratch dir; the owner's own config was only read):
#   glab: GITLAB_TOKEN="" + owner config           -> cjpoll (the defect)
#         GLAB_CONFIG_DIR=<empty dir>              -> 401
#         XDG_CONFIG_HOME=<empty dir> alone        -> cjpoll: glab still reads
#                                                     ~/.config/glab-cli, so
#                                                     XDG does NOT isolate glab
#         GLAB_CONFIG_DIR=<empty> + XDG=<keyring cfg> -> 401 (GLAB_CONFIG_DIR wins)
#         GLAB_CONFIG_DIR=<cfg with use_keyring:"true", no token> -> 401
#         cwd repo with .git/glab-cli/config.yml (keyring or token), isolated
#         global dir -> 401; the repo-local file never supplied a token
#         GITLAB_URI / GITLAB_API_HOST override the API host even with
#         GITLAB_HOST=gitlab.com, so an inherited one would send the PAT to
#         another host. GITLAB_ACCESS_TOKEN / OAUTH_TOKEN are token sources.
#         GLAB_DEBUG / GLAB_DEBUG_HTTP did not print the token.
#   gh:   GH_TOKEN="" or GITHUB_TOKEN="" + owner config -> CJPoll
#         GH_CONFIG_DIR=<empty dir>                -> "gh auth login" (no user)
#         GH_CONFIG_DIR=<empty> + GITHUB_TOKEN=x   -> GITHUB_TOKEN is used
#         GH_TOKEN=" " (whitespace)                -> 401, no fallback
#         GH_HOST overrides the API host; GH_DEBUG did not print the token;
#         gh wrote nothing into the empty config dir.
#
# Cost, accepted: the owner's CLI aliases and preferences do not apply under the
# wrappers. An alias is run by its real command name instead.
#
# What the CLIs write into the per-call dir (measured live, real tokens): glab
# writes a default config.yml and aliases.yml (0600), neither holding the token;
# gh writes nothing. So a dir left behind holds no secret.
#
# Residual: a SIGKILL of the wrapper skips the EXIT trap and leaves that dir in
# TMPDIR (no secret in it, per the above).

FCI_ESCALATE='do not run `glab-athena refresh`, any `glab auth`/`gh auth`, or edit a token file yourself (owner-gated), and do not fall back to plain `glab`/`gh`; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'"'"'t be done as Athena").'

# fci_token_ok <token> : 0 iff the token is non-empty and holds no whitespace
# and no control character. An empty token is how the CLI falls back to the
# owner; whitespace or a control character means the source is not one token.
fci_token_ok() {
  case "$1" in
    '' | *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# fci_require_token <rc> <tool> <bot> <source> <token> : return when the token
# is usable, otherwise refuse with exit <rc>. Never prints the token.
fci_require_token() {
  local rc="$1" tool="$2" bot="$3" src="$4" token="$5" why
  fci_token_ok "$token" && return 0
  if [ -z "$token" ]; then why="is missing, unreadable or empty"
  else why="holds whitespace or a control character, so it is not one token"; fi
  echo "$tool: REFUSING: the $bot token from $src $why, so this cannot run as $bot. With an empty token the CLI would fall back to the owner's own login." >&2
  echo "  Fix: $FCI_ESCALATE" >&2
  exit "$rc"
}

# fci_scrub_env <ERE> : unset every exported variable whose NAME matches <ERE>.
fci_scrub_env() {
  local re="$1" name
  while IFS= read -r name; do
    [[ "$name" =~ $re ]] && unset "$name"
  done < <(compgen -e)
  return 0
}

# fci_isolate <tool> <config-dir-var> : create a fresh, empty, mode-0700 config
# dir, export it as <config-dir-var>, and remove it on every exit of this shell.
# bash runs the EXIT trap on a normal exit, an error exit, and on termination by
# HUP/INT/TERM too (the self-test's SIGTERM case pins that), so no per-signal
# trap is needed. The caller must then RUN the CLI as a child, never `exec` it:
# exec would skip the cleanup. Refuses (exit 3) when the dir cannot be made:
# running without isolation is the thing being prevented.
fci_isolate() {
  local tool="$1" var="$2"
  FCI_CFG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$tool-cfg.XXXXXXXX" 2>/dev/null)" && [ -d "$FCI_CFG_DIR" ] || {
    echo "$tool: REFUSING: could not create a private config dir under ${TMPDIR:-/tmp}, so the CLI would read the owner's own config and login." >&2
    echo "  Fix: make \$TMPDIR (or /tmp) writable, then retry; $FCI_ESCALATE" >&2
    exit 3
  }
  chmod 700 "$FCI_CFG_DIR"
  trap 'rm -rf -- "$FCI_CFG_DIR"' EXIT
  export "$var=$FCI_CFG_DIR"
}
