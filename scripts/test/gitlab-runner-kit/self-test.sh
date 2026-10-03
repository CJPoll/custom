#!/usr/bin/env bash
# Discovered self-test for the GitLab runner kit (DND-1937): N named runner
# users per host. Covers scripts/lib/gitlab-runner-kit.sh (the pure rules) and
# scripts/setup-gitlab-runner{-user,-docker,} end to end.
#
# Hermetic and functional (DND-1222). The setup scripts run as root on a real
# host; here they run against a temp root (ATHENA_RUNNER_KIT_ROOT) with fixture
# /etc/passwd, /etc/subuid and /etc/subgid, and with PATH holding ONLY:
#   * stubs for the commands that would change the host (useradd, chown,
#     loginctl, emerge, rc-update, rc-service, curl) or read it (id, getent);
#   * logging shims for every real tool the scripts use (awk, mkdir, ...).
# Every external command a script runs therefore lands in one argv log, which
# the token cases search. Nothing here needs root or touches the real /etc.
#
# SYNTHETIC VALUES ONLY. Runner users are gitlab-runner-alpha/-bravo/-charlie;
# tokens are assembled at runtime so this public file holds no token literal.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$(cd "${HERE}/../../.." && pwd -P)"
LIB="${SRC}/scripts/lib/gitlab-runner-kit.sh"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "${@:2}"; FAIL=$((FAIL+1)); }
check() { # <label> <command...>: passes when the command exits 0
  local label="$1"; shift
  if "$@"; then ok "${label}"; else bad "${label}"; fi
}

# Synthetic tokens. "glrt" and "-" are joined at runtime.
P_RT="glrt""-"
TOK_A="${P_RT}SYNTHaaaaaaaaaaaaaaaaaaaaaa1"
TOK_B="${P_RT}SYNTHbbbbbbbbbbbbbbbbbbbbbb2"
TOK_C="${P_RT}SYNTHcccccccccccccccccccccc3"
NOT_TOK="plainSYNTHdddddddddddddddddddd4"
ALL_TOK=("${TOK_A}" "${TOK_B}" "${TOK_C}" "${NOT_TOK}")
TRANSCRIPT="${TMP}/transcript"; : > "${TRANSCRIPT}"

echo "gitlab-runner-kit self-test (repo: ${SRC})"

# =========================================================== 1. the pure rules
# shellcheck source=../../lib/gitlab-runner-kit.sh
. "${LIB}"

check "lib: the default user is valid" grk_validate_user gitlab-runner
check "lib: gitlab-runner-<suffix> is valid" grk_validate_user gitlab-runner-alpha
for badname in root gitlab-runner- gitlab-runnerx gitlab-runner-Alpha "gitlab-runner-a b" gitlab-runner--x \
               gitlab-runner-abcdefghijklmnopqrstuvwxyz; do
  err="$(grk_validate_user "${badname}" 2>&1)" && bad "lib: user '${badname}' refused" "accepted"
  case "${err}" in *Fix:*) ok "lib: user '${badname}' refused with Fix:" ;; *) bad "lib: user '${badname}' refused with Fix:" "${err}" ;; esac
done

eq() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi
}
eq "lib: default runner service is unchanged" "$(grk_runner_service gitlab-runner)" "gitlab-runner"
eq "lib: default docker service is unchanged" "$(grk_docker_service gitlab-runner)" "docker-rootless-gitlab-runner"
eq "lib: a named user's runner service is an OpenRC instance" "$(grk_runner_service gitlab-runner-alpha)" "gitlab-runner.alpha"
eq "lib: a named user's docker service is an OpenRC instance" "$(grk_docker_service gitlab-runner-alpha)" "docker-rootless-gitlab-runner.alpha"
eq "lib: the default user keeps subid start 296608" "$(grk_subid_start gitlab-runner)" "296608"
eq "lib: the CI dir is /srv/ci/<user>" "$(grk_ci_dir gitlab-runner-alpha)" "/srv/ci/gitlab-runner-alpha"

