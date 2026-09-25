#!/bin/sh
# PreToolUse git-stash guard (DND-670).
#
# Denies every Bash command that would write the git STASH LIST from a Claude
# Code session. The stash list is not per-worktree: `refs/stash` and its reflog
# live in the COMMON git dir, so every linked worktree of a repo shares ONE
# stash list with the owner's main checkout. `git rev-parse --git-path
# refs/stash` from a worktree prints the main checkout's path. So a captain's
# `git stash` + `git stash pop` in its worktree pops whatever is on top, and
# that can be the owner's saved work. Measured 2026-09-25 on walt_ui: the
# PT-1709 captain ran `git stash` then `git stash pop` and popped the owner's
# PT-822 entry instead of its own. Nothing errored.
#
# SCOPE: every Claude Code session, main checkout included. Hooks fire only on
# Claude Code tool calls, and every Claude Code session here is an agent
# session, so "linked worktree OR agent session" is every session this hook
# ever sees. Deciding per target repo would mean computing that repo from the
# command text (`-C`, `cd`, `--git-dir`, GIT_DIR, a cwd from an earlier call),
# and a wrongly computed repo would read as "main checkout, allow" (the
# failed-lookup class in ~/dev/custom/CLAUDE.md). The main checkout's list is
# the owner's too. The owner's own terminal is never touched.
#
# WHAT IS DENIED: `git stash` with any verb other than the three read-only ones
# below, including bare `git stash` and option-first forms (`git stash -u`,
# `git stash -- f`), which are an implicit push. Also: `update-ref` / `reflog
# delete|expire` / a file write (rm, mv, cp, a redirect, ...) naming
# refs/stash, since each rewrites the same list without the stash subcommand.
#
# DESIGN DECISION — READS ARE ALLOWED: `git stash list`, `git stash show` and
# `git stash create`. list/show only read. `create` writes a dangling commit
# object and no ref, so it cannot touch the list; athena:admiral-resume and
# athena:teardown-worktree-stack use it to salvage a dirty worktree.
#
# INDIRECTION (the DND-390 lesson): the command TEXT is split into shell words
# the way sh splits it (quotes and backslashes honoured, then removed), so a
# quoted value stays one word: `git -C "/a b" stash pop` is git, -C, /a b,
# stash, pop. Simple commands end at ; & | ( ) backtick and newline outside
# quotes. A quoted word that held whitespace or a separator is re-read as a
# command of its own (`sh -c 'git stash'`, nested `bash -c "... \"...\" ..."`).
# Inside each simple command, every `git` word
# counts (bare, path-qualified, `git-stash`), wherever it sits: after `sh -c`,
# `bash -c`, `env`, `command`, `sudo`, `xargs`, `nohup`, in a subshell, after a
# `cd`. Git global options are skipped (`-C <dir>`, `-c k=v`, `--git-dir[=]`,
# `--work-tree`, `--attr-source`, `--no-pager`, ...). A word after an option
# the hook does not know may be that option's value, so it is decided AND the
# scan continues past it: a new two-word option cannot hide `stash`. Also denied:
#   * a command word built by expansion followed by `stash` or a stash alias
#     (`$GIT stash`, `$GIT sp`, `${GIT:-git} stash`, `$(command -v git) stash`,
#     a backtick form);
#   * `git <expanded subcommand>` (`git $SUB`): its value is unknowable here;
#   * a git ALIAS that resolves to a mutating stash (its value parsed like a
#     command line, global options included, and resolved through chains,
#     from the global config and the repo config of the cwd and every `-C` /
#     `cd` dir), a shell alias (`!...`) whose body mentions stash or runs a
#     stash write read as a command (`!git sp`), and DEFINING an alias whose
#     value names stash (`git -c alias.p=stash p`, `git config alias.p ...`).
#
# ACCEPTED FALSE POSITIVE (the class forge-auth-guard documents): matching is
# lexical, so a command that only MENTIONS a mutating stash (a heredoc, a
# `git commit -m`, a `grep`) is denied too. That costs one retry: move the text
# into a file with the Write tool and pass the file (`git commit -F`), or use
# the Grep tool. A miss costs the owner's saved work.
#
# NOT CATCHABLE (a tripwire, not a sandbox): a string computed then executed
# (`eval "$(printf ...)"`, base64 | sh); both command word and subcommand
# expanded (`$G $S`); a shell alias or function or script file defined in one
# call and run in a later one; another interpreter building argv (`python -c`);
# `--autostash` on rebase/pull/merge, which stores into the list only on a
# conflict and is used by the shipwright (out of scope, proposed separately);
# reflog expiry by `git gc`; git arguments supplied through a pipe
# (`printf 'stash pop' | xargs git`); an alias defined in a file the command
# only names (`git -c include.path=<file>`, a `.gitconfig` written with the
# Write tool in an earlier call is caught when the alias is USED, since
# aliases are read at decision time).
#
# Design guarantees (mirror forge-identity-guard):
#   * FAIL-OPEN — any error (missing jq, unparseable input, non-Bash tool, no
#     match) exits 0 and ALLOWS silently. A deny is only emitted on a positive
#     match.
#   * NO ESCAPE HATCH — there is no env var or marker that switches it off. A
#     session that must write the stash list is the owner, in a terminal.
#
# Wired in ~/.claude/settings.json as a PreToolUse hook scoped to Bash
# (ai/hooks/registry.json is the source of truth; `scripts/setup-hooks --install`
# wires it). Self-test: ai/hooks/git-stash-guard.self-test.sh.

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# FLAT feeds only the LEXICAL checks below (the prefilter, refs/stash writes,
# alias definitions, the dirs aliases are read from): flattened (a newline ends
# a command, so it becomes `;`), dequoted, `git-stash` spelled `git stash`.
# The stash verdict itself tokenizes the raw command (see the awk block).
FLAT=$(printf '%s' "$CMD" | tr '\n\t' '; ' | tr -d "'\"\\\\" \
  | sed -E 's#(^|[^[:alnum:]_.-])git-stash([^[:alnum:]_.-]|$)#\1git stash\2#g')

