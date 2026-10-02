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
# DND-1163: the athena:inbox bins resolve the session's project from
# CLAUDE_PROJECT_DIR, then /proc/$CLAUDE_PID/cwd, before the cwd. Scrubbed so
# the fixtures, not the Claude session running this suite, decide the project.
unset CLAUDE_PROJECT_DIR CLAUDE_PID

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
printf '%s\n%s\n' "${CLUSTERING_DIGEST-unset}" "${CLUSTERING_DIGEST_BLOCKS-unset}" >"$d/claude-digest-env"
printf '%s\n' "${CLUSTERING_NOTICES-unset}" >"$d/claude-notices-env"
# DND-1749: the architect records each won't-fix closure and the top-level
# session each notice it posted, in the file the runner names.
notices="${CLUSTERING_NOTICES:-/dev/null}"
if [ -e /proc/self/fd/9 ]; then echo open >"$d/claude-fd9"; else echo closed >"$d/claude-fd9"; fi
prev=""
for a in "$@"; do
  if [ "$prev" = "--mcp-config" ]; then cp -- "$a" "$d/claude-mcp.json"; stat -c %a -- "$a" >"$d/claude-mcp.mode"; fi
  prev="$a"
done
case "$(cat "$d/mode" 2>/dev/null || echo ok)" in
  ok)        : >"$CLUSTERING_RECEIPT"; echo "moved 2, merged 1, closed 0" >"$CLUSTERING_SUMMARY"
             # DND-1738: a morning pass writes the digest to its run record.
             if [ -n "${CLUSTERING_DIGEST:-}" ]; then
               echo "Daily digest 2026-09-27" >"$CLUSTERING_DIGEST"; echo '[]' >"$CLUSTERING_DIGEST_BLOCKS"
             fi
             exit 0 ;;
  nodigest)  : >"$CLUSTERING_RECEIPT"; echo "moved 0, merged 0, closed 0" >"$CLUSTERING_SUMMARY"; exit 0 ;;
  wontfix)   : >"$CLUSTERING_RECEIPT"; echo "moved 0, merged 0, closed 0, won't fix 3" >"$CLUSTERING_SUMMARY"
             printf 'closed DND-901\nclosed DND-902\nclosed DND-903\n' >>"$notices"
             printf 'posted DND-901 D0FAKE0001/1700000000.000100\n' >>"$notices"
             printf 'failed DND-902 slack_post refused the blocks\n' >>"$notices"
             exit 0 ;;
  badnotice) : >"$CLUSTERING_RECEIPT"; echo "moved 0, merged 0, closed 0, won't fix 1" >"$CLUSTERING_SUMMARY"
             printf 'closed DND-904\nposted nonsense\n' >>"$notices"
             exit 0 ;;
  crlf)      : >"$CLUSTERING_RECEIPT"; echo "moved 0, merged 0, closed 0, won't fix 1" >"$CLUSTERING_SUMMARY"
             printf 'closed DND-905\r\nposted DND-905 D0FAKE0001/1700000000.000200\r\n' >>"$notices"
             exit 0 ;;
  fail)      : >"$CLUSTERING_RECEIPT"; echo "the pass fell over"; exit 7 ;;
  nosummary) : >"$CLUSTERING_RECEIPT"; exit 0 ;;
  blocked0)  exit 0 ;;
  limit)     echo "You've hit your weekly limit"; exit 1 ;;
  slimit)    echo "You've hit your session limit · resets 6:30am (America/Denver)"; exit 1 ;;
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
# DND-1738: the morning digest goes to the run record, never to the owner's DM.
# DND-1749: the brief now posts won't-fix notices with slack_post, so the check
# is that no sentence about the digest names slack_post.
digest_posted() { grep -qi 'slack_post' <<<"$(tr '.' '\n' <"$1" | grep -i 'digest')"; }
if grep -qF '$CLUSTERING_DIGEST' "$c/runner.out" && grep -qF "$(sd "$c")/runs/<ts>.digest.md" "$c/runner.out" \
   && ! digest_posted "$c/runner.out" && grep -q 'Do not post the digest' "$c/runner.out"; then
  ok "the morning brief names the digest's run-record path and gives no slack_post instruction (DND-1738)"
else
  bad "dry-run morning digest record" "out=$(cat "$c/runner.out")"
fi

rc="$(run_runner "$c" CLUSTERING_NOW="$EVENING" DRY_RUN=1)"
if [ "$rc" = 0 ] && grep -q 'NOT the morning run' "$c/runner.out" && grep -q 'Do NOT write the daily digest' "$c/runner.out" \
   && ! grep -qF '$CLUSTERING_DIGEST' "$c/runner.out" && ! digest_posted "$c/runner.out" \
   && [ ! -e "$(sd "$c")" ]; then
  ok "DRY_RUN=1 at 19:00 Denver prints the evening brief (no digest, no run-record path)"
else
  bad "dry-run evening" "rc=$rc out=$(cat "$c/runner.out") err=$(cat "$c/runner.err")"
fi

