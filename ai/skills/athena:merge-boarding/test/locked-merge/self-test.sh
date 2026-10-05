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
# Limit: the gh-athena stub builds its squash tree with the same `git
# merge-tree` the code under test uses, so m1 checks file contents, not a
# second algorithm. A real divergence from GitHub's merge (rename handling)
# would read as exit 7 in production; no case here can show it.
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
# locked-merge (and the real integration-gate r2/r7 run) emit telemetry
# (DND-1475): never into the machine's real store from a fixture.
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry"
# Receipts are sealed under the machine's receipt-seal key (DND-1814): a
# private key under the suite's temp dir here, never the real one.
export ATHENA_SECRETS_ROOT="${TMP}/secrets"
SEAL="$(cd "${HERE}/../../../../bin" && pwd)/receipt-seal"
unset ATHENA_UNIT

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '       %s\n' "$2"; }

# ---- stubs ----
# DND-1647: a guard stands behind every gh/glab stub on PATH, so a stub
# that is missing or not executable fails the suite instead of reaching the
# real CLI (ai/lib/forge-stub-guard.sh).
. "${HERE}/../../../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
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
  # DND-1902: the base tip's rollup. No tip_rollup.json = no check reported.
  "api graphql") [ -e "${ST}/tip_fail" ] && { echo "gh: Bad credentials (HTTP 401)" >&2; exit 1; }
              f="${ST}/tip_rollup.json"
              [ -e "${f}" ] || f="${ST}/../../no_checks.json" ;;
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
# DND-1908: every refusal below is printed by the guard's OWN gmg_refuse and
# its own marks, never a hand-typed copy of the format, so a format change in
# the guard reaches this stub and the tool must still classify it.
# $ST/gmg_lib names the guard library.
. "$(cat "${ST}/gmg_lib")" || exit 99
GMG_TOOL=gh-athena
refuse() { ( gmg_refuse "$@" ); exit $?; }
# DND-1906: the guard's own re-check finds the tip red (it turned red after
# the tool's own check): the guard's refusal shape, exit 3, nothing lands.
[ "${mode}" = redtip ] && refuse 'gh pr merge' "${GMG_RED_MARK} main tip abc is RED, so the line is stopped (DND-1902)." 'land only a red-main fix'
# DND-1907: the guard's own re-check cannot read the tip's runs: COULD NOT LOOK
# (a refusal too, exit 3, nothing lands), worded as the guard words it.
[ "${mode}" = looktip ] && refuse 'gh pr merge' "${GMG_LOOK_MARK} whether the main tip abc is red cannot be told: gh run list failed." 'check gh auth, then re-run'
# Both marks in one refusal: red outranks COULD NOT LOOK.
[ "${mode}" = redlook ] && refuse 'gh pr merge' "${GMG_RED_MARK} main tip abc is RED.
  ${GMG_LOOK_MARK} whether more is red." 'land only a red-main fix'
# Any other guard refusal is exit 3 too, but not a red tip.
[ "${mode}" = guardother ] && refuse 'gh pr merge' 'a check is not green.' 'wait for green'
# DND-1908: a mark OUTSIDE the refusal's reason shape (inside the refused
# command text, or opening a later line) is not a classification.
[ "${mode}" = markinwhat ] && refuse 'gh pr merge MAIN RED: COULD NOT LOOK:' 'a check is not green.' 'wait for green'
[ "${mode}" = marklater ] && refuse 'gh pr merge' 'a check is not green.
  MAIN RED: quoted from a log line' 'wait for green'
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
echo '{"data":{"repository":{"object":{"__typename":"Commit","statusCheckRollup":null}}}}' > "${TMP}/no_checks.json"
fsg_require_stubs "${STUBS}" gh
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
  printf '{"state":"OPEN","headRefOid":"%s","headRefName":"dnd-42-fixture","baseRefName":"main"}\n' "${H}" > "${ST}/pr.json"
  echo '[]' > "${ST}/runs.json"; echo "$(cd "${HERE}/../../../.." && pwd)/lib/gh-merge-guard.sh" > "${ST}/gmg_lib"; echo good > "${ST}/merge_mode"; echo 0 > "${ST}/confirm_rc"
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
  "${SEAL}" seal --kind integration "${f}"
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
unnamed() { grep -qF -- "$2" <<<"${out}" && bad "$1 names '$2'" "${out}" || ok "$1 does not name '$2'"; }

