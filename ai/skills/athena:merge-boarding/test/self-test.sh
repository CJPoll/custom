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

# --owner-approval takes a VERIFIABLE record of the owner's own words (owner
# approval policy, 2026-09-28): session:<session-uuid>/<message-uuid>
# quote:<words>, checked against a Claude Code transcript under
# $HOME/.claude/projects. This fixture HOME holds one human-typed owner turn.
FIXTURE_HOME="${TMP}/home"
FX_SID=11111111-2222-3333-4444-555555555555
FX_MID=aaaaaaaa-0000-0000-0000-000000000001
mkdir -p "${FIXTURE_HOME}/.claude/projects/proj"
printf '%s\n' '{"type":"user","uuid":"'"${FX_MID}"'","isSidechain":false,"entrypoint":"cli","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":"yes, provision the KMS key"}}' \
  > "${FIXTURE_HOME}/.claude/projects/proj/${FX_SID}.jsonl"
APPROVAL="session:${FX_SID}/${FX_MID} quote:yes, provision the KMS key"

# DND-486: integration-gate runs its gate inside test-slot. Every case uses a
# private one-slot pool under TMP (test-slot honors these seams only for a
# non-default pool dir), so this suite never touches or waits on the machine's
# real pool, whatever fleet is running.
# A suite launched from inside a real slot (a captain's wrapped harness-gate)
# must not carry that slot into its fixtures.
unset ATHENA_TEST_SLOT_HELD ATHENA_TEST_SLOT_HEARTBEAT
export ATHENA_TEST_SLOT_DIR="${TMP}/slots" ATHENA_TEST_SLOTS=1
TEST_SLOT="$(cd "${ROOT}/../../bin" && pwd)/test-slot"

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
    && git add seed.txt && git commit -qm seed \
    && printf '/g.sh\n/gp.sh\n/GATE_RAN\n/PREP_RAN\n/HARNESS_RAN\n/log\n' >> .git/info/exclude )
}
# The fixture gate stubs (g.sh, gp.sh), the markers they touch, and the `log`
# a `| tee log` gate writes live in the repo root but are the harness's, not
# the tree under test: excluded, so the DND-1011 clean-tree check judges only
# what the case itself leaves uncommitted.

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
out="$( cd "$R" && HOME="$FIXTURE_HOME" "$GATE" --target main --no-fetch --gate "${R}/g.sh" --owner-approval "$APPROVAL" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c14 --owner-approval lands the HOT head" || bad "c14 expected exit 0, got $rc" "$out"
grep -qF "(OWNER-APPROVED: ${APPROVAL})" <<<"$(grep 'INTEGRATION OK' <<<"$out")" && ok "c14 the approval is attributable in the OK line" || bad "c14 approval not in the OK line" "$out"
grep -q 'BLAST-RADIUS HOT' <<<"$out" && ok "c14 approval RECORDS without hiding what was approved" || bad "c14 approval suppressed the HOT block" "$out"
# ...and it is never silently available.
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --owner-approval '' 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c14 an empty --owner-approval is a usage error" || bad "c14 expected exit 2, got $rc" "$out"
# ...and free text is not a record: refused, no OK line, no receipt.
out="$( cd "$R" && HOME="$FIXTURE_HOME" "$GATE" --target main --no-fetch --gate "${R}/g.sh" --owner-approval 'owner said go' 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c14 a free-text --owner-approval is REFUSED (exit 2)" || bad "c14 free text: expected exit 2, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c14 free text printed INTEGRATION OK" "$out" || ok "c14 free text prints no INTEGRATION OK"
# ...and a VERIFIED record on a head nothing holds is refused too, so no OK
# line or receipt ever records an approval that gated nothing.
R="${TMP}/c14b"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo x > app.txt && git add app.txt && git commit -qm app )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "$R"
out="$( cd "$R" && HOME="$FIXTURE_HOME" "$GATE" --target main --no-fetch --gate "${R}/g.sh" --owner-approval "$APPROVAL" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c14b a verified approval on a COLD head is REFUSED (exit 2)" || bad "c14b expected exit 2, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c14b printed INTEGRATION OK with an unneeded approval" "$out" || ok "c14b no INTEGRATION OK records an approval that gated nothing"

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
out="$( cd "$R" && HOME="$FIXTURE_HOME" "$GATE" --target main --no-fetch --owner-approval "$APPROVAL" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c20 owner-approved HOT head lands" || bad "c20 expected exit 0, got $rc" "$out"
grep -q 'BLAST-RADIUS HOT-OWNER-APPROVED .*(GATE: ai/bin/harness-gate -- declared on main)' <<<"$out" && ok "c20 HOT-OWNER-APPROVED names the gate" || bad "c20 HOT-OWNER-APPROVED line does not name the gate" "$out"
grep -qF "(GATE: ai/bin/harness-gate -- declared on main) (OWNER-APPROVED: ${APPROVAL})" <<<"$(grep 'INTEGRATION OK' <<<"$out")" && ok "c20 OK line names the gate beside the approval" || bad "c20 OK line missing gate beside approval" "$out"

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

