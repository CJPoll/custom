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

# record_verdict <repo> <verdict> [sha] -- forge a critic-review receipt for
# HEAD (or an explicit SHA). integration-gate now refuses a head with no green
# standing-judge verdict, so every case that expects INTEGRATION OK must show
# one. Written in the receipt's real on-disk shape and read back by
# critic-review's own reader, so a schema drift fails this suite rather than
# silently passing every merge.
record_verdict() { # <repo dir> <verdict> [sha]
  # ${3:-...}, never ${3-...}: record_pass passes an EXPLICITLY EMPTY third
  # argument when no SHA is given, and ${3-...} treats that as "set" -- which
  # silently wrote a receipt named for the empty string, i.e. a receipt that
  # matches nothing. The suite caught it; the colon is load-bearing.
  ( cd "$1" && sha="${3:-$(git rev-parse HEAD)}" \
    && d="$(git rev-parse --git-path critic-verdicts)" && mkdir -p "$d" \
    && printf '{"schema":1,"tool":"critic-review","sha":"%s","base":"main","verdict":"%s","findings":[],"dirty":false,"at":"2026-09-20T00:00:00Z"}\n' \
         "$sha" "$2" > "${d}/${sha}.json" )
}
record_pass() { record_verdict "$1" pass "${2-}"; }

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
record_pass "$R"
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
record_pass "$R"
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
record_pass "$R"
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
record_pass "$R"
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
o="$( cd "${TMP}" && "$GATE" --no-fetch --gate "${R}/g.sh" 2>&1 )"; check_fix not-a-repo "$o" $?
[ -z "$fixless" ] && ok "c8 every non-zero exit path carries Fix:" || bad "c8 paths missing Fix::${fixless}"

# ---------------------------------------------------------------- case 9
# THE DND-194 REGRESSION. Gate green, but the standing judge produced NO
# verdict for this head -- it never ran, or had not finished. This is the exact
# state in which PR #40 was merged on 2026-09-19 and landed a factual error on
# main. "No verdict" must never read as a pass.
R="${TMP}/c9"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "c9 exit 3 when no judge verdict exists for the head" || bad "c9 expected exit 3, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c9 declared INTEGRATION OK with no judge verdict" "$out" || ok "c9 does not print INTEGRATION OK without a verdict"
grep -q 'Fix:' <<<"$out" && ok "c9 carries an actionable Fix:" || bad "c9 missing Fix:" "$out"

# ---------------------------------------------------------------- case 10
# THE DND-212 REGRESSION. The judge RAN but FAILED OPEN (model unreachable), so
# it never looked at this diff. A fail-open is not a verdict.
R="${TMP}/c10"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_verdict "$R" fail-open
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "c10 exit 3 on a fail-open verdict" || bad "c10 expected exit 3, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c10 treated a fail-open as a pass" "$out" || ok "c10 fail-open is not a pass"

# A recorded BLOCK likewise refuses.
record_verdict "$R" block
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "c10 exit 3 on a recorded BLOCK verdict" || bad "c10 block expected exit 3, got $rc" "$out"

# ---------------------------------------------------------------- case 11
# THE SHA-MATCH DISCIPLINE. A verdict for the PARENT commit is not a verdict
# for the head being merged. Without this, the whole design would "pass" while
# judging a commit nobody is landing -- a green suite proving nothing.
R="${TMP}/c11"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
parent="$( cd "$R" && git rev-parse HEAD )"
( cd "$R" && echo g > g.txt && git add g.txt && git commit -qm g )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "$R" "$parent"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "c11 exit 3 when the verdict belongs to an earlier SHA" || bad "c11 expected exit 3, got $rc" "$out"
# and the same repo passes once the verdict names the actual head
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c11 exit 0 once the verdict names the head being merged" || bad "c11 expected exit 0, got $rc" "$out"

