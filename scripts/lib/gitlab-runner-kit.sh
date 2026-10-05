# shellcheck shell=bash
#
# gitlab-runner-kit.sh — the pure rules of the self-hosted GitLab runner kit
# (DND-1937): N named runner users per host, one per trust domain.
#
# Sourced by scripts/setup-gitlab-runner{-user,-docker,}. Every function here is
# side-effect free: it reads only its arguments (and, for the subid scan, the
# file it is handed), and it writes only stdout/stderr. The setup scripts hold
# every side effect (useradd, install, rc-update, file writes).
#
# A refusal prints the problem and a `Fix:` line on stderr and returns non-zero.
#
# Naming. A runner user is `gitlab-runner` (the default, the original DND-177
# install) or `gitlab-runner-<suffix>`. Its services are OpenRC multiplexed
# instances of the two committed initd scripts:
#
#   user                   runner service           rootless docker service
#   gitlab-runner          gitlab-runner            docker-rootless-gitlab-runner
#   gitlab-runner-<sfx>    gitlab-runner.<sfx>      docker-rootless-gitlab-runner.<sfx>
#
# Subordinate ids. The default user keeps the DND-177 block 296608:65536. Any
# other user gets a deterministic 65536-id block: slot = (POSIX `cksum` CRC of
# the name, not zlib's CRC32) mod 4096,
# start = 1000000000 + slot * 65536. The region sits above shadow's default
# SUB_UID_MAX (600100000), so `useradd` never auto-allocates into it, and the
# same name maps to the same block on every host. Two names can share a slot;
# the setup script then refuses on the overlap (grk_subid_conflicts) and the
# owner passes --subid-start.

GRK_DEFAULT_USER="gitlab-runner"
GRK_DEFAULT_SUBID_START=296608
GRK_SUBID_COUNT=65536
GRK_SUBID_BASE=1000000000
GRK_SUBID_SLOTS=4096
GRK_SUBID_MIN=100000
GRK_SUBID_MAX=4294901759 # 2^32 - 1 - 65536: the last start a full block fits under
# The rootless dockerd's socket dir, as the initd files default it: the socket
# is <dir>/<uid>/docker.sock. The kit writes this default only. An install that
# overrides ATHENA_INITD_RUN_USER_DIR in a conf.d must edit the socket path in
# its ci/deploy entries' volumes by hand.
GRK_RUN_USER_DIR="/run/user"
# The database service's data dir a ci entry keeps in memory (DND-1973).
GRK_DB_TMPFS_PATH="/var/lib/postgresql/data"
GRK_DB_TMPFS_OPTS="rw,size=2g"

grk_refuse() { # <problem> <fix>
  printf '%s\n' "$(grk_redact "$1")" >&2
  printf 'Fix: %s\n' "$(grk_redact "$2")" >&2
  return 1
}

# grk_redact TEXT -> TEXT with every glrt- token replaced, so a token pasted
# into the wrong flag is never echoed back by a refusal. A token is the whole
# run of token characters, '.' included (GitLab's routable tokens are
# dot-segmented, DND-1982), ending on a non-'.': a '.' with no token character
# after it is a sentence's period, and stays (ai/contracts/
# athena-machine-secrets.md -> Credential patterns).
grk_redact() {
  local s="${1-}"
  while [[ "${s}" =~ glrt-[A-Za-z0-9_.-]*[A-Za-z0-9_-] ]]; do
    s="${s/"${BASH_REMATCH[0]}"/glrt-<not shown>}"
  done
  printf '%s' "${s}"
}