# ---------------------------------------------------------------- case 24
# DND-965: a pass leaves a per-SHA RECEIPT in the repo's git COMMON dir, the
# record locked-merge requires before it merges. Before this, INTEGRATION OK
# was stdout only, so "the gate passed on this SHA" rested on the caller's word
# (gen_saas #468 merged past a RED gate). The receipt records what locked-merge
# re-checks (head, base) and what the state log needs (gate, source, overrides,
# blast radius, time). Run from a LINKED worktree: the receipt must land in the
# common dir, where every checkout of the repo finds it.
receipt_of() { printf '%s/integration-receipts/%s.json' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" "$2"; }
R="${TMP}/c24"; new_repo "$R"
( cd "$R" && echo m > m.txt && git add m.txt && git commit -qm m && git worktree add -q -b feature "${TMP}/c24-wt" )
W="${TMP}/c24-wt"
( cd "$W" && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${TMP}/c24-GATE_RAN" "${TMP}/c24-g.sh"
record_pass "$W"
head_sha="$( cd "$W" && git rev-parse HEAD )"; main_sha="$( cd "$R" && git rev-parse main )"
out="$( cd "$W" && "$GATE" --target main --no-fetch --gate "${TMP}/c24-g.sh" 2>&1 )"; rc=$?
rf="${R}/.git/integration-receipts/${head_sha}.json"
[ "$rc" -eq 0 ] && ok "c24 exit 0" || bad "c24 expected exit 0, got $rc" "$out"
[ "$(receipt_of "$W" "$head_sha")" = "$rf" ] && ok "c24 a linked worktree resolves the MAIN common dir" || bad "c24 common dir mismatch" "$(receipt_of "$W" "$head_sha")"
if [ -f "$rf" ]; then
  ok "c24 receipt written at <common>/integration-receipts/<head>.json"
  [ "$(jq -r '.schema' "$rf")" = "integration-receipt/1" ] && ok "c24 schema integration-receipt/1" || bad "c24 schema" "$(cat "$rf")"
  [ "$(jq -r '.verdict' "$rf")" = "pass" ] && ok "c24 verdict pass" || bad "c24 verdict" "$(cat "$rf")"
  [ "$(jq -r '.head' "$rf")" = "$head_sha" ] && ok "c24 head is the gated SHA" || bad "c24 head" "$(cat "$rf")"
  [ "$(jq -r '.base' "$rf")" = "$main_sha" ] && ok "c24 base is the target SHA contained" || bad "c24 base" "$(cat "$rf")"
  [ "$(jq -r '.target_ref' "$rf")" = "main" ] && ok "c24 target_ref recorded" || bad "c24 target_ref" "$(cat "$rf")"
  [ "$(jq -r '.gate' "$rf")" = "${TMP}/c24-g.sh" ] && ok "c24 gate command recorded" || bad "c24 gate" "$(cat "$rf")"
  jq -e '.gate_source | test("caller-supplied")' "$rf" >/dev/null && ok "c24 gate source recorded" || bad "c24 gate_source" "$(cat "$rf")"
  jq -e '.blast_radius | startswith("BLAST-RADIUS ")' "$rf" >/dev/null && ok "c24 blast-radius verdict recorded" || bad "c24 blast_radius" "$(cat "$rf")"
  jq -e '.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$rf" >/dev/null && ok "c24 UTC timestamp recorded" || bad "c24 recorded_at" "$(cat "$rf")"
  jq -e '.critic_override == null and .owner_approval == null' "$rf" >/dev/null && ok "c24 no override recorded when none passed" || bad "c24 overrides" "$(cat "$rf")"
  jq -e --arg l "$(grep '^INTEGRATION OK' <<<"$out")" '.integration_ok_line == $l' "$rf" >/dev/null && ok "c24 receipt carries the INTEGRATION OK line verbatim" || bad "c24 integration_ok_line" "$(cat "$rf")"
  [ -z "$(find "${R}/.git/integration-receipts" -name '*.tmp*' 2>/dev/null)" ] && ok "c24 no temp file left behind (atomic write)" || bad "c24 temp file left"
else
  bad "c24 no receipt at ${rf}" "$out"
fi
[ -z "$(cd "$W" && git status --porcelain)" ] && ok "c24 receipt is outside the working tree" || bad "c24 receipt dirtied the tree" "$(cd "$W" && git status --porcelain)"

# ---------------------------------------------------------------- case 25
# A RED gate leaves NO passing receipt -- and a pass recorded by an earlier run
# on the same SHA does not survive it (the reported #468 shape).
R="${TMP}/c25"; new_repo "$R"
stub_gate_pair "${R}/g.sh"
( cd "$R" && echo a > a.txt && git add a.txt && git commit -qm a \
  && git checkout -qb feature && echo b > b.txt && git add b.txt && git commit -qm b )
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
mkdir -p "$(dirname "$rf")"; printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s"}\n' "$head_sha" > "$rf"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 1 ] && ok "c25 exit 1 (gate RED)" || bad "c25 expected exit 1, got $rc" "$out"
[ -e "$rf" ] && bad "c25 a passing receipt survived a RED gate" "$(cat "$rf")" || ok "c25 RED gate removed the stale receipt"

# ---------------------------------------------------------------- case 26
# A REFUSED run (branch behind the target, exit 2) also removes a stale pass.
R="${TMP}/c26"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f \
  && git checkout -q main && echo m > m.txt && git add m.txt && git commit -qm m && git checkout -q feature )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
mkdir -p "$(dirname "$rf")"; printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s"}\n' "$head_sha" > "$rf"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c26 exit 2 (behind target)" || bad "c26 expected exit 2, got $rc" "$out"
if [ -e "$rf" ]; then bad "c26 a passing receipt survived a refused run"; else ok "c26 refused run removed the stale receipt"; fi

# ---------------------------------------------------------------- case 27
# A --critic-override is recorded in the receipt, with the state it overrode.
R="${TMP}/c27"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'model down 3x' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c27 exit 0 under --critic-override" || bad "c27 expected exit 0, got $rc" "$out"
jq -e '.critic_override == "model down 3x" and (.critic_override_state | test("NO RECEIPT"))' "$rf" >/dev/null 2>&1 \
  && ok "c27 override reason and state recorded" || bad "c27 override not recorded" "$(cat "$rf" 2>&1)"

# ---------------------------------------------------------------- case 28
# A receipt that cannot be written is a FAILURE, never INTEGRATION OK: a pass
# locked-merge cannot find is a merge it will refuse, so success must not be
# announced ahead of the side effect it promises.
R="${TMP}/c28"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "$R"
mkdir -p "${R}/.git/integration-receipts"; chmod 555 "${R}/.git/integration-receipts"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
chmod 755 "${R}/.git/integration-receipts"
[ "$rc" -eq 5 ] && ok "c28 exit 5 when the receipt cannot be written" || bad "c28 expected exit 5, got $rc" "$out"
grep -q '^INTEGRATION OK' <<<"$out" && bad "c28 printed INTEGRATION OK with no receipt" "$out" || ok "c28 no INTEGRATION OK without a receipt"
grep -q '^Fix:' <<<"$out" && ok "c28 carries a Fix: line" || bad "c28 missing Fix:" "$out"

# ---------------------------------------------------------------- case 29
# --help documents the receipt and exit 5.
hout="$("$GATE" --help 2>/dev/null)"
grep -q 'integration-receipts' <<<"$hout" && ok "c29 --help names the receipt store" || bad "c29 --help lacks the receipt" "$hout"
grep -q '5 gate green but the receipt' <<<"$hout" && ok "c29 --help documents exit 5" || bad "c29 --help lacks exit 5" "$hout"

# ---------------------------------------------------------------- case 30
# DND-1011: the gate runs in the WORKING TREE, but the receipt certifies the
# committed HEAD. An uncommitted edit (or an un-added file) that turns a red
# head green must not become that head's pass.
stub_gate_needs_fixed() { printf '#!/bin/sh\n[ "$(cat f.txt 2>/dev/null)" = fixed ] || { echo "f.txt not fixed"; exit 1; }\nexit 0\n' > "$1"; chmod +x "$1"; }
R="${TMP}/c30"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo broken > f.txt && git add f.txt && git commit -qm f )
stub_gate_needs_fixed "${R}/g.sh"; record_pass "$R"
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
echo fixed > "${R}/f.txt"   # the tracked edit that is never committed
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c30 exit 2: a modified tracked file is refused before the gate" || bad "c30 expected exit 2, got $rc" "$out"
grep -q '^INTEGRATION OK' <<<"$out" && bad "c30 certified a head its gate never saw (dirty tree)" "$out" || ok "c30 no INTEGRATION OK on a dirty tree"
[ -e "$rf" ] && bad "c30 wrote a receipt for a dirty tree" "$(cat "$rf")" || ok "c30 no receipt for a dirty tree"
grep -q 'f.txt' <<<"$out" && grep -q '^Fix:' <<<"$out" && ok "c30 names the dirty path, with a Fix:" || bad "c30 dirty path / Fix: missing" "$out"