A_START="$(grk_subid_start gitlab-runner-alpha)"
B_START="$(grk_subid_start gitlab-runner-bravo)"
C_START="$(grk_subid_start gitlab-runner-charlie)"
eq "lib: the subid start is deterministic" "$(grk_subid_start gitlab-runner-alpha)" "${A_START}"
disjoint() { # <start1> <start2>: two 65536 blocks do not overlap
  [ $(( $1 + 65536 )) -le "$2" ] || [ $(( $2 + 65536 )) -le "$1" ]
}
check "lib: two named users get disjoint blocks" disjoint "${A_START}" "${B_START}"
check "lib: a named user's block is disjoint from the default's" disjoint "${A_START}" 296608
inregion() { [ "$1" -ge 1000000000 ] && [ $(( ($1 - 1000000000) % 65536 )) -eq 0 ] && [ $(( $1 + 65536 )) -le 1268435456 ]; }
check "lib: a named user's block is a 65536-aligned slot of the region" inregion "${A_START}"

SUBFX="${TMP}/subuid.fixture"
printf 'athena:165536:65536\ngithub-runner:231072:65536\ngitlab-runner:296608:65536\n\n# comment\n' > "${SUBFX}"
check "lib: no conflict for the default user (its own line is skipped)" grk_subid_conflicts "${SUBFX}" gitlab-runner 296608 65536
check "lib: no conflict for a named user's block" grk_subid_conflicts "${SUBFX}" gitlab-runner-alpha "${A_START}" 65536
check "lib: a missing subid file has no conflicts" grk_subid_conflicts "${TMP}/no-such-file" gitlab-runner-alpha "${A_START}" 65536
printf 'intruder:%s:10\n' "$(( A_START + 65535 ))" >> "${SUBFX}"
out="$(grk_subid_conflicts "${SUBFX}" gitlab-runner-alpha "${A_START}" 65536)"; rc=$?
eq "lib: an overlap on the block's last id is exit 1" "${rc}" "1"
eq "lib: the overlapping line is printed" "${out}" "intruder:$(( A_START + 65535 )):10"
printf 'edge:%s:65536\n' "$(( A_START + 65536 ))" > "${TMP}/edge"
check "lib: a block starting right after is not an overlap" grk_subid_conflicts "${TMP}/edge" gitlab-runner-alpha "${A_START}" 65536
printf 'athena:165536:65536\nbroken-line\n' > "${TMP}/malformed"
err="$(grk_subid_conflicts "${TMP}/malformed" gitlab-runner-alpha "${A_START}" 65536 2>&1)"; rc=$?
eq "lib: a malformed subid line is exit 2, never 'no conflict'" "${rc}" "2"
case "${err}" in *"line 2"*Fix:*) ok "lib: the malformed line is named, with Fix:" ;; *) bad "lib: the malformed line is named, with Fix:" "${err}" ;; esac
check "lib: --subid-start accepts a block start" grk_validate_subid_start 1073741824
err="$(grk_validate_subid_start 12x 2>&1)" && bad "lib: --subid-start 12x refused" || \
  case "${err}" in *Fix:*) ok "lib: --subid-start 12x refused with Fix:" ;; *) bad "lib: --subid-start 12x refused with Fix:" "${err}" ;; esac

eq "lib: --runner NAME:TAG defaults its limit to 1" "$(grk_parse_runner alpha-ci:ci)" "alpha-ci ci 1"
eq "lib: --runner NAME:TAG:LIMIT" "$(grk_parse_runner alpha-deploy:deploy:2)" "alpha-deploy deploy 2"
for badspec in alpha-ci "alpha-ci:" "Alpha:ci" "alpha-ci:ci,deploy" "alpha-ci:ci:0" "alpha-ci:ci:x"; do
  err="$(grk_parse_runner "${badspec}" 2>&1)" && bad "lib: --runner '${badspec}' refused" "accepted"
  case "${err}" in *Fix:*) ok "lib: --runner '${badspec}' refused with Fix:" ;; *) bad "lib: --runner '${badspec}' refused with Fix:" "${err}" ;; esac
done
check "lib: a glrt- token shape is accepted" grk_valid_token "${TOK_A}"
if grk_valid_token "${NOT_TOK}" || grk_valid_token "${P_RT}short" || grk_valid_token "${TOK_A} x"; then
  bad "lib: a non-glrt, short, or spaced token is refused"
