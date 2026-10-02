#!/usr/bin/env bash
# Self-test for scripts/setup-leadtime-cron (DND-1480).
#
# Run: bash ai/test/setup-leadtime-cron/self-test.sh
#
# Nothing real is touched:
#   * the installer runs against a FAKE crontab through its LEADTIME_CRONTAB
#     seam, backed by a file. A poisoned `crontab` is first on PATH, so a call
#     that bypasses the seam fails the case instead of reaching the real one.
#   * the "main checkout" is a throwaway git repo under a temp dir, holding a
#     copy of the installer, a stub runner, the skill, a synthetic repo config
#     and fixture shipwright cursors. Its state dirs are all inside it.
#   * time comes from LEADTIME_NOW.

set -uo pipefail
unset CLAUDE_PROJECT_DIR CLAUDE_PID LEAD_TIME_STATE_DIR SHIPWRIGHT_STATE_DIR

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
INSTALLER="${REPO_ROOT}/scripts/setup-leadtime-cron"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT INT TERM

ok()    { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
case_() { printf '\n%s\n' "$1"; }

[ -x "${INSTALLER}" ] || { echo "self-test: ${INSTALLER} is missing or not executable." >&2
  echo "  Fix: restore scripts/setup-leadtime-cron (chmod +x)." >&2; exit 2; }

# 2026-10-01T12:00:00Z; the custom ingest cursor seeds to 14 days before it.
NOW="$(date -u -d '2026-10-01T12:00:00Z' +%s)"
NOW_MINUS_14D='2026-09-17T12:00:00Z'

# --- fakes ---------------------------------------------------------------------
BIN="${TMP}/bin"; mkdir -p "$BIN"
cat >"$BIN/fake-crontab" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_CRONTAB}.calls"
case "$1" in
  -l) if [ -n "${FAKE_CRONTAB_FAIL:-}" ]; then echo "${FAKE_CRONTAB_FAIL}" >&2; exit 1; fi
      [ -e "$FAKE_CRONTAB" ] || { echo "no crontab for $(id -un)" >&2; exit 1; }
      cat "$FAKE_CRONTAB" ;;
  -)  if [ -n "${FAKE_CRONTAB_WRITE_FAIL:-}" ]; then cat >/dev/null; echo "${FAKE_CRONTAB_WRITE_FAIL}" >&2; exit 1; fi
      cat >"$FAKE_CRONTAB" ;;
  *)  echo "fake crontab: unsupported $*" >&2; exit 9 ;;
esac
EOF
POISON="${TMP}/real-crontab-touched"
cat >"$BIN/crontab" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"${POISON}"
echo "self-test: the REAL crontab path was called; the LEADTIME_CRONTAB seam was bypassed" >&2
exit 99
EOF
chmod +x "$BIN/fake-crontab" "$BIN/crontab"

# --- a throwaway main checkout --------------------------------------------------
IR="${TMP}/inst/repo"
mkdir -p "$IR/scripts" "$IR/ai/skills/athena:lead-time-improve" "$IR/ai/config" "$IR/ai/bin" "$IR/ai/lib"
cp "$INSTALLER" "$IR/scripts/"
# The shared libs the installer sources (the MCP preflight, DND-1571).
cp -r "${REPO_ROOT}/scripts/lib" "$IR/scripts/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$IR/scripts/athena-leadtime-run.sh"
chmod +x "$IR/scripts/athena-leadtime-run.sh"
printf -- '---\nname: athena:lead-time-improve\n---\n' >"$IR/ai/skills/athena:lead-time-improve/SKILL.md"
# The real resolver (DND-1526): the installer reads the repo list only through it.
cp "${REPO_ROOT}/ai/bin/lead-time-repos" "$IR/ai/bin/"
for f in strict_argv.rb lead_time_config.rb lead_time_config_io.rb; do cp "${REPO_ROOT}/ai/lib/$f" "$IR/ai/lib/"; done
# The checkouts the config points at: temp repos named as the repos are.
CO="${TMP}/checkouts"
for r in custom gen_saas walt_ui; do git init -q "$CO/$r" >&2; done
CO="$(cd -- "$CO" && pwd -P)"
TRACKED_JSON="{\"repos\":[{\"name\":\"custom\",\"path\":\"$CO/custom\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"$CO/gen_saas\",\"mode\":\"watch\"},{\"name\":\"walt_ui\",\"path\":\"$CO/walt_ui\",\"mode\":\"watch\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}"
printf '%s\n' "${TRACKED_JSON}" >"$IR/ai/config/lead-time-repos.json"
git -C "$IR" init -q -b main >&2
git -C "$IR" add -A >&2
git -C "$IR" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm seed >&2
IR="$(cd -- "$IR" && pwd -P)"
git -C "$IR" worktree add -q "${TMP}/inst/wt" >&2
WT="$(cd -- "${TMP}/inst/wt" && pwd -P)"
IRUN="$IR/scripts/athena-leadtime-run.sh"
LT="$IR/ai-artifacts/lead-time"
SW="$IR/ai-artifacts/shipwright"
ENTRY="30 * * * * ${IRUN}"
# A fake Claude config (LEADTIME_CLAUDE_JSON) with notion-personal registered
# for the main checkout: every case reads this, never ~/.claude.json. Synthetic
# values only.
CJ="${TMP}/claude.json"
jq -n --arg p "$IR" '{projects: {($p): {mcpServers: {
    "notion-personal": {type: "stdio", command: "/x/notion-athena-mcp", args: []}}}}}' >"$CJ"

# Shipwright fixture cursors: gen_saas and walt_ui. Reset per seeding case.
shipwright_cursors() {
  rm -rf -- "$SW" "$LT"; mkdir -p "$SW"
  printf '2026-10-01T10:11:43Z\n' >"$SW/lead-cursor.gen_saas.txt"
  printf '2026-10-01T09:50:16Z\n' >"$SW/lead-cursor.walt_ui.txt"
  printf '2026-10-01T11:00:13Z\n' >"$SW/lead-cursor.custom.txt"
}

