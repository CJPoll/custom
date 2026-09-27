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
# quotes. A quoted word that held whitespace or a separator, and a heredoc
# body, is re-read as a command of its own (`sh -c 'git stash'`, nested
# `bash -c "... \"...\" ..."`), in data mode unless the shell may run it
# (see QUOTED PAYLOADS ARE DATA).
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
#     value names stash (`git -c alias.p=stash p`, `git config alias.p ...`);
#   * a subcommand that is not a git builtin (nor a git-* command on PATH, per
#     `git --list-cmds`) when the command points git at a config the hook
#     does not read: `--git-dir`, GIT_DIR, GIT_COMMON_DIR, GIT_CONFIG*,
#     HOME, XDG_CONFIG_HOME, `include.path` / `includeIf.*.path`, a bare `cd`
#     / `cd -` / `popd`, a `cd` / `pushd` / `-C` target that is expanded
#     (`cd "$D"`) or holds whitespace, an alias definition whose value holds
#     an expansion (`-c alias.p="$V"`, `git config alias.p "$V"`), or a
#     `-c` / `--config-env` argument that holds one (`-c "$KV"`). An alias
#     defined there cannot be read, so it is treated as unknown rather than
#     absent. Builtins stay allowed. A value built by COMMAND SUBSTITUTION
#     (`-c alias.p=$(...)`, a backtick) is denied outright, used or not.
#   * git's own rewrite of a subcommand: help.autocorrect makes git RUN the
#     closest command for a typo (`git stsh pop` runs `git stash pop`).
#     Setting it in the command is denied; when a config the hook reads has
#     it on, a subcommand that is neither a builtin nor a known alias is
#     denied like the unread-config case above.
#   * RESIDUAL — LEXICAL INDIRECTION: this is a text guard. Every rule above
#     reads the command's text; a stash write whose spelling is assembled at
#     run time from pieces the text does not show is out of its reach (see
#     NOT CATCHABLE). The expansion rules are a backstop for the alias forms,
#     not a proof: an alias definition or config source the hook cannot read
#     literally makes every non-builtin subcommand unknown.
#
# ACCEPTED FALSE POSITIVE (the class forge-auth-guard documents): matching is
# lexical, so a command that only MENTIONS a LITERAL mutating stash (a
# heredoc, a `git commit -m`, a `grep`) is denied too. That costs one retry:
# write the command to a script file with the Write tool and run `bash
# <file>` (a commit message goes to a file passed to `git commit -F`). The
# deny text names no tool a captain lacks (no Grep tool; DND-799). A miss
# costs the owner's saved work.
#
# QUOTED PAYLOADS ARE DATA (DND-799): a quoted argument or a quoted heredoc
# body that the shell will not execute is read in DATA mode. Every spelling
# that NAMES the write still denies there: a literal stash write, stash-ref
# plumbing, a stash alias, and a glob or expanded command word followed by
# a literal stash verb or a stash-write subcommand (`/usr/bin/g?t stash
# pop`, `$GIT stash pop`). What data mode drops is the rest of the
# expansion rules: a glob or brace command word with no arguments or with
# expanded ones (`.[]`, `{print $1}`, `{{.A}} {{.B}}`), a subcommand built
# by expansion (`git $SUB`), and an unread config. So jq/awk/grep/curl
# payloads and python/ruby heredocs with brackets and braces are allowed.
# Data mode FAILS CLOSED: a payload is data only when every command word in
# its text is a PURE DATA tool (safe_word(): a tool that runs no program in
# any form, a text or file utility, a keyword, an interpreter). Any other
# command word makes it EXEC and read in full, including git, gh, glab,
# docker, sed, rg, sort and wget whatever their subcommand (admiral
# decision after critic round 10: per-tool read lists were deleted; the
# relief they gave for git/gh/docker/sed pipelines returns with DND-775).
# So is a payload holding a command substitution, and an unquoted or
# unterminated heredoc. The arguments of a test (`[`, `[[`, `test`) are
# data too.
#   RESIDUAL (data mode), a deliberate reduction from cbac851/d8cf63e,
#   which read every payload in full: a stash write that names NO stash
#   verb (a glob git-stash word bare or with options only, `git-st*sh -u`;
#   a glob or expanded git word with an expanded subcommand, `g?t $S`,
#   `git $S`) inside DATA that some OTHER program in the same call runs was
#   caught before and is not now. The evaluators the text cannot model are
#   the general class "a file or string written in this call and then
#   executed": an interpreter that runs its argument or its stdin
#   (`python3 -c`, `ruby -e`, `perl -e`, `node -e`, `awk system()`, or a
#   heredoc/script fed to one), and a file written to disk and then run --
#   by git (a config-named program, a repo hook that even a read-only git
#   fires), by the shell through PATH (a script written to a bin dir and
#   run by its bare name), or by any later command. The literal and
#   verb-naming spellings still deny, and a command word holding `/` is
#   exec. This is the same class NOT CATCHABLE names (a script defined in
#   one call and run in another; another interpreter building argv).
#   OWNER DECISION (the record this reduction needs; critic rounds 12-13):
#     Owner: Cody. Time: 2026-09-27 ~07:20Z. Source: the laptop
#     coordinator session (terminal), relayed by the main session.
#     Question: "Accept the DND-799 text-guard residual (a string or file
#     written in the same command and then executed — e.g. python3 -c, a
#     repo hook git fires, a script written then run) until DND-775 is
#     activated, with DND-905 as the fallback if activation slips past
#     2026-10-04?"
#     Answer: "approved".
#   DND-775 (the git-level guard on refs/stash, injected into agent
#   sessions) is the enforcement that closes the whole class below the
#   text; DND-905 is the text-layer fallback if its activation slips past
#   2026-10-04.
#
# PRECISION (DND-780, narrow cut): the leading test bracket `[` / `[[` and
# the lone brace-group word `{` are not glob command words (as globs they
# match only themselves; the word after `{` keeps command position); the
# `?` of `$?` is not a glob; a word shaped like an assignment (`rc=$?`,
# `a[1]=x`, `a+=x`) gives the next word command position (it is still
# judged itself); a word whose expansions are all inside double
# quotes, each a bare `$NAME` or `${NAME}` directly followed by `/`, and
# whose last path component is plain (`"$W/t"`), is that literal name. When
# several rules fire, the most specific finding is reported (a literal
# `git stash pop` is named as such after an unrelated `$(...)`), and every
# reason ends with `Matched: <words> at word N of the command`. Every other
# glob or brace command word is judged as at cbac851.
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
# (`printf 'stash pop' | xargs git`). An alias in a config the command only
# names (`-c include.path=<file>`, `--git-dir`, HOME=...) is not read; its
# non-builtin subcommand is denied instead (see above). A `.gitconfig` written
# with the Write tool in an earlier call is caught when the alias is USED,
# since aliases are read at decision time.
#
# Design guarantees:
#   * NOT A STASH COMMAND, ALLOW — unparseable input, missing jq (nothing can
#     be emitted without it), a non-Bash tool, or no match exits 0 and allows.
#   * BOUNDED HAND-OFF — no data of unbounded size reaches another process
#     through argv or the environment. The kernel refuses (E2BIG) any single
#     argv or environment string over MAX_ARG_STRLEN (128 KiB), and the tool
#     then never runs. Measured 2026-09-26: the desktop's shell snapshots held
#     ~172 KB of aliases, handed to the evaluator in one env var; awk exited
#     126 and every command was allowed. So the command, the aliases and the
#     alias-name patterns go into files under a private mktemp dir (removed on
#     exit by trap) and are read from there; argv carries only those paths.
#     Snapshot aliases are deduplicated (every snapshot on disk repeats them).
#   * AN EVALUATION FAULT IS NOT "NOTHING FOUND" — a helper that fails (the
#     evaluator or the snapshot reader exits non-zero, a grep errors, the
#     global git config cannot be read, a work file cannot be written or
#     read) is a FAULT. On a fault the hook falls back to a lexical verdict:
#     it DENIES when the command text names `stash` as a word, or names a
#     shell or git alias whose value names stash; otherwise it ALLOWS with an
#     additionalContext saying the guard did not run. Why not deny every
#     command on a fault: most faults are persistent (a missing tool, an
#     oversize input, a corrupt config) and hit every command the prefilter
#     passes, which is every `git` or `$` command in every agent session on
#     the machine, the self-test and the fix included. Why not allow: that is
#     the defect this replaced, a guard that switched itself off on exactly
#     the unusual input nobody tested. The fallback keeps the incident class
#     (a literal stash write, or an alias spelling one) closed during a fault,
#     at the cost of also denying stash READS until the fault is fixed.
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

