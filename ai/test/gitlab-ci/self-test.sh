#!/usr/bin/env bash
# self-test.sh -- static suite for .gitlab-ci.yml (DND-1946). Discovered by
# harness-gate. Parses the file and asserts the rules the pipeline holds:
# the fork guard leads workflow:rules, MR and branch pipelines do not
# duplicate, every runnable job is tagged, nothing carries credentials, and
# the gate job runs ai/bin/harness-gate with full history. DND-1998 adds the
# CI image: the job runs dockerfiles/ci-harness/setup.sh before the gate and
# links no ~/dev/custom, the Dockerfile builds FROM the job's exact image and
# runs the same setup.sh, and setup.sh pins one apt snapshot, exact package
# versions and a sha256-checked git tarball. Functional only
# (DND-1222): reads those three files, no network, no docker, no timing.
# Each rule has a miss case: a mutated copy of the file must fail the checker.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
CI_FILE="${ROOT}/.gitlab-ci.yml"
DOCKERFILE="${ROOT}/dockerfiles/ci-harness/Dockerfile"
SETUP="${ROOT}/dockerfiles/ci-harness/setup.sh"
CHECK="${HERE}/check.rb"

[ -x /usr/bin/ruby ] || { echo "gitlab-ci self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -f "${CI_FILE}" ] || { echo "gitlab-ci self-test: FAIL -- ${CI_FILE} is missing"; echo "  Fix: restore .gitlab-ci.yml at the repo root (DND-1946)."; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The real file passes.
out="$(/usr/bin/ruby "${CHECK}" "${CI_FILE}" "${DOCKERFILE}" "${SETUP}" 2>&1)"
if [ $? -eq 0 ]; then ok "the committed .gitlab-ci.yml, Dockerfile and setup.sh satisfy every rule"; else bad "the committed .gitlab-ci.yml, Dockerfile and setup.sh satisfy every rule" "${out}"; fi

# The default image paths resolve beside the file: no extra args finds them.
out="$(/usr/bin/ruby "${CHECK}" "${CI_FILE}" 2>&1)"
if [ $? -eq 0 ]; then ok "check.rb finds dockerfiles/ci-harness beside the file"; else bad "check.rb finds dockerfiles/ci-harness beside the file" "${out}"; fi

# mutate_in WHICH NAME EXPECT SED-EXPR: mutate a copy of one of the three
# files (ci, dockerfile, setup); the checker must fail on it, naming EXPECT.
mutate_in() {
  local which="$1" name="$2" expect="$3" expr="$4" out src f
  local y="${CI_FILE}" d="${DOCKERFILE}" s="${SETUP}"
  case "${which}" in
    ci)         src="${CI_FILE}";    y="${TMP}/m.yml";        f="${y}" ;;
    dockerfile) src="${DOCKERFILE}"; d="${TMP}/m.Dockerfile"; f="${d}" ;;
    setup)      src="${SETUP}";      s="${TMP}/m.setup.sh";   f="${s}" ;;
  esac
  sed -e "${expr}" "${src}" > "${f}"
  if cmp -s "${f}" "${src}"; then bad "${name}" "mutation did not change the file"; return; fi
  out="$(/usr/bin/ruby "${CHECK}" "${y}" "${d}" "${s}" 2>&1)"
  if [ $? -ne 0 ] && [[ "${out}" == *"${expect}"* ]]; then ok "${name}"; else bad "${name}" "expected failure naming [${expect}], got: ${out}"; fi
}
mutate() { mutate_in ci "$@"; }

mutate "fork guard removed fails"        "fork guard"      's/CI_MERGE_REQUEST_SOURCE_PROJECT_PATH/CI_SOMETHING_ELSE/g'
mutate "untagged job fails"              "tags"            's/tags: \[ci\]/tags: []/'
mutate "per-host tag fails"              "tags"            's/tags: \[ci\]/tags: [host-a]/'
mutate "id_tokens fails"                 "id_tokens"       's/^  interruptible: true$/  interruptible: true\n  id_tokens: {}/'
mutate "secrets key fails"               "secrets"         's/^  stage: test$/  stage: test\n  secrets: {}/'
mutate "gate not run fails"              "harness-gate"    's#ai/bin/harness-gate$#true#'
mutate "shallow clone fails"             "GIT_DEPTH"       's/GIT_DEPTH: "0"/GIT_DEPTH: "1"/'
mutate "duplicate-pipeline guard removed fails" "CI_OPEN_MERGE_REQUESTS" 's/CI_OPEN_MERGE_REQUESTS/CI_X/'
mutate "job not interruptible fails"     "interruptible"   's/^  interruptible: true$/  interruptible: false/'
mutate "unpinned image fails"            "image"           's/@sha256:[0-9a-f]*//'
mutate "default id_tokens fails"         "id_tokens"       's/^default:$/default:\n  id_tokens: {}/'
mutate "include fails"                   "include"         's/^default:$/include: https:\/\/example.invalid\/x.yml\ndefault:/'
mutate "fork guard operator flipped fails" "fork guard"    's/!= \$CI_PROJECT_PATH/== $CI_PROJECT_PATH/'
mutate "MR rule removed fails"           "merge_request_event" 's/merge_request_event/pipeline_event/'
mutate "branch rule removed fails"       "branch pipeline" "s/^    - if: '\$CI_COMMIT_BRANCH'\$/    - if: '\$CI_COMMIT_TAG'/"
mutate "branch rule never fails"         "must not be"     "s/^    - if: '\$CI_COMMIT_BRANCH'\$/    - if: '\$CI_COMMIT_BRANCH'\n      when: never/"
mutate "origin/main fetch removed fails" "fetch origin/main" 's/git fetch --no-tags origin/git status --no-tags origin/'
mutate "gate echoed not run fails"       "harness-gate"    's#env HOME=/home/ci ai/bin/harness-gate$#echo ai/bin/harness-gate#'
mutate "credential-named variable fails" "credential"      's/GIT_DEPTH: "0"/GIT_DEPTH: "0"\n    DEPLOY_TOKEN: "x"/'

