#!/usr/bin/env bash
# self-test.sh -- the leadtime-product suite (DND-1540). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. the domain suite (product_test.rb), through `leadtime-product --self-test`;
#   2. the CLI end to end against temp repos: a bare origin and a clone of it as
#      the product repo R (named "prod"), a temp state dir, and FAKES for every
#      forge and gate tool (gh, gh-athena, integration-gate, locked-merge,
#      confirm-merged, teardown-stack). The fake gh-athena's `git` passthrough
#      runs plain git against the temp origin. Nothing real is pushed, opened,
#      gated or merged, and no bootstrap (docker) runs: LEADTIME_PRODUCT_BOOTSTRAP
#      is a stub command in every case.
# Functional only (DND-1222): no sleeps, no timing, no load. Names are synthetic.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
BIN="${ROOT}/ai/bin/leadtime-product"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }

[ -x /usr/bin/ruby ] || { echo "leadtime-product self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -x "${BIN}" ] || { echo "leadtime-product self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/bin/leadtime-product"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; echo "  Fix: free space in TMPDIR"; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)"
HOLDER_PIDS=()
release_holders() { local p; for p in "${HOLDER_PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; HOLDER_PIDS=(); }
cleanup() { release_holders; rm -rf -- "${TMP}"; }
trap cleanup EXIT INT TERM
unset LEADTIME_PRODUCT_MANIFEST LEADTIME_PRODUCT_BOOTSTRAP LEADTIME_NOW

G=(-c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main)
RUN_ID="run-20261001T123000Z-4242"
NOW_FIXED="$(date -d '2026-10-01 12:30 UTC' +%s)"

echo "== domain"
if "${BIN}" --self-test >"${TMP}/lib.out" 2>&1; then
  ok "leadtime-product --self-test: $(tail -1 "${TMP}/lib.out")"
else
  bad "leadtime-product --self-test" "$(cat "${TMP}/lib.out")"
fi

echo "== framework"
out="$("${BIN}" --help 2>"${TMP}/err")"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"Usage:"* ]] && [ ! -s "${TMP}/err" ]; then ok "--help: usage on stdout, exit 0"; else bad "--help" "rc=$rc"; fi
"${BIN}" frob >/dev/null 2>"${TMP}/err"; rc=$?
if [ "$rc" = 2 ] && grep -q 'Fix:' "${TMP}/err"; then ok "an unknown subcommand: exit 2 with Fix:"; else bad "unknown subcommand" "rc=$rc"; fi
"${BIN}" cut --repo prod >/dev/null 2>"${TMP}/err"; rc=$?
if [ "$rc" = 2 ] && grep -q -- '--phase' "${TMP}/err"; then ok "cut without --phase: exit 2 naming it"; else bad "cut missing flag" "rc=$rc $(cat "${TMP}/err")"; fi
"${BIN}" sweep >/dev/null 2>"${TMP}/err"; rc=$?
if [ "$rc" = 2 ] && grep -q 'LEADTIME_PRODUCT_MANIFEST' "${TMP}/err"; then ok "no manifest: exit 2, never an empty sweep"; else bad "no manifest" "rc=$rc"; fi

# --- fixtures -------------------------------------------------------------------
# The fakes record every call, in order, in $FAKE/calls.
FAKE="${TMP}/fake"; mkdir -p "$FAKE"
cat >"$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$FAKE/calls"
if [ "$1 $2" = "pr view" ]; then
  f="$FAKE/pr-$3.json"; [ -r "$f" ] || { echo "no such PR $3" >&2; exit 1; }; cat "$f"; exit 0
fi
if [ "$1 $2" = "run list" ]; then f="$FAKE/runs-$4.json"; [ -r "$f" ] && cat "$f" || echo '[]'; exit 0; fi
echo "fake gh: unexpected $*" >&2; exit 64
EOF
cat >"$FAKE/gh-athena" <<'EOF'
#!/usr/bin/env bash
printf 'gh-athena %s\n' "$*" >>"$FAKE/calls"
if [ "$1" = git ]; then shift; [ -e "$FAKE/push-rc" ] && exit "$(cat "$FAKE/push-rc")"; exec git "$@"; fi
if [ "$1 $2" = "pr create" ]; then
  n=$(( $(cat "$FAKE/pr-counter" 2>/dev/null || echo 6) + 1 )); echo "$n" >"$FAKE/pr-counter"
  prev=""; for a in "$@"; do [ "$prev" = "--body-file" ] && cp -- "$a" "$FAKE/body-$n.md"; prev="$a"; done
  echo "https://github.com/example/prod/pull/$n"; exit 0