# grk_validate_user NAME -> 0, or a refusal.
grk_validate_user() {
  local name="${1-}"
  [ "${name}" = "${GRK_DEFAULT_USER}" ] && return 0
  if [ "${#name}" -gt 32 ]; then
    grk_refuse "runner user '${name}' is longer than 32 characters (the useradd limit)" \
      "pick a shorter suffix: --user gitlab-runner-<suffix>, <= 32 characters in all"
    return 1
  fi
  if [[ ! "${name}" =~ ^gitlab-runner-[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    grk_refuse "runner user '${name}' is not gitlab-runner or gitlab-runner-<suffix> (suffix: lowercase letters, digits, single dashes)" \
      "pass --user gitlab-runner (the default) or --user gitlab-runner-<suffix>, e.g. --user gitlab-runner-personal"
    return 1
  fi
}

# grk_suffix NAME -> "" for the default user, else the part after gitlab-runner-.
grk_suffix() {
  if [ "$1" = "${GRK_DEFAULT_USER}" ]; then printf '\n'; else printf '%s\n' "${1#gitlab-runner-}"; fi
}

# grk_runner_service NAME -> the OpenRC service that runs `gitlab-runner run`.
grk_runner_service() {
  local sfx; sfx="$(grk_suffix "$1")"
  if [ -z "${sfx}" ]; then printf 'gitlab-runner\n'; else printf 'gitlab-runner.%s\n' "${sfx}"; fi
}

# grk_docker_service NAME -> the OpenRC service that runs the user's rootless dockerd.
grk_docker_service() {
  printf 'docker-rootless-%s\n' "$(grk_runner_service "$1")"
}

# grk_ci_dir NAME -> the user's CI data root (docker data root + job cache).
grk_ci_dir() { printf '/srv/ci/%s\n' "$1"; }

# grk_builds_dir NAME -> the user's job builds dir: builds_dir for a ci or
# deploy entry, bind-mounted into the job at the same path (DND-1973).
grk_builds_dir() { printf '%s/builds\n' "$(grk_ci_dir "$1")"; }

# grk_docker_socket UID -> the rootless dockerd socket of the user with UID, or
# a refusal. A uid that is empty, 0 or not a number is an error, never an empty
# or root path in a volume mount.
grk_docker_socket() {
  if [[ ! "${1-}" =~ ^[1-9][0-9]{0,9}$ ]] || [ "$1" -gt 4294967294 ]; then
    grk_refuse "runner uid '${1-}' is not a non-root numeric uid, so its docker socket path cannot be named" \
      "check the runner user's /etc/passwd line (getent passwd <user>): its third field must be its numeric uid, not 0"
    return 1
  fi
  printf '%s/%s/docker.sock\n' "${GRK_RUN_USER_DIR}" "$1"
}

# The runner contract per role (DND-1973). The role is the entry's one tag.
#   ci, deploy  the job gets its OWN user's rootless docker socket at
#               /var/run/docker.sock and that user's builds dir as builds_dir,
#               bind-mounted at the same path, so a container the job starts on
#               that daemon can mount the job's checkout.
#   ci          also keeps the database service's data dir in tmpfs
#               (services_tmpfs cannot be set from .gitlab-ci.yml).
#   any other   (untagged, or another tag): only the cache volume; no socket,
#               no builds_dir.
# privileged stays false for every role.
grk_role_gets_docker() { [ "${1-}" = "ci" ] || [ "${1-}" = "deploy" ]; }
grk_role_gets_db_tmpfs() { [ "${1-}" = "ci" ]; }

# grk_role_security_opt ROLE -> the [runners.docker] security_opt value of
# ROLE, or nothing for "write no security_opt" (DND-1999). Deny by default:
# only a role named here is loosened from Docker's defaults.
#   ci          seccomp and AppArmor unconfined (the live runner's pair).
#               tool-sandbox runs bwrap --unshare-all ... in ci jobs: Docker's
#               default seccomp refuses the user namespace. /proc stays masked
#               in the job container; the gate runs in a sibling container with
#               an unmasked /proc instead (DND-2085, .gitlab-ci.yml). Every value must be API-valid: systempaths=unconfined
#               is a docker CLI flag the Engine API rejects ("invalid
#               --security-opt 2"), and it stopped every ci job (DND-2039).
#               Residual: seccomp:unconfined lifts Docker's whole
#               default filter for ci job code (user namespaces and /proc
#               mounts inside the job container, and also keyctl, bpf,
#               perf_event_open, userfaultfd, ...). Accepted because the ci
#               user holds no deploy secret, and host-only /proc stays refused
#               (the job's root is the runner user's subuid on the host). A
#               narrow profile (default + the calls bwrap needs) is DND-2005.
#               Where AppArmor is not loaded the entry is a no-op; it keeps
#               bwrap's mounts working on a host where it is.
#   deploy      none: Docker's default seccomp and masked /proc. Deploy jobs
#               only drive the mounted daemon socket (docker build; buildx's
#               buildkitd is a sibling container the daemon starts).
#   - (untagged) seccomp and AppArmor unconfined: rootless BuildKit as a job
#               image (moby/buildkit:rootless) nests a user namespace
#               (system-files/gitlab-runner-runbook.md). /proc stays masked.
#   any other   none: the kit knows no need for it.
GRK_SECURITY_OPT_CI='["seccomp:unconfined", "apparmor:unconfined"]'
GRK_SECURITY_OPT_UNTAGGED='["seccomp:unconfined", "apparmor:unconfined"]'
grk_role_security_opt() {
  case "${1-}" in
    ci) printf '%s\n' "${GRK_SECURITY_OPT_CI}" ;;
    -)  printf '%s\n' "${GRK_SECURITY_OPT_UNTAGGED}" ;;
    *)  printf '\n' ;;
  esac
}

