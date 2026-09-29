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
# work-repo captain ran `git stash` then `git stash pop` and popped the owner's
# stash entry instead of its own. Nothing errored.
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
# lexical, so a command that only MENTIONS a mutating stash (a heredoc, a
# `git commit -m`, a `grep`) is denied too. That costs one retry: move the text
# into a file with the Write tool and pass the file (`git commit -F`), or use
# the Grep tool. A miss costs the owner's saved work. Where the git layer is
# live, most of this class is gone (next section).
#
# WHEN THE GIT LAYER IS LIVE (DND-1095). DND-775 put two layers under this
# guard in agent sessions: the PATH git wrapper ai/agent-bin/git (refuses a
# stash write from argv, before git runs) and the reference-transaction hook
# ai/git-hooks/agent-stash-guard.sh (refuses any refs/stash change, whatever
# spelled the git call). Both were live-verified on the desktop and the laptop
# (evidence on DND-775). The text guard then only needs to deny what those
# layers cannot refuse. So a command the rules above deny is judged again,
# with the active rules below, when ALL of these hold:
#   * git_layer_live: the hook's own env (Claude Code's, carrying the settings
#     env) registers the hook as git resolves it (event reference-transaction,
#     a command naming an executable agent-stash-guard.sh, both switches
#     true), GIT_TRACE2 is set, git is >= 2.54, ATHENA_AGENT_BIN holds the
#     wrapper, CLAUDE_ENV_FILE carries the agent PATH line, and the nearest
#     `claude` ancestor started after ATHENA_AGENT_ENV_INSTALLED_AT. That last
#     check is PENDING RESTART: Claude Code reads CLAUDE_ENV_FILE once per
#     process, so an older session may lack the wrapper on its PATH. Anything
#     unmeasurable (no /proc, no stamp, no claude ancestor) reads as not live.
#   * not exposed: the command text (as typed, and with quotes and
#     backslashes removed) shows no way around those layers: git by path
#     (`/usr/bin/git`, an exec-path `git-*`), a PATH change (any mention of
#     PATH, `command -p`, `read`, a login shell `sh -l`/`--login`, a sourced
#     file `.`/`source`), a lookup (`which`, `whence`, `where`, `type`, `hash`,
#     zsh `$commands[...]`), or an edit of the hook's env (`env -`, `unset`,
#     `exec -`, GIT_CONFIG*, GIT_TRACE2, GIT_EXEC_PATH, `--exec-path`, any
#     `hook.` config key), or a launcher that runs its payload OUTSIDE the
#     agent env, where neither layer exists (ssh, mosh, tmux, screen, zellij,
#     sudo, doas, su, runuser, pkexec, at, batch, crontab, systemd-run,
#     machinectl, nsenter, docker, podman, flatpak-spawn, hyprctl, swaymsg,
#     kitty, wezterm). Matched in any case, since git reads a key's section
#     and name in any case. Over-inclusive: a match only keeps the full guard.
# The active rules. Each finding keeps its deny unless named here:
#   * `git stash <word>` denies only for a word git 2.54 runs as a write
#     (push save pop apply drop clear store branch import export), a bare or
#     option-first stash, or an expanded word. git refuses any other word
#     (`git stash guard`: fatal, rc 128), so a search term is not a write.
#   * a glob or brace command word with no `/` and no expansion (`{print`,
#     `[.x[]`, `#{x}`), or an assignment word (`X=${A:-b}`, not a command),
#     no longer denies unless the text it sits in names stash: it expands to a
#     bare name, found on PATH, where git is the wrapper and no git-stash
#     exists (the DND-775 verify: rc 127). A `$` or backtick in the word
#     keeps the deny (`${D}?sh` can expand to a path), and so do words after
#     it that read as a stash write, a stash alias or an autocorrect risk.
#     In a quoted payload a computed first verb word (`$X`, `$(...)`, a
#     backtick; not a lone `$` or `$?`) keeps it too (option B, below).
#   * `git <expanded subcommand>` no longer denies unless its text names
#     stash: the wrapper reads argv after expansion. It still denies in a
#     quoted payload when the subcommand is computed (option B), when git
#     may read a config this guard did not, or help.autocorrect is on (the
#     unread-config condition: the wrapper passes a typo through), or when a
#     git `!` alias this guard read resolves to a stash write while its body
#     does not spell stash (`!git st\ash drop` as git reads it): the wrapper
#     resolves every
#     other alias through git, and refuses only a `!` body naming stash.
#   * an unknown subcommand after a command word built by expansion (`$s ]`
#     after a `git -C "$d"`, `$H/ticket.rb DND-1 --flag`) no longer denies
#     unless its text names stash or git's autocorrect could turn the word
#     into stash (can_become_stash: git's own weighted distance, and stash
#     must be the unique best builtin). A stash word, a known stash alias or
#     stash plumbing there still does.
#   * a shell alias is not expanded inside its own expansion, as the shell
#     does not (the owner's `grep` alias is `grep --color ...`).
# "The text it sits in" is the whole command, one quoted payload, or one
# alias expansion, as analyze reads it, plus every text enclosing it: a
# payload can run the words around it (`sh -c '$*' sh ... stash drop`).
# What stays denied, and why:
#   * every literal stash write, in a payload or heredoc too: a payload can run
#     outside the agent env (`ssh h '...'`, `tmux new '...'`, sudo, at), where
#     neither layer exists. So `git commit -m "... git stash pop ..."` still
#     denies; pass the message with -F.
#   * refs/stash file writes (rm, a redirect ...), gc.reflogExpire,
#     help.autocorrect and alias definitions: git sees no ref transaction for
#     a file write or a gc expiry, and the wrapper passes a typo through.
#   * unread-config under a literal git: help.autocorrect in an unread config
#     turns a typo into `stash drop`, which the hook cannot see.
# OPTION B (DND-1095, admiral decision after critic round 2). A quoted
# payload may be handed to a launcher the exposure list does not name
# (`pueue add -- '...'`, `emacsclient -e '...'`), which runs it outside the
# agent env, where neither git layer exists. A launcher blocklist is
# open-ended, so inside a quoted payload a verb computed by parameter or
# command expansion keeps the deny, after a literal git or a glob or brace
# command word; after a literal git, so does a glob or brace verb. That keeps these false positives DENIED with the layer live,
# accepted for now (lifting them is option A, the owner's call): awk
# `'{print $4}'`, JSON or jq text with `[x] $VAR`, ruby `"#{x} $X"`, and
# `"athena-harness[bot] -- $X"`. The same shapes typed at the top level run
# in the agent env, where the wrapper judges them, so they stay allowed.
# RESIDUAL of the active rules, beyond the two layers' own (DND-775 Q2), each
# needing a stash spelling computed at run time (no `stash` in its text):
#   * a quoted payload handed to a launcher the list above does not name,
#     whose command word AND verb are both built by glob or brace with no
#     `$` (`{git,} st{a,}sh drop`; under a literal git the brace verb is
#     denied): telling that verb from a grep pattern
#     (`[_ ]id{0,8}`) needs a glob model (option C), so it is left;
#   * an unquoted command handed to such a launcher as argv (`pueue add --
#     git $X pop`): the old guard never read it either, since git is not in
#     command position there;
#   * a PATH changed by something the text does not show (a script it runs,
#     direnv, nix-shell), so a bare `git` in that script may not be the
#     wrapper;
#   * a git reached by a computed path together with an alias or typo from a
#     config this guard cannot read.
# The old guard denied these only because a computed word is unknowable. They
# are the "string computed then executed" class of NOT CATCHABLE below.
# When the active rules allow a command the first pass denied, the hook says
# so in additionalContext and allows it. When a first-pass deny stands, its
# reason says why the second pass did not run (LIVE_WHY, or the exposure).
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
  jq -cn --arg r "git-stash-guard: $1 Every linked worktree shares ONE stash list with the main checkout (refs/stash lives in the common git dir), so a stash push/pop/apply/drop from a fleet worktree can apply, drop or clobber the OWNER's saved work with no error (DND-670: a captain's \`git stash pop\` popped the owner's stash entry). Agent sessions never write the stash list. Fix: to park WIP, commit it on your worktree branch (\`git add -A && git commit -m \"WIP: <what>\"\`; squash or amend it later); for a clean tree to experiment in, add a scratch tree with \`git worktree add <path> -b <scratch-branch>\` and remove it after. Read-only \`git stash list\`, \`git stash show\` and \`git stash create\` stay allowed. If this command only MENTIONS stash text (a heredoc, a commit message, a grep) and writes no stash, move the text into a file with the Write tool and pass the file (\`git commit -F <file>\`), or use the Grep tool; never rephrase a real stash command to slip past this guard." \
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