# An UNTRACKED file counts too: forgetting `git add` is how a committed head
# ships broken while its working tree passes.
R="${TMP}/c30u"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo x > x.txt && git add x.txt && git commit -qm x )
stub_gate_needs_fixed "${R}/g.sh"; record_pass "$R"
echo fixed > "${R}/f.txt"   # never added
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ! grep -q '^INTEGRATION OK' <<<"$out" && ok "c30 an untracked file is refused too" || bad "c30 untracked file passed (rc=$rc)" "$out"

# A gate that CHANGES the tree or HEAD (gen_saas prep-commit auto-commits)
# passed on something other than the head it would certify: refused.
R="${TMP}/c30c"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo x > x.txt && git add x.txt && git commit -qm x )
printf '#!/bin/sh\necho y > y.txt && git add y.txt && git commit -qm auto-fix\nexit 0\n' > "${R}/g.sh"; chmod +x "${R}/g.sh"
record_pass "$R"
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ! grep -q '^INTEGRATION OK' <<<"$out" && ok "c30 a gate that moved HEAD is not a pass of the old head" || bad "c30 gate moved HEAD and still passed (rc=$rc)" "$out"
[ -e "$rf" ] && bad "c30 receipt written for a head the gate moved off" "$(cat "$rf")" || ok "c30 no receipt when the gate moved HEAD"

# Ignored files are not dirt (build output, deps): a clean head still passes.
R="${TMP}/c30i"; new_repo "$R"
( cd "$R" && printf 'build/\n' > .gitignore && git add .gitignore && git commit -qm ignore \
  && git checkout -qb feature && echo x > x.txt && git add x.txt && git commit -qm x && mkdir build && echo o > build/out )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"; record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^INTEGRATION OK' <<<"$out" && ok "c30 ignored files are not dirt" || bad "c30 ignored file refused (rc=$rc)" "$out"

