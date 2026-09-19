#!/usr/bin/env bash
# Self-test for the forge-identity preflight guard (ai/bin/forge-preflight) and
# the bypass-visibility hook (ai/hooks/forge-identity-guard.sh) — the durable
# fix for DND-203 / DND-206.
#
# NO NETWORK, EVER. The forge wrappers (gh-athena / glab-athena) are replaced by
# PATH-independent shims passed through the GH_ATHENA_BIN / GLAB_ATHENA_BIN test
# seams; each shim records exactly what argv it was handed and answers from a
# fixed mode. Every assertion here is about a decision that is INVISIBLE in
# production — a broken wrapper that fails open to the owner's identity, a guard
# that probes GitHub with the wrong endpoint and reports a false failure, a
# bypass that stays silent. Each of those looks exactly like the healthy state
# from the outside; that is the whole reason this guard exists.
#
# Run: bash ai/test/forge-preflight/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
PREFLIGHT="${AI_DIR}/bin/forge-preflight"
HOOK="${AI_DIR}/hooks/forge-identity-guard.sh"
CHECK_GUARD="${AI_DIR}/bin/check-guard-messages"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

CASE_N=0
setup_case() {
  CASE_N=$((CASE_N+1))
  CHOME="${TMP}/home${CASE_N}"; mkdir -p "${CHOME}/.claude"
  SHIM_DIR="${TMP}/shim${CASE_N}"; mkdir -p "${SHIM_DIR}"
  ARGV="${SHIM_DIR}/argv"; : > "${ARGV}"
  GH_SHIM=""; GLAB_SHIM=""
}

# make_shim <mode> -> writes a wrapper shim into SHIM_DIR and echoes its path.
# Modes model the exact behaviours DND-203 recorded:
#   gh_healthy   : `--check` exits 0; `api user` returns the 403 an App
#                  installation token ALWAYS returns (no authenticated user).
#                  This single shim is both the healthy case AND the trap.
#   gh_broken    : any call dies naming the missing App ID file (creds absent).
#   glab_healthy : `api user` resolves to the athena-amby service account.
#   glab_broken  : the token file is missing.
make_shim() {
  local mode="$1" path="${SHIM_DIR}/wrapper-${1}"
  cat > "${path}" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${ARGV}"
mode="${mode}"
case "\$mode" in
  gh_healthy)
    if [ "\$1" = "--check" ]; then echo "gh-athena: OK — authenticated as the App"; exit 0; fi
    echo '{"message":"Resource not accessible by integration"}'; exit 1 ;;
  gh_broken)
    # Deliberately GENERIC (no filename): so case 1's "names the file" assertion
    # is pinned on the PREFLIGHT's own Fix: line, not on a relayed wrapper string.
    echo "gh-athena: could not authenticate." >&2
    exit 3 ;;
  glab_healthy)
    echo '{"username":"athena-amby","name":"Athena","bot":true,"state":"active"}'; exit 0 ;;
  glab_wrong_identity)
    # authenticates fine, but as the OWNER, not the service account.
    echo '{"username":"cjpoll","name":"Cody","bot":false,"state":"active"}'; exit 0 ;;
  glab_broken)
    echo "glab-athena: token file \${HOME}/.claude/gitlab-athena-token missing/unreadable (run: glab-athena refresh)" >&2
    exit 1 ;;
esac
EOF
  chmod +x "${path}"
  printf '%s' "${path}"
}

run_preflight() { # run_preflight <remote> [gh_shim] [glab_shim]
  local remote="$1" gh="${2:-/nonexistent/gh}" glab="${3:-/nonexistent/glab}"
  set +e
  OUT="$(env HOME="${CHOME}" FORGE_PREFLIGHT_REMOTE="${remote}" \
    GH_ATHENA_BIN="${gh}" GLAB_ATHENA_BIN="${glab}" \
    "${PREFLIGHT}" 2>"${TMP}/err${CASE_N}")"
  RC=$?
  ERR="$(cat "${TMP}/err${CASE_N}")"
}

run_hook() { # run_hook <command-string>
  local cmd="$1" input
  input="$(jq -Rn --arg c "${cmd}" '{tool_name:"Bash",tool_input:{command:$c}}')"
  set +e
  OUT="$(printf '%s' "${input}" | env HOME="${CHOME}" sh "${HOOK}" 2>"${TMP}/herr${CASE_N}")"
  RC=$?
}

echo "forge-preflight self-test"
echo
echo "-- the preflight: GitHub ---------------------------------------------------"