# ---- is the DND-775 git layer live for this session? ------------------------
# The hook runs in Claude Code's own environment, which carries the settings
# env. Every condition below must hold; any that cannot be measured reads as
# NOT live, so the guard keeps its full behaviour. LIVE_WHY names the first
# failed condition; a standing deny reports it (see LAYER_NOTE below).
# GSG_ENV_LINE must equal AgentStashEnv::ENV_LINE (ai/lib/agent_stash_env.rb),
# the line ai/agent-env/session-env.sh runs before every Bash tool command.
# Enforced by construction on both sides: check-hooks-registered FAILs an
# ACTIVE install whose session-env.sh runs any other line, and this suite's
# L2 cases read that real file, so a drift here fails them.
GSG_ENV_LINE='if [ -n "${ATHENA_AGENT_BIN:-}" ] && [ -x "$ATHENA_AGENT_BIN/git" ]; then PATH="$ATHENA_AGENT_BIN:$PATH"; export PATH; fi'
git_layer_live() {
  LIVE_WHY=""
  # 1. The reference-transaction hook, as git itself resolves the config
  #    (GIT_CONFIG_COUNT/KEY/VALUE, GIT_CONFIG_PARAMETERS, global): the event,
  #    a command naming an executable agent-stash-guard.sh, both switches on.
  (cd / && git config --get-regexp '^hook\.') > "$GSG_TMP/hookcfg" 2>/dev/null \
    || { LIVE_WHY="no hook config (git config lists no hook.* key)"; return 1; }
  _ev=$(awk '$1 == "hook.agentstash.event" { v = $2 } END { print v }' "$GSG_TMP/hookcfg")
  [ "$_ev" = reference-transaction ] || { LIVE_WHY="hook.agentstash.event is not reference-transaction"; return 1; }
  for _k in hook.agentstash.enabled hook.reference-transaction.enabled; do
    _v=$(awk -v k="$_k" '$1 == k { v = tolower($2) } END { print v }' "$GSG_TMP/hookcfg")
    case "$_v" in true | yes | on | 1) ;; *) LIVE_WHY="$_k is not true"; return 1 ;; esac
  done
  _h=$(sed -n "s#^hook\.agentstash\.command h='\([^']*/ai/git-hooks/agent-stash-guard\.sh\)';.*#\1#p" "$GSG_TMP/hookcfg" | tail -n 1)
  [ -n "$_h" ] && [ -f "$_h" ] && [ -x "$_h" ] || { LIVE_WHY="the hook command names no executable agent-stash-guard.sh"; return 1; }
  [ -n "${GIT_TRACE2:-}" ] || { LIVE_WHY="GIT_TRACE2 is unset"; return 1; }
  # 2. git loads config-based hooks from 2.54 (DND-775 probe 3).
  _gv=$(git --version 2>/dev/null) || { LIVE_WHY="git --version failed"; return 1; }
  _gv=${_gv#git version }
  _maj=${_gv%%.*}; _min=${_gv#*.}; _min=${_min%%.*}
  case "$_maj$_min" in '' | *[!0-9]*) LIVE_WHY="unreadable git version"; return 1 ;; esac
  [ "$_maj" -gt 2 ] || { [ "$_maj" -eq 2 ] && [ "$_min" -ge 54 ]; } || { LIVE_WHY="git $_gv predates config-based hooks"; return 1; }
  # 3. The PATH wrapper, and the CLAUDE_ENV_FILE line that puts it first on
  #    the Bash tool's PATH.
  _w="${ATHENA_AGENT_BIN:-}/git"
  [ -n "${ATHENA_AGENT_BIN:-}" ] && [ -f "$_w" ] && [ -x "$_w" ] \
    && head -n 5 "$_w" 2>/dev/null | grep -q 'git (agent wrapper)' \
    || { LIVE_WHY="no PATH git wrapper at ATHENA_AGENT_BIN"; return 1; }
  [ -n "${CLAUDE_ENV_FILE:-}" ] && grep -Fxq "$GSG_ENV_LINE" "$CLAUDE_ENV_FILE" 2>/dev/null \
    || { LIVE_WHY="CLAUDE_ENV_FILE does not carry the agent PATH line"; return 1; }
  # 4. Not PENDING RESTART: Claude Code reads CLAUDE_ENV_FILE once per
  #    process, so the nearest `claude` ancestor must have started strictly
  #    after ATHENA_AGENT_ENV_INSTALLED_AT (whole seconds; a tie is pending).
  # The stamp is an ISO UTC second; `date -d ""` would read an empty one as
  # today's midnight, so the shape is checked first.
  case "${ATHENA_AGENT_ENV_INSTALLED_AT:-}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) LIVE_WHY="ATHENA_AGENT_ENV_INSTALLED_AT is not an ISO UTC second"; return 1 ;;
  esac
  _inst=$(date -u -d "$ATHENA_AGENT_ENV_INSTALLED_AT" +%s 2>/dev/null)
  case "$_inst" in '' | *[!0-9]*) LIVE_WHY="ATHENA_AGENT_ENV_INSTALLED_AT is unreadable"; return 1 ;; esac
  _start=$(claude_start_epoch) || { LIVE_WHY="no claude ancestor start time"; return 1; }
  [ "$_start" -gt "$_inst" ] || { LIVE_WHY="this session predates the install (pending restart)"; return 1; }
  return 0
}