else ok "lib: a non-glrt, short, or spaced token is refused"; fi
check "lib: https://gitlab.com is a valid url" grk_valid_url https://gitlab.com
if grk_valid_url http://gitlab.com || grk_valid_url https://u:p@gitlab.com || grk_valid_url https://gitlab.com/x; then
  bad "lib: http, credentialed and pathed urls are refused"
else ok "lib: http, credentialed and pathed urls are refused"; fi

render="$(grk_render_runner alpha-ci ci 1 https://gitlab.com /srv/ci/gitlab-runner-alpha "${TOK_A}")"
for want in '[[runners]]' 'name = "alpha-ci"' 'tags = ["ci"], run_untagged = false' 'limit = 1' \
            'privileged = false' 'volumes = ["/srv/ci/gitlab-runner-alpha/cache:/cache"]' "token = \"${TOK_A}\""; do
  case "${render}" in *"${want}"*) ok "lib: a rendered entry has ${want%% =*}" ;; *) bad "lib: a rendered entry has ${want%% =*}" "${render}" ;; esac
done
printf '%s\n' "${render}" > "${TMP}/cfg"
check "lib: config_has_runner finds a rendered entry" grk_config_has_runner "${TMP}/cfg" alpha-ci
if grk_config_has_runner "${TMP}/cfg" alpha; then bad "lib: config_has_runner matches whole names only"; else ok "lib: config_has_runner matches whole names only"; fi

# =========================================================== 2. the scripts
ROOT="${TMP}/root"
STUBS="${TMP}/stubs"
SHIMS="${TMP}/shims"
ARGV_LOG="${TMP}/argv.log"
mkdir -p "${ROOT}/etc/portage" "${ROOT}/etc/init.d" "${ROOT}/etc/conf.d" "${ROOT}/home" "${ROOT}/srv" "${ROOT}/usr/local/bin" "${ROOT}/fake-groups" "${STUBS}" "${SHIMS}"
: > "${ARGV_LOG}"
printf 'root:x:0:0::/root:/bin/bash\nathena:x:1001:1001::/home/athena:/bin/bash\n' > "${ROOT}/etc/passwd"
printf 'athena:165536:65536\ngithub-runner:231072:65536\n' > "${ROOT}/etc/subuid"
cp "${ROOT}/etc/subuid" "${ROOT}/etc/subgid"
# The binary already exists, so no download path runs.
printf '#!/bin/sh\necho "Version: 0.0.0-selftest"\n' > "${ROOT}/usr/local/bin/gitlab-runner"
chmod 755 "${ROOT}/usr/local/bin/gitlab-runner"

# Logging shims: each real tool logs its argv, then runs.
for tool in awk cksum mkdir chmod mv mktemp cat grep ln rm cut head tr sed dirname basename tail wc sort env cp stat touch sha256sum; do
  real="$(command -v "${tool}")" || { echo "FAIL: ${tool} not on PATH"; exit 1; }
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nexec "%s" "$@"\n' "${tool}" "${ARGV_LOG}" "${real}" > "${SHIMS}/${tool}"
  chmod 755 "${SHIMS}/${tool}"
