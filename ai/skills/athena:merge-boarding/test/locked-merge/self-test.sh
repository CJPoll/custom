#!/usr/bin/env bash
# Self-test for athena:merge-boarding's locked-merge.
#
# The defect this tool exists to catch: a GitHub squash-merge onto a base that
# moved after integration-gate ran lands a tree nobody gated, and nothing
# refuses it. The cases that matter are the misses -- base moved before the
# lock (c2: exit 3, NO merge call) and a landing on a different base or tree
# (c8/c9: exit 7) -- because each of those reads as a clean merge otherwise.
#
# Hermetic: a local bare "origin" reached through a github.com URL via
# url.insteadOf, and PATH/AI_BIN stubs for gh, gh-athena and confirm-merged.
#
# Run: bash ai/skills/athena:merge-boarding/test/locked-merge/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/scripts/locked-merge"

PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOCKED_MERGE_CONFIRM_SLEEP=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '       %s\n' "$2"; }

# ---- stubs ----
STUBS="${TMP}/stubs"; mkdir -p "${STUBS}"
cat > "${STUBS}/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub: `pr view ... [-q Q]` reads $ST/pr.json; `run list ... -q Q` reads $ST/runs.json.
q=""; prev=""
for a in "$@"; do [ "${prev}" = "-q" ] && q="${a}"; prev="${a}"; done
case "$1 $2" in
  "pr view")  f="${ST}/pr.json" ;;
  "run list") f="${ST}/runs.json" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 99 ;;
esac
if [ -n "${q}" ]; then jq -r "${q}" "${f}"; else cat "${f}"; fi
EOF
cat > "${STUBS}/gh-athena" <<'EOF'
#!/usr/bin/env bash
# gh-athena stub: logs argv, then squashes per $ST/merge_mode into the bare origin.
echo "$*" >> "${ST}/merge.log"
mode="$(cat "${ST}/merge_mode")"
[ "${mode}" = refuse ] && { echo "refused: checks not green" >&2; exit 1; }
sha=""; prev=""
for a in "$@"; do [ "${prev}" = "--match-head-commit" ] && sha="${a}"; prev="${a}"; done
G="git --git-dir=${BARE}"
if [ "${mode}" = moved ]; then   # someone else lands first, forge does not refuse
  x="$(${G} commit-tree "$(${G} rev-parse main^{tree})" -p "$(${G} rev-parse main)" -m other)"
  ${G} update-ref refs/heads/main "${x}"
fi
tree="$(${G} rev-parse "${sha}^{tree}")"
[ "${mode}" = badtree ] && tree="$(${G} rev-parse main^{tree})"
m="$(${G} commit-tree "${tree}" -p "$(${G} rev-parse main)" -m squash)"
${G} update-ref refs/heads/main "${m}"
jq --arg m "${m}" '.state="MERGED" | .mergeCommit={oid:$m}' "${ST}/pr.json" > "${ST}/pr.tmp" && mv "${ST}/pr.tmp" "${ST}/pr.json"
EOF
cat > "${STUBS}/confirm-merged" <<'EOF'
#!/usr/bin/env bash
exit "$(cat "${ST}/confirm_rc")"
EOF
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}" LOCKED_MERGE_AI_BIN="${STUBS}"

# fixture <name> -- fresh bare origin + clone "wt" on a feature head H.
# Sets: ST, BARE, WT, H.
fixture() {
  local d="${TMP}/$1"; mkdir -p "${d}/st"
  export ST="${d}/st" BARE="${d}/origin.git"
  git init -q --bare -b main "${BARE}"
  WT="${d}/wt"; git init -q -b main "${WT}"
  git -C "${WT}" config remote.origin.url "https://github.com/t/t.git"
  git -C "${WT}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "${WT}" config "url.${BARE}.insteadOf" "https://github.com/t/t.git"
  ( cd "${WT}" && echo seed > seed.txt && git add seed.txt && git commit -qm seed && git push -q origin main \
    && git checkout -qb feature && echo f > f.txt && git add f.txt && git commit -qm f && git push -q origin feature )
  H="$(git -C "${WT}" rev-parse HEAD)"
  printf '{"state":"OPEN","headRefOid":"%s","baseRefName":"main"}\n' "${H}" > "${ST}/pr.json"
  echo '[]' > "${ST}/runs.json"; echo good > "${ST}/merge_mode"; echo 0 > "${ST}/confirm_rc"
  : > "${ST}/merge.log"
}
advance_main() { local G="git --git-dir=${BARE}"
  ${G} update-ref refs/heads/main "$(${G} commit-tree "$(${G} rev-parse main^{tree})" -p "$(${G} rev-parse main)" -m ahead)"; }