# i1 THE #562 MISS: the branch list reads idle (empty), but the base commit's
# own run is in progress. The old check merged here.
idle_fixture i1 in_progress ""
idle_run i1; expect i1 5; no_merge i1; names i1 "BASE DEPLOY BUSY"; names i1 "101"
# DND-1706: a busy refusal names the slow waiter, never `gh run watch` (a 3 s poll).
names i1 "gh-ci-wait"; unnamed i1 "gh run watch"
# i2 a stale list status: the list says completed, the by-id read says running.
idle_fixture i2; set_base_run completed "" in_progress
idle_run i2; expect i2 5; no_merge i2; names i2 "BASE DEPLOY BUSY"
# i3 the #595 case, made observable: completed/failure merges with a WARN.
# DND-1902: a deploy run that reports red on the tip's own checks is refused
# by the red-tip check (b*); one the tip's rollup does not show stays a WARN.
idle_fixture i3 completed failure
idle_run i3; expect i3 0; names i3 "concluded failure"; names i3 "DND-1902"
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
names i7 "gh-ci-wait"; unnamed i7 "gh run watch"
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
names m3 "CONFLICT"; names m3 "in: f.txt"
names m3 "never rebase a published branch"
# m8 git merge-tree itself fails: COULD NOT LOOK (exit 2), never a clean merge.
fixture m8; commit_on_main m.txt m; mkdir -p "${TMP}/m8/shim"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = merge-tree ] && { echo "fatal: shim merge-tree failure" >&2; exit 128; }; done\nexec %s "$@"\n' "$(command -v git)" > "${TMP}/m8/shim/git"
chmod +x "${TMP}/m8/shim/git"
# DND-1667: a guard right behind the git shim, so a shim that is missing or
# not executable fails the suite instead of reaching the real git. fsg_make,
# not fsg_arm: the rest of the suite runs the real git for its fixtures.
fsg_make "${TMP}/git-guard" git
fsg_require_stubs "${TMP}/m8/shim" git
out="$(PATH="${TMP}/m8/shim:${FSG_DIR}:${PATH}" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m8.lock" 2>&1)"; rc=$?
expect m8 2; no_merge m8; names m8 "COULD NOT LOOK"; names m8 "shim merge-tree failure"
# m9 a receipt base that is not in the object store: RECEIPT BASE UNKNOWN,
# never RECEIPT FOR ANOTHER BASE.
fixture m9; plant_receipt "${H}" "$(printf 'e%.0s' {1..40})"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/m9.lock"; expect_receipt_refusal m9 "RECEIPT BASE UNKNOWN"
grep -qF "RECEIPT FOR ANOTHER BASE" <<<"${out}" && bad "m9 misread an unknown base as another base" "${out}" || ok "m9 not reported as another base"
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
  && printf '{"schema":1,"tool":"critic-review","sha":"%s","base":"main","verdict":"pass","findings":[],"dirty":false,"at":"2026-09-27T00:00:00Z"}\n' "${H}" > "${d}/${H}.json" \
  && "${SEAL}" seal --kind critic "${d}/${H}.json" )
( cd "${WT}" && "${igate}" --gate "${TMP}/r7/green.sh" >"${TMP}/r7/igate.out" 2>&1 ); irc=$?
[ "${irc}" -eq 0 ] && ok "r7 integration-gate passes" || bad "r7 integration-gate expected exit 0, got ${irc}" "$(cat "${TMP}/r7/igate.out")"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/r7.lock"; expect r7 0
grep -q "^RECEIPT " <<<"${out}" && ok "r7 prints the RECEIPT it merged on" || bad "r7 no RECEIPT line" "${out}"