done
REAL_INSTALL="$(command -v install)"
REAL_BASH="$(command -v bash)"
stub() { # <name> <body>: a stub that logs its argv, then runs body
  printf '#!%s\nprintf "%%s\\n" "%s $*" >> "%s"\nROOT="%s"\n%s\n' "${REAL_BASH}" "$1" "${ARGV_LOG}" "${ROOT}" "$2" > "${STUBS}/$1"
  chmod 755 "${STUBS}/$1"
}
stub id '
if [ "$1" = "-u" ] && [ $# -eq 1 ]; then echo 0; exit 0; fi
if [ "$1" = "-u" ]; then awk -F: -v u="$2" '"'"'$1==u{print $3; f=1} END{exit !f}'"'"' "${ROOT}/etc/passwd"; exit; fi
if [ "$1" = "-nG" ]; then
  if [ -f "${ROOT}/fake-groups/$2" ]; then cat "${ROOT}/fake-groups/$2"; else echo "$2"; fi; exit 0
fi
exit 1'
stub getent '
[ "$1" = passwd ] || exit 2
grep "^$2:" "${ROOT}/etc/passwd" || exit 2'
stub useradd '
home=""; name=""
while [ $# -gt 0 ]; do case "$1" in -d) home="$2"; shift ;; -s) shift ;; -m) ;; *) name="$1" ;; esac; shift; done
uid=$(( 2000 + $(wc -l < "${ROOT}/etc/passwd") ))
printf "%s:x:%s:%s::%s:/bin/bash\n" "${name}" "${uid}" "${uid}" "${home}" >> "${ROOT}/etc/passwd"
mkdir -p "${ROOT}${home}"; chmod 0755 "${ROOT}${home}"'
stub install "
args=()
while [ \$# -gt 0 ]; do case \"\$1\" in -o|-g) shift ;; *) args+=(\"\$1\") ;; esac; shift; done
exec ${REAL_INSTALL} \"\${args[@]}\""
stub chown ':'
stub loginctl 'case "$1" in show-user) echo "Linger=no" ;; esac'
stub emerge ':'
stub rc-update ':'
stub rc-service 'case "$2" in status) exit 3 ;; esac'
stub curl 'exit 1'
for t in rootlesskit slirp4netns fuse-overlayfs; do stub "${t}" ':'; done

KIT_PATH="${STUBS}:${SHIMS}"
# kit <script> [args...] <stdin-file>: run one setup script in the temp root.
# Sets OUT (stdout), ERR (stderr) and RC.
kit() {
  local script="$1"; shift
  local stdin_file="${!#}"
  local args=("${@:1:$(($# - 1))}")
  env -i PATH="${KIT_PATH}" HOME="${TMP}" LANG=C ATHENA_RUNNER_KIT_ROOT="${ROOT}" \
    "${REAL_BASH}" "${SRC}/scripts/${script}" "${args[@]+"${args[@]}"}" \
    <"${stdin_file}" >"${TMP}/out" 2>"${TMP}/err"; RC=$?
  OUT="$(<"${TMP}/out")"; ERR="$(<"${TMP}/err")"
  { printf '%s\n' "--- ${script}"; cat "${TMP}/out" "${TMP}/err"; } >> "${TRANSCRIPT}"
}
NOIN="${TMP}/empty-stdin"; : > "${NOIN}"
expect_rc() { # <label> <want-rc>
  if [ "${RC}" = "$2" ]; then ok "$1"; else bad "$1" "exit ${RC}, want $2" "stdout: ${OUT}" "stderr: ${ERR}"; fi
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || echo missing; }
snapshot() { (cd "${ROOT}" && find . -printf '%p %m %s %l\n' | sort) ; }

# --- --help: stdout, exit 0, does nothing ------------------------------------
for s in setup-gitlab-runner-user setup-gitlab-runner-docker setup-gitlab-runner; do
  before="$(snapshot)"; : > "${ARGV_LOG}"
  kit "${s}" --help "${NOIN}"
  expect_rc "${s} --help exits 0" 0
  case "${OUT}" in *"--user <name>"*) ok "${s} --help is on stdout and names --user" ;; *) bad "${s} --help is on stdout and names --user" "${OUT}" ;; esac
  eq "${s} --help writes nothing to stderr" "${ERR}" ""
  eq "${s} --help changes no file" "$(snapshot)" "${before}"
  if grep -vE '^(awk|dirname) ' "${ARGV_LOG}" | grep -q .; then bad "${s} --help runs no host command" "$(cat "${ARGV_LOG}")"
  else ok "${s} --help runs no host command"; fi
done

# --- a bad --user is refused before anything changes -------------------------
before="$(snapshot)"
kit setup-gitlab-runner-user --user evil "${NOIN}"
expect_rc "setup-gitlab-runner-user --user evil is refused" 1
case "${ERR}" in *Fix:*) ok "a bad --user carries Fix:" ;; *) bad "a bad --user carries Fix:" "${ERR}" ;; esac
eq "a refused --user changes no file" "$(snapshot)" "${before}"

