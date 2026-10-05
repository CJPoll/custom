#!/usr/bin/env bash
# self-test.sh -- static suite for .gitlab-ci.yml (DND-1946). Discovered by
# harness-gate. Parses the file and asserts the rules the pipeline holds:
# the fork guard leads workflow:rules, MR and branch pipelines do not
# duplicate, every runnable job is tagged, nothing carries credentials, and
# the gate runs ai/bin/harness-gate with full history. DND-2085 adds the
# sibling container: the job checks its daemon is rootless, builds
# dockerfiles/ci-harness under a content-hash tag, runs the boundary probe as
# root and then the gate as `ci`, each with exactly the three --security-opt
# values; no `docker run` gets --privileged, a host namespace, --cap-add, a
# device, --volumes-from or the docker socket; after_script removes the
# siblings by name. DND-1998's image rules stay: the Dockerfile has one pinned
# FROM and runs setup.sh, and setup.sh pins one apt snapshot, exact package
# versions and a sha256-checked git tarball. Functional only (DND-1222): reads
# those three files, no network, no docker, no timing.
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

# The real files pass.
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
mutate "unpinned image fails"            "image"           's/^\(  image: [^@]*\)@sha256:[0-9a-f]*/\1/'
mutate "default id_tokens fails"         "id_tokens"       's/^default:$/default:\n  id_tokens: {}/'
mutate "include fails"                   "include"         's/^default:$/include: https:\/\/example.invalid\/x.yml\ndefault:/'
mutate "fork guard operator flipped fails" "fork guard"    's/!= \$CI_PROJECT_PATH/== $CI_PROJECT_PATH/'
mutate "MR rule removed fails"           "merge_request_event" 's/merge_request_event/pipeline_event/'
mutate "branch rule removed fails"       "branch pipeline" "s/^    - if: '\$CI_COMMIT_BRANCH'\$/    - if: '\$CI_COMMIT_TAG'/"
mutate "branch rule never fails"         "must not be"     "s/^    - if: '\$CI_COMMIT_BRANCH'\$/    - if: '\$CI_COMMIT_BRANCH'\n      when: never/"
mutate "origin/main fetch removed fails" "fetch origin/main" 's/ fetch --no-tags origin/ status --no-tags origin/'
mutate "gate echoed not run fails"       "exactly ai/bin/harness-gate"    's#"$CI_HARNESS_IMAGE" ai/bin/harness-gate$#"$CI_HARNESS_IMAGE" echo ai/bin/harness-gate#'
mutate "credential-named variable fails" "credential"      's/GIT_DEPTH: "0"/GIT_DEPTH: "0"\n    DEPLOY_TOKEN: "x"/'

# Goal 4 (DND-2067): no pipeline on the default branch.
mutate "default-branch rule removed fails" "default branch" '/CI_DEFAULT_BRANCH/,+1d'
mutate "default-branch rule not never fails" "must be" '/CI_DEFAULT_BRANCH/{n;s/never/always/;}'
# Order: move the never-rule behind the branch rule; the checker must refuse.
/usr/bin/ruby -ryaml -e 'd = YAML.safe_load_file(ARGV[0], aliases: true); r = d["workflow"]["rules"]; i = r.index { |x| x["if"].to_s.include?("CI_DEFAULT_BRANCH") }; r.push(r.delete_at(i)); File.write(ARGV[1], YAML.dump(d))' "${CI_FILE}" "${TMP}/order.yml"
out="$(/usr/bin/ruby "${CHECK}" "${TMP}/order.yml" 2>&1)"
if [ $? -ne 0 ] && [[ "${out}" == *"must come before"* ]]; then ok "default-branch rule after the branch rule fails"; else bad "default-branch rule after the branch rule fails" "${out}"; fi

