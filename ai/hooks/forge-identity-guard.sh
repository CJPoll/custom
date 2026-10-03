#!/bin/sh
# PreToolUse forge-identity guard.
#
# Denies every forge WRITE run on plain `gh` / `glab` (see SCOPE) — a write
# that stamps authorship yet bypasses the Athena wrapper (`gh-athena` /
# `glab-athena`).
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
# resolved is still denied, naming that it could not tell — an unresolvable remote
# must not read as "not GitHub". DND-393 extends the rule to gitlab.com: a plain
# push there goes out on the owner's SSH key and GitLab records the owner, and
# `glab-athena git` is now the Athena path to point it at. A remote resolving
# elsewhere (a local path, another host) is allowed silently.
#
# SCOPE: EVERY forge write run on plain `gh` / `glab` (DND-1179). Create and
# merge, and the `gh api` / `glab api` merge and ref-write shapes (DND-728,
# DND-741, DND-742), keep their own blocks and Fix text, because a merge or a
# ref write also skips a safety check, not only attribution. Every other write
# (close, edit, comment, review, label, release, secret, variable, repo, api
# POST, …) is denied by the positive model in the last gh/glab block: a READ
# allowlist per command group, any other verb denied. Plain `git push` to a
# forge remote has its own block (DND-389/393).
# Later (2026-09-29, DND-1179): this paragraph said only create and merge were
# matched, and that `pr comment`, `mr approve` and `api --method POST` relied on
# wrapper discipline, "a follow-up if a bare non-create/merge write is ever
# observed mis-attributing". It was observed: a plain `gh pr close 119 -R
# CJPoll/custom` ran and GitHub recorded the close as CJPoll.
#
# DENY, WITH A Fix: — DND-577 (2026-09-24). This guard used to WARN and always
# allow (DND-206 scope 2). A PreToolUse `additionalContext` reaches the model
# together with the tool RESULT, so the warning arrived after the write had
# already gone out as the owner: measured 2026-09-24, a captain's plain push of
# `hyprpaper-08-syntax` (CJPoll/custom PR #76, 97f3793) and an admiral's first
# push of PR #77's branch were both recorded as CJPoll, each agent reporting the
# warning only after the push. Detection without prevention.
# DND-206 feared a block would strand a captain whose wrapper is legitimately
# unavailable. The warn never offered that captain a legitimate path either: it
# already said "do not work around this; escalate and wait". So a deny removes
# only the illegitimate path (the owner-attributed write) and changes no
# legitimate outcome. Every match now returns permissionDecision "deny" with the
# same Fix:, which stops the command BEFORE it runs.
#
# SCOPE: every Claude Code session (like forge-auth-guard). Hooks fire only on
# Claude Code tool calls, so the owner's own terminal is never touched: a push
# typed in an interactive shell outside Claude Code keeps working. A coordinator
# session is Athena too, and its writes go through the wrapper as well.
#
# ACCEPTED FALSE POSITIVE (the DND-390 class forge-auth-guard documents, and
# DND-397 below): matching is lexical, so a command that only MENTIONS a bare
# write (a heredoc body, a `git commit -m`, a grep) is denied too. Rephrasing
# costs one retry (write the text with the Write tool, pass it with
# `git commit -F` / `grep -f`); a miss costs an owner-attributed write. The deny
# reason says so. Tracked for reduction in DND-547.
#
# Design guarantees (mirror safe-wait-guard):
#   * FAIL-OPEN — any error (missing jq, unparseable input, non-Bash tool, no
#     match) exits 0 and ALLOWS silently. A bug here can never wedge Bash.
#     A deny is only ever emitted for a positive match.
#   * WRAPPER   — only plain gh/glab and plain git push match. The wrapper
#     path (`gh-athena pr close`, `glab-athena mr note`) is never matched: the
#     create/merge/api patterns need whitespace after `gh`/`glab` (the wrapper
#     has `-`), and the DND-1179 rule needs the command word, path stripped, to
#     be exactly `gh` or `glab`.
#     Later (2026-09-29, DND-1179): this bullet was NARROW, "only the
#     wrapper-bypassing create commands match". Every plain write matches now.
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

# Join backslash-newline continuations FIRST, as the shell does before it runs
# anything (DND-1179): every rule below reads CMD, and one that turned the
# newline into a separator judged `gh api … \⏎ -f x` or `git -C r \⏎ push` as
# two commands, neither of them a write. Inside single quotes the pair is
# literal, so joining there over-reads: the safe direction for a deny rule.
CMD=$(printf '%s\n' "$CMD" | awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }')

# Flatten to one logical line so a command split across newlines still matches.
FLAT=$(printf '%s' "$CMD" | tr '\n\t' '  ')

