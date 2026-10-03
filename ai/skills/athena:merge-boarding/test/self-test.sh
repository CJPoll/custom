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
# shellcheck source=scripts/test/lib/proc-state.bash
. "${ROOT}/../../../scripts/test/lib/proc-state.bash"

PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# A global core.excludesFile has leaked into mktemp test repos on this machine
# before, silently ignoring fixture files. Neutralise all global git config.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# integration-gate, test-slot and critic-review emit telemetry (DND-1474,
# DND-1475): never into the machine's real store from a fixture.
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry"

# --owner-approval takes a VERIFIABLE record of the owner's decision (owner
# approval policy, 2026-09-28): session:<session-uuid>/<message-uuid>
# quote:<words>, checked against a Claude Code transcript under
# $HOME/.claude/projects, or the owner's click, click:<delivery_id>
# (DND-1784; blast-radius --self-test covers that form). This fixture HOME
# holds one human-typed owner turn.
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
unset ATHENA_TEST_SLOT_HELD ATHENA_TEST_SLOT_HEARTBEAT ATHENA_TEST_SLOT_PARENT_CHECK INTEGRATION_GATE_IN_SLOT INTEGRATION_GATE_PRESTARTED_CRITIC ATHENA_TEST_SLOT_GATE_RUN
export ATHENA_TEST_SLOT_DIR="${TMP}/slots" ATHENA_TEST_SLOTS=1
TEST_SLOT="$(cd "${ROOT}/../../bin" && pwd)/test-slot"
# DND-1814: every receipt is sealed under the machine's receipt-seal key. The
# fixtures use a private key under TMP, never the real one, and seal the
# receipts they forge as a landed judge would (seal_receipt); forge_verdict
# writes one unsealed, as a person or branch code would.
export ATHENA_SECRETS_ROOT="${TMP}/secrets"
SEAL="$(cd "${ROOT}/../../bin" && pwd)/receipt-seal"
seal_receipt() { "$SEAL" seal --kind "$1" "$2"; } # <critic|integration> <file>

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
  forge_verdict "$@" && ( cd "$1" && sha="${3:-$(git rev-parse HEAD)}" \
    && seal_receipt critic "$(git rev-parse --git-path critic-verdicts)/${sha}.json" )
}
# forge_verdict <repo dir> <verdict> [sha] -- the same receipt, UNSEALED: what
# a person or a branch's code writes by hand (DND-1814).
forge_verdict() {
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
# The tool runs only the integrated head, so a RED can be a flake as easily as a
# break. Its Fix must not assert an unmeasured "passed alone", and must route a
# flake to athena:flaky-ticket rather than "fix it on this branch" (2026-09-29:
# two gen_saas integrated-head REDs were known flakes, DND-1255 class).
grep -q 'passed alone' <<<"$out" && bad "c4 Fix: claims the branch passed alone, which the tool never ran" "$out" || ok "c4 Fix: claims nothing it did not measure"
grep -q 'athena:flaky-ticket' <<<"$out" && ok "c4 Fix: routes a flake to athena:flaky-ticket" || bad "c4 Fix: gives a flake no route" "$out"
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
# DND-1895: ai/bin/harness-gate is held, so this edit is HOT and needs the owner's record (a synthetic one here).
out="$( cd "$R" && HOME="$FIXTURE_HOME" "$GATE" --target main --no-fetch --owner-approval "$APPROVAL" 2>&1 )"; rc=$?
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

# ---------------------------------------------------------------- case 26b
# DND-1656: a USAGE ERROR in the argument parse (exit 2) also removes a stale
# pass for the head; --help (and a clean run's parse) writes nothing.
R="${TMP}/c26b"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
plant_c26b() { mkdir -p "$(dirname "$rf")"; printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s"}\n' "$head_sha" > "$rf"; }
for ue in "--target" "--bogus-flag" "--gate" "--slot-wait-timeout abc"; do
  plant_c26b
  # shellcheck disable=SC2086
  out="$( cd "$R" && "$GATE" $ue 2>&1 )"; rc=$?
  [ "$rc" -eq 2 ] && ok "c26b '${ue}' exits 2" || bad "c26b '${ue}' expected exit 2, got $rc" "$out"
  grep -q 'Fix:' <<<"$out" && ok "c26b '${ue}' carries Fix:" || bad "c26b '${ue}' lacks Fix:" "$out"
  if [ -e "$rf" ]; then bad "c26b a passing receipt survived usage error '${ue}'" "$out"; else ok "c26b usage error '${ue}' removed the stale receipt"; fi
done
# A valid flag before the bad one, and another head's receipt is left alone.
plant_c26b; other_rf="$(dirname "$rf")/0000000000000000000000000000000000000000.json"; printf '{}\n' > "$other_rf"
out="$( cd "$R" && "$GATE" --no-fetch --bogus-flag 2>&1 )"; rc=$?
{ [ "$rc" -eq 2 ] && [ ! -e "$rf" ] && [ -e "$other_rf" ]; } && ok "c26b valid-then-bad flag clears only this head's receipt" || bad "c26b valid-then-bad rc=$rc" "$out"
# An unwritable store: still exit 2 (never 5), with a Fix: naming the store.
plant_c26b; chmod 555 "$(dirname "$rf")"
out="$( cd "$R" && "$GATE" --target 2>&1 )"; rc=$?
chmod 755 "$(dirname "$rf")"
{ [ "$rc" -eq 2 ] && grep -q 'could not remove the earlier receipt' <<<"$out"; } && ok "c26b unremovable receipt: exit stays 2, says so" || bad "c26b unremovable rc=$rc" "$out"
plant_c26b
out="$( cd "$R" && "$GATE" --help 2>&1 )"; rc=$?
{ [ "$rc" -eq 0 ] && [ -e "$rf" ]; } && ok "c26b --help exits 0 and writes nothing" || bad "c26b --help rc=$rc or touched the receipt" "$out"
# A usage error with no resolvable head (outside a repo) still exits 2, no crash.
NOREPO="${TMP}/c26b-norepo"; mkdir -p "$NOREPO"
out="$( cd "$NOREPO" && GIT_CEILING_DIRECTORIES="$TMP" "$GATE" --target 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "c26b usage error outside a repo still exits 2" || bad "c26b outside repo expected 2, got $rc" "$out"

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
grep -q '5 receipt error, no INTEGRATION OK printed' <<<"$hout" && ok "c29 --help documents exit 5" || bad "c29 --help lacks exit 5" "$hout"
grep -q 'BEFORE the' <<<"$hout" && grep -q 'after a green gate' <<<"$hout" && ok "c29 --help names both exit 5 cases" || bad "c29 --help exit 5 lacks a case" "$hout"

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
# Gone is judged on the kernel state of every group member, never `kill -0
# -pgid` (DND-1550): the gate exits without joining the judge, so its killed
# members are orphans and stay ZOMBIES until PID 1 reaps them, and kill -0
# succeeds on a zombie. The 30 s bound only caps a hang; a judge that was
# never stopped blocks on its FIFO forever and still fails.
gone=0
if [ -n "$pg" ]; then
  proc_group_wait_gone "$pg" 300 && gone=1
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
# be traced to a carry. record_carried forges the on-disk schema-2 shape. Its
# merge_base is the REAL merge base of main and the head unless a fifth argument
# names another commit: the gate checks that the judged diff covers the target
# (case c32g), so a fake SHA there is no longer filler.
record_carried() { # <repo dir> <carried_from sha> [sha] [schema] [merge_base]
  ( cd "$1" && sha="${3:-$(git rev-parse HEAD)}" \
    && mb="${5:-$(git merge-base main "$sha")}" \
    && d="$(git rev-parse --git-path critic-verdicts)" && mkdir -p "$d" \
    && jq -n --arg sha "$sha" --arg src "$2" --argjson schema "${4:-2}" --arg mb "$mb" \
         '{schema:$schema, tool:"critic-review", sha:$sha, base:"main", verdict:"pass", findings:[],
           dirty:false, at:"2026-09-27T00:00:00Z", merge_base:$mb, patch_id:("b"*40),
           diff_digest:("c"*64), msgs_digest:("d"*64), judge_digest:("e"*64),
           carried_from:(if $src == "" then null else $src end),
           carried_receipt:(if $src == "" then null else "/x/\($src).json" end)}' > "${d}/${sha}.json" \
    && seal_receipt critic "${d}/${sha}.json" )
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
  && jq --arg r "${up_from}..${up_to}" '.upstream_range = $r | .interaction = "pass"' "$f" > "$f.t" && mv "$f.t" "$f" \
  && seal_receipt critic "$f" )
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

# F3 a schema-1 PASS body still gates green once the landed judge has sealed
# it (record_pass is schema 1). An UNSEALED one is refused: case c33.
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

# c32g A PASS JUDGED AGAINST A NARROWER BASE does not cover the target. The
# receipt's merge_base is a stacked parent branch that is not on main, so the
# judged diff (parent..head) omits the parent's own commits, which the
# integrated diff (main..head) contains. Measured 2026-09-29 (gen_saas
# DND-1185): a captain's `critic-review --base <parent>` PASS was reused by
# `integration-gate --with-critic` (target origin/main), which printed
# INTEGRATION OK, while a whole-stack run of the same judge had found real gaps
# in the parent commits. The same receipt still gates against the parent it
# was judged on, and a PASS judged against an OLDER main (an ancestor of the
# target) is a superset review, so it covers the newer target.
R="${TMP}/c32g"; new_repo "$R"
( cd "$R" && git checkout -qb parent && echo p > p.txt && git add p.txt && git commit -qm parent \
  && git checkout -qb child && echo c > c.txt && git add c.txt && git commit -qm child )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
parent_sha="$( cd "$R" && git rev-parse parent )"
record_carried "$R" "" "" 2 "$parent_sha"
head_sha="$( cd "$R" && git rev-parse HEAD )"; rf="$(receipt_of "$R" "$head_sha")"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && grep -q 'does not cover' <<<"$out" && grep -q 'Fix:' <<<"$out" \
  && ok "c32g PASS judged against a stacked parent: exit 3, names the coverage gap" \
  || bad "c32g expected exit 3 naming 'does not cover', got $rc" "$out"
[ -e "$rf" ] && bad "c32g an integration receipt was written" "$(cat "$rf")" || ok "c32g no integration receipt written"
out="$( cd "$R" && "$GATE" --target parent --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c32g the same PASS gates green against the parent it was judged on" \
  || bad "c32g expected exit 0 with --target parent, got $rc" "$out"
( cd "$R" && git checkout -q main && echo u > u.txt && git add u.txt && git commit -qm upstream \
  && git checkout -q child && git merge -q --no-edit main )
old_main="$( cd "$R" && git rev-parse main~1 )"
record_carried "$R" "" "" 2 "$old_main"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "c32g a PASS judged against an OLDER main covers the newer target" \
  || bad "c32g expected exit 0 for an ancestor merge_base, got $rc" "$out"
# c32h the DND-1185 path itself: --with-critic must RE-RUN the judge against
# the target rather than reuse the narrow PASS, and its verdict decides.
R="${TMP}/c32h"; new_repo "$R"
( cd "$R" && git checkout -qb parent && echo p > p.txt && git add p.txt && git commit -qm parent \
  && git checkout -qb child && echo c > c.txt && git add c.txt && git commit -qm child )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_carried "$R" "" "" 2 "$( cd "$R" && git rev-parse parent )"
out="$(wc_gate "$R" "${TMP}/critic-block" "${R}/g.sh")"; rc=$?
[ "$rc" -eq 3 ] && ! grep -q 'a PASS is already recorded' <<<"$out" && grep -q 'critic-review: BLOCKED' <<<"$out" \
  && ok "c32h --with-critic re-judges against the target instead of reusing a narrow PASS" \
  || bad "c32h expected a fresh judge run and exit 3, got $rc" "$out"

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
# and blast-radius linked to the real ones, and the shared receipt library
# (ai/lib/integration-receipt.sh, DND-969) linked beside them. It is a git
# repo, so its own main checkout (where test-slot is resolved) is the layout
# itself.
layout_copy() {
  mkdir -p "$1/ai/skills/athena:merge-boarding/scripts" "$1/ai/bin" "$1/ai/lib"
  ln -s "$(cd "${ROOT}/../../lib" && pwd)/integration-receipt.sh" "$1/ai/lib/integration-receipt.sh"
  ln -s "$(cd "${ROOT}/../../lib" && pwd)/proc-stat.sh" "$1/ai/lib/proc-stat.sh"
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
# interface: every caller agrees on the budget). Each copy marks which one ran, then
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
[ "$rc" -eq 2 ] && grep -q '^Fix:' <<<"$out" && grep -q 'cannot locate the main checkout' <<<"$out" && [ ! -f "${R}/GATE_RAN" ] \
  && ok "s12 an unresolvable script checkout is exit 2 with Fix:, gate not run" || bad "s12 no-git layout expected exit 2 naming the main checkout, got $rc" "$out"
# ...and a layout without the shared receipt library (DND-969) is exit 2 with a
# Fix: naming it, before any gate runs. Its exit 2 must not be mistaken for the
# unresolvable-checkout refusal above, so each case greps its own cause.
L="${TMP}/s12-nolib"; layout_copy "$L"; rm -f "$L/ai/lib/integration-receipt.sh"
R="${TMP}/s12c"; slot_repo "$R" "touch '${R}/GATE_RAN'"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'cannot load .*integration-receipt.sh' <<<"$out" && grep -q '^Fix:' <<<"$out" && [ ! -f "${R}/GATE_RAN" ] \
  && ok "s12 a missing receipt library is exit 2 with Fix:, gate not run" || bad "s12 missing library expected exit 2 naming it, got $rc" "$out"

# s14..s16 (DND-1504): exit 6 from a test-slot that reports TIMEOUT, at both
# places integration-gate calls it, and the outer-only refusal of a missing
# test-slot. s2 and s11 reach exit 6 only through the real test-slot and a
# 1 s wait; these use a fake that reports TIMEOUT at once, so no case depends
# on a clock or on load (DND-1222). The fake lives in the layout's main
# checkout, the one test-slot integration-gate resolves, and logs each call,
# so every case asserts the fake was the one called: a fake that went missing
# would be exit 2 here, never a silent fall-through to the real test-slot.
# Each case first plants a passing receipt for its head: a run that does not
# end in INTEGRATION OK must leave none, planted or written.
#
# fake_slot <path> <mode> <call log> <pool dir> -- a test-slot that answers
# --weight-of with 1 and, per mode:
#   outer-timeout  every run call: outcome "timeout", exit 75, CMD not run.
#   inner-timeout  the first run call holds slot <pool dir>:1 (a real flock,
#                  so integration-gate's slot_really_held accepts it) and
#                  runs CMD; a run call made while that slot is held (the
#                  gate's own call, from inside the slot) times out.
# Log lines: "weigh", "run" (CMD ran), "timeout-0" (a timeout outside a held
# slot), "timeout-1" (a timeout inside one).
fake_slot() {
  { printf '#!/usr/bin/env bash\nmode=%q log=%q pool=%q\n' "$2" "$3" "$4"
    cat <<'FAKE'
out=""; weigh=0
while [ $# -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in
    --weight-of) weigh=1; shift ;;
    --outcome-file) out="$2"; shift 2 ;;
    --label|--pool|--wait-timeout|--weight) shift 2 ;;
    *) shift ;;
  esac
done
[ "${1-}" = -- ] && shift
if [ "$weigh" -eq 1 ]; then echo weigh >>"$log"; echo 1; exit 0; fi
held=0; [ -n "${ATHENA_TEST_SLOT_HELD:-}" ] && held=1
if [ "$mode" = outer-timeout ] || { [ "$mode" = inner-timeout ] && [ "$held" -eq 1 ]; }; then
  echo "timeout-${held}" >>"$log"
  [ -n "$out" ] && echo timeout >"$out"
  echo "test-slot: TIMEOUT (fake): no slot within the wait" >&2
  exit 75
fi
echo run >>"$log"
mkdir -p "$pool"; exec 9>"$pool/slot-1.lock"; flock -x 9
ATHENA_TEST_SLOT_HELD="$pool:1" "$@"; rc=$?
[ -n "$out" ] && echo "ran exit=$rc" >"$out"
exit "$rc"
FAKE
  } >"$1"; chmod +x "$1"
}
# plant_receipt <repo> -- a passing receipt for HEAD, as an earlier OK left
# it; sets rf to its path. Not a $(...) helper, so a failed plant is counted:
# a plant that did not land would make every "no receipt" check below pass
# without testing anything.
plant_receipt() {
  rf="$(receipt_of "$1" "$(git -C "$1" rev-parse HEAD)")"
  mkdir -p "$(dirname "$rf")"
  printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s"}\n' "$(git -C "$1" rev-parse HEAD)" >"$rf"
  [ -s "$rf" ] || bad "fixture: receipt not planted at ${rf}"
}
SLOT_FIX_FULL="Fix: the machine's heavy-test slot pool stayed full"

