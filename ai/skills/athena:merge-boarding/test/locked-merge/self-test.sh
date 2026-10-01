#!/usr/bin/env bash
# Self-test for athena:merge-boarding's locked-merge.
#
# The defect this tool exists to catch: a GitHub squash-merge onto a base that
# moved after integration-gate ran lands a tree nobody gated, and nothing
# refuses it. The cases that matter are the misses -- a landing on a different
# base or tree (c8/c9/m2: exit 7) and a conflict with a moved base (m3: exit 3,
# NO merge call) -- because each of those reads as a clean merge otherwise.
# DND-1463: a base that moved on past the receipt's base (an ancestor) merges
# now (c2, r3, m1); one that is not an ancestor is still refused (m4).
#
# DND-965: the second defect is a merge of a head integration-gate never
# passed. locked-merge used to take the caller's word that the gate ran (gen_saas
# #468 merged past a RED gate). The r* cases are those misses: no receipt, a RED
# run, a receipt for another base, an unreadable store -- each must refuse with
# exit 9 and NO merge call. r7 is the end-to-end path through the real
# integration-gate.
#
# Hermetic: a local bare "origin" reached through a github.com URL via
# url.insteadOf, and PATH/AI_BIN stubs for gh, gh-athena and confirm-merged.
#
# Run: bash ai/skills/athena:merge-boarding/test/locked-merge/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/scripts/locked-merge"

PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOCKED_MERGE_CONFIRM_SLEEP=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '       %s\n' "$2"; }

# ---- stubs ----
STUBS="${TMP}/stubs"; mkdir -p "${STUBS}"
cat > "${STUBS}/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub (argv logged to $ST/gh.log): `pr view` reads $ST/pr.json;
# `run list --commit` reads $ST/runs_commit.json; `run list --branch` reads
# $ST/runs.json; `run view <id>` reads $ST/run_<id>.json. $ST/gh_fail -> exit 1.
echo "$*" >> "${ST}/gh.log"
q=""; prev=""; commit=""
for a in "$@"; do [ "${prev}" = "-q" ] && q="${a}"; [ "${a}" = "--commit" ] && commit=1; prev="${a}"; done
case "$1 $2" in
  "pr view")  f="${ST}/pr.json" ;;
  "run list") [ -e "${ST}/gh_fail" ] && exit 1
              if [ -n "${commit}" ]; then f="${ST}/runs_commit.json"; else f="${ST}/runs.json"; fi ;;
  "run view") [ -e "${ST}/gh_fail" ] && exit 1; f="${ST}/run_$3.json" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 99 ;;
esac
if [ -n "${q}" ]; then jq -r "${q}" "${f}"; else cat "${f}"; fi
EOF
cat > "${STUBS}/gh-athena" <<'EOF'
#!/usr/bin/env bash
# gh-athena stub: logs argv, then squashes per $ST/merge_mode into the bare origin.
echo "$*" >> "${ST}/merge.log"
mode="$(cat "${ST}/merge_mode")"
[ "${mode}" = refuse ] && { echo "refused: checks not green" >&2; exit 1; }
sha=""; prev=""
for a in "$@"; do [ "${prev}" = "--match-head-commit" ] && sha="${a}"; prev="${a}"; done
G="git --git-dir=${BARE}"
if [ "${mode}" = moved ]; then   # someone else lands first, forge does not refuse
  x="$(${G} commit-tree "$(${G} rev-parse main^{tree})" -p "$(${G} rev-parse main)" -m other)"
  ${G} update-ref refs/heads/main "${x}"
fi
# The squash tree is GitHub's: the head merged into the current main
# (merge-ort). A conflict refuses, as the forge does. DND-1463: main may have
# moved past the receipt's base, so this is not always the head's own tree.
tree="$(${G} merge-tree --write-tree "$(${G} rev-parse main)" "${sha}" 2>/dev/null)" \
  || { echo "refused: merge conflict" >&2; exit 1; }
