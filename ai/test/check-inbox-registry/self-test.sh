#!/usr/bin/env bash
# Black-box suite for ai/bin/check-inbox-registry's landed bar (DND-792, folded
# into DND-743) -- discovered and run by harness-gate.
#
# The defect this pins: the check read the BRANCH's ai/inbox/registry.json as
# the list of entries this machine's live registry must hold. So:
#   - a branch that ADDS an entry or a channel failed the gate until the live
#     registry was provisioned with it. Machine state became a precondition of
#     reviewing code, and the only route to green was installing an entry that
#     had not landed;
#   - a branch that REMOVES or edits a landed entry lowered its own bar, so real
#     drift on main passed. See ~/dev/custom/CLAUDE.md -> "A check's own bar
#     must not live in the diff it is checking".
# The fix reads the required entries from what LANDED on origin
# (ai/lib/landed.rb), names a branch-only change as pending (non-failing), and
# reports an unreadable bar as could-not-measure (exit 3).
#
# Every case builds a throwaway repo holding the checker under test (with
# ai/inbox/lib/registry.rb, ai/lib/landed.rb, scripts/setup-inbox-registry and
# the athena:inbox validator libs), lands it on a local bare origin, installs
# the live registry from the MAIN checkout (as the owner does), and runs the
# checker from a LINKED WORKTREE on a feature branch -- the shape a captain runs
# the gate in. The checker resolves its repo from its own location, so it
# measures the fixture, never the live tree or the live registry
# (ATHENA_INBOX_ROOT always points into the fixture, HOME is faked). Black-box,
# so it runs unchanged against the pre-fix checker; that is how the fail-first
# evidence was recorded:
#
#   CHECK_INBOX_REGISTRY_UNDER_TEST=/path/to/old/ai/bin/check-inbox-registry \
#     ai/test/check-inbox-registry/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
BIN="${CHECK_INBOX_REGISTRY_UNDER_TEST:-${AI_DIR}/bin/check-inbox-registry}"
SRC_ROOT="$(cd "$(dirname "${BIN}")/../.." && pwd)"
SOURCES=(ai/bin/check-inbox-registry ai/inbox/lib/registry.rb ai/lib/landed.rb scripts/setup-inbox-registry
         "ai/skills/athena:inbox/lib/err.sh" "ai/skills/athena:inbox/lib/names.sh"
         "ai/skills/athena:inbox/lib/descriptor.sh")

for f in "${SOURCES[@]}"; do
  if [ ! -f "${SRC_ROOT}/${f}" ]; then
    echo "check-inbox-registry self-test: FAIL -- ${SRC_ROOT}/${f} does not exist" >&2
    echo "Fix: point CHECK_INBOX_REGISTRY_UNDER_TEST at a checker inside a checkout that also has ${SOURCES[*]:1}." >&2
    exit 1
  fi
done

# A version manager's shim resolves its installs through $HOME, so pin it at the
# real home before HOME is faked (the same reason as ai/inbox/test/self-test.sh).
export ASDF_DATA_DIR="${ASDF_DATA_DIR:-${HOME}/.asdf}"
export ASDF_DIR="${ASDF_DIR:-${HOME}/.asdf}"
RUBY_BIN="$( (cd "${SRC_ROOT}" && asdf which ruby) 2>/dev/null || command -v ruby)"

TMP="$(mktemp -d)"; TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export HOME="${TMP}/home"; mkdir -p "${HOME}"
unset ATHENA_INBOX_REGISTRY
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"
export GIT_TERMINAL_PROMPT=0
GITC=(-c user.name=fixture -c user.email=fixture@example.invalid -c init.defaultBranch=main)

commit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" "${GITC[@]}" commit -q --allow-empty -m "$2" >/dev/null 2>&1; }

# registry <root> <file>=<repo>=<channel>[,<channel>...] ...
# One log channel per name, path "<file-stem>-<channel>.jsonl". A repo of "-"
# means "~/dev/<file-stem>/.git", which the faked HOME keeps pointing at nothing.
registry() {
  local root="$1"; shift
  mkdir -p "${root}/ai/inbox"
  "${RUBY_BIN}" -rjson -e '
    projects = ARGV.drop(1).map do |spec|
      file, repo, chans = spec.split("=", 3)
      stem = file.delete_suffix(".json")
      repo = "~/dev/#{stem}/.git" if repo == "-"
      channels = chans.to_s.split(",").to_h do |c|
        [c, { "kind" => "log", "path" => "#{stem}-#{c}.jsonl", "dedupe" => ["event_id"], "schema_v" => [1] }]
      end
      { "file" => file, "entry" => { "v" => 1, "repo" => repo, "channels" => channels } }
    end
    File.write(ARGV[0], JSON.pretty_generate({ "v" => 1, "projects" => projects }) + "\n")
  ' "${root}/ai/inbox/registry.json" "$@"
}

