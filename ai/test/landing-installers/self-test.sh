#!/usr/bin/env bash
# Self-test for ai/bin/landing-installers (DND-1664).
#
# The gap this pins: check-hooks-registered and check-inbox-registry read their
# bar AS LANDED on origin/main, so a ~/dev/custom landing that adds a row to
# ai/hooks/registry.json or ai/inbox/registry.json makes that row required the
# moment the push lands. The no-CI landing ran `main-health check` right after
# the fast-forward with no installer step, so the landed tip gated RED (1 of
# 169: landed row not wired) and the red marker refused every push to main
# (measured 2026-10-02 01:17Z, DND-1653 landing e4eed785).
#
# landing-installers is the one home of "which installer a landing needs":
# keyed on the landed range touching either registry, run from the MAIN
# checkout after the fast-forward, before main-health. Cases:
#   1  a range that adds a hook row runs setup-hooks --install, then its --check
#   2  a range that touches the inbox registry runs setup-inbox-registry
#   3  a range touching neither runs nothing, and says how many it considered
#   4  a changed `env` section: where the env is active (the hooks --check
#      fails) the owner's --install-env is named, exit 4, never run; where it
#      is inactive nothing is owed (exit 0); a failed check with no env change
#      is exit 1
#   5  --dry-run names the installers and runs none
#   6  a wrongly computed key (unknown SHA, reversed range) is exit 2, not "none"
#   7  a main checkout that has not fast-forwarded to --to is exit 3, ran none
#   8  a linked worktree is not the main checkout: exit 3, ran none
#   9  a failing installer or a failing --check is exit 1 with a Fix:
#  10  --help is stdout, exit 0, and runs nothing
#  11  the landing procedure orders landing-installers between the fast-forward
#      and main-health check (merge-boarding's no-CI landing, CLAUDE.md)
#  12  --repo inside the main checkout resolves to its top level
#  13  an unparseable hooks registry is exit 3, never "env unchanged"
#  14  a missing installer is exit 3, never a pass
#
# Hermetic: fixture repos only, the global git config replaced; the installers
# are stubs committed INTO the fixture (the tool runs the main checkout's own
# scripts/), and each records its argv.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
REPO_ROOT="$(dirname "${AI_DIR}")"
TOOL="${LANDING_INSTALLERS_UNDER_TEST:-${AI_DIR}/bin/landing-installers}"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${T}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"
export GIT_TERMINAL_PROMPT=0
unset GIT_CONFIG_COUNT
export LI_T="${T}"

# --- fixture ------------------------------------------------------------------
# A main checkout with both registries and two stub installers. Each stub
# appends "<name> <argv>" to ${LI_T}/ran.log; LI_FAIL=<name>:<flag> makes that
# one call fail.
R="${T}/main"
mkdir -p "${R}/scripts" "${R}/ai/hooks" "${R}/ai/inbox"
for s in setup-hooks setup-inbox-registry; do
  cat > "${R}/scripts/${s}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${s}" "\$*" >> "\${LI_T}/ran.log"
[ "\${LI_FAIL:-}" = "${s}:\$1" ] && { echo "${s}: simulated failure" >&2; exit 1; }
exit 0
EOF
  chmod +x "${R}/scripts/${s}"
done
printf '{"_meta":{},"env":{"A":"1"},"hooks":[],"retired":[]}\n' > "${R}/ai/hooks/registry.json"
printf '{"_meta":{},"v":1,"projects":[]}\n' > "${R}/ai/inbox/registry.json"
printf 'x\n' > "${R}/README"
git -C "${R}" init -q && git -C "${R}" add -A && git -C "${R}" commit -qm base
BASE="$(git -C "${R}" rev-parse HEAD)"

commit() { # <message> ; commits whatever the caller changed
  git -C "${R}" add -A && git -C "${R}" commit -qm "$1"
  git -C "${R}" rev-parse HEAD
}

printf '{"_meta":{},"env":{"A":"1"},"hooks":[{"event":"PreToolUse","script":"x.sh"}],"retired":[]}\n' > "${R}/ai/hooks/registry.json"
HOOKS="$(commit 'add a hook row')"
printf '{"_meta":{},"v":1,"projects":[{"file":"p.json"}]}\n' > "${R}/ai/inbox/registry.json"
INBOX="$(commit 'add an inbox entry')"
printf 'y\n' > "${R}/README"
PLAIN="$(commit 'touch neither registry')"
printf '{"_meta":{},"env":{"A":"2"},"hooks":[{"event":"PreToolUse","script":"x.sh"}],"retired":[]}\n' > "${R}/ai/hooks/registry.json"
ENV="$(commit 'change the env section')"

