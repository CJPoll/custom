#!/usr/bin/env bash
# Self-test for athena:merge-boarding's integration-gate.
#
# The defect this tool exists to catch is invisible to both git and the forge:
# two branches with COMPLETELY DISJOINT file sets, each gate-green alone, that
# are gate-RED once integrated (shared budgets/registries are one global number
# or document). Case 4 reproduces exactly that and is the reason the suite
# exists -- it fails on a harness without this script.
#
# The other assertions are all about outcomes that look identical to a healthy
# run from the outside: a no-drift run that is indistinguishable from a skipped
# run, an unresolvable ref that reads as "no drift", and -- the subtle one --
# an intersection that is EMPTY BY CONSTRUCTION after a rebase being read as
# "the incoming delta missed my files, board it".
#
# Run: bash ai/skills/athena:merge-boarding/test/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"
GATE="${ROOT}/scripts/integration-gate"

PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# A global core.excludesFile has leaked into mktemp test repos on this machine
# before, silently ignoring fixture files. Neutralise all global git config.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '       %s\n' "$2"; }

# A gate that always passes, and records that it actually ran.
stub_gate_green() { printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$1" > "$2"; chmod +x "$2"; }
# A gate that is green unless BOTH files exist -- i.e. red only on integration.
stub_gate_pair()  { printf '#!/bin/sh\nif [ -f a.txt ] && [ -f b.txt ]; then echo "budget exceeded"; exit 1; fi\nexit 0\n' > "$1"; chmod +x "$1"; }

# new_repo <dir> -- a repo on branch `main` with one commit.
new_repo() {
  mkdir -p "$1"; ( cd "$1" && git init -q -b main . && echo seed > seed.txt \
    && git add seed.txt && git commit -qm seed )
}

# ---------------------------------------------------------------- case 1
# Target unchanged since the branch point: exit 0, says "unchanged", and the
# gate STILL RUNS. A no-drift run must not be indistinguishable from a skipped
# one -- that is the whole "silence is not success" class.
R="${TMP}/c1"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c1 exit 0 when target unchanged" || bad "c1 expected exit 0, got $rc" "$out"
grep -q 'unchanged since branch point' <<<"$out" && ok "c1 reports 'unchanged' explicitly" || bad "c1 no-drift verdict not printed" "$out"
[ -f "${R}/GATE_RAN" ] && ok "c1 gate still RAN on a no-drift run" || bad "c1 gate was skipped on no-drift"
grep -q 'INTEGRATION OK' <<<"$out" && ok "c1 prints INTEGRATION OK" || bad "c1 missing INTEGRATION OK" "$out"

# ---------------------------------------------------------------- case 2
# Target advanced and HEAD does NOT contain it: refuse, and say how to fix it.
R="${TMP}/c2"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f \
  && git checkout -q main && echo m > m.txt && git add m.txt && git commit -qm m \
  && git checkout -q feature )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c2 exit 2 when branch is behind the target" || bad "c2 expected exit 2, got $rc" "$out"
grep -q 'git rebase main' <<<"$out" && ok "c2 Fix: names the rebase" || bad "c2 Fix: does not name git rebase" "$out"
grep -q 'advanced' <<<"$out" && ok "c2 reports the drift" || bad "c2 drift not reported" "$out"
[ ! -f "${R}/GATE_RAN" ] && ok "c2 does not run the gate on a branch it refused" || bad "c2 ran the gate despite refusing"

# ---------------------------------------------------------------- case 3
# Branch contains the advanced target and the gate is green: INTEGRATION OK,
# and it prints the exact head SHA the admiral is told to merge.
R="${TMP}/c3"; new_repo "$R"
( cd "$R" && echo m > m.txt && git add m.txt && git commit -qm m \
  && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
head_sha="$( cd "$R" && git rev-parse HEAD )"
[ "$rc" -eq 0 ] && ok "c3 exit 0 when integrated and green" || bad "c3 expected exit 0, got $rc" "$out"
grep -q "INTEGRATION OK ${head_sha}" <<<"$out" && ok "c3 prints INTEGRATION OK <head sha>" || bad "c3 head SHA not printed" "$out"

# ---------------------------------------------------------------- case 4
# THE DEFECT CLASS. Disjoint file sets; each side green alone; RED integrated.
# A harness without this script cannot catch this: git reports no conflict and
# (with no CI) nothing re-runs the gate after the rebase.
R="${TMP}/c4"; new_repo "$R"
stub_gate_pair "${R}/g.sh"
( cd "$R" && echo a > a.txt && git add a.txt && git commit -qm a \
  && git checkout -qb feature && echo b > b.txt && git add b.txt && git commit -qm b )
# sanity: each side alone is green
( cd "$R" && git checkout -q main && "${R}/g.sh" >/dev/null 2>&1 ) && ok "c4 target alone is gate-green" || bad "c4 fixture: target alone not green"
( cd "$R" && git checkout -q --detach HEAD >/dev/null 2>&1; git checkout -q feature )
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 1 ] && ok "c4 exit 1: gate RED on the integrated head (the defect class)" || bad "c4 expected exit 1, got $rc" "$out"
grep -q 'disjoint file set does not imply a disjoint gate' <<<"$out" && ok "c4 Fix: explains green-alone != green-merged" || bad "c4 Fix: missing the explanation" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c4 printed INTEGRATION OK on a red gate" || ok "c4 does not print INTEGRATION OK when red"

