#!/usr/bin/env bash
# Self-test for scripts/wt-preflight's address-pool gate (DND-864).
#
# The gate runs BEFORE any git work: a repo that runs compose stacks must get no
# worktree while pool-headroom refuses, and an unreadable docker refuses too. A
# compose-less repo passes the gate untouched (it then fails later at the pull,
# since the fixture has no origin; reaching step 1 is what this asserts).
#
# Hermetic: a stub docker via ATHENA_DOCKER_BIN; throwaway repos; no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/wt-preflight"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The fixture Ruby resolves BEFORE HOME moves: asdf's `ruby` shim needs the real
# HOME. pool-headroom runs on #!/usr/bin/ruby (DND-931), so the fake HOME no
# longer breaks the tool, and no case can write under the real HOME.
RUBY="$(ruby -e 'print RbConfig.ruby')" || { echo "wt-preflight self-test: no ruby on PATH"; echo "Fix: install the harness Ruby (/usr/bin/ruby, 3.4+)"; exit 2; }
export HOME="${TMP}/home"; mkdir -p "${HOME}"

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

cat > "${TMP}/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${TMP_LOG}"
[ -f "${DOWN}" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1 $2" in
  "info --format") echo null ;;
  "network ls") cat "${IDS}" ;;
  "network inspect") cat "${NETS}" ;;
  "ps -aq") : ;;
  *) echo "unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "${TMP}/docker"
export ATHENA_DOCKER_BIN="${TMP}/docker" TMP_LOG="${TMP}/docker.log" DOWN="${TMP}/down"
export IDS="${TMP}/ids" NETS="${TMP}/nets.json"

# A pool with 30 of 31 subnets held (1 free, below the default bar of 2).
"${RUBY}" -rjson -e '
  nets = (17..31).map { |o| { "Name" => "a#{o}", "IPAM" => { "Config" => [{ "Subnet" => "172.#{o}.0.0/16" }] }, "Labels" => {}, "Containers" => {} } } +
         (0..14).map { |i| { "Name" => "b#{i}", "IPAM" => { "Config" => [{ "Subnet" => "192.168.#{i * 16}.0/20" }] }, "Labels" => {}, "Containers" => {} } }
  File.write(ARGV[0], JSON.dump(nets)); File.write(ARGV[1], nets.map { |n| n["Name"] }.join("\n"))
' "${NETS}" "${IDS}"

mkrepo() { git init -q -b main "$1"; git -C "$1" commit -q --allow-empty -m seed; }
mkrepo "${TMP}/stacky"; : > "${TMP}/stacky/docker-compose.yml"
mkrepo "${TMP}/plain"

run() { out="$("${TOOL}" "$@" 2>&1)"; rc=$?; }

# p1 pool LOW: refuse before any git work.
run --repo "${TMP}/stacky" p1-branch
[ "${rc}" -ne 0 ] && ok "p1 low pool refuses" || bad "p1 low pool passed" "${out}"
grep -q "pool-headroom LOW" <<<"${out}" && ok "p1 names LOW" || bad "p1 LOW line" "${out}"
grep -q "^Fix: " <<<"${out}" && ok "p1 prints Fix:" || bad "p1 Fix:" "${out}"
grep -q "== 1\." <<<"${out}" && bad "p1 went on to git work" "${out}" || ok "p1 no git work"

# p2 docker unreadable: refuse, never read as headroom.
touch "${DOWN}"; run --repo "${TMP}/stacky" p2-branch
[ "${rc}" -ne 0 ] && ok "p2 unreadable docker refuses" || bad "p2 unreadable docker passed" "${out}"
grep -q "cannot measure" <<<"${out}" && ok "p2 says cannot measure" || bad "p2 message" "${out}"
grep -q "== 1\." <<<"${out}" && bad "p2 went on to git work" "${out}" || ok "p2 no git work"

# p3 a compose-less repo passes the gate without asking docker.
: > "${TMP_LOG}"; run --repo "${TMP}/plain" p3-branch
grep -q "== 1\." <<<"${out}" && ok "p3 compose-less repo reaches step 1" || bad "p3 did not pass the gate" "${out}"
[ -s "${TMP_LOG}" ] && bad "p3 called docker" "$(cat "${TMP_LOG}")" || ok "p3 docker not called"

# p4 room in the pool: the gate passes.
rm -f "${DOWN}"; head -n 20 "${IDS}" > "${IDS}.20"; mv "${IDS}.20" "${IDS}"
"${RUBY}" -rjson -e 'n = JSON.parse(File.read(ARGV[0])).first(20); File.write(ARGV[0], JSON.dump(n))' "${NETS}"
run --repo "${TMP}/stacky" p4-branch
grep -q "pool-headroom OK" <<<"${out}" && grep -q "== 1\." <<<"${out}" && ok "p4 headroom passes the gate" || bad "p4 gate" "${out}"

echo "wt-preflight self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: repair the address-pool gate in scripts/wt-preflight (step 0) so each case above holds." >&2
  exit 1
fi
