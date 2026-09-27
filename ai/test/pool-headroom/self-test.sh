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
[ -f "${ST}/gh_fail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
b=""; prev=""
for a in "$@"; do [ "${prev}" = "--head" ] && b="${a}"; prev="${a}"; done
if [ -f "${ST}/merged_${b}" ]; then printf '[{"number":%s}]\n' "$(cat "${ST}/merged_${b}")"; else echo '[]'; fi
EOF
cp "${STUBS}/gh" "${STUBS}/glab"
chmod +x "${STUBS}"/*
export ATHENA_DOCKER_BIN="${STUBS}/docker" ATHENA_GH_BIN="${STUBS}/gh" ATHENA_GLAB_BIN="${STUBS}/glab"

# A github-remote repo with two linked worktrees: "merged" and "live".
REPO="${TMP}/repo"; git init -q -b main "${REPO}"
git -C "${REPO}" config remote.origin.url git@github.com:t/t.git
git -C "${REPO}" commit -q --allow-empty -m seed
git -C "${REPO}" worktree add -q -b feat-merged "${TMP}/wt/feat-merged"
git -C "${REPO}" worktree add -q -b feat-live "${TMP}/wt/feat-live"

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

# THE MISSES: docker cannot be read -> 3, never 0.
fixture m1 0; touch "${ST}/down"; run; expect "m1 docker down" 3
has "m1 says cannot measure" "cannot measure the address pool"
fixture m2 0; : > "${ST}/pools"; run; expect "m2 empty DefaultAddressPools output" 3
fixture m3 0; : > "${ST}/net_ids"; run; expect "m3 zero networks listed" 3
fixture m4 0; echo '[]' > "${ST}/pools"; run; expect "m4 empty pool list" 3
fixture m5 0; echo 'not json' > "${ST}/networks.json"; run; expect "m5 unparseable inspect" 3

# Configured pools are honoured: one /24 split into /26 = 4 subnets, 4 held.
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