# Appended to every deny reason: how to proceed when the command only MENTIONS
# a bare write instead of performing one (the accepted false positive above).
MENTION_NOTE=' If this command only MENTIONS that text (a heredoc, a commit message, a grep) and performs no such write, move the text into a file with the Write tool and pass the file (`git commit -F <file>`, `grep -f <file>`); never rephrase a real write to slip past this guard.'

# deny <reason> : stop the command BEFORE it runs (DND-577). A PreToolUse
# `additionalContext` only reaches the model with the tool result, after the
# write. Fail-open if jq cannot encode (which simply allows — consistent with
# the guarantee).
deny() {
  jq -cn --arg r "$1$MENTION_NOTE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
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
  deny 'forge-identity: this is a bare `gh pr create`, which attributes the PR to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: open it through the wrapper — `~/dev/custom/ai/bin/gh-athena pr create …` — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `gh`; writes (create/comment/review/merge) go through gh-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# Bare `gh pr merge`: the MERGE write the admiral performs. Same command-word
# shape and flag tolerance; `gh-athena pr merge` still does NOT match (after
# `gh` comes `-`, not whitespace).
if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+([^;|&]* )?pr[[:space:]]+merge'; then
  deny 'forge-identity: this is a bare `gh pr merge`, which stamps the merge to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: merge through the one guarded path — run `~/dev/custom/ai/skills/athena:merge-boarding/scripts/integration-gate` from the worktree of the PR, then `~/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr <n> --head <sha>` with the SHA its INTEGRATION OK line names (it makes the pinned `gh-athena pr merge` call under the merge lock; athena:merge-boarding -> "Landing onto a moving main") — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `gh`; writes (create/comment/review/merge) go through gh-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# Bare `gh api` that merges (DND-728): the REST merge routes (…/pulls/<n>/merge,
# …/merges, …/merge-upstream) or a GraphQL merge mutation, in the same command
# segment as `gh … api`. It runs as the owner AND skips the wrapper's merge
# guard. `gh-athena api …` does NOT match (after `gh` comes `-`); the wrapper
# judges those itself, with the full argv and any query file. Lexical, so a
# query read from a file (`-F query=@f`, `--input f`) or a %-encoded route is
# not seen here (the named residual); a plain-gh READ of a merge route is denied
# too, and its Fix names the read that does not need it.
if printf '%s' "$FLAT" | grep -Eiq '(^|[^[:alnum:]_-])gh[[:space:]]+([^;|&]* )?api[[:space:]][^;|&]*(pulls/[^[:space:];|&]+/merge([^[:alnum:]_-]|$)|/merges([^[:alnum:]_-]|$)|/merge-upstream|(^|[^[:alnum:]_])(mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest|mergeBranch)([^[:alnum:]_]|$))'; then
  deny 'forge-identity: this is a bare `gh api` call on a merge route or with a merge mutation (REST …/pulls/<n>/merge, …/merges, …/merge-upstream; GraphQL mergePullRequest / enablePullRequestAutoMerge / enqueuePullRequest / mergeBranch). It merges as the machine owner AND skips the pinned-head, all-green merge guard (DND-609, DND-728). Fix: merge through the one guarded path — once every check on the head is green, run `~/dev/custom/ai/skills/athena:merge-boarding/scripts/integration-gate` from the worktree of the PR, then `~/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr <n> --head <sha>` with the SHA its INTEGRATION OK line names (it makes the pinned `gh-athena pr merge` call under the merge lock; athena:merge-boarding -> "Landing onto a moving main"). To only READ merge state, use `gh pr view <n> --json mergedAt,state`. If the wrapper refuses, do not work around it; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# Bare `gh api` that creates or moves a ref (DND-741): a REST write to
# …/git/refs[/…] or …/git/ref/… (not a plain DELETE), any write to
# …/contents/…, …/branches/<b>/rename, …/pulls/<n>/update-branch, or a GraphQL
# ref-write mutation, in one command segment of `gh … api`. It runs as the
# owner AND puts commits on a branch with no pinned head and no green check.
# The wrapper refuses the same set (ai/lib/gh-merge-guard.sh, which also records
# why EVERY ref write is refused, not only one aimed at the default branch).
# Lexical and best-effort, like the merge rule above: a REST call is a write
# when it names -X/--method other than GET/HEAD, carries a method-override
# header, or has no method but a field or --input (gh then POSTs). A query read
# from a file, a %-encoded route and an aliased flag are not seen here; the
# wrapper sees them. `gh-athena api …` does NOT match (after `gh` comes `-`).
REF_MUT_RE='(^|[^[:alnum:]_])(createCommitOnBranch|createRef|updateRefs?|createLinkedBranch|revertPullRequest|updatePullRequestBranch)([^[:alnum:]_]|$)'
REF_ROUTE_RE='(repos/[^/[:space:]]+/[^/[:space:]]+|repositories/[^/[:space:]]+)/(git/refs?([/.?[:space:]'"'"'"]|$)|contents/|branches/[^[:space:]]+/rename([^[:alnum:]_-]|$)|pulls/[^/[:space:]]+/update-branch([^[:alnum:]_-]|$))'
GIT_REF_RE='(repos/[^/[:space:]]+/[^/[:space:]]+|repositories/[^/[:space:]]+)/git/refs?([/.?[:space:]'"'"'"]|$)'
REF_DENY='forge-identity: this is a bare `gh api` call that creates or moves a ref (REST …/git/refs, …/contents/…, …/branches/<b>/rename or …/pulls/<n>/update-branch; GraphQL createCommitOnBranch / createRef / updateRef / updateRefs / createLinkedBranch / revertPullRequest / updatePullRequestBranch). It runs as the machine owner AND can put commits on the default branch with no pinned head and no green check (DND-741). Fix: commit locally and move a branch only with `~/dev/custom/ai/bin/gh-athena git push origin <feature-branch>` (athena:github -> "Pushing as Athena"); land on the default branch only through a PR: once every check on its head is green, run `~/dev/custom/ai/skills/athena:merge-boarding/scripts/integration-gate` from the worktree of the PR, then `~/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr <n> --head <sha>` with the SHA its INTEGRATION OK line names (it makes the pinned `gh-athena pr merge` call under the merge lock; athena:merge-boarding -> "Landing onto a moving main"). To delete a branch, `gh-athena git push origin --delete <branch>`. If the wrapper refuses, do not work around it; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'

# api_ref_write <segment> : true when one `gh … api` command segment writes a ref.
api_ref_write() {
  _s=$1
  printf '%s' "$_s" | grep -Eq "$REF_MUT_RE" && return 0
  printf '%s' "$_s" | grep -Eiq "$REF_ROUTE_RE" || return 1
  printf '%s' "$_s" | grep -Eiq 'x-(http-)?method(-override)?[[:space:]]*:' && return 0
  _m=$(printf '%s' "$_s" | sed -nE "s/(^|.*[[:space:]])(-[[:alpha:]]*X|--method)(=|[[:space:]]+)?[\"']?([[:alpha:]]+).*/\4/p" | tr '[:lower:]' '[:upper:]')
  case "$_m" in
    GET|HEAD) return 1 ;;
    DELETE) printf '%s' "$_s" | grep -Eiq "$GIT_REF_RE" && return 1; return 0 ;;
    ?*) return 0 ;;
  esac
  printf '%s' "$_s" | grep -Eq '(^|[[:space:]])(-[[:alpha:]]*[fF]|--(raw-)?field|--input)' && return 0
  return 1
}