# DND-1749: on the cron, the top-level session is this headless session. Every
# brief, morning or evening, tells it to post the won't-fix notices the
# architect hands it and to record each closure and post in $CLUSTERING_NOTICES.
notice_brief() { # <file>
  grep -qF 'mcp__athena__slack_post' "$1" && grep -qF '$CLUSTERING_NOTICES' "$1" \
    && grep -qF 'closed DND-N' "$1" && grep -qF 'posted DND-N <channel>/<ts>' "$1" \
    && grep -qF 'failed DND-N <why>' "$1" && grep -qF 'inbox_name' "$1" \
    && grep -qF -- '--veto-by-hand' "$1" && grep -qF 'right BEFORE the status change' "$1" \
    && ! grep -qF 'do nothing else yourself:' "$1"
}
for when in MORNING EVENING; do
  rc="$(run_runner "$c" CLUSTERING_NOW="${!when}" -- --dry-run)"
  if [ "$rc" = 0 ] && notice_brief "$c/runner.out" && grep -qF "$(sd "$c")/runs/<ts>.notices" "$c/runner.out" \
     && [ ! -e "$(sd "$c")" ]; then
    ok "the ${when,,} dry-run brief has the session post each won't-fix notice and record it (DND-1749)"
  else
    bad "dry-run ${when,,} notice instruction" "rc=$rc out=$(cat "$c/runner.out")"
  fi
done

