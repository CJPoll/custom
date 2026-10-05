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

# Synthetic tokens. "glrt" and "-" are joined at runtime. They have the shape
# GitLab mints (DND-1982): a routable token is dot-segmented,
# glrt-t<n>_<payload>.<version>.<crc>, so '.' is part of every real token.
# Each tail (the text after the first '.') is distinct, so a leak check can
# search for the tail alone.
P_RT="glrt""-"
TOK_A="${P_RT}t3_SYNTHaaaaaaaaaaaaaaaaaaaa.01.0aaaaaaa1"
TOK_B="${P_RT}t3_SYNTHbbbbbbbbbbbbbbbbbbbb.02.0bbbbbbb2"
TOK_C="${P_RT}t3_SYNTHcccccccccccccccccccc.03.0ccccccc3"
NOT_TOK="plainSYNTHdddddddddddddddddddd4"
ALL_TOK=("${TOK_A}" "${TOK_B}" "${TOK_C}" "${NOT_TOK}")
tok_tail() { printf '%s' "${1#*.}"; } # the text after the first '.'
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
# DND-1982: the shape GitLab mints carries '.'; the brief's acceptance token.
check "lib: a dot-segmented routable token is accepted" grk_valid_token "${P_RT}t3_AAAAAAAAAAAAAAAAAAAA.01.0aaaaaaaa"
check "lib: the 20-character minimum counts the dot segments" grk_valid_token "${P_RT}t3_SYNTH.01.0aaaaaaaaaaa"
check "lib: an undotted (legacy) token is still accepted" grk_valid_token "${P_RT}SYNTHaaaaaaaaaaaaaaaaaaaaaa1"
if grk_valid_token "${NOT_TOK}" || grk_valid_token "${P_RT}short" || grk_valid_token "${TOK_A} x"; then
  bad "lib: a non-glrt, short, or spaced token is refused"
else ok "lib: a non-glrt, short, or spaced token is refused"; fi
n=0
for badtok in "${TOK_A}." ".${TOK_A}" "${P_RT}.t3_SYNTHaaaaaaaaaaaaaaaaaaaa" "${P_RT}t3_SYNTHaaaaaaaaaa..01.0aaaaaaa1" \
              "${P_RT}short.01.0a"; do
  n=$((n + 1))
  if grk_valid_token "${badtok}"; then bad "lib: an empty dot segment or a short token is refused (case ${n})"
  else ok "lib: an empty dot segment or a short token is refused (case ${n})"; fi
done
# grk_redact consumes the whole token, '.' segments included, and leaves a
# sentence's trailing period: a '.' with no token character after it is not
# part of the token.
red="$(grk_redact "token ${TOK_A}. next")"
eq "lib: redact replaces a dotted token, keeping a trailing period" "${red}" "token glrt-<not shown>. next"
case "${red}" in *"$(tok_tail "${TOK_A}")"*) bad "lib: redact leaves no fragment after the token's first '.'" "${red}" ;;
  *) ok "lib: redact leaves no fragment after the token's first '.'" ;; esac
red="$(grk_redact "a=${TOK_A},b=${TOK_B}")"
eq "lib: redact replaces two dotted tokens in one line" "${red}" "a=glrt-<not shown>,b=glrt-<not shown>"
red="$(grk_redact "x ${P_RT}t3_SYNTHeeee..05..0eeee y")"
eq "lib: redact also consumes a run of dots inside a token" "${red}" "x glrt-<not shown> y"
check "lib: https://gitlab.com is a valid url" grk_valid_url https://gitlab.com
if grk_valid_url http://gitlab.com || grk_valid_url https://u:p@gitlab.com || grk_valid_url https://gitlab.com/x; then
  bad "lib: http, credentialed and pathed urls are refused"
else ok "lib: http, credentialed and pathed urls are refused"; fi

render="$(grk_render_runner alpha-ci ci 1 https://gitlab.com /srv/ci/gitlab-runner-alpha "${TOK_A}" /run/user/2001/docker.sock)"
for want in '[[runners]]' 'name = "alpha-ci"' 'tags = ["ci"], run_untagged = false' 'limit = 1' \
            'privileged = false' "token = \"${TOK_A}\""; do
  case "${render}" in *"${want}"*) ok "lib: a rendered entry has ${want%% =*}" ;; *) bad "lib: a rendered entry has ${want%% =*}" "${render}" ;; esac
done
printf '%s\n' "${render}" > "${TMP}/cfg"
if grk_config_has_runner alpha-ci < "${TMP}/cfg"; then ok "lib: config_has_runner finds a rendered entry"; else bad "lib: config_has_runner finds a rendered entry"; fi
if grk_config_has_runner alpha < "${TMP}/cfg"; then bad "lib: config_has_runner matches whole names only"; else ok "lib: config_has_runner matches whole names only"; fi
eq "lib: config_roles reads each entry's role" "$(printf '%s\n%s\n%s\n' "$(grk_render_runner a ci 1 https://gitlab.com /x "${TOK_A}" /run/user/2001/docker.sock)" "$(grk_render_runner b - 1 https://gitlab.com /x "${TOK_A}")" '[[runners]]' | grk_config_roles | tr '\n' ' ')" "ci - ? "
eq "lib: --runner NAME:- is an untagged runner" "$(grk_parse_runner walt-ui:-:3)" "walt-ui - 3"
case "$(grk_render_runner walt-ui - 3 https://gitlab.com /srv/ci/gitlab-runner "${TOK_A}")" in
  *"untagged: no tags, run_untagged = true"*) ok "lib: an untagged entry says so, not run_untagged = false" ;;
  *) bad "lib: an untagged entry says so, not run_untagged = false" ;; esac
# The runner contract per role (DND-1973): what a job of each role is given.
eq "lib: the builds dir is /srv/ci/<user>/builds" "$(grk_builds_dir gitlab-runner-alpha)" "/srv/ci/gitlab-runner-alpha/builds"
eq "lib: a user's rootless docker socket is /run/user/<uid>/docker.sock" "$(grk_docker_socket 2001)" "/run/user/2001/docker.sock"
for baduid in "" 0 x12 "12 3" -5 4294967295; do
  err="$(grk_docker_socket "${baduid}" 2>&1)" && bad "lib: uid '${baduid}' gives no socket path" "accepted: ${err}"
  case "${err}" in *Fix:*) ok "lib: uid '${baduid}' is refused with Fix:, never an empty socket path" ;; *) bad "lib: uid '${baduid}' is refused with Fix:, never an empty socket path" "${err}" ;; esac