# 1. Credentials absent (the DND-203 GitHub half): the wrapper cannot
#    authenticate, so opening a PR now would silently become CJPoll. The
#    preflight must REFUSE, and its message must carry a Fix: that names the
#    exact file to create — a bare "it failed" would leave the captain to
#    rediscover the remedy DND-203 already documented.
setup_case
run_preflight "git@github.com:CJPoll/custom.git" "$(make_shim gh_broken)"
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ "${ERR}" == *"github-athena-app-id"* ]]; then
  ok "creds absent: refuses (non-zero) with a Fix: line naming github-athena-app-id"
else bad "creds absent: refuses with a Fix: line naming the file" "rc=${RC} err='${ERR}'"; fi

# 2. Credentials present and healthy: the preflight passes SILENTLY. A guard
#    that chattered on every healthy run would train captains to ignore it, so
#    healthy == no stdout, no stderr, exit 0.
setup_case
run_preflight "https://github.com/CJPoll/custom.git" "$(make_shim gh_healthy)"
if [[ "${RC}" == 0 && -z "${OUT}" && -z "${ERR}" ]]; then
  ok "healthy github: passes silently (exit 0, no output)"
else bad "healthy github: passes silently" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# 3. THE TRAP (the single most likely way to get this ticket wrong). An App
#    installation token returns 403 "Resource not accessible by integration"
#    from `api user` even when perfectly healthy. A guard that probed with
#    `api user` would read that 403 as a failure and push the captain into the
#    exact bare-`gh` fallback this guard exists to prevent. So: with a shim that
#    PASSES `--check` but 403s on `api user`, the preflight must PASS — and the
#    recorded argv proves it probed with `--check` and NEVER with `api user`.
setup_case
run_preflight "git@github.com:CJPoll/custom.git" "$(make_shim gh_healthy)"
if [[ "${RC}" == 0 ]] \
   && grep -q -- '--check' "${ARGV}" \
   && ! grep -q 'api user' "${ARGV}"; then
  ok "403-from-api-user while --check passes: PASSES, and probed with --check not 'api user'"
else bad "403-from-api-user while --check passes: PASSES via --check" \
  "rc=${RC} argv='$(cat "${ARGV}")'"; fi

# 3b. An ssh-alias remote (git@github.com-work:…) is still github.com and must
#     be classified as such: with a broken wrapper it must REFUSE, not fall
#     through to the "unmanaged host" pass. If the `github.com-*` alias pattern
#     were dropped, this remote would exit 0 and a real github target would slip
#     past the only guard in front of it — the failed-lookup-looks-empty bug.
setup_case
run_preflight "git@github.com-work:CJPoll/custom.git" "$(make_shim gh_broken)"
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]]; then
  ok "github ssh-alias host (github.com-work): classified as github, refuses when broken"
else bad "github alias host classified as github" "rc=${RC} err='${ERR}'"; fi

# 3b-ii. DNS hosts are case-insensitive, so a mixed-case remote (GitHub.com)
#     must classify as github and refuse when the wrapper is broken — not fall
#     through to the unmanaged-host pass because the `case` arms are lowercase.
setup_case
run_preflight "git@GitHub.com:CJPoll/custom.git" "$(make_shim gh_broken)"
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]]; then
  ok "mixed-case host (GitHub.com): normalized to github, refuses when broken"
else bad "mixed-case host normalized to github" "rc=${RC} err='${ERR}'"; fi

# 3c. A github subdomain (ssh.github.com, used for ssh-over-443) is github too:
#     a healthy wrapper passes, and the argv proves it probed with --check.
setup_case
run_preflight "ssh://git@ssh.github.com/CJPoll/custom.git" "$(make_shim gh_healthy)"
if [[ "${RC}" == 0 && -z "${OUT}" ]] && grep -q -- '--check' "${ARGV}"; then
  ok "github subdomain host (ssh.github.com): classified as github, passes via --check"
else bad "github subdomain classified as github" "rc=${RC} out='${OUT}' argv='$(cat "${ARGV}")'"; fi

echo
echo "-- the preflight: GitLab (the per-forge asymmetry) -------------------------"

# 3d. The same alias tolerance on the GitLab side: gitlab.com-work is gitlab.com.
setup_case
run_preflight "git@gitlab.com-work:amby_ai/walt_ui.git" "/nonexistent/gh" "$(make_shim glab_healthy)"
if [[ "${RC}" == 0 && -z "${OUT}" ]] && grep -q 'api user' "${ARGV}"; then
  ok "gitlab ssh-alias host (gitlab.com-work): classified as gitlab, passes via 'api user'"
