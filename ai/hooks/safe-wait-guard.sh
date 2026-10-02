#!/bin/sh
# PreToolUse safe-wait guard.
#
# Blocks a Bash tool call whose command contains a dangerous shell wait
# construct, and tells the agent the safe alternative. This machine-enforces the
# "NEVER write a shell wait-loop that spins" Hard Rule in
# ~/dev/custom/ai/CLAUDE.md, whose motivating incident is a work-repo flaky ticket:
# an orphaned `(while :; do :; done) &` reparented to PID 1, pinned load ~290
# for an hour, and flaked neighboring ExUnit suites into Postgres 57014 timeouts.
#
# What it blocks (see the messages below for the exact fixes):
#   1. Busy-spin loop      — a while/until loop with NO `sleep` in it (and not a
#                            `read`-driven stream loop).
#   2. Unreaped bg loop    — a while/until/for loop that is backgrounded
#                            (`done &`, `( … ) &`, `{ …; } &`) with no
#                            trap/kill/pkill reaper.
#   4. pgrep -f self-match — any `pgrep -f "<pattern>"` inside a while/until
#                            wait. It matches the waiting shell's own argv, so
#                            it never exits. `grep -v $$` does not help: the
#                            forked pipeline children carry the same argv under
#                            other pids (measured 2026-09-25, DND-589/DND-541).
#      Also `tail --pid` on a PID that `pgrep -f` resolved, loop or not: with
#      no target alive it returns the waiting shell, so the tail blocks its
#      whole timeout on itself; with a sibling alive it returns the sibling's
#      process (measured 2026-09-30, DND-1330).
#   5. pkill -f self-kill  — a `pkill -f <pattern>` whose pattern matches the
#                            command's own text kills the agent's tool shell.
# (Rule #3, the foreground-`sleep`-returns-immediately gotcha, is surfaced inside
#  the messages above rather than as a standalone block, because every sanctioned
#  poll uses a foreground `sleep` — blocking on it would nuke the good pattern.)
#
# Design guarantees:
#   * FAIL-OPEN — any error (missing jq, unparseable input, missing field, non-
#     Bash tool) exits 0 and ALLOWS the tool. A bug here can never wedge Bash.
#   * NARROW    — only Bash is inspected; the required must-not-block patterns
#     (a loop that sleeps, a trap-reaped background loop, `while read … done <
#     file`, ordinary commands) all pass. False positives are costly: this gates
#     every Bash call.
#
# Wired in ~/.claude/settings.json as a PreToolUse hook scoped to Bash.

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