# The sibling containers (DND-2085). GATE, PROBE and PREP address the lines.
GATE='/custom-gate-\$CI_JOB_ID" --user ci/'
PROBE='/custom-probe-\$CI_JOB_ID" --user 0/'
PREP='/custom-prep-\$CI_JOB_ID" --user 0/'
NOTALLOWED="is not allowed"
mutate "gate run in the job container fails"   "not in the job container" "${GATE}"'s#^    - docker run .* ai/bin/harness-gate$#    - ai/bin/harness-gate#'
mutate "gate run under runuser fails"          "not in the job container" "${GATE}"'s#^    - docker run .* ai/bin/harness-gate$#    - runuser -u ci -- ai/bin/harness-gate#'
mutate "gate --privileged fails"               "--privileged"      "${GATE}"'s/--rm --init/--rm --privileged --init/'
mutate "gate --pid=host fails"                 "--pid=host"        "${GATE}"'s/--rm --init/--rm --pid=host --init/'
mutate "gate --pid host (two words) fails"     "--pid"             "${GATE}"'s/--rm --init/--rm --pid host --init/'
mutate "gate --network=host fails"             "--network=host"    "${GATE}"'s/--rm --init/--rm --network=host --init/'
mutate "gate --net host fails"                 "--net"             "${GATE}"'s/--rm --init/--rm --net host --init/'
mutate "gate --cap-add fails"                  "--cap-add"         "${GATE}"'s/--rm --init/--rm --cap-add SYS_ADMIN --init/'
mutate "gate --userns=host fails"              "--userns=host"     "${GATE}"'s/--rm --init/--rm --userns=host --init/'
mutate "gate --cgroupns=host fails"            "--cgroupns=host"   "${GATE}"'s/--rm --init/--rm --cgroupns=host --init/'
mutate "gate --device fails"                   "--device"          "${GATE}"'s/--rm --init/--rm --device \/dev\/kmsg --init/'
mutate "gate --device-cgroup-rule fails"       "--device-cgroup-rule" "${GATE}"'s/--rm --init/--rm --device-cgroup-rule a --init/'
mutate "gate --volumes-from fails"             "--volumes-from"    "${GATE}"'s/--rm --init/--rm --volumes-from x --init/'
mutate "gate docker.sock bind fails"           "must bind exactly" "${GATE}"'s#--rm --init#--rm -v /var/run/docker.sock:/var/run/docker.sock --init#'
mutate "gate socket directory bind fails"      "must bind exactly" "${GATE}"'s#--rm --init#--rm -v /run/user/1000:/r --init#'
mutate "gate --volume bind fails"              "--volume"          "${GATE}"'s#--rm --init#--rm --volume /:/host --init#'
mutate "gate --mount bind fails"               "--mount"           "${GATE}"'s#--rm --init#--rm --mount type=bind,src=/run/user/1000,dst=/s --init#'
mutate "gate glued -v fails"                   "-v/:/host"         "${GATE}"'s#--rm --init#--rm -v/:/host --init#'
mutate "gate glued -u0 fails"                  "-u0"               "${GATE}"'s#--rm --init#--rm -u0 --init#'
mutate "gate --security-opt=value form fails"  "--security-opt=label=disable" "${GATE}"'s/--rm --init/--rm --security-opt=label=disable --init/'
mutate "gate extra --security-opt fails"       "exactly the three" "${GATE}"'s/--rm --init/--rm --security-opt label=disable --init/'
mutate "gate missing systempaths fails"        "exactly the three" "${GATE}"'s/ --security-opt systempaths=unconfined//'
mutate "gate missing seccomp fails"            "exactly the three" "${GATE}"'s/ --security-opt seccomp=unconfined//'
mutate "gate duplicated opt fails"             "exactly the three" "${GATE}"'s/--security-opt apparmor=unconfined/--security-opt apparmor=unconfined --security-opt apparmor=unconfined/'
mutate "gate as root fails"                    "--user ci"         "${GATE}"'s/--user ci/--user 0/'
mutate "gate second --user fails"              "exactly once"      "${GATE}"'s/--user ci/--user ci --user 0/'
mutate "gate renamed fails"                    "custom-gate"       "${GATE}"'s/custom-gate-\$CI_JOB_ID/gate/'
mutate "gate not --rm fails"                   "--rm"              "${GATE}"'s/--rm --init/--init/'
mutate "gate other image fails"                "built image"       "${GATE}"'s/"\$CI_HARNESS_IMAGE" ai/ruby:3 ai/'
mutate "gate checkout not bound fails"         "must bind exactly" "${GATE}"'s#-v "$CI_PROJECT_DIR:$CI_PROJECT_DIR"#-v "$CI_PROJECT_DIR:/src"#'
mutate "gate gets the whole job env fails"     "--env-file"        "${GATE}"'s/--rm --init/--rm --env-file \/tmp\/env --init/'
mutate "gate gets a variable fails"            "flag \"-e\""       "${GATE}"'s/--rm --init/--rm -e CI_JOB_TOKEN --init/'
mutate "gate glued -e fails"                   "-eCI_JOB_TOKEN"    "${GATE}"'s/--rm --init/--rm -eCI_JOB_TOKEN --init/'
mutate "gate git include writable fails"       "must bind exactly" "${GATE}"'s#.gitlab-runner.ext.conf:ro"#.gitlab-runner.ext.conf"#'
mutate "gate whole runner tmp dir fails"       "must bind exactly" "${GATE}"'s#-v "$CI_PROJECT_DIR.tmp/.gitlab-runner.ext.conf:$CI_PROJECT_DIR.tmp/.gitlab-runner.ext.conf:ro"#-v "$CI_PROJECT_DIR.tmp:$CI_PROJECT_DIR.tmp:ro"#'
mutate "probe gets the git include fails"      "must bind exactly" "${PROBE}"'s#-w "$CI_PROJECT_DIR"#-v "$CI_PROJECT_DIR.tmp/.gitlab-runner.ext.conf:$CI_PROJECT_DIR.tmp/.gitlab-runner.ext.conf:ro" -w "$CI_PROJECT_DIR"#'
mutate "probe --init fails"                   "--init is for the gate only" "${PROBE}"'s/--rm --name/--rm --init --name/'
mutate "prep --privileged fails"               "--privileged"      "${PREP}"'s/--user 0/--user 0 --privileged/'
mutate "prep extra mount fails"                "must bind exactly" "${PREP}"'s#--user 0#--user 0 -v /run/user/1000:/r#'
mutate "prep unmasked fails"                   "takes no --security-opt" "${PREP}"'s/--user 0/--user 0 --security-opt systempaths=unconfined/'
mutate "prep runs another command fails"       "hand the tree to ci" "${PREP}"'s/chown -R ci:ci "$CI_PROJECT_DIR"$/sh -c id/'
mutate "probe --pid=host fails"                "--pid=host"        "${PROBE}"'s/--user 0/--user 0 --pid=host/'
mutate "probe removed fails"                   "boundary probe"    "${PROBE}d"
mutate "probe as ci fails"                     "--user 0"          "${PROBE}"'s/--user 0/--user ci/'
mutate "probe without systempaths fails"       "exactly the three" "${PROBE}"'s/ --security-opt systempaths=unconfined//'
mutate "probe with an argument fails"          "no arguments"      "${PROBE}"'s#boundary-probe.sh$#boundary-probe.sh --root /tmp#'
mutate "probe after the gate fails"            "the boundary probe must come before" "${PROBE}"'{h;d;}; /custom-gate-.*harness-gate$/G'