# Nothing that could be a stash write: no `stash` text, no `git` word, and no
# expansion (a `$GIT sp` names neither, but may run a stash alias).
GIT_OR_EXP='(^|[^[:alnum:]_.-])git([^[:alnum:]_.-]|$)|[$`]'
printf '%s' "$FLAT" | grep -Eq "stash|$GIT_OR_EXP" || exit 0

deny() {
  jq -cn --arg r "git-stash-guard: $1 Every linked worktree shares ONE stash list with the main checkout (refs/stash lives in the common git dir), so a stash push/pop/apply/drop from a fleet worktree can apply, drop or clobber the OWNER's saved work with no error (DND-670: a captain's \`git stash pop\` popped the owner's PT-822 entry). Agent sessions never write the stash list. Fix: to park WIP, commit it on your worktree branch (\`git add -A && git commit -m \"WIP: <what>\"\`; squash or amend it later); for a clean tree to experiment in, add a scratch tree with \`git worktree add <path> -b <scratch-branch>\` and remove it after. Read-only \`git stash list\`, \`git stash show\` and \`git stash create\` stay allowed. If this command only MENTIONS stash text (a heredoc, a commit message, a grep) and writes no stash, move the text into a file with the Write tool and pass the file (\`git commit -F <file>\`), or use the Grep tool; never rephrase a real stash command to slip past this guard." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
    2>/dev/null
  exit 0
}

# ---- refs/stash rewritten without the stash subcommand ----------------------
# A redirect to /dev/null or an fd duplication writes nothing, so strip both
# before looking for a write operator.
WRITES=$(printf '%s' "$FLAT" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]##g')
if printf '%s' "$WRITES" | grep -Eq 'refs/stash' \
  && printf '%s' "$WRITES" | grep -Eq '(update-ref|reflog[[:space:]]+(delete|expire)|>|(^|[[:space:];&|(/])(rm|mv|cp|tee|truncate|unlink|shred|ln|dd|install)[[:space:]])'; then
  deny 'this command rewrites refs/stash (update-ref, reflog delete/expire, or a file write), which is the shared stash list.'
fi

# ---- defining an alias whose value names stash ------------------------------
if printf '%s' "$FLAT" | grep -Eq 'alias\.[^[:space:]=;&|]+[=[:space:]]([^;&|]*[^[:alnum:]_.-])?stash([^[:alnum:]_.-]|$)'; then
  deny 'this command defines a git alias whose value names `stash` (via `-c alias.<x>=...` or `git config alias.<x> ...`), a way to run a stash write under another name.'
fi
# An alias whose value arrives through an environment variable
# (`--config-env=alias.<x>=<VAR>`, `GIT_CONFIG_KEY_<n>=alias.<x>`): the value
# is not in the command text, so any such alias definition is denied.
if printf '%s' "$FLAT" | grep -Eq '(--config-env[=[:space:]]+|GIT_CONFIG_KEY_[0-9]+=)alias\.'; then
  deny 'this command defines a git alias through an environment variable (`--config-env=alias.<x>=<VAR>` or `GIT_CONFIG_KEY_<n>=alias.<x>`), whose value this guard cannot read and which may run a stash write under another name. Define aliases in your git config instead.'
fi

