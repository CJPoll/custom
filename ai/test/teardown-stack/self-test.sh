#!/usr/bin/env bash
# Self-test for ai/bin/teardown-stack (DND-864).
#
# What must never happen: a `down -v` on a stack the tool cannot attribute to
# the merged change (not merged, merge undeterminable, project name shared with
# another checkout, a non-default project, the main checkout), or a "torn down"
# report while resources linger. Each such case asserts the exit code AND that
# no `compose down` ran.
#
# Hermetic: stub docker/gh/glab via ATHENA_*_BIN and CONFIRM_MERGED_GH/GLAB,
# throwaway git repos. No daemon, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/bin/teardown-stack"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
TMP="$(cd "${TMP}" && pwd -P)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

STUBS="${TMP}/stubs"; mkdir -p "${STUBS}"
cat > "${STUBS}/docker" <<'EOF'
#!/usr/bin/env bash
# Stateful docker stub. Resources per project live in $ST/res/<project>/<kind>
# (one id per line). `compose down` empties them unless $ST/linger exists.
echo "$*" >> "${ST}/docker.log"
[ -f "${ST}/down" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
# fail_after_down: the daemon dies once `compose down` has run.
[ -f "${ST}/fail_after_down" ] && [ -s "${ST}/compose.log" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
proj_of() { for a in "$@"; do case "$a" in label=com.docker.compose.project=*) echo "${a#label=com.docker.compose.project=}";; esac; done; }
list() { local f="${ST}/res/$1/$2"; [ -f "$f" ] && cat "$f"; return 0; }
case "$1" in
  info) echo 29.0.0 ;;
  inspect) cat "${ST}/containers.json" ;;
  ps)
    p="$(proj_of "$@")"
    if [ -n "$p" ]; then list "$p" containers; else cat "${ST}/ps_ids"; fi ;;
  volume)  list "$(proj_of "$@")" volumes ;;
  network) list "$(proj_of "$@")" networks ;;
  compose)
    echo "CWD $(pwd -P) PROJECT $3" >> "${ST}/compose.log"
    [ -f "${ST}/linger" ] || rm -rf "${ST}/res/$3" ;;
  *) echo "docker stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "${STUBS}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ST}/gh.log"
[ -f "${ST}/forge_fail" ] && { echo "HTTP 502" >&2; exit 1; }
case "$*" in
  *"--json state,mergedAt"*)
    if [ -f "${ST}/merged" ]; then echo '{"state":"MERGED","mergedAt":"2026-01-01T00:00:00Z"}'
    else echo '{"state":"OPEN","mergedAt":null}'; fi ;;
  *"--json headRefName"*)
    # head_hang: the branch lookup hangs (DND-1088); a child holds stdout open.
    if [ -f "${ST}/head_hang" ]; then echo $$ >> "${ST}/hung.pids"; sleep 300 & echo $! >> "${ST}/hung.pids"; wait; fi
    if [ -f "${ST}/wrong_shape" ]; then echo '["not","an","object"]'
    else printf '{"headRefName":"%s"}\n' "$(cat "${ST}/branch")"; fi ;;
  *) echo "gh stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "${STUBS}/glab" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ST}/glab.log"
