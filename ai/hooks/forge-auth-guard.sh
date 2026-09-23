#!/bin/sh
# PreToolUse forge-auth guard.
#
# DENIES a Bash command that would touch, rotate, or refresh forge (GitHub /
# GitLab) authentication state. Auth is OWNER-GATED: the machine owner sets up
# the `gh` / `glab` credentials and the Athena identity wrappers once, out of
# band; the agent NEVER logs in, logs out, refreshes a token, mints an OAuth
# token, or edits a credential/config file. This machine-enforces the
# "auth state is owner-gated, never touched by the agent" invariant that the
# athena-admiral (and the fleet) carries in prose — prose -> a deny hook, the
# "relocate or STRENGTHEN a check" the safety block (ai/blocks/ops/safety-checks.md)
# permits.
#
# Deny-by-default is correct HERE (unlike forge-identity-guard, which warns):
# there is NO legitimate agent use for changing auth state. A read of auth
# status (`gh auth status`, `glab auth status`) is NOT a change and is allowed.
#
# What it DENIES (see the messages for the exact remedy):
#   1. `gh auth <login|logout|refresh|token|setup-git|switch>` (also gh-athena wrapper;
#      bare OR path-qualified, e.g. ~/dev/custom/ai/bin/gh-athena, /usr/bin/gh)
#   2. `glab auth <login|logout|refresh|configure-docker|docker-helper|dpop-gen>`
#      (also glab-athena wrapper; bare OR path-qualified)
#      For either CLI, a subcommand supplied by expansion (`gh auth $SUB`,
#      `gh auth $(...)`) is denied too: its value is unknowable here.
#   3. A POST to an OAuth token endpoint (`gh api`, `glab api`, `curl`, `wget`
#      or httpie/xh hitting `oauth/token` / `/oauth/access_token` with a POST
#      verb, a body/field flag that implies POST, or an httpie data item /
#      piped or redirected stdin body, which makes httpie POST).
#   4. A WRITE (redirect, tee, sed -i, rm/mv/cp/install/ln, editor) targeting a
#      known forge credential/config location (anything under ~/.config/gh,
#      ~/.config/glab-cli, $XDG_CONFIG_HOME/gh|glab-cli, $GH_CONFIG_DIR or
#      $GLAB_CONFIG_DIR, or a gh/ or glab-cli/ hosts.yml/config.yml under any
#      config root). Also a write by BARE NAME after reaching the location
#      another way: a `cd`/`pushd` into the config ROOT (~/.config,
#      $XDG_CONFIG_HOME) and then `rm -rf gh`; or a session cwd (the hook
#      input's `cwd`, which persists across Bash calls) inside a forge config
#      dir (any write) or equal to a config root (a write naming gh/glab-cli).
#   5. `auth <mutation>` after a command word built by EXPANSION: a variable
#      (`$G auth login`, `${GH:-gh} auth setup-git`, `"$GH" auth token`) or a
#      command substitution (`$(which gh) auth login`). The command it names is
#      unknowable here, so ANY expanded command word followed by `auth` and a
#      gh/glab mutating subcommand is denied.
#   6. `glab-athena refresh` (bare, path-qualified, quoted or chained): it mints
#      a new PAT for the Athena GitLab service account with the OWNER's glab
#      session. An expired Athena token is escalated, never self-healed.
#      The deny has no exception, so it binds EVERY Claude Code session
#      (admiral and coordinator included): only the human owner, in their
#      own terminal outside Claude Code, can run the refresh.
#      gh-athena has no equivalent: it mints its short-lived App installation
#      token inside every call (and in `--check`, which forge-preflight runs),
#      from the App key, with no owner session, so it is not denied.
#
# DELIBERATE FALSE POSITIVE (kept by coordinator decision, DND-390): matching
# runs on TEXT, not parsed argv. The command is flattened to one line and
# dequoted (' " and \ removed), so quoting cannot split a pattern, but it also
# means a command that merely CONTAINS a denied pattern is denied: a printf or
# echo of a log line naming the subcommand, a `git commit -m` whose message
# names it, a grep for it, or (rule 5) some other tool's `$CLI auth login`.
# This is accepted for a deny-only guard: rephrasing costs one retry (write the
# text through a file, or `git commit -F`), while a miss lets owner-gated auth
# state change. Do not "fix" it by parsing argv; that reopens every
# quoting/indirection bypass the flattening closes.
#
# NOT CATCHABLE IN PRINCIPLE (a tripwire for the direct and lightly-indirected
# forms, not a sandbox). Anything where the denied TEXT never appears in the
# command line:
#   * a string computed and then executed: `eval "$(printf 'gh au%sh login' t)"`,
#     `a=au; gh ${a}th login`, `echo Z2ggYXV0aCBsb2dpbg== | base64 -d | sh`;
#   * the subcommand or command supplied through a pipe: `echo login | xargs gh auth`;
#   * a script file, alias, or shell function defined in one call and run in a
#     later one, or another interpreter (`python -c`, `node -e`) that builds
#     the argv itself;
#   * a config dir named in the command text through a symlink or any other
#     path this hook cannot recognise (`cd ~/dotfiles/gh-link && rm hosts.yml`).
#     Only ~/.config, $XDG_CONFIG_HOME, $GH_CONFIG_DIR and $GLAB_CONFIG_DIR are
#     known locations. The cwd checks compare realpaths, so a symlinked cwd IS
#     caught once it is the session cwd; the text of this one command is not
#     resolved. Likewise a cwd inside a config dir that only an agent-exported
#     $GH_CONFIG_DIR names (the hook cannot see a Bash-session export).
#
# Design guarantees (mirror safe-wait-guard / forge-identity-guard):
#   * FAIL-OPEN — any error (missing jq, unparseable input, non-Bash tool, no
#     match) exits 0 and ALLOWS silently. A bug here can never wedge Bash.
#   * NARROW    — only auth-MUTATING shapes match; status reads and ordinary
#     `gh`/`glab` reads/writes (pr/mr/api reads) pass untouched.
#
# Wired in ~/.claude/settings.json as a PreToolUse hook scoped to Bash
# (ai/hooks/registry.json is the source of truth; `scripts/setup-hooks --install`
# wires it).

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# The session cwd the command will run in. Claude Code's hooks reference
# documents `cwd` as the directory when the hook fires, updated as the session
# navigates, so a `cd` in an EARLIER Bash call is visible here. (Whether Claude
# Code resets a cwd that leaves the project is not documented; if it does, the
# cwd checks in rule 4 are simply inert there, never over-denying.) Absent or
# unreadable -> empty, and the cwd checks are skipped (fail-open).
# The config-location env vars those checks read ($GH_CONFIG_DIR,
# $GLAB_CONFIG_DIR, $XDG_CONFIG_HOME, $HOME) come from THIS hook's process, i.e.
# Claude Code's environment. A value an agent `export`s in an earlier Bash call
# is not visible here; the literal `~/.config/gh|glab-cli` pattern on the cwd
# still applies.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=

