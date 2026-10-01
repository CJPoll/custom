#!/usr/bin/env bash
# Self-test for scripts/athena-leadtime-run.sh (DND-1479).
#
# Run: bash ai/test/leadtime-run/self-test.sh
#
# Functional only (DND-1222): no sleeps, no timing, no load. Nothing real is
# touched, with one exception: each runner case runs the real
# scripts/reap-orphan-dbus, which reaps only genuinely orphaned autolaunch
# D-Bus daemons older than 5 minutes (the same best-effort call the cron makes).
# Otherwise each case has:
#   * a temp bare origin and a clone of it as LEADTIME_REPO (the "main
#     checkout"), seeded with the skill and the repo config;
#   * a fake ~/.claude.json (LEADTIME_CLAUDE_JSON);
#   * a fake claude (LEADTIME_CLAUDE) whose behaviour is the word in
#     <case>/mode; no model runs;
#   * a fake send-mail (LEADTIME_SEND_MAIL) that records its argv;
#   * a fake telemetry-emit (LEADTIME_TELEMETRY_EMIT);
#   * an injected clock (LEADTIME_NOW).
# ATHENA_INBOX_ROOT is also pinned to a temp dir, so nothing can reach the
# live harness-alerts channel even if a seam were missed.

set -uo pipefail
unset CLAUDE_PROJECT_DIR CLAUDE_PID CLAUDE_AGENT_ID CLAUDE_AGENT_TYPE DRY_RUN
unset LEADTIME_FAIL_ESCALATE LEADTIME_BLOCK_ESCALATE LEADTIME_TIMEOUT LEADTIME_LANES_DIR

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
RUNNER="${REPO_ROOT}/scripts/athena-leadtime-run.sh"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
HOLDER_PIDS=()
cleanup() {
  local p
  for p in "${HOLDER_PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

ok()    { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
case_() { printf '\n%s\n' "$1"; }

export ATHENA_INBOX_ROOT="${TMP}/inbox-root"
NOW_FIXED="$(date -d '2026-10-01 12:30 UTC' +%s)"
G=(-c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main)

# --- shared fakes ----------------------------------------------------------------
cat >"$TMP/fake-send-mail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SEND_LOG:?}"
n="$(grep -c . "${FAKE_SEND_LOG}")"
echo "athena:inbox: delivered msg-${n}.md"
EOF
chmod +x "$TMP/fake-send-mail"

# --- fixtures ----------------------------------------------------------------------
# new_case — a case dir with a bare origin, a clone of it (the main checkout),
# a fake claude.json, a fake claude and a fake telemetry-emit.
new_case() {
  local c seed
  c="$(mktemp -d -p "$TMP" case.XXXXXX)"; c="$(cd -- "$c" && pwd -P)"
  seed="$c/seed"
  git "${G[@]}" init -q "$seed"
  mkdir -p "$seed/ai/skills/athena:lead-time-improve" "$seed/ai/config"
  printf -- '---\nname: athena:lead-time-improve\n---\n' >"$seed/ai/skills/athena:lead-time-improve/SKILL.md"
  printf '{"repos":[{"name":"custom","path":"~/dev/custom","mode":"improve"}],"window":20}\n' \
    >"$seed/ai/config/lead-time-repos.json"
  printf 'ai-artifacts/\n' >"$seed/.gitignore"
  git -C "$seed" add -A
  git "${G[@]}" -C "$seed" commit -q -m seed
  git clone -q --bare "$seed" "$c/origin.git"
  git clone -q "$c/origin.git" "$c/repo"
  jq -n --arg p "$c/repo" '{projects: {($p): {mcpServers: {
      "notion-personal": {type: "stdio", command: "/x/notion-athena-mcp", args: [], env: {NOTION_ATHENA_TOKEN_FILE: "/x/token"}},
      "athena": {type: "http", url: "https://example.invalid/mcp", headersHelper: "/x/athena-mcp-headers"}}}}}' \
    >"$c/claude.json"
  cat >"$c/stub-claude" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