run() { # <args...> ; sets RC OUT ERR, clears ran.log first
  : > "${T}/ran.log"
  OUT="$("${TOOL}" "$@" 2>"${T}/err")"; RC=$?
  ERR="$(cat "${T}/err")"
  RAN="$(cat "${T}/ran.log")"
}


has() { # <pattern> <text> ; grep -q on a here-string (no pipe under pipefail)
  grep -q -- "$1" <<<"$2"
}

# --- 1 ------------------------------------------------------------------------
run --repo "${R}" --from "${BASE}" --to "${HOOKS}"
if [ "${RC}" -eq 0 ] \
   && [ "${RAN}" = "$(printf 'setup-hooks --install\nsetup-hooks --check')" ]; then
  ok "1 a hook row landed: setup-hooks --install then --check, exit 0"
else
  bad "1 a hook row landed" "rc=${RC} ran=[${RAN}] out=[${OUT}] err=[${ERR}]"
fi

# --- 2 ------------------------------------------------------------------------
run --to "${INBOX}" --repo "${R}" --from "${HOOKS}"
if [ "${RC}" -eq 0 ] \
   && [ "${RAN}" = "$(printf 'setup-inbox-registry --install\nsetup-inbox-registry --check')" ]; then
  ok "2 an inbox entry landed: setup-inbox-registry --install then --check (flag order free)"
else
  bad "2 an inbox entry landed" "rc=${RC} ran=[${RAN}] out=[${OUT}] err=[${ERR}]"
fi

# --- 3 ------------------------------------------------------------------------
run --repo "${R}" --from "${INBOX}" --to "${PLAIN}"
if [ "${RC}" -eq 0 ] && [ -z "${RAN}" ] \
   && has '2 registries considered, 0 changed' "${OUT}"; then
  ok "3 neither registry touched: nothing runs, and the count is printed"
else
  bad "3 neither registry touched" "rc=${RC} ran=[${RAN}] out=[${OUT}]"
fi

# --- 4 ------------------------------------------------------------------------
# 4a: env changed, the env is INACTIVE here (the hooks --check passes): the
#     agent installer runs, nothing is owed, no ask for a no-op.
run --repo "${R}" --from "${PLAIN}" --to "${ENV}"
if [ "${RC}" -eq 0 ] \
   && [ "${RAN}" = "$(printf 'setup-hooks --install\nsetup-hooks --check')" ] \
   && has 'note: .*env section' "${OUT}" && ! has 'OWNER STEP' "${OUT}"; then
  ok "4a env changed, env inactive (check passes): installer runs, exit 0, a note and no owner step"
else
  bad "4a env changed, env inactive" "rc=${RC} ran=[${RAN}] out=[${OUT}] err=[${ERR}]"
fi
# 4b: env changed, the env is ACTIVE here (the hooks --check reads DRIFT after
#     the plain install): exit 4 names --install-env as the owner's; never runs it.
LI_FAIL="setup-hooks:--check" run --repo "${R}" --from "${PLAIN}" --to "${ENV}"
if [ "${RC}" -eq 4 ] \
   && [ "${RAN}" = "$(printf 'setup-hooks --install\nsetup-hooks --check')" ] \
   && has 'OWNER STEP: scripts/setup-hooks --install-env' "${OUT}" \
   && has '^Fix:.*install-env' "${ERR}" \
   && ! has 'install-env' "${RAN}"; then
  ok "4b env changed, env active (check fails): exit 4 names the owner's --install-env, never runs it"
else
  bad "4b env changed, env active" "rc=${RC} ran=[${RAN}] out=[${OUT}] err=[${ERR}]"
fi
# 4c: the same failing check on a range that did NOT change env is exit 1:
#     exit 4 is reserved for the owner's step.
LI_FAIL="setup-hooks:--check" run --repo "${R}" --from "${BASE}" --to "${HOOKS}"
if [ "${RC}" -eq 1 ] && ! has 'OWNER STEP' "${OUT}" && has '^Fix:' "${ERR}"; then
  ok "4c a failed hooks --check with no env change is exit 1, not an owner step"
else
  bad "4c failed check, no env change" "rc=${RC} out=[${OUT}] err=[${ERR}]"
fi