# grk_config_entry_security_opt NAME < CONFIG -> the security_opt value of the
# [[runners]] entry named NAME, all whitespace removed; nothing when it sets
# none. A # comment line, or a # comment after the value, is not a setting.
# Exit 1 when no entry is named NAME, so a missing entry never reads as "sets
# none". It reads one line: a hand-written multi-line array reads as "[" and
# so never matches a role. That false warning is loud and safe; do not loosen
# the comparison to silence it.
grk_config_entry_security_opt() {
  awk -v want="$1" '
    /^[[:space:]]*\[\[runners\]\]/ { cur = ""; next }
    /^[[:space:]]*name[[:space:]]*=/ { s = $0; sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); cur = s; if (cur == want) seen = 1; next }
    cur == want && /^[[:space:]]*security_opt[[:space:]]*=/ { s = $0; sub(/^[^=]*=/, "", s); sub(/#[^"]*$/, "", s); gsub(/[[:space:]]/, "", s); print s; exit }
    END { exit seen ? 0 : 1 }'
}

# grk_security_opt_matches ROLE NAME < CONFIG -> 0 when entry NAME's
# security_opt is ROLE's (whitespace aside), both "none" included.
grk_security_opt_matches() {
  local got want
  got="$(grk_config_entry_security_opt "$2")" || return 1
  want="$(grk_role_security_opt "$1")"
  [ "${got}" = "${want//[[:space:]]/}" ]
}

# grk_config_entry_has_builds_dir NAME < CONFIG -> 0 when the [[runners]] entry
# named NAME in the config text on stdin sets builds_dir. A ci or deploy entry
# without it predates the runner contract (DND-1973).
grk_config_entry_has_builds_dir() {
  awk -v want="$1" '
    /^[[:space:]]*\[\[runners\]\]/ { cur = ""; next }
    /^[[:space:]]*name[[:space:]]*=/ { s = $0; sub(/^[^"]*"/, "", s); sub(/".*$/, "", s); cur = s; next }
    cur == want && /^[[:space:]]*builds_dir[[:space:]]*=/ { found = 1 }
    END { exit found ? 0 : 1 }'
}

# grk_subid_start NAME -> the deterministic first subordinate id of NAME's block.
grk_subid_start() {
  local crc
  if [ "$1" = "${GRK_DEFAULT_USER}" ]; then printf '%s\n' "${GRK_DEFAULT_SUBID_START}"; return 0; fi
  crc="$(printf '%s' "$1" | cksum)" || return 1
  crc="${crc%% *}"
  printf '%s\n' "$(( GRK_SUBID_BASE + (crc % GRK_SUBID_SLOTS) * GRK_SUBID_COUNT ))"
}

# grk_validate_subid_start N -> 0, or a refusal.
grk_validate_subid_start() {
  if [[ ! "${1-}" =~ ^[0-9]{1,10}$ ]] || [ "$1" -lt "${GRK_SUBID_MIN}" ] || [ "$1" -gt "${GRK_SUBID_MAX}" ]; then
    grk_refuse "--subid-start '${1-}' is not a whole number in ${GRK_SUBID_MIN}..${GRK_SUBID_MAX}" \
      "pass --subid-start <N> with N a free block start, e.g. a multiple of 65536 that no /etc/subuid or /etc/subgid line covers"
    return 1
  fi
}

# grk_subid_entry FILE NAME -> NAME's existing "start:count" in FILE, or nothing.
# A missing FILE has no entries.
grk_subid_entry() {
  [ -e "$1" ] || return 0
  awk -F: -v u="$2" '$1 == u { print $2 ":" $3; exit }' "$1"
}

# grk_subid_conflicts FILE NAME START COUNT
#   exit 0: no other entry in FILE overlaps [START, START+COUNT)
#   exit 1: overlap; each overlapping line is printed on stdout
#   exit 2: FILE has a line that is not owner:start:count; refused with Fix:
# NAME's own lines are skipped. A missing FILE has no entries (exit 0). Blank
# lines and # comments are skipped.
grk_subid_conflicts() {
  local file="$1" name="$2" start="$3" count="$4" out rc
  [ -e "${file}" ] || return 0
  out="$(awk -F: -v u="${name}" -v s="${start}" -v c="${count}" '
    /^[[:space:]]*(#|$)/ { next }
    NF != 3 || $1 == "" || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $3 == 0 { bad = bad NR " "; next }
    $1 == u { next }
    ($2 + 0) < (s + c) && (s + 0) < ($2 + $3) { print }
    END { if (bad != "") { print "MALFORMED " bad; exit 2 } }
  ' "${file}")"; rc=$?
  if [ "${rc}" -eq 2 ]; then
    grk_refuse "${file} has line(s) that are not owner:start:count (line ${out##*MALFORMED }), so overlap cannot be judged" \
      "repair those lines of ${file} by hand (each line is <user>:<first id>:<count>), then re-run"
    return 2
  fi
  if [ "${rc}" -ne 0 ]; then
    grk_refuse "awk could not scan ${file} (exit ${rc}), so overlap cannot be judged" \
      "check that ${file} is readable and awk is installed, then re-run"
    return 2
  fi
  if [ -n "${out}" ]; then printf '%s\n' "${out}"; return 1; fi
  return 0
}

# grk_parse_runner SPEC -> "NAME TAG LIMIT" for SPEC = NAME:TAG[:LIMIT], or a refusal.
grk_parse_runner() {
  local spec="${1-}" name tag limit rest
  name="${spec%%:*}"; rest="${spec#*:}"
  if [ "${rest}" = "${spec}" ]; then
    grk_refuse "--runner '${spec}' has no tag" "pass --runner NAME:TAG[:LIMIT], e.g. --runner personal-ci:ci or --runner personal-deploy:deploy:1"
    return 1
  fi
  tag="${rest%%:*}"
  if [ "${tag}" = "${rest}" ]; then limit=1; else limit="${rest#*:}"; fi
  if [[ ! "${name}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    grk_refuse "--runner name '${name}' is not lowercase letters, digits and dashes (1-63 chars)" \
      "pass --runner NAME:TAG[:LIMIT] with NAME like personal-ci"
    return 1
  fi
  if [ "${tag}" != "-" ] && [[ ! "${tag}" =~ ^[a-z0-9][a-z0-9_.-]{0,62}$ ]]; then
    grk_refuse "--runner '${name}' tag '${tag}' is not one lowercase tag" \
      "pass exactly one tag per runner: --runner ${name}:<tag>, e.g. ci or deploy (or - for an untagged runner)"
    return 1
  fi
  if [[ ! "${limit}" =~ ^[1-9][0-9]{0,2}$ ]]; then
    grk_refuse "--runner '${name}' limit '${limit}' is not a whole number from 1 to 999" \
      "pass --runner ${name}:${tag}:<N> with N >= 1, or omit :<N> for 1"
    return 1
  fi
  printf '%s %s %s\n' "${name}" "${tag}" "${limit}"
}

# grk_valid_token TOKEN -> 0 when TOKEN is a runner authentication token shape:
# glrt- then at least 20 characters of non-empty [A-Za-z0-9_-] segments joined
# by single '.'s. GitLab's routable tokens are dot-segmented
# (glrt-t<n>_<payload>.<version>.<crc>, DND-1982); an undotted token is the
# older shape, still accepted. Never prints the token, whatever the outcome.
grk_valid_token() {
  local t="${1-}"
  [ "${#t}" -ge 25 ] && [[ "${t}" =~ ^glrt-[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$ ]]
}

# grk_valid_url URL -> 0 when URL is an https origin (no path, no credentials).
grk_valid_url() {
  [[ "${1-}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]]
}

# grk_config_has_runner NAME < CONFIG -> 0 when the config text on stdin already
# holds a [[runners]] entry named NAME (the line grk_render_runner writes, or
# register's). It reads stdin, so the caller decides who reads the file.
grk_config_has_runner() {
  grep -Eq "^[[:space:]]*name[[:space:]]*=[[:space:]]*\"$1\"[[:space:]]*$"
}

# grk_config_roles < CONFIG -> one line per [[runners]] entry: its tag, "-" when
# untagged, or "?" when the entry has no role comment (gitlab-runner register
# wrote it). The role comment is the one grk_render_runner writes.
grk_config_roles() {
  awk '
    /^[[:space:]]*\[\[runners\]\]/ { if (n) print (r == "" ? "?" : r); n = 1; r = ""; next }
    n && /^[[:space:]]*# tags = \["/ { s = $0; sub(/.*# tags = \["/, "", s); sub(/"\].*/, "", s); r = s; next }
    n && /^[[:space:]]*# untagged:/ { r = "-"; next }
    END { if (n) print (r == "" ? "?" : r) }'
}

# grk_one_role USER ROLE... -> 0 when every ROLE is the same known role, else a
# refusal. One runner user holds ONE trust role (DND-1937): a ci job's code
# reaches its user's docker socket, builds dir and cache, so a deploy runner
# sharing that user would hand MR code the deploy job's OIDC token and checkout.
grk_one_role() {
  local user="$1" first="" r; shift
  for r in "$@"; do
    if [ "${r}" = "?" ]; then
      grk_refuse "${user}'s config.toml has a [[runners]] entry whose tag this kit cannot tell (no role comment), so adding runners could mix trust roles" \
        "add these runners under a new user (--user gitlab-runner-<suffix>), or give the existing entry its role comment by hand"
      return 1
    fi
    [ -n "${first}" ] || first="${r}"
    if [ "${r}" != "${first}" ]; then
      local sfx="${r//[^a-z0-9]/}"; [ -n "${sfx}" ] || sfx="untagged"
      grk_refuse "runner user ${user} would hold runners tagged '${first}' and '${r}': one runner user holds one trust role" \
        "give each role its own user, e.g. --user ${user} for '${first}' and --user ${user}-${sfx} for '${r}' (each gets its own dockerd, cache and 0700 home)"
      return 1
    fi
  done
}

# grk_render_header CONCURRENT -> the top of a new config.toml.
grk_render_header() {
  printf '# Written by scripts/setup-gitlab-runner (DND-1937). Holds glrt- runner\n'
  printf '# authentication tokens: mode 0600, owned by the runner user, never committed.\n'
  printf '# Non-secret reference shape: system-files/gitlab-runner-config.toml.example.\n'
  printf 'concurrent = %s\n' "$1"
  printf 'check_interval = 0\n'
}

# grk_render_runner NAME TAG LIMIT URL CI_DIR TOKEN [SOCKET] -> one [[runners]]
# entry. SOCKET (the user's grk_docker_socket) is required for a ci or deploy
# entry: one without it is refused, never written with no daemon. The token
# reaches only stdout, through the printf builtin: no argv.
grk_render_runner() {
  local docker=false builds="$5/builds" secopt
  secopt="$(grk_role_security_opt "$2")"
  if grk_role_gets_docker "$2"; then
    docker=true
    if [[ "${7-}" != /*/docker.sock ]]; then
      grk_refuse "runner $1 (tag $2) needs its user's docker socket path, got '${7-}'" \
        "pass the socket from grk_docker_socket <uid> as the 7th argument (setup-gitlab-runner does)"
      return 1
    fi
  fi
  printf '\n[[runners]]\n'
  printf '  name = "%s"\n' "$1"
  if [ "$2" = "-" ]; then
    printf '  # untagged: no tags, run_untagged = true, set on the runner in GitLab when it\n'
    printf '  # was created ("Run untagged jobs" ON, tags empty). A runner\n'
  else
    printf '  # tags = ["%s"], run_untagged = false: set on the runner in GitLab when it\n' "$2"
    printf '  # was created (POST user/runners tag_list=%s run_untagged=false). A runner\n' "$2"
  fi
  printf '  # authentication token carries them server-side; config.toml has no field.\n'
  printf '  url = "%s"\n' "$4"
  printf '  token = "%s"\n' "$6"
  printf '  executor = "docker"\n'
  printf '  limit = %s\n' "$3"
  if $docker; then
    printf '  # Role %s (DND-1973): jobs get this user'"'"'s own rootless docker socket\n' "$2"
    printf '  # and its builds dir, at the same path on the host and in the job.\n'
    printf '  builds_dir = "%s"\n' "${builds}"
  fi
  printf '  [runners.docker]\n'
  printf '    image = "alpine:3.20"\n'
  printf '    privileged = false\n'
  # Per role (DND-1999, grk_role_security_opt): none means Docker's defaults.
  if [ -n "${secopt}" ]; then printf '    security_opt = %s\n' "${secopt}"; fi
  if $docker; then
    printf '    volumes = ["%s:/var/run/docker.sock", "%s:%s", "%s/cache:/cache"]\n' "$7" "${builds}" "${builds}" "$5"
  else
    printf '    volumes = ["%s/cache:/cache"]\n' "$5"
  fi
  if grk_role_gets_db_tmpfs "$2"; then
    printf '  [runners.docker.services_tmpfs]\n'
    printf '    "%s" = "%s"\n' "${GRK_DB_TMPFS_PATH}" "${GRK_DB_TMPFS_OPTS}"
  fi
}

# OpenRC sources /etc/conf.d/<base> BEFORE /etc/conf.d/<base>.<suffix> for an
# instance, so anything the default user's (base) conf.d sets is inherited by
# every instance that does not set it again. The base conf.d therefore names no
# user, home or config path: the initd derives those from RC_SVCNAME. An
# instance's conf.d names all of them, and each initd refuses an instance whose
# resolved user is not its own (grk_render_* and *.initd start_pre).

# grk_render_docker_confd NAME -> /etc/conf.d/<docker service> for a new install.
grk_render_docker_confd() {
  printf '# Written by scripts/setup-gitlab-runner-docker (DND-1937) for %s.\n' "$1"
  printf '# The rootless dockerd of this runner user; data root under its own 0700 CI dir.\n'
  if [ "$1" != "${GRK_DEFAULT_USER}" ]; then printf 'DOCKER_ROOTLESS_USER="%s"\n' "$1"; fi
  printf 'DOCKERD_ROOTLESS_OPTS="--data-root %s/docker"\n' "$(grk_ci_dir "$1")"
}

# grk_render_runner_confd NAME HOME -> /etc/conf.d/<runner service> for a new install.
grk_render_runner_confd() {
  printf '# Written by scripts/setup-gitlab-runner (DND-1937) for %s.\n' "$1"
  if [ "$1" = "${GRK_DEFAULT_USER}" ]; then
    printf '# The default user: the initd derives RUNNER_USER, RUNNER_HOME and\n'
    printf '# RUNNER_CONFIG. Setting them here would leak into every instance.\n'
    return 0
  fi
  printf 'RUNNER_USER="%s"\n' "$1"
  printf 'RUNNER_HOME="%s"\n' "$2"
  printf 'RUNNER_CONFIG="%s/.gitlab-runner/config.toml"\n' "$2"
}