# ---------------------------------------------------------------- case 12
# The escape hatch is BOUNDED and ATTRIBUTABLE. It must land the head AND
# print the reason into the line the admiral copies into its state log --
# converting an unrecorded bypass into a recorded one.
R="${TMP}/c12"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model unreachable' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c12 override lands a head with no verdict" || bad "c12 expected exit 0, got $rc" "$out"
grep -q 'INTEGRATION OK .* (CRITIC OVERRIDE \[.*\]: model unreachable)' <<<"$out" && ok "c12 the reason is printed into INTEGRATION OK" || bad "c12 override not attributable in the OK line" "$out"
# ...and the state it overrode is READ from the receipt, not asserted. The old
# line claimed "NO standing-judge verdict" unconditionally.
grep -q 'state overridden: NO RECEIPT for this head in any checkout of this repo' <<<"$out" && ok "c12 names the state actually overridden" || bad "c12 did not name the overridden state" "$out"
# ...and it is not silently available: an empty reason is a usage error.
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override '' 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c12 override without a reason is a usage error" || bad "c12 expected exit 2, got $rc" "$out"
grep -q 'Fix:' <<<"$out" && ok "c12 usage error carries Fix:" || bad "c12 missing Fix:" "$out"

# ---------------------------------------------------------------- case 13
# ORDERING. A RED gate must be reported as RED (exit 1), not masked by the
# missing verdict (exit 3) -- the more specific failure wins.
R="${TMP}/c13"; new_repo "$R"
stub_gate_pair "${R}/gp.sh"
( cd "$R" && echo a > a.txt && git add a.txt && git commit -qm a \
  && git checkout -qb feature && echo b > b.txt && git add b.txt && git commit -qm b )
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/gp.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 1 ] && ok "c13 a red gate exits 1 even with no verdict recorded" || bad "c13 expected exit 1, got $rc" "$out"

# ---------------------------------------------------------------- case 14
# BLAST RADIUS (step 8c). Every criterion before this one asks whether the CODE
# is correct; this one asks what MERGING CAUSES. Measured 2026-09-20 (gen_saas
# PR #256, DND-234): merging would have run `terraform apply -auto-approve` and
# created a real, billable AWS KMS key, and the bar would have merged it.
# The workflow is seeded into the BASE commit so the .tf is what drives the
# verdict -- a workflow created inside the diff is itself a hit.
R="${TMP}/c14"; new_repo "$R"
mkdir -p "${R}/.github/workflows"
printf 'name: post-merge\non:\n  push:\n    branches: [main]\njobs:\n  d:\n    runs-on: ubuntu-latest\n    steps: [{run: terraform apply -auto-approve}]\n' > "${R}/.github/workflows/post-merge.yml"
( cd "$R" && git add -A && git commit -qm wf )
( cd "$R" && git checkout -qb feature && mkdir -p infra && echo 'resource {}' > infra/kms.tf && git add infra/kms.tf && git commit -qm tf )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 4 ] && ok "c14 exit 4 when merging performs a real-world action" || bad "c14 expected exit 4, got $rc" "$out"
grep -q 'BLAST-RADIUS HOT' <<<"$out" && ok "c14 names the blast radius as HOT" || bad "c14 no BLAST-RADIUS HOT line" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c14 printed INTEGRATION OK on a HOT head" "$out" || ok "c14 does NOT print INTEGRATION OK on a HOT head"
grep -q 'Fix:' <<<"$out" && ok "c14 carries an actionable Fix:" || bad "c14 missing Fix:" "$out"

# ...and the owner's own authorization lands it, RECORDED, never hidden.
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --owner-approval 'owner said go' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c14 --owner-approval lands the HOT head" || bad "c14 expected exit 0, got $rc" "$out"
grep -q 'INTEGRATION OK .*(OWNER-APPROVED: owner said go)' <<<"$out" && ok "c14 the approval is attributable in the OK line" || bad "c14 approval not in the OK line" "$out"
grep -q 'BLAST-RADIUS HOT' <<<"$out" && ok "c14 approval RECORDS without hiding what was approved" || bad "c14 approval suppressed the HOT block" "$out"
# ...and it is never silently available.
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --owner-approval '' 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c14 an empty --owner-approval is a usage error" || bad "c14 expected exit 2, got $rc" "$out"