# --- user alpha: user, home, CI dirs -----------------------------------------
kit setup-gitlab-runner-user --user gitlab-runner-alpha "${NOIN}"
expect_rc "user alpha: setup-gitlab-runner-user succeeds" 0
check "user alpha: passwd entry created" grep -q '^gitlab-runner-alpha:' "${ROOT}/etc/passwd"
eq "user alpha: home is 0700" "$(mode_of "${ROOT}/home/gitlab-runner-alpha")" "700"
for d in "" /docker /cache; do
  eq "user alpha: /srv/ci/gitlab-runner-alpha${d} is 0700" "$(mode_of "${ROOT}/srv/ci/gitlab-runner-alpha${d}")" "700"
done
check "user alpha: the CI dirs are created owned by the user" \
  grep -q "^install -d -m 0700 -o gitlab-runner-alpha -g gitlab-runner-alpha ${ROOT}/srv/ci/gitlab-runner-alpha/cache\$" "${ARGV_LOG}"
kit setup-gitlab-runner-user --user gitlab-runner-alpha "${NOIN}"
expect_rc "user alpha: a re-run is idempotent" 0
eq "user alpha: a re-run adds no second passwd line" "$(grep -c '^gitlab-runner-alpha:' "${ROOT}/etc/passwd")" "1"

# --- docker alpha: subid block, service instance, conf.d ---------------------
kit setup-gitlab-runner-docker --user gitlab-runner-alpha "${NOIN}"
expect_rc "docker alpha: setup-gitlab-runner-docker succeeds" 0
eq "docker alpha: /etc/subuid gets the deterministic block" "$(grep '^gitlab-runner-alpha:' "${ROOT}/etc/subuid")" "gitlab-runner-alpha:${A_START}:65536"
eq "docker alpha: /etc/subgid gets the same block" "$(grep '^gitlab-runner-alpha:' "${ROOT}/etc/subgid")" "gitlab-runner-alpha:${A_START}:65536"
eq "docker alpha: the instance is a symlink to the base initd" \
  "$(readlink "${ROOT}/etc/init.d/docker-rootless-gitlab-runner.alpha")" "docker-rootless-gitlab-runner"
check "docker alpha: the base initd is installed" test -x "${ROOT}/etc/init.d/docker-rootless-gitlab-runner"
check "docker alpha: conf.d names the user" grep -qx 'DOCKER_ROOTLESS_USER="gitlab-runner-alpha"' "${ROOT}/etc/conf.d/docker-rootless-gitlab-runner.alpha"
check "docker alpha: conf.d puts the data root in the user's CI dir" \
  grep -qx 'DOCKERD_ROOTLESS_OPTS="--data-root /srv/ci/gitlab-runner-alpha/docker"' "${ROOT}/etc/conf.d/docker-rootless-gitlab-runner.alpha"
check "docker alpha: the instance is added to the default runlevel" grep -qx 'rc-update add docker-rootless-gitlab-runner.alpha default' "${ARGV_LOG}"
check "docker alpha: linger is enabled for the user" grep -qx 'loginctl enable-linger gitlab-runner-alpha' "${ARGV_LOG}"
check "docker alpha: the user's .bashrc gets DOCKER_HOST" grep -q 'DOCKER_HOST=' "${ROOT}/home/gitlab-runner-alpha/.bashrc"
kit setup-gitlab-runner-docker --user gitlab-runner-alpha "${NOIN}"
expect_rc "docker alpha: a re-run is idempotent" 0
eq "docker alpha: a re-run adds no second subuid line" "$(grep -c '^gitlab-runner-alpha:' "${ROOT}/etc/subuid")" "1"

# --- user + docker bravo: a second user on the same host ---------------------
kit setup-gitlab-runner-user --user gitlab-runner-bravo "${NOIN}"; expect_rc "user bravo: succeeds" 0
kit setup-gitlab-runner-docker --user gitlab-runner-bravo "${NOIN}"; expect_rc "docker bravo: succeeds" 0
b_line="$(grep '^gitlab-runner-bravo:' "${ROOT}/etc/subuid")"
eq "docker bravo: its own block" "${b_line}" "gitlab-runner-bravo:${B_START}:65536"
check "two users on one host get disjoint subuid blocks" disjoint "${A_START}" "${B_START}"
eq "user bravo: home is 0700 (alpha cannot read it)" "$(mode_of "${ROOT}/home/gitlab-runner-bravo")" "700"
eq "user alpha: home still 0700 (bravo cannot read it)" "$(mode_of "${ROOT}/home/gitlab-runner-alpha")" "700"

