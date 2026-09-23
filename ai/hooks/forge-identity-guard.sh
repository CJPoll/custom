#!/bin/sh
# PreToolUse forge-identity guard.
#
# Surfaces a bare `gh pr create` / `glab mr create` — a forge WRITE that stamps
# authorship — that bypasses the Athena wrapper (`gh-athena` / `glab-athena`).
# The DND-203 outage had two halves; this closes the second: a HEALTHY wrapper
# that a captain simply never called, so the MR was authored by the machine
# owner (`cjpoll`) with nothing in the output saying so. The failure mode is
# silence, and silence goes unnoticed for days.
#
# DND-389 adds a PUSH rule: a plain `git push` whose remote resolves to
# github.com (not through `gh-athena git`) goes out with the owner's SSH key or
# credential helper, so GitHub records the machine owner (CJPoll) as the actor.
# Measured 2026-09-23: every captain/admiral branch push on gen_saas showed
# actor=CJPoll. The remote is resolved the way git would (the command's own
# remote/URL argument, else branch.<cur>.pushRemote / remote.pushDefault /
# branch.<cur>.remote / origin) in the repo the push runs in (`-C <dir>`, else a
# preceding `cd <dir>`, else the hook's cwd). A push whose remote CANNOT be
# resolved still warns, naming that it could not tell — an unresolvable remote
# must not read as "not GitHub". A remote resolving elsewhere (GitLab, a local
# path) is allowed silently: glab-athena has no git passthrough, so there is no
# Athena push path to point a GitLab push at.
#
# SCOPE: this surfaces the authorship-ESTABLISHING write — `pr create` /
# `mr create` — AND the MERGE write the athena-admiral performs (`pr merge` /
# `mr merge`), which stamps the merge commit / merge event with an author. The
# admiral-500 design (ai/docs/admiral-500-design.md §2) strengthens the
# "attributed writes go through the wrapper" invariant by extending this guard
# from create to also cover merge. Other attributed writes (`pr comment`, `mr
# approve`, `api --method POST`) are still NOT matched here; they rely on the
# captain's wrapper discipline and the forge-preflight assertion. This is
# deliberate, not full write coverage — broadening the subcommand alternation
# further is a follow-up if a bare non-create/merge write is ever observed
# mis-attributing.
#
# WARN, NEVER BLOCK — deliberate (DND-206 scope 2). A hard block is how the
# OTHER half of the outage happened: an over-eager guard that refuses when the
# wrapper is legitimately unavailable strands the captain and recreates the
# outage with a new message. So this guard emits `additionalContext` (guidance
# the model sees) and ALWAYS allows the command. It is never itself the reason
# work stops.
#
# "Captain context" is approximated as any session: a warn is non-blocking and
# harmless, reliably detecting a subagent context from a Bash hook is not
# available, and missing the case is the costly failure — so it warns broadly.
#
# Design guarantees (mirror safe-wait-guard):
#   * FAIL-OPEN — any error (missing jq, unparseable input, non-Bash tool, no
#     match) exits 0 and ALLOWS silently. A bug here can never wedge Bash.
#   * NARROW    — only the wrapper-bypassing create commands match. The wrapper
#     path (`gh-athena pr create`, `glab-athena mr create`) is explicitly NOT
#     matched: `gh`/`glab` there is followed by `-`, not whitespace.
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

# warn <context> : emit non-blocking additionalContext and allow. Fail-open if
# jq cannot encode (which simply allows — consistent with the guarantee).
warn() {
  jq -cn --arg c "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' \
    2>/dev/null
  exit 0
}

# Bare `gh pr create`: the command word is `gh` (optionally path-prefixed, e.g.
# /usr/bin/gh) followed by whitespace then `pr create`, tolerating global flags
# BETWEEN the command word and the subcommand (`gh -R owner/repo pr create`,
# `gh --repo x pr create`). The optional `[^;|&]* ` segment cannot cross a
# command separator, so it stays within this one command. `gh-athena pr create`
# still does NOT match: after `gh` comes `-`, not whitespace.
if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+([^;|&]* )?pr[[:space:]]+create'; then
  warn 'forge-identity: this is a bare `gh pr create`, which attributes the PR to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: open it through the wrapper — `~/dev/custom/ai/bin/gh-athena pr create …` — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `gh`; writes (create/comment/review/merge) go through gh-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# Bare `gh pr merge`: the MERGE write the admiral performs. Same command-word
# shape and flag tolerance; `gh-athena pr merge` still does NOT match (after
# `gh` comes `-`, not whitespace).
if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+([^;|&]* )?pr[[:space:]]+merge'; then
  warn 'forge-identity: this is a bare `gh pr merge`, which stamps the merge to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: merge through the wrapper — `~/dev/custom/ai/bin/gh-athena pr merge …` — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `gh`; writes (create/comment/review/merge) go through gh-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# Bare `glab mr create`: same shape, same tolerance for flags before the
# subcommand (`glab -R x mr create`); `glab-athena mr create` does NOT match.
if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+([^;|&]* )?mr[[:space:]]+create'; then
  warn 'forge-identity: this is a bare `glab mr create`, which attributes the MR to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: open it through the wrapper — `~/dev/custom/ai/bin/glab-athena mr create …` — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `glab`; writes go through glab-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# Bare `glab mr merge`: the MERGE write the admiral performs. Same shape;