# Only inspect Bash; fail-open on any jq trouble.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# ---- A message body fed to send-mail is data ------------------------------
# A message that QUOTES the orphaned-spin-loop example `while :; do :; done`, fed to
# `send-mail` in a heredoc, is text, not code, and must not be denied. The
# exemption is an ALLOW-LIST of whole-command shapes, not a deny-list of
# runners: a deny-list of what could execute the body is never complete
# (`| at now`, `| crontab -`, `1>file` then run, a renamed shell). The body is
# dropped from the scan text only when the command is EXACTLY one of:
#     send-mail ARGS <<'DELIM'            (or <<"DELIM", <<\DELIM, <<-'DELIM')
#     cat <<'DELIM' | send-mail ARGS
# where send-mail is a literal path resolving to THIS tree's own send-mail (see
# is_this_send_mail), and ALL of:
#   * exactly one heredoc; its delimiter QUOTED, so nothing in the body expands;
#   * the heredoc reaches its terminator line;
#   * the command is ONE line outside the body, with nothing after the
#     terminator. So no second command can run what send-mail stored;
#   * the delimiter word ends at whitespace or end of line (bash would join
#     `'EOF'x` into `EOFx` and end the body somewhere else);
#   * outside the delimiter word the line has no quote, `\`, `#`, backtick
#     or `@`, and ARGS are plain literals or `$VAR` (see ARG). So bash splits
#     the line into the same words this guard does: no redirect, substitution,
#     pipeline stage, continuation, comment, or `<<` hidden inside a quote.
# Anything else, including `cat` alone, `tee`, `git commit -m "$(cat <<'EOF'…`
# and every shell, is scanned exactly as before this rule existed. The text
# outside the body is always scanned. `<<<` here-strings are never exempt.
heredoc_outside_if_single() {
  printf '%s\n' "$1" | awk -v sq="'" -v dq='"' '
    function take_op(line,    i, after, c, j, d, t) {
      i = index(line, "<<")
      if (i == 0) return line
      after = substr(line, i + 2)
      if (substr(after, 1, 1) == "<") { bad = 1; return line }
      if (substr(after, 1, 1) == "-") { tabs = 1; after = substr(after, 2) }
      sub(/^[ \t]+/, "", after)
      c = substr(after, 1, 1)
      if (c == sq || c == dq) {
        j = index(substr(after, 2), c)
        if (j == 0) { bad = 1; return line }
        d = substr(after, 2, j - 1)
        after = substr(after, j + 2)
      } else if (c == "\\") {
        after = substr(after, 2)
        if (match(after, /^[A-Za-z_][A-Za-z0-9_.-]*/) == 0) { bad = 1; return line }
        d = substr(after, 1, RLENGTH)
        after = substr(after, RLENGTH + 1)
      } else { bad = 1; return line }
      # bash joins anything attached to the delimiter into the word
      # (`'EOF'x` is `EOFx`), so the word must end at whitespace or end of line.
      if (d == "" || (after != "" && after !~ /^[ \t]/)) { bad = 1; return line }
      if (index(after, "<<") > 0) { bad = 1; return line }
      # Parse agreement with bash by construction: outside the delimiter word
      # the line carries no quote, backslash, comment or substitution, so it is
      # plain words split on whitespace for bash as for this guard (a `<<`
      # inside a closed quote is text to bash, not a heredoc).
      t = substr(line, 1, i - 1) after
      if (index(t, sq) > 0 || t ~ /["\\#`@]/) { bad = 1; return line }
      delim = d; ops++
      return substr(line, 1, i - 1) "@HEREDOC@" after
    }
    BEGIN { state = 0 }
    {
      if (state == 0) { out = take_op($0); lines++; if (ops == 1) state = 1; next }
      if (state == 1) {
        t = $0
        if (tabs) sub(/^\t+/, "", t)
        if (t == delim) state = 2
        next
      }
      if ($0 != "") after_term = 1
    }
    END {
      if (bad || ops != 1 || state != 2 || lines != 1 || after_term) exit 2
      print out
    }
  ' 2>/dev/null
}

# The command word must BE this harness's send-mail, not merely something named
# send-mail (a shell symlinked to /tmp/x/send-mail would run the body). So it
# is a LITERAL path (no `$`, quote, brace or glob can reach it), resolved
# against the hook input's `cwd` (`~/` against $HOME), and its realpath must
# equal the realpath of THIS tree's own `ai/skills/athena:inbox/bin/send-mail`.
# Both sides are realpath'd. A bare `send-mail` (resolved through PATH) and
# `"$VAR/send-mail"` cannot be resolved here, so they are scanned in full. The
# hook is wired at the main checkout, so a worktree's own copy of send-mail
# does not match either: that fails closed (scanned in full), never open.
LIT='[A-Za-z0-9_.~:/-]'
# ARGS are allow-listed too: plain literals and `$VAR` / `${VAR}` only. No
# quote at all (a `<<` inside a closed quote is not a heredoc to bash; an open
# one runs on into the body), no `\` (continues the line into the "body"), no
# `#` (a comment hides the `<<`), and no `@`, so the `@HEREDOC@` placeholder
# can only match as its own token.
ARG="([A-Za-z0-9_.~:/=,+%-]|\\\$[A-Za-z_][A-Za-z0-9_]*|\\\$\\{[A-Za-z_][A-Za-z0-9_]*\\})+"
CAT_STAGE='[[:space:]]*(cat[[:space:]]+@HEREDOC@[[:space:]]*\|[[:space:]]*)?'

# is_this_send_mail <word> : 0 iff <word> resolves to this tree's send-mail.
is_this_send_mail() {
  _w=$1
  case $_w in
    '~/'*) _w="$HOME/${_w#\~/}" ;;
    /*) ;;
    *) _cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
       case $_cwd in /*) _w="$_cwd/$_w" ;; *) return 1 ;; esac ;;
  esac
  _got=$(realpath -e -- "$_w" 2>/dev/null) || return 1
  _want=$(realpath -e -- "$(dirname -- "$0")/../skills/athena:inbox/bin/send-mail" 2>/dev/null) || return 1
  [ -n "$_got" ] && [ "$_got" = "$_want" ]
}

SCAN=$CMD
case $CMD in
  *'<<'*)
    if OUTSIDE=$(heredoc_outside_if_single "$CMD") \
      && printf '%s' "$OUTSIDE" | grep -Eq "^${CAT_STAGE}${LIT}*/send-mail([[:space:]]+(${ARG}|@HEREDOC@))*[[:space:]]*\$" \
      && [ "$(printf '%s' "$OUTSIDE" | grep -o '@HEREDOC@' | wc -l)" -eq 1 ] \
      && is_this_send_mail "$(printf '%s' "$OUTSIDE" | sed -E "s/^${CAT_STAGE}//; s/[[:space:]].*\$//")"; then
      SCAN=$OUTSIDE
    fi
    ;;
esac

# Flatten to a single logical line so line-oriented grep can see constructs that
# the author split across newlines/tabs (e.g. `done` and `&` on separate lines).
FLAT=$(printf '%s' "$SCAN" | tr '\n\t' '  ')

# has_word <extended-regex-token> : token present as a shell word in FLAT.
has_word() {
  printf '%s' "$FLAT" | grep -Eq "(^|[^[:alnum:]_])($1)([^[:alnum:]_]|\$)"
}

# has <extended-regex> : arbitrary ERE present in FLAT.
has() {
  printf '%s' "$FLAT" | grep -Eq "$1"
}

# deny <reason> : emit the PreToolUse deny decision and exit (fail-open if jq
# cannot encode, which would simply allow — consistent with the guarantee).
# Appended to every deny: how to pass a loop that is only quoted TEXT.
DATA_HINT=' If the flagged loop is only quoted text in a message body, the reliable path is to write the body with the Write tool and pass `--body-file <path>` to send-mail. A heredoc body is treated as data only for the exact one-line command `<path>/athena:inbox/bin/send-mail ARGS <<'"'"'EOF'"'"'` (a literal path to the harness copy, quoted delimiter), where ARGS are plain unquoted words or `$VAR` only: no quotes, `#`, `?`, `&`, `@`, backslash, redirect, pipe or second command.'

deny() {
  jq -cn --arg r "$1$DATA_HINT" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
    2>/dev/null
  exit 0
}

# A real loop needs both `do` and `done` (word `do` does not match inside "done").
HAS_DO_DONE=false
if has_word 'do' && has_word 'done'; then HAS_DO_DONE=true; fi

# while/until present, and for-loops (for shape 2).
HAS_WHILE_UNTIL=false
if has_word 'while' || has_word 'until'; then HAS_WHILE_UNTIL=true; fi
HAS_LOOP_KW=false
if [ "$HAS_WHILE_UNTIL" = true ] || has_word 'for'; then HAS_LOOP_KW=true; fi

# ---- Shape 4: pgrep -f self-match inside a while/until wait ----------------
# pgrep -f (or -lf, -af, …) in a while/until loop. A `$$` exclusion is NOT an
# escape: the Bash tool runs `zsh -c '<command>'`, and every forked pipeline or
# $(…) child carries that argv (pattern included) under a pid other than $$.
# `pgrep` with -f in any flag cluster or position, or --full.
PGREP_FULL='pgrep([[:space:]]+[^|;&)]*)?[[:space:]]+(-[[:alnum:]]*f[[:alnum:]]*|--full)([[:space:]]|$)'
if [ "$HAS_WHILE_UNTIL" = true ] \
  && has "$PGREP_FULL"; then
  deny 'SAFE-WAIT (pgrep -f self-match): `pgrep -f "<pattern>"` inside a wait loop matches the waiting shell'"'"'s own argv, so the loop never exits. `| grep -v $$` does not fix it: the forked pipeline children carry the same argv under other pids. Fix: block on the known PID — `timeout N tail --pid=<pid> -f /dev/null` (capture it with `$!` when you start the process) — or match by process name, not argv (`pgrep -x <comm>`), or wait on the output artifact the process writes.'
fi

# `tail --pid` on a PID from `pgrep -f`, with or without a loop. Measured
# 2026-09-30: `pgrep -f <unique> | head -1` with no target alive printed the
# Bash tool's own `zsh -c` pid, so `timeout N tail --pid=$(...)` waits out its
# full timeout on itself; DND-1330's `pgrep -f "integration-gate --with-critic"`
# returned a sibling captain's gate instead of its own.
if has "$PGREP_FULL" && has 'tail[[:space:]][^|;&]*--pid'; then
  deny 'SAFE-WAIT (pgrep -f pid for tail --pid): a PID found by `pgrep -f "<pattern>"` is not the process you started. The Bash tool runs your command as `zsh -c '"'"'<command>'"'"'`, so the pattern is in the waiting shell'"'"'s own argv: with the target already gone, pgrep returns that shell and the tail blocks its whole timeout on itself. With a sibling agent running the same command, it returns the sibling'"'"'s process. `head -1`, `-o` and `|| echo 1` do not fix either case. Fix: capture the PID when you start the process (`cmd >"$log" 2>&1 & echo $!`, or have the script write its own pidfile) and pass that literal pid to `timeout N tail --pid=<pid> -f /dev/null`; or, for a `run_in_background` task, let its completion notification wake you; or wait on the artifact it writes (a receipt, a final log line) with a bounded poll. `pgrep -x <comm>` is allowed but matches any process with that name.'
fi

# ---- Shape 1: busy-spin loop (while/until with no sleep) -------------------
# A loop that sleeps each iteration is NOT a spin; a `read`-driven loop consumes
# a stream (e.g. `while read … done < file`) and is not a wait — allow both.
if [ "$HAS_WHILE_UNTIL" = true ] && [ "$HAS_DO_DONE" = true ] \
  && ! has_word 'sleep' \
  && ! has_word 'read'; then
  deny 'SAFE-WAIT (busy-spin loop): this while/until loop has no `sleep` in its body — it pins the CPU (measured: an orphaned spin loop pinned load ~290 and flaked ExUnit into Postgres 57014 timeouts). Fix: prefer letting the harness wake you (task-notification / SendMessage / Monitor), or block on the child with `timeout N tail --pid=<pid> -f /dev/null`. If it must be a poll, add a `sleep N` per iteration (cadence matched to the state) plus a max-iteration/`timeout` bound.'
fi

# ---- Shape 2: unreaped backgrounded loop ----------------------------------
# The loop is backgrounded (`done &`, `( … ) &`, `{ …; } &` — not `&&`) and no
# trap/kill/pkill reaper is installed, so a crashed parent orphans it to PID 1.
if [ "$HAS_LOOP_KW" = true ] && [ "$HAS_DO_DONE" = true ] \
  && has 'done[[:space:];)}]*&([^&]|$)' \
  && ! has_word 'p?kill|trap'; then
  deny 'SAFE-WAIT (unreaped background loop): this loop is backgrounded (`done &` / `( … ) &`) with no reaper, so a crashed or rate-limited parent orphans it to PID 1 (measured: pinned load ~290 for an hour, flaked ExUnit into Postgres 57014 timeouts). Fix: install a reaper — `child=$!; trap '"'"'kill "$child" 2>/dev/null'"'"' EXIT INT TERM` — or do not background it: block in the foreground with `timeout N tail --pid=<pid> -f /dev/null`, or let the harness wake you.'
fi

# ---- Shape 5: pkill -f kills the shell that runs it -------------------------
# The Bash tool runs `zsh -c '<command>'`, so the whole command text is in that
# shell's argv. pkill excludes only itself, so a `pkill -f <pattern>` whose
# pattern matches the command text kills the agent's own tool shell (measured:
# DND-541 architect, 2026-09-24; the jev admiral killing its own re-armed
# watcher, 2026-10-02 07:45Z). The test is the pattern itself, not a keyword:
# it is run against the command text, so `pkill -f "[x]yz"` (which cannot
# match its own text) passes.
#
# How the pattern is found. split_commands splits the text into simple
# commands the way a shell would for this purpose: quotes are removed and
# respected, and an unquoted `;`, `&`, `|`, `(`, `)`, backtick or newline ends a
# command. So a pkill on line 2 is seen, and `git commit -m "a; pkill -f x"`
# is one command whose first word is git. Each command is one output line,
# its words joined by \037; a word holding a `$` or backtick expansion is
# prefixed \036 (its value is unknown here). An unquoted `#` at a word start
# begins a comment. pkill_pattern then drops wrapper words (then, do, sudo,
# nohup, env VAR=x, timeout N, …), and when the command is pkill with -f or
# --full, takes its pattern: the first non-option word (procps reorders
# options, so one may follow it), skipping the argument of an option that
# takes one and any redirection. An unknown pattern, or one grep rejects,
# passes (fail-open).
split_commands() {
  printf '%s' "$1" | awk -v sq="'" '
    function flushw() {
      if (inw) w[n++] = (ex ? "\036" : "") cur
      cur = ""; inw = 0; ex = 0
    }
    function flushc(   i, s) {
      flushw()
      if (n > 0) { s = w[0]; for (i = 1; i < n; i++) s = s "\037" w[i]; print s }
      n = 0
    }
    BEGIN { RS = "\001" }
    {
      s = $0; L = length(s); q = ""
      for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (q == sq) { if (c == sq) q = ""; else cur = cur c; continue }
        if (q == "\"") {
          if (c == "\"") { q = ""; continue }
          if (c == "\\" && i < L) {
            d = substr(s, i + 1, 1)
            if (d == "$" || d == "`" || d == "\"" || d == "\\") { cur = cur d; i++; continue }
          }
          if (c == "$" || c == "`") ex = 1
          cur = cur c; continue
        }
        if (c == "\\" && i < L) { cur = cur substr(s, i + 1, 1); inw = 1; i++; continue }
        if (c == sq || c == "\"") { q = c; inw = 1; continue }
        if (c == "#" && !inw) {
          while (i < L && substr(s, i + 1, 1) != "\n") i++
          continue
        }
        if (c == " " || c == "\t") { flushw(); continue }
        if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "`" || c == "\n") {
          if (c == "`") ex = 1
          flushc(); continue
        }
        if (c == "$") ex = 1
        cur = cur c; inw = 1
      }
      flushc()
    }
  ' 2>/dev/null
}

