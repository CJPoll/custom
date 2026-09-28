#!/usr/bin/env bash
# Self-test for ai/bin/pool-headroom (DND-864).
#
# The cases that matter are the misses: a docker that is down, prints nothing,
# or lists zero networks must exit 3 ("cannot measure"), never 0. A LOW pool
# must name the merged-but-up stack with its teardown line.
#
# Hermetic: stub docker/gh/glab via ATHENA_*_BIN, throwaway git repos. No
# daemon, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/bin/pool-headroom"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

STUBS="${TMP}/stubs"; mkdir -p "${STUBS}"
cat > "${STUBS}/docker" <<'EOF'
#!/usr/bin/env bash
# docker stub: answers from files in $ST; logs every call.
echo "$*" >> "${ST}/docker.log"
if [ -f "${ST}/docker_hang" ]; then echo $$ >> "${ST}/hung.pids"; sleep 300 & echo $! >> "${ST}/hung.pids"; wait; fi
[ -f "${ST}/down" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1 $2" in
  "info --format")
    case "$3" in *DefaultAddressPools*) cat "${ST}/pools" ;; *) echo 29.0.0 ;; esac ;;
  "network ls")    cat "${ST}/net_ids" ;;
  "network inspect") cat "${ST}/networks.json" ;;
  "ps -aq")        cat "${ST}/ps_ids" ;;
  "inspect "*)     cat "${ST}/containers.json" ;;
  *) echo "docker stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "${STUBS}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${ST}/gh.log"