# A daemon call the checker cannot read as an allowlisted shape fails.
ADD='s#^\(    - docker build .*\)$#\1\n    - '
mutate "docker container run fails"            "only \`docker info\`" "${ADD}"'docker container run --privileged alpine true#'
mutate "docker create fails"                   "only \`docker info\`" "${ADD}"'docker create --privileged alpine#'
mutate "docker exec fails"                     "only \`docker info\`" "${ADD}"'docker exec x id#'
mutate "docker global -H option fails"         "only \`docker info\`" "${ADD}"'docker -H unix:///run/user/1000/docker.sock run --privileged alpine true#'
mutate "docker behind env fails"               "cannot read"       "${ADD}"'env docker run --privileged alpine true#'
mutate "docker behind a variable assignment fails" "cannot read"   "${ADD}"'X=1 docker run --privileged alpine true#'
mutate "docker inside sh -c fails"             "cannot read"       "${ADD}"'sh -c "docker run --privileged alpine true"#'
mutate "docker inside \$(...) fails"           "cannot read"       "${ADD}"'X=$(docker run --privileged alpine true)#'
mutate "docker glued to a separator fails"     "cannot read"       "${ADD}"'true;docker run --privileged alpine true#'
mutate "docker after & fails"                  "--privileged"      "${ADD}"'true \& docker run --privileged alpine true#'
mutate "docker in an if fails"                 "cannot read"       "${ADD}"'if docker run --privileged alpine true; then true; fi#'
mutate "a continued line's flag fails"         "--privileged"      's/^    - docker run --rm --init --name "custom-gate/    - |\n      docker run --rm --init --name "custom-gate/;s/--rm --init --name "custom-gate/--rm \\\n      --privileged --init --name "custom-gate/'
mutate "docker build with extra options fails" "docker build: must be exactly" 's/docker build --progress=plain/docker build --progress=plain --network=host/'
mutate "docker info with a global option fails" "only \`docker info\`" 's/docker info --format/docker -H tcp:\/\/x info --format/'
mutate "docker info with extra options fails"  "docker info: must be exactly"  's/docker info --format/docker info --debug --format/'
mutate "docker rm of another container fails"  "docker rm: must be"            's/docker rm -f "custom-probe/docker rm -f other "custom-probe/'