# ---- DND-1902: a red base tip stops the line, under the lock ----
# The defect: gen_saas main went red 2026-10-03 14:06Z and a merge landed onto
# it at 14:23Z; nothing here read the tip's own runs. tip_rollup <status>
# <conclusion-json> plants a rollup for the tip with one judged Deploy run.
tip_rollup() { # <status> <conclusion|null>
  jq -n --arg s "$1" --argjson c "$2" '{data:{repository:{object:{__typename:"Commit",statusCheckRollup:{contexts:{
    totalCount:1, pageInfo:{hasNextPage:false}, nodes:[{__typename:"CheckRun", name:"Deploy", status:$s, conclusion:$c,
    startedAt:"2026-10-03T14:00:00Z", detailsUrl:"https://github.com/t/t/actions/runs/9001/job/1",
    checkSuite:{databaseId:71, app:{databaseId:15368, slug:"github-actions"}, workflowRun:{event:"push", workflow:{databaseId:6}}}}]}}}}}}' \
    > "${ST}/tip_rollup.json"
}
# b1 DND-2061 THE MISS (owner, 2026-10-05: "I don't want a branch to have to
# be built on latest main to be mergeable. That's the point of parallel
# merges."): main moved to a red tip the gated head does not contain -> merges
# (exit 0), naming the red tip and its run. Red CONTENT still refuses (b6).
fixture b1; commit_on_main m.txt m; tip_rollup COMPLETED '"FAILURE"'; RED_TIP="$(git --git-dir="${BARE}" rev-parse main)"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b1.lock"; expect b1 0
names b1 "${RED_TIP}"; names b1 "Deploy: COMPLETED/FAILURE"; names b1 "actions/runs/9001"; names b1 "DND-2061"
# b1b KEPT: the same red tip does not excuse a missing receipt (exit 9).
fixture b1b; commit_on_main m.txt m; tip_rollup COMPLETED '"FAILURE"'; rm -f "$(receipt_path "${H}")"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b1b.lock"; expect b1b 9; no_merge b1b
# b2 a red-main fix: the head CONTAINS the red tip (the fixture's head is cut
# from main's tip) -> merges, and says so.
fixture b2; tip_rollup COMPLETED '"FAILURE"'
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b2.lock"; expect b2 0; names b2 "RED-MAIN FIX"
# b3 the tip's runs cannot be read -> merges, the error named (DND-2061: the
# head's checks and receipt already passed; the runs decide nothing).
fixture b3; : > "${ST}/tip_fail"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b3.lock"; expect b3 0
names b3 "could not be read"; names b3 "HTTP 401"
# b4 a pending run on the tip is not red: merges now, naming it.
fixture b4; commit_on_main m.txt m; tip_rollup IN_PROGRESS null
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b4.lock"; expect b4 0; names b4 "PENDING"
# b5 no check on the tip (custom: no CI) -> merges as before.
fixture b5; commit_on_main m.txt m
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b5.lock"; expect b5 0; names b5 "no check has reported"
# b6/b7 the incident's real shape: every run green, but main holds two
# migrations with one version. The origin is athena-ai-harness/gen_saas,
# which ai/config/main-content-checks.json declares.
gs_fixture() { # <name> -- a fixture whose origin is athena-ai-harness/gen_saas
  fixture "$1"; local GS="https://github.com/athena-ai-harness/gen_saas.git"
  git -C "${WT}" config remote.origin.url "${GS}"; git -C "${WT}" config --unset-all "url.${BARE}.insteadOf"
  git -C "${WT}" config "url.${BARE}.insteadOf" "${GS}"
}
on_main() { # <file...> -- main gains these empty files (one commit)
  ( cd "${WT}" && git checkout -q main && for f in "$@"; do mkdir -p "$(dirname "${f}")"; : > "${f}"; done \
    && git add -A && git commit -qm "main: $*" && git push -q origin main && git checkout -q feature )
}
GSM=apps/athena/priv/repo/migrations
gs_dup_fixture() { # <name> -- main gains a duplicated athena migration version
  gs_fixture "$1"; on_main "${GSM}/20261003120000_cap.exs" "${GSM}/20261003120000_strip.exs"
}
gs_dup_fixture b6
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b6.lock"; expect b6 11; no_merge b6
names b6 "apps/athena/priv/repo/migrations version 20261003120000: 20261003120000_cap.exs, 20261003120000_strip.exs"
gs_dup_fixture b7; follow_main
( cd "${WT}" && git mv apps/athena/priv/repo/migrations/20261003120000_strip.exs apps/athena/priv/repo/migrations/20261003120001_strip.exs \
  && git commit -qm fix && git push -q origin feature )