# --- 5 ------------------------------------------------------------------------
run --dry-run --repo "${R}" --from "${BASE}" --to "${INBOX}"
if [ "${RC}" -eq 0 ] && [ -z "${RAN}" ] \
   && has 'scripts/setup-hooks --install' "${OUT}" \
   && has 'scripts/setup-inbox-registry --install' "${OUT}"; then
  ok "5 --dry-run names both installers and runs none"
else
  bad "5 --dry-run" "rc=${RC} ran=[${RAN}] out=[${OUT}] err=[${ERR}]"
fi
run --dry-run --repo "${R}" --from "${PLAIN}" --to "${ENV}"
if [ "${RC}" -eq 0 ] && [ -z "${RAN}" ] && has 'note: .*install-env' "${OUT}"; then
  ok "5b --dry-run over an env change notes the possible owner step, exit 0"
else
  bad "5b --dry-run env change" "rc=${RC} ran=[${RAN}] out=[${OUT}] err=[${ERR}]"
fi

# --- 6 ------------------------------------------------------------------------
run --repo "${R}" --from deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --to "${HOOKS}"
rc_a="${RC}"; ran_a="${RAN}"; err_a="${ERR}"
run --repo "${R}" --from "${HOOKS}" --to "${BASE}"
if [ "${rc_a}" -eq 2 ] && [ -z "${ran_a}" ] && has '^Fix:' "${err_a}" \
   && [ "${RC}" -eq 2 ] && [ -z "${RAN}" ] && has '^Fix:' "${ERR}"; then
  ok "6 an unknown SHA or a reversed range is exit 2 with Fix:, never an empty plan"
else
  bad "6 wrong key" "unknown: rc=${rc_a} ran=[${ran_a}] err=[${err_a}]; reversed: rc=${RC} ran=[${RAN}] err=[${ERR}]"
fi

# --- 7 ------------------------------------------------------------------------
git -C "${R}" checkout -q "${BASE}"
run --repo "${R}" --from "${BASE}" --to "${HOOKS}"
git -C "${R}" checkout -q main
if [ "${RC}" -eq 3 ] && [ -z "${RAN}" ] && has '^Fix:.*ff-only' "${ERR}"; then
  ok "7 a main checkout behind --to is exit 3, ran nothing, Fix: names the fast-forward"
else
  bad "7 checkout behind --to" "rc=${RC} ran=[${RAN}] err=[${ERR}]"
fi

# --- 8 ------------------------------------------------------------------------
git -C "${R}" worktree add -q --detach "${T}/wt" "${ENV}"
run --repo "${T}/wt" --from "${BASE}" --to "${HOOKS}"
if [ "${RC}" -eq 3 ] && [ -z "${RAN}" ] && has '^Fix:' "${ERR}"; then
  ok "8 a linked worktree is refused (exit 3): installers run from the main checkout"
else
  bad "8 linked worktree" "rc=${RC} ran=[${RAN}] err=[${ERR}]"
fi
# ...but a dry run from a worktree is fine: it reads, it never installs.
run --dry-run --repo "${T}/wt" --from "${BASE}" --to "${HOOKS}"
if [ "${RC}" -eq 0 ] && [ -z "${RAN}" ]; then
  ok "8b --dry-run from a linked worktree reads the plan"
else
  bad "8b dry-run from worktree" "rc=${RC} ran=[${RAN}] err=[${ERR}]"
fi

# --- 9 ------------------------------------------------------------------------
LI_FAIL="setup-hooks:--install" run --repo "${R}" --from "${BASE}" --to "${INBOX}"
rc_i="${RC}"; ran_i="${RAN}"; err_i="${ERR}"
LI_FAIL="setup-inbox-registry:--check" run --repo "${R}" --from "${BASE}" --to "${INBOX}"
if [ "${rc_i}" -eq 1 ] && has '^Fix:' "${err_i}" \
   && ! has 'setup-hooks --check' "${ran_i}" \
   && [ "${RC}" -eq 1 ] && has '^Fix:' "${ERR}"; then
  ok "9 a failed installer (its --check skipped) or a failed --check is exit 1 with Fix:"
else
  bad "9 failures" "install: rc=${rc_i} ran=[${ran_i}] err=[${err_i}]; check: rc=${RC} ran=[${RAN}] err=[${ERR}]"
fi

# --- 10 -----------------------------------------------------------------------
: > "${T}/ran.log"
help_out="$("${TOOL}" --help 2>/dev/null)"; help_rc=$?
if [ "${help_rc}" -eq 0 ] && has 'landing-installers' "${help_out}" \
   && [ ! -s "${T}/ran.log" ]; then
  ok "10 --help is stdout, exit 0, runs nothing"