# pkill_pattern <words…> : print the pattern of a `pkill -f`, else nothing.
pkill_pattern() {
  while [ $# -gt 0 ]; do
    case $1 in
      then|do|else|elif|if|while|until|'!'|'{'|exec|command|sudo|nohup|setsid|time|xargs) shift ;;
      nice) shift; case ${1-} in -n) shift 2 ;; -[0-9]*) shift ;; esac ;;
      env) shift; while [ $# -gt 0 ]; do case $1 in -*|*=*) shift ;; *) break ;; esac; done ;;
      timeout) shift; while [ $# -gt 0 ]; do case $1 in -*) shift ;; *) break ;; esac; done; shift ;;
      [A-Za-z_]*=*) shift ;;
      *) break ;;
    esac
  done
  case ${1-} in pkill|*/pkill) shift ;; *) return 0 ;; esac
  _full=false; _pat=''; _skip=false
  for _w in "$@"; do
    if [ "$_skip" = true ]; then _skip=false; continue; fi
    case $_w in
      "$(printf '\036')"*) [ -z "$_pat" ] && _pat=UNKNOWN ;;
      --full) _full=true ;;
      --signal|--ns|--nslist|--pidfile|--parent|--group|--pgroup|--session|--terminal|--euid|--uid|--cgroup|--env|--runstates) _skip=true ;;
      --*) ;;
      '>'|'>>'|'<'|[0-9]'>'|[0-9]'>>'|[0-9]'<'|'&>') _skip=true ;;
      '>'*|'<'*|[0-9]'>'*|[0-9]'<'*|'&>'*) ;;
      -*)
        _c=${_w#-}
        case $_c in
          [GPUF]) _skip=true ;;
          [A-Z0-9][A-Z0-9+]*) ;;
          *)
            case $_c in *f*) _full=true ;; esac
            case $_c in *[gstuGPUF]) _skip=true ;; esac
            ;;
        esac
        ;;
      *) [ -z "$_pat" ] && _pat=$_w ;;
    esac
  done
  [ "$_full" = true ] && [ -n "$_pat" ] && [ "$_pat" != UNKNOWN ] && printf '%s\n' "$_pat"
  return 0
}