# --- the default user keeps today's values -----------------------------------
kit setup-gitlab-runner-user "${NOIN}"; expect_rc "default user: succeeds" 0
kit setup-gitlab-runner-docker "${NOIN}"; expect_rc "default docker: succeeds" 0
eq "default user: keeps the 296608 block" "$(grep '^gitlab-runner:' "${ROOT}/etc/subuid")" "gitlab-runner:296608:65536"
check "default user: service is docker-rootless-gitlab-runner, no instance" grep -qx 'rc-update add docker-rootless-gitlab-runner default' "${ARGV_LOG}"
if [ -e "${ROOT}/etc/init.d/docker-rootless-gitlab-runner." ]; then bad "default user: no dotted instance file"; else ok "default user: no dotted instance file"; fi
printf 'DOCKER_ROOTLESS_USER="gitlab-runner"\n# owner-edited\n' > "${ROOT}/etc/conf.d/docker-rootless-gitlab-runner"
kit setup-gitlab-runner-docker "${NOIN}"; expect_rc "default docker: a re-run succeeds" 0
check "default user: an existing conf.d is kept as is" grep -qx '# owner-edited' "${ROOT}/etc/conf.d/docker-rootless-gitlab-runner"

# --- an overlap is refused with Fix:, and nothing is written -----------------
kit setup-gitlab-runner-user --user gitlab-runner-charlie "${NOIN}"; expect_rc "user charlie: succeeds" 0
printf 'squatter:%s:65536\n' "${C_START}" >> "${ROOT}/etc/subgid"
sub_before="$(cat "${ROOT}/etc/subuid" "${ROOT}/etc/subgid")"
kit setup-gitlab-runner-docker --user gitlab-runner-charlie "${NOIN}"
expect_rc "docker charlie: an overlapping subgid line is refused" 1
case "${ERR}" in *"squatter:${C_START}:65536"*Fix:*--subid-start*) ok "the refusal names the line and its Fix: names --subid-start" ;;
  *) bad "the refusal names the line and its Fix: names --subid-start" "${ERR}" ;; esac
eq "an overlap refusal writes neither subuid nor subgid" "$(cat "${ROOT}/etc/subuid" "${ROOT}/etc/subgid")" "${sub_before}"
FREE=$(( 1268435456 - 65536 ))
kit setup-gitlab-runner-docker --user gitlab-runner-charlie --subid-start "${FREE}" "${NOIN}"
expect_rc "docker charlie: --subid-start with a free block succeeds" 0
eq "docker charlie: the given block is written" "$(grep '^gitlab-runner-charlie:' "${ROOT}/etc/subuid")" "gitlab-runner-charlie:${FREE}:65536"
printf 'not-a-subid-line\n' >> "${ROOT}/etc/subuid"
kit setup-gitlab-runner-user --user gitlab-runner-delta "${NOIN}"
kit setup-gitlab-runner-docker --user gitlab-runner-delta "${NOIN}"
expect_rc "docker delta: a malformed /etc/subuid is refused, never read as empty" 1
case "${ERR}" in *Fix:*) ok "the malformed-file refusal carries Fix:" ;; *) bad "the malformed-file refusal carries Fix:" "${ERR}" ;; esac
sed -i '/^not-a-subid-line$/d' "${ROOT}/etc/subuid"

# --- no runner user may be in the docker group -------------------------------
printf 'gitlab-runner-bravo docker\n' > "${ROOT}/fake-groups/gitlab-runner-bravo"
kit setup-gitlab-runner-docker --user gitlab-runner-bravo "${NOIN}"
expect_rc "a runner user in the docker group is refused" 1
case "${ERR}" in *Fix:*gpasswd*) ok "the docker-group refusal's Fix: names gpasswd" ;; *) bad "the docker-group refusal's Fix: names gpasswd" "${ERR}" ;; esac
rm -f "${ROOT}/fake-groups/gitlab-runner-bravo"