# DND-1571: --dry-run runs the tick's preconditions, so a printed brief means
# a tick can start. Each failure: exit 78, the tick's Fix:, no brief, no state.
dry_refused() { # <case> <label> <grep pattern on stderr>
  local c="$1" rc
  rc="$(run_runner "$c" -- --dry-run)"
  if [ "$rc" = 78 ] && grep -q -- "$3" "$c/runner.err" && grep -q 'Fix:' "$c/runner.err" \
     && grep -q 'a tick would exit 78' "$c/runner.err" && ! grep -q 'athena-architect' "$c/runner.out" \
     && [ ! -e "$(sd "$c")" ] && [ "$(invoked "$c")" = 0 ]; then
    ok "--dry-run with $2: exit 78 with Fix:, prints no brief, touches nothing"
  else
    bad "dry-run $2" "rc=$rc out=$(head -3 "$c/runner.out") err=$(cat "$c/runner.err")"
  fi
}
c2="$(new_case)"; jq '(.projects[] .mcpServers) |= del(.athena)' "$c2/claude.json" >"$c2/cj" && mv "$c2/cj" "$c2/claude.json"
dry_refused "$c2" "athena not registered" 'Fix:.*scripts/add-athena-mcp (registers athena)'
c2="$(new_case)"; printf '{"projects": {' >"$c2/claude.json"
dry_refused "$c2" "an invalid Claude config (could not look)" 'not valid JSON'
c2="$(new_case)"; rm -r "$(repo_of "$c2")/ai/skills/athena:epic-clustering"
dry_refused "$c2" "the skill not in the main checkout" 'epic-clustering'

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
# DND-1738: the digest is the run's record, named in its .run record.
run_rec="$(newest "$c" run)"; dg="$(sed -n 1p "$c/claude-digest-env")"; dgb="$(sed -n 2p "$c/claude-digest-env")"
case "$dg" in
  "$(sd "$c")"/runs/*.digest.md)
    if [ "$dgb" = "${dg%.md}.blocks.json" ] && [ -s "$dg" ] && [ -s "$dgb" ] \
       && grep -qxF "digest: written ${dg}" "$run_rec" && grep -qxF "digest_blocks: ${dgb}" "$run_rec" \
       && [ "${run_rec%.run}.digest.md" = "$dg" ]; then
      ok "a morning session gets runs/<ts>.digest.md (+ .blocks.json) for its digest; the .run record names both"
    else
      bad "digest run record" "dg=$dg dgb=$dgb run=$(cat "$run_rec" 2>&1)"
    fi ;;
  *) bad "digest path" "CLUSTERING_DIGEST=$dg run=$(cat "$run_rec" 2>&1)" ;;
esac
rc="$(run_runner "$c")"
run_rec="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -q 'already written today' "$c/claude-args" && ! grep -qF '$CLUSTERING_DIGEST' "$c/claude-args" \
   && [ "$(sed -n 1p "$c/claude-digest-env")" = unset ] && grep -q '^digest: not due (already written ' "$run_rec"; then
  ok "a second morning run on the same Denver day does not write the digest again, and its .run says so"
else
  bad "digest once per day" "rc=$rc args=$(tail -c 600 "$c/claude-args") run=$(cat "$run_rec" 2>&1)"
fi

# A morning session that writes no digest: never a silent skip.
c="$(new_case)"; echo nodigest >"$c/mode"
rc="$(run_runner "$c")"
run_rec="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -q '^digest: MISSING ' "$run_rec" && grep -q 'digest.*MISSING' "$c/runner.err" \
   && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$(sd "$c")/digest-last-day" ]; then
  ok "a morning run whose digest was not written says MISSING in .run and on stderr (Fix:), and does not stamp the day"
else
  bad "digest missing" "rc=$rc run=$(cat "$run_rec" 2>&1) err=$(cat "$c/runner.err") day=$(cat "$(sd "$c")/digest-last-day" 2>&1)"
fi

# An evening run: no digest asked for, and the .run record says why.
c="$(new_case)"
rc="$(run_runner "$c" CLUSTERING_NOW="$EVENING")"
run_rec="$(newest "$c" run)"
if [ "$rc" = 0 ] && [ "$(sed -n 1p "$c/claude-digest-env")" = unset ] && grep -q '^digest: not due (evening run' "$run_rec" \
   && [ -z "$(find "$(sd "$c")/runs" -name '*.digest.md')" ] && [ ! -e "$(sd "$c")/digest-last-day" ]; then
  ok "an evening run asks for no digest and its .run record says not due"
else
  bad "evening digest" "rc=$rc run=$(cat "$run_rec" 2>&1) env=$(cat "$c/claude-digest-env" 2>&1)"
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

# DND-1749: every won't-fix closure gets one notice: line in the .run record,
# so a notice that was never posted is observable after the session exits.
run_rec="$(newest "$c" run)"; nf="$(cat "$c/claude-notices-env")"
if [ "$nf" = "${run_rec%.run}.notices" ] && grep -qx "notice: none (no won't-fix closure recorded in ${nf})" "$run_rec"; then
  ok "a session gets runs/<ts>.notices; a pass that closed nothing says notice: none in .run, naming the file"
else
  bad "notices path / none" "nf=$nf run=$(cat "$run_rec" 2>&1)"
fi

c="$(new_case)"; echo wontfix >"$c/mode"
rc="$(run_runner "$c" CLUSTERING_NOW="$EVENING")"
run_rec="$(newest "$c" run)"; nf="${run_rec%.run}.notices"
if [ "$rc" = 0 ] && grep -qx 'notice: posted D0FAKE0001/1700000000.000100 DND-901' "$run_rec" \
   && grep -qx 'notice: NOT POSTED DND-902 slack_post refused the blocks' "$run_rec" \
   && grep -qx "notice: NOT POSTED DND-903 (no post recorded in ${nf})" "$run_rec" \
   && [ "$(grep -c '^notice: ' "$run_rec")" = 3 ]; then
  ok "a pass with three won't-fix closures writes one notice: line each: posted, NOT POSTED with its why, NOT POSTED unrecorded"
else
  bad "notice lines" "rc=$rc run=$(cat "$run_rec" 2>&1) notices=$(cat "$nf" 2>&1)"
fi
if grep -q 'DND-902' "$c/runner.err" && grep -q 'DND-903' "$c/runner.err" && grep -q 'NOT POSTED' "$c/runner.err" \
   && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$(sd "$c")/consecutive-failures" ] && grep -q 'outcome=ok exit=0' "$run_rec"; then
  ok "an unposted notice is loud on stderr with a Fix:, and changes neither the exit code nor the counter"
else
  bad "notice not posted loud" "err=$(cat "$c/runner.err") run=$(cat "$run_rec" 2>&1)"
fi

c="$(new_case)"; echo badnotice >"$c/mode"
rc="$(run_runner "$c" CLUSTERING_NOW="$EVENING")"
run_rec="$(newest "$c" run)"; nf="${run_rec%.run}.notices"
if [ "$rc" = 0 ] && grep -qx "notice: UNREADABLE ${nf} line 2: posted nonsense" "$run_rec" \
   && grep -qx "notice: NOT POSTED DND-904 (no post recorded in ${nf})" "$run_rec"; then
  ok "a malformed notices line is named UNREADABLE in .run, never dropped, and its closure still reads NOT POSTED"
else
  bad "malformed notice line" "rc=$rc run=$(cat "$run_rec" 2>&1)"
fi

c="$(new_case)"; echo crlf >"$c/mode"
rc="$(run_runner "$c" CLUSTERING_NOW="$EVENING")"
run_rec="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -qx 'notice: posted D0FAKE0001/1700000000.000200 DND-905' "$run_rec" \
   && ! grep -q $'\r' "$run_rec"; then
  ok "CRLF line endings in the notices file are read, not reported UNREADABLE"
else
  bad "crlf notices" "rc=$rc run=$(cat -A "$run_rec" 2>&1)"
fi

# A session that reached the model and failed may have closed a ticket before
# recording it: its empty notices file is UNKNOWN, never "none". A session
# that never reached the model closed nothing: "none".
c="$(new_case)"; echo fail >"$c/mode"
rc="$(run_runner "$c" CLUSTERING_NOW="$EVENING")"
run_rec="$(newest "$c" run)"
if [ "$rc" = 7 ] && grep -q '^notice: UNKNOWN (the session reached the model and ended failed' "$run_rec" \
   && ! grep -q '^notice: none' "$run_rec" && grep -q 'notice: UNKNOWN' "$c/runner.err" && grep -q 'Fix:' "$c/runner.err"; then
  ok "a failed session that reached the model reads notice: UNKNOWN, loud with a Fix:, never none"
else
  bad "notice unknown on failure" "rc=$rc run=$(cat "$run_rec" 2>&1)"
fi
c="$(new_case)"; echo blocked0 >"$c/mode"
rc="$(run_runner "$c" CLUSTERING_NOW="$EVENING")"
run_rec="$(newest "$c" run)"
if [ "$rc" = 69 ] && grep -q '^notice: none ' "$run_rec"; then
  ok "a blocked session (never reached the model) reads notice: none"
else
  bad "notice none on blocked" "rc=$rc run=$(cat "$run_rec" 2>&1)"
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
# send-mail exits 0 but prints no delivered line: NOT a confirmed delivery
# (DND-1513). The episode stays unalerted, so the next wedged tick retries.
cat >"$TMP/quiet-send-mail" <<'EOF'
#!/usr/bin/env bash
echo x >>"$(dirname "$0")/quiet-calls"; exit 0
EOF
chmod +x "$TMP/quiet-send-mail"
cq="$(new_case)"; mkdir -p "$(sd "$cq")"; echo 2 >"$(sd "$cq")/consecutive-failures"
run_runner "$cq" CLUSTERING_SEND_MAIL="$TMP/quiet-send-mail" >/dev/null
run_runner "$cq" CLUSTERING_SEND_MAIL="$TMP/quiet-send-mail" >/dev/null
if [ "$(grep -c . "$TMP/quiet-calls")" = 2 ] && grep -qx 'alert: FAILED to send' "$(newest "$cq" wedged)" \
   && grep -q "no 'athena:inbox: delivered' line" "$cq/runner.err" && [ -z "$(sed -n 's/^alerted=//p' "$(sd "$cq")/wedged")" ]; then
  ok "exit 0 with no delivered line is not sent: recorded FAILED, never stored as alerted, retried next tick"
else
  bad "unnamed delivery" "calls=$(cat "$TMP/quiet-calls" 2>&1) rec=$(cat "$(newest "$cq" wedged)" 2>&1) state=$(cat "$(sd "$cq")/wedged" 2>&1)"
fi
# A state an older runner wrote with the unconfirmed placeholder is retried.
sed -i 's/^alerted=.*/alerted=(delivered; name not reported)/' "$(sd "$cq")/wedged"
rm -f "$TMP/send-mail-calls"; echo ok >"$TMP/send-mail-mode"
run_runner "$cq" CLUSTERING_SEND_MAIL="$TMP/fake-send-mail" >/dev/null
if [ "$(grep -c . "$TMP/send-mail-calls")" = 1 ] && grep -qx 'alert: harness-alerts 0001-fake-harness-lane-drain.md' "$(newest "$cq" wedged)"; then
  ok "a stored '(delivered; name not reported)' is unconfirmed: the next wedged tick sends and records the name"
