#!/usr/bin/env bash
# setup.sh -- provision the custom CI harness image (DND-1998).
#
# Usage: setup.sh            (as root, inside a Debian trixie container)
#        setup.sh --help
#
# The one definition of the tool set ai/bin/harness-gate needs in CI. Two
# callers run it, so they cannot drift apart:
#   - .gitlab-ci.yml's harness-gate job, at the start of every run;
#   - dockerfiles/ci-harness/Dockerfile, to build the same image locally.
# Both start from the same base image digest (ai/test/gitlab-ci asserts it).
#
# Every input is pinned, so two runs a month apart install the same bytes:
#   - apt reads ONE snapshot.debian.org timestamp (SNAPSHOT), never the moving
#     archive, and each named package is pinned to its exact version there. A
#     version the snapshot does not hold fails the install; it never floats.
#   - git is built from the kernel.org release tarball, checked against its
#     sha256 (GIT_SHA256). trixie ships git 2.47, which has no `git hook list`;
#     check-hooks-registered, agent-stash-guard and gh-athena need it.
#   - nothing is read from CI variables; no credential is used or needed.
#
# To bump: change SNAPSHOT, re-resolve each version with
# `apt-cache policy <pkg>` inside the snapshot, and update PACKAGES; for git,
# change GIT_VERSION and GIT_SHA256 from kernel.org's sha256sums.asc.
#
# It also creates the non-root `ci` user the gate runs as, with a git identity
# and `main` as the default branch (suites assert ownership and permission
# behavior that root bypasses).

