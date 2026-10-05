#!/usr/bin/env bash
# self-test.sh -- static suite for .gitlab-ci.yml (DND-1946). Discovered by
# harness-gate. Parses the file and asserts the rules the pipeline holds:
# the fork guard leads workflow:rules, MR and branch pipelines do not
# duplicate, every runnable job is tagged, nothing carries credentials, and
# the gate job runs ai/bin/harness-gate with full history. Functional only
# (DND-1222): reads one file, no network, no docker, no timing.
# Each rule has a miss case: a mutated copy of the file must fail the checker.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
CI_FILE="${ROOT}/.gitlab-ci.yml"
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
out="$(/usr/bin/ruby "${CHECK}" "${CI_FILE}" 2>&1)"
if [ $? -eq 0 ]; then ok "the committed .gitlab-ci.yml satisfies every rule"; else bad "the committed .gitlab-ci.yml satisfies every rule" "${out}"; fi

# mutate NAME EXPECT SED-EXPR: the mutated copy must fail, naming EXPECT.
mutate() {
  local name="$1" expect="$2" expr="$3" f="${TMP}/m.yml" out
  sed -e "${expr}" "${CI_FILE}" > "${f}"
  if cmp -s "${f}" "${CI_FILE}"; then bad "${name}" "mutation did not change the file"; return; fi
  out="$(/usr/bin/ruby "${CHECK}" "${f}" 2>&1)"
  if [ $? -ne 0 ] && [[ "${out}" == *"${expect}"* ]]; then ok "${name}"; else bad "${name}" "expected failure naming [${expect}], got: ${out}"; fi
}

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

# Goal 4 (DND-2067): no pipeline on the default branch.
mutate "default-branch rule removed fails" "default branch" '/CI_DEFAULT_BRANCH/,+1d'
mutate "default-branch rule not never fails" "must be" '/CI_DEFAULT_BRANCH/{n;s/never/always/;}'
# Order: move the never-rule behind the branch rule; the checker must refuse.
/usr/bin/ruby -ryaml -e 'd = YAML.safe_load_file(ARGV[0], aliases: true); r = d["workflow"]["rules"]; i = r.index { |x| x["if"].to_s.include?("CI_DEFAULT_BRANCH") }; r.push(r.delete_at(i)); File.write(ARGV[1], YAML.dump(d))' "${CI_FILE}" "${TMP}/order.yml"
out="$(/usr/bin/ruby "${CHECK}" "${TMP}/order.yml" 2>&1)"
if [ $? -ne 0 ] && [[ "${out}" == *"must come before"* ]]; then ok "default-branch rule after the branch rule fails"; else bad "default-branch rule after the branch rule fails" "${out}"; fi

# A missing file is an error, not a pass.
out="$(/usr/bin/ruby "${CHECK}" "${TMP}/absent.yml" 2>&1)"
if [ $? -ne 0 ] && [[ "${out}" == *"Fix:"* ]]; then ok "missing file fails with Fix:"; else bad "missing file fails with Fix:" "${out}"; fi

echo
echo "gitlab-ci self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
