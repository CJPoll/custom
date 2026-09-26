#!/usr/bin/env bash
# End-to-end suite for ai/bin/block-optimize (DND-528, QA plan I1/I2 and the
# manager cases on real git). A throwaway git repo whose origin/main carries
# STUB ai/bin/{build-agents,check-agent-size,variant-eval}; a stub `claude` on
# PATH stands in for the proposer. No model, no network, no live config.
#
#   I1  refs, HEAD, the index and `git worktree list` are byte-identical before
#       and after a full PROPOSED run.
#   I2  the candidate commit exists and is reachable from no ref.
#   plus: the proposer path, a scope violation (no worktree, no variant-eval),
#   a failing size check (no variant-eval), stale evidence, a malformed JSON.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$(cd "${here}/../../../bin" && pwd)/block-optimize"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/block-optimize-it-XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

export GIT_AUTHOR_NAME=it GIT_AUTHOR_EMAIL=it@localhost GIT_COMMITTER_NAME=it GIT_COMMITTER_EMAIL=it@localhost
export GIT_CONFIG_NOSYSTEM=1

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
expect() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

repo="${tmp}/repo"
mkdir -p "${repo}/ai/bin" "${repo}/ai/blocks/ops" "${repo}/ai/agents" \
  "${repo}/ai/eval/admiral-fixtures/AE-18-refused-spawn-is-pause"

cat > "${repo}/ai/blocks/routing.yml" <<'EOF'
blocks:
  ops/fleet-coordination: [admiral]
  ops/safety-checks: [admiral, captain]
skills: {}
EOF
printf 'fleet coordination rule\n' > "${repo}/ai/blocks/ops/fleet-coordination.md"
printf 'safety rule\n' > "${repo}/ai/blocks/ops/safety-checks.md"
printf 'admiral line one\nadmiral line two\n' > "${repo}/ai/agents/athena-admiral.md.in"
printf 'captain\n' > "${repo}/ai/agents/athena-captain.md.in"
printf 'mode = next-action\nexpect_action = mark-parked:X\n' \
  > "${repo}/ai/eval/admiral-fixtures/AE-18-refused-spawn-is-pause/meta"
printf 'Decide.\n' > "${repo}/ai/eval/admiral-fixtures/AE-18-refused-spawn-is-pause/scenario.md"

# Stub build-agents: render = template + blocks; --check verifies the render.
cat > "${repo}/ai/bin/build-agents" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
render() { cat ai/agents/athena-admiral.md.in ai/blocks/ops/fleet-coordination.md ai/blocks/ops/safety-checks.md; }
if [ "${1:-}" = "--check" ]; then
  render | cmp -s - ai/agents/athena-admiral.md || { echo "stale render. Fix: run build-agents"; exit 1; }
  exit 0
fi
render > ai/agents/athena-admiral.md
if [ "${STUB_BUILD_IGNORED:-0}" = 1 ]; then mkdir -p ai/cache && printf 'planted\n' > ai/cache/planted; fi
cat ai/agents/athena-captain.md.in ai/blocks/ops/fleet-coordination.md > ai/agents/athena-captain.md
EOF
# Stub check-agent-size: fails when told to.
cat > "${repo}/ai/bin/check-agent-size" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_CAS_EXIT:-0}" = 0 ] || { echo "admiral over budget. Fix: shrink it"; exit 1; }
EOF
# Stub variant-eval: writes a schema-v1 JSON for the refs it was handed.
cat > "${repo}/ai/bin/variant-eval" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) variant="$2"; shift 2 ;; --baseline) baseline="$2"; shift 2 ;;
    --json) json="$2"; shift 2 ;; --out) out="$2"; shift 2 ;; *) shift ;;
  esac