# ---------------------------------------------------------------- case 15
# THE OVERRIDE'S SCOPE. --critic-override covers the ABSENCE of a verdict, not
# a recorded BLOCK. It used to short-circuit the verdict READ entirely, so it
# also merged past a BLOCK with real findings -- while printing "NO
# standing-judge verdict", the line the admiral copies verbatim into its state
# log. The attributable record said the opposite of what happened. Measured
# pressure toward exactly this reading: 2026-09-20-notif-platform's coordinator
# had to add an out-of-band header RETRACTING the override fallback mid-run.
R="${TMP}/c15"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"

# (a) recorded BLOCK for THIS head: the override is REFUSED.
record_verdict "$R" block
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model unreachable' 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "c15 override is REFUSED past a recorded BLOCK" || bad "c15 expected exit 3, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c15 override merged past a recorded BLOCK" "$out" || ok "c15 no INTEGRATION OK past a recorded BLOCK"
grep -q 'CRITIC OVERRIDE REFUSED' <<<"$out" && ok "c15 says the override was refused" || bad "c15 refusal not named" "$out"
grep -q 'Fix:' <<<"$out" && ok "c15 refusal carries an actionable Fix:" || bad "c15 refusal missing Fix:" "$out"
grep -q 'NO standing-judge verdict' <<<"$out" && bad "c15 printed the FALSE 'no verdict' line over a BLOCK" "$out" || ok "c15 does not claim 'no verdict' when one is recorded"

# (b) no verdict at all: still allowed, and the reason line is ACCURATE.
# NB: `git rev-parse --git-path` is CWD-RELATIVE in a main checkout, so the rm
# must run INSIDE the repo -- resolving it out here deletes nothing and the
# case silently tests the previous subcase's receipt instead.
( cd "$R" && rm -rf "$( git rev-parse --git-path critic-verdicts )" )
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model unreachable' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c15 override still lands a head with NO verdict" || bad "c15 expected exit 0, got $rc" "$out"
grep -q 'state overridden: NO RECEIPT for this head in any checkout of this repo' <<<"$out" && ok "c15 names NEVER RAN as the overridden state" || bad "c15 wrong/absent state label" "$out"

# (c) a verdict for an OLDER sha is no verdict for THIS head -- and the
#     override treats it as such, not as a BLOCK and not as a pass.
( cd "$R" && echo g > g.txt && git add g.txt && git commit -qm g )
parent="$( cd "$R" && git rev-parse HEAD~1 )"
record_pass "$R" "$parent"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model unreachable' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c15 a verdict for an older SHA is treated as no verdict" || bad "c15 expected exit 0, got $rc" "$out"
grep -q 'state overridden: NO RECEIPT for this head in any checkout of this repo' <<<"$out" && ok "c15 older-SHA verdict is labelled NEVER RAN for this head" || bad "c15 older-SHA state mislabelled" "$out"
# ...and that same older-SHA receipt is NOT what a BLOCK looks like: a BLOCK
# recorded for the OLDER sha must not refuse the CURRENT head.
record_verdict "$R" block "$parent"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model unreachable' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c15 a BLOCK on an OLDER sha does not refuse this head" || bad "c15 expected exit 0, got $rc" "$out"

# (d) fail-open (the DND-212 state): allowed, and NAMED as a fail-open.
record_verdict "$R" fail-open
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model unreachable' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c15 override lands a fail-open head" || bad "c15 expected exit 0, got $rc" "$out"
grep -q 'state overridden: judge FAILED OPEN' <<<"$out" && ok "c15 names FAILED OPEN as the overridden state" || bad "c15 fail-open state mislabelled" "$out"

