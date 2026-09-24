#!/usr/bin/env bash
# budget.sh -- DOMAIN. The waiter's quiet budget, as a function of the session
# mode. Pure: every input is an argument; the only effect is err.sh's refusal
# line on stderr (see err.sh for why that one exception is named, not hidden).
#
# ============================ WHY THE MODE MATTERS ==========================
#
# An unattended `claude -p` kills its background tasks once they outlive its
# background-wait ceiling (600s unless CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
# says otherwise). A waiter killed there does not report a timeout -- it
# VANISHES, and the session that armed it waits forever for a notification that
# is never coming. So a headless waiter must finish under that ceiling.
#
# An interactive session has no such kill. Holding it to the same 540s only
# costs it context: every quiet wake is a notification and a re-arm in the
# transcript. Owner request (Cody, 2026-09-24): "Is it possible to set like a
# ~30-minute timeout on the inbox-wait? Each of those rearms consumes some
# context window".
#
# ============================ HOW THE MODE IS TOLD ==========================
#
# MEASURED 2026-09-24 on Claude Code 2.1.280/2.1.281, from a Bash-tool child:
#
#                                 CLAUDE_CODE_ENTRYPOINT  CLAUDE_CODE_SESSION_ATTENDED
#   interactive `claude`          cli                     1
#   headless `claude -p`          sdk-cli                 0
#
# `claude -p` was probed twice: under `env -i` (a cron-like, clean parent) and
# launched from inside an interactive session's Bash tool. Both times it SET
# both variables itself (sdk-cli / 0), overwriting the inherited cli / 1. So an
# inherited value cannot make a headless child look interactive.
#
# INTERACTIVE ONLY WHEN BOTH SIGNALS AGREE. Any other combination -- unset,
# empty, one signal only, the two disagreeing, or an entrypoint this was never
# measured against (an IDE extension, an Agent SDK) -- is UNKNOWN, and unknown
# gets the headless values. "Could not tell" must never read as interactive: a
# wrong guess in that direction is the vanished waiter above. The mode line the
# caller prints names what was seen, so a miss is observable rather than quiet.
#
# ============================ THE NUMBERS ==================================
#
#   interactive: default 1800s, ceiling 3600s.
#     1800 is the owner's ~30 minutes. 3600 bounds the override: the waiter is
#     still a bounded wait (the Hard Rule forbids an unbounded one), and an hour
#     is the longest a session should go without the re-arm that also
#     re-provisions doorbells and re-resolves the registry.
#   headless / unknown: default 540s, ceiling 600s -- unchanged -- unless
#     CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS is set, in which case the ceiling
#     FOLLOWS it (ms -> s, rounded down) and the default is min(540, 90% of the
#     ceiling), so the default always lands under the kill. A value of 0 means
#     "wait indefinitely" to `claude -p`; there is then no kill to stay under,
#     and the waiter's own bound, 3600s, is the ceiling.
#   CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS is a print-mode setting. It is read in
#   headless and unknown modes and ignored in interactive mode, where it
#   governs nothing.
#
# An override (ATHENA_INBOX_WAIT_BUDGET) at or over the ceiling is REFUSED,
# never clamped: a caller who asked for 900 and silently got 540 has
# configuration that does something other than it says.
# ============================================================================

INBOX_WAIT_INTERACTIVE_DEFAULT=1800
INBOX_WAIT_INTERACTIVE_CEILING=3600
INBOX_WAIT_HEADLESS_DEFAULT=540
INBOX_WAIT_HEADLESS_CEILING=600

# inbox_wait_mode <entrypoint> <attended>
# Prints one of: interactive | headless | unknown. Never fails.
inbox_wait_mode() {
  local entry="$1" attended="$2"
  if [ "${entry}" = "cli" ] && [ "${attended}" = "1" ]; then
    printf 'interactive\n'
  elif [ "${entry}" = "sdk-cli" ] && [ "${attended}" = "0" ]; then
    printf 'headless\n'
  else
    printf 'unknown\n'
  fi
}