inst() { # <crontab-file> [VAR=val ...] [-- args...]  (runs the MAIN checkout's installer)
  local f="$1"; shift; local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  # XDG_CONFIG_HOME is an empty temp dir and ATHENA_LEADTIME_CONFIG is unset
  # unless a case passes it, so no case reads this machine's real override.
  env -u ATHENA_LEADTIME_CONFIG XDG_CONFIG_HOME="${TMP}/xdg" PATH="$BIN:$PATH" LEADTIME_CRONTAB="$BIN/fake-crontab" FAKE_CRONTAB="$f" LEADTIME_NOW="$NOW" \
    LEADTIME_CLAUDE_JSON="$CJ" \
    "${envs[@]}" "${INST:-$IR/scripts/setup-leadtime-cron}" "$@" >"${TMP}/inst.out" 2>"${TMP}/inst.err"
  printf '%s' "$?"
}
out() { cat "${TMP}/inst.out" "${TMP}/inst.err"; }
poisoned() { [ -e "$POISON" ]; }

# ===========================================================================
case_ 'setup-leadtime-cron — read-only modes (QA 1, 2, 7)'

shipwright_cursors
ct="${TMP}/ct1"
rc="$(inst "$ct" -- --help)"
if [ "$rc" = 0 ] && grep -q 'Usage:' "${TMP}/inst.out" && [ ! -s "${TMP}/inst.err" ] \
   && [ ! -e "$ct.calls" ] && [ ! -e "$LT" ] && ! poisoned; then
  ok "QA1: --help prints usage on stdout, exits 0, never runs crontab, seeds nothing"
else
  bad "QA1 --help" "rc=$rc $(out | head -5) calls=$(cat "$ct.calls" 2>&1)"
fi

printf '# mine\n0 * * * * /opt/other-job\n' >"$ct"
before="$(cat "$ct")"
rc="$(inst "$ct" -- --dry-run)"
if [ "$rc" = 0 ] && grep -qF "${ENTRY}" "${TMP}/inst.out" && [ "$(cat "$ct")" = "$before" ] \
   && ! grep -qx -- '-' "$ct.calls" && [ ! -e "$LT" ] && grep -q 'would seed' "${TMP}/inst.out" && ! poisoned; then
  ok "QA2: --dry-run prints the entry and the seeding plan; the crontab and state are untouched"
else
  bad "QA2 --dry-run" "rc=$rc $(out) ct=$(cat "$ct") calls=$(cat "$ct.calls" 2>&1)"
fi

rc="$(inst "$ct" -- --backup "${TMP}/ct-backup")"
if [ "$rc" = 0 ] && cmp -s "$ct" "${TMP}/ct-backup" && [ "$(stat -c %a "${TMP}/ct-backup")" = 600 ]; then
  ok "QA7: --backup writes the current crontab (mode 600)"
else
  bad "QA7 --backup" "rc=$rc $(out)"
fi
rc="$(inst "${TMP}/ct-none" -- --backup "${TMP}/ct-backup-empty")"
if [ "$rc" = 0 ] && [ -e "${TMP}/ct-backup-empty" ] && [ "$(cat "${TMP}/ct-backup-empty")" = "" ]; then
  ok "QA7: --backup of 'no crontab for <user>' writes an empty file"
else
  bad "QA7 --backup empty" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'setup-leadtime-cron — install, idempotence, foreign lines (QA 3, 4)'

shipwright_cursors
ct="${TMP}/ct-empty"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "${ENTRY}" ]; then
  ok "QA3: --install on an empty crontab writes exactly one ':30' entry for the main checkout's runner"
else
  bad "QA3 install empty" "rc=$rc ct=$(cat "$ct" 2>&1) $(out)"
fi
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "${ENTRY}" ]; then
  ok "QA3: a second --install still leaves exactly one entry"
else
  bad "QA3 idempotent" "rc=$rc ct=$(cat "$ct")"
fi
rc="$(inst "$ct")"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "${ENTRY}" ]; then
  ok "no mode flag is --install (the setup-clustering-cron form)"
else
  bad "default mode" "rc=$rc ct=$(cat "$ct")"
fi

ct="${TMP}/ct-foreign"
printf '# owner comment\n0 * * * * /home/u/dev/custom/scripts/athena-shipwright-run.sh\n\n0 7,19 * * * /home/u/dev/custom/scripts/athena-clustering-run.sh\n*/5 * * * * /opt/x --flag "a  b"\t# tab\n' >"$ct"
cp "$ct" "${TMP}/ct-foreign.orig"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ "$(head -n 5 "$ct")" = "$(cat "${TMP}/ct-foreign.orig")" ] \
   && [ "$(tail -n 1 "$ct")" = "${ENTRY}" ] && [ "$(wc -l <"$ct")" = 6 ]; then
  ok "QA4: --install keeps the shipwright, clustering, comment, blank and tabbed lines byte for byte"
else
  bad "QA4 foreign" "rc=$rc ct=$(cat -A "$ct")"
fi

rc="$(inst "$ct" -- --schedule '45 * * * *')"
if [ "$rc" = 0 ] && [ "$(grep -cF "$IRUN" "$ct")" = 1 ] && grep -qxF "45 * * * * ${IRUN}" "$ct"; then
  ok "--schedule updates the entry in place (still one)"
else
  bad "schedule in place" "rc=$rc ct=$(cat "$ct")"
fi
rc="$(inst "$ct" -- --schedule '30 * *')"
if [ "$rc" = 1 ] && grep -q 'Fix:' "${TMP}/inst.err" && grep -qxF "45 * * * * ${IRUN}" "$ct"; then
  ok "a malformed --schedule is refused and changes nothing"
else
  bad "bad schedule" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'setup-leadtime-cron — --check (QA 5)'

ct="${TMP}/ct-check"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 1 ] && grep -q 'MISSING' "${TMP}/inst.err" && grep -q 'Fix:.*--install' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "QA5: --check without the entry: exit 1, Fix: names --install, writes nothing"
else
  bad "QA5 check absent" "rc=$rc $(out)"
fi
rc="$(inst "$ct" -- --install)"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ] && grep -q '^OK' "${TMP}/inst.out" && grep -qF "${ENTRY}" "${TMP}/inst.out"; then
  ok "QA5: --check with the entry: exit 0, prints it"
else
  bad "QA5 check present" "rc=$rc $(out)"
fi
sed -i "s|^30 \* \* \* \*|#30 * * * *|" "$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 1 ] && grep -q 'MISSING' "${TMP}/inst.err"; then
  ok "QA5: a commented-out entry is not live"
