#!/usr/bin/env bash
# Self-test for locked-merge's GitLab path (--mr, DND-1943).
#
# The defect: locked-merge exited 2 on any origin but github.com, so a GitLab
# project with no merge train (gitlab.com Free) had no locked merge. Two
# admirals merging there hit the TOCTOU locked-merge exists to close (a squash
# onto a base that moved after the gate, landing a tree nobody computed). The
# cases that matter are the misses: a head that moved (g2), a red tip (g4,
# g7), a landing on another base or tree (g13), and a project that has a
# merge train (g9), which must keep boarding the train and never reach the
# merge call here.
#
# The GitHub suite (../locked-merge/self-test.sh) is unchanged by DND-1943.
#
# Hermetic: a local bare "origin" reached through a gitlab.com URL via
# url.insteadOf, a plain-glab stub on PATH for the reads, and AI_BIN stubs for
# glab-athena, confirm-merged and teardown-stack. Every guard refusal the
# glab-athena stub prints comes from the guard library's own glmg_refuse, with
# the shared marks from gh-merge-guard.sh, so a format change reaches the
# stub. The pipeline half of the red-tip judge runs inside the real wrapper
# (DND-1941); here the stub stands for its refusal.
#
# Functional only (DND-1222): the lock wait is shown by an event (a held
# flock, the tool's flock child), never by a wall-clock sleep.
#
# Run: bash ai/skills/athena:merge-boarding/test/locked-merge-gitlab/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/scripts/locked-merge"
LIB="$(cd "${HERE}/../../../.." && pwd)/lib"

PASS=0; FAIL=0
TMP="$(mktemp -d)"; g8pid=""
# g8 runs the tool in the background: never leave it behind.
trap '[ -n "${g8pid}" ] && kill "${g8pid}" 2>/dev/null; rm -rf "${TMP}"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOCKED_MERGE_CONFIRM_SLEEP=0
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry"
export ATHENA_SECRETS_ROOT="${TMP}/secrets"
SEAL="$(cd "${HERE}/../../../../bin" && pwd)/receipt-seal"
unset ATHENA_UNIT

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '       %s\n' "$2"; }