# ---------------------------------------------------------------- case 31
# DND-1010 --with-critic. The judge runs beside the gate; the verdict step
# then reads its receipt exactly as it would have. Stubbed via critic-review's
# own CRITIC_REVIEW_STUB hook, so the real receipt writer and reader run. A
# private TMPDIR keeps the temp-log check immune to other runs on the machine.
C31TMP="${TMP}/c31tmp"; mkdir -p "$C31TMP"
printf 'looks good\nFINDINGS: none\n' > "${TMP}/critic-pass"
printf 'bad\nFINDINGS: correctness\n' > "${TMP}/critic-block"
wc_gate() { ( cd "$1" && TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="$2" "$GATE" --target main --no-fetch --gate "$3" --with-critic 2>&1 ); }
R="${TMP}/c31"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"   # no verdict recorded
out="$(wc_gate "$R" "${TMP}/critic-pass" "${R}/g.sh")"; rc=$?
[ "$rc" -eq 0 ] && [ -f "${R}/GATE_RAN" ] && grep -q '^INTEGRATION OK' <<<"$out" \
  && ok "c31 --with-critic: judge + gate both run, a PASS lands INTEGRATION OK" || bad "c31 with-critic pass (rc=$rc)" "$out"
grep -q 'beside the gate' <<<"$out" && ok "c31 says the judge ran beside the gate" || bad "c31 no concurrency line" "$out"
out="$(wc_gate "$R" "${TMP}/critic-block" "${R}/g.sh")"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'not re-run' <<<"$out" && ok "c31 a PASS already recorded for the head is not re-judged" || bad "c31 re-judged a PASS (rc=$rc)" "$out"
R="${TMP}/c31b"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$(wc_gate "$R" "${TMP}/critic-block" "${R}/g.sh")"; rc=$?
[ "$rc" -eq 3 ] && ! grep -q '^INTEGRATION OK' <<<"$out" && ok "c31 a BLOCK from the concurrent judge is refused (exit 3)" || bad "c31 block (rc=$rc)" "$out"
R="${TMP}/c31c"; new_repo "$R"
stub_gate_pair "${R}/gp.sh"
( cd "$R" && echo a > a.txt && git add a.txt && git commit -qm a && git checkout -qb feature && echo b > b.txt && git add b.txt && git commit -qm b )
out="$(wc_gate "$R" "${TMP}/critic-block" "${R}/gp.sh")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'critic-review: BLOCKED' <<<"$out" \
  && ok "c31 a RED gate still joins the judge: one round returns both results" || bad "c31 red gate + judge (rc=$rc)" "$out"
[ -z "$(find "$C31TMP" -maxdepth 1 -name 'integration-gate-critic.*' 2>/dev/null)" ] \
  && ok "c31 the judge's temp log is removed" || bad "c31 temp log left behind" "$(ls "$C31TMP")"

# No orphan. The judge is blocked (its stub is a FIFO nobody writes) when the
# gate step exits 2 without joining it (the gate moved HEAD). The EXIT trap
# must stop the judge's whole process group.
R="${TMP}/c31d"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo x > x.txt && git add x.txt && git commit -qm x )
printf '#!/bin/sh\necho y > y.txt && git add y.txt && git commit -qm auto-fix\nexit 0\n' > "${R}/g.sh"; chmod +x "${R}/g.sh"
mkfifo "${TMP}/critic-fifo"
out="$(wc_gate "$R" "${TMP}/critic-fifo" "${R}/g.sh")"; rc=$?
pg="$(sed -n 's/.*beside the gate (pgid \([0-9]*\),.*/\1/p' <<<"$out")"
gone=0
if [ -n "$pg" ]; then
  for _ in $(seq 1 50); do
    kill -0 -- "-${pg}" 2>/dev/null || { gone=1; break; }
    sleep 0.1
  done
fi
[ "$rc" -eq 2 ] && [ -n "$pg" ] && [ "$gone" -eq 1 ] \
  && ok "c31 a gate step that exits early stops the judge's process group (no orphan)" \
  || bad "c31 judge left running (rc=$rc pgid=${pg:-none} gone=$gone)" "$out"
[ -n "$pg" ] && kill -KILL -- "-${pg}" 2>/dev/null
rm -f "${TMP}/critic-fifo"

# ---------------------------------------------------------------- case 32
# DND-986: a CARRIED critic PASS (critic-review found an identical change that
# already passed, and recorded a schema-2 receipt naming it) is a present
# verdict. The OK line and the receipt must NAME it, so a post-merge defect can
# be traced to a carry. record_carried forges the on-disk schema-2 shape.
record_carried() { # <repo dir> <carried_from sha> [sha] [schema]
  ( cd "$1" && sha="${3:-$(git rev-parse HEAD)}" \
    && d="$(git rev-parse --git-path critic-verdicts)" && mkdir -p "$d" \
    && jq -n --arg sha "$sha" --arg src "$2" --argjson schema "${4:-2}" \
         '{schema:$schema, tool:"critic-review", sha:$sha, base:"main", verdict:"pass", findings:[],
           dirty:false, at:"2026-09-27T00:00:00Z", merge_base:("a"*40), patch_id:("b"*40),
           diff_digest:("c"*64), msgs_digest:("d"*64), judge_digest:("e"*64),
           carried_from:(if $src == "" then null else $src end),
           carried_receipt:(if $src == "" then null else "/x/\($src).json" end)}' > "${d}/${sha}.json" )
}
src_sha="$(printf 'f%.0s' {1..40})"
R="${TMP}/c32"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_carried "$R" "$src_sha"
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c32 F1 carried PASS: exit 0" || bad "c32 F1 expected exit 0, got $rc" "$out"
grep -Eq "^INTEGRATION OK ${head_sha} .*\(CRITIC CARRIED from ${src_sha:0:12}\)" <<<"$out" \
  && ok "c32 F1 OK line names the carried critic PASS" || bad "c32 F1 OK line lacks CRITIC CARRIED" "$out"
