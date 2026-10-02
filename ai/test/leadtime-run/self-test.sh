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
# A registry entry for this checkout under the pinned root, so the one case
# that uses the REAL send-mail delivers into the temp inbox and nowhere else.
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
NOW_FIXED="$(date -d '2026-10-01 12:30 UTC' +%s)"
G=(-c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main)
RESOLVER_LIBS="strict_argv.rb lead_time_config.rb lead_time_config_io.rb leadtime_product.rb leadtime_product_io.rb lead_time_trailer.rb"

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
  mkdir -p "$seed/ai/skills/athena:lead-time-improve" "$seed/ai/config" "$seed/ai/bin" "$seed/ai/lib"
  printf -- '---\nname: athena:lead-time-improve\n---\n' >"$seed/ai/skills/athena:lead-time-improve/SKILL.md"
  # The real resolver (DND-1526), so every case resolves the list as the cron does.
  cp -- "${REPO_ROOT}/ai/bin/lead-time-repos" "$seed/ai/bin/"
  # The real product-lane tool (DND-1540), so a product repo is worked as the cron works it.
  cp -- "${REPO_ROOT}/ai/bin/leadtime-product" "$seed/ai/bin/"
  for f in ${RESOLVER_LIBS}; do cp -- "${REPO_ROOT}/ai/lib/$f" "$seed/ai/lib/"; done
  # The checkouts the configs point at: temp repos named as the repos are.
  for r in custom gen_saas walt_ui; do git "${G[@]}" init -q "$c/checkouts/$r"; done
  printf '{"repos":[{"name":"custom","path":"%s","mode":"improve"}],"window":20,"improvement_epic":"epic-fixture"}\n' \
    "$c/checkouts/custom" >"$seed/ai/config/lead-time-repos.json"
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
# other_fleet — another fleet lands a commit on origin/main while this run is
# in flight (from its own clone, never this lane).
other_fleet() {
  local o; o="$(mktemp -d -p "$d" other.XXXXXX)"
  git clone -q "$(git remote get-url origin)" "$o/c" 2>/dev/null
  echo "$RANDOM" >"$o/c/other-$(basename "$o").txt"
  g -C "$o/c" add -A >/dev/null; g -C "$o/c" commit -q -m "another fleet's change"
  g -C "$o/c" push -q origin HEAD:main 2>/dev/null || exit 9
  g -C "$o/c" rev-parse HEAD >>"$d/other-shas"
}
# sync_down — the lane's sync down (athena:shipwright-lane -> Sync down first).
sync_down() { git fetch -q origin main && g rebase -q FETCH_HEAD; }
own_land() { # <file> — commit one change in the lane and push it to main
  echo change >"$1"; g add "$1" >/dev/null; g commit -q -m "own change $1"
  g rev-parse HEAD >>"$d/own-shas"
  g push -q origin HEAD:main 2>/dev/null || exit 9
}
case "$(cat "$d/mode" 2>/dev/null || echo ok)" in
  ok)        : >"$LEADTIME_RECEIPT"; summary; exit 0 ;;
  noreceipt) summary; exit 0 ;;
  fail)      : >"$LEADTIME_RECEIPT"; echo "the run fell over"; exit 7 ;;
  timeout)   : >"$LEADTIME_RECEIPT"; exit 124 ;;
  nosummary) : >"$LEADTIME_RECEIPT"; exit 0 ;;
  blocked0)  exit 0 ;;
  limit)     echo "You've hit your weekly limit"; exit 1 ;;
  crash)     echo "segmentation fault"; exit 3 ;;
  strand)    : >"$LEADTIME_RECEIPT"; echo change >strand.txt; g add strand.txt >/dev/null; g commit -q -m "unlanded change"; summary; exit 0 ;;
  corrupt-ref) : >"$LEADTIME_RECEIPT"; b="$(git symbolic-ref --short HEAD)"; echo "$b" >"$d/corrupt-branch"
             printf 'not-a-sha\n' >"$(git rev-parse --path-format=absolute --git-common-dir)/refs/heads/$b"; summary; exit 0 ;;
  strand-noreceipt) echo change >strand.txt; g add strand.txt >/dev/null; g commit -q -m "unlanded change"; exit 0 ;;
  land)      : >"$LEADTIME_RECEIPT"; echo change >landed.txt; g add landed.txt >/dev/null; g commit -q -m "landed change"
             g push -q origin HEAD:main 2>/dev/null || exit 9; summary; exit 0 ;;
  moved)     : >"$LEADTIME_RECEIPT"; other_fleet; sync_down; summary; exit 0 ;;
  moved-land) : >"$LEADTIME_RECEIPT"; other_fleet; sync_down; own_land own.txt; summary; exit 0 ;;
  land-moved) : >"$LEADTIME_RECEIPT"; own_land own.txt; other_fleet; sync_down; summary; exit 0 ;;
  rebase-land) : >"$LEADTIME_RECEIPT"; echo change >own.txt; g add own.txt >/dev/null; g commit -q -m "own change"
             # pull by URL, as an improvised HTTPS fallback would: the argv in
             # the reflog action then holds a colon
             other_fleet; g pull -q --rebase "file://$(git remote get-url origin)" main
             g rev-parse HEAD >>"$d/own-shas"; g push -q origin HEAD:main 2>/dev/null || exit 9; summary; exit 0 ;;
  land-strand) : >"$LEADTIME_RECEIPT"; own_land own.txt; echo more >more.txt; g add more.txt >/dev/null
             g commit -q -m "unpushed own change"; g rev-parse HEAD >>"$d/unpushed-shas"; summary; exit 0 ;;
  truncreflog-land): >"$LEADTIME_RECEIPT"; b="$(git rev-parse HEAD)"; own_land own.txt
             # drop the lane-creation entries (every entry whose new value is BASE)
             f="$(git rev-parse --git-path logs/HEAD)"; awk -v b="$b" '$2 != b' "$f" >"$f.t" && mv "$f.t" "$f"
             summary; exit 0 ;;
  noreflog-land) : >"$LEADTIME_RECEIPT"; own_land own.txt; rm -f "$(git rev-parse --git-path logs/HEAD)"; summary; exit 0 ;;
  own-branch-gone) : >"$LEADTIME_RECEIPT"; b="$(git symbolic-ref --short HEAD)"
             git checkout -q --detach; git branch -q -D "$b"; summary; exit 0 ;;
  delete-refused) : >"$LEADTIME_RECEIPT"; b="$(git symbolic-ref --short HEAD)"; echo "$b" >"$d/refused-branch"
             # a held ref lock: teardown's `git branch -D` is refused (DND-1715)
             : >"$(git rev-parse --path-format=absolute --git-common-dir)/refs/heads/$b.lock"; summary; exit 0 ;;
  product-*)
    # A product repo's lane (DND-1540), through the real tool the brief names.
    : >"$LEADTIME_RECEIPT"
    printf '%s\n' "${LEADTIME_PRODUCT_MANIFEST:-}" >"$d/claude-product-manifest"
    tool="$d/repo/ai/bin/leadtime-product"
    "$tool" cut --repo gen_saas --phase verify >"$d/cut.out" 2>&1 || echo "cut-rc=$?" >>"$d/cut.out"
    lock="$(jq -r '.repos[] | select(.name == "gen_saas") | .lock' "$LEADTIME_PRODUCT_MANIFEST")"
    if flock -n "$lock" true; then echo free >"$d/product-lock"; else echo held >"$d/product-lock"; fi
    lane="$(sed -n 's/^lane=//p' "$d/cut.out")"
    if [ "$(cat "$d/mode")" != product-cut ] && [ -n "$lane" ]; then
      # The commit carries the trailer line cut printed (DND-1529).
      echo change >"$lane/fix.txt"; g -C "$lane" add fix.txt >/dev/null
      g -C "$lane" commit -q -m "product change" -m "$(sed -n 's/^trailer=//p' "$d/cut.out")"
      if [ "$(cat "$d/mode")" = product-pr ]; then
        echo "before/after evidence" >"$d/evidence.md"
        "$tool" pr --repo gen_saas --title "speed up verify" --body-file "$d/evidence.md" >"$d/pr.out" 2>&1 || echo "pr-rc=$?" >>"$d/pr.out"
      fi
    fi
    summary; exit 0 ;;
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
  # XDG_CONFIG_HOME is an empty temp dir and ATHENA_LEADTIME_CONFIG is unset
  # unless a case passes it, so no case reads this machine's real override.
  env -u ATHENA_LEADTIME_CONFIG XDG_CONFIG_HOME="$c/xdg" \
      LEADTIME_REPO="$c/repo" LEADTIME_CLAUDE="$c/stub-claude" LEADTIME_CLAUDE_JSON="$c/claude.json" \
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
mkdir -p "$c/plain-dir"
rc="$(run_runner "$c" LEADTIME_REPO="$c/plain-dir")"
if [ "$rc" = 2 ] && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$c/plain-dir/ai-artifacts" ]; then
  ok "an existing directory that is not a git checkout exits 2 with Fix: and no state"
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
if [ "$rc" = 78 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'lead-time-repos.json' "$c/runner.err" \
   && grep -q 'lead-time-repos exit 3' "$c/runner.err" && [ "$(lane_dirs "$c")" = 0 ]; then
  ok "the tracked repo config missing: the resolver cannot look (exit 3), so exit 78, counted, no session"
else
  bad "config missing" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
rm -f "$c/repo/ai/bin/lead-time-repos"
rc="$(run_runner "$c")"
if [ "$rc" = 78 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] \
   && grep -qF "lead-time-repos not run): $c/repo/ai/bin/lead-time-repos is absent" "$c/runner.err" \
   && grep -qF 'Fix: land ai/bin/lead-time-repos (DND-1526) on main' "$c/runner.err"; then
  ok "the resolver missing from the main checkout: exit 78, counted, no session (never the tracked file read directly)"
else
  bad "resolver missing" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '5b. the repo list comes from ai/bin/lead-time-repos (DND-1527)'

# override <case> <json> — a machine-local override for the case (mode 600).
override() { ( umask 077; printf '%s\n' "$2" >"$1/override.json" ); }

# No override: the desktop's runs are unchanged. The tracked list's names and
# modes (the REAL ai/config/lead-time-repos.json, its paths moved to temp
# checkouts) are exactly the repos the brief names, plus config=default.
c="$(new_case)"
jq --arg d "$c/checkouts" '.repos |= map(.path = ($d + "/" + .name))' "${REPO_ROOT}/ai/config/lead-time-repos.json" \
  >"$c/repo/ai/config/lead-time-repos.json"
want="$(jq -r --arg d "$c/checkouts" '[.repos[] | "\(.name) (\(.mode), \($d)/\(.name))"] | join("; ")' \
  "${REPO_ROOT}/ai/config/lead-time-repos.json")"
want_names="$(jq -r '[.repos[].name] | join(",")' "${REPO_ROOT}/ai/config/lead-time-repos.json")"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && [ -n "$want" ] && grep -qF "these repos, which ai/bin/lead-time-repos resolved for this machine (config=default" "$c/claude-args" \
   && grep -qF ": ${want}." "$c/claude-args" \
   && grep -qxF "config=default repos=${want_names} skipped=none" "$run" \
   && grep -qxF "config_file=$c/repo/ai/config/lead-time-repos.json" "$run" \
   && grep -q 'outcome=ok exit=0' "$run" && ! grep -q 'Skipped on this machine' "$c/claude-args"; then
  ok "no override: the brief names the tracked list ($want); .run says config=default repos=${want_names} skipped=none"
else
  bad "no override" "rc=$rc run=$(cat "$run" 2>/dev/null) args=$(cat "$c/claude-args" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
override "$c" "{\"repos\":[{\"name\":\"gen_saas\",\"path\":\"$c/checkouts/gen_saas\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-fixture\"}"
rc="$(run_runner "$c" ATHENA_LEADTIME_CONFIG="$c/override.json")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -qF "(config=override $c/override.json): gen_saas (improve, $c/checkouts/gen_saas)." "$c/claude-args" \
   && ! grep -q 'custom (improve)' "$c/claude-args" \
   && grep -qxF "config=override repos=gen_saas skipped=none" "$run" \
   && grep -qxF "config_file=$c/override.json" "$run"; then
  ok "an override naming gen_saas only: the brief and .run name gen_saas; custom is absent"
else
  bad "override gen_saas" "rc=$rc run=$(cat "$run" 2>/dev/null) args=$(cat "$c/claude-args" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
mkdir -p "$c/xdg/athena"
( umask 077; printf '{"repos":[{"name":"walt_ui","path":"%s","mode":"watch"}],"window":20,"improvement_epic":"epic-fixture"}\n' \
    "$c/checkouts/walt_ui" >"$c/xdg/athena/lead-time-repos.json" )
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -qxF "config=override repos=walt_ui skipped=none" "$run" && grep -qF "walt_ui (watch, $c/checkouts/walt_ui)." "$c/claude-args"; then
  ok "the XDG override file is found the same way (the runner passes no path of its own)"
else
  bad "xdg override" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
override "$c" "{\"repos\":[{\"name\":\"custom\",\"path\":\"$c/checkouts/custom\",\"mode\":\"improve\"},{\"name\":\"walt_ui\",\"path\":\"$c/absent/walt_ui\",\"mode\":\"watch\"}],\"window\":20,\"improvement_epic\":\"epic-fixture\"}"
rc="$(run_runner "$c" ATHENA_LEADTIME_CONFIG="$c/override.json")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -qxF "config=override repos=custom skipped=walt_ui(no such path $c/absent/walt_ui)" "$run" \
   && grep -qF "Skipped on this machine, so not run: walt_ui (no such path $c/absent/walt_ui)" "$c/claude-args" \
   && grep -qF 'repo=<R> skipped=' "$c/claude-args" && grep -qF ": custom (improve, $c/checkouts/custom)." "$c/claude-args"; then
  ok "a repo not checked out here is skipped by name: in .run (skipped=<name>(<reason>)) and in the brief, never silently"
else
  bad "skipped repo" "rc=$rc run=$(cat "$run" 2>/dev/null) args=$(cat "$c/claude-args" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
override "$c" '{"repos":['
rc="$(run_runner "$c" ATHENA_LEADTIME_CONFIG="$c/override.json")"
failed="$(newest "$c" failed)"
if [ "$rc" = 78 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] && [ "$(lane_dirs "$c")" = 0 ] \
   && grep -q 'lead-time-repos exit 2' "$c/runner.err" && grep -q '^resolver: lead-time-repos: ' "$failed" \
   && grep -q '^resolver: Fix: ' "$failed" && grep -q 'Fix:' "$c/runner.err"; then
  ok "a malformed override: exit 78, counted, no session; the resolver's line and Fix: are in the .failed record"
else
  bad "malformed override" "rc=$rc fails=$(fails "$c") failed=$(cat "$failed" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
override "$c" "{\"repos\":[{\"name\":\"custom\",\"path\":\"$c/absent/custom\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-fixture\"}"
rc="$(run_runner "$c" ATHENA_LEADTIME_CONFIG="$c/override.json")"
if [ "$rc" = 78 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'lead-time-repos exit 4' "$c/runner.err" \
   && grep -q 'no configured repo is checked out' "$c/runner.err" && grep -q 'Fix:' "$c/runner.err"; then
  ok "zero resolved repos: a counted failure (exit 78) with Fix:, never an empty success"
else
  bad "zero repos" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
override "$c" '{"repos":['
rc="$(run_runner "$c" ATHENA_LEADTIME_CONFIG="$c/override.json" -- --dry-run)"
if [ "$rc" = 78 ] && grep -q 'Fix:' "$c/runner.err" && [ ! -e "$(sd "$c")" ] && [ ! -e "$(lanes "$c")" ] \
   && [ "$(invoked "$c")" = 0 ] && ! grep -q 'MODE: lead-time' "$c/runner.out"; then
  ok "--dry-run with a list that does not resolve: exit 78 with Fix:, prints no brief, touches nothing"
else
  bad "dry-run unresolved" "rc=$rc out=$(cat "$c/runner.out") err=$(cat "$c/runner.err")"
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

# DND-1571: --dry-run runs the same preflight, so a rendered brief means a
# tick can start. Each failure: exit 78, the tick's Fix:, no brief, no state.
dry_refused() { # <case> <label> <grep pattern on stderr>
  local c="$1" rc
  rc="$(run_runner "$c" -- --dry-run)"
  if [ "$rc" = 78 ] && grep -q -- "$3" "$c/runner.err" && grep -q 'Fix:' "$c/runner.err" \
     && grep -q 'a tick would exit 78' "$c/runner.err" && ! grep -q 'MODE: lead-time' "$c/runner.out" \
     && [ ! -e "$(sd "$c")" ] && [ ! -e "$(lanes "$c")" ] && [ "$(invoked "$c")" = 0 ]; then
    ok "--dry-run with $2: exit 78 with Fix:, prints no brief, touches nothing"
  else
    bad "dry-run $2" "rc=$rc out=$(head -3 "$c/runner.out") err=$(cat "$c/runner.err")"
  fi
}
c="$(new_case)"
jq --arg p "$c/repo" 'del(.projects[$p].mcpServers["notion-personal"])' "$c/claude.json" >"$c/cj" && mv "$c/cj" "$c/claude.json"
dry_refused "$c" "notion-personal not registered" 'Fix:.*scripts/add-notion --personal.*notion-personal'
c="$(new_case)"
rm -f -- "$c/claude.json"
dry_refused "$c" "the Claude config missing (could not look)" "cannot read $c/claude.json"
c="$(new_case)"
printf '{not json' >"$c/claude.json"
dry_refused "$c" "an invalid Claude config (could not look)" 'not valid JSON'
c="$(new_case)"
git -C "$c/repo" rm -q -- 'ai/skills/athena:lead-time-improve/SKILL.md'
dry_refused "$c" "the skill not in the main checkout" 'athena:lead-time-improve skill is not in the main checkout'

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
if [ "$(cat "$c/claude-fd8")" = open ] && [ "$(cat "$c/claude-fd9")" = closed ]; then
  ok "the session keeps the lane lock (fd 8) held and never inherits the run lock (fd 9)"
else
  bad "lock fds" "fd8=$(cat "$c/claude-fd8") fd9=$(cat "$c/claude-fd9")"
fi
if [ "$(cat "$c/claude-mcp.mode")" = 600 ] \
   && [ "$(jq -c '.mcpServers | keys' "$c/claude-mcp.json")" = '["notion-personal"]' ] \
   && grep -qx -- '--strict-mcp-config' "$c/claude-args" \
   && [ -z "$(find "$(lanes "$c")" -name '*.mcp.json' 2>/dev/null)" ]; then
  ok "the --mcp-config is 0600, carries notion-personal only, is strict, and is removed after the run"
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

c="$(new_case)"; echo timeout >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 124 ] && [ "$(fails "$c")" = 1 ] && grep -q 'outcome=failed exit=124' "$(newest "$c" run)" \
   && grep -q 'timeout' "$c/runner.err"; then
  ok "a session timeout (124) is a counted failure and the Fix: names the timeout"
else
  bad "timeout" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

c="$(new_case)"; echo noreceipt >"$c/mode"
echo 1 >"$(mkdir -p "$(sd "$c")" && printf '%s' "$(sd "$c")")/consecutive-failures"
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && [ ! -e "$(sd "$c")/consecutive-failures" ] && [ ! -e "$(sd "$c")/consecutive-blocked" ] \
   && [ -z "$(newest "$c" blocked)" ]; then
  ok "a run that wrote its summary but skipped the receipt is ok, never BLOCKED (the summary proves the model ran)"
else
  bad "summary without receipt" "rc=$rc err=$(cat "$c/runner.err")"
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
if [ "$r5" = 75 ] && [ "$(sends "$c" leadtime-wedged)" = 1 ] && grep -q 'already sent' "$(newest "$c" wedged)" \
   && [ "$(grep -c . "$c/telemetry-calls")" = 5 ] && grep -q '^prune=ok: pruned 2' "$(newest "$c" wedged)"; then
  ok "a later wedged tick in the same episode sends nothing more; wedged ticks still prune and record it"
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

# The alert must be deliverable by the real sender, not only the fake: the
# real send-mail, into the pinned temp inbox.
c="$(new_case)"; echo fail >"$c/mode"
run_runner "$c" LEADTIME_FAIL_ESCALATE=1 LEADTIME_SEND_MAIL= >/dev/null
rc="$(run_runner "$c" LEADTIME_FAIL_ESCALATE=1 LEADTIME_SEND_MAIL=)"
msg="$(find "$ALERTS" -maxdepth 1 -type f -name '*-leadtime-wedged.md' 2>/dev/null | head -n1)"
if [ "$rc" = 75 ] && [ -n "$msg" ] && grep -q "$(newest "$c" wedged)" "$msg" \
   && grep -q 'alert: harness-alerts ' "$(newest "$c" wedged)" && ! grep -q 'FAILED to send' "$(newest "$c" wedged)"; then
  ok "the real send-mail delivers ONE -leadtime-wedged.md on harness-alerts, re: the .wedged record"
else
  bad "real send-mail" "rc=$rc msg=$msg err=$(cat "$c/runner.err")"
fi

# send-mail exits 0 but prints no delivered line: NOT a confirmed delivery
# (DND-1513). It is recorded FAILED, never stored as alerted, and the next
# wedged tick retries.
cat >"$TMP/quiet-send-mail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SEND_LOG:?}"; exit 0
EOF
chmod +x "$TMP/quiet-send-mail"
c="$(new_case)"; echo fail >"$c/mode"
run_runner "$c" LEADTIME_FAIL_ESCALATE=1 >/dev/null
r1="$(run_runner "$c" LEADTIME_FAIL_ESCALATE=1 LEADTIME_SEND_MAIL="$TMP/quiet-send-mail")"
s1="$(sends "$c" leadtime-wedged)"; w1="$(newest "$c" wedged)"
r2="$(run_runner "$c" LEADTIME_FAIL_ESCALATE=1)"
if [ "$r1$r2" = 7575 ] && [ "$s1" = 1 ] && grep -qx 'alert: FAILED to send' "$w1" \
   && [ "$(sends "$c" leadtime-wedged)" = 2 ] && grep -q '^alert: harness-alerts msg-2.md' "$(newest "$c" wedged)"; then
  ok "exit 0 with no delivered line is not sent: recorded FAILED, and the next wedged tick sends it"
else
  bad "quiet send" "rcs=$r1$r2 s1=$s1 w1=$(cat "$w1" 2>&1) sends=$(cat "$c/send.log" 2>&1) err=$(cat "$c/runner.err")"
fi
# A state an older runner wrote with the unconfirmed placeholder is retried.
sed -i 's/^alerted=.*/alerted=(delivered; name not reported)/' "$(sd "$c")/wedged"
r3="$(run_runner "$c" LEADTIME_FAIL_ESCALATE=1)"
if [ "$r3" = 75 ] && [ "$(sends "$c" leadtime-wedged)" = 3 ] && grep -q '^alert: harness-alerts msg-3.md' "$(newest "$c" wedged)"; then
  ok "a stored '(delivered; name not reported)' is unconfirmed: the next wedged tick sends and records the name"
else
  bad "legacy placeholder" "rc=$r3 sends=$(cat "$c/send.log" 2>&1) state=$(cat "$(sd "$c")/wedged" 2>&1)"
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
c="$(new_case)"; echo strand-noreceipt >"$c/mode"
rc="$(run_runner "$c")"
if [ "$rc" = 72 ] && [ "$(fails "$c")" = 1 ] && [ "$(lane_branches "$c")" = 1 ] && [ -z "$(newest "$c" blocked)" ]; then
  ok "stranded commits with no receipt still exit 72 and count; never exit 0, never BLOCKED"
else
  bad "stranded no receipt" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi
# The run's own lane branch ref is corrupt (DND-1662): COULD NOT TELL, never a
# clean run and never mislabelled "commits not on origin/main"; the record and
# the Fix: name the unreadable ref, and the ref file is left as found.
c="$(new_case)"; echo corrupt-ref >"$c/mode"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"; failed="$(newest "$c" failed)"
cb="$(cat "$c/corrupt-branch" 2>/dev/null)"; cref="$c/repo/.git/refs/heads/$cb"
if [ "$rc" = 72 ] && [ "$(fails "$c")" = 1 ] && [ -n "$cb" ] && [ "$(cat "$cref" 2>/dev/null)" = "not-a-sha" ] \
   && grep -q 'COULD NOT TELL: git cannot read its ref' "$run" && ! grep -q 'commits not on origin/main' "$run" \
   && grep -q 'COULD NOT TELL: git cannot read the lane branch' "$failed" \
   && grep -q "Fix:.*show-ref --exists refs/heads/$cb.*logs/refs/heads/$cb" "$c/runner.err"; then
  ok "own lane branch ref corrupt: COULD NOT TELL, exit 72, counted, the record and Fix: name the unreadable ref, the ref left as found"
else
  bad "own lane corrupt ref" "rc=$rc fails=$(fails "$c") ref=$(cat "$cref" 2>&1) run=$(cat "$run" 2>/dev/null) failed=$(cat "$failed" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '11b. a refused branch delete is reported, never counted (DND-1715)'

# The run's own lane landed (no commits), but `git branch -D` is refused (a held
# ref lock). The branch is kept and named in stderr, the .run and the
# .branch-kept record, each with the delete to run. The tick stays a clean
# success: exit 0, the failure counter cleared (owner rule: never wedge the
# lead-time cron over hygiene).
c="$(new_case)"; echo delete-refused >"$c/mode"
echo 1 >"$(mkdir -p "$(sd "$c")" && printf '%s' "$(sd "$c")")/consecutive-failures"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"; kept="$(newest "$c" branch-kept)"
rb="$(cat "$c/refused-branch" 2>/dev/null)"
if [ "$rc" = 0 ] && [ "$(fails "$c")" = 0 ] && [ -z "$(newest "$c" failed)" ] && [ -n "$rb" ] \
   && git -C "$c/repo" show-ref --verify --quiet "refs/heads/$rb" && [ "$(lane_dirs "$c")" = 0 ] \
   && grep -q 'outcome=ok exit=0' "$run" \
   && grep -q "branch=$rb (branch $rb KEPT (delete REFUSED" "$run" \
   && grep -q "^branch_delete: .*$rb.*Fix: git -C $c/repo branch -D $rb" "$run" \
   && [ -n "$kept" ] && grep -q "Fix: git -C $c/repo branch -D $rb" "$kept" \
   && grep -q "could not delete branch $rb" "$c/runner.err" \
   && grep -q "Fix:.*git -C $c/repo branch -D $rb" "$c/runner.err"; then
  ok "own lane: a refused branch -D keeps the branch, names it with a Fix: in stderr, .run and .branch-kept; exit 0, counter cleared"
else
  bad "own lane delete refused" "rc=$rc fails=$(fails "$c") branch=$rb run=$(cat "$run" 2>/dev/null) kept=$(cat "$kept" 2>/dev/null) err=$(cat "$c/runner.err")"
fi
# A healthy run says so: a .run with no refusal reads branch_delete=ok, so an
# absent line is never mistaken for a clean delete.
c="$(new_case)"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -qx 'branch_delete=ok' "$run" && [ -z "$(newest "$c" branch-kept)" ]; then
  ok "a run whose deletes all succeeded records branch_delete=ok and leaves no .branch-kept record"
else
  bad "delete ok line" "rc=$rc run=$(cat "$run" 2>/dev/null)"
fi
# A dead lane's landed branch whose delete is refused: kept and named; the reap
# counts exactly as a reap always does, never once more for the refusal: with a
# failing session that is 2 (the corpse and the tick), as in case 12.
c="$(new_case)"; echo fail >"$c/mode"
mkdir -p "$(lanes "$c")"
git -C "$c/repo" worktree add -q -b leadtime/run-heldref "$(lanes "$c")/run-heldref" origin/main
: >"$(lanes "$c")/run-heldref.lock"
: >"$c/repo/.git/refs/heads/leadtime/run-heldref.lock"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"; kept="$(newest "$c" branch-kept)"
if [ "$rc" = 7 ] && [ "$(fails "$c")" = 2 ] && [ ! -e "$(lanes "$c")/run-heldref" ] \
   && git -C "$c/repo" show-ref --verify --quiet refs/heads/leadtime/run-heldref \
   && grep -q 'reaped dead lane run-heldref' "$c/runner.err" \
   && grep -q "could not delete branch leadtime/run-heldref (reaped dead run)" "$c/runner.err" \
   && grep -q "Fix:.*branch -D leadtime/run-heldref" "$c/runner.err" \
   && [ -n "$kept" ] && grep -q 'leadtime/run-heldref' "$kept" \
   && grep -q '^branch_delete: .*leadtime/run-heldref' "$run"; then
  ok "reap: a refused delete of a dead lane's branch is named with a Fix: in stderr, .branch-kept and .run; counted exactly as any reap (2 with the failing tick)"
else
  bad "reap delete refused" "rc=$rc fails=$(fails "$c") run=$(cat "$run" 2>/dev/null) kept=$(cat "$kept" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# A refusal from an earlier lane never speaks for this run's own: the lockless
# reap (in the runner's own shell) is refused, then the run's own branch is
# already gone at teardown, so its delete is never tried. The lane= line must
# not claim the run's branch was KEPT.
c="$(new_case)"; echo own-branch-gone >"$c/mode"
mkdir -p "$(lanes "$c")"
git -C "$c/repo" worktree add -q -b leadtime/run-lockheld "$(lanes "$c")/run-lockheld" origin/main
: >"$c/repo/.git/refs/heads/leadtime/run-lockheld.lock"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if grep -q 'reaped lockless lane run-lockheld' "$c/runner.err" \
   && grep -q '^branch_delete: reaped lockless lane: branch leadtime/run-lockheld KEPT' "$run" \
   && grep -q '^lane=.* (removed)$' "$run" && ! grep -q 'delete REFUSED' "$run"; then
  ok "an earlier lane's refused delete is named for that lane only; the run's own lane= line is not marked KEPT"
else
  bad "stale refusal flag" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
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

c="$(new_case)"; echo nosummary >"$c/mode"
mkdir -p "$(lanes "$c")"
git -C "$c/repo" worktree add -q -b leadtime/run-lockless "$(lanes "$c")/run-lockless" origin/main
git -C "$c/repo" worktree add -q -b leadtime/run-workdead "$(lanes "$c")/run-workdead" origin/main
echo work >"$(lanes "$c")/run-workdead/w.txt"
git -C "$(lanes "$c")/run-workdead" add w.txt
git "${G[@]}" -C "$(lanes "$c")/run-workdead" commit -q -m "dead run's work"
: >"$(lanes "$c")/run-workdead.lock"
rc="$(run_runner "$c")"
if [ ! -e "$(lanes "$c")/run-lockless" ] && grep -q 'reaped lockless lane run-lockless' "$c/runner.err" \
   && ! git -C "$c/repo" show-ref --verify --quiet refs/heads/leadtime/run-lockless; then
  ok "a lane dir with no lock file is reaped (a crash between worktree add and the lock)"
else
  bad "lockless reap" "err=$(cat "$c/runner.err")"
fi
if [ ! -e "$(lanes "$c")/run-workdead" ] && git -C "$c/repo" show-ref --verify --quiet refs/heads/leadtime/run-workdead \
   && grep -q 'kept STRANDED branch leadtime/run-workdead' "$c/runner.err" && [ "$rc" = 70 ] && [ "$(fails "$c")" = 3 ]; then
  ok "a dead lane's unlanded commits keep their branch; both corpses and the tick are counted (3)"
else
  bad "dead lane with work" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

# A dead lane whose branch ref is corrupt (DND-1662): `show-ref --verify`
# answers it as it answers a missing ref, so the reap read it as "no branch"
# and said nothing. It is COULD NOT TELL, named with a Fix:, and the ref file
# is left exactly as found.
c="$(new_case)"
mkdir -p "$(lanes "$c")"
git -C "$c/repo" worktree add -q -b leadtime/run-corrupt "$(lanes "$c")/run-corrupt" origin/main
: >"$(lanes "$c")/run-corrupt.lock"
cref="$c/repo/.git/refs/heads/leadtime/run-corrupt"
printf 'not-a-sha\n' >"$cref"
rc="$(run_runner "$c")"
if [ -f "$cref" ] && [ "$(cat "$cref")" = "not-a-sha" ] \
   && grep -q 'COULD NOT TELL whether branch leadtime/run-corrupt exists' "$c/runner.err" \
   && grep -q 'Fix:.*show-ref --exists refs/heads/leadtime/run-corrupt' "$c/runner.err"; then
  ok "a dead lane whose branch ref is corrupt: COULD NOT TELL with a Fix:, the ref file left as found"
else
  bad "corrupt lane branch" "rc=$rc ref=$(cat "$cref" 2>&1) err=$(cat "$c/runner.err")"
fi

c="$(new_case)"
: >"$c/not-a-dir"
rc="$(run_runner "$c" LEADTIME_LANES_DIR="$c/not-a-dir/lanes")"
if [ "$rc" = 73 ] && [ "$(fails "$c")" = 1 ] && [ "$(invoked "$c")" = 0 ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "a lane that cannot be created: exit 73, counted, no session"
else
  bad "lane create failure" "rc=$rc fails=$(fails "$c") err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '13. the main checkout is fast-forwarded only to work on origin/main'

c="$(new_case)"; echo land >"$c/mode"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
origin_tip="$(git -C "$c/origin.git" rev-parse main)"
if [ "$rc" = 0 ] && [ "$(git -C "$c/repo" rev-parse main)" = "$origin_tip" ] && [ -e "$c/repo/landed.txt" ] \
   && grep -q "^ff=$origin_tip" "$run" && grep -q "^own_landed=1 $origin_tip\$" "$run" \
   && grep -q '^main_moved=.* commits=1$' "$run" && [ "$(lane_branches "$c")" = 0 ]; then
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

c="$(new_case)"; echo land >"$c/mode"
echo "someone's local file" >"$c/repo/landed.txt"
rc="$(run_runner "$c")"
if [ "$rc" = 0 ] && grep -q '^ff=REFUSED (see ' "$(newest "$c" run)" \
   && [ "$(cat "$c/repo/landed.txt")" = "someone's local file" ] && grep -q 'Fix:.*never force' "$c/runner.err"; then
  ok "a fast-forward git refuses (it would overwrite a local file) is reported, never forced; the file is untouched"
else
  bad "ff refused" "rc=$rc run=$(cat "$(newest "$c" run)" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# ---------------------------------------------------------------------------------
case_ '13b. the .run credits the run with its own commits only (DND-1507)'

# Another fleet lands on origin/main mid-run and the lane syncs down to it: the
# lane moved off BASE with no commit of its own.
c="$(new_case)"; echo moved >"$c/mode"
main_before="$(git -C "$c/repo" rev-parse main)"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -q 'outcome=ok exit=0' "$run" && grep -q '^own_landed=0$' "$run" \
   && grep -q '^ff=none' "$run" && ! grep -q "^ff=$(cat "$c/other-shas" 2>/dev/null)" "$run" \
   && grep -q '^main_moved=origin/main .* commits=1$' "$run" && ! grep -q '^landed=' "$run" \
   && [ "$(git -C "$c/repo" rev-parse main)" = "$main_before" ] && [ "$(lane_branches "$c")" = 0 ]; then
  ok "a lane synced to a newer origin/main with no own commit: own_landed=0, no ff, the motion is main_moved=, main untouched"
else
  bad "moved, no own commit" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# Another fleet lands, the lane syncs, then the run lands one commit of its own.
c="$(new_case)"; echo moved-land >"$c/mode"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
own="$(cat "$c/own-shas" 2>/dev/null)"
if [ "$rc" = 0 ] && [ -n "$own" ] && grep -q "^own_landed=1 $own\$" "$run" && grep -q "^ff=$own\$" "$run" \
   && grep -q '^main_moved=origin/main .* commits=2$' "$run" && [ "$(git -C "$c/repo" rev-parse main)" = "$own" ]; then
  ok "one own commit landed after another fleet's: own_landed names exactly it; ff is it; main_moved counts both"
else
  bad "moved then own landing" "rc=$rc own=$own run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# The run lands its commit, then another fleet lands and the lane syncs past
# it: the ff stops at the run's own commit, never the other fleet's.
c="$(new_case)"; echo land-moved >"$c/mode"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
own="$(cat "$c/own-shas" 2>/dev/null)"
if [ "$rc" = 0 ] && [ -n "$own" ] && grep -q "^own_landed=1 $own\$" "$run" && grep -q "^ff=$own\$" "$run" \
   && [ "$(git -C "$c/repo" rev-parse main)" = "$own" ] \
   && [ "$(git -C "$c/origin.git" rev-parse main)" = "$(cat "$c/other-shas")" ]; then
  ok "a lane synced past its own landed commit: the main checkout is fast-forwarded to the run's own commit only"
else
  bad "own landing then moved" "rc=$rc own=$own main=$(git -C "$c/repo" rev-parse main) run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# The run commits, another fleet lands, and `pull --rebase` replays the run's
# commit onto it: the replayed commit is the run's own, the other fleet's not.
c="$(new_case)"; echo rebase-land >"$c/mode"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
own="$(cat "$c/own-shas" 2>/dev/null)"
if [ "$rc" = 0 ] && [ -n "$own" ] && grep -q "^own_landed=1 $own\$" "$run" && grep -q "^ff=$own\$" "$run" \
   && grep -q '^main_moved=origin/main .* commits=2$' "$run"; then
  ok "an own commit replayed by pull --rebase onto another fleet's: own_landed names the replayed commit only"
else
  bad "rebased own landing" "rc=$rc own=$own run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# The run lands one commit, then makes a second it never pushes: the tick is
# STRANDED, and the main checkout still gets the run's landed commit.
c="$(new_case)"; echo land-strand >"$c/mode"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
own="$(cat "$c/own-shas" 2>/dev/null)"; unpushed="$(cat "$c/unpushed-shas" 2>/dev/null)"
if [ "$rc" = 72 ] && [ -n "$own" ] && grep -q "^own_landed=1 $own\$" "$run" \
   && grep -q "^ff=$own (the newest own landed commit; the run's newer own commit $unpushed is not on origin/main)" "$run" \
   && [ "$(git -C "$c/repo" rev-parse main)" = "$own" ]; then
  ok "an own landed commit under an unpushed own commit: stranded (72), own_landed names the landed one, ff reaches it"
else
  bad "landed then stranded" "rc=$rc own=$own run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# The lane's HEAD reflog is gone, so the run's own commits cannot be told from
# a sync: that is UNKNOWN and no ff, never "none" and never the lane tip.
c="$(new_case)"; echo noreflog-land >"$c/mode"
main_before="$(git -C "$c/repo" rev-parse main)"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -q '^own_landed=UNKNOWN' "$run" && grep -q '^ff=none (own commits UNKNOWN' "$run" \
   && [ "$(git -C "$c/repo" rev-parse main)" = "$main_before" ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "an unreadable lane reflog reads own_landed=UNKNOWN with a Fix:, and the main checkout is not moved"
else
  bad "no reflog" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# The reflog lost its first entry (expired or rewritten mid-run): it no longer
# starts at BASE, so it cannot prove what the run made. UNKNOWN, its own Fix:.
c="$(new_case)"; echo truncreflog-land >"$c/mode"
main_before="$(git -C "$c/repo" rev-parse main)"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -q '^own_landed=UNKNOWN (the lane.s HEAD reflog does not start at BASE' "$run" \
   && grep -q '^ff=none (own commits UNKNOWN' "$run" && [ "$(git -C "$c/repo" rev-parse main)" = "$main_before" ] \
   && grep -q 'Fix: the reflog was rewritten or expired' "$c/runner.err"; then
  ok "a lane reflog that does not start at BASE reads own_landed=UNKNOWN with its own Fix:; main is not moved"
else
  bad "truncated reflog" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
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
case_ '16. product repos: an improve repo other than custom (DND-1540)'

# Fakes for the forge the product lane talks to; nothing real is pushed or read.
mkdir -p "$TMP/pfake"
cat >"$TMP/pfake/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$PFAKE_LOG"
if [ "$1 $2" = "pr view" ]; then
  jq -n --arg h "$(cat "$PFAKE_HEAD" 2>/dev/null)" '{state: "OPEN", headRefOid: $h,
    statusCheckRollup: [{__typename: "CheckRun", status: "IN_PROGRESS", conclusion: null}], mergeCommit: null}'; exit 0
fi
echo '[]'
EOF
cat >"$TMP/pfake/gh-athena" <<'EOF'
#!/usr/bin/env bash
printf 'gh-athena %s\n' "$*" >>"$PFAKE_LOG"
if [ "$1" = git ]; then shift; exec git "$@"; fi
if [ "$1 $2" = "pr create" ]; then echo "https://github.com/example/gen_saas/pull/41"; exit 0; fi
exit 64
EOF
chmod +x "$TMP/pfake/gh" "$TMP/pfake/gh-athena"

# product_case — a case whose override lists custom (improve) and gen_saas
# (improve), with gen_saas a clone of its own temp origin.
product_case() {
  local c="$1" s="$1/gen-seed"
  rm -rf "$c/checkouts/gen_saas"
  git "${G[@]}" init -q "$s"; echo one >"$s/a.txt"; git -C "$s" add -A; git "${G[@]}" -C "$s" commit -q -m seed
  git clone -q --bare "$s" "$c/gen-origin.git"; git clone -q "$c/gen-origin.git" "$c/checkouts/gen_saas"
  override "$c" "{\"repos\":[{\"name\":\"custom\",\"path\":\"$c/checkouts/custom\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"$c/checkouts/gen_saas\",\"mode\":\"improve\"},{\"name\":\"walt_ui\",\"path\":\"$c/checkouts/walt_ui\",\"mode\":\"watch\"}],\"window\":20,\"improvement_epic\":\"epic-fixture\"}"
  # The skill opts into the product lane by naming its command (DND-1542).
  printf 'Product repos: leadtime-product cut, then leadtime-product pr.\n' >>"$c/repo/ai/skills/athena:lead-time-improve/SKILL.md"
}
glanes() { printf '%s/checkouts/gen_saas/.git/leadtime-lanes' "$1"; }
prun() { # <case> [VAR=val ...] — run_runner with the product fakes and the override
  local c="$1"; shift
  run_runner "$c" ATHENA_LEADTIME_CONFIG="$c/override.json" LEADTIME_GH="$TMP/pfake/gh" LEADTIME_GH_ATHENA="$TMP/pfake/gh-athena" \
    LEADTIME_PRODUCT_FORGE=github LEADTIME_PRODUCT_BOOTSTRAP= PFAKE_LOG="$c/pfake.log" PFAKE_HEAD="$c/pfake.head" "$@"
}

# No improve repo other than custom: behaviour identical to today. The whole
# suite above runs unchanged; here the product machinery is shown inert.
c="$(new_case)"
rc="$(run_runner "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -qx 'product_prs=0 landed=none' "$run" && ! grep -q '^product' <(grep -v '^product_prs=' "$run") \
   && ! grep -q 'leadtime-product' "$c/claude-args" && [ -z "$(find "$(sd "$c")/runs" -name '*.product.json')" ] \
   && [ ! -e "$(sd "$c")/product-prs.jsonl" ] && [ ! -s "$c/claude-product-manifest" ] \
   && [ ! -e "$c/checkouts/custom/.git/leadtime-lanes" ]; then
  ok "no improve repo other than custom: no manifest, no product lane, no product text in the brief; .run says product_prs=0 landed=none"
else
  bad "no product repo" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi
c="$(new_case)"
rc="$(run_runner "$c" -- --dry-run)"
if [ "$rc" = 0 ] && ! grep -q 'leadtime-product' "$c/runner.out" && ! grep -q 'product' "$c/runner.out"; then
  ok "--dry-run with no product repo: the brief has no product text"
else
  bad "dry-run no product" "rc=$rc out=$(cat "$c/runner.out")"
fi

# An improve repo R listed while the skill has no product-lane procedure yet
# (a skill without DND-1542): the lane is OFF. No lane, no manifest, no product
# text in the brief; .run names the repo and why.
c="$(new_case)"; product_case "$c"
printf -- '---\nname: athena:lead-time-improve\n---\n' >"$c/repo/ai/skills/athena:lead-time-improve/SKILL.md"
rc="$(prun "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -q '^product_lane=OFF repos=gen_saas: .*no product-lane procedure (DND-1542)' "$run" \
   && grep -qx 'product_prs=0 landed=none' "$run" && ! grep -q 'leadtime-product' "$c/claude-args" \
   && [ -z "$(find "$(sd "$c")/runs" -name '*.product.json')" ] && [ ! -e "$(glanes "$c")" ] && [ ! -s "$c/pfake.log" ]; then
  ok "an improve repo R with no product procedure in the skill: lane OFF, no product text in the brief, .run says product_lane=OFF"
else
  bad "product lane off" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# The real skill carries the product-lane procedure (DND-1542), so the runner
# turns the lane ON. A rewrap that splits the opt-in text across lines would
# turn it OFF with no other signal; this is that signal.
real_skill="${REPO_ROOT}/ai/skills/athena:lead-time-improve/SKILL.md"
if grep -qF 'leadtime-product pr' -- "${real_skill}"; then
  ok "the landed athena:lead-time-improve skill names 'leadtime-product pr' on one line: the product lane is ON"
else
  bad "skill opt-in" "${real_skill} lacks the one-line text the runner greps for; the product lane would be OFF"
fi

# One improve repo R: a lane reserved in R's common dir, held through the
# session, cut on demand from R's origin/main, removed after; a dead run's
# lane in R reaped by its lock.
c="$(new_case)"; product_case "$c"; echo product-cut >"$c/mode"
mkdir -p "$(glanes "$c")"
git -C "$c/checkouts/gen_saas" worktree add -q -b leadtime/gen_saas-tail-old "$(glanes "$c")/run-20260930T113000Z-7" origin/main
printf 'branch=leadtime/gen_saas-tail-old\n' >"$(glanes "$c")/run-20260930T113000Z-7.meta"
: >"$(glanes "$c")/run-20260930T113000Z-7.lock"
rc="$(prun "$c")"
run="$(newest "$c" run)"
gbase="$(git -C "$c/checkouts/gen_saas" rev-parse refs/remotes/origin/main)"
if [ "$rc" = 0 ] && grep -q "^lane=$(glanes "$c")/run-" "$c/cut.out" && grep -qx 'branch=leadtime/gen_saas-verify-20261001T123000Z' "$c/cut.out" \
   && grep -q "^base=$gbase" "$c/cut.out" && [ "$(cat "$c/product-lock")" = held ] \
   && [ -z "$(find "$(glanes "$c")" -mindepth 1 -maxdepth 1 -name 'run-*')" ] \
   && ! git -C "$c/checkouts/gen_saas" show-ref --quiet refs/heads/leadtime/gen_saas-tail-old \
   && grep -q 'product_reaped: repo=gen_saas lane=run-20260930T113000Z-7' "$run" \
   && grep -q '^product_lane: repo=gen_saas removed' "$run" && grep -qx 'product_prs=0 landed=none' "$run" \
   && grep -q 'leadtime-product cut --repo' "$c/claude-args" && grep -q 'gen_saas (improve' "$c/claude-args"; then
  ok "one improve repo R: lane cut in R's common dir from R's origin/main, its lock held through the session, removed after; a dead lane reaped by its lock"
else
  bad "product lane" "rc=$rc run=$(cat "$run" 2>/dev/null) cut=$(cat "$c/cut.out" 2>/dev/null) lock=$(cat "$c/product-lock" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

c="$(new_case)"; product_case "$c"; echo product-pr >"$c/mode"
rc="$(prun "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -q 'outcome=ok exit=0' "$run" && grep -q '^product_lane: repo=gen_saas awaiting landing on PR #41' "$run" \
   && [ "$(jq -r 'select(.event=="opened") | .pr' "$(sd "$c")/product-prs.jsonl")" = 41 ] \
   && [ ! -e "$(sd "$c")/consecutive-failures" ] && grep -q 'push -u origin HEAD' "$c/pfake.log"; then
  ok "a pushed commit on an open PR: not STRANDED, exit 0, recorded in product-prs.jsonl, not counted"
else
  bad "product pr" "rc=$rc run=$(cat "$run" 2>/dev/null) pr=$(cat "$c/pr.out" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

c="$(new_case)"; product_case "$c"; echo product-strand >"$c/mode"
rc="$(prun "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 72 ] && grep -q 'outcome=stranded exit=72' "$run" && grep -q '^product_lane: repo=gen_saas STRANDED' "$run" \
   && git -C "$c/checkouts/gen_saas" show-ref --quiet refs/heads/leadtime/gen_saas-verify-20261001T123000Z \
   && [ "$(fails "$c")" = 1 ] && grep -q 'Fix:' "$c/runner.err"; then
  ok "an unpushed commit in a product lane: STRANDED, exit 72, branch kept, counted"
else
  bad "product strand" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# The sweep runs before the session and its result reaches the brief and .run.
c="$(new_case)"; product_case "$c"
mkdir -p "$(sd "$c")"
printf '%s\n' "$(printf 'a%.0s' {1..40})" >"$c/pfake.head"
printf '{"event":"opened","at":"2026-10-01T11:00:00Z","repo":"gen_saas","pr":40,"url":"https://github.com/example/gen_saas/pull/40","phase":"verify","branch":"leadtime/gen_saas-verify-x","head":"%s","run_id":"run-20261001T113000Z-1"}\n' \
  "$(printf 'a%.0s' {1..40})" >"$(sd "$c")/product-prs.jsonl"
rc="$(prun "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && grep -qx 'product_prs=1 landed=none' "$run" && grep -q '^product: repo=gen_saas pr=#40 open: CI pending' "$run" \
   && grep -q 'product_prs=1 landed=none' "$c/claude-args" && grep -q '^gh pr view 40' "$c/pfake.log"; then
  ok "the sweep checks every open improver PR before the session; .run and the brief carry product_prs=<open n>"
else
  bad "product sweep" "rc=$rc run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# A sweep that fails with NO stderr: the session still runs, the failure is in
# .run, and no product-lane command inherits a runner lock descriptor (the run
# lock, the custom lane's, a product lane's), so a child that outlives the
# tick cannot pin one.
c="$(new_case)"; product_case "$c"
cat >"$c/repo/ai/bin/leadtime-product" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/../../.." && pwd)"
for f in /proc/$$/fd/*; do readlink "$f"; done | grep -F "$d/" | grep '\.lock$' >>"$d/inherited-locks" || true
[ "$1" = sweep ] && exit 9
exit 0
EOF
chmod +x "$c/repo/ai/bin/leadtime-product"
rc="$(prun "$c")"
run="$(newest "$c" run)"
if [ "$rc" = 0 ] && [ "$(invoked "$c")" = 1 ] && grep -q 'outcome=ok exit=0' "$run" \
   && grep -q '^product_prs=UNKNOWN landed=UNKNOWN (sweep exit 9)' "$run" && grep -q '^product_sweep=FAILED exit=9' "$run" \
   && grep -q 'the sweep failed (exit 9)' "$c/claude-args" && grep -q 'Fix:' "$c/runner.err" \
   && [ ! -s "$c/inherited-locks" ]; then
  ok "a sweep failing with empty stderr: the session still runs; .run says product_prs=UNKNOWN; no product command inherits a lock fd"
else
  bad "silent sweep failure" "rc=$rc inherited=$(cat "$c/inherited-locks" 2>/dev/null) run=$(cat "$run" 2>/dev/null) err=$(cat "$c/runner.err")"
fi

# A stopped product line alerts ONCE per episode on harness-alerts, re: its
# marker; the next tick does not repeat it; the owner's rm ends the episode.
c="$(new_case)"; product_case "$c"
mkdir -p "$(sd "$c")"
printf 'deploy failed on gen_saas#40 (merge abc): a revert is owed\n' >"$(sd "$c")/product-line-stopped.gen_saas"
rc1="$(prun "$c")"; run1="$(newest "$c" run)"
n1="$(sends "$c" leadtime-product-line-stopped)"; cp "$c/claude-args" "$c/claude-args.1"
rc2="$(prun "$c")"
n2="$(sends "$c" leadtime-product-line-stopped)"
rm -f -- "$(sd "$c")/product-line-stopped.gen_saas"
rc3="$(prun "$c")"
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 0 ] && [ "$n1" = 1 ] && [ "$n2" = 1 ] \
   && grep -q -- "--re $(sd "$c")/product-line-stopped.gen_saas" "$c/send.log" \
   && grep -q '^product_line_alert=gen_saas sent msg-1.md' "$run1" \
   && grep -q 'product_line=STOPPED gen_saas' "$c/claude-args.1" \
   && [ ! -e "$(sd "$c")/product-line-stopped-alerted.gen_saas" ]; then
  ok "a stopped product line: one harness-alert re: its marker, no repeat on the next tick, the episode ends on rm"
else
  bad "stopped-line alert" "rc=$rc1/$rc2/$rc3 n=$n1/$n2 send=$(cat "$c/send.log") run=$(cat "$run1" 2>/dev/null) err=$(cat "$c/runner.err")"
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
