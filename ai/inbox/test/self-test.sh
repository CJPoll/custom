#!/usr/bin/env bash
# Self-test for the Athena Inbox tenancy registry's three artifacts:
# ai/inbox/registry.json (committed source of truth),
# scripts/setup-inbox-registry (idempotent installer),
# ai/bin/check-inbox-registry (unprompted read-only drift check).
#
# Every assertion here is about a decision that is INVISIBLE in production. The
# contract defines a missing registry entry as zero channels, exit 0, no error —
# so a clobbered entry, an entry written 0644, an installer that rewrites the
# directory instead of merging into it, and a check that quietly passes over a
# dead registry all look exactly like the healthy state from the outside. The
# anti-clobber case (C3) is the one this whole ticket exists for.
#
# Nothing outside the sandbox is touched: $HOME, $ATHENA_INBOX_ROOT and the
# source of truth are all redirected into a mktemp -d that the EXIT trap
# removes. No network, ever — nothing here makes a request.
#
# Run: bash ai/inbox/test/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
SETUP="${REPO}/scripts/setup-inbox-registry"
CHECK="${REPO}/ai/bin/check-inbox-registry"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0

SKIP=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  skip  %s\n        %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }

# A version manager's shim resolves its installs through $HOME (asdf, mise,
# rbenv), so faking HOME without this makes every ruby script exit 126 — twenty
# assertions failing at once for a reason that has nothing to do with the code
# under test. Pin the shim at the real home before HOME is replaced.
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-${HOME}/.asdf}"
export ASDF_DIR="${ASDF_DIR:-${HOME}/.asdf}"
RUBY_BIN="$( (cd "${REPO}" && asdf which ruby) 2>/dev/null || command -v ruby)"

# Sandbox: a fake HOME (so a declared "~/..." repo cannot reach a real path),
# a fake inbox root, and a fixture source of truth.
export HOME="${TMP}/home"
export ATHENA_INBOX_ROOT="${TMP}/root"
export ATHENA_INBOX_REGISTRY="${TMP}/registry.json"
mkdir -p "${HOME}"
PROJECTS="${ATHENA_INBOX_ROOT}/projects"

# A one-project fixture. `repo` is written with ~ so the expansion is exercised;
# the fake HOME keeps it pointing at nothing real.
write_registry() {
  cat > "${ATHENA_INBOX_REGISTRY}" <<'JSON'
{
  "projects": [
    {
      "file": "demo.json",
      "entry": {
        "v": 1,
        "repo": "~/dev/demo/.git",
        "channels": {
          "slack": {
            "kind": "log",
            "path": "demo-slack.jsonl",
            "dedupe": ["event_id"],
            "schema_v": [1]
          }
        }
      }
    }
  ]
}
JSON
}

reset_sandbox() {
  rm -rf "${ATHENA_INBOX_ROOT}"
  write_registry
}

# A stray entry belonging to nothing this list declares. It must survive every
# install and every remove, untouched, byte for byte.
UNRELATED_JSON='{"v":1,"repo":"/somewhere/else/.git","channels":{}}'
plant_unrelated() {
  mkdir -p "${PROJECTS}"; chmod 700 "${PROJECTS}"
  printf '%s\n' "${UNRELATED_JSON}" > "${PROJECTS}/stranger.json"
  chmod 600 "${PROJECTS}/stranger.json"
}

