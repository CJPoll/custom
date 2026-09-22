#!/usr/bin/env bash
# Compute the standup reporting window as two UTC bounds:
#   CUTOFF  (lower) = 09:00:00 America/Denver of the last business day
#   CEILING (upper) = 08:59:59 America/Denver of "today"
# Cody's stated window: yesterday 9:00 AM MT through today 8:59 AM MT.
#
# Why this script exists instead of inline prose: the naive idiom
#   TZ=America/Denver date -d "2026-09-21 09:00" -u +...Z
# is WRONG. GNU `date -u` forces the -d string to be PARSED in UTC, so the
# leading `TZ=America/Denver` env is ignored for parsing and the 09:00 is taken
# as UTC -- a cutoff six hours too early that still prints a plausible Zulu
# timestamp (the "failed lookup that looks non-empty" class, pointed the other
# way). The fix is to embed TZ INSIDE the -d string, which GNU date honors for
# parsing regardless of -u. That also tracks DST automatically: 15:00Z in MDT,
# 16:00Z in MST -- never a hardcoded offset.
#
# Usage:
#   standup-window.sh                # window for the real "today" (MT)
#   standup-window.sh --date <YMD>   # treat <YMD> as "today" (for tests)
#   standup-window.sh --field cutoff|ceiling   # print just one bound
# Output (default): two lines, "CUTOFF=<utc>" and "CEILING=<utc>".
set -euo pipefail

ZONE="America/Denver"
today=""
field="both"

while [ "$#" -gt 0 ]; do
  arg="$1"
  shift
  case "$arg" in
    --date)  today="$1"; shift ;;
    --field) field="$1"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "standup-window.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# "today" as an MT calendar date (bare date is zone-independent to print).
if [ -z "$today" ]; then
  today="$(TZ="$ZONE" date +%F)"
fi

# Day-of-week of the calendar date (1=Mon .. 7=Sun); bare date, zone-independent.
dow="$(date -d "$today" +%u)"
case "$dow" in
  1) back=3 ;;   # Mon -> Fri
  6) back=1 ;;   # Sat -> Fri
  7) back=2 ;;   # Sun -> Fri
  *) back=1 ;;   # Tue-Fri -> prev day
esac

# lastbiz calendar date: arithmetic on the bare date, no zone/time involved.
lastbiz="$(date -d "$today -$back days" +%F)"

# Convert each wall-clock MT instant to UTC. TZ is embedded in the -d string so
# `date -u` parses it in ZONE, then prints the UTC equivalent (DST-correct).
CUTOFF="$(date -u -d "TZ=\"$ZONE\" $lastbiz 09:00:00" +%Y-%m-%dT%H:%M:%SZ)"
CEILING="$(date -u -d "TZ=\"$ZONE\" $today 08:59:59" +%Y-%m-%dT%H:%M:%SZ)"

case "$field" in
  cutoff)  echo "$CUTOFF" ;;
  ceiling) echo "$CEILING" ;;
  both)    echo "CUTOFF=$CUTOFF"; echo "CEILING=$CEILING" ;;
  *) echo "standup-window.sh: unknown --field: $field" >&2; exit 2 ;;
esac