[ -f "${ST}/forge_fail" ] && { echo "HTTP 502" >&2; exit 1; }
if [ -f "${ST}/merged" ]; then s=merged; m='"2026-01-01T00:00:00Z"'; else s=opened; m=null; fi
printf '{"state":"%s","merged_at":%s,"source_branch":"%s"}\n' "$s" "$m" "$(cat "${ST}/branch")"
EOF
chmod +x "${STUBS}"/*
export ATHENA_DOCKER_BIN="${STUBS}/docker" ATHENA_GH_BIN="${STUBS}/gh" ATHENA_GLAB_BIN="${STUBS}/glab"
export CONFIRM_MERGED_GH="${STUBS}/gh" CONFIRM_MERGED_GLAB="${STUBS}/glab"

# One repo, several linked worktrees, each a different stack layout.
REPO="${TMP}/repo"; git init -q -b main "${REPO}"
git -C "${REPO}" config remote.origin.url git@github.com:t/t.git
git -C "${REPO}" commit -q --allow-empty -m seed
WT="${TMP}/wt"
for b in dnd-1-x sub-only scripted no-compose; do git -C "${REPO}" worktree add -q -b "$b" "${WT}/$b"; done
: > "${WT}/dnd-1-x/docker-compose.yml"
mkdir -p "${WT}/sub-only/backend"; : > "${WT}/sub-only/backend/docker-compose.yml"
mkdir -p "${WT}/scripted/bin"; : > "${WT}/scripted/docker-compose.yml"
cat > "${WT}/scripted/bin/teardown-worktree-stack.sh" <<'EOF'
#!/usr/bin/env bash
echo "SCRIPT $1" >> "${ST}/script.log"
[ -f "${ST}/script_fail" ] && { echo "error: linger" >&2; exit 1; }
exit 0
EOF
chmod +x "${WT}/scripted/bin/teardown-worktree-stack.sh"

# fixture <name> <branch>: merged PR for <branch>; project dnd-1-x is up in its
# worktree (2 containers, 3 volumes, 1 network).
fixture() {
  export ST="${TMP}/st-$1"; mkdir -p "${ST}/res/dnd-1-x"
  touch "${ST}/merged"; echo "$2" > "${ST}/branch"
  printf 'c1\nc2\n' > "${ST}/res/dnd-1-x/containers"
  printf 'v1\nv2\nv3\n' > "${ST}/res/dnd-1-x/volumes"
  printf 'n1\n' > "${ST}/res/dnd-1-x/networks"
  printf 'c1\nc2\n' > "${ST}/ps_ids"
  containers "dnd-1-x=${WT}/dnd-1-x" "dnd-1-x=${WT}/dnd-1-x"
}
containers() { # project=dir ...
  /usr/bin/ruby -rjson -e 'puts JSON.dump(ARGV.map { |a| p, d = a.split("=", 2)
    { "Config" => { "Labels" => { "com.docker.compose.project" => p, "com.docker.compose.project.working_dir" => d } } } })' "$@" \
    > "${ST}/containers.json"
}
run() { out="$(cd "${REPO}" && "${TOOL}" "$@" 2>&1)"; rc=$?; }
expect() { # <label> <rc>
  [ "${rc}" -eq "$2" ] && ok "$1 exit $2" || bad "$1 expected exit $2, got ${rc}" "${out}"
  if [ "$2" -ne 0 ]; then grep -q '^Fix: ' <<<"${out}" && ok "$1 prints Fix:" || bad "$1 missing Fix:" "${out}"; fi
}
has() { grep -qF -- "$2" <<<"${out}" && ok "$1" || bad "$1: missing '$2'" "${out}"; }
no_down() { [ -s "${ST}/compose.log" ] && bad "$1 ran compose down" "$(cat "${ST}/compose.log")" || ok "$1 no compose down"; }

# t1 happy path: merged PR -> its worktree's default-named stack goes, verified.
fixture t1 dnd-1-x; run --pr 5
expect t1 0
has "t1 reports what it removed" "TORN DOWN project dnd-1-x in ${WT}/dnd-1-x (removed 2 container(s), 3 volume(s), 1 network(s))"
has "t1 names the worktree to remove next" "next: remove the worktree ${WT}/dnd-1-x"
has "t1 names the no-sudo husk reclaim" "Permission denied on container-owned deps/_build is a husk: reclaim it without sudo"
has "t1 cites the husk section by name" "athena:teardown-worktree-stack -> A root-owned husk"
[ -d "${WT}/dnd-1-x" ] && ok "t1 the tool itself left the worktree" || bad "t1 the tool removed the worktree"
grep -qxF "CWD ${WT}/dnd-1-x PROJECT dnd-1-x" "${ST}/compose.log" && ok "t1 down ran in the worktree for its project" \
  || bad "t1 compose call" "$(cat "${ST}/compose.log" 2>/dev/null)"
grep -q -- "-p dnd-1-x down -v --remove-orphans" "${ST}/docker.log" && ok "t1 down -v --remove-orphans" || bad "t1 down flags" "$(cat "${ST}/docker.log")"

# t2 NOT merged: refuse, touch nothing.
fixture t2 dnd-1-x; rm "${ST}/merged"; run --pr 5; expect t2 1; no_down t2
# t3 the merge cannot be determined: 3, never a teardown.
fixture t3 dnd-1-x; touch "${ST}/forge_fail"; run --pr 5; expect t3 3; no_down t3
# t4 resources linger after down: 4, never "torn down".
fixture t4 dnd-1-x; touch "${ST}/linger"; run --pr 5; expect t4 4
grep -q "TORN DOWN" <<<"${out}" && bad "t4 claimed TORN DOWN" "${out}" || ok "t4 no false TORN DOWN"
# t5 project name shared with another checkout: refuse.
fixture t5 dnd-1-x; containers "dnd-1-x=${WT}/dnd-1-x" "dnd-1-x=${TMP}/elsewhere/dnd-1-x"
run --pr 5; expect "t5 collision" 2; no_down t5
# t6 a non-default project runs under the worktree: refuse (tier 3).
fixture t6 dnd-1-x; containers "dnd-1-x=${WT}/dnd-1-x" "walt-ui-dnd-1-x=${WT}/dnd-1-x/backend"
run --pr 5; expect "t6 foreign project" 2; no_down t6
# t7 nothing up at all: 0, said so.
fixture t7 dnd-1-x; rm -rf "${ST}/res/dnd-1-x"; containers; : > "${ST}/ps_ids"
run --pr 5; expect t7 0; has "t7 says nothing up" "nothing up for project dnd-1-x"; no_down t7
# t8 labelled resources but no container ties them to the worktree: refuse.
fixture t8 dnd-1-x; rm "${ST}/res/dnd-1-x/containers"; containers; : > "${ST}/ps_ids"
run --pr 5; expect "t8 unattributable volumes" 2; no_down t8
# t9 docker down: 3, not "nothing up".
fixture t9 dnd-1-x; touch "${ST}/down"; run --pr 5; expect "t9 docker unreachable" 3; no_down t9

# t10 tier 1: the repo's own script wins and gets the worktree path.
fixture t10 scripted; run --pr 5; expect t10 0
grep -qxF "SCRIPT ${WT}/scripted" "${ST}/script.log" && ok "t10 script ran with the worktree" || bad "t10 script" "$(cat "${ST}/script.log" 2>/dev/null)"
no_down t10
fixture t10b scripted; touch "${ST}/script_fail"; run --pr 5; expect "t10b script failure" 4

# t10c the MAIN checkout's script covers a worktree branched before it landed.
REPO2="${TMP}/repo2"; git init -q -b main "${REPO2}"
git -C "${REPO2}" config remote.origin.url git@github.com:t/t2.git
git -C "${REPO2}" commit -q --allow-empty -m seed
git -C "${REPO2}" worktree add -q -b old-branch "${WT}/old-branch"
mkdir -p "${REPO2}/bin" "${WT}/old-branch/backend"; : > "${WT}/old-branch/backend/docker-compose.yml"
cp "${WT}/scripted/bin/teardown-worktree-stack.sh" "${REPO2}/bin/"
fixture t10c old-branch; out="$(cd "${REPO2}" && "${TOOL}" --pr 5 2>&1)"; rc=$?; expect "t10c main-checkout script" 0
grep -qxF "SCRIPT ${WT}/old-branch" "${ST}/script.log" && ok "t10c main-checkout script ran with the worktree" \
  || bad "t10c script" "$(cat "${ST}/script.log" 2>/dev/null)"

# t11 compose files only below the root and no script declare no stack
# (~/dev/custom's templates/docker-compose.yml): 0, and docker is never asked,
# so a down daemon cannot turn a custom merge into locked-merge's exit 10.
fixture t11 sub-only; touch "${ST}/down"; run --pr 5; expect "t11 templates only, docker down" 0
has "t11 says no stack declared" "declares no per-worktree stack"; no_down t11
[ -s "${ST}/docker.log" ] && bad "t11 called docker" "$(cat "${ST}/docker.log")" || ok "t11 docker not called"

# t4b docker dies after `down` ran: 4 (ran, unverified), never 3 ("nothing touched").
fixture t4b dnd-1-x; touch "${ST}/fail_after_down"; run --pr 5; expect "t4b unverifiable after down" 4
grep -q "Nothing was torn down" <<<"${out}" && bad "t4b claims nothing was torn down" "${out}" || ok "t4b no false 'nothing touched'"

# t10d tier-1 script exits 0 but a compose container still runs under the worktree: 4.
fixture t10d scripted; containers "dnd-1-x=${WT}/dnd-1-x" "left=${WT}/scripted"
run --pr 5; expect "t10d script left a container" 4

# t18 a forge answer of the wrong shape: 3, never Ruby's default 1 ("not merged").
fixture t18 dnd-1-x; touch "${ST}/wrong_shape"; run --pr 5; expect "t18 wrong-shape forge answer" 3; no_down t18

# t20 a forge lookup that hangs (DND-1088): 3 within the bound, the command
# named in a Fix:, nothing torn down, no hung process left. Bounded by
# timeout(1) so a regression fails (124) instead of hanging the suite.
fixture t20 dnd-1-x; touch "${ST}/head_hang"
out="$(cd "${REPO}" && ATHENA_FORGE_TIMEOUT_S=2 timeout 60 "${TOOL}" --pr 5 2>&1)"; rc=$?
[ "${rc}" -ne 124 ] && ok "t20 hung gh did not hang teardown-stack" || bad "t20 teardown-stack hung on a hung gh (timeout 124)" "${out}"
expect "t20 hung forge lookup" 3; no_down t20
has "t20 names the timed-out command" "\`gh pr view 5 --json headRefName\` timed out after 2s"
grep -q "^Fix: .*gh pr view 5 --json headRefName" <<<"${out}" && ok "t20 Fix: names the hung command" || bad "t20 Fix: does not name the hung command" "${out}"
# Alive and not a zombie: kill -0 answers for an unreaped orphan.
alive=""; while read -r p; do [ -r "/proc/${p}/stat" ] && ! grep -q ') Z ' "/proc/${p}/stat" 2>/dev/null && alive="${alive} ${p}"; done < "${ST}/hung.pids"
[ -z "${alive}" ] && ok "t20 left no hung process behind" || { bad "t20 left hung process(es):${alive}"; kill -9 ${alive} 2>/dev/null; }

# t19 worktree registered but its directory is gone, no script: refuse with a Fix.
git -C "${REPO}" worktree add -q -b vanished "${WT}/vanished"; rm -rf "${WT}/vanished"
fixture t19 vanished; run --pr 5; expect "t19 worktree dir gone" 2; no_down t19
has "t19 names the gone directory" "its directory is gone"
git -C "${REPO}" worktree prune
# t12 no compose file: 0 and docker never consulted.
fixture t12 no-compose; touch "${ST}/down"; run --pr 5; expect t12 0
has "t12 says no stack declared" "declares no per-worktree stack"; [ -s "${ST}/docker.log" ] && bad "t12 called docker" || ok "t12 docker not called"
# t13 no worktree has the branch: 0, and the miss is named.
fixture t13 gone-branch; run --pr 5; expect t13 0; has "t13 names the branch and count" "no worktree of ${REPO} has gone-branch checked out ("
# t14 branch checked out in the MAIN checkout: refuse.
fixture t14 main; run --pr 5; expect "t14 main checkout" 2; no_down t14

# t15 GitLab MR path.
fixture t15 dnd-1-x; run --mr 9; expect "t15 gitlab mr" 0; has "t15 torn down" "TORN DOWN project dnd-1-x"
# t16 dry run: plan printed, nothing run.
fixture t16 dnd-1-x; run --pr 5 --dry-run; expect "t16 dry run" 0; has "t16 plan" "DRY RUN would run"; no_down t16

# t17 parked mode.
fixture t17 unused; run --worktree "${WT}/dnd-1-x" --parked STUCK; expect "t17 parked" 0; has "t17 torn down" "TORN DOWN project dnd-1-x"
[ -s "${ST}/gh.log" ] && bad "t17 parked mode consulted the forge" || ok "t17 parked mode needs no merge"
grep -q "next: remove the worktree" <<<"${out}" && bad "t17 parked mode told the admiral to remove the tree" "${out}" || ok "t17 parked keeps the tree"
fixture t17b unused; run --worktree "${REPO}" --parked STUCK; expect "t17b parked main checkout" 2; no_down t17b
fixture t17c unused; mkdir -p "${WT}/dnd-1-x/deep"; run --worktree "${WT}/dnd-1-x/deep" --parked STUCK; expect "t17c not a top level" 2; no_down t17c

# Usage.
fixture u unused
run --pr 5 --mr 5; expect "u1 pr and mr" 2
run --pr 5 --parked STUCK --worktree "${WT}/dnd-1-x"; expect "u2 merged + parked" 2
run; expect "u3 no mode" 2
run --worktree "${WT}/dnd-1-x"; expect "u4 worktree without --parked" 2
run --pr abc; expect "u5 non-integer pr" 2
no_down u
out="$("${TOOL}" --help 2>/dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && grep -q "^Usage:" <<<"${out}" && ok "u6 --help on stdout, exit 0" || bad "u6 --help" "${out}"

echo "teardown-stack self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: repair ai/bin/teardown-stack (or ai/lib/docker_stacks*.rb) until every case above passes; it must never run down -v on a stack it cannot attribute." >&2
  exit 1
fi
