#!/usr/bin/env bash
# Self-test for scripts/setup-shipwright-cron (DND-1503).
#
# Run: bash scripts/test/setup-shipwright-cron/self-test.sh
#
# Nothing real is touched:
#   * the installer runs from a throwaway copy of scripts/ (the installer, its
#     libs and a stub runner), so RUNNER is a temp path;
#   * `crontab` first on PATH is a fake backed by a file, so the real crontab is
#     never read or written;
#   * `sudo` first on PATH records and refuses, so no case can reach root.
#
# The DND-1503 cases: only the exact managed entry is ours. A commented-out
# entry, a <runner>.bak line, and a longer path that contains the runner path
# are kept by --install and --remove, and none of them makes --check green.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
INSTALLER="${SCRIPTS}/setup-shipwright-cron"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()    { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
case_() { printf '\n%s\n' "$1"; }

BIN="${TMP}/bin"; mkdir -p "$BIN"
cat >"$BIN/crontab" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_CRONTAB}.calls"
case "$1" in
  -l) if [ -n "${FAKE_CRONTAB_FAIL:-}" ]; then echo "${FAKE_CRONTAB_FAIL}" >&2; exit 1; fi
      [ -e "$FAKE_CRONTAB" ] || { echo "no crontab for $(id -un)" >&2; exit 1; }
      cat "$FAKE_CRONTAB" ;;
  -)  cat >"$FAKE_CRONTAB" ;;
  *)  echo "fake crontab: unsupported $*" >&2; exit 9 ;;
esac
EOF
cat >"$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_CRONTAB}.sudo"
echo "fake sudo: refused" >&2
exit 1
EOF
chmod +x "$BIN/crontab" "$BIN/sudo"

# A throwaway scripts/ dir: the installer, the libs it sources, a stub runner.
IS="${TMP}/inst/scripts"; mkdir -p "$IS"
cp "$INSTALLER" "$IS/"
cp -r "${SCRIPTS}/lib" "$IS/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$IS/athena-shipwright-run.sh"
chmod +x "$IS/athena-shipwright-run.sh"
IS="$(cd -- "$IS" && pwd -P)"
RUN="$IS/athena-shipwright-run.sh"
ENTRY="0 * * * * ${RUN}"

inst() { # <crontab-file> [args...]   (FAKE_CRONTAB_FAIL from the caller's env)
  local f="$1"; shift
  env PATH="$BIN:$PATH" FAKE_CRONTAB="$f" FAKE_CRONTAB_FAIL="${FAKE_CRONTAB_FAIL:-}" "$IS/setup-shipwright-cron" "$@" \
    >"${TMP}/inst.out" 2>"${TMP}/inst.err"
  printf '%s' "$?"
}
out() { cat "${TMP}/inst.out" "${TMP}/inst.err"; }

# ===========================================================================
case_ 'setup-shipwright-cron — install, idempotence, check, remove'

ct="${TMP}/ct-basic"
printf '# owner comment\n0 7 * * * /opt/other-job --flag\n' >"$ct"
rc="$(inst "$ct")"
if [ "$rc" = 0 ] && [ "$(grep -cxF "$ENTRY" "$ct")" = 1 ] && grep -qx '# owner comment' "$ct" \
   && grep -qxF '0 7 * * * /opt/other-job --flag' "$ct"; then
  ok "install adds exactly one entry and keeps every other line"
else
  bad "install" "rc=$rc ct=$(cat "$ct") $(out)"
fi
rc="$(inst "$ct" --schedule '15 * * * *')"
if [ "$rc" = 0 ] && [ "$(grep -cF "$RUN" "$ct")" = 1 ] && grep -qxF "15 * * * * ${RUN}" "$ct"; then
  ok "re-running updates the schedule in place (still one entry)"
else
  bad "idempotent" "rc=$rc ct=$(cat "$ct")"
fi
rc="$(inst "$ct" --check)"
if [ "$rc" = 0 ] && grep -q '^OK' "${TMP}/inst.out"; then
  ok "--check is green once the entry is live"
else
  bad "check present" "rc=$rc $(out)"
fi
rc="$(inst "$ct" --remove)"
if [ "$rc" = 0 ] && ! grep -qF "$RUN" "$ct" && grep -qxF '0 7 * * * /opt/other-job --flag' "$ct"; then
  ok "--remove drops only the shipwright entry"
else
  bad "remove" "rc=$rc ct=$(cat "$ct")"
fi
rc="$(inst "$ct" --check)"
if [ "$rc" = 1 ] && grep -q 'MISSING' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "--check is red (exit 1, MISSING, Fix:) once the entry is gone"
else
  bad "check absent" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'setup-shipwright-cron — which lines are ours (DND-1503)'

# Not ours, each kept byte for byte: a commented-out entry, a longer runner
# path (<runner>.bak), and a longer path that contains the runner path.
NOT_OURS="$(printf '#0 * * * * %s\n0 * * * * %s.bak\n0 * * * * /backup%s\n' "$RUN" "$RUN" "$RUN")"
ct="${TMP}/ct-ours"
printf '%s\n' "$NOT_OURS" >"$ct"
rc="$(inst "$ct")"
if [ "$rc" = 0 ] && [ "$(head -n 3 "$ct")" = "$NOT_OURS" ] && [ "$(tail -n 1 "$ct")" = "$ENTRY" ] \
   && [ "$(wc -l <"$ct")" = 4 ]; then
  ok "install keeps a commented-out entry, <runner>.bak and a longer path byte for byte"
else
  bad "install keeps not-ours" "rc=$rc ct=$(cat -A "$ct")"
