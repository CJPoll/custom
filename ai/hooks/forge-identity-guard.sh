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
# resolved is still denied, naming that it could not tell — an unresolvable remote
# must not read as "not GitHub". DND-393 extends the rule to gitlab.com: a plain
# push there goes out on the owner's SSH key and GitLab records the owner, and
# `glab-athena git` is now the Athena path to point it at. A remote resolving
# elsewhere (a local path, another host) is allowed silently.
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
# mis-attributing. Two `gh api` shapes ARE matched, because they also skip a
# safety check, not only attribution: a merge (DND-728) and a ref write
# (DND-741). Each has its own block below.
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
  deny 'forge-identity: this is a bare `gh pr merge`, which stamps the merge to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: merge through the wrapper — `~/dev/custom/ai/bin/gh-athena pr merge …` — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `gh`; writes (create/comment/review/merge) go through gh-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
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
  deny 'forge-identity: this is a bare `gh api` call on a merge route or with a merge mutation (REST …/pulls/<n>/merge, …/merges, …/merge-upstream; GraphQL mergePullRequest / enablePullRequestAutoMerge / enqueuePullRequest / mergeBranch). It merges as the machine owner AND skips the pinned-head, all-green merge guard (DND-609, DND-728). Fix: merge through the one guarded path — `~/dev/custom/ai/bin/gh-athena pr merge <n> --squash --match-head-commit <sha>` after every check on that head is green. To only READ merge state, use `gh pr view <n> --json mergedAt,state`. If the wrapper refuses, do not work around it; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
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
REF_DENY='forge-identity: this is a bare `gh api` call that creates or moves a ref (REST …/git/refs, …/contents/…, …/branches/<b>/rename or …/pulls/<n>/update-branch; GraphQL createCommitOnBranch / createRef / updateRef / updateRefs / createLinkedBranch / revertPullRequest / updatePullRequestBranch). It runs as the machine owner AND can put commits on the default branch with no pinned head and no green check (DND-741). Fix: commit locally and move a branch only with `~/dev/custom/ai/bin/gh-athena git push origin <feature-branch>` (athena:github -> "Pushing as Athena"); land on the default branch only through a PR, with `~/dev/custom/ai/bin/gh-athena pr merge <n> --squash --match-head-commit <sha>` after every check on that head is green. To delete a branch, `gh-athena git push origin --delete <branch>`. If the wrapper refuses, do not work around it; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'

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

# Bare `glab mr merge`: the MERGE write the admiral performs. Same shape;
# `glab-athena mr merge` does NOT match.
if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+([^;|&]* )?mr[[:space:]]+merge'; then
  deny 'forge-identity: this is a bare `glab mr merge`, which stamps the merge to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent. Fix: merge through the wrapper — `~/dev/custom/ai/bin/glab-athena mr merge …` — after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `glab`; writes go through glab-athena. If the wrapper itself fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
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

# No bypass detected → allow silently.
exit 0