API_SEGS=$(printf '%s' "$FLAT" | tr ';&|' '\n\n\n' | grep -E '(^|[^[:alnum:]_-])gh[[:space:]]+(.* )?api[[:space:]]')
if [ -n "$API_SEGS" ]; then
  _hit=$(printf '%s\n' "$API_SEGS" | while IFS= read -r _seg; do
    if api_ref_write "$_seg"; then echo hit; break; fi
  done)
  [ -z "$_hit" ] || deny "$REF_DENY"
fi

# Bare `glab mr create`: same shape, same tolerance for flags before the
# subcommand (`glab -R x mr create`); `glab-athena mr create` does NOT match.
if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+([^;|&]* )?mr[[:space:]]+create'; then
  deny 'forge-identity: this is a bare `glab mr create`, which attributes the MR to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: open it through the wrapper — `~/dev/custom/ai/bin/glab-athena mr create …` — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `glab`; writes go through glab-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# Bare `glab mr merge` (or its alias `glab mr accept`, DND-742): the MERGE write
# the admiral performs. It runs as the owner AND skips glab-athena's merge guard
# (pinned head, passed head pipeline). Same shape; `glab-athena mr merge` does
# NOT match.
if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+([^;|&]* )?mr[[:space:]]+(merge|accept)'; then
  deny 'forge-identity: this is a bare `glab mr merge` / `glab mr accept`, which stamps the merge to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent — AND skips the pinned-head, passed-pipeline merge guard (DND-742). Fix: board the merge train through the wrapper — `~/dev/custom/ai/bin/glab-athena api -X POST "projects/:id/merge_trains/merge_requests/<iid>" -f sha=<head sha>` — or, with no train, `~/dev/custom/ai/bin/glab-athena mr merge <iid> --sha <head sha> --yes`, once the head pipeline passed on that head, after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `glab`; writes go through glab-athena. If the wrapper refuses or fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# Bare `glab api` that merges (DND-742): the REST merge route