else
  bad "legacy placeholder" "calls=$(cat "$TMP/send-mail-calls" 2>&1) rec=$(cat "$(newest "$cq" wedged)" 2>&1)"
fi
# The reader has landed (DND-987), so the request is unconditional: the
# runner no longer looks for a reader in the main checkout before sending.
c2="$(new_case)"; rm -f "$TMP/send-mail-calls"
rc="$(run_runner "$c2" CLUSTERING_SEND_MAIL="$TMP/fake-send-mail")"
if [ "$rc" = 0 ] && [ "$(grep -c . "$TMP/send-mail-calls")" = 1 ] && grep -qx 'drain: sent 0001-fake-harness-lane-drain.md' "$(newest "$c2" run)" \
   && ! grep -q '^drain: skipped' "$(newest "$c2" run)"; then
  ok "the drain request is always sent: there is no reader gate to skip it"
else
  bad "drain unconditional" "rc=$rc calls=$(cat "$TMP/send-mail-calls" 2>&1) run=$(cat "$(newest "$c2" run)" 2>&1)"
fi
# Writer and reader agree: the slug this runner sends is the filename suffix
# the landed reader (athena:inbox-attend -> A fourth writer) handles, and the
# lane brief it routes to has its drain steps.
slug="$(sed -n 3p "$TMP/send-mail-args")"
if [ "$slug" = harness-lane-drain ] \
   && grep -qF -- "-${slug}.md" "${REPO_ROOT}/ai/skills/athena:inbox-attend/SKILL.md" \
   && grep -qF -- '**A fourth writer: the harness-lane drain request' "${REPO_ROOT}/ai/skills/athena:inbox-attend/SKILL.md" \
   && grep -qF -- '**On a drain request**' "${REPO_ROOT}/ai/docs/ticket-lane-action-brief.md"; then
  ok "the drain slug is the one the landed reader handles (athena:inbox-attend -> A fourth writer)"
else
  bad "drain reader contract" "slug=$slug; the reader in ${REPO_ROOT} does not handle -${slug}.md"
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
c="$(new_case)"; echo slimit >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 69 ] && [ ! -e "$(sd "$c")/consecutive-failures" ] && grep -q 'session limit' "$(newest "$c" blocked)"; then
  ok "no receipt, non-zero exit with the session-limit wording: BLOCKED, never a wedge failure"
else
  bad "blocked session limit" "rc=$rc failures='$(cat "$(sd "$c")/consecutive-failures" 2>/dev/null)' err=$(cat "$c/runner.err")"
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
# The shared libs they source (the MCP preflight, DND-1571).
cp -r "${SCRIPTS}/lib" "$IR/scripts/"
git -C "$IR" init -q -b main >&2
git -C "$IR" add -A >&2
git -C "$IR" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -qm seed >&2
IR="$(cd -- "$IR" && pwd -P)"
git -C "$IR" worktree add -q "${TMP}/inst/wt" >&2
IRUN="$IR/scripts/athena-clustering-run.sh"
# A fake Claude config (CLUSTERING_CLAUDE_JSON) with both servers registered
# for the main checkout: no case reads ~/.claude.json. Synthetic values only.
ICJ="${TMP}/inst-claude.json"
jq -n --arg p "$IR" '{projects: {($p): {mcpServers: {
    "notion-personal": {type: "stdio", command: "/x/notion-athena-mcp", args: []},
    "athena": {type: "http", url: "https://example.invalid/mcp"}}}}}' >"$ICJ"