# Content + mode + size fingerprint of the whole projects/ directory.
snapshot() { ( cd "${PROJECTS}" 2>/dev/null && find . -type f -print0 | sort -z | xargs -0 -r stat -c '%n %a %s' ; cksum "${PROJECTS}"/* 2>/dev/null ) | sort; }

mode_of() { stat -c '%a' "$1" 2>/dev/null; }

echo "registry self-test"

# --- C1: a fresh install creates the entry with the modes the contract makes a
# MUST. 0644 in a 0755 directory is readable by anything on the box and looks
# identical to a correct install from the outside.
reset_sandbox
"${SETUP}" --install >/dev/null 2>&1
if [ "$(mode_of "${PROJECTS}/demo.json")" = "600" ] && [ "$(mode_of "${PROJECTS}")" = "700" ]; then
  ok "C1 install writes the entry 0600 inside a 0700 projects/"
else
  bad "C1 install writes the entry 0600 inside a 0700 projects/" \
      "got entry=$(mode_of "${PROJECTS}/demo.json") dir=$(mode_of "${PROJECTS}")"
fi

# --- C2: idempotence. A second install must report no changes and write
# nothing; an installer that rewrites on every run cannot be run from a hook or
# a setup script without churning the files it is protecting.
before="$(snapshot)"
out2="$("${SETUP}" --install 2>&1)"
after="$(snapshot)"
if printf '%s' "${out2}" | grep -q "nothing to do" && [ "${before}" = "${after}" ]; then
  ok "C2 a second install is a no-op"
else
  bad "C2 a second install is a no-op" "output: ${out2}"
fi

# --- C3: THE ANTI-CLOBBER CASE, and the point of this ticket. An entry the
# committed list does not declare — another project's, or one being trialled by
# hand — must survive an install untouched. A full-directory rewrite is what
# silently dropped two hooks on 2026-09-17.
plant_unrelated
stranger_before="$(cat "${PROJECTS}/stranger.json")"
"${SETUP}" --install >/dev/null 2>&1
if [ -f "${PROJECTS}/stranger.json" ] && [ "$(cat "${PROJECTS}/stranger.json")" = "${stranger_before}" ]; then
  ok "C3 an undeclared entry survives an install byte for byte"
else
  bad "C3 an undeclared entry survives an install byte for byte" \
      "stranger.json is $( [ -f "${PROJECTS}/stranger.json" ] && echo changed || echo gone )"
fi

# --- C4: the check must not police, or even name, an entry it does not
# declare. Naming it would turn the check into a cross-tenant disclosure path,
# which the contract forbids of every refusal.
outc="$("${CHECK}" 2>&1)"
if [ $? -eq 0 ] && ! printf '%s' "${outc}" | grep -q "stranger"; then
  ok "C4 an undeclared entry is neither failed nor named by the check"
else
  bad "C4 an undeclared entry is neither failed nor named by the check" "${outc}"
fi

# --- C5: a hand-edited entry is drift, and the failure NAMES the file. A check
# that fails without naming the entry leaves the owner diffing two untracked
# files by hand.
printf '%s\n' '{"v":1,"repo":"/wrong/.git","channels":{}}' > "${PROJECTS}/demo.json"
chmod 600 "${PROJECTS}/demo.json"
out5="$("${CHECK}" 2>&1)"; rc5=$?
if [ ${rc5} -ne 0 ] && printf '%s' "${out5}" | grep -q "demo.json"; then
  ok "C5 a hand-edited entry fails the check, naming the entry"
else
  bad "C5 a hand-edited entry fails the check, naming the entry" "rc=${rc5}: ${out5}"
fi

# --- C6: the failure carries the greppable Fix: clause (CLAUDE.md, guard
# messages are written for the LLM). A bare failure tells an agent nothing about
# how to self-correct.
if printf '%s' "${out5}" | grep -q "Fix:"; then
  ok "C6 the drift failure carries an actionable Fix: line"
else
  bad "C6 the drift failure carries an actionable Fix: line" "${out5}"
fi

# --- C7: the check is READ-ONLY, including on the failure path. A check that
# repairs what it finds destroys the evidence of the drift and hides how often
# the registry is being clobbered.
#
# The sandbox is rebuilt first, deliberately: taking the snapshot after the
# earlier failing checks would compare one polluted state with the next and go
# green over a check that writes the same file every run (measured — a marker-
# writing mutation survived the earlier form of this case).
reset_sandbox
"${SETUP}" --install >/dev/null 2>&1
plant_unrelated
printf '%s\n' '{"v":1,"repo":"/wrong/.git","channels":{}}' > "${PROJECTS}/demo.json"
chmod 600 "${PROJECTS}/demo.json"
snap_before="$(snapshot)"
"${CHECK}" >/dev/null 2>&1
if [ "$(snapshot)" = "${snap_before}" ]; then
  ok "C7 the check writes nothing, even when it fails"
else
  bad "C7 the check writes nothing, even when it fails" "projects/ changed during a failing check"
fi

# --- C8: install repairs a hand-edited entry AND backs up what it replaced.
# Without the backup an install would destroy a deliberate local edit with no
# undo — the same shape as the clobber this tooling exists to answer.
out8="$("${SETUP}" --install 2>&1)"
if "${CHECK}" >/dev/null 2>&1 && ls "${PROJECTS}"/demo.json.bak-* >/dev/null 2>&1; then
  ok "C8 install repairs a drifted entry and backs up what it replaced"
else
  bad "C8 install repairs a drifted entry and backs up what it replaced" "${out8}"
fi

# --- C9: a DELETED entry is drift. This is the silent-death case: the contract
# says a missing entry means zero channels and exit 0, so nothing else on the
# machine will ever mention it.
rm -f "${PROJECTS}/demo.json"
out9="$("${CHECK}" 2>&1)"; rc9=$?
if [ ${rc9} -ne 0 ] && printf '%s' "${out9}" | grep -q "demo.json is missing"; then
  ok "C9 a deleted entry fails the check"
else
  bad "C9 a deleted entry fails the check" "rc=${rc9}: ${out9}"
fi

# --- C10: and install restores it. The check tells you what is wrong; the
# installer is the recovery path its Fix: line points at, so that path has to
# actually work.
"${SETUP}" --install >/dev/null 2>&1
if "${CHECK}" >/dev/null 2>&1; then
  ok "C10 install restores a deleted entry"
else
  bad "C10 install restores a deleted entry" "$("${CHECK}" 2>&1)"
fi

# --- C11: a wrong mode alone is drift. An entry that is correct but world-
# readable still violates the contract, and nothing else would report it.
chmod 644 "${PROJECTS}/demo.json"
out11="$("${CHECK}" 2>&1)"
if printf '%s' "${out11}" | grep -q "0644"; then
  ok "C11 a 0644 entry is reported as drift"
else
  bad "C11 a 0644 entry is reported as drift" "${out11}"
fi
"${SETUP}" --install >/dev/null 2>&1

# --- C12: --dry-run reports what it would do and writes NOTHING. A dry run that
# writes is worse than no dry run, because it is used precisely when the caller
# is unsure.
rm -f "${PROJECTS}/demo.json"
snap_before="$(snapshot)"
out12="$("${SETUP}" --install --dry-run 2>&1)"
if [ "$(snapshot)" = "${snap_before}" ] && printf '%s' "${out12}" | grep -q "dry-run"; then
  ok "C12 --dry-run writes nothing"
else
  bad "C12 --dry-run writes nothing" "${out12}"
fi
"${SETUP}" --install >/dev/null 2>&1

# --- C13: --remove takes out exactly the declared entries, backs them up, and
# leaves the undeclared one alone. Remove is the other half of the merge
# property: it must be as narrow as install.
out13="$("${SETUP}" --remove 2>&1)"
if [ ! -f "${PROJECTS}/demo.json" ] && [ -f "${PROJECTS}/stranger.json" ] && ls "${PROJECTS}"/demo.json.bak-* >/dev/null 2>&1; then
  ok "C13 --remove deletes only declared entries, backing them up"
else
  bad "C13 --remove deletes only declared entries, backing them up" "${out13}"
fi

# --- C14: environment-safety. On a machine that does not run this facility at
# all (no inbox root — a fresh checkout, a CI or agent environment with a
# different HOME), the check must PASS with a note. A check that false-fails
# there gets disabled, and then it is not protecting anything.
rm -rf "${ATHENA_INBOX_ROOT}"
out14="$("${CHECK}" 2>&1)"; rc14=$?
if [ ${rc14} -eq 0 ] && printf '%s' "${out14}" | grep -q "not this environment"; then
  ok "C14 no inbox root -> the check passes with a note"
else
  bad "C14 no inbox root -> the check passes with a note" "rc=${rc14}: ${out14}"
fi

# --- C15: but a root that EXISTS with no projects/ is real drift, not "not this
# environment". This is the boundary between the two, and getting it wrong in
# the safe direction turns the check into a permanent PASS.
mkdir -p "${ATHENA_INBOX_ROOT}"
"${CHECK}" >/dev/null 2>&1 && rc15=0 || rc15=1
if [ ${rc15} -eq 1 ]; then
  ok "C15 a root with no projects/ is drift, not 'not this environment'"
else
  bad "C15 a root with no projects/ is drift, not 'not this environment'" "check passed over a missing registry"
fi

# --- C16: a declared "~/..." repo is installed EXPANDED and absolute. The
# contract matches repo identity as an absolute realpath, so an entry that kept
# the tilde would match no session — zero channels, exit 0, silent.
reset_sandbox
"${SETUP}" --install >/dev/null 2>&1
repo_value="$(grep -o '"repo": "[^"]*"' "${PROJECTS}/demo.json")"
case "${repo_value}" in
  *"\"${HOME}/dev/demo/.git\""*) ok "C16 a ~-relative repo is installed as an absolute path" ;;
  *) bad "C16 a ~-relative repo is installed as an absolute path" "got ${repo_value}" ;;
esac

# --- C17: THE CWD-RELATIVE TRAP. `git rev-parse --git-common-dir` prints `.git`
# in a main checkout and an absolute path only inside a worktree. A resolver
# that returns the raw string, or resolves it after a chdir, yields a path that
# exists nowhere and matches no entry — zero channels, exit 0, and a dead
# channel nobody is told about. Resolution must happen at the point of capture.
mkdir -p "${TMP}/gitrepo"
( cd "${TMP}/gitrepo" && git init -q . ) >/dev/null 2>&1
# Run from a cwd that is NOT the repo and NOT the fixture: if resolution were
# deferred to the caller's cwd, `.git` would resolve here and the assertion
# below would catch it. RUBY_BIN is resolved outside the sandbox because a
# version-manager shim needs a .tool-versions it will not find in $TMP.
resolved="$(cd "${TMP}" && "${RUBY_BIN}" -r "${REPO}/ai/inbox/lib/registry" -e 'print InboxRegistry.git_common_dir(ARGV[0])' "${TMP}/gitrepo")"
if [ "${resolved}" = "$(cd "${TMP}/gitrepo" && realpath .git)" ]; then
  ok "C17 a main checkout's common dir resolves absolute, at the point of capture"
else
  bad "C17 a main checkout's common dir resolves absolute, at the point of capture" "got '${resolved}'"
fi

# --- C18: a declared repo that disagrees with git ON THIS MACHINE is drift.
# A worktree path declared as a repo identity is the realistic version of this
# mistake: every worktree resolves to its PARENT's common dir, so such an entry
# would never match the session it was written for.
mkdir -p "${TMP}/gitrepo/wt"
( cd "${TMP}/gitrepo" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git worktree add -q "${TMP}/gitwt" -b wt ) >/dev/null 2>&1
if [ -d "${TMP}/gitwt" ]; then
  python3 - "${ATHENA_INBOX_REGISTRY}" "${TMP}/gitwt/.git" <<'PY'
import json, sys
p, repo = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["projects"][0]["entry"]["repo"] = repo
json.dump(d, open(p, "w"), indent=2)
PY
  out18="$("${CHECK}" 2>&1)"; rc18=$?
  if [ ${rc18} -ne 0 ] && printf '%s' "${out18}" | grep -q "resolves to"; then
    ok "C18 a declared repo git disagrees with is drift"
  else
    bad "C18 a declared repo git disagrees with is drift" "rc=${rc18}: ${out18}"
  fi
else
  bad "C18 a declared repo git disagrees with is drift" "could not create a git worktree fixture"
fi

# --- C19: an entry the athena:inbox reader would REFUSE is never installed.
# An entry that the installer accepts and the reader rejects is a channel that
# is configured, installed, and dark — exactly the silence this tooling closes.
reset_sandbox
python3 - "${ATHENA_INBOX_REGISTRY}" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["projects"][0]["entry"]["channels"]["slack"]["paths"] = "typo.jsonl"
json.dump(d, open(p, "w"), indent=2)
PY
out19="$("${SETUP}" --install 2>&1)"; rc19=$?
if ! command -v jq >/dev/null 2>&1; then
  skip "C19 an entry the reader refuses is not installed" \
       "jq is absent, so the athena:inbox validator cannot run here"
elif [ ${rc19} -ne 0 ] && [ ! -f "${PROJECTS}/demo.json" ] && printf '%s' "${out19}" | grep -q "Fix:"; then
  ok "C19 an entry the reader refuses is not installed"
else
  bad "C19 an entry the reader refuses is not installed" "rc=${rc19}: ${out19}"
fi

# --- C20: an unknown flag is a usage error carrying a Fix: line, not a silent
# fallback to --install. Falling back would let a typo'd flag write the registry.
#
# The sandbox is reset first so the source of truth is VALID here: run against
# the invalid fixture above, this case would pass on that refusal instead and
# stay green while a typo'd flag silently installed (measured).
reset_sandbox
out20="$("${SETUP}" --instal 2>&1)"; rc20=$?
if [ ${rc20} -ne 0 ] && [ ! -f "${PROJECTS}/demo.json" ] && printf '%s' "${out20}" | grep -q "Fix:"; then
  ok "C20 an unknown flag is refused with a Fix: line"
else
  bad "C20 an unknown flag is refused with a Fix: line" "rc=${rc20}: ${out20}"
fi

# --- C21: a malformed committed source of truth is a distinct exit code (2) and
# names the file. It is a code error, not a machine-state question, and must not
# read as ordinary drift.
printf '%s' '{ not json' > "${ATHENA_INBOX_REGISTRY}"
out21="$("${CHECK}" 2>&1)"; rc21=$?
if [ ${rc21} -eq 2 ] && printf '%s' "${out21}" | grep -q "Fix:"; then
  ok "C21 a malformed source of truth exits 2 with a Fix: line"
else
  bad "C21 a malformed source of truth exits 2 with a Fix: line" "rc=${rc21}: ${out21}"
fi

# --- C22: the committed registry.json this repo actually ships is valid and
# would install. A fixture-only suite would pass happily over a broken real one.
unset ATHENA_INBOX_REGISTRY
reset_root="${TMP}/realcheck"
if ATHENA_INBOX_ROOT="${reset_root}" "${SETUP}" --install --dry-run >/dev/null 2>&1; then
  ok "C22 the committed ai/inbox/registry.json is valid and installable"
else
  bad "C22 the committed ai/inbox/registry.json is valid and installable" \
      "$(ATHENA_INBOX_ROOT="${reset_root}" "${SETUP}" --install --dry-run 2>&1)"
fi

# --- C23: the committed source of truth carries NO credential. It is the one
# inbox artifact that is in git and readable by anything that can read the repo;
# the machine token lives at ~/.config/athena-inbox-client/config.json and
# nowhere else (contract: "No credential ever appears inside the root", and the
# committed list is the same promise one level up).
if grep -Eq 'xox[abpsr]-|"(token|secret|password|api_key)"' "${REPO}/ai/inbox/registry.json"; then
  bad "C23 the committed registry carries no credential" \
      "$(grep -En 'xox[abpsr]-|"(token|secret|password|api_key)"' "${REPO}/ai/inbox/registry.json")"
else
  ok "C23 the committed registry carries no credential"
fi

# --- C24: a backup the installer leaves behind must not look like a registry
# entry. A backup named so that it parses as a candidate would be loaded by a
# reader looking for this session's entry — and a stale copy of an entry is
# exactly the cross-wiring the tenancy rules exist to prevent.
export ATHENA_INBOX_REGISTRY="${TMP}/registry.json"   # C22 unset it
reset_sandbox
"${SETUP}" --install >/dev/null 2>&1
printf '%s\n' '{"v":1,"repo":"/wrong/.git","channels":{}}' > "${PROJECTS}/demo.json"
"${SETUP}" --install >/dev/null 2>&1
strays="$(cd "${PROJECTS}" && ls | grep -v '^demo\.json$' | grep -E '^[a-z0-9][a-z0-9_-]*\.json$')"
if [ -z "${strays}" ]; then
  ok "C24 an installer backup does not match the registry filename grammar"
else
  bad "C24 an installer backup does not match the registry filename grammar" "candidate-looking: ${strays}"
fi

echo
if [ "${FAIL}" -eq 0 ]; then
  suffix=""; [ "${SKIP}" -gt 0 ] && suffix=", ${SKIP} skipped"
  echo "VERDICT: PASS (${PASS} cases${suffix})"
  exit 0
fi
echo "VERDICT: FAIL (${FAIL} failed, ${PASS} passed)"
echo "Fix: read each FAIL above — it names the property that broke. The installer is" \
     "scripts/setup-inbox-registry, the check is ai/bin/check-inbox-registry, and the" \
     "shared render/compare rules are ai/inbox/lib/registry.rb. Do not commit while this is red."
exit 1
