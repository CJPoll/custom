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
# branch.<cur>.remote / origin) in the repo the push runs in (the last
# preceding `cd <dir>`, else the hook's cwd, then each `-C <dir>` applied on
# top, as git applies it). A push whose remote CANNOT be
# resolved is still denied, naming that it could not tell — an unresolvable remote
# must not read as "not GitHub". DND-393 extends the rule to gitlab.com: a plain
# push there goes out on the owner's SSH key and GitLab records the owner, and
# `glab-athena git` is now the Athena path to point it at. A remote resolving
# elsewhere (a local path, another host) is allowed silently.
# DND-1862: which word is the subcommand, which is the repository and which is
# an option's value is read with git's own grammar, the wrapper's
# fg_global_opt and fg_push_argv (ai/lib/forge-git-passthrough.sh), in a bash
# child ("The push's argv, read with git's grammar" below). -C values join as
# git joins them, and --git-dir, --work-tree, --bare, -c and --config-env
# apply when a remote NAME is looked up. An option git does not have is
# denied, since the target cannot be told. A shell redirection
# (`2>/dev/null`, `> log`) is not argv and is dropped before the reading.
# Residual (each still allowed): a URL rewrite (insteadOf / pushInsteadOf)
# applied to a literal URL or path word, since only remote names go through
# git; config from the environment (`GIT_DIR=… git push`, GIT_CONFIG_*); a
# redirection placed before `push` (`git 2>x push`), and a quoted value with
# whitespace in it (`git -c 'k=a b' push`), which each keep the text from
# matching as a push candidate at all.
#
# Later (2026-10-03, DND-1862): the push rule read its own words: -C and -c
# took a value in the global peel, and -o, --push-option, --receive-pack,
# --exec and --repo by exact name in the push walk. So `git push -fo
# /tmp/x.git`, `git push --push-o /tmp/x.git` and `git push --repo=/tmp/x.git
# --no-repo` read the path as the repository and were allowed, while git
# pushes to the default remote; `git --namespace ns push` was never seen.
#
# Later (2026-10-03, DND-1887): the push rule denied `git push -h` and
# `--help`, which print usage and send nothing. Superseded: help as the FIRST
# push argument is allowed; help anywhere else is judged as before.
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
#     A deny is only ever emitted for a positive match. One exception
#     denies on an error: when git's grammar cannot be read (the passthrough
#     unreadable, or no bash), a git push CANDIDATE is denied as the push
#     rule's unresolved remote, not allowed (DND-1862). A candidate is
#     lexical and over-matches, so in that state a command that only looks
#     like a push (`git --no-pager log --grep push`) is denied too: an
#     accepted false positive, like the mentions below.
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

# api_method <segment> : the HTTP method one `gh … api` segment names (upper
# case, the last one wins), or "" when it names none. Options that take a value
# are read WITH that value, so `--jq -XGET` is a jq filter and never a method
# (DND-1886), and a quoted value is one word however many spaces it holds
# (DND-1911). The value options are the shared classifier's -R/--repo and
# --hostname (ai/lib/forge-write-class.awk, valued) plus gh api's own: -q/--jq,
# -t/--template, -p/--preview, --cache, --output, -H/--header, -f/-F/--field/
# --raw-field/--form and --input.
api_method() {
  printf '%s' "$1" | awk '{
    # DND-1911: the words are read the way the shell does. A quoted value that
    # holds a space (--jq ".a -XGET") is ONE word, so its tail is never read
    # as an option. Quotes group and are dropped, a backslash escapes the next
    # character, and an unterminated quote runs to the end of the segment.
    m = ""; seen = 0; nw = 0; cur = ""; has = 0; q = ""
    for (p = 1; p <= length($0) + 1; p++) {
      tc = (p <= length($0)) ? substr($0, p, 1) : " "
      if (q != "") { if (tc == q) q = ""; else cur = cur tc; continue }
      if (tc == "\"" || tc == "'"'"'") { q = tc; has = 1; continue }
      if (tc == "\\" && p < length($0)) { cur = cur substr($0, p + 1, 1); has = 1; p++; continue }
      if (tc == " ") { if (has) W[++nw] = cur; cur = ""; has = 0; continue }
      cur = cur tc; has = 1
    }
    for (i = 1; i <= nw; i++) {
      x = W[i]
      if (!seen) { if (x == "api") seen = 1; continue }
      if (x == "-X" || x == "--method") { m = W[i + 1]; i++; continue }
      if (x ~ /^--method=/) { m = substr(x, 10); continue }
      if (x ~ /^--(jq|template|preview|cache|output|header|field|raw-field|form|input|repo|hostname)=/) continue
      if (x ~ /^-[^-]/) {
        # A short cluster (`-iqXGET`): flags with no value (`-i`) are skipped,
        # and the first value option takes the rest of the word, or the next
        # word, as its value.
        cl = substr(x, 2); done = 0
        for (c = 1; c <= length(cl); c++) {
          ch = substr(cl, c, 1); rest = substr(cl, c + 1)
          if (ch == "X") { sub(/^=/, "", rest); if (rest == "") { rest = W[i + 1]; i++ } m = rest; done = 1; break }
          if (ch ~ /[qtpRHfF]/) { if (rest == "") i++; done = 1; break }
        }
        if (done) continue
      }
      if (x == "-q" || x == "--jq" || x == "-t" || x == "--template" || x == "-p" || x == "--preview" || x == "--cache" || x == "--output" || x == "-H" || x == "--header" || x == "-f" || x == "-F" || x == "--field" || x == "--raw-field" || x == "--form" || x == "--input" || x == "-R" || x == "--repo" || x == "--hostname") { i++; continue }
    }
    # A quoted "-X PATCH" is one word whose method value has a leading space.
    sub(/^[ ]+/, "", m)
    sub(/[^A-Za-z].*/, "", m)
    print toupper(m)
  }'
}

