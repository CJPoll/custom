#!/usr/bin/env bash
# self-test for athena_fetch_origin_main in the cron runners
# (scripts/athena-shipwright-run.sh, scripts/athena-leadtime-run.sh).
#
# The helper picks how a cron tick fetches origin's main: a github.com origin
# through ai/bin/gh-athena, a gitlab.com origin through ai/bin/glab-athena (both
# HTTPS with the bot's token), anything else through plain git. Every case runs
# the helper as each runner defines it, against a fixture main checkout whose
# ai/bin holds stubs that record their argv, so no network or credential is used.
#
# Functional only (DND-1222): no timing, no load.
set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
RUNNERS=("scripts/athena-shipwright-run.sh" "scripts/athena-leadtime-run.sh")

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT

# helper_src RUNNER -> the athena_fetch_origin_main definition in that runner.
helper_src() {
  sed -n '/^athena_fetch_origin_main() {/,/^}/p' "${ROOT}/$1"
}

# make_checkout DIR URL STUB_RC -> a git repo with origin=URL and recording
# stubs ai/bin/gh-athena and ai/bin/glab-athena that exit STUB_RC.
make_checkout() {
  local dir="$1" url="$2" rc="$3" tool
  mkdir -p "${dir}/ai/bin"
  git -C "${dir}" init -q
  git -C "${dir}" remote add origin "${url}"
  for tool in gh-athena glab-athena; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "%s/calls"\nexit %s\n' \
      "${tool}" "${dir}" "${rc}" > "${dir}/ai/bin/${tool}"
    chmod +x "${dir}/ai/bin/${tool}"
  done
}

# run_helper RUNNER DIR -> runs the runner's helper on DIR; prints its exit code.
run_helper() {
  local src rc
  src="$(helper_src "$1")"
  bash -c "${src}"$'\n''athena_fetch_origin_main "$1"' _ "$2" >/dev/null 2>&1
  rc=$?
  printf '%s' "${rc}"
}

for runner in "${RUNNERS[@]}"; do
  name="$(basename "${runner}" .sh)"
  echo "${name}:"

  if [ -n "$(helper_src "${runner}")" ]; then
    ok "${name}: defines athena_fetch_origin_main"
  else
    bad "${name}: athena_fetch_origin_main not found"
    continue
  fi

  # Every plain fetch of origin main in the runner goes through the helper.
  plain="$(grep -nE 'git -C "\$\{MAIN_CHECKOUT\}" fetch' "${ROOT}/${runner}" || true)"
  if [ -z "${plain}" ]; then
    ok "${name}: no plain-git fetch of the main checkout's origin remains"
  else
    bad "${name}: plain-git fetch still present: ${plain}"
  fi

  i=0
  for case in \
    "git@github.com:CJPoll/custom.git|gh-athena" \
    "https://github.com/CJPoll/custom.git|gh-athena" \
    "git@gitlab.com:cjpoll/custom.git|glab-athena" \
    "https://gitlab.com/cjpoll/custom.git|glab-athena"; do
    i=$((i + 1))
    url="${case%%|*}"
    want="${case##*|}"
    dir="${TMP}/${name}-route-${i}"
    make_checkout "${dir}" "${url}" 0
    rc="$(run_helper "${runner}" "${dir}")"
    calls="$(cat "${dir}/calls" 2>/dev/null || true)"
    if [ "${rc}" = "0" ] && [ "${calls}" = "${want} git -C ${dir} fetch --quiet origin main" ]; then
      ok "${name}: ${url} routes through ${want}"
    else
      bad "${name}: ${url} expected ${want}; rc=${rc} calls=[${calls}]"
    fi
  done

  # A forge URL form the route can't rewrite (ssh://, a host alias) is refused
  # with exit 3 and a Fix, and neither a stub nor plain git (the owner's key)
  # is tried.
  j=0
  for url in "ssh://git@github.com/CJPoll/custom.git" "ssh://git@gitlab.com/cjpoll/custom.git" "git@github.com-work:CJPoll/custom.git"; do
    j=$((j + 1))
    dir="${TMP}/${name}-refuse-${j}"
    make_checkout "${dir}" "${url}" 0
    rc="$(run_helper "${runner}" "${dir}")"
    if [ "${rc}" = "3" ] && [ ! -e "${dir}/calls" ] && ! git -C "${dir}" rev-parse -q --verify FETCH_HEAD >/dev/null 2>&1; then
      ok "${name}: ${url} is refused (exit 3), no route or plain-git attempt"
    else
      bad "${name}: ${url} expected refusal exit 3; rc=${rc} calls=[$(cat "${dir}/calls" 2>/dev/null)]"
    fi
  done

  # A routed fetch that fails is reported as a failure, never a plain-git retry
  # with the owner's SSH key.
  dir="${TMP}/${name}-fail"
  make_checkout "${dir}" "git@github.com:CJPoll/custom.git" 3
  rc="$(run_helper "${runner}" "${dir}")"
  calls="$(cat "${dir}/calls" 2>/dev/null || true)"
  if [ "${rc}" != "0" ] && [ "$(printf '%s\n' "${calls}" | wc -l)" = "1" ]; then
    ok "${name}: a failed routed fetch returns non-zero with no fallback attempt"
  else
    bad "${name}: failed routed fetch: rc=${rc} calls=[${calls}]"
  fi

  # A non-forge origin (a local bare repo) uses plain git and calls no stub.
  bare="${TMP}/${name}-bare.git"
  git init -q --bare "${bare}"
  seed="${TMP}/${name}-seed"
  git init -q -b main "${seed}"
  git -C "${seed}" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m seed
  git -C "${seed}" push -q "${bare}" main
  dir="${TMP}/${name}-local"
  make_checkout "${dir}" "${bare}" 0
  rc="$(run_helper "${runner}" "${dir}")"
  if [ "${rc}" = "0" ] && [ ! -e "${dir}/calls" ] && git -C "${dir}" rev-parse -q --verify FETCH_HEAD >/dev/null; then
    ok "${name}: a local-path origin fetches with plain git and no stub"
  else
    bad "${name}: local-path origin: rc=${rc} calls=[$(cat "${dir}/calls" 2>/dev/null)]"
  fi
done

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