mutate "rootless check removed fails"          "rootless"          's/name=rootless/name=seccomp/'
mutate "rootless check made advisory fails"    "rootless"          's/^        exit 1$/        true/'
mutate "rootless check after the probe fails"  "rootless check must come before" '/^    - docker info/,/^      fi$/{H;d;}; /custom-gate-.*harness-gate$/G'
mutate "image built from elsewhere fails"      "build the image"   's#-t "$CI_HARNESS_IMAGE" dockerfiles/ci-harness$#-t "$CI_HARNESS_IMAGE" .#'
mutate "image tag not a content hash fails"    "content hash"      's#^    - CI_HARNESS_IMAGE=.*#    - CI_HARNESS_IMAGE=custom-ci-harness:latest#'
mutate "tree not handed to ci fails"           "hand the tree to ci" 's/chown -R ci:ci/chown -R root:root/'
mutate "after_script cleanup removed fails"    "after_script"      's/docker rm -f /docker ps /'
mutate "after_script skips the gate fails"     "after_script"      's/ "custom-gate-\$CI_JOB_ID" >/ >/'
mutate "after_script skips the prep fails"     "after_script"      's/ "custom-prep-\$CI_JOB_ID" "custom-gate/ "custom-gate/'
mutate "~/dev/custom link fails"               "dev/custom"        's#chown -R ci:ci "$CI_PROJECT_DIR"$#chown -R ci:ci "$CI_PROJECT_DIR" \&\& ln -sfn "$CI_PROJECT_DIR" /home/ci/dev/custom#'
mutate "before_script ~/dev/custom link fails" "dev/custom"        's#^  script:$#  before_script:\n    - ln -sfn "$CI_PROJECT_DIR" /home/ci/dev/custom\n  script:#'
mutate "a hidden job's docker run with --privileged fails" "--privileged" 's/^default:$/.x:\n  script:\n    - docker run --privileged alpine true\ndefault:/'
mutate "an image entrypoint running docker fails" "--privileged"   's#^  image: \(docker:.*\)$#  image:\n    name: \1\n    entrypoint: ["sh", "-c", "docker run --privileged alpine true"]#'

# The pinned CI image (DND-1998).
mutate_in dockerfile "Dockerfile FROM unpinned fails"    "pinned by @sha256" 's/@sha256:[0-9a-f]*//'
mutate_in dockerfile "Dockerfile not running setup.sh fails" "COPY setup.sh" 's/^RUN .*/RUN true/'
mutate_in dockerfile "second FROM fails"                 "exactly one FROM"  '$a FROM debian:latest'
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
mutate_in setup "unpinned gem fails"             "name:exact-version"  's/^  json:.*/  json/'
mutate_in setup "gems reassigned fails"          "exactly once"        's/^\(GEMS=(\)$/GEMS=()\n\1/'
mutate_in setup "extra unpinned gem fails"       "\"\${GEMS[@]}\""     's/"\${GEMS\[@\]}"$/"${GEMS[@]}" rake/'
mutate_in setup "gem install dropped fails"      "\"\${GEMS[@]}\""     's/^gem install .*/true/'

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