inst() { # <crontab-file> [VAR=val ...] -- args...  (runs the MAIN checkout's installer)
  local f="$1"; shift; local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env PATH="$BIN:$PATH" FAKE_CRONTAB="$f" CLUSTERING_CLAUDE_JSON="$ICJ" "${envs[@]}" "${INST:-$IR/scripts/setup-clustering-cron}" "$@" \
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
sed -i "s|^#30 6,18|30 6,18|" "$ct"
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
# DND-1638: every mode that reads the crontab treats only "no crontab for
# <user>" as empty. --remove on an unreadable crontab used to be the same class.
rc="$(inst "$ct" FAKE_CRONTAB_FAIL='/var/spool/cron/crontabs/u: Permission denied' -- --remove)"
if [ "$rc" = 2 ] && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && grep -q 'could not read' "${TMP}/inst.err" \
   && grep -q 'Fix:' "${TMP}/inst.err"; then
  ok "--remove on a crontab that cannot be read writes nothing (exit 2, Fix:)"
else
  bad "unreadable crontab --remove" "rc=$rc ct=$(cat "$ct") err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct" FAKE_CRONTAB_FAIL='/var/spool/cron/crontabs/u: Permission denied' -- --check)"
if [ "$rc" = 2 ] && grep -q 'could not read' "${TMP}/inst.err" && ! grep -q 'MISSING' "${TMP}/inst.err"; then
  ok "--check on a crontab that cannot be read is exit 2 'could not read', never MISSING"
else
  bad "unreadable crontab --check" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
ctn="${TMP}/ct-none"; rm -f "$ctn"
rc="$(inst "$ctn")"
if [ "$rc" = 0 ] && [ "$(cat "$ctn")" = "0 7,19 * * * ${IRUN}" ]; then
  ok "'no crontab for <user>' is an empty crontab: install writes the one entry"
else
  bad "no crontab install" "rc=$rc ct=$(cat "$ctn" 2>&1) err=$(cat "${TMP}/inst.err")"
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
git -C "$IR" checkout -q HEAD -- scripts/athena-clustering-run.sh >&2

# DND-1728: the installer runs the runner's own --dry-run last, so a lib the
# tick loads (dbus-env.sh) that does not load turns --check, --dry-run and the
# install red. The runner is the real one; only its lib is broken.
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct")"
rc2="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ] && [ "$rc2" = 0 ]; then
  ok "control: with every lib intact the install and --check pass the runner's --dry-run"
else
  bad "runner dry run control" "rc=$rc rc2=$rc2 err=$(cat "${TMP}/inst.err")"
fi
printf 'return 1\n' >"$IR/scripts/lib/dbus-env.sh"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 2 ] && grep -qF "the runner's own --dry-run refuses (${IRUN} --dry-run, exit 78)" "${TMP}/inst.err" \
   && grep -q 'dbus-env.sh could not be loaded' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" && ! grep -q '^OK' "${TMP}/inst.out"; then
  ok "--check with a live entry is red (exit 2) when dbus-env.sh does not load, naming it with the runner's Fix:"
else
  bad "check unloadable dbus lib" "rc=$rc out=$(cat "${TMP}/inst.out") err=$(cat "${TMP}/inst.err")"
fi
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" -- --dry-run)"
rc2="$(inst "$ct")"
if [ "$rc" = 2 ] && [ "$rc2" = 2 ] && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ] && ! grep -q 'would install' "${TMP}/inst.out" \
   && grep -q 'dbus-env.sh could not be loaded' "${TMP}/inst.err"; then
  ok "--dry-run and the install are refused (exit 2) when dbus-env.sh does not load; the crontab is untouched"
else
  bad "install unloadable dbus lib" "rc=$rc rc2=$rc2 ct=$(cat "$ct") err=$(cat "${TMP}/inst.err")"
fi
git -C "$IR" checkout -q HEAD -- scripts/lib/dbus-env.sh >&2

# DND-1642: a main checkout that cannot be resolved is an error at its source.
# A resolver answer the installer cannot enter used to fall through
# `dirname "$(cd ... && pwd)"` to ".", so the runner became ./scripts/... and
# the refusal came later, if at all. Synthetic: a PATH stub, never a real repo.
mkdir -p "${TMP}/badgit"
REAL_GIT="$(command -v git)"
printf '#!/bin/sh\ncase "$*" in *--git-common-dir*|*--git-dir*) echo /nonexistent-dnd1642/.git; exit 0 ;; esac\nexec %s "$@"\n' "$REAL_GIT" >"${TMP}/badgit/git"
chmod +x "${TMP}/badgit/git"
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" "PATH=${TMP}/badgit:${BIN}:${PATH}" -- --dry-run)"
if [ "$rc" = 2 ] && grep -q 'cannot enter' "${TMP}/inst.err" && grep -q 'Fix:' "${TMP}/inst.err" \
   && ! grep -qF './scripts/' "${TMP}/inst.out" "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "an unenterable git dir is exit 2 naming the cause with a Fix:, never a relative runner (DND-1642)"
else
  bad "unresolvable main checkout" "rc=$rc out=$(cat "${TMP}/inst.out") err=$(cat "${TMP}/inst.err")"
fi

case_ 'setup-clustering-cron — which lines are ours (DND-1503)'