# Flatten to one logical line so a command split across newlines still matches.
# Then DEQUOTE: drop every ' " and \ so shell quoting cannot split a pattern
# ("gh" auth ..., a quoted subcommand, oauth/"token", a backslash-escaped
# command word). The shell removes the same characters before exec, so the
# dequoted text is closer to what actually runs. Every rule matches against it.
FLAT=$(printf '%s' "$CMD" | tr '\n\t' '  ' | tr -d "'\"\\\\")

has() { printf '%s' "$FLAT" | grep -Eq "$1"; }
hasi() { printf '%s' "$FLAT" | grep -Eiq "$1"; }

# deny <reason> : emit the PreToolUse deny decision and exit (fail-open if jq
# cannot encode, which would simply allow — consistent with the guarantee).
deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
    2>/dev/null
  exit 0
}

# CMD_START: the left boundary of a COMMAND WORD (DND-388). The word may be bare
# or path-qualified (`gh`, `/usr/bin/gh`, `~/.../gh-athena`, `$HOME/.../glab`,
# `./gh`), so '/' IS a boundary, alongside the shell separators (space ; & | (
# backtick $ and start of line). A letter, digit, '_', '-' or '.' is NOT a
# boundary, so a word that merely ENDS in the name (`sigh`, `my-gh`,
# `foo_glab`) never matches. The pre-DND-388 class also excluded '/', so every
# path-qualified invocation was allowed.
CMD_START='(^|[^[:alnum:]_.-])'

