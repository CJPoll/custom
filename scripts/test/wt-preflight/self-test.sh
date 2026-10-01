#!/usr/bin/env bash
# Self-test for scripts/wt-preflight: the address-pool gate (DND-864, p1-p4)
# and the step-1 pull-failure classification (DND-1509, p5-p11).
#
# The gate runs BEFORE any git work: a repo that runs compose stacks must get no
# worktree while pool-headroom refuses, and an unreadable docker refuses too. A
# compose-less repo passes the gate untouched (p3's fixture has no origin, so it
# then fails at the pull; reaching step 1 is what p3 asserts).
#
# Step 1 cases build a local bare origin each: a held lock, a real divergence,
# an unreachable origin and a non-main branch must each be named as what it is.
#
# Hermetic: a stub docker via ATHENA_DOCKER_BIN; throwaway repos; no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/wt-preflight"
PASS=0; FAIL=0
p7pid=""
TMP="$(mktemp -d)"; trap '[ -n "${p7pid}" ] && kill "${p7pid}" 2>/dev/null; rm -rf "${TMP}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The fixture Ruby resolves BEFORE HOME moves: asdf's `ruby` shim needs the real
# HOME. pool-headroom runs on #!/usr/bin/ruby (DND-931), so the fake HOME no
# longer breaks the tool, and no case can write under the real HOME.
RUBY="$(/usr/bin/ruby -e 'print RbConfig.ruby')" || { echo "wt-preflight self-test: /usr/bin/ruby did not run"; echo "Fix: install the harness Ruby (/usr/bin/ruby, 3.4+)"; exit 2; }
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

# --- Step 1: a failed `pull --ff-only` is classified before it is named (DND-1509).
# Before the fix, every failure read "local main diverged?", including a lock
# held by another git (the lead-time cron fetching the same checkout).
# Fixtures: a bare origin, a seeding clone, and a clone origin has moved past.
# Each case holds its condition for the whole run, so no case races a timer.
mkorigin() { # mkorigin <dir> -> <dir>/o.git with one commit, <dir>/s a pushing clone
  git init -q --bare -b main "$1/o.git"
  git clone -q "$1/o.git" "$1/s" 2>/dev/null
  git -C "$1/s" commit -q --allow-empty -m seed
  git -C "$1/s" push -q origin main
}
advance() { git -C "$1/s" commit -q --allow-empty -m "$2"; git -C "$1/s" push -q origin main; }

# p5 a lock held by another git: named as a lock, never as divergence.
F="${TMP}/lockfix"; mkdir -p "${F}"; mkorigin "${F}"
git clone -q "${F}/o.git" "${F}/r"; advance "${F}" two
: > "${F}/r/.git/index.lock"
run --repo "${F}/r" --lock-retries 0 p5-branch
[ "${rc}" -ne 0 ] && ok "p5 held lock refuses" || bad "p5 held lock passed" "${out}"
grep -q "held by another git process" <<<"${out}" && ok "p5 names the lock" || bad "p5 lock message" "${out}"
grep -qF "${F}/r/.git/index.lock" <<<"${out}" && ok "p5 names the lock path" || bad "p5 lock path" "${out}"
grep -q "diverged" <<<"${out}" && bad "p5 reported divergence" "${out}" || ok "p5 not called divergence"
grep -q "^Fix: " <<<"${out}" && ok "p5 prints Fix:" || bad "p5 Fix:" "${out}"
grep -q "== 2\." <<<"${out}" && bad "p5 went on to create a worktree" "${out}" || ok "p5 stops at step 1"

# p6 the bounded retry: a lock still held after the retries is still the lock
# message, and it says how many retries it made. The lock never clears, so the
# outcome does not depend on how fast the machine is.
run --repo "${F}/r" --lock-retries 1 p6-branch
grep -q "held by another git process" <<<"${out}" && ok "p6 lock message after retry" || bad "p6 lock message" "${out}"
grep -q "after 1 retry" <<<"${out}" && ok "p6 names the retries" || bad "p6 retry count" "${out}"

# p7 a lock that clears during the retry: the pull re-runs and step 1 passes.
# Event-ordered, not timed: the test releases the lock only when the tool says
# it is waiting on it. The retry cap only bounds a hang; the case passes on the
# first retry that finds the lock gone.
FIFO="${TMP}/p7.fifo"; mkfifo "${FIFO}"
# The timeout and the kill below only cap a hang; neither decides a verdict.
timeout 180 "${TOOL}" --repo "${F}/r" --lock-retries 60 p7-branch > "${FIFO}" 2>&1 &
p7pid=$!
out=""; released=0
while IFS= read -r -t 120 line; do
  out+="${line}"$'\n'
  if [ "${released}" = 0 ] && grep -q "waiting for it to clear" <<<"${line}"; then
    rm -f "${F}/r/.git/index.lock"; released=1
  fi