H="$(git -C "${WT}" rev-parse HEAD)"; jq --arg h "${H}" '.headRefOid=$h' "${ST}/pr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/pr.json"
plant_receipt "${H}" "$(git --git-dir="${BARE}" rev-parse main)"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b7.lock"; expect b7 0; names b7 "RED-MAIN FIX"
# b8 the incident's mechanism: main holds ONE 20261003120000 migration, and
# the PR (gated on the older base, DND-1463) adds another. Main is not red
# yet; the squash would make it red. Refused before the merge call.
gs_fixture b8; old_main="$(git --git-dir="${BARE}" rev-parse main)"; on_main "${GSM}/20261003120000_cap.exs"
( cd "${WT}" && mkdir -p "${GSM}" && : > "${GSM}/20261003120000_strip.exs" && git add -A && git commit -qm strip && git push -q origin feature )
H="$(git -C "${WT}" rev-parse HEAD)"; jq --arg h "${H}" '.headRefOid=$h' "${ST}/pr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/pr.json"
plant_receipt "${H}" "${old_main}"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b8.lock"; expect b8 3; no_merge b8
names b8 "SEMANTIC CONFLICT"; names b8 "${GSM} version 20261003120000: 20261003120000_cap.exs, 20261003120000_strip.exs"
# b9 a declared repo whose tree has no directory the pattern matches: COULD
# NOT LOOK, never "no duplicate" (a moved path or a wrong pattern).
gs_fixture b9
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b9.lock"; expect b9 2; no_merge b9
names b9 "COULD NOT LOOK"; names b9 "matches no directory"

# b10 DND-1906 THE MISS: the tip turns red between the tool's own check and the
# guard's re-check. The guard refuses (exit 3, MAIN RED); that read as exit 4
# after the confirm retries. Now exit 11, the guard's message kept, no retries.
fixture b10; echo redtip > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
cat > "${STUBS}/confirm-merged" <<'EOF2'
#!/usr/bin/env bash
echo called >> "${ST}/confirm.log"
exit "$(cat "${ST}/confirm_rc")"
EOF2
: > "${ST}/confirm.log"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b10.lock"; expect b10 11; no_teardown b10
names b10 "MAIN RED: main tip abc is RED"
grep -q "^Fix: land only a red-main fix: .*the red tip the guard names above" <<<"${out}" && ok "b10 Fix: points at the guard's tip, not the stale one" || bad "b10 Fix: wrong" "${out}"
[ -s "${ST}/confirm.log" ] && bad "b10 confirm-merged was retried" "$(cat "${ST}/confirm.log")" || ok "b10 no confirm retries"
# b11 another guard refusal (exit 3, not red) keeps exit 4: no other code moves.
fixture b11; echo guardother > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b11.lock"; expect b11 4; no_teardown b11

# b12 DND-1907 THE MISS: the guard refuses COULD NOT LOOK at the tip. That read
# as exit 4 after the confirm retries. Now exit 2 (this tool's own COULD NOT
# LOOK code) at once, the guard's message and Fix: kept, no retries.
fixture b12; echo looktip > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
: > "${ST}/confirm.log"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b12.lock"; expect b12 2; no_teardown b12
names b12 "COULD NOT LOOK: whether the main tip abc is red cannot be told"
grep -q "^  Fix: check gh auth" <<<"${out}" && ok "b12 the guard's Fix: kept" || bad "b12 guard Fix: lost" "${out}"
grep -q "^Fix: .*Nothing was merged" <<<"${out}" && ok "b12 own Fix: present" || bad "b12 own Fix: missing" "${out}"
[ -s "${ST}/confirm.log" ] && bad "b12 confirm-merged was retried" "$(cat "${ST}/confirm.log")" || ok "b12 no confirm retries"

# b13 red outranks COULD NOT LOOK when a refusal carries both marks: exit 11.
fixture b13; echo redlook > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b13.lock"; expect b13 11; no_teardown b13

# b14 DND-1908 THE MISS: the tool matched the literal REFUSING and each mark
# anywhere in the guard's stderr. A mark inside the refused command text, or
# opening a later line, read as a red tip or a COULD NOT LOOK. Only the guard's
# own `REFUSING ...: <mark>` shape counts: both keep exit 4.
fixture b14; echo markinwhat > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b14.lock"; expect b14 4; no_teardown b14
fixture b15; echo marklater > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/b15.lock"; expect b15 4; no_teardown b15
# b16 the tool holds no copy of the refusal format: it asks the guard library.
grep -qF 'REFUSING' "${TOOL}" && bad "b16 the tool carries a literal REFUSING" "$(grep -nF REFUSING "${TOOL}")" || ok "b16 no literal REFUSING in the tool (the guard's format is shared)"