done
SOCK_A="/run/user/2001/docker.sock"
ci_render="$(grk_render_runner alpha-ci ci 1 https://gitlab.com /srv/ci/gitlab-runner-alpha "${TOK_A}" "${SOCK_A}")"
for want in '  builds_dir = "/srv/ci/gitlab-runner-alpha/builds"' \
            '    volumes = ["/run/user/2001/docker.sock:/var/run/docker.sock", "/srv/ci/gitlab-runner-alpha/builds:/srv/ci/gitlab-runner-alpha/builds", "/srv/ci/gitlab-runner-alpha/cache:/cache"]' \
            '  [runners.docker.services_tmpfs]' \
            '    "/var/lib/postgresql/data" = "rw,size=2g"' \
            '    privileged = false'; do
  if grep -qxF -- "${want}" <<<"${ci_render}"; then ok "lib: a ci entry has: ${want## }"; else bad "lib: a ci entry has: ${want## }" "${ci_render}"; fi
done
dp_render="$(grk_render_runner charlie-deploy deploy 1 https://gitlab.com /srv/ci/gitlab-runner-charlie "${TOK_A}" /run/user/2003/docker.sock)"
for want in '  builds_dir = "/srv/ci/gitlab-runner-charlie/builds"' \
            '    volumes = ["/run/user/2003/docker.sock:/var/run/docker.sock", "/srv/ci/gitlab-runner-charlie/builds:/srv/ci/gitlab-runner-charlie/builds", "/srv/ci/gitlab-runner-charlie/cache:/cache"]' \
            '    privileged = false'; do
  if grep -qxF -- "${want}" <<<"${dp_render}"; then ok "lib: a deploy entry has: ${want## }"; else bad "lib: a deploy entry has: ${want## }" "${dp_render}"; fi
done
case "${dp_render}" in *services_tmpfs*|*postgresql*) bad "lib: a deploy entry has no services tmpfs (no database service)" "${dp_render}" ;;
  *) ok "lib: a deploy entry has no services tmpfs (no database service)" ;; esac
# builds_dir is a [[runners]] key: it must come before the [runners.docker] table.
bd_line="$(grep -n '^  builds_dir' <<<"${ci_render}" | cut -d: -f1)"; dk_line="$(grep -n '^  \[runners.docker\]$' <<<"${ci_render}" | cut -d: -f1)"
if [ -n "${bd_line}" ] && [ -n "${dk_line}" ] && [ "${bd_line}" -lt "${dk_line}" ]; then ok "lib: builds_dir sits in [[runners]], before [runners.docker]"
else bad "lib: builds_dir sits in [[runners]], before [runners.docker]" "${ci_render}"; fi
err="$(grk_render_runner alpha-ci ci 1 https://gitlab.com /srv/ci/gitlab-runner-alpha "${TOK_A}" 2>&1)" && bad "lib: a ci entry with no socket is refused" "accepted"
case "${err}" in *Fix:*) ok "lib: a ci entry with no socket is refused with Fix:, never written without the daemon" ;; *) bad "lib: a ci entry with no socket is refused with Fix:, never written without the daemon" "${err}" ;; esac
case "${err}" in *"${TOK_A}"*) bad "lib: that refusal never prints the token" ;; *) ok "lib: that refusal never prints the token" ;; esac
for tag in - other; do
  r="$(grk_render_runner u "${tag}" 1 https://gitlab.com /srv/ci/gitlab-runner "${TOK_A}" "${SOCK_A}")"
  case "${r}" in *docker.sock*|*builds_dir*|*services_tmpfs*) bad "lib: a '${tag}' entry gets no socket, builds_dir or tmpfs (only ci and deploy do)" "${r}" ;;
    *) ok "lib: a '${tag}' entry gets no socket, builds_dir or tmpfs (only ci and deploy do)" ;; esac
  case "${r}" in *'volumes = ["/srv/ci/gitlab-runner/cache:/cache"]'*) ok "lib: a '${tag}' entry keeps the cache-only volumes" ;; *) bad "lib: a '${tag}' entry keeps the cache-only volumes" "${r}" ;; esac
done
# Per-role security_opt (DND-1999). The rendered line of each role is matched
# exactly, and each entry has at most one security_opt line.
SO_CI='    security_opt = ["seccomp:unconfined", "apparmor:unconfined"]'
SO_UNTAGGED='    security_opt = ["seccomp:unconfined", "apparmor:unconfined"]'
so_lines() { grep -c 'security_opt' <<<"$1"; }
eq "lib: a ci entry has exactly one security_opt line" "$(so_lines "${ci_render}")" "1"
if grep -qxF -- "${SO_CI}" <<<"${ci_render}"; then ok "lib: a ci entry's security_opt is seccomp + apparmor unconfined (the live pair, no systempaths)"
else bad "lib: a ci entry's security_opt is seccomp + apparmor unconfined (the live pair, no systempaths)" "${ci_render}"; fi
case "${ci_render}" in *systempaths*) bad "lib: a ci entry renders no systempaths (the Engine API refuses it)" "${ci_render}" ;;
  *) ok "lib: a ci entry renders no systempaths (the Engine API refuses it)" ;; esac
eq "lib: a deploy entry has no security_opt (Docker's default seccomp and masked /proc)" "$(so_lines "${dp_render}")" "0"
case "${dp_render}" in *unconfined*) bad "lib: a deploy entry names nothing unconfined" "${dp_render}" ;;
  *) ok "lib: a deploy entry names nothing unconfined" ;; esac
un_render="$(grk_render_runner walt-ui - 3 https://gitlab.com /srv/ci/gitlab-runner "${TOK_A}")"
eq "lib: an untagged entry has exactly one security_opt line" "$(so_lines "${un_render}")" "1"
if grep -qxF -- "${SO_UNTAGGED}" <<<"${un_render}"; then ok "lib: an untagged entry keeps the rootless-BuildKit pair (seccomp + apparmor unconfined)"
else bad "lib: an untagged entry keeps the rootless-BuildKit pair (seccomp + apparmor unconfined)" "${un_render}"; fi
case "${un_render}" in *systempaths*) bad "lib: an untagged entry does not unmask /proc" "${un_render}" ;;
  *) ok "lib: an untagged entry does not unmask /proc" ;; esac