fi
if [ "$1 $2" = "pr close" ]; then exit "$(cat "$FAKE/close-rc" 2>/dev/null || echo 0)"; fi
echo "fake gh-athena: unexpected $*" >&2; exit 64
EOF
cat >"$FAKE/integration-gate" <<'EOF'
#!/usr/bin/env bash
printf 'integration-gate %s\n' "$*" >>"$FAKE/calls"
if [ -e "$FAKE/gate-rebase" ]; then
  echo rebased >rebased.txt; git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false add rebased.txt
  git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q -m rebased
fi
cat "$FAKE/gate-out" 2>/dev/null
exit "$(cat "$FAKE/gate-rc" 2>/dev/null || echo 0)"
EOF
for t in locked-merge confirm-merged teardown-stack; do
  cat >"$FAKE/$t" <<EOF
#!/usr/bin/env bash
printf '$t %s\n' "\$*" >>"\$FAKE/calls"
exit "\$(cat "\$FAKE/$t-rc" 2>/dev/null || echo 0)"
EOF
done
chmod +x "$FAKE"/*
export FAKE LEADTIME_GH="$FAKE/gh" LEADTIME_GH_ATHENA="$FAKE/gh-athena" LEADTIME_INTEGRATION_GATE="$FAKE/integration-gate" \
       LEADTIME_LOCKED_MERGE="$FAKE/locked-merge" LEADTIME_CONFIRM_MERGED="$FAKE/confirm-merged" \
       LEADTIME_TEARDOWN_STACK="$FAKE/teardown-stack" LEADTIME_PRODUCT_FORGE=github LEADTIME_NOW="$NOW_FIXED"
export LEADTIME_PRODUCT_BOOTSTRAP="echo bootstrapped >>\"$FAKE/calls\""

# new_repo -- a fresh state dir, a bare origin and a clone of it named prod,
# and the manifest for RUN_ID. Sets R, S, MAN, LANES; clears the fakes' state.
new_repo() {
  local d; d="$(mktemp -d -p "$TMP" case.XXXXXX)"
  rm -f "$FAKE"/calls "$FAKE"/pr-*.json "$FAKE"/runs-*.json "$FAKE"/*-rc "$FAKE"/gate-* "$FAKE"/pr-counter "$FAKE"/body-*
  git "${G[@]}" init -q "$d/seed"; echo one >"$d/seed/a.txt"; git -C "$d/seed" add -A; git "${G[@]}" -C "$d/seed" commit -q -m seed
  git clone -q --bare "$d/seed" "$d/origin.git"
  mkdir -p "$d/checkouts"; git clone -q "$d/origin.git" "$d/checkouts/prod"
  ORIGIN="$d/origin.git"; R="$d/checkouts/prod"; S="$d/state"; LANES="$R/.git/leadtime-lanes"; MAN="$d/manifest.json"
  mkdir -p "$S" "$LANES"
  jq -n --arg r "$R" --arg l "$LANES" --arg id "$RUN_ID" --arg s "$S" \
    '{run_id: $id, state_dir: $s, repos: [{name: "prod", path: $r, common: ($r + "/.git"), lanes_dir: $l,
      lane: ($l + "/" + $id), lock: ($l + "/" + $id + ".lock")}]}' >"$MAN"
}
hold_lock() { # <file> -- a fixture process holds an flock on <file> until released
  local fifo; fifo="$(mktemp -u -p "$TMP" held.XXXXXX)"; mkfifo "$fifo"
  ( exec 7>>"$1"; flock 7; echo held >"$fifo"; exec tail -f /dev/null ) &
  HOLDER_PIDS+=("$!")
  timeout 30 cat "$fifo" >/dev/null
}
lp() { "${BIN}" "$@" --manifest "$MAN" >"${TMP}/out" 2>"${TMP}/err"; echo $?; }
lane_commit() { # <file> -- one commit in this run's lane
  echo change >"$LANES/$RUN_ID/$1"; git -C "$LANES/$RUN_ID" add "$1"; git "${G[@]}" -C "$LANES/$RUN_ID" commit -q -m "change $1"
}
pr_json() { # <n> <state> <head> <ci-rollup-json> [merge-oid]
  jq -n --arg st "$2" --arg h "$3" --argjson ci "$4" --arg m "${5:-}" \
    '{state: $st, headRefOid: $h, statusCheckRollup: $ci, mergeCommit: (if $m == "" then null else {oid: $m} end)}' >"$FAKE/pr-$1.json"
}
GREEN='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]'
RED='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]'
PENDING='[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]'
called() { grep -c "^$1" "$FAKE/calls" 2>/dev/null || true; }
# open_one -- cut, commit, and open PR #7 in this run; teardown. Sets HEAD7, BR7.
open_one() {
  hold_lock "$LANES/$RUN_ID.lock"
  lp cut --repo prod --phase verify >/dev/null
  lane_commit fix.txt
  HEAD7="$(git -C "$LANES/$RUN_ID" rev-parse HEAD)"; BR7="$(git -C "$LANES/$RUN_ID" rev-parse --abbrev-ref HEAD)"
  echo "before/after evidence" >"$TMP/evidence.md"
  lp pr --repo prod --title "speed up verify" --body-file "$TMP/evidence.md" >/dev/null
  lp teardown >/dev/null
  release_holders; rm -f "$LANES/$RUN_ID.lock"
  : >"$FAKE/calls"
}

echo "== cut"
new_repo
rc="$(lp cut --repo prod --phase verify)"
if [ "$rc" = 2 ] && grep -q 'no lane lock' "${TMP}/err" && [ ! -e "$LANES/$RUN_ID" ]; then
  ok "cut with no reserved lock: exit 2, no lane"
else bad "cut no lock" "rc=$rc $(cat "${TMP}/err")"; fi
: >"$LANES/$RUN_ID.lock"
rc="$(lp cut --repo prod --phase verify)"
if [ "$rc" = 2 ] && grep -q 'not held' "${TMP}/err" && [ ! -e "$LANES/$RUN_ID" ]; then
  ok "cut with a lock nobody holds (the runner is gone): exit 2, no lane"
else bad "cut dead lock" "rc=$rc $(cat "${TMP}/err")"; fi
hold_lock "$LANES/$RUN_ID.lock"
rc="$(lp cut --repo prod --phase Bad/phase)"
[ "$rc" = 2 ] && grep -q 'Fix:' "${TMP}/err" && ok "a bad phase: exit 2 with Fix:" || bad "bad phase" "rc=$rc"
rc="$(lp cut --repo other --phase verify)"
[ "$rc" = 2 ] && grep -q 'this run.s product repos: prod' "${TMP}/err" && ok "a repo with no product lane: exit 2 naming the run's repos" || bad "other repo" "rc=$rc $(cat "${TMP}/err")"
rc="$(lp cut --repo prod --phase verify)"
base="$(git -C "$R" rev-parse refs/remotes/origin/main)"
if [ "$rc" = 0 ] && [ "$(git -C "$LANES/$RUN_ID" rev-parse HEAD)" = "$base" ] \
   && [ "$(git -C "$LANES/$RUN_ID" rev-parse --abbrev-ref HEAD)" = "leadtime/prod-verify-20261001T123000Z" ] \
   && grep -qx "lane=$LANES/$RUN_ID" "${TMP}/out" && grep -qx 'bootstrap=ran' "$LANES/$RUN_ID.meta" \
   && [ "$(called bootstrapped)" = 1 ]; then
  ok "cut: a lane in R's common dir at <run-id>, cut from R's origin/main on leadtime/prod-verify-<utc>; bootstrap ran"
else bad "cut" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err") meta=$(cat "$LANES/$RUN_ID.meta" 2>/dev/null)"; fi
rc="$(lp cut --repo prod --phase verify)"
[ "$rc" = 2 ] && grep -q 'already cut' "${TMP}/err" && ok "a second cut in one run: exit 2" || bad "second cut" "rc=$rc"
release_holders

new_repo
hold_lock "$LANES/$RUN_ID.lock"
rc="$(LEADTIME_PRODUCT_BOOTSTRAP='echo docker said no; exit 9' lp cut --repo prod --phase verify)"
if [ "$rc" = 5 ] && grep -q 'cannot act on prod' "$S/journal.md" && grep -q 'exit 9' "$S/journal.md" \
   && grep -qx 'bootstrap=failed' "$LANES/$RUN_ID.meta" && grep -q 'not retried' "${TMP}/err"; then
  ok "a failed bootstrap: exit 5, journaled 'cannot act on prod', not retried"
else bad "bootstrap failed" "rc=$rc err=$(cat "${TMP}/err") journal=$(cat "$S/journal.md" 2>/dev/null)"; fi
release_holders

echo "== pr"
new_repo
hold_lock "$LANES/$RUN_ID.lock"
lp cut --repo prod --phase verify >/dev/null
echo "evidence" >"$TMP/evidence.md"
rc="$(lp pr --repo prod --title t --body-file "$TMP/evidence.md")"
[ "$rc" = 2 ] && grep -q 'no commit beyond origin/main' "${TMP}/err" && ok "pr with nothing to propose: exit 2" || bad "pr nothing" "rc=$rc $(cat "${TMP}/err")"
echo dirty >"$LANES/$RUN_ID/dirty.txt"
rc="$(lp pr --repo prod --title t --body-file "$TMP/evidence.md")"
[ "$rc" = 2 ] && grep -q 'uncommitted' "${TMP}/err" && ok "pr with uncommitted changes: exit 2" || bad "pr dirty" "rc=$rc"
rm -f "$LANES/$RUN_ID/dirty.txt"
lane_commit fix.txt
tip="$(git -C "$LANES/$RUN_ID" rev-parse HEAD)"
rc="$(lp pr --repo prod --title "speed up verify" --body-file "$TMP/evidence.md")"
rec="$(jq -c 'select(.event == "opened")' "$S/product-prs.jsonl" 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$(git -C "$ORIGIN" rev-parse leadtime/prod-verify-20261001T123000Z 2>/dev/null)" = "$tip" ] \
   && grep -q '^gh-athena git -c credential.helper= -c url.https://github.com/.insteadOf=git@github.com: push -u origin HEAD' "$FAKE/calls" \
   && grep -q '^gh-athena pr create --base main --head leadtime/prod-verify-20261001T123000Z --title speed up verify' "$FAKE/calls" \
   && [ "$(jq -r .head <<<"$rec")" = "$tip" ] && [ "$(jq -r .pr <<<"$rec")" = 7 ] && [ "$(jq -r .phase <<<"$rec")" = verify ] \
   && [ "$(cat "$FAKE/body-7.md")" = evidence ] && [ "$(stat -c %a "$S/product-prs.jsonl")" = 600 ]; then
  ok "pr: pushed as Athena (gh-athena git push), opened with gh-athena pr create, recorded (repo, pr, phase, head) in product-prs.jsonl"
else bad "pr" "rc=$rc err=$(cat "${TMP}/err") rec=$rec calls=$(cat "$FAKE/calls")"; fi

echo "== teardown"
rc="$(lp teardown)"
if [ "$rc" = 0 ] && grep -q 'awaiting landing on PR #7' "${TMP}/out" && [ ! -e "$LANES/$RUN_ID" ] \
   && ! git -C "$R" show-ref --verify --quiet refs/heads/leadtime/prod-verify-20261001T123000Z; then
  ok "a pushed commit on an open PR: awaiting landing, not STRANDED (exit 0); lane removed"
else bad "teardown awaiting" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi
release_holders

new_repo
hold_lock "$LANES/$RUN_ID.lock"
lp cut --repo prod --phase verify >/dev/null
lane_commit unpushed.txt
rc="$(lp teardown)"
if [ "$rc" = 72 ] && grep -q 'STRANDED' "${TMP}/out" && git -C "$R" show-ref --verify --quiet refs/heads/leadtime/prod-verify-20261001T123000Z \
   && [ ! -e "$LANES/$RUN_ID" ]; then
  ok "an unpushed commit: STRANDED, exit 72, branch kept"
else bad "teardown stranded" "rc=$rc out=$(cat "${TMP}/out")"; fi

new_repo
hold_lock "$LANES/$RUN_ID.lock"
lp cut --repo prod --phase verify >/dev/null
lane_commit pushed.txt
echo evidence >"$TMP/evidence.md"
lp pr --repo prod --title t --body-file "$TMP/evidence.md" >/dev/null
lane_commit after-push.txt
rc="$(lp teardown)"
[ "$rc" = 72 ] && grep -q 'STRANDED' "${TMP}/out" && ok "a commit made after the push: STRANDED, exit 72" || bad "commit after push" "rc=$rc out=$(cat "${TMP}/out")"
release_holders

new_repo
rc="$(lp teardown)"
[ "$rc" = 0 ] && grep -q 'none (no lane cut)' "${TMP}/out" && ok "no lane cut: teardown says so, exit 0" || bad "teardown none" "rc=$rc"

echo "== reap"
new_repo
DEAD="run-20260930T113000Z-11"; LIVE="run-20260930T123000Z-12"
git -C "$R" worktree add -q -b leadtime/prod-tail-dead "$LANES/$DEAD" origin/main
printf 'branch=leadtime/prod-tail-dead\nbootstrap=ran\n' >"$LANES/$DEAD.meta"
echo x >"$LANES/$DEAD/x.txt"; git -C "$LANES/$DEAD" add x.txt; git "${G[@]}" -C "$LANES/$DEAD" commit -q -m dead
: >"$LANES/$DEAD.lock"
git -C "$R" worktree add -q -b leadtime/prod-tail-live "$LANES/$LIVE" origin/main
hold_lock "$LANES/$LIVE.lock"
rc="$(lp reap)"
if [ "$rc" = 0 ] && [ ! -e "$LANES/$DEAD" ] && [ ! -e "$LANES/$DEAD.lock" ] && grep -q "lane=$DEAD STRANDED" "${TMP}/out" \
   && git -C "$R" show-ref --verify --quiet refs/heads/leadtime/prod-tail-dead && [ -d "$LANES/$LIVE" ] && [ -e "$LANES/$LIVE.lock" ] \
   && grep -q "teardown-stack --worktree $LANES/$DEAD --parked" "$FAKE/calls"; then
  ok "reap: a dead lane (lock free) is removed, its unpushed branch kept, its stack torn down; a live (held) lane is untouched"
else bad "reap" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi
release_holders

echo "== sweep"
new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$PENDING"
before="$(cat "$S/product-prs.jsonl")"
rc="$(lp sweep)"
# One read of the PR, nothing else: no checks watch, no rerun, no gate, no new event.
if [ "$rc" = 0 ] && head -1 "${TMP}/out" | grep -qx 'product_prs=1 landed=none' && grep -q 'pr=#7 open: CI pending' "${TMP}/out" \
   && [ "$(called integration-gate)" = 0 ] && [ "$(grep -c . "$FAKE/calls")" = 1 ] && grep -qx 'gh pr view 7 --json state,headRefOid,statusCheckRollup,mergeCommit' "$FAKE/calls" \
   && [ "$(cat "$S/product-prs.jsonl")" = "$before" ]; then
  ok "CI pending: the PR is read once and left open in product-prs.jsonl (no new event, no gate, no wait), product_prs=1 landed=none"
else bad "sweep pending" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err") calls=$(cat "$FAKE/calls")"; fi

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN" "$(printf 'd%.0s' {1..40})"
rc="$(lp sweep)"
order="$(grep -E '^(integration-gate|locked-merge|confirm-merged)' "$FAKE/calls" | cut -d' ' -f1 | tr '\n' ' ')"
if [ "$rc" = 0 ] && [ "$order" = "integration-gate locked-merge confirm-merged " ] \
   && grep -q '^integration-gate --with-critic --rebase' "$FAKE/calls" \
   && grep -q "^locked-merge --pr 7 --head $HEAD7 --repo $LANES/$RUN_ID-land" "$FAKE/calls" \
   && head -1 "${TMP}/out" | grep -qx 'product_prs=0 landed=prod#7' \
   && [ "$(jq -r 'select(.event=="merged") | .merge_sha' "$S/product-prs.jsonl")" = "$(printf 'd%.0s' {1..40})" ] \
   && [ ! -e "$LANES/$RUN_ID-land" ] && [ ! -e "$LANES/$RUN_ID-land.lock" ] \
   && ! git -C "$R" show-ref --verify --quiet "refs/heads/$BR7"; then
  ok "CI green: integration-gate --with-critic, then locked-merge, then confirm-merged; landed=prod#7; landing lane removed"
else bad "sweep land" "rc=$rc order=$order out=$(cat "${TMP}/out") calls=$(cat "$FAKE/calls")"; fi

# The merge's deploy, a run later: still running -> recorded as pending, checked next tick.
printf '[{"name":"Post-Merge Deploy","status":"in_progress","conclusion":"","headSha":"%s"}]' "$(printf 'd%.0s' {1..40})" \
  >"$FAKE/runs-$(printf 'd%.0s' {1..40}).json"
before="$(cat "$S/product-prs.jsonl")"
rc="$(lp sweep)"
if [ "$rc" = 0 ] && grep -q 'deploy pending' "${TMP}/out" && [ "$(cat "$S/product-prs.jsonl")" = "$before" ] \
   && [ ! -e "$S/product-line-stopped.prod" ]; then
  ok "merged, deploy still running: reported pending, nothing recorded, the next tick checks again (no wait)"
else bad "deploy pending" "rc=$rc out=$(cat "${TMP}/out")"; fi
# The merge's deploy, a run later: failed -> stop the line, revert owed.
printf '[{"name":"Post-Merge Deploy","status":"completed","conclusion":"failure","headSha":"%s"}]' "$(printf 'd%.0s' {1..40})" \
  >"$FAKE/runs-$(printf 'd%.0s' {1..40}).json"
rc="$(lp sweep)"
if [ "$rc" = 0 ] && grep -q 'DEPLOY FAILED' "${TMP}/out" && [ -s "$S/product-line-stopped.prod" ] \
   && grep -q 'revert is owed' "$S/product-line-stopped.prod" && grep -q 'LINE STOPPED' "$S/journal.md" \
   && [ "$(jq -r 'select(.event=="revert-owed") | .pr' "$S/product-prs.jsonl")" = 7 ]; then
  ok "merged, deploy failed: revert-owed recorded, the line stopped, journaled"
else bad "deploy failed" "rc=$rc out=$(cat "${TMP}/out")"; fi
hold_lock "$LANES/$RUN_ID.lock"
rc="$(lp cut --repo prod --phase verify)"
[ "$rc" = 2 ] && grep -q 'line is stopped' "${TMP}/err" && grep -q 'rm ' "${TMP}/err" \
  && ok "a stopped line refuses a new lane, naming the re-arm" || bad "cut on stopped line" "rc=$rc $(cat "${TMP}/err")"
release_holders

new_repo; open_one
pr_json 7 MERGED "$HEAD7" "$GREEN" "$(printf 'e%.0s' {1..40})"
lp sweep >/dev/null
printf '[{"name":"Post-Merge Deploy","status":"completed","conclusion":"success","headSha":"%s"}]' "$(printf 'e%.0s' {1..40})" \
  >"$FAKE/runs-$(printf 'e%.0s' {1..40}).json"
rc="$(lp sweep)"
if [ "$rc" = 0 ] && grep -q 'deploy concluded success' "${TMP}/out" && [ ! -e "$S/product-line-stopped.prod" ] \
   && [ "$(jq -r 'select(.event=="deployed") | .pr' "$S/product-prs.jsonl")" = 7 ]; then
  ok "merged outside the run, deploy success: deployed, the line runs"
else bad "deploy success" "rc=$rc out=$(cat "${TMP}/out")"; fi

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$RED"
rc="$(lp sweep)"
if [ "$rc" = 0 ] && grep -q '^gh-athena pr close 7' "$FAKE/calls" && [ "$(called integration-gate)" = 0 ] && [ "$(called locked-merge)" = 0 ] \
   && [ "$(jq -r 'select(.event=="closed") | .reason' "$S/product-prs.jsonl")" = "CI red on ${HEAD7:0:12}" ] \
   && grep -q 'CLOSED, no merge' "$S/journal.md"; then
  ok "CI red: the PR is closed and journaled, with no gate and no merge"
else bad "ci red" "rc=$rc out=$(cat "${TMP}/out") calls=$(cat "$FAKE/calls")"; fi

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
echo 4 >"$FAKE/gate-rc"
rc="$(lp sweep)"
rc2="$(lp sweep)"
if [ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ "$(called integration-gate)" = 1 ] && [ "$(called locked-merge)" = 0 ] \
   && grep -q '^gh-athena pr close 7' "$FAKE/calls" && grep -q 'exit 4' "$S/journal.md" && grep -q 'Cody' "$S/journal.md" \
   && head -1 "${TMP}/out" | grep -qx 'product_prs=0 landed=none'; then
  ok "integration-gate exit 4: no merge, no retry (one gate call over two sweeps), PR closed, journal names exit 4"
else bad "exit 4" "rc=$rc rc2=$rc2 calls=$(cat "$FAKE/calls") journal=$(cat "$S/journal.md")"; fi

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
echo 3 >"$FAKE/gate-rc"
lp sweep >/dev/null
[ "$(called locked-merge)" = 0 ] && grep -q 'critic BLOCK' "$S/journal.md" && grep -q '^gh-athena pr close 7' "$FAKE/calls" \
  && ok "critic BLOCK (integration-gate exit 3): closed, journaled, no merge" || bad "critic block" "calls=$(cat "$FAKE/calls")"

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
echo 6 >"$FAKE/gate-rc"
lp sweep >/dev/null
[ "$(called locked-merge)" = 0 ] && ! grep -q 'pr close' "$FAKE/calls" && grep -q 'pr=#7 open: integration-gate exit 6' "${TMP}/out" \
  && ok "integration-gate exit 6 (gate not run): left open for the next run, nothing closed" || bad "gate 6" "out=$(cat "${TMP}/out")"

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
: >"$FAKE/gate-rebase"
lp sweep >/dev/null
newhead="$(jq -r 'select(.event=="head") | .head' "$S/product-prs.jsonl")"
if [ "$(called locked-merge)" = 0 ] && [ -n "$newhead" ] && [ "$newhead" != "$HEAD7" ] \
   && grep -q "push --force-with-lease=refs/heads/$BR7:$HEAD7 origin HEAD:refs/heads/$BR7" "$FAKE/calls" \
   && [ "$(git -C "$ORIGIN" rev-parse "$BR7" 2>/dev/null)" = "$newhead" ]; then
  ok "a rebased head is pushed with --force-with-lease and recorded; it lands only once its own CI is green"
else bad "rebased" "head=$newhead calls=$(cat "$FAKE/calls")"; fi

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
echo 8 >"$FAKE/locked-merge-rc"
lp sweep >/dev/null
[ -s "$S/product-line-stopped.prod" ] && [ "$(called confirm-merged)" = 0 ] && grep -q 'exit 8' "$S/product-line-stopped.prod" \
  && ok "locked-merge exit 8 (merge not confirmed): the line stops, nothing retried blind" || bad "lm 8" "calls=$(cat "$FAKE/calls")"

new_repo; open_one
pr_json 7 OPEN "$(printf 'f%.0s' {1..40})" "$GREEN"
lp sweep >/dev/null
[ "$(called integration-gate)" = 0 ] && grep -q 'head moved' "${TMP}/out" \
  && ok "a PR head the run did not push is never landed" || bad "head moved" "out=$(cat "${TMP}/out")"

new_repo
printf '{"event":"opened","at":"x","repo":"prod","pr":3,"url":"u","phase":"p","branch":"b","head":"h","run_id":"r"}\nnot json\n' >"$S/product-prs.jsonl"
rc="$(lp sweep)"
[ "$rc" = 2 ] && grep -q 'line 2 is not JSON' "${TMP}/err" && ok "an unreadable store line is an error naming the line, never an empty sweep" || bad "bad store" "rc=$rc $(cat "${TMP}/err")"

echo "== classification"
if grep -q $'^ai/lib/leadtime_product.rb\tlibrary' "${ROOT}/ai/guard-classification.tsv" \
   && grep -q $'^ai/lib/leadtime_product_io.rb\tlibrary' "${ROOT}/ai/guard-classification.tsv"; then
  ok "both libs are classified in ai/guard-classification.tsv"
else bad "classification" "a lib row is missing"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
