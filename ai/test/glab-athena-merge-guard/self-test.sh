#!/usr/bin/env bash
# Self-test for the glab-athena merge guard (DND-742).
#
# The defect this pins: glab-athena ran every command as-is. `glab-athena mr
# merge` with no --sha, or while the head pipeline was running or red, went to
# GitLab, and so did `glab-athena api` merges (REST PUT …/merge, a merge-train
# POST, GraphQL mergeRequestAccept). The wrapper now requires, on every merge
# path it lets through, a pin of the MR's exact head SHA and a head pipeline
# that PASSED on that head; the REST merge route, mergeRequestAccept and `mcp
# serve` are refused outright. Since DND-1845 both merge paths also need
# integration-gate's sealed receipt for the head (the R cases), read from a
# fixture checkout of the MR's project. Since DND-1941 a merge also needs auto-
# merge off by name (the AM cases), a target tip that is not RED by its
# pipelines (P) or content (GS), and API ref writes are refused (W, GR).
# Design and measurements: the header of ai/lib/glab-merge-guard.sh. Old-vs-new
# evidence and mutation results: SABOTAGE_RECORDS.md next to this file.
#
# NO NETWORK, EVER. `glab` is a stub on PATH. It answers the guard's seven reads
# (`mr view … -F json`, `api projects/<p>/merge_requests/<iid>`, `api
# projects/<p>/repository/commits/<sha>`, `api projects/<p>/repository/branches/
# <branch>`, `api projects/<p>/merge_requests/<iid>/versions`, `api
# projects/<p>/pipelines?sha=…&ref=…`, `api projects/<p>/repository/merge_base?…`)
# from fixture files, and records every
# OTHER call as an exec in a separate log. Every refusal case asserts that log
# is empty, i.e. nothing that could merge reached glab.
#
# Gated: ai/bin/harness-gate runs every tracked **/self-test.sh.
#
# Run against another copy of the wrapper (old-vs-new evidence) with
#   GLAB_ATHENA_UNDER_TEST=/path/to/glab-athena bash ai/test/glab-athena-merge-guard/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
WRAPPER="${GLAB_ATHENA_UNDER_TEST:-${AI_DIR}/bin/glab-athena}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- hermetic environment ---------------------------------------------------
FAKE_TOKEN="glpat-SELFTESTFAKETOKEN0000"
printf '%s\n' "${FAKE_TOKEN}" > "${TMP}/token"; chmod 600 "${TMP}/token"
export GITLAB_ATHENA_TOKEN_FILE="${TMP}/token"
unset GLAB_ATHENA_MERGE_DRY_RUN GLAB_ATHENA_GIT_DRY_RUN
# DND-1939: a merge glab-athena runs is confirmed with confirm-merged and
# recorded as merge.landed. Never into the machine's real store, and with no
# wait between confirm tries (the cases stage the forge's answer up front).
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry" GLAB_ATHENA_LANDING_TRIES=2 GLAB_ATHENA_LANDING_SLEEP=0
unset ATHENA_UNIT
# DND-1936: glab-athena resolves the bot from the project's (host, namespace)
# before the merge guard runs. A fixture map gives every (host, namespace) the
# receipt-project cases below use the one synthetic bot, so each case still
# reaches the guard it tests; an empty fixture overlay keeps this machine's own
# overlay out. The identity refusals have their own suites
# (ai/test/forge-identity, ai/test/glab-athena).
export ATHENA_FORGE_IDENTITIES_FILE="${TMP}/forge-identities.json"
jq -n --arg t "${TMP}/token" '{kind:"athena-forge-identities", schema:1, identities:
  [["gitlab.com","example-group"], ["gitlab.com","x"], ["gitlab.com","someone"], ["evil-gitlab.com","example-group"],
   ["gitlabxcom","example-group"], ["other.example.com","example-group"], ["gitlab.com","cjpoll"],
   ["gitlab.com","athena-ai-harness"], ["gitlab.com","example-moved"]]
  | map({host:.[0], namespace:.[1], bot:"synthetic-merge-bot", token_file:$t, refresh:"group_service_account"})}' \
  > "${ATHENA_FORGE_IDENTITIES_FILE}"
export ATHENA_PRIVATE_ROOT="${TMP}/empty-overlay"; mkdir -p "${ATHENA_PRIVATE_ROOT}/overlay"; chmod 700 "${ATHENA_PRIVATE_ROOT}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${ATHENA_PRIVATE_ROOT}/athena-overlay.json"

FX="${TMP}/fx"; mkdir -p "${FX}" "${TMP}/bin"
export STUB_FX="${FX}" STUB_READS="${TMP}/reads.log" STUB_EXECS="${TMP}/execs.log"

# The stub glab. A read the case staged answers from <fx>/<kind>.out (stdout),
# .err (stderr) and .rc (exit code, default 0). Anything else is an EXEC:
# logged to STUB_EXECS and answered "stub: ran …".
cat > "${TMP}/bin/glab" <<'STUB'
#!/usr/bin/env bash
[ "${GITLAB_TOKEN:-}" = "glpat-SELFTESTFAKETOKEN0000" ] || { echo "stub: GITLAB_TOKEN not the Athena token" >&2; exit 97; }
answer() {
  local k="$1" rc=0
  # No fixture: not one of this case's reads (a user's own GET of the same
  # shape). It falls through to an exec, so a guard read the case forgot to
  # stage shows up as an exec and fails the case loudly.
  [ -f "${STUB_FX}/$k.out" ] || [ -f "${STUB_FX}/$k.rc" ] || return 0
  printf '%s\n' "$*" >> "${STUB_READS}"
  # DND-1939: once something ran (the merge), a staged <kind>.after.out /
  # .after.rc / .after.err is the forge's answer: the MR as merged, or a
  # read that fails.
  if [ -s "${STUB_EXECS}" ] && { [ -f "${STUB_FX}/$k.after.out" ] || [ -f "${STUB_FX}/$k.after.rc" ]; }; then
    [ -f "${STUB_FX}/$k.after.err" ] && cat "${STUB_FX}/$k.after.err" >&2
    [ -f "${STUB_FX}/$k.after.out" ] && cat "${STUB_FX}/$k.after.out"
    exit "$(cat "${STUB_FX}/$k.after.rc" 2>/dev/null || echo 0)"
  fi
  [ -f "${STUB_FX}/$k.rc" ] && rc="$(cat "${STUB_FX}/$k.rc")"
  [ -f "${STUB_FX}/$k.err" ] && cat "${STUB_FX}/$k.err" >&2
  [ -f "${STUB_FX}/$k.out" ] && cat "${STUB_FX}/$k.out"
  exit "$rc"
}
all="$*"
case "$all" in
  "mr view "*"-F json"|"mr view -F json") answer mrview "$all" ;;
esac
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[^\ ]+/merge_requests/[0-9]+$ ]]; then answer mrapi "$all"; fi
if [[ "$all" =~ ^api\ projects/[0-9]+/repository/commits/[0-9a-f]+$ ]]; then answer commit "$all"; fi
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[0-9]+/repository/branches/[^\ ]+$ ]]; then answer branch "$all"; fi
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[0-9]+/merge_requests/[0-9]+/versions$ ]]; then answer versions "$all"; fi
# DND-1941: the target tip's own pipelines, and the forge's merge base of the
# tip and the head (asked only when the head is not in the local store).
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[0-9]+/pipelines\?sha=[0-9a-f]+\&ref=[^\ ]+\&per_page=100$ ]]; then answer pipes "$all"; fi
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[0-9]+/repository/merge_base\?refs%5B%5D=[0-9a-f]+\&refs%5B%5D=[0-9a-f]+$ ]]; then answer mergebase "$all"; fi
# DND-1939: the landing record's project read (its default branch). Before the
# visibility catch-all, which matches the same path; with no project fixture
# staged it falls through to that catch-all.
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[0-9]+$ ]]; then answer project "$all"; fi
# The outbound scan's visibility read (DND-1938), run on an api write that
# carries a field (a train car's `-f sha=`) once the merge guard has passed it.
# Answered "private": the project the merge guard judges is the work-shaped
# fixture, and the scan has its own suite (ai/test/glab-athena-outbound). It is
# logged apart from STUB_READS, which counts the merge guard's own reads.
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?(projects|groups)/[^/\ ]+$ ]]; then
  printf '%s\n' "$all" >> "${STUB_READS}.vis"; echo '{"visibility":"private"}'; exit 0
fi
printf '%s\n' "$all" >> "${STUB_EXECS}"
echo "stub: ran $all"
# DND-1939: a staged exec.rc is the exit of what ran (a merge glab refused).
[ -f "${STUB_FX}/exec.rc" ] && exit "$(cat "${STUB_FX}/exec.rc")"
exit 0
STUB
chmod +x "${TMP}/bin/glab"
# DND-1647: a guard stands behind every gh/glab stub on PATH, so a stub
# that is missing or not executable fails the suite instead of reaching the
# real CLI (ai/lib/forge-stub-guard.sh).
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
fsg_require_stubs "${TMP}/bin" glab
export PATH="${TMP}/bin:${PATH}"

# Shapes measured on example-group/example-app !4242 (2026-09-26): the open MR's head
# pipeline is a merged-results pipeline on refs/merge-requests/4242/merge, whose
# commit's parents are [target, head].
HEAD_SHA="4cc5665184c838efca81646c61b461e72e6ea145"
MERGE_SHA="e8feb98c3218bbc35a684bcd047ada5d94e0f176"
TARGET_SHA="fb181a4274258faf3b2a7ba8e6b438e0c490a6e9"
OTHER_SHA="0e134e88662690fe8edde401fa79bf44aa688eec"