# Not ours, each kept byte for byte: a commented-out entry, a longer runner
# path (<runner>.bak), and a longer path that contains the runner path.
NOT_OURS="$(printf '#0 7,19 * * * %s\n0 7,19 * * * %s.bak\n0 7,19 * * * /backup%s\n' "$IRUN" "$IRUN" "$IRUN")"
ct="${TMP}/ct-ours"
printf '%s\n' "$NOT_OURS" >"$ct"
rc="$(inst "$ct")"
if [ "$rc" = 0 ] && [ "$(head -n 3 "$ct")" = "$NOT_OURS" ] && [ "$(tail -n 1 "$ct")" = "0 7,19 * * * ${IRUN}" ] \
   && [ "$(wc -l <"$ct")" = 4 ]; then
  ok "install keeps a commented-out entry, <runner>.bak and a longer path byte for byte"
else
  bad "install keeps not-ours" "rc=$rc ct=$(cat -A "$ct")"
fi
rc="$(inst "$ct" -- --remove)"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "$NOT_OURS" ]; then
  ok "--remove keeps them too, and drops only the live entry"
else
  bad "remove keeps not-ours" "rc=$rc ct=$(cat -A "$ct")"
fi
printf '0 7,19 * * * %s.bak\n0 7,19 * * * /backup%s\n' "$IRUN" "$IRUN" >"$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 1 ] && grep -q 'MISSING' "${TMP}/inst.err"; then
  ok "--check is red when only longer runner paths are live"
else
  bad "check not-ours" "rc=$rc out=$(cat "${TMP}/inst.out" "${TMP}/inst.err")"
fi
printf '0\t7,19\t*\t*\t*\t%s\n' "$IRUN" >"$ct"
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ]; then
  ok "--check reads a tab-separated entry as installed"
else
  bad "tab check" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct")"
if [ "$rc" = 0 ] && [ "$(cat "$ct")" = "0 7,19 * * * ${IRUN}" ]; then
  ok "install rewrites a tab-separated entry as the one canonical entry"
else
  bad "tab install" "rc=$rc ct=$(cat -A "$ct")"
fi

case_ 'setup-clustering-cron — the runner MCP preflight (DND-1571)'

ICJ_NO_ATHENA="${TMP}/inst-no-athena.json"
jq --arg p "$IR" 'del(.projects[$p].mcpServers.athena)' "$ICJ" >"${ICJ_NO_ATHENA}"
printf '{not json' >"${TMP}/inst-corrupt.json"
printf '0 * * * * /opt/other-job\n0 7,19 * * * %s\n' "$IRUN" >"$ct"
rc="$(inst "$ct" CLUSTERING_CLAUDE_JSON="${ICJ_NO_ATHENA}" -- --check)"
if [ "$rc" = 2 ] && grep -q 'NOT REGISTERED' "${TMP}/inst.err" && grep -q 'Fix:.*scripts/add-athena-mcp (registers athena)' "${TMP}/inst.err" \
   && ! grep -q 'OK' "${TMP}/inst.out" && ! grep -q 'COULD NOT LOOK' "${TMP}/inst.err"; then
  ok "--check with athena not registered: exit 2, NOT REGISTERED, Fix: names the server and its command"
else
  bad "check athena missing" "rc=$rc out=$(cat "${TMP}/inst.out") err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct" CLUSTERING_CLAUDE_JSON="${TMP}/inst-absent.json" -- --check)"
if [ "$rc" = 4 ] && grep -q 'COULD NOT LOOK' "${TMP}/inst.err" && grep -qF "${TMP}/inst-absent.json" "${TMP}/inst.err" \
   && ! grep -q 'NOT REGISTERED' "${TMP}/inst.err"; then
  ok "--check with the Claude config missing: exit 4, COULD NOT LOOK"
else
  bad "check config missing" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct" CLUSTERING_CLAUDE_JSON="${TMP}/inst-corrupt.json" -- --check)"
if [ "$rc" = 4 ] && grep -q 'COULD NOT LOOK' "${TMP}/inst.err" && grep -q 'not valid JSON' "${TMP}/inst.err"; then
  ok "--check with an invalid Claude config: exit 4, COULD NOT LOOK"
else
  bad "check config corrupt" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct" -- --check)"
if [ "$rc" = 0 ] && grep -q '^OK' "${TMP}/inst.out" && grep -q 'MCP: notion-personal athena registered' "${TMP}/inst.out"; then
  ok "--check with both servers registered: exit 0, and says the MCP preflight passed"
else
  bad "check mcp ok" "rc=$rc out=$(cat "${TMP}/inst.out") err=$(cat "${TMP}/inst.err")"
fi
mv "$IR/ai/skills/athena:epic-clustering/SKILL.md" "${TMP}/skill.aside"
rc="$(inst "$ct" -- --check)"
mv "${TMP}/skill.aside" "$IR/ai/skills/athena:epic-clustering/SKILL.md"
if [ "$rc" = 2 ] && grep -q 'epic-clustering skill is not in the main checkout' "${TMP}/inst.err" && ! grep -q '^OK' "${TMP}/inst.out"; then
  ok "--check with the skill not in the main checkout: exit 2, never OK"
else
  bad "check skill missing" "rc=$rc err=$(cat "${TMP}/inst.err")"
fi
printf '0 * * * * /opt/other-job\n' >"$ct"
rc="$(inst "$ct" CLUSTERING_CLAUDE_JSON="${ICJ_NO_ATHENA}")"
if [ "$rc" = 2 ] && grep -q 'NOT REGISTERED' "${TMP}/inst.err" && [ "$(cat "$ct")" = '0 * * * * /opt/other-job' ]; then
  ok "install with athena not registered: refused (exit 2), the crontab untouched"