tree="$(head -1 <<<"${tree}")"
[ "${mode}" = badtree ] && tree="$(${G} rev-parse main^{tree})"
# headtree: the forge lands exactly the gated head's tree, dropping main's move.
[ "${mode}" = headtree ] && tree="$(${G} rev-parse "${sha}^{tree}")"
m="$(${G} commit-tree "${tree}" -p "$(${G} rev-parse main)" -m squash)"
${G} update-ref refs/heads/main "${m}"
jq --arg m "${m}" '.state="MERGED" | .mergeCommit={oid:$m}' "${ST}/pr.json" > "${ST}/pr.tmp" && mv "${ST}/pr.tmp" "${ST}/pr.json"
# DND-1324: the forge lands the squash, then answers 502 to the caller.
[ "${mode}" = err502 ] && { echo "HTTP 502: Bad Gateway (https://api.github.com/graphql)" >&2; exit 1; }
exit 0
EOF
cat > "${STUBS}/confirm-merged" <<'EOF'
#!/usr/bin/env bash
exit "$(cat "${ST}/confirm_rc")"
EOF
cat > "${STUBS}/teardown-stack" <<'EOF'
#!/usr/bin/env bash
# teardown-stack stub (DND-864): logs argv and whether the merge lock is free,
# then exits per $ST/teardown_rc.
echo "$*" >> "${ST}/teardown.log"
if flock -n 7 7>>"${LOCK_PATH}"; then echo "lock free" >> "${ST}/teardown.log"; else echo "lock held" >> "${ST}/teardown.log"; fi
rc="$(cat "${ST}/teardown_rc")"
[ "${rc}" -eq 0 ] || { echo "teardown-stack: stub failure" >&2; echo "Fix: stub" >&2; }
exit "${rc}"
EOF
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}" LOCKED_MERGE_AI_BIN="${STUBS}"

# fixture <name> -- fresh bare origin + clone "wt" on a feature head H.
# Sets: ST, BARE, WT, H.
fixture() {
  local d="${TMP}/$1"; mkdir -p "${d}/st"
  export ST="${d}/st" BARE="${d}/origin.git"
  git init -q --bare -b main "${BARE}"
  WT="${d}/wt"; git init -q -b main "${WT}"
  git -C "${WT}" config remote.origin.url "https://github.com/t/t.git"
  git -C "${WT}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "${WT}" config "url.${BARE}.insteadOf" "https://github.com/t/t.git"
  ( cd "${WT}" && echo seed > seed.txt && git add seed.txt && git commit -qm seed && git push -q origin main \
    && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f && git push -q origin feature )
  H="$(git -C "${WT}" rev-parse HEAD)"
  printf '{"state":"OPEN","headRefOid":"%s","baseRefName":"main"}\n' "${H}" > "${ST}/pr.json"
  echo '[]' > "${ST}/runs.json"; echo good > "${ST}/merge_mode"; echo 0 > "${ST}/confirm_rc"
  echo 0 > "${ST}/teardown_rc"; : > "${ST}/teardown.log"; export LOCK_PATH="${TMP}/$1.lock"
  : > "${ST}/merge.log"
  plant_receipt "${H}" "$(git --git-dir="${BARE}" rev-parse main)"
}

# receipt_path <head> -- where integration-gate records its pass (DND-965):
# the repo's git COMMON dir, shared by every checkout of the repo.
receipt_path() { printf '%s/integration-receipts/%s.json' "$(git -C "${WT}" rev-parse --path-format=absolute --git-common-dir)" "$1"; }