# ---- the local checkout the receipt check reads (DND-1845) ------------------
# Every merge glab-athena lets through now also needs integration-gate's sealed
# receipt for the MR's exact head, read from the git common dir of the checkout
# the wrapper runs in. The fixture is a checkout of the MR's project (origin is
# never contacted) that DECLARES NO GATE: a GitLab project gated with a
# caller-supplied `--gate` is still gated. Commits:
#   OLD_TIP  main's parent        TIP_FX  main's tip (the target branch tip)
#   SIDE_FX  a sibling of TIP_FX, not an ancestor of it
# Receipts are sealed under a private key in the suite's temp dir (DND-1814).
export ATHENA_SECRETS_ROOT="${TMP}/secrets"
REPO_FX="${TMP}/example-app"
git init -q -b main "${REPO_FX}"
rfx() { git -C "${REPO_FX}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
rfx remote add origin git@gitlab.com:example-group/example-app.git
echo one > "${REPO_FX}/README"; rfx add README; rfx commit -q -m one
OLD_TIP="$(rfx rev-parse HEAD)"
echo two >> "${REPO_FX}/README"; rfx commit -q -am two
TIP_FX="$(rfx rev-parse HEAD)"
rfx checkout -q -b side "${OLD_TIP}"; echo side >> "${REPO_FX}/README"; rfx commit -q -am side
SIDE_FX="$(rfx rev-parse HEAD)"
rfx checkout -q main
COMMON_FX="$(git -C "${REPO_FX}" rev-parse --path-format=absolute --git-common-dir)"
STORE_FX="${COMMON_FX}/integration-receipts"
cd "${REPO_FX}" || exit 2

reset_fx() { rm -f "${FX}"/* "${STUB_READS}" "${STUB_EXECS}"; rm -rf "${STORE_FX}"; : > "${STUB_READS}"; : > "${STUB_EXECS}"; }

# mr_json <status> [pipeline sha] [pipeline ref] [head] [iid] -> an MR object.
mr_json() {
  printf '{"iid":%s,"project_id":7000001,"sha":"%s","target_branch":"main","web_url":"https://gitlab.com/example-group/example-app/-/merge_requests/%s","head_pipeline":{"id":9000000001,"sha":"%s","ref":"%s","status":"%s"}}\n' \
    "${5:-4242}" "${4:-${HEAD_SHA}}" "${5:-4242}" "${2:-${MERGE_SHA}}" "${3:-refs/merge-requests/4242/merge}" "$1"
}
# branch_is <sha> : the forge reports <sha> as the tip of the MR's target branch.
branch_is() { printf '{"name":"main","commit":{"id":"%s"}}\n' "$1" > "${FX}/branch.out"; }
# plant <head> <base> [verdict] [jq edit] : a receipt as integration-gate
# writes it, sealed. The optional jq edit adjusts fields before the seal.
plant() {
  mkdir -p "${STORE_FX}"
  jq -n --arg h "$1" --arg b "$2" --arg v "${3:-pass}" \
    '{schema:"integration-receipt/1", verdict:$v, head:$h, target_ref:"origin/main", base:$b,
      gate:"cd backend && bin/prep-commit.sh", gate_source:"caller-supplied; no gate declared on origin/main",
      owner_approval:null, recorded_at:"2026-10-03T00:00:00Z"}' | jq "${4:-.}" > "${STORE_FX}/$1.json"
  "${AI_DIR}/bin/receipt-seal" seal --kind integration "${STORE_FX}/$1.json"
}
# green_fx : every read answers "passed merged-results pipeline on the head",
# and integration-gate passed that head against the target tip.
green_fx() {
  mr_json success > "${FX}/mrview.out"
  mr_json success > "${FX}/mrapi.out"
  printf '{"id":"%s","parent_ids":["%s","%s"]}\n' "${MERGE_SHA}" "${TARGET_SHA}" "${HEAD_SHA}" > "${FX}/commit.out"
  branch_is "${TIP_FX}"
  printf '[{"id":1,"head_commit_sha":"%s"}]\n' "${HEAD_SHA}" > "${FX}/versions.out"
  tip_pipes success
  # The forge's merge base of the tip and the (non-local) head: not the tip, so
  # the head does not contain it. Read only when the tip is red.
  printf '{"id":"%s"}\n' "${OLD_TIP}" > "${FX}/mergebase.out"
  plant "${HEAD_SHA}" "${TIP_FX}"
}
# pipe <id> <status> [source] [sha] [ref] : one pipeline object, as GitLab's
# `projects/<id>/pipelines` lists it.
pipe() {
  printf '{"id":%s,"sha":"%s","ref":"%s","status":"%s","source":"%s","web_url":"https://gitlab.com/example-group/example-app/-/pipelines/%s"}' \
    "$1" "${4:-${TIP_FX}}" "${5:-main}" "$2" "${3:-push}" "$1"
}
# tip_pipes <status> [ref] : the target tip has one main pipeline, <status>.
tip_pipes() { printf '[%s]\n' "$(pipe 8000000001 "$1" push "${TIP_FX}" "${2:-main}")" > "${FX}/pipes.out"; }
# pipes_are <pipe json>... : the tip's pipelines, newest first (GitLab's order).
pipes_are() { local IFS=,; printf '[%s]\n' "$*" > "${FX}/pipes.out"; }
# nogate_fx : green, but integration-gate never passed the head (no receipt).
nogate_fx() { green_fx; rm -rf "${STORE_FX}"; }
status_fx() { green_fx; mr_json "$1" > "${FX}/mrview.out"; mr_json "$1" > "${FX}/mrapi.out"; }
fx() { printf '%s' "$2" > "${FX}/$1.out"; printf '%s' "${3:-0}" > "${FX}/$1.rc"; [ -z "${4:-}" ] || printf '%s\n' "$4" > "${FX}/$1.err"; }

run() { OUT="$("${WRAPPER}" "$@" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"; }
execs() { cat "${STUB_EXECS}"; }
reads() { cat "${STUB_READS}"; }
refused() { [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"Fix:"* ]] && [ ! -s "${STUB_EXECS}" ]; }
# ran_once <args…> : the command reached glab exactly once, as given.
ran_once() { [ "${RC}" = 0 ] && [ "$(execs)" = "$*" ]; }
detail()  { printf 'rc=%s out=%q err=%q reads=%q execs=%q' "${RC}" "${OUT}" "${ERR}" "$(reads)" "$(execs)"; }

# expect_refused <id> <label> <must-contain> <args…>
expect_refused() {
  local id="$1" label="$2" want="$3"; shift 3
  run "$@"
  if refused && [[ "${ERR}" == *"${want}"* ]]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want refusal naming '${want}')" "$(detail)"; fi
}
# run_guard <args…> : the merge guard itself (glmg_guard, sourced), for the
# cases the wrapper refuses before the guard runs (DND-1936). Sets OUT/RC/ERR
# like run; a pass prints GUARD-PASSED.
run_guard() {
  OUT="$(bash -c '. "$1" || exit 99; shift; glmg_guard "$@"; echo GUARD-PASSED' _ "${AI_DIR}/lib/glab-merge-guard.sh" "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}
# guard_refused <id> <label> <must-contain> <args…> / guard_passed <id> <label> <args…>
guard_refused() {
  local id="$1" label="$2" want="$3"; shift 3
  run_guard "$@"
  if refused && [[ "${ERR}" == *"${want}"* ]]; then ok "${id}. ${label} (guard)"
  else bad "${id}. ${label} (guard; want refusal naming '${want}')" "$(detail)"; fi
}
guard_passed() {
  local id="$1" label="$2"; shift 2
  run_guard "$@"
  if [ "${RC}" = 0 ] && [ "${OUT}" = GUARD-PASSED ] && [ ! -s "${STUB_EXECS}" ]; then ok "${id}. ${label} (guard)"
  else bad "${id}. ${label} (guard; want a pass)" "$(detail)"; fi
}
# expect_ran <id> <label> <reads: none|any> <args…>
expect_ran() {
  local id="$1" label="$2" rd="$3"; shift 3
  run "$@"
  if ran_once "$@" && { [ "${rd}" = any ] || [ ! -s "${STUB_READS}" ]; }; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want one exec, reads=${rd})" "$(detail)"; fi
}

echo "glab-athena merge-guard self-test"
echo "wrapper: ${WRAPPER}"
echo

echo "--- mr merge: the pin and the passed head pipeline ---"
reset_fx; green_fx
expect_refused M1 "mr merge with no --sha is refused, naming the head" "${HEAD_SHA}" mr merge 4242 --auto-merge=false --yes
reset_fx; green_fx
expect_ran M2 "mr merge --sha <head> with a passed merged-results pipeline runs" any mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" == *"repository/commits/${MERGE_SHA}"* ]]; then ok "M2b. the merged-results commit was read to tie the pipeline to the head"
else bad "M2b. merged-results commit read" "$(detail)"; fi
reset_fx; green_fx
expect_refused M3 "mr merge --sha <not the head> is refused" "not the MR's head" mr merge 4242 --auto-merge=false --sha "${OTHER_SHA}" --yes
reset_fx; status_fx running
expect_refused M4 "a running head pipeline is refused" "'running', not success" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; status_fx failed
expect_refused M5 "a failed head pipeline is refused" "'failed', not success" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
printf '{"iid":4242,"project_id":7000001,"sha":"%s","head_pipeline":null}\n' "${HEAD_SHA}" > "${FX}/mrview.out"
expect_refused M6 "no head pipeline is refused" "has no head pipeline" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; mr_json success "${HEAD_SHA}" "feature-branch" > "${FX}/mrview.out"
expect_ran M7 "a passed pipeline ON the head (branch pipeline) runs" any mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" != *"repository/commits"* ]]; then ok "M7b. no commit read when the pipeline sha is the head"
else bad "M7b. unexpected commit read" "$(detail)"; fi
reset_fx; green_fx
printf '{"id":"%s","parent_ids":["%s","%s"]}\n' "${MERGE_SHA}" "${TARGET_SHA}" "${OTHER_SHA}" > "${FX}/commit.out"
expect_refused M8 "a merged-results commit whose 2nd parent is not the head is refused" "do not end in head" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; mr_json success "216e40abc081b59f341d2d1de2fdd12facee7772" "refs/merge-requests/4242/train" > "${FX}/mrview.out"
expect_refused M9 "a merge-train head pipeline cannot be tied and is refused" "cannot be tied" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; fx commit '' 1 'glab: 404 Commit Not Found'
expect_refused M10 "a failed commit read is refused" "could not read the merged-results commit" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; fx mrview '' 1 'glab: 404 Not Found'
expect_refused M11 "a failed MR read is refused" "could not read the MR" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_refused M12 "mr accept (merge's alias) with no --sha is refused" "no sha was given" mr accept 4242 --auto-merge=false --yes
reset_fx; green_fx
expect_refused M13 "--repo before the subcommand, no --sha, is refused" "no sha was given" --repo example-group/example-app mr merge 4242 --auto-merge=false --yes
reset_fx; green_fx
expect_refused M13b "mr -R <repo> merge, no --sha, is refused" "no sha was given" mr -R example-group/example-app merge 4242 --auto-merge=false
if [[ "$(reads)" == *"mr view 4242 -R example-group/example-app -F json"* ]]; then ok "M13c. the MR is read in the -R project"
else bad "M13c. -R carried into the read" "$(detail)"; fi
reset_fx; green_fx
expect_ran M14 "--sha=<head> with combined short flags runs" any mr merge 4242 --auto-merge=false "--sha=${HEAD_SHA}" -sdy
reset_fx; green_fx
expect_refused M15 "an unknown mr merge flag is refused" "--bogus" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --bogus
reset_fx; green_fx
expect_refused M16 "--sha given twice is refused" "2 times" mr merge 4242 --auto-merge=false --sha "${OTHER_SHA}" --sha "${HEAD_SHA}"
reset_fx; green_fx
expect_refused M17 "mr merge --help gets no short-circuit (judged, refused with no pin)" "no sha was given" mr merge --auto-merge=false --help
reset_fx; green_fx
expect_refused M23 "--help then --help=false (pflag: last wins, so it merges) is refused" "no sha was given" mr merge 4242 --auto-merge=false --help --help=false --yes
reset_fx; green_fx
expect_refused M24 "-h then --help=0 is refused" "no sha was given" mr merge 4242 --auto-merge=false -h --help=0 --yes
reset_fx; green_fx
expect_refused M18 "an unknown flag before the subcommand is refused" "comes before the subcommand" --bogus x mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}"
reset_fx; green_fx; printf '{"iid":4242,"sha":"%s","head_pipeline":{"status":"success"}}\n' "${HEAD_SHA}" > "${FX}/mrview.out"
expect_refused M19 "an MR read with no project_id is refused" "no usable sha" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}"
reset_fx; green_fx
printf '{"id":"%s","parent_ids":["%s"]}\n' "${MERGE_SHA}" "${HEAD_SHA}" > "${FX}/commit.out"
expect_refused M20 "a merged-results commit with one parent is refused" "do not end in head" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}"
reset_fx; green_fx
expect_ran M21 "no selector: the current branch's MR, pinned and green, runs" any mr merge --auto-merge=false --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" == *"mr view -F json"* ]]; then ok "M21b. the current-branch MR was read"; else bad "M21b. current-branch read" "$(detail)"; fi
reset_fx; green_fx
expect_refused M22 "mr merge -R<repo> attached, no --sha, is refused" "no sha was given" mr merge -Rexample-group/example-app 4242 --auto-merge=false
# A flag cluster before the subcommand whose meaning differs between the
# guard's flag table and cobra's command walk (critic round 3). Measured, glab
# 1.112: `glab mr -ym merge x --help` prints mr merge's help, so cobra routes
# `mr -ym merge 4242` to merge (-ym is dropped from the walk), and merge's pflag
# parse then reads -y as yes and -m as the message 4242: the current branch's MR
# merges with no pin. The mr-merge table instead reads `m` as taking `merge`.
for cl in -ym -sm -dm -rm -hm; do
  reset_fx; green_fx
  expect_refused "M25${cl}" "mr ${cl} merge 4242 (a cluster before the subcommand) is refused" "before the subcommand" mr "${cl}" merge 4242
done
reset_fx; green_fx
expect_refused M26 "mr -h merge 4242 --sha <head> (help before the subcommand) is refused" "before the subcommand" mr -h merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_refused M27 "-y before mr, then merge, is refused" "before the subcommand" -y mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}"
reset_fx; green_fx
expect_refused M28 "a cluster before mr merge, with a pin, is still refused" "before the subcommand" mr -ym merge 4242 --auto-merge=false --sha "${HEAD_SHA}"
# The class, not the listed sites: EVERY short flag, every two-letter cluster of
# them, and every long flag in the tables, placed before `merge` and before
# `mr`, must be refused. Only -R/--repo forms may sit there (M29-M31).
M32_BAD=""
M32_SHORT="m d s y h r X x"
M32_WORDS=""
for a in ${M32_SHORT}; do
  M32_WORDS+=" -${a}"
  for b in ${M32_SHORT} R; do M32_WORDS+=" -${a}${b}"; done
done
M32_WORDS+=" --message --sha --squash-message --auto-merge --when-pipeline-succeeds --rebase --remove-source-branch --squash --yes --help --help=false --sha=x --bogus -- -"
for w in ${M32_WORDS}; do
  for shape in pre-merge pre-mr; do
    reset_fx; green_fx
    if [ "${shape}" = pre-merge ]; then run mr "${w}" merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
    else run "${w}" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes; fi
    refused || M32_BAD+=" ${shape}:${w}"
  done
done
if [ -z "${M32_BAD}" ]; then ok "M32. every non-repo flag spelling before the subcommand is refused ($(wc -w <<<"${M32_WORDS}") spellings x 2 shapes)"
else bad "M32. flag spellings before the subcommand that were not refused" "${M32_BAD}"; fi
reset_fx; green_fx
expect_ran M29 "--repo <repo> before the subcommand, pinned and green, runs" any --repo example-group/example-app mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_ran M30 "mr --repo=<repo> merge, pinned and green, runs" any mr --repo=example-group/example-app merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_ran M31 "mr -R<repo> merge (attached), pinned and green, runs" any mr -Rexample-group/example-app merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes

echo
echo "--- api: the REST merge route is refused outright ---"
# DND-1936: glab-athena keys the bot on the endpoint's project, so a numeric
# project id, a dot segment, %-encoding past the project path and an absolute
# URL are refused by the identity map before the guard runs (A3, A7, A9, A12).
# Every other route case names the project by path and reaches the guard;
# A3g, A7g, A9g and A12g run the guard itself on the original shapes, so its
# normalisation stays covered.
reset_fx; green_fx
expect_refused A1 "PUT projects/:id/merge_requests/<iid>/merge" "REST merge" api -X PUT "projects/:id/merge_requests/4242/merge"
reset_fx
expect_refused A2 "--method=put, encoded project, query string" "REST merge" api --method=put "projects/example-group%2Fexample-app/merge_requests/4242/merge?sha=${HEAD_SHA}"
reset_fx
expect_refused A3 "-XPUT full URL with api/v4 (identity: absolute URL)" "absolute URL" api -XPUT "https://gitlab.com/api/v4/projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
guard_refused A3g "-XPUT full URL with api/v4" "REST merge" api -XPUT "https://gitlab.com/api/v4/projects/1/merge_requests/2/merge"
reset_fx
expect_refused A4 "no method, a field -> POST" "REST merge" api "projects/example-group%2Fexample-app/merge_requests/2/merge" -f "sha=${HEAD_SHA}"
reset_fx
expect_refused A5 "GET with a method-override header" "REST merge" api -H "X-HTTP-Method-Override: PUT" "projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
expect_refused A6 ".json format suffix" "REST merge" api -X PUT "projects/example-group%2Fexample-app/merge_requests/2/merge.json"
reset_fx
expect_refused A7 "dot segments (identity)" "segment" api -X PUT "projects/example-group%2Fexample-app/./merge_requests/../merge_requests/2/merge"
reset_fx
guard_refused A7g "dot segments" "REST merge" api -X PUT "projects/1/./merge_requests/../merge_requests/2/merge"
reset_fx
expect_refused A8 "upper-case route word" "REST merge" api -X PUT "projects/example-group%2Fexample-app/MERGE_REQUESTS/2/Merge"
reset_fx
expect_refused A9 "%-encoded route word (identity)" "%-encoded" api -X PUT "projects/example-group%2Fexample-app/merge_requests/2/%6derge"
reset_fx
guard_refused A9g "%-encoded route word" "REST merge" api -X PUT "projects/1/merge_requests/2/%6derge"
reset_fx
expect_refused A10 "--form _method=PUT" "REST merge" api --form "_method=PUT" "projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
expect_refused A11 "an unknown api flag" "--bogus" api --bogus "projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
expect_refused A12 "a malformed escape (identity)" "%-encoded" api -X PUT "projects/example-group%2Fexample-app/merge_requests/2/merg%zz"
reset_fx
guard_refused A12g "a malformed escape" "cannot be normalized" api -X PUT "projects/1/merge_requests/2/merg%zz"
reset_fx
expect_refused A13 "api/v4 prefix without host" "REST merge" api -X PUT "api/v4/projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
expect_refused A14 "GET with a _method field" "REST merge" api -X GET -f "_method=PUT" "projects/example-group%2Fexample-app/merge_requests/2/merge"
# glab dispatches `glab -R g/r api …` to api (measured, glab 1.112), so a word
# before `api` must not hide the call from the api judgment.
reset_fx
expect_refused A15 "-R <repo> before api" "is not the first word" -R example-group/example-app api -X PUT "projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
expect_refused A16 "--repo=<repo> before api" "is not the first word" --repo=example-group/example-app api -X PUT "projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
expect_refused A17 "-X PUT before api" "PUT" -X PUT api "projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
expect_refused A18 "-- before api" "REFUSING" -- api -X PUT "projects/example-group%2Fexample-app/merge_requests/2/merge"
reset_fx
expect_refused A19 "-R <repo> before api, train boarding with no pin" "is not the first word" -R example-group/example-app api -X POST "projects/:id/merge_trains/merge_requests/4242"
reset_fx
expect_refused A20 "-R <repo> before api, REST merge by a field (default POST)" "is not the first word" -R example-group/example-app api "projects/example-group%2Fexample-app/merge_requests/2/merge" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_refused A21 "-R <repo> before api, train boarding with a wrong pin (default POST)" "is not the first word" -R example-group/example-app api "projects/:id/merge_trains/merge_requests/4242" -f "sha=${OTHER_SHA}"

echo
echo "--- api: merge-train boarding is the guarded path ---"
reset_fx; green_fx
expect_refused T1 "boarding with no sha field is refused" "no sha was given" api -X POST "projects/:id/merge_trains/merge_requests/4242"
reset_fx; green_fx
expect_ran T2 "boarding with -f sha=<head>, passed pipeline, runs" any api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api projects/:id/merge_requests/4242"* ]]; then ok "T2b. the MR was read in the same project"
else bad "T2b. MR read endpoint" "$(detail)"; fi
reset_fx; green_fx
expect_refused T3 "boarding with a sha that is not the head" "not the MR's head" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${OTHER_SHA}"
reset_fx; status_fx running
expect_refused T4 "boarding while the head pipeline runs" "'running', not success" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx; green_fx; printf '%s' "${HEAD_SHA}" > "${TMP}/sha.txt"
expect_refused T5 "the sha field read from a file" "read from a file" api -X POST "projects/:id/merge_trains/merge_requests/4242" -F "sha=@${TMP}/sha.txt"
reset_fx; green_fx
expect_refused T6 "a query string on the train endpoint" "query string" api -X POST "projects/:id/merge_trains/merge_requests/4242?sha=${HEAD_SHA}"
reset_fx; green_fx; printf '{"sha":"%s"}' "${HEAD_SHA}" > "${TMP}/body.json"
expect_refused T7 "--input body on the train endpoint" "--input or --form" api -X POST "projects/:id/merge_trains/merge_requests/4242" --input "${TMP}/body.json"
reset_fx; green_fx
expect_refused T8 "sha given twice" "2 times" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${OTHER_SHA}" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_refused T9 "PUT on a car" "not the boarding call" api -X PUT "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx
expect_ran T10 "DELETE a car (take it off the train) runs with no reads" none api -X DELETE "projects/:id/merge_trains/merge_requests/4242"
reset_fx
expect_ran T11 "GET a car runs with no reads" none api "projects/:id/merge_trains/merge_requests/4242"
reset_fx; green_fx
expect_refused T12 "auto_merge=true plus the pin, passed pipeline, is refused (a deferred boarding, DND-1941)" "auto_merge" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f auto_merge=true -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_ran T13 "an encoded project path" any api -X POST "projects/example-group%2Fexample-app/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api projects/example-group%2Fexample-app/merge_requests/4242"* ]]; then ok "T13b. the encoded project was re-encoded for the MR read"
else bad "T13b. encoded project read" "$(detail)"; fi
reset_fx; green_fx; mr_json success > "${FX}/mrapi.out"; mr_json success "${MERGE_SHA}" "refs/merge-requests/4242/merge" "${HEAD_SHA}" 99 > "${FX}/mrapi.out"
expect_refused T14 "the MR read back is a different iid" "is not !4242" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx; fx mrapi '' 1 'glab: 404 Not Found'
expect_refused T15 "a failed MR read" "could not read !4242" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_refused T16 "DELETE with a method-override header" "not the boarding call" api -X DELETE -H "X-HTTP-Method-Override: POST" "projects/:id/merge_trains/merge_requests/4242"
reset_fx; green_fx
expect_ran T17 "no method, sha field -> POST, guarded, runs" any api "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_ran T18 "--hostname is carried into the MR read" any api --hostname gitlab.com -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api --hostname gitlab.com projects/:id/merge_requests/4242"* ]]; then ok "T18b. hostname in the read"
else bad "T18b. hostname in the read" "$(detail)"; fi
reset_fx; green_fx
expect_refused T19 "a _method field on the train endpoint" "_method" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}" -f "_method=PUT"
reset_fx; green_fx; status_fx failed
expect_refused T20 "boarding with a failed head pipeline" "'failed', not success" api "projects/:id/merge_trains/merge_requests/4242" -F "sha=${HEAD_SHA}"

echo
echo "--- api graphql: mergeRequestAccept is refused wherever the query comes from ---"
# DND-1936: a GraphQL call names its target inside the query, so glab-athena
# keys no bot on it and refuses every `api graphql` before the guard runs (GQ1);
# -R cannot name it either, because the guard refuses -R before `api` (GQ3)
# and its api flag table has no -R after it (GQ2). So the scan is unreachable
# through the wrapper today, and G1-G12, F1 and F2 run the guard itself
# (glmg_guard, sourced), keeping its scan covered for when a keyed GraphQL
# path exists.
reset_fx
expect_refused GQ1 "the wrapper refuses \`api graphql\` (identity: no bot can be keyed on a query)" "api graphql" api graphql -f 'query=query { currentUser { username } }'
reset_fx
expect_refused GQ2 "\`api graphql -R <repo>\`: the guard's api flag table has no -R" "-R" api graphql -R example-group/example-app -f 'query=query { currentUser { username } }'
reset_fx
expect_refused GQ3 "\`-R <repo> api graphql\`: api is not the first word" "is not the first word" -R example-group/example-app api graphql -f 'query=query { currentUser { username } }'
Q='mutation { mergeRequestAccept(input: {projectPath: "example-group/example-app", iid: "4242", sha: "x"}) { errors } }'
reset_fx
guard_refused G1 "inline -f query" "mergeRequestAccept" api graphql -f "query=${Q}"
reset_fx; printf '%s' "${Q}" > "${TMP}/q.graphql"
guard_refused G2 "-F query=@file" "mergeRequestAccept" api graphql -F "query=@${TMP}/q.graphql"
reset_fx; printf '{"query":"mutation { mergeRequest\\u0041ccept(input: {}) { errors } }"}' > "${TMP}/q.json"
guard_refused G3 "--input JSON body with a \\u escape" "mergeRequestAccept" api graphql --input "${TMP}/q.json"
reset_fx
guard_refused G4 "-F query=@- (stdin)" "stdin" api graphql -F "query=@-"
reset_fx
guard_refused G5 "--input - (stdin)" "stdin" api graphql --input -
reset_fx; printf 'not json' > "${TMP}/bad.json"
guard_refused G6 "--input that is not JSON" "not JSON" api graphql --input "${TMP}/bad.json"
reset_fx
guard_refused G7 "an unreadable query file" "cannot read" api graphql -F "query=@${TMP}/does-not-exist"
reset_fx
guard_refused G8 "the full GraphQL URL" "mergeRequestAccept" api "https://gitlab.com/api/graphql" -f "query=${Q}"
reset_fx
guard_refused G9 "an operation alias around it" "mergeRequestAccept" api graphql -f 'query=mutation M { go: mergeRequestAccept(input: $i) { errors } }'
reset_fx
guard_passed G10 "mergeTrainsDeleteCar passes" api graphql -f 'query=mutation { mergeTrainsDeleteCar(input: {carId: "x"}) { errors } }'
reset_fx
guard_passed G11 "a read query passes" api graphql -f 'query=query { currentUser { username } }'
reset_fx
guard_passed G12 "mergeRequestSetLabels passes" api graphql -f 'query=mutation { mergeRequestSetLabels(input: {}) { errors } }'


# The scan's own failure must never read as "no merge mutation". F1: mktemp
# fails for the scan file only (the isolation dir, mktemp -d, still works).
# F2: grep errors (exit 2) on the scan.
mkdir -p "${TMP}/brokenbin"
REAL_MKTEMP="$(command -v mktemp)"; REAL_GREP="$(command -v grep)"
printf '#!/usr/bin/env bash\ncase " $* " in *" -d "*) exec "%s" "$@" ;; esac\nexit 1\n' "${REAL_MKTEMP}" > "${TMP}/brokenbin/mktemp"
chmod +x "${TMP}/brokenbin/mktemp"
reset_fx; PATH="${TMP}/brokenbin:${PATH}" run_guard api graphql -f 'query=query { currentUser { username } }'
if refused && [[ "${ERR}" == *"scratch file"* ]]; then ok "F1. the scan's scratch file cannot be made -> refused"
else bad "F1. mktemp failure fails closed" "$(detail)"; fi
rm -f "${TMP}/brokenbin/mktemp"
printf '#!/usr/bin/env bash\ncase " $* " in *" -aEiq "*) echo "grep: simulated I/O error" >&2; exit 2 ;; esac\nexec "%s" "$@"\n' "${REAL_GREP}" > "${TMP}/brokenbin/grep"
chmod +x "${TMP}/brokenbin/grep"
reset_fx; PATH="${TMP}/brokenbin:${PATH}" run_guard api graphql -f 'query=query { currentUser { username } }'
if refused && [[ "${ERR}" == *"grep exit 2"* ]]; then ok "F2. the scan's grep errors (exit 2) -> refused"
else bad "F2. grep error fails closed" "$(detail)"; fi
rm -rf "${TMP}/brokenbin"

echo
echo "--- other merge paths ---"
reset_fx
expect_refused C1 "mcp serve (its tools can merge) is refused" "mcp" mcp serve
# `glab mr create --auto-merge` (glab 1.112: "Set the merge request to merge when
# all merge checks pass") schedules a merge of a head nobody pinned or checked.
reset_fx
expect_refused C2 "mr create --auto-merge is refused" "--auto-merge" mr create --fill --auto-merge --yes
reset_fx
expect_refused C3 "mr new (create's alias) --auto-merge=true is refused" "--auto-merge" mr new --fill --auto-merge=true --yes
reset_fx
expect_refused C4 "mr -R <repo> create --auto-merge is refused" "--auto-merge" mr -R example-group/example-app create --fill --auto-merge
reset_fx
expect_refused C5 "--auto-merge on another subcommand is refused" "--auto-merge" mr update 4242 --auto-merge

echo
echo "--- negatives: reads and non-merge writes pass as-is, with no extra reads ---"
reset_fx; expect_ran N1 "mr view" none mr view 4242
reset_fx; expect_ran N2 "mr create" none mr create --fill --yes --target-branch main
reset_fx; expect_ran N3 "mr note whose text says merge" none mr note 4242 --message "please merge"
reset_fx; expect_ran N4 "api GET an MR" none api "projects/:id/merge_requests/4242"
reset_fx; expect_ran N5 "api POST approve" none api -X POST "projects/:id/merge_requests/4242/approve"
reset_fx; expect_ran N6 "api GET the active train" none api "projects/:id/merge_trains?scope=active"
reset_fx; expect_ran N7 "api POST a note" none api -X POST "projects/:id/merge_requests/4242/notes" -f "body=merge soon"
reset_fx; expect_ran N8 "api POST cancel auto-merge" none api -X POST "projects/:id/merge_requests/4242/cancel_merge_when_pipeline_succeeds"
reset_fx; expect_ran N9 "api GET merge_ref" none api "projects/:id/merge_requests/4242/merge_ref"
reset_fx; expect_ran N10 "ci status" none ci status
reset_fx; expect_ran N11 "api PUT MR labels" none api -X PUT "projects/:id/merge_requests/4242" -f "labels=Auto-Deploy"
reset_fx; expect_ran N12 "mr list" none mr list
reset_fx; expect_ran N13 "api POST a pipeline for the MR" none api -X POST "projects/:id/merge_requests/4242/pipelines"
reset_fx; expect_ran N14 "mr create whose title says merge" none mr create --title merge --description "merge accept api" --yes
reset_fx; expect_ran N15 "help mr merge" none help mr merge

echo
echo "--- DND-1845: every merge needs integration-gate's receipt for the MR's head ---"
# The defect: glab-athena pinned the head and its passed pipeline, but never
# asked whether integration-gate passed that head. An MR integration-gate held
# at exit 4 (blast-radius, no receipt written) could still be merged or boarded
# onto the train. Every merge path the guard lets through now reads the sealed
# receipt for exactly the MR's head (ai/lib/integration-receipt.sh, the reader
# gh-athena and locked-merge use) and refuses without it.
TRAIN="projects/:id/merge_trains/merge_requests/4242"
MERGE_ARGS=(mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes)
BOARD_ARGS=(api -X POST "${TRAIN}" -f "sha=${HEAD_SHA}")
# receipt_refused <id> <label> <kind> <args…> : refused with that kind, a Fix:
# naming integration-gate, and nothing that merges reached glab.
receipt_refused() {
  local id="$1" label="$2" kind="$3" fixline; shift 3
  run "$@"
  fixline="$(grep -m1 'Fix:' <<<"${ERR}")"
  if refused && [[ "${ERR}" == *"${kind}"* ]] && [[ "${fixline}" == *"integration-gate"* ]]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want ${kind}, Fix naming integration-gate)" "$(detail)"; fi
}
# receipt_ran <id> <label> <args…> : ran once, as given, after the receipt read.
receipt_ran() {
  local id="$1" label="$2"; shift 2
  run "$@"
  if ran_once "$@" && [[ "${ERR}" == *"RECEIPT ${STORE_FX}/${HEAD_SHA}.json"* ]]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want one exec and a RECEIPT line)" "$(detail)"; fi
}

reset_fx; nogate_fx
receipt_refused R1 "THE MISS: mr merge, pinned head, passed pipeline, NO receipt -> refused" "NO RECEIPT" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"${STORE_FX}/${HEAD_SHA}.json"* ]] && ok "R1b. the refusal names the receipt path it searched" || bad "R1b. searched path" "$(detail)"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"${HEAD_SHA}"* ]] && ok "R1c. the Fix says to run integration-gate on that head" || bad "R1c. Fix names the head" "$(detail)"
reset_fx; nogate_fx
receipt_refused R2 "THE MISS on the train: boarding, pinned head, passed pipeline, NO receipt -> refused" "NO RECEIPT" "${BOARD_ARGS[@]}"
reset_fx; nogate_fx
expect_refused R2b "mr merge --auto-merge with no receipt -> refused (deferred, before any read)" "deferred merge" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge --yes
reset_fx; green_fx
receipt_ran R3 "mr merge with a receipt for the head -> runs" "${MERGE_ARGS[@]}"
reset_fx; green_fx
receipt_ran R3b "train boarding with a receipt for the head -> runs" "${BOARD_ARGS[@]}"

# Criterion 1: boarding is checked against the MR's HEAD, never the train's
# merged-result commit (the head pipeline's sha here is the merge commit).
reset_fx; nogate_fx; plant "${MERGE_SHA}" "${TIP_FX}"
receipt_refused R4 "criterion 1: a receipt for the merged-result commit, none for the head -> boarding refused" "NO RECEIPT" "${BOARD_ARGS[@]}"
[[ "${ERR}" == *"${HEAD_SHA}.json"* ]] && [[ "${ERR}" != *"${MERGE_SHA}.json"* ]] \
  && ok "R4b. the receipt searched is the head's, not the merged-result commit's" || bad "R4b. head, not merge ref" "$(detail)"

# Criterion 2: non-merge writes stay unguarded: no reads, no receipt, and not
# even a checkout needed. Outside a checkout the project is named by -R or by
# the api endpoint, which is what picks the bot (DND-1936).
mkdir -p "${TMP}/not-a-repo"; cd "${TMP}/not-a-repo" || exit 2
P_ENC="example-group%2Fexample-app" P_R="example-group/example-app"
reset_fx; expect_ran R5a "criterion 2: api PUT an Auto-Deploy label, outside any checkout" none api -X PUT "projects/${P_ENC}/merge_requests/4242" -f "add_labels=Auto-Deploy"
reset_fx; expect_ran R5b "criterion 2: mr update --label (a risk label)" none mr update 4242 --label "risk::low" -R "${P_R}"
reset_fx; expect_ran R5c "criterion 2: mr note" none mr note 4242 --message "gated" -R "${P_R}"
reset_fx; expect_ran R5d "criterion 2: mr approve" none mr approve 4242 -R "${P_R}"
reset_fx; expect_ran R5e "criterion 2: api POST approve" none api -X POST "projects/${P_ENC}/merge_requests/4242/approve"
reset_fx; expect_ran R5f "criterion 2: api POST play a manual job (release deploy)" none api -X POST "projects/${P_ENC}/jobs/9000000002/play"
reset_fx; expect_ran R5g "criterion 2: ci trigger a manual job" none ci trigger 9000000003 -R "${P_R}"
cd "${REPO_FX}" || exit 2

# Criterion 3: an exit-4 head leaves NO receipt (integration-gate writes one
# only on INTEGRATION OK), so it is refused (R1). Cleared with --owner-approval,
# the gate writes a pass receipt that records the approval; that satisfies the
# guard on both paths.
OA='.owner_approval = "click:00000000-0000-4000-8000-000000000001" | .blast_radius = "BLAST-RADIUS HOT 4cc5665 OWNER-APPROVED"'
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${TIP_FX}" pass "${OA}"
receipt_ran R6 "criterion 3: an owner-approved receipt for the head -> mr merge runs" "${MERGE_ARGS[@]}"
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${TIP_FX}" pass "${OA}"
receipt_ran R6b "criterion 3: an owner-approved receipt for the head -> boarding runs" "${BOARD_ARGS[@]}"

# Criterion 4: the project declares no gate (bin/prep-commit.sh and
# ai/bin/harness-gate are absent at its root), so integration-gate gates it with
# a caller-supplied --gate. An MR outside the backend is gated with that part's
# own command; its receipt is the same shape, and the guard never asks which
# suite ran.
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${TIP_FX}" pass '.gate = "cd mobile && bin/test"'
receipt_ran R7 "criterion 4: a receipt whose caller-supplied gate is a non-backend suite -> runs" "${MERGE_ARGS[@]}"

# Criterion 5: nothing author-specific.
for who in human bot; do
  reset_fx; nogate_fx
  for f in mrview mrapi; do jq -c --arg w "${who}" '.author = {"username": ("a-" + $w), "bot": ($w == "bot")}' "${FX}/${f}.out" > "${FX}/${f}.tmp" && mv "${FX}/${f}.tmp" "${FX}/${f}.out"; done
  receipt_refused "R8-${who}" "criterion 5: a ${who}-authored MR with no receipt -> refused" "NO RECEIPT" "${MERGE_ARGS[@]}"
  plant "${HEAD_SHA}" "${TIP_FX}"
  receipt_ran "R8b-${who}" "criterion 5: a ${who}-authored MR with a receipt -> runs" "${MERGE_ARGS[@]}"
done

# Criterion 6: the head was re-pushed after integration-gate passed an earlier
# one (e.g. a head pushed after integration-gate --rebase that is not the
# rebased head it gated). The old head's receipt does not cover the new head.
versions_fx() { printf '[{"id":2,"head_commit_sha":"%s"},{"id":1,"head_commit_sha":"%s"}]\n' "${HEAD_SHA}" "${OTHER_SHA}" > "${FX}/versions.out"; }
reset_fx; nogate_fx; versions_fx; plant "${OTHER_SHA}" "${TIP_FX}"
receipt_refused R9 "criterion 6: a re-pushed head (receipt only for the earlier head) -> mr merge refused" "NO RECEIPT" "${MERGE_ARGS[@]}"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"re-gate the new head"*"${HEAD_SHA}"* ]] && [[ "${ERR}" == *"${OTHER_SHA}"* ]] \
  && ok "R9b. the refusal names the gated earlier head and its Fix says to re-gate the new head" || bad "R9b. re-gate Fix" "$(detail)"
reset_fx; nogate_fx; versions_fx; plant "${OTHER_SHA}" "${TIP_FX}"
receipt_refused R9c "criterion 6: the same on the train" "NO RECEIPT" "${BOARD_ARGS[@]}"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"re-gate the new head"* ]] && ok "R9d. train refusal says re-gate the new head" || bad "R9d. train re-gate Fix" "$(detail)"
reset_fx; nogate_fx; fx versions '' 1 'glab: 500'
receipt_refused R9e "the version history cannot be read -> still refused as NO RECEIPT" "NO RECEIPT" "${MERGE_ARGS[@]}"

# The reader's other outcomes, through this guard.
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${OLD_TIP}"
run "${MERGE_ARGS[@]}"
if ran_once "${MERGE_ARGS[@]}" && [[ "${ERR}" == *"BASE MOVED"* ]]; then ok "R10. a receipt on an ancestor of the target tip -> runs, and says the base moved (DND-1463)"
else bad "R10. ancestor base" "$(detail)"; fi
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${SIDE_FX}"
receipt_refused R11 "a receipt on a base that is not an ancestor of the target tip -> refused" "RECEIPT FOR ANOTHER BASE" "${MERGE_ARGS[@]}"
reset_fx; green_fx
jq 'del(.seal, .producer)' "${STORE_FX}/${HEAD_SHA}.json" > "${STORE_FX}/f.tmp" && mv "${STORE_FX}/f.tmp" "${STORE_FX}/${HEAD_SHA}.json"
receipt_refused R12 "a forged (unsealed) receipt -> refused (DND-1814)" "RECEIPT UNVERIFIED" "${MERGE_ARGS[@]}"
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${TIP_FX}" red
receipt_refused R13 "a receipt whose verdict is not pass -> refused" "RECEIPT INVALID" "${MERGE_ARGS[@]}"
reset_fx; green_fx; chmod 000 "${STORE_FX}"
run "${MERGE_ARGS[@]}"; chmod 700 "${STORE_FX}"
if refused && [[ "${ERR}" == *"COULD NOT LOOK"* ]] && [[ "${ERR}" != *"NO RECEIPT"* ]]; then ok "R14. an unsearchable store -> COULD NOT LOOK, never NO RECEIPT"
else bad "R14. unsearchable store" "$(detail)"; fi

# Where the receipt is read from: the checkout of the MR's own project.
reset_fx; green_fx; cd "${TMP}/not-a-repo" || exit 2
receipt_refused R15 "run outside any checkout -> refused (COULD NOT LOOK)" "COULD NOT LOOK" mr -R example-group/example-app merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
cd "${REPO_FX}" || exit 2
for other in "git@gitlab.com:example-group/other-app.git" "git@evil-gitlab.com:example-group/example-app.git" "https://gitlab.com/x/example-group/example-app.git"; do
  OFX="${TMP}/other-$RANDOM"; git init -q -b main "${OFX}"; git -C "${OFX}" remote add origin "${other}"
  reset_fx; green_fx; cd "${OFX}" || exit 2
  receipt_refused "R16 ${other}" "a checkout of another project -> refused (COULD NOT LOOK)" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
  cd "${REPO_FX}" || exit 2
done
WT_FX="${TMP}/example-app-wt"
git -C "${REPO_FX}" worktree add -q --detach "${WT_FX}" "${OLD_TIP}" 2>/dev/null
reset_fx; green_fx; cd "${WT_FX}" || exit 2
receipt_ran R17 "run from a linked worktree -> reads the shared git common dir, runs" "${MERGE_ARGS[@]}"
cd "${REPO_FX}" || exit 2
HTTPS_FX="${TMP}/https-app"; git init -q -b main "${HTTPS_FX}"; git -C "${HTTPS_FX}" remote add origin "https://gitlab.com/Example-Group/Example-App.git"
# The bot is resolved from -R here: with no -R, the Example-Group origin is
# itself refused by the identity map, whose namespaces match exactly (R18b).
reset_fx; green_fx; cd "${HTTPS_FX}" || exit 2
run mr -R example-group/example-app merge 4242 --auto-merge=false --sha "${HEAD_SHA}" --yes
if refused && [[ "${ERR}" == *"NO RECEIPT"* ]] && [[ "${ERR}" == *"${HTTPS_FX}"* ]]; then ok "R18. an https remote (any case) matches the project; its own store is the one read"
else bad "R18. https remote matches" "$(detail)"; fi
reset_fx; green_fx
run "${MERGE_ARGS[@]}"
if refused && [[ "${ERR}" == *"NO ENTRY"* ]] && [[ "${ERR}" == *"differs only in case"* ]] && [ ! -s "${STUB_READS}" ]; then ok "R18b. with no -R, a differently cased origin is refused by the identity map before any read (DND-1936)"
else bad "R18b. differently cased origin refused" "$(detail)"; fi
cd "${REPO_FX}" || exit 2
# matched_in <id> <label> <dir> : run from <dir>, the guard took it as the MR's
# checkout: it searched <dir>'s own store (empty) and refused NO RECEIPT.
matched_in() {
  cd "$3" || exit 2
  run "${MERGE_ARGS[@]}"
  cd "${REPO_FX}" || exit 2
  if refused && [[ "${ERR}" == *"NO RECEIPT"* ]] && [[ "${ERR}" == *"$3/.git/integration-receipts"* ]]; then ok "$1. $2"
  else bad "$1. $2" "$(detail)"; fi
}
SSH_FX="${TMP}/ssh-app"; git init -q -b main "${SSH_FX}"; git -C "${SSH_FX}" remote add origin "ssh://git@gitlab.com:2222/example-group/example-app.git/"
reset_fx; green_fx; matched_in R26 "an ssh:// remote with a port and a trailing .git/ matches the project" "${SSH_FX}"
TWO_FX="${TMP}/two-app"; git init -q -b main "${TWO_FX}"
git -C "${TWO_FX}" remote add fork "git@gitlab.com:someone/example-app.git"; git -C "${TWO_FX}" remote add origin "git@gitlab.com:example-group/example-app.git"
reset_fx; green_fx; matched_in R27 "a checkout whose second remote is the project matches" "${TWO_FX}"
SUB_FX="${TMP}/sub-app"; git init -q -b main "${SUB_FX}"; git -C "${SUB_FX}" remote add origin "git@gitlab.com:example-group/sub/example-app.git"
reset_fx; green_fx; for f in mrview mrapi; do jq -c '.web_url = "https://gitlab.com/example-group/sub/example-app/-/merge_requests/4242"' "${FX}/${f}.out" > "${FX}/${f}.tmp" && mv "${FX}/${f}.tmp" "${FX}/${f}.out"; done
matched_in R28 "a nested subgroup project matches its checkout" "${SUB_FX}"
DOT_FX="${TMP}/dot-app"; git init -q -b main "${DOT_FX}"; git -C "${DOT_FX}" remote add origin "git@gitlabxcom:example-group/example-app.git"
reset_fx; green_fx; cd "${DOT_FX}" || exit 2
receipt_refused R29 "a remote host that matches only if '.' were a wildcard -> refused" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
cd "${REPO_FX}" || exit 2
reset_fx; green_fx
receipt_refused R30 "train boarding with --hostname naming another host than the MR's -> refused" "is not the MR's host" api --hostname other.example.com -X POST "${TRAIN}" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
receipt_ran R31 "mr merge reads the target tip on the MR's own host" "${MERGE_ARGS[@]}"
[[ "$(reads)" == *"api --hostname gitlab.com projects/7000001/repository/branches/main"* ]] \
  && ok "R31b. the tip read carries --hostname from the MR's web_url" || bad "R31b. hostname from web_url" "$(detail)"

# The target tip, read from the forge.
reset_fx; green_fx; fx branch '' 1 'glab: 404 Branch Not Found'
receipt_refused R19 "the target tip cannot be read -> refused (COULD NOT LOOK), the failure named" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"404 Branch Not Found"* ]] && ok "R19b. the forge's error is in the refusal" || bad "R19b. forge error named" "$(detail)"
reset_fx; green_fx; fx branch '{"commit":{"id":"not-a-sha"}}'
receipt_refused R20 "a target tip that is not a SHA -> refused" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
reset_fx; green_fx; branch_is "0123456789abcdef0123456789abcdef01234567"
receipt_refused R21 "a target tip not in the local object store -> refused (COULD NOT LOOK), Fix says fetch" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"git fetch"* ]] && ok "R21b. the Fix says to fetch" || bad "R21b. fetch named" "$(detail)"
reset_fx; green_fx; jq -c 'del(.web_url)' "${FX}/mrview.out" > "${FX}/m.tmp" && mv "${FX}/m.tmp" "${FX}/mrview.out"
receipt_refused R22 "an MR read with no web_url (project unknown) -> refused" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
reset_fx; green_fx; jq -c 'del(.target_branch)' "${FX}/mrview.out" > "${FX}/m.tmp" && mv "${FX}/m.tmp" "${FX}/mrview.out"
receipt_refused R23 "an MR read with no target_branch -> refused" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
reset_fx; green_fx
receipt_ran R24 "train boarding with --hostname -> runs" api --hostname gitlab.com -X POST "${TRAIN}" -f "sha=${HEAD_SHA}"
[[ "$(reads)" == *"api --hostname gitlab.com projects/7000001/repository/branches/main"* ]] \
  && ok "R24b. the target tip is read on the same host" || bad "R24b. hostname on the branch read" "$(detail)"
reset_fx; green_fx; for f in mrview mrapi; do jq -c '.target_branch = "release/2026.10"' "${FX}/${f}.out" > "${FX}/${f}.tmp" && mv "${FX}/${f}.tmp" "${FX}/${f}.out"; done; tip_pipes success release/2026.10
receipt_ran R25 "a target branch with a slash -> runs" "${MERGE_ARGS[@]}"
[[ "$(reads)" == *"repository/branches/release%2F2026.10"* ]] && ok "R25b. the branch name is URL-encoded in the read" || bad "R25b. branch encoding" "$(detail)"

echo
echo "--- DND-1941: a deferred merge is refused (the receipt cannot be read when it lands) ---"
# glab's `mr merge` sets auto-merge by DEFAULT (glab 1.92.1 --help: "--auto-merge
# Set auto-merge. (true)"): GitLab then merges when its own checks pass, later,
# onto whatever the target is then. Every project merged through glab-athena
# needs a receipt (DND-1845), so every project is gated, and a deferred merge is
# refused everywhere (DND-969 on GitHub). Each refusal is made before any read.
# am_refused <id> <label> <args…> : refused as a deferred merge, with no read.
am_refused() {
  local id="$1" label="$2"; shift 2
  run "$@"
  if refused && [[ "${ERR}" == *"deferred merge"* ]] && [[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"--auto-merge=false"* ]] && [ ! -s "${STUB_READS}" ]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want a deferred-merge refusal, Fix naming --auto-merge=false, no read)" "$(detail)"; fi
}
reset_fx; green_fx
am_refused AM1 "THE MISS: mr merge --sha <head>, green, receipt, auto-merge left at glab's default -> refused" mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
am_refused AM2 "--auto-merge -> refused" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge --yes
reset_fx; green_fx
am_refused AM3 "--auto-merge=true -> refused" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge=true --yes
reset_fx; green_fx
am_refused AM4 "--auto-merge=false then --auto-merge (pflag: the last wins) -> refused" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge=false --auto-merge --yes
reset_fx; green_fx
am_refused AM5 "--auto-merge false (a bool takes no separate value; 'false' is a positional) -> refused" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge false --yes
reset_fx; green_fx
am_refused AM6 "--when-pipeline-succeeds (glab's hidden, deprecated spelling) -> refused" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge=false --when-pipeline-succeeds --yes
reset_fx; green_fx
am_refused AM7 "--when-pipeline-succeeds=false (any spelling of the deprecated flag) -> refused" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge=false --when-pipeline-succeeds=false --yes
reset_fx; green_fx
am_refused AM8 "mr accept, default auto-merge -> refused" mr accept 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
am_refused AM15 "--auto-merge=false after -- (a positional there, so auto-merge stays on) -> refused" mr merge 4242 --sha "${HEAD_SHA}" --yes -- --auto-merge=false
reset_fx; green_fx
expect_refused AM9 "--auto-merge=maybe (not a bool pflag parses) -> refused" "maybe" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge=maybe --yes
for f in false 0 f F FALSE False; do
  reset_fx; green_fx
  receipt_ran "AM10-${f}" "--auto-merge=${f} (immediate), green, receipt -> runs" mr merge 4242 --sha "${HEAD_SHA}" "--auto-merge=${f}" --yes
done
reset_fx; green_fx
am_refused AM11 "THE MISS on the train: boarding with -f auto_merge=true -> refused" api -X POST "${TRAIN}" -f auto_merge=true -f "sha=${HEAD_SHA}"
reset_fx; green_fx
am_refused AM12 "boarding with -F when_pipeline_succeeds=true -> refused" api -X POST "${TRAIN}" -F when_pipeline_succeeds=true -f "sha=${HEAD_SHA}"
reset_fx; green_fx
am_refused AM13 "boarding with -f auto_merge=false (the field at all) -> refused" api -X POST "${TRAIN}" -f auto_merge=false -f "sha=${HEAD_SHA}"
reset_fx; green_fx
am_refused AM14 "boarding with an upper-case AUTO_MERGE field -> refused" api -X POST "${TRAIN}" -f AUTO_MERGE=true -f "sha=${HEAD_SHA}"

echo
echo "--- DND-1941: API ref writes are refused (the DND-741 analogue) ---"
# ref_refused <id> <label> <must-contain> <args…> : refused as a ref write, with
# no read and nothing reaching glab.
ref_refused() {
  local id="$1" label="$2" want="$3"; shift 3
  run "$@"
  if refused && [[ "${ERR}" == *"moves a branch"* ]] && [[ "${ERR}" == *"${want}"* ]] && [ ! -s "${STUB_READS}" ]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want a ref-write refusal naming '${want}')" "$(detail)"; fi
}
reset_fx; ref_refused W1 "POST repository/branches (create a branch)" "repository/branches" api -X POST "projects/:id/repository/branches" -f branch=x -f ref=main
reset_fx; ref_refused W2 "POST repository/commits with branch=main" "repository/commits" api -X POST "projects/:id/repository/commits" -f branch=main -f "commit_message=x" -f "actions[][action]=create"
reset_fx; ref_refused W2b "POST repository/commits on a feature branch (the scope is every branch)" "repository/commits" api -X POST "projects/:id/repository/commits" -f branch=feature
reset_fx; ref_refused W2c "repository/commits with fields and no -X (glab defaults to POST)" "repository/commits" api "projects/:id/repository/commits" -f branch=main
reset_fx; ref_refused W3 "POST repository/commits/<sha>/cherry_pick" "cherry_pick" api -X POST "projects/:id/repository/commits/${HEAD_SHA}/cherry_pick" -f branch=main
reset_fx; ref_refused W3b "POST repository/commits/<sha>/revert" "revert" api -X POST "projects/:id/repository/commits/${HEAD_SHA}/revert" -f branch=main
reset_fx; ref_refused W4 "PUT repository/files/<encoded path>" "repository/files" api -X PUT "projects/:id/repository/files/lib%2Fa.ex" -f branch=main -f content=x
reset_fx; ref_refused W4b "DELETE repository/files/<path> (a commit too)" "repository/files" api -X DELETE "projects/:id/repository/files/lib%2Fa.ex" -f branch=main
reset_fx; ref_refused W5 "POST protected_branches" "protected_branches" api -X POST "projects/:id/protected_branches" -f name=x
reset_fx; ref_refused W5b "DELETE protected_branches/main (unprotects main)" "protected_branches" api -X DELETE "projects/:id/protected_branches/main"
reset_fx; ref_refused W5c "PATCH protected_branches/main (allow force push)" "protected_branches" api -X PATCH "projects/:id/protected_branches/main" -f allow_force_push=true
reset_fx; ref_refused W5d "PUT repository/branches/main/unprotect" "repository/branches" api -X PUT "projects/:id/repository/branches/main/unprotect"
reset_fx; ref_refused W6 "POST remote_mirrors" "remote_mirrors" api -X POST "projects/:id/remote_mirrors" -f url=https://example.invalid/x.git
reset_fx; ref_refused W6b "PUT remote_mirrors/<id>" "remote_mirrors" api -X PUT "projects/:id/remote_mirrors/1" -f enabled=true
reset_fx; ref_refused W6c "POST remote_mirrors/<id>/sync" "remote_mirrors" api -X POST "projects/:id/remote_mirrors/1/sync"
reset_fx; ref_refused W7 "POST mirror/pull (a pull mirror moves refs in)" "mirror/pull" api -X POST "projects/:id/mirror/pull"
reset_fx; ref_refused W8 "POST repository/tags" "repository/tags" api -X POST "projects/:id/repository/tags" -f tag_name=v1 -f ref=main
reset_fx; ref_refused W8b "POST protected_tags" "protected_tags" api -X POST "projects/:id/protected_tags" -f name=v1
reset_fx; ref_refused W9 "PUT merge_requests/<iid>/rebase (moves the source branch)" "rebase" api -X PUT "projects/:id/merge_requests/4242/rebase"
reset_fx; ref_refused W10 "PUT repository/submodules/<path>" "repository/submodules" api -X PUT "projects/:id/repository/submodules/lib%2Fdep" -f branch=main -f "commit_sha=${HEAD_SHA}"
reset_fx; ref_refused W11 "POST repository/changelog (commits the changelog)" "repository/changelog" api -X POST "projects/:id/repository/changelog" -f version=1.0.0
reset_fx; ref_refused W12 "an encoded project path, upper case, a .json suffix" "repository/commits" api -X post "PROJECTS/example-group%2Fexample-app/REPOSITORY/COMMITS.json" -f branch=main
# The wrapper refuses an absolute-URL endpoint before the guard (DND-1936: its
# host and project are not the ones the bot is keyed on); W13g keeps the
# guard's own reading of it covered.
reset_fx; expect_refused W13 "the full URL with api/v4 (identity)" "absolute URL" api -X POST "https://gitlab.com/api/v4/projects/1/repository/branches" -f branch=x
reset_fx; guard_refused W13g "the full URL with api/v4" "repository/branches" api -X POST "https://gitlab.com/api/v4/projects/1/repository/branches" -f branch=x
reset_fx; ref_refused W14 "a branch DELETE with a method-override header is not a plain DELETE" "repository/branches" api -X DELETE -H "X-HTTP-Method-Override: POST" "projects/:id/repository/branches/feature"
reset_fx; ref_refused W15 "a branch DELETE with a _method field is not a plain DELETE" "repository/branches" api -X DELETE -f "_method=POST" "projects/:id/repository/branches/feature"
reset_fx; ref_refused W16 "a DELETE that also names protected_branches deeper in the path" "protected_branches" api -X DELETE "projects/:id/repository/branches/x/protected_branches/main"
reset_fx; ref_refused W24 "POST groups/<g>/protected_branches (group-level protection)" "protected_branches" api -X POST "groups/example-group/protected_branches" -f name=main
reset_fx; ref_refused W24b "DELETE groups/<g>/protected_branches/main (unprotects main in every project)" "protected_branches" api -X DELETE "groups/example-group%2Fsub/protected_branches/main"
reset_fx; expect_ran W24c "GET groups/<g>/protected_branches passes" none api "groups/example-group/protected_branches"
reset_fx; expect_ran W24d "a group write that is not protection passes (POST group labels)" none api -X POST "groups/example-group/labels" -f name=x -f color=#fff
reset_fx; expect_ran W17 "GET repository/branches passes" none api "projects/:id/repository/branches"
reset_fx; expect_ran W18 "a plain DELETE of a branch passes (moves nothing onto a ref)" none api -X DELETE "projects/:id/repository/branches/feature%2Fx"
reset_fx; expect_ran W19 "a plain DELETE of a tag passes" none api -X DELETE "projects/:id/repository/tags/v1"
reset_fx; expect_ran W20 "GET protected_branches passes" none api "projects/:id/protected_branches"
reset_fx; expect_ran W21 "GET remote_mirrors passes" none api "projects/:id/remote_mirrors"
reset_fx; expect_ran W22 "POST a commit comment passes" none api -X POST "projects/:id/repository/commits/${HEAD_SHA}/comments" -f note=x
reset_fx; expect_ran W23 "GET a file passes" none api "projects/:id/repository/files/lib%2Fa.ex?ref=main"

echo
echo "--- DND-1941: GraphQL ref writes are refused ---"
# The wrapper refuses every `api graphql` before the guard (DND-1936, GQ1-GQ3),
# so these run the guard itself, like G1-G12.
reset_fx; guard_refused GR1 "commitCreate" "commitCreate" api graphql -f 'query=mutation { commitCreate(input: {projectPath: "g/p", branch: "main", message: "x", actions: []}) { errors } }'
reset_fx; guard_refused GR2 "createBranch" "createBranch" api graphql -f 'query=mutation { createBranch(input: {projectPath: "g/p", name: "x", ref: "main"}) { errors } }'
reset_fx; guard_refused GR3 "tagCreate" "tagCreate" api graphql -f 'query=mutation { tagCreate(input: {}) { errors } }'
reset_fx; guard_refused GR4 "branchRuleUpdate (protection)" "branchRuleUpdate" api graphql -f 'query=mutation { branchRuleUpdate(input: {}) { errors } }'
reset_fx; guard_refused GR5 "branchRuleDelete (protection)" "branchRuleDelete" api graphql -f 'query=mutation { branchRuleDelete(input: {}) { errors } }'
reset_fx; printf '{"query":"mutation { commit\\u0043reate(input: {}) { errors } }"}' > "${TMP}/qc.json"
reset_fx; guard_refused GR6 "commitCreate in an --input body with a \\u escape" "commitCreate" api graphql --input "${TMP}/qc.json"
reset_fx; guard_passed GR7 "branchDelete passes (a ref delete)" api graphql -f 'query=mutation { branchDelete(input: {}) { errors } }'

echo
echo "--- DND-1941: a RED target tip stops the line (DND-1902 on GitHub) ---"
# The tip's own main pipelines (projects/<id>/pipelines?sha=<tip>&ref=<target>).
# The latest pipeline of each source is judged; an older red one is superseded
# only when that source's latest SUCCEEDED. A red tip refuses every merge but a
# red-main fix, a head that contains the tip. No pipeline at all is COULD NOT
# LOOK, never green.
# tip_refused <id> <label> <mark> <args…> : refused with <mark>, nothing ran.
tip_refused() {
  local id="$1" label="$2" mark="$3"; shift 3
  run "$@"
  if refused && [[ "${ERR}" == *"${mark}"* ]]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want a refusal naming '${mark}')" "$(detail)"; fi
}
tip_ran() {
  local id="$1" label="$2" note="$3"; shift 3
  run "$@"
  if ran_once "$@" && [[ "${ERR}" == *"${note}"* ]]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want one exec and '${note}')" "$(detail)"; fi
}
reset_fx; green_fx; tip_pipes failed
tip_refused P1 "THE MISS: an ordinary MR onto a failed tip -> refused (MAIN RED)" "MAIN RED:" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"pipelines/8000000001"* ]] && ok "P1b. the refusal names the red pipeline" || bad "P1b. red pipeline named" "$(detail)"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"red-main fix"* ]] && ok "P1c. the Fix names the red-main fix" || bad "P1c. Fix" "$(detail)"
reset_fx; green_fx; tip_pipes failed
tip_refused P2 "the same on the train" "MAIN RED:" "${BOARD_ARGS[@]}"
reset_fx; green_fx; tip_pipes failed; printf '{"id":"%s"}\n' "${TIP_FX}" > "${FX}/mergebase.out"
tip_ran P3 "a red-main fix (the forge's merge base of tip and head IS the tip) -> runs" "RED-MAIN FIX" "${MERGE_ARGS[@]}"
reset_fx; green_fx; tip_pipes failed; printf '{"id":"%s"}\n' "${OLD_TIP}" > "${FX}/mergebase.out"
tip_refused P4 "a head that does not contain the red tip -> refused" "MAIN RED:" "${MERGE_ARGS[@]}"
reset_fx; green_fx; tip_pipes failed; fx mergebase '' 1 'glab: 500'
tip_refused P5 "red tip, containment unreadable -> COULD NOT LOOK" "COULD NOT LOOK:" "${MERGE_ARGS[@]}"
reset_fx; green_fx; fx pipes '[]'
tip_refused P6 "THE MISS: a tip with NO pipeline -> COULD NOT LOOK, never green" "COULD NOT LOOK:" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"no pipeline"* ]] && ok "P6b. the refusal says no pipeline ran on the tip" || bad "P6b. no pipeline named" "$(detail)"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *'api -X POST "projects/7000001/pipeline?ref=main"'* ]] && ok "P6c. the Fix names the call that runs a pipeline on the tip" || bad "P6c. pipeline Fix" "$(detail)"
reset_fx; green_fx; fx pipes '' 1 'glab: 503 Service Unavailable'
tip_refused P7 "the tip's pipelines cannot be read -> COULD NOT LOOK, the error named" "503 Service Unavailable" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"COULD NOT LOOK:"* ]] && ok "P7b. it is COULD NOT LOOK" || bad "P7b. LOOK mark" "$(detail)"
reset_fx; green_fx; fx pipes '{"message":"404 Not Found"}'
tip_refused P8 "a pipelines answer that is not a list -> COULD NOT LOOK" "COULD NOT LOOK:" "${MERGE_ARGS[@]}"
reset_fx; green_fx; tip_pipes running
tip_ran P9 "a running tip pipeline is not red: the merge runs and names it PENDING" "PENDING" "${MERGE_ARGS[@]}"
reset_fx; green_fx; pipes_are "$(pipe 8000000003 success)" "$(pipe 8000000002 failed)"
tip_ran P10 "an older failed pipeline superseded by a newer SUCCESS of the same source -> runs" "no judged run is red" "${MERGE_ARGS[@]}"
reset_fx; green_fx; pipes_are "$(pipe 8000000003 running)" "$(pipe 8000000002 failed)"
tip_refused P11 "an older failed pipeline, the newer one only running -> still red" "does not supersede" "${MERGE_ARGS[@]}"
reset_fx; green_fx; pipes_are "$(pipe 8000000003 success)" "$(pipe 8000000002 failed parent_pipeline)"
tip_refused P12 "a failed child pipeline, older than a green push pipeline -> red (each source's latest is judged; another source never supersedes it)" "MAIN RED:" "${MERGE_ARGS[@]}"
reset_fx; green_fx; tip_pipes canceled
tip_refused P13 "a canceled tip pipeline is red" "MAIN RED:" "${MERGE_ARGS[@]}"
reset_fx; green_fx; tip_pipes canceling
tip_refused P13b "a canceling tip pipeline is red (it ends canceled)" "MAIN RED:" "${MERGE_ARGS[@]}"
reset_fx; green_fx; pipes_are "$(pipe 8000000003 success web)" "$(pipe 8000000002 failed push)"
tip_refused P13c "a newer SUCCESS of another source (a web run) does not clear a failed push pipeline" "MAIN RED:" "${MERGE_ARGS[@]}"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"/retry"* ]] && ok "P13d. the Fix says a red pipeline clears when it is retried and passes" || bad "P13d. retry Fix" "$(detail)"
reset_fx; green_fx; tip_pipes bogus_status
tip_refused P14 "a status the judge does not know -> COULD NOT LOOK" "COULD NOT LOOK:" "${MERGE_ARGS[@]}"
reset_fx; green_fx; printf '[%s]\n' "$(pipe 8000000001 success push "${OLD_TIP}")" > "${FX}/pipes.out"
tip_refused P15 "a listed pipeline whose sha is not the tip -> COULD NOT LOOK" "COULD NOT LOOK:" "${MERGE_ARGS[@]}"
reset_fx; green_fx; printf '[%s]\n' "$(pipe 8000000001 success push "${TIP_FX}" other-branch)" > "${FX}/pipes.out"
tip_refused P16 "a listed pipeline on another ref -> COULD NOT LOOK" "COULD NOT LOOK:" "${MERGE_ARGS[@]}"
reset_fx; green_fx
p100="$(for i in $(seq 1 100); do pipe "$((8000000100 + i))" success; printf ','; done)"; printf '[%s]\n' "${p100%,}" > "${FX}/pipes.out"
tip_refused P17 "a full page of 100 pipelines (more may exist) -> COULD NOT LOOK" "COULD NOT LOOK:" "${MERGE_ARGS[@]}"
reset_fx; green_fx
receipt_ran P18 "a green tip: the merge runs and names the tip" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"BASE-TIP main ${TIP_FX}"* ]] && [[ "$(reads)" == *"api --hostname gitlab.com projects/7000001/pipelines?sha=${TIP_FX}&ref=main&per_page=100"* ]] \
  && ok "P18b. the tip's pipelines were read on the MR's host, for the tip and the target" || bad "P18b. tip read" "$(detail)"
[[ "${ERR}" == *"content: no check declared for example-group/example-app"* ]] \
  && ok "P18c. a project with no content declaration says so, naming the key it looked up" || bad "P18c. content key named" "$(detail)"
reset_fx; nogate_fx; tip_pipes failed
receipt_refused P19 "a red tip does not excuse a missing receipt (the receipt is read first)" "NO RECEIPT" "${MERGE_ARGS[@]}"

# The GitLab lock path (DND-1943) makes this exact call and maps the guard's
# refusal to its exit 11 (MAIN RED) or 2 (COULD NOT LOOK) by the shared
# classifier gmg_refusal_has_reason. Contract: this guard's refusal, for that
# argv, is one the classifier reads; a format drift would read as exit 4.
LOCK_ARGS=(mr merge 4242 -R example-group/example-app --squash --sha "${HEAD_SHA}" --auto-merge=false --yes)
lock_class() {
  printf '%s\n' "${ERR}" > "${TMP}/lock-err"
  ( . "${HERE}/../../lib/gh-merge-guard.sh" >/dev/null 2>&1 || exit 9
    gmg_refusal_has_reason "${TMP}/lock-err" "$1" )
}
reset_fx; green_fx; tip_pipes failed
tip_refused P20 "the lock tool's argv onto a failed tip -> refused (MAIN RED)" "MAIN RED:" "${LOCK_ARGS[@]}"
lock_class "MAIN RED:" && ok "P20b. the lock tool's classifier reads it as MAIN RED (its exit 11)" || bad "P20b. MAIN RED classified" "$(detail)"
reset_fx; green_fx; fx pipes '[]'
tip_refused P21 "the lock tool's argv onto a tip with no pipeline -> COULD NOT LOOK" "COULD NOT LOOK:" "${LOCK_ARGS[@]}"
lock_class "COULD NOT LOOK:" && ok "P21b. the lock tool's classifier reads it as COULD NOT LOOK (its exit 2)" || bad "P21b. LOOK classified" "$(detail)"
! lock_class "MAIN RED:" && ok "P21c. and not as MAIN RED" || bad "P21c. LOOK misread as red" "$(detail)"
reset_fx; green_fx
receipt_ran P22 "the lock tool's argv onto a green tip -> runs" "${LOCK_ARGS[@]}"

echo
echo "--- DND-1941: the tip's CONTENT (ai/config/main-content-checks.json) ---"
# The declaration lists each product's project paths; the GitLab project
# athena-ai-harness/gen_saas resolves the gen_saas entry (DND-2034). A fixture
# checkout of it, its tip holding two migrations with one version.
GS="${TMP}/gen_saas"; MIG="apps/athena/priv/repo/migrations"
git init -q -b main "${GS}"
gs() { git -C "${GS}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
gs remote add origin git@gitlab.com:athena-ai-harness/gen_saas.git
mkdir -p "${GS}/${MIG}"; : > "${GS}/${MIG}/20250101000000_init.exs"; gs add -A; gs commit -q -m base
GS_BASE="$(gs rev-parse HEAD)"
: > "${GS}/${MIG}/20250101000000_other.exs"; gs add -A; gs commit -q -m dup
GS_DUP="$(gs rev-parse HEAD)"
gs mv "${MIG}/20250101000000_other.exs" "${MIG}/20250102000000_other.exs"; gs commit -q -m fix
GS_FIX="$(gs rev-parse HEAD)"
gs checkout -q -b still "${GS_DUP}"; : > "${GS}/${MIG}/20250103000000_more.exs"; gs add -A; gs commit -q -m still
GS_STILL="$(gs rev-parse HEAD)"
gs checkout -q -b feat "${GS_BASE}"; : > "${GS}/${MIG}/20250104000000_feat.exs"; gs add -A; gs commit -q -m feat
GS_FEAT="$(gs rev-parse HEAD)"
gs checkout -q main
GS_STORE="$(git -C "${GS}" rev-parse --path-format=absolute --git-common-dir)/integration-receipts"
# gs_fx <head> <tip> [project] : MR !77 of <project> (default
# athena-ai-harness/gen_saas),
# head <head> with a passed branch pipeline on it, the target tip <tip> with a
# passed main pipeline, and a sealed receipt for <head> on <tip>.
gs_fx() {
  local m
  m="$(printf '{"iid":77,"project_id":7000002,"sha":"%s","target_branch":"main","web_url":"https://gitlab.com/%s/-/merge_requests/77","head_pipeline":{"id":9000000077,"sha":"%s","ref":"feat","status":"success"}}' "$1" "${3:-athena-ai-harness/gen_saas}" "$1")"
  printf '%s\n' "$m" > "${FX}/mrview.out"; printf '%s\n' "$m" > "${FX}/mrapi.out"
  printf '{"name":"main","commit":{"id":"%s"}}\n' "$2" > "${FX}/branch.out"
  printf '[%s]\n' "$(pipe 8000000077 success push "$2")" > "${FX}/pipes.out"
  printf '[{"id":1,"head_commit_sha":"%s"}]\n' "$1" > "${FX}/versions.out"
  rm -rf "${GS_STORE}"; STORE_FX="${GS_STORE}" plant "$1" "$2"
}
cd "${GS}" || exit 2
reset_fx; gs_fx "${GS_FEAT}" "${GS_DUP}"
tip_refused GS1 "THE MISS: an ordinary MR onto a tip with a duplicated migration version -> refused" "Duplicated migration version" mr merge 77 --sha "${GS_FEAT}" --auto-merge=false --yes
[[ "${ERR}" == *"MAIN RED:"* ]] && [[ "${ERR}" == *"20250101000000_init.exs, 20250101000000_other.exs"* ]] \
  && ok "GS1b. it is MAIN RED and names both files" || bad "GS1b. dup files named" "$(detail)"
reset_fx; gs_fx "${GS_FIX}" "${GS_DUP}"
tip_ran GS2 "a red-main fix (contains the tip, removes the duplicate) -> runs" "RED-MAIN FIX" mr merge 77 --sha "${GS_FIX}" --auto-merge=false --yes
reset_fx; gs_fx "${GS_STILL}" "${GS_DUP}"
tip_refused GS3 "a head that contains the tip but keeps the duplicate -> refused" "still holds" mr merge 77 --sha "${GS_STILL}" --auto-merge=false --yes
reset_fx; gs_fx "${GS_FEAT}" "${GS_BASE}"
tip_ran GS4 "the GitLab project athena-ai-harness/gen_saas resolves the gen_saas declaration: a clean tip is read and runs" "no duplicated migration version (1 director(ies), 1 migration(s) read)" mr merge 77 --sha "${GS_FEAT}" --auto-merge=false --yes
reset_fx; gs_fx "${GS_FEAT}" "${GS_DUP}"
tip_refused GS5 "the same refusal on the train" "Duplicated migration version" api -X POST "projects/:id/merge_trains/merge_requests/77" -f "sha=${GS_FEAT}"
reset_fx; gs_fx "0123456789abcdef0123456789abcdef01234567" "${GS_DUP}"
tip_refused GS6 "a duplicated tip and a head not in the local store -> COULD NOT LOOK (whether it is a fix cannot be read)" "COULD NOT LOOK:" mr merge 77 --sha 0123456789abcdef0123456789abcdef01234567 --auto-merge=false --yes
[[ "${ERR}" == *"fetch the PR branch"* ]] && [[ "${ERR}" == *"holds a duplicated migration version"* ]] \
  && ok "GS6b. it says to fetch the head, and still names the duplicate" || bad "GS6b. fetch named" "$(detail)"

# DND-2034: gen_saas moved to the athena-ai-harness group (the same GitLab
# project). The declaration was keyed on cjpoll/gen_saas alone, so an MR on
# the new path found no entry and merged onto a duplicated tip, exit 0.
reset_fx; gs_fx "${GS_FEAT}" "${GS_DUP}" athena-ai-harness/gen_saas
tip_refused GM1 "THE MOVE: an MR on athena-ai-harness/gen_saas onto a duplicated tip -> refused" "Duplicated migration version" mr merge 77 --sha "${GS_FEAT}" --auto-merge=false --yes
reset_fx; gs_fx "${GS_FEAT}" "${GS_BASE}" athena-ai-harness/gen_saas
tip_ran GM2 "athena-ai-harness/gen_saas resolves the gen_saas declaration: a clean tip is read and runs" "no duplicated migration version (1 director(ies), 1 migration(s) read)" mr merge 77 --sha "${GS_FEAT}" --auto-merge=false --yes
# The class: a declared product under a path the declaration does not list
# (the stale pre-move path, the next move) is refused by name, never read as
# "no check".
for gm in "GM3 cjpoll" "GM4 example-moved"; do
  set -- ${gm}
  gs remote set-url origin "git@gitlab.com:$2/gen_saas.git"
  reset_fx; gs_fx "${GS_FEAT}" "${GS_BASE}" "$2/gen_saas"
  tip_refused "$1" "a declared product's name under the undeclared path $2/gen_saas -> COULD NOT LOOK, never 'no check declared'" "COULD NOT LOOK:" mr merge 77 --sha "${GS_FEAT}" --auto-merge=false --yes
  [[ "${ERR}" == *"$2/gen_saas"* ]] && [[ "${ERR}" == *"main-content-checks.json"* ]] && [[ "${ERR}" != *"no check declared"* ]] \
    && ok "$1b. it names the path it looked up and the declaration to add it to" || bad "$1b. undeclared path named" "$(detail)"
done
gs remote set-url origin git@gitlab.com:athena-ai-harness/gen_saas.git
cd "${REPO_FX}" || exit 2

echo
echo "--- DND-1941: the shared content key is never computed wrong silently ---"
# gmg_content_re (ai/lib/gh-merge-guard.sh, shared by both guards): a key that
# is malformed for its type is an error, never "no check declared".
key_rc() { ( . "${AI_DIR}/lib/gh-merge-guard.sh" >/dev/null 2>&1; gmg_content_re "$1" "$2"; echo "rc=$? re=${GMG_CONTENT_RE} key=${GMG_CONTENT_KEY:-} why=${GMG_CONTENT_WHY:-} entry=${GMG_CONTENT_ENTRY:-}" ); }
out="$(key_rc "" gen_saas)"; [[ "${out}" == rc=2* ]] && [[ "${out}" == *"malformed"* ]] && ok "K1. an empty owner is an error, not 'no check'" || bad "K1. empty owner" "${out}"
out="$(key_rc cjpoll "")"; [[ "${out}" == rc=2* ]] && ok "K2. an empty repo is an error" || bad "K2. empty repo" "${out}"
out="$(key_rc "cj poll" gen_saas)"; [[ "${out}" == rc=2* ]] && ok "K3. whitespace in a key is an error" || bad "K3. whitespace" "${out}"
out="$(key_rc CJPoll gen_saas)"; [[ "${out}" == rc=2* ]] && [[ "${out}" == *"key=cjpoll/gen_saas "* ]] && [[ "${out}" == *"athena-ai-harness/gen_saas"* ]] \
  && ok "K4. the pre-move path CJPoll/gen_saas is not declared: an error naming the declared path (case-folded)" || bad "K4. stale path" "${out}"
out="$(key_rc cjpoll gen_saas_v2)"; [[ "${out}" == "rc=0 re= key=cjpoll/gen_saas_v2"* ]] && ok "K5. a different project name is not a near miss: no check declared" || bad "K5. other name" "${out}"
out="$(key_rc example-group/sub example-app)"; [[ "${out}" == "rc=0 re= key=example-group/sub/example-app"* ]] && ok "K6. a nested GitLab group is one key, and an undeclared one is named" || bad "K6. nested key" "${out}"
out="$(key_rc athena-ai-harness gen_saas)"; [[ "${out}" == rc=0*"apps/"* ]] && ok "K7. the moved path athena-ai-harness/gen_saas resolves the gen_saas entry (DND-2034)" || bad "K7. moved path" "${out}"
out="$(key_rc Athena-AI-Harness gen_saas)"; [[ "${out}" == rc=0*"apps/"* ]] && ok "K8. the moved path resolves case-folded" || bad "K8. moved path case" "${out}"
# A wrongly computed key: the right project name under a namespace the
# declaration does not list. It must say so, never read as "no check".
out="$(key_rc athena-ai-harness/sub gen_saas)"; [[ "${out}" == rc=2* ]] && [[ "${out}" == *"athena-ai-harness/sub/gen_saas"* ]] && [[ "${out}" == *"athena-ai-harness/gen_saas"* ]] \
  && ok "K9. a declared product's name under an undeclared path is an error naming the key and the declared paths" || bad "K9. undeclared path of a declared product" "${out}"
# custom declares no content check (it has no migration directory). Its
# path is declared, and its NONE note says it is a declared product.
out="$(key_rc athena-ai-harness custom)"; [[ "${out}" == "rc=0 re= key=athena-ai-harness/custom "*"entry=custom" ]] \
  && ok "K10. athena-ai-harness/custom resolves custom's entry, which declares no content check" || bad "K10. custom path" "${out}"
out="$( . "${AI_DIR}/lib/gh-merge-guard.sh" >/dev/null 2>&1; gmg_content_re athena-ai-harness custom; gmg_content_none_note )"
[[ "${out}" == "the declared product custom (athena-ai-harness/custom) declares no content check" ]] \
  && ok "K11. its note names the declared product, not 'no check declared'" || bad "K11. declared-product note" "${out}"
out="$(key_rc cjpoll custom)"; [[ "${out}" == rc=2* ]] && [[ "${out}" == *"athena-ai-harness/custom"* ]] \
  && ok "K12. custom's pre-move path is an error too, even with no check to run" || bad "K12. custom near miss" "${out}"
# The near-miss rule's two halves, each alone: the key's project name equals
# an entry's NAME (whose paths end otherwise), or a declared PATH's last
# segment (whose entry is named otherwise).
NM_CFG="${TMP}/near-miss.json"
printf '%s' '{"schema":"main-content-checks/2","repos":{"foo":{"paths":["a/bar"],"unique_migration_dirs":"^m$"}}}' > "${NM_CFG}"
nm_rc() { ( . "${AI_DIR}/lib/gh-merge-guard.sh" >/dev/null 2>&1; GMG_CONTENT_CONFIG="${NM_CFG}"; gmg_content_re "$1" "$2"; echo "rc=$? why=${GMG_CONTENT_WHY:-}" ); }
out="$(nm_rc x foo)"; [[ "${out}" == rc=2*"declared product 'foo'"* ]] && ok "K13. a key named like an entry (not like its paths) is a near miss" || bad "K13. entry-name half" "${out}"
out="$(nm_rc x bar)"; [[ "${out}" == rc=2*"declared product 'foo'"* ]] && ok "K14. a key named like a declared path's last segment is a near miss" || bad "K14. path-segment half" "${out}"
out="$(nm_rc a bar)"; [[ "${out}" == "rc=0 why=" ]] && ok "K15. the declared path itself is a hit" || bad "K15. hit" "${out}"

echo "--- DND-1939: a merge glab-athena ran is merge.landed once confirm-merged sees it ---"
LANDED_SHA="5b3a7d0c9e8f6a4b2c1d0e9f8a7b6c5d4e3f2a1b"
landed() { cat "$1"/*.jsonl 2>/dev/null | jq -c 'select(.event == "merge.landed")'; }
landed_n() { local n; n="$(landed "$1" | grep -c .)"; printf '%s' "${n:-0}"; }
# merged_fx [merge sha] [squash sha] : the forge's answer after the merge ran.
merged_fx() {
  local m="${1:-null}" q="${2:-null}"
  [ "${m}" = null ] || m="\"${m}\""; [ "${q}" = null ] || q="\"${q}\""
  for f in mrview mrapi; do
    jq -c --argjson m "${m}" --argjson q "${q}" \
      '.state = "merged" | .merged_at = "2026-10-03T12:00:00Z" | .merge_commit_sha = $m | .squash_commit_sha = $q | .source_branch = "dnd-1-synthetic-unit"' \
      "${FX}/${f}.out" > "${FX}/${f}.after.out"
  done
  # The project, for its default branch and merge method (read only once the
  # MR is merged).
  printf '{"id":7000001,"default_branch":"%s","merge_method":"%s","visibility":"private"}\n' "${3:-main}" "${4:-merge}" > "${FX}/project.out"
}
# land_run <store> <args…> : the wrapper with its own telemetry store.
land_run() { local s="$1"; shift; OUT="$(ATHENA_TELEMETRY_DIR="${s}" "${WRAPPER}" "$@" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"; }

reset_fx; green_fx; merged_fx "${LANDED_SHA}"; S="${TMP}/m1-store"
land_run "${S}" "${MERGE_ARGS[@]}"
EV="$(landed "${S}")"
if ran_once "${MERGE_ARGS[@]}" && [ "$(landed_n "${S}")" = 1 ] \
  && [ "$(jq -cS .attrs <<<"${EV}")" = "$(jq -cnS --arg b "${TIP_FX}" --arg a "${LANDED_SHA}" '{via:"mr",mr:4242,before:$b,after:$a}')" ] \
  && [ "$(jq -r .head <<<"${EV}")" = "${HEAD_SHA}" ] && [ "$(jq -r .repo <<<"${EV}")" = example-app ] \
  && [ "$(jq -r '[.unit, .unit_source] | join(" ")' <<<"${EV}")" = "DND-1 branch" ] \
  && [[ "$(reads)" == *"mr view 4242 -F json"* ]] && [[ "$(reads)" == *"api --hostname gitlab.com projects/7000001"* ]] \
  && [ ! -e "${S}/write-failures" ] && ! grep -rqF "${FAKE_TOKEN}" "${S}" && [[ "${ERR}" != *"merge.landed"* ]]; then
  ok "ML1. a merge glab ran and confirm-merged then sees: one merge.landed via=mr (mr, before = the target tip the guard read, after = the merge commit, head = the MR head, unit from the source branch), repo = the checkout's key, no token in the store"
else bad "ML1. merge.landed on a confirmed MR merge" "$(detail) ev='${EV}' failures='$(cat "${S}/write-failures" 2>/dev/null)'"; fi

reset_fx; green_fx; merged_fx null "${LANDED_SHA}"; S="${TMP}/m2-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 1 ] && [ "$(landed "${S}" | jq -r .attrs.after)" = "${LANDED_SHA}" ] \
  && ok "ML2. a squash with no merge commit (fast-forward method): after = the squash commit" \
  || bad "ML2. squash commit as after" "$(detail) ev='$(landed "${S}")'"

reset_fx; green_fx; merged_fx null null main ff; S="${TMP}/m3-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 1 ] && [ "$(landed "${S}" | jq -r .attrs.after)" = "${HEAD_SHA}" ] \
  && ok "ML3. a fast-forward merge (no merge or squash commit): after = the MR head itself" \
  || bad "ML3. ff merge after" "$(detail) ev='$(landed "${S}")'"

# ML15. No merge or squash commit on a project that is NOT fast-forward: the
# head is not what landed, so the missing commit is a miss, never the head.
reset_fx; green_fx; merged_fx null null main merge; S="${TMP}/m15-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 0 ] && [[ "${ERR}" == *"no merge.landed recorded for !4242:"*"merge_method 'merge'"* ]] \
  && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "ML15. no merge or squash commit on a merge-commit project: no event (the head is not the landed commit), the miss is said with a Fix:" \
  || bad "ML15. null merge commit on a non-ff project" "$(detail) ev='$(landed "${S}")'"

# open_fx : the forge's answer after the merge ran: the MR still open.
open_fx() { jq -c '.state = "opened" | .merged_at = null' "${FX}/mrview.out" > "${FX}/mrview.after.out"; }
reset_fx; green_fx; open_fx; S="${TMP}/m4-store"
land_run "${S}" "${MERGE_ARGS[@]}"
if ran_once "${MERGE_ARGS[@]}" && [ "$(landed_n "${S}")" = 0 ] && [ "$(grep -c 'mr view 4242 -F json' "${STUB_READS}")" = 3 ] \
  && [[ "${ERR}" == *"no merge.landed recorded for !4242: glab exited 0, but confirm-merged did not see it merged in 2 read(s)"* ]] \
  && [[ "${ERR}" == *"Fix:"* ]] && [[ "${ERR}" == *"confirm-merged --mr 4242"* ]]; then
  ok "ML4. glab returned 0 but confirm-merged never sees the merge (bounded tries): no event, exit 0 kept, the miss is said with a Fix:"
else bad "ML4. unconfirmed merge" "$(detail)"; fi

reset_fx; green_fx; open_fx; printf '1' > "${FX}/exec.rc"; S="${TMP}/m5-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 1 ] && [ "$(landed_n "${S}")" = 0 ] && [ "$(execs)" = "${MERGE_ARGS[*]}" ] && [[ "${ERR}" != *"merge.landed"* ]] \
  && ok "ML5. a merge glab refused (exit 1), cleanly not merged: exit 1 passed through, no event, no miss line" \
  || bad "ML5. refused merge" "$(detail)"

reset_fx; green_fx; printf '1' > "${FX}/exec.rc"; merged_fx "${LANDED_SHA}"; S="${TMP}/m6-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 1 ] && [ "$(landed_n "${S}")" = 1 ] \
  && ok "ML6. a merge call that failed but landed anyway (DND-1324's shape): exit 1 kept, the confirmed landing is recorded" \
  || bad "ML6. failed call that landed" "$(detail) ev='$(landed "${S}")'"

reset_fx; green_fx; merged_fx "${LANDED_SHA}"; jq -c '.state = "opened"' "${FX}/mrapi.out" > "${FX}/mrapi.after.out"; S="${TMP}/m7-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 0 ] && [[ "${ERR}" == *"no merge.landed"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "ML7. confirm-merged says merged but the project-keyed MR read does not: no event, said with a Fix:" \
  || bad "ML7. disagreeing reads" "$(detail) ev='$(landed "${S}")'"

reset_fx; green_fx; merged_fx "${LANDED_SHA}"; S="${TMP}/m8-store"
land_run "${S}" mr list
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 0 ] && [ ! -s "${STUB_READS}" ] \
  && ok "ML8. a command that is not a merge: no confirm read, no event" \
  || bad "ML8. non-merge command" "$(detail)"

# could_not_look : the miss names COULD NOT LOOK, carries a Fix: whose hand
# record matches the automatic one (before, unit branch), and no event.
could_not_look() { [ "$(landed_n "${S}")" = 0 ] && [[ "${ERR}" == *"no merge.landed recorded for !4242: COULD NOT LOOK"* ]] \
  && [[ "${ERR}" == *"Fix:"* ]] && [[ "${ERR}" == *"--attr before=${TIP_FX}"* ]] && [[ "${ERR}" == *"--unit-branch"* ]]; }
reset_fx; green_fx; printf '1' > "${FX}/mrview.after.rc"; printf 'glab: 502 Bad Gateway\n' > "${FX}/mrview.after.err"; S="${TMP}/m9-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 0 ] && could_not_look && [ "$(grep -c 'mr view 4242 -F json' "${STUB_READS}")" = 3 ] \
  && ok "ML9. glab exited 0 but the confirm read errors (confirm-merged exit 3): COULD NOT LOOK, not \"not merged\", with a Fix:" \
  || bad "ML9. confirm read errors after a 0 exit" "$(detail)"

reset_fx; green_fx; printf '1' > "${FX}/exec.rc"; printf '1' > "${FX}/mrview.after.rc"; S="${TMP}/m10-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 1 ] && could_not_look && [ "$(grep -c 'mr view 4242 -F json' "${STUB_READS}")" = 2 ] \
  && ok "ML10. glab exited 1 and the one confirm read errors: whether it landed is unknown, so it is said (COULD NOT LOOK), exit 1 kept" \
  || bad "ML10. confirm read errors after a failed call" "$(detail)"

reset_fx; green_fx; merged_fx "${LANDED_SHA}" null develop; S="${TMP}/m11-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 0 ] && [[ "${ERR}" == *"!4242 merged into main, not the default branch develop: no merge.landed"* ]] \
  && ok "ML11. an MR merged into a branch that is not the project's default: no event, the skip is said" \
  || bad "ML11. non-default target" "$(detail)"

reset_fx; green_fx; merged_fx "${LANDED_SHA}"; rm -f "${FX}/project.out"; printf '1' > "${FX}/project.rc"; S="${TMP}/m12-store"
land_run "${S}" "${MERGE_ARGS[@]}"
[ "${RC}" = 0 ] && could_not_look && [[ "${ERR}" == *"default branch"* ]] \
  && ok "ML12. the project's default branch cannot be read: COULD NOT LOOK, no event" \
  || bad "ML12. project unreadable" "$(detail)"

# ML13. Fail-open: a telemetry store that cannot be written changes nothing
# the caller sees (exit code, stdout).
reset_fx; green_fx; merged_fx "${LANDED_SHA}"; printf 'x' > "${TMP}/not-a-dir"; S="${TMP}/not-a-dir"
land_run "${S}" "${MERGE_ARGS[@]}"
ran_once "${MERGE_ARGS[@]}" && [ "${OUT}" = "stub: ran ${MERGE_ARGS[*]}" ] \
  && ok "ML13. an unwritable telemetry store: the merge's exit 0 and stdout are unchanged (fail-open)" \
  || bad "ML13. fail-open on an unwritable store" "$(detail)"

# ML14. A checkout missing ai/lib/glab-landing.sh: the merge still runs, its
# exit code and stdout unchanged, and the miss is said with a Fix:.
# The copy is a real file (the wrapper resolves its own dir with readlink -f);
# every other file is a link to this tree, glab-landing.sh left out.
FB="${TMP}/fallback/ai"; mkdir -p "${FB}/bin" "${FB}/lib"
for f in "${AI_DIR}"/*; do case "${f##*/}" in bin|lib) ;; *) ln -s "${f}" "${FB}/${f##*/}" ;; esac; done
for f in "${AI_DIR}"/bin/*; do ln -s "${f}" "${FB}/bin/${f##*/}"; done
for f in "${AI_DIR}"/lib/*; do [ "${f##*/}" = glab-landing.sh ] || ln -s "${f}" "${FB}/lib/${f##*/}"; done
rm -f "${FB}/bin/glab-athena"; cp "${AI_DIR}/bin/glab-athena" "${FB}/bin/glab-athena"
reset_fx; green_fx; merged_fx "${LANDED_SHA}"; S="${TMP}/m14-store"
OUT="$(ATHENA_TELEMETRY_DIR="${S}" "${FB}/bin/glab-athena" "${MERGE_ARGS[@]}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
ran_once "${MERGE_ARGS[@]}" && [ "${OUT}" = "stub: ran ${MERGE_ARGS[*]}" ] && [ "$(landed_n "${S}")" = 0 ] \
  && [[ "${ERR}" == *"no merge.landed recorded for !4242: cannot load"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "ML14. glab-landing.sh missing: the merge runs unchanged, the miss is said with a Fix:" \
  || bad "ML14. missing landing lib" "$(detail)"

echo
echo "--- the dry-run seam ---"
reset_fx; green_fx
OUT="$(GLAB_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: would exec glab mr merge 4242 --auto-merge=false --sha ${HEAD_SHA}"* ]] && [ ! -s "${STUB_EXECS}" ] && [ -s "${STUB_READS}" ]; then
  ok "D1. dry-run runs the guard's reads and execs nothing"
else bad "D1. dry-run seam" "$(detail)"; fi
reset_fx; green_fx
OUT="$(GLAB_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" mr merge 4242 --auto-merge=false 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if refused; then ok "D2. dry-run still refuses"; else bad "D2. dry-run refusal" "$(detail)"; fi
reset_fx; nogate_fx
OUT="$(GLAB_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" mr merge 4242 --auto-merge=false --sha "${HEAD_SHA}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if refused && [[ "${ERR}" == *"NO RECEIPT"* ]]; then ok "D3. dry-run with no receipt refuses the same way (DND-1845)"; else bad "D3. dry-run receipt refusal" "$(detail)"; fi

# DND-1647: no gh/glab call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

echo
echo "==================================================="
echo "RESULT: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" = 0 ]; then echo "ALL CASES PASS"; exit 0; fi
exit 1