else
  bad "install athena missing" "rc=$rc ct=$(cat "$ct") err=$(cat "${TMP}/inst.err")"
fi
rc="$(inst "$ct" CLUSTERING_CLAUDE_JSON="${TMP}/inst-corrupt.json" -- --dry-run)"
if [ "$rc" = 4 ] && grep -q 'COULD NOT LOOK' "${TMP}/inst.err" && ! grep -q 'would install' "${TMP}/inst.out"; then
  ok "--dry-run with an invalid Claude config: exit 4, no plan printed"
else
  bad "dry-run config corrupt" "rc=$rc out=$(cat "${TMP}/inst.out") err=$(cat "${TMP}/inst.err")"
fi

git -C "$IR" rm -q scripts/athena-clustering-run.sh >&2
printf '0 * * * * /opt/other-job\n\n0 7,19 * * * %s\n5 * * * * /opt/third\n' "$IRUN" >"$ct"
rc="$(inst "$ct" CLUSTERING_CLAUDE_JSON="${TMP}/inst-corrupt.json" -- --remove)"
if [ "$rc" = 0 ] && ! grep -qF "$IRUN" "$ct" \
   && [ "$(cat "$ct")" = "$(printf '0 * * * * /opt/other-job\n\n5 * * * * /opt/third')" ]; then
  ok "--remove still works when the runner is gone, and keeps the owner's blank lines"
else
  bad "remove without runner" "rc=$rc ct=$(cat -A "$ct") err=$(cat "${TMP}/inst.err")"
fi

# ---------------------------------------------------------------------------
case_ 'athena-clustering-run.sh — a missing scripts/lib file is recorded, counted, alerted (DND-1603)'