jq -e --arg s "$src_sha" '.critic_carried_from == $s and .schema == "integration-receipt/1"' "$rf" >/dev/null 2>&1 \
  && ok "c32 F1 receipt records critic_carried_from; schema unchanged" || bad "c32 F1 receipt" "$(cat "$rf" 2>&1)"
jq -e --arg l "$(grep '^INTEGRATION OK' <<<"$out")" '.integration_ok_line == $l' "$rf" >/dev/null 2>&1 \
  && ok "c32 F1 receipt carries the OK line verbatim" || bad "c32 F1 integration_ok_line" "$(cat "$rf" 2>&1)"

# F1b a carried PASS gated with a precautionary --critic-override: the OK line
# names BOTH (the override is UNUSED); the carry must not be dropped from it.
rf_b="$(receipt_of "$R" "$head_sha")"; rm -f "$rf_b"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" --critic-override 'belt and braces' 2>&1 )"; rc=$?
okl="$(grep '^INTEGRATION OK' <<<"$out")"
[ "$rc" -eq 0 ] && grep -q "(CRITIC CARRIED from ${src_sha:0:12})" <<<"$okl" && grep -q 'CRITIC OVERRIDE \[UNUSED' <<<"$okl" \
  && ok "c32 F1b carried PASS + unused override: OK line names both" || bad "c32 F1b OK line dropped the carry or the override (rc $rc)" "$okl"

# F1c a carried PASS confirmed by an INTERACTION review of the upstream delta
# (round 3, owner spec): the OK line says CARRIED + INTERACTION and names the
# range; the receipt records it.
R="${TMP}/c32i"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_carried "$R" "$src_sha"
up_from="$(printf 'a%.0s' {1..40})"; up_to="$(printf 'c%.0s' {1..40})"
( cd "$R" && d="$(git rev-parse --git-path critic-verdicts)" && f="${d}/$(git rev-parse HEAD).json" \
  && jq --arg r "${up_from}..${up_to}" '.upstream_range = $r | .interaction = "pass"' "$f" > "$f.t" && mv "$f.t" "$f" )
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
okl="$(grep '^INTEGRATION OK' <<<"$out")"
[ "$rc" -eq 0 ] && grep -qF "(CRITIC CARRIED + INTERACTION from ${src_sha:0:12}; upstream ${up_from:0:12}..${up_to:0:12})" <<<"$okl" \
  && ok "c32 F1c OK line names the interaction-confirmed carry and its range" || bad "c32 F1c OK line (rc $rc)" "$okl"
jq -e --arg s "$src_sha" --arg r "${up_from}..${up_to}" '.critic_carried_from == $s and .critic_upstream_range == $r' "$rf" >/dev/null 2>&1 \
  && ok "c32 F1c receipt records critic_upstream_range" || bad "c32 F1c receipt" "$(cat "$rf" 2>&1)"
jq -e '.critic_upstream_range == null' "$(receipt_of "${TMP}/c32" "$( cd "${TMP}/c32" && git rev-parse HEAD )")" >/dev/null 2>&1 \
  && ok "c32 F1c a pure carry records critic_upstream_range null" || bad "c32 F1c pure-carry receipt lacks a null range"

# F2 a JUDGED schema-2 PASS: no CRITIC CARRIED, critic_carried_from null.
R="${TMP}/c32b"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_carried "$R" ""
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c32 F2 judged schema-2 PASS: exit 0" || bad "c32 F2 expected exit 0, got $rc" "$out"
grep -q 'CRITIC CARRIED' <<<"$out" && bad "c32 F2 judged PASS reported as carried" "$out" || ok "c32 F2 no CRITIC CARRIED"
jq -e '.critic_carried_from == null' "$rf" >/dev/null 2>&1 && ok "c32 F2 critic_carried_from is null" || bad "c32 F2 receipt" "$(cat "$rf" 2>&1)"

# F3 a legacy schema-1 PASS still gates green (record_pass is schema 1).
R="${TMP}/c32c"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c32 F3 schema-1 PASS: exit 0 (no regression)" || bad "c32 F3 expected exit 0, got $rc" "$out"

# F4 THE MISS: a carried PASS for the PRE-rebase SHA only. The gate never
# carries: the exact head has no receipt, so exit 3 and no integration receipt.
R="${TMP}/c32d"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
old_head="$( cd "$R" && git rev-parse HEAD )"
record_carried "$R" "$src_sha" "$old_head"
( cd "$R" && git commit -q --amend --no-edit --date=2001-01-01T00:00:00 )
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "c32 F4 no receipt for the exact head: exit 3 (never carried at gate time)" || bad "c32 F4 expected exit 3, got $rc" "$out"
[ -e "$rf" ] && bad "c32 F4 an integration receipt was written" "$(cat "$rf")" || ok "c32 F4 no integration receipt written"