# new_fixture <name> [registry spec...]: main checkout with the registry landed
# on origin main (default: demo.json with one `slack` channel), the live
# registry installed from the main checkout, and a linked worktree on `feature`.
# Prints the fixture dir: main <dir>/main, worktree <dir>/wt, origin
# <dir>/origin.git, live root <dir>/root.
new_fixture() {
  local d="${TMP}/$1" f; shift
  mkdir -p "${d}"
  git init -q --bare "${d}/origin.git"
  git "${GITC[@]}" init -q "${d}/main"
  for f in "${SOURCES[@]}"; do
    mkdir -p "$(dirname "${d}/main/${f}")"
    cp -p "${SRC_ROOT}/${f}" "${d}/main/${f}"
  done
  if [ "$#" -eq 0 ]; then set -- "demo.json=-=slack"; fi
  registry "${d}/main" "$@"
  commit "${d}/main" landed
  git -C "${d}/main" remote add origin "${d}/origin.git"
  git -C "${d}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "${d}/main" fetch -q origin >/dev/null 2>&1
  git -C "${d}/main" worktree add -q -b feature "${d}/wt" >/dev/null 2>&1
  install_live "${d}"
  printf '%s\n' "${d}"
}

# install_live <dir>: the owner installs the live registry from the MAIN checkout.
install_live() {
  ATHENA_INBOX_ROOT="$1/root" XDG_STATE_HOME="$1/state" "$1/main/scripts/setup-inbox-registry" --install >/dev/null 2>&1
}

# land_branch <dir>: the owner lands the feature branch on main and fast-forwards
# the main checkout to it.
land_branch() {
  git -C "$1/wt" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "$1/main" "${GITC[@]}" merge -q --ff-only feature >/dev/null 2>&1
  git -C "$1/main" fetch -q origin >/dev/null 2>&1
}

OUT=""; RC=0
check() { # check <dir>: run the worktree's checker against the fixture's live root
  OUT="$(cd "$1/wt" && ATHENA_INBOX_ROOT="$1/root" "$1/wt/ai/bin/check-inbox-registry" 2>&1)"; RC=$?
}

expect() { # expect <label> <rc> [grep-pattern] [absent-pattern]
  local label="$1" want="$2" pat="${3:-}" absent="${4:-}"
  if [ "${RC}" -ne "${want}" ]; then bad "${label}" "exit ${RC}, want ${want}; output: ${OUT}"; return; fi
  if [ -n "${pat}" ] && ! grep -qiE -- "${pat}" <<<"${OUT}"; then bad "${label}" "output lacks /${pat}/: ${OUT}"; return; fi
  if [ -n "${absent}" ] && grep -qiE -- "${absent}" <<<"${OUT}"; then bad "${label}" "output has /${absent}/: ${OUT}"; return; fi
  ok "${label}"
}

echo "check-inbox-registry landed-bar suite (checker: ${BIN})"

# 1. Baseline: the landed entry is installed, the branch changes nothing.
D="$(new_fixture baseline)"
check "${D}"; expect "landed entry installed, branch unchanged -> pass" 0

# 2. THE DEFECT: a branch-added entry needs no live provisioning.
D="$(new_fixture branch-adds-entry)"
registry "${D}/wt" "demo.json=-=slack" "peer.json=-=slack"; commit "${D}/wt" add-peer
check "${D}"; expect "branch-added entry, not installed -> pass, named as pending" 0 "peer\.json: a new entry"

# 3. A branch-added channel on a landed entry is pending too, not drift.
D="$(new_fixture branch-adds-channel)"
registry "${D}/wt" "demo.json=-=slack,extra"; commit "${D}/wt" add-extra
check "${D}"; expect "branch-added channel, not installed -> pass, named as pending" 0 "extra"

# 4. After the branch lands, the (formerly branch-added) entry must be installed.
D="$(new_fixture lands)"
registry "${D}/wt" "demo.json=-=slack" "peer.json=-=slack"; commit "${D}/wt" add-peer
land_branch "${D}"
check "${D}"; expect "entry landed but not installed -> FAIL (drift as today)" 1 "peer\.json"

# 5. A branch that REMOVES a landed entry cannot lower the bar.
D="$(new_fixture branch-removes)"
registry "${D}/wt"; commit "${D}/wt" remove-demo
rm -f "${D}/root/projects/demo.json"
check "${D}"; expect "landed entry removed on the branch, and deleted live -> still FAIL" 1 "demo\.json"