pkill_self_match() {
  case $SCAN in *pkill*) ;; *) return 0 ;; esac
  _us=$(printf '\037')
  split_commands "$SCAN" | while IFS= read -r _line; do
    case $_line in *pkill*) ;; *) continue ;; esac
    _tok=$(
      IFS=$_us; set -f
      # shellcheck disable=SC2086
      set -- $_line
      pkill_pattern "$@"
    )
    [ -n "$_tok" ] || continue
    if printf '%s\n' "$CMD" | grep -Eq -e "$_tok" 2>/dev/null; then
      printf '%s\n' "$_tok"
      break
    fi
  done
}
PKILL_HIT=$(pkill_self_match)
if [ -n "$PKILL_HIT" ]; then
  deny 'SAFE-WAIT (pkill -f self-match): the pattern `'"$PKILL_HIT"'` matches this command'"'"'s own text. The Bash tool runs your command as `zsh -c '"'"'<command>'"'"'`, and pkill excludes only itself, so it kills your own tool shell (and anything that shell started) before the target. Fix: kill the PID you captured when you started the process (`cmd & pid=$!`, later `kill "$pid"`), or match by process name (`pkill -x <comm>`), or write the pattern so it cannot match its own text, e.g. a bracket class: `pkill -f "[m]y-pattern"`.'
fi

# No dangerous construct detected -> allow silently.
exit 0
