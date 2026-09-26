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
# `git stash -- f`), which are an implicit push. Also the plumbing that
# rewrites the same list without the stash subcommand (see plumb() in the awk
# block): `reflog delete|expire|drop` naming the stash ref in ANY spelling
# (`stash`, `stash@{N}`, `refs/stash`, `refs/stash@{N}`) or given `--all`;
# `update-ref` / `symbolic-ref` on the stash ref, with `--stdin`, or with no
# literal ref (xargs-fed); a fetch/push refspec into the stash ref (either
# spelling) or refs/*; a push naming the stash ref or --mirror;
# filter-branch/filter-repo `--all`; setting gc.reflogExpire*; and a file
# write (rm, mv, cp, a redirect, ...) naming refs/stash.
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
# the hook does not know may be that option's value, so the scan continues past
# it, and every word reachable only that way denies only when it is stash or a
# stash alias (see git_verdict): a new two-word option cannot hide `stash`, and
# `git --no-pager diff $X` stays allowed. Not caught: a subcommand built by
# expansion after an unknown option (`git --new-opt v $X`). Also denied:
#   * a command word built by expansion followed by `stash` or a stash alias
#     (`$GIT stash`, `$GIT sp`, `${GIT:-git} stash`, `$(command -v git) stash`,
#     a backtick form);
#   * `git <expanded subcommand>` (`git $SUB`, a glob `git st?sh`, a brace
#     `git {stash,pop}`): its value is unknowable here, and so is a glob or
#     brace in the stash verb (`git stash l?st`);
#   * a command word the shell rewrites by glob or brace (`/usr/bin/g?t`,
#     `git-st*sh`), in command position (a simple command's first word, or
#     after env/command/sudo/exec/nohup/xargs/time/eval/nice/setsid or a
#     VAR=value), judged both as git and as git-stash (no verb, a writing
#     verb, or an expanded verb is denied). Accepted false positive: a glob
#     command word with no arguments or only options (`./run-*.sh -v`).
#     Not caught: a glob command word after a prefix that takes its own
#     argument (`timeout 5 /usr/bin/g?t stash pop`, `sudo -u x ...`);
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
# ZSH: the Bash tool runs zsh, so zsh-only word rewrites count too: EQUALS
# (`=git` is git's path), global aliases (`alias -g`, any word position),
# suffix aliases (`alias -s`), and the noglob/nocorrect/- precommand modifiers.
#
# SHELL ALIASES: a command word that is a shell alias from the Bash tool's
# shell snapshot (see below) is expanded and read as a command. Shell
# FUNCTIONS from the snapshot are not read (none on this machine names stash).
#
# NOT CATCHABLE (a tripwire, not a sandbox): a string computed then executed
# (`eval "$(printf ...)"`, base64 | sh); both command word and subcommand
# expanded (`$G $S`); a shell alias or function or script file defined in one
# call and run in a later one; another interpreter building argv (`python -c`);
# `--autostash` on rebase/pull/merge, which stores into the list only on a
# conflict and is used by the shipwright (out of scope, proposed separately);
# reflog expiry by `git gc` / `git maintenance` / auto-gc under the EXISTING
# expiry config (default 90 days; any git command can trigger auto-gc);
# `fetch --mirror` into this same repo; a ref-rewriting
# tool other than git (a script writing .git/ files by a computed path); git arguments supplied through a pipe
# (`printf 'stash pop' | xargs git`); an alias defined in a file the command
# only names (`git -c include.path=<file>`, a `.gitconfig` written with the
# Write tool in an earlier call is caught when the alias is USED, since
# aliases are read at decision time).
#
# Design guarantees (mirror forge-identity-guard):
#   * FAIL-OPEN — any error (missing jq, unparseable input, non-Bash tool, no
#     match) exits 0 and ALLOWS. A deny is only emitted on a positive match.
#     A crash of the evaluator itself is not silent: it allows with an
#     additionalContext saying the guard did not run.
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