for tag in other build ci2 deployx; do
  r="$(grk_render_runner u "${tag}" 1 https://gitlab.com /srv/ci/gitlab-runner "${TOK_A}")"
  case "${r}" in *security_opt*|*unconfined*) bad "lib: a '${tag}' entry (no known role) gets Docker's defaults, no security_opt" "${r}" ;;
    *) ok "lib: a '${tag}' entry (no known role) gets Docker's defaults, no security_opt" ;; esac
done
# security_opt is a [runners.docker] key: it must sit after that table header.
so_line="$(grep -n '^    security_opt' <<<"${ci_render}" | cut -d: -f1)"
if [ -n "${so_line}" ] && [ -n "${dk_line}" ] && [ "${so_line}" -gt "${dk_line}" ]; then ok "lib: security_opt sits in [runners.docker]"
else bad "lib: security_opt sits in [runners.docker]" "${ci_render}"; fi
# Engine-API grammar (DND-2039). The runner sends security_opt as HostConfig.SecurityOpt,
# and the daemon (moby daemon/daemon_unix.go parseSecurityOpt) accepts only these
# keys, as key=value or the deprecated key:value: label, apparmor, seccomp, and
# no-new-privileges (bare, or =true|false). Any other key is refused at container
# create: "invalid --security-opt 2". `systempaths=unconfined` is a docker CLI flag
# the CLI rewrites to MaskedPaths/ReadonlyPaths; the API refuses it, so every
# ci job failed to start (2026-10-04). Each rendered value must match.
so_value_ok() {
  case "$1" in
    seccomp[:=]?*|apparmor[:=]?*|label[:=]?*) return 0 ;;
    no-new-privileges|no-new-privileges[:=]true|no-new-privileges[:=]false) return 0 ;;
    *) return 1 ;;
  esac
}
so_values_ok() { # ROLE -> 0 when every value of the role's security_opt is API-valid
  local v rest; rest="$(grk_role_security_opt "$1")"; rest="${rest//[\[\]\" ]/}"
  [ -n "${rest}" ] || return 0
  local IFS=,; for v in ${rest}; do so_value_ok "${v}" || { printf 'invalid: %s\n' "${v}" >&2; return 1; }; done
}
for role in ci deploy - other; do
  check "lib: every security_opt value of role '${role}' is a form the Docker Engine API accepts" so_values_ok "${role}"
done
if so_value_ok "systempaths=unconfined"; then bad "lib: the grammar check rejects systempaths=unconfined (CLI-only)"
else ok "lib: the grammar check rejects systempaths=unconfined (CLI-only)"; fi
for good in seccomp:unconfined apparmor=unconfined label=disable no-new-privileges; do
  check "lib: the grammar check accepts ${good}" so_value_ok "${good}"
done
# Reading a kept entry's security_opt back (the re-run drift warning).
eq "lib: role_security_opt ci" "$(grk_role_security_opt ci)" '["seccomp:unconfined", "apparmor:unconfined"]'
eq "lib: role_security_opt untagged" "$(grk_role_security_opt -)" '["seccomp:unconfined", "apparmor:unconfined"]'
eq "lib: role_security_opt deploy is empty" "$(grk_role_security_opt deploy)" ""
eq "lib: role_security_opt of an unknown role is empty" "$(grk_role_security_opt other)" ""
two="$(printf '%s\n%s\n' "${ci_render}" "${dp_render}")"
eq "lib: entry_security_opt reads the ci entry's value, spaces removed" \
  "$(grk_config_entry_security_opt alpha-ci <<<"${two}")" '["seccomp:unconfined","apparmor:unconfined"]'
eq "lib: entry_security_opt reads the deploy entry as none" "$(grk_config_entry_security_opt charlie-deploy <<<"${two}")" ""
if grk_config_entry_security_opt no-such-runner <<<"${two}" >/dev/null; then bad "lib: entry_security_opt of a missing entry fails, never reads as none"
else ok "lib: entry_security_opt of a missing entry fails, never reads as none"; fi
if grk_security_opt_matches deploy no-such-runner <<<"${two}"; then bad "lib: security_opt_matches of a missing entry is no match"
else ok "lib: security_opt_matches of a missing entry is no match"; fi
check "lib: security_opt_matches: the rendered ci entry matches its role" \
  grk_security_opt_matches ci alpha-ci <<<"${two}"
check "lib: security_opt_matches: the rendered deploy entry matches its role" \
  grk_security_opt_matches deploy charlie-deploy <<<"${two}"
old_dp="$(sed 's/^  \[runners.docker\]$/&\n    security_opt = ["seccomp:unconfined", "apparmor:unconfined"]/' <<<"${dp_render}")"
if grk_security_opt_matches deploy charlie-deploy <<<"${old_dp}"; then bad "lib: a deploy entry with the old unconfined pair does not match its role" "${old_dp}"
else ok "lib: a deploy entry with the old unconfined pair does not match its role"; fi
old_ci="$(sed 's/^    security_opt = .*$/    security_opt = [ "seccomp:unconfined" , "apparmor:unconfined", "systempaths=unconfined" ]/' <<<"${ci_render}")"
if grk_security_opt_matches ci alpha-ci <<<"${old_ci}"; then bad "lib: a ci entry with the CLI-only systempaths value does not match its role" "${old_ci}"
else ok "lib: a ci entry with the CLI-only systempaths value does not match its role"; fi
spaced_ci="$(sed 's/^    security_opt = .*$/  security_opt=[ "seccomp:unconfined","apparmor:unconfined" ]/' <<<"${ci_render}")"
check "lib: security_opt_matches ignores whitespace inside the array" grk_security_opt_matches ci alpha-ci <<<"${spaced_ci}"
commented_dp="$(sed 's/^  \[runners.docker\]$/&\n    # security_opt = ["seccomp:unconfined"]/' <<<"${dp_render}")"
trailing_ci="$(sed 's/^    security_opt = .*$/& # set by hand/' <<<"${ci_render}")"
check "lib: a # comment after the value is not part of it" grk_security_opt_matches ci alpha-ci <<<"${trailing_ci}"
check "lib: a commented-out security_opt is not read as one" grk_security_opt_matches deploy charlie-deploy <<<"${commented_dp}"
case "$(grk_render_runner_confd gitlab-runner /home/gitlab-runner)" in
  *RUNNER_USER=*|*RUNNER_HOME=*|*RUNNER_CONFIG=*) bad "lib: the default user's runner conf.d sets no user/home/config (instances inherit it)" ;;
  *) ok "lib: the default user's runner conf.d sets no user/home/config (instances inherit it)" ;; esac