# inbox_wait_budget <entrypoint> <attended> <ceiling-ms> <override>
# Empty <ceiling-ms> / <override> mean unset (`${VAR:-}` cannot tell the two
# apart, and a blank export is not an error).
#
# On success prints ONE tab-separated line and returns 0:
#   <mode> TAB <budget-s> TAB <ceiling-s> TAB <why>
# where <why> is a human sentence naming the signals seen.
# On a refusal prints the refusal (with Fix:) on stderr and returns 2.
inbox_wait_budget() {
  local entry="$1" attended="$2" ceiling_ms="$3" override="$4"
  local mode default ceiling why seen
  mode="$(inbox_wait_mode "${entry}" "${attended}")"
  seen="CLAUDE_CODE_ENTRYPOINT=${entry:-<unset>}, CLAUDE_CODE_SESSION_ATTENDED=${attended:-<unset>}"

  case "${mode}" in
    interactive)
      default="${INBOX_WAIT_INTERACTIVE_DEFAULT}"
      ceiling="${INBOX_WAIT_INTERACTIVE_CEILING}"
      why="interactive session (${seen}); no background-task kill applies"
      ;;
    *)
      if [ "${mode}" = "headless" ]; then
        why="headless claude -p (${seen})"
      else
        why="could not tell interactive from headless (${seen}); using the headless-safe values"
      fi
      default="${INBOX_WAIT_HEADLESS_DEFAULT}"
      ceiling="${INBOX_WAIT_HEADLESS_CEILING}"
      if [ -n "${ceiling_ms}" ]; then
        case "${ceiling_ms}" in
          *[!0-9]*)
            inbox_fail "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS is not a whole number of milliseconds (got \"${ceiling_ms}\"), so the background-task kill this waiter must finish under cannot be computed" \
              "set it to a whole number of milliseconds (0 means wait indefinitely), or unset it to use claude -p's 600s default. The waiter refuses rather than guessing, because a guess above the real kill is a waiter that vanishes."
            return 2
            ;;
        esac
        if [ "${#ceiling_ms}" -gt 12 ]; then
          inbox_fail "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS is ${ceiling_ms}ms, too large to compute a ceiling from" \
            "set it to a whole number of milliseconds of at most 12 digits (0 means wait indefinitely), or unset it to use claude -p's 600s default."
          return 2
        fi
        if [ "${ceiling_ms}" -eq 0 ]; then
          ceiling="${INBOX_WAIT_INTERACTIVE_CEILING}"
          why="${why}; CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 (no kill), so the waiter's own ${ceiling}s bound is the ceiling"
        else
          ceiling=$(( 10#${ceiling_ms} / 1000 ))   # 10#: a leading zero is not octal
          if [ "${ceiling}" -lt 2 ]; then
            inbox_fail "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS is ${ceiling_ms}ms, which leaves no whole second of budget under the background-task kill" \
              "raise CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS to at least 2000, or unset it to use claude -p's 600s default."
            return 2
          fi
          why="${why}; ceiling follows CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=${ceiling_ms}"
        fi
        # The default must land UNDER the kill whatever the ceiling is.
        local ninety=$(( ceiling * 9 / 10 ))
        [ "${ninety}" -lt "${default}" ] && default="${ninety}"
      fi
      ;;
  esac

  local budget="${default}"
  if [ -n "${override}" ]; then
    case "${override}" in
      *[!0-9]*)
        inbox_fail "ATHENA_INBOX_WAIT_BUDGET is not a positive integer number of seconds (got \"${override}\")" \
          "set it to a whole number of seconds below ${ceiling} (the ${mode}-mode ceiling), or unset it to use the ${default}s default."
        return 2
        ;;
    esac
    if [ "${override}" -eq 0 ]; then
      inbox_fail "ATHENA_INBOX_WAIT_BUDGET is 0, which would arm a waiter that returns immediately" \
        "set it to a whole number of seconds below ${ceiling} (the ${mode}-mode ceiling), or unset it to use the ${default}s default."
      return 2
    fi
    # The length test first: a value past bash's integer range makes `-ge` an
    # ERROR (status 2), which an `if` reads as false -- i.e. accepted.
    if [ "${#override}" -gt 9 ] || [ "${override}" -ge "${ceiling}" ]; then
      inbox_fail "ATHENA_INBOX_WAIT_BUDGET is ${override}s, at or over the ${ceiling}s ceiling for this ${mode}-mode session (${why})" \
        "set it below ${ceiling}. It is refused rather than clamped so you learn the budget you asked for is not the budget you would have got. In headless mode a waiter killed at the ceiling does not report a timeout -- it disappears, and the session waiting on it is never told; raise CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS too if you mean to raise this."
      return 2
    fi
    budget="${override}"
    why="${why}; ATHENA_INBOX_WAIT_BUDGET override"
  fi

  printf '%s\t%s\t%s\t%s\n' "${mode}" "${budget}" "${ceiling}" "${why}"
}