# plant_receipt <head> <base> [verdict] [recorded-head] -- a receipt in the
# on-disk shape integration-gate writes (its self-test asserts that shape).
plant_receipt() {
  local f; f="$(receipt_path "$1")"; mkdir -p "$(dirname "${f}")"
  jq -n --arg h "${4:-$1}" --arg b "$2" --arg v "${3:-pass}" \
    '{schema:"integration-receipt/1", verdict:$v, head:$h, target_ref:"origin/main", base:$b,
      gate:"g.sh", gate_source:"caller-supplied", gate_edited_by_branch:false,
      critic_override:null, critic_override_state:null, owner_approval:null,
      blast_radius:"BLAST-RADIUS COLD", recorded_at:"2026-09-27T00:00:00Z"}' > "${f}"
}
advance_main() { local G="git --git-dir=${BARE}"
  ${G} update-ref refs/heads/main "$(${G} commit-tree "$(${G} rev-parse main^{tree})" -p "$(${G} rev-parse main)" -m ahead)"; }
run() { out="$("${TOOL}" "$@" 2>&1)"; rc=$?; }
expect() { # <label> <rc>
  [ "${rc}" -eq "$2" ] && ok "$1 exit $2" || bad "$1 expected exit $2, got ${rc}" "${out}"
  if [ "$2" -ne 0 ]; then grep -q '^Fix: ' <<<"${out}" && ok "$1 prints Fix:" || bad "$1 missing Fix:" "${out}"; fi
}
no_merge() { [ -s "${ST}/merge.log" ] && bad "$1 merge was CALLED" "$(cat "${ST}/merge.log")" || ok "$1 no merge call"; no_teardown "$1"; }
no_teardown() { [ -s "${ST}/teardown.log" ] && bad "$1 teardown ran without a confirmed landing" "$(cat "${ST}/teardown.log")" || ok "$1 no teardown"; }

# c1 happy path; default lock derives from the repo name under HOME.
fixture c1
out="$(HOME="${TMP}/home" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" 2>&1)"; rc=$?
expect c1 0
grep -q "^LOCK ${TMP}/home/.local/state/athena/wt-merge.lock$" <<<"${out}" && ok "c1 default lock path" || bad "c1 default lock path" "${out}"
grep -q '^MERGED 7 [0-9a-f]\{40\} ON [0-9a-f]\{40\} TREE-MATCH$' <<<"${out}" && ok "c1 MERGED line" || bad "c1 MERGED line" "${out}"
grep -q -- "--squash --match-head-commit ${H}" "${ST}/merge.log" && ok "c1 merge pinned to head" || bad "c1 merge not pinned" "$(cat "${ST}/merge.log")"
grep -q -- '--auto' "${ST}/merge.log" && bad "c1 merge used --auto" || ok "c1 no --auto"
grep -qxF -- "--pr 7 --repo ${WT}" "${ST}/teardown.log" && ok "c1 the merge drove teardown-stack for PR 7" \
  || bad "c1 teardown-stack not run for the landed PR" "$(cat "${ST}/teardown.log")"

# c2 DND-1463: base moved after the gate, and the receipt's base is an
# ancestor of the new tip. Owner decision 2026-10-01: merge it (it used to be
# exit 3, "re-gate"). The move is named, never silent.
fixture c2; advance_main
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c2.lock"; expect c2 0
grep -q 'BASE MOVED' <<<"${out}" && ok "c2 names the moved base" || bad "c2 does not name the moved base" "${out}"

# c3 PR head moved; c4 PR not open.
fixture c3; jq '.headRefOid="'"$(printf 'a%.0s' {1..40})"'"' "${ST}/pr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/pr.json"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c3.lock"; expect c3 3; no_merge c3
fixture c4; jq '.state="CLOSED"' "${ST}/pr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/pr.json"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c4.lock"; expect c4 3; no_merge c4

# c5 forge refuses, and the forge does not show the PR merged either.
fixture c5; echo refuse > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c5.lock"; expect c5 4; no_teardown c5