case "$(grk_render_docker_confd gitlab-runner)" in
  *DOCKER_ROOTLESS_USER=*) bad "lib: the default user's docker conf.d sets no user (instances inherit it)" ;;
  *) ok "lib: the default user's docker conf.d sets no user (instances inherit it)" ;; esac

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
for tool in sh test awk cksum mkdir chmod mv mktemp cat grep ln rm cut head tr sed dirname basename tail wc sort env cp stat touch sha256sum; do
  real="$(type -P "${tool}")" && [ -n "${real}" ] || { echo "FAIL: ${tool} has no executable on PATH"; exit 1; }  # a path, never a builtin: a builtin name would exec the shim itself
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nexec "%s" "$@"\n' "${tool}" "${ARGV_LOG}" "${real}" > "${SHIMS}/${tool}"
  chmod 755 "${SHIMS}/${tool}"
done
REAL_INSTALL="$(command -v install)"
REAL_BASH="$(command -v bash)"
REAL_UID="$(id -u)"
stub() { # <name> <body>: a stub that logs its argv, then runs body
  printf '#!%s\nprintf "%%s\\n" "%s $*" >> "%s"\nROOT="%s"\nREAL_UID="%s"\n%s\n' "${REAL_BASH}" "$1" "${ARGV_LOG}" "${ROOT}" "${REAL_UID}" "$2" > "${STUBS}/$1"
  chmod 755 "${STUBS}/$1"
}
stub id '
if [ "$1" = "-u" ] && [ $# -eq 1 ]; then echo 0; exit 0; fi
if [ "$1" = "-u" ]; then grep -q "^$2:" "${ROOT}/etc/passwd" && { echo "${REAL_UID}"; exit 0; }; exit 1; fi
if [ "$1" = "-nG" ]; then
  if [ -f "${ROOT}/fake-groups/$2" ]; then cat "${ROOT}/fake-groups/$2"; else echo "$2"; fi; exit 0
fi
exit 1'
stub getent '
[ "$1" = passwd ] || exit 2
grep "^$2:" "${ROOT}/etc/passwd" || exit 2'
stub useradd '
home=""; name=""
while [ $# -gt 0 ]; do case "$1" in -d) home="$2"; shift ;; -s|-K) shift ;; -m) ;; *) name="$1" ;; esac; shift; done
uid=$(( 2000 + $(wc -l < "${ROOT}/etc/passwd") ))
printf "%s:x:%s:%s::%s:/bin/bash\n" "${name}" "${uid}" "${uid}" "${home}" >> "${ROOT}/etc/passwd"
mkdir -p "${ROOT}${home}"; chmod 0755 "${ROOT}${home}"'
stub install "
args=()
while [ \$# -gt 0 ]; do case \"\$1\" in -o|-g) shift ;; *) args+=(\"\$1\") ;; esac; shift; done
exec ${REAL_INSTALL} \"\${args[@]}\""
stub chown ':'
# runuser -u USER -- CMD...: the test runs as one account, so it just runs CMD.
stub runuser '
[ "$1" = "-u" ] && [ "$3" = "--" ] || { echo "runuser stub: unexpected argv" >&2; exit 2; }
shift 3; exec "$@"'
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
  if grep -q . <<<"$(grep -vE '^(awk|dirname) ' "${ARGV_LOG}")"; then bad "${s} --help runs no host command" "$(cat "${ARGV_LOG}")"
  else ok "${s} --help runs no host command"; fi
done

kit setup-gitlab-runner --help "${NOIN}"
for want in "builds_dir" "/var/run/docker.sock" "services_tmpfs" "runner token" "DND-1942" \
            "security_opt" "systempaths=unconfined" "seccomp:unconfined" "Docker's default seccomp" "user namespaces" "mount /proc"; do
  case "${OUT}" in *"${want}"*) ok "setup-gitlab-runner --help states the role contract and its residual (${want})" ;;
    *) bad "setup-gitlab-runner --help states the role contract and its residual (${want})" ;; esac
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
eq "user alpha: /srv/ci/gitlab-runner-alpha is 0710 (root-owned; the user only traverses)" "$(mode_of "${ROOT}/srv/ci/gitlab-runner-alpha")" "710"
check "user alpha: /srv/ci/gitlab-runner-alpha is created root-owned" \
  grep -q "^install -d -m 0710 -o root -g gitlab-runner-alpha ${ROOT}/srv/ci/gitlab-runner-alpha\$" "${ARGV_LOG}"
for d in /docker /cache; do
  eq "user alpha: /srv/ci/gitlab-runner-alpha${d} is 0700" "$(mode_of "${ROOT}/srv/ci/gitlab-runner-alpha${d}")" "700"
done
# The builds dir: traverse-only for others, so a job's non-root user reaches its
# checkout inside the container; /srv/ci/<user> (0710) still keeps host users out.
eq "user alpha: /srv/ci/gitlab-runner-alpha/builds is 0711" "$(mode_of "${ROOT}/srv/ci/gitlab-runner-alpha/builds")" "711"
check "user alpha: the builds dir is created owned by the user" \
  grep -q "^install -d -m 0711 -o gitlab-runner-alpha -g gitlab-runner-alpha ${ROOT}/srv/ci/gitlab-runner-alpha/builds\$" "${ARGV_LOG}"
check "user alpha: useradd allocates no subid block itself" grep -q '^useradd .*-K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 gitlab-runner-alpha$' "${ARGV_LOG}"
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

# --- root never follows a symlink a runner user planted -------------------------
mkdir -p "${TMP}/elsewhere"; chmod 755 "${TMP}/elsewhere"
mkdir -p "${ROOT}/srv/ci"; ln -s "${TMP}/elsewhere" "${ROOT}/srv/ci/gitlab-runner-echo"
kit setup-gitlab-runner-user --user gitlab-runner-echo "${NOIN}"
expect_rc "user echo: a symlinked /srv/ci/<user> is refused" 1
case "${ERR}" in *symlink*Fix:*) ok "the symlink refusal carries Fix:" ;; *) bad "the symlink refusal carries Fix:" "${ERR}" ;; esac
eq "user echo: the symlink's target is untouched" "$(mode_of "${TMP}/elsewhere")" "755"
rm -f "${ROOT}/srv/ci/gitlab-runner-echo"