done
touch "${STUB_VE_MARK}"
sub() { git show "$1:ai/agents/athena-admiral.md" | sha256sum | cut -c1-64; }
printf 'variant-eval stub\n' > "${out}"
vsha="${STUB_VE_VARIANT:-${variant}}"
cat > "${json}" <<JSON
{"schema":"variant-eval/proposal@1","variant":"${variant}","variant_sha":"${vsha}","baseline":"${baseline}",
 "baseline_sha":"${baseline}","corpus":"full","runs":10,"gate_ok":true,"gate_detail":null,"verdict":"inconclusive",
 "unmeasured":null,"deterministic":{"regressed":[],"fixed":[],"new":[]},
 "t2_subjects":{"base":{"lines":4,"sha256":"$(sub "${baseline}")"},"var":{"lines":4,"sha256":"$(sub "${variant}")"}},
 "t2":[{"name":"AE-18-refused-spawn-is-pause","base":{"k":8,"n":10},"var":{"k":9,"n":10},"flip":"inconclusive"}],
 "regressions":[],"improvements":[]}
JSON
exit 0
EOF
chmod +x "${repo}"/ai/bin/*
printf 'ai/cache/\n' > "${repo}/.gitignore"

git -C "${repo}" init -q -b main
(cd "${repo}" && ai/bin/build-agents)
git -C "${repo}" add -A
git -C "${repo}" commit -qm fixture
git -C "${repo}" update-ref refs/remotes/origin/main HEAD
render_sha12="$(git -C "${repo}" show HEAD:ai/agents/athena-admiral.md | sha256sum | cut -c1-12)"

evidence() { # $1 = sha12
  printf 'subject: %s 4 lines sha %s (loaded inline via --agents as x)\n' "${repo}/ai/agents/athena-admiral.md" "$1"
  printf 'PASS AE-18-refused-spawn-is-pause   8/10   [next-action] ok\n'
  printf 'admiral-eval: 1/1 cases pass (runs/T2 case = 10)\n'
}
evidence "${render_sha12}" > "${tmp}/evidence.txt"
evidence "000000000000" > "${tmp}/stale.txt"

good_patch() {
  cat <<'EOF'
diff --git a/ai/agents/athena-admiral.md.in b/ai/agents/athena-admiral.md.in
index 1111111..2222222 100644
--- a/ai/agents/athena-admiral.md.in
+++ b/ai/agents/athena-admiral.md.in
@@ -1,2 +1,2 @@
-admiral line one
+admiral line one, clearer
 admiral line two
EOF
}
good_patch > "${tmp}/good.diff"
cat > "${tmp}/shared.diff" <<'EOF'
diff --git a/ai/blocks/ops/fleet-coordination.md b/ai/blocks/ops/fleet-coordination.md
index 1111111..2222222 100644
--- a/ai/blocks/ops/fleet-coordination.md
+++ b/ai/blocks/ops/fleet-coordination.md
@@ -1 +1 @@
-fleet coordination rule
+fleet coordination rule, clearer
EOF
sed 's#ai/agents/athena-admiral.md.in#ai/bin/check-agent-size#g' "${tmp}/good.diff" > "${tmp}/scope.diff"

snapshot() {
  {
    git -C "${repo}" for-each-ref
    git -C "${repo}" rev-parse HEAD
    sha256sum "${repo}/.git/index"
    git -C "${repo}" worktree list --porcelain
    git -C "${repo}" status --porcelain
  } > "$1"
}

run_bo() { # $1 = out dir name; rest = args. Sets rc; never aborts the suite.
  local out="${tmp}/$1"
  shift
  rc=0
  (cd "${repo}" && ruby "${bin}" --out-dir "${out}" "$@") > "${tmp}/stdout" 2> "${tmp}/stderr" || rc=$?
}

export STUB_VE_MARK="${tmp}/ve-called"

echo "block-optimize integration:"

# --- I1/I2: a full PROPOSED run via --diff never adopts. ---------------------
snapshot "${tmp}/before"
rm -f "${STUB_VE_MARK}"
run_bo out1 --case AE-18 --evidence "${tmp}/evidence.txt" --diff "${tmp}/good.diff"
snapshot "${tmp}/after"
expect "I-happy exits 0 (rc=${rc})" '[ "${rc}" = 0 ]'
expect "I-happy labels UNPROVEN" 'grep -q "PROPOSED — NO MEASURED REGRESSION; IMPROVEMENT UNPROVEN" "${tmp}/out1/proposal.md"'
expect "I-happy blast radius is none (only the admiral template changed)" 'grep -q "blast radius: none" "${tmp}/out1/proposal.md"'
for f in proposal.diff scorecard.json scorecard.txt proposal.md; do
  expect "I-happy wrote ${f}" '[ -s "${tmp}/out1/${f}" ]'
done
expect "I-happy proposal.diff carries source paths only" \
  'grep -q "athena-admiral.md.in" "${tmp}/out1/proposal.diff" && ! grep -q "^+++ b/ai/agents/athena-admiral.md$" "${tmp}/out1/proposal.diff"'
expect "I1 refs, HEAD, index, worktree list and status are byte-identical" 'cmp -s "${tmp}/before" "${tmp}/after"'
cand="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["variant_sha"]' "${tmp}/out1/scorecard.json")"
expect "I2 the candidate is a commit object" '[ "$(git -C "${repo}" cat-file -t "${cand}")" = commit ]'
expect "I2 the candidate is reachable from no ref" '[ -z "$(git -C "${repo}" for-each-ref --contains "${cand}")" ]'
expect "I2 the candidate's parent is origin/main" \
  '[ "$(git -C "${repo}" rev-parse "${cand}^")" = "$(git -C "${repo}" rev-parse origin/main)" ]'
expect "I-happy leaves no scratch worktree registered" '[ ! -d "${repo}/.git/worktrees" ] || [ -z "$(ls -A "${repo}/.git/worktrees")" ]'

# --- the proposer path (stub claude on PATH). ---------------------------------
stubbin="${tmp}/stubbin"
mkdir -p "${stubbin}"
cat > "${stubbin}/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${tmp}/claude-argv"
cat > "${tmp}/claude-prompt"
printf 'Here it is.\n\`\`\`diff\n'
cat "${tmp}/shared.diff"
printf '\`\`\`\n'
EOF
chmod +x "${stubbin}/claude"
PATH="${stubbin}:${PATH}" run_bo out2 --case AE-18-refused-spawn-is-pause --evidence "${tmp}/evidence.txt"
expect "I-proposer exits 0 (rc=${rc})" '[ "${rc}" = 0 ]'
expect "I-proposer blast radius lists the captain render (a shared block changed)" \
  'grep -q "UNMEASURED (no behavioral corpus): athena-captain" "${tmp}/out2/proposal.md"'
expect "I-proposer passed --tools with an empty value" 'grep -qx -- "--tools" "${tmp}/claude-argv" && grep -qx "" "${tmp}/claude-argv"'
expect "I-proposer passed --disallowedTools ... WebSearch" 'grep -qx "WebSearch" "${tmp}/claude-argv"'
expect "I-proposer prompt carries the scenario and allowed files" \
  'grep -q "Decide." "${tmp}/claude-prompt" && grep -q "### ai/blocks/ops/fleet-coordination.md" "${tmp}/claude-prompt"'
expect "I-proposer prompt never carries safety-checks" '! grep -q "### ai/blocks/ops/safety-checks.md" "${tmp}/claude-prompt"'

# --- an unfenced patch outside the fence is never applied (critic, cca15bb). --
cat > "${stubbin}/claude" <<EOF
#!/usr/bin/env bash
cat > /dev/null
printf 'Here it is.\n\`\`\`diff\n'
cat "${tmp}/good.diff"
printf '\`\`\`\nAnd one more, outside the fence:\n'
cat "${tmp}/shared.diff"
EOF
PATH="${stubbin}:${PATH}" run_bo out2b --case AE-18 --evidence "${tmp}/evidence.txt"
expect "I-smuggle exits 0 (rc=${rc})" '[ "${rc}" = 0 ]'
expect "I-smuggle applied only the fenced patch (fleet-coordination untouched)" \
  '! grep -q "fleet-coordination" "${tmp}/out2b/proposal.diff" && grep -q "blast radius: none" "${tmp}/out2b/proposal.md"'

# --- scope violation: rejected before any worktree or variant-eval. ------------
rm -f "${STUB_VE_MARK}"
snapshot "${tmp}/before"
run_bo out3 --case AE-18 --diff "${tmp}/scope.diff"
snapshot "${tmp}/after"
expect "I-scope exits 1 (rc=${rc})" '[ "${rc}" = 1 ]'
expect "I-scope names the denied path" 'grep -q "REJECTED: scope violation (before any git write): ai/bin/check-agent-size" "${tmp}/out3/proposal.md"'
expect "I-scope never called variant-eval" '[ ! -e "${STUB_VE_MARK}" ]'
expect "I-scope left the repo byte-identical" 'cmp -s "${tmp}/before" "${tmp}/after"'

# --- a failing size check: no variant-eval. ------------------------------------
rm -f "${STUB_VE_MARK}"
STUB_CAS_EXIT=1 run_bo out4 --case AE-18 --diff "${tmp}/good.diff"
expect "I-size exits 1 (rc=${rc})" '[ "${rc}" = 1 ]'
expect "I-size names check-agent-size" 'grep -q "ai/bin/check-agent-size failed" "${tmp}/out4/proposal.md"'
expect "I-size never called variant-eval" '[ ! -e "${STUB_VE_MARK}" ]'

# --- a gitignored file planted by the build is still an effect (critic, 64ebc3a).
rm -f "${STUB_VE_MARK}"
STUB_BUILD_IGNORED=1 run_bo out4b --case AE-18 --diff "${tmp}/good.diff"
expect "I-ignored exits 1 (rc=${rc})" '[ "${rc}" = 1 ]'
expect "I-ignored names the planted ignored path" \
  'grep -q "REJECTED: scope violation after build: ai/cache/" "${tmp}/out4b/proposal.md"'
expect "I-ignored never called variant-eval" '[ ! -e "${STUB_VE_MARK}" ]'

# --- stale evidence. -----------------------------------------------------------
run_bo out5 --case AE-18 --evidence "${tmp}/stale.txt" --diff "${tmp}/good.diff"
expect "I-stale exits 1 (rc=${rc})" '[ "${rc}" = 1 ]'
expect "I-stale says STALE" 'grep -q "STALE evidence" "${tmp}/out5/proposal.md"'

# --- a JSON naming another candidate is malformed, never UNPROVEN. -------------
STUB_VE_VARIANT="$(printf 'd%.0s' $(seq 40))" run_bo out6 --case AE-18 --diff "${tmp}/good.diff"
expect "I-malformed exits 1 (rc=${rc})" '[ "${rc}" = 1 ]'
expect "I-malformed says malformed" 'grep -q "malformed variant-eval JSON" "${tmp}/out6/proposal.md"'

# --- usage: a non-empty out-dir is refused (exit 2). ---------------------------
run_bo out1 --case AE-18 --diff "${tmp}/good.diff"
expect "I-usage a non-empty --out-dir exits 2 (rc=${rc})" '[ "${rc}" = 2 ]'
expect "I-usage carries Fix:" 'grep -q "Fix:" "${tmp}/stderr"'

if [ "${failures}" -ne 0 ]; then
  echo "block-optimize integration: ${failures} check(s) FAILED" >&2
  echo "  Fix: ai/bin/block-optimize must reject before any git write or model spend on a bad candidate, and a" >&2
  echo "  PROPOSED run must leave refs/HEAD/index/worktree list untouched with the candidate on no ref." >&2
  exit 1
fi
echo "block-optimize integration: OK"
