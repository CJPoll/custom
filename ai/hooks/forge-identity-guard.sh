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
# DND-397: before matching, drop text that only MENTIONS a push. mask_data
# removes heredoc bodies and replaces multi-word quoted strings with a
# placeholder, so `python3 - <<'EOF' … git push … EOF`, `grep -n "git push" f`
# and `echo 'git push'` no longer warn. It never hides text a shell will run:
#   * If the command invokes a shell or evaluator anywhere (sh, bash, zsh,
#     dash, ksh, fish, su, eval, ssh, watch, source — bare or path-qualified,
#     outside quotes and heredoc bodies), NOTHING is masked. `bash -c '…'`,
#     `bash <<EOF`, `… | sh` and `eval "…"` are scanned exactly as before.
#   * A double-quoted string containing `$(` or a backtick is RE-SCANNED with
#     these same rules, not masked: its command substitution runs. So
#     `echo "$(git push …)"` still warns, while the heredoc inside
#     `git commit -m "$(cat <<'EOF' … EOF)"` is still dropped.
#   * An unquoted-delimiter heredoc body containing `$(` or a backtick is kept:
#     its command substitution runs.
#   * A ONE-word quoted string is kept (`"origin"`, `-C "/dir"`, `"$W"`), so a
#     quoted remote, dir or command word still resolves.
#   * An unterminated quote or heredoc is kept as-is.
# Residual (named, not hidden): a push a NON-shell interpreter spawns from its
# own quoted code or heredoc (`python3 -c "os.system('git push')"`) is not
# seen. It was only seen before by accident of the dequote, and
# `subprocess.run(['git','push'])` never was.
mask_data() {
  awk '
    function shellword(w,   b) {
      b = w; sub(/.*\//, "", b)
      return b ~ /^(sh|bash|zsh|dash|ksh|fish|su|eval|ssh|watch|source)$/
    }
    # flush(w): end an unquoted word; a shell word anywhere sets `shell`.
    function flush(w) { if (w != "" && shellword(w)) shell = 1; return "" }
    function quoted(body, q) {
      if (body !~ /[ \t\n]/) return q body q
      # A double-quoted $(...) or `...` runs: re-scan it with the same rules.
      if (q == "\"" && (index(body, "$(") || index(body, "`"))) return q mask(body) q
      return q "FORGE_QUOTED_TEXT" q
    }
    function mask(s,   n, i, c, t, j, d, body, k, strip, dl, qd, h, e, line, cmp, found, out, w, nhd, hd, hs, hq) {
      n = length(s); i = 1; out = ""; w = ""; nhd = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { t = substr(s, i, 2); out = out t; w = w t; i += 2; continue }
        if (c == "\047") {
          j = index(substr(s, i + 1), "\047")
          if (j == 0) { out = out substr(s, i); break }
          body = substr(s, i + 1, j - 1); out = out quoted(body, "\047"); w = w body
          i += j + 1; continue
        }
        if (c == "\"") {
          j = i + 1
          while (j <= n) { d = substr(s, j, 1); if (d == "\\") { j += 2; continue }; if (d == "\"") break; j++ }
          if (j > n) { out = out substr(s, i); break }
          body = substr(s, i + 1, j - i - 1); out = out quoted(body, "\""); w = w body
          i = j + 1; continue
        }
        if (substr(s, i, 3) == "<<<") { w = flush(w); out = out "<<<"; i += 3; continue }
        if (substr(s, i, 2) == "<<") {
          w = flush(w); k = i + 2; strip = 0
          if (substr(s, k, 1) == "-") { strip = 1; k++ }
          while (substr(s, k, 1) == " " || substr(s, k, 1) == "\t") k++
          dl = ""; qd = 0
          while (k <= n) {
            d = substr(s, k, 1)
            if (d ~ /[ \t\n;&|()<>]/) break
            if (d == "\047" || d == "\"" || d == "\\") qd = 1; else dl = dl d
            k++
          }
          if (dl != "") { nhd++; hd[nhd] = dl; hs[nhd] = strip; hq[nhd] = qd }
          out = out substr(s, i, k - i); i = k; continue
        }
        if (c == "\n") {
          w = flush(w); out = out c; i++
          for (h = 1; h <= nhd; h++) {
            body = ""; found = 0
            while (i <= n) {
              e = index(substr(s, i), "\n")
              if (e == 0) { line = substr(s, i); i = n + 1 } else { line = substr(s, i, e - 1); i += e }
              cmp = line; if (hs[h]) sub(/^\t+/, "", cmp)
              if (cmp == hd[h]) { found = 1; break }
              body = body line "\n"
            }
            if (!found) { out = out body; continue }   # unterminated: keep
            if (!hq[h] && (index(body, "$(") || index(body, "`"))) out = out body
            out = out line "\n"
          }
          nhd = 0; continue
        }
        if (c ~ /[ \t;&|()]/) { w = flush(w); out = out c; i++; continue }
        out = out c; w = w c; i++
      }
      w = flush(w)
      return out
    }
    { src = src (NR > 1 ? "\n" : "") $0 }
    END { shell = 0; m = mask(src); printf "%s", (shell ? src : m) }'
}

# wrapper_vars: the names assigned a wrapper path (`W=~/…/glab-athena`,
# `export W="$HOME/…/gh-athena"`) whose LAST assignment in the command is still
# a wrapper, one per line. Reads GFLAT, which is already dequoted.
wrapper_vars() {
  printf '%s' "$GFLAT" | grep -Eo '(^|[[:space:];&|(])[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|)]*' \
    | sed -E 's#^[[:space:];&|(]##' | awk -F= '
      { v = substr($0, length($1) + 2); last[$1] = (v ~ /(^|\/)(gh|glab)-athena$/) }
      END { for (k in last) if (last[k]) print k }'
}

# Dequote (as forge-auth-guard does) so quoting cannot split the pattern, and
# mask the wrapper forms `gh-athena git` / `glab-athena git` first so they are
# never matched. DND-397: `$W git` / `${W} git` count as the wrapper form too
# when W is a wrapper_vars name.
# Newlines become `;` here (not spaces, as in FLAT): a push's arguments end at
# the end of its line, so `git push<NL>echo done` never reads `echo` as a remote.
GFLAT=$(printf '%s' "$CMD" | mask_data | tr '\n\t' '; ' | tr -d "'\"\\\\" | sed -E 's#(gh|glab)-athena[[:space:]]+git([[:space:]])#FORGE_ATHENA_GIT\2#g')
for _v in $(wrapper_vars); do
  GFLAT=$(printf '%s' "$GFLAT" | sed -E "s#\\\$(${_v}|\\{${_v}\\})[[:space:]]+git([[:space:]])#FORGE_ATHENA_GIT\\2#g")
done
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
# push's warning is collected (a GitLab push must not hide a later GitHub one)
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
    fi               # else: neither a remote nor a URL -> unresolved (warn below)
  elif [ -n "$TARGET" ] && [ -n "$(forge_of_url "$TARGET")" ]; then
    URLS=$TARGET     # a literal forge URL needs no repo to classify
  fi
  if [ -z "$URLS" ]; then
    add_warning "forge-identity: this is a plain \`git push\` and the guard could not resolve its remote (repo dir '${DIR:-unknown}', remote '${TARGET:-default}'), so it cannot tell whether it goes to github.com or gitlab.com. If it does, it authenticates as the machine owner (CJPoll), not Athena. GitHub: ${PUSH_FIX} GitLab: ${GITLAB_PUSH_FIX}"
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

[ -z "$WARNINGS" ] || warn "$WARNINGS"

# No bypass detected → allow silently.
exit 0