# --- the default user keeps today's values -----------------------------------
kit setup-gitlab-runner-user "${NOIN}"; expect_rc "default user: succeeds" 0
kit setup-gitlab-runner-docker "${NOIN}"; expect_rc "default docker: succeeds" 0
eq "default user: keeps the 296608 block" "$(grep '^gitlab-runner:' "${ROOT}/etc/subuid")" "gitlab-runner:296608:65536"
check "default user: service is docker-rootless-gitlab-runner, no instance" grep -qx 'rc-update add docker-rootless-gitlab-runner default' "${ARGV_LOG}"
if [ -e "${ROOT}/etc/init.d/docker-rootless-gitlab-runner." ]; then bad "default user: no dotted instance file"; else ok "default user: no dotted instance file"; fi
check "default user: a new docker conf.d names no user (instances would inherit it)" \
  bash -c '! grep -q "^DOCKER_ROOTLESS_USER=" "$1"' _ "${ROOT}/etc/conf.d/docker-rootless-gitlab-runner"
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

# subuid/subgid stay paired, and an append survives a missing final newline.
kit setup-gitlab-runner-user --user gitlab-runner-foxtrot "${NOIN}"
printf 'gitlab-runner-foxtrot:%s:65536\n' "$(( 1268435456 - 2 * 65536 ))" >> "${ROOT}/etc/subgid"
kit setup-gitlab-runner-docker --user gitlab-runner-foxtrot "${NOIN}"
expect_rc "docker foxtrot: a block present only in subgid is reused for subuid" 0
eq "docker foxtrot: subuid gets subgid's block" "$(grep '^gitlab-runner-foxtrot:' "${ROOT}/etc/subuid")" \
  "gitlab-runner-foxtrot:$(( 1268435456 - 2 * 65536 )):65536"
kit setup-gitlab-runner-user --user gitlab-runner-hotel "${NOIN}"
printf 'gitlab-runner-hotel:%s:65536\n' "$(( 1268435456 - 4 * 65536 ))" >> "${ROOT}/etc/subgid"
sub_before="$(cat "${ROOT}/etc/subuid" "${ROOT}/etc/subgid")"
kit setup-gitlab-runner-docker --user gitlab-runner-hotel --subid-start $(( 1268435456 - 5 * 65536 )) "${NOIN}"
expect_rc "docker hotel: --subid-start that differs from the user's existing block is refused" 1
case "${ERR}" in *"maps would diverge"*Fix:*) ok "the diverging-block refusal carries Fix:" ;; *) bad "the diverging-block refusal carries Fix:" "${ERR}" ;; esac
eq "docker hotel: the refusal writes neither file" "$(cat "${ROOT}/etc/subuid" "${ROOT}/etc/subgid")" "${sub_before}"
printf 'tail-no-newline:1:1' >> "${ROOT}/etc/subuid"; printf 'tail-no-newline:1:1' >> "${ROOT}/etc/subgid"
kit setup-gitlab-runner-user --user gitlab-runner-golf "${NOIN}"
kit setup-gitlab-runner-docker --user gitlab-runner-golf --subid-start $(( 1268435456 - 3 * 65536 )) "${NOIN}"
expect_rc "docker golf: succeeds after a line with no final newline" 0
check "docker golf: the unterminated line is kept whole" grep -qx 'tail-no-newline:1:1' "${ROOT}/etc/subuid"
check "docker golf: its own line is whole" grep -qx "gitlab-runner-golf:$(( 1268435456 - 3 * 65536 )):65536" "${ROOT}/etc/subuid"

# A kept instance conf.d that names another user is refused.
printf 'DOCKER_ROOTLESS_USER="gitlab-runner"\n' > "${ROOT}/etc/conf.d/docker-rootless-gitlab-runner.golf"
kit setup-gitlab-runner-docker --user gitlab-runner-golf "${NOIN}"
expect_rc "docker golf: a kept conf.d naming another user is refused" 1
case "${ERR}" in *DOCKER_ROOTLESS_USER=gitlab-runner*Fix:*) ok "the kept-conf.d refusal names the user, with Fix:" ;; *) bad "the kept-conf.d refusal names the user, with Fix:" "${ERR}" ;; esac
rm -f "${ROOT}/etc/conf.d/docker-rootless-gitlab-runner.golf"

# --- no runner user may be in the docker group -------------------------------
printf 'gitlab-runner-bravo docker\n' > "${ROOT}/fake-groups/gitlab-runner-bravo"
kit setup-gitlab-runner-docker --user gitlab-runner-bravo "${NOIN}"
expect_rc "a runner user in the docker group is refused" 1
case "${ERR}" in *Fix:*gpasswd*) ok "the docker-group refusal's Fix: names gpasswd" ;; *) bad "the docker-group refusal's Fix: names gpasswd" "${ERR}" ;; esac
rm -f "${ROOT}/fake-groups/gitlab-runner-bravo"

# --- the runner: tokens on stdin, config.toml 0600 ---------------------------
: > "${ARGV_LOG}"
printf '%s\n%s\n' "${TOK_A}" "${TOK_B}" > "${TMP}/tokens-ab"
kit setup-gitlab-runner --user gitlab-runner-alpha --runner alpha-ci:ci --runner alpha-ci2:ci:2 "${TMP}/tokens-ab"
expect_rc "runner alpha: setup-gitlab-runner succeeds" 0
CFG="${ROOT}/home/gitlab-runner-alpha/.gitlab-runner/config.toml"
eq "runner alpha: config.toml is 0600" "$(mode_of "${CFG}")" "600"
eq "runner alpha: ~/.gitlab-runner is 0700" "$(mode_of "${ROOT}/home/gitlab-runner-alpha/.gitlab-runner")" "700"
check "runner alpha: concurrent is the summed limits" grep -qx 'concurrent = 3' "${CFG}"
eq "runner alpha: two [[runners]] entries" "$(grep -c '^\[\[runners\]\]$' "${CFG}")" "2"
check "runner alpha: first token is in its entry" grep -qxF "  token = \"${TOK_A}\"" "${CFG}"
check "runner alpha: second token is in its entry" grep -qxF "  token = \"${TOK_B}\"" "${CFG}"
check "runner alpha: an entry records its tag" grep -qF 'tags = ["ci"], run_untagged = false' "${CFG}"
check "runner alpha: an entry has its own limit" grep -qx '  limit = 2' "${CFG}"
uid_of() { awk -F: -v u="$1" '$1 == u { print $3 }' "${ROOT}/etc/passwd"; }
A_UID="$(uid_of gitlab-runner-alpha)"
A_VOL="    volumes = [\"/run/user/${A_UID}/docker.sock:/var/run/docker.sock\", \"/srv/ci/gitlab-runner-alpha/builds:/srv/ci/gitlab-runner-alpha/builds\", \"/srv/ci/gitlab-runner-alpha/cache:/cache\"]"
eq "runner alpha: every ci entry mounts alpha's own docker socket, same-path builds dir and cache" "$(grep -cxF -- "${A_VOL}" "${CFG}")" "2"
eq "runner alpha: every ci entry sets builds_dir to alpha's builds dir" \
  "$(grep -cxF '  builds_dir = "/srv/ci/gitlab-runner-alpha/builds"' "${CFG}")" "2"