# F4b a carried receipt whose carried_from is malformed is not a pass.
R="${TMP}/c32e"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_carried "$R" "not-a-sha"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "c32 F4b malformed carried_from: exit 3" || bad "c32 F4b expected exit 3, got $rc" "$out"

# F5 --with-critic (DND-1010) on a rebased, unchanged branch: the judge the
# gate runs beside itself is critic-review's own writer, so it carries the
# earlier PASS and reviews only the upstream delta. No forged receipt: the
# first PASS and the carry are both real critic-review runs (stubbed judge).
R="${TMP}/c32f"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f \
  && TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/critic-pass" "${ROOT}/../../bin/critic-review" --base main >/dev/null 2>&1 \
  && git checkout -q main && echo u > u.txt && git add u.txt && git commit -qm upstream \
  && git checkout -q feature && git rebase -q main )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
out="$(wc_gate "$R" "${TMP}/critic-pass" "${R}/g.sh")"; rc=$?
okl="$(grep '^INTEGRATION OK' <<<"$out")"
[ "$rc" -eq 0 ] && grep -q 'critic-review: PASS (CARRIED + INTERACTION)' <<<"$out" \
  && grep -q '(CRITIC CARRIED + INTERACTION from ' <<<"$okl" \
  && ok "c32 F5 --with-critic on an unchanged rebase: the judge carries + reviews the interaction, OK line names it" \
  || bad "c32 F5 --with-critic carry (rc $rc)" "$out"

# DND-486: the gate runs inside a machine test slot, and a gate that never ran
# (no slot within the wait window, or no outcome recorded) is exit 6 -- never
# INTEGRATION OK, never "gate RED". A missing wrapper is exit 2, never an
# unslotted run. Cases s1..s8 follow the DND-486 QA plan; s9..s12 extend it.

# await_file PATH -- bounded poll (<= 20 s) for a file to appear.
await_file() { local i; for ((i = 0; i < 100; i++)); do [ -e "$1" ] && return 0; sleep 0.2; done; return 1; }