# --- the runner: tokens on stdin, config.toml 0600 ---------------------------
: > "${ARGV_LOG}"
printf '%s\n%s\n' "${TOK_A}" "${TOK_B}" > "${TMP}/tokens-ab"
kit setup-gitlab-runner --user gitlab-runner-alpha --runner alpha-ci:ci --runner alpha-deploy:deploy:2 "${TMP}/tokens-ab"
expect_rc "runner alpha: setup-gitlab-runner succeeds" 0
CFG="${ROOT}/home/gitlab-runner-alpha/.gitlab-runner/config.toml"
eq "runner alpha: config.toml is 0600" "$(mode_of "${CFG}")" "600"
eq "runner alpha: ~/.gitlab-runner is 0700" "$(mode_of "${ROOT}/home/gitlab-runner-alpha/.gitlab-runner")" "700"
check "runner alpha: concurrent is the summed limits" grep -qx 'concurrent = 3' "${CFG}"
eq "runner alpha: two [[runners]] entries" "$(grep -c '^\[\[runners\]\]$' "${CFG}")" "2"
check "runner alpha: first token is in its entry" grep -qxF "  token = \"${TOK_A}\"" "${CFG}"
check "runner alpha: second token is in its entry" grep -qxF "  token = \"${TOK_B}\"" "${CFG}"
check "runner alpha: the deploy entry records its tag" grep -qF 'tags = ["deploy"], run_untagged = false' "${CFG}"
check "runner alpha: the deploy entry has its own limit" grep -qx '  limit = 2' "${CFG}"
eq "runner alpha: the instance is a symlink to the base initd" "$(readlink "${ROOT}/etc/init.d/gitlab-runner.alpha")" "gitlab-runner"
check "runner alpha: conf.d names the config" \
  grep -qx 'RUNNER_CONFIG="/home/gitlab-runner-alpha/.gitlab-runner/config.toml"' "${ROOT}/etc/conf.d/gitlab-runner.alpha"
check "runner alpha: the config is chowned to the user" grep -q '^chown gitlab-runner-alpha:gitlab-runner-alpha ' "${ARGV_LOG}"
if grep -q '^rc-service .* start' "${ARGV_LOG}"; then bad "runner alpha: the service is not started"; else ok "runner alpha: the service is not started"; fi

cfg_before="$(cat "${CFG}")"
kit setup-gitlab-runner --user gitlab-runner-alpha --runner alpha-ci:ci --runner alpha-deploy:deploy:2 "${NOIN}"
expect_rc "runner alpha: a re-run with the entries present reads no token" 0
eq "runner alpha: a re-run leaves the config unchanged" "$(cat "${CFG}")" "${cfg_before}"

printf '%s\n' "${TOK_C}" > "${TMP}/tokens-c"
kit setup-gitlab-runner --user gitlab-runner-alpha --runner alpha-ci:ci --runner alpha-extra:extra "${TMP}/tokens-c"
expect_rc "runner alpha: a new entry is appended, reading only its token" 0
eq "runner alpha: three entries after the append" "$(grep -c '^\[\[runners\]\]$' "${CFG}")" "3"
check "runner alpha: the appended entry has the new token" grep -qxF "  token = \"${TOK_C}\"" "${CFG}"
eq "runner alpha: the config stays 0600 after the append" "$(mode_of "${CFG}")" "600"