# claude_start_epoch : the start time (epoch seconds) of the nearest ancestor
# whose comm is `claude`, from /proc. Fails when none is found in 12 levels
# or /proc cannot be read.
claude_start_epoch() {
  _hz=$(getconf CLK_TCK 2>/dev/null)
  case "$_hz" in '' | *[!0-9]* | 0) return 1 ;; esac
  _bt=$(awk '$1 == "btime" { print $2 }' /proc/stat 2>/dev/null)
  case "$_bt" in '' | *[!0-9]*) return 1 ;; esac
  _p=$PPID; _d=0
  while [ "$_d" -lt 12 ]; do
    case "$_p" in '' | *[!0-9]* | 0 | 1) return 1 ;; esac
    IFS= read -r _st 2>/dev/null < "/proc/$_p/stat" || return 1
    _comm=${_st#*\(}; _comm=${_comm%\)*}
    _rest=${_st##*\) }
    set -f; set -- $_rest; set +f
    # $_rest starts at field 3 (state), so field 4 (ppid) is $2 and field
    # 22 (starttime) is ${20}.
    if [ "$_comm" = claude ]; then
      case "${20:-}" in '' | *[!0-9]*) return 1 ;; esac
      echo $((_bt + ${20} / _hz))
      return 0
    fi
    _p=$2; _d=$((_d + 1))
  done
  return 1
}