else
  bad "QA5 commented" "rc=$rc $(out)"
fi
printf '%s\n%s\n' "${ENTRY}" "${ENTRY}" >"$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 1 ] && grep -q 'DUPLICATE' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "QA5: two live entries are red (DUPLICATE), never 'installed'"
else
  bad "QA5 duplicate" "rc=$rc $(out)"
fi
printf '30 * * * * /gone/worktree/scripts/athena-leadtime-run.sh\n' >"$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 1 ] && grep -q 'STALE' "${TMP}/inst.err" && grep -qF '/gone/worktree/scripts/athena-leadtime-run.sh' "${TMP}/inst.err"; then
  ok "QA5: an entry for another runner path is red and named (STALE)"
else
  bad "QA5 stale path" "rc=$rc $(out)"
fi
printf '%s\n' "${ENTRY}" >"$ct"
chmod -x "$IRUN"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 1 ] && grep -qF "$IRUN" "${TMP}/inst.err" && grep -q 'not executable\|absent' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "QA5: the entry pointing at a missing/non-executable runner is red and names it"
else
  bad "QA5 missing runner" "rc=$rc $(out)"
fi
chmod +x "$IRUN"
rc="$(inst "$ct" FAKE_CRONTAB_FAIL='crontab: Permission denied' -- --check)"
if [ "$rc" = 2 ] && grep -q 'could not read' "${TMP}/inst.err" && ! grep -q 'MISSING' "${TMP}/inst.err"; then
  ok "--check on an unreadable crontab is exit 2 'could not read', never MISSING"
else
  bad "check unreadable" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'setup-leadtime-cron — --remove (QA 6)'

ct="${TMP}/ct-remove"
printf '0 * * * * /opt/other-job\n\n%s\n5 * * * * /opt/third\n' "${ENTRY}" >"$ct"
rc="$(inst "$ct" -- --remove)"
if [ "$rc" = 0 ] && ! grep -qF "$IRUN" "$ct" \
   && [ "$(cat "$ct")" = "$(printf '0 * * * * /opt/other-job\n\n5 * * * * /opt/third')" ]; then
  ok "QA6: --remove drops only our line and keeps the owner's blank line"
else
  bad "QA6 remove" "rc=$rc ct=$(cat -A "$ct") $(out)"
fi
printf '%s\n' "${ENTRY}" >"$ct"
mv "$IRUN" "${TMP}/runner.aside"
rc="$(inst "$ct" -- --remove)"
mv "${TMP}/runner.aside" "$IRUN"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "" ]; then
  ok "QA6: --remove works when the runner is gone"
else
  bad "QA6 remove without runner" "rc=$rc ct=$(cat "$ct") $(out)"
fi

# ===========================================================================
case_ 'setup-leadtime-cron — refusals (QA 8)'

shipwright_cursors
ct="${TMP}/ct-wt"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(INST="$WT/scripts/setup-leadtime-cron" inst "$ct" -- --install)"
if [ "$rc" = 5 ] && grep -q 'Fix:' "${TMP}/inst.err" && grep -qF "$IR" "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && [ ! -e "$LT" ]; then
  ok "QA8: --install from a linked worktree is refused (exit 5), Fix: names the main checkout, nothing written"
else
  bad "QA8 worktree install" "rc=$rc ct=$(cat "$ct") $(out)"
fi
printf '0 * * * * /opt/other-job\n%s\n' "${ENTRY}" >"$ct"
rc="$(INST="$WT/scripts/setup-leadtime-cron" inst "$ct" -- --remove)"
if [ "$rc" = 5 ] && grep -qF "${ENTRY}" "$ct"; then
  ok "QA8: --remove from a linked worktree is refused too"
else
  bad "QA8 worktree remove" "rc=$rc ct=$(cat "$ct") $(out)"
fi
rc="$(INST="$WT/scripts/setup-leadtime-cron" inst "$ct" -- --check)"
if [ "$rc" = 0 ] && grep -qF "${ENTRY}" "${TMP}/inst.out"; then
  ok "--check from a linked worktree reads the main checkout's entry"
else
  bad "worktree check" "rc=$rc $(out)"
fi

printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" FAKE_CRONTAB_FAIL='crontab: Permission denied' -- --install)"
if [ "$rc" = 2 ] && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "a crontab that cannot be read is never overwritten (exit 2, Fix:)"
else
  bad "unreadable crontab" "rc=$rc $(out)"
fi
# DND-1638: --remove on a crontab that cannot be read writes nothing either.
rc="$(inst "$ct" FAKE_CRONTAB_FAIL='/var/spool/cron/crontabs/u: Permission denied' -- --remove)"
if [ "$rc" = 2 ] && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && grep -q 'could not read' "${TMP}/inst.err" \
   && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "--remove on a crontab that cannot be read writes nothing (exit 2, Fix:)"
else
  bad "unreadable crontab --remove" "rc=$rc $(out)"
fi
ctn="${TMP}/ct-none"; rm -f "$ctn"
rc="$(inst "$ctn" -- --install)"
if [ "$rc" = 0 ] && [ "$(cat "$ctn")" = "${ENTRY}" ]; then
  ok "'no crontab for <user>' is an empty crontab: --install writes the one entry"
else
  bad "no crontab install" "rc=$rc ct=$(cat "$ctn" 2>&1) $(out)"
fi
mv "$IR/ai/skills/athena:lead-time-improve/SKILL.md" "${TMP}/skill.aside"
rc="$(inst "$ct" -- --install)"
mv "${TMP}/skill.aside" "$IR/ai/skills/athena:lead-time-improve/SKILL.md"
if [ "$rc" = 2 ] && grep -q 'lead-time-improve' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "the skill not in the main checkout: install refused (every tick would exit 78)"
else
  bad "unlanded skill" "rc=$rc $(out)"
fi
chmod -x "$IRUN"
rc="$(inst "$ct" -- --install)"
chmod +x "$IRUN"
if [ "$rc" = 2 ] && grep -qF "$IRUN" "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "a runner that is not executable in the main checkout: install refused"
else
  bad "unlanded runner" "rc=$rc $(out)"
fi
rc="$(inst "$ct" LEADTIME_NOW=yesterday -- --install)"
if [ "$rc" = 1 ] && grep -q 'Fix:' "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "a malformed LEADTIME_NOW is refused before any write"
else
  bad "bad now" "rc=$rc $(out)"