echo x >>"$d/claude-invoked"
printf '%s\n' "$@" >"$d/claude-args"
pwd -P >"$d/claude-cwd"
printf '%s\n' "${LEAD_TIME_STATE_DIR:-}" >"$d/claude-state-env"
for fd in 8 9; do
  if [ -e "/proc/self/fd/$fd" ]; then echo open >"$d/claude-fd$fd"; else echo closed >"$d/claude-fd$fd"; fi
done
prev=""
for a in "$@"; do
  if [ "$prev" = "--mcp-config" ]; then cp -- "$a" "$d/claude-mcp.json"; stat -c %a -- "$a" >"$d/claude-mcp.mode"; fi
  prev="$a"
done
g() { git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }
summary() { echo 'repo=custom mode=improve biggest=verify action=no-action reason="fixture"' >"$LEADTIME_SUMMARY"; }
case "$(cat "$d/mode" 2>/dev/null || echo ok)" in
  ok)        : >"$LEADTIME_RECEIPT"; summary; exit 0 ;;
  fail)      : >"$LEADTIME_RECEIPT"; echo "the run fell over"; exit 7 ;;
  nosummary) : >"$LEADTIME_RECEIPT"; exit 0 ;;
  blocked0)  exit 0 ;;
  limit)     echo "You've hit your weekly limit"; exit 1 ;;
  crash)     echo "segmentation fault"; exit 3 ;;
  strand)    : >"$LEADTIME_RECEIPT"; echo change >strand.txt; g add strand.txt >/dev/null; g commit -q -m "unlanded change"; summary; exit 0 ;;
  land)      : >"$LEADTIME_RECEIPT"; echo change >landed.txt; g add landed.txt >/dev/null; g commit -q -m "landed change"
             g push -q origin HEAD:main 2>/dev/null || exit 9; summary; exit 0 ;;
esac
EOF
  chmod +x "$c/stub-claude"
  cat >"$c/fake-telemetry-emit" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >>"$d/telemetry-calls"
if [ "$(cat "$d/telemetry-mode" 2>/dev/null || echo ok)" = fail ]; then
  echo "telemetry-emit: cannot remove a day file"; echo "  Fix: check the store's permissions."; exit 1
fi
echo "pruned 2"
EOF
  chmod +x "$c/fake-telemetry-emit"
  : >"$c/send.log"
  printf '%s' "$c"
}
sd()      { printf '%s/repo/ai-artifacts/lead-time' "$1"; }
lanes()   { printf '%s/repo/.git/leadtime-lanes' "$1"; }
invoked() { [ -e "$1/claude-invoked" ] && grep -c . "$1/claude-invoked" || echo 0; }
sends()   { grep -c "$2" "$1/send.log" 2>/dev/null || true; }
newest()  { find "$(sd "$1")/runs" -maxdepth 1 -name "*.$2" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -n1 | cut -d" " -f2-; }
fails()   { cat "$(sd "$1")/consecutive-failures" 2>/dev/null || echo 0; }
lane_dirs()    { find "$(lanes "$1")" -mindepth 1 -maxdepth 1 -type d -name 'run-*' 2>/dev/null | grep -c . || true; }
lane_branches(){ git -C "$1/repo" for-each-ref --format='%(refname)' refs/heads/leadtime | grep -c . || true; }

# run_runner <case> [VAR=val ...] [-- runner args] -> prints the exit code.
run_runner() {
  local c="$1"; shift
  local envs=() args=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; args=("$@"); break; fi
    envs+=("$1"); shift
  done
  env LEADTIME_REPO="$c/repo" LEADTIME_CLAUDE="$c/stub-claude" LEADTIME_CLAUDE_JSON="$c/claude.json" \
      LEADTIME_NOW="$NOW_FIXED" LEADTIME_SEND_MAIL="$TMP/fake-send-mail" FAKE_SEND_LOG="$c/send.log" \
      LEADTIME_TELEMETRY_EMIT="$c/fake-telemetry-emit" \
      "${envs[@]}" "$RUNNER" "${args[@]}" >"$c/runner.out" 2>"$c/runner.err"
  printf '%s' "$?"
}

