#!/usr/bin/env bash
# self-test.sh -- the lead-time-repos suite (DND-1526). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. the domain suite (config_test.rb), run through `lead-time-repos
#      --self-test` so its self-test path is exercised;
#   2. the CLI end to end, against a temp HOME (and so a temp override path),
#      temp git checkouts, and ATHENA_LEADTIME_CONFIG files in a temp dir.
#      It never reads or writes the real ~/.config/athena override.
# Every miss is tested, not just the hit (~/.claude/CLAUDE.md -> *A failed
# lookup must never look like an empty one*). Functional only (DND-1222): no
# sleeps, no timing, no load. Ids and paths are synthetic.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
BIN="${ROOT}/ai/bin/lead-time-repos"

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "lead-time-repos self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -x "${BIN}" ] || { echo "lead-time-repos self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/bin/lead-time-repos"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; echo "  Fix: free space in TMPDIR"; exit 1; }
cleanup() { chmod -R u+rwx "${TMP}" 2>/dev/null; rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

echo "== domain"
if /usr/bin/ruby "${BIN}" --self-test >"${TMP}/lib.out" 2>&1; then
  ok "lead-time-repos --self-test: $(tail -1 "${TMP}/lib.out")"
else
  bad "lead-time-repos --self-test" "$(cat "${TMP}/lib.out")"
fi

# ── fixtures ────────────────────────────────────────────────────────────────
H="${TMP}/home"
mkdir -p "${H}/dev"
GENV=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
for r in custom gen_saas walt_ui; do
  "${GENV[@]}" git init -q -b main "${H}/dev/${r}" || { echo "FAIL git init"; echo "  Fix: install git"; exit 1; }
done
OVR="${H}/.config/athena/lead-time-repos.json"
CFG="${TMP}/cfg"
mkdir -p "${CFG}"

OUT=""; ERR=""; CODE=0
# run [VAR=value ...] -- ARGS... : the CLI with a scrubbed environment: temp
# HOME, no XDG_CONFIG_HOME, no ATHENA_LEADTIME_CONFIG unless given.
run() {
  local vars=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  OUT="$(env -u ATHENA_LEADTIME_CONFIG -u XDG_CONFIG_HOME -u LEAD_TIME_PHASES_CONFIG HOME="${H}" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "${vars[@]}" \
        /usr/bin/ruby "${BIN}" "$@" 2>"${TMP}/err" </dev/null)"
  CODE=$?
  ERR="$(cat "${TMP}/err")"
}
jq_r() { printf '%s' "${OUT}" | /usr/bin/ruby -rjson -e "j = JSON.parse(\$stdin.read); puts((begin; ${1}; end))"; }
write_ovr() { mkdir -p "$(dirname "${OVR}")"; printf '%s\n' "$1" >"${OVR}"; chmod 0644 "${OVR}"; }
cfg() { printf '%s\n' "$2" >"${CFG}/$1"; chmod 0644 "${CFG}/$1"; printf '%s' "${CFG}/$1"; }

echo "== --help"
run -- --help
eq "--help exits 0" "${CODE}" "0"
has "--help is on stdout" "${OUT}" "Usage:"
eq "--help writes nothing" "$(find "${H}" -path "${H}/dev" -prune -o -print | wc -l | tr -d ' ')" "1"

echo "== no override: the tracked default, unchanged"
run -- --json
eq "no override exits 0" "${CODE}" "0"
eq "source=default" "$(jq_r 'j["source"]')" "default"
eq "path is the tracked file" "$(jq_r 'j["path"]')" "${ROOT}/ai/config/lead-time-repos.json"
eq "custom improve, gen_saas watch, walt_ui watch" "$(jq_r 'j["repos"].map { |r| r["name"] + ":" + r["mode"] }.join(",")')" "custom:improve,gen_saas:watch,walt_ui:watch"
eq "paths expand under HOME" "$(jq_r 'j["repos"].map { |r| r["path"] }.join(",")')" "${H}/dev/custom,${H}/dev/gen_saas,${H}/dev/walt_ui"
eq "window and epic come from the tracked file" "$(jq_r '[j["window"], j["improvement_epic"] == JSON.parse(File.read(j["path"]))["improvement_epic"]].join(",")')" "20,true"
eq "nothing skipped, 3 considered" "$(jq_r '[j["skipped"].size, j["considered"]].join(",")')" "0,3"
run --
eq "the table exits 0" "${CODE}" "0"
has "the table names the source" "${OUT}" "source=default"
has "the table counts" "${OUT}" "3 considered, 3 resolved, 0 skipped"
[ -e "${H}/.config" ] && bad "a run writes no override" "${H}/.config exists" || ok "a run writes no override"

echo "== override present: its repo list, window and epic replace the tracked ones"
write_ovr "{\"repos\":[{\"name\":\"gen_saas\",\"path\":\"~/dev/gen_saas\",\"mode\":\"improve\",\"product_epic\":\"prod-epic\"}],\"window\":7,\"improvement_epic\":\"harness-epic\"}"
run -- --json
eq "an override exits 0" "${CODE}" "0"
eq "source=override, its path" "$(jq_r '[j["source"], j["path"]].join(",")')" "override,${OVR}"
eq "only the override's repos: no tracked repo is added" "$(jq_r 'j["repos"].map { |r| r["name"] + ":" + r["mode"] }.join(",")')" "gen_saas:improve"
eq "its window and epic" "$(jq_r '[j["window"], j["improvement_epic"]].join(",")')" "7,harness-epic"
eq "product_epic present is carried" "$(jq_r 'r = j["repos"][0]; [r["product_epic"], r["product_epic_source"]].join(",")')" "prod-epic,repo"
run --
has "the table prints the override path" "${OUT}" "source=override path=${OVR}"
run XDG_CONFIG_HOME="${TMP}/elsewhere" -- --json
eq "XDG_CONFIG_HOME moves the override path (none there: default)" "$(jq_r 'j["source"]')" "default"

# DND-1672: the tracked default declares idle_workflow "none" for custom and
# "post-merge.yml" for gen_saas. An override entry that omits a field the
# tracked default declares for the same repo inherits it, and says so; a field
# the override declares wins; a repo the override drops stays dropped.
echo "== override inherits per-repo fields the tracked default declares (DND-1672)"
write_ovr "{\"repos\":[{\"name\":\"custom\",\"path\":\"~/dev/custom\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"~/dev/gen_saas\",\"mode\":\"improve\",\"idle_workflow\":\"none\"}],\"window\":20,\"improvement_epic\":\"harness-epic\"}"
run -- --json
eq "an override with an omitted field exits 0" "${CODE}" "0"
eq "custom's omitted idle_workflow is the tracked default's, never nil" "$(jq_r 'j["repos"][0]["idle_workflow"].inspect')" '"none"'
eq "... and is named as inherited" "$(jq_r 'j["repos"][0]["inherited"].join(",")')" "idle_workflow"
eq "the override's own idle_workflow wins over the tracked one" "$(jq_r 'j["repos"][1]["idle_workflow"]')" "none"
eq "... and nothing is inherited for it" "$(jq_r 'j["repos"][1]["inherited"].size')" "0"
eq "the override still changes a repo's mode" "$(jq_r 'j["repos"][1]["mode"]')" "improve"
eq "inherits_from names the tracked default" "$(jq_r 'j["inherits_from"]')" "${ROOT}/ai/config/lead-time-repos.json"
eq "a repo the override drops does not come back" "$(jq_r 'j["repos"].map { |r| r["name"] }.join(",")')" "custom,gen_saas"
run --
has "the table names the inherited field and where it came from" "${OUT}" "idle_workflow=none (tracked default)"
GOOD_ENV="$(cfg envonly.json "{\"repos\":[{\"name\":\"custom\",\"path\":\"~/dev/custom\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
run ATHENA_LEADTIME_CONFIG="${GOOD_ENV}" -- --json
eq "ATHENA_LEADTIME_CONFIG stays authoritative: nothing inherited" "$(jq_r '[j["repos"][0]["idle_workflow"].inspect, j["repos"][0]["inherited"].size, j["inherits_from"].inspect].join(",")')" "nil,0,nil"
rm -f "${OVR}"
run -- --json
eq "no override: inherits_from is null" "$(jq_r 'j["inherits_from"].inspect')" "nil"

echo "== override refused (exit 2, Fix:), never read as no override"
refused() { # DESC EXPECT-IN-ERR
  eq "$1: exit 2" "${CODE}" "2"
  has "$1: names it" "${ERR}" "$2"
  has "$1: carries Fix:" "${ERR}" "Fix:"
}
write_ovr '{nope'
run -- ; refused "malformed JSON" "not valid JSON"
write_ovr '{"repos":[{"name":"custom","path":"~/dev/custom","mode":"improve"}],"window":20,"improvement_epic":"e","extra":1}'
run -- ; refused "an unknown key" "unknown key(s) extra"
write_ovr '{"repos":[{"name":"custom","path":"~/dev/custom","mode":"fix"}],"window":20,"improvement_epic":"e"}'
run -- ; refused "a bad mode" '"custom" has unknown mode'
write_ovr '{"repos":[{"name":"custom","path":"~/dev/custom","mode":"improve"}],"window":20,"improvement_epic":"e"}'
chmod 0664 "${OVR}"
run -- ; refused "a group-writable override" "group/other-writable (mode 0664)"
chmod 0646 "${OVR}"
run -- ; refused "an other-writable override" "group/other-writable"
rm -f "${OVR}"; ln -s "${TMP}/no-such-target.json" "${OVR}"
run -- ; refused "a dangling symlink override" "cannot be read"
rm -f "${OVR}"; mkdir "${OVR}"
run -- ; refused "an override that is a directory" "not a regular file"
rmdir "${OVR}"
write_ovr '{"repos":[{"name":"custom","path":"~/dev/custom","mode":"improve"}],"window":20,"improvement_epic":"e"}'
chmod 0200 "${OVR}"
run --
eq "an unreadable override: could not look, exit 3" "${CODE}" "3"
has "... naming the file" "${ERR}" "cannot read the override config ${OVR}"
rm -f "${OVR}"

echo "== ATHENA_LEADTIME_CONFIG: authoritative"
GOOD="$(cfg good.json "{\"repos\":[{\"name\":\"walt_ui\",\"path\":\"${H}/dev/walt_ui\",\"mode\":\"watch\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
run ATHENA_LEADTIME_CONFIG="${GOOD}" -- --json
eq "the env path is read: exit 0" "${CODE}" "0"
eq "... as the override" "$(jq_r '[j["source"], j["path"], j["repos"].map { |r| r["name"] }.join].join(",")')" "override,${GOOD},walt_ui"
run ATHENA_LEADTIME_CONFIG= -- ; refused "the env var set empty" "set but empty"
run ATHENA_LEADTIME_CONFIG=rel.json -- ; refused "the env var relative" "not an absolute path"
run ATHENA_LEADTIME_CONFIG="${CFG}/none.json" -- ; refused "the env path missing (never the tracked default)" "does not exist"
chmod 0666 "${GOOD}"
run ATHENA_LEADTIME_CONFIG="${GOOD}" -- ; refused "a world-writable env file" "group/other-writable"
chmod 0644 "${GOOD}"
run LEAD_TIME_PHASES_CONFIG="${GOOD}" -- ; refused "the retired LEAD_TIME_PHASES_CONFIG seam" "LEAD_TIME_PHASES_CONFIG is retired"

echo "== HOME"
OUT="$(env -u HOME -u XDG_CONFIG_HOME -u ATHENA_LEADTIME_CONFIG -u LEAD_TIME_PHASES_CONFIG /usr/bin/ruby "${BIN}" 2>&1)"; CODE=$?
eq "HOME unset with no env path: exit 2" "${CODE}" "2"
has "... naming HOME, with Fix:" "${OUT}" "HOME is unset or empty"
run HOME=relative/home -- ; refused "a relative HOME" "HOME is relative"

echo "== presence: missing checkouts are skipped by name and counted"
PART="$(cfg part.json "{\"repos\":[{\"name\":\"custom\",\"path\":\"${H}/dev/custom\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"${TMP}/gone/gen_saas\",\"mode\":\"watch\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
run ATHENA_LEADTIME_CONFIG="${PART}" -- --json
eq "a missing checkout: exit 0" "${CODE}" "0"
eq "the rest resolve" "$(jq_r 'j["repos"].map { |r| r["name"] }.join(",")')" "custom"
eq "the missing one is skipped by name, with its path" "$(jq_r 's = j["skipped"][0]; [s["name"], s["path"]].join(",")')" "gen_saas,${TMP}/gone/gen_saas"
has "... and its reason" "$(jq_r 'j["skipped"][0]["reason"]')" "no such path"
eq "considered counts both" "$(jq_r 'j["considered"]')" "2"
eq "product_epic absent falls back to improvement_epic" "$(jq_r 'r = j["repos"][0]; [r["product_epic"], r["product_epic_source"]].join(",")')" "e,improvement_epic"
run ATHENA_LEADTIME_CONFIG="${PART}" --
has "the table prints the skip" "${OUT}" "skipped  gen_saas"
has "the table counts the skip" "${OUT}" "2 considered, 1 resolved, 1 skipped"

ALLGONE="$(cfg allgone.json "{\"repos\":[{\"name\":\"custom\",\"path\":\"${TMP}/gone/custom\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
run ATHENA_LEADTIME_CONFIG="${ALLGONE}" --
eq "zero repos left: exit 4" "${CODE}" "4"
has "... saying so" "${ERR}" "no configured repo is checked out on this machine"
has "... with Fix:" "${ERR}" "Fix:"
eq "... and nothing on stdout" "${OUT}" ""

echo "== presence: an existing path that is wrong is an error, not a skip"
mkdir -p "${TMP}/plain/custom"
NOTGIT="$(cfg notgit.json "{\"repos\":[{\"name\":\"custom\",\"path\":\"${TMP}/plain/custom\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
run ATHENA_LEADTIME_CONFIG="${NOTGIT}" -- ; refused "a directory that is not a git repository" "is not a git repository"
"${GENV[@]}" git init -q -b main "${TMP}/other"
MISMATCH="$(cfg mismatch.json "{\"repos\":[{\"name\":\"custom\",\"path\":\"${TMP}/other\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
run ATHENA_LEADTIME_CONFIG="${MISMATCH}" -- ; refused "a name/basename mismatch" 'main checkout is named "other"'
mkdir -p "${H}/dev/custom/sub"
SUB="$(cfg sub.json "{\"repos\":[{\"name\":\"custom\",\"path\":\"${H}/dev/custom/sub\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
run ATHENA_LEADTIME_CONFIG="${SUB}" -- ; refused "a path inside a checkout but not its top" "not the top of its git checkout"
printf 'x\n' >"${TMP}/afile"
AFILE="$(cfg afile.json "{\"repos\":[{\"name\":\"afile\",\"path\":\"${TMP}/afile\",\"mode\":\"watch\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
run ATHENA_LEADTIME_CONFIG="${AFILE}" -- ; refused "a path that is a file" "not a directory"
mkdir -p "${TMP}/locked"
"${GENV[@]}" git init -q -b main "${TMP}/locked/custom"
LOCKED="$(cfg locked.json "{\"repos\":[{\"name\":\"custom\",\"path\":\"${TMP}/locked/custom\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"e\"}")"
chmod 000 "${TMP}/locked"
run ATHENA_LEADTIME_CONFIG="${LOCKED}" --
chmod 755 "${TMP}/locked"
eq "a checkout it cannot reach (EACCES on a parent): could not look, exit 3, never a skip" "${CODE}" "3"
has "... naming the path" "${ERR}" "could not probe ${TMP}/locked/custom"
lacks "... and never 'no such path'" "${ERR}" "no such path"
run GIT_DIR="${TMP}/other/.git" ATHENA_LEADTIME_CONFIG="${PART}" -- --json
eq "a leaked GIT_DIR does not redirect the probes" "$(jq_r 'j["repos"].map { |r| r["name"] }.join(",")')" "custom"

echo "== --repo-path: a change repo's path (DND-1528)"
# The runner's own repo is this checkout's main checkout, read from git here
# the same way the tool must, so the suite never hardcodes ~/dev/custom.
OWN_COMMON="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "${ROOT}" rev-parse --path-format=absolute --git-common-dir)"
OWN="$(dirname "${OWN_COMMON}")"
OWN_NAME="$(basename "${OWN}")"
run ATHENA_LEADTIME_CONFIG="${PART}" -- --repo-path custom
eq "a configured, present repo: exit 0" "${CODE}" "0"
eq "... prints its configured path, and only that" "${OUT}" "${H}/dev/custom"
run ATHENA_LEADTIME_CONFIG="${GOOD}" -- --repo-path "${OWN_NAME}"
eq "the runner's own repo, not configured here: exit 0" "${CODE}" "0"
eq "... prints the runner's main checkout (git rev-parse --git-common-dir)" "${OUT}" "${OWN}"
run ATHENA_LEADTIME_CONFIG="${ALLGONE}" -- --repo-path "${OWN_NAME}"
eq "a machine whose every configured checkout is missing still resolves the runner's own repo" "${OUT}" "${OWN}"
run GIT_DIR="${TMP}/other/.git" ATHENA_LEADTIME_CONFIG="${GOOD}" -- --repo-path "${OWN_NAME}"
eq "a leaked GIT_DIR does not redirect the own-repo lookup" "${OUT}" "${OWN}"
run ATHENA_LEADTIME_CONFIG="${PART}" -- --repo-path gen_saas
refused "a configured repo skipped on this machine" "gen_saas: skipped on this machine"
eq "... and nothing on stdout" "${OUT}" ""
run ATHENA_LEADTIME_CONFIG="${GOOD}" -- --repo-path nope
refused "a repo neither configured nor the runner's own" "not the runner's own repo"
eq "... and nothing on stdout" "${OUT}" ""
run ATHENA_LEADTIME_CONFIG="${GOOD}" -- --repo-path "${OWN_NAME}" --json
refused "--repo-path with --json" "--repo-path prints one path"
run ATHENA_LEADTIME_CONFIG="${GOOD}" -- --self-test --repo-path "${OWN_NAME}"
refused "--repo-path with --self-test" "--repo-path prints one path"
run ATHENA_LEADTIME_CONFIG="${NOTGIT}" -- --repo-path "${OWN_NAME}"
refused "a refused config refuses --repo-path too (one resolver)" "is not a git repository"

echo "== usage"
run -- --bogus
eq "an unknown flag: exit 2" "${CODE}" "2"
has "... with Fix:" "${ERR}" "Fix:"

echo
echo "lead-time-repos self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read the FAIL lines above; the suite pins ai/bin/lead-time-repos (DND-1526)."
  exit 1
fi
exit 0