# (…/merge_requests/<iid>/merge), a merge-train car (…/merge_trains/
# merge_requests/<iid>), or the GraphQL mergeRequestAccept, in the same command
# segment as `glab … api`. It runs as the owner AND skips glab-athena's merge
# guard. `glab-athena api …` does NOT match (after `glab` comes `-`); the wrapper
# judges those itself. Lexical, so a query read from a file or a %-encoded route
# is not seen here (the wrapper sees both). A plain-glab READ of a train car is
# denied too; its Fix names the reads that do not need it. `…/merge_ref` and
# `…/merge_trains?scope=…` do not match.
if printf '%s' "$FLAT" | grep -Eiq '(^|[^[:alnum:]_-])glab[[:space:]]+([^;|&]* )?api[[:space:]][^;|&]*(merge_requests/[^[:space:];|&/]+/merge([^[:alnum:]_-]|$)|merge_trains/merge_requests|(^|[^[:alnum:]_])mergeRequestAccept([^[:alnum:]_]|$))'; then
  deny 'forge-identity: this is a bare `glab api` call on a merge route, a merge-train car, or with the merge mutation (REST …/merge_requests/<iid>/merge; …/merge_trains/merge_requests/<iid>; GraphQL mergeRequestAccept). It merges as the machine owner AND skips the pinned-head, passed-pipeline merge guard (DND-742). Fix: board through the one guarded path — `~/dev/custom/ai/bin/glab-athena api -X POST "projects/:id/merge_trains/merge_requests/<iid>" -f sha=<head sha>` once the head pipeline passed on that head (or `~/dev/custom/ai/bin/glab-athena mr merge <iid> --sha <head sha> --yes` where there is no train). To only READ merge state, use `glab mr view <iid> -F json` or `glab api "projects/:id/merge_trains?scope=active"`. If the wrapper refuses, do not work around it; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
fi

# ---- Plain `git push` to a github.com remote (DND-389) ----------------------
# DND-397: a push that is only MENTIONED (a heredoc body, `grep -n "git push"`,
# `echo 'git push'`) is still denied. That is deliberate: masking such text was
# built and reviewed over three critic rounds, and each round found a real push
# the mask hid (`$SHELL -c "…"`, `git rebase --exec "…"`, `cat <<EOF | perl`,
# `git grep -O"…"`, an `echo '…' > .git/hooks/post-commit` that the next `git
# commit` runs). A lexical guard cannot prove quoted text inert, and this guard
# must never miss a real push, so a mention costs a deny (one retry) instead.
# The parked design is on branch dnd-397-mention-masking-parked.

# bless_wrapper_var: the ONE shape in which `$W git …` is provably the Athena
# wrapper (DND-397, the coordinator's `W=~/…/glab-athena; "$W" git push` probe):
#   * the command's FIRST statement, at top level, is `[export ]W=<path>` whose
#     value is bare or wholly double-quoted and ends in /gh-athena or
#     /glab-athena (optionally from ~, $HOME or ${HOME}) — the same path trust
#     the literal `gh-athena git` rewrite below has always given;
#   * it is ended directly by `;`, `&&` or a newline;
#   * the VERY NEXT statement's command word — after simple `NAME=val` prefixes —
#     is `$W`, `"$W"`, `${W}` or `"${W}"`, followed by `git`.
# Whitespace INSIDE a statement is matched as [ \t] only: a newline ends a
# statement, so `W=…⏎W=/usr/bin/env⏎"$W" git push` (a reassignment, not a
# prefix) and `"$W"⏎git push` (the wrapper alone, then a plain push) are never
# read as one statement. A newline is accepted only as the separator itself
# and as blank lines around it.
# Only that one use is rewritten to the wrapper form. A first statement always
# runs in the shell the next statement runs in, so W is set there; nothing sits
# between them to unset, shadow or re-scope it. Every other shape — a use later
# in the command, inside `( … )`, `bash -c '…'` or a heredoc, an assignment in
# argument, prefix or pipeline position — is left alone and is denied, as it was warned
# about before DND-397. Reads the raw command (before dequoting).
bless_wrapper_var() {
  awk '
    { src = src (NR > 1 ? "\n" : "") $0 }
    END {
      s = src
      VAL = "(~|[$]HOME|[$][{]HOME[}])?([A-Za-z0-9._-]*/)*(gh|glab)-athena"
      if (!match(s, "^[[:space:]]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=")) { printf "%s", s; exit }
      head = substr(s, 1, RLENGTH); rest = substr(s, RLENGTH + 1)
      name = head; sub(/=$/, "", name); sub(/^[[:space:]]*(export[ \t]+)?/, "", name)
      q = ""; if (substr(rest, 1, 1) == "\"") q = "\""
      if (!match(rest, "^" q VAL q "[ \t]*(;|&&|\n)[[:space:]]*")) { printf "%s", s; exit }
      head = head substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
      if (match(rest, "^([A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9._/:=-]*[ \t]+)+")) {
        head = head substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
      }
      if (!match(rest, "^(\"[$]" name "\"|\"[$][{]" name "[}]\"|[$]" name "|[$][{]" name "[}])[ \t]+git[ \t]")) { printf "%s", s; exit }
      printf "%s", head "FORGE_ATHENA_GIT " substr(rest, RLENGTH + 1)
    }'
}