set -euo pipefail
# Every step without its own message (the git build, the user setup, a
# symlink) still fails with the command, its line and a Fix:.
on_err() {
  echo "setup.sh: line $2: \`$3\` failed (exit $1)" >&2
  echo "  Fix: read the output above for its cause. For the git build: a GIT_VERSION bump may need another build dependency in PACKAGES. Re-run dockerfiles/ci-harness/Dockerfile's build locally to reproduce." >&2
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  # The header comment, from line 2 to the first line that is not a comment.
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
  exit 0
fi
if [ "$#" -ne 0 ]; then
  echo "setup.sh: unexpected argument: $1" >&2
  echo "  Fix: run setup.sh with no arguments (or --help)." >&2
  exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "setup.sh: must run as root (it installs packages and creates the ci user)" >&2
  echo "  Fix: run it as the container's root user, before switching to ci." >&2
  exit 1
fi

SNAPSHOT=20261003T000000Z
GIT_VERSION=2.54.0
GIT_SHA256=f689162364c10de79ef89aa8dbf48731eb057e34edbbd20aca510ce0154681a3

# Runtime tools the gate's suites call, then git's build dependencies.
PACKAGES=(
  jq=1.7.1-6+deb13u4
  python3=3.13.5-1
  procps=2:4.0.4-9
  ca-certificates=20250419
  curl=8.14.1-2+deb13u5
  gawk=1:5.2.1-2+b1
  bubblewrap=0.12.0-1~deb13u1
  util-linux=2.41.5-0+deb13u1
  gh=2.46.0-3
  nodejs=20.19.2+dfsg-1+deb13u3
  inotify-tools=4.23.9.0-2+b1
  openssh-client=1:10.0p1-7+deb13u4
  make=4.4.1-2
  gcc=4:14.2.0-1
  libc6-dev=2.41-12+deb13u4
  libcurl4-openssl-dev=8.14.1-2+deb13u5
  zlib1g-dev=1:1.3.dfsg+really1.3.1-1+b1
  libexpat1-dev=2.8.3-1~deb13u1
  xz-utils=5.8.1-1+deb13u1
)

# apt: the snapshot only. The base image's own sources point at the moving
# archive, so they are removed rather than added to.
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot.sources <<EOF
Types: deb
URIs: https://snapshot.debian.org/archive/debian/${SNAPSHOT}
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://snapshot.debian.org/archive/debian-security/${SNAPSHOT}
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
# A snapshot's Release file is past its Valid-Until by design; the signature
# is still checked.
APT=(apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=3)
if ! "${APT[@]}" update -qq; then
  echo "setup.sh: apt update from snapshot ${SNAPSHOT} failed" >&2
  echo "  Fix: check that https://snapshot.debian.org is reachable from the runner; retry the job. Never fall back to the moving archive." >&2
  exit 1
fi
if ! DEBIAN_FRONTEND=noninteractive "${APT[@]}" install -y -qq --no-install-recommends "${PACKAGES[@]}"; then
  echo "setup.sh: installing the pinned package set from snapshot ${SNAPSHOT} failed" >&2
  echo "  Fix: a pin above is not in the snapshot; re-resolve it with apt-cache policy inside the snapshot and update PACKAGES." >&2
  exit 1
fi

# git, from the release tarball, checked by sha256.
src="$(mktemp -d)"
if ! curl -fsSL --retry 3 -o "${src}/git.tar.xz" \
  "https://mirrors.edge.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz"; then
  echo "setup.sh: downloading git-${GIT_VERSION}.tar.xz from kernel.org failed" >&2
  echo "  Fix: check that https://mirrors.edge.kernel.org is reachable from the runner; retry the job." >&2
  exit 1
fi
if ! echo "${GIT_SHA256}  ${src}/git.tar.xz" | sha256sum -c --quiet -; then
  echo "setup.sh: git-${GIT_VERSION}.tar.xz does not match GIT_SHA256" >&2
  echo "  Fix: take the checksum from kernel.org's signed sha256sums.asc; never install an unchecked tarball." >&2
  exit 1
fi
tar -xJf "${src}/git.tar.xz" -C "${src}"
# prefix=/usr, as on the owner's machine: suites and the tool-sandbox call
# /usr/bin/git by path, and agent-bin-git's fallback-layout cases assume no git
# in /usr/local/bin. apt installs no git (asserted below), so nothing collides.
# contrib/subtree is installed too: Debian's git ships `git subtree`, and the
# forge-identity suites refuse and pass `git subtree push` / `split` for real.
build=(-s -j"$(nproc)" prefix=/usr NO_TCLTK=1 NO_GETTEXT=1 NO_PERL=1 NO_PYTHON=1)
if grep -q 'install ok installed' <<<"$(dpkg-query -W -f='${Status}' git 2>/dev/null || true)"; then
  echo "setup.sh: apt installed Debian's git, which the source build would overwrite" >&2
  echo "  Fix: find the package in PACKAGES that depends on git and drop it, or pin a release that does not." >&2
  exit 1
fi
make -C "${src}/git-${GIT_VERSION}" "${build[@]}" all install
make -C "${src}/git-${GIT_VERSION}/contrib/subtree" "${build[@]}" install
rm -rf "${src}"
# `git hook -h` exits 129 by design, so read its usage text, not its status.
hook_usage="$(git hook -h 2>&1 || true)"
[[ "${hook_usage}" == *"git hook list"* ]] || {
  echo "setup.sh: the installed git has no \`git hook list\`" >&2
  echo "  Fix: set GIT_VERSION to a release whose \`git hook -h\` lists \`git hook list\` (2.54.0 does)." >&2
  exit 1
}
[ -x "$(git --exec-path)/git-subtree" ] || {
  echo "setup.sh: the installed git has no git-subtree" >&2
  echo "  Fix: keep the contrib/subtree install step after the git build." >&2
  exit 1
}

# Harness Ruby executables carry the absolute #!/usr/bin/ruby shebang.
ln -sf "$(command -v ruby)" /usr/bin/ruby

# The non-root user the gate runs as.
id ci >/dev/null 2>&1 || useradd --create-home --shell /bin/bash ci
runuser -u ci -- env HOME=/home/ci git config --global user.name ci
runuser -u ci -- env HOME=/home/ci git config --global user.email ci@localhost
runuser -u ci -- env HOME=/home/ci git config --global init.defaultBranch main

echo "setup.sh: OK -- snapshot ${SNAPSHOT}, $(git --version), $(ruby -e 'print RUBY_VERSION')"