eq "runner alpha: every ci entry keeps the database service's data dir in tmpfs" \
  "$(grep -cxF '    "/var/lib/postgresql/data" = "rw,size=2g"' "${CFG}")" "2"
eq "runner alpha: no entry is privileged" "$(grep -c 'privileged = true' "${CFG}")" "0"
eq "runner alpha: every ci entry has the ci security_opt (DND-1999)" "$(grep -cxF -- "${SO_CI}" "${CFG}")" "2"
eq "runner alpha: no other security_opt line" "$(grep -c 'security_opt' "${CFG}")" "2"
eq "runner alpha: the instance is a symlink to the base initd" "$(readlink "${ROOT}/etc/init.d/gitlab-runner.alpha")" "gitlab-runner"
check "runner alpha: conf.d names the config" \
  grep -qx 'RUNNER_CONFIG="/home/gitlab-runner-alpha/.gitlab-runner/config.toml"' "${ROOT}/etc/conf.d/gitlab-runner.alpha"
check "runner alpha: the config is written as the user, not by root" grep -q '^runuser -u gitlab-runner-alpha -- sh -c' "${ARGV_LOG}"
if grep -q '^rc-service .* start' "${ARGV_LOG}"; then bad "runner alpha: the service is not started"; else ok "runner alpha: the service is not started"; fi

cfg_before="$(cat "${CFG}")"
kit setup-gitlab-runner --user gitlab-runner-alpha --runner alpha-ci:ci --runner alpha-ci2:ci:2 "${NOIN}"
expect_rc "runner alpha: a re-run with the entries present reads no token" 0
eq "runner alpha: a re-run leaves the config unchanged" "$(cat "${CFG}")" "${cfg_before}"
case "${ERR}" in *"predates the runner contract"*) bad "runner alpha: kept entries with the contract raise no warning" "${ERR}" ;;
  *) ok "runner alpha: kept entries with the contract raise no warning" ;; esac
case "${ERR}" in *security_opt*) bad "runner alpha: kept entries with the role's security_opt raise no warning" "${ERR}" ;;
  *) ok "runner alpha: kept entries with the role's security_opt raise no warning" ;; esac
# A kept ci entry written before DND-1973 (no builds_dir) is named, never kept silently.
F_CFG_DIR="${ROOT}/home/gitlab-runner-foxtrot/.gitlab-runner"; mkdir -p "${F_CFG_DIR}"
printf 'concurrent = 1\n\n[[runners]]\n  name = "foxtrot-ci"\n  # tags = ["ci"], run_untagged = false: set on the runner\n  executor = "docker"\n  [runners.docker]\n    volumes = ["/srv/ci/gitlab-runner-foxtrot/cache:/cache"]\n' > "${F_CFG_DIR}/config.toml"
legacy_before="$(cat "${F_CFG_DIR}/config.toml")"
kit setup-gitlab-runner --user gitlab-runner-foxtrot --runner foxtrot-ci:ci "${NOIN}"
expect_rc "runner foxtrot: a re-run over a pre-contract entry still succeeds (it reads no token)" 0
case "${ERR}" in *foxtrot-ci*"predates the runner contract"*Fix:*) ok "runner foxtrot: the pre-contract entry is named, with Fix:" ;;
  *) bad "runner foxtrot: the pre-contract entry is named, with Fix:" "${ERR}" ;; esac
eq "runner foxtrot: the kept entry is left as is" "$(cat "${F_CFG_DIR}/config.toml")" "${legacy_before}"
case "${ERR}" in *foxtrot-ci*security_opt*"seccomp:unconfined"*Fix:*) ok "runner foxtrot: a kept ci entry with no security_opt is named, with the role's value and Fix:" ;;
  *) bad "runner foxtrot: a kept ci entry with no security_opt is named, with the role's value and Fix:" "${ERR}" ;; esac

printf '%s\n' "${TOK_C}" > "${TMP}/tokens-c"
kit setup-gitlab-runner --user gitlab-runner-alpha --runner alpha-ci:ci --runner alpha-ci3:ci "${TMP}/tokens-c"
expect_rc "runner alpha: a new entry is appended, reading only its token" 0
eq "runner alpha: three entries after the append" "$(grep -c '^\[\[runners\]\]$' "${CFG}")" "3"
check "runner alpha: the appended entry has the new token" grep -qxF "  token = \"${TOK_C}\"" "${CFG}"
eq "runner alpha: the config stays 0600 after the append" "$(mode_of "${CFG}")" "600"

# One trust role per runner user: a deploy runner never joins a ci user's config.
before="$(snapshot)"
kit setup-gitlab-runner --user gitlab-runner-alpha --runner alpha-deploy:deploy "${TMP}/tokens-c"
expect_rc "runner alpha: a deploy entry in a ci user's config is refused" 1
case "${ERR}" in *"one trust role"*Fix:*"--user gitlab-runner-alpha-deploy"*) ok "the role refusal's Fix: names a separate deploy user" ;;
  *) bad "the role refusal's Fix: names a separate deploy user" "${ERR}" ;; esac
