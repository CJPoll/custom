#!/usr/bin/env bash
# Self-test for athena:standup's reporting-window computation.
#
# It pins the exact UTC bounds standup-window.sh must produce for a known MDT
# date and a known MST date. The bug this guards against is invisible from the
# outside: TZ=America/Denver date -d "<wall clock>" -u silently parses the wall
# clock in UTC (because `-u` overrides the env TZ for PARSING), yielding a cutoff
# six hours too early that still prints a plausible Zulu timestamp. A run on a
# day with early-morning merges would then attribute another day's work to
# yesterday, and nothing would raise. A hardcoded offset would be a worse bug
# (wrong half the year), so the MST case exists to catch that too.
#
# Run: bash test/self-test.sh   (exit 0 = pass, non-zero = fail)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"
WIN="${ROOT}/scripts/standup-window.sh"

fails=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

[ -x "$WIN" ] || { echo "FAIL: $WIN not executable"; exit 1; }

# --- MDT (summer, UTC-6). 2026-09-22 is a Tuesday -> lastbiz Mon 2026-09-21. ---
out="$("$WIN" --date 2026-09-22)"
check "MDT cutoff  (Tue 2026-09-22)" "CUTOFF=2026-09-21T15:00:00Z"  "$(printf '%s\n' "$out" | sed -n '1p')"
check "MDT ceiling (Tue 2026-09-22)" "CEILING=2026-09-22T14:59:59Z" "$(printf '%s\n' "$out" | sed -n '2p')"

# --- MST (winter, UTC-7). 2026-01-15 is a Thursday -> lastbiz Wed 2026-01-14. ---
out="$("$WIN" --date 2026-01-15)"
check "MST cutoff  (Thu 2026-01-15)" "CUTOFF=2026-01-14T16:00:00Z"  "$(printf '%s\n' "$out" | sed -n '1p')"
check "MST ceiling (Thu 2026-01-15)" "CEILING=2026-01-15T15:59:59Z" "$(printf '%s\n' "$out" | sed -n '2p')"

# --- Weekend + Monday roll back to the previous Friday. ---
check "Mon 2026-09-14 cutoff -> Fri 09-11" "2026-09-11T15:00:00Z" "$("$WIN" --date 2026-09-14 --field cutoff)"
check "Sat 2026-09-19 cutoff -> Fri 09-18" "2026-09-18T15:00:00Z" "$("$WIN" --date 2026-09-19 --field cutoff)"
check "Sun 2026-09-20 cutoff -> Fri 09-18" "2026-09-18T15:00:00Z" "$("$WIN" --date 2026-09-20 --field cutoff)"

# --- The window is well-ordered: cutoff strictly before ceiling. ---
c="$("$WIN" --date 2026-09-22 --field cutoff)"
k="$("$WIN" --date 2026-09-22 --field ceiling)"
if [ "$c" \< "$k" ]; then printf 'ok   cutoff < ceiling\n'; else printf 'FAIL cutoff !< ceiling (%s .. %s)\n' "$c" "$k"; fails=$((fails + 1)); fi

# --- Regression assertion on the class itself: the buggy idiom must NOT match. ---
buggy="$(TZ=America/Denver date -d "2026-09-21 09:00" -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$buggy" = "2026-09-21T15:00:00Z" ]; then
  printf 'FAIL guard is vacuous: the naive idiom already yields the correct value on this box\n'
  fails=$((fails + 1))
else
  printf 'ok   naive idiom is demonstrably wrong here (%s), proving the guard is live\n' "$buggy"
fi

if [ "$fails" -eq 0 ]; then
  echo "PASS: standup-window self-test"
  exit 0
fi
echo "FAIL: $fails standup-window assertion(s) failed"
exit 1
