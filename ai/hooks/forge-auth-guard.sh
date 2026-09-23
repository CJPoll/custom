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
#   2. `glab auth <login|logout|refresh>` (also glab-athena wrapper; bare OR
#      path-qualified)
#   3. A POST to an OAuth token endpoint (`gh api`, `glab api`, or `curl` hitting
#      `oauth/token` / `/oauth/access_token` with a POST verb or a body/field
#      flag that implies POST).
#   4. A WRITE (redirect, tee, sed -i, rm/mv/cp/install/ln, editor) targeting a
#      known forge credential/config location (anything under ~/.config/gh or
#      ~/.config/glab-cli, or a gh/ or glab-cli/ hosts.yml/config.yml under any
#      config root).
#
# Matching runs on the command flattened to one line with quotes and
# backslashes removed, so quoting cannot split a pattern. Like every text
# guard it matches TEXT, not parsed argv: a command that merely prints the
# pattern (a printf of a log line naming the subcommand) is also denied. That
# false positive is accepted for a deny-only guard: rephrasing costs one retry,
# while a miss leaks owner-gated auth state. Indirection through a variable
# (`G=gh; $G auth ...`) or a `cd` into the config dir followed by a bare-name
# rm is NOT caught; this guard is a tripwire for the direct forms, not a
# sandbox.
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

# ---- 1: gh auth <mutation> (bare, path-qualified, or -athena wrapper) ------
# `gh` or `gh-athena`, then `auth`, then a mutating subcommand (`switch` changes
# the active account in hosts.yml). `gh auth status` is NOT matched (a read).
if has "${CMD_START}gh(-athena)?[[:space:]]+auth[[:space:]]+(login|logout|refresh|token|setup-git|switch)"; then
  deny 'forge-auth: this changes GitHub auth state (login/logout/refresh/token/setup-git/switch), which is OWNER-GATED — the agent never touches forge credentials. Fix: do NOT run this, bare or path-qualified (~/.../gh-athena counts too). If a forge write is failing on auth, STOP and report to the owner that gh auth needs attention; verify the identity wrapper with `~/dev/custom/ai/bin/forge-preflight` (reads only). Reading status is fine: `gh auth status`.'
fi

# ---- 2: glab auth <mutation> (bare, path-qualified, or -athena wrapper) ----
if has "${CMD_START}glab(-athena)?[[:space:]]+auth[[:space:]]+(login|logout|refresh)"; then
  deny 'forge-auth: this changes GitLab auth state (login/logout/refresh), which is OWNER-GATED — the agent never touches forge credentials. Fix: do NOT run this, bare or path-qualified (~/.../glab-athena counts too). If a forge write is failing on auth, STOP and report to the owner that glab auth needs attention; verify the identity wrapper with `~/dev/custom/ai/bin/forge-preflight` (reads only). Reading status is fine: `glab auth status`.'
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
#     request to POST: `-f`, `-F`, `--field`, `--raw-field`, `--input`.
# curl's `-f` (`--fail`) and `-D` (`--dump-header`) are NOT POST flags, so a
# plain GET of a token path (e.g. `curl -fsSL .../oauth/token/info`) does NOT
# match.
if has 'oauth/(token|access_token)' \
  && { hasi '((-X|--request|--method)([[:space:]]*|=)post|(^|[[:space:]])post([[:space:]]|$))' \
    || has '(^|[[:space:]])(-[[:alnum:]]*d|-F|--(data|json|form|post-data|post-file))' \
    || { has "${CMD_START}glab(-athena)?[[:space:]]+api[[:space:]]|${CMD_START}gh(-athena)?[[:space:]]+api[[:space:]]" \
      && has '(^|[[:space:]])(-f|--field|--raw-field|--input)'; }; }; then
  deny 'forge-auth: this POSTs to an OAuth token endpoint (minting/refreshing a forge token), which is OWNER-GATED — the agent never mints forge credentials. Fix: do NOT run this. Report to the owner if a token is expired or missing; the owner provisions forge auth out of band.'
fi

# ---- 4: a WRITE to a known forge credential/config file --------------------
# The command names a gh/glab credential or config location AND carries a
# mutating operator. Locations: anything under ~/.config/gh or
# ~/.config/glab-cli or $XDG_CONFIG_HOME/gh|glab-cli (the dirs themselves
# included), or a `gh/` / `glab-cli/` hosts.yml / config.yml under any root.
# Operators: a redirect; an in-place edit (`sed`/`perl` with `-i`, anywhere in
# that command's flags, or `--in-place`); or a mutating tool (tee, rm, unlink,
# shred, mv, cp, install, ln, dd, truncate, an editor) invoked bare OR
# path-qualified (`/bin/rm`), after any separator. A plain read
# (cat/grep/less/ls, `sed -n`, `perl -ne`) does NOT match. The in-place check
# stops at | ; & so a later `grep -i` is not read as sed's flag. A redirect to
# /dev/null or an fd duplication (2>&1) does not write the file, so both are
# removed before the operator check.
WRITES=$(printf '%s' "$FLAT" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]##g')
if has '((\.config|XDG_CONFIG_HOME\}?)/(gh|glab-cli)(/|[[:space:]]|$)|(^|[^[:alnum:]_.-])(gh|glab-cli)/(hosts|config)\.yml)' \
  && printf '%s' "$WRITES" | grep -Eq "(>|${CMD_START}(tee|rm|unlink|shred|mv|cp|install|ln|dd|truncate|vim?|nvim|nano|emacs)[[:space:]]|${CMD_START}(sed|perl)[[:space:]]([^|;&]*[[:space:]])?(-[nprlaswWXtTcEuz]*i|--in-place))"; then
  deny 'forge-auth: this writes to a forge credential/config location (gh hosts.yml/config.yml, glab-cli config.yml, or the ~/.config/gh / ~/.config/glab-cli dir), which is OWNER-GATED — the agent never edits forge auth config. Fix: do NOT modify it. If the config is wrong, report to the owner, who provisions forge auth out of band. Reading the file (cat/grep/ls) is allowed.'
fi

# No auth-mutating construct detected -> allow silently.
exit 0