# A bad token, or none, is refused with Fix: and nothing is written.
printf '%s\n' "${NOT_TOK}" > "${TMP}/tokens-bad"
before="$(snapshot)"
kit setup-gitlab-runner --user gitlab-runner-bravo --runner bravo-ci:ci "${TMP}/tokens-bad"
expect_rc "runner bravo: a non-glrt stdin line is refused" 1
case "${ERR}" in *Fix:*) ok "the bad-token refusal carries Fix:" ;; *) bad "the bad-token refusal carries Fix:" "${ERR}" ;; esac
eq "runner bravo: a bad token changes no file" "$(snapshot)" "${before}"
kit setup-gitlab-runner --user gitlab-runner-bravo --runner bravo-ci:ci "${NOIN}"
expect_rc "runner bravo: an empty stdin is refused" 1
eq "runner bravo: a missing token changes no file" "$(snapshot)" "${before}"
kit setup-gitlab-runner --user gitlab-runner-bravo --runner bravo-ci:ci --dry-run "${TMP}/tokens-ab"
expect_rc "runner bravo: --dry-run succeeds" 0
eq "runner bravo: --dry-run changes no file" "$(snapshot)" "${before}"
kit setup-gitlab-runner --user gitlab-runner-bravo --runner bravo-ci:ci --runner bravo-ci:deploy "${TMP}/tokens-ab"
expect_rc "a runner name given twice is refused" 1
kit setup-gitlab-runner --user gitlab-runner-bravo "--token=${TOK_A}" "${NOIN}"
expect_rc "a token passed as an argument is refused as an unknown argument" 1
kit setup-gitlab-runner --user gitlab-runner-bravo --runner "${TOK_B}" "${NOIN}"
expect_rc "a token pasted as a --runner spec is refused" 1
case "${ERR}" in *"glrt-<not shown>"*) ok "the refusal shows glrt-<not shown> in the token's place" ;; *) bad "the refusal shows glrt-<not shown> in the token's place" "${ERR}" ;; esac

# --- a token never reaches argv or any output --------------------------------
leaked=""
for t in "${ALL_TOK[@]}"; do
  # The deliberately refused argv case above put TOK_A in the script's own argv;
  # every OTHER process's argv is in the log, and must not hold any token.
  if grep -qF -- "${t}" "${ARGV_LOG}"; then leaked="${leaked} argv-log"; fi
done
[ -z "${leaked}" ] && ok "no token reached any spawned command's argv" || bad "no token reached any spawned command's argv" "${leaked}"
transcript_hits=0
while IFS= read -r line; do
  for t in "${ALL_TOK[@]}"; do
    case "${line}" in *"${t}"*) transcript_hits=$((transcript_hits + 1)) ;; esac
  done
done < "${TRANSCRIPT}"
eq "no token reached any stdout or stderr" "${transcript_hits}" "0"

# --- the initd derives the user from the service name ------------------------
initd_vars() { # <initd> <RC_SVCNAME> -> the derived user/home/config
  env -i PATH=/usr/bin:/bin RC_SVCNAME="$2" sh -c '
    after() { printf "after %s\n" "$*"; }; need() { :; }
    . "$1" >/dev/null 2>&1
    printf "%s|%s|%s|%s\n" "${RUNNER_USER:-}" "${RUNNER_HOME:-}" "${RUNNER_CONFIG:-}" "${DOCKER_ROOTLESS_USER:-}"
    depend' sh "${SRC}/system-files/$1.initd"
}
got="$(initd_vars gitlab-runner gitlab-runner)"
case "${got}" in "gitlab-runner|/home/gitlab-runner|/home/gitlab-runner/.gitlab-runner/config.toml|"*"after elogind firewall docker-rootless-gitlab-runner") ok "initd: the default service keeps today's user, home and config" ;;
  *) bad "initd: the default service keeps today's user, home and config" "${got}" ;; esac
got="$(initd_vars gitlab-runner gitlab-runner.alpha)"
case "${got}" in "gitlab-runner-alpha|/home/gitlab-runner-alpha|/home/gitlab-runner-alpha/.gitlab-runner/config.toml|"*"after elogind firewall docker-rootless-gitlab-runner.alpha") ok "initd: gitlab-runner.alpha runs as gitlab-runner-alpha after its own docker" ;;
  *) bad "initd: gitlab-runner.alpha runs as gitlab-runner-alpha after its own docker" "${got}" ;; esac
got="$(initd_vars docker-rootless-gitlab-runner docker-rootless-gitlab-runner)"
case "${got}" in "|||gitlab-runner"*) ok "initd: the default docker service keeps user gitlab-runner" ;; *) bad "initd: the default docker service keeps user gitlab-runner" "${got}" ;; esac
got="$(initd_vars docker-rootless-gitlab-runner docker-rootless-gitlab-runner.alpha)"
case "${got}" in "|||gitlab-runner-alpha"*) ok "initd: docker-rootless-gitlab-runner.alpha runs as gitlab-runner-alpha" ;; *) bad "initd: docker-rootless-gitlab-runner.alpha runs as gitlab-runner-alpha" "${got}" ;; esac

echo "gitlab-runner-kit self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