run() { out="$("${TOOL}" "$@" 2>&1)"; rc=$?; }
expect() { # <label> <rc>
  [ "${rc}" -eq "$2" ] && ok "$1 exit $2" || bad "$1 expected exit $2, got ${rc}" "${out}"
  if [ "$2" -ne 0 ]; then grep -q '^Fix: ' <<<"${out}" && ok "$1 prints Fix:" || bad "$1 missing Fix:" "${out}"; fi
}
no_merge() { [ -s "${ST}/merge.log" ] && bad "$1 merge was CALLED" "$(cat "${ST}/merge.log")" || ok "$1 no merge call"; }

# c1 happy path; default lock derives from the repo name under HOME.
fixture c1
out="$(HOME="${TMP}/home" "${TOOL}" --pr 7 --head "${H}" --repo "${WT}" 2>&1)"; rc=$?
expect c1 0
grep -q "^LOCK ${TMP}/home/.local/state/athena/wt-merge.lock$" <<<"${out}" && ok "c1 default lock path" || bad "c1 default lock path" "${out}"
grep -q '^MERGED 7 [0-9a-f]\{40\} ON [0-9a-f]\{40\} TREE-MATCH$' <<<"${out}" && ok "c1 MERGED line" || bad "c1 MERGED line" "${out}"
grep -q -- "--squash --match-head-commit ${H}" "${ST}/merge.log" && ok "c1 merge pinned to head" || bad "c1 merge not pinned" "$(cat "${ST}/merge.log")"
grep -q -- '--auto' "${ST}/merge.log" && bad "c1 merge used --auto" || ok "c1 no --auto"

# c2 THE MISS: base moved after the gate -> refuse before merging.
fixture c2; advance_main
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c2.lock"; expect c2 3; no_merge c2
grep -q 'does not contain' <<<"${out}" && ok "c2 names the uncontained base" || bad "c2 message" "${out}"

# c3 PR head moved; c4 PR not open.
fixture c3; jq '.headRefOid="'"$(printf 'a%.0s' {1..40})"'"' "${ST}/pr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/pr.json"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c3.lock"; expect c3 3; no_merge c3
fixture c4; jq '.state="CLOSED"' "${ST}/pr.json" > "${ST}/x" && mv "${ST}/x" "${ST}/pr.json"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c4.lock"; expect c4 3; no_merge c4

# c5 forge refuses.
fixture c5; echo refuse > "${ST}/merge_mode"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c5.lock"; expect c5 4

# c6 required-idle workflow busy.
fixture c6; echo '[{"status":"queued"}]' > "${ST}/runs.json"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c6.lock" --require-idle-workflow post-merge.yml; expect c6 5; no_merge c6
echo '[{"status":"completed"}]' > "${ST}/runs.json"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c6.lock" --require-idle-workflow post-merge.yml; expect c6-idle 0

# c7 lock held elsewhere -> timeout, lock file left intact.
fixture c7; exec 8>>"${TMP}/c7.lock"; flock 8
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c7.lock" --wait 1; expect c7 6; no_merge c7
exec 8>&-
[ -e "${TMP}/c7.lock" ] && ok "c7 lock file not removed" || bad "c7 lock file was removed"

# c8 THE OTHER MISS: forge lands on a base that moved under the merge.
fixture c8; echo moved > "${ST}/merge_mode"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c8.lock"; expect c8 7
grep -q 'LANDED UNGATED' <<<"${out}" && ok "c8 says LANDED UNGATED" || bad "c8 message" "${out}"

# c9 landed tree differs from the gated tree.
fixture c9; echo badtree > "${ST}/merge_mode"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c9.lock"; expect c9 7

# c10 merge ran, landing unconfirmed.
fixture c10; echo 1 > "${ST}/confirm_rc"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c10.lock"; expect c10 8

# c11 non-GitHub origin; c12 malformed keys; c13 unknown flag.
fixture c11; git -C "${WT}" config remote.origin.url "git@gitlab.com:t/t.git"
run --pr 7 --head "${H}" --repo "${WT}" --lock "${TMP}/c11.lock"; expect c11 2; no_merge c11
fixture c12
run --pr 7 --head "${H:0:12}" --repo "${WT}"; expect c12-short-sha 2
run --pr x7 --head "${H}" --repo "${WT}"; expect c12-bad-pr 2
run --pr 7 --head "${H}" --repo "${WT}" --lock rel.lock; expect c12-relative-lock 2
run --pr 7 --head "${H}" --repo "${WT}" --bogus; expect c13 2
no_merge c12-c13

# c14 --help: stdout, exit 0, no side effects.
hout="$("${TOOL}" --help 2>/dev/null)"; rc=$?
[ "${rc}" -eq 0 ] && grep -q '^Usage:' <<<"${hout}" && ok "c14 --help on stdout, exit 0" || bad "c14 --help" "${hout}"

echo "locked-merge self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