# api_ref_write <segment> : true when one `gh … api` command segment writes a ref.
api_ref_write() {
  _s=$1
  printf '%s' "$_s" | grep -Eq "$REF_MUT_RE" && return 0
  printf '%s' "$_s" | grep -Eiq "$REF_ROUTE_RE" || return 1
  printf '%s' "$_s" | grep -Eiq 'x-(http-)?method(-override)?[[:space:]]*:' && return 0
  _m=$(api_method "$_s")
  case "$_m" in
    DELETE) printf '%s' "$_s" | grep -Eiq "$GIT_REF_RE" && return 1; return 0 ;;
    GET|HEAD|"") ;;
    *) return 0 ;;
  esac
  # DND-1886: the lexical reading (any -X<word> in the segment, last wins) can
  # take an option's value for the method. It denies where it names a write
  # the option-aware reading above does not, so a GET/HEAD/no-method reading
  # never allows what the lexical one denied. The option-aware reading decides
  # which rule owns the deny and its Fix (the generic api-write rule denies a
  # non-GET/HEAD method either way).
  _lex=$(printf '%s' "$_s" | sed -nE "s/(^|.*[[:space:]])(-[[:alpha:]]*X|--method)(=|[[:space:]]+)?[\"']?([[:alpha:]]+).*/\4/p" | tr '[:lower:]' '[:upper:]')
  case "$_lex" in
    GET|HEAD|"") ;;
    DELETE) printf '%s' "$_s" | grep -Eiq "$GIT_REF_RE" && return 1; return 0 ;;
    *) return 0 ;;
  esac
  [ "$_m" = GET ] || [ "$_m" = HEAD ] && return 1
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
  deny 'forge-identity: this is a bare `glab mr merge` / `glab mr accept`, which stamps the merge to the machine owner, not Athena — the silent mis-attribution DND-203 exists to prevent — AND skips the pinned-head, passed-pipeline merge guard (DND-742). Fix: board the merge train through the wrapper — `~/dev/custom/ai/bin/glab-athena api -X POST "projects/:id/merge_trains/merge_requests/<iid>" -f sha=<head sha>` — or, with no train, `~/dev/custom/ai/bin/glab-athena mr merge <iid> --sha <head sha> --auto-merge=false --yes`, once the head pipeline passed on that head, after verifying the wrapper is healthy with `~/dev/custom/ai/bin/forge-preflight`. Reads may stay on plain `glab`; writes go through glab-athena. If the wrapper refuses or fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
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
  deny 'forge-identity: this is a bare `glab api` call on a merge route, a merge-train car, or with the merge mutation (REST …/merge_requests/<iid>/merge; …/merge_trains/merge_requests/<iid>; GraphQL mergeRequestAccept). It merges as the machine owner AND skips the pinned-head, passed-pipeline merge guard (DND-742). Fix: board through the one guarded path — `~/dev/custom/ai/bin/glab-athena api -X POST "projects/:id/merge_trains/merge_requests/<iid>" -f sha=<head sha>` once the head pipeline passed on that head (or `~/dev/custom/ai/bin/glab-athena mr merge <iid> --sha <head sha> --auto-merge=false --yes` where there is no train). To only READ merge state, use `glab mr view <iid> -F json` or `glab api "projects/:id/merge_trains?scope=active"`. If the wrapper refuses, do not work around it; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'\''t be done as Athena").'
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
# An empty quoted word ('' or "") is still a word to git: `git -C '' push`
# runs in the cwd, and dropping it would make `push` read as -C's value. So it
# becomes the word FI_EMPTY_WORD before the quotes are dropped, and
# PUSH_READ_BASH reads it back as "" (DND-1862). Applied twice, so two
# adjacent empty words (`'' ''`) both survive.
EMPTY_WORD_SED="s/(^|[[:space:];&|(])(''|\"\")([[:space:];&|)]|\$)/\\1FI_EMPTY_WORD\\3/g"
GFLAT=$(printf '%s' "$CMD" | bless_wrapper_var | tr '\n\t' '; ' | sed -E "$EMPTY_WORD_SED" | sed -E "$EMPTY_WORD_SED" | tr -d "'\"\\\\" | sed -E 's#(gh|glab)-athena[[:space:]]+git([[:space:]])#FORGE_ATHENA_GIT\2#g')
# A CANDIDATE push: `git`, bare or path-qualified, then words that each start
# with `-` (an option), each optionally followed by one word that does not
# (that option's value), then `push`. This only finds candidates, so it
# over-matches (`git --no-pager log --grep push`); which word is the
# subcommand, and which are values, is decided by git's own grammar in
# PUSH_READ_BASH below (the header's DND-1862 Later label says what it was).
# `git commit -m "push"` does not match: `commit` is not an option.
GIT_PUSH_RE='(^|[[:space:];&|(/])git([[:space:]]+--?[^[:space:];&|]+([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)?)*[[:space:]]+push([[:space:]]|$|[;&|)])'