# Work files (see BOUNDED HAND-OFF). FAULT names the first evaluation fault.
FAULT=""
GSG_TMP=$(mktemp -d 2>/dev/null) || GSG_TMP=""
if [ -n "$GSG_TMP" ] && [ -d "$GSG_TMP" ]; then
  trap 'rm -rf "$GSG_TMP"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  : > "$GSG_TMP/shaliases"; : > "$GSG_TMP/shalias.re"; : > "$GSG_TMP/aliases"
  : > "$GSG_TMP/autocorrect"
  printf '%s' "$CMD" > "$GSG_TMP/cmd" || FAULT="the command could not be written to a work file"
else
  GSG_TMP=""; FAULT="mktemp could not create a work dir"
fi

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
if [ -z "$FAULT" ] && [ -d "$SNAPDIR" ]; then
  # Deduplicated: every snapshot on disk repeats the owner's alias set. One
  # name may still carry several values (snapshots of different profiles),
  # and each value counts.
  find "$SNAPDIR" -maxdepth 1 -type f -name 'snapshot-*.sh' -exec grep -hE '^alias (-[gs] )?(-- )?[^=[:space:]]+=' {} + \
    > "$GSG_TMP/shaliases.raw" 2>/dev/null
  sort -u "$GSG_TMP/shaliases.raw" > "$GSG_TMP/shaliases.uniq" 2>/dev/null \
    || FAULT="the shell snapshot aliases could not be sorted"
  # Relevant: a value naming git, stash, an expansion or a glob, or one whose
  # first word is itself a relevant alias (a chain), to a fixpoint.
  [ -n "$FAULT" ] || awk '
      { l = $0; sub(/^alias (-[gs] )?(-- )?/, "", l); eq = index(l, "=")
        name[NR] = substr(l, 1, eq - 1); v = substr(l, eq + 1); gsub(/\047|"/, "", v)
        split(v, w, /[ \t]+/); first[NR] = w[1]; line[NR] = $0
        if (v ~ /git|stash|[$`*?[{]/) rel[name[NR]] = 1 }
      END {
        do { grew = 0
          for (i = 1; i <= NR; i++) if (!(name[i] in rel) && (first[i] in rel)) { rel[name[i]] = 1; grew = 1 }
        } while (grew)
        for (i = 1; i <= NR; i++) if (name[i] in rel) print line[i]
      }' "$GSG_TMP/shaliases.uniq" > "$GSG_TMP/shaliases" 2>/dev/null \
    || FAULT="${FAULT:-the shell snapshot aliases could not be read (awk failed)}"
fi
# A word naming one of those aliases also lets the command past the prefilter:
# one pattern per line, in a file (a name list can pass 128 KiB). A suffix
# alias (`alias -s ext=...`) is matched as `.ext` at a word's end.
if [ -z "$FAULT" ] && [ -s "$GSG_TMP/shaliases" ]; then
  sed -E 's/^alias (-[gs] )?(-- )?([^=]+)=.*/\3/' "$GSG_TMP/shaliases" \
    | sed -e 's/[][\.*^$+?(){}|/]/\\&/g' -e 's/.*/(^|[^[:alnum:]_.-]|[.])(&)([^[:alnum:]_.-]|$)/' \
    | sort -u > "$GSG_TMP/shalias.re" 2>/dev/null \
    || FAULT="the shell alias patterns could not be written"
fi
# prefilter <extra ERE> : does FLAT match the extra pattern, a glob/brace
# character, or a relevant shell alias name? 0 yes, 1 no, 2 grep failed.
prefilter() {
  if [ -n "$GSG_TMP" ]; then
    printf '%s' "$FLAT" | grep -Eq -e "$1" -e '[*?[{]' -f "$GSG_TMP/shalias.re" 2>/dev/null
  else
    printf '%s' "$FLAT" | grep -Eq -e "$1" -e '[*?[{]' 2>/dev/null
  fi
}

# Appended to the aliases work file. `git config --get-regexp` exits 1 when
# nothing matches; any other non-zero exit is an error.
# The same reads collect help.autocorrect into its own work file (see the
# header); the function's status is the alias read's.
alias_read() {
  if [ -n "$1" ] && [ -d "$1" ]; then
    git -C "$1" config --get-regexp '^alias\.' >> "$GSG_TMP/aliases" 2>/dev/null
    _ar=$?
    git -C "$1" config --get-regexp '^help\.autocorrect$' >> "$GSG_TMP/autocorrect" 2>/dev/null
    return $_ar
  else
    (cd / && { git config --get-regexp '^alias\.' >> "$GSG_TMP/aliases" 2>/dev/null
      _ar=$?
      git config --get-regexp '^help\.autocorrect$' >> "$GSG_TMP/autocorrect" 2>/dev/null
      exit $_ar; })
  fi
}

deny() {
  jq -cn --arg r "git-stash-guard: $1 Every linked worktree shares ONE stash list with the main checkout (refs/stash lives in the common git dir), so a stash push/pop/apply/drop from a fleet worktree can apply, drop or clobber the OWNER's saved work with no error (DND-670: a captain's \`git stash pop\` popped the owner's PT-822 entry). Agent sessions never write the stash list. Fix: to park WIP, commit it on your worktree branch (\`git add -A && git commit -m \"WIP: <what>\"\`; squash or amend it later); for a clean tree to experiment in, add a scratch tree with \`git worktree add <path> -b <scratch-branch>\` and remove it after. Read-only \`git stash list\`, \`git stash show\` and \`git stash create\` stay allowed. If this command only MENTIONS stash text (a heredoc, a commit message, a grep) and writes no stash, write the command to a script file with the Write tool and run \`bash <file>\` (for a commit message, write it to a file and pass \`git commit -F <file>\`); never rephrase a real stash command to slip past this guard." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
    2>/dev/null
  exit 0
}

# fault_verdict : the lexical fallback on an evaluation fault (see the header).
# Denies when the command names `stash` as a word, or names (as a whole word)
# a shell or git alias whose value names stash, from whatever alias files were
# read before the fault. Otherwise allows, saying the guard did not run.
fault_verdict() {
  if printf '%s' "$FLAT" | grep -Eq '(^|[^[:alnum:]_.-])stash([^[:alnum:]_.-]|$)'; then
    deny "this command names \`stash\`, and the guard could not evaluate it ($FAULT), so it fails CLOSED: a read (\`git stash list\`) is denied too until the fault is fixed. Run \`sh ~/dev/custom/ai/hooks/git-stash-guard.self-test.sh\` and report the failure to your admiral."
  fi
  if [ -n "$GSG_TMP" ]; then
    # A fault before the alias reads leaves those files empty: read the git
    # aliases now (a failing read adds nothing), and the snapshot aliases from
    # the deduplicated list, which exists before relevance filtering.
    [ -s "$GSG_TMP/aliases" ] || { alias_read ""; alias_read "$CWD"; }
    { sed -nE '/stash/s/^alias (-[gs] )?(-- )?([^=]+)=.*/\3/p' "$GSG_TMP/shaliases" "$GSG_TMP/shaliases.uniq"
      sed -nE '/^alias\.[^ ]+ .*stash/s/^alias\.([^ ]+) .*/\1/p' "$GSG_TMP/aliases"
    } > "$GSG_TMP/stashnames" 2>/dev/null
    if [ -s "$GSG_TMP/stashnames" ] \
      && printf '%s' "$FLAT" | tr -s '[:space:];&|()<>`' '[\n*]' | grep -Fxiq -f "$GSG_TMP/stashnames" 2>/dev/null; then
      deny "this command names a shell or git alias whose value names stash, and the guard could not evaluate it ($FAULT), so it fails CLOSED. Run \`sh ~/dev/custom/ai/hooks/git-stash-guard.self-test.sh\` and report the failure to your admiral."
    fi
  fi
  jq -cn --arg c "git-stash-guard: could not evaluate this command ($FAULT). It names no stash and no stash alias, so it was ALLOWED unchecked. Fix: run \`sh ~/dev/custom/ai/hooks/git-stash-guard.self-test.sh\` and report the failure to your admiral; do not run a stash write meanwhile." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null
  exit 0
}

[ -z "$FAULT" ] || fault_verdict
# A glob or brace can also build a command word (`/usr/bin/g?t`).
prefilter "stash|$GIT_OR_EXP"
case $? in
  0) ;;
  1) exit 0 ;;
  *) FAULT="the prefilter grep failed"; fault_verdict ;;