# gh_hang: a hung forge CLI (DND-1088). A child holds stdout open, as a real
# CLI's helper would, so only a process-group kill ends the read.
if [ -f "${ST}/gh_hang" ]; then echo $$ >> "${ST}/hung.pids"; sleep 300 & echo $! >> "${ST}/hung.pids"; wait; fi
[ -f "${ST}/gh_fail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
b=""; prev=""
for a in "$@"; do [ "${prev}" = "--head" ] && b="${a}"; prev="${a}"; done
[ -f "${ST}/wrong_key" ] && { echo '[{"id":99}]'; exit 0; }
if [ -f "${ST}/merged_${b}" ]; then printf '[{"number":%s}]\n' "$(cat "${ST}/merged_${b}")"; else echo '[]'; fi
EOF
cat > "${STUBS}/glab" <<'EOF'
#!/usr/bin/env bash
# glab stub: only `mr list --source-branch B --merged -F json`, answering iid.
echo "$*" >> "${ST}/glab.log"
if [ -f "${ST}/glab_hang" ]; then echo $$ >> "${ST}/hung.pids"; sleep 300 & echo $! >> "${ST}/hung.pids"; wait; fi
case "$*" in "mr list --source-branch "*" --merged -F json") ;; *) echo "glab stub: unexpected $*" >&2; exit 99 ;; esac
b="$4"
if [ -f "${ST}/merged_${b}" ]; then printf '[{"iid":%s,"state":"merged"}]\n' "$(cat "${ST}/merged_${b}")"; else echo '[]'; fi
EOF
chmod +x "${STUBS}"/*
export ATHENA_DOCKER_BIN="${STUBS}/docker" ATHENA_GH_BIN="${STUBS}/gh" ATHENA_GLAB_BIN="${STUBS}/glab"

# A github-remote repo with two linked worktrees: "merged" and "live".
REPO="${TMP}/repo"; git init -q -b main "${REPO}"
git -C "${REPO}" config remote.origin.url git@github.com:t/t.git
git -C "${REPO}" commit -q --allow-empty -m seed
git -C "${REPO}" worktree add -q -b feat-merged "${TMP}/wt/feat-merged"
git -C "${REPO}" worktree add -q -b feat-live "${TMP}/wt/feat-live"
# A gitlab-remote repo with one linked worktree.
GLREPO="${TMP}/glrepo"; git init -q -b main "${GLREPO}"
git -C "${GLREPO}" config remote.origin.url git@gitlab.com:t/t.git
git -C "${GLREPO}" commit -q --allow-empty -m seed
git -C "${GLREPO}" worktree add -q -b gl-merged "${TMP}/wt/gl-merged"

# fixture <name> <n-filler-networks>: builtin pools, bridge + two compose
# stacks (merged, live) + one orphan + N filler networks, all in the pool.
fixture() {
  export ST="${TMP}/$1"; mkdir -p "${ST}"
  echo null > "${ST}/pools"
  ruby -rjson -e '
    st, n, tmp = ARGV[0], Integer(ARGV[1]), ARGV[2]
    nets = [{ "Name" => "bridge", "IPAM" => { "Config" => [{ "Subnet" => "172.17.0.0/16" }] }, "Labels" => {}, "Containers" => {} }]
    [["feat-merged", "172.18.0.0/16"], ["feat-live", "172.19.0.0/16"], ["gone", "172.20.0.0/16"]].each do |p, s|
      nets << { "Name" => "net-#{p}", "IPAM" => { "Config" => [{ "Subnet" => s }] },
                "Labels" => { "com.docker.compose.project" => p }, "Containers" => { "c" => {} } }
    end
    n.times { |i| nets << { "Name" => "fill#{i}", "IPAM" => { "Config" => [{ "Subnet" => "192.168.#{i * 16}.0/20" }] }, "Labels" => {}, "Containers" => {} } }
    File.write("#{st}/networks.json", JSON.dump(nets))
    File.write("#{st}/net_ids", nets.map { |x| x["Name"] }.join("\n") + "\n")
    cs = [["feat-merged", "#{tmp}/wt/feat-merged"], ["feat-live", "#{tmp}/wt/feat-live"], ["gone", "#{tmp}/wt/gone"]]
    File.write("#{st}/containers.json", JSON.dump(cs.map { |p, d| { "Config" => { "Labels" => {
      "com.docker.compose.project" => p, "com.docker.compose.project.working_dir" => d } } } }))
    File.write("#{st}/ps_ids", "c1\nc2\nc3\n")
  ' "${ST}" "$2" "${TMP}"
  echo 7 > "${ST}/merged_feat-merged"
}
run() { out="$("${TOOL}" "$@" 2>&1)"; rc=$?; }
expect() { # <label> <rc>
  [ "${rc}" -eq "$2" ] && ok "$1 exit $2" || bad "$1 expected exit $2, got ${rc}" "${out}"
  if [ "$2" -ne 0 ]; then grep -q '^Fix: ' <<<"${out}" && ok "$1 prints Fix:" || bad "$1 missing Fix:" "${out}"; fi
}
has() { grep -qF -- "$2" <<<"${out}" && ok "$1" || bad "$1: missing '$2'" "${out}"; }

# h1 plenty of room: 4 held of 31.
fixture h1 0; run; expect h1 0
has "h1 summary" "pool-headroom OK: free 27/31 subnets, 4 held"
[ -s "${ST}/gh.log" ] && bad "h1 made forge calls on the OK path" || ok "h1 no forge calls when OK"

# h2 LOW: 4 + 16 fillers = 20 of 31 -> 11 free; --min-free 12 makes it low.
fixture h2 16; run --min-free 12; expect h2 1
has "h2 names LOW" "pool-headroom LOW: free 11/31"
has "h2 MERGED-BUT-UP named" "MERGED-BUT-UP project feat-merged"
has "h2 teardown line for the merged stack" "teardown: ~/dev/custom/ai/bin/teardown-stack --pr 7 --repo ${TMP}/wt/feat-merged"
has "h2 LIVE stack named, not torn down" "LIVE project feat-live"
has "h2 ORPHAN named" "ORPHAN project gone: ${TMP}/wt/gone is gone"
grep -q "teardown-stack --pr .* feat-live" <<<"${out}" && bad "h2 offered to tear down a LIVE stack" "${out}" || ok "h2 no teardown for the live stack"

# h3 forge unreadable: the merge state is UNKNOWN, never "nothing merged".
fixture h3 16; touch "${ST}/gh_fail"; run --min-free 12; expect h3 1
has "h3 unknown merge state" "merge state UNKNOWN"
grep -q "LIVE project feat-merged" <<<"${out}" && bad "h3 read a forge failure as not-merged" "${out}" || ok "h3 forge failure not read as live"

# h4 GitLab: glab's argv and its iid key produce an --mr teardown line.
fixture h4 16; echo 12 > "${ST}/merged_gl-merged"
ruby -rjson -e 'f = ARGV[0]; c = JSON.parse(File.read(f))
  c[1]["Config"]["Labels"]["com.docker.compose.project.working_dir"] = ARGV[1]; File.write(f, JSON.dump(c))' \
  "${ST}/containers.json" "${TMP}/wt/gl-merged"
run --min-free 12; expect h4 1
has "h4 gitlab teardown line" "teardown: ~/dev/custom/ai/bin/teardown-stack --mr 12 --repo ${TMP}/wt/gl-merged"
grep -qxF "mr list --source-branch gl-merged --merged -F json" "${ST}/glab.log" && ok "h4 glab argv" || bad "h4 glab argv" "$(cat "${ST}/glab.log" 2>/dev/null)"

# h5 a merged-list entry without its key is UNKNOWN, never "nothing merged".
fixture h5 16; touch "${ST}/wrong_key"; run --min-free 12; expect h5 1
has "h5 unknown merge state" "merge state UNKNOWN"
grep -q "LIVE project feat-merged" <<<"${out}" && bad "h5 read a keyless entry as not merged" "${out}" || ok "h5 keyless entry not read as live"

# HUNG CALLS (DND-1088): a forge CLI that never answers must not hang the
# tool, and must not read as "nothing merged". Each run is itself bounded by
# timeout(1), so the unfixed code fails these cases (124) instead of hanging
# the suite. ATHENA_*_TIMEOUT_S are test seams that shorten the bound.
run_bounded() { out="$(ATHENA_FORGE_TIMEOUT_S=2 ATHENA_DOCKER_TIMEOUT_S=2 timeout 40 "${TOOL}" "$@" 2>&1)"; rc=$?; }
no_survivors() { # <label>: every hung stub process was killed, none orphaned
  local alive=""
  [ -s "${ST}/hung.pids" ] || { bad "$1: the stub never recorded a hung pid" ""; return; }
  while read -r p; do kill -0 "$p" 2>/dev/null && alive="${alive} ${p}"; done < "${ST}/hung.pids"
  if [ -z "${alive}" ]; then ok "$1 left no hung process behind"; else bad "$1 left hung process(es):${alive}" ""; kill -9 ${alive} 2>/dev/null; fi
}
# t1 GitLab: glab hangs -> the stack is UNKNOWN within the bound, with a Fix naming the command.
fixture t1 16; echo 12 > "${ST}/merged_gl-merged"; touch "${ST}/glab_hang"
ruby -rjson -e 'f = ARGV[0]; c = JSON.parse(File.read(f))
  c[1]["Config"]["Labels"]["com.docker.compose.project.working_dir"] = ARGV[1]; File.write(f, JSON.dump(c))' \
  "${ST}/containers.json" "${TMP}/wt/gl-merged"
run_bounded --min-free 12
[ "${rc}" -ne 124 ] && ok "t1 hung glab did not hang pool-headroom" || bad "t1 pool-headroom hung on a hung glab (timeout 124)" "${out}"
expect t1 1
has "t1 merge state UNKNOWN" "merge state UNKNOWN"
has "t1 names the timed-out command" "\`glab mr list --source-branch gl-merged --merged -F json\` timed out after 2s"
grep -q "^Fix: .*glab mr list --source-branch gl-merged --merged -F json" <<<"${out}" && ok "t1 Fix: names the hung command" || bad "t1 Fix: does not name the hung command" "${out}"
grep -q "gl-merged.*nothing merged" <<<"${out}" && bad "t1 read a hung glab as nothing merged" "${out}" || ok "t1 hung glab not read as nothing merged"
grep -q "teardown-stack --mr" <<<"${out}" && bad "t1 offered a teardown for an UNKNOWN stack" "${out}" || ok "t1 no teardown line for the UNKNOWN stack"
no_survivors t1
# t2 GitHub: gh hangs; two github stacks -> both UNKNOWN, and gh is run ONCE
# (a CLI that timed out is not asked again this run, so N stacks cost one bound).
fixture t2 16; touch "${ST}/gh_hang"; run_bounded --min-free 12
[ "${rc}" -ne 124 ] && ok "t2 hung gh did not hang pool-headroom" || bad "t2 pool-headroom hung on a hung gh (timeout 124)" "${out}"
expect t2 1
[ "$(grep -c "project feat-.*merge state UNKNOWN" <<<"${out}")" -eq 2 ] && ok "t2 both github stacks UNKNOWN" || bad "t2 expected 2 UNKNOWN stacks" "${out}"
[ "$(wc -l < "${ST}/gh.log")" -eq 1 ] && ok "t2 gh run once after it timed out" || bad "t2 gh run $(wc -l < "${ST}/gh.log") times" "$(cat "${ST}/gh.log")"
has "t2 skipped call says why" "not run: \`gh\` timed out earlier in this run"
grep -q "LIVE project feat-live" <<<"${out}" && bad "t2 read a hung gh as live" "${out}" || ok "t2 hung gh not read as live"
no_survivors t2
# t3 docker hangs: the pool cannot be measured -> 3 within the bound, never 0.
fixture t3 0; touch "${ST}/docker_hang"; run_bounded
[ "${rc}" -ne 124 ] && ok "t3 hung docker did not hang pool-headroom" || bad "t3 pool-headroom hung on a hung docker (timeout 124)" "${out}"
expect t3 3
has "t3 names the timed-out docker command" "timed out after 2s"
no_survivors t3
# t4 a malformed bound is refused, never read as "no bound".
fixture t4 16; out="$(ATHENA_FORGE_TIMEOUT_S=soon timeout 40 "${TOOL}" --min-free 12 2>&1)"; rc=$?
expect "t4 malformed ATHENA_FORGE_TIMEOUT_S" 3
has "t4 names the malformed seam" "ATHENA_FORGE_TIMEOUT_S"

# THE MISSES: docker cannot be read -> 3, never 0.
fixture m1 0; touch "${ST}/down"; run; expect "m1 docker down" 3
has "m1 says cannot measure" "cannot measure the address pool"
fixture m2 0; : > "${ST}/pools"; run; expect "m2 empty DefaultAddressPools output" 3
fixture m3 0; : > "${ST}/net_ids"; run; expect "m3 zero networks listed" 3
fixture m4 0; echo '[]' > "${ST}/pools"; run; expect "m4 empty pool list" 3
fixture m5 0; echo 'not json' > "${ST}/networks.json"; run; expect "m5 unparseable inspect" 3

# Configured pools are honoured: 172.16.0.0/12 split into /16s = 16 subnets, 4 held.
fixture c1 0; echo '[{"Base":"172.16.0.0/12","Size":16}]' > "${ST}/pools"; run
expect "c1 configured 16-subnet pool" 0; has "c1 configured capacity" "free 12/16 subnets, 4 held, min-free 2, pools configured"

# --repo: a repo with no compose file needs no subnet (docker not consulted).
fixture r1 0; touch "${ST}/down"; mkdir -p "${TMP}/nocompose/sub"; run --repo "${TMP}/nocompose"
expect "r1 no compose file" 0; has "r1 note" "run no stack"
[ -s "${ST}/docker.log" ] && bad "r1 called docker for a compose-less repo" || ok "r1 docker not called"
# A root compose file is a stack repo (gen_saas).
fixture r2 0; touch "${ST}/down"; mkdir -p "${TMP}/rootcompose"; : > "${TMP}/rootcompose/docker-compose.yml"
run --repo "${TMP}/rootcompose"; expect "r2 root compose is probed" 3
# So is a repo with a teardown script and compose below the root (walt_ui).
mkdir -p "${TMP}/scripted/backend" "${TMP}/scripted/bin"; : > "${TMP}/scripted/backend/docker-compose.yml"
printf '#!/bin/sh\n' > "${TMP}/scripted/bin/teardown-worktree-stack.sh"; chmod +x "${TMP}/scripted/bin/teardown-worktree-stack.sh"
run --repo "${TMP}/scripted"; expect "r2b teardown-script repo is probed" 3
# Compose files only below the root, no script: templates (~/dev/custom), not a stack.
: > "${ST}/docker.log"; mkdir -p "${TMP}/templates/templates"; : > "${TMP}/templates/templates/docker-compose.yml"
run --repo "${TMP}/templates"; expect "r2c templates-only repo is not gated" 0
[ -s "${ST}/docker.log" ] && bad "r2c called docker" || ok "r2c docker not called"
# An unreadable --repo: 3 (cannot measure), never Ruby's default 1 ("LOW").
mkdir -p "${TMP}/locked"; chmod 000 "${TMP}/locked"
run --repo "${TMP}/locked"; expect "r4 unreadable repo" 3; chmod 755 "${TMP}/locked"
run --repo "${TMP}/does-not-exist"; expect "r3 missing --repo" 2

# Usage.
run --bogus; expect "u1 unknown flag" 2
run --min-free lots; expect "u2 non-integer --min-free" 2
run --min-free 1 --min-free 2; expect "u3 repeated flag" 2
out="$("${TOOL}" --help 2>/dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && grep -q "^Usage:" <<<"${out}" && ok "u4 --help on stdout, exit 0" || bad "u4 --help" "${out}"

echo "pool-headroom self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: repair ai/bin/pool-headroom (or ai/lib/docker_stacks*.rb) until every case above passes; an unreadable docker must exit 3, never 0." >&2
  exit 1
fi