# The pinned CI image (DND-1998).
mutate "setup.sh not run fails"          "setup.sh"        's#^    - dockerfiles/ci-harness/setup.sh$#    - true#'
mutate "setup.sh after the gate fails"   "before ai/bin/harness-gate" 's#^    - dockerfiles/ci-harness/setup.sh$#    - true#; s#^\(    - runuser -u ci -- env HOME=/home/ci ai/bin/harness-gate\)$#\1\n    - dockerfiles/ci-harness/setup.sh#'
mutate "~/dev/custom link fails"         "dev/custom"      's#^    - chown -R ci:ci "$CI_PROJECT_DIR"$#    - chown -R ci:ci "$CI_PROJECT_DIR" \&\& ln -sfn "$CI_PROJECT_DIR" /home/ci/dev/custom#'
mutate "image digest drifts from Dockerfile fails" "FROM must be exactly" 's/@sha256:b/@sha256:c/'
mutate_in dockerfile "Dockerfile FROM drift fails" "FROM must be exactly" 's/@sha256:b/@sha256:c/'
mutate_in dockerfile "Dockerfile not running setup.sh fails" "COPY setup.sh" 's/^RUN .*/RUN true/'
mutate_in setup "moving apt archive fails"       "snapshot.debian.org" 's#^URIs: https://snapshot.debian.org/archive/debian/${SNAPSHOT}$#URIs: https://deb.debian.org/debian#'
mutate_in setup "unpinned package fails"         "name=exact-version"  's/^  jq=.*/  jq/'
mutate_in setup "malformed snapshot fails"       "SNAPSHOT"            's/^SNAPSHOT=.*/SNAPSHOT=latest/'
mutate_in setup "empty source checksum fails"    "GIT_SHA256"          's/^GIT_SHA256=.*/GIT_SHA256=/'
mutate_in setup "dropped checksum step fails"    "sha256sum -c"        's/| sha256sum -c --quiet -/| true/'
mutate_in setup "floating source version fails"  "GIT_VERSION"         's/^GIT_VERSION=.*/GIT_VERSION=latest/'
mutate_in setup "base sources kept fails"        "remove the base image" 's#^rm -f /etc/apt/sources.list /etc/apt/sources.list.d/\*$#true#'
mutate_in setup "one-line moving source fails"   "one-line"            's#^\(rm -f /etc/apt/sources.list .*\)$#\1\necho "deb https://deb.debian.org/debian trixie main" > /etc/apt/sources.list#'
mutate_in setup "extra sources file fails"       "other sources"       's#^\(rm -f /etc/apt/sources.list .*\)$#\1\ncp /x /etc/apt/sources.list.d/extra.list#'
mutate_in setup "extra unpinned package fails"   "exactly"             's/"\${PACKAGES\[@\]}"; then$/"${PACKAGES[@]}" vim; then/'
mutate_in setup "glob version fails"             "name=exact-version"  's/^  jq=.*/  jq=1.7*/'
mutate_in setup "snapshot reassigned fails"      "exactly once"        's/^\(SNAPSHOT=.*\)$/\1\nSNAPSHOT=latest/'
mutate_in setup "checksum reassigned fails"      "exactly once"        's/^\(GIT_SHA256=.*\)$/\1\nGIT_SHA256=$(curl -s x)/'
mutate_in dockerfile "second FROM fails"         "exactly one FROM"    '$a FROM debian:latest'
mutate "before_script ~/dev/custom link fails"   "dev/custom"          's#^  script:$#  before_script:\n    - ln -sfn "$CI_PROJECT_DIR" /home/ci/dev/custom\n  script:#'

# A missing image file is an error, not a pass.
out="$(/usr/bin/ruby "${CHECK}" "${CI_FILE}" "${TMP}/absent.Dockerfile" "${SETUP}" 2>&1)"
if [ $? -ne 0 ] && [[ "${out}" == *"Dockerfile"*"missing"* ]]; then ok "missing Dockerfile fails"; else bad "missing Dockerfile fails" "${out}"; fi
out="$(/usr/bin/ruby "${CHECK}" "${CI_FILE}" "${DOCKERFILE}" "${TMP}/absent.setup.sh" 2>&1)"
if [ $? -ne 0 ] && [[ "${out}" == *"setup.sh"*"missing"* ]]; then ok "missing setup.sh fails"; else bad "missing setup.sh fails" "${out}"; fi

# A missing file is an error, not a pass.
out="$(/usr/bin/ruby "${CHECK}" "${TMP}/absent.yml" 2>&1)"
if [ $? -ne 0 ] && [[ "${out}" == *"Fix:"* ]]; then ok "missing file fails with Fix:"; else bad "missing file fails with Fix:" "${out}"; fi

echo
echo "gitlab-ci self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
