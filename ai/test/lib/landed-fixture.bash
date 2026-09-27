# shellcheck shell=bash
# landed-fixture.bash -- a throwaway repo whose origin/main IS a given tree.
#
# Source this from a suite that runs a check whose bar is what LANDED on origin
# (ai/lib/landed.rb: check-inbox-registry, check-hooks-registered) and asserts
# that the check agrees with an installer run from the same tree. Run against
# the real checkout, such a suite measures the branch's copy against the REAL
# origin/main's copy. So it goes red on any branch that edits the registry (the
# edit is pending until it lands, by design), and it reads the real origin over
# the network (exit 3 offline). That is the DND-792 defect, moved into a test
# (DND-743 critic, round 3).
#
# landed_fixture copies the named paths into a fresh repo and pushes them to a
# bare origin there as main. In the fixture, "what landed" is the tree under
# test, so the suite asserts what it always meant to (installer and check
# agree), with no network and no real origin. The landed-versus-branch cases
# live in the checks' own suites (ai/test/check-*-registered/self-test.sh),
# not here.
#
# The fixture's git runs with no global or system config, so the owner's hooks,
# signing and aliases stay out of it. A gate pin (ATHENA_LANDED_PIN_*) is keyed
# to the real repo's common dir, so the fixture's check does not apply it.

# landed_fixture <src-root> <dest> <path>...
#   <dest> must not exist. Each <path> (a file or a directory, relative to
#   <src-root>) is copied to the same path under <dest>. The bare origin is
#   <dest>.origin.git. Returns non-zero, with a message and a Fix: on stderr,
#   when any step fails, so a suite never runs its check in a half-built
#   fixture and reads the result as the check's.
landed_fixture() {
  local src="$1" dest="$2" p
  shift 2
  if [ -e "${dest}" ]; then
    printf 'landed_fixture: %s already exists\nFix: pass a fresh path under the suite'"'"'s mktemp -d.\n' "${dest}" >&2
    return 1
  fi
  mkdir -p "${dest}" || return 1
  for p in "$@"; do
    if [ ! -e "${src}/${p}" ]; then
      printf 'landed_fixture: %s does not exist in %s\nFix: name a path the checkout has, or restore it from git.\n' "${p}" "${src}" >&2
      return 1
    fi
    mkdir -p "$(dirname -- "${dest}/${p}")" || return 1
    cp -Rp -- "${src}/${p}" "${dest}/${p}" || return 1
  done
  _landed_fixture_git init -q --bare "${dest}.origin.git" \
    && _landed_fixture_git init -q "${dest}" \
    && _landed_fixture_git -C "${dest}" remote add origin "${dest}.origin.git" \
    && landed_fixture_land "${dest}" \
    || { printf 'landed_fixture: could not build the fixture repo at %s\nFix: check that git is installed and the suite'"'"'s temp dir is writable.\n' "${dest}" >&2; return 1; }
}

# landed_fixture_land <dest>
#   Commits whatever changed in <dest> and pushes it to the fixture origin as
#   main, then fetches, so origin/main and the local ref agree. Idempotent.
landed_fixture_land() {
  local dest="$1"
  _landed_fixture_git -C "${dest}" add -A \
    && { _landed_fixture_git -C "${dest}" diff --cached --quiet \
         || _landed_fixture_git -C "${dest}" -c user.name=fixture -c user.email=fixture@example.invalid \
              commit -q -m land; } \
    && _landed_fixture_git -C "${dest}" push -q origin HEAD:refs/heads/main \
    && _landed_fixture_git -C "${dest}" fetch -q origin
}

_landed_fixture_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 git "$@" >/dev/null 2>&1
}