# hold_lock <file> <case> — a fixture process holds an flock on <file> until
# killed; returns once the lock is held (blocks on a fifo, bounded).
hold_lock() {
  local f="$1" c="$2" fifo
  fifo="$(mktemp -u -p "$c" held.XXXXXX)"; mkfifo "$fifo"
  ( exec 7>>"$f"; flock 7; echo held >"$fifo"; exec tail -f /dev/null ) &
  HOLDER_PIDS+=("$!")
  timeout 30 cat "$fifo" >/dev/null
}
release_holders() {
  local p
  for p in "${HOLDER_PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  HOLDER_PIDS=()
}

# ---------------------------------------------------------------------------------
case_ '1-3. --help, --dry-run and a bad argument have no side effects'

c="$(new_case)"
rc="$(run_runner "$c" -- --help)"
if [ "$rc" = 0 ] && grep -q 'Usage:' "$c/runner.out" && [ ! -s "$c/runner.err" ] \
   && [ ! -e "$(sd "$c")" ] && [ ! -e "$(lanes "$c")" ] && [ "$(invoked "$c")" = 0 ]; then
  ok "--help prints usage on stdout, exits 0, creates no state and runs no session"
else
  bad "--help" "rc=$rc out=$(head -3 "$c/runner.out") err=$(cat "$c/runner.err")"
fi

for form in flag env; do
  c="$(new_case)"
  if [ "$form" = flag ]; then rc="$(run_runner "$c" -- --dry-run)"; else rc="$(run_runner "$c" DRY_RUN=1)"; fi
  if [ "$rc" = 0 ] && grep -q 'MODE: lead-time' "$c/runner.out" && grep -q 'athena:lead-time-improve' "$c/runner.out" \
     && grep -q 'subagent_type: athena-shipwright' "$c/runner.out" \
     && grep -q "$c/repo/.git/leadtime-lanes/run-" "$c/runner.out" \
     && grep -q "$c/repo/ai-artifacts/lead-time/runs/.*\.summary" "$c/runner.out" \
     && [ ! -e "$(sd "$c")" ] && [ ! -e "$(lanes "$c")" ] && [ "$(invoked "$c")" = 0 ] \
     && [ ! -e "$c/telemetry-calls" ]; then
    ok "--dry-run ($form) prints a brief naming MODE: lead-time, the skill, the lane and the summary file; touches nothing"
  else
    bad "--dry-run ($form)" "rc=$rc out=$(cat "$c/runner.out") err=$(cat "$c/runner.err")"
  fi
done

c="$(new_case)"
rc="$(run_runner "$c" -- --frobnicate)"
if [ "$rc" = 64 ] && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$(sd "$c")" ]; then
  ok "an unknown argument exits 64 with Fix: and no state"
else
  bad "unknown argument" "rc=$rc err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
rc="$(run_runner "$c" LEADTIME_NOW=soon)"
if [ "$rc" = 64 ] && grep -q 'Fix:' "$c/runner.err" && [ "$(invoked "$c")" = 0 ]; then
  ok "a LEADTIME_NOW that is not epoch seconds exits 64 with Fix:"
else
  bad "bad LEADTIME_NOW" "rc=$rc err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