esac


# ---- refs/stash rewritten without the stash subcommand ----------------------
# A redirect to /dev/null or an fd duplication writes nothing, so strip both
# before looking for a write operator.
WRITES=$(printf '%s' "$FLAT" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9-]##g')
if printf '%s' "$WRITES" | grep -Eq 'refs/stash' \
  && printf '%s' "$WRITES" | grep -Eq '(update-ref|reflog[[:space:]]+(delete|expire)|>|(^|[[:space:];&|(/])(rm|mv|cp|tee|truncate|unlink|shred|ln|dd|install)[[:space:]])'; then
  deny 'this command rewrites refs/stash (update-ref, reflog delete/expire, or a file write), which is the shared stash list.'
fi

# ---- setting help.autocorrect -----------------------------------------------
# help.autocorrect makes git RUN the closest command for a typo, so with it
# on `git stsh pop` runs `git stash pop`. Setting it (inline `-c`, `git config
# ... help.autocorrect <v>`, `--config-env`) is denied; reading or unsetting
# it is not. When it is already on in config, see UNREAD_CONFIG below.
if printf '%s' "$FLAT" | grep -Eiq 'help\.autocorrect(=|[[:space:]]+[^-[:space:];&|])'; then
  deny 'this command sets git help.autocorrect, which makes git run the closest command for a mistyped subcommand (`git stsh pop` runs `git stash pop`). Leave help.autocorrect at its configured value and spell subcommands out.'
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
# An alias defined in the command whose value (or whose whole -c /
# --config-env argument, after git) is a COMMAND SUBSTITUTION (`...` or
# $(...)): the value is unreadable, and a substitution also splits the
# command into words the evaluator reads as a separate command, so its use
# (`git -c alias.p=$(...) p`) is not seen as git. Denied outright, used or
# not. A plain variable (`alias.p="$V"`) is handled by UNREAD_CONFIG below,
# which denies only a non-builtin subcommand.
if printf '%s' "$FLAT" | grep -Eq \
  -e 'alias\.[^[:space:]=;&|]+[=[:space:]][^;&|]*(`|\$\()' \
  -e '(^|[^[:alnum:]_.-])git[[:space:]]+([^;&|]*[[:space:]])?(-c|--config-env)([[:space:]]+|=)[^[:space:];&|]*(`|\$\()'; then
  deny 'this command defines git config inline (`-c alias.<x>=...`, `-c <key=value>`, `--config-env`, or `git config alias.<x> ...`) from a command substitution (`...` or `$(...)`), whose value this guard cannot read and which may define an alias that writes the stash list. Spell the value out literally, or put it in your git config.'
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
# A dir whose path holds whitespace, or one reached through a variable
# (`cd "$D"`), is not read: it sets UNREAD_CONFIG below instead.
UNREAD_CONFIG=0
prefilter "$GIT_OR_EXP"
case $? in
  0)
    # The global read stands alone, so a repo git refuses to read (dubious
    # ownership, a corrupt repo config) still leaves the global aliases in
    # scope. The GLOBAL read failing is a fault: every git alias is unknown.
    alias_read ""
    _rc=$?
    [ "$_rc" -le 1 ] || { FAULT="the global git config could not be read (git config exited $_rc)"; fault_verdict; }
    alias_read "$CWD"
    # No pathname expansion of the dirs in the hook's own shell.
    set -f
    for _d in $(printf '%s' "$FLAT" | grep -Eo '(^|[[:space:];&|(])(-C|cd|pushd)[[:space:]]+[^[:space:];&|()]+' | sed -E 's#.*(-C|cd|pushd)[[:space:]]+##'); do
      case "$_d" in "~"|"~/"*) _d="$HOME${_d#\~}" ;; esac
      case "$_d" in /*) ;; *) [ -n "$CWD" ] && _d="$CWD/$_d" ;; esac
      alias_read "$_d"
    done
    set +f
    # UNREAD_CONFIG: the command points git at a config this hook does not
    # read (see the header), so a non-builtin subcommand is an unknown alias.
    printf '%s' "$FLAT" | grep -Eq \
      -e '--git-dir' \
      -e '(^|[^[:alnum:]_])(GIT_DIR|GIT_COMMON_DIR|GIT_CONFIG[A-Z_]*|HOME|XDG_CONFIG_HOME)=' \
      -e '(^|[[:space:];&|(])(-C|cd|pushd)[[:space:]]+[^[:space:];&|()]*[$`]' \
      -e '(^|[[:space:];&|(])(cd|pushd|popd)([[:space:]]+-)?[[:space:]]*($|[;&|)])' \
      -e 'alias\.[^[:space:]=;&|]+[=[:space:]][^;&|]*[$`]' \
      -e '(^|[[:space:];&|(])(-c|--config-env)([[:space:]]+|=)[^[:space:];&|]*[$`]' 2>/dev/null
    _rc=$?
    if [ "$_rc" -eq 1 ]; then
      printf '%s' "$FLAT" | grep -Eiq 'include(if[^[:space:]]*)?\.path' 2>/dev/null
      _rc=$?
    fi
    if [ "$_rc" -eq 1 ]; then
      # Whitespace inside a quoted or backslash-escaped cd/pushd/-C target
      # (read from the raw command: FLAT has its quotes removed).
      printf '%s' "$CMD" | grep -Eq \
        -e "(^|[[:space:];&|(])(-C|cd|pushd)[[:space:]]+(\"[^\"]*[[:space:]][^\"]*\"|'[^']*[[:space:]][^']*')" \
        -e '(^|[[:space:];&|(])(-C|cd|pushd)[[:space:]]+[^[:space:];&|()]*\\[[:space:]]' 2>/dev/null
      _rc=$?
    fi
    # help.autocorrect on in a config the hook read (any value but an off
    # one; a valueless key is true): a typo may run stash, so a subcommand
    # that is neither a builtin nor a known alias is treated as unknown.
    if [ "$_rc" -eq 1 ] && [ -s "$GSG_TMP/autocorrect" ] \
      && grep -Eiqv '^help\.autocorrect[[:space:]]+(0|false|no|off|never|show)$' "$GSG_TMP/autocorrect" 2>/dev/null; then
      _rc=0
    fi
    case $_rc in
      0)
        UNREAD_CONFIG=1
        (cd / && git --list-cmds=builtins,main,others,nohelpers) > "$GSG_TMP/builtins" 2>/dev/null \
          || { FAULT="git --list-cmds could not list the builtins"; fault_verdict; }
        ;;
      1) ;;
      *) FAULT="the config-source grep failed"; fault_verdict ;;
    esac
    ;;
  1) ;;
  *) FAULT="the prefilter grep failed"; fault_verdict ;;
esac

# ---- git stash, through every head the header lists -------------------------
# Its inputs are files (BOUNDED HAND-OFF): argv carries only their paths.
VERDICT=$(awk -v cmdf="$GSG_TMP/cmd" -v alf="$GSG_TMP/aliases" -v shf="$GSG_TMP/shaliases" \
  -v cfgov="$UNREAD_CONFIG" -v bif="$GSG_TMP/builtins" '
  # slurp(f): the whole file, lines joined by newlines. An unreadable file
  # exits 3, which the caller reads as a fault.
  function slurp(f,   s, l, n, rc) {
    s = ""; n = 0
    while ((rc = (getline l < f)) > 0) s = (n++ ? s "\n" : "") l
    if (rc < 0) exit 3
    close(f)
    return s
  }
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
  # command (`sh -c "git stash"`), so analyze re-reads it. UX[k] is 1 when
  # word k holds an UNQUOTED `$` (its value may be split into several words).
  # The `?` of `$?` (an exit status, a number) is not a glob and is not
  # marked (DND-780); every other glob character is marked as before.
  # PQ is accepted for call compatibility and left empty.
  # HEREDOCS (DND-799): the body of a `<<` / `<<-` here-document is not
  # tokenized with the command. It is cut out whole: HB[h] is the body of
  # heredoc h (HB[0] is the count), HQ[h] is 1 when the delimiter was quoted
  # (`<<\047EOF\047`, `<<"EOF"`, `<<\EOF`: the body is not expanded) AND the
  # body was terminated. analyze reads each body as a command text of its
  # own. A `<<` after an unquoted word-leading `#` on
  # its line (a comment, or a literal `#` word) or inside `((`/`$[`
  # arithmetic (a shift) is not taken as a heredoc: the lines after it are
  # tokenized with the command, as before.
  function tokenize(text, W, QF, SB, UX, PQ, HB, HQ,    n, i, L, c, st, cur, has, q, ns, skip, ux, wq, hdp, hds, nohd, cm, ar, np, pd, pq, ps, nh, h, pos, nx, line, t, body, bl, term, op, _hd) {
    n = 0; st = 0; cur = ""; has = 0; q = 0; ns = 1; skip = 0; ux = 0; L = length(text)
    wq = 0; hdp = 0; cm = 0; ar = 0; np = 0; nh = 0; HB[0] = 0
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
      if (c == "\\") { wq = 1; if (i < L) { i++; c = substr(text, i, 1); if (c != "\n") { cur = cur c; has = 1 } } continue }
      # zsh EQUALS (on by default; the Bash tool runs zsh): an unquoted
      # leading `=name` expands to the path of command `name`, so `=git` is
      # git. The `=` is dropped.
      if (c == "=" && !has && substr(text, i + 1, 1) ~ /[A-Za-z0-9_.\/-]/) continue
      if (c == "\047") { st = 1; has = 1; wq = 1; continue }
      if (c == "\"") { st = 2; has = 1; wq = 1; continue }
      if (c == "#" && !has) cm = 1
      # A redirection is removed by the shell before the command sees its
      # argv, so neither the operator nor its target is a word: `git
      # stash>/dev/null pop` and `git 2>/dev/null stash pop` are `git stash
      # pop`. An fd number joined to the operator (`2>`) goes with it, and the
      # next word (the target) is dropped. `&>` / `&>>` are redirections, not
      # a `&` separator. A process substitution (`<(...)`, `>(...)`) is not a
      # redirection: its body is read as a command.
      if (c ~ /[<>]/ || (c == "&" && substr(text, i + 1, 1) == ">")) {
        if (c == "&") i++
        # `<<` inside `$[...]` (zsh arithmetic) is a shift, and inside an
        # unclosed `${...}` parameter expansion it is literal text of that
        # one word (`echo ${x#<<'E' }`), not a heredoc (critic round 14).
        # `$((...))` arithmetic is already excluded by `ar`. Over-setting
        # nohd only reads the following lines as commands, which is safe.
        nohd = 0
        _hd = cur; gsub(/\001/, "", _hd)
        if (_hd ~ /\$\[/) nohd = 1
        else if (gsub(/\$\{/, "", _hd) > gsub(/\}/, "", _hd)) nohd = 1
        if (has && cur !~ /^[0-9]+$/) {
          if (skip) { skip = 0; if (hdp) { np++; pd[np] = cur; pq[np] = wq; ps[np] = hds; hdp = 0 } }
          else { n++; W[n] = cur; QF[n] = q; SB[n] = ns; UX[n] = ux; ns = 0 }
        }
        cur = ""; has = 0; q = 0; ux = 0; wq = 0; hdp = 0
        if (substr(text, i + 1, 1) == "(") continue
        op = c
        while (i < L && substr(text, i + 1, 1) ~ /[<>&|-]/) { i++; op = op substr(text, i, 1) }
        if ((op == "<<" || op == "<<-") && !cm && !ar && !nohd) { hdp = 1; hds = (op == "<<-") }
        skip = 1
        continue
      }
      if (is_sep(c)) {
        if (has) {
          if (skip) { skip = 0; if (hdp) { np++; pd[np] = cur; pq[np] = wq; ps[np] = hds; hdp = 0 } }
          else { n++; W[n] = cur; QF[n] = q; SB[n] = ns; UX[n] = ux; ns = 0 }
        }
        cur = ""; has = 0; q = 0; ux = 0; wq = 0
        # `((` opens arithmetic (a `<<` inside it is a shift); `))` closes it.
        if (c == "(" && substr(text, i + 1, 1) == "(") ar++
        else if (c == ")" && substr(text, i + 1, 1) == ")" && ar > 0) { ar--; i++ }
        if (c !~ /[ \t]/) { ns = 1; skip = 0; hdp = 0 }
        if (c == "\n") {
          cm = 0
          # The bodies of the heredocs opened on the line just ended, in
          # order, each up to its delimiter line (tabs stripped for `<<-`).
          pos = i + 1
          for (h = 1; h <= np; h++) {
            body = ""; bl = 0; term = 0
            while (pos <= L) {
              for (nx = pos; nx <= L && substr(text, nx, 1) != "\n"; nx++) ;
              line = substr(text, pos, nx - pos); pos = nx + 1
              t = line; if (ps[h]) sub(/^\t+/, "", t)
              if (t == pd[h]) { term = 1; break }
              body = (bl++ ? body "\n" : "") line
            }
            HB[++nh] = body; HQ[nh] = (pq[h] && term)
          }
          if (np) { np = 0; i = pos - 1 }
        }
        continue
      }
      # An unquoted glob or brace character means the shell rewrites the word
      # before the command sees it (`git {stash,pop}`, `git st?sh`). Mark it
      # with \001 so the word counts as built by expansion.
      if (c == "$") {
        ux = 1; has = 1
        if (substr(text, i + 1, 1) == "?") { cur = cur "$?"; i++; continue }
        cur = cur c; continue
      }
      if (c ~ /[*?[{]/) { cur = cur c "\001"; has = 1; continue }
      cur = cur c; has = 1
    }
    if (has && !skip) { n++; W[n] = cur; QF[n] = q; SB[n] = ns; UX[n] = ux }
    HB[0] = nh
    return n
  }
  # refpart(t): the ref a revision/refspec word names: glob marks, a leading
  # `+` and any `@{...}` reflog selector removed (`stash@{0}` -> stash).
  function refpart(t) { gsub(/\001/, "", t); sub(/^\+/, "", t); sub(/@\{.*$/, "", t); return t }
  # is_assign(t): t has the shape of an assignment word (NAME=...,
  # NAME[i]=..., NAME+=...). Used ONLY to give the next word command
  # position (cmd_prefix), which can only add checks. The glob and
  # expansion rules still judge the word itself: the tokenizer removes
  # quotes, so `"A"=/usr/bin/g?t` (a command word, not an assignment) has
  # the same shape (DND-780 narrow cut, critic round 1).
  function is_assign(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/ }
  # literal_non_git(t, ux): word t holds an expansion only inside double
  # quotes (ux == 0, so it is never split into several words or globbed) and
  # ends in a literal path component that is not git or git-stash
  # (`"$W/t"`). The word is exactly that path, so it is not git.
  # Proven by FORM, not by finding the last `/` (critic rounds 4 and 7: a
  # `/` can sit inside `$(...)`, `${G%/}` or a zsh colon modifier
  # `$G:s/q/t`). Every expansion must be a bare `$NAME` or `${NAME}`
  # directly followed by a literal `/`, whose value can only fill a
  # directory part; after removing those, no `$`, backtick, brace, paren,
  # glob mark or literal-dollar may remain, and the final component must be
  # plain filename characters.
  function literal_non_git(t, ux,    s, b) {
    if (ux) return 0
    s = t
    gsub(/\$[A-Za-z_][A-Za-z0-9_]*\//, "/", s)
    gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\}\//, "/", s)
    if (s ~ /[$`{}()\001\002]/ || s !~ /\//) return 0
    b = s; sub(/^.*\//, "", b)
    return b ~ /^[A-Za-z0-9._+@%,=-]+$/ && b != "git" && b != "git-stash"
  }
  # rank(r): how specific a finding is (lower is more specific). analyze
  # reports the most specific finding in the command, so a literal
  # `git stash pop` is named as such even when an earlier, unrelated
  # expansion also trips a rule (DND-780).
  function rank(r) {
    return r == "stash" ? 1 : r == "refwrite" ? 2 : r == "alias" ? 3 : r == "shell-alias" ? 4 \
      : r == "unread-config" ? 5 : r == "expanded" ? 6 : r == "expanded-git" ? 7 : r == "glob-head" ? 8 : 9
  }
  function better(a, b) { return (b != "" && (a == "" || rank(b) < rank(a))) ? b : a }
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
    # Not an alias we read: absent, unless the command points git at a
    # config we did not read and sc is no builtin (then it is unknown).
    if (!(sc in nal)) return (cfgov && !(sc in builtin)) ? "unread-config" : ""
    # Past the bound, a chain still resolving is treated as a stash write.
    if (depth > 10) return "alias"
    for (i = 1; i <= nal[sc]; i++) {
      v = aval[sc, i]
      # A shell alias runs its body with sh: read the body as a command (so
      # `!git sp` reaches alias sp), and deny any body naming stash at all.
      if (v ~ /^!/) {
        if (mentions_stash(v) || analyze(substr(v, 2), depth + 1, 0) != "") return "alias"
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
        if (r == "stash" || r == "alias" || r == "refwrite" || r == "unread-config") return (expanded_head ? "expanded-git" : r)
      } else if (r != "") return r
      if (maybe_value) { j++; continue }
      break
    }
    return ""
  }
  # cmd_prefix(t): a word after which the next word is still a command word.
  function cmd_prefix(t) {
    # `{\001` is the brace-group keyword as the tokenizer marks it (DND-780).
    return is_assign(t) || t ~ /^(env|command|sudo|exec|nohup|xargs|time|eval|builtin|nice|setsid|noglob|nocorrect|-|then|do|else|elif|if|while|until|case|coproc|!|\{\001)$/
  }
  # squote(w): w as one single-quoted shell word.
  function squote(w) { gsub(/\047/, "\047\\\047\047", w); return "\047" w "\047" }
  # note(c, W, k, e, depth, force): remember WHAT matched finding c, so the
  # deny reason can name it (DND-780): the words k..e of the simple command
  # (at most 6, marks removed, newlines flattened, cut at 120 chars), their
  # word position k, and the nesting depth (0 = the command as typed). The
  # first match of a category is kept; force replaces it (an outer shell
  # alias names itself, not the text its expansion matched).
  function note(c, W, k, e, depth, force,    t, i) {
    if (c == "" || ((c in NT) && !force)) return
    t = ""
    for (i = k; i <= e && i < k + 6; i++) t = t (i > k ? " " : "") W[i]
    if (e >= k + 6) t = t " ..."
    NT[c] = clip(t); NP[c] = k; ND[c] = depth
  }
  function clip(t) {
    gsub(/\001/, "", t); gsub(/\002/, "$", t); gsub(/[\n\r\t]+/, " ", t)
    return length(t) > 120 ? substr(t, 1, 117) "..." : t
  }
  # QUOTED PAYLOADS ARE DATA (DND-799). A quoted word holding whitespace or
  # a separator, or a heredoc body, is re-read as a command text. Unless the
  # shell may EXECUTE it, it is read in DATA mode: only findings that name
  # the write count there (a literal stash write, stash-ref plumbing, a
  # stash git or shell alias, a glob or expanded command word followed by a
  # stash verb), never the rest of the expansion findings (a glob or brace
  # command word with no or expanded arguments, a subcommand built by
  # expansion, an unread config). So `jq \047.[] | .x\047`, `awk \047{print $1}\047`,
  # `docker ps --format \047{{.Names}} {{.ID}}\047` and a python heredoc
  # with brackets are data, while `grep \047git stash pop\047` still denies
  # (the accepted false positive in the header).
  # A payload is EXEC (read in full, as before) when any of these holds:
  #   * the text it sits in has a command word safe_word() does not know
  #     (FAIL CLOSED): a shell or other runner (`sh -c`, `cat f | sh`,
  #     `bash <<\047EOF\047`, eval, source, `.`, xargs, sudo, env -S, trap,
  #     alias), a script by path or bare name, a command word built by
  #     expansion (`$SHELL -c`, `while read l; do $l; done`), or any program
  #     not on the pure-data list (git, gh, docker, sed, rg, sort, wget
  #     included);
  #   * it holds a command substitution (`$(`, a backtick, `${(`): the
  #     shell runs it while expanding a double-quoted word, and a builtin
  #     may re-evaluate a single-quoted one;
  #   * a heredoc whose delimiter is unquoted (its body is expanded) or that
  #     has no terminating line.
  # A payload nested in a data payload is data too. A payload nested in an
  # exec payload is decided again from the text it sits in.
  function weak(r) { return r ~ /^(expanded|unread-config)$/ }
  # safe_word(t): a PURE DATA tool: runs no program in any form, or a shell
  # keyword or builtin that runs nothing. An interpreter is here on purpose:
  # its string is data to this guard (see RESIDUAL in the header). Anything
  # else is unknown and makes the text EXEC (fail closed). Tools that can
  # run a program in some form stay off the list (DND-799 critic rounds
  # 1-10), as do builtins that re-evaluate an arithmetic subscript.
  function safe_word(t) {
    return t ~ /^(jq|yq|gojq|awk|gawk|mawk|nawk|grep|egrep|fgrep|curl|echo|printf|cat|tac|head|tail|uniq|wc|cut|tr|tee|column|paste|join|comm|diff|cmp|ls|stat|file|date|basename|dirname|realpath|readlink|test|true|false|cd|pushd|popd|export|unset|set|sleep|mkdir|rmdir|touch|cp|mv|rm|ln|chmod|python|python3|ruby|perl|node|xxd|od|base64|sha1sum|sha256sum|md5sum|bc|expr|seq|nl|fold|fmt|rev|iconv|uname|hostname|whoami|id|pwd|which|type|command|builtin|nohup|time|noglob|nocorrect|mktemp|du|df|ps|pgrep|printenv|wait|if|then|else|elif|fi|for|while|until|do|done|case|esac|!|-|:)$/ \
      || t == "[\001" || t == "[\001[\001" || t == "{\001" || t == "}"
  }
  # exec_text(W, SB, UX, n): 1 when the text may run a string it holds:
  # any command word that is not a bare pure-data tool. A word that holds a
  # `/` is a path -- a script or a binary this guard will not vouch for, so
  # it is exec even if its basename matches a data tool (`./cat`, `d/jq`;
  # critic round 11). A bare word not on safe_word() is exec too (a runner,
  # a script by name, a word built by expansion or glob, `.`, and every
  # program-running tool: git, gh, docker, sed, rg, sort, wget). An earlier
  # runner-word list (round 1) and per-tool read lists (rounds 4-8) were
  # deleted (rounds 6 and 10): this fail-closed check reaches every case.
  function exec_text(W, SB, UX, n,    k, cp, t) {
    cp = 0
    for (k = 1; k <= n; k++) {
      cp = SB[k] || (cp && k > 1 && cmd_prefix(W[k - 1]))
      if (!cp || is_assign(W[k])) continue
      if (W[k] ~ /\// || !safe_word(W[k])) return 1
    }
    return 0
  }
  # analyze(text, depth, data): the most specific finding in text (see rank),
  # or "" when it runs no stash write. It stops early only on a literal
  # stash. data is 1 when text is a DATA payload (see above): its expansion
  # findings are dropped.
  function analyze(text, depth, data,    W, QF, SB, UX, PQ, HB, HQ, n, k, e, r, sw, m, i, cp, t, j, x, best, ex, h, tst, dm, sc, hit) {
    # Past the nesting bound, text that still names stash is a deny.
    if (depth > 8) {
      if (!mentions_stash(text)) return ""
      if (!("stash" in NT)) { NT["stash"] = clip(text); NP["stash"] = 0; ND["stash"] = depth }
      return "stash"
    }
    n = tokenize(text, W, QF, SB, UX, PQ, HB, HQ); best = ""
    # Inside DATA every nested payload is data too: nothing in this text
    # is run, so neither is a quoted word or heredoc within it.
    ex = data ? 0 : exec_text(W, SB, UX, n)
    for (k = 1; k <= n; k++) if (QF[k]) {
      # A payload holding a command substitution (`$(`, a backtick, a zsh
      # `${(` flag) is exec: double-quoted, the shell runs it while
      # expanding the word; single-quoted, zsh runs it when a builtin
      # evaluates the string as a subscript (read, shift, return,
      # [[ -eq ]]; measured, critic rounds 3 and 6).
      best = better(best, analyze(W[k], depth + 1, data || !(ex || W[k] ~ /\$\(|`|\$\{\(/)))
      if (best == "stash") return best
    }
    for (h = 1; h <= HB[0]; h++) {
      best = better(best, analyze(HB[h], depth + 1, data || (HQ[h] && !ex)))
      if (best == "stash") return best
    }
    cp = 0; tst = 0
    for (k = 1; k <= n; k++) {
      # cp: word k is in command position (starts a simple command, or
      # follows a prefix such as env/sudo/xargs or a VAR=value assignment).
      cp = SB[k] || (cp && k > 1 && cmd_prefix(W[k - 1]))
      for (e = k; e < n && !SB[e + 1]; e++) ;
      # The arguments of a test (`[`, `[[`, `test`) are never run, so they
      # are read in data mode (DND-799, from DND-853: `[ -n "$s" ]` after a
      # `cd "$W"` read `$s ]` as an expanded git command word).
      if (SB[k]) tst = 0
      if (cp && (W[k] == "[\001" || W[k] == "[\001[\001" || W[k] == "test")) tst = 1
      dm = data || tst
      # A shell alias in command position: read its value, followed by the
      # rest of this simple command, as a command of its own. The name is
      # looked up without glob marks: an alias named `gs?` expands before
      # globbing, so the matcher must not judge it as a glob (DND-780).
      x = W[k]; gsub(/\001/, "", x)
      # A shell does not expand an alias again inside its own expansion
      # (`alias grep=\047grep --color\047`): AEXP holds the aliases being
      # expanded (DND-799; before, `grep -i stash` recursed to the nesting
      # bound and denied as naming stash).
      if (cp && (x in shal) && !(x in AEXP)) {
        AEXP[x] = 1
        for (j = 1; j <= shal[x]; j++) {
          t = shv[x, j]
          for (i = k + 1; i <= e; i++) t = t " " squote(W[i])
          if (analyze(t, depth + 1, data) != "") { best = better(best, "shell-alias"); note("shell-alias", W, k, e, depth, 1) }
        }
        delete AEXP[x]
      }
      # A zsh SUFFIX alias (`alias -s ext=cmd`): a command word `x.ext` runs
      # `cmd x.ext ...`.
      if (cp && match(W[k], /\.[^.\/]+$/) && ((x = substr(W[k], RSTART + 1)) in sal)) {
        for (j = 1; j <= sal[x]; j++) {
          t = sv[x, j]
          for (i = k; i <= e; i++) t = t " " squote(W[i])
          if (analyze(t, depth + 1, data) != "") { best = better(best, "shell-alias"); note("shell-alias", W, k, e, depth, 1) }
        }
      }
      # the words of this simple command from k on, as their own array
      delete sw; m = 0
      for (i = k + 1; i <= e; i++) sw[++m] = W[i]
      # A simple command that starts at `stash` followed a `)` or backtick:
      # the tail of `$(command -v git) stash`.
      if (SB[k] && W[k] == "stash" && !is_read(m >= 1 ? sw[1] : "")) { note("stash", W, k, e, depth, 0); return "stash" }
      if (W[k] ~ /(^|\/)git-stash$/ && !is_read(m >= 1 ? sw[1] : "")) { note("stash", W, k, e, depth, 0); return "stash" }
      # A command word the shell rewrites by glob or brace (`/usr/bin/g?t`,
      # `git-st*sh`) may be git or may be git-stash, so it is judged as both:
      # as git-stash, no verb (a bare or option-first push), a writing verb,
      # or a verb built by expansion is denied; as git, the usual verdict.
      # Exactly `[` and `[[` are exempt: the test builtin and keyword, which
      # never run their arguments, and as globs they match only themselves
      # (an unclosed `[` is literal) (DND-780). So is a lone `{`: brace
      # expansion needs a closing `}` in the same word, so it is the brace
      # group keyword, and the word after it keeps command position (see
      # cmd_prefix).
      # In DATA mode (dm) only a LITERAL stash write counts (see QUOTED
      # PAYLOADS ARE DATA): git is judged with no unread config (cfgov 0),
      # and a glob command word denies only when followed by a literal
      # stash verb or a subcommand that is a stash write (critic round 3:
      # data mode is not trusted to prove nothing evaluates the string, so
      # it keeps every spelling that names the write).
      if (dm) { sc = cfgov; cfgov = 0 }
      if (cp && W[k] ~ /\001/ && W[k] != "[\001" && W[k] != "[\001[\001" && W[k] != "{\001") {
        for (i = 1; i <= m && sw[i] ~ /^-/; i++) ;
        if (dm) hit = (i <= m && sw[i] ~ /^(push|save|pop|apply|drop|clear|store|branch)$/) || git_verdict(sw, m, 1, 0, 0) ~ /^(stash|alias|refwrite)$/
        else hit = (i > m || sw[i] ~ /^(push|save|pop|apply|drop|clear|store|branch)$/ || sw[i] ~ /[$`\001]/ || git_verdict(sw, m, 1, 0, 0) != "")
        if (dm) cfgov = sc
        if (hit) { best = better(best, "glob-head"); note("glob-head", W, k, e, depth, 0) }
        continue
      }
      if (W[k] ~ /(^|\/)git$/) r = git_verdict(sw, m, 1, 0, 0)
      else if (W[k] ~ /[$`]/ && !literal_non_git(W[k], UX[k])) r = git_verdict(sw, m, 1, 1, 0)
      else r = ""
      if (dm) cfgov = sc
      if (dm && weak(r)) r = ""
      note(r, W, k, e, depth, 0)
      if (r == "stash") return r
      best = better(best, r)
    }
    return best
  }
  BEGIN {
    na = split(slurp(alf), lines, "\n")
    for (k = 1; k <= na; k++) {
      l = lines[k]
      if (l !~ /^alias\./) continue
      name = substr(l, 7); val = ""
      sp = index(name, " ")
      if (sp > 0) { val = substr(name, sp + 1); name = substr(name, 1, sp - 1) }
      nal[name]++; aval[name, nal[name]] = val
    }
    if (cfgov) {
      nb = split(slurp(bif), bl, "\n")
      for (k = 1; k <= nb; k++) if (bl[k] != "") builtin[bl[k]] = 1
    }
    ns = split(slurp(shf), slines, "\n")
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
      # One name may carry several values (one per snapshot profile): keep
      # every distinct value. gal/sal/shal count them; *v holds each.
      if ((kind, name, val) in seenv) continue
      seenv[kind, name, val] = 1
      if (kind == "g") gv[name, ++gal[name]] = val
      else if (kind == "s") sv[name, ++sal[name]] = val
      else shv[name, ++shal[name]] = val
    }
    cmd = slurp(cmdf)
    r = analyze(cmd, 0, 0)
    # zsh GLOBAL aliases (`alias -g`) expand in any word position, not only
    # command position: also read the command with each one substituted
    # wherever it stands as a whole word (a quoted occurrence is substituted
    # too, which can only over-deny).
    # A name with several values is read once per value: pass p substitutes
    # the p-th value of each name (its last, once p passes its count).
    maxg = 0
    for (name in gal) if (gal[name] > maxg) maxg = gal[name]
    for (p = 1; r == "" && p <= maxg; p++) {
      g = cmd; hit = 0; hitn = ""
      for (name in gal) {
        gval = gv[name, (p <= gal[name]) ? p : gal[name]]
        re = name; gsub(/[][\\.^$*+?(){}|\/]/, "\\\\&", re)
        while (match(g, "(^|[ \t\n;&|()`])" re "([ \t\n;&|()`]|$)")) {
          pre = substr(g, 1, RSTART - 1); m0 = substr(g, RSTART, RLENGTH)
          lead = substr(m0, 1, 1); if (lead !~ /[ \t\n;&|()`]/) lead = ""
          tail = substr(m0, RLENGTH, 1); if (tail !~ /[ \t\n;&|()`]/) tail = ""
          g = pre lead gval tail substr(g, RSTART + RLENGTH); hit = 1; hitn = hitn (hitn == "" ? "" : " ") name
        }
      }
      if (hit) {
        r = analyze(g, 1, 0)
        if (r != "") { r = "shell-alias"; NT[r] = clip("zsh global alias " hitn); NP[r] = 0; ND[r] = 0 }
      }
    }
    if (r != "") print r "\t" ((r in NT) ? NT[r] : "") "\t" ((r in NP) ? NP[r] : 0) "\t" ((r in ND) ? ND[r] : 0)
  }' 2>/dev/null)
AWK_RC=$?

# An evaluator that crashed must not read as "nothing found" (see AN
# EVALUATION FAULT IS NOT "NOTHING FOUND" in the header).
if [ "$AWK_RC" -ne 0 ]; then
  FAULT="its awk evaluator exited $AWK_RC"
  fault_verdict
fi

# The verdict line is: category TAB matched words TAB word position TAB depth.
# MATCHED names what the evaluator matched (DND-780), so an agent can tell a
# real hit from a false positive before it retries.
V_CAT=$(printf '%s' "$VERDICT" | cut -f1)
V_TOK=$(printf '%s' "$VERDICT" | cut -f2)
V_POS=$(printf '%s' "$VERDICT" | cut -f3)
V_DEP=$(printf '%s' "$VERDICT" | cut -f4)
MATCHED=""
if [ -n "$V_TOK" ]; then
  MATCHED=" Matched: \`$V_TOK\`"
  if [ -n "$V_POS" ] && [ "$V_POS" != 0 ]; then
    if [ "$V_DEP" = 0 ]; then MATCHED="$MATCHED at word $V_POS of the command"
    else MATCHED="$MATCHED at word $V_POS of a nested command (a quoted payload or an alias expansion)"; fi
  fi
  MATCHED="$MATCHED."
fi

case "$V_CAT" in
  refwrite) deny 'this runs git plumbing that rewrites or expires the stash ref or its reflog without the stash subcommand: `reflog delete|expire|drop` naming `stash`/`stash@{N}`/`refs/stash` or given `--all`, `update-ref`/`symbolic-ref` on the stash ref (or with `--stdin`, or with refs supplied from elsewhere), a fetch/push refspec whose destination is the stash ref (either spelling) or refs/*, a push naming the stash ref (`push . --delete stash`) or `--mirror`, or filter-branch/filter-repo `--all`.'"$MATCHED" ;;
  stash) deny 'this runs `git stash` with a verb that writes the stash list (bare `git stash`, push/save, pop, apply, drop, clear, store, branch, or an option-first implicit push).'"$MATCHED" ;;
  shell-alias) deny 'this runs a shell alias loaded into the Bash tool from the owner profile (oh-my-zsh defines `gstp` = `git stash pop`) that expands to a stash write.'"$MATCHED" ;;
  alias) deny 'this runs a git alias that resolves to a stash write (or a shell alias that mentions stash).'"$MATCHED" ;;
  expanded) deny 'this runs git with a subcommand built by expansion (`git $X`, a glob `git st?sh`, a brace `git {stash,pop}`), which may be a stash write and cannot be read here. Spell the subcommand (and a stash verb) out literally, quoting any glob or brace characters.'"$MATCHED" ;;
  glob-head) deny 'this runs a command word the shell rewrites by glob or brace expansion (`/usr/bin/g?t`, `git-st*sh`), which may be git or git-stash writing the stash list. Spell the command word literally.'"$MATCHED" ;;
  unread-config) deny 'this runs a git subcommand that is neither a builtin nor an alias this guard read, where git may resolve it to a stash write: the command points git at a config this guard does not read (`--git-dir`, GIT_DIR, GIT_CONFIG_GLOBAL/SYSTEM, HOME, XDG_CONFIG_HOME, `include.path`, a `cd`/`-C` target that is expanded or holds whitespace, or an alias defined from an expansion), or help.autocorrect is on and git would run the closest command for a typo. Spell a builtin subcommand out, or drop the override.'"$MATCHED" ;;
  expanded-git) deny 'this runs `stash` through a command word built by expansion (`$GIT stash`, `$(command -v git) stash`), which may be git writing the stash list.'"$MATCHED" ;;
esac
exit 0