eq "runner alpha: the role refusal changes no file" "$(snapshot)" "${before}"
kit setup-gitlab-runner --user gitlab-runner-bravo --runner bravo-ci:ci --runner bravo-deploy:deploy "${TMP}/tokens-ab"
expect_rc "runner bravo: ci and deploy in one call for one user is refused" 1
eq "runner bravo: that refusal changes no file" "$(snapshot)" "${before}"
# The deploy runner as its own user: its own config, its own dockerd service.
kit setup-gitlab-runner --user gitlab-runner-charlie --runner charlie-deploy:deploy "${TMP}/tokens-c"
expect_rc "runner charlie: a deploy runner under its own user succeeds" 0
check "runner charlie: its config holds the deploy entry" \
  grep -qF 'tags = ["deploy"], run_untagged = false' "${ROOT}/home/gitlab-runner-charlie/.gitlab-runner/config.toml"
if grep -qF 'deploy' "${CFG}"; then bad "runner alpha: the ci user's config holds no deploy entry"; else ok "runner alpha: the ci user's config holds no deploy entry"; fi
D_CFG="${ROOT}/home/gitlab-runner-charlie/.gitlab-runner/config.toml"
C_UID="$(uid_of gitlab-runner-charlie)"
check "runner charlie: the deploy entry mounts charlie's OWN socket, builds dir and cache" \
  grep -qxF "    volumes = [\"/run/user/${C_UID}/docker.sock:/var/run/docker.sock\", \"/srv/ci/gitlab-runner-charlie/builds:/srv/ci/gitlab-runner-charlie/builds\", \"/srv/ci/gitlab-runner-charlie/cache:/cache\"]" "${D_CFG}"
check "runner charlie: the deploy entry's builds_dir is charlie's" grep -qxF '  builds_dir = "/srv/ci/gitlab-runner-charlie/builds"' "${D_CFG}"
if [ "${C_UID}" != "${A_UID}" ] && ! grep -qF -e "/run/user/${A_UID}/" -e "gitlab-runner-alpha" "${D_CFG}"; then
  ok "runner charlie: the deploy config names nothing of the ci user's (socket, builds dir, cache)"
else bad "runner charlie: the deploy config names nothing of the ci user's (socket, builds dir, cache)" "$(cat "${D_CFG}")"; fi
if grep -qF 'services_tmpfs' "${D_CFG}"; then bad "runner charlie: the deploy entry has no services tmpfs"; else ok "runner charlie: the deploy entry has no services tmpfs"; fi
eq "runner charlie: the deploy entry is not privileged" "$(grep -cx '    privileged = false' "${D_CFG}")" "1"
if grep -qF -e 'security_opt' -e 'unconfined' "${D_CFG}"; then bad "runner charlie: the deploy entry has no security_opt and nothing unconfined (DND-1999)" "$(cat "${D_CFG}")"
else ok "runner charlie: the deploy entry has no security_opt and nothing unconfined (DND-1999)"; fi
kit setup-gitlab-runner --user gitlab-runner-charlie --runner charlie-deploy:deploy "${NOIN}"
expect_rc "runner charlie: a re-run keeps the deploy entry" 0
case "${ERR}" in *security_opt*) bad "runner charlie: a kept deploy entry with no security_opt raises no warning" "${ERR}" ;;
  *) ok "runner charlie: a kept deploy entry with no security_opt raises no warning" ;; esac
# A kept deploy entry written before DND-1999 still carries the old unconfined
# pair. The re-run keeps it (it reads no token) but names it, with Fix:.
kit setup-gitlab-runner-user --user gitlab-runner-golf "${NOIN}"; expect_rc "user golf: succeeds" 0
G_CFG_DIR="${ROOT}/home/gitlab-runner-golf/.gitlab-runner"; mkdir -p "${G_CFG_DIR}"
sed -e 's/charlie/golf/g' -e 's/^  \[runners.docker\]$/&\n    security_opt = ["seccomp:unconfined", "apparmor:unconfined"]/' "${D_CFG}" > "${G_CFG_DIR}/config.toml"
old_deploy_before="$(cat "${G_CFG_DIR}/config.toml")"
kit setup-gitlab-runner --user gitlab-runner-golf --runner golf-deploy:deploy "${NOIN}"
expect_rc "runner golf: a re-run over a pre-DND-1999 deploy entry succeeds (it reads no token)" 0
case "${ERR}" in *golf-deploy*security_opt*seccomp:unconfined*Fix:*"delete its [runners.docker] security_opt line"*) ok "runner golf: the kept deploy entry's unconfined security_opt is named, with Fix:" ;;
  *) bad "runner golf: the kept deploy entry's unconfined security_opt is named, with Fix:" "${ERR}" ;; esac
eq "runner golf: the kept entry is left as is" "$(cat "${G_CFG_DIR}/config.toml")" "${old_deploy_before}"
# A ci or deploy entry needs the user's builds dir (setup-gitlab-runner-user
# makes it); without it the job's bind mount would fail at run time.
kit setup-gitlab-runner-user --user gitlab-runner-india "${NOIN}"; expect_rc "user india: succeeds" 0
rmdir "${ROOT}/srv/ci/gitlab-runner-india/builds"
before="$(snapshot)"
kit setup-gitlab-runner --user gitlab-runner-india --runner india-ci:ci "${TMP}/tokens-c"
expect_rc "runner india: a ci entry with no builds dir is refused" 1
case "${ERR}" in *builds*Fix:*setup-gitlab-runner-user*) ok "the missing-builds-dir refusal's Fix: names setup-gitlab-runner-user" ;;
  *) bad "the missing-builds-dir refusal's Fix: names setup-gitlab-runner-user" "${ERR}" ;; esac
eq "runner india: that refusal changes no file" "$(snapshot)" "${before}"
# A malformed uid in passwd is refused, never written as an empty socket path.
sed -i 's/^\(gitlab-runner-india:x:\)[0-9]*:/\1notanumber:/' "${ROOT}/etc/passwd"
install -d -m 0711 "${ROOT}/srv/ci/gitlab-runner-india/builds"
before="$(snapshot)"
kit setup-gitlab-runner --user gitlab-runner-india --runner india-ci:ci "${TMP}/tokens-c"
expect_rc "runner india: a non-numeric uid is refused" 1
case "${ERR}" in *uid*Fix:*) ok "the bad-uid refusal carries Fix:" ;; *) bad "the bad-uid refusal carries Fix:" "${ERR}" ;; esac
eq "runner india: the bad-uid refusal changes no file" "$(snapshot)" "${before}"
# An entry whose role this kit cannot tell (register wrote it) blocks additions.
printf '[[runners]]\n  name = "legacy"\n' > "${TMP}/legacy-cfg"
mkdir -p "${ROOT}/home/gitlab-runner-delta/.gitlab-runner"
cp "${TMP}/legacy-cfg" "${ROOT}/home/gitlab-runner-delta/.gitlab-runner/config.toml"
kit setup-gitlab-runner --user gitlab-runner-delta --runner delta-ci:ci "${TMP}/tokens-c"
expect_rc "runner delta: adding to a config with an untold role is refused" 1
case "${ERR}" in *"cannot tell"*Fix:*) ok "the untold-role refusal carries Fix:" ;; *) bad "the untold-role refusal carries Fix:" "${ERR}" ;; esac

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