# ---- git aliases in scope ----------------------------------------------------
# From the global config plus the repo config of the cwd and of every `-C <dir>`
# or `cd`/`pushd <dir>` in the command. A dir that is not a repo still yields
# the global aliases; a dir that does not exist falls back to a plain read.
# Not resolved: a dir whose path contains whitespace (it is split into words),
# or one reached through a variable (`cd "$D"`). Global aliases still apply.
alias_read() {
  if [ -n "$1" ] && [ -d "$1" ]; then
    git -C "$1" config --get-regexp '^alias\.' 2>/dev/null
  else
    (cd / && git config --get-regexp '^alias\.' 2>/dev/null)
  fi
}
ALIASES=""
if printf '%s' "$FLAT" | grep -Eq "$GIT_OR_EXP"; then
  # The global read stands alone, so a repo git refuses to read (dubious
  # ownership, a corrupt config) still leaves the global aliases in scope.
  ALIASES="$(alias_read "")
$(alias_read "$CWD")"
  for _d in $(printf '%s' "$FLAT" | grep -Eo '(^|[[:space:];&|(])(-C|cd|pushd)[[:space:]]+[^[:space:];&|()]+' | sed -E 's#.*(-C|cd|pushd)[[:space:]]+##'); do
    case "$_d" in "~"|"~/"*) _d="$HOME${_d#\~}" ;; esac
    case "$_d" in /*) ;; *) [ -n "$CWD" ] && _d="$CWD/$_d" ;; esac
    ALIASES="$ALIASES
$(alias_read "$_d")"
  done
fi

# ---- git stash, through every head the header lists -------------------------
VERDICT=$(GSG_CMD="$CMD" GSG_ALIASES="$ALIASES" awk '
  function is_read(v) { sub(/[<>].*/, "", v); return v ~ /^(list|show|create)$/ }
  function mentions_stash(v) { return v ~ /(^|[^[:alnum:]_.-])stash([^[:alnum:]_.-]|$)/ }
  function is_sep(c) { return c ~ /[ \t\n;&|()`]/ }
  # tokenize(text, W, QF, SB): split text into shell words, honouring quotes
  # and backslashes the way sh does, so a quoted value stays ONE word
  # (`git -C "/a b" stash` is git, -C, /a b, stash). Quotes and backslashes are
  # removed from the word. SB[k] is 1 when word k starts a simple command
  # (after ; & | ( ) backtick or a newline, outside quotes). QF[k] is 1 when a
  # quoted part of word k held whitespace or a separator: its content may be a
  # command (`sh -c "git stash"`), so analyze re-reads it.
  function tokenize(text, W, QF, SB,    n, i, L, c, st, cur, has, q, ns) {
    n = 0; st = 0; cur = ""; has = 0; q = 0; ns = 1; L = length(text)
    for (i = 1; i <= L; i++) {
      c = substr(text, i, 1)
      if (st == 1) {
        if (c == "\047") st = 0; else { cur = cur c; if (is_sep(c)) q = 1 }
        continue
      }
      if (st == 2) {
        if (c == "\"") st = 0
        else if (c == "\\" && i < L && substr(text, i + 1, 1) ~ /["\\$`]/) { i++; cur = cur substr(text, i, 1) }
        else { cur = cur c; if (is_sep(c)) q = 1 }
        continue
      }
      if (c == "\\") { if (i < L) { i++; c = substr(text, i, 1); if (c != "\n") { cur = cur c; has = 1 } } continue }
      if (c == "\047") { st = 1; has = 1; continue }
      if (c == "\"") { st = 2; has = 1; continue }
      if (is_sep(c)) {
        if (has) { n++; W[n] = cur; QF[n] = q; SB[n] = ns; ns = 0 }
        cur = ""; has = 0; q = 0
        if (c !~ /[ \t]/) ns = 1
        continue
      }
      cur = cur c; has = 1
    }
    if (has) { n++; W[n] = cur; QF[n] = q; SB[n] = ns }
    return n
  }
  # decide(sc, nxt, depth): "" when allowed, else what was found.
  # A non-`!` alias value is parsed exactly as a command line is: git splits
  # it like a shell and runs it through its own option parser, so
  # `-c k=v stash pop` in an alias pops. The user'"'"'s next word follows it.
  function decide(sc, nxt, depth,    i, v, a, aq, as, n, r) {
    if (sc == "stash") return is_read(nxt) ? "" : "stash"
    if (sc ~ /[$`]/) return "expanded"
    # Alias names are config keys, so git matches them case-insensitively
    # (`git SP` runs alias.sp); --get-regexp prints them lower-cased.
    sc = tolower(sc)
    if (!(sc in nal)) return ""
    # Past the bound, a chain still resolving is treated as a stash write.
    if (depth > 10) return "alias"
    for (i = 1; i <= nal[sc]; i++) {
      v = aval[sc, i]
      # A shell alias runs its body with sh: read the body as a command (so
      # `!git sp` reaches alias sp), and deny any body naming stash at all.
      if (v ~ /^!/) {
        if (mentions_stash(v) || analyze(substr(v, 2), depth + 1) != "") return "alias"
        continue
      }
      n = tokenize(v, a, aq, as)
      if (nxt != "") a[++n] = nxt
      r = git_verdict(a, n, 1, 0, depth + 1)
      if (r != "") return "alias"
    }
    return ""
  }
  # two_word(t): a git global option known to take its value as the NEXT word.
  function two_word(t) {
    return t ~ /^-[Cc]$/ || t ~ /^--(git-dir|work-tree|namespace|config-env|super-prefix|attr-source)$/
  }
  # git_verdict(w, n, j, expanded_head, depth): decide the git invocation
  # whose words are w[j..n]. Known two-word options skip their value. A word
  # right after an UNKNOWN dash option may be that option'"'"'s value (a newer
  # git adds such options: --attr-source did), so it is decided as a candidate
  # AND the scan continues past it. That over-denies `git --flag word stash`,
  # never misses. After an expanded head (`$GIT`) a candidate counts when it
  # is stash or a stash alias.
  function git_verdict(w, n, j, expanded_head, depth,    r) {
    while (j <= n) {
      if (two_word(w[j])) { j += 2; continue }
      if (w[j] ~ /^-/) { j++; continue }
      if (expanded_head) {
        # A word built by expansion may be git: `stash` or a stash alias after
        # it counts. An expanded candidate after it does not (`$EDITOR $FILE`).
        r = decide(w[j], (j + 1 <= n ? w[j + 1] : ""), depth)
        if (r == "stash" || r == "alias") return "expanded-git"
      } else {
        r = decide(w[j], (j + 1 <= n ? w[j + 1] : ""), depth)
        if (r != "") return r
      }
      if (j > 1 && w[j - 1] ~ /^-/ && w[j - 1] !~ /=/ && !two_word(w[j - 1])) { j++; continue }
      break
    }
    return ""
  }
  # analyze(text, depth): the verdict for one command text, and for every
  # quoted word in it that may itself be a command.
  function analyze(text, depth,    W, QF, SB, n, k, e, r, sw, m, i) {
    # Past the nesting bound, text that still names stash is a deny.
    if (depth > 8) return mentions_stash(text) ? "stash" : ""
    n = tokenize(text, W, QF, SB)
    for (k = 1; k <= n; k++) if (QF[k]) { r = analyze(W[k], depth + 1); if (r != "") return r }
    for (k = 1; k <= n; k++) {
      for (e = k; e < n && !SB[e + 1]; e++) ;
      # the words of this simple command from k on, as their own array
      delete sw; m = 0
      for (i = k + 1; i <= e; i++) sw[++m] = W[i]
      # A simple command that starts at `stash` followed a `)` or backtick:
      # the tail of `$(command -v git) stash`.
      if (SB[k] && W[k] == "stash" && !is_read(m >= 1 ? sw[1] : "")) return "stash"
      if (W[k] ~ /(^|\/)git-stash$/ && !is_read(m >= 1 ? sw[1] : "")) return "stash"
      if (W[k] ~ /(^|\/)git$/) r = git_verdict(sw, m, 1, 0, 0)
      else if (W[k] ~ /[$`]/) r = git_verdict(sw, m, 1, 1, 0)
      else r = ""
      if (r != "") return r
    }
    return ""
  }
  BEGIN {
    na = split(ENVIRON["GSG_ALIASES"], lines, "\n")
    for (k = 1; k <= na; k++) {
      l = lines[k]
      if (l !~ /^alias\./) continue
      name = substr(l, 7); val = ""
      sp = index(name, " ")
      if (sp > 0) { val = substr(name, sp + 1); name = substr(name, 1, sp - 1) }
      nal[name]++; aval[name, nal[name]] = val
    }
    r = analyze(ENVIRON["GSG_CMD"], 0)
    if (r != "") print r
  }' 2>/dev/null)

case "$VERDICT" in
  stash) deny 'this runs `git stash` with a verb that writes the stash list (bare `git stash`, push/save, pop, apply, drop, clear, store, branch, or an option-first implicit push).' ;;
  alias) deny 'this runs a git alias that resolves to a stash write (or a shell alias that mentions stash).' ;;
  expanded) deny 'this runs git with a subcommand built by expansion (`git $X`), which may be a stash write and cannot be read here. Write the subcommand literally.' ;;
  expanded-git) deny 'this runs `stash` through a command word built by expansion (`$GIT stash`, `$(command -v git) stash`), which may be git writing the stash list.' ;;
esac
exit 0