# ---- shell aliases the Bash tool's shell carries -----------------------------
# The Bash tool sources a shell snapshot of the owner's profile before every
# command, aliases included; here oh-my-zsh's git plugin defines
# `gstp='git stash pop'`, `gstd`, `gstc`, `gsta`... So a command word may be a
# shell alias that expands to a stash write. The aliases are read from the same
# snapshots (every one on disk, so another session's snapshot counts too) and
# kept only when their value could matter (git, stash, an expansion, a glob,
# or a chain to such an alias).
# No snapshot dir means the Bash tool loads no aliases either.
SNAPDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/shell-snapshots"
SHALIASES=""
if [ -d "$SNAPDIR" ]; then
  # Relevant: a value naming git, stash, an expansion or a glob, or one whose
  # first word is itself a relevant alias (a chain), to a fixpoint.
  SHALIASES=$(find "$SNAPDIR" -maxdepth 1 -type f -name 'snapshot-*.sh' -exec grep -hE '^alias (-[gs] )?(-- )?[^=[:space:]]+=' {} + 2>/dev/null \
    | awk '
      { l = $0; sub(/^alias (-[gs] )?(-- )?/, "", l); eq = index(l, "=")
        name[NR] = substr(l, 1, eq - 1); v = substr(l, eq + 1); gsub(/\047|"/, "", v)
        split(v, w, /[ \t]+/); first[NR] = w[1]; line[NR] = $0
        if (v ~ /git|stash|[$`*?[{]/) rel[name[NR]] = 1 }
      END {
        do { grew = 0
          for (i = 1; i <= NR; i++) if (!(name[i] in rel) && (first[i] in rel)) { rel[name[i]] = 1; grew = 1 }
        } while (grew)
        for (i = 1; i <= NR; i++) if (name[i] in rel) print line[i]
      }')
fi
# A word naming one of those aliases also lets the command past the prefilter.
SHALIAS_RE=""
if [ -n "$SHALIASES" ]; then
  # A suffix alias (`alias -s ext=...`) is matched as `.ext` at a word's end.
  SHALIAS_RE=$(printf '%s\n' "$SHALIASES" | sed -E 's/^alias (-[gs] )?(-- )?([^=]+)=.*/\3/' \
    | sed -e 's/[][\.*^$+?(){}|/]/\\&/g' | paste -sd'|' -)
  SHALIAS_RE="|(^|[^[:alnum:]_.-]|[.])($SHALIAS_RE)([^[:alnum:]_.-]|\$)"
fi
# A glob or brace can also build a command word (`/usr/bin/g?t`).
printf '%s' "$FLAT" | grep -Eq "stash|$GIT_OR_EXP|[*?[{]$SHALIAS_RE" || exit 0

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

# ---- setting reflog expiry ---------------------------------------------------
# gc.reflogExpire / gc.reflogExpireUnreachable (also the per-pattern
# gc.<pattern>.reflogExpire forms) decide when `git gc`, `git maintenance` and
# auto-gc expire reflog entries, the stash list's included. Setting one, inline
# (`-c gc.reflogExpire=now gc`) or in config, is denied.
if printf '%s' "$FLAT" | grep -Eiq 'gc\.([^[:space:]=]+\.)?reflogexpire'; then
  deny 'this command sets gc reflog expiry (gc.reflogExpire / gc.reflogExpireUnreachable), which makes `git gc` or `git maintenance` expire stash list entries. Leave reflog expiry at its configured value.'
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
if printf '%s' "$FLAT" | grep -Eq "$GIT_OR_EXP|[*?[{]$SHALIAS_RE"; then
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
VERDICT=$(GSG_CMD="$CMD" GSG_ALIASES="$ALIASES" GSG_SHALIASES="$SHALIASES" awk '
  function is_read(v) { sub(/[<>].*/, "", v); return v ~ /^(list|show|create)$/ }
  function mentions_stash(v) { return v ~ /(^|[^[:alnum:]_.-])stash([^[:alnum:]_.-]|$)/ }
  function is_sep(c) { return c ~ /[ \t\n;&|()`]/ }
  # tokenize(text, W, QF, SB): split text into shell words, honouring quotes
  # and backslashes the way sh does, so a quoted value stays ONE word
  # (`git -C "/a b" stash` is git, -C, /a b, stash). Quotes and backslashes are
  # removed from the word. SB[k] is 1 when word k starts a simple command
  # (after ; & | ( ) backtick or a newline, outside quotes). Redirections
  # (operator, fd number and target) are dropped, as sh drops them from argv.
  # An unquoted glob
  # or brace character is followed by a \001 mark. QF[k] is 1 when a
  # quoted part of word k held whitespace or a separator: its content may be a
  # command (`sh -c "git stash"`), so analyze re-reads it.
  function tokenize(text, W, QF, SB,    n, i, L, c, st, cur, has, q, ns, skip) {
    n = 0; st = 0; cur = ""; has = 0; q = 0; ns = 1; skip = 0; L = length(text)
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
      # zsh EQUALS (on by default; the Bash tool runs zsh): an unquoted
      # leading `=name` expands to the path of command `name`, so `=git` is
      # git. The `=` is dropped.
      if (c == "=" && !has && substr(text, i + 1, 1) ~ /[A-Za-z0-9_.\/-]/) continue
      if (c == "\047") { st = 1; has = 1; continue }
      if (c == "\"") { st = 2; has = 1; continue }
      # A redirection is removed by the shell before the command sees its
      # argv, so neither the operator nor its target is a word: `git
      # stash>/dev/null pop` and `git 2>/dev/null stash pop` are `git stash
      # pop`. An fd number joined to the operator (`2>`) goes with it, and the
      # next word (the target) is dropped. `&>` / `&>>` are redirections, not
      # a `&` separator. A process substitution (`<(...)`, `>(...)`) is not a
      # redirection: its body is read as a command.
      if (c ~ /[<>]/ || (c == "&" && substr(text, i + 1, 1) == ">")) {
        if (c == "&") i++
        if (has && cur !~ /^[0-9]+$/) {
          if (skip) skip = 0; else { n++; W[n] = cur; QF[n] = q; SB[n] = ns; ns = 0 }
        }
        cur = ""; has = 0; q = 0
        if (substr(text, i + 1, 1) == "(") continue
        while (i < L && substr(text, i + 1, 1) ~ /[<>&|-]/) i++
        skip = 1
        continue
      }
      if (is_sep(c)) {
        if (has) {
          if (skip) skip = 0; else { n++; W[n] = cur; QF[n] = q; SB[n] = ns; ns = 0 }
        }
        cur = ""; has = 0; q = 0
        if (c !~ /[ \t]/) { ns = 1; skip = 0 }
        continue
      }
      # An unquoted glob or brace character means the shell rewrites the word
      # before the command sees it (`git {stash,pop}`, `git st?sh`). Mark it
      # with \001 so the word counts as built by expansion.
      if (c ~ /[*?[{]/) { cur = cur c "\001"; has = 1; continue }
      cur = cur c; has = 1
    }
    if (has && !skip) { n++; W[n] = cur; QF[n] = q; SB[n] = ns }
    return n
  }
  # refpart(t): the ref a revision/refspec word names: glob marks, a leading
  # `+` and any `@{...}` reflog selector removed (`stash@{0}` -> stash).
  function refpart(t) { gsub(/\001/, "", t); sub(/^\+/, "", t); sub(/@\{.*$/, "", t); return t }
  # is_stash_ref(t): t names the stash ref in either spelling git accepts.
  function is_stash_ref(t) { t = refpart(t); return t == "stash" || t == "refs/stash" }
  # plumb(sc, w, n, j): "refwrite" when git plumbing sc (= w[j]) with
  # arguments w[j+1..n] rewrites or expires the stash ref or its reflog
  # without the stash subcommand. A ref argument that is the stash ref in any
  # spelling (`stash`, `stash@{N}`, `refs/stash`, `refs/stash@{N}`), `--all`,
  # `update-ref --stdin` (a batch this hook cannot read), an argument built by
  # expansion, or NO ref argument at all (refs supplied by xargs or a pipe)
  # all count. fetch/push: a refspec whose destination is the stash ref in
  # either spelling or a `refs/*` / `*` glob; for push also a bare stash ref
  # word (`--delete stash`) and `--mirror`. filter-branch/filter-repo:
  # `--all` (it rewrites every ref).
  function plumb(sc, w, n, j,    k, t, start, nargs, dst) {
    if (sc == "reflog") {
      if (j + 1 > n || w[j + 1] !~ /^(delete|expire|drop)$/) return ""
      start = j + 2
    } else if (sc == "update-ref" || sc == "symbolic-ref") {
      start = j + 1
    } else if (sc == "fetch" || sc == "push") {
      # A refspec destination (after the last `:`) that is the stash ref in
      # either spelling, or a whole-namespace glob. A push also resolves a
      # bare ref word against the target repo (`push . --delete stash`,
      # `push . stash` both reach refs/stash), and `--mirror` rewrites every
      # ref, so for push any stash word or --mirror counts.
      for (k = j + 1; k <= n; k++) {
        if (sc == "push" && w[k] == "--mirror") return "refwrite"
        if (w[k] ~ /^-/) continue
        if (w[k] ~ /:/) {
          dst = w[k]; sub(/^.*:/, "", dst)
          if (is_stash_ref(dst) || refpart(dst) ~ /^(refs\/)?\*$/) return "refwrite"
        } else if (sc == "push" && is_stash_ref(w[k])) return "refwrite"
      }
      return ""
    } else if (sc ~ /^filter-(branch|repo)$/) {
      for (k = j + 1; k <= n; k++) if (w[k] == "--all") return "refwrite"
      return ""
    } else return ""
    nargs = 0
    for (k = start; k <= n; k++) {
      t = w[k]
      if (t == "--all" || t == "--stdin") return "refwrite"
      if (t ~ /^-/) continue
      nargs++
      if (t ~ /[$`]/ || is_stash_ref(t)) return "refwrite"
    }
    return nargs == 0 ? "refwrite" : ""
  }
  # decide(sc, w, n, j, depth): "" when allowed, else what was found, for the
  # git subcommand sc (= w[j]) with arguments w[j+1..n].
  # A non-`!` alias value is parsed exactly as a command line is: git splits
  # it like a shell and runs it through its own option parser, so
  # `-c k=v stash pop` in an alias pops. The user'"'"'s remaining words follow it.
  function decide(sc, w, n, j, depth,    i, k, v, a, aq, as, na, r) {
    if (sc == "stash") return is_read(j + 1 <= n ? w[j + 1] : "") ? "" : "stash"
    if (sc ~ /[$`\001]/) return "expanded"
    r = plumb(sc, w, n, j)
    if (r != "") return r
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
      na = tokenize(v, a, aq, as)
      for (k = j + 1; k <= n; k++) a[++na] = w[k]
      r = git_verdict(a, na, 1, 0, depth + 1)
      if (r != "") return "alias"
    }
    return ""
  }
  # two_word(t): a git global option known to take its value as the NEXT word.
  function two_word(t) {
    return t ~ /^-[Cc]$/ || t ~ /^--(git-dir|work-tree|namespace|config-env|super-prefix|attr-source)$/
  }
  # one_word(t): a git global option known to take NO value (git 2.55 usage,
  # plus the pathspec switches from git(1)).
  function one_word(t) {
    return t ~ /^(-[pPvh]|--(paginate|no-pager|bare|no-replace-objects|no-lazy-fetch|no-optional-locks|no-advice|literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|html-path|man-path|info-path|exec-path|version|help))$/
  }
  # git_verdict(w, n, j, expanded_head, depth): decide the git invocation
  # whose words are w[j..n]. The joint rule (DND-670 critic rounds 1 and 7):
  #   * a word is the DEFINITE subcommand when every word before it is a known
  #     option or a known option'"'"'s value; it is decided in full (stash, a
  #     stash alias, or a subcommand built by expansion all deny);
  #   * a word that is the subcommand only if an UNKNOWN option (a newer git
  #     adds such options: --attr-source did) takes no value, or that follows
  #     one as a possible value, is a POSSIBLE subcommand: it denies only when
  #     it is stash, a stash alias, or plumbing that rewrites the stash ref.
  #     The scan continues past a possible value.
  # So a new two-word option cannot hide `stash`, and `git --no-pager diff $X`
  # is not denied. An expanded head (`$GIT`) makes every candidate possible.
  function git_verdict(w, n, j, expanded_head, depth,    r, unknown, maybe_value) {
    unknown = expanded_head
    while (j <= n) {
      if (two_word(w[j])) { j += 2; continue }
      if (w[j] ~ /^-/) {
        if (w[j] !~ /=/ && !one_word(w[j])) unknown = 1
        j++; continue
      }
      r = decide(w[j], w, n, j, depth)
      maybe_value = (j > 1 && w[j - 1] ~ /^-/ && w[j - 1] !~ /=/ && !two_word(w[j - 1]) && !one_word(w[j - 1]))
      if (unknown) {
        if (r == "stash" || r == "alias" || r == "refwrite") return (expanded_head ? "expanded-git" : r)
      } else if (r != "") return r
      if (maybe_value) { j++; continue }
      break
    }
    return ""
  }
  # cmd_prefix(t): a word after which the next word is still a command word.
  function cmd_prefix(t) {
    return t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t ~ /^(env|command|sudo|exec|nohup|xargs|time|eval|builtin|nice|setsid|noglob|nocorrect|-|then|do|else|if|while|until|!)$/
  }
  # squote(w): w as one single-quoted shell word.
  function squote(w) { gsub(/\047/, "\047\\\047\047", w); return "\047" w "\047" }
  function analyze(text, depth,    W, QF, SB, n, k, e, r, sw, m, i, cp, t) {
    # Past the nesting bound, text that still names stash is a deny.
    if (depth > 8) return mentions_stash(text) ? "stash" : ""
    n = tokenize(text, W, QF, SB)
    for (k = 1; k <= n; k++) if (QF[k]) { r = analyze(W[k], depth + 1); if (r != "") return r }
    cp = 0
    for (k = 1; k <= n; k++) {
      # cp: word k is in command position (starts a simple command, or
      # follows a prefix such as env/sudo/xargs or a VAR=value assignment).
      cp = SB[k] || (cp && k > 1 && cmd_prefix(W[k - 1]))
      for (e = k; e < n && !SB[e + 1]; e++) ;
      # A shell alias in command position: read its value, followed by the
      # rest of this simple command, as a command of its own.
      if (cp && (W[k] in shal)) {
        t = shal[W[k]]
        for (i = k + 1; i <= e; i++) t = t " " squote(W[i])
        if (analyze(t, depth + 1) != "") return "shell-alias"
      }
      # A zsh SUFFIX alias (`alias -s ext=cmd`): a command word `x.ext` runs
      # `cmd x.ext ...`.
      if (cp && match(W[k], /\.[^.\/]+$/) && ((t = substr(W[k], RSTART + 1)) in sal)) {
        t = sal[t]
        for (i = k; i <= e; i++) t = t " " squote(W[i])
        if (analyze(t, depth + 1) != "") return "shell-alias"
      }
      # the words of this simple command from k on, as their own array
      delete sw; m = 0
      for (i = k + 1; i <= e; i++) sw[++m] = W[i]
      # A simple command that starts at `stash` followed a `)` or backtick:
      # the tail of `$(command -v git) stash`.
      if (SB[k] && W[k] == "stash" && !is_read(m >= 1 ? sw[1] : "")) return "stash"
      if (W[k] ~ /(^|\/)git-stash$/ && !is_read(m >= 1 ? sw[1] : "")) return "stash"
      # A command word the shell rewrites by glob or brace (`/usr/bin/g?t`,
      # `git-st*sh`) may be git or may be git-stash, so it is judged as both:
      # as git-stash, no verb (a bare or option-first push), a writing verb,
      # or a verb built by expansion is denied; as git, the usual verdict.
      if (cp && W[k] ~ /\001/) {
        for (i = 1; i <= m && sw[i] ~ /^-/; i++) ;
        if (i > m || sw[i] ~ /^(push|save|pop|apply|drop|clear|store|branch)$/ || sw[i] ~ /[$`\001]/) return "glob-head"
        if (git_verdict(sw, m, 1, 0, 0) != "") return "glob-head"
        continue
      }
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
    ns = split(ENVIRON["GSG_SHALIASES"], slines, "\n")
    for (k = 1; k <= ns; k++) {
      l = slines[k]
      kind = (l ~ /^alias -g /) ? "g" : ((l ~ /^alias -s /) ? "s" : "")
      sub(/^alias (-[gs] )?(-- )?/, "", l)
      eq = index(l, "="); if (eq == 0) continue
      name = substr(l, 1, eq - 1)
      # The value is shell text (usually one single-quoted word): its words,
      # unquoted, are the command the alias runs.
      nv = tokenize(substr(l, eq + 1), vw, vq, vs)
      val = ""
      for (i = 1; i <= nv; i++) val = val (i > 1 ? " " : "") vw[i]
      if (kind == "g") gal[name] = val
      else if (kind == "s") sal[name] = val
      else shal[name] = val
    }
    cmd = ENVIRON["GSG_CMD"]
    r = analyze(cmd, 0)
    # zsh GLOBAL aliases (`alias -g`) expand in any word position, not only
    # command position: also read the command with each one substituted
    # wherever it stands as a whole word (a quoted occurrence is substituted
    # too, which can only over-deny).
    if (r == "") {
      g = cmd; hit = 0
      for (name in gal) {
        re = name; gsub(/[][\\.^$*+?(){}|\/]/, "\\\\&", re)
        while (match(g, "(^|[ \t\n;&|()`])" re "([ \t\n;&|()`]|$)")) {
          pre = substr(g, 1, RSTART - 1); m0 = substr(g, RSTART, RLENGTH)
          lead = substr(m0, 1, 1); if (lead !~ /[ \t\n;&|()`]/) lead = ""
          tail = substr(m0, RLENGTH, 1); if (tail !~ /[ \t\n;&|()`]/) tail = ""
          g = pre lead gal[name] tail substr(g, RSTART + RLENGTH); hit = 1
        }
      }
      if (hit) { r = analyze(g, 1); if (r != "") r = "shell-alias" }
    }
    if (r != "") print r
  }' 2>/dev/null)
AWK_RC=$?

# An evaluator that crashed must not read as "nothing found". The command is
# still allowed (fail-open), but the session is told the guard did not run.
if [ "$AWK_RC" -ne 0 ]; then
  jq -cn --arg c "git-stash-guard: could not evaluate this command (its awk evaluator exited $AWK_RC), so it was ALLOWED unchecked. Fix: run \`sh ~/dev/custom/ai/hooks/git-stash-guard.self-test.sh\` and report the failure to your admiral; do not run a stash write meanwhile." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null
  exit 0
fi

case "$VERDICT" in
  refwrite) deny 'this runs git plumbing that rewrites or expires the stash ref or its reflog without the stash subcommand: `reflog delete|expire|drop` naming `stash`/`stash@{N}`/`refs/stash` or given `--all`, `update-ref`/`symbolic-ref` on the stash ref (or with `--stdin`, or with refs supplied from elsewhere), a fetch/push refspec whose destination is the stash ref (either spelling) or refs/*, a push naming the stash ref (`push . --delete stash`) or `--mirror`, or filter-branch/filter-repo `--all`.' ;;
  stash) deny 'this runs `git stash` with a verb that writes the stash list (bare `git stash`, push/save, pop, apply, drop, clear, store, branch, or an option-first implicit push).' ;;
  shell-alias) deny 'this runs a shell alias loaded into the Bash tool from the owner profile (oh-my-zsh defines `gstp` = `git stash pop`) that expands to a stash write.' ;;
  alias) deny 'this runs a git alias that resolves to a stash write (or a shell alias that mentions stash).' ;;
  expanded) deny 'this runs git with a subcommand built by expansion (`git $X`, a glob `git st?sh`, a brace `git {stash,pop}`), which may be a stash write and cannot be read here. Spell the subcommand (and a stash verb) out literally, quoting any glob or brace characters.' ;;
  glob-head) deny 'this runs a command word the shell rewrites by glob or brace expansion (`/usr/bin/g?t`, `git-st*sh`), which may be git or git-stash writing the stash list. Spell the command word literally.' ;;
  expanded-git) deny 'this runs `stash` through a command word built by expansion (`$GIT stash`, `$(command -v git) stash`), which may be git writing the stash list.' ;;
esac
exit 0
