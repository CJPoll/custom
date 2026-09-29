#!/usr/bin/env bash
# Self-test for athena:memory-maintenance's index-budget.
#
# The case that matters is the miss: a MEMORY.md that cannot be found must
# exit 2, never 0. A wrongly computed project slug otherwise reads as "within
# budget" forever while the real index overflows.
#
# Hermetic: fixtures and a fake $HOME under mktemp; the live index is never read.
# Run: bash ai/skills/athena:memory-maintenance/test/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"
TOOL="${ROOT}/scripts/index-budget"

PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

check() { # name expected-rc actual-rc
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1";
  else FAIL=$((FAIL+1)); echo "FAIL $1 (want rc $2, got $3)"; fi
}
has() { # name needle file
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); echo "ok   $1";
  else FAIL=$((FAIL+1)); echo "FAIL $1: no '$2' in:"; sed 's/^/     /' "$3"; fi
}

gen() { # file lines width
  : > "$1"
  i=0
  while [ "$i" -lt "$2" ]; do
    head -c "$3" /dev/zero | tr '\0' 'x' >> "$1"; echo >> "$1"; i=$((i+1))
  done
}

# 1. --help: stdout, exit 0, does nothing else.
"$TOOL" --help > "$TMP/help" 2>&1; check "--help exits 0" 0 $?
has "--help prints usage" "Usage:" "$TMP/help"

# 2. Within budget.
gen "$TMP/small.md" 10 20
"$TOOL" --file "$TMP/small.md" > "$TMP/o" 2>&1; check "small index is within budget" 0 $?
has "names the counts" "10 lines" "$TMP/o"

# 3. Over on lines only (191 short lines).
gen "$TMP/lines.md" 191 5
"$TOOL" --file "$TMP/lines.md" > "$TMP/o" 2>&1; check "191 lines is over budget" 1 $?
has "over on lines names lines" "OVER budget on lines" "$TMP/o"
has "over carries a Fix:" "Fix:" "$TMP/o"

# 4. Over on bytes only (100 lines x 230 bytes > 22528).
gen "$TMP/bytes.md" 100 230
"$TOOL" --file "$TMP/bytes.md" > "$TMP/o" 2>&1; check "23100 bytes is over budget" 1 $?
has "over on bytes names bytes" "OVER budget on bytes" "$TMP/o"

# 5. Boundary: exactly 190 lines is within budget.
gen "$TMP/edge.md" 190 5
"$TOOL" --file "$TMP/edge.md" > "$TMP/o" 2>&1; check "exactly 190 lines is within budget" 0 $?

# 6. THE MISS: a missing file is exit 2, never "within budget".
"$TOOL" --file "$TMP/nope.md" > "$TMP/o" 2>&1; check "missing index exits 2" 2 $?
has "missing index carries a Fix:" "Fix:" "$TMP/o"

# 7. Default path: derived from the main checkout under $HOME; missing -> 2.
mkdir -p "$TMP/home"
HOME="$TMP/home" "$TOOL" > "$TMP/o" 2>&1; check "default path missing exits 2" 2 $?
has "default path names the project memory dir" "$TMP/home/.claude/projects/-" "$TMP/o"
dflt="$(sed -n 's/^index-budget: no readable index at \(.*\)\. Fix:.*/\1/p' "$TMP/o")"
case "$dflt" in */memory/MEMORY.md) PASS=$((PASS+1)); echo "ok   default path ends in memory/MEMORY.md";;
  *) FAIL=$((FAIL+1)); echo "FAIL default path shape: '$dflt'";; esac
if [ -n "$dflt" ]; then
  mkdir -p "$(dirname "$dflt")"; gen "$dflt" 3 5
  HOME="$TMP/home" "$TOOL" > "$TMP/o" 2>&1; check "default path found is measured" 0 $?
fi

# 8. Bad arguments exit 2 with a Fix:.
"$TOOL" --bogus > "$TMP/o" 2>&1; check "unknown argument exits 2" 2 $?
has "unknown argument carries a Fix:" "Fix:" "$TMP/o"
"$TOOL" --file > "$TMP/o" 2>&1; check "--file without a path exits 2" 2 $?

# 9. --repo <path>: another repo's index, keyed the way Claude Code keys it.
#    The project slug replaces EVERY non-alphanumeric character with '-', so
#    ~/dev/gen_saas is -...-dev-gen-saas. A '/'-only rewrite computes
#    -...-dev-gen_saas, a directory that never exists.
mkdir -p "$TMP/home2" "$TMP/dev/gen_saas"
git -C "$TMP/dev/gen_saas" init -q
realrepo="$(cd "$TMP/dev/gen_saas" && pwd -P)"
slug="$(printf '%s' "$realrepo" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$TMP/home2/.claude/projects/$slug/memory"
gen "$TMP/home2/.claude/projects/$slug/memory/MEMORY.md" 3 5
HOME="$TMP/home2" "$TOOL" --repo "$TMP/dev/gen_saas" > "$TMP/o" 2>&1; check "--repo with '_' in its path finds its index" 0 $?
has "--repo names the slugged index" "$slug/memory/MEMORY.md" "$TMP/o"
# ...from a linked worktree too: the key is the MAIN checkout, not the tree.
git -C "$TMP/dev/gen_saas" commit -q --allow-empty -m init
git -C "$TMP/dev/gen_saas" worktree add -q "$TMP/wt/gen_saas-x" -b x
HOME="$TMP/home2" "$TOOL" --repo "$TMP/wt/gen_saas-x" > "$TMP/o" 2>&1; check "--repo from a worktree keys on the main checkout" 0 $?
has "--repo worktree names the main checkout's index" "$slug/memory/MEMORY.md" "$TMP/o"
# THE MISS: a path that is not a repo is exit 2 with a Fix:, never "within".
mkdir -p "$TMP/notarepo"
HOME="$TMP/home2" "$TOOL" --repo "$TMP/notarepo" > "$TMP/o" 2>&1; check "--repo on a non-repo exits 2" 2 $?
has "--repo non-repo carries a Fix:" "Fix:" "$TMP/o"
"$TOOL" --repo > "$TMP/o" 2>&1; check "--repo without a path exits 2" 2 $?
"$TOOL" --repo "$TMP/dev/gen_saas" --file "$TMP/small.md" > "$TMP/o" 2>&1; check "--repo with --file exits 2" 2 $?

echo "index-budget self-test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || { echo "SELF-TEST FAILED"; exit 1; }
echo "ALL CASES PASS"