# 6. A branch that EDITS a landed entry: the live entry is judged against the
#    landed text, and the branch's version is pending.
D="$(new_fixture branch-edits)"
registry "${D}/wt" "demo.json=-=other"; commit "${D}/wt" edit-demo
check "${D}"; expect "landed entry edited on the branch, live matches landed -> pass, named as pending" 0 "demo\.json"
ATHENA_INBOX_REGISTRY="${D}/wt/ai/inbox/registry.json" ATHENA_INBOX_ROOT="${D}/root" XDG_STATE_HOME="${D}/state" \
  "${D}/main/scripts/setup-inbox-registry" --install >/dev/null 2>&1
check "${D}"; expect "live entry provisioned from the branch, not landed -> FAIL (drift from landed)" 1 "demo\.json"

# 7. Could not measure is not a pass: origin unreachable.
D="$(new_fixture origin-unreachable)"
git -C "${D}/main" remote set-url origin "${D}/no-such-origin.git"
check "${D}"; expect "origin unreachable -> could not measure, exit 3" 3 "could not measure"
expect "...and the output says an offline machine, or one with no inbox, exits 3" 3 "offline machine, or one with no inbox.*could not measure"

# 8. Could not measure: the landed registry is malformed on origin main.
D="$(new_fixture landed-malformed)"
printf '{ not json\n' > "${D}/main/ai/inbox/registry.json"; commit "${D}/main" break
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
git -C "${D}/wt" "${GITC[@]}" rebase -q origin/main >/dev/null 2>&1
registry "${D}/wt" "demo.json=-=slack"; commit "${D}/wt" fix-on-branch
check "${D}"; expect "landed registry malformed -> could not measure, exit 3" 3 "could not measure"

# 9. The branch's own registry is malformed: a code error in the diff, exit 2.
D="$(new_fixture branch-malformed)"
printf '{ not json\n' > "${D}/wt/ai/inbox/registry.json"; commit "${D}/wt" break
check "${D}"; expect "branch registry malformed -> exit 2 with a Fix:" 2 "Fix:"

# 10. Not this environment: no inbox root and no landed repo checked out here.
D="$(new_fixture no-root)"
rm -rf "${D}/root"
check "${D}"; expect "no inbox root, no declared repo here -> pass" 0 "not this environment"

# 11. A branch cannot make this machine "not this environment" by deleting the
#     entry that proves it is: the landed entry's repo is checked out here.
D="$(new_fixture root-lost "fixture.json=$(cd "${TMP}" && pwd -P)/root-lost/main/.git=slack")"
registry "${D}/wt"; commit "${D}/wt" remove-fixture
rm -rf "${D}/root"
check "${D}"; expect "root lost, landed repo checked out here, branch deletes its entry -> FAIL" 1 "does not exist"

# 12. A local origin/main moved by hand is not the landed bar.
D="$(new_fixture forged-ref)"
registry "${D}/wt"; commit "${D}/wt" drop-all
git -C "${D}/wt" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1
rm -f "${D}/root/projects/demo.json"
check "${D}"; expect "local origin/main forged to the branch -> could not measure, exit 3" 3 "disagrees with origin"

# 13. The gate's pin (DND-735): origin main moves after the pin is taken. The
#     pinned run measures the pin; the unpinned run sees a stale local ref.
D="$(new_fixture pinned)"
PIN="$(git -C "${D}/main" rev-parse HEAD)"
KEY="$(cd "$(git -C "${D}/main" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
git clone -q -b main "${D}/origin.git" "${D}/other" >/dev/null 2>&1
commit "${D}/other" moved; git -C "${D}/other" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
OUT="$(cd "${D}/wt" && ATHENA_LANDED_PIN_SHA="${PIN}" ATHENA_LANDED_PIN_REPO="${KEY}" ATHENA_INBOX_ROOT="${D}/root" \
  "${D}/wt/ai/bin/check-inbox-registry" 2>&1)"; RC=$?
expect "origin moved after the gate pinned it -> pass against the pin" 0
OUT="$(cd "${D}/wt" && env -u ATHENA_LANDED_PIN_SHA -u ATHENA_LANDED_PIN_REPO ATHENA_INBOX_ROOT="${D}/root" \
  "${D}/wt/ai/bin/check-inbox-registry" 2>&1)"; RC=$?
expect "...and unpinned, the stale local origin/main -> could not measure, exit 3" 3 "disagrees with origin"

echo "check-inbox-registry landed-bar suite: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -eq 0 ]; then echo "ALL CASES PASS"; exit 0; fi
echo "SELF-TEST FAILED"; exit 1