fi
rc="$(inst "$ct" -- --bogus)"
if [ "$rc" = 1 ] && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "an unknown flag is a usage error with Fix:"
else
  bad "unknown flag" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'setup-leadtime-cron — cursor seeding (QA 9)'

shipwright_cursors
ct="${TMP}/ct-seed"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] \
   && [ "$(cat "$LT/watch-cursor.gen_saas.txt")" = '2026-10-01T10:11:43Z' ] \
   && [ "$(cat "$LT/watch-cursor.walt_ui.txt")" = '2026-10-01T09:50:16Z' ] \
   && [ "$(cat "$LT/cursor.custom.txt")" = "${NOW_MINUS_14D}" ] \
   && [ ! -e "$LT/watch-cursor.custom.txt" ] && [ ! -e "$LT/cursor.gen_saas.txt" ]; then
  ok "QA9: absent cursors are seeded (watch repos from the shipwright's files; custom = now - 14 days)"
else
  bad "QA9 seed" "rc=$rc $(out) files=$(find "$LT" -type f -printf '%f ' 2>&1)"
fi

printf '2026-09-30T00:00:00Z\n' >"$LT/watch-cursor.gen_saas.txt"
printf '2026-09-29T00:00:00Z\n' >"$LT/cursor.custom.txt"
rm -f "$LT/watch-cursor.walt_ui.txt"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ "$(cat "$LT/watch-cursor.gen_saas.txt")" = '2026-09-30T00:00:00Z' ] \
   && [ "$(cat "$LT/cursor.custom.txt")" = '2026-09-29T00:00:00Z' ] \
   && [ "$(cat "$LT/watch-cursor.walt_ui.txt")" = '2026-10-01T09:50:16Z' ] \
   && grep -q 'kept' "${TMP}/inst.out"; then
  ok "QA9: existing cursors are never overwritten; only the absent one is seeded"
else
  bad "QA9 keep" "rc=$rc $(out)"
fi

shipwright_cursors
rm -f "$SW/lead-cursor.walt_ui.txt"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ ! -e "$LT/watch-cursor.walt_ui.txt" ] \
   && grep -q 'walt_ui' "${TMP}/inst.out" && grep -q '48h' "${TMP}/inst.out" \
   && [ -e "$LT/watch-cursor.gen_saas.txt" ]; then
  ok "QA9: a missing shipwright cursor leaves that repo's cursor absent, and the installer says so"
else
  bad "QA9 missing source" "rc=$rc $(out)"
fi

shipwright_cursors
printf 'null\n' >"$SW/lead-cursor.gen_saas.txt"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ ! -e "$LT/watch-cursor.gen_saas.txt" ] \
   && grep -q 'gen_saas' "${TMP}/inst.err" && grep -q 'not an RFC 3339' "${TMP}/inst.err"; then
  ok "QA9: a malformed shipwright cursor is not copied, and is named (never read as 'no cursor')"
else
  bad "QA9 malformed source" "rc=$rc $(out)"
fi

shipwright_cursors
cp "$IR/ai/config/lead-time-repos.json" "${TMP}/config.aside"
printf '{"repos":[{"name":"../x","path":"%s","mode":"watch"}],"window":20,"improvement_epic":"epic-id"}\n' "$CO/custom" \
  >"$IR/ai/config/lead-time-repos.json"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" -- --install)"
cp "${TMP}/config.aside" "$IR/ai/config/lead-time-repos.json"
if [ "$rc" = 2 ] && grep -q 'Fix:' "${TMP}/inst.err" && grep -q 'is not a plain name' "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && [ ! -e "$LT" ]; then
  ok "a repo name that is not a plain file-name label is refused before any write"
else
  bad "bad repo name" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'setup-leadtime-cron — which lines are ours (review round)'

ct="${TMP}/ct-ours"
printf '#30 * * * * %s\n0 * * * * %s.bak\n' "$IRUN" "$IRUN" >"$ct"
cp "$ct" "${TMP}/ct-ours.orig"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ "$(head -n 2 "$ct")" = "$(cat "${TMP}/ct-ours.orig")" ] && [ "$(tail -n 1 "$ct")" = "${ENTRY}" ] \
   && [ "$(wc -l <"$ct")" = 3 ]; then
  ok "--install keeps a commented-out entry and a longer runner path (<runner>.bak) byte for byte"
else
  bad "install keeps not-ours" "rc=$rc ct=$(cat -A "$ct")"
fi
rc="$(inst "$ct" -- --remove)"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "$(cat "${TMP}/ct-ours.orig")" ]; then
  ok "--remove keeps them too, and drops only the live entry"
else
  bad "remove keeps not-ours" "rc=$rc ct=$(cat -A "$ct")"
fi
rc="$(inst "$ct" -- --remove)"
if [ "$rc" = 0 ] && grep -q 'nothing removed' "${TMP}/inst.out" && [ "$(cat "$ct")" = "$(cat "${TMP}/ct-ours.orig")" ]; then
  ok "--remove with no entry says 'nothing removed'"
else
  bad "remove nothing" "rc=$rc $(out)"
fi

printf '30\t*\t*\t*\t*\t%s\n' "$IRUN" >"$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ]; then
  ok "--check reads a tab-separated entry as installed"
else
  bad "tab check" "rc=$rc $(out)"
fi
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "${ENTRY}" ]; then
  ok "--install replaces a tab-separated entry instead of adding a duplicate"
else
  bad "tab install" "rc=$rc ct=$(cat -A "$ct")"
fi

printf '0 * * * * /opt/other-job\n30 * * * * /gone/wt/scripts/athena-leadtime-run.sh\n' >"$ct"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && grep -qxF '30 * * * * /gone/wt/scripts/athena-leadtime-run.sh' "$ct" && grep -qxF "${ENTRY}" "$ct" \
   && grep -q 'WARNING' "${TMP}/inst.err" && grep -qF '/gone/wt/' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "--install keeps a stale runner line but names it (WARNING, Fix:), never silently"
else
  bad "stale on install" "rc=$rc ct=$(cat "$ct") $(out)"
fi

printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" FAKE_CRONTAB_WRITE_FAIL='crontab: write refused' -- --install)"
if [ "$rc" = 2 ] && grep -q 'could not write the crontab' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "a failed crontab write is exit 2 with Fix:, never a silent exit"
else
  bad "write fail install" "rc=$rc $(out)"
fi
printf '%s\n' "${ENTRY}" >"$ct"
rc="$(inst "$ct" FAKE_CRONTAB_WRITE_FAIL='crontab: write refused' -- --remove)"
if [ "$rc" = 2 ] && grep -q 'Fix:' "${TMP}/inst.err" && [ "$(cat "$ct")" = "${ENTRY}" ]; then
  ok "a failed crontab write on --remove is exit 2 with Fix:"
else
  bad "write fail remove" "rc=$rc $(out)"
fi
rc="$(inst "$ct" -- --check --install)"
if [ "$rc" = 1 ] && grep -q 'cannot be combined' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "two different mode flags are refused, never 'last one wins'"
else
  bad "mode conflict" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'setup-leadtime-cron — config and state faults (review round)'

cp "$IR/ai/config/lead-time-repos.json" "${TMP}/config.aside"
config_case() { # <label> <json> <the resolver's reason, as a grep -F needle>
  shipwright_cursors
  printf '0 * * * * /opt/other-job\n' >"$ct"
  printf '%s\n' "$2" >"$IR/ai/config/lead-time-repos.json"
  rc="$(inst "$ct" -- --install)"
  if [ "$rc" = 2 ] && grep -q 'Fix:' "${TMP}/inst.err" && grep -qF -- "$3" "${TMP}/inst.err" \
     && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] \
     && [ ! -e "$LT" ] && ! grep -q 'null' "${TMP}/inst.out"; then
    ok "config $1: refused (exit 2, Fix:) before any write; never a repo called 'null'"
  else
    bad "config $1" "rc=$rc $(out) files=$(find "$LT" -type f -printf '%f ' 2>/dev/null)"
  fi
}
TAIL='"window":20,"improvement_epic":"epic-id"'
config_case 'repo with no name'  "{\"repos\":[{\"path\":\"$CO/gen_saas\",\"mode\":\"watch\"}],$TAIL}" 'is missing name'
config_case 'repo with bad mode' "{\"repos\":[{\"name\":\"gen_saas\",\"path\":\"$CO/gen_saas\",\"mode\":\"tweak\"}],$TAIL}" 'mode'
config_case 'numeric name'       "{\"repos\":[{\"name\":5,\"path\":\"$CO/gen_saas\",\"mode\":\"watch\"}],$TAIL}" 'is not a plain name'
config_case 'invalid JSON'       '{"repos":[' 'not valid JSON'
config_case 'no .repos'          "{$TAIL}" 'repos'
config_case 'empty .repos'       "{\"repos\":[],$TAIL}" 'repos'
cp "${TMP}/config.aside" "$IR/ai/config/lead-time-repos.json"

shipwright_cursors
mkdir -p "$IR/ai-artifacts" && chmod 555 "$IR/ai-artifacts"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" -- --install)"
chmod 755 "$IR/ai-artifacts"
if [ "$rc" = 2 ] && grep -q 'Fix:' "${TMP}/inst.err" && grep -q 'crontab was not changed' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "an unwritable state dir: exit 2, Fix:, and the crontab is not changed"
else
  bad "unwritable state" "rc=$rc $(out)"
fi

shipwright_cursors
mkdir -p "$LT"; printf 'garbage\n' >"$LT/watch-cursor.gen_saas.txt"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && [ "$(cat "$LT/watch-cursor.gen_saas.txt")" = 'garbage' ] \
   && grep -q 'WARNING' "${TMP}/inst.err" && grep -q 'watch-cursor.gen_saas.txt' "${TMP}/inst.err"; then
  ok "a malformed existing cursor is kept (never overwritten) but named, never read as healthy"
else
  bad "malformed existing" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'setup-leadtime-cron — the repo list comes from ai/bin/lead-time-repos (DND-1527)'

shipwright_cursors
ct="${TMP}/ct-resolved"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 0 ] && grep -qF "Repos (ai/bin/lead-time-repos: source=default $IR/ai/config/lead-time-repos.json):" "${TMP}/inst.out" \
   && grep -qE '^  custom +improve ' "${TMP}/inst.out" && grep -qE '^  gen_saas +watch ' "${TMP}/inst.out" \
   && grep -q '0 skipped' "${TMP}/inst.out"; then
  ok "--install prints the resolved list, its source and its skip count"
else
  bad "install prints list" "rc=$rc $(out)"
fi

rm -f "$ct"; printf '%s\n' "${ENTRY}" >"$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ] && grep -q '^OK' "${TMP}/inst.out" && grep -qF 'source=default' "${TMP}/inst.out" \
   && grep -qE '^  custom +improve ' "${TMP}/inst.out" && grep -qE '^  walt_ui +watch ' "${TMP}/inst.out"; then
  ok "--check prints the resolved list (read-only)"
else
  bad "check prints list" "rc=$rc $(out)"
fi

# A repo not checked out on this machine: skipped by name, no cursor seeded.
shipwright_cursors
( umask 077; printf '{"repos":[{"name":"custom","path":"%s","mode":"improve"},{"name":"walt_ui","path":"%s","mode":"watch"}],"window":20,"improvement_epic":"epic-id"}\n' \
    "$CO/custom" "${TMP}/absent/walt_ui" >"${TMP}/override-skip.json" )
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" ATHENA_LEADTIME_CONFIG="${TMP}/override-skip.json" -- --install)"
if [ "$rc" = 0 ] && [ ! -e "$LT/watch-cursor.walt_ui.txt" ] && [ -e "$LT/cursor.custom.txt" ] \
   && [ ! -e "$LT/watch-cursor.gen_saas.txt" ] \
   && grep -qF "skipped walt_ui: no such path ${TMP}/absent/walt_ui" "${TMP}/inst.out" \
   && grep -qF 'source=override' "${TMP}/inst.out" && grep -qxF "${ENTRY}" "$ct"; then
  ok "a skipped repo gets no cursor and is printed by name; an override replaces the tracked list whole"
else
  bad "skipped repo" "rc=$rc $(out) files=$(find "$LT" -type f -printf '%f ' 2>/dev/null)"
fi