# A config.toml symlink planted by the user is replaced, never written through.
mkdir -p "${ROOT}/home/gitlab-runner-bravo/.gitlab-runner"
printf 'sentinel\n' > "${TMP}/link-target"
ln -s "${TMP}/link-target" "${ROOT}/home/gitlab-runner-bravo/.gitlab-runner/config.toml"
kit setup-gitlab-runner --user gitlab-runner-bravo --runner bravo-ci:ci "${TMP}/tokens-c"
expect_rc "runner bravo: a symlinked config.toml is replaced by a regular file" 0
eq "runner bravo: the symlink's target is untouched" "$(cat "${TMP}/link-target")" "sentinel"
if [ -L "${ROOT}/home/gitlab-runner-bravo/.gitlab-runner/config.toml" ]; then bad "runner bravo: config.toml is no longer a symlink"
else ok "runner bravo: config.toml is no longer a symlink"; fi
check "runner bravo: the config is written as the user (runuser)" grep -q '^runuser -u gitlab-runner-bravo -- sh -c' "${ARGV_LOG}"

# A kept runner conf.d that names another user is refused.
printf 'RUNNER_USER="gitlab-runner"\n' > "${ROOT}/etc/conf.d/gitlab-runner.bravo"
kit setup-gitlab-runner --user gitlab-runner-bravo --runner bravo-ci:ci "${NOIN}"
expect_rc "runner bravo: a kept conf.d naming another user is refused" 1
rm -f "${ROOT}/etc/conf.d/gitlab-runner.bravo"

# --- a token never reaches argv or any output --------------------------------
leaked=""
for t in "${ALL_TOK[@]}"; do
  # The deliberately refused argv case above put TOK_A in the script's own argv;
  # every OTHER process's argv is in the log, and must not hold any token.
  if grep -qF -- "${t}" "${ARGV_LOG}"; then leaked="${leaked} argv-log"; fi
done
for t in "${TOK_A}" "${TOK_B}" "${TOK_C}"; do
  # A tail alone is a leak too (DND-1982: a redaction that stops at '.').
  if grep -qF -- "$(tok_tail "${t}")" "${ARGV_LOG}"; then leaked="${leaked} argv-log-tail"; fi
done
[ -z "${leaked}" ] && ok "no token reached any spawned command's argv" || bad "no token reached any spawned command's argv" "${leaked}"
transcript_hits=0
while IFS= read -r line; do
  for t in "${ALL_TOK[@]}"; do
    case "${line}" in *"${t}"*) transcript_hits=$((transcript_hits + 1)) ;; esac
  done
  for t in "${TOK_A}" "${TOK_B}" "${TOK_C}"; do
    case "${line}" in *"$(tok_tail "${t}")"*) transcript_hits=$((transcript_hits + 1)) ;; esac
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

# OpenRC sources the base conf.d, then the instance's, then the initd. An
# instance that inherits another user from the base conf.d refuses to start.
instance_guard() { # <initd> <RC_SVCNAME> <base conf text> <instance conf text>
  printf '%s\n' "$3" > "${TMP}/base.conf"; printf '%s\n' "$4" > "${TMP}/inst.conf"
  env -i PATH=/usr/bin:/bin RC_SVCNAME="$2" sh -c '
    eerror() { printf "%s\n" "$*"; }
    . "$1"; . "$2"; . "$3" >/dev/null 2>&1
    _instance_guard' sh "${TMP}/base.conf" "${TMP}/inst.conf" "${SRC}/system-files/$1.initd"
}
out="$(instance_guard gitlab-runner gitlab-runner.alpha 'RUNNER_USER="gitlab-runner"
RUNNER_HOME="/home/gitlab-runner"
RUNNER_CONFIG="/home/gitlab-runner/.gitlab-runner/config.toml"' '')"; rc=$?
eq "initd: an instance inheriting the base conf.d's user refuses to start" "${rc}" "1"
case "${out}" in *"Fix: set RUNNER_USER=\"gitlab-runner-alpha\""*) ok "initd: the refusal's Fix: names the instance's own user" ;; *) bad "initd: the refusal's Fix: names the instance's own user" "${out}" ;; esac
instance_guard gitlab-runner gitlab-runner.alpha 'RUNNER_USER="gitlab-runner"' \
  "$(grk_render_runner_confd gitlab-runner-alpha /home/gitlab-runner-alpha)" >/dev/null
eq "initd: an instance with its own rendered conf.d starts" "$?" "0"
instance_guard gitlab-runner gitlab-runner.alpha "$(grk_render_runner_confd gitlab-runner /home/gitlab-runner)" '' >/dev/null
eq "initd: an instance under the kit's default base conf.d starts (it derives its user)" "$?" "0"
instance_guard gitlab-runner gitlab-runner 'RUNNER_USER="gitlab-runner"' '' >/dev/null
eq "initd: the default service is not an instance and is not guarded" "$?" "0"
out="$(instance_guard docker-rootless-gitlab-runner docker-rootless-gitlab-runner.alpha 'DOCKER_ROOTLESS_USER="gitlab-runner"' '')"; rc=$?
eq "initd: a docker instance inheriting the base user refuses to start" "${rc}" "1"
instance_guard docker-rootless-gitlab-runner docker-rootless-gitlab-runner.alpha \
  "$(grk_render_docker_confd gitlab-runner)" '' >/dev/null; rc=$?
eq "initd: a docker instance inheriting the default user's data root refuses to start" "${rc}" "1"
instance_guard docker-rootless-gitlab-runner docker-rootless-gitlab-runner.alpha \
  "$(grk_render_docker_confd gitlab-runner)" "$(grk_render_docker_confd gitlab-runner-alpha)" >/dev/null
eq "initd: a docker instance with its own rendered conf.d starts" "$?" "0"

echo "gitlab-runner-kit self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