else
  bad "10 --help" "rc=${help_rc}"
fi

# --- 11 -----------------------------------------------------------------------
# The procedure itself: in each statement of the no-CI landing, the installer
# COMMAND comes after the fast-forward command and before the main-health
# COMMAND. Each pattern names the ai/bin/ path, so prose mentioning
# "main-health check" cannot satisfy it. The installer pattern is per file:
# merge-boarding also runs a --dry-run before the push (step 3), so there the
# installing call is the one with --repo.
order_ok() { # <file> <start-pattern> <end-pattern> <installer-run pattern>
  awk -v s="$2" -v e="$3" '
    index($0, s) { on = 1 }
    on && index($0, e) { exit }
    on { print }' "$1" > "${T}/section"
  local ff li mh
  ff="$(grep -n -- 'merge --ff-only' "${T}/section" | head -n 1 | cut -d: -f1)"
  li="$(grep -n -- "$4" "${T}/section" | head -n 1 | cut -d: -f1)"
  mh="$(grep -n -- 'ai/bin/main-health check' "${T}/section" | head -n 1 | cut -d: -f1)"
  [ -n "${ff}" ] && [ -n "${li}" ] && [ -n "${mh}" ] && [ "${ff}" -lt "${li}" ] && [ "${li}" -lt "${mh}" ]
}
MB="${REPO_ROOT}/ai/skills/athena:merge-boarding/SKILL.md"
if order_ok "${MB}" 'The landing, as Cody confirmed it' 'Stop the line' 'ai/bin/landing-installers --repo'; then
  ok "11a merge-boarding's no-CI landing: fast-forward, landing-installers, then main-health check"
else
  bad "11a merge-boarding order" "$(head -n 60 "${T}/section")"
fi
if order_ok "${REPO_ROOT}/CLAUDE.md" '**An admiral merges that PR; nobody waits for the owner.**' 'A red `main` or a failed deploy stops the line' 'ai/bin/landing-installers'; then
  ok "11b CLAUDE.md's landing steps: fast-forward, landing-installers, then main-health check"
else
  bad "11b CLAUDE.md order" "$(cat "${T}/section")"
fi

# --- 12 -----------------------------------------------------------------------
# A directory inside the main checkout names that checkout: the installers are
# found at its top level, not reported missing.
mkdir -p "${R}/ai/sub"
run --repo "${R}/ai/sub" --from "${BASE}" --to "${HOOKS}"
if [ "${RC}" -eq 0 ] \
   && [ "${RAN}" = "$(printf 'setup-hooks --install\nsetup-hooks --check')" ]; then
  ok "12 --repo inside the main checkout resolves to its top level"
else
  bad "12 subdirectory --repo" "rc=${RC} ran=[${RAN}] err=[${ERR}]"
fi

# --- 13 -----------------------------------------------------------------------
# A hooks registry that does not parse at TO: COULD NOT LOOK (exit 3), never a
# silent "env unchanged".
printf '{not json\n' > "${R}/ai/hooks/registry.json"
BADJSON="$(commit 'break the hooks registry')"
run --repo "${R}" --from "${ENV}" --to "${BADJSON}"
if [ "${RC}" -eq 3 ] && [ -z "${RAN}" ] && has 'does not parse' "${ERR}" && has '^Fix:' "${ERR}"; then
  ok "13 an unparseable hooks registry is exit 3 with Fix:, nothing run"
else
  bad "13 unparseable registry" "rc=${RC} ran=[${RAN}] err=[${ERR}]"
fi

# --- 14 -----------------------------------------------------------------------
# An installer the landed tree lacks: exit 3, named, not a pass.
git -C "${R}" rm -q scripts/setup-inbox-registry
printf '{"_meta":{},"v":1,"projects":[{"file":"q.json"}]}\n' > "${R}/ai/inbox/registry.json"
NOINST="$(commit 'inbox change, installer gone')"
run --repo "${R}" --from "${BADJSON}" --to "${NOINST}"
if [ "${RC}" -eq 3 ] && [ -z "${RAN}" ] && has 'setup-inbox-registry is missing' "${ERR}" && has '^Fix:' "${ERR}"; then
  ok "14 a missing installer is exit 3 with Fix:"
else
  bad "14 missing installer" "rc=${RC} ran=[${RAN}] err=[${ERR}]"
fi

printf '\nlanding-installers self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