# ---------------------------------------------------------------- case 5
# Intersection is computed correctly against an explicit --since anchor.
R="${TMP}/c5"; new_repo "$R"
( cd "$R" && echo v1 > shared.txt && echo o > other.txt && git add . && git commit -qm base )
base="$( cd "$R" && git rev-parse HEAD )"
( cd "$R" && echo v2 > shared.txt && echo x > incoming-only.txt && git add . && git commit -qm advance \
  && git checkout -qb feature && echo v3 > shared.txt && echo y > mine-only.txt && git add . && git commit -qm mine )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target main --no-fetch --since "$base" --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c5 exit 0" || bad "c5 expected exit 0, got $rc" "$out"
sect="$( sed -n '/^--- intersection/,$p' <<<"$out" )"
grep -q 'shared.txt' <<<"$sect" && ok "c5 intersection contains the overlapping file" || bad "c5 intersection missed shared.txt" "$sect"
grep -q 'mine-only.txt' <<<"$sect" && bad "c5 intersection wrongly included a non-overlapping file" "$sect" || ok "c5 intersection excludes non-overlapping files"
grep -q 'incoming-only.txt' <<<"$sect" && bad "c5 intersection wrongly included an incoming-only file" "$sect" || ok "c5 intersection excludes incoming-only files"

# ---------------------------------------------------------------- case 6
# An unresolvable --target is an ERROR, never a quiet exit 0 "no drift".
R="${TMP}/c6"; new_repo "$R"
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target origin/nope --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c6 exit 2 on an unresolvable target" || bad "c6 expected exit 2, got $rc" "$out"
grep -q 'origin/nope' <<<"$out" && ok "c6 names the ref it looked for" || bad "c6 did not name the missing ref" "$out"
[ ! -f "${R}/GATE_RAN" ] && ok "c6 does not run the gate on an unresolved ref" || bad "c6 ran the gate on an unresolved ref"
# same for --since
out="$( cd "$R" && "$GATE" --target main --no-fetch --since deadbeef --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c6 exit 2 on an unresolvable --since" || bad "c6 --since expected exit 2, got $rc" "$out"

# ---------------------------------------------------------------- case 7
# THE FAILED-LOOKUP GUARD. After integration with no --since, the incoming
# delta is empty BY CONSTRUCTION. It must report UNAVAILABLE, never "(empty)",
# because "empty" would be read as "incoming missed my files -- board it".
R="${TMP}/c7"; new_repo "$R"
( cd "$R" && echo m > m.txt && git add m.txt && git commit -qm m \
  && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
sect="$( sed -n '/^--- intersection/,$p' <<<"$out" )"
grep -q 'UNAVAILABLE' <<<"$sect" && ok "c7 intersection reports UNAVAILABLE, not empty" || bad "c7 uncomputable intersection read as empty" "$sect"
grep -q 'Do NOT read this as an empty intersection' <<<"$sect" && ok "c7 says explicitly not to read it as empty" || bad "c7 missing the do-not-misread warning" "$sect"
# With --since supplied, the same repo DOES produce a real verdict.
root_sha="$( cd "$R" && git rev-list --max-parents=0 HEAD )"
out2="$( cd "$R" && "$GATE" --target main --no-fetch --since "$root_sha" --gate "${R}/g.sh" 2>&1 )"
sect2="$( sed -n '/^--- intersection/,$p' <<<"$out2" )"
grep -q 'UNAVAILABLE' <<<"$sect2" && bad "c7 still UNAVAILABLE despite --since" "$sect2" || ok "c7 --since restores a real intersection verdict"

# ---------------------------------------------------------------- case 8
# Every non-zero exit path carries an actionable Fix: (repo convention).
R="${TMP}/c8"; new_repo "$R"
stub_gate_pair "${R}/gp.sh"; stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
( cd "$R" && echo a > a.txt && git add a.txt && git commit -qm a \
  && git checkout -qb feature && echo b > b.txt && git add b.txt && git commit -qm b )
fixless=""
check_fix() { # <label> <output> <rc>
  if [ "$3" -ne 0 ] && ! grep -q 'Fix:' <<<"$2"; then fixless="${fixless} $1"; fi
}
o="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/gp.sh" 2>&1 )"; check_fix gate-red "$o" $?
o="$( cd "$R" && "$GATE" --target nope --no-fetch --gate "${R}/g.sh" 2>&1 )"; check_fix bad-target "$o" $?
o="$( cd "$R" && "$GATE" --bogus 2>&1 )"; check_fix bad-flag "$o" $?
o="$( cd "$R" && "$GATE" --target 2>&1 )"; check_fix missing-arg "$o" $?
o="$( cd "${TMP}" && "$GATE" --no-fetch --gate /bin/true 2>&1 )"; check_fix not-a-repo "$o" $?
[ -z "$fixless" ] && ok "c8 every non-zero exit path carries Fix:" || bad "c8 paths missing Fix::${fixless}"

# ---------------------------------------------------------------- summary
printf '\nintegration-gate self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