# The auth subcommands each CLI treats as MUTATING, classified from
# `gh auth --help` (gh 2.96.0) and `glab auth --help` (glab 1.92.1) (DND-390):
#   gh:   login, logout, refresh, setup-git (rewrites git's credential config),
#         switch (rewrites the active account in hosts.yml), token (prints the
#         stored token: credential egress, denied since the start).
#         READ: status; git-credential (hidden; git's helper protocol, whose
#         store/erase gh ignores; the sanctioned push path uses it).
#   glab: login, logout, refresh (older glab; kept for them), configure-docker
#         (writes docker's credential-helper config), docker-helper (emits or
#         stores registry credentials via docker's helper protocol; docker
#         execs its own docker-credential-glab binary, never this text),
#         dpop-gen (mints a signed DPoP proof JWT from the SSH key: a new
#         credential). READ: status.
GH_MUT='(login|logout|refresh|token|setup-git|switch)'
GLAB_MUT='(login|logout|refresh|configure-docker|docker-helper|dpop-gen)'
ANY_MUT='(login|logout|refresh|token|setup-git|switch|configure-docker|docker-helper|dpop-gen)'
# A subcommand word that starts with an expansion ($VAR, ${...}, $(...), or a
# backtick): its value is unknowable here, so it is treated as mutating.
EXPANDED='[$`]'

# ---- 1: gh auth <mutation> (bare, path-qualified, or -athena wrapper) ------
# `gh` or `gh-athena`, then `auth`, then a mutating (or expanded) subcommand.
# `gh auth status` and `gh auth git-credential` are NOT matched (reads).
if has "${CMD_START}gh(-athena)?[[:space:]]+auth[[:space:]]+(${GH_MUT}|${EXPANDED})"; then
  deny 'forge-auth: this changes GitHub auth state (login/logout/refresh/token), which is OWNER-GATED — the agent never touches forge credentials. Fix: do NOT run this — do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena"). Diagnosing is fine: `~/dev/custom/ai/bin/forge-preflight` and `gh auth status` are reads.'
fi

# ---- 2: glab auth <mutation> (bare, path-qualified, or -athena wrapper) ----
if has "${CMD_START}glab(-athena)?[[:space:]]+auth[[:space:]]+(${GLAB_MUT}|${EXPANDED})"; then
  deny 'forge-auth: this changes GitLab auth state (login/logout/refresh), which is OWNER-GATED — the agent never touches forge credentials. Fix: do NOT run this — do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena"). Diagnosing is fine: `~/dev/custom/ai/bin/forge-preflight` and `glab auth status` are reads.'
fi