fi
rc="$(inst "$ct" --remove)"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "$NOT_OURS" ]; then
  ok "--remove keeps them too, and drops only the live entry"
else
  bad "remove keeps not-ours" "rc=$rc ct=$(cat -A "$ct")"
fi
printf '%s\n' "$NOT_OURS" >"$ct"
rc="$(inst "$ct" --check)"
if [ "$rc" = 1 ] && grep -q 'MISSING' "${TMP}/inst.err" && [ "$(cat "$ct")" = "$NOT_OURS" ]; then
  ok "--check is red when only a commented-out entry and longer paths remain"
else
  bad "check not-ours" "rc=$rc $(out)"
fi
printf '0\t*\t*\t*\t*\t%s\n' "$RUN" >"$ct"
rc="$(inst "$ct" --check)"
if [ "$rc" = 0 ]; then
  ok "--check reads a tab-separated entry as installed"
else
  bad "tab check" "rc=$rc $(out)"
fi
rc="$(inst "$ct")"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "$ENTRY" ]; then
  ok "install rewrites a tab-separated entry as the one canonical entry"
else
  bad "tab install" "rc=$rc ct=$(cat -A "$ct")"
fi

# ===========================================================================
case_ 'setup-shipwright-cron — a missing matcher is refused, never read as empty'

NL="${TMP}/nolib/scripts"; mkdir -p "$NL"
cp "$INSTALLER" "$IS/athena-shipwright-run.sh" "$NL/"
ct="${TMP}/ct-nolib"
printf '%s\n%s\n' "$NOT_OURS" "$ENTRY" >"$ct"
cp "$ct" "${TMP}/ct-nolib.orig"
for args in "" "--remove" "--check"; do
  # shellcheck disable=SC2086
  env PATH="$BIN:$PATH" FAKE_CRONTAB="$ct" "$NL/setup-shipwright-cron" $args >"${TMP}/inst.out" 2>"${TMP}/inst.err"
  rc=$?
  if [ "$rc" = 2 ] && grep -q 'cron-entry.sh' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
     && cmp -s "$ct" "${TMP}/ct-nolib.orig"; then
    ok "no scripts/lib/cron-entry.sh: '${args:-install}' is exit 2 with Fix:, the crontab unchanged"
  else
    bad "nolib ${args:-install}" "rc=$rc $(out) ct=$(cat "$ct")"
  fi
done

# ===========================================================================
case_ 'setup-shipwright-cron — a crontab that cannot be read is never written (DND-1638)'

# crontab -l failing for any reason but "no crontab for <user>" used to read as
# an empty crontab, so --install wrote back only its own line and --remove
# wrote back nothing: every other entry was deleted. The message is cronie's
# perror() shape, with a synthetic path.
DENIED='/var/spool/cron/crontabs/u: Permission denied'
ct="${TMP}/ct-denied"
printf '0 7 * * * /opt/other-job\n30 * * * * /opt/leadtime-job\n' >"$ct"
cp "$ct" "${TMP}/ct-denied.orig"
for args in "" "--remove" "--dry-run"; do
  # shellcheck disable=SC2086
  rc="$(FAKE_CRONTAB_FAIL="$DENIED" inst "$ct" $args)"
  if [ "$rc" = 2 ] && grep -q 'could not read the current crontab' "${TMP}/inst.err" \
     && grep -q 'Permission denied' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
     && cmp -s "$ct" "${TMP}/ct-denied.orig" && ! grep -qx -- '-' "${ct}.calls"; then
    ok "unreadable crontab: '${args:-install}' is exit 2 with Fix:, nothing written"
  else
    bad "unreadable ${args:-install}" "rc=$rc $(out) ct=$(cat "$ct") calls=$(cat "${ct}.calls" 2>&1)"
  fi
done
rc="$(FAKE_CRONTAB_FAIL="$DENIED" inst "$ct" --check)"
if [ "$rc" = 2 ] && grep -q 'could not read the current crontab' "${TMP}/inst.err" \
   && ! grep -q 'MISSING' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "unreadable crontab: --check is exit 2 'could not read', never MISSING"
else
  bad "unreadable --check" "rc=$rc $(out)"
fi
ct="${TMP}/ct-none"
rm -f "$ct"
rc="$(inst "$ct")"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "$ENTRY" ]; then
  ok "'no crontab for <user>' is still an empty crontab: install writes the one entry"
else
  bad "no crontab install" "rc=$rc $(out) ct=$(cat "$ct" 2>&1)"
fi
rm -f "$ct"
rc="$(inst "$ct" --check)"
if [ "$rc" = 1 ] && grep -q 'MISSING' "${TMP}/inst.err"; then
  ok "'no crontab for <user>': --check is MISSING (exit 1), not a read failure"
else
  bad "no crontab check" "rc=$rc $(out)"
fi

# ===========================================================================
case_ 'no case reached root'
if compgen -G "${TMP}/*.sudo" >/dev/null; then
  bad "no case ran sudo" "calls: $(cat "${TMP}"/*.sudo 2>&1)"
else
  ok "no case ran sudo"
fi

printf '\n'
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf 'VERDICT: PASS (%d cases)\n' "$TOTAL"
  exit 0
fi
printf 'VERDICT: FAIL (%d of %d cases)\n' "$FAIL" "$TOTAL"
printf '  Fix: read each FAIL above; the claim names the behaviour it protects.\n'
printf '       Repair scripts/setup-shipwright-cron or scripts/lib/cron-entry.sh,\n'
printf '       then re-run bash scripts/test/setup-shipwright-cron/self-test.sh.\n'
exit 1