rc="$(run_runner "$c" LEADTIME_REPO="$c/seed/../not-a-repo")"
if [ "$rc" = 2 ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "a repo that is not a git checkout exits 2 with Fix:"
else
  bad "not a checkout" "rc=$rc err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '4. the single-run lock'

c="$(new_case)"
mkdir -p "$(sd "$c")/runs"
hold_lock "$(sd "$c")/run.lock" "$c"
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && [ "$(invoked "$c")" = 0 ] && [ -n "$(newest "$c" locked)" ] && grep -q 'Fix:' "$c/runner.err" \
   && [ ! -e "$(lanes "$c")" ]; then
  ok "a held lock: exit 0, a .locked record, no session and no lane"
else
  bad "lock held" "rc=$rc invoked=$(invoked "$c") err=$(cat "$c/runner.err")"
fi
release_holders
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && [ "$(invoked "$c")" = 1 ]; then
  ok "once the holder is gone the next tick runs"
else
  bad "after release" "rc=$rc err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '5-6. preconditions: the skill, the config, notion-personal'

c="$(new_case)"
rm -f "$c/repo/ai/skills/athena:lead-time-improve/SKILL.md"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'Fix:' "$c/runner.err" \
   && [ -n "$(newest "$c" failed)" ] && [ "$(lane_dirs "$c")" = 0 ]; then
  ok "the skill missing from the main checkout: exit 78, counted, no session, no lane"
else
  bad "skill missing" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
rm -f "$c/repo/ai/config/lead-time-repos.json"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'lead-time-repos.json' "$c/runner.err"; then
  ok "the repo config missing: exit 78, counted, no session"
else
  bad "config missing" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
jq --arg p "$c/repo" 'del(.projects[$p].mcpServers["notion-personal"])' "$c/claude.json" >"$c/cj" && mv "$c/cj" "$c/claude.json"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'notion-personal' "$c/runner.err" \
   && grep -q 'Fix:' "$c/runner.err"; then
  ok "notion-personal not registered: exit 78, counted, no session"
else
  bad "mcp missing" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
printf '{not json' >"$c/claude.json"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && grep -q 'not valid JSON' "$c/runner.err" && [ "$(invoked "$c")" = 0 ]; then
  ok "an unparseable claude.json is its own fault, never 'no servers registered'"
else
  bad "corrupt claude.json" "rc=$rc err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '7. a healthy run'

c="$(new_case)"
echo 1 >"$(mkdir -p "$(sd "$c")" && printf '%s' "$(sd "$c")")/consecutive-failures"
echo 1 >"$(sd "$c")/consecutive-blocked"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
lane_cwd="$(cat "$c/claude-cwd" 2>/dev/null)"
if [ "$rc" = 0 ] && [ -n "$run" ] && grep -q 'outcome=ok exit=0' "$run" && grep -q '^summary: repo=custom' "$run" \
   && grep -q '^prune=ok: pruned 2' "$run" && grep -q '^ff=none' "$run" && grep -q 'removed' "$run" \
   && [ ! -e "$(sd "$c")/consecutive-failures" ] && [ ! -e "$(sd "$c")/consecutive-blocked" ] \
   && [ "$(lane_dirs "$c")" = 0 ] && [ "$(lane_branches "$c")" = 0 ]; then
  ok "exit 0; .run has outcome ok, the summary and the prune result; lane and branch removed; both counters cleared"
else
  bad "healthy run" "rc=$rc run=$(cat "$run" 2>/dev/null) lanes=$(lane_dirs "$c") branches=$(lane_branches "$c") err=$(cat "$c/runner.err")"
fi
case "$lane_cwd" in
  "$c/repo/.git/leadtime-lanes/run-"*) ok "the session ran in its own lane under the git common dir ($lane_cwd)" ;;
  *) bad "session cwd" "cwd=$lane_cwd" ;;
esac
if [ "$(cat "$c/claude-fd8")" = closed ] && [ "$(cat "$c/claude-fd9")" = closed ]; then
  ok "the session inherits neither the run lock (fd 9) nor the lane lock (fd 8)"
else
  bad "lock fds" "fd8=$(cat "$c/claude-fd8") fd9=$(cat "$c/claude-fd9")"
fi
if [ "$(cat "$c/claude-mcp.mode")" = 600 ] \
   && [ "$(jq -c '.mcpServers | keys' "$c/claude-mcp.json")" = '["notion-personal"]' ] \
   && [ -z "$(find "$(lanes "$c")" -name '*.mcp.json' 2>/dev/null)" ]; then
  ok "the --mcp-config is 0600, carries notion-personal only, and is removed after the run"