# ---- 3: POST to an OAuth token endpoint ------------------------------------
# A request that mints/refreshes a token: an oauth token path together with a
# POST. POST is recognised in every form the tools accept:
#   * an explicit verb, spaced, `=`-joined or attached, any case:
#     `-X POST`, `-XPOST`, `--request=post`, `--method POST`, httpie `POST`;
#   * a body flag, which makes curl/wget send a POST (case-sensitive): a
#     short-flag cluster containing `d` (`-d`, `-dx`, `-sd`), `-F`, `--data*`,
#     `--json`, `--form*`, wget `--post-data` / `--post-file`;
#   * a field flag in a `gh api` / `glab api` command, which switches the
#     request to POST: `-f`, `-F`, `--field`, `--raw-field`, `--input`;
#   * in an httpie command (`http`, `https`, or the xh clone `xh`/`xhs`), no
#     verb at all: httpie infers POST from a request body (DND-390), which is
#     any data item in the same simple command (`key=value`, `key:=json`,
#     `key=@file`, `key:=@file`, a `field@file` upload), `--raw`, or a body on
#     stdin (piped into httpie, or a `<` redirect). A header (`Key:Value`) or a
#     query param (`key==value`) is NOT a body.
# curl's `-f` (`--fail`) and `-D` (`--dump-header`) are NOT POST flags, so a
# plain GET of a token path (e.g. `curl -fsSL .../oauth/token/info`) does NOT
# match; neither does `http .../oauth/token/info Authorization:Bearer\ x`.
HTTPIE="${CMD_START}(https?|xhs?)[[:space:]]"
if has 'oauth/(token|access_token)' \
  && { hasi '((-X|--request|--method)([[:space:]]*|=)post|(^|[[:space:]])post([[:space:]]|$))' \
    || has '(^|[[:space:]])(-[[:alnum:]]*d|-F|--(data|json|form|post-data|post-file))' \
    || { has "${CMD_START}glab(-athena)?[[:space:]]+api[[:space:]]|${CMD_START}gh(-athena)?[[:space:]]+api[[:space:]]" \
      && has '(^|[[:space:]])(-f|--field|--raw-field|--input)'; } \
    || has "${HTTPIE}([^|;&]*[[:space:]])?([^[:space:]=:/@-][^[:space:]=:/@]*(:?=([^=]|\$)|@)|--raw)" \
    || has "${HTTPIE}[^|;&]*<" \
    || has "(^|[^|])[|][[:space:]]*([^[:space:];&|]*/)?(https?|xhs?)[[:space:]]"; }; then
  deny 'forge-auth: this POSTs to an OAuth token endpoint (minting/refreshing a forge token), which is OWNER-GATED — the agent never mints forge credentials. Fix: do NOT run this — do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena"). The owner provisions forge auth out of band.'
fi

# ---- 4: a WRITE to a known forge credential/config file --------------------
# The command names a gh/glab credential or config location AND carries a
# mutating operator. Locations: anything under ~/.config/gh or
# ~/.config/glab-cli or $XDG_CONFIG_HOME/gh|glab-cli (the dirs themselves
# included, whatever follows the dir name: / ; ) & * { space or end, but not a
# sibling like gh-dash), anything named via $GH_CONFIG_DIR / $GLAB_CONFIG_DIR,
# or a `gh/` / `glab-cli/` hosts.yml / config.yml under any root.
# Operators: a redirect; an in-place edit (`sed`/`gsed`/`perl` with `-i`, anywhere in
# that command's flags, or `--in-place`); or a mutating tool (tee, rm, unlink,
# shred, mv, cp, install, ln, dd, truncate, an editor) invoked bare OR
# path-qualified (`/bin/rm`), after any separator. A plain read
# (cat/grep/less/ls, `sed -n`, `perl -ne`) does NOT match. The in-place check
# stops at | ; & so a later `grep -i` is not read as sed's flag. A redirect to
# /dev/null or an fd duplication (2>&1) does not write the file, so both are
# removed before the operator check.
WRITES=$(printf '%s' "$FLAT" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]##g')
writes() { printf '%s' "$WRITES" | grep -Eq "$1"; }
MUT_TOOL='(tee|rm|unlink|shred|mv|cp|install|ln|dd|truncate|vim?|nvim|nano|emacs)'
WRITE_OP="(>|${CMD_START}${MUT_TOOL}[[:space:]]|${CMD_START}g?(sed|perl)[[:space:]]([^|;&]*[[:space:]])?(-[nprlaswWXtTcEuz]*i|--in-place))"
FORGE_LOC='((\.config|XDG_CONFIG_HOME)\}?/(gh|glab-cli)([^[:alnum:]_.-]|$)|(GH|GLAB)_CONFIG_DIR([^[:alnum:]_]|$)|(^|[^[:alnum:]_.-])(gh|glab-cli)/(hosts|config)\.yml)'
# ---- 4b: the same write, by BARE NAME, after reaching the location (DND-390)
# The location never appears as a path in the command when the agent first
# moves into it: `cd ~/.config && rm -rf gh`, or a cwd left in ~/.config/gh by
# an EARLIER Bash call (the session cwd persists) and then `rm hosts.yml`.
#   * At a config ROOT (a `cd`/`pushd` to ~/.config, $HOME/.config,
#     $XDG_CONFIG_HOME or ${XDG_CONFIG_HOME:-...} in this command, or a cwd
#     equal to one): deny a mutating tool whose operand is the bare dir name
#     `gh` / `glab-cli` (or gh/..., gh*, gh{...}), a redirect into gh/ or
#     glab-cli/, or a further `cd gh` / `cd glab-cli` followed by any write.
#   * INSIDE a forge config dir (a cwd under ~/.config/gh|glab-cli,
#     $XDG_CONFIG_HOME/gh|glab-cli, $GH_CONFIG_DIR or $GLAB_CONFIG_DIR, by its
#     literal path or its realpath): deny ANY write, since every bare name there
#     is forge config. A `cd` into the dir itself in the command text is
#     already rule 4 (the dir path is named).
# A candidate dir is used only when it is an absolute path other than `/`: an
# unset or relative $GH_CONFIG_DIR is skipped, never read as "matches every
# cwd" (which would deny every write on the machine).
# A bare name may carry a relative prefix that still names the same entry:
# `./gh`, `././gh`, `$PWD/gh`, `${PWD}/gh`.
BARE_NAME='(\./|[$]\{?PWD\}?/)*(gh|glab-cli)'
BARE_OP="${CMD_START}${MUT_TOOL}[[:space:]]([^|;&]*[[:space:]])?${BARE_NAME}([/*{][^[:space:];&|]*)?([[:space:];&|)]|\$)|>[[:space:]]*${BARE_NAME}/"
# `cd`/`pushd` may carry options before the path (`cd --`, `cd -P`, `pushd -n`).
CD_WORD="${CMD_START}(cd|pushd)([[:space:]]+-[^[:space:];&|]*)*[[:space:]]+"
CD_ROOT="${CD_WORD}(([^[:space:];&|]*/)?\.config\}?|[$]\{?XDG_CONFIG_HOME(:-[^}]*)?\}?)/?([[:space:];&|)]|\$)"
CD_FORGE_BARE="${CD_WORD}${BARE_NAME}/?([[:space:];&|)]|\$)"