# c19 DND-1324 THE MISS: the merge call fails (forge 502) but the squash
# landed. Exit 4 said "nothing was merged", so the admiral would re-merge or
# report a landed PR as unmerged. It must confirm, verify the landing and
# report it like any other merge.
fixture c19; echo err502 > "${ST}/merge_mode"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c19.lock"; expect c19 0
grep -q '^MERGED 7 [0-9a-f]\{40\} ON [0-9a-f]\{40\} TREE-MATCH$' <<<"${out}" && ok "c19 reports the landing" || bad "c19 MERGED line" "${out}"
grep -qi 'merge call failed' <<<"${out}" && ok "c19 names the failed merge call" || bad "c19 hides the failed merge call" "${out}"
grep -qxF -- "--pr 7 --repo ${WT}" "${ST}/teardown.log" && ok "c19 tears down the landed PR" || bad "c19 no teardown" "$(cat "${ST}/teardown.log")"
[ "$(grep -c -- '--squash' "${ST}/merge.log")" -eq 1 ] && ok "c19 merge called once, not retried" || bad "c19 merge call count" "$(cat "${ST}/merge.log")"

# ---- DND-1378: the required-idle check is keyed on the base SHA ----
# idle_fixture <name> [status] [conclusion] -- fixture whose main is AGED two
# hours (fixed committer date, no wall-clock race) and merged into the feature
# head, with base run 101 for that SHA in both the --commit list and
# `run view 101`. The branch list is empty.
idle_fixture() {
  fixture "$1"; local G="git --git-dir=${BARE}" old
  old="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
  ${G} update-ref refs/heads/main "$(GIT_COMMITTER_DATE="${old}" ${G} commit-tree "$(${G} rev-parse main^{tree})" -p "$(${G} rev-parse main)" -m "${IDLE_MSG:-base}")"
  follow_main
  set_base_run "${2:-completed}" "${3:-success}"
  : > "${ST}/gh.log"
}
# follow_main -- merge origin/main into the feature head and re-plant its receipt.
follow_main() {
  BASE_SHA="$(git --git-dir="${BARE}" rev-parse main)"
  ( cd "${WT}" && git fetch -q origin && git merge -q --no-edit origin/main && git push -q origin feature )
  H="$(git -C "${WT}" rev-parse HEAD)"
  jq --arg h "${H}" '.headRefOid=$h' "${ST}/pr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/pr.json"
  plant_receipt "${H}" "${BASE_SHA}"
}
set_base_run() { # <status> <conclusion> [view-status]
  jq -n --arg b "${BASE_SHA}" --arg s "$1" --arg c "$2" '[{databaseId:101,status:$s,conclusion:$c,headSha:$b,createdAt:"2026-09-30T00:00:00Z"}]' > "${ST}/runs_commit.json"
  jq -n --arg b "${BASE_SHA}" --arg s "${3:-$1}" --arg c "$2" '{databaseId:101,status:$s,conclusion:$c,headSha:$b}' > "${ST}/run_101.json"
}
idle_run() { run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/$1.lock" --require-idle-workflow post-merge.yml; }
names() { grep -qF -- "$2" <<<"${out}" && ok "$1 names '$2'" || bad "$1 does not name '$2'" "${out}"; }

# i1 THE #562 MISS: the branch list reads idle (empty), but the base commit's
# own run is in progress. The old check merged here.
idle_fixture i1 in_progress ""
idle_run i1; expect i1 5; no_merge i1; names i1 "BASE DEPLOY BUSY"; names i1 "101"
# i2 a stale list status: the list says completed, the by-id read says running.
idle_fixture i2; set_base_run completed "" in_progress
idle_run i2; expect i2 5; no_merge i2; names i2 "BASE DEPLOY BUSY"
# i3 the #595 case, made observable: completed/failure merges with a WARN.
# Flip to a refusal only on an owner-ratified rule (DND-1378 escalation).
idle_fixture i3 completed failure
idle_run i3; expect i3 0; names i3 "concluded failure"; names i3 "no ratified rule"
# i4 no run for a base committed moments ago: NOT SEEN YET, never idle.
idle_fixture i4; advance_main; follow_main; echo '[]' > "${ST}/runs_commit.json"
idle_run i4; expect i4 5; no_merge i4; names i4 "NOT SEEN YET"
# i5 no run for an aged base with no skip marker: NO RUN FOR BASE.
idle_fixture i5; echo '[]' > "${ST}/runs_commit.json"
idle_run i5; expect i5 5; no_merge i5; names i5 "NO RUN FOR BASE"; names i5 "Owner approval policy"
# i6 an aged base carrying [skip ci]: no run expected, the branch list decides.
IDLE_MSG="base [skip ci]" idle_fixture i6; echo '[]' > "${ST}/runs_commit.json"
idle_run i6; expect i6 0; names i6 "BASE-RUN none"
IDLE_MSG="base [skip ci]" idle_fixture i6b; echo '[]' > "${ST}/runs_commit.json"
echo '[{"databaseId":55,"status":"queued","headSha":"x"}]' > "${ST}/runs.json"
idle_run i6b; expect i6b 5; no_merge i6b
# i7 base run done, but the branch list has a live run (a re-run of an older
# run): refuse and name it. (Was c6.)
idle_fixture i7; echo '[{"databaseId":55,"status":"queued","headSha":"x"}]' > "${ST}/runs.json"
idle_run i7; expect i7 5; no_merge i7; names i7 "55"
# i8 a lookup that cannot be trusted is COULD NOT LOOK, never idle.
idle_fixture i8a; jq '.[0].headSha="'"$(printf 'c%.0s' {1..40})"'"' "${ST}/runs_commit.json" > "${ST}/x" && mv "${ST}/x" "${ST}/runs_commit.json"
idle_run i8a; expect i8a 2; no_merge i8a; names i8a "COULD NOT LOOK"
idle_fixture i8b; : > "${ST}/gh_fail"
idle_run i8b; expect i8b 2; no_merge i8b; names i8b "COULD NOT LOOK"
# i9 happy path: IDLE line names the base run; lookups keyed on the full SHA.
idle_fixture i9
idle_run i9; expect i9 0; names i9 "IDLE post-merge.yml base ${BASE_SHA}: BASE-RUN 101 completed/success"
grep -qF -- "--commit ${BASE_SHA}" "${ST}/gh.log" && ok "i9 run list keyed on the full base SHA" || bad "i9 no --commit <base>" "$(cat "${ST}/gh.log")"
grep -qF -- "--limit 100" "${ST}/gh.log" && ok "i9 branch list reads 100 runs" || bad "i9 branch list limit" "$(cat "${ST}/gh.log")"

# c7 lock held elsewhere -> timeout, lock file left intact.
fixture c7; exec 8>>"${TMP}/c7.lock"; flock 8
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c7.lock" --wait 1; expect c7 6; no_merge c7
exec 8>&-
[ -e "${TMP}/c7.lock" ] && ok "c7 lock file not removed" || bad "c7 lock file was removed"

# c8 THE OTHER MISS: forge lands on a base that moved under the merge.
fixture c8; echo moved > "${ST}/merge_mode"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c8.lock"; expect c8 7; no_teardown c8
grep -q 'LANDED UNGATED' <<<"${out}" && ok "c8 says LANDED UNGATED" || bad "c8 message" "${out}"

# c9 landed tree differs from the gated tree.
fixture c9; echo badtree > "${ST}/merge_mode"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c9.lock"; expect c9 7; no_teardown c9

# c10 merge ran, landing unconfirmed.
fixture c10; echo 1 > "${ST}/confirm_rc"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c10.lock"; expect c10 8; no_teardown c10

# c17 (DND-864): landed, teardown failed -> exit 10 (9 is DND-965's NO RECEIPT,
# which lands nothing), the landing still reported.
fixture c17; echo 4 > "${ST}/teardown_rc"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c17.lock"; expect c17 10
grep -q '^MERGED 7 ' <<<"${out}" && ok "c17 still reports the landing" || bad "c17 MERGED line" "${out}"
grep -q 'LANDED, but teardown-stack' <<<"${out}" && ok "c17 says it LANDED" || bad "c17 message" "${out}"
# c18 (DND-864): the merge lock is released before the teardown runs.
fixture c18
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c18.lock"; expect c18 0
grep -qx "lock free" "${ST}/teardown.log" && ok "c18 lock released before teardown" \
  || bad "c18 lock still held during teardown" "$(cat "${ST}/teardown.log")"

# c11 non-GitHub origin; c12 malformed keys; c13 unknown flag.
fixture c11; git -C "${WT}" config remote.origin.url "git@gitlab.com:t/t.git"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c11.lock"; expect c11 2; no_merge c11
fixture c12
run --pr 7 --head "${H:0:12}" --repo "${WT}"; expect c12-short-sha 2
run --pr x7 --head "${H}" --repo "${WT}"; expect c12-bad-pr 2
run --pr 7 --head "${H}" --repo "${WT}" --lock rel.lock; expect c12-relative-lock 2
run --pr 7 --head "${H}" --repo "${WT}" --bogus; expect c13 2
no_merge c12-c13

# ---- DND-965: the gate's receipt is required, under the lock ----
expect_receipt_refusal() { # <label> <text the refusal must name>
  expect "$1" 9; no_merge "$1"
  grep -qF -- "$2" <<<"${out}" && ok "$1 names '$2'" || bad "$1 does not name '$2'" "${out}"
}
set_main() { git --git-dir="${BARE}" update-ref refs/heads/main "$1"; }

# r1 THE MISS: no receipt at all -- the gate never passed on this head.
fixture r1; rm -f "$(receipt_path "${H}")"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r1.lock"; expect_receipt_refusal r1 "NO RECEIPT"
grep -qF "$(receipt_path "${H}")" <<<"${out}" && ok "r1 names the path it searched" || bad "r1 does not name the searched path" "${out}"

# r2 THE REPORTED INSTANCE (gen_saas #468): integration-gate ran RED on this
# head. The real gate, not a planted file -- and a pass left over from an
# earlier run must not survive the RED one.
fixture r2; printf '#!/bin/sh\necho red; exit 1\n' > "${TMP}/r2/red.sh"; chmod +x "${TMP}/r2/red.sh"
igate="$(cd "${HERE}/../.." && pwd)/scripts/integration-gate"
( cd "${WT}" && "${igate}" --gate "${TMP}/r2/red.sh" >"${TMP}/r2/igate.out" 2>&1 ); irc=$?
[ "${irc}" -eq 1 ] && ok "r2 integration-gate is RED (exit 1)" || bad "r2 integration-gate expected exit 1, got ${irc}" "$(cat "${TMP}/r2/igate.out")"
if [ -e "$(receipt_path "${H}")" ]; then bad "r2 a passing receipt survived a RED gate"; else ok "r2 RED gate left no receipt"; fi
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r2.lock"; expect_receipt_refusal r2 "NO RECEIPT"

# r3 DND-1463 THE REGRESSION: a receipt recorded against an OLDER base that is
# an ancestor of the current tip (origin/main moved on after the gate ran).
# Before DND-1463 this was exit 9 RECEIPT FOR ANOTHER BASE; the owner softened
# the bar, so it merges now.
fixture r3; old_base="$(git --git-dir="${BARE}" rev-parse main)"
( cd "${WT}" && echo g > g.txt && git add g.txt && git commit -qm g && git push -q origin feature )
H1="${H}"; H="$(git -C "${WT}" rev-parse HEAD)"
set_main "${H1}"
jq --arg h "${H}" '.headRefOid=$h' "${ST}/pr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/pr.json"
plant_receipt "${H}" "${old_base}"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r3.lock"; expect r3-ancestor-base 0
grep -q '^MERGED 7 ' <<<"${out}" && ok "r3 merged on the ancestor-base receipt" || bad "r3 no MERGED line" "${out}"

# ---- DND-1463: the receipt's base may be an ANCESTOR of the tip ----
# commit_on_main <file> <content> -- main moves on with a real change.
commit_on_main() {
  local G="git --git-dir=${BARE}" blob tree
  blob="$(printf '%s\n' "$2" | ${G} hash-object -w --stdin)"
  tree="$( { ${G} ls-tree main | awk -F'\t' -v f="$1" '$2 != f'; printf '100644 blob %s\t%s\n' "${blob}" "$1"; } | ${G} mktree)"
  ${G} update-ref refs/heads/main "$(${G} commit-tree "${tree}" -p "$(${G} rev-parse main)" -m "main: $1")"
}
# m1 main moved with a real, non-conflicting change. The landed tree must be
# the head merged into the new tip: both the branch's f.txt and main's m.txt.
fixture m1; commit_on_main m.txt m
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m1.lock"; expect m1 0
M1="$(git --git-dir="${BARE}" rev-parse main)"
[ "$(git --git-dir="${BARE}" show "${M1}:m.txt" 2>/dev/null)" = m ] && [ "$(git --git-dir="${BARE}" show "${M1}:f.txt" 2>/dev/null)" = f ] \
  && ok "m1 landed tree carries main's change and the branch's" || bad "m1 landed tree" "$(git --git-dir="${BARE}" ls-tree "${M1}")"
names m1 "BASE MOVED"
# m2 STEP 7 STILL FIRES when main moved: the forge lands exactly the gated
# head's tree, silently dropping main's m.txt. That is not the expected merge.
fixture m2; commit_on_main m.txt m; echo headtree > "${ST}/merge_mode"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m2.lock"; expect m2 7; no_teardown m2
names m2 "LANDED UNGATED"
# m3 a real conflict with the moved base is refused before the merge call.
fixture m3; commit_on_main f.txt main-side
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m3.lock"; expect m3 3; no_merge m3
names m3 "CONFLICT"
# m4 a receipt whose base is NOT an ancestor of the tip (a sibling of main,
# as after a force-push past it) is still refused.
fixture m4; G4="git --git-dir=${BARE}"
side="$(${G4} commit-tree "$(${G4} rev-parse main^{tree})" -p "$(${G4} rev-parse main)" -m side)"
${G4} update-ref refs/heads/side "${side}"   # on a ref, so the fetch brings it
commit_on_main m.txt m; plant_receipt "${H}" "${side}"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m4.lock"; expect_receipt_refusal m4 "RECEIPT FOR ANOTHER BASE"
# m5 main moved; the only receipt is for a DIFFERENT head -> still refused.
fixture m5; base5="$(git --git-dir="${BARE}" rev-parse main)"; commit_on_main m.txt m
mv "$(receipt_path "${H}")" "$(receipt_path "$(printf 'd%.0s' {1..40})")"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m5.lock"; expect_receipt_refusal m5-other-head-file "NO RECEIPT"
plant_receipt "${H}" "${base5}" pass "$(printf 'd%.0s' {1..40})"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m5.lock"; expect_receipt_refusal m5-recorded-other-head "RECEIPT INVALID"
# m6 main moved; no receipt at all -> still refused.
fixture m6; commit_on_main m.txt m; rm -f "$(receipt_path "${H}")"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m6.lock"; expect_receipt_refusal m6 "NO RECEIPT"
# m7 a receipt whose base is the tip but is NOT in the head: integration-gate
# records only a base the head contains, so this receipt is not believed.
fixture m7; commit_on_main m.txt m; plant_receipt "${H}" "$(git --git-dir="${BARE}" rev-parse main)"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m7.lock"; expect_receipt_refusal m7 "RECEIPT INVALID"

# r4 unreadable receipt (malformed JSON) is not "no receipt".
fixture r4; echo '{not json' > "$(receipt_path "${H}")"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r4.lock"; expect_receipt_refusal r4 "RECEIPT UNREADABLE"
grep -qF "NO RECEIPT" <<<"${out}" && bad "r4 misread an unreadable receipt as absent" "${out}" || ok "r4 not reported as NO RECEIPT"

# r5 a receipt whose recorded head is another SHA, or whose verdict is not
# pass, is not a pass for this head.
fixture r5; plant_receipt "${H}" "$(git --git-dir="${BARE}" rev-parse main)" pass "$(printf 'b%.0s' {1..40})"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r5.lock"; expect_receipt_refusal r5-head "RECEIPT INVALID"
plant_receipt "${H}" "$(git --git-dir="${BARE}" rev-parse main)" red
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r5.lock"; expect_receipt_refusal r5-verdict "RECEIPT INVALID"

# r6 a store that cannot be read: COULD NOT LOOK, never "no receipt".
fixture r6; store="$(dirname "$(receipt_path "${H}")")"; chmod 000 "${store}"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r6.lock"; chmod 755 "${store}"
expect_receipt_refusal r6 "COULD NOT LOOK"
grep -qF "NO RECEIPT" <<<"${out}" && bad "r6 misread an unreadable store as absent" "${out}" || ok "r6 not reported as NO RECEIPT"

# r7 end to end: the real integration-gate passes, locked-merge merges.
fixture r7; rm -f "$(receipt_path "${H}")"
printf '#!/bin/sh\nexit 0\n' > "${TMP}/r7/green.sh"; chmod +x "${TMP}/r7/green.sh"
( cd "${WT}" && d="$(git rev-parse --git-path critic-verdicts)" && mkdir -p "$d" \
  && printf '{"schema":1,"tool":"critic-review","sha":"%s","base":"main","verdict":"pass","findings":[],"dirty":false,"at":"2026-09-27T00:00:00Z"}\n' "${H}" > "${d}/${H}.json" )
( cd "${WT}" && "${igate}" --gate "${TMP}/r7/green.sh" >"${TMP}/r7/igate.out" 2>&1 ); irc=$?
[ "${irc}" -eq 0 ] && ok "r7 integration-gate passes" || bad "r7 integration-gate expected exit 0, got ${irc}" "$(cat "${TMP}/r7/igate.out")"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r7.lock"; expect r7 0
grep -q "^RECEIPT " <<<"${out}" && ok "r7 prints the RECEIPT it merged on" || bad "r7 no RECEIPT line" "${out}"

# c14 --help: stdout, exit 0, no side effects.
hout="$("${TOOL}" --help 2>/dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && grep -q '^Usage:' <<<"${hout}" && ok "c14 --help on stdout, exit 0" || bad "c14 --help" "${hout}"
grep -q '^  9 ' <<<"${hout}" && ok "c14 --help documents exit 9" || bad "c14 --help lacks exit 9" "${hout}"
grep -q '^  10 ' <<<"${hout}" && ok "c14 --help documents exit 10 (DND-864 teardown)" || bad "c14 --help lacks exit 10" "${hout}"
for w in "NOT SEEN YET" "NO RUN FOR BASE" "COULD NOT LOOK" "base SHA"; do
  grep -qF "${w}" <<<"${hout}" && ok "c14 --help documents '${w}' (DND-1378)" || bad "c14 --help lacks '${w}'" "${hout}"
done

# c15 DND-986: integration-gate's receipt gains critic_carried_from when the
# critic PASS was carried. The field is additive, so locked-merge must accept a
# receipt carrying it exactly as before (it checks schema/verdict/head/base).
fixture c15
f="$(receipt_path "${H}")"
jq --arg s "$(printf 'f%.0s' {1..40})" '.critic_carried_from = $s' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c15.lock"; expect c15-carried-receipt 0

echo "locked-merge self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
