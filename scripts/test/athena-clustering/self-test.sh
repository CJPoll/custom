#!/usr/bin/env bash
# Self-test for scripts/athena-clustering-run.sh and scripts/setup-clustering-cron
# (DND-983).
#
# Run: bash scripts/test/athena-clustering/self-test.sh
#
# Nothing real is touched, with one exception: each runner case runs the real
# scripts/reap-orphan-dbus, which reaps only genuinely orphaned autolaunch
# D-Bus daemons older than 5 minutes (the same best-effort call the cron makes).
# Otherwise:
#   * the runner runs against a THROWAWAY git repo (CLUSTERING_REPO), a fake
#     ~/.claude.json (CLUSTERING_CLAUDE_JSON) and a STUB claude
#     (CLUSTERING_CLAUDE) that records how it was called. No model runs.
#   * the installer runs against a FAKE `crontab` first on PATH, backed by a
#     file. The real crontab is never read or written.
#   * ATHENA_INBOX_ROOT is pinned to a temp dir, so a wedge alert never reaches
#     the live harness-alerts channel.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPTS}/.." && pwd -P)"
RUNNER="${SCRIPTS}/athena-clustering-run.sh"
INSTALLER="${SCRIPTS}/setup-clustering-cron"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
HOLDER_PID=""
cleanup() {
  if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

ok()    { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
case_() { printf '\n%s\n' "$1"; }

# --- the inbox is pinned for the whole suite ---------------------------------
export ATHENA_INBOX_ROOT="${TMP}/inbox-root"
unset CLAUDE_AGENT_ID CLAUDE_AGENT_TYPE DRY_RUN
install_inbox_registry() { # <root>
  local common
  common="$(cd -- "${REPO_ROOT}" && realpath -- "$(git rev-parse --git-common-dir)")"
  mkdir -p "$1/projects"; chmod 700 "$1" "$1/projects"
  jq --arg r "${common}" '.projects[] | select(.file == "custom.json") | .entry | .repo = $r' \
    "${REPO_ROOT}/ai/inbox/registry.json" >"$1/projects/custom.json"
  chmod 600 "$1/projects/custom.json"
}
install_inbox_registry "${ATHENA_INBOX_ROOT}"
case "${ATHENA_INBOX_ROOT}" in
  "${TMP}"/*) ;;
  *) echo "self-test: ATHENA_INBOX_ROOT is not under ${TMP}; refusing to run." >&2
     echo "  Fix: this is a bug in the suite's setup; the pin must run before any case." >&2
     exit 2 ;;
esac
ALERTS="${ATHENA_INBOX_ROOT}/harness-alerts/to-custom"
wedge_count() { find "${ALERTS}" -maxdepth 1 -type f -name '*-clustering-wedged.md' 2>/dev/null | grep -c . || true; }
wedge_msg()   { find "${ALERTS}" -maxdepth 1 -type f -name '*-clustering-wedged.md' 2>/dev/null | sort | tail -n1; }
clear_alerts() { find "${ALERTS}" -maxdepth 1 -type f -name '*.md' -delete 2>/dev/null || true; }

# 2026-09-27 07:00 and 19:00 America/Denver (MDT, UTC-6).
MORNING="$(date -d '2026-09-27 13:00 UTC' +%s)"
EVENING="$(date -d '2026-09-28 01:00 UTC' +%s)"

# --- fixtures ----------------------------------------------------------------
# A case dir holds a throwaway repo, a fake ~/.claude.json and a stub claude.
# The stub's behaviour is the word in <case>/mode.
new_case() {
  local c r
  c="$(mktemp -d -p "$TMP" case.XXXXXX)"; r="$c/repo"
  mkdir -p "$r/ai/skills/athena:epic-clustering"
  printf -- '---\nname: athena:epic-clustering\n---\n' >"$r/ai/skills/athena:epic-clustering/SKILL.md"
  # The drain request's reader (DND-987), present by default.
  mkdir -p "$r/ai/skills/athena:inbox-attend"
  printf 'A message whose filename ends `-harness-lane-drain.md` wakes the harness lane.\n' \
    >"$r/ai/skills/athena:inbox-attend/SKILL.md"
  git -C "$r" init -q -b main >&2
  git -C "$r" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty -m seed >&2
  r="$(cd -- "$r" && pwd -P)"
  jq -n --arg p "$r" '{projects: {($p): {mcpServers: {
      "notion-personal": {type: "stdio", command: "/x/notion-athena-mcp", args: [], env: {NOTION_ATHENA_TOKEN_FILE: "/x/token"}},
      "athena": {type: "http", url: "https://example.invalid/mcp", headersHelper: "/x/athena-mcp-headers"}}}}}' \
    >"$c/claude.json"
  cat >"$c/stub-claude" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
echo x >>"$d/claude-invoked"
printf '%s\n' "$@" >"$d/claude-args"
pwd -P >"$d/claude-cwd"
if [ -e /proc/self/fd/9 ]; then echo open >"$d/claude-fd9"; else echo closed >"$d/claude-fd9"; fi
prev=""
for a in "$@"; do
  if [ "$prev" = "--mcp-config" ]; then cp -- "$a" "$d/claude-mcp.json"; stat -c %a -- "$a" >"$d/claude-mcp.mode"; fi
  prev="$a"
done
case "$(cat "$d/mode" 2>/dev/null || echo ok)" in
  ok)        : >"$CLUSTERING_RECEIPT"; echo "moved 2, merged 1, closed 0" >"$CLUSTERING_SUMMARY"; exit 0 ;;
  fail)      : >"$CLUSTERING_RECEIPT"; echo "the pass fell over"; exit 7 ;;
  nosummary) : >"$CLUSTERING_RECEIPT"; exit 0 ;;
  blocked0)  exit 0 ;;
  limit)     echo "You've hit your weekly limit"; exit 1 ;;
  crash)     echo "segmentation fault"; exit 3 ;;
esac
EOF
  chmod +x "$c/stub-claude"
  printf '%s' "$c"
}
repo_of() { printf '%s/repo' "$1"; }
sd() { printf '%s/repo/ai-artifacts/clustering' "$1"; }
invoked() { [ -e "$1/claude-invoked" ] && grep -c . "$1/claude-invoked" || echo 0; }
newest() { find "$(sd "$1")/runs" -maxdepth 1 -name "*.$2" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -n1 | cut -d" " -f2-; }

# run_runner <case> [VAR=val ...] [-- runner args] -> prints the exit code.
run_runner() {
  local c="$1"; shift
  local envs=() args=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; args=("$@"); break; fi
    envs+=("$1"); shift
  done
  env CLUSTERING_REPO="$(repo_of "$c")" CLUSTERING_CLAUDE="$c/stub-claude" \
      CLUSTERING_CLAUDE_JSON="$c/claude.json" CLUSTERING_NOW="$MORNING" \
      "${envs[@]}" "$RUNNER" "${args[@]}" >"$c/runner.out" 2>"$c/runner.err"
  printf '%s' "$?"
}

# ---------------------------------------------------------------------------
case_ 'athena-clustering-run.sh — --help and --dry-run have no side effects'

c="$(new_case)"
rc="$(run_runner "$c" -- --help)"
if [ "$rc" = 0 ] && grep -q 'Usage:' "$c/runner.out" && [ ! -s "$c/runner.err" ] \
   && [ ! -e "$(sd "$c")" ] && [ "$(invoked "$c")" = 0 ]; then
  ok "--help prints usage on stdout, exits 0, creates no state and runs no session"
else
  bad "--help" "rc=$rc out=$(head -3 "$c/runner.out") err=$(cat "$c/runner.err") state=$(ls -d "$(sd "$c")" 2>&1)"
fi

rc="$(run_runner "$c" -- --dry-run)"
if [ "$rc" = 0 ] && grep -q 'athena:epic-clustering' "$c/runner.out" && grep -q 'athena-architect' "$c/runner.out" \
   && grep -q 'daily digest' "$c/runner.out" && grep -q '2026-09-27' "$c/runner.out" \
   && [ ! -e "$(sd "$c")" ] && [ "$(invoked "$c")" = 0 ]; then
  ok "--dry-run prints the morning brief (digest due) and touches nothing"
else
  bad "--dry-run morning" "rc=$rc out=$(cat "$c/runner.out") err=$(cat "$c/runner.err")"
fi

rc="$(run_runner "$c" CLUSTERING_NOW="$EVENING" DRY_RUN=1)"
if [ "$rc" = 0 ] && grep -q 'NOT the morning run' "$c/runner.out" && grep -q 'Do NOT send the daily digest' "$c/runner.out" \
   && [ ! -e "$(sd "$c")" ]; then
  ok "DRY_RUN=1 at 19:00 Denver prints the evening brief (no digest)"
else
  bad "dry-run evening" "rc=$rc out=$(cat "$c/runner.out") err=$(cat "$c/runner.err")"
fi

rc="$(run_runner "$c" -- --bogus)"
if [ "$rc" = 64 ] && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$(sd "$c")" ]; then
  ok "an unknown argument exits 64 with a Fix: and does nothing"
else
  bad "unknown arg" "rc=$rc err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-clustering-run.sh — a healthy run'

c="$(new_case)"
rc="$(run_runner "$c")"
lanes="$(sd "$c")/lanes"
if [ "$rc" = 0 ] && [ "$(invoked "$c")" = 1 ]; then
  ok "a healthy session exits 0"
else
  bad "healthy run" "rc=$rc err=$(cat "$c/runner.err")"
fi
case "$(cat "$c/claude-cwd" 2>/dev/null)" in
  "$lanes"/run-*) ok "the session ran in its own per-run lane under the state dir, not at the checkout root" ;;
  *) bad "lane cwd" "cwd=$(cat "$c/claude-cwd" 2>&1) lanes=$lanes" ;;
esac
if [ "$(cat "$c/claude-fd9" 2>/dev/null)" = closed ]; then
  ok "the session does not inherit the lock descriptor (a surviving child cannot hold the lock)"
else
  bad "lock fd inherited" "fd9=$(cat "$c/claude-fd9" 2>&1)"
fi
if [ -z "$(find "$lanes" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
  ok "the lane is removed after the run"
else
  bad "lane teardown" "$(ls -la "$lanes")"
fi
if [ "$(jq -r '.mcpServers | keys | join(",")' "$c/claude-mcp.json" 2>/dev/null)" = "athena,notion-personal" ] \
   && [ "$(cat "$c/claude-mcp.mode")" = 600 ] && grep -qx -- '--dangerously-skip-permissions' "$c/claude-args"; then
  ok "the session gets the main checkout's local MCP servers through a 0600 --mcp-config"
else
  bad "mcp config" "keys=$(jq -c . "$c/claude-mcp.json" 2>&1) mode=$(cat "$c/claude-mcp.mode" 2>&1)"
fi
if grep -q 'daily digest' "$c/claude-args" && [ "$(cat "$(sd "$c")/digest-last-day" 2>/dev/null)" = 2026-09-27 ] \
   && [ ! -e "$(sd "$c")/consecutive-failures" ] && [ -n "$(newest "$c" log)" ] && [ -n "$(newest "$c" summary)" ]; then
  ok "the morning run asks for the digest and records the Denver day it was sent; log and summary kept in runs/"
else
  bad "digest bookkeeping" "day=$(cat "$(sd "$c")/digest-last-day" 2>&1) runs=$(ls "$(sd "$c")/runs" 2>&1)"
fi
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && grep -q 'already sent today' "$c/claude-args" && ! grep -q 'also send the daily digest' "$c/claude-args"; then
  ok "a second morning run on the same Denver day does not send the digest again"
else
  bad "digest once per day" "rc=$rc args=$(tail -c 600 "$c/claude-args")"
fi

drain_count() { find "${ALERTS}" -maxdepth 1 -type f -name '*-harness-lane-drain.md' 2>/dev/null | grep -c . || true; }
run_rec="$(newest "$c" run)"
dm="$(find "${ALERTS}" -maxdepth 1 -type f -name '*-harness-lane-drain.md' -printf '%T@ %p\n' | sort -n | tail -n1 | cut -d' ' -f2-)"
if grep -q 'outcome=ok exit=0' "$run_rec" 2>/dev/null && grep -q '^drain: sent ' "$run_rec" \
   && [ "$(sed -n 's/^re: //p' "$dm" | head -n1)" = "$run_rec" ]; then
  ok "each run sends ONE harness-lane drain request (real send-mail, pinned root), re: its .run record"
else
  bad "drain request delivered" "run=$(cat "$run_rec" 2>&1) drains=$(drain_count) err=$(cat "$c/runner.err")"
fi

# A fake send-mail: records argv and cwd, succeeds or fails on demand.
cat >"$TMP/fake-send-mail" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$@" >"$d/send-mail-args"; pwd -P >"$d/send-mail-cwd"
echo x >>"$d/send-mail-calls"
[ "$(cat "$d/send-mail-mode" 2>/dev/null)" = fail ] && { echo "fake: channel refused" >&2; exit 3; }
echo "athena:inbox: path: local -- fake"; echo "athena:inbox: delivered 0001-fake-harness-lane-drain.md"
EOF
chmod +x "$TMP/fake-send-mail"
c="$(new_case)"; echo ok >"$TMP/send-mail-mode"
rc="$(run_runner "$c" CLUSTERING_SEND_MAIL="$TMP/fake-send-mail")"
run_rec="$(newest "$c" run)"
if [ "$rc" = 0 ] && [ "$(tr '\n' ' ' <"$TMP/send-mail-args")" = "--local harness-alerts-detector harness-lane-drain --to custom --re ${run_rec} --body-file $(sed -n 9p "$TMP/send-mail-args") " ] \
   && [ "$(cat "$TMP/send-mail-cwd")" = "$REPO_ROOT" ] && grep -qx 'drain: sent 0001-fake-harness-lane-drain.md' "$run_rec"; then
  ok "the drain request runs send-mail from the harness repo with the lane slug, re: the .run record"
else
  bad "drain argv" "rc=$rc args=$(tr '\n' ' ' <"$TMP/send-mail-args" 2>&1) cwd=$(cat "$TMP/send-mail-cwd" 2>&1) run=$(cat "$run_rec" 2>&1)"
fi
echo fail >"$TMP/send-mail-mode"
rc="$(run_runner "$c" CLUSTERING_SEND_MAIL="$TMP/fake-send-mail")"
run_rec="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -qx 'drain: FAILED to send' "$run_rec" && grep -q 'drain request could NOT be sent' "$c/runner.err" \
   && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$(sd "$c")/consecutive-failures" ]; then
  ok "a failed drain send is recorded as FAILED and loud, and changes neither the exit code nor the counter"
else
  bad "drain send failure" "rc=$rc run=$(cat "$run_rec" 2>&1) err=$(cat "$c/runner.err")"
fi
echo ok >"$TMP/send-mail-mode"; rm -f "$TMP/send-mail-calls"
echo blocked0 >"$c/mode"
rc="$(run_runner "$c" CLUSTERING_SEND_MAIL="$TMP/fake-send-mail")"
if [ "$rc" = 69 ] && grep -q 'outcome=blocked exit=69' "$(newest "$c" run)" && [ "$(grep -c . "$TMP/send-mail-calls")" = 1 ]; then
  ok "a blocked run still ends with its drain request"
else
  bad "blocked drain" "rc=$rc calls=$(cat "$TMP/send-mail-calls" 2>&1)"
fi
# send-mail exits 0 but prints no delivered name: still a delivery, never an
# empty name that the episode state would read as "not yet sent".
cat >"$TMP/quiet-send-mail" <<'EOF'
#!/usr/bin/env bash
echo x >>"$(dirname "$0")/quiet-calls"; exit 0
EOF
chmod +x "$TMP/quiet-send-mail"
cq="$(new_case)"; mkdir -p "$(sd "$cq")"; echo 2 >"$(sd "$cq")/consecutive-failures"
run_runner "$cq" CLUSTERING_SEND_MAIL="$TMP/quiet-send-mail" >/dev/null
run_runner "$cq" CLUSTERING_SEND_MAIL="$TMP/quiet-send-mail" >/dev/null
if [ "$(grep -c . "$TMP/quiet-calls")" = 1 ] && grep -q '^alert: already sent for this episode ((delivered; name not reported))' "$(newest "$cq" wedged)"; then
  ok "a delivery with no reported name counts as sent: the episode does not alert twice"
else
  bad "unnamed delivery" "calls=$(cat "$TMP/quiet-calls" 2>&1) rec=$(cat "$(newest "$cq" wedged)" 2>&1)"
fi
c2="$(new_case)"; rm -r "$(repo_of "$c2")/ai/skills/athena:inbox-attend"; rm -f "$TMP/send-mail-calls"
rc="$(run_runner "$c2" CLUSTERING_SEND_MAIL="$TMP/fake-send-mail")"
if [ "$rc" = 0 ] && [ ! -e "$TMP/send-mail-calls" ] && grep -q '^drain: skipped (no reader' "$(newest "$c2" run)" \
   && grep -q 'Fix:' "$c2/runner.err"; then
  ok "with no drain reader in the main checkout (DND-987 not landed) the request is skipped and the record says why"
else
  bad "drain without reader" "rc=$rc calls=$(cat "$TMP/send-mail-calls" 2>&1) run=$(cat "$(newest "$c2" run)" 2>&1)"
fi
rm -f "$TMP/send-mail-calls"; mkdir -p "$(sd "$c")"; echo 5 >"$(sd "$c")/consecutive-failures"
rc="$(run_runner "$c" CLUSTERING_SEND_MAIL="$TMP/fake-send-mail")"
if [ "$rc" = 75 ] && grep -qx 'clustering-wedged' "$TMP/send-mail-args" && [ "$(grep -c . "$TMP/send-mail-calls")" = 1 ]; then
  ok "a wedged tick runs no pass and sends no drain request (only its wedge alert)"
else
  bad "wedged drain" "rc=$rc args=$(tr '\n' ' ' <"$TMP/send-mail-args") calls=$(cat "$TMP/send-mail-calls" 2>&1)"
fi

# ---------------------------------------------------------------------------
case_ 'athena-clustering-run.sh — the single-run lock'

c="$(new_case)"
mkdir -p "$(sd "$c")/runs"
lock="$(sd "$c")/run.lock"
mkfifo "$c/release" "$c/held"
( exec 9>>"$lock"; flock 9; echo held >"$c/held"; read -r _ <"$c/release" ) &
HOLDER_PID=$!
timeout 30 cat "$c/held" >/dev/null   # blocks (bounded) until the holder has the lock
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && [ "$(invoked "$c")" = 0 ] && [ -n "$(newest "$c" locked)" ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "a tick that finds the lock held skips (exit 0), runs nothing, and leaves a .locked record"
else
  bad "lock contention" "rc=$rc invoked=$(invoked "$c") err=$(cat "$c/runner.err")"
fi
echo go >"$c/release"; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && [ "$(invoked "$c")" = 1 ]; then
  ok "once the holder is gone the next tick runs"
else
  bad "after release" "rc=$rc err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-clustering-run.sh — failures, the wedge, and ONE alert per episode'

clear_alerts
c="$(new_case)"; echo fail >"$c/mode"
counter="$(sd "$c")/consecutive-failures"
rc1="$(run_runner "$c")"; rc2="$(run_runner "$c")"
if [ "$rc1" = 7 ] && [ "$rc2" = 7 ] && [ "$(cat "$counter")" = 2 ] && [ -n "$(newest "$c" failed)" ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "a failing session is an unsuccessful outcome: exit passes through, counter 2, .failed record with Fix:"
else
  bad "failure counting" "rc1=$rc1 rc2=$rc2 counter=$(cat "$counter" 2>&1) err=$(cat "$c/runner.err")"
fi
rc="$(run_runner "$c")"
rec="$(newest "$c" wedged)"
m="$(wedge_msg)"
if [ "$rc" = 75 ] && [ "$(invoked "$c")" = 2 ] && [ -n "$rec" ] \
   && grep -q '^wedged: consecutive_failures=2 threshold=2 first_wedged=[0-9TZ:-]* episode=[0-9TZ-]*$' "$rec" \
   && grep -qF "rearm: rm ${counter}" "$rec" && grep -q '^Fix:' "$rec" \
   && grep -q "^last_output_log=$(sd "$c")/runs/.*\.log$" "$rec"; then
  ok "at the threshold the tick exits 75, spawns nothing, and writes a .wedged record (counter, episode, re-arm, Fix:)"
else
  bad "wedged tick" "rc=$rc invoked=$(invoked "$c") rec=$(cat "$rec" 2>&1)"
fi
ep="$(sed -n 's/^wedged: .* episode=//p' "$rec" 2>/dev/null | tail -n1)"
if [ "$(wedge_count)" = 1 ] && [ "$(sed -n 's/^re: //p' "$m" | head -n1)" = "$rec" ] \
   && grep -qx "episode: ${ep}" "$m" && grep -qF "rm ${counter}" "$m" && grep -q '^Fix:' "$m" \
   && grep -qx "alert: harness-alerts $(basename -- "$m")" "$rec"; then
  ok "ONE harness-alert, re: the record, carrying its episode and the re-arm command"
else
  bad "wedge alert" "alerts=$(wedge_count) msg=$(cat "$m" 2>&1) err=$(cat "$c/runner.err")"
fi
rc="$(run_runner "$c")"
rec2="$(newest "$c" wedged)"
if [ "$rc" = 75 ] && [ "$(wedge_count)" = 1 ] && [ "$rec2" != "$rec" ] && grep -q '^alert: already sent for this episode' "$rec2"; then
  ok "a later tick of the same episode records again but does not alert again"
else
  bad "one alert per episode" "rc=$rc alerts=$(wedge_count) rec2=$(cat "$rec2" 2>&1)"
fi
rm -f "$counter"; echo ok >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && [ ! -e "$(sd "$c")/wedged" ]; then
  ok "after the re-arm the next tick runs and the episode ends"
else
  bad "re-arm" "rc=$rc state=$(cat "$(sd "$c")/wedged" 2>&1)"
fi
echo fail >"$c/mode"; run_runner "$c" >/dev/null; run_runner "$c" >/dev/null
rc="$(run_runner "$c")"
ep2="$(sed -n 's/^wedged: .* episode=//p' "$(newest "$c" wedged)" 2>/dev/null | tail -n1)"
if [ "$rc" = 75 ] && [ "$(wedge_count)" = 2 ] && [ -n "$ep2" ] && [ "$ep2" != "$ep" ]; then
  ok "a later wedge is a new episode and alerts again"
else
  bad "new episode" "rc=$rc alerts=$(wedge_count) ep=$ep ep2=$ep2"
fi

# A failed send is loud, never recorded as sent, and retried next tick.
clear_alerts
c="$(new_case)"; mkdir -p "$(sd "$c")"; echo 2 >"$(sd "$c")/consecutive-failures"
empty_root="${TMP}/empty-inbox-root"; mkdir -p "$empty_root"
rc="$(run_runner "$c" ATHENA_INBOX_ROOT="$empty_root")"
if [ "$rc" = 75 ] && [ "$(wedge_count)" = 0 ] && grep -q 'could NOT be sent' "$c/runner.err" \
   && grep -q '^alert: FAILED to send' "$(newest "$c" wedged)"; then
  ok "a failed alert is loud, recorded as FAILED, and the tick still exits 75"
else
  bad "failed send" "rc=$rc err=$(cat "$c/runner.err")"
fi
rc="$(run_runner "$c")"
if [ "$rc" = 75 ] && [ "$(wedge_count)" = 1 ]; then
  ok "the next tick of that episode sends it"
else
  bad "retry send" "rc=$rc alerts=$(wedge_count) err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-clustering-run.sh — a session that did no work is never read as success'

c="$(new_case)"; echo nosummary >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 70 ] && [ "$(cat "$(sd "$c")/consecutive-failures")" = 1 ] && grep -q 'no summary' "$(newest "$c" failed)" \
   && [ ! -e "$(sd "$c")/digest-last-day" ]; then
  ok "exit 0 with a receipt but no summary is a failure (exit 70), and no digest day is recorded"
else
  bad "missing summary" "rc=$rc err=$(cat "$c/runner.err")"
fi

c="$(new_case)"; echo blocked0 >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 69 ] && [ ! -e "$(sd "$c")/consecutive-failures" ] && [ -n "$(newest "$c" blocked)" ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "no receipt, exit 0: BLOCKED (exit 69), the wedge counter untouched"
else
  bad "blocked exit 0" "rc=$rc err=$(cat "$c/runner.err")"
fi
echo limit >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 69 ] && [ ! -e "$(sd "$c")/consecutive-failures" ] && grep -q 'weekly limit' "$(newest "$c" blocked)"; then
  ok "no receipt, non-zero exit with a usage-limit signature: BLOCKED, never a wedge failure"
else
  bad "blocked limit" "rc=$rc err=$(cat "$c/runner.err")"
fi
echo crash >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 3 ] && [ "$(cat "$(sd "$c")/consecutive-failures")" = 1 ] && grep -q 'never reported for duty' "$(newest "$c" failed)"; then
  ok "no receipt, non-zero exit, no signature: a failure that feeds the wedge"
else
  bad "crash" "rc=$rc err=$(cat "$c/runner.err")"
fi

blocked_count() { find "${ALERTS}" -maxdepth 1 -type f -name '*-clustering-blocked.md' 2>/dev/null | grep -c . || true; }
clear_alerts
c="$(new_case)"; echo blocked0 >"$c/mode"
rc1="$(run_runner "$c")"; n1="$(blocked_count)"
rc2="$(run_runner "$c")"
rec="$(newest "$c" blocked)"
m="$(find "${ALERTS}" -maxdepth 1 -type f -name '*-clustering-blocked.md' | head -n1)"
ep="$(sed -n 's/^blocked: .* episode=//p' "$rec" 2>/dev/null | tail -n1)"
if [ "$rc1" = 69 ] && [ "$rc2" = 69 ] && [ "$n1" = 0 ] && [ "$(blocked_count)" = 1 ] \
   && grep -q '^blocked: consecutive_blocked=2 threshold=2 first_blocked=[0-9TZ:-]* episode=[0-9TZ-]*$' "$rec" \
   && [ "$(sed -n 's/^re: //p' "$m" | head -n1)" = "$rec" ] && grep -qx "episode: ${ep}" "$m" && grep -q '^Fix:' "$m" \
   && [ ! -e "$(sd "$c")/consecutive-failures" ]; then
  ok "a blocked streak alerts ONCE at the threshold (re: its record, same episode), and never touches the wedge"
else
  bad "blocked streak alert" "rc1=$rc1 rc2=$rc2 n1=$n1 alerts=$(blocked_count) rec=$(cat "$rec" 2>&1) err=$(cat "$c/runner.err")"
fi
rc="$(run_runner "$c")"
if [ "$rc" = 69 ] && [ "$(blocked_count)" = 1 ] && grep -q '^alert: already sent for this episode' "$(newest "$c" blocked)"; then
  ok "a third blocked tick records but does not alert again"
else
  bad "blocked once per episode" "rc=$rc alerts=$(blocked_count)"
fi
echo ok >"$c/mode"; run_runner "$c" >/dev/null
if [ ! -e "$(sd "$c")/consecutive-blocked" ] && [ ! -e "$(sd "$c")/blocked" ]; then
  ok "a session that reaches the model ends the blocked streak and its episode"
else
  bad "blocked episode ends" "$(ls "$(sd "$c")")"
fi
echo blocked0 >"$c/mode"; run_runner "$c" >/dev/null; run_runner "$c" >/dev/null
if [ "$(blocked_count)" = 2 ]; then
  ok "a later blocked streak is a new episode and alerts again"
else
  bad "new blocked episode" "alerts=$(blocked_count)"
fi

# ---------------------------------------------------------------------------
case_ 'athena-clustering-run.sh — the MCP servers the pass needs'

c="$(new_case)"; jq '.projects = {}' "$c/claude.json" >"$c/cj" && mv "$c/cj" "$c/claude.json"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && [ "$(invoked "$c")" = 0 ] && grep -qF "$(repo_of "$c")" "$(newest "$c" failed)" \
   && grep -q 'add-notion' "$c/runner.err" && grep -q 'Fix:' "$c/runner.err" \
   && [ "$(cat "$(sd "$c")/consecutive-failures")" = 1 ]; then
  ok "no MCP entry for the main checkout: exit 78, no session, the record names the key searched, counted"
else
  bad "missing mcp entry" "rc=$rc err=$(cat "$c/runner.err")"
fi
c="$(new_case)"; jq '(.projects[] .mcpServers) |= del(.athena)' "$c/claude.json" >"$c/cj" && mv "$c/cj" "$c/claude.json"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'athena' "$(newest "$c" failed)" && grep -q 'add-athena-mcp' "$c/runner.err"; then
  ok "a missing required server (athena) is the same hard failure"
else
  bad "missing athena server" "rc=$rc err=$(cat "$c/runner.err")"
fi
c="$(new_case)"; rm -r "$(repo_of "$c")/ai/skills/athena:epic-clustering"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'epic-clustering' "$(newest "$c" failed)" \
   && grep -q 'Fix:' "$c/runner.err" && [ "$(cat "$(sd "$c")/consecutive-failures")" = 1 ]; then
  ok "the skill not landed: exit 78, no session, counted (a do-nothing pass never reads as green)"
else
  bad "missing skill" "rc=$rc err=$(cat "$c/runner.err")"
fi
c="$(new_case)"; printf '{"projects": {' >"$c/claude.json"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && grep -q 'not valid JSON' "$c/runner.err" && ! grep -q 'add-notion' "$c/runner.err"; then
  ok "an unparseable ~/.claude.json is named as such, never as 'no servers registered'"
else
  bad "corrupt claude.json" "rc=$rc err=$(cat "$c/runner.err")"
fi
c="$(new_case)"
rc="$(run_runner "$c" CLUSTERING_CLAUDE_JSON="$c/absent.json")"
if [ "$rc" = 78 ] && grep -q 'absent.json' "$c/runner.err"; then
  ok "an unreadable ~/.claude.json is a hard failure naming the file"
else
  bad "absent claude.json" "rc=$rc err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-clustering-run.sh — a dead lane is reaped and counted'

c="$(new_case)"; mkdir -p "$(sd "$c")/lanes/run-dead"
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && [ ! -e "$(sd "$c")/lanes/run-dead" ] && grep -q 'reaped dead lane run-dead' "$c/runner.err"; then
  ok "a crashed predecessor's lane is removed (we hold the lock, so it is dead)"
else
  bad "reap" "rc=$rc err=$(cat "$c/runner.err")"
fi
c="$(new_case)"; echo fail >"$c/mode"; mkdir -p "$(sd "$c")/lanes/run-dead"
run_runner "$c" >/dev/null
if [ "$(cat "$(sd "$c")/consecutive-failures")" = 2 ]; then
  ok "the reaped corpse counts as an unsuccessful outcome"
else
  bad "corpse counted" "counter=$(cat "$(sd "$c")/consecutive-failures" 2>&1)"
fi

# ===========================================================================
# setup-clustering-cron
# ===========================================================================
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
chmod +x "$BIN/crontab"

# A throwaway repo carrying the two scripts, so the installer resolves ITS main
# checkout, plus a linked worktree of it.
IR="${TMP}/inst/repo"; mkdir -p "$IR/scripts" "$IR/ai/skills/athena:epic-clustering"
printf -- '---\nname: athena:epic-clustering\n---\n' >"$IR/ai/skills/athena:epic-clustering/SKILL.md"
cp "$INSTALLER" "$RUNNER" "$IR/scripts/"
git -C "$IR" init -q -b main >&2
git -C "$IR" add -A >&2
git -C "$IR" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm seed >&2
IR="$(cd -- "$IR" && pwd -P)"
git -C "$IR" worktree add -q "${TMP}/inst/wt" >&2
IRUN="$IR/scripts/athena-clustering-run.sh"

inst() { # <crontab-file> [VAR=val ...] -- args...  (runs the MAIN checkout's installer)
  local f="$1"; shift; local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env PATH="$BIN:$PATH" FAKE_CRONTAB="$f" "${envs[@]}" "${INST:-$IR/scripts/setup-clustering-cron}" "$@" \
    >"${TMP}/inst.out" 2>"${TMP}/inst.err"
  printf '%s' "$?"
}

case_ 'setup-clustering-cron — read-only modes'

ct="${TMP}/ct1"
rc="$(inst "$ct" -- --help)"
if [ "$rc" = 0 ] && grep -q 'Usage:' "${TMP}/inst.out" && [ ! -e "$ct.calls" ]; then
  ok "--help prints usage on stdout, exits 0, and never runs crontab"
else
  bad "installer --help" "rc=$rc out=$(head -3 "${TMP}/inst.out") calls=$(cat "$ct.calls" 2>&1)"
fi
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 1 ] && grep -q 'MISSING' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" && [ ! -e "$ct" ]; then
  ok "--check is red (exit 1, Fix:) when the entry is absent, and writes nothing"
else
  bad "check absent" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
printf '# my stuff\n0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" -- --dry-run)"
if [ "$rc" = 0 ] && grep -qF "0 7,19 * * * ${IRUN}" "${TMP}/inst.out" && [ "$(cat "$ct")" = "$(printf '# my stuff\n0 * * * * /opt/other-job')" ] \
   && grep -q 'UTC' "${TMP}/inst.out"; then
  ok "--dry-run shows the entry and the UTC mapping, and leaves the crontab alone"
else
  bad "dry-run" "rc=$rc out=$(cat "${TMP}/inst.out") ct=$(cat "$ct")"
fi

case_ 'setup-clustering-cron — install, idempotence, check, remove, backup'

rc="$(inst "$ct")"
if [ "$rc" = 0 ] && [ "$(grep -cF "$IRUN" "$ct")" = 1 ] && grep -qx '0 \* \* \* \* /opt/other-job' "$ct" && grep -qx '# my stuff' "$ct"; then
  ok "install adds exactly one entry and keeps every other line"
else
  bad "install" "rc=$rc ct=$(cat "$ct") err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct" -- --schedule '30 6,18 * * *')"
if [ "$rc" = 0 ] && [ "$(grep -cF "$IRUN" "$ct")" = 1 ] && grep -qxF "30 6,18 * * * ${IRUN}" "$ct"; then
  ok "re-running updates the schedule in place (still one entry)"
else
  bad "idempotent" "rc=$rc ct=$(cat "$ct")"
fi
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ] && grep -q 'OK' "${TMP}/inst.out"; then
  ok "--check is green once the entry is live"
else
  bad "check present" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
sed -i "s|^30 6,18|#30 6,18|" "$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 1 ]; then
  ok "--check is red when the entry is commented out"
else
  bad "check commented" "rc=$rc ct=$(cat "$ct")"
fi
rc="$(inst "$ct" -- --backup "${TMP}/ct-backup")"
if [ "$rc" = 0 ] && cmp -s "$ct" "${TMP}/ct-backup"; then
  ok "--backup snapshots the live crontab"
else
  bad "backup" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct" -- --remove)"
if [ "$rc" = 0 ] && ! grep -qF "$IRUN" "$ct" && grep -qx '0 \* \* \* \* /opt/other-job' "$ct"; then
  ok "--remove drops only the clustering entry"
else
  bad "remove" "rc=$rc ct=$(cat "$ct")"
fi

case_ 'setup-clustering-cron — refusals'

printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" FAKE_CRONTAB_FAIL='crontab: Permission denied' --)"
if [ "$rc" = 2 ] && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "a crontab that cannot be read is never overwritten (exit 2, Fix:)"
else
  bad "unreadable crontab" "rc=$rc ct=$(cat "$ct") err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct" -- --schedule '0 7 * *')"
if [ "$rc" = 1 ] && grep -q 'Fix:' "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "a malformed --schedule is refused"
else
  bad "bad schedule" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
rc="$(INST="${TMP}/inst/wt/scripts/setup-clustering-cron" inst "$ct")"
if [ "$rc" = 0 ] && grep -qxF "0 7,19 * * * ${IRUN}" "$ct" && ! grep -qF "${TMP}/inst/wt" "$ct"; then
  ok "run from a linked worktree, it installs the MAIN checkout's runner path"
else
  bad "worktree install" "rc=$rc ct=$(cat "$ct") err=$(cat "${TMP}/inst.err")"
fi
mv "$IR/ai/skills/athena:epic-clustering/SKILL.md" "${TMP}/skill.aside"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct")"
if [ "$rc" = 2 ] && grep -q 'epic-clustering' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
   && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "the skill not landed in the main checkout: install is refused"
else
  bad "unlanded skill" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
mv "${TMP}/skill.aside" "$IR/ai/skills/athena:epic-clustering/SKILL.md"
git -C "$IR" rm -q scripts/athena-clustering-run.sh >&2
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(INST="${TMP}/inst/wt/scripts/setup-clustering-cron" inst "$ct")"
if [ "$rc" = 2 ] && grep -q 'Fix:' "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "a runner not landed in the main checkout is refused (it would fail every tick)"
else
  bad "unlanded runner" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
printf '0 * * * * /opt/other-job\n\n0 7,19 * * * %s\n5 * * * * /opt/third\n' "$IRUN" >"$ct"
rc="$(inst "$ct" -- --remove)"
if [ "$rc" = 0 ] && ! grep -qF "$IRUN" "$ct" \
   && [ "$(cat "$ct")" = "$(printf '0 * * * * /opt/other-job\n\n5 * * * * /opt/third')" ]; then
  ok "--remove still works when the runner is gone, and keeps the owner's blank lines"
else
  bad "remove without runner" "rc=$rc ct=$(cat -A "$ct") err=$(cat "${TMP}/inst.err")"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || {
  printf 'Fix: read each FAIL line above; it names the guarantee that broke. Re-run with: bash scripts/test/athena-clustering/self-test.sh\n' >&2
  exit 1
}
exit 0