# Dequote (as forge-auth-guard does) so quoting cannot split the pattern, and
# mask the wrapper forms `gh-athena git` / `glab-athena git` first so they are
# never matched. DND-397: bless_wrapper_var first rewrites the one provable
# `W=<wrapper>; "$W" git …` shape to the wrapper form.
# Newlines become `;` here (not spaces, as in FLAT): a push's arguments end at
# the end of its line, so `git push<NL>echo done` never reads `echo` as a remote.
GFLAT=$(printf '%s' "$CMD" | bless_wrapper_var | tr '\n\t' '; ' | tr -d "'\"\\\\" | sed -E 's#(gh|glab)-athena[[:space:]]+git([[:space:]])#FORGE_ATHENA_GIT\2#g')
# `git`, bare or path-qualified, then only GLOBAL options (-C/-c take a value),
# then `push`. `git commit -m "push"` does not match: `commit` is not an option.
GIT_PUSH_RE='(^|[[:space:];&|(/])git([[:space:]]+(-[Cc][[:space:]]+[^[:space:];&|]+|--?[^[:space:];&|]+))*[[:space:]]+push([[:space:]]|$|[;&|)])'

PUSH_FIX='Fix: push through the wrapper, which authenticates as athena-harness[bot] over HTTPS for that one command: `GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= -c url.https://github.com/.insteadOf=git@github.com: push …` (athena:github -> "Pushing as Athena"). If the wrapper refuses or fails, do not work around this; escalate to your admiral with the command + error and wait.'
GITLAB_PUSH_FIX='Fix: push through the wrapper, which authenticates as athena-amby over HTTPS for that one command: `GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/glab-athena git push …` (athena:gitlab -> "Pushing as Athena"). If the wrapper refuses or fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'"'"'t be done as Athena").'

# forge_of_url <url> : prints "github" / "gitlab" when the URL's HOST is
# github.com / gitlab.com (or a subdomain); prints nothing otherwise. A local
# path that merely contains "github.com" (a Go-workspace path) is neither.
forge_of_url() {
  _u=$1
  case "$_u" in
    /*|./*|../*|\~*|file://*) return 0 ;;
    *://*) _h=${_u#*://}; _h=${_h%%/*}; _h=${_h##*@}; _h=${_h%%:*} ;;
    *:*) _h=${_u%%:*}; case "$_h" in */*) return 0 ;; esac; _h=${_h##*@} ;;
    *) return 0 ;;
  esac
  _h=$(printf '%s' "$_h" | tr 'A-Z' 'a-z')
  case "$_h" in
    github.com|*.github.com) printf github ;;
    gitlab.com|*.gitlab.com) printf gitlab ;;
  esac
  return 0
}