PUSH_FIX='Fix: push through the wrapper, which authenticates as athena-harness[bot] over HTTPS for that one command: `GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= -c url.https://github.com/.insteadOf=git@github.com: push …` (athena:github -> "Pushing as Athena"). If the wrapper refuses or fails, do not work around this; escalate to your admiral with the command + error and wait.'
GITLAB_PUSH_FIX='Fix: push through the wrapper, which authenticates as the Athena bot of the project namespace over HTTPS for that one command: `GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/glab-athena git push …` (athena:gitlab -> "Pushing as Athena"). If the wrapper refuses or fails, do not work around this; escalate to your admiral with the command + error and wait (athena:github -> "When a forge write can'"'"'t be done as Athena").'

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

# ---- The push's argv, read with git's grammar (DND-1862) --------------------
# The words are read with the tables and the walk the wrapper itself uses:
# fg_global_opt and fg_push_argv in ai/lib/forge-git-passthrough.sh ("git's
# own argv grammar", DND-1843). The interface read from it: the file stays
# definition-only at top level; fg_global_opt returns 0 (a value option),
# 1 (no value), 3 (prints and exits) or 2 (unknown); fg_push_argv fills
# FG_PA_OPTS (spelled --repo=<r>, --no-repo, --<name>=<value>), FG_PA_POS and
# FG_PA_BAD. The self-test's DND-1862 cases exercise each, and a missing
# function or table makes every candidate deny. Naming this hook in that
# file's own list of readers is a separate change, because that file is an
# owner-held surface. That file is bash and this hook is POSIX sh, so the
# reading runs in one `bash` child per candidate push. The child sources the
# file (it only defines functions and tables), turns FI_EMPTY_WORD back into
# "", drops shell redirections (a word that starts with optional digits then
# `<` or `>`, and the word after a bare operator such as `>` or `2>`), and
# prints one line per finding:
#   NOTPUSH        git runs no push here: the first non-option word is
#                  another subcommand, or a global option prints and exits
#   BAD <word>     an option git's grammar does not have, an ambiguous
#                  abbreviation, or a value missing: the target is unknown
#   CD <dir>       a -C value, in order (git joins them)
#   G <option>     a global option that changes which repository or config
#                  git reads (--git-dir, --work-tree, --bare, -c,
#                  --config-env), spelled as one word, for the lookups below
#   REPO <word>    the repository: the first word, and every --repo value.
#                  git ignores --repo when a first word is given; checking it
#                  anyway can only over-deny (the passthrough does the same)
#   DEFAULT        no repository word is in force: git uses the default remote
#   ALSO <word>    a later word or an option value; it is checked only when
#                  it names a configured remote or a forge URL, so a misread
#                  can only add a check (the passthrough does the same)
#   OK             the reading finished
# No OK line (bash missing, the file unreadable, a function or table gone)
# is not "no push": the candidate is denied as unresolved, with a Fix naming
# the file. That is the FAIL-OPEN exception the header names.
# Lexical, like every rule here: the words are the dequoted text split on
# whitespace, so a quoted value with a space in it splits in two.
PT_LIB="$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")")/../lib/forge-git-passthrough.sh"
PUSH_READ_BASH='
. "$1" 2>/dev/null || exit 70
declare -F fg_global_opt fg_push_argv >/dev/null 2>&1 || exit 70
declare -p FG_PA_OPTS FG_PA_POS FG_PA_BAD >/dev/null 2>&1 || exit 70
shift
words=(); skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  if [[ $a =~ ^[0-9]*[\<\>] ]]; then
    [[ $a =~ ^[0-9]*[\<\>]+$ ]] && skip=1
    continue
  fi
  [ "$a" = FI_EMPTY_WORD ] && a=""
  words+=("$a")