# s14: the OUTER call (the slot integration-gate takes first) reports TIMEOUT.
L="${TMP}/s14-layout"; layout_copy "$L"
fake_slot "$L/ai/bin/test-slot" outer-timeout "${TMP}/s14.calls" "${TMP}/s14-pool"
R="${TMP}/s14"; slot_repo "$R" "touch '${R}/GATE_RAN'"
plant_receipt "$R"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 6 ] && ok "s14 a TIMEOUT on the outer slot is exit 6" || bad "s14 expected exit 6, got $rc" "$out"
grep -q "GATE NOT RUN on $(git -C "$R" rev-parse --short=12 HEAD): no machine test slot within the wait window" <<<"$out" \
  && ok "s14 says GATE NOT RUN on the head, no slot within the wait" || bad "s14 missing the GATE NOT RUN line" "$out"
grep -qF "$SLOT_FIX_FULL" <<<"$out" && ok "s14 Fix: says the slot pool stayed full" || bad "s14 Fix: does not name the full pool" "$out"
grep -qE 'INTEGRATION OK|gate RED' <<<"$out" && bad "s14 read a TIMEOUT as OK or RED" "$out" || ok "s14 neither OK nor RED"
grep -q 'running gate on the integrated head' <<<"$out" && bad "s14 the run inside the slot started" "$out" || ok "s14 nothing ran inside the slot"
[ ! -f "${R}/GATE_RAN" ] && ok "s14 the gate did not run" || bad "s14 the gate ran despite the TIMEOUT"
[ ! -e "$rf" ] && ok "s14 no receipt for the head (the planted pass is gone)" || bad "s14 a receipt survived exit 6" "$(cat "$rf")"
[ "$(grep -cx 'timeout-0' "${TMP}/s14.calls" 2>/dev/null)" = 1 ] && ! grep -qx run "${TMP}/s14.calls" \
  && ok "s14 the fake test-slot was called, once, and timed out" || bad "s14 the fake test-slot was not the one called (calls: $(tr '\n' ' ' <"${TMP}/s14.calls" 2>/dev/null))" "$out"

# s15: the outer slot is taken; the gate's own call, from inside the slot,
# reports TIMEOUT. The same exit 6, from the second place it is raised. The
# real test-slot re-enters a held cpu slot at once and never times out there,
# so this branch is defensive: it covers a test-slot that drifts from that
# contract. s15 does not claim the real test-slot behaves this way.
L="${TMP}/s15-layout"; layout_copy "$L"
fake_slot "$L/ai/bin/test-slot" inner-timeout "${TMP}/s15.calls" "${TMP}/s15-pool"
R="${TMP}/s15"; slot_repo "$R" "touch '${R}/GATE_RAN'"
plant_receipt "$R"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 6 ] && ok "s15 a TIMEOUT on the gate's own slot call is exit 6" || bad "s15 expected exit 6, got $rc" "$out"
grep -q 'running gate on the integrated head' <<<"$out" && ok "s15 the run inside the slot reached the gate step" || bad "s15 the inner run never reached the gate step" "$out"
grep -q "GATE NOT RUN on $(git -C "$R" rev-parse --short HEAD): no machine test slot within the wait window" <<<"$out" \
  && ok "s15 says GATE NOT RUN on the head, no slot within the wait" || bad "s15 missing the GATE NOT RUN line" "$out"
grep -qF "$SLOT_FIX_FULL" <<<"$out" && ok "s15 Fix: says the slot pool stayed full" || bad "s15 Fix: does not name the full pool" "$out"
grep -qE 'INTEGRATION OK|gate RED' <<<"$out" && bad "s15 read a TIMEOUT as OK or RED" "$out" || ok "s15 neither OK nor RED"
[ ! -f "${R}/GATE_RAN" ] && ok "s15 the gate did not run" || bad "s15 the gate ran despite the TIMEOUT"
[ ! -e "$rf" ] && ok "s15 no receipt for the head (the planted pass is gone)" || bad "s15 a receipt survived exit 6" "$(cat "$rf")"
[ "$(grep -x -e run -e 'timeout-[01]' "${TMP}/s15.calls" 2>/dev/null | tr '\n' ' ')" = 'run timeout-1 ' ] \
  && ok "s15 the fake test-slot ran the outer slot, then timed out the gate's call" || bad "s15 unexpected test-slot calls: $(tr '\n' ' ' <"${TMP}/s15.calls" 2>/dev/null)" "$out"

# s16: test-slot absent from the main checkout. The refusal comes before the
# slot wait and its cleanup trap, so it must still leave no pass for the head.
L="${TMP}/s16-layout"; layout_copy "$L"
R="${TMP}/s16"; slot_repo "$R" "touch '${R}/GATE_RAN'"
plant_receipt "$R"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "s16 exit 2 when test-slot is absent" || bad "s16 expected exit 2, got $rc" "$out"
grep -qF "Fix: the main checkout's ai/bin/test-slot is missing (${L}/ai/bin/test-slot)" <<<"$out" \
  && ok "s16 Fix: names the missing test-slot path" || bad "s16 Fix: does not name ${L}/ai/bin/test-slot" "$out"