else
  bad "mcp config" "mode=$(cat "$c/claude-mcp.mode") keys=$(jq -c '.mcpServers | keys' "$c/claude-mcp.json")"
fi
if [ "$(cat "$c/claude-state-env")" = "$c/repo/ai-artifacts/lead-time" ] \
   && grep -q "$c/repo/ai-artifacts/lead-time/runs/.*\.summary" "$c/claude-args" \
   && grep -q -- '--dangerously-skip-permissions' "$c/claude-args" \
   && [ "$(cat "$c/telemetry-calls")" = '--prune' ]; then
  ok "the session gets LEAD_TIME_STATE_DIR = the main checkout's state dir and its summary path; prune ran once, before it"
else
  bad "session env/brief" "state=$(cat "$c/claude-state-env") tel=$(cat "$c/telemetry-calls" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------------
case_ '8. a session that did no work is never read as success'

c="$(new_case)"; echo nosummary >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 70 ] && [ "$(fails "$c")" = 1 ] && grep -q 'outcome=failed exit=70' "$(newest "$c" run)" \
   && grep -q 'summary: (none' "$(newest "$c" run)"; then
  ok "exit 0 with no summary: exit 70, counted, the .run says so"
else
  bad "no summary" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

c="$(new_case)"; echo crash >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 3 ] && [ "$(fails "$c")" = 1 ] && [ ! -e "$(sd "$c")/consecutive-blocked" ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "a crash before the receipt with no limit wording is a counted failure, not BLOCKED"
else
  bad "crash" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '9. failures, the wedge, and ONE alert per episode'

c="$(new_case)"; echo fail >"$c/mode"
r1="$(run_runner "$c")"; r2="$(run_runner "$c")"; r3="$(run_runner "$c")"
if [ "$r1$r2$r3" = 777 ] && [ "$(fails "$c")" = 3 ] && [ "$(invoked "$c")" = 3 ] && [ "$(sends "$c" leadtime-wedged)" = 0 ]; then
  ok "three failing ticks each exit the session's code and count"
else
  bad "three failures" "rcs=$r1$r2$r3 fails=$(fails "$c") invoked=$(invoked "$c")"
fi
r4="$(run_runner "$c")"
wedged="$(newest "$c" wedged)"
if [ "$r4" = 75 ] && [ "$(invoked "$c")" = 3 ] && [ -n "$wedged" ] && grep -q "rearm: rm $(sd "$c")/consecutive-failures" "$wedged" \
   && grep -q '^wedged: consecutive_failures=3 threshold=3' "$wedged" && [ "$(sends "$c" leadtime-wedged)" = 1 ] \
   && grep -q -- "--re $wedged" "$c/send.log" && grep -q 'alert: harness-alerts msg-1.md' "$wedged"; then
  ok "the fourth tick exits 75, spawns nothing, writes .wedged with the re-arm, and sends ONE leadtime-wedged alert re: it"
else
  bad "wedge" "rc=$r4 wedged=$(cat "$wedged" 2>/dev/null) sends=$(cat "$c/send.log")"
fi
r5="$(run_runner "$c")"
if [ "$r5" = 75 ] && [ "$(sends "$c" leadtime-wedged)" = 1 ] && grep -q 'already sent' "$(newest "$c" wedged)"; then
  ok "a later wedged tick in the same episode sends nothing more"
else
  bad "wedge repeat" "rc=$r5 sends=$(sends "$c" leadtime-wedged)"
fi
rm -f "$(sd "$c")/consecutive-failures"
for _ in 1 2 3; do run_runner "$c" >/dev/null; done
r6="$(run_runner "$c")"
if [ "$r6" = 75 ] && [ "$(sends "$c" leadtime-wedged)" = 2 ]; then
  ok "after the re-arm (rm consecutive-failures), a new wedge alerts again"
else
  bad "new episode" "rc=$r6 sends=$(sends "$c" leadtime-wedged)"
fi

# ---------------------------------------------------------------------------------
case_ '10. BLOCKED: never counted, ONE alert per episode, cleared by a session that reaches the model'

c="$(new_case)"; echo limit >"$c/mode"
r1="$(run_runner "$c")"
s1="$(sends "$c" leadtime-blocked)"
r2="$(run_runner "$c")"
blocked="$(newest "$c" blocked)"
if [ "$r1$r2" = 6969 ] && [ "$(fails "$c")" = 0 ] && [ "$s1" = 0 ] && [ "$(sends "$c" leadtime-blocked)" = 1 ] \
   && grep -q 'classification=weekly limit' "$blocked" && grep -q '^blocked: consecutive_blocked=2 threshold=2' "$blocked" \
   && grep -q 'outcome=blocked exit=69' "$(newest "$c" run)" && [ "$(lane_dirs "$c")" = 0 ]; then
  ok "two blocked ticks: exit 69 both, not counted, exactly one leadtime-blocked alert, lanes removed"
else
  bad "blocked" "rcs=$r1$r2 fails=$(fails "$c") sends=$(cat "$c/send.log") err=$(cat "$c/runner.err")"
fi
r3="$(run_runner "$c")"
if [ "$r3" = 69 ] && [ "$(sends "$c" leadtime-blocked)" = 1 ]; then
  ok "a third blocked tick in the episode sends nothing more"
else
  bad "blocked repeat" "rc=$r3 sends=$(sends "$c" leadtime-blocked)"
fi
echo ok >"$c/mode"
r4="$(run_runner "$c")"
if [ "$r4" = 0 ] && [ ! -e "$(sd "$c")/consecutive-blocked" ] && [ ! -e "$(sd "$c")/blocked" ]; then
  ok "a successful tick clears consecutive-blocked and ends the episode"
else
  bad "blocked clear" "rc=$r4 err=$(cat "$c/runner.err")"
fi
c="$(new_case)"; echo blocked0 >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 69 ] && [ "$(fails "$c")" = 0 ] && grep -q 'classification=UNCLASSIFIED' "$(newest "$c" blocked)"; then
  ok "exit 0 with no receipt is BLOCKED (unclassified), not success"