# ---- stubs ----
. "${LIB}/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
STUBS="${TMP}/stubs"; mkdir -p "${STUBS}"
cat > "${STUBS}/glab" <<'EOF'
#!/usr/bin/env bash
# plain-glab stub (reads only; argv logged to $ST/glab.log). The endpoint is
# the last word: projects/<enc> reads $ST/project.json,
# projects/<enc>/merge_requests/<iid> reads $ST/mr.json. $ST/glab_fail -> exit 1.
echo "$*" >> "${ST}/glab.log"
[ "$1" = api ] || { echo "glab stub: unexpected $*" >&2; exit 99; }
[ -e "${ST}/glab_fail" ] && { echo "glab: 401 Unauthorized" >&2; exit 1; }
ep="${!#}"
case "${ep}" in
  projects/*/merge_requests/*) cat "${ST}/mr.json" ;;
  projects/*) cat "${ST}/project.json" ;;
  *) echo "glab stub: unexpected endpoint ${ep}" >&2; exit 99 ;;
esac
EOF
cat > "${STUBS}/glab-athena" <<'EOF'
#!/usr/bin/env bash
# glab-athena stub: logs argv, then lands per $ST/merge_mode into the bare
# origin the way GitLab does on a merge-method project with squash: a squash
# commit S (the head's tree, on the merge base) and a merge commit M with
# parents [main, S]. Mode ff: S alone, on main (a fast-forward project).
echo "$*" >> "${ST}/merge.log"
mode="$(cat "${ST}/merge_mode")"
[ "${mode}" = refuse ] && { echo "glab: 405 Method Not Allowed" >&2; exit 1; }
. "${LIB}/gh-merge-guard.sh" || exit 99
. "${LIB}/glab-merge-guard.sh" || exit 99
refuse() { ( glmg_refuse "$@" ); exit $?; }
[ "${mode}" = redtip ] && refuse 'glab mr merge' "${GMG_RED_MARK} main tip abc is RED, so the line is stopped (DND-1902)." 'land only a red-main fix'
[ "${mode}" = looktip ] && refuse 'glab mr merge' "${GMG_LOOK_MARK} whether the main tip abc is red cannot be told: the pipelines read failed." 'check glab auth, then re-run'
[ "${mode}" = guardother ] && refuse 'glab mr merge' "!7's head pipeline 5 is 'failed', not success" 'wait for green'
sha=""; prev=""
for a in "$@"; do [ "${prev}" = "--sha" ] && sha="${a}"; prev="${a}"; done
G="git --git-dir=${BARE}"
if [ "${mode}" = moved ]; then
  x="$(${G} commit-tree "$(${G} rev-parse main^{tree})" -p "$(${G} rev-parse main)" -m other)"
  ${G} update-ref refs/heads/main "${x}"
fi
main="$(${G} rev-parse main)"
mb="$(${G} merge-base "${main}" "${sha}")"
s="$(${G} commit-tree "$(${G} rev-parse "${sha}^{tree}")" -p "${mb}" -m squash)"
tree="$(${G} merge-tree --write-tree "${main}" "${s}" 2>/dev/null)" || { echo "glab: 406 merge conflict" >&2; exit 1; }
tree="$(head -1 <<<"${tree}")"
[ "${mode}" = badtree ] && tree="$(${G} rev-parse main^{tree})"
if [ "${mode}" = ff ]; then
  s="$(${G} commit-tree "${tree}" -p "${main}" -m squash)"
  ${G} update-ref refs/heads/main "${s}"
  jq --arg s "${s}" '.state="merged" | .merge_commit_sha=null | .squash_commit_sha=$s' "${ST}/mr.json" > "${ST}/mr.tmp"
else
  m="$(${G} commit-tree "${tree}" -p "${main}" -p "${s}" -m merge)"
  ${G} update-ref refs/heads/main "${m}"
  jq --arg m "${m}" --arg s "${s}" '.state="merged" | .merge_commit_sha=$m | .squash_commit_sha=$s' "${ST}/mr.json" > "${ST}/mr.tmp"
fi
mv "${ST}/mr.tmp" "${ST}/mr.json"
[ "${mode}" = err502 ] && { echo "glab: 502 Bad Gateway" >&2; exit 1; }
exit 0
EOF
cat > "${STUBS}/confirm-merged" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ST}/confirm.log"
exit "$(cat "${ST}/confirm_rc")"
EOF
cat > "${STUBS}/teardown-stack" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ST}/teardown.log"
if flock -n 7 7>>"${LOCK_PATH}"; then echo "lock free" >> "${ST}/teardown.log"; else echo "lock held" >> "${ST}/teardown.log"; fi
exit 0
EOF
chmod +x "${STUBS}"/*
fsg_require_stubs "${STUBS}" glab
export PATH="${STUBS}:${PATH}" LOCKED_MERGE_AI_BIN="${STUBS}" LIB

# fixture <name> [origin-url] -- fresh bare origin + clone "wt" on a feature
# head H; MR !7 open on H; a project with no merge train. Sets ST, BARE, WT, H.
fixture() {
  local d="${TMP}/$1" url="${2:-https://gitlab.com/t/proj.git}"; mkdir -p "${d}/st"
  export ST="${d}/st" BARE="${d}/origin.git"
  git init -q --bare -b main "${BARE}"
  WT="${d}/wt"; git init -q -b main "${WT}"
  git -C "${WT}" config remote.origin.url "${url}"
  git -C "${WT}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "${WT}" config "url.${BARE}.insteadOf" "${url}"
  ( cd "${WT}" && echo seed > seed.txt && git add seed.txt && git commit -qm seed && git push -q origin main \
    && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f && git push -q origin feature )
  H="$(git -C "${WT}" rev-parse HEAD)"
  jq -n --arg h "${H}" '{iid:7, project_id:11, source_project_id:11, target_project_id:11, state:"opened", sha:$h,
    source_branch:"dnd-42-fixture", target_branch:"main", merge_commit_sha:null, squash_commit_sha:null}' > "${ST}/mr.json"
  echo '{"id":11,"path_with_namespace":"t/proj","merge_method":"merge"}' > "${ST}/project.json"
  echo good > "${ST}/merge_mode"; echo 0 > "${ST}/confirm_rc"
  : > "${ST}/teardown.log"; : > "${ST}/merge.log"; : > "${ST}/confirm.log"; : > "${ST}/glab.log"
  export LOCK_PATH="${TMP}/$1.lock"
  plant_receipt "${H}" "$(git --git-dir="${BARE}" rev-parse main)"
}
receipt_path() { printf '%s/integration-receipts/%s.json' "$(git -C "${WT}" rev-parse --path-format=absolute --git-common-dir)" "$1"; }
plant_receipt() { # <head> <base>
  local f; f="$(receipt_path "$1")"; mkdir -p "$(dirname "${f}")"
  jq -n --arg h "$1" --arg b "$2" \
    '{schema:"integration-receipt/1", verdict:"pass", head:$h, target_ref:"origin/main", base:$b,
      gate:"g.sh", gate_source:"caller-supplied", gate_edited_by_branch:false,
      critic_override:null, critic_override_state:null, owner_approval:null,
      blast_radius:"BLAST-RADIUS COLD", recorded_at:"2026-10-04T00:00:00Z"}' > "${f}"
  "${SEAL}" seal --kind integration "${f}"
}
set_mr() { jq "$1" "${ST}/mr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/mr.json"; }
commit_on_main() { # <file> <content>
  local G="git --git-dir=${BARE}" blob tree
  blob="$(printf '%s\n' "$2" | ${G} hash-object -w --stdin)"
  tree="$( { ${G} ls-tree main | awk -F'\t' -v f="$1" '$2 != f'; printf '100644 blob %s\t%s\n' "${blob}" "$1"; } | ${G} mktree)"
  ${G} update-ref refs/heads/main "$(${G} commit-tree "${tree}" -p "$(${G} rev-parse main)" -m "main: $1")"
}
run() { out="$("${TOOL}" "$@" 2>&1)"; rc=$?; }
lm() { run --mr 7 --head "${H}" --repo "${WT}" --lock "${LOCK_PATH}" "$@"; }
expect() { # <label> <rc>
  [ "${rc}" -eq "$2" ] && ok "$1 exit $2" || bad "$1 expected exit $2, got ${rc}" "${out}"
  if [ "$2" -ne 0 ]; then grep -q '^Fix: ' <<<"${out}" && ok "$1 prints Fix:" || bad "$1 missing Fix:" "${out}"; fi
}
names() { grep -qF -- "$2" <<<"${out}" && ok "$1 names '$2'" || bad "$1 does not name '$2'" "${out}"; }
no_merge() { [ -s "${ST}/merge.log" ] && bad "$1 merge was CALLED" "$(cat "${ST}/merge.log")" || ok "$1 no merge call"; no_teardown "$1"; }
no_teardown() { [ -s "${ST}/teardown.log" ] && bad "$1 teardown ran without a confirmed landing" "$(cat "${ST}/teardown.log")" || ok "$1 no teardown"; }
no_confirm() { [ -s "${ST}/confirm.log" ] && bad "$1 confirm-merged was retried" "$(cat "${ST}/confirm.log")" || ok "$1 no confirm retries"; }
tel_events() { cat "$1"/*.jsonl 2>/dev/null | jq -c --arg e "$2" 'select(.event == $e)'; }
tel_count() { local n; n="$(tel_events "$1" "$2" | grep -c .)"; printf '%s' "${n:-0}"; }
landed_ok() { # <label> -- landed: MERGED line, a merge commit on the gated base
  grep -q '^MERGED 7 [0-9a-f]\{40\} ON [0-9a-f]\{40\} TREE-MATCH$' <<<"${out}" && ok "$1 MERGED line" || bad "$1 MERGED line" "${out}"
}

# g1 happy path: default lock (the SAME file the GitHub path takes for this
# repo), the pinned merge call, confirm and teardown by --mr, telemetry.
fixture g1; T="${TMP}/g1-store"; B1="$(git --git-dir="${BARE}" rev-parse main)"
export LOCK_PATH="${TMP}/home/.local/state/athena/wt-merge.lock"
out="$(HOME="${TMP}/home" ATHENA_TELEMETRY_DIR="${T}" "${TOOL}" --mr 7 --head "${H}" --repo "${WT}" 2>&1)"; rc=$?
expect g1 0; landed_ok g1
grep -q "^LOCK ${TMP}/home/.local/state/athena/wt-merge.lock$" <<<"${out}" && ok "g1 default lock is <repo>-merge.lock, as on GitHub" || bad "g1 default lock path" "${out}"
names g1 "no merge train"
grep -qxF -- "mr merge 7 -R t/proj --squash --sha ${H} --auto-merge=false --yes" "${ST}/merge.log" \
  && ok "g1 merge call: pinned --sha, --squash, never auto-merge" || bad "g1 merge call" "$(cat "${ST}/merge.log")"
grep -qxF -- "--mr 7 --repo ${WT} --fetch" "${ST}/confirm.log" && ok "g1 confirm-merged --mr" || bad "g1 confirm-merged argv" "$(cat "${ST}/confirm.log")"
grep -qxF -- "--mr 7 --repo ${WT}" "${ST}/teardown.log" && ok "g1 teardown-stack --mr 7" || bad "g1 teardown argv" "$(cat "${ST}/teardown.log")"
grep -qx "lock free" "${ST}/teardown.log" && ok "g1 lock released before teardown" || bad "g1 lock held during teardown" "$(cat "${ST}/teardown.log")"
M1="$(git --git-dir="${BARE}" rev-parse main)"
[ "$(git --git-dir="${BARE}" rev-parse "${M1}^1")" = "${B1}" ] && ok "g1 landed on the gated base" || bad "g1 landed parent"
lw="$(tel_events "${T}" merge.lock_wait)"
[ "$(tel_count "${T}" merge.lock_wait)" = 1 ] && [ "$(jq -r .attrs.outcome <<<"${lw}")" = acquired ] \
  && [ "$(jq -r '[.unit, .head] | join(" ")' <<<"${lw}")" = "DND-42 ${H}" ] \
  && ok "g1 one merge.lock_wait: acquired, unit from the MR's source branch, the gated head" || bad "g1 merge.lock_wait" "${lw}"
[ "$(tel_count "${T}" merge.landed)" = 0 ] && ok "g1 no merge.landed (glab-athena records it, DND-1939)" \
  || bad "g1 a second merge.landed" "$(tel_events "${T}" merge.landed)"
grep -q "merge_requests/7" "${ST}/glab.log" && ! grep -q "glab-athena\|mr merge" "${ST}/glab.log" \
  && ok "g1 reads went to plain glab, the merge to glab-athena" || bad "g1 read/write split" "$(cat "${ST}/glab.log")"

# g2 THE MISS: the MR's head moved after the gate -> exit 3, no merge call.
fixture g2; set_mr ".sha=\"$(printf 'a%.0s' {1..40})\""
lm; expect g2 3; no_merge g2; names g2 "not the gated ${H}"
# g3 the MR is not open.
fixture g3; set_mr '.state="closed"'
lm; expect g3 3; no_merge g3; names g3 "MR !7 is closed, not opened"

# g4 THE MISS: the base tip is red. The merge guard (DND-1941) refuses inside
# the call with MAIN RED: exit 11 at once, no confirm retries, no teardown.
fixture g4; echo redtip > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
lm; expect g4 11; no_teardown g4; no_confirm g4; names g4 "MAIN RED: main tip abc is RED"
grep -q "^Fix: land only a red-main fix" <<<"${out}" && ok "g4 Fix: names the red-main fix rule" || bad "g4 Fix:" "${out}"
# g5 the guard could not look at the tip: exit 2, its Fix: kept.
fixture g5; echo looktip > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
lm; expect g5 2; no_teardown g5; no_confirm g5; names g5 "COULD NOT LOOK: whether the main tip abc is red"
grep -q "^  Fix: check glab auth" <<<"${out}" && ok "g5 the guard's Fix: kept" || bad "g5 guard Fix: lost" "${out}"
# g6 any other guard refusal (a failed head pipeline): exit 4, never landed.
fixture g6; echo guardother > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
lm; expect g6 4; no_teardown g6; names g6 "glab-athena mr merge 7 refused or failed"

# g7 a red tip by CONTENT (a duplicated migration version on the tip), read
# here before the call, as on GitHub. The origin is CJPoll/gen_saas, which
# ai/config/main-content-checks.json declares.
GS="https://gitlab.com/CJPoll/gen_saas.git"; GSM=apps/athena/priv/repo/migrations
on_main() { ( cd "${WT}" && git checkout -q main && for f in "$@"; do mkdir -p "$(dirname "${f}")"; : > "${f}"; done \
  && git add -A && git commit -qm "main: $*" && git push -q origin main && git checkout -q feature ); }
fixture g7 "${GS}"; on_main "${GSM}/20261003120000_cap.exs" "${GSM}/20261003120000_strip.exs"
lm; expect g7 11; no_merge g7; names g7 "MAIN RED:"
names g7 "${GSM} version 20261003120000: 20261003120000_cap.exs, 20261003120000_strip.exs"
# g7b a red-main fix (contains the tip, removes the duplicate) merges.
( cd "${WT}" && git fetch -q origin && git merge -q --no-edit origin/main \
  && git mv "${GSM}/20261003120000_strip.exs" "${GSM}/20261003120001_strip.exs" && git commit -qm fix && git push -q origin feature )
H="$(git -C "${WT}" rev-parse HEAD)"; set_mr ".sha=\"${H}\""; plant_receipt "${H}" "$(git --git-dir="${BARE}" rev-parse main)"
lm; expect g7b 0; names g7b "RED-MAIN FIX"
# g7c the merged tree would duplicate a version: SEMANTIC CONFLICT, no call.
fixture g7c "${GS}"; old_main="$(git --git-dir="${BARE}" rev-parse main)"; on_main "${GSM}/20261003120000_cap.exs"
( cd "${WT}" && mkdir -p "${GSM}" && : > "${GSM}/20261003120000_strip.exs" && git add -A && git commit -qm strip && git push -q origin feature )
H="$(git -C "${WT}" rev-parse HEAD)"; set_mr ".sha=\"${H}\""; plant_receipt "${H}" "${old_main}"
lm; expect g7c 3; no_merge g7c; names g7c "SEMANTIC CONFLICT"

# g8 THE LOCK: another merge holds the lock. The tool waits at it (its flock
# child is alive and nothing merged), then merges once the lock is released.
fixture g8; exec 8>>"${LOCK_PATH}"; flock 8
# 8>&-: the tool must not inherit the holder's fd, or it would hold the very
# lock it waits for (an flock belongs to the open file, shared across fork).
"${TOOL}" --mr 7 --head "${H}" --repo "${WT}" --lock "${LOCK_PATH}" --wait 120 > "${TMP}/g8.out" 2>&1 8>&- &
g8pid=$!
waiting=""
for _ in $(seq 1 600); do   # bounded: the flock child appearing is the event
  if pgrep -P "${g8pid}" -x flock >/dev/null 2>&1; then waiting=1; break; fi
  kill -0 "${g8pid}" 2>/dev/null || break
  sleep 0.05
done
[ -n "${waiting}" ] && ok "g8 the tool is blocked in flock on the held lock" || bad "g8 the tool never waited at the lock" "$(cat "${TMP}/g8.out")"
[ -s "${ST}/merge.log" ] && bad "g8 merged while the lock was held" || ok "g8 nothing merged while the lock was held"
exec 8>&-
wait "${g8pid}"; rc=$?; g8pid=""; out="$(cat "${TMP}/g8.out")"
expect g8 0; landed_ok g8
# g8b the wait is bounded: --wait 1 on a held lock is exit 6, lock file kept.
fixture g8b; T="${TMP}/g8b-store"; exec 8>>"${LOCK_PATH}"; flock 8
out="$(ATHENA_TELEMETRY_DIR="${T}" "${TOOL}" --mr 7 --head "${H}" --repo "${WT}" --lock "${LOCK_PATH}" --wait 1 2>&1)"; rc=$?
exec 8>&-
expect g8b 6; no_merge g8b
[ -e "${LOCK_PATH}" ] && ok "g8b lock file not removed" || bad "g8b lock file was removed"
[ "$(tel_events "${T}" merge.lock_wait | jq -r .attrs.outcome)" = timeout ] && ok "g8b merge.lock_wait outcome=timeout" \
  || bad "g8b merge.lock_wait" "$(cat "${T}"/*.jsonl 2>/dev/null)"

# g9 THE ROUTING: a project with merge trains enabled boards the train. Exit
# 12 before the lock: no merge call, no lock wait, the Fix names Boarding.
fixture g9; T="${TMP}/g9-store"; echo '{"id":11,"merge_method":"merge","merge_trains_enabled":true}' > "${ST}/project.json"
out="$(ATHENA_TELEMETRY_DIR="${T}" "${TOOL}" --mr 7 --head "${H}" --repo "${WT}" --lock "${LOCK_PATH}" 2>&1)"; rc=$?
expect g9 12; no_merge g9; names g9 "MERGE TRAIN"; names g9 "Boarding"; names g9 "merge_trains/merge_requests/7"
[ "$(tel_count "${T}" merge.lock_wait)" = 0 ] && ok "g9 the train route takes no lock" || bad "g9 waited on the lock" "$(cat "${T}"/*.jsonl)"
grep -q "merge_requests/7" "${ST}/glab.log" && bad "g9 read the MR after routing to the train" || ok "g9 decided from the project alone"
# g10 trains present but disabled: the no-train path.
fixture g10; echo '{"id":11,"merge_method":"merge","merge_trains_enabled":false}' > "${ST}/project.json"
lm; expect g10 0; names g10 "merge trains disabled"
# g11 a project read that is not a full view (no merge_method): COULD NOT
# LOOK, never "no train".
fixture g11; echo '{"id":11}' > "${ST}/project.json"
lm; expect g11 2; no_merge g11; names g11 "COULD NOT LOOK"
fixture g11b; echo '{"id":11,"merge_method":"merge","merge_trains_enabled":"yes"}' > "${ST}/project.json"
lm; expect g11b 2; no_merge g11b
# g12 the project cannot be read at all: COULD NOT LOOK.
fixture g12; : > "${ST}/glab_fail"
lm; expect g12 2; no_merge g12; names g12 "401 Unauthorized"

# g13 THE OTHER MISS: GitLab lands on a base that moved under the merge, or
# a tree other than the computed one: LANDED UNGATED (exit 7).
fixture g13; echo moved > "${ST}/merge_mode"
lm; expect g13 7; no_teardown g13; names g13 "LANDED UNGATED"
fixture g13b; echo badtree > "${ST}/merge_mode"
lm; expect g13b 7; no_teardown g13b
# g14 a fast-forward project: no merge commit, the squash commit is checked.
fixture g14; echo ff > "${ST}/merge_mode"; echo '{"id":11,"merge_method":"ff"}' > "${ST}/project.json"
lm; expect g14 0; landed_ok g14
# g15 the base moved after the gate (DND-1463): merged and named, as on GitHub.
fixture g15; commit_on_main m.txt m
lm; expect g15 0; names g15 "BASE MOVED"
[ "$(git --git-dir="${BARE}" show main:m.txt)" = m ] && [ "$(git --git-dir="${BARE}" show main:f.txt)" = f ] \
  && ok "g15 landed tree holds main's change and the MR's" || bad "g15 landed tree"
# g16 a conflict with the moved base is refused before the call.
fixture g16; commit_on_main f.txt main-side
lm; expect g16 3; no_merge g16; names g16 "CONFLICT"
# g17 no integration-gate receipt for the head: exit 9, no call.
fixture g17; rm -f "$(receipt_path "${H}")"
lm; expect g17 9; no_merge g17; names g17 "NO RECEIPT"
# g18 the merge call fails (502) after GitLab landed it: verified, exit 0.
fixture g18; echo err502 > "${ST}/merge_mode"
lm; expect g18 0; landed_ok g18; names g18 "merge call failed, but MR !7 landed"
# g19 GitLab refuses and nothing landed: exit 4.
fixture g19; echo refuse > "${ST}/merge_mode"; echo 1 > "${ST}/confirm_rc"
lm; expect g19 4; no_teardown g19
# g20 a fork MR (its head in another project) is refused.
fixture g20; set_mr '.source_project_id=99'
lm; expect g20 2; no_merge g20; names g20 "comes from another project"
# g21 an MR read that answers for another MR: COULD NOT LOOK.
fixture g21; set_mr '.iid=8'
lm; expect g21 2; no_merge g21; names g21 "did not return MR !7"

# g22 argument and origin refusals.
fixture g22
run --mr 7 --pr 7 --head "${H}" --repo "${WT}"; expect g22-both 2
run --mr x7 --head "${H}" --repo "${WT}"; expect g22-bad-mr 2
run --mr 7 --head "${H}" --repo "${WT}" --require-idle-workflow post-merge.yml; expect g22-idle 2
names g22-idle "GitHub Actions workflow"
git -C "${WT}" config remote.origin.url "https://github.com/t/t.git"
run --mr 7 --head "${H}" --repo "${WT}"; expect g22-github-origin 2; names g22-github-origin "not gitlab.com"
git -C "${WT}" config remote.origin.url "git@gitlab.example.com:t/proj.git"
run --mr 7 --head "${H}" --repo "${WT}"; expect g22-other-host 2
git -C "${WT}" config remote.origin.url "https://gitlab.com/t/proj.git"
run --pr 7 --head "${H}" --repo "${WT}"; expect g22-pr-on-gitlab 2; names g22-pr-on-gitlab "--mr"
no_merge g22

# g23 nested groups and an scp-style origin resolve to the whole path.
fixture g23 "git@gitlab.com:grp/sub/proj.git"
lm; expect g23 0
grep -q -- "-R grp/sub/proj " "${ST}/merge.log" && ok "g23 nested project path passed whole" || bad "g23 project path" "$(cat "${ST}/merge.log")"
grep -q "projects/grp%2Fsub%2Fproj/merge_requests/7" "${ST}/glab.log" && ok "g23 reads URL-encode the path" || bad "g23 encoded path" "$(cat "${ST}/glab.log")"

# g24 the refusal shape the merge guard prints (glmg_refuse) is the one the
# tool reads back (gmg_refusal_has_reason), for each mark, and the other mark
# does not match: the classifier cannot drift from the GitLab guard's format.
for mark in "MAIN RED:" "COULD NOT LOOK:"; do
  ( . "${LIB}/gh-merge-guard.sh" && . "${LIB}/glab-merge-guard.sh" && glmg_refuse 'glab mr merge' "${mark} tip" 'fix' ) 2> "${TMP}/g24.err"
  if ( . "${LIB}/gh-merge-guard.sh" && gmg_refusal_has_reason "${TMP}/g24.err" "${mark}" ); then
    ok "g24 a glab-athena '${mark}' refusal is read back"
  else bad "g24 reader missed a glab-athena '${mark}' refusal" "$(cat "${TMP}/g24.err")"; fi
  other="MAIN RED:"; [ "${mark}" = "MAIN RED:" ] && other="COULD NOT LOOK:"
  if ( . "${LIB}/gh-merge-guard.sh" && gmg_refusal_has_reason "${TMP}/g24.err" "${other}" ); then
    bad "g24 '${other}' matched a '${mark}' refusal" "$(cat "${TMP}/g24.err")"
  else ok "g24 '${other}' does not match a '${mark}' refusal"; fi
done

# g25 --help documents the GitLab path and exit 12.
hout="$("${TOOL}" --help 2>/dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && grep -q -- '--mr <iid>' <<<"${hout}" && ok "g25 --help shows --mr" || bad "g25 --help --mr" "${hout}"
grep -q '^  12 MERGE TRAIN' <<<"${hout}" && ok "g25 --help documents exit 12" || bad "g25 --help lacks exit 12" "${hout}"

if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

echo "locked-merge GitLab self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