done
set -- "${words[@]}"
found=0
while [ $# -gt 0 ]; do
  w=$1; shift
  case "$w" in
    push) found=1; break ;;
    -*)
      fg_global_opt "$w"; rc=$?
      case "$rc" in
        0)
          [ $# -gt 0 ] || break
          case "$w" in
            -C) printf "CD %s\n" "$1" ;;
            -c|--git-dir|--work-tree|--config-env) printf "G %s\nG %s\n" "$w" "$1" ;;
          esac
          shift ;;
        1)
          case "$w" in
            --bare|--git-dir=*|--work-tree=*|--config-env=*) printf "G %s\n" "$w" ;;
          esac ;;
        3) break ;;
        *) printf "BAD %s\n" "$w"; echo OK; exit 0 ;;
      esac ;;
    *) break ;;
  esac
done
if [ "$found" = 0 ]; then echo NOTPUSH; echo OK; exit 0; fi
# DND-1887: help as the FIRST push argument prints usage and exits before git
# reads a remote. Stricter than git on purpose (as merge-role-guard, DND-1865):
# git accepts abbreviated long options, so `--push-op -h` makes -h a value, and
# help in any other position is judged like any push.
case "${1-}" in -h|--help) echo NOTPUSH; echo OK; exit 0 ;; esac
fg_push_argv "$@"
if [ -n "$FG_PA_BAD" ]; then printf "BAD %s\n" "$FG_PA_BAD"; echo OK; exit 0; fi
has_repo=0
for o in "${FG_PA_OPTS[@]}"; do
  case "$o" in
    --repo=*) has_repo=1; printf "REPO %s\n" "${o#--repo=}" ;;
    --no-repo) has_repo=0 ;;
    --*=*) printf "ALSO %s\n" "${o#*=}" ;;
  esac
done
if [ "${#FG_PA_POS[@]}" -gt 0 ]; then
  printf "REPO %s\n" "${FG_PA_POS[0]}"
  for a in "${FG_PA_POS[@]:1}"; do printf "ALSO %s\n" "$a"; done
elif [ "$has_repo" = 0 ]; then
  echo DEFAULT
fi
echo OK
'

# expand_home <path> : a leading ~ or $HOME, as the shell would expand it.
expand_home() {
  case "$1" in
    "~"|"~/"*) printf '%s' "$HOME${1#\~}" ;;
    "\$HOME"*) printf '%s' "$HOME${1#\$HOME}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# push_repo_dir <-C values, one per line>: the repo dir the push runs in. It