# looks_like_url_or_path <word> : a URL (scheme://, scp-style host:path) or a
# filesystem path — something git would use as a repository without a remote.
# A bare word that is not a configured remote is NEITHER: it is unresolved.
looks_like_url_or_path() {
  case "$1" in
    */*|*:*|.|..|\~*) return 0 ;;
  esac
  return 1
}

# Split GFLAT at the FIRST push match (gawk/mawk leftmost match), so the repo
# dir and the push arguments always come from the same push.
split_first_push() {
  printf '%s' "$GFLAT" | awk -v re="$GIT_PUSH_RE" -v part="$1" '{
    if (!match($0, re)) exit
    m = substr($0, RSTART, RLENGTH)
    if (part == "before") { print substr($0, 1, RSTART - 1); exit }
    if (part == "match")  { print m; exit }
    rest = substr($0, RSTART + RLENGTH)
    if (m ~ /[;&|)]$/) rest = ";" rest     # the boundary ate a separator
    print rest
  }'
}

# push_repo_dir: the repo dir the push runs in — `-C <dir>`, else the last
# `cd <dir>` before the push, else the hook input cwd. Relative paths resolve
# against the input cwd (where the command actually runs), not the hook's dir.
push_repo_dir() {
  _base=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  _c=$(split_first_push match | sed -nE 's#.*[[:space:]]-C[[:space:]]+([^[:space:];&|]+).*#\1#p')
  if [ -z "$_c" ]; then
    _c=$(split_first_push before | grep -Eo '(^|[[:space:];&|(])cd[[:space:]]+[^[:space:];&|)]+' | tail -n1 | sed -E 's#.*cd[[:space:]]+##')
  fi
  [ -n "$_c" ] || _c=$_base
  case "$_c" in "~"|"~/"*) _c="$HOME${_c#\~}" ;; "\$HOME"*) _c="$HOME${_c#\$HOME}" ;; esac
  case "$_c" in /*|'') ;; *) [ -n "$_base" ] && _c="$_base/$_c" ;; esac
  printf '%s' "$_c"
}

# Examine EVERY push in the command, one at a time: after each, GFLAT becomes
# the text after it (bounded, so a pathological command cannot loop). Every
# push's reason is collected (a GitLab push must not hide a later GitHub one)
# and they are emitted together after the loop.
WARNINGS=""
add_warning() {
  case "$WARNINGS" in *"$1"*) return 0 ;; esac
  if [ -n "$WARNINGS" ]; then WARNINGS="$WARNINGS
$1"; else WARNINGS=$1; fi
}
N=0
while [ "$N" -lt 10 ] && printf '%s' "$GFLAT" | grep -Eq "$GIT_PUSH_RE"; do
  N=$((N + 1))
  # The push's own arguments: from `push` to the next separator.
  AFTER=$(split_first_push after)
  ARGS=$(printf '%s' "$AFTER" | sed -E 's#^[[:space:]]*##; s#[;&|)].*##')
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
    elif looks_like_url_or_path "$TARGET"; then
      URLS=$TARGET   # a URL literal or a path, classified by host below
    fi               # else: neither a remote nor a URL -> unresolved (denied below)
  elif [ -n "$TARGET" ] && [ -n "$(forge_of_url "$TARGET")" ]; then
    URLS=$TARGET     # a literal forge URL needs no repo to classify
  fi
  if [ -z "$URLS" ]; then
    add_warning "forge-identity: this is a plain \`git push\` and the guard could not resolve its remote (repo dir '${DIR:-unknown}', remote '${TARGET:-default}'), so it cannot tell whether it goes to github.com or gitlab.com. If it does, it authenticates as the machine owner (CJPoll), not Athena. GitHub: ${PUSH_FIX} GitLab: ${GITLAB_PUSH_FIX} If it genuinely goes elsewhere (a local path), re-run it with the repo as a literal \`git -C <absolute dir>\` and a configured remote or a literal URL, so the guard can resolve it."
  fi
  set -f
  for u in $URLS; do
    case "$(forge_of_url "$u")" in
      github)
        add_warning "forge-identity: this is a plain \`git push\` to a github.com remote ('${TARGET}' -> ${u}), which authenticates with the machine owner's SSH key or credential helper — GitHub records the push as CJPoll, not Athena. ${PUSH_FIX}" ;;
      gitlab)
        add_warning "forge-identity: this is a plain \`git push\` to a gitlab.com remote ('${TARGET}' -> ${u}), which authenticates with the machine owner's SSH key or credential helper — GitLab records the push as the owner, not athena-amby. ${GITLAB_PUSH_FIX}" ;;
    esac
  done
  set +f
  GFLAT=$AFTER
done

[ -z "$WARNINGS" ] || deny "$WARNINGS"

# ---- Every other plain gh/glab WRITE (DND-1179) ------------------------------
# 2026-09-29 00:11Z an admiral ran a plain `gh pr close 119 -R CJPoll/custom`
# (output redirected). Before this rule the guard covered only create/merge,
# the api merge/ref routes and plain push, so it ran, and GitHub recorded the
# close as CJPoll. This rule closes the class with a POSITIVE model, chosen
# over a longer deny-list because a deny-list misses the next verb the CLI
# ships: for each known command group, a READ allowlist (RD, in the shared
# classifier named below); any other
# verb of that group is a write and is denied. `api` is judged by its method (below). The specific rules above run
# first, so a create, a merge or a ref write keeps its own Fix.
#   * Known groups: every group and group alias of gh 2.96 / glab 1.112. A group
#     with a write verb has a READ allowlist (RD); one that cannot write to the
#     forge (help, config, search, …; and `auth`, forge-auth-guard's domain) is
#     ALLOWED whole (AGS). Verb aliases (`ls`, `co`, `show`) are in RD too.
#     `gh copilot`, `glab duo cli` and `glab mcp serve` start an agent or a
#     server that can write as the owner, so they are denied. The self-test
#     (K1, K2) reads the installed CLIs and fails on any group, or gh group
#     alias, that is in neither list, so a CLI upgrade turns it red instead of
#     failing open. glab does not list its group aliases; those (var, project,
#     pipe, pipeline, stacks, sched, skd) are kept by hand.
#   * A word after `gh`/`glab` that is no known group is ALLOWED: it is prose
#     (`the gh CLI`), an alias or an extension. The named residual: an alias or
#     an extension that performs a write. `gh alias set` / `import` and `glab
#     alias set` are denied for that reason.
#   * `api`: a write when it names -X/--method other than GET/HEAD, carries a
#     method-override header, or has no method but a field, --form or --input
#     (gh and glab then POST). A `graphql` call is a write when the command has
#     the word `mutation` anywhere, or its query is one this guard cannot read:
#     from a file (`=@f`, --input) or built by expansion (`query=$Q`, `$(…)`,
#     backticks).
#   * Help (`gh pr close --help`) is allowed: --help/-h right after the group or
#     the verb. The words are matched after dequoting, so `"gh" pr close` counts.
#     A backtick becomes a `$` word, so a verb built by one is an unknown verb.
#   * Known false denies (reads, one retry through the wrapper): `gh issue
#     develop --list`, `gh codespace ssh|code|cp`, a read flag placed between
#     the group and the verb that takes a value this guard does not know.
#   * Two passes, and a write found by either denies. Pass A drops every quote
#     and splits on every separator, so a command inside any string (a
#     `sh -c` payload, a quoted `$(…)`) is judged. Pass B splits the way the
#     shell does, so a separator inside quotes (`--jq '.a | b' -f x=y`) cannot
#     cut a command in two; it re-splits any word that holds a command.
# Lexical, like every rule here: a command that only MENTIONS a write is denied
# (the accepted false positive above), and a command word built by expansion
# (`$G pr close`) is not seen.
# The classifier (the AG/RD tables, api_write, judge) is shared with the agent
# PATH wrappers ai/agent-bin/gh and ai/agent-bin/glab (DND-1803), which judge
# the real argv: ai/lib/forge-write-class.awk. Its text goes in front of this
# hook's own lexical driver. If it cannot be read, awk fails on the call to
# fwc_init, FORGE_WRITE is empty and this rule allows, per FAIL-OPEN above;
# the PATH wrappers still refuse the write when it runs.
FWC_LIB="$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")")/../lib/forge-write-class.awk"
FWC_TEXT=$(cat "$FWC_LIB" 2>/dev/null) || FWC_TEXT=""
[ -n "$FWC_TEXT" ] || printf 'forge-identity: cannot read %s, so the plain gh/glab write rule (DND-1179) is not checked here. Fix: restore ai/lib/forge-write-class.awk beside ai/hooks.\n' "$FWC_LIB" >&2
FORGE_WRITE=$(printf '%s\n' "$CMD" | awk "$FWC_TEXT"'
  BEGIN { fwc_init() }
  # judge_words(w, nw): judge every gh/glab word of one command segment.
  function judge_words(w, nw,    i, b) {
    n = nw
    for (i = 1; i <= nw; i++) t[i] = w[i]
    for (i = nw + 1; i in t; i++) delete t[i]
    for (i = 1; i <= n; i++) { b = t[i]; sub(/.*\//, "", b); if (b == "gh" || b == "glab") judge(i) }
  }
  # PASS B: split `s` the way the shell does. Quotes and backslashes group a
  # word, so a separator INSIDE quotes is data (`--jq ".a | b" -f x=y` stays
  # one command); outside them, newline ; & | ( ) and a backtick end the
  # command. A word that itself holds a command (the payload of a `sh -c` string,
  # a quoted `$(…)`) is split again, to depth 4.
  function shell_split(s, depth,    L, p, c, cur, has, w, nw, sub_w, nsub, k, q, lit) {
    L = length(s); p = 1; cur = ""; has = 0; nw = 0; nsub = 0
    while (p <= L + 1) {
      c = (p <= L) ? substr(s, p, 1) : "\n"
      if (c == "\\" && p < L) { cur = cur substr(s, p + 1, 1); has = 1; p += 2; continue }
      if (c == Q) {
        # Single-quoted text is literal: its `$` expands nothing, so it is
        # masked (\034) and a GraphQL `query($o: …)` literal stays readable.
        q = index(substr(s, p + 1), Q)
        lit = (q == 0) ? substr(s, p + 1) : substr(s, p + 1, q - 1)
        gsub(/[$]/, "\034", lit)
        cur = cur lit; has = 1; p = (q == 0) ? L + 1 : p + q + 1; continue
      }
      if (c == "\"") {
        p++
        while (p <= L && substr(s, p, 1) != "\"") {
          if (substr(s, p, 1) == "\\" && p < L) { cur = cur substr(s, p + 1, 1); p += 2; continue }
          cur = cur substr(s, p, 1); p++
        }
        p++; has = 1; continue
      }
      if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "`") {
        if (has) { w[++nw] = cur; if (cur ~ /[ \t\n;&|()`$]/) sub_w[++nsub] = cur }
        cur = ""; has = 0
        if (c != " " && c != "\t") { judge_words(w, nw); nw = 0 }
        p++; continue
      }
      cur = cur c; has = 1; p++
    }
    if (depth < 4) for (k = 1; k <= nsub; k++) shell_split(sub_w[k], depth + 1)
  }
  { buf = buf (NR > 1 ? "\n" : "") $0 }
  END {
    Q = sprintf("%c", 39)
    # PASS A: every quote and backslash dropped, then split on every
    # separator. It over-reads (a command inside any quoted string is judged),
    # which catches a payload that pass B leaves in one word.
    s = ""
    for (p = 1; p <= length(buf); p++) {
      c = substr(buf, p, 1)
      if (c == Q || c == "\"" || c == "\\") continue
      if (c == "\n") c = ";"; else if (c == "\t") c = " "
      s = s c
    }
    MUT = (tolower(s) ~ /(^|[^a-z0-9_])mutation([^a-z0-9_]|$)/)
    # A backtick opens or closes a substitution: it becomes a `$` word, so a
    # verb built by one (gh pr `printf close`) reads as `$` (an unknown verb:
    # denied) and a command inside one is still split into its own words.
    # Braces are NOT separators: `repos/{owner}/{repo}` is one word.
    gsub(/`/, "$ ", s)
    gsub(/[;&|()]/, "\n", s)
    nseg = split(s, seg, "\n")
    for (q = 1; q <= nseg; q++) {
      n = split(seg[q], t, " ")
      for (i = 1; i <= n; i++) { b = t[i]; sub(/.*\//, "", b); if (b == "gh" || b == "glab") judge(i) }
    }
    shell_split(buf, 0)
  }' 2>/dev/null)
if [ -n "$FORGE_WRITE" ]; then
  _cli=$(printf '%s' "$FORGE_WRITE" | cut -f1)
  _grp=$(printf '%s' "$FORGE_WRITE" | cut -f2)
  _verb=$(printf '%s' "$FORGE_WRITE" | cut -f3)
  _reads=$(printf '%s' "$FORGE_WRITE" | cut -f4 | sed -E 's/^\|//; s/\|$//; s/\|/, /g')
  [ -n "$_reads" ] || _reads='none; it runs an agent or a server that can write as the owner'
  if [ "$_cli" = gh ]; then _who='GitHub records it as the machine owner (CJPoll), not athena-harness[bot]'
  else _who='GitLab records it as the machine owner, not athena-amby'; fi
  _esc='If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'"'"'t be done as Athena").'
  if [ "$_grp" = api ]; then
    deny "forge-identity: this is a plain \`$_cli api\` call that WRITES: a method other than GET/HEAD, a field or --input with no \`-X GET\` (the CLI then POSTs), a method-override header, or a GraphQL mutation or query read from a file. $_who: the silent mis-attribution DND-203 exists to prevent (DND-1179). Fix: run the same call through the wrapper, \`~/dev/custom/ai/bin/$_cli-athena api …\` (check it with \`~/dev/custom/ai/bin/forge-preflight\` if it fails). To only READ, pass \`-X GET\` with the fields, or drop them. $_esc"
  elif [ "$_grp" = alias ]; then
    deny "forge-identity: this is \`$_cli alias $_verb\`. An alias can run a forge write under a name this guard does not recognise, as the machine owner (DND-1179). Fix: do not define aliases; run the command itself, and run a write through \`~/dev/custom/ai/bin/$_cli-athena\`. $_esc"
  else
    deny "forge-identity: this is a plain \`$_cli $_grp $_verb\`, a forge WRITE ($_cli $_grp reads are only: $_reads). $_who: the silent mis-attribution DND-203 exists to prevent (DND-1179). Fix: run the same command through the wrapper, \`~/dev/custom/ai/bin/$_cli-athena $_grp $_verb …\` (check it with \`~/dev/custom/ai/bin/forge-preflight\` if it fails). Reads may stay on plain \`$_cli\`. $_esc"
  fi
fi

# No bypass detected → allow silently.
exit 0