# exposed : the command text shows a way around the git layer: git by path
# (the exec-path binaries included), a PATH change, a lookup of the real git,
# or an edit of the hook's env, including any git config key under `hook.`
# (git matches a key's section and name in any case, so the match ignores
# case), a login shell or a sourced file (either can reset PATH), a `read`
# (it can set PATH), any mention of PATH, or a launcher whose payload runs
# outside the agent env (see the header). Over-inclusive on purpose: a match
# only keeps the full text guard.
# It reads the raw text AND FLAT (quotes and backslashes removed), so a
# quoted or escaped spelling (`/usr/bin/"git"`, `gi\t`, `P""ATH=`) matches.
exposed() {
  printf '%s\n%s' "$CMD" "$FLAT" | grep -Eiq \
    -e '/git(-[[:alnum:]-]+)?([^[:alnum:]_./-]|$)' \
    -e '(^|[^[:alnum:]_])path([^[:alnum:]_]|$)' \
    -e '(^|[^[:alnum:]_./-])(sh|bash|zsh|dash|ksh|mksh|fish)[[:space:]]+([^;&|]*[[:space:]])?(-[[:alnum:]]*l|--login)' \
    -e '(^|[;&|({[:space:]])(\.|source)[[:space:]]' \
    -e '(^|[^[:alnum:]_-])read([[:space:]]|$)' \
    -e '(^|[^[:alnum:]_-])(command|env|exec)[[:space:]]+-' \
    -e '(^|[^[:alnum:]_-])(unset|which|whence|where|type|hash)([[:space:]]|$)' \
    -e 'commands\[' \
    -e '(^|[^[:alnum:]_])hook\.' \
    -e 'GIT_CONFIG|GIT_TRACE2|GIT_EXEC_PATH|exec-path' \
    -e '(^|[^[:alnum:]_.-])(ssh|mosh|tmux|screen|zellij|sudo|doas|su|runuser|pkexec|at|batch|crontab|systemd-run|machinectl|nsenter|docker|podman|flatpak-spawn|hyprctl|swaymsg|kitty|wezterm)([^[:alnum:]_.-]|$)' 2>/dev/null
  # grep exit 2 (an error) counts as exposed: the full guard stays on.
  [ $? -ne 1 ]
}