# b17 DND-1908: whatever gmg_refuse prints, gmg_refusal_has_reason reads back,
# including after a format change (a different refusal word): the writer and
# the reader share one definition, so they cannot drift apart.
b17_lib="$(cd "${HERE}/../../../.." && pwd)/lib/gh-merge-guard.sh"
b17_err="${TMP}/b17.err"
for b17_word in REFUSING DENIED; do
  ( . "${b17_lib}" && GMG_TOOL=gh-athena && GMG_REFUSE_WORD="${b17_word}" && gmg_refuse 'gh pr merge' "${GMG_RED_MARK} tip is RED" 'fix it' ) 2> "${b17_err}"
  if ( . "${b17_lib}" && GMG_REFUSE_WORD="${b17_word}" && gmg_refusal_has_reason "${b17_err}" "${GMG_RED_MARK}" ); then
    ok "b17 a ${b17_word} refusal is read back by its red mark"
  else
    bad "b17 reader missed a ${b17_word} refusal" "$(cat "${b17_err}")"
  fi
  if ( . "${b17_lib}" && GMG_REFUSE_WORD="${b17_word}" && gmg_refusal_has_reason "${b17_err}" "${GMG_LOOK_MARK}" ); then
    bad "b17 reader matched the wrong mark" "$(cat "${b17_err}")"
  else
    ok "b17 the other mark does not match a ${b17_word} refusal"
  fi
done
if ( . "${b17_lib}" && gmg_refusal_has_reason "${TMP}/b17.absent" "${GMG_RED_MARK}" ); then
  bad "b17 an unreadable file matched" ""
else
  ok "b17 an unreadable stderr file is no match"
fi

# c14 --help: stdout, exit 0, no side effects.
hout="$("${TOOL}" --help 2>/dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && grep -q '^Usage:' <<<"${hout}" && ok "c14 --help on stdout, exit 0" || bad "c14 --help" "${hout}"
grep -q '^  9 ' <<<"${hout}" && ok "c14 --help documents exit 9" || bad "c14 --help lacks exit 9" "${hout}"
grep -q '^  10 ' <<<"${hout}" && ok "c14 --help documents exit 10 (DND-864 teardown)" || bad "c14 --help lacks exit 10" "${hout}"
grep -q '^  11 .*RED' <<<"${hout}" && ok "c14 --help documents exit 11 (DND-1902 red tip)" || bad "c14 --help lacks exit 11" "${hout}"
for w in "NOT SEEN YET" "NO RUN FOR BASE" "COULD NOT LOOK" "base SHA"; do
  grep -qF "${w}" <<<"${hout}" && ok "c14 --help documents '${w}' (DND-1378)" || bad "c14 --help lacks '${w}'" "${hout}"
done

# c15 DND-986: integration-gate's receipt gains critic_carried_from when the
# critic PASS was carried. The field is additive, so locked-merge must accept a
# receipt carrying it exactly as before (it checks schema/verdict/head/base).
fixture c15
f="$(receipt_path "${H}")"
jq --arg s "$(printf 'f%.0s' {1..40})" '.critic_carried_from = $s' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
# The gate seals what it writes (DND-1814); reseal the edited body as it would.
"${SEAL}" seal --kind integration "${f}"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c15.lock"; expect c15-carried-receipt 0

# c16 DND-1814: a FORGED receipt -- the right shape for exactly the head and
# base, written by hand with no seal -- is refused before any merge call, with
# the re-gate Fix:. Before DND-1814 locked-merge merged on it.
fixture c16
f="$(receipt_path "${H}")"
jq 'del(.seal, .producer)' "${f}" > "${f}.tmp" && mv "${f}.tmp" "${f}"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c16.lock"; expect_receipt_refusal c16 "RECEIPT UNVERIFIED"
grep -q 'UNSEALED' <<<"${out}" && grep -q '^Fix:.*integration-gate' <<<"${out}" \
  && ok "c16 the refusal says UNSEALED and carries the re-gate Fix:" || bad "c16 forged receipt not explained" "${out}"