# abs_dir <path> : print <path> without trailing slashes iff it is absolute and
# not the root; print nothing otherwise.
abs_dir() {
  case "$1" in /*) ;; *) return 0 ;; esac
  _a=$(printf '%s' "$1" | sed 's#/*$##')
  [ -n "$_a" ] && printf '%s' "$_a"
}
# cwd_match <under|equal> <dir> : is the cwd (literal or realpath) <dir> (or,
# for `under`, inside it), comparing against <dir> literal and realpath?
cwd_match() {
  _d=$(abs_dir "$2"); [ -n "$_d" ] || return 1
  _dr=$(abs_dir "$(readlink -f "$_d" 2>/dev/null)")
  for _c in "$CWD_ABS" "$CWD_REAL"; do
    [ -n "$_c" ] || continue
    for _t in "$_d" "$_dr"; do
      [ -n "$_t" ] || continue
      [ "$_c" = "$_t" ] && return 0
      [ "$1" = under ] && case "$_c" in "$_t"/*) return 0 ;; esac
    done
  done
  return 1
}
CWD_ABS=$(abs_dir "$CWD")
CWD_REAL=
[ -n "$CWD_ABS" ] && CWD_REAL=$(abs_dir "$(readlink -f "$CWD_ABS" 2>/dev/null)")

cwd_in_forge_dir() {
  [ -n "$CWD_ABS" ] || return 1
  printf '%s\n%s' "$CWD_ABS" "$CWD_REAL" | grep -Eq '/\.config/(gh|glab-cli)(/|$)' && return 0
  for _k in "${GH_CONFIG_DIR:-}" "${GLAB_CONFIG_DIR:-}" \
    "${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/gh}" "${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/glab-cli}" \
    "${HOME:+$HOME/.config/gh}" "${HOME:+$HOME/.config/glab-cli}"; do
    cwd_match under "$_k" && return 0
  done
  return 1
}
cwd_at_config_root() {
  [ -n "$CWD_ABS" ] || return 1
  printf '%s\n%s' "$CWD_ABS" "$CWD_REAL" | grep -Eq '/\.config$' && return 0
  for _k in "${XDG_CONFIG_HOME:-}" "${HOME:+$HOME/.config}"; do
    cwd_match equal "$_k" && return 0
  done
  return 1
}

if { has "$FORGE_LOC" && writes "$WRITE_OP"; } \
  || { { has "$CD_ROOT" || cwd_at_config_root; } \
    && { writes "$BARE_OP" || { has "$CD_FORGE_BARE" && writes "$WRITE_OP"; }; }; }; then
  deny 'forge-auth: this writes to a forge credential/config file (gh hosts.yml/config.yml or glab-cli config.yml), which is OWNER-GATED — the agent never edits forge auth config. Fix: do NOT modify it — do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena"). The owner provisions forge auth out of band; reading the file (cat/grep) is allowed.'
fi

# ---- 4c: any write while the session cwd is INSIDE a forge config dir ------
# Every bare name here is forge config, so any write operator is denied. This
# over-denies a write that lands elsewhere (`gh pr list > /tmp/out`), so the
# message names the cwd and the one recovery that works: a `cd` out of the dir
# in its OWN Bash call (the hook sees the cwd from before this command runs).
if cwd_in_forge_dir && writes "$WRITE_OP"; then
  deny "forge-auth: the session cwd ($CWD_ABS) is inside a forge credential/config dir (gh or glab-cli config), and this command writes (a redirect, tee/rm/mv/cp/ln/truncate, sed -i, or an editor), so it may modify forge auth config by bare name, which is OWNER-GATED. Fix: run \`cd ~\` (or cd to your worktree) as its OWN Bash call first, then re-run this command; a cd inside this same command does not help, because the guard checks the cwd before the command runs. If you meant to change forge config, do NOT — do not work around this; escalate to your admiral with the command + error and wait (athena:github -> \"When a forge write can't be done as Athena\")."
fi

# ---- 5: auth <mutation> after an EXPANDED command word (DND-390) ------------
# The command word is a variable (`$G`, `${GH:-gh}`, `"$GH"` once dequoted,
# `$HOME/bin/$X`) or ends a command substitution (`$(which gh)`, a backtick
# form). What it names is unknowable here, so ANY such word followed by `auth`
# and a gh/glab mutating (or expanded) subcommand is denied. `$GH auth status`,
# `$GH auth git-credential get` and `$GH pr list` are NOT matched. Another tool
# with the same shape (`$GCLOUD auth login`) is denied too: the deliberate
# text-match false positive described in the header.
VAR_WORD='(^|[[:space:];&|(`])[^[:space:];&|()`]*[$](\{[^}]*\}|[[:alnum:]_]+)[^[:space:];&|()`]*'
if has "(${VAR_WORD}|[)\`])[[:space:]]+auth[[:space:]]+(${ANY_MUT}|${EXPANDED})"; then
  deny 'forge-auth: this runs `auth <login/logout/refresh/token/setup-git/switch/configure-docker/...>` through a command word built from a variable or command substitution, so it may change GitHub/GitLab auth state, which is OWNER-GATED — the agent never touches forge credentials. Fix: do NOT run this — do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena"). Diagnosing is fine: `~/dev/custom/ai/bin/forge-preflight` and `gh auth status` are reads.'
fi

# ---- 6: glab-athena refresh (DND-390, coordinator scope addition) ----------
# The wrapper intercepts `refresh` only as its FIRST argument, so only that
# shape is matched: `glab-athena mr list --search refresh` or
# `glab-athena api user` stay allowed. Bare `glab refresh` is not a glab command.
if has "${CMD_START}glab-athena[[:space:]]+refresh([[:space:];&|)]|\$)"; then
  deny 'forge-auth: `glab-athena refresh` mints a new token for the Athena GitLab service account using the OWNER'\''s glab session, which is OWNER-GATED: an expired Athena token is escalated, never self-healed. Fix: do NOT run this — do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena"). The admiral escalates to the coordinator, who asks the owner: only the owner runs the refresh, in their own terminal (this guard denies it in every Claude Code session). Diagnosing is fine: `~/dev/custom/ai/bin/forge-preflight` is a read.'
fi

# No auth-mutating construct detected -> allow silently.
exit 0
