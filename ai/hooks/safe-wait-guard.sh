#!/bin/sh
# PreToolUse safe-wait guard.
#
# Blocks a Bash tool call whose command contains a dangerous shell wait
# construct, and tells the agent the safe alternative. This machine-enforces the
# "NEVER write a shell wait-loop that spins" Hard Rule in
# ~/dev/custom/ai/CLAUDE.md, whose motivating incident is flaky ticket PT-919:
# an orphaned `(while :; do :; done) &` reparented to PID 1, pinned load ~290
# for an hour, and flaked neighboring ExUnit suites into Postgres 57014 timeouts.
#
# What it blocks (see the messages below for the exact fixes):
#   1. Busy-spin loop      — a while/until loop with NO `sleep` in it (and not a
#                            `read`-driven stream loop).
#   2. Unreaped bg loop    — a while/until/for loop that is backgrounded
#                            (`done &`, `( … ) &`, `{ …; } &`) with no
#                            trap/kill/pkill reaper.
#   4. pgrep -f self-match — a `pgrep -f "<pattern>"` inside a while/until wait
#                            with no `grep -v $$` self-exclusion (it matches the
#                            waiting shell's own argv, so it never exits).
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
# A message that QUOTES the PT-919 example `while :; do :; done`, fed to
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
# pgrep -f (or -lf, -af, …) in a while/until loop with no `$$` self-exclusion.
if [ "$HAS_WHILE_UNTIL" = true ] \
  && has 'pgrep[[:space:]]+-[[:alnum:]]*f' \
  && ! has '\$\$'; then
  deny 'SAFE-WAIT (pgrep -f self-match): `pgrep -f "<pattern>"` inside a wait loop matches the waiting shell'"'"'s own argv, so the loop never exits. Fix: exclude the waiter — `pgrep -f "<pattern>" | grep -v $$`, or block on the known PID instead: `timeout N tail --pid=<pid> -f /dev/null`. (A foreground `sleep` used to pace a poll can also return immediately in this harness — prefer blocking on the child or a harness wakeup.)'
fi

# ---- Shape 1: busy-spin loop (while/until with no sleep) -------------------
# A loop that sleeps each iteration is NOT a spin; a `read`-driven loop consumes
# a stream (e.g. `while read … done < file`) and is not a wait — allow both.
if [ "$HAS_WHILE_UNTIL" = true ] && [ "$HAS_DO_DONE" = true ] \
  && ! has_word 'sleep' \
  && ! has_word 'read'; then
  deny 'SAFE-WAIT (busy-spin loop): this while/until loop has no `sleep` in its body — it pins the CPU (PT-919: an orphaned spin loop pinned load ~290 and flaked ExUnit into Postgres 57014 timeouts). Fix: prefer letting the harness wake you (task-notification / SendMessage / Monitor), or block on the child with `timeout N tail --pid=<pid> -f /dev/null`. If it must be a poll, add a `sleep N` per iteration (cadence matched to the state) plus a max-iteration/`timeout` bound.'
fi

# ---- Shape 2: unreaped backgrounded loop ----------------------------------
# The loop is backgrounded (`done &`, `( … ) &`, `{ …; } &` — not `&&`) and no
# trap/kill/pkill reaper is installed, so a crashed parent orphans it to PID 1.
if [ "$HAS_LOOP_KW" = true ] && [ "$HAS_DO_DONE" = true ] \
  && has 'done[[:space:];)}]*&([^&]|$)' \
  && ! has_word 'p?kill|trap'; then
  deny 'SAFE-WAIT (unreaped background loop): this loop is backgrounded (`done &` / `( … ) &`) with no reaper, so a crashed or rate-limited parent orphans it to PID 1 (PT-919: pinned load ~290 for an hour, flaked ExUnit into Postgres 57014 timeouts). Fix: install a reaper — `child=$!; trap '"'"'kill "$child" 2>/dev/null'"'"' EXIT INT TERM` — or do not background it: block in the foreground with `timeout N tail --pid=<pid> -f /dev/null`, or let the harness wake you.'
fi

# No dangerous construct detected -> allow silently.
exit 0