# ---- DND-1475: telemetry, merge.lock_wait and merge.landed ----
# Each case has its own store. tel_events <store> <event> -> the lines.
tel_events() { cat "$1"/*.jsonl 2>/dev/null | jq -c --arg e "$2" 'select(.event == $e)'; }
tel_count() { local n; n="$(tel_events "$1" "$2" | grep -c .)"; printf '%s' "${n:-0}"; }
no_drops() { [ -e "$2/write-failures" ] && bad "$1 the writer counted a drop" "$(cat "$2/write-failures")" || ok "$1 no write-failures"; }

# t1 lock free: lock_wait acquired, then landed via=pr with the PR, base and merge commit.
fixture t1; T="${TMP}/t1-store"; B1="$(git --git-dir="${BARE}" rev-parse main)"
out="$(ATHENA_TELEMETRY_DIR="${T}" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/t1.lock" 2>&1)"; rc=$?
expect t1 0
M1="$(git --git-dir="${BARE}" rev-parse main)"
lw="$(tel_events "${T}" merge.lock_wait)"; ld="$(tel_events "${T}" merge.landed)"
[ "$(tel_count "${T}" merge.lock_wait)" = 1 ] && [ "$(jq -c .attrs <<<"${lw}")" = '{"lock":"explicit","outcome":"acquired"}' ] \
  && jq -e '.duration_s | type == "number" and . >= 0' <<<"${lw}" >/dev/null \
  && ok "t1 one merge.lock_wait: acquired, lock=explicit (a closed label, never the path), a duration" || bad "t1 merge.lock_wait" "${lw}"
[ "$(tel_count "${T}" merge.landed)" = 1 ] \
  && [ "$(jq -cS .attrs <<<"${ld}")" = "$(jq -cnS --arg b "${B1}" --arg m "${M1}" '{via:"pr",pr:7,before:$b,after:$m}')" ] \
  && [ "$(jq -r .head <<<"${ld}")" = "${H}" ] && [ "$(jq -r .duration_s <<<"${ld}")" = null ] \
  && [ "$(jq -r .repo <<<"${ld}")" = wt ] \
  && ok "t1 one merge.landed: via=pr pr=7 before=base after=merge commit, head = the gated head, a point event, repo of --repo" \
  || bad "t1 merge.landed" "${ld}"
# The ledger joins these to the landing by unit or head (DND-1477): both carry
# the gated head, and the unit the PR's head branch names, not the checkout's.
[ "$(jq -r '[.unit, .unit_source, .head] | join(" ")' <<<"${lw}")" = "DND-42 branch ${H}" ] \
  && [ "$(jq -r '[.unit, .unit_source] | join(" ")' <<<"${ld}")" = "DND-42 branch" ] \
  && ok "t1 both events: unit from the PR's head branch (DND-42), head = the gated head" \
  || bad "t1 unit/head" "${lw} ${ld}"
no_drops t1 "${T}"

# t2 lock held, --wait 1: lock_wait timeout, no landed, exit 6 unchanged.
fixture t2; T="${TMP}/t2-store"; exec 8>>"${TMP}/t2.lock"; flock 8
out="$(ATHENA_TELEMETRY_DIR="${T}" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/t2.lock" --wait 1 2>&1)"; rc=$?
exec 8>&-
expect t2 6; no_merge t2
[ "$(tel_count "${T}" merge.lock_wait)" = 1 ] && [ "$(tel_events "${T}" merge.lock_wait | jq -r .attrs.outcome)" = timeout ] \
  && ok "t2 one merge.lock_wait with outcome=timeout" || bad "t2 merge.lock_wait" "$(cat "${T}"/*.jsonl 2>/dev/null)"
[ "$(tel_count "${T}" merge.landed)" = 0 ] && ok "t2 no merge.landed" || bad "t2 a timeout emitted merge.landed"
no_drops t2 "${T}"

# t3 refused under the lock (no receipt): lock_wait, no landed.
fixture t3; T="${TMP}/t3-store"; rm -f "$(receipt_path "${H}")"
out="$(ATHENA_TELEMETRY_DIR="${T}" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/t3.lock" 2>&1)"; rc=$?
expect t3 9
[ "$(tel_count "${T}" merge.lock_wait)" = 1 ] && [ "$(tel_count "${T}" merge.landed)" = 0 ] \
  && ok "t3 a refusal under the lock: lock_wait only, no landed" || bad "t3 events" "$(cat "${T}"/*.jsonl 2>/dev/null)"

# t4 LANDED UNGATED (exit 7): the merge is confirmed, so it is still a landing.
fixture t4; T="${TMP}/t4-store"; echo badtree > "${ST}/merge_mode"
out="$(ATHENA_TELEMETRY_DIR="${T}" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/t4.lock" 2>&1)"; rc=$?
expect t4 7
[ "$(tel_count "${T}" merge.landed)" = 1 ] && ok "t4 a confirmed landing that failed the tree check is still merge.landed" \
  || bad "t4 merge.landed" "$(cat "${T}"/*.jsonl 2>/dev/null)"

# t5 refused before the lock (bad args): nothing at all.
fixture t5; T="${TMP}/t5-store"
out="$(ATHENA_TELEMETRY_DIR="${T}" "${TOOL}" --pr x --head "${H}" --repo "${WT}" 2>&1)"; rc=$?
expect t5 2
[ ! -e "${T}" ] && ok "t5 a usage refusal emits nothing" || bad "t5 wrote telemetry" "$(cat "${T}"/*.jsonl 2>/dev/null)"

# t6 FAIL-OPEN: an unwritable store changes neither the exit code nor stdout
# (shas and fixture names normalised: each twin is its own fixture).
norm() { sed -E 's/[0-9a-f]{40}/SHA/g; s/t6[a-d]/T6/g'; }
mkdir -p "${TMP}/t6-ro"; chmod 500 "${TMP}/t6-ro"
fixture t6a; o1="$(ATHENA_TELEMETRY_DIR="${TMP}/t6-rw" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/t6a.lock" 2>/dev/null | norm)"; c1=${PIPESTATUS[0]}
fixture t6b; o2="$(ATHENA_TELEMETRY_DIR="${TMP}/t6-ro/telemetry" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/t6b.lock" 2>"${TMP}/t6b.err" | norm)"; c2=${PIPESTATUS[0]}
# The writer's last-resort line (contract: Fails open) must still reach stderr.
grep -q '^athena-telemetry:.*Fix:' "${TMP}/t6b.err" && ok "t6 the writer's athena-telemetry: Fix: line reaches stderr" \
  || bad "t6 the athena-telemetry: line was swallowed" "$(cat "${TMP}/t6b.err")"
[ "${c1}" = 0 ] && [ "${c1}" = "${c2}" ] && [ "${o1}" = "${o2}" ] && ok "t6 merged: unwritable store, exit and stdout unchanged" \
  || bad "t6 merged: the unwritable store changed the run (exit ${c1} vs ${c2})" "$(diff <(printf '%s\n' "${o1}") <(printf '%s\n' "${o2}"))"
fixture t6c; exec 8>>"${TMP}/t6c.lock"; flock 8
o1="$(ATHENA_TELEMETRY_DIR="${TMP}/t6-rw2" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/t6c.lock" --wait 1 2>/dev/null | norm)"; c1=${PIPESTATUS[0]}
o2="$(ATHENA_TELEMETRY_DIR="${TMP}/t6-ro/telemetry" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/t6c.lock" --wait 1 2>/dev/null | norm)"; c2=${PIPESTATUS[0]}
exec 8>&-
[ "${c1}" = 6 ] && [ "${c1}" = "${c2}" ] && [ "${o1}" = "${o2}" ] && ok "t6 timeout: unwritable store, exit 6 and stdout unchanged" \
  || bad "t6 timeout: the unwritable store changed the run (exit ${c1} vs ${c2})" "$(diff <(printf '%s\n' "${o1}") <(printf '%s\n' "${o2}"))"
chmod 700 "${TMP}/t6-ro"
[ ! -e "${TMP}/t6-ro/telemetry" ] && ok "t6 nothing was written to the unwritable store" || bad "t6 unwritable store written"

# DND-1647: no gh/glab call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab/git call fell through past its stub (DND-1647/DND-1667)"
else bad "no gh/glab/git call fell through past its stub (DND-1647/DND-1667)" "see the forge-stub-guard FAIL above"; fi

echo "locked-merge self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