else
  bad "blocked0" "rc=$rc err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '11. a stranded lane keeps its branch and counts'

c="$(new_case)"; echo strand >"$c/mode"
main_before="$(git -C "$c/repo" rev-parse main)"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 72 ] && [ "$(fails "$c")" = 1 ] && [ "$(lane_branches "$c")" = 1 ] && [ "$(lane_dirs "$c")" = 0 ] \
   && grep -q 'outcome=stranded exit=72' "$run" && grep -q 'KEPT' "$run" \
   && grep -q 'Fix:.*log origin/main\.\.leadtime/run-' "$c/runner.err" && grep -q 'branch -D leadtime/run-' "$c/runner.err" \
   && [ "$(git -C "$c/repo" rev-parse main)" = "$main_before" ]; then
  ok "commits not on origin/main: branch kept, worktree removed, exit 72, counted, Fix: names inspect and delete; main untouched"
else
  bad "stranded" "rc=$rc fails=$(fails "$c") branches=$(lane_branches "$c") run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '12. dead lanes are reaped by their lock, never a live one'

c="$(new_case)"
mkdir -p "$(lanes "$c")"
git -C "$c/repo" worktree add -q -b leadtime/run-dead "$(lanes "$c")/run-dead" origin/main
: >"$(lanes "$c")/run-dead.lock"
git -C "$c/repo" worktree add -q -b leadtime/run-live "$(lanes "$c")/run-live" origin/main
: >"$(lanes "$c")/run-live.lock"
hold_lock "$(lanes "$c")/run-live.lock" "$c"
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && [ ! -e "$(lanes "$c")/run-dead" ] && [ ! -e "$(lanes "$c")/run-dead.lock" ] \
   && ! git -C "$c/repo" show-ref --verify --quiet refs/heads/leadtime/run-dead \
   && grep -q 'reaped dead lane run-dead' "$c/runner.err"; then
  ok "a lane whose lock nobody holds is reaped at start (worktree, lock and landed branch)"