# `glab-athena mr merge` does NOT match.
if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+([^;|&]* )?mr[[:space:]]+merge'; then
  warn 'forge-identity: this is a bare `glab mr merge`, which stamps the merge to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: merge through the wrapper — `~/dev/custom/ai/bin/glab-athena mr merge …` — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `glab`; writes go through glab-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# ---- Plain `git push` to a github.com remote (DND-389) ----------------------
# Dequote (as forge-auth-guard does) so quoting cannot split the pattern, and
# mask the wrapper form `gh-athena git` first so it is never matched.
GFLAT=$(printf '%s' "$FLAT" | tr -d "'\"\\\\" | sed -E 's#gh-athena[[:space:]]+git([[:space:]])#GH_ATHENA_GIT\1#g')
# `git`, bare or path-qualified, then only GLOBAL options (-C/-c take a value),
# then `push`. `git commit -m "push"` does not match: `commit` is not an option.
GIT_PUSH_RE='(^|[[:space:];&|(/])git([[:space:]]+(-[Cc][[:space:]]+[^[:space:];&|]+|--?[^[:space:];&|]+))*[[:space:]]+push([[:space:]]|$|[;&|)])'

PUSH_FIX='Fix: push through the wrapper, which authenticates as athena-harness[bot] over HTTPS for that one command: `GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= -c url.https://github.com/.insteadOf=git@github.com: push …` (athena:github -> "Pushing as Athena"). If the wrapper refuses or fails, do not work around this; escalate to your admiral with the command + error and wait.'

# push_segment_default_dir: the repo dir the push runs in.
push_repo_dir() {
  _pre=$(printf '%s' "$GFLAT" | grep -Eo "$GIT_PUSH_RE" | head -n1)
  _c=$(printf '%s' "$_pre" | sed -nE 's#.*[[:space:]]-C[[:space:]]+([^[:space:];&|]+).*#\1#p')
  if [ -z "$_c" ]; then
    # Last `cd <dir>` BEFORE the git push.
    _before=$(printf '%s' "$GFLAT" | sed -E "s#${GIT_PUSH_RE}.*##")
    _c=$(printf '%s' "$_before" | grep -Eo '(^|[[:space:];&|(])cd[[:space:]]+[^[:space:];&|)]+' | tail -n1 | sed -E 's#.*cd[[:space:]]+##')
  fi
  [ -n "$_c" ] || _c=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  case "$_c" in "~"|"~/"*) _c="$HOME${_c#\~}" ;; "\$HOME"*) _c="$HOME${_c#\$HOME}" ;; esac
  printf '%s' "$_c"
}

if printf '%s' "$GFLAT" | grep -Eq "$GIT_PUSH_RE"; then
  # The push's own arguments: from `push` to the next separator.
  ARGS=$(printf '%s' "$GFLAT" | sed -E "s#^.*${GIT_PUSH_RE}##; s#^[[:space:]]*##; s#[;&|)].*##")
  # A github.com URL (any form) named literally on the push -> warn outright.
  case " $ARGS " in *github.com*)
    warn "forge-identity: this is a plain \`git push\` to github.com, which authenticates with the machine owner's SSH key or credential helper — GitHub records the push as CJPoll, not Athena. ${PUSH_FIX}" ;;
  esac
  # First positional (skipping options; -o/--push-option/--receive-pack/--exec/--repo take a value).
  TARGET=""; SKIP=0; PREV=""
  set -f   # word-split ARGS without globbing against the cwd
  for w in $ARGS; do
    if [ "$SKIP" = 1 ]; then SKIP=0; case "$PREV" in --repo) TARGET=$w; break ;; esac; continue; fi
    case "$w" in
      -o|--push-option|--receive-pack|--exec|--repo) SKIP=1; PREV=$w ;;
      --repo=*) TARGET=${w#--repo=}; break ;;
      -*) ;;
      *) TARGET=$w; break ;;
    esac
  done
  set +f
  DIR=$(push_repo_dir)
  URLS=""
  if [ -n "$DIR" ] && git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -z "$TARGET" ]; then
      CUR=$(git -C "$DIR" symbolic-ref -q --short HEAD 2>/dev/null)
      [ -n "$CUR" ] && TARGET=$(git -C "$DIR" config --get "branch.$CUR.pushRemote" 2>/dev/null)
      [ -n "$TARGET" ] || TARGET=$(git -C "$DIR" config --get remote.pushDefault 2>/dev/null)
      [ -n "$TARGET" ] || { [ -n "$CUR" ] && TARGET=$(git -C "$DIR" config --get "branch.$CUR.remote" 2>/dev/null); }
      [ -n "$TARGET" ] || TARGET=origin
    fi
    if git -C "$DIR" remote 2>/dev/null | grep -qxF -- "$TARGET"; then
      URLS=$(git -C "$DIR" remote get-url --push --all "$TARGET" 2>/dev/null)
    else
      URLS=$TARGET   # a URL literal (or a path)
    fi
  fi
  if [ -z "$URLS" ]; then
    warn "forge-identity: this is a plain \`git push\` and the guard could not resolve its remote (repo dir '${DIR:-unknown}', remote '${TARGET:-default}'), so it cannot tell whether it goes to github.com. If it does, it authenticates as the machine owner (CJPoll), not Athena. ${PUSH_FIX}"
  fi
  case "$URLS" in *github.com*)
    warn "forge-identity: this is a plain \`git push\` to a github.com remote ('${TARGET}' -> $(printf '%s' "$URLS" | head -n1)), which authenticates with the machine owner's SSH key or credential helper — GitHub records the push as CJPoll, not Athena. ${PUSH_FIX}" ;;
  esac
fi

# No bypass detected → allow silently.
exit 0