else bad "gitlab alias host classified as gitlab" "rc=${RC} out='${OUT}' argv='$(cat "${ARGV}")'"; fi

# 4. GitLab is the OPPOSITE of GitHub: the athena-amby service-account PAT DOES
#    resolve to an authenticated user, so `api user` succeeding IS the correct
#    health probe here. A healthy GitLab wrapper passes silently, and the argv
#    proves the probe was `api user` — the asymmetry with case 3 is deliberate.
setup_case
run_preflight "ssh://git@gitlab.com/amby_ai/walt_ui.git" "/nonexistent/gh" "$(make_shim glab_healthy)"
if [[ "${RC}" == 0 && -z "${OUT}" && -z "${ERR}" ]] && grep -q 'api user' "${ARGV}"; then
  ok "healthy gitlab: passes silently and probes with 'api user'"
else bad "healthy gitlab: passes silently via 'api user'" "rc=${RC} out='${OUT}' err='${ERR}' argv='$(cat "${ARGV}")'"; fi

# 5. GitLab wrapper broken (token file missing): refuse with a Fix: line that
#    names the remedy (the refresh command), same contract as the GitHub half.
setup_case
run_preflight "git@gitlab.com:amby_ai/walt_ui.git" "/nonexistent/gh" "$(make_shim glab_broken)"
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ "${ERR}" == *"glab-athena refresh"* ]]; then
  ok "gitlab broken: refuses with a Fix: line naming 'glab-athena refresh'"
else bad "gitlab broken: refuses with a Fix: line" "rc=${RC} err='${ERR}'"; fi

# 5b. GitLab authenticates, but as the OWNER not the athena-amby service account
#     (a token file holding the owner's PAT, or an empty file glab falls back
#     from). A check that accepted "some user authenticated" would pass here and
#     let MRs be opened as the owner — the exact failure this guard exists to
#     stop. The preflight must REFUSE, asserting the resolved identity IS Athena.
setup_case
run_preflight "git@gitlab.com:amby_ai/walt_ui.git" "/nonexistent/gh" "$(make_shim glab_wrong_identity)"
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ "${ERR}" == *"athena-amby"* ]]; then
  ok "gitlab authenticates as the owner, not athena-amby: refuses"
else bad "gitlab wrong identity: refuses" "rc=${RC} err='${ERR}'"; fi

# 5c. A FAILED lookup must never look like a clean pass (repo doctrine). No
#     origin remote and no override → the forge cannot be resolved, so a PR
#     opened now would bypass the guard. Refuse with a Fix:, do not exit 0.
setup_case
mkdir -p "${TMP}/nogit${CASE_N}"
set +e
OUT="$(cd "${TMP}/nogit${CASE_N}" && env -u FORGE_PREFLIGHT_REMOTE HOME="${CHOME}" \
  GH_ATHENA_BIN="$(make_shim gh_healthy)" "${PREFLIGHT}" 2>"${TMP}/err${CASE_N}")"
RC=$?; ERR="$(cat "${TMP}/err${CASE_N}")"
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ "${ERR}" == *"origin"* ]]; then
  ok "no origin remote: refuses with a Fix: (a failed lookup is not a clean pass)"
else bad "no origin remote: refuses" "rc=${RC} err='${ERR}'"; fi

# 5d. A remote that parses to an empty host is malformed, not an unmanaged
#     forge — again, a failed lookup must refuse rather than read as "OK".
setup_case
run_preflight "ssh://" "$(make_shim gh_healthy)"
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ ! -s "${ARGV}" ]]; then
  ok "unparseable remote (empty host): refuses and invokes no wrapper"
else bad "empty host: refuses without probing" "rc=${RC} err='${ERR}' argv='$(cat "${ARGV}")'"; fi

# 6. An unmanaged forge host (no wrapper exists for it) is not a failure — the
#    preflight has nothing to assert and must PASS rather than block work on a
#    forge it does not manage (the "never be the reason work stops" principle).
#    It must also not invoke any wrapper: nothing recorded in argv.
setup_case
GH="$(make_shim gh_healthy)"; GLAB="$(make_shim glab_healthy)"
run_preflight "git@example.org:some/repo.git" "${GH}" "${GLAB}"
if [[ "${RC}" == 0 ]] && [[ ! -s "${ARGV}" ]]; then
  ok "unmanaged host: passes and invokes no wrapper"
else bad "unmanaged host: passes and invokes no wrapper" "rc=${RC} argv='$(cat "${ARGV}")'"; fi