# sx_runner <case> [<lib file to omit>...] — a copy of the runner beside its
# libs and the alert sender, in a fixture tree, minus the named lib files.
sx_runner() {
  local c="$1" l; shift
  mkdir -p "$c/sx/scripts/lib" "$c/sx/ai/lib"
  cp -- "$RUNNER" "${SCRIPTS}/reap-orphan-dbus" "$c/sx/scripts/"
  cp -- "${SCRIPTS}"/lib/*.sh "$c/sx/scripts/lib/"
  cp -- "${REPO_ROOT}/ai/lib/harness-alert-send.sh" "$c/sx/ai/lib/"
  for l in "$@"; do rm -f -- "$c/sx/scripts/lib/$l"; done
  printf '%s' "$c/sx/scripts/athena-clustering-run.sh"
}
cat >"$TMP/lib-send-mail" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/lib-send-calls"
echo "athena:inbox: delivered 0001-fake.md"
EOF
chmod +x "$TMP/lib-send-mail"

REAL_RUNNER="$RUNNER"
c="$(new_case)"
RUNNER="$(sx_runner "$c")"
rc="$(run_runner "$c" CLUSTERING_SEND_MAIL="$TMP/lib-send-mail")"
if [ "$rc" = 0 ] && [ "$(invoked "$c")" = 1 ]; then
  ok "control: the fixture copy with every lib present runs a healthy tick"
else
  bad "control copy" "rc=$rc err=$(cat "$c/runner.err")"
fi

for lib in mcp-preflight.sh dbus-env.sh; do
  c="$(new_case)"
  RUNNER="$(sx_runner "$c" "$lib")"
  rm -f "$TMP/lib-send-calls"
  r1="$(run_runner "$c" CLUSTERING_FAIL_ESCALATE=2 CLUSTERING_SEND_MAIL="$TMP/lib-send-mail")"
  rec="$(newest "$c" failed)"
  if [ "$r1" = 78 ] && [ "$(invoked "$c")" = 0 ] && [ "$(cat "$(sd "$c")/consecutive-failures" 2>/dev/null || echo 0)" = 1 ] \
     && [ -n "$rec" ] && grep -q "scripts/lib/$lib" "$rec" && grep -q "scripts/lib/$lib" "$c/runner.err" \
     && grep -q 'Fix:' "$c/runner.err"; then
    ok "$lib missing: exit 78, a .failed record naming it, the wedge counter at 1, Fix:, no session"
  else
    bad "$lib missing" "rc=$r1 rec=$(cat "$rec" 2>/dev/null) err=$(cat "$c/runner.err")"
  fi
  r2="$(run_runner "$c" CLUSTERING_FAIL_ESCALATE=2 CLUSTERING_SEND_MAIL="$TMP/lib-send-mail")"
  r3="$(run_runner "$c" CLUSTERING_FAIL_ESCALATE=2 CLUSTERING_SEND_MAIL="$TMP/lib-send-mail")"
  if [ "$r2" = 78 ] && [ "$r3" = 75 ] && [ -n "$(newest "$c" wedged)" ] \
     && [ "$(grep -c 'clustering-wedged' "$TMP/lib-send-calls" 2>/dev/null || echo 0)" = 1 ] && [ "$(invoked "$c")" = 0 ]; then
    ok "$lib missing: it wedges at the threshold and sends ONE clustering-wedged alert, like any counted failure"
  else
    bad "$lib wedge" "r2=$r2 r3=$r3 wedged=$(newest "$c" wedged) sends=$(cat "$TMP/lib-send-calls" 2>&1)"
  fi
done

for lib in mcp-preflight.sh dbus-env.sh; do
  c="$(new_case)"
  RUNNER="$(sx_runner "$c" "$lib")"
  rc="$(run_runner "$c" -- --dry-run)"
  if [ "$rc" = 78 ] && grep -q "scripts/lib/$lib is missing" "$c/runner.err" && grep -q 'a tick would exit 78' "$c/runner.err" \
     && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$(sd "$c")" ] && [ ! -s "$c/runner.out" ]; then
    ok "--dry-run with $lib missing: exit 78 with Fix:, no brief, touches nothing"
  else
    bad "dry-run $lib missing" "rc=$rc err=$(cat "$c/runner.err")"
  fi
done

# A lib that is present but does not load (here: it returns non-zero) is the
# same fault, and the record says so.
c="$(new_case)"
RUNNER="$(sx_runner "$c" dbus-env.sh)"
printf 'return 1\n' >"$c/sx/scripts/lib/dbus-env.sh"
rc="$(run_runner "$c")"
rec="$(newest "$c" failed)"
if [ "$rc" = 78 ] && [ -n "$rec" ] && grep -q 'dbus-env.sh could not be loaded' "$rec" && [ "$(invoked "$c")" = 0 ]; then
  ok "an unloadable dbus-env.sh: exit 78, a .failed record saying could not be loaded"
else
  bad "unloadable lib" "rc=$rc rec=$(cat "$rec" 2>/dev/null) err=$(cat "$c/runner.err")"
fi
# A truncated mcp-preflight.sh loads (exit 0) and defines nothing.
c="$(new_case)"
RUNNER="$(sx_runner "$c" mcp-preflight.sh)"
: >"$c/sx/scripts/lib/mcp-preflight.sh"
rc="$(run_runner "$c")"
rec="$(newest "$c" failed)"
if [ "$rc" = 78 ] && [ -n "$rec" ] && grep -q 'does not define clustering_mcp_preflight' "$rec" && [ "$(invoked "$c")" = 0 ]; then
  ok "an empty mcp-preflight.sh (loads, defines nothing): exit 78, a .failed record, counted"
else
  bad "empty preflight lib" "rc=$rc rec=$(cat "$rec" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# --dry-run runs the tick's own lib check, not a readability test (DND-1728):
# a lib that is present but does not load, loads without defining what the
# tick calls, or cannot be read refuses the dry run the way it fails the tick.
# lib_dry_case <lib> <label> <expected reason> <how to break it>
lib_dry_case() {
  local lib="$1" label="$2" want="$3" how="$4" c rc
  c="$(new_case)"
  RUNNER="$(sx_runner "$c")"
  case "$how" in
    return1) printf 'return 1\n' >"$c/sx/scripts/lib/$lib" ;;
    empty)   : >"$c/sx/scripts/lib/$lib" ;;
    conflict) printf '<<<<<<< HEAD\nf() {\n=======\n' >"$c/sx/scripts/lib/$lib" ;;
    unreadable) chmod 000 "$c/sx/scripts/lib/$lib" ;;
  esac
  rc="$(run_runner "$c" -- --dry-run)"
  if [ "$rc" = 78 ] && grep -q "scripts/lib/$lib $want" "$c/runner.err" && grep -q 'a tick would exit 78' "$c/runner.err" \
     && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$(sd "$c")" ] && [ ! -s "$c/runner.out" ] && [ "$(invoked "$c")" = 0 ]; then
    ok "--dry-run with $lib $label: exit 78 naming it ($want), Fix:, no brief, touches nothing"
  else
    bad "dry-run $lib $label" "rc=$rc err=$(cat "$c/runner.err")"
  fi
  chmod 644 "$c/sx/scripts/lib/$lib" 2>/dev/null || true
}
lib_dry_case dbus-env.sh 'that does not load' 'could not be loaded' return1
lib_dry_case dbus-env.sh 'with a merge-conflict marker' 'could not be loaded' conflict
lib_dry_case dbus-env.sh 'that defines nothing' 'loaded but does not define athena_dbus_env_setup' empty
lib_dry_case mcp-preflight.sh 'that defines nothing' 'loaded but does not define clustering_mcp_preflight' empty
if [ "$(id -u)" != 0 ]; then
  lib_dry_case dbus-env.sh 'unreadable' 'is unreadable' unreadable
  lib_dry_case mcp-preflight.sh 'unreadable' 'is unreadable' unreadable
fi

# The tick names the same reason the dry run does: one check serves both.
c="$(new_case)"
RUNNER="$(sx_runner "$c")"
: >"$c/sx/scripts/lib/dbus-env.sh"
rc="$(run_runner "$c")"
rec="$(newest "$c" failed)"
if [ "$rc" = 78 ] && [ -n "$rec" ] && grep -q 'dbus-env.sh loaded but does not define athena_dbus_env_setup' "$rec" \
   && [ "$(cat "$(sd "$c")/consecutive-failures" 2>/dev/null || echo 0)" = 1 ] && [ "$(invoked "$c")" = 0 ]; then
  ok "an empty dbus-env.sh (loads, defines nothing): the tick exits 78 with a .failed record naming the function, counted"
else
  bad "empty dbus lib tick" "rc=$rc rec=$(cat "$rec" 2>/dev/null) err=$(cat "$c/runner.err")"
fi
RUNNER="$REAL_RUNNER"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || {
  printf 'Fix: read each FAIL line above; it names the guarantee that broke. Re-run with: bash scripts/test/athena-clustering/self-test.sh\n' >&2
  exit 1
}
exit 0