done < "${FIFO}"
kill "${p7pid}" 2>/dev/null; wait "${p7pid}" 2>/dev/null; p7pid=""
[ "${released}" = 1 ] && ok "p7 tool waited on the held lock" || bad "p7 never waited on the lock" "${out}"
grep -q "== 2\." <<<"${out}" && ok "p7 released lock: step 1 passes" || bad "p7 retry did not pass step 1" "${out}"
[ "$(git -C "${F}/r" rev-parse main)" = "$(git -C "${F}/o.git" rev-parse main)" ] && ok "p7 local main fast-forwarded" || bad "p7 main not fast-forwarded" "${out}"
# The worktree step then fails (no wt under the fake HOME); p7 asserts only
# that step 1 got through.

# p8 a bad --lock-retries value refuses with a Fix:.
run --repo "${F}/r" --lock-retries soon p8-branch
[ "${rc}" -ne 0 ] && grep -q "^Fix: " <<<"${out}" && ok "p8 bad --lock-retries refuses with Fix:" || bad "p8 bad --lock-retries" "${out}"

# p9 a real divergence keeps today's message.
F="${TMP}/divfix"; mkdir -p "${F}"; mkorigin "${F}"
git clone -q "${F}/o.git" "${F}/r"; advance "${F}" two
git -C "${F}/r" commit -q --allow-empty -m local-only
run --repo "${F}/r" p9-branch
[ "${rc}" -ne 0 ] && ok "p9 divergence refuses" || bad "p9 divergence passed" "${out}"
grep -q "local main diverged" <<<"${out}" && ok "p9 names divergence" || bad "p9 divergence message" "${out}"
grep -q "held by another git process" <<<"${out}" && bad "p9 reported a lock" "${out}" || ok "p9 not called a lock"
grep -q "^Fix: " <<<"${out}" && ok "p9 prints Fix:" || bad "p9 Fix:" "${out}"

# p10 any other failure prints git's own error, not a guess.
F="${TMP}/othfix"; mkdir -p "${F}"; mkorigin "${F}"
git clone -q "${F}/o.git" "${F}/r"
git -C "${F}/r" remote set-url origin "${F}/no-such-origin"
run --repo "${F}/r" p10-branch
[ "${rc}" -ne 0 ] && ok "p10 other failure refuses" || bad "p10 other failure passed" "${out}"
grep -q "does not appear to be a git repository" <<<"${out}" && ok "p10 shows git's stderr" || bad "p10 git stderr" "${out}"
grep -q "diverged" <<<"${out}" && bad "p10 reported divergence" "${out}" || ok "p10 not called divergence"
grep -q "held by another git process" <<<"${out}" && bad "p10 reported a lock" "${out}" || ok "p10 not called a lock"
grep -q "^Fix: " <<<"${out}" && ok "p10 prints Fix:" || bad "p10 Fix:" "${out}"

# p11 a branch other than main that cannot fast-forward is named as being off
# main, never as main diverging (main itself is in step with origin/main).
F="${TMP}/branchfix"; mkdir -p "${F}"; mkorigin "${F}"
git clone -q "${F}/o.git" "${F}/r"
git -C "${F}/r" checkout -q -b feature --track origin/main
git -C "${F}/r" commit -q --allow-empty -m feature-only
advance "${F}" two
run --repo "${F}/r" p11-branch
[ "${rc}" -ne 0 ] && ok "p11 off-main failure refuses" || bad "p11 off-main passed" "${out}"
grep -q "on 'feature', not main" <<<"${out}" && ok "p11 names the branch" || bad "p11 branch message" "${out}"
grep -q "diverged" <<<"${out}" && bad "p11 reported main diverged" "${out}" || ok "p11 not called divergence"
grep -q "^Fix: " <<<"${out}" && ok "p11 prints Fix:" || bad "p11 Fix:" "${out}"

echo "wt-preflight self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: repair scripts/wt-preflight so each case above holds: the address-pool gate (step 0, p1-p4) or the pull-failure classification (step 1, p5-p11)." >&2
  exit 1
fi