grep -q 'taking a machine test slot' <<<"$out" && bad "s16 went on to take a slot" "$out" || ok "s16 refused before any slot"
grep -qE 'INTEGRATION OK|gate RED|GATE NOT RUN' <<<"$out" && bad "s16 reported a gate result" "$out" || ok "s16 reports no gate result"
[ ! -f "${R}/GATE_RAN" ] && ok "s16 the gate never ran unslotted" || bad "s16 the gate ran without a slot"
[ ! -e "$rf" ] && ok "s16 no receipt for the head (the planted pass is gone)" || bad "s16 a planted pass survived the exit-2 refusal" "$(cat "$rf")"
# ...and the same for a script checkout whose main checkout cannot be named.
L="${TMP}/s16-nogit"; layout_copy "$L"; rm -rf "$L/.git"
R="${TMP}/s16b"; slot_repo "$R" "touch '${R}/GATE_RAN'"
plant_receipt "$R"
out="$( cd "$R" && "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'cannot locate the main checkout' <<<"$out" && ok "s16 an unresolvable script checkout is exit 2" || bad "s16 no-git layout expected exit 2, got $rc" "$out"
[ ! -e "$rf" ] && ok "s16 no receipt after the unresolvable-checkout refusal" || bad "s16 a planted pass survived the unresolvable-checkout refusal" "$(cat "$rf")"