# starts in the last `cd <dir>` in BEFORE (the text before the push), else
# the hook input cwd, and
# applies each -C in order, as git does (`-C a -C b` is a/b). Relative paths
# resolve against the input cwd (where the command actually runs), not the
# hook's dir.
push_repo_dir() {
  _base=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  _c=$(printf '%s' "$BEFORE" | grep -Eo '(^|[[:space:];&|(])cd[[:space:]]+[^[:space:];&|)]+' | tail -n1 | sed -E 's#.*cd[[:space:]]+##')
  [ "$_c" = FI_EMPTY_WORD ] && _c=""   # `cd ''` stays where it is
  _c=$(expand_home "$_c")
  case "$_c" in /*|'') ;; *) [ -n "$_base" ] && _c="$_base/$_c" ;; esac
  [ -n "$_c" ] || _c=$_base
  _ifs=$IFS; IFS='
'
  for _d in $1; do
    _d=$(expand_home "$_d")
    case "$_d" in
      '') ;;
      /*) _c=$_d ;;
      *) if [ -n "$_c" ]; then _c="$_c/$_d"; else _c=$_d; fi ;;
    esac
  done
  IFS=$_ifs
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
UNRESOLVED_TAIL="GitHub: ${PUSH_FIX} GitLab: ${GITLAB_PUSH_FIX}"
N=0
while [ "$N" -lt 10 ] && printf '%s' "$GFLAT" | grep -Eq "$GIT_PUSH_RE"; do
  N=$((N + 1))
  BEFORE=$(split_first_push before)
  AFTER=$(split_first_push after)
  # The push's own arguments: from `push` to the next separator.
  ARGS=$(printf '%s' "$AFTER" | sed -E 's#^[[:space:]]*##; s#[;&|)].*##')
  # The words after `git`, `push` included: the match minus its leading
  # boundary, `git` and a trailing separator.
  BODY=$(split_first_push match | sed -E 's#^[[:space:];&|(/]*git##; s#[;&|)]$##')
  set -f   # word-split without globbing against the cwd
  # shellcheck disable=SC2086
  READ=$(bash -c "$PUSH_READ_BASH" forge-identity-push "$PT_LIB" $BODY $ARGS 2>/dev/null)
  set +f
  GFLAT=$AFTER
  if [ "$(printf '%s\n' "$READ" | tail -n1)" != OK ]; then
    add_warning "forge-identity: this looks like a plain \`git push\`, and the guard could not read its arguments with git's push grammar ($PT_LIB, sourced by bash), so it cannot tell which remote it goes to. If that is github.com or gitlab.com, it authenticates as the machine owner (CJPoll), not Athena. Fix: restore ai/lib/forge-git-passthrough.sh beside ai/hooks and make sure \`bash\` is on PATH; meanwhile push through the wrapper. ${UNRESOLVED_TAIL}"
    continue
  fi
  printf '%s\n' "$READ" | grep -qx NOTPUSH && continue
  BADW=$(printf '%s\n' "$READ" | sed -n 's/^BAD //p' | head -n1)
  if [ -n "$BADW" ]; then
    add_warning "forge-identity: this is a plain \`git push\` with \`$BADW\`, which git's grammar does not read as an option it has (unknown, ambiguous, or missing its value), so the guard cannot tell which word is the repository. If it goes to github.com or gitlab.com, it authenticates as the machine owner (CJPoll), not Athena. Fix: spell the option in full as \`git push -h\` (a push option) or \`git -h\` (a global option) lists it, or drop it. ${UNRESOLVED_TAIL}"
    continue
  fi
  DIR=$(push_repo_dir "$(printf '%s\n' "$READ" | sed -n 's/^CD //p')")
  # One word per line, so it splits the same under the default IFS and the
  # newline-only IFS of the loops below (a word holds no whitespace).
  GOPTS=$(printf '%s\n' "$READ" | sed -n 's/^G //p')
  INREPO=0; REMOTES=""
  set -f
  # shellcheck disable=SC2086
  if [ -n "$DIR" ] && git -C "$DIR" $GOPTS rev-parse --git-dir >/dev/null 2>&1; then
    INREPO=1
    # shellcheck disable=SC2086
    REMOTES=$(git -C "$DIR" $GOPTS remote 2>/dev/null)
  fi
  set +f
  is_remote() { [ -n "$1" ] && printf '%s\n' "$REMOTES" | grep -qxF -- "$1"; }
  # remote_urls <remote> : its push URLs, as git resolves them in that repo.
  remote_urls() {
    # shellcheck disable=SC2086
    git -C "$DIR" $GOPTS remote get-url --push --all "$1" 2>/dev/null
  }
  PAIRS=""; UNRES=""
  add_pair() { PAIRS="$PAIRS$1 $2
"; }
  # strict <word> : a repository git pushes to; a word that resolves to
  # nothing is unresolved (denied below), never "not a forge".
  strict() {
    _t=$1; _found=0
    if [ "$INREPO" = 1 ] && is_remote "$_t"; then
      for _u in $(remote_urls "$_t"); do add_pair "$_t" "$_u"; _found=1; done
    elif [ "$INREPO" = 1 ] && looks_like_url_or_path "$_t"; then
      add_pair "$_t" "$_t"; _found=1   # a URL literal or a path, classified by host below
    elif [ -n "$(forge_of_url "$_t")" ]; then
      add_pair "$_t" "$_t"; _found=1   # a literal forge URL needs no repo to classify
    fi
    [ "$_found" = 1 ] || UNRES=${UNRES:-${_t:-default}}
  }
  # also <word> : checked only when it names a remote or a forge URL.
  also() {
    if [ "$INREPO" = 1 ] && is_remote "$1"; then
      for _u in $(remote_urls "$1"); do add_pair "$1" "$_u"; done
    elif [ -n "$(forge_of_url "$1")" ]; then
      add_pair "$1" "$1"
    fi
  }
  _ifs=$IFS; IFS='
'
  set -f
  for _line in $READ; do
    case "$_line" in
      "REPO "*) strict "${_line#REPO }" ;;
      "ALSO "*) also "${_line#ALSO }" ;;
      DEFAULT)
        _def=""
        if [ "$INREPO" = 1 ]; then
          # shellcheck disable=SC2086
          CUR=$(git -C "$DIR" $GOPTS symbolic-ref -q --short HEAD 2>/dev/null)
          # shellcheck disable=SC2086
          [ -n "$CUR" ] && _def=$(git -C "$DIR" $GOPTS config --get "branch.$CUR.pushRemote" 2>/dev/null)
          # shellcheck disable=SC2086
          [ -n "$_def" ] || _def=$(git -C "$DIR" $GOPTS config --get remote.pushDefault 2>/dev/null)
          # shellcheck disable=SC2086
          [ -n "$_def" ] || { [ -n "$CUR" ] && _def=$(git -C "$DIR" $GOPTS config --get "branch.$CUR.remote" 2>/dev/null); }
          [ -n "$_def" ] || _def=origin
          strict "$_def"
        else
          UNRES=${UNRES:-default}
        fi ;;
    esac
  done
  IFS=$_ifs
  set +f
  if [ -n "$UNRES" ]; then
    add_warning "forge-identity: this is a plain \`git push\` and the guard could not resolve its remote (repo dir '${DIR:-unknown}', remote '${UNRES}'), so it cannot tell whether it goes to github.com or gitlab.com. If it does, it authenticates as the machine owner (CJPoll), not Athena. ${UNRESOLVED_TAIL} If it genuinely goes elsewhere (a local path), re-run it with the repo as a literal \`git -C <absolute dir>\` and a configured remote or a literal URL, so the guard can resolve it."
  fi
  _ifs=$IFS; IFS='
'
  set -f
  for _p in $PAIRS; do
    _t=${_p%% *}; u=${_p#* }
    case "$(forge_of_url "$u")" in
      github)
        add_warning "forge-identity: this is a plain \`git push\` to a github.com remote ('${_t}' -> ${u}), which authenticates with the machine owner's SSH key or credential helper — GitHub records the push as CJPoll, not Athena. ${PUSH_FIX}" ;;
      gitlab)
        add_warning "forge-identity: this is a plain \`git push\` to a gitlab.com remote ('${_t}' -> ${u}), which authenticates with the machine owner's SSH key or credential helper — GitLab records the push as the owner, not the Athena bot for that namespace. ${GITLAB_PUSH_FIX}" ;;
    esac
  done
  IFS=$_ifs
  set +f
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
  else _who='GitLab records it as the machine owner, not the Athena bot for the project'\''s namespace (ai/config/forge-identities.json + the private overlay)'; fi
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