# A malformed override: exit 2, nothing written.
shipwright_cursors
( umask 077; printf '{"repos":[' >"${TMP}/override-bad.json" )
printf '0 * * * * /opt/other-job\n' >"$ct"; rm -f "$ct.calls"
rc="$(inst "$ct" ATHENA_LEADTIME_CONFIG="${TMP}/override-bad.json" -- --install)"
if [ "$rc" = 2 ] && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && [ ! -e "$LT" ] \
   && grep -q 'lead-time-repos exit 2' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
   && ! grep -qx -- '-' "$ct.calls"; then
  ok "a malformed override: exit 2 with the resolver's Fix:, the crontab unchanged and nothing seeded"
else
  bad "malformed override" "rc=$rc $(out)"
fi
printf '%s\n' "${ENTRY}" >"$ct"
rc="$(inst "$ct" ATHENA_LEADTIME_CONFIG="${TMP}/override-bad.json" -- --check)"
if [ "$rc" = 2 ] && grep -q 'does not resolve' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = "${ENTRY}" ]; then
  ok "--check with the entry but a list that does not resolve is red (exit 2), never OK"
else
  bad "check unresolved" "rc=$rc $(out)"
fi

# Zero repos checked out: the resolver's exit 4 is refused, not an empty install.
shipwright_cursors
( umask 077; printf '{"repos":[{"name":"custom","path":"%s","mode":"improve"}],"window":20,"improvement_epic":"epic-id"}\n' \
    "${TMP}/absent/custom" >"${TMP}/override-none.json" )
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" ATHENA_LEADTIME_CONFIG="${TMP}/override-none.json" -- --install)"
if [ "$rc" = 2 ] && grep -q 'lead-time-repos exit 4' "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] \
   && [ ! -e "$LT" ]; then
  ok "zero resolved repos: install refused (exit 2), nothing written"
else
  bad "zero repos" "rc=$rc $(out)"
fi

# The resolver missing from the main checkout: refused, never a jq read of the file.
shipwright_cursors
mv "$IR/ai/bin/lead-time-repos" "${TMP}/resolver.aside"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" -- --install)"
mv "${TMP}/resolver.aside" "$IR/ai/bin/lead-time-repos"
if [ "$rc" = 2 ] && grep -qF "lead-time-repos not run): $IR/ai/bin/lead-time-repos is absent" "${TMP}/inst.err" \
   && grep -qF 'Fix: land ai/bin/lead-time-repos (DND-1526) on main' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && [ ! -e "$LT" ]; then
  ok "the resolver missing from the main checkout: install refused (exit 2), nothing written"
else
  bad "resolver missing" "rc=$rc $(out)"
fi

# The --json reader lib (DND-1604) missing from the main checkout: --install
# refuses before any write, and --check is red with an installed entry, each
# naming the lib with a Fix:. It is the MAIN checkout's copy, the runner's.
shipwright_cursors
mv "$IR/scripts/lib/lead-time-repos.sh" "${TMP}/repos-lib.aside"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 2 ] && grep -qF "lead-time-repos not run): $IR/scripts/lib/lead-time-repos.sh is missing from the main checkout" "${TMP}/inst.err" \
   && grep -qF 'Fix: land scripts/lib/lead-time-repos.sh (DND-1604) on main' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && [ ! -e "$LT" ]; then
  ok "the --json reader lib missing from the main checkout: install refused (exit 2), nothing written"
else
  bad "reader lib missing (install)" "rc=$rc $(out)"
fi
printf '0 * * * * /opt/other-job\n%s\n' "${ENTRY}" >"$ct"
rc="$(inst "$ct" -- --check)"
mv "${TMP}/repos-lib.aside" "$IR/scripts/lib/lead-time-repos.sh"
if [ "$rc" = 2 ] && grep -qF "$IR/scripts/lib/lead-time-repos.sh is missing from the main checkout" "${TMP}/inst.err" \
   && grep -q 'every tick would exit 78' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" && ! grep -q '^OK' "${TMP}/inst.out"; then
  ok "--check with the --json reader lib missing from the main checkout: exit 2 naming it, Fix:, never OK"
else
  bad "reader lib missing (check)" "rc=$rc $(out)"
fi
# Present but defining nothing (a truncated file): refused, naming the function.
cp "$IR/scripts/lib/lead-time-repos.sh" "${TMP}/repos-lib.aside"
: >"$IR/scripts/lib/lead-time-repos.sh"
rc="$(inst "$ct" -- --check)"
cp "${TMP}/repos-lib.aside" "$IR/scripts/lib/lead-time-repos.sh"
if [ "$rc" = 2 ] && grep -qF "$IR/scripts/lib/lead-time-repos.sh could not be loaded or does not define lt_repos_resolve" "${TMP}/inst.err" \
   && grep -q 'Fix: restore scripts/lib/lead-time-repos.sh' "${TMP}/inst.err" && ! grep -q '^OK' "${TMP}/inst.out"; then
  ok "--check with an empty --json reader lib: exit 2 naming lt_repos_resolve, Fix:, never OK"
else
  bad "reader lib empty (check)" "rc=$rc $(out)"
fi
# Present but unreadable is its own fault, never reported as missing.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$IR/scripts/lib/lead-time-repos.sh"
  rc="$(inst "$ct" -- --check)"
  chmod 644 "$IR/scripts/lib/lead-time-repos.sh"
  if [ "$rc" = 2 ] && grep -qF "$IR/scripts/lib/lead-time-repos.sh is unreadable" "${TMP}/inst.err" \
     && grep -qF 'Fix: restore read permission on it (chmod u+r' "${TMP}/inst.err" && ! grep -q 'is missing' "${TMP}/inst.err"; then
    ok "--check with the --json reader lib unreadable: exit 2, says unreadable (not missing), Fix: chmod"
  else
    bad "reader lib unreadable (check)" "rc=$rc $(out)"
  fi
fi

# ===========================================================================
case_ 'setup-leadtime-cron — the runner MCP preflight (DND-1571)'

# cj_variant <name> <jq filter> — a copy of the fake config, edited.
cj_variant() { jq --arg p "$IR" "$2" "$CJ" >"${TMP}/$1.json"; printf '%s' "${TMP}/$1.json"; }
CJ_NO_NOTION="$(cj_variant no-notion 'del(.projects[$p].mcpServers["notion-personal"]) | .projects[$p].mcpServers.other = {type: "stdio", command: "/x/other"}')"
CJ_NO_KEY="$(cj_variant no-key 'del(.projects[$p])')"
printf '{not json' >"${TMP}/corrupt.json"