# slot_repo <dir> <gate body> -- a repo whose landed main declares
# ai/bin/harness-gate with <gate body> (sh), on a feature branch with a PASS.
slot_repo() {
  new_repo "$1"; mkdir -p "$1/ai/bin"
  printf '#!/bin/sh\n%s\n' "$2" > "$1/ai/bin/harness-gate"; chmod +x "$1/ai/bin/harness-gate"
  ( cd "$1" && git add -A && git commit -qm gate \
    && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
  record_pass "$1"
}

# s1: the gate ran INSIDE a slot of the (test) pool. The marker lives
# outside the repo: the DND-1011 check refuses a gate that dirties the tree.
R="${TMP}/s1"; slot_repo "$R" "printf '%s' \"\$ATHENA_TEST_SLOT_HELD\" > '${R}.HELD'"
out="$( cd "$R" && "$GATE" --target main --no-fetch 2>&1 )"; rc=$?
pool="$(realpath -m "${TMP}/slots")"
[ "$rc" -eq 0 ] && ok "s1 exit 0 for a green gate run in a slot" || bad "s1 expected exit 0, got $rc" "$out"
[ "$(cat "${R}.HELD" 2>/dev/null)" = "${pool}:1" ] && ok "s1 the gate ran holding slot ${pool}:1" || bad "s1 gate did not run in a slot (HELD='$(cat "${R}.HELD" 2>/dev/null)')" "$out"

# s2: slot 1 held by a foreign run; a 1 s slot wait times out -> exit 6.
R="${TMP}/s2"; slot_repo "$R" "touch '${R}/GATE_RAN'"
mkfifo "${TMP}/s2.fifo"
"$TEST_SLOT" --label 's2 foreign holder' -- bash -c ': > "$1"; exec 3<>"$2"; read -t 30 -u 3 _x' _ "${TMP}/s2.started" "${TMP}/s2.fifo" 2>/dev/null &
holder=$!
await_file "${TMP}/s2.started" || bad "s2 fixture: the foreign holder never started"
out="$( cd "$R" && "$GATE" --target main --no-fetch --slot-wait-timeout 1 2>&1 )"; rc=$?
timeout 5 bash -c 'printf "go\n" > "$1"' _ "${TMP}/s2.fifo"; wait "$holder" 2>/dev/null
[ "$rc" -eq 6 ] && ok "s2 exit 6 when no slot frees within the wait" || bad "s2 expected exit 6, got $rc" "$out"
grep -q 'GATE NOT RUN' <<<"$out" && ok "s2 says GATE NOT RUN" || bad "s2 missing GATE NOT RUN" "$out"
grep -q 'Fix:' <<<"$out" && ok "s2 carries Fix:" || bad "s2 missing Fix:" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "s2 printed INTEGRATION OK for a gate that never ran" "$out" || ok "s2 no INTEGRATION OK"
grep -q 'gate RED' <<<"$out" && bad "s2 called a gate that never ran RED" "$out" || ok "s2 no 'gate RED'"
[ ! -f "${R}/GATE_RAN" ] && ok "s2 the gate did not run" || bad "s2 the gate ran despite the timeout"

# s3: a red gate is still exit 1 RED.
R="${TMP}/s3"; slot_repo "$R" "exit 1"
out="$( cd "$R" && "$GATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'gate RED' <<<"$out" && ok "s3 a failing gate is exit 1 gate RED" || bad "s3 expected exit 1 gate RED, got $rc" "$out"

# s4: a gate that itself exits 75 RAN and failed: RED, never "not run".
R="${TMP}/s4"; slot_repo "$R" "exit 75"
out="$( cd "$R" && "$GATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'gate RED' <<<"$out" && ok "s4 a gate exiting 75 on its own is RED (exit 1), not 6" || bad "s4 expected exit 1 gate RED, got $rc" "$out"
grep -q 'GATE NOT RUN' <<<"$out" && bad "s4 read the gate's own 75 as a slot timeout" "$out" || ok "s4 not mistaken for a slot timeout"

# layout_copy <dir> -- a copy of the checkout layout integration-gate resolves
# its siblings from: the script copied (so realpath lands here), critic-review
# and blast-radius linked to the real ones. It is a git repo, so its own main
# checkout (where test-slot is resolved) is the layout itself.
layout_copy() {
  mkdir -p "$1/ai/skills/athena:merge-boarding/scripts" "$1/ai/bin"
  git init -q "$1"
  cp "$GATE" "$1/ai/skills/athena:merge-boarding/scripts/integration-gate"
  ln -s "$(cd "${ROOT}/../../bin" && pwd)/critic-review" "$1/ai/bin/critic-review"
  ln -s "$(cd "${ROOT}/../../bin" && pwd)/blast-radius" "$1/ai/bin/blast-radius"
}

# s5: test-slot is not executable in the script's main checkout (the layout)
# -> exit 2, gate never ran.
L="${TMP}/s5-layout"; layout_copy "$L"
printf '#!/bin/sh\nexit 0\n' > "$L/ai/bin/test-slot"; chmod -x "$L/ai/bin/test-slot"
R="${TMP}/s5"; slot_repo "$R" "touch '${R}/GATE_RAN'"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "s5 exit 2 when test-slot is not executable" || bad "s5 expected exit 2, got $rc" "$out"
grep -q "Fix:.*${L}/ai/bin/test-slot" <<<"$out" && ok "s5 Fix: names the missing test-slot path" || bad "s5 Fix: does not name the test-slot path" "$out"
[ ! -f "${R}/GATE_RAN" ] && ok "s5 the gate never ran unslotted" || bad "s5 the gate ran without a slot"
rm -f "$L/ai/bin/test-slot"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && [ ! -f "${R}/GATE_RAN" ] && ok "s5 exit 2 when test-slot is absent, gate not run" || bad "s5 absent test-slot expected exit 2, got $rc" "$out"

# s6: a test-slot that exits 0 but records no outcome -> exit 6, never OK/RED.
L="${TMP}/s6-layout"; layout_copy "$L"
printf '#!/bin/sh\nexit 0\n' > "$L/ai/bin/test-slot"; chmod +x "$L/ai/bin/test-slot"
R="${TMP}/s6"; slot_repo "$R" "touch '${R}/GATE_RAN'"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 6 ] && ok "s6 exit 6 when test-slot left no outcome" || bad "s6 expected exit 6, got $rc" "$out"
grep -q 'Fix:.*test-slot left no outcome' <<<"$out" && ok "s6 Fix: names the missing outcome" || bad "s6 Fix: does not name the missing outcome" "$out"
grep -qE 'INTEGRATION OK|gate RED' <<<"$out" && bad "s6 read a missing outcome as OK or RED" "$out" || ok "s6 neither OK nor RED"
# ...and an outcome it cannot parse is the same: not a result.
printf '#!/bin/sh\nwhile [ "$1" != -- ]; do [ "$1" = --outcome-file ] && echo garbage > "$2"; shift; done\nexit 0\n' > "$L/ai/bin/test-slot"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 6 ] && ! grep -qE 'INTEGRATION OK|gate RED' <<<"$out" && ok "s6 an unparseable outcome is exit 6, neither OK nor RED" || bad "s6 unparseable outcome expected exit 6, got $rc" "$out"

# s7: a green gate keeps the OK line's format, and blast-radius still ran.
R="${TMP}/s7"; slot_repo "$R" "exit 0"
out="$( cd "$R" && "$GATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q "^INTEGRATION OK [0-9a-f]* (GATE: ai/bin/harness-gate -- declared on main)$" <<<"$out" && ok "s7 INTEGRATION OK format unchanged" || bad "s7 OK line changed (rc=$rc)" "$out"
grep -q 'BLAST-RADIUS' <<<"$out" && ok "s7 blast-radius still ran" || bad "s7 blast-radius did not run" "$out"

# s8: --help needs no test-slot and lists exit 6 (exit 5 is the receipt's).
out="$( cd "$TMP" && "${TMP}/s5-layout/ai/skills/athena:merge-boarding/scripts/integration-gate" --help 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -qE '^ +6 gate NOT RUN' <<<"$out" && ok "s8 --help exits 0 without test-slot and lists exit 6" || bad "s8 --help expected exit 0 listing exit 6, got $rc" "$out"