else
  bad "dead reap" "rc=$rc err=$(cat "$c/runner.err")"
fi
if [ -d "$(lanes "$c")/run-live" ] && git -C "$c/repo" show-ref --verify --quiet refs/heads/leadtime/run-live; then
  ok "a lane whose lock is held is left strictly alone"
else
  bad "live lane" "the held lane was touched"
fi
release_holders
c="$(new_case)"; echo fail >"$c/mode"
mkdir -p "$(lanes "$c")"
git -C "$c/repo" worktree add -q -b leadtime/run-corpse "$(lanes "$c")/run-corpse" origin/main
: >"$(lanes "$c")/run-corpse.lock"
rc="$(run_runner "$c")"
if [ "$rc" = 7 ] && [ "$(fails "$c")" = 2 ]; then
  ok "a reaped corpse counts toward the wedge, on top of the tick's own failure"
else
  bad "corpse counted" "rc=$rc fails=$(fails "$c")"
fi

# ---------------------------------------------------------------------------------
case_ '13. the main checkout is fast-forwarded only to work on origin/main'

c="$(new_case)"; echo land >"$c/mode"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
origin_tip="$(git -C "$c/origin.git" rev-parse main)"
if [ "$rc" = 0 ] && [ "$(git -C "$c/repo" rev-parse main)" = "$origin_tip" ] && [ -e "$c/repo/landed.txt" ] \
   && grep -q "^ff=$origin_tip" "$run" && grep -q 'commits=1' "$run" && [ "$(lane_branches "$c")" = 0 ]; then
  ok "a pushed lane commit lands in the main checkout by fast-forward; .run names the landing; branch deleted"
else
  bad "landed ff" "rc=$rc main=$(git -C "$c/repo" rev-parse main) origin=$origin_tip run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi
# (the unpushed side is case 11: main_before is unchanged)
c="$(new_case)"; echo land >"$c/mode"
git -C "$c/repo" checkout -q -b elsewhere
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && grep -q '^ff=REFUSED (the main checkout is on refs/heads/elsewhere' "$(newest "$c" run)" \
   && [ "$(git -C "$c/repo" rev-parse HEAD)" != "$(git -C "$c/origin.git" rev-parse main)" ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "a main checkout that is not on main is never moved; the .run and Fix: say so"
else
  bad "ff off main" "rc=$rc err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
git -C "$c/repo" remote remove origin
rc="$(run_runner "$c")"
if [ "$rc" = 1 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'Fix:' "$c/runner.err" \
   && [ "$(lane_dirs "$c")" = 0 ]; then
  ok "no origin/main to cut from: exit 1, counted, no lane and no session (a miss is never a lane cut from elsewhere)"
else
  bad "no origin" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '14. a prune failure is recorded and never fails the tick'

c="$(new_case)"; echo fail >"$c/telemetry-mode"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -q 'outcome=ok' "$run" && grep -q '^prune=FAILED exit=1' "$run" \
   && [ ! -e "$(sd "$c")/consecutive-failures" ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "telemetry-emit --prune exit 1: .run records prune=FAILED, the outcome is ok, nothing counted"
else
  bad "prune failure" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi
c="$(new_case)"
rc="$(run_runner "$c" LEADTIME_TELEMETRY_EMIT="$c/no-such-telemetry-emit")"
if [ "$rc" = 0 ] && grep -q '^prune=FAILED exit=127' "$(newest "$c" run)"; then
  ok "a missing telemetry-emit reads as a FAILED prune (exit 127), never as a quiet one"
else
  bad "missing telemetry-emit" "rc=$rc run=$(cat "$(newest "$c" run)" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------------
case_ '15. classification'

if grep -q $'^scripts/athena-leadtime-run.sh\tguard' "${REPO_ROOT}/ai/guard-classification.tsv"; then
  ok "ai/guard-classification.tsv classifies the runner as a guard"
else
  bad "classification" "no guard row for scripts/athena-leadtime-run.sh"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