ct="${TMP}/ct-mcp"
printf '0 * * * * /opt/other-job\n%s\n' "${ENTRY}" >"$ct"
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${CJ_NO_NOTION}" -- --check)"
if [ "$rc" = 2 ] && grep -q 'NOT REGISTERED' "${TMP}/inst.err" && grep -q 'Fix:.*scripts/add-notion --personal.*notion-personal' "${TMP}/inst.err" \
   && ! grep -q '^OK' "${TMP}/inst.out" && ! grep -q 'COULD NOT LOOK' "${TMP}/inst.err"; then
  ok "--check with notion-personal not registered: exit 2, NOT REGISTERED, Fix: names the server and how to register it"
else
  bad "check mcp missing" "rc=$rc $(out)"
fi
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${CJ_NO_KEY}" -- --check)"
if [ "$rc" = 2 ] && grep -q 'NOT REGISTERED' "${TMP}/inst.err" && grep -qF "'$IR'" "${TMP}/inst.err" && grep -q 'Fix:.*notion-personal' "${TMP}/inst.err"; then
  ok "--check with no servers under the main checkout's key: NOT REGISTERED, names the key it searched"
else
  bad "check mcp no key" "rc=$rc $(out)"
fi
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${TMP}/absent.json" -- --check)"
if [ "$rc" = 4 ] && grep -q 'COULD NOT LOOK' "${TMP}/inst.err" && grep -qF "${TMP}/absent.json" "${TMP}/inst.err" \
   && grep -q 'Fix:' "${TMP}/inst.err" && ! grep -q 'NOT REGISTERED' "${TMP}/inst.err"; then
  ok "--check with the Claude config missing: exit 4, COULD NOT LOOK, never 'not registered'"
else
  bad "check config missing" "rc=$rc $(out)"
fi
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${TMP}/corrupt.json" -- --check)"
if [ "$rc" = 4 ] && grep -q 'COULD NOT LOOK' "${TMP}/inst.err" && grep -q 'not valid JSON' "${TMP}/inst.err" \
   && ! grep -q 'NOT REGISTERED' "${TMP}/inst.err"; then
  ok "--check with an invalid Claude config: exit 4, COULD NOT LOOK"
else
  bad "check config corrupt" "rc=$rc $(out)"
fi
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ] && grep -q '^OK' "${TMP}/inst.out" && grep -q 'MCP.*notion-personal' "${TMP}/inst.out"; then
  ok "--check with notion-personal registered: exit 0, and says the MCP preflight passed"
else
  bad "check mcp ok" "rc=$rc $(out)"
fi
# A wrongly computed key: servers registered under the linked worktree's path
# only. Run from that worktree, --check must look under the MAIN checkout's
# key (the one the cron tick uses) and say NOT REGISTERED, never OK.
CJ_WT_ONLY="${TMP}/wt-only.json"
jq -n --arg p "$WT" '{projects: {($p): {mcpServers: {"notion-personal": {type: "stdio", command: "/x/n"}}}}}' >"${CJ_WT_ONLY}"
rc="$(INST="$WT/scripts/setup-leadtime-cron" inst "$ct" LEADTIME_CLAUDE_JSON="${CJ_WT_ONLY}" -- --check)"
if [ "$rc" = 2 ] && grep -q 'NOT REGISTERED' "${TMP}/inst.err" && grep -qF "'$IR'" "${TMP}/inst.err" \
   && grep -q '(1 project(s) have any)' "${TMP}/inst.err" && ! grep -q '^OK' "${TMP}/inst.out"; then
  ok "--check from a worktree with servers registered only under the worktree's key: NOT REGISTERED, names the main checkout's key"
else
  bad "check wrong key" "rc=$rc $(out)"
fi
# The installer runs the MAIN checkout's preflight, the copy the cron runner
# loads, never the copy beside it in a worktree.
cp "$WT/scripts/lib/mcp-preflight.sh" "${TMP}/wt-lib.aside"
printf '\nLEADTIME_MCP_REQUIRED="notion-personal bogus-server"\n' >>"$WT/scripts/lib/mcp-preflight.sh"
rc="$(INST="$WT/scripts/setup-leadtime-cron" inst "$ct" -- --check)"
cp "${TMP}/wt-lib.aside" "$WT/scripts/lib/mcp-preflight.sh"
if [ "$rc" = 0 ] && grep -q '^OK' "${TMP}/inst.out" && ! grep -q 'bogus-server' "${TMP}/inst.out" "${TMP}/inst.err"; then
  ok "--check from a worktree uses the main checkout's preflight, not the worktree's copy"
else
  bad "check main lib" "rc=$rc $(out)"
fi
mv "$IR/scripts/lib/mcp-preflight.sh" "${TMP}/main-lib.aside"
rc="$(inst "$ct" -- --check)"
mv "${TMP}/main-lib.aside" "$IR/scripts/lib/mcp-preflight.sh"
if [ "$rc" = 4 ] && grep -q 'COULD NOT LOOK' "${TMP}/inst.err" && grep -q 'missing from the main checkout' "${TMP}/inst.err" \
   && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "--check with the preflight library missing from the main checkout: exit 4, COULD NOT LOOK, Fix:"
else
  bad "check lib missing" "rc=$rc $(out)"
fi
printf '{"projects": "not an object"}\n' >"${TMP}/shape.json"
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${TMP}/shape.json" -- --check)"
if [ "$rc" = 4 ] && grep -q 'COULD NOT LOOK' "${TMP}/inst.err" && grep -q 'not the shape' "${TMP}/inst.err" \
   && ! grep -q 'NOT REGISTERED' "${TMP}/inst.err"; then
  ok "--check with valid JSON of the wrong shape: COULD NOT LOOK, never 'not registered'"
else
  bad "check config shape" "rc=$rc $(out)"
fi