# s13: integration-gate holds its gate as `bash -c`, so it names a declared
# gate to test-slot in ATHENA_TEST_SLOT_GATE_RUN, and test-slot writes that
# run's gate.run (DND-1530): lead time's implement/verify anchor on the first
# gate run, and a captain whose only gate is integration-gate had none. The
# layout's test-slot records each claim, then execs this checkout's real one.
L="${TMP}/s13-layout"; layout_copy "$L"
REAL_SLOT="$(cd "${ROOT}/../../bin" && pwd)/test-slot"
printf '#!/bin/sh\nprintf "%%s\\n" "${ATHENA_TEST_SLOT_GATE_RUN-unset}" >> "%s"\nexec "%s" "$@"\n' "${TMP}/s13.claims" "$REAL_SLOT" > "$L/ai/bin/test-slot"
chmod +x "$L/ai/bin/test-slot"
( cd "$L" && git add -A && git commit -qm layout )
R="${TMP}/s13"; new_repo "$R"; mkdir -p "$R/bin"
printf '#!/bin/sh\nprintf "%%s" "${ATHENA_TEST_SLOT_GATE_RUN-unset}" > "%s"\nexit 0\n' "${TMP}/s13.gate-env" > "$R/bin/prep-commit.sh"
chmod +x "$R/bin/prep-commit.sh"
( cd "$R" && git add -A && git commit -qm gate && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
record_pass "$R"
out="$( cd "$R" && ATHENA_TELEMETRY_DIR="${TMP}/s13-tel" "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "s13 exit 0 for a green declared bin/prep-commit.sh" || bad "s13 expected exit 0, got $rc" "$out"
grep -qxF "$(realpath "$R")/bin/prep-commit.sh" "${TMP}/s13.claims" 2>/dev/null \
  && ok "s13 the gate's test-slot run names the declared gate" || bad "s13 no claim naming the declared gate (claims: $(tr '\n' ' ' < "${TMP}/s13.claims" 2>/dev/null))" "$out"
[ "$(cat "${TMP}/s13.gate-env" 2>/dev/null)" = unset ] \
  && ok "s13 the claim never reaches the gate's own environment" || bad "s13 the gate saw the claim ('$(cat "${TMP}/s13.gate-env" 2>/dev/null)')" "$out"
s13_ev="$(cat "${TMP}/s13-tel"/*.jsonl 2>/dev/null | jq -c 'select(.event == "gate.run") | [.attrs.gate, .attrs.ok, .attrs.exit]')"
[ "$s13_ev" = '["bin/prep-commit.sh",true,0]' ] \
  && ok "s13 one gate.run for the declared gate" || bad "s13 expected one gate.run for bin/prep-commit.sh, got '${s13_ev}'" "$out"
# A harness-gate repo: harness-gate writes harness_gate.run itself, so it is
# never claimed (an older test-slot would pass the claim on to the gate's
# environment, and a test-slot self-test inside harness-gate would read it),
# and test-slot writes no gate.run for it.
R="${TMP}/s13b"; slot_repo "$R" "exit 0"
: > "${TMP}/s13.claims"
out="$( cd "$R" && ATHENA_TELEMETRY_DIR="${TMP}/s13b-tel" "$L/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
s13b_ev="$(cat "${TMP}/s13b-tel"/*.jsonl 2>/dev/null | jq -c 'select(.event == "gate.run")' | wc -l)"
[ "$rc" -eq 0 ] && [ "$s13b_ev" -eq 0 ] \
  && ok "s13 a declared harness-gate writes no gate.run" || bad "s13 harness-gate expected exit 0 and no gate.run, got rc $rc, $s13b_ev event(s)" "$out"
grep -q / "${TMP}/s13.claims" \
  && bad "s13 harness-gate was claimed (claims: $(tr '\n' ' ' < "${TMP}/s13.claims"))" "$out" || ok "s13 a declared harness-gate is never claimed"

# ---------------------------------------------------------------- case 33
# DND-1814: THE CRITIC BAR TRUSTS ONLY A SEALED VERDICT. A critic receipt was a
# plain JSON file: one hand-written for a head no judge ever ran on read
# VERDICT PASS, and integration-gate runs the branch's gate unsandboxed, so a
# gate step could write one mid-gate and the gate then read it as the judge's.
# Each refusal below printed INTEGRATION OK on the unfixed gate.
#
# R1 a forged (unsealed) PASS for a head no judge ever ran on.
R="${TMP}/c33a"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
forge_verdict "$R" pass
head_sha="$( cd "$R" && git rev-parse HEAD )"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && grep -q 'UNVERIFIED PASS' <<<"$out" && grep -q 'UNSEALED' <<<"$out" \
  && ok "c33 R1 a forged PASS for a never-judged head does not meet the critic bar (exit 3)" \
  || bad "c33 R1 expected exit 3 UNVERIFIED PASS, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c33 R1 printed INTEGRATION OK on a forged PASS" "$out" || ok "c33 R1 no INTEGRATION OK"
[ ! -e "$(receipt_of "$R" "$head_sha")" ] && ok "c33 R1 no integration receipt" || bad "c33 R1 an integration receipt was written"

# R2 the gate step itself writes a PASS receipt for HEAD while the gate runs.
# It WRITES one. A step that deliberately runs the sealer
# (ai/bin/receipt-seal seal) is not refused: that residual is stated in
# ai/lib/receipt_seal.rb and needs a privilege boundary, not a file format.
R="${TMP}/c33b"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
cat > "${R}/g.sh" <<'GATE'
#!/bin/sh
sha="$(git rev-parse HEAD)"; d="$(git rev-parse --path-format=absolute --git-path critic-verdicts)"
mkdir -p "$d"
printf '{"schema":2,"tool":"critic-review","sha":"%s","base":"main","verdict":"pass","findings":[],"dirty":false,"at":"2026-10-02T00:00:00Z","merge_base":"%s"}\n' \
  "$sha" "$(git merge-base main HEAD)" > "${d}/${sha}.json"
exit 0
GATE
chmod +x "${R}/g.sh"
head_sha="$( cd "$R" && git rev-parse HEAD )"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && grep -q 'UNVERIFIED PASS' <<<"$out" \
  && ok "c33 R2 a PASS a gate step writes mid-gate does not meet the critic bar (exit 3)" \
  || bad "c33 R2 expected exit 3 UNVERIFIED PASS, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "c33 R2 printed INTEGRATION OK on a mid-gate PASS" "$out" || ok "c33 R2 no INTEGRATION OK"

# R3 a sealed PASS of ANOTHER head copied onto this head's name: the seal
# covers the sha inside it, so it never counts for a head it does not name.
R="${TMP}/c33c"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
old_sha="$( cd "$R" && git rev-parse HEAD )"; record_pass "$R"
( cd "$R" && echo g > g.txt && git add g.txt && git commit -qm g )
head_sha="$( cd "$R" && git rev-parse HEAD )"
( cd "$R" && d="$(git rev-parse --git-path critic-verdicts)" && cp "${d}/${old_sha}.json" "${d}/${head_sha}.json" )
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && grep -q 'does not record the commit it is filed under' <<<"$out" \
  && ok "c33 R3 a sealed PASS copied onto another head's name does not count (exit 3)" \
  || bad "c33 R3 expected exit 3 naming the copied receipt, got $rc" "$out"

# R4 a sealed PASS edited after sealing (a BLOCK turned into a PASS).
R="${TMP}/c33d"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_verdict "$R" block
( cd "$R" && f="$(git rev-parse --git-path critic-verdicts)/$(git rev-parse HEAD).json" \
  && jq -c '.verdict = "pass"' "$f" > "$f.t" && mv "$f.t" "$f" )
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && grep -q 'FORGED OR EDITED' <<<"$out" \
  && ok "c33 R4 a BLOCK edited into a PASS does not meet the critic bar (exit 3)" \
  || bad "c33 R4 expected exit 3 FORGED OR EDITED, got $rc" "$out"

# R5 the legitimate path still passes: a sealed PASS (c1 and c3 above) and a
# PASS the gate's own --with-critic judge records (c31) both reach
# INTEGRATION OK, and the integration receipt the gate writes is sealed.
R="${TMP}/c33e"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
record_pass "$R"
head_sha="$( cd "$R" && git rev-parse HEAD )"
out="$( cd "$R" && "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q "^INTEGRATION OK ${head_sha}" <<<"$out" \
  && ok "c33 R5 a legitimately judged (sealed) head still passes" || bad "c33 R5 expected INTEGRATION OK, got $rc" "$out"
"$SEAL" verify --kind integration "$(receipt_of "$R" "$head_sha")" \
  && ok "c33 R5 the integration receipt the gate wrote is sealed and verifies" || bad "c33 R5 the gate's receipt does not verify"

# ---------------------------------------------------------------- DND-1064
# The containment bar ("HEAD contains the target when the gate starts") was
# evaluated BEFORE the test-slot wait, so a queue wait longer than the gap
# between landings either refused a wrapped caller twice (the captain form,
# `test-slot -- integration-gate`) or, unwrapped, let the gate start on a head
# that no longer contained main. Now the slot is taken FIRST and the fetch,
# the containment check, and an opt-in --rebase all happen inside it.
#
# remote_repo <dir> <gate body> -- a bare origin whose main declares
# ai/bin/harness-gate with <gate body>, a clone at <dir>/clone with a LINKED
# WORKTREE at <dir>/wt on branch feature with one commit (--rebase refuses a
# main checkout), and a pusher clone at <dir>/up for moving origin/main.
remote_repo() {
  local d="$1"
  new_repo "$d/seed"; mkdir -p "$d/seed/ai/bin"
  printf '#!/bin/sh\n%s\n' "$2" > "$d/seed/ai/bin/harness-gate"; chmod +x "$d/seed/ai/bin/harness-gate"
  ( cd "$d/seed" && git add -A && git commit -qm gate && echo shared-v1 > shared.txt && git add shared.txt && git commit -qm shared )
  git clone -q --bare "$d/seed" "$d/origin.git"
  git clone -q "$d/origin.git" "$d/clone"
  git -C "$d/clone" worktree add -q -b feature "$d/wt" origin/main
  git clone -q "$d/origin.git" "$d/up"
  printf '/g.sh\n/gp.sh\n/GATE_RAN\n/log\n' >> "$d/clone/.git/info/exclude"
  ( cd "$d/wt" && echo f > f.txt && git add f.txt && git commit -qm f )
}
# move_main <dir> <file> <content> -- land one commit on origin/main.
move_main() { ( cd "$1/up" && git pull -q --ff-only origin main && echo "$3" > "$2" && git add "$2" && git commit -qm "move $2" && git push -q origin HEAD:main ); }
# await_grep <file> <pattern> -- bounded poll (<= 20 s) for a line in a file.
await_grep() { local i; for ((i = 0; i < 100; i++)); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
# hold_slot <name> -- a foreign run holds the one test slot until release_slot.
hold_slot() {
  mkfifo "${TMP}/$1.fifo"
  "$TEST_SLOT" --label "$1 foreign holder" -- bash -c ': > "$1"; exec 3<>"$2"; read -t 60 -u 3 _x' _ "${TMP}/$1.started" "${TMP}/$1.fifo" 2>/dev/null &
  HOLDER=$!
  await_file "${TMP}/$1.started" || bad "$1 fixture: the foreign holder never started"
}
release_slot() { timeout 5 bash -c 'printf "go\n" > "$1"' _ "${TMP}/$1.fifo"; wait "$HOLDER" 2>/dev/null; }
# gate_behind_moving_main <name> <dir> <cmd...> -- start <cmd> in <dir>/wt
# while the slot is held, land a commit on origin/main once the run is queued,
# then free the slot and wait for the run. Sets OUT (its output) and RC.
gate_behind_moving_main() {
  local name="$1" d="$2"; shift 2
  hold_slot "$name"
  ( cd "$d/wt" && TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/critic-pass" "$@" ) > "${TMP}/${name}.out" 2>&1 &
  local gpid=$!
  await_grep "${TMP}/${name}.out" 'WAITING' || bad "${name} fixture: the run never queued for the slot" "$(cat "${TMP}/${name}.out")"
  move_main "$d" moved.txt "landed during the wait"
  release_slot "$name"
  wait "$gpid"; RC=$?
  OUT="$(cat "${TMP}/${name}.out")"
}

# r1: unwrapped, no --rebase. main moves while the run waits for its slot.
# Before DND-1064 the containment check had already passed before the wait, so
# the gate started (and printed INTEGRATION OK) on a head that did not contain
# the main of gate start. The bar is now evaluated inside the slot: refused.
D="${TMP}/r1"; remote_repo "$D" "touch '${D}.GATE_RAN'"
gate_behind_moving_main r1 "$D" "$GATE" --with-critic
[ "$RC" -eq 2 ] && grep -q 'does not contain origin/main' <<<"$OUT" \
  && ok "r1 main moved during the slot wait: containment is judged at gate start and refuses" \
  || bad "r1 expected exit 2 'does not contain origin/main', got $RC" "$OUT"
grep -q '^INTEGRATION OK' <<<"$OUT" && bad "r1 printed INTEGRATION OK on a head that did not contain main at gate start" "$OUT" || ok "r1 no INTEGRATION OK"
[ ! -f "${D}.GATE_RAN" ] && ok "r1 the gate never started on the stale head" || bad "r1 the gate ran on a head that did not contain main at gate start"
grep -q 'Fix:.*--rebase' <<<"$OUT" && ok "r1 Fix: names --rebase" || bad "r1 Fix: does not offer --rebase" "$OUT"

# r2: unwrapped, --rebase. The same move is absorbed: the head is rebased
# inside the slot, the judge and the gate run on the rebased head, and the
# receipt records the NEW main as the base it contained.
D="${TMP}/r2"; remote_repo "$D" "touch '${D}.GATE_RAN'"
gate_behind_moving_main r2 "$D" "$GATE" --with-critic --rebase
new_main="$(git -C "$D/up" rev-parse HEAD)"; head_sha="$(git -C "$D/wt" rev-parse HEAD)"
[ "$RC" -eq 0 ] && grep -q "^INTEGRATION OK ${head_sha} " <<<"$OUT" \
  && ok "r2 --rebase: main moved during the wait, one run ends INTEGRATION OK" \
  || bad "r2 expected INTEGRATION OK on the rebased head, got $RC" "$OUT"
git -C "$D/wt" merge-base --is-ancestor "$new_main" HEAD && ok "r2 the gated head contains the main that landed during the wait" || bad "r2 the head does not contain the new main"
[ "$(git -C "$D/wt" symbolic-ref -q --short HEAD)" = feature ] && ok "r2 the branch itself was rebased (still on feature)" || bad "r2 HEAD left detached or on another branch"
rcpt="$(git -C "$D/wt" rev-parse --path-format=absolute --git-common-dir)/integration-receipts/${head_sha}.json"
[ "$(jq -r .base "$rcpt" 2>/dev/null)" = "$new_main" ] && ok "r2 the receipt's base is the main contained at gate start" || bad "r2 receipt base is not the new main ($(jq -r .base "$rcpt" 2>/dev/null))"
grep -q 'rebased .* onto origin/main' <<<"$OUT" && ok "r2 the rebase is reported" || bad "r2 the rebase was not reported" "$OUT"
sect="$( sed -n '/^--- intersection/,$p' <<<"$OUT" )"
grep -q 'UNAVAILABLE' <<<"$sect" && bad "r2 intersection UNAVAILABLE although the pre-rebase branch point was known" "$sect" || ok "r2 intersection measured from the pre-rebase branch point"
( cd "$D/wt" && "${ROOT}/../../bin/critic-review" --verdict-for "$head_sha" >/dev/null 2>&1 ) \
  && ok "r2 the judge's PASS is recorded for the rebased head" || bad "r2 no PASS recorded for the rebased head" "$OUT"

# r3: the captain form, `test-slot -- integration-gate --rebase`. The move
# lands during the OUTER wait; the gate re-enters the held slot and rebases.
D="${TMP}/r3"; remote_repo "$D" "touch '${D}.GATE_RAN'"
gate_behind_moving_main r3 "$D" "$TEST_SLOT" -- "$GATE" --with-critic --rebase
new_main="$(git -C "$D/up" rev-parse HEAD)"
[ "$RC" -eq 0 ] && grep -q '^INTEGRATION OK' <<<"$OUT" && git -C "$D/wt" merge-base --is-ancestor "$new_main" HEAD \
  && ok "r3 wrapped in test-slot: a move during the outer wait still ends in one INTEGRATION OK" \
  || bad "r3 expected INTEGRATION OK on a head containing the new main, got $RC" "$OUT"
# ...and without --rebase the wrapped form still refuses: the bar did not move.
D="${TMP}/r3b"; remote_repo "$D" "touch '${D}.GATE_RAN'"
gate_behind_moving_main r3b "$D" "$TEST_SLOT" -- "$GATE" --with-critic
[ "$RC" -eq 2 ] && grep -q 'does not contain origin/main' <<<"$OUT" && [ ! -f "${D}.GATE_RAN" ] \
  && ok "r3 wrapped, no --rebase: still refused, gate not run" || bad "r3b expected exit 2 refusal, got $RC" "$OUT"

# r4: --rebase onto a CONFLICTING move refuses, names the conflict, never
# auto-resolves, and leaves the branch exactly where it was.
D="${TMP}/r4"; remote_repo "$D" "touch '${D}.GATE_RAN'"
( cd "$D/wt" && echo mine > shared.txt && git commit -qam "edit shared" )
before="$(git -C "$D/wt" rev-parse HEAD)"
move_main "$D" shared.txt "theirs"
out="$( cd "$D/wt" && CRITIC_REVIEW_STUB="${TMP}/critic-pass" "$GATE" --rebase 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'REBASE CONFLICT' <<<"$out" && grep -q 'shared.txt' <<<"$out" \
  && ok "r4 a conflicting move is exit 2 REBASE CONFLICT naming the path" || bad "r4 expected exit 2 REBASE CONFLICT naming shared.txt, got $rc" "$out"
grep -q '^Fix:' <<<"$out" && ok "r4 carries Fix:" || bad "r4 missing Fix:" "$out"
[ "$(git -C "$D/wt" rev-parse HEAD)" = "$before" ] && [ "$(git -C "$D/wt" symbolic-ref -q --short HEAD)" = feature ] \
  && ok "r4 the branch is back at its original head" || bad "r4 the branch moved or was left detached"
[ ! -d "$(git -C "$D/wt" rev-parse --git-path rebase-merge)" ] && [ ! -d "$(git -C "$D/wt" rev-parse --git-path rebase-apply)" ] \
  && [ -z "$(git -C "$D/wt" status --porcelain)" ] \
  && ok "r4 no rebase left in progress, tree clean" || bad "r4 rebase left in progress or tree dirty" "$(git -C "$D/wt" status)"
[ ! -f "${D}.GATE_RAN" ] && ok "r4 the gate did not run" || bad "r4 the gate ran after a conflict"

# r5: --rebase refuses a dirty tree before touching anything.
D="${TMP}/r5"; remote_repo "$D" "touch '${D}.GATE_RAN'"
move_main "$D" moved.txt "landed"
echo wip > "$D/wt/wip.txt"
before="$(git -C "$D/wt" rev-parse HEAD)"
out="$( cd "$D/wt" && "$GATE" --rebase 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'wip.txt' <<<"$out" && grep -q '^Fix:' <<<"$out" && [ "$(git -C "$D/wt" rev-parse HEAD)" = "$before" ] \
  && ok "r5 --rebase refuses a dirty tree with Fix:, branch untouched" || bad "r5 expected exit 2 naming wip.txt, got $rc" "$out"
[ -f "$D/wt/wip.txt" ] && ok "r5 the uncommitted file is left in place" || bad "r5 the uncommitted file was removed"

# r6: --rebase on a head that already contains main rebases nothing.
D="${TMP}/r6"; remote_repo "$D" "exit 0"
before="$(git -C "$D/wt" rev-parse HEAD)"; record_pass "$D/wt"
out="$( cd "$D/wt" && "$GATE" --rebase 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$D/wt" rev-parse HEAD)" = "$before" ] && ! grep -q 'rebased ' <<<"$out" \
  && ok "r6 --rebase on a head that already contains main is a no-op rebase" || bad "r6 expected OK on the unchanged head, got $rc" "$out"

# r8: the judge started before the slot wait is still RUNNING when the run
# inside the slot reaches it: it is adopted (not re-run) and joined, though it
# is not that process's child. Its stub is a FIFO answered only after the
# adoption line appears, so the join must really block on it.
D="${TMP}/r8"; remote_repo "$D" "exit 0"
mkfifo "${TMP}/r8-critic.fifo"
( cd "$D/wt" && TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/r8-critic.fifo" "$GATE" --with-critic ) > "${TMP}/r8.out" 2>&1 &
r8pid=$!
await_grep "${TMP}/r8.out" 'still running beside the gate' || bad "r8 the running judge was not adopted" "$(cat "${TMP}/r8.out")"
timeout 10 bash -c 'cat "$1" > "$2"' _ "${TMP}/critic-pass" "${TMP}/r8-critic.fifo"
wait "$r8pid"; rc=$?; out="$(cat "${TMP}/r8.out")"
[ "$rc" -eq 0 ] && grep -q '^critic-review: PASS' <<<"$out" && grep -q '^INTEGRATION OK' <<<"$out" \
  && ok "r8 a judge still running at slot entry is adopted, joined, and its PASS gates the run" || bad "r8 adopted judge (rc=$rc)" "$out"
[ "$(grep -c 'running the standing judge on' <<<"$out")" -eq 1 ] && ok "r8 the judge ran once, not twice" || bad "r8 the judge was started more than once" "$out"
rm -f "${TMP}/r8-critic.fifo"

# r9: --rebase while the judge started before the wait is still running. That
# judge runs git in the same tree, and a rebase beside it collided on
# index.lock (seen in this suite's own r3). It is stopped and drained BEFORE
# the rebase, and the rebased head gets a judge of its own.
D="${TMP}/r9"; remote_repo "$D" "exit 0"
mkfifo "${TMP}/r9-critic.fifo"
hold_slot r9
( cd "$D/wt" && TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/r9-critic.fifo" "$GATE" --with-critic --rebase ) > "${TMP}/r9.out" 2>&1 &
r9pid=$!
await_grep "${TMP}/r9.out" 'WAITING' || bad "r9 fixture: the run never queued for the slot" "$(cat "${TMP}/r9.out")"
move_main "$D" moved.txt "landed during the wait"
release_slot r9
await_grep "${TMP}/r9.out" 'inside the slot ->' || bad "r9 the rebase did not run beside a still-running judge" "$(cat "${TMP}/r9.out")"
timeout 10 bash -c 'cat "$1" > "$2"' _ "${TMP}/critic-pass" "${TMP}/r9-critic.fifo"
wait "$r9pid"; rc=$?; out="$(cat "${TMP}/r9.out")"
[ "$rc" -eq 0 ] && grep -q '^INTEGRATION OK' <<<"$out" \
  && ok "r9 --rebase beside a still-running judge: one INTEGRATION OK on the rebased head" || bad "r9 expected INTEGRATION OK, got $rc" "$out"
stop_ln="$(grep -n 'stopped the judge started on' <<<"$out" | head -1 | cut -d: -f1)"
reb_ln="$(grep -n 'inside the slot ->' <<<"$out" | head -1 | cut -d: -f1)"
[ -n "$stop_ln" ] && [ -n "$reb_ln" ] && [ "$stop_ln" -lt "$reb_ln" ] \
  && ok "r9 the old head's judge is stopped before the rebase touches the tree" || bad "r9 judge not stopped before the rebase (stop=${stop_ln:-none} rebase=${reb_ln:-none})" "$out"
[ "$(grep -c 'running the standing judge on' <<<"$out")" -eq 2 ] && ok "r9 the rebased head got its own judge" || bad "r9 expected two judge starts (old head, rebased head)" "$out"
rm -f "${TMP}/r9-critic.fifo"

# r10: --rebase refuses a main checkout (a shared surface) before it moves
# anything, even when a rebase is needed.
D="${TMP}/r10"; remote_repo "$D" "touch '${D}.GATE_RAN'"
( cd "$D/clone" && git checkout -q -b topic origin/main && echo t > t.txt && git add t.txt && git commit -qm t )
move_main "$D" moved.txt "landed"
before="$(git -C "$D/clone" rev-parse HEAD)"
out="$( cd "$D/clone" && "$GATE" --rebase 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'main checkout' <<<"$out" && grep -q '^Fix:' <<<"$out" && [ "$(git -C "$D/clone" rev-parse HEAD)" = "$before" ] && [ ! -f "${D}.GATE_RAN" ] \
  && ok "r10 --rebase refuses a main checkout with Fix:, nothing moved" || bad "r10 expected exit 2 'main checkout', got $rc" "$out"

# r11: --rebase refuses a detached HEAD: no branch would move.
D="${TMP}/r11"; remote_repo "$D" "touch '${D}.GATE_RAN'"
( cd "$D/wt" && git checkout -q --detach HEAD )
move_main "$D" moved.txt "landed"
before="$(git -C "$D/wt" rev-parse HEAD)"
out="$( cd "$D/wt" && "$GATE" --rebase 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'detached' <<<"$out" && grep -q '^Fix:' <<<"$out" && [ "$(git -C "$D/wt" rev-parse HEAD)" = "$before" ] \
  && ok "r11 --rebase refuses a detached HEAD with Fix:" || bad "r11 expected exit 2 'detached', got $rc" "$out"

# r12: a rebase git refuses for a reason that is NOT a conflict (a held
# index.lock) is REBASE FAILED, never REBASE CONFLICT, and moves nothing.
D="${TMP}/r12"; remote_repo "$D" "touch '${D}.GATE_RAN'"
move_main "$D" moved.txt "landed"
before="$(git -C "$D/wt" rev-parse HEAD)"
lockf="$(git -C "$D/wt" rev-parse --path-format=absolute --git-path index.lock)"; : > "$lockf"
out="$( cd "$D/wt" && "$GATE" --rebase 2>&1 )"; rc=$?
rm -f "$lockf"
[ "$rc" -eq 2 ] && grep -q 'REBASE FAILED (not a conflict)' <<<"$out" && grep -q '^Fix:' <<<"$out" && ! grep -q 'REBASE CONFLICT' <<<"$out" \
  && ok "r12 a non-conflict rebase failure is REBASE FAILED with Fix:" || bad "r12 expected exit 2 REBASE FAILED, got $rc" "$out"
[ "$(git -C "$D/wt" rev-parse HEAD)" = "$before" ] && [ ! -f "${D}.GATE_RAN" ] && ok "r12 nothing moved and the gate did not run" || bad "r12 the branch moved or the gate ran"

# r13: a refusal BEFORE the slot wait (a dirty tree) still clears an earlier
# pass for its head -- no outcome but INTEGRATION OK leaves a receipt.
D="${TMP}/r13"; remote_repo "$D" "exit 0"
head_sha="$(git -C "$D/wt" rev-parse HEAD)"
rdir="$(git -C "$D/wt" rev-parse --path-format=absolute --git-common-dir)/integration-receipts"
mkdir -p "$rdir"; echo '{"verdict":"pass"}' > "${rdir}/${head_sha}.json"
echo wip > "$D/wt/wip.txt"
out="$( cd "$D/wt" && "$GATE" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && [ ! -e "${rdir}/${head_sha}.json" ] \
  && ok "r13 a dirty-tree refusal before the wait removes the head's earlier receipt" || bad "r13 expected exit 2 and no receipt (rc=$rc, receipt $([ -e "${rdir}/${head_sha}.json" ] && echo present || echo gone))" "$out"

# r14: the in-slot marker with a STALE slot variable (that slot is not held)
# is not honoured: the run still takes its slot first.
D="${TMP}/r14"; remote_repo "$D" "exit 0"; record_pass "$D/wt"
out="$( cd "$D/wt" && INTEGRATION_GATE_IN_SLOT=1 ATHENA_TEST_SLOT_HELD="$(realpath -m "${TMP}/slots"):1" "$GATE" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'taking a machine test slot first' <<<"$out" \
  && ok "r14 a forged marker with a stale slot variable still takes the slot first" || bad "r14 the stale marker skipped the slot-first step (rc=$rc)" "$out"

# r7: --help documents --rebase and takes no slot.
out="$( cd "$TMP" && "${TMP}/s5-layout/ai/skills/athena:merge-boarding/scripts/integration-gate" --help 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q -- '--rebase' <<<"$out" && ok "r7 --help documents --rebase" || bad "r7 --help missing --rebase (rc=$rc)" "$out"

# ---------------------------------------------------------------- DND-1326
# The outer slot is weighed as test-slot weighs the declared gate itself
# (test-slot --weight-of), and the --with-critic judge queues in test-slot's
# model pool. The layout carries THIS checkout's test-slot, which has
# --weight-of; each case reads the weight from the pool's own events.
L="${TMP}/w-layout"; layout_copy "$L"
cp "$(cd "${ROOT}/../../bin" && pwd)/test-slot" "$L/ai/bin/test-slot"
( cd "$L" && git add -A && git commit -qm layout )
WGATE="$L/ai/skills/athena:merge-boarding/scripts/integration-gate"
# w_weight <pool dir> <label prefix> [model] -- the weight of the first run
# acquired in that pool whose label starts with the prefix.
w_weight() {
  jq -s --arg p "$2" '[.[] | select(.event == "acquired" and (.label | startswith($p))) | .weight] | first' \
    "$1/${3:+model/}events.jsonl" 2>/dev/null
}
# w1: a harness-gate run at HARNESS_GATE_JOBS=16 holds 16 units, not the default.
WS="${TMP}/w1-slots"; R="${TMP}/w1"; slot_repo "$R" "exit 0"
out="$( cd "$R" && ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 HARNESS_GATE_JOBS=16 "$WGATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^INTEGRATION OK' <<<"$out" && ok "w1 exit 0 with a weighed outer slot" || bad "w1 expected exit 0, got $rc" "$out"
[ "$(w_weight "$WS" "integration-gate ")" = 16 ] \
  && ok "w1 a HARNESS_GATE_JOBS=16 gate's outer slot holds 16 units" || bad "w1 outer slot weight $(w_weight "$WS" "integration-gate ") (want 16)" "$out"
grep -q 'weight 16' <<<"$out" && ok "w1 the run names the weight it takes" || bad "w1 weight not named" "$out"
# w2: a gate test-slot cannot weigh by its workers (prep-commit.sh) keeps
# test-slot's default (budget/3), as before DND-1326.
WS="${TMP}/w2-slots"; R="${TMP}/w2"; new_repo "$R"; mkdir -p "$R/bin"
printf '#!/bin/sh\nexit 0\n' > "$R/bin/prep-commit.sh"; chmod +x "$R/bin/prep-commit.sh"
( cd "$R" && git add -A && git commit -qm gate && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
record_pass "$R"
out="$( cd "$R" && ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 HARNESS_GATE_JOBS=16 "$WGATE" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && [ "$(w_weight "$WS" "integration-gate ")" = 8 ] \
  && ok "w2 a prep-commit.sh gate keeps test-slot's default weight" || bad "w2 expected exit 0 at weight 8 (rc=$rc, weight $(w_weight "$WS" "integration-gate "))" "$out"
# w3: --with-critic's judge queues in the MODEL pool (one unit), beside the gate.
WS="${TMP}/w3-slots"; R="${TMP}/w3"; slot_repo "$R" "exit 0"
rm -rf "${R}/$(cd "$R" && git rev-parse --git-path critic-verdicts)"   # no verdict yet
out="$( cd "$R" && ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/critic-pass" "$WGATE" --target main --no-fetch --with-critic 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^critic-review: PASS' <<<"$out" && grep -q '^INTEGRATION OK' <<<"$out" \
  && ok "w3 --with-critic in the model pool: judged PASS, INTEGRATION OK" || bad "w3 expected exit 0 with a PASS (rc=$rc)" "$out"
[ "$(w_weight "$WS" "critic-review " model)" = 1 ] \
  && ok "w3 the judge held one model-pool unit" || bad "w3 the judge was not in the model pool (weight '$(w_weight "$WS" "critic-review " model)')" "$out"
[ -s "$WS/events.jsonl" ] && [ "$(w_weight "$WS" "critic-review ")" = null ] \
  && ok "w3 the judge held no cpu unit (the cpu pool's events exist)" || bad "w3 the judge took cpu units, or the cpu events are missing" "$out"
# w4: a main-checkout test-slot that predates --weight-of (it refuses the
# flag) is not a failure: the slot takes test-slot's default, and says so.
L4="${TMP}/w4-layout"; layout_copy "$L4"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = --weight-of ] && { echo "test-slot: unknown argument --weight-of" >&2; exit 2; }; done\nexec "%s" "$@"\n' \
  "$L/ai/bin/test-slot" > "$L4/ai/bin/test-slot"; chmod +x "$L4/ai/bin/test-slot"
( cd "$L4" && git add -A && git commit -qm layout )
WS="${TMP}/w4-slots"; R="${TMP}/w4"; slot_repo "$R" "exit 0"
out="$( cd "$R" && ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 HARNESS_GATE_JOBS=16 "$L4/ai/skills/athena:merge-boarding/scripts/integration-gate" --target main --no-fetch 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && [ "$(w_weight "$WS" "integration-gate ")" = 8 ] \
  && ok "w4 an older test-slot: exit 0 at its default weight" || bad "w4 expected exit 0 at weight 8 (rc=$rc, weight $(w_weight "$WS" "integration-gate "))" "$out"
grep -q "default weight" <<<"$out" && ok "w4 the fallback to the default weight is named" || bad "w4 fallback not named" "$out"
# w5: a target that cannot be read and a target that declares no gate take
# the default weight with DIFFERENT notes: "could not look" never reads as
# "none". (Each run is then refused inside the slot, as before.)
WS="${TMP}/w5-slots"; R="${TMP}/w5"; slot_repo "$R" "exit 0"
out="$( cd "$R" && ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 "$WGATE" --target nosuch/main --no-fetch 2>&1 )"
grep -q "nosuch/main is not fetched yet, so its declared gate could not be read" <<<"$out" \
  && ok "w5 an unreadable target is named as could-not-read" || bad "w5 unreadable target note" "$out"
R="${TMP}/w5b"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
out="$( cd "$R" && ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 "$WGATE" --target main --no-fetch 2>&1 )"
grep -q "main declares no gate and no --gate was passed" <<<"$out" \
  && ok "w5 a target with no declared gate is named as none" || bad "w5 no-gate note" "$out"
# w6: the outer slot is a cpu slot, so a caller --gate naming a model-pool
# command is still weighed in cpu units (the cpu default), never as model calls.
WS="${TMP}/w6-slots"; R="${TMP}/w6"; new_repo "$R"; mkdir -p "$R/ai/bin"
printf '#!/bin/sh\nexit 0\n' > "$R/ai/bin/critic-eval"; chmod +x "$R/ai/bin/critic-eval"
( cd "$R" && git add -A && git commit -qm tool && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
record_pass "$R"
out="$( cd "$R" && ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 "$WGATE" --target main --no-fetch --gate 'ai/bin/critic-eval --run --concurrency 2' 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && [ "$(w_weight "$WS" "integration-gate ")" = 8 ] \
  && ok "w6 a model-pool --gate command is weighed in cpu units" || bad "w6 expected exit 0 at cpu weight 8 (rc=$rc, weight $(w_weight "$WS" "integration-gate "))" "$out"
# w7: a judge the model pool never admits records no verdict. The gate still
# runs; the verdict step reads the absence (exit 3) and the judge's log shows
# test-slot's TIMEOUT, so it never reads as a PASS or a BLOCK.
WS="${TMP}/w7-slots"; R="${TMP}/w7"; slot_repo "$R" "exit 0"
rm -rf "${R}/$(cd "$R" && git rev-parse --git-path critic-verdicts)"
mkfifo "${TMP}/w7.fifo"
ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 ATHENA_TEST_MODEL_SLOTS=1 "$L/ai/bin/test-slot" --pool model --label 'w7 foreign holder' -- \
  bash -c ': > "$1"; exec 3<>"$2"; read -t 60 -u 3 _x' _ "${TMP}/w7.started" "${TMP}/w7.fifo" 2>/dev/null &
holder=$!
await_file "${TMP}/w7.started" || bad "w7 fixture: the model-pool holder never started"
out="$( cd "$R" && ATHENA_TEST_SLOT_DIR="$WS" ATHENA_TEST_SLOTS=24 ATHENA_TEST_MODEL_SLOTS=1 TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/critic-pass" "$WGATE" --target main --no-fetch --with-critic --slot-wait-timeout 1 2>&1 )"; rc=$?
timeout 5 bash -c 'printf "go\n" > "$1"' _ "${TMP}/w7.fifo"; wait "$holder" 2>/dev/null
[ "$rc" -eq 3 ] && grep -q 'test-slot: TIMEOUT' <<<"$out" && ! grep -q '^INTEGRATION OK' <<<"$out" \
  && ok "w7 a judge the model pool never admits is an absent verdict (exit 3), with test-slot's TIMEOUT shown" \
  || bad "w7 expected exit 3 with a TIMEOUT line (rc=$rc)" "$out"

# ---------------------------------------------------------------- DND-1475
# Telemetry: exactly one integration_gate.run per invocation, on every exit
# path, emitted by the outer run only (the run re-executes itself inside
# test-slot, so a naive emitter writes two). Each case has its own store.
# ig_events <store> -- the integration_gate.run lines in a store.
ig_events() { cat "$1"/*.jsonl 2>/dev/null | jq -c 'select(.event == "integration_gate.run")'; }
ig_count() { local n; n="$(ig_events "$1" | grep -c .)"; printf '%s' "${n:-0}"; }
# ig_one <case> <store> <expected exit> <expected outcome> -- exactly one
# event, carrying that exit code and outcome; sets EV to the line.
ig_one() {
  EV="$(ig_events "$2")"
  [ "$(ig_count "$2")" = 1 ] && ok "$1 exactly one integration_gate.run" || bad "$1 expected one integration_gate.run, got $(ig_count "$2")" "$(cat "$2"/*.jsonl 2>/dev/null)"
  [ "$(jq -r '.attrs.exit_code' <<<"$EV")" = "$3" ] && [ "$(jq -r '.attrs.outcome' <<<"$EV")" = "$4" ] \
    && ok "$1 exit_code=$3 outcome=$4" || bad "$1 expected exit_code=$3 outcome=$4" "$EV"
  jq -e '.duration_s | type == "number" and . >= 0' <<<"$EV" >/dev/null && ok "$1 duration_s is the wall, a number" || bad "$1 duration_s" "$EV"
  [ -e "$2/write-failures" ] && bad "$1 the writer counted a drop" "$(cat "$2/write-failures")" || ok "$1 no write-failures"
}

# t1 OK, no --with-critic: exit_code 0, with_critic false, head = the judged head.
R="${TMP}/t1"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"; record_pass "$R"
T="${TMP}/t1-store"
out="$( cd "$R" && ATHENA_TELEMETRY_DIR="$T" "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "t1 the run is OK" || bad "t1 expected exit 0, got $rc" "$out"
ig_one t1 "$T" 0 ok
[ "$(jq -r '.head' <<<"$EV")" = "$(git -C "$R" rev-parse HEAD)" ] && ok "t1 head is the judged head" || bad "t1 head" "$EV"
[ "$(jq -r '.attrs.with_critic' <<<"$EV")" = false ] && [ "$(jq -r '.attrs.rebased' <<<"$EV")" = false ] \
  && ok "t1 with_critic=false rebased=false" || bad "t1 with_critic/rebased" "$EV"
[ "$(jq -r '.attrs.base' <<<"$EV")" = "$(git -C "$R" rev-parse main)" ] && ok "t1 base is the target it contained" || bad "t1 base" "$EV"

# t2 --with-critic --rebase onto a main that moved: one event, head = the
# REBASED head, rebased=true, with_critic=true, base = the new main.
D="${TMP}/t2"; remote_repo "$D" "exit 0"; move_main "$D" moved.txt "landed"
T="${TMP}/t2-store"
out="$( cd "$D/wt" && ATHENA_TELEMETRY_DIR="$T" TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/critic-pass" "$GATE" --with-critic --rebase 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "t2 the rebased run is OK" || bad "t2 expected exit 0, got $rc" "$out"
ig_one t2 "$T" 0 ok
[ "$(jq -r '.head' <<<"$EV")" = "$(git -C "$D/wt" rev-parse HEAD)" ] && ok "t2 head is the rebased head" || bad "t2 head" "$EV"
[ "$(jq -r '.attrs.rebased' <<<"$EV")" = true ] && [ "$(jq -r '.attrs.with_critic' <<<"$EV")" = true ] \
  && ok "t2 rebased=true with_critic=true" || bad "t2 rebased/with_critic" "$EV"
[ "$(jq -r '.attrs.base' <<<"$EV")" = "$(git -C "$D/up" rev-parse HEAD)" ] && ok "t2 base is the main that moved" || bad "t2 base" "$EV"

# t3 a refusal: no critic verdict on the head -> exit 3, one event, not two.
R="${TMP}/t3"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"
T="${TMP}/t3-store"
out="$( cd "$R" && ATHENA_TELEMETRY_DIR="$T" "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] && ok "t3 no verdict is exit 3" || bad "t3 expected exit 3, got $rc" "$out"
ig_one t3 "$T" 3 no_critic_pass

# t4 a refusal inside the slot after the parse (an unresolvable target): one event.
T="${TMP}/t4-store"
out="$( cd "$R" && ATHENA_TELEMETRY_DIR="$T" "$GATE" --target origin/nope --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && ok "t4 an unresolvable target is exit 2" || bad "t4 expected exit 2, got $rc" "$out"
ig_one t4 "$T" 2 refused
[ "$(jq -r '.attrs | has("base")' <<<"$EV")" = false ] && ok "t4 no base when the target never resolved (null, not a guess)" || bad "t4 base" "$EV"
# ...a refusal in the OUTER run before the slot (a dirty tree): one event.
T="${TMP}/t4b-store"; echo wip > "${R}/wip.txt"
out="$( cd "$R" && ATHENA_TELEMETRY_DIR="$T" "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
rm -f "${R}/wip.txt"
[ "$rc" -eq 2 ] && ok "t4b a dirty tree is exit 2" || bad "t4b expected exit 2, got $rc" "$out"
ig_one t4b "$T" 2 refused
# ...a usage error INSIDE the parse (an unknown flag) emits nothing: the run
# has not started, and --help / an unknown flag must write nothing.
T="${TMP}/t4c-store"
( cd "$R" && ATHENA_TELEMETRY_DIR="$T" "$GATE" --bogus >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T" ] && ok "t4c an unknown flag (inside the parse) is exit 2 and emits nothing" || bad "t4c expected exit 2 and no store, got $rc" "$(ls -la "$T" 2>&1)"
( cd "$R" && ATHENA_TELEMETRY_DIR="$T" "$GATE" --help >/dev/null 2>&1 )
[ ! -e "$T" ] && ok "t4c --help emits nothing" || bad "t4c --help wrote telemetry"

# t5 the captain form, `test-slot -- integration-gate`: still exactly one.
R="${TMP}/t5"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
stub_gate_green "${R}/GATE_RAN" "${R}/g.sh"; record_pass "$R"
T="${TMP}/t5-store"
out="$( cd "$R" && ATHENA_TELEMETRY_DIR="$T" "$TEST_SLOT" -- "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "t5 wrapped run is OK" || bad "t5 expected exit 0, got $rc" "$out"
ig_one t5 "$T" 0 ok

# t6 RED gate: exit 1, outcome red.
R="${TMP}/t6"; new_repo "$R"
( cd "$R" && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f )
printf '#!/bin/sh\nexit 1\n' > "${R}/g.sh"; chmod +x "${R}/g.sh"; record_pass "$R"
T="${TMP}/t6-store"
out="$( cd "$R" && ATHENA_TELEMETRY_DIR="$T" "$GATE" --target main --no-fetch --gate "${R}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 1 ] && ok "t6 a red gate is exit 1" || bad "t6 expected exit 1, got $rc" "$out"
ig_one t6 "$T" 1 red

# t7 FAIL-OPEN: an unwritable store changes neither the exit code nor stdout,
# for the OK run and for the refusal. Each pair runs the same repo twice.
fail_open_pair() { # <case> <repo> <args...>
  local name="$1" r="$2" ro="${TMP}/$1-ro" o1 o2 c1 c2; shift 2
  mkdir -p "$ro"; chmod 500 "$ro"
  o1="$( cd "$r" && ATHENA_TELEMETRY_DIR="${TMP}/$name-rw" "$GATE" "$@" 2>/dev/null )"; c1=$?
  o2="$( cd "$r" && ATHENA_TELEMETRY_DIR="$ro/telemetry" "$GATE" "$@" 2>/dev/null )"; c2=$?
  chmod 700 "$ro"
  [ "$c1" = "$c2" ] && [ "$o1" = "$o2" ] && ok "$name unwritable store: exit $c2 and stdout unchanged" \
    || bad "$name unwritable store changed the run (exit $c1 vs $c2)" "$(diff <(printf '%s\n' "$o1") <(printf '%s\n' "$o2"))"
  [ "$(ig_count "${TMP}/$name-rw")" = 1 ] && ok "$name the writable twin wrote its one event" || bad "$name writable twin" "$(ig_count "${TMP}/$name-rw")"
  [ ! -e "$ro/telemetry" ] && ok "$name nothing was written to the unwritable store" || bad "$name unwritable store"
}
R="${TMP}/t1"
fail_open_pair t7ok "$R" --target main --no-fetch --gate "${R}/g.sh"
R="${TMP}/t3"
fail_open_pair t7refused "$R" --target main --no-fetch --gate "${R}/g.sh"

# ---------------------------------------------------------------- DND-1576
# sm1: after the gate runs in a linked worktree whose compose stack is up, the
# worktree's stack marker is recorded (teardown-stack --record), so a later
# `compose down` that keeps volumes still leaves them attributable at merge.
# sm2: docker unreadable: the marker is not recorded, said so, and the gate
# verdict and exit are unchanged. A stub docker on ATHENA_DOCKER_BIN; no daemon.
sm_docker() { # <file> <worktree> <fail?>
  cat > "$1" <<EOF
#!/usr/bin/env bash
[ "$3" = fail ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "\$1 \$2" in
  "info "*) echo 29.0.0 ;;
  "ps "*) echo c1 ;;
  "inspect "*) echo '[{"Config":{"Labels":{"com.docker.compose.project":"sm1-wt","com.docker.compose.project.working_dir":"$2"}}}]' ;;
  "volume ls") echo sm1-wt_pg ;;
  "volume inspect") echo '[{"Name":"sm1-wt_pg","CreatedAt":"2026-10-01T00:00:00Z","Labels":{"com.docker.compose.volume":"pg"}}]' ;;
  "compose -p") case "\$*" in *--volumes*) echo pg ;; *) : ;; esac ;;
  "network ls") : ;;
  *) echo "sm docker stub: unexpected \$*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$1"
}
for sm in sm1 sm2; do
  R="${TMP}/${sm}"; new_repo "$R"
  W="${TMP}/${sm}-x/sm1-wt"
  ( cd "$R" && : > docker-compose.yml && git add docker-compose.yml && git commit -qm compose \
    && git worktree add -q -b feature "$W" && cd "$W" && echo f > f.txt && git add f.txt && git commit -qm f )
  W="$(cd "$W" && pwd -P)"
  stub_gate_green "${W}/GATE_RAN" "${W}/g.sh"; record_pass "$W"
  mode=ok; [ "$sm" = sm2 ] && mode=fail
  sm_docker "${TMP}/${sm}-docker" "$W" "$mode"
  out="$( cd "$W" && ATHENA_DOCKER_BIN="${TMP}/${sm}-docker" "$GATE" --target main --no-fetch --gate "${W}/g.sh" 2>&1 )"; rc=$?
  marker="$(git -C "$W" rev-parse --path-format=absolute --git-dir)/athena-stack-marker.json"
  [ "$rc" -eq 0 ] && grep -q 'INTEGRATION OK' <<<"$out" && ok "${sm} gate OK" || bad "${sm} expected INTEGRATION OK, got $rc" "$out"
  if [ "$sm" = sm1 ]; then
    grep -qF "integration-gate: teardown-stack: RECORDED stack marker ${marker}" <<<"$out" && ok "sm1 says it recorded the marker" || bad "sm1 no RECORDED line" "$out"
    grep -qF '"name":"sm1-wt_pg"' "$marker" 2>/dev/null && ok "sm1 marker records the volume" || bad "sm1 marker missing or wrong" "$(cat "$marker" 2>&1)"
  else
    grep -q 'stack marker not recorded (teardown-stack --record exit 3)' <<<"$out" && ok "sm2 says the marker was not recorded" || bad "sm2 no not-recorded line" "$out"
    grep -q '^Fix: fix the unreachable' <<<"$out" && bad "sm2 printed teardown-stack's Fix: bare on an OK run" "$out" || ok "sm2 teardown-stack's Fix: is prefixed"
    [ -f "$marker" ] && bad "sm2 wrote a marker" || ok "sm2 no marker"
  fi
done

# ---------------------------------------------------------------- DND-1796
# THE JUDGES COME FROM THE LANDED TARGET. When the gated branch is in the repo
# that holds the gate (custom gating custom), the classifier, its manifest, the
# owner verifiers and the gate script itself are what the TARGET holds, read
# out of git. Before DND-1796 they were the copies beside the running script,
# i.e. the branch's own when run from its worktree: one commit that dropped a
# held surface from the manifest read COLD and landed its own exit 4.
# landed_layout <dir> -- a custom-like repo whose main commit holds REAL
# copies of the gate, its shim, its libs, blast-radius, its manifest and the
# owner verifiers (a symlink would resolve to this checkout's files, which a
# fixture branch cannot edit). No declared gate is copied (harness-gate would
# run for real), so each case passes a stub --gate.
DND1796_REPO="$(cd "${ROOT}/../../.." && pwd)"
landed_layout() {
  mkdir -p "$1/ai/skills/athena:merge-boarding/scripts" "$1/ai/bin" "$1/ai/blast-radius"
  cp "$GATE" "$1/ai/skills/athena:merge-boarding/scripts/integration-gate"
  cp -R "${DND1796_REPO}/ai/lib" "$1/ai/lib"
  # The mechanics cases below edit the gate and its libs and expect a LANDING, so
  # their manifest leaves the receipt chain unheld (DND-1807 holds it for real;
  # lb10 runs the real manifest). The owner verifiers and the rest stay held.
  jq -f "${TMP}/lb-unhold-chain.jq" "${DND1796_REPO}/ai/blast-radius/surfaces.json" > "$1/ai/blast-radius/surfaces.json"
  for b in integration-gate blast-radius test-slot critic-review receipt-seal; do cp "${DND1796_REPO}/ai/bin/${b}" "$1/ai/bin/${b}"; done
  ( cd "$1" && git init -q -b main . && git add -A && git commit -qm layout \
    && printf '/g.sh\n/GATE_RAN\n' >> .git/info/exclude )
}
# landed_branch <layout> <worktree> -- a feature worktree of the layout.
landed_branch() { ( cd "$1" && git worktree add -q -b "$(basename "$2")" "$2" ); stub_gate_green "$2/GATE_RAN" "$2/g.sh"; }
LBG=ai/skills/athena:merge-boarding/scripts/integration-gate
printf '.surfaces |= map(select(.class != "owner-approval-policy"))\n' > "${TMP}/lb-narrow.jq"
printf '.surfaces |= map(.patterns |= (if . == null then . else map(select((test("integration-gate|integration-receipt|receipt_seal|receipt-seal|merge-guard|forge-git-passthrough|gh-athena|glab-athena|locked-merge|main-health|forge-api-scan|forge-cli-isolation|critic-review|critic_carry|critic_verdict_stores")) | not)) end))\n' > "${TMP}/lb-unhold-chain.jq"

# lb1: a branch that narrows the manifest (drops the held owner-approval-policy
# surface) and so touches a file that surface holds. The landed manifest holds
# it: HOT, exit 4, no OK line, no receipt -- by every path the gate is invoked.
L="${TMP}/lb1-layout"; landed_layout "$L"; W="${TMP}/lb1-wt"; landed_branch "$L" "$W"
( cd "$W" && jq -f "${TMP}/lb-narrow.jq" ai/blast-radius/surfaces.json > m.json && mv m.json ai/blast-radius/surfaces.json \
  && git commit -qam 'narrow the manifest' )
record_pass "$W"
for via in "${W}/${LBG}" "${W}/ai/bin/integration-gate" "${L}/ai/bin/integration-gate"; do
  out="$( cd "$W" && "$via" --target main --no-fetch --gate "${W}/g.sh" 2>&1 )"; rc=$?
  label="lb1 (${via#"${TMP}"/})"
  [ "$rc" -eq 4 ] && grep -q 'BLAST-RADIUS HOT' <<<"$out" && ok "${label} a narrowed manifest is still HOT, exit 4" \
    || bad "${label} expected exit 4 BLAST-RADIUS HOT, got $rc" "$out"
  grep -q 'INTEGRATION OK' <<<"$out" && bad "${label} printed INTEGRATION OK" "$out" || ok "${label} no INTEGRATION OK"
  grep -q "landed on main" <<<"$out" && ok "${label} says the judges are the landed ones" || bad "${label} does not name the landed judges" "$out"
done
[ ! -e "$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)/integration-receipts/$(git -C "$W" rev-parse HEAD).json" ] \
  && ok "lb1 no receipt for the HOT head" || bad "lb1 a receipt was written for a HOT head"

# lb2: a branch that rewrites the owner-turn verifier to accept any record.
# The landed verifier refuses the bogus --owner-approval (exit 2), so the
# branch cannot approve its own hold.
L="${TMP}/lb2-layout"; landed_layout "$L"; W="${TMP}/lb2-wt"; landed_branch "$L" "$W"
( cd "$W" && sed -i 's/^  def check(ref, words, dir: default_dir)$/&\n    return [:verified, words]/' ai/lib/owner_turn.rb \
  && grep -q 'return \[:verified, words\]' ai/lib/owner_turn.rb && git commit -qam 'accept any record' ) \
  || bad "lb2 fixture: could not rewrite owner_turn.rb"
record_pass "$W"
BOGUS="session:${FX_SID}/aaaaaaaa-0000-0000-0000-00000000dead quote:I approve this"
out="$( cd "$W" && HOME="$FIXTURE_HOME" "${W}/${LBG}" --target main --no-fetch --gate "${W}/g.sh" --owner-approval "$BOGUS" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q "not the owner's own words" <<<"$out" && ok "lb2 the landed verifier refuses a bogus --owner-approval (exit 2)" \
  || bad "lb2 expected exit 2 from the landed verifier, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "lb2 the branch's verifier approved its own hold" "$out" || ok "lb2 no INTEGRATION OK"

# lb3: a branch that edits the gate script itself. The TARGET's copy,
# materialised from git, is re-executed and writes the receipt; the branch's
# copy never prints the OK line. A legitimate gate change still lands, judged
# by the landed gate.
L="${TMP}/lb3-layout"; landed_layout "$L"; W="${TMP}/lb3-wt"; landed_branch "$L" "$W"
( cd "$W" && sed -i 's/^OK_LINE="INTEGRATION OK /OK_LINE="BRANCH-COPY INTEGRATION OK /' "$LBG" \
  && grep -q 'BRANCH-COPY' "$LBG" && git commit -qam 'edit the gate' ) || bad "lb3 fixture: could not edit the gate"
record_pass "$W"
out="$( cd "$W" && "${W}/${LBG}" --target main --no-fetch --gate "${W}/g.sh" 2>&1 )"; rc=$?
head_sha="$(git -C "$W" rev-parse HEAD)"
[ "$rc" -eq 0 ] && grep -q "^INTEGRATION OK ${head_sha} " <<<"$out" && ok "lb3 a gate-editing branch lands, judged by the landed gate" \
  || bad "lb3 expected exit 0 with the landed OK line, got $rc" "$out"
grep -q 'BRANCH-COPY' <<<"$out" && bad "lb3 the branch's own gate wrote the verdict" "$out" || ok "lb3 the branch's gate copy did not write the verdict"
grep -q 're-executing the landed copy' <<<"$out" && ok "lb3 says it re-executed the landed copy" || bad "lb3 no re-exec line" "$out"
jq -e '.integration_ok_line | startswith("INTEGRATION OK ")' \
  "$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)/integration-receipts/${head_sha}.json" >/dev/null 2>&1 \
  && ok "lb3 the receipt was written by the landed copy" || bad "lb3 receipt missing or written by the branch's copy"
# lb3b: ...and a main checkout whose working tree holds a local edit to the
# gate is not landed code either: run through its shim, the TARGET's copy
# from git still judges, never the edited file.
sed -i 's/^OK_LINE="INTEGRATION OK /OK_LINE="MAIN-DIRTY INTEGRATION OK /' "${L}/${LBG}"
mkdir -p "${TMP}/lb3b-tmp"
out="$( cd "$W" && TMPDIR="${TMP}/lb3b-tmp" "${L}/ai/bin/integration-gate" --target main --no-fetch --gate "${W}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q "^INTEGRATION OK ${head_sha} " <<<"$out" && ok "lb3b a dirty main checkout's gate is not what judges" \
  || bad "lb3b expected exit 0 with the landed OK line, got $rc" "$out"
grep -qE 'MAIN-DIRTY|BRANCH-COPY' <<<"$out" && bad "lb3b a working-tree copy wrote the verdict" "$out" || ok "lb3b neither working-tree copy wrote the verdict"
( cd "$L" && git checkout -q -- "$LBG" )
left="$(find "${TMP}/lb3b-tmp" -maxdepth 1 -name 'integration-gate-landed.*')"
[ -z "$left" ] && ok "lb3b the landed copy removed its materialised tree" || bad "lb3b a materialised landed tree was left behind" "$left"

# lb3d (DND-1814): the receipt lb3's landed copy sealed from its materialised
# temp tree (now removed) still verifies for a reader in the branch, whose own
# gate copy differs from the producer: the landed-history lookup finds it.
git -C "$L" update-ref refs/remotes/origin/main main
out="$( cd "$W" && "${W}/ai/bin/receipt-seal" verify --kind integration \
  "$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)/integration-receipts/${head_sha}.json" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && ok "lb3d a receipt the landed copy sealed verifies for a branch reader after its temp tree is gone" \
  || bad "lb3d expected the landed copy's receipt to verify, got $rc" "$out"

# lb3c: the re-exec marker outside a held slot is refused, never honoured.
out="$( cd "$W" && INTEGRATION_GATE_LANDED_REEXEC=1 INTEGRATION_GATE_SCRIPT_COMMON="${L}/.git" "${W}/${LBG}" --target main --no-fetch --gate "${W}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q '^Fix:' <<<"$out" && ! grep -q 'INTEGRATION OK' <<<"$out" && ok "lb3c a forged re-exec marker is refused (exit 2)" \
  || bad "lb3c expected exit 2 for a forged marker, got $rc" "$out"

# lb9 (DND-1814): a green gate whose receipt cannot be SEALED is exit 5: no
# INTEGRATION OK line, and no receipt left in the store. The layout's landed
# receipt-seal refuses to seal (verify still works, so the critic bar reads).
L="${TMP}/lb9-layout"; landed_layout "$L"
printf '#!/bin/sh\nif [ "$1" = seal ]; then echo "receipt-seal: could not seal: fixture refusal." >&2; echo "Fix: fixture." >&2; exit 1; fi\nexec %s "$@"\n' "$SEAL" \
  > "${L}/ai/bin/receipt-seal"
( cd "$L" && git commit -qam 'a sealer that refuses to seal' ) || bad "lb9 fixture: could not commit the refusing sealer"
W="${TMP}/lb9-wt"; landed_branch "$L" "$W"
( cd "$W" && echo f > f.txt && git add f.txt && git commit -qm f )
record_pass "$W"
head_sha="$(git -C "$W" rev-parse HEAD)"
out="$( cd "$W" && "${W}/${LBG}" --target main --no-fetch --gate "${W}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 5 ] && grep -q 'could not be SEALED' <<<"$out" && grep -q '^Fix:' <<<"$out" \
  && ok "lb9 a receipt that cannot be sealed is exit 5 with Fix:" || bad "lb9 expected exit 5 naming the seal, got $rc" "$out"
grep -q '^INTEGRATION OK' <<<"$out" && bad "lb9 printed INTEGRATION OK with no sealed receipt" "$out" || ok "lb9 no INTEGRATION OK"
store="$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)/integration-receipts"
[ ! -e "${store}/${head_sha}.json" ] && ok "lb9 no receipt for the head" || bad "lb9 an unsealed receipt was left for the head"
left="$(find "$store" -maxdepth 1 -name ".${head_sha}.json.tmp.*" 2>/dev/null)"
[ -z "$left" ] && ok "lb9 no temp receipt left in the store" || bad "lb9 a temp receipt was left in the store" "$left"

# lb5: --rebase on a gate-editing branch behind the target: the rebase runs,
# then the landed copy (of the NEW target) judges the rebased head.
L="${TMP}/lb5-layout"; landed_layout "$L"; W="${TMP}/lb5-wt"; landed_branch "$L" "$W"
( cd "$W" && sed -i 's/^OK_LINE="INTEGRATION OK /OK_LINE="BRANCH-COPY INTEGRATION OK /' "$LBG" && git commit -qam 'edit the gate' )
( cd "$L" && echo m > m.txt && git add m.txt && git commit -qm 'main moves' )
main_sha="$(git -C "$L" rev-parse main)"
out="$( cd "$W" && "${W}/${LBG}" --target main --no-fetch --rebase --gate "${W}/g.sh" --critic-override 'fixture: no judge' 2>&1 )"; rc=$?
head_sha="$(git -C "$W" rev-parse HEAD)"
[ "$rc" -eq 0 ] && grep -q "^INTEGRATION OK ${head_sha} " <<<"$out" && grep -q 'rebased' <<<"$out" \
  && ok "lb5 --rebase then the landed copy judges the rebased head" || bad "lb5 expected exit 0 after a rebase, got $rc" "$out"
grep -q 'BRANCH-COPY' <<<"$out" && bad "lb5 the branch's gate wrote the verdict" "$out" || ok "lb5 the branch's gate did not write the verdict"
[ "$(jq -r .base "$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)/integration-receipts/${head_sha}.json" 2>/dev/null)" = "$main_sha" ] \
  && ok "lb5 the receipt names the moved target as its base" || bad "lb5 receipt base is not the moved target"

# lb6: --with-critic, and the branch edits critic-review. The judge the
# branch's copy started beside the slot wait is stopped; the landed one runs.
L="${TMP}/lb6-layout"; landed_layout "$L"; W="${TMP}/lb6-wt"; landed_branch "$L" "$W"
( cd "$W" && printf '\n# branch edit\n' >> ai/bin/critic-review && git commit -qam 'edit the critic' )
out="$( cd "$W" && TMPDIR="$C31TMP" CRITIC_REVIEW_STUB="${TMP}/critic-pass" "${W}/${LBG}" --target main --no-fetch --with-critic --gate "${W}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^INTEGRATION OK' <<<"$out" && ok "lb6 --with-critic lands with the landed judge" || bad "lb6 expected exit 0, got $rc" "$out"
grep -q 'stopped the judge this copy started' <<<"$out" && ok "lb6 the branch's pre-started judge was stopped" || bad "lb6 the branch's judge was adopted" "$out"

# lb4: the TARGET does not hold blast-radius (the branch adds it). A landed
# classifier that cannot be materialised is an ERROR with Fix:, never a fall
# back to the branch's copy and never a pass.
L="${TMP}/lb4-layout"; landed_layout "$L"
( cd "$L" && git rm -q ai/bin/blast-radius && git commit -qm 'no classifier' )
W="${TMP}/lb4-wt"; landed_branch "$L" "$W"
( cd "$W" && cp "${DND1796_REPO}/ai/bin/blast-radius" ai/bin/blast-radius && git add ai/bin/blast-radius && git commit -qm 'add classifier' )
record_pass "$W"
out="$( cd "$W" && "${W}/${LBG}" --target main --no-fetch --gate "${W}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && grep -q '^Fix:' <<<"$out" && grep -q 'ai/bin/blast-radius' <<<"$out" && ok "lb4 a classifier missing on the TARGET is exit 2 with Fix:" \
  || bad "lb4 expected exit 2 naming the missing classifier, got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "lb4 fell back to the branch's classifier" "$out" || ok "lb4 no INTEGRATION OK"
[ ! -f "${W}/GATE_RAN" ] && ok "lb4 the gate did not run on an unjudgeable head" || bad "lb4 ran the gate before finding no classifier"

# lb10 (DND-1807): with the REAL manifest as the landed one, a branch that edits
# the gate script is HOT: exit 4, no OK line, no receipt. The mechanics cases
# above run with the receipt chain unheld (landed_layout) so they can land.
L="${TMP}/lb10-layout"; landed_layout "$L"
cp "${DND1796_REPO}/ai/blast-radius/surfaces.json" "${L}/ai/blast-radius/surfaces.json"
( cd "$L" && git commit -qam 'land the real manifest' )
W="${TMP}/lb10-wt"; landed_branch "$L" "$W"
( cd "$W" && sed -i 's/^OK_LINE="INTEGRATION OK /OK_LINE="BRANCH-COPY INTEGRATION OK /' "$LBG" && git commit -qam 'edit the gate' ) || bad "lb10 fixture: could not edit the gate"
record_pass "$W"
out="$( cd "$W" && "${W}/${LBG}" --target main --no-fetch --gate "${W}/g.sh" 2>&1 )"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'BLAST-RADIUS HOT' <<<"$out" && grep -q 'owner-approval-policy' <<<"$out" && ok "lb10 a gate-editing branch is HOT under the landed manifest, exit 4" \
  || bad "lb10 expected exit 4 HOT [owner-approval-policy], got $rc" "$out"
grep -q 'INTEGRATION OK' <<<"$out" && bad "lb10 printed INTEGRATION OK" "$out" || ok "lb10 no INTEGRATION OK"
[ ! -e "$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)/integration-receipts/$(git -C "$W" rev-parse HEAD).json" ] \
  && ok "lb10 no receipt for the HOT head" || bad "lb10 a receipt was written for a HOT head"

# ---------------------------------------------------------------- summary
printf '\nintegration-gate self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
