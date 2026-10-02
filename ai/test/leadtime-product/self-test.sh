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
if [ "$1 $2 $3" = "run list --workflow" ]; then f="$FAKE/base-runs.json"; [ -r "$f" ] && cat "$f" || echo '[]'; exit 0; fi
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
[ -x "\$FAKE/$t-hook" ] && "\$FAKE/$t-hook"
cat "\$FAKE/$t-out" 2>/dev/null
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
  rm -f "$FAKE"/calls "$FAKE"/pr-*.json "$FAKE"/runs-*.json "$FAKE"/base-runs.json "$FAKE"/*-rc "$FAKE"/*-out "$FAKE"/gate-* \
        "$FAKE"/pr-counter "$FAKE"/body-*
  git "${G[@]}" init -q "$d/seed"; echo one >"$d/seed/a.txt"; git -C "$d/seed" add -A; git "${G[@]}" -C "$d/seed" commit -q -m seed
  git clone -q --bare "$d/seed" "$d/origin.git"
  mkdir -p "$d/checkouts"; git clone -q "$d/origin.git" "$d/checkouts/prod"
  ORIGIN="$d/origin.git"; R="$d/checkouts/prod"; S="$d/state"; LANES="$R/.git/leadtime-lanes"; MAN="$d/manifest.json"
  mkdir -p "$S" "$LANES"
  jq -n --arg r "$R" --arg l "$LANES" --arg id "$RUN_ID" --arg s "$S" --arg idle "${IDLE-post-merge.yml}" \
    '{run_id: $id, state_dir: $s, repos: [{name: "prod", path: $r, common: ($r + "/.git"), lanes_dir: $l,
      lane: ($l + "/" + $id), lock: ($l + "/" + $id + ".lock")} + (if $idle == "" then {} else {idle_workflow: $idle} end)]}' >"$MAN"
}
hold_lock() { # <file> -- a fixture process holds an flock on <file> until released
  local fifo; fifo="$(mktemp -u -p "$TMP" held.XXXXXX)"; mkfifo "$fifo"
  ( exec 7>>"$1"; flock 7; echo held >"$fifo"; exec tail -f /dev/null ) &
  HOLDER_PIDS+=("$!")
  timeout 30 cat "$fifo" >/dev/null
}
lp() { "${BIN}" "$@" --manifest "$MAN" >"${TMP}/out" 2>"${TMP}/err"; echo $?; }
lane_commit() { # <file> -- one commit in this run's lane, carrying the lane's trailer (DND-1529)
  echo change >"$LANES/$RUN_ID/$1"; git -C "$LANES/$RUN_ID" add "$1"
  git "${G[@]}" -C "$LANES/$RUN_ID" commit -q -m "change $1" -m "Lead-time-experiment: prod verify phase"
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
echo bare >"$LANES/$RUN_ID/bare.txt"; git -C "$LANES/$RUN_ID" add bare.txt; git "${G[@]}" -C "$LANES/$RUN_ID" commit -q -m "a change with no trailer"
rc="$(lp pr --repo prod --title t --body-file "$TMP/evidence.md")"
[ "$rc" = 2 ] && grep -q 'no commit in the prod lane carries the line `Lead-time-experiment: prod verify phase`' "${TMP}/err" \
  && grep -q 'Fix:.*the squash merge keeps commit messages, not the PR body' "${TMP}/err" && ! grep -q '^gh-athena pr create' "$FAKE/calls" \
  && ok "regression: pr with no lane commit carrying the trailer: exit 2 with Fix:, nothing opened (the squash keeps commit messages, not the body)" \
  || bad "pr no trailer" "rc=$rc $(cat "${TMP}/err")"
lane_commit fix.txt
tip="$(git -C "$LANES/$RUN_ID" rev-parse HEAD)"
rc="$(lp pr --repo prod --title "speed up verify" --body-file "$TMP/evidence.md")"
rec="$(jq -c 'select(.event == "opened")' "$S/product-prs.jsonl" 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$(git -C "$ORIGIN" rev-parse leadtime/prod-verify-20261001T123000Z 2>/dev/null)" = "$tip" ] \
   && grep -q '^gh-athena git -c credential.helper= -c url.https://github.com/.insteadOf=git@github.com: push -u origin HEAD' "$FAKE/calls" \
   && grep -q '^gh-athena pr create --base main --head leadtime/prod-verify-20261001T123000Z --title speed up verify' "$FAKE/calls" \
   && [ "$(jq -r .head <<<"$rec")" = "$tip" ] && [ "$(jq -r .pr <<<"$rec")" = 7 ] && [ "$(jq -r .phase <<<"$rec")" = verify ] \
   && [ "$(cat "$FAKE/body-7.md")" = "$(printf 'evidence\n\nLead-time-experiment: prod verify phase')" ] && [ "$(stat -c %a "$S/product-prs.jsonl")" = 600 ]; then
  ok "pr: pushed as Athena (gh-athena git push), opened with gh-athena pr create (the body ends with the lane's Lead-time-experiment trailer, DND-1529), recorded (repo, pr, phase, head) in product-prs.jsonl"
else bad "pr" "rc=$rc err=$(cat "${TMP}/err") rec=$rec calls=$(cat "$FAKE/calls")"; fi

lane_commit more.txt
tip2="$(git -C "$LANES/$RUN_ID" rev-parse HEAD)"
rc="$(lp pr --repo prod --title "speed up verify" --body-file "$TMP/evidence.md")"
if [ "$rc" = 0 ] && grep -qx 'https://github.com/example/prod/pull/7' "${TMP}/out" && [ "$(grep -c '^gh-athena pr create' "$FAKE/calls")" = 1 ] \
   && [ "$(jq -r 'select(.event=="head") | .head' "$S/product-prs.jsonl")" = "$tip2" ] && [ "$(git -C "$ORIGIN" rev-parse leadtime/prod-verify-20261001T123000Z)" = "$tip2" ]; then
  ok "a second pr in the same lane pushes to the same PR and records its new head (never a duplicate PR)"
else bad "second pr" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi

echo "== experiment trailer (DND-1529)"
# The hook itself, called directly: the lane's phase, its metric when the
# meta names one, and a refusal (never a PR without a trailer) with no phase.
hook() {
  /usr/bin/ruby -e '
    require ARGV[0]
    rl = LeadTimeProduct::RepoLane.new(name: "prod")
    meta = ARGV[1].split(",").to_h { |kv| kv.split("=", 2) }
    begin
      puts LeadTimeProductIO.experiment_trailer(rl, meta)
    rescue LeadTimeProduct::Error => e
      puts "refused: #{e.message} | #{e.fix}"
    end' "${ROOT}/ai/lib/leadtime_product_io.rb" "$1"
}
[ "$(hook "phase=verify")" = "Lead-time-experiment: prod verify phase" ] \
  && ok "the hook builds 'Lead-time-experiment: <R> <phase> phase' from the lane's phase" || bad "hook phase" "$(hook "phase=verify")"
[ "$(hook "phase=integrate,metric=counter:slot_wait_s")" = "Lead-time-experiment: prod integrate counter:slot_wait_s" ] \
  && ok "... with the lane's metric when its meta names one" || bad "hook metric" "$(hook "phase=integrate,metric=counter:slot_wait_s")"
out="$(hook "branch=b")"
[[ "$out" == "refused: the prod lane: cannot build a Lead-time-experiment trailer: no phase"*"leadtime-product cut --repo prod --phase"* ]] \
  && ok "a lane with no phase is refused with a Fix:, never a PR without a trailer" || bad "hook no phase" "$out"

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

# A lane the runner reserved and nobody cut (DND-1640): its meta is the
# runner's reservation (origin, pid, run_id; no branch) and there is no
# worktree. That is "none (no lane cut)", never a cut lane.
new_repo
printf 'origin=cron\npid=4242\nrun_id=%s\n' "$RUN_ID" >"$LANES/$RUN_ID.meta"
rc="$(lp teardown)"
if [ "$rc" = 0 ] && grep -qx 'product_lane: repo=prod none (no lane cut)' "${TMP}/out" && ! grep -q ' cut,' "${TMP}/out" \
   && [ ! -e "$LANES/$RUN_ID.meta" ]; then
  ok "a reserved lane never cut (reservation meta only): none (no lane cut), exit 0"
else bad "reserved never cut" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi

# A cut lane whose branch ref is already gone (DND-1640): the lane dir and its
# meta exist, refs/heads/<branch> does not. Never read as "no lane cut".
new_repo
hold_lock "$LANES/$RUN_ID.lock"
lp cut --repo prod --phase verify >/dev/null
BRG="$(git -C "$LANES/$RUN_ID" rev-parse --abbrev-ref HEAD)"
git -C "$R" update-ref -d "refs/heads/$BRG"
rc="$(lp teardown)"
if [ "$rc" = 0 ] && grep -qx "product_lane: repo=prod lane $RUN_ID cut, worktree removed; branch $BRG already gone (nothing to keep)" "${TMP}/out" \
   && ! grep -q 'no lane cut' "${TMP}/out" && [ ! -e "$LANES/$RUN_ID" ] && [ ! -e "$LANES/$RUN_ID.meta" ]; then
  ok "a cut lane whose branch ref is gone: names the lane and the branch, never 'no lane cut'; worktree and meta removed"
else bad "branch gone" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi
release_holders

# A branch git cannot read is never reported as "already gone": a git that
# fails show-ref (exit 128) is COULD NOT TELL, kept, counted (exit 72).
new_repo
hold_lock "$LANES/$RUN_ID.lock"
lp cut --repo prod --phase verify >/dev/null
BRG="$(git -C "$LANES/$RUN_ID" rev-parse --abbrev-ref HEAD)"
git -C "$R" update-ref -d "refs/heads/$BRG"
GITSHIM="$TMP/gitshim"; mkdir -p "$GITSHIM"
# DND-1667: a guard right behind the git shim, so a shim that is missing or not
# executable fails the suite instead of reaching the real git
# (ai/lib/forge-stub-guard.sh). fsg_make, not fsg_arm: the suite runs the real
# git for its fixtures.
. "${ROOT}/ai/lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
REAL_GIT="$(command -v git)"
cat >"$GITSHIM/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = show-ref ] && { echo "fatal: shim" >&2; exit 128; }; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GITSHIM/git"
fsg_require_stubs "$GITSHIM" git
rc="$(PATH="$GITSHIM:$FSG_DIR:$PATH" lp teardown)"
if [ "$rc" = 72 ] && grep -q "COULD NOT TELL (cannot read branch $BRG" "${TMP}/out" && ! grep -q 'already gone' "${TMP}/out" \
   && [ -d "$LANES/$RUN_ID" ] && [ -e "$LANES/$RUN_ID.meta" ]; then
  ok "a branch git cannot read: COULD NOT TELL, exit 72, worktree and meta kept, never 'already gone'"
else bad "branch unreadable" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi
release_holders

# A corrupt branch ref (DND-1662). A working git answers `show-ref --verify` on
# a ref file holding garbage, an empty ref file and an unreadable one exactly
# as it answers a missing ref (exit 1), so each read as "already gone" and the
# lane was removed. Each is COULD NOT TELL: exit 72, worktree and meta kept,
# the ref file untouched for recovery.
for corrupt in garbage empty unreadable; do
  [ "$corrupt" = unreadable ] && [ "$(id -u)" = 0 ] && { ok "corrupt ref ($corrupt): skipped, root reads a mode-000 file"; continue; }
  new_repo
  hold_lock "$LANES/$RUN_ID.lock"
  lp cut --repo prod --phase verify >/dev/null
  BRG="$(git -C "$LANES/$RUN_ID" rev-parse --abbrev-ref HEAD)"
  REF="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/refs/heads/$BRG"
  [ -f "$REF" ] || bad "corrupt ref ($corrupt): fixture" "no loose ref file at $REF"
  case "$corrupt" in
    garbage) printf 'not-a-sha\n' >"$REF" ;;
    empty) : >"$REF" ;;
    unreadable) chmod 000 "$REF" ;;
  esac
  before_ref="$(stat -c '%a %s' "$REF")"
  rc="$(lp teardown)"
  after_ref="$(stat -c '%a %s' "$REF" 2>/dev/null)"
  [ "$corrupt" = unreadable ] && chmod 600 "$REF"
  if [ "$rc" = 72 ] && grep -q "COULD NOT TELL (cannot read branch $BRG" "${TMP}/out" && ! grep -q 'already gone' "${TMP}/out" \
     && grep -q "branch kept. Fix: .*show-ref --exists refs/heads/$BRG.*logs/refs/heads/$BRG" "${TMP}/out" \
     && [ -d "$LANES/$RUN_ID" ] && [ -e "$LANES/$RUN_ID.meta" ] && [ "$after_ref" = "$before_ref" ]; then
    ok "corrupt ref ($corrupt): COULD NOT TELL with a Fix: (the ref, its reflog), exit 72, lane and meta kept, ref file untouched; never 'already gone'"
  else bad "corrupt ref ($corrupt)" "rc=$rc ref=$before_ref->$after_ref out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi
  release_holders
  git -C "$R" worktree remove --force "$LANES/$RUN_ID" 2>/dev/null
done

# The same with the worktree already removed: only the meta is left.
new_repo
hold_lock "$LANES/$RUN_ID.lock"
lp cut --repo prod --phase verify >/dev/null
BRG="$(git -C "$LANES/$RUN_ID" rev-parse --abbrev-ref HEAD)"
git -C "$R" worktree remove --force "$LANES/$RUN_ID"
git -C "$R" branch -D -q "$BRG"
rc="$(lp teardown)"
if [ "$rc" = 0 ] && grep -qx "product_lane: repo=prod lane $RUN_ID cut, worktree already gone; branch $BRG already gone (nothing to keep)" "${TMP}/out" \
   && ! grep -q 'no lane cut' "${TMP}/out" && [ ! -e "$LANES/$RUN_ID.meta" ]; then
  ok "meta only, branch gone: says the worktree was already gone, never 'no lane cut'"
else bad "meta only branch gone" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi
release_holders

# A lane cut before its meta was written (a run that died between the two).
new_repo
git -C "$R" worktree add -q -b leadtime/prod-verify-nometa "$LANES/$RUN_ID" origin/main
lane_commit nometa.txt
rc="$(lp teardown)"
[ "$rc" = 72 ] && grep -q 'STRANDED: branch leadtime/prod-verify-nometa KEPT' "${TMP}/out" \
  && git -C "$R" show-ref --verify --quiet refs/heads/leadtime/prod-verify-nometa \
  && ok "a lane with no meta: its branch is read from the worktree, never 'no lane cut'; unpushed -> STRANDED" \
  || bad "no meta" "rc=$rc out=$(cat "${TMP}/out")"
new_repo
git -C "$R" worktree add -q --detach "$LANES/$RUN_ID" origin/main
rc="$(lp teardown)"
[ "$rc" = 72 ] && grep -q 'COULD NOT TELL' "${TMP}/out" && [ -d "$LANES/$RUN_ID" ] \
  && ok "a lane with no meta and no branch checked out: COULD NOT TELL, kept, counted (exit 72)" \
  || bad "no meta detached" "rc=$rc out=$(cat "${TMP}/out")"
git -C "$R" worktree remove --force "$LANES/$RUN_ID"

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

# One dead lane whose branch git cannot read never stops the reap (DND-1640):
# it is named COULD NOT TELL with its lock and meta kept for the next tick,
# and the dead lane after it is still reaped.
new_repo
BAD="run-20260930T113000Z-10"; DEAD="run-20260930T113000Z-11"
git -C "$R" worktree add -q -b leadtime/prod-tail-bad "$LANES/$BAD" origin/main
printf 'branch=leadtime/prod-tail-bad\nbootstrap=ran\n' >"$LANES/$BAD.meta"
git -C "$R" update-ref -d refs/heads/leadtime/prod-tail-bad
: >"$LANES/$BAD.lock"
git -C "$R" worktree add -q -b leadtime/prod-tail-dead "$LANES/$DEAD" origin/main
printf 'branch=leadtime/prod-tail-dead\nbootstrap=ran\n' >"$LANES/$DEAD.meta"
echo x >"$LANES/$DEAD/x.txt"; git -C "$LANES/$DEAD" add x.txt; git "${G[@]}" -C "$LANES/$DEAD" commit -q -m dead
: >"$LANES/$DEAD.lock"
rc="$(PATH="$GITSHIM:$FSG_DIR:$PATH" lp reap)"
if [ "$rc" = 0 ] && grep -q "lane=$BAD COULD NOT TELL (cannot read branch leadtime/prod-tail-bad" "${TMP}/out" \
   && [ -e "$LANES/$BAD.lock" ] && [ -e "$LANES/$BAD.meta" ] \
   && grep -q "lane=$DEAD STRANDED" "${TMP}/out" && [ ! -e "$LANES/$DEAD.lock" ] && [ ! -e "$LANES/$DEAD" ]; then
  ok "reap: an unreadable branch is COULD NOT TELL with its lock and meta kept; the next dead lane is still reaped"
else bad "reap unreadable" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi

# "Kept for the next tick" must be reachable by the next tick: two lanes whose
# branch git cannot read on tick 1 are judged on tick 2, never "no lane cut".
#   NOMETA: locked, cut before its meta was written (its branch is only in its
#           worktree's HEAD);
#   LOCKLESS: no lock (found by its directory), meta records its branch.
new_repo
NOMETA="run-20260930T113000Z-20"; LOCKLESS="run-20260930T113000Z-21"
git -C "$R" worktree add -q -b leadtime/prod-tail-nometa "$LANES/$NOMETA" origin/main
git -C "$R" update-ref -d refs/heads/leadtime/prod-tail-nometa
: >"$LANES/$NOMETA.lock"
git -C "$R" worktree add -q -b leadtime/prod-tail-lockless "$LANES/$LOCKLESS" origin/main
printf 'branch=leadtime/prod-tail-lockless\nbootstrap=ran\n' >"$LANES/$LOCKLESS.meta"
git -C "$R" update-ref -d refs/heads/leadtime/prod-tail-lockless
rc1="$(PATH="$GITSHIM:$FSG_DIR:$PATH" lp reap)"; out1="$(cat "${TMP}/out")"
kept=no; [ -d "$LANES/$NOMETA" ] && [ -e "$LANES/$NOMETA.lock" ] && [ -d "$LANES/$LOCKLESS" ] && [ -e "$LANES/$LOCKLESS.meta" ] && kept=yes
rc2="$(lp reap)"; out2="$(cat "${TMP}/out")"
if [ "$rc1" = 0 ] && [ "$(grep -c 'COULD NOT TELL (cannot read branch' <<<"$out1")" = 2 ] && [ "$kept" = yes ] \
   && [ "$rc2" = 0 ] \
   && grep -qx "product_reaped: repo=prod lane=$NOMETA lane $NOMETA cut, worktree removed; branch leadtime/prod-tail-nometa already gone (nothing to keep)" <<<"$out2" \
   && grep -qx "product_reaped: repo=prod lane=$LOCKLESS (lockless) lane $LOCKLESS cut, worktree removed; branch leadtime/prod-tail-lockless already gone (nothing to keep)" <<<"$out2" \
   && ! grep -q 'no lane cut' <<<"$out2" && [ ! -e "$LANES/$NOMETA" ] && [ ! -e "$LANES/$NOMETA.lock" ] && [ ! -e "$LANES/$LOCKLESS" ]; then
  ok "reap twice: an unreadable lane keeps its worktree, lock and meta on tick 1 and is judged on tick 2 (locked no-meta and lockless), never 'no lane cut'"
else bad "reap two ticks" "rc1=$rc1 kept=$kept out1=$out1 | rc2=$rc2 out2=$out2 err=$(cat "${TMP}/err")"; fi

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
   && grep -qx "locked-merge --pr 7 --head $HEAD7 --repo $LANES/$RUN_ID-land --wait 600 --require-idle-workflow post-merge.yml" "$FAKE/calls" \
   && head -1 "${TMP}/out" | grep -qx 'product_prs=0 landed=prod#7' \
   && [ "$(jq -r 'select(.event=="merged") | .merge_sha' "$S/product-prs.jsonl")" = "$(printf 'd%.0s' {1..40})" ] \
   && [ ! -e "$LANES/$RUN_ID-land" ] && [ ! -e "$LANES/$RUN_ID-land.lock" ] \
   && ! git -C "$R" show-ref --verify --quiet "refs/heads/$BR7" && [ "$(called teardown-stack)" = 0 ]; then
  ok "CI green: integration-gate --with-critic, then locked-merge, then confirm-merged; landed=prod#7; landing lane removed (its stack is locked-merge's to tear down)"
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
echo 3 >"$FAKE/gate-rc"; echo "critic-review: VERDICT BLOCK for $HEAD7 — findings: correctness" >"$FAKE/gate-out"
lp sweep >/dev/null
[ "$(called locked-merge)" = 0 ] && grep -q 'critic BLOCK' "$S/journal.md" && grep -q '^gh-athena pr close 7' "$FAKE/calls" \
  && ok "a recorded critic BLOCK (integration-gate exit 3): closed, journaled, no merge" || bad "critic block" "calls=$(cat "$FAKE/calls")"

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
echo 3 >"$FAKE/gate-rc"; echo "critic-review: judge FAILED OPEN (model error)" >"$FAKE/gate-out"
lp sweep >/dev/null
[ "$(called locked-merge)" = 0 ] && ! grep -q 'pr close' "$FAKE/calls" && grep -q 'pr=#7 open: integration-gate exit 3 with no recorded critic BLOCK' "${TMP}/out" \
  && ok "exit 3 with no recorded BLOCK (the judge failed open): left open, never closed" || bad "exit 3 no block" "out=$(cat "${TMP}/out")"

# The repo's merge bar: its idle post-merge workflow.
IDLE="" new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
lp sweep >/dev/null
[ "$(called integration-gate)" = 0 ] && [ "$(called locked-merge)" = 0 ] && grep -q 'declares no idle_workflow' "${TMP}/out" \
  && grep -q 'not landed: the repo declares no idle_workflow' "$S/journal.md" \
  && ok "a repo that declares no idle_workflow lands nothing (deny by default), journaled with its Fix" || bad "idle undeclared" "out=$(cat "${TMP}/out")"

IDLE=none new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
lp sweep >/dev/null
grep -qx "locked-merge --pr 7 --head $HEAD7 --repo $LANES/$RUN_ID-land --wait 600" "$FAKE/calls" && ! grep -q 'run list --workflow' "$FAKE/calls" \
  && ok "idle_workflow none: locked-merge without the idle flag, and no base-deploy read" || bad "idle none" "calls=$(cat "$FAKE/calls")"

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
echo '[{"status":"completed","conclusion":"failure","headSha":"0123456789abcdef0123456789abcdef01234567"}]' >"$FAKE/base-runs.json"
lp sweep >/dev/null
[ "$(called integration-gate)" = 0 ] && [ "$(called locked-merge)" = 0 ] && grep -q 'concluded failure' "$S/product-line-stopped.prod" \
  && grep -q '^product_line=STOPPED prod: ' "${TMP}/out" \
  && ok "the base's post-merge deploy failed: the line stops before any gate or merge, and the sweep prints product_line=STOPPED" \
  || bad "base deploy failed" "out=$(cat "${TMP}/out") calls=$(cat "$FAKE/calls")"

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN" "$(printf 'd%.0s' {1..40})"
echo "WARN base deploy 99 for abc concluded failure; merging anyway: no ratified rule holds a merge on a failed deploy" >"$FAKE/locked-merge-out"
lp sweep >/dev/null
head -1 "${TMP}/out" | grep -qx 'product_prs=0 landed=prod#7' && grep -q 'WARN base deploy' "$S/product-line-stopped.prod" \
  && ok "locked-merge's WARN base deploy: the landing is recorded and the line stops" || bad "merge warn" "out=$(cat "${TMP}/out")"

new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
echo 6 >"$FAKE/gate-rc"
lp sweep >/dev/null
[ "$(called locked-merge)" = 0 ] && ! grep -q 'pr close' "$FAKE/calls" && grep -q 'pr=#7 open: integration-gate exit 6' "${TMP}/out" \
  && grep -q "^teardown-stack --worktree $LANES/$RUN_ID-land --parked" "$FAKE/calls" && [ ! -e "$LANES/$RUN_ID-land" ] \
  && ok "integration-gate exit 6 (gate not run): left open for the next run, nothing closed; the landing lane's stack torn down" || bad "gate 6" "out=$(cat "${TMP}/out") calls=$(cat "$FAKE/calls")"

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

# A landing branch git cannot read (DND-1677). The landing lane's branch is
# deleted only when it can be read; a ref holding garbage was skipped with no
# word, so it accumulated unseen. It is KEPT, named with a Fix: (the ref and its
# reflog), and counted on the summary line. The landing itself still counts.
new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN" "$(printf 'd%.0s' {1..40})"
REF7="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/refs/heads/$BR7"
printf '#!/usr/bin/env bash\nprintf "not-a-sha\\n" >"%s"\n' "$REF7" >"$FAKE/locked-merge-hook"; chmod +x "$FAKE/locked-merge-hook"
rc="$(lp sweep)"
if [ "$rc" = 0 ] && head -1 "${TMP}/out" | grep -qx 'product_prs=0 landed=prod#7 unreadable_branches=1' \
   && grep -q "pr=#7 landed .*; landing branch $BR7 KEPT: COULD NOT TELL (cannot read branch $BR7" "${TMP}/out" \
   && grep -q "Fix: .*show-ref --exists refs/heads/$BR7.*logs/refs/heads/$BR7" "${TMP}/out" \
   && [ "$(cat "$REF7")" = not-a-sha ] && [ ! -e "$LANES/$RUN_ID-land" ] && [ ! -e "$LANES/$RUN_ID-land.meta" ]; then
  ok "an unreadable landing branch after a landing: KEPT, named with a Fix: (ref, reflog), counted unreadable_branches=1; never skipped silently"
else bad "landing branch unreadable" "rc=$rc ref=$(cat "$REF7" 2>/dev/null) out=$(cat "${TMP}/out") err=$(cat "${TMP}/err")"; fi
rm -f "$FAKE/locked-merge-hook"

# The same class before the landing lane is cut: a local landing branch git
# cannot read is never read as absent (which tried `worktree add -b` and failed
# with git's own words). Nothing is gated, the ref is untouched, it is named
# with its Fix: and counted.
new_repo; open_one
pr_json 7 OPEN "$HEAD7" "$GREEN"
REF7="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/refs/heads/$BR7"
mkdir -p "$(dirname -- "$REF7")"; printf 'not-a-sha\n' >"$REF7"
rc="$(lp sweep)"
if [ "$rc" = 0 ] && head -1 "${TMP}/out" | grep -qx 'product_prs=1 landed=none unreadable_branches=1' \
   && grep -q "pr=#7 open: local branch $BR7 KEPT: COULD NOT TELL (cannot read branch $BR7" "${TMP}/out" \
   && grep -q "Fix: .*logs/refs/heads/$BR7" "${TMP}/out" \
   && [ "$(called integration-gate)" = 0 ] && [ "$(cat "$REF7")" = not-a-sha ] && [ ! -e "$LANES/$RUN_ID-land" ]; then
  ok "an unreadable local landing branch before the lane is cut: KEPT, named with a Fix:, counted; no gate, never read as absent"
else bad "local branch unreadable" "rc=$rc out=$(cat "${TMP}/out") err=$(cat "${TMP}/err") calls=$(cat "$FAKE/calls")"; fi

new_repo
printf '{"event":"opened","at":"x","repo":"prod","pr":3,"url":"u","phase":"p","branch":"b","head":"h","run_id":"r"}\nnot json\n' >"$S/product-prs.jsonl"
rc="$(lp sweep)"
[ "$rc" = 3 ] && grep -q 'line 2 is not JSON' "${TMP}/err" && ok "an unreadable store line is could-not-look (exit 3) naming the line, never an empty sweep" || bad "bad store" "rc=$rc $(cat "${TMP}/err")"

echo "== cut --metric (DND-1529)"
new_repo
hold_lock "$LANES/$RUN_ID.lock"
rc="$(lp cut --repo prod --phase integrate --metric "check:self-test: x/y")"
[ "$rc" = 0 ] && grep -qx 'trailer=Lead-time-experiment: prod integrate check:self-test: x/y' "${TMP}/out" \
  && grep -qx 'metric=check:self-test: x/y' "$LANES/$RUN_ID.meta" \
  && ok "cut --metric: the lane's meta records it, and cut prints the trailer line its commits carry" || bad "cut --metric" "rc=$rc $(cat "${TMP}/out" "${TMP}/err")"
new_repo
hold_lock "$LANES/$RUN_ID.lock"
rc="$(lp cut --repo prod --phase verify --metric " ")"
[ "$rc" = 2 ] && grep -q 'no metric' "${TMP}/err" && [ ! -e "$LANES/$RUN_ID" ] \
  && ok "cut with a blank --metric: exit 2 before any lane is cut" || bad "cut empty metric" "rc=$rc $(cat "${TMP}/err")"

echo "== classification"
if grep -q $'^ai/lib/leadtime_product.rb\tlibrary' "${ROOT}/ai/guard-classification.tsv" \
   && grep -q $'^ai/lib/leadtime_product_io.rb\tlibrary' "${ROOT}/ai/guard-classification.tsv"; then
  ok "both libs are classified in ai/guard-classification.tsv"
else bad "classification" "a lib row is missing"; fi

# DND-1667: no git call may have fallen through past its shim.
if fsg_verify; then ok "no git call fell through past its shim (DND-1667)"
else bad "no git call fell through past its shim (DND-1667)" "see the forge-stub-guard FAIL above"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
