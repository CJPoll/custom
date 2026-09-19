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
#   1. `gh auth <login|logout|refresh|token|setup-git>` (also gh-athena wrapper)
#   2. `glab auth <login|logout|refresh>` (also glab-athena wrapper)
#   3. A POST to an OAuth token endpoint (`gh api`, `glab api`, or `curl` hitting
#      `oauth/token` / `/oauth/access_token` with a POST verb).
#   4. A WRITE (redirect, tee, sed -i, rm/mv/cp/install, editor) targeting a
#      known forge credential/config file (gh hosts.yml/config.yml, glab-cli
#      config.yml, a *_TOKEN/credentials file under those config dirs).
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
FLAT=$(printf '%s' "$CMD" | tr '\n\t' '  ')

has() { printf '%s' "$FLAT" | grep -Eq "$1"; }

# deny <reason> : emit the PreToolUse deny decision and exit (fail-open if jq
# cannot encode, which would simply allow — consistent with the guarantee).
deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
    2>/dev/null
  exit 0
}

# ---- 1: gh auth <mutation> (bare or -athena wrapper) -----------------------
# `gh` or `gh-athena`, then `auth`, then a mutating subcommand. `gh auth status`
# is NOT matched (status is a read).
if has '(^|[^[:alnum:]_/-])gh(-athena)?[[:space:]]+auth[[:space:]]+(login|logout|refresh|token|setup-git)'; then
  deny 'forge-auth: this changes GitHub auth state (login/logout/refresh/token), which is OWNER-GATED — the agent never touches forge credentials. Fix: do NOT run this. If a forge write is failing on auth, STOP and report to the owner that gh auth needs attention; verify the identity wrapper with `~/dev/custom/ai/bin/forge-preflight` (reads only). Reading status is fine: `gh auth status`.'
fi

# ---- 2: glab auth <mutation> (bare or -athena wrapper) ---------------------
if has '(^|[^[:alnum:]_/-])glab(-athena)?[[:space:]]+auth[[:space:]]+(login|logout|refresh)'; then
  deny 'forge-auth: this changes GitLab auth state (login/logout/refresh), which is OWNER-GATED — the agent never touches forge credentials. Fix: do NOT run this. If a forge write is failing on auth, STOP and report to the owner that glab auth needs attention; verify the identity wrapper with `~/dev/custom/ai/bin/forge-preflight` (reads only). Reading status is fine: `glab auth status`.'
fi

# ---- 3: POST to an OAuth token endpoint ------------------------------------
# A request that mints/refreshes a token: an oauth token path together with an
# explicit POST verb (gh/glab `api --method POST`, curl `-X POST`/`--request
# POST`, or `-d`/`--data` which forces POST).
if has 'oauth/(token|access_token)' \
  && has '(--method[[:space:]]+POST|-X[[:space:]]+POST|--request[[:space:]]+POST|(^|[[:space:]])(-d|--data)([[:space:]]|=))'; then
  deny 'forge-auth: this POSTs to an OAuth token endpoint (minting/refreshing a forge token), which is OWNER-GATED — the agent never mints forge credentials. Fix: do NOT run this. Report to the owner if a token is expired or missing; the owner provisions forge auth out of band.'
fi

# ---- 4: a WRITE to a known forge credential/config file --------------------
# The command names a gh/glab credential or config file AND carries a mutating
# operator (redirect, tee, sed -i, rm/mv/cp/install, an editor). A plain read
# (cat/grep/less of the file) does NOT match.
if has '(\.config/(gh|glab-cli)/(hosts\.yml|config\.yml)|glab-cli/config\.yml|\.config/gh/hosts\.yml)' \
  && has '(>>?[[:space:]]*[^&|]|(^|[[:space:]|;&])(tee|rm|mv|cp|install|dd|truncate|vim?|nvim|nano|emacs)[[:space:]]|sed[[:space:]]+-i)'; then
  deny 'forge-auth: this writes to a forge credential/config file (gh hosts.yml/config.yml or glab-cli config.yml), which is OWNER-GATED — the agent never edits forge auth config. Fix: do NOT modify it. If the config is wrong, report to the owner, who provisions forge auth out of band. Reading the file (cat/grep) is allowed.'
fi

# No auth-mutating construct detected -> allow silently.
exit 0