echo
echo "-- the bypass hook: warn, never block --------------------------------------"

# 7. A bare `gh pr create` is the silent GitLab-style bypass on GitHub: a
#    healthy wrapper simply not called, re-attributing the PR to the owner. The
#    hook must SURFACE it (non-empty output carrying a Fix:) — and, because a
#    hard block is how the OTHER half of DND-203 stranded a captain, it must
#    NOT deny: no permissionDecision in the output, exit 0.
setup_case
run_hook "gh pr create --fill --base main"
if [[ "${RC}" == 0 ]] && [[ "${OUT}" == *"Fix:"* ]] \
   && [[ "${OUT}" == *"gh-athena"* ]] \
   && [[ "${OUT}" != *"permissionDecision"* ]]; then
  ok "bare 'gh pr create': surfaced with a Fix:, and never denied (warn not block)"
else bad "bare 'gh pr create': surfaced as a non-blocking warn" "rc=${RC} out='${OUT}'"; fi

# 8. The wrapper path must NOT be surfaced — warning on the sanctioned command
#    would be noise that trains the fix away. `gh-athena pr create` has `gh`
#    followed by `-`, not whitespace, so it must produce no output.
setup_case
run_hook "~/dev/custom/ai/bin/gh-athena pr create --fill"
if [[ "${RC}" == 0 && -z "${OUT}" ]]; then
  ok "wrapper path 'gh-athena pr create': not surfaced (no output)"
else bad "wrapper path not surfaced" "rc=${RC} out='${OUT}'"; fi

# 8b. A global flag between the command word and the subcommand
#     (`gh -R owner/repo pr create`) is a common cross-repo form and is still a
#     bare `gh` — it must be surfaced. The wrapper with the SAME flags stays
#     silent, so the tolerance cannot leak into a false positive on the wrapper.
setup_case
run_hook "gh -R owner/repo pr create --fill"
S_FLAG="${OUT}"
setup_case
run_hook "~/dev/custom/ai/bin/gh-athena -R owner/repo pr create --fill"
S_WRAP="${OUT}"
if [[ "${S_FLAG}" == *"Fix:"* ]] && [[ -z "${S_WRAP}" ]]; then
  ok "flags before the subcommand: bare 'gh -R x pr create' surfaced, wrapper still not"
else bad "flags before subcommand boundary" "bare='${S_FLAG}' wrapper='${S_WRAP}'"; fi

# 9. The same for GitLab: bare `glab mr create` surfaced, wrapper path silent.
#    One assertion covers both halves of the boundary that matters here.
setup_case
run_hook "glab mr create --fill"
S1="${OUT}"
setup_case
run_hook "ai/bin/glab-athena mr create --fill"
S2="${OUT}"
if [[ "${S1}" == *"Fix:"* && "${S1}" == *"glab-athena"* ]] && [[ -z "${S2}" ]]; then
  ok "bare 'glab mr create' surfaced; 'glab-athena mr create' is not"
else bad "glab bypass boundary" "bare='${S1}' wrapper='${S2}'"; fi

# 10. FAIL-OPEN: a non-Bash tool is not this guard's business and must pass
#     through silently. A guard that errored on unrelated input would gate every
#     tool call in the session.
setup_case
set +e
OUT="$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | env HOME="${CHOME}" sh "${HOOK}" 2>&1)"; RC=$?
if [[ "${RC}" == 0 && -z "${OUT}" ]]; then
  ok "non-Bash tool: fail-open, silent"
else bad "non-Bash tool: fail-open, silent" "rc=${RC} out='${OUT}'"; fi

echo
echo "-- the guard-message convention --------------------------------------------"

# 11. check-guard-messages must pass: forge-preflight carries a Fix: line (it is
#     listed in GUARD_BINS) and the hook carries one too (every ai/hooks/*.sh is
#     a guard by default). This is the meta-check that a future edit stripping
#     the Fix: clause would redden.
setup_case
set +e
CGM_OUT="$("${CHECK_GUARD}" 2>&1)"; CGM_RC=$?
if [[ "${CGM_RC}" == 0 ]]; then
  ok "check-guard-messages passes (both guards carry an actionable Fix:)"
else bad "check-guard-messages passes" "rc=${CGM_RC} out='${CGM_OUT}'"; fi

echo
if [[ "${FAIL}" -eq 0 ]]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0; fi
echo "VERDICT: FAIL (${FAIL} of $((PASS+FAIL)) cases)"; exit 1