# ---- git stash, through every head the header lists -------------------------
# Its inputs are files (BOUNDED HAND-OFF): argv carries only their paths.
# `active` is 1 only on the second pass WHEN THE GIT LAYER IS LIVE (see the
# header): each rule marked "active" there narrows to what the git layer
# cannot refuse.
GSG_PROG='
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
  # wlev(a, b): git'"'"'s weighted edit distance from a typed word a to a
  # command b, as help.c scores autocorrect candidates: a swap 0, a
  # substitution 2, an insertion 1, a deletion 3. A prefix of b scores 0.
  function wlev(a, b,    la, lb, i, j, d, c, x) {
    if (index(b, a) == 1) return 0
    la = length(a); lb = length(b)
    for (i = 0; i <= la; i++) d[i, 0] = i * 3
    for (j = 0; j <= lb; j++) d[0, j] = j
    for (i = 1; i <= la; i++) for (j = 1; j <= lb; j++) {
      c = d[i - 1, j - 1] + (substr(a, i, 1) == substr(b, j, 1) ? 0 : 2)
      x = d[i - 1, j] + 3; if (x < c) c = x
      x = d[i, j - 1] + 1; if (x < c) c = x
      if (i > 1 && j > 1 && substr(a, i, 1) == substr(b, j - 1, 1) && substr(a, i - 1, 1) == substr(b, j, 1)) {
        x = d[i - 2, j - 2]; if (x < c) c = x
      }
      d[i, j] = c
    }
    return d[la, lb]
  }
  # can_become_stash(v): help.autocorrect could turn the word v into stash.
  # git autocorrects only to a UNIQUE best candidate scoring under its
  # floor (7, on distance + 1), so v is safe when stash scores 6 or more, or
  # when some other builtin scores no worse. Conservative on ties.
  function can_become_stash(v,    ds, b) {
    v = tolower(v); gsub(/\001/, "", v)
    ds = wlev(v, "stash")
    if (ds >= 6) return 0
    for (b in builtin) if (b != "stash" && wlev(v, b) <= ds) return 0
    return 1
  }
  # stash_write(v): `git stash v` writes the stash list (v is "" when no word
  # follows). Legacy: any verb but the three reads. Active: only what git 2.54
  # runs as a write (every verb in its usage but list/show/create, a bare or
  # option-first push, or a verb built by expansion). git itself refuses any
  # other word (`git stash guard`: fatal, rc 128, the list untouched).
  function stash_write(v) {
    if (!active) return !is_read(v)
    sub(/[<>].*/, "", v)
    return v == "" || v ~ /^-/ || v ~ /[$`\001]/ || v ~ /^(push|save|pop|apply|drop|clear|store|branch|import|export)$/
  }
  # TSTASH: the text analyze is reading (the whole command, one quoted
  # payload, or one alias expansion) holds `stash` in any case. Active rules
  # keep a heuristic deny when it does, so `X=stash; git $X` handed to ssh or
  # tmux still denies. See analyze.
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
  function tokenize(text, W, QF, SB, UX, PQ,    n, i, L, c, st, cur, has, q, ns, skip, ux) {
    n = 0; st = 0; cur = ""; has = 0; q = 0; ns = 1; skip = 0; ux = 0; L = length(text)
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
          if (skip) skip = 0; else { n++; W[n] = cur; QF[n] = q; SB[n] = ns; UX[n] = ux; ns = 0 }
        }
        cur = ""; has = 0; q = 0; ux = 0
        if (substr(text, i + 1, 1) == "(") continue
        while (i < L && substr(text, i + 1, 1) ~ /[<>&|-]/) i++
        skip = 1
        continue
      }
      if (is_sep(c)) {
        if (has) {
          if (skip) skip = 0; else { n++; W[n] = cur; QF[n] = q; SB[n] = ns; UX[n] = ux; ns = 0 }
        }
        cur = ""; has = 0; q = 0; ux = 0
        if (c !~ /[ \t]/) { ns = 1; skip = 0 }
        continue
      }
      # An unquoted glob or brace character means the shell rewrites the word
      # before the command sees it (`git {stash,pop}`, `git st?sh`). Mark it
      # with \001 so the word counts as built by expansion.
      if (c == "$") {
        ux = 1; has = 1
        if (substr(text, i + 1, 1) == "?") { cur = cur "$?"; i++; continue }
        # `$(` ends this word at the `(`, which leaves a lone `$`: mark it
        # \003 so computed() tells a command substitution from a literal `$`.
        if (substr(text, i + 1, 1) == "(") { cur = cur "$\003"; continue }
        cur = cur c; continue
      }
      if (c ~ /[*?[{]/) { cur = cur c "\001"; has = 1; continue }
      cur = cur c; has = 1
    }
    if (has && !skip) { n++; W[n] = cur; QF[n] = q; SB[n] = ns; UX[n] = ux }
    return n
  }
  # refpart(t): the ref a revision/refspec word names: glob marks, a leading
  # `+` and any `@{...}` reflog selector removed (`stash@{0}` -> stash).
  function refpart(t) { gsub(/[\001\003]/, "", t); sub(/^\+/, "", t); sub(/@\{.*$/, "", t); return t }
  # is_assign(t): t has the shape of an assignment word (NAME=...,
  # NAME[i]=..., NAME+=...). Used ONLY to give the next word command
  # position (cmd_prefix), which can only add checks. The glob and
  # expansion rules still judge the word itself: the tokenizer removes
  # quotes, so `"A"=/usr/bin/g?t` (a command word, not an assignment) has
  # the same shape (DND-780 narrow cut, critic round 1).
  function is_assign(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/ }
  # computed(t): t holds a parameter or command expansion, so its value is
  # made at run time (`$X`, `${X}`, `$(...)`, `$4`, a backtick). A lone `$`
  # is a literal, and `$?` is an exit status (a number, never stash). A `$(`
  # reaches here as `$` and the \003 mark (see tokenize).
  function computed(t) { return t ~ /`/ || t ~ /\$[\003A-Za-z0-9_{(@*#!$-]/ }
  # INPAY is 1 while analyze reads a quoted payload (QF): text another
  # program may run, possibly through a launcher outside the agent env that
  # the exposure list does not name (pueue, emacsclient, ...), where neither
  # git layer exists. There a verb computed at run time keeps its deny
  # (DND-1095 option B): the critic'"'"'s `pueue add -- '"'"'X=$(printf st%s
  # ash); git $X pop'"'"'`.
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
    if (sc == "stash") return stash_write(j + 1 <= n ? w[j + 1] : "") ? "stash" : ""
    # Active: git reached by name is the PATH wrapper, which judges the
    # subcommand after expansion. The deny stays when the text names stash
    # (TSTASH), when git may autocorrect a typo or read an alias this guard
    # could not (cfgov: the wrapper passes a typo through), or when an alias
    # this guard read resolves to a stash write through a `!` body that does
    # not spell stash (STASH_ALIAS), which the wrapper cannot see, or when a
    # quoted payload computes it (INPAY): the payload may run outside the
    # agent env, where no wrapper judges it. Under a literal git (LITGIT) a
    # glob or brace subcommand counts as computed there too (`git
    # st{a,}sh drop`); under a glob command word it does not, since that is
    # the shape of a grep pattern (`[_ ]id{0,8}`).
    if (sc ~ /[$`\001]/) return (active && !TSTASH && !cfgov && !STASH_ALIAS && !(INPAY && (computed(sc) || (LITGIT && sc ~ /\001/)))) ? "" : "expanded"
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
        # Active: under a head built by expansion, a word that is only an
        # unknown subcommand (`$s ]`, `$H/t.rb DND-1 --flag`) no longer
        # denies unless the text names stash (TSTASH: `sh -c '"'"'$*'"'"' sh
        # /usr/bin/g?t stash drop` runs its later words); a stash word, a
        # known stash alias or stash plumbing still does.
        # A word git could autocorrect to stash keeps it too.
        if (r == "unread-config" && active && expanded_head && !TSTASH && !can_become_stash(w[j])) r = ""
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
    return is_assign(t) || t ~ /^(env|command|sudo|exec|nohup|xargs|time|eval|builtin|nice|setsid|noglob|nocorrect|-|then|do|else|if|while|until|!|\{\001)$/
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
    gsub(/[\001\003]/, "", t); gsub(/\002/, "$", t); gsub(/[\n\r\t]+/, " ", t)
    return length(t) > 120 ? substr(t, 1, 117) "..." : t
  }
  # analyze(text, depth): the most specific finding in text (see rank), or
  # "" when it runs no stash write. It stops early only on a literal stash.
  # analyze(text, depth) sets TSTASH for this text and restores the caller'"'"'s
  # on return. A nested text inherits its enclosing text'"'"'s TSTASH: a payload
  # can run words of the command around it (`sh -c '"'"'$*'"'"' sh ... stash
  # drop`, `read`, xargs), so those words count as its own.
  # It also restores LITGIT (is the git_verdict in progress under a literal
  # git), which analyze_text sets at each git_verdict it starts, so a `!`
  # alias body read mid-verdict cannot clear its caller'"'"'s.
  function analyze(text, depth,    saved, lg, r) {
    saved = TSTASH; TSTASH = saved || (tolower(text) ~ /stash/); lg = LITGIT
    r = analyze_text(text, depth)
    TSTASH = saved; LITGIT = lg
    return r
  }
  function analyze_text(text, depth,    W, QF, SB, UX, PQ, n, k, e, r, sw, m, i, cp, t, j, x, best, gv, xw, sp) {
    # Past the nesting bound, text that still names stash is a deny.
    if (depth > 8) {
      if (!mentions_stash(text)) return ""
      if (!("stash" in NT)) { NT["stash"] = clip(text); NP["stash"] = 0; ND["stash"] = depth }
      return "stash"
    }
    n = tokenize(text, W, QF, SB, UX, PQ); best = ""
    for (k = 1; k <= n; k++) if (QF[k]) {
      sp = INPAY; INPAY = 1; r = analyze(W[k], depth + 1); INPAY = sp
      best = better(best, r); if (best == "stash") return best
    }
    cp = 0
    for (k = 1; k <= n; k++) {
      # cp: word k is in command position (starts a simple command, or
      # follows a prefix such as env/sudo/xargs or a VAR=value assignment).
      cp = SB[k] || (cp && k > 1 && cmd_prefix(W[k - 1]))
      for (e = k; e < n && !SB[e + 1]; e++) ;
      # A shell alias in command position: read its value, followed by the
      # rest of this simple command, as a command of its own. The name is
      # looked up without glob marks: an alias named `gs?` expands before
      # globbing, so the matcher must not judge it as a glob (DND-780).
      x = W[k]; gsub(/\001/, "", x)
      # Active: the shell does not expand an alias inside its own expansion
      # (`grep=grep --color ...` runs grep once), so a name already being
      # expanded is not expanded again.
      if (cp && (x in shal) && !(active && (x in EXPANDING))) {
        EXPANDING[x] = 1
        for (j = 1; j <= shal[x]; j++) {
          t = shv[x, j]
          for (i = k + 1; i <= e; i++) t = t " " squote(W[i])
          if (analyze(t, depth + 1) != "") { best = better(best, "shell-alias"); note("shell-alias", W, k, e, depth, 1) }
        }
        delete EXPANDING[x]
      }
      # A zsh SUFFIX alias (`alias -s ext=cmd`): a command word `x.ext` runs
      # `cmd x.ext ...`.
      if (cp && match(W[k], /\.[^.\/]+$/) && ((x = substr(W[k], RSTART + 1)) in sal)) {
        for (j = 1; j <= sal[x]; j++) {
          t = sv[x, j]
          for (i = k; i <= e; i++) t = t " " squote(W[i])
          if (analyze(t, depth + 1) != "") { best = better(best, "shell-alias"); note("shell-alias", W, k, e, depth, 1) }
        }
      }
      # the words of this simple command from k on, as their own array
      delete sw; m = 0
      for (i = k + 1; i <= e; i++) sw[++m] = W[i]
      # A simple command that starts at `stash` followed a `)` or backtick:
      # the tail of `$(command -v git) stash`.
      if (SB[k] && W[k] == "stash" && stash_write(m >= 1 ? sw[1] : "")) { note("stash", W, k, e, depth, 0); return "stash" }
      if (W[k] ~ /(^|\/)git-stash$/ && stash_write(m >= 1 ? sw[1] : "")) { note("stash", W, k, e, depth, 0); return "stash" }
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
      if (cp && W[k] ~ /\001/ && W[k] != "[\001" && W[k] != "[\001[\001" && W[k] != "{\001") {
        for (i = 1; i <= m && sw[i] ~ /^-/; i++) ;
        # Active: a glob word with no `/` expands to a bare name, which the
        # shell looks up on PATH, where git is the wrapper, and no git-stash
        # is on PATH (DND-775 verify: rc 127). So it denies only when it holds
        # a `/`, holds an expansion (`${D}?sh` can expand to a path) and is
        # not an assignment word, it sits in a quoted payload and its first
        # verb word is computed (xw), the text names stash (TSTASH), or its
        # words read, by the active rules, as a stash write, a stash alias or
        # a possible autocorrect (gv). xw is DND-1095 option B: a launcher the
        # exposure list does not name runs the payload outside the agent env,
        # where the glob head can be git and the verb a computed stash, which
        # neither git layer can refuse. So `{print $4}` in awk stays denied.
        LITGIT = 0; gv = git_verdict(sw, m, 1, 0, 0)
        xw = INPAY && i <= m && computed(sw[i])
        if ((i > m || sw[i] ~ /^(push|save|pop|apply|drop|clear|store|branch)$/ || sw[i] ~ /[$`\001]/ || gv != "") \
          && (!active || W[k] ~ /\// || (W[k] ~ /[$`]/ && !is_assign(W[k])) || xw || TSTASH || gv != "")) {
          best = better(best, "glob-head"); note("glob-head", W, k, e, depth, 0)
        }
        continue
      }
      if (W[k] ~ /(^|\/)git$/) { LITGIT = 1; r = git_verdict(sw, m, 1, 0, 0) }
      else if (W[k] ~ /[$`]/ && !literal_non_git(W[k], UX[k])) { LITGIT = 0; r = git_verdict(sw, m, 1, 1, 0) }
      else r = ""
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
    # STASH_ALIAS: a git `!` alias this guard read resolves to a stash write
    # while its body does not spell stash, so the wrapper (which asks git for
    # every other alias and refuses a `!` body naming stash) cannot see it.
    for (name in nal) {
      bang = 0
      for (k = 1; k <= nal[name]; k++) if (aval[name, k] ~ /^!/ && tolower(aval[name, k]) !~ /stash/) bang = 1
      aw[1] = name
      if (bang && decide(name, aw, 1, 1, 0) != "") { STASH_ALIAS = 1; break }
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
    r = analyze(cmd, 0)
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
        r = analyze(g, 1)
        if (r != "") { r = "shell-alias"; NT[r] = clip("zsh global alias " hitn); NP[r] = 0; ND[r] = 0 }
      }
    }
    if (r != "") print r "\t" ((r in NT) ? NT[r] : "") "\t" ((r in NP) ? NP[r] : 0) "\t" ((r in ND) ? ND[r] : 0)
  }'

# evaluate <active> : run the evaluator; sets VERDICT. An evaluator that
# crashed must not read as "nothing found" (see AN EVALUATION FAULT IS NOT
# "NOTHING FOUND" in the header).
# A second pass that fails keeps the first pass's deny (PASS2_FAULT): a
# failed measurement must never turn a deny into an allow.
evaluate() {
  VERDICT=$(awk -v cmdf="$GSG_TMP/cmd" -v alf="$GSG_TMP/aliases" -v shf="$GSG_TMP/shaliases" \
    -v cfgov="$UNREAD_CONFIG" -v bif="$GSG_TMP/builtins" -v active="$1" "$GSG_PROG" 2>/dev/null)
  AWK_RC=$?
  if [ "$AWK_RC" -ne 0 ] && [ "$1" = 1 ]; then
    VERDICT=$LEGACY; PASS2_FAULT="its second-pass evaluator exited $AWK_RC"
    return
  fi
  if [ "$AWK_RC" -ne 0 ]; then
    FAULT="its awk evaluator exited $AWK_RC"
    fault_verdict
  fi
}

evaluate 0
# WHEN THE GIT LAYER IS LIVE (see the header), a finding is re-judged by the
# active rules: only what the git layer cannot refuse still denies.
# LAYER_NOTE says, in a standing deny, why the second pass did not allow it,
# so a session that should be live but is not can be told apart from a real
# hit (a failed lookup must not read as an empty one).
LAYER_NOTE=""
if [ -n "$VERDICT" ]; then
  if ! git_layer_live; then
    LAYER_NOTE=" The DND-775 git layer is not live for this session ($LIVE_WHY), so the full text guard applies."
  elif exposed; then
    LAYER_NOTE=" The DND-775 git layer is live, but this command shows a way around it (git by path, a PATH change, a git lookup, a hook env or config edit, or a launcher that runs outside the agent env), so the full text guard applies."
  else
    LEGACY=$VERDICT; PASS2_FAULT=""
    evaluate 1
    if [ -z "$VERDICT" ] && [ -z "$PASS2_FAULT" ]; then
      _lt=$(printf '%s' "$LEGACY" | cut -f2)
      jq -cn --arg c "git-stash-guard: left \`$_lt\` to the DND-775 git layer, which is live in this session (the PATH git wrapper and the reference-transaction hook). It refuses a stash write by a git this session runs; see the hook header for what it cannot see." \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}' 2>/dev/null
      exit 0
    fi
    if [ -n "$PASS2_FAULT" ]; then
      LAYER_NOTE=" The DND-775 git layer is live, but the guard could not re-judge this command ($PASS2_FAULT), so the full text guard applies. Run \`sh ~/dev/custom/ai/hooks/git-stash-guard.self-test.sh\` and report the failure to your admiral."
    else
      LAYER_NOTE=" The DND-775 git layer is live; this finding is one it cannot refuse, so it stands."
    fi
  fi
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
MATCHED="$MATCHED$LAYER_NOTE"

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