# (e) a recorded PASS exists: the flag overrode NOTHING, and the record says so
#     rather than claiming a bypass that never happened.
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model unreachable' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c15 exit 0 when a PASS verdict exists" || bad "c15 expected exit 0, got $rc" "$out"
grep -q 'CRITIC OVERRIDE \[UNUSED' <<<"$out" && ok "c15 an unnecessary override records itself as UNUSED" || bad "c15 claimed a bypass that did not happen" "$out"

# ---------------------------------------------------------------- case 16
# THE DND-479 REGRESSION. The gate command was caller-supplied, so `--gate true`
# turned the whole gate into a pass: on 2026-09-24 a captain ran it on gen_saas
# PR #337 and got INTEGRATION OK, which read exactly like a real run. The bar
# lived in the caller's argv. A repo that DECLARES its gate on the landed target
# must run that gate; argv may not replace it.
# declared_repo <dir> <gate path> -- a repo whose landed main declares <gate
# path>; the gate touches GATE_RAN so a test can prove it actually ran.
declared_repo() {
  new_repo "$1"
  mkdir -p "$1/$(dirname "$2")"
  printf '#!/bin/sh\ntouch "%s/GATE_RAN"\nexit 0\n' "$1" > "$1/$2"; chmod +x "$1/$2"
  ( cd "$1" && git add "$2" && git commit -qm "declare $2" \
    && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
  record_pass "$1"
}
R="${TMP}/c16"; declared_repo "$R" ai/bin/harness-gate
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate true 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c16 --gate true is REFUSED where the target declares a gate" || bad "c16 expected exit 2, got $rc" "$out"
grep -q '^INTEGRATION OK' <<<"$out" && bad "c16 --gate true printed INTEGRATION OK (the DND-479 defect)" "$out" || ok "c16 no INTEGRATION OK for a caller-supplied no-op"
grep -q 'Fix:.*ai/bin/harness-gate' <<<"$out" && ok "c16 Fix: names the declared gate" || bad "c16 Fix: does not name the declared gate" "$out"
[ ! -f "${R}/GATE_RAN" ] && ok "c16 nothing ran on a refused gate" || bad "c16 a gate ran despite the refusal"
# A REAL command that differs from the declared gate is refused too: argv may
# not swap the landed bar for another one, however plausible.
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate 'mix test' 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c16 a different --gate is refused where a gate is declared" || bad "c16 different gate expected exit 2, got $rc" "$out"
# Omitting --gate runs the DECLARED gate, and every OK line names what ran.
out="$( cd "$R" && "$GATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c16 no --gate runs the declared gate" || bad "c16 declared gate expected exit 0, got $rc" "$out"
[ -f "${R}/GATE_RAN" ] && ok "c16 the declared gate actually RAN" || bad "c16 the declared gate did not run"
grep -q "INTEGRATION OK [0-9a-f]* (GATE: ai/bin/harness-gate -- declared on main)" <<<"$out" && ok "c16 INTEGRATION OK names the gate and its source" || bad "c16 OK line does not name the gate" "$out"
# Passing the declared gate explicitly (with or without ./) is the same thing.
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate ./ai/bin/harness-gate 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c16 --gate naming the declared gate is accepted" || bad "c16 explicit declared gate expected exit 0, got $rc" "$out"

# ---------------------------------------------------------------- case 17
# Declaration order and source. bin/prep-commit.sh (gen_saas) wins over
# ai/bin/harness-gate (custom), and ONLY the landed target counts: a gate the
# branch itself adds is not a declaration, because a PR must not set its own bar.
R="${TMP}/c17"; new_repo "$R"
mkdir -p "$R/bin" "$R/ai/bin"
printf '#!/bin/sh\ntouch "%s/PREP_RAN"\nexit 0\n' "$R" > "$R/bin/prep-commit.sh"
printf '#!/bin/sh\ntouch "%s/HARNESS_RAN"\nexit 0\n' "$R" > "$R/ai/bin/harness-gate"
chmod +x "$R/bin/prep-commit.sh" "$R/ai/bin/harness-gate"
( cd "$R" && git add -A && git commit -qm both && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$R/PREP_RAN" ] && [ ! -f "$R/HARNESS_RAN" ] && ok "c17 bin/prep-commit.sh is preferred over ai/bin/harness-gate" || bad "c17 wrong declared gate ran (rc=$rc)" "$out"
R="${TMP}/c17b"; new_repo "$R"
( cd "$R" && git checkout -qb feature && mkdir -p ai/bin \
  && printf '#!/bin/sh\nexit 0\n' > ai/bin/harness-gate && chmod +x ai/bin/harness-gate \
  && git add -A && git commit -qm "branch adds its own gate" )
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c17 a gate only the BRANCH adds is not a declaration" || bad "c17 branch-added gate expected exit 2, got $rc" "$out"
grep -q 'Fix:' <<<"$out" && ok "c17 no-declaration refusal carries Fix:" || bad "c17 missing Fix:" "$out"

# ---------------------------------------------------------------- case 18
# No declared gate: --gate is required, and a known no-op is refused. The
# forced-green shapes count too -- a real check whose failure is masked
# (`x || true`, `x; true`, `x &`) is a no-op with extra steps.
R="${TMP}/c18"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "$R"
noop_leaked=""; noop_fixless=""
for g in 'true' ':' '/bin/true' '/usr/bin/true' 'exit 0' 'exit' '   ' 'true;' 'true && :' \
         "sh -c 'true'" 'bash -c "exit 0"' 'env true' 'command true' 'echo ok' \
         "${R}/g.sh || true" "${R}/g.sh; true" "${R}/g.sh &" '! false' '( true )'; do
  o="$( cd "$R" && "$GATE" --target main --no-fetch --gate "$g" 2>&1 )"; c=$?
  if [ "$c" -ne 2 ] || grep -q '^INTEGRATION OK' <<<"$o"; then noop_leaked="${noop_leaked} [${g}]"; fi
  grep -q 'Fix:' <<<"$o" || noop_fixless="${noop_fixless} [${g}]"
done
[ -z "$noop_leaked" ] && ok "c18 every known no-op / forced-green --gate is refused (exit 2)" || bad "c18 no-op gates accepted:${noop_leaked}"
[ -z "$noop_fixless" ] && ok "c18 every no-op refusal carries Fix:" || bad "c18 no-op refusals missing Fix:${noop_fixless}"
[ ! -f "${R}/GATE_RAN" ] && ok "c18 no refused gate ran" || bad "c18 a refused gate still ran"
# ...and real gate shapes are NOT refused as no-ops (they may fail to run in
# this fixture -- exit 1 -- but never the exit-2 refusal).
real_refused=""
for g in 'mix test' 'cd backend && mix test' 'make test | tee log' 'bin/check --strict' 'npm test && npm run lint'; do
  o="$( cd "$R" && "$GATE" --target main --no-fetch --gate "$g" 2>&1 )"; c=$?
  [ "$c" -eq 2 ] && real_refused="${real_refused} [${g}]"
done
[ -z "$real_refused" ] && ok "c18 real gate commands are not mistaken for no-ops" || bad "c18 real gates refused:${real_refused}"
# ...while a real caller-supplied gate still works, and is NAMED with its source.
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh || ${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c18 a real fallback chain is not mistaken for a no-op" || bad "c18 real chain expected exit 0, got $rc" "$out"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
grep -q "INTEGRATION OK [0-9a-f]* (GATE: ${R}/g.sh -- caller-supplied; no gate declared on main)" <<<"$out" && ok "c18 OK line names a caller-supplied gate as such" || bad "c18 OK line does not name the caller gate" "$out"

# ---------------------------------------------------------------- case 19
# A gate the BRANCH edits is the same class one step removed: the branch picks
# its own bar. The gate still runs (a new check must run on integration), but
# the run says so loudly and the OK line carries it into the state log.
R="${TMP}/c19"; declared_repo "$R" ai/bin/harness-gate
( cd "$R" && printf '#!/bin/sh\nexit 0\n' > ai/bin/harness-gate && git commit -qam "weaken gate" )
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c19 an edited declared gate still runs" || bad "c19 expected exit 0, got $rc" "$out"
grep -q 'WARN gate .*ai/bin/harness-gate.* differs from main' <<<"$out" && ok "c19 warns that this branch edits its own gate" || bad "c19 no edited-gate warning" "$out"
grep -q 'INTEGRATION OK [0-9a-f]* (GATE: ai/bin/harness-gate -- declared on main; EDITED BY THIS BRANCH)' <<<"$out" && ok "c19 OK line marks the gate as edited by the branch" || bad "c19 OK line does not mark the edit" "$out"
R="${TMP}/c19b"; new_repo "$R"
( cd "$R" && printf '#!/bin/sh\nexit 0\n' > check.sh && chmod +x check.sh && git add check.sh && git commit -qm check \
  && git checkout -qb feature && printf '#!/bin/sh\n# weakened\nexit 0\n' > check.sh && git commit -qam weaken )
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate './check.sh' 2>&1 )"; rc=$?
grep -q 'EDITED BY THIS BRANCH' <<<"$out" && ok "c19 a caller-supplied gate the branch edits is marked too" || bad "c19 caller gate edit not marked" "$out"

# ---------------------------------------------------------------- case 20
# The HOT-OWNER-APPROVED line names the gate too: the owner-facing record must
# say what actually verified the head it authorizes.
R="${TMP}/c20"; declared_repo "$R" ai/bin/harness-gate
mkdir -p "${R}/.github/workflows"
( cd "$R" && git checkout -q main \
  && printf 'name: post-merge\non:\n  push:\n    branches: [main]\njobs:\n  d:\n    runs-on: ubuntu-latest\n    steps: [{run: terraform apply -auto-approve}]\n' > .github/workflows/post-merge.yml \
  && git add -A && git commit -qm wf && git checkout -q feature && git rebase -q main \
  && mkdir -p infra && echo 'resource {}' > infra/kms.tf && git add infra/kms.tf && git commit -qm tf )
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --owner-approval 'owner said go' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c20 owner-approved HOT head lands" || bad "c20 expected exit 0, got $rc" "$out"
grep -q 'BLAST-RADIUS HOT-OWNER-APPROVED .*(GATE: ai/bin/harness-gate -- declared on main)' <<<"$out" && ok "c20 HOT-OWNER-APPROVED names the gate" || bad "c20 HOT-OWNER-APPROVED line does not name the gate" "$out"
grep -q 'INTEGRATION OK [0-9a-f]* (GATE: ai/bin/harness-gate -- declared on main) (OWNER-APPROVED: owner said go)' <<<"$out" && ok "c20 OK line names the gate beside the approval" || bad "c20 OK line missing gate beside approval" "$out"

# ---------------------------------------------------------------- case 21
# DND-457: the verdict for a head is found from ANY checkout of the repo. The
# PASS is recorded in a linked worktree; the gate runs in the main checkout at
# the same head. It used to read only its own $GIT_DIR and report the judge as
# never having run. And a BLOCK in a THIRD checkout still refuses the override.
R="${TMP}/c21"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f \
  && git worktree add -q --detach "${TMP}/c21-wt" HEAD && git worktree add -q --detach "${TMP}/c21-wt2" HEAD )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "${TMP}/c21-wt"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c21 main checkout gate finds a PASS recorded in a worktree" || bad "c21 expected exit 0, got $rc" "$out"
grep -q 'has NOT run' <<<"$out" && bad "c21 claimed the judge has NOT run" "$out" || ok "c21 never claims the judge has NOT run"
record_verdict "${TMP}/c21-wt2" block
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model unreachable' 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "c21 a BLOCK in another checkout refuses the override" || bad "c21 expected exit 3, got $rc" "$out"
grep -q 'CRITIC OVERRIDE REFUSED' <<<"$out" && ok "c21 names the refusal" || bad "c21 refusal not named" "$out"

# ---------------------------------------------------------------- case 22
# The file sets list BOTH sides of a rename (DND-770). Rename detection (git's
# default, diff.renames) listed only a rename's new path, so a branch that
# renamed a file the target had just edited read an EMPTY intersection --
# "the incoming delta missed your files" -- and no replay was triggered for
# the file whose incoming edit now rides the reviewed rename. The fixture
# pins diff.renames=true and core.quotePath=true in the repo, so neither the
# neutralised global config nor a user config decides the result.
R="${TMP}/c22"; new_repo "$R"
NA="$(printf 't\303\251.txt')"   # a non-ASCII name, which core.quotePath C-quotes
( cd "$R" && git config diff.renames true && git config core.quotePath true \
  && seq 1 40 > moved.txt && git add . && git commit -qm base )
base="$( cd "$R" && git rev-parse HEAD )"
( cd "$R" && seq 1 41 > moved.txt && printf 'x\n' > "$NA" && git add . && git commit -qm advance \
  && git checkout -qb feature && git mv moved.txt renamed.txt && printf 'y\n' >> "$NA" \
  && git add . && git commit -qm mine )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --since "$base" --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c22 exit 0" || bad "c22 expected exit 0, got $rc" "$out"
sect="$( sed -n '/^--- intersection/,$p' <<<"$out" )"
grep -qx '    moved.txt' <<<"$sect" && ok "c22 intersection names the OLD path of a rename (DND-770)" || bad "c22 intersection missed the renamed-away path" "$sect"
grep -qxF "    ${NA}" <<<"$sect" && ok "c22 intersection names a non-ASCII path verbatim, not C-quoted" || bad "c22 non-ASCII path missing or quoted" "$sect"

# ---------------------------------------------------------------- case 23
# A `git diff` that FAILS (not "no changes") must be an ERROR, not an empty
# file set -- the failed-lookup class (~/dev/custom/ai/CLAUDE.md -> "A failed
# lookup must never look like an empty one"), one level down from case 6/7:
# those cover an unresolvable REF; this covers a resolvable ref pair whose
# diff itself cannot be computed (a corrupt object in an otherwise-valid
# repo). Reproduced by corrupting HEAD's tree object so `git diff --name-only`
# fails with a real git error while `git rev-parse` on the commits still
# succeeds.
R="${TMP}/c23"; new_repo "$R"
( cd "$R" && echo a > a.txt && git add a.txt && git commit -qm a )
base="$( cd "$R" && git rev-parse HEAD~1 )"
head="$( cd "$R" && git rev-parse HEAD )"
tree="$( cd "$R" && git rev-parse HEAD^{tree} )"
objfile="${R}/.git/objects/${tree:0:2}/${tree:2}"
chmod +w "$objfile"; echo garbage > "$objfile"
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_verdict "$R" pass "$head"
out="$( cd "$R" && "$GATE" --target main --no-fetch --since "$base" --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c23 exit 2 on a git-diff failure (corrupt object)" || bad "c23 expected exit 2, got $rc" "$out"
grep -q 'git diff failed measuring changed paths' <<<"$out" && ok "c23 names the failure, not an empty result" || bad "c23 did not surface the git-diff failure" "$out"
grep -q 'is corrupt' <<<"$out" && ok "c23 includes git's own error text" || bad "c23 swallowed git's stderr" "$out"
grep -q 'Fix:' <<<"$out" && ok "c23 carries a Fix: line" || bad "c23 missing Fix: line" "$out"
grep -q '(empty -- incoming delta is outside your reviewed file set)' <<<"$out" && bad "c23 misreported the failure as an empty intersection" "$out" || ok "c23 does not misreport the failure as empty"
[ ! -f "${R}/GATE_RAN" ] && ok "c23 does not run the gate past an unmeasurable file set" || bad "c23 ran the gate despite the git-diff failure"

# ---------------------------------------------------------------- summary
printf '\nintegration-gate self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