mv "$IR/ai/skills/athena:lead-time-improve/SKILL.md" "${TMP}/skill.aside"
rc="$(inst "$ct" -- --check)"
mv "${TMP}/skill.aside" "$IR/ai/skills/athena:lead-time-improve/SKILL.md"
if [ "$rc" = 2 ] && grep -q 'lead-time-improve skill is not in the main checkout' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
   && ! grep -q '^OK' "${TMP}/inst.out"; then
  ok "--check with the skill not in the main checkout: exit 2 (every tick would exit 78), never OK"
else
  bad "check skill missing" "rc=$rc $(out)"
fi
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${TMP}/absent.json" -- --check)"
if [ "$rc" = 1 ] && grep -q 'MISSING' "${TMP}/inst.err" && grep -q 'COULD NOT LOOK' "${TMP}/inst.err"; then
  ok "--check with no entry AND no config: exit 1 (MISSING), and the preflight fault is named too"
else
  bad "check missing + no config" "rc=$rc $(out)"
fi

shipwright_cursors
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${CJ_NO_NOTION}" -- --install)"
if [ "$rc" = 2 ] && grep -q 'NOT REGISTERED' "${TMP}/inst.err" && grep -q 'Fix:.*notion-personal' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && [ ! -e "$LT" ]; then
  ok "--install with notion-personal not registered: refused (exit 2), no entry, no cursor"
else
  bad "install mcp missing" "rc=$rc ct=$(cat "$ct") $(out)"
fi
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${TMP}/corrupt.json" -- --install)"
if [ "$rc" = 4 ] && grep -q 'COULD NOT LOOK' "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && [ ! -e "$LT" ]; then
  ok "--install with an invalid Claude config: refused (exit 4), nothing written"
else
  bad "install config corrupt" "rc=$rc $(out)"
fi
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${CJ_NO_NOTION}" -- --dry-run)"
if [ "$rc" = 2 ] && grep -q 'Fix:.*notion-personal' "${TMP}/inst.err" && ! grep -q 'would install' "${TMP}/inst.out"; then
  ok "--dry-run with notion-personal not registered: exit 2 with the same Fix:, no plan printed"
else
  bad "dry-run mcp missing" "rc=$rc $(out)"
fi
rc="$(inst "$ct" LEADTIME_CLAUDE_JSON="${CJ_NO_NOTION}" -- --remove)"
if [ "$rc" = 0 ]; then
  ok "--remove never runs the preflight (removing must work on a broken machine)"
else
  bad "remove mcp missing" "rc=$rc $(out)"
fi

# ===========================================================================
case_ "setup-leadtime-cron — the runner's own --dry-run (DND-1728)"

# The runner's dry run checks what this installer does not (the scripts/lib
# files a tick loads). A stub runner stands in: it logs its argv, then exits as
# the case says. Synthetic text only.
STUB_LOG="${TMP}/stub-runner.args"
stub_runner() { # <exit> — the stub refuses with a reason and a Fix: unless <exit> is 0
  printf '#!/usr/bin/env bash\necho "$*" >>%q\n' "$STUB_LOG" >"$IRUN"
  if [ "$1" != 0 ]; then
    printf 'echo "athena-leadtime: /x/scripts/lib/dbus-env.sh could not be loaded, so D-Bus autolaunch cannot be suppressed; a tick would exit 78 and spawn no session." >&2\n' >>"$IRUN"
    printf 'echo "  Fix: restore the synthetic lib." >&2\n' >>"$IRUN"
  fi
  printf 'exit %s\n' "$1" >>"$IRUN"
  chmod +x "$IRUN"
}
ct="${TMP}/ct-dry"
shipwright_cursors
printf '# mine\n' >"$ct"
stub_runner 0; rm -f "$STUB_LOG"
rc="$(inst "$ct" -- --install)"
rc2="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ "$(grep -cx -- '--dry-run' "$STUB_LOG" 2>/dev/null)" = 2 ]; then
  ok "--install and --check each run the runner's own --dry-run, and pass when it passes"
else
  bad "runner dry run passes" "rc=$rc rc2=$rc2 args=$(cat "$STUB_LOG" 2>&1) $(out)"
fi
stub_runner 78
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 2 ] && grep -qF "the runner's own --dry-run refuses (${IRUN} --dry-run, exit 78)" "${TMP}/inst.err" \
   && grep -q 'dbus-env.sh could not be loaded' "${TMP}/inst.err" && grep -q 'Fix: restore the synthetic lib.' "${TMP}/inst.err" \
   && ! grep -q '^OK' "${TMP}/inst.out"; then
  ok "--check with a live entry is red (exit 2) when the runner's --dry-run refuses, quoting its reason and Fix:"
else
  bad "check runner dry run refuses" "rc=$rc $(out)"
fi
shipwright_cursors
before="$(cat "$ct")"
rc="$(inst "$ct" -- --install)"
if [ "$rc" = 2 ] && [ "$(cat "$ct")" = "$before" ] && [ ! -e "$LT" ] && grep -q 'Nothing was written' "${TMP}/inst.err"; then
  ok "--install is refused (exit 2) when the runner's --dry-run refuses: no crontab write, no cursor"
else
  bad "install runner dry run refuses" "rc=$rc ct=$(cat "$ct") lt=$(ls "$LT" 2>&1) $(out)"
fi
rc="$(inst "$ct" -- --dry-run)"
if [ "$rc" = 2 ] && ! grep -q 'would install' "${TMP}/inst.out" && grep -q "runner's own --dry-run refuses" "${TMP}/inst.err"; then
  ok "--dry-run is refused (exit 2) the same way, with no plan printed"
else
  bad "dry-run runner dry run refuses" "rc=$rc $(out)"
fi
rm -f "$STUB_LOG"
rc="$(inst "$ct" -- --remove)"
if [ "$rc" = 0 ] && [ ! -e "$STUB_LOG" ]; then
  ok "--remove never runs the runner's --dry-run (removing must work on a broken machine)"
else
  bad "remove runs dry run" "rc=$rc args=$(cat "$STUB_LOG" 2>&1) $(out)"
fi
stub_runner 0

if poisoned; then
  bad "no case reached the real crontab" "calls: $(cat "$POISON")"
else
  ok "no case reached the real crontab (the poisoned PATH crontab never ran)"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || {
  printf 'Fix: read each FAIL line above; it names the guarantee that broke. Re-run with: bash ai/test/setup-leadtime-cron/self-test.sh\n' >&2
  exit 1
}
exit 0