# A bad --slot-wait-timeout is a usage error with Fix:.
out="$( cd "$TMP" && "$GATE" --slot-wait-timeout soon 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'Fix:' <<<"$out" && ok "s9 a non-integer --slot-wait-timeout is exit 2 with Fix:" || bad "s9 expected exit 2 with Fix:, got $rc" "$out"

# s10: the slotted gate keeps the shell semantics it had unslotted, pipefail
# included: a failing check piped into tee is still RED, never green.
R="${TMP}/s10"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
record_pass "$R"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate 'false | cat' 2>&1 )"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'gate RED' <<<"$out" && ok "s10 'false | cat' stays RED inside the slot (pipefail kept)" || bad "s10 expected exit 1 gate RED, got $rc" "$out"

# s11: --with-critic and a slot that never frees. The gate never ran (exit
# 6), but the judge beside it did: it is joined, so its verdict is printed
# and recorded, and the re-run does not pay for the judge again.
R="${TMP}/s11"; slot_repo "$R" "touch '${R}/GATE_RAN'"
rm -rf "${R}/$(cd "$R" && git rev-parse --git-path critic-verdicts)"   # no verdict yet (git-path is relative)
mkfifo "${TMP}/s11.fifo"
"$TEST_SLOT" --label 's11 foreign holder' -- bash -c ': > "$1"; exec 3<>"$2"; read -t 30 -u 3 _x' _ "${TMP}/s11.started" "${TMP}/s11.fifo" 2>/dev/null &
holder=$!
await_file "${TMP}/s11.started" || bad "s11 fixture: the foreign holder never started"
out="$( cd "$R" && TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/critic-pass" "$GATE" --target main --no-fetch --with-critic --slot-wait-timeout 1 2>&1 )"; rc=$?
timeout 5 bash -c 'printf "go\n" > "$1"' _ "${TMP}/s11.fifo"; wait "$holder" 2>/dev/null
[ "$rc" -eq 6 ] && grep -q 'GATE NOT RUN' <<<"$out" && ok "s11 --with-critic: a slot timeout is still exit 6" || bad "s11 expected exit 6, got $rc" "$out"
grep -q '^critic-review: PASS' <<<"$out" && ok "s11 the judge was joined and its verdict printed" || bad "s11 judge not joined on GATE NOT RUN" "$out"
( cd "$R" && "${ROOT}/../../bin/critic-review" --verdict-for "$(git rev-parse HEAD)" >/dev/null 2>&1 ) \
  && ok "s11 the judge's PASS is recorded for the re-run" || bad "s11 no PASS recorded after GATE NOT RUN"
[ ! -f "${R}/GATE_RAN" ] && ok "s11 the gate did not run" || bad "s11 the gate ran despite the timeout"

# s12: run from a LINKED WORKTREE of the custom repo, the gate uses the MAIN
# checkout's test-slot, never the worktree's copy (test-slot's stable
# interface: every caller agrees on N). Each copy marks which one ran, then
# execs the real test-slot.
L="${TMP}/s12-layout"; layout_copy "$L"
REAL_SLOT="$(cd "${ROOT}/../../bin" && pwd)/test-slot"
printf '#!/bin/sh\ntouch "%s"\nexec "%s" "$@"\n' "${TMP}/s12.MAIN_USED" "$REAL_SLOT" > "$L/ai/bin/test-slot"; chmod +x "$L/ai/bin/test-slot"
( cd "$L" && git add -A && git commit -qm layout && git worktree add -q "${TMP}/s12-wt" )
printf '#!/bin/sh\ntouch "%s"\nexec "%s" "$@"\n' "${TMP}/s12.WT_USED" "$REAL_SLOT" > "${TMP}/s12-wt/ai/bin/test-slot"
R="${TMP}/s12"; slot_repo "$R" "exit 0"
out="$( cd "$R" && "${TMP}/s12-wt/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "s12 exit 0 from a worktree copy of the script" || bad "s12 expected exit 0, got $rc" "$out"
[ -f "${TMP}/s12.MAIN_USED" ] && [ ! -f "${TMP}/s12.WT_USED" ] \
  && ok "s12 the main checkout's test-slot ran, not the worktree's" \
  || bad "s12 wrong test-slot copy (main=$([ -f "${TMP}/s12.MAIN_USED" ] && echo y || echo n) wt=$([ -f "${TMP}/s12.WT_USED" ] && echo y || echo n))" "$out"
# ...and a script checkout that is not a git repo cannot name its main
# checkout: exit 2 with Fix:, the gate never runs unslotted.
L="${TMP}/s12-nogit"; layout_copy "$L"; rm -rf "$L/.git"
printf '#!/bin/sh\nexit 0\n' > "$L/ai/bin/test-slot"; chmod +x "$L/ai/bin/test-slot"
R="${TMP}/s12b"; slot_repo "$R" "touch '${R}/GATE_RAN'"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q '^Fix:' <<<"$out" && [ ! -f "${R}/GATE_RAN" ] \
  && ok "s12 an unresolvable script checkout is exit 2 with Fix:, gate not run" || bad "s12 no-git layout expected exit 2, got $rc" "$out"

# ---------------------------------------------------------------- summary
printf '\nintegration-gate self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
