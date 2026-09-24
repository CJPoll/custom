#!/usr/bin/env bash
# self-test for ai/bin/test-slot (DND-485) — discovered and run by harness-gate.
#
# Every case runs in a throwaway pool (ATHENA_TEST_SLOT_DIR + ATHENA_TEST_SLOTS
# seams under a mktemp dir), never the real machine pool. No sleep stands in
# for a timing assumption: a held command blocks on a FIFO the suite writes to,
# bounded by `read -t`; every "wait until X" is a bounded condition poll; every
# background run is bounded by timeout(1). Case numbers are the QA Plan's rows.
set -u -o pipefail

here="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$here/../../bin" && pwd)/test-slot"

if [ ! -x "$BIN" ]; then
  echo "test-slot self-test: FAIL — $BIN missing or not executable" >&2
  echo "Fix: create ai/bin/test-slot and chmod +x it." >&2
  exit 1
fi
for tool in jq flock timeout mkfifo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "test-slot self-test: FAIL — required tool '$tool' not on PATH" >&2
    echo "Fix: install $tool (util-linux / coreutils / jq) and re-run." >&2
    exit 1
  fi
done

# A suite launched from inside a slot (DND-486 wraps the gate) must not carry
# that slot into its fixtures: every case here decides re-entrancy itself.
unset ATHENA_TEST_SLOT_HELD ATHENA_TEST_SLOT_DIR ATHENA_TEST_SLOTS ATHENA_TEST_SLOT_HEARTBEAT

W="$(mktemp -d "${TMPDIR:-/tmp}/test-slot-selftest.XXXXXX")"
BG_PIDS=()

cleanup() {
  local f p
  # Held commands are single bash processes (no children); kill each by the
  # pid it recorded, then every bounded background wrapper we started.
  for f in "$W"/*.pid; do
    [ -e "$f" ] || continue
    p="$(cat "$f" 2>/dev/null)"
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  for p in "${BG_PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL [%s] %s\n' "$1" "$2" >&2; }
check() { local name=$1; shift; if "$@"; then ok; else bad "$name" "$*"; fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
absent() { [ ! -e "$1" ]; }
present() { [ -e "$1" ]; }
eq() { [ "$1" = "$2" ]; }

# await_file PATH [SECONDS] — bounded poll for a file to appear.
await_file() {
  local i n=$(( ${2:-20} * 20 ))
  for ((i = 0; i < n; i++)); do [ -e "$1" ] && return 0; sleep 0.05; done
  return 1
}
# await_grep FILE STRING [SECONDS] — bounded poll for STRING in FILE.
await_grep() {
  local i n=$(( ${3:-20} * 20 ))
  for ((i = 0; i < n; i++)); do has "$1" "$2" && return 0; sleep 0.05; done
  return 1
}

newpool() { # newpool NAME N — fresh (not yet created) pool for one case
  POOL="$W/pools/$1"
  mkdir -p "$W/pools"
  export ATHENA_TEST_SLOT_DIR="$POOL" ATHENA_TEST_SLOTS="$2"
}

# bg NAME ARGS... — run test-slot ARGS in the background, bounded by
# timeout 60; stdout/stderr land in $W/NAME.out / .err; pid in $W/NAME.bg.
# BG_PRE (array) is put before test-slot, e.g. to launch it with INT/QUIT at
# default (a background job of this non-job-control suite starts them ignored).
BG_PRE=()
bg() {
  local name=$1; shift
  timeout 60 "${BG_PRE[@]}" "$BIN" "$@" >"$W/$name.out" 2>"$W/$name.err" &
  echo $! >"$W/$name.bg"
  BG_PIDS+=("$!")
}
# reap NAME — wait for a bg run (bounded by its timeout); its exit code -> $RC.
# Never call it in $(...): a subshell cannot wait for the suite's children.
RC=""
reap() { wait "$(cat "$W/$1.bg")"; RC=$?; }

# The held command: records its own pid and its parent (the wrapper) pid,
# marks itself started, then blocks on its FIFO until released (read -t
# bounds it, so an unreleased holder can never outlive the suite by long).
HOLD_CMD='echo $$ > "$1.pid"; echo $PPID > "$1.wrapper"; : > "$1.started"; exec 3<>"$1.fifo"; read -t 30 -u 3 _x; : > "$1.done"'

# hold NAME LABEL [EXTRA test-slot ARGS...] — start a holder and wait until
# its command is running (so its slot is certainly held).
hold() {
  local name=$1 label=$2; shift 2
  mkfifo "$W/$name.fifo"
  bg "$name" --label "$label" "$@" -- bash -c "$HOLD_CMD" _ "$W/$name"
  await_file "$W/$name.started" 20 || bad "hold:$name" "holder never started: $(cat "$W/$name.err" 2>/dev/null)"
}
release() { timeout 5 bash -c 'printf "go\n" > "$1"' _ "$W/$1.fifo"; }

# conc.sh DIR TARGET MAXPOLLS — records concurrency: bumps DIR/cur under a
# lock, tracks DIR/max, holds until cur >= TARGET (bounded poll), then leaves.
cat >"$W/conc.sh" <<'EOF'
#!/usr/bin/env bash
d=$1; target=$2; polls=$3
exec 8>>"$d/lock"
flock 8; n=$(( $(cat "$d/cur" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/cur"
m=$(cat "$d/max" 2>/dev/null || echo 0); [ "$n" -gt "$m" ] && echo "$n" >"$d/max"; flock -u 8
for ((i = 0; i < polls; i++)); do [ "$(cat "$d/cur")" -ge "$target" ] && break; sleep 0.05; done
flock 8; echo $(( $(cat "$d/cur") - 1 )) >"$d/cur"; echo x >>"$d/ran"; flock -u 8
EOF
chmod +x "$W/conc.sh"

events() { cat "$POOL/events.jsonl" 2>/dev/null; }
event_count() { # event_count EVENT [LABEL]
  events | jq -s --arg e "$1" --arg l "${2:-}" '[.[] | select(.event == $e and ($l == "" or .label == $l))] | length'
}

# ---------------------------------------------------------------- pure helpers
(
  # shellcheck source=/dev/null
  source "$BIN"
  f=0
  t() { if "$@"; then :; else echo "FAIL [helper] $*" >&2; f=$((f + 1)); fi; }
  t is_heavy_argv bash bin/prep-commit.sh
  t is_heavy_argv /home/x/bin/prep-commit.sh
  t is_heavy_argv mix test
  t is_heavy_argv mix test --max-cases 4
  t is_heavy_argv /usr/bin/elixir /usr/bin/mix test
  t eval '! is_heavy_argv mix test test/foo_test.exs'
  t eval '! is_heavy_argv mix test apps/athena'
  t eval '! is_heavy_argv mix compile'
  t eval '! is_heavy_argv vim bin/prep-commit.sh'
  t eval '! is_heavy_argv grep mix test'
  t eval '! is_heavy_argv bash /x/ai/bin/test-slot -- mix test'
  t eval '! is_heavy_argv bash /x/ai/bin/test-slot -- bin/prep-commit.sh'
  t eq "$(parse_n 3)" 3
  t eval '! parse_n 0 >/dev/null'
  t eval '! parse_n x >/dev/null'
  t eval '! parse_n "" >/dev/null'
  t eval '! parse_n 03 >/dev/null'
  t eq "$(outcome_line timeout)" timeout
  t eq "$(outcome_line ran 7)" "ran exit=7"
  t eq "$(json_str "a\"b\\c
d	e" | jq -r .)" "a\"b\\c
d	e"
  t eq "$(pick_label /home/x/repo /usr/bin/mix)" "repo mix"
  t eq "$(unslotted_state 'pid:[1]' 'pid:[1]' 0)" slotted
  t eq "$(unslotted_state 'pid:[1]' 'pid:[1]' 1)" unslotted
  t eq "$(unslotted_state 'pid:[1]' 'pid:[1]' 2)" unknown
  t eq "$(unslotted_state 'pid:[1]' 'pid:[2]' 1)" container
  t eq "$(unslotted_state 'pid:[1]' 'pid:[2]' 0)" container
  t eq "$(unslotted_state 'pid:[1]' '' 1)" unslotted
  t eq "$(default_signals 0000000000000000)" "INT,QUIT"
  t eq "$(default_signals 0000000000000006)" ""
  t eq "$(default_signals 0000000000000002)" "QUIT"
  t eq "$(default_signals 0000000000000004)" "INT"
  t eq "$(default_signals 0000000000001002)" "QUIT"
  t eq "$(default_signals '')" "INT,QUIT"
  exit "$f"
)
if [ $? -eq 0 ]; then ok; else bad helpers "pure helper cases failed (see above)"; fi

# ----------------------------------------------------------------- parse/usage
# 1: --help → stdout usage, exit 0, pool NOT created (default or seam path).
out="$(XDG_STATE_HOME="$W/xdg1" ATHENA_TEST_SLOT_DIR="$W/seam1" "$BIN" --help 2>"$W/1.err")"; rc=$?
check 1-rc eq "$rc" 0
check 1-usage eval '[[ "$out" == *Usage* ]]'
check 1-no-default-pool absent "$W/xdg1"
check 1-no-seam-pool absent "$W/seam1"
check 1-quiet eval '[ ! -s "$W/1.err" ]'

# 2: no `--` / no CMD → exit 2 + Fix.
newpool p2 1
"$BIN" true 2>"$W/2a.err"; check 2a-rc eq "$?" 2; check 2a-fix has "$W/2a.err" "Fix:"
"$BIN" -- 2>"$W/2b.err"; check 2b-rc eq "$?" 2; check 2b-fix has "$W/2b.err" "Fix:"
"$BIN" --bogus -- true 2>"$W/2c.err"; check 2c-rc eq "$?" 2; check 2c-fix has "$W/2c.err" "Fix:"

# 3: --wait-timeout abc → exit 2 + Fix.
"$BIN" --wait-timeout abc -- true 2>"$W/3.err"; check 3-rc eq "$?" 2; check 3-fix has "$W/3.err" "Fix:"

# 4: seam dir + invalid N (0, x) → exit 2, Fix names the variable, never falls back.
for bad_n in 0 x; do
  newpool "p4$bad_n" "$bad_n"
  "$BIN" -- touch "$W/4$bad_n.ran" 2>"$W/4$bad_n.err"
  check "4-$bad_n-rc" eq "$?" 2
  check "4-$bad_n-fix" has "$W/4$bad_n.err" "Fix:"
  check "4-$bad_n-names-var" has "$W/4$bad_n.err" "ATHENA_TEST_SLOTS"
  check "4-$bad_n-not-run" absent "$W/4$bad_n.ran"
done

# 5: ATHENA_TEST_SLOTS without the dir seam (or with the dir seam = the
# default path) is ignored: N shown is the script constant.
out="$(env -u ATHENA_TEST_SLOT_DIR ATHENA_TEST_SLOTS=9 XDG_STATE_HOME="$W/xdg5" "$BIN" --status 2>&1)"
check 5-const eval '[[ "$out" == *"N=3 (provisional, unmeasured)"* && "$out" != *"N=9"* ]]'
out="$(ATHENA_TEST_SLOT_DIR="$W/xdg5b/athena/test-slots" ATHENA_TEST_SLOTS=9 XDG_STATE_HOME="$W/xdg5b" "$BIN" --status 2>&1)"
check 5-default-path-const eval '[[ "$out" == *"N=3 (provisional, unmeasured)"* && "$out" != *"N=9"* ]]'
check 5-status-created-nothing absent "$W/xdg5/athena"

# 6: an existing pool dir with mode 0755 is refused with a chmod Fix.
newpool p6 1
mkdir -m 0755 "$POOL"
"$BIN" -- touch "$W/6.ran" 2>"$W/6.err"; rc=$?
check 6-rc eq "$rc" 2
check 6-fix has "$W/6.err" "Fix:"
check 6-chmod has "$W/6.err" "chmod 700"
check 6-not-run absent "$W/6.ran"

# ------------------------------------------------------- acquire/run/release
# 7: CMD's exit code passes through; events + outcome file record it.
newpool p7 1
"$BIN" --label L7 --outcome-file "$W/7.outcome" -- sh -c 'exit 7' 2>"$W/7.err"; rc=$?
check 7-rc eq "$rc" 7
check 7-acquired eq "$(event_count acquired L7)" 1
check 7-released eq "$(events | jq -s '[.[] | select(.event=="released" and .label=="L7" and .exit==7)] | length')" 1
check 7-outcome eq "$(cat "$W/7.outcome" 2>/dev/null)" "ran exit=7"
check 7-pool-mode eq "$(stat -c %a "$POOL" 2>/dev/null)" 700

# 8: CMD stdout passes through byte-identical.
newpool p8 1
"$BIN" -- printf 'a\0b\n\tc' >"$W/8.wrapped" 2>/dev/null
printf 'a\0b\n\tc' >"$W/8.direct"
check 8-bytes cmp -s "$W/8.wrapped" "$W/8.direct"
check 8-rc eval '"$BIN" -- true 2>/dev/null'

# 9: N=2, one holder → a second run starts at once, in slot 2.
newpool p9 2
hold A9 A9
"$BIN" --label B9 -- true 2>"$W/9.err"; rc=$?
check 9-rc eq "$rc" 0
check 9-no-wait lacks "$W/9.err" "WAITING"
check 9-holder2 present "$POOL/slot-2.holder"
release A9; reap A9; check 9-A-rc eq "$RC" 0

# 10/11: N=1, holder A → B prints WAITING with pool, N, count, A's label, and
# does not run; releasing A lets B run, with waited_s > 0.
newpool p10 1
hold A10 holder-A10
bg B10 --label B10 -- sh -c ': > "$1"' _ "$W/B10.ran"
check 10-waiting await_grep "$W/B10.err" "WAITING" 20
check 10-pool has "$W/B10.err" "$POOL"
check 10-N has "$W/B10.err" "N=1"
check 10-held has "$W/B10.err" "1 held"
check 10-label has "$W/B10.err" "holder-A10"
check 10-not-run absent "$W/B10.ran"
release A10
reap B10; check 11-B-rc eq "$RC" 0
check 11-B-ran present "$W/B10.ran"
check 11-waited eq "$(events | jq -s '[.[] | select(.event=="acquired" and .label=="B10" and .waited_s > 0)] | length')" 1
reap A10; check 11-A-rc eq "$RC" 0

# 12/18: N=1, holder A, B --wait-timeout 3 → exit 75, TIMEOUT + did NOT run +
# Fix + A's label, CMD never ran, outcome `timeout`; heartbeats (seam 1 s).
newpool p12 1
hold A12 holder-A12
ATHENA_TEST_SLOT_HEARTBEAT=1 bg B12 --label B12 --wait-timeout 3 --outcome-file "$W/12.outcome" -- sh -c ': > "$1"' _ "$W/B12.ran"
reap B12; check 12-rc eq "$RC" 75
check 12-timeout has "$W/B12.err" "TIMEOUT"
check 12-not-run-msg has "$W/B12.err" "did NOT run"
check 12-fix has "$W/B12.err" "Fix:"
check 12-label has "$W/B12.err" "holder-A12"
check 12-not-run absent "$W/B12.ran"
check 12-outcome eq "$(cat "$W/12.outcome" 2>/dev/null)" "timeout"
check 12-event eq "$(event_count timeout B12)" 1
check 18-heartbeats eval '[ "$(grep -c "still waiting" "$W/B12.err")" -ge 2 ]'
release A12; reap A12; check 12-A-rc eq "$RC" 0

# 13: a CMD that itself exits 75 is distinguishable through the outcome file.
newpool p13 1
"$BIN" --outcome-file "$W/13.outcome" -- sh -c 'exit 75' 2>/dev/null; rc=$?
check 13-rc eq "$rc" 75
check 13-outcome eq "$(cat "$W/13.outcome" 2>/dev/null)" "ran exit=75"

# 13b: a stale outcome file is removed at start, so a refused run leaves none.
echo "ran exit=0" >"$W/13b.outcome"
"$BIN" --outcome-file "$W/13b.outcome" --wait-timeout nope -- true 2>/dev/null
check 13b-stale-removed absent "$W/13b.outcome"

# 14: SIGKILL the holder's WRAPPER only → the slot stays held (CMD inherited
# the lock fd); B waits; releasing the CMD frees it → liveness is the flock.
newpool p14 1
hold A14 holder-A14
wrapper="$(cat "$W/A14.wrapper")"
kill -9 "$wrapper"
reap A14 2>/dev/null; check 14-wrapper-dead eval '[ "$RC" -ne 0 ]'
bg B14 --label B14 -- sh -c ': > "$1"' _ "$W/B14.ran"
check 14-waits await_grep "$W/B14.err" "WAITING" 20
check 14-not-run absent "$W/B14.ran"
release A14
reap B14; check 14-B-rc eq "$RC" 0
check 14-B-ran present "$W/B14.ran"

# 15: a stale holder file with a live pid but NO lock → acquired at once.
newpool p15 1
mkdir -m 0700 "$POOL"
printf '{"label":"STALE15","cwd":"/","pid":%s,"started_at":"2026-01-01T00:00:00Z","exclusive":false}\n' "$$" >"$POOL/slot-1.holder"
timeout 10 "$BIN" -- true 2>"$W/15.err"; rc=$?
check 15-rc eq "$rc" 0
check 15-no-wait lacks "$W/15.err" "WAITING"

# 16: N=1, waiters B and C → never 2 concurrent; both eventually run.
newpool p16 1
mkdir -p "$W/c16"
hold A16 holder-A16
bg B16 --label B16 -- "$W/conc.sh" "$W/c16" 2 30
bg C16 --label C16 -- "$W/conc.sh" "$W/c16" 2 30
await_grep "$W/B16.err" "WAITING" 20
await_grep "$W/C16.err" "WAITING" 20
release A16
reap B16; check 16-B-rc eq "$RC" 0
reap C16; check 16-C-rc eq "$RC" 0
check 16-max1 eq "$(cat "$W/c16/max" 2>/dev/null)" 1
check 16-both-ran eq "$(wc -l <"$W/c16/ran" 2>/dev/null)" 2
reap A16

# 17: N=3, 6 concurrent → max observed concurrency is exactly 3; all exit 0.
newpool p17 3
mkdir -p "$W/c17"
for k in 1 2 3 4 5 6; do bg "R17$k" --label "R17$k" -- "$W/conc.sh" "$W/c17" 3 200; done
all0=1
for k in 1 2 3 4 5 6; do reap "R17$k"; [ "$RC" = 0 ] || all0=0; done
check 17-all-exit0 eq "$all0" 1
check 17-max3 eq "$(cat "$W/c17/max" 2>/dev/null)" 3
check 17-all-ran eq "$(wc -l <"$W/c17/ran" 2>/dev/null)" 6

# ---------------------------------------------------------------- re-entrancy
# 19: nested test-slot at N=1 runs directly (no self-deadlock).
newpool p19 1
timeout 30 "$BIN" --label outer19 -- "$BIN" --label inner19 -- true 2>"$W/19.err"; rc=$?
check 19-rc eq "$rc" 0
check 19-reentrant eq "$(event_count reentrant inner19)" 1

# 20: ATHENA_TEST_SLOT_HELD names this pool's slot 1 but it is free → WARN
# stale, then a normal acquisition.
newpool p20 1
mkdir -m 0700 "$POOL"
ATHENA_TEST_SLOT_HELD="$POOL:1" timeout 10 "$BIN" --label L20 -- true 2>"$W/20.err"; rc=$?
check 20-rc eq "$rc" 0
check 20-warn has "$W/20.err" "WARN stale"
check 20-acquired eq "$(event_count acquired L20)" 1
check 20-not-reentrant eq "$(event_count reentrant L20)" 0

# 21: ATHENA_TEST_SLOT_HELD names a DIFFERENT pool whose slot 1 IS held →
# not re-entrant here; acquires in this pool.
newpool p21other 1
other="$POOL"
hold A21 holder-A21
newpool p21 1
ATHENA_TEST_SLOT_HELD="$other:1" timeout 10 "$BIN" --label L21 -- true 2>"$W/21.err"; rc=$?
check 21-rc eq "$rc" 0
check 21-acquired eq "$(event_count acquired L21)" 1
check 21-not-reentrant eq "$(event_count reentrant L21)" 0
release A21; reap A21

# ---------------------------------------------------------------- --exclusive
# 22: N=3, one holder → --exclusive waits, holds the free slots as EXCLUSIVE;
# a normal run then WAITs and names EXCLUSIVE holders; after A leaves, X holds
# all 3; after X leaves, the normal run runs.
newpool p22 3
hold A22 holder-A22
mkfifo "$W/X22.fifo"
bg X22 --label X22 --exclusive -- bash -c "$HOLD_CMD" _ "$W/X22"
check 22-X-waits await_grep "$W/X22.err" "WAITING" 20
check 22-X-not-run absent "$W/X22.started"
bg D22 --label D22 -- sh -c ': > "$1"' _ "$W/D22.ran"
check 22-D-waits await_grep "$W/D22.err" "WAITING" 20
check 22-D-sees-exclusive has "$W/D22.err" "EXCLUSIVE"
release A22
check 22-X-runs await_file "$W/X22.started" 20
st="$("$BIN" --status --json 2>/dev/null)"
check 22-all-3-exclusive eq "$(jq '[.holders[] | select(.exclusive == true and .label == "X22")] | length' <<<"$st")" 3
check 22-D-not-run absent "$W/D22.ran"
release X22
reap X22; check 22-X-rc eq "$RC" 0
reap D22; check 22-D-rc eq "$RC" 0
check 22-D-ran present "$W/D22.ran"
reap A22

# -------------------------------------------------------------------- --status
# 23: pool absent → `pool not initialised at <dir>`, not `held=0`; nothing created.
newpool p23 1
out="$("$BIN" --status 2>&1)"
check 23-not-init eval '[[ "$out" == *"pool not initialised at $POOL"* ]]'
check 23-no-held0 eval '[[ "$out" != *"held=0"* ]]'
check 23-created-nothing absent "$POOL"
check 23-json eq "$("$BIN" --status --json 2>/dev/null | jq -r .initialised)" false

# 24: N=2, two holders, one waiter → --status --json counts and labels.
newpool p24 2
hold A24 holder-A24
hold B24 holder-B24
bg C24 --label waiter-C24 -- true
await_grep "$W/C24.err" "WAITING" 20
st="$("$BIN" --status --json 2>/dev/null)"
check 24-held eq "$(jq .held <<<"$st")" 2
check 24-waiting eq "$(jq .waiting <<<"$st")" 1
check 24-label eq "$(jq '[.holders[].label] | index("holder-A24") != null' <<<"$st")" true
check 24-waiter-label eq "$(jq -r '.waiters[0].label' <<<"$st")" waiter-C24
check 24-provisional eq "$(jq .provisional <<<"$st")" true
check 24-N eq "$(jq .n <<<"$st")" 2
txt="$("$BIN" --status 2>/dev/null)"
check 24-text-line eval '[[ "$txt" == *"held=2 waiting=1"* && "$txt" == *load1=* && "$txt" == *nproc=* ]]'
release A24; release B24
reap C24; check 24-C-rc eq "$RC" 0
reap A24; reap B24

# 25: an unwrapped prep-commit.sh shows as UNSLOTTED; the same script run
# under test-slot does not.
newpool p25 2
mkdir -p "$W/fake25"
cat >"$W/fake25/prep-commit.sh" <<'EOF'
#!/usr/bin/env bash
echo $$ > "$1.pid"; : > "$1.started"; exec 3<>"$1.fifo"; read -t 30 -u 3 _x
EOF
chmod +x "$W/fake25/prep-commit.sh"
mkfifo "$W/U25.fifo" "$W/S25.fifo"
(cd "$W/fake25" && timeout 60 ./prep-commit.sh "$W/U25" >/dev/null 2>&1) &
BG_PIDS+=("$!"); u25_bg=$!
bg S25 --label S25 -- "$W/fake25/prep-commit.sh" "$W/S25"
await_file "$W/U25.started" 20; await_file "$W/S25.started" 20
st="$("$BIN" --status 2>/dev/null)"
u_pid="$(cat "$W/U25.pid")"; s_pid="$(cat "$W/S25.pid")"
check 25-unslotted-listed eval '[[ "$st" == *"UNSLOTTED: $u_pid "* ]]'
check 25-unslotted-cwd eval '[[ "$st" == *"UNSLOTTED: $u_pid $W/fake25 "* ]]'
check 25-slotted-not-listed eval '[[ "$st" != *"UNSLOTTED: $s_pid "* ]]'
release U25; release S25
wait "$u25_bg" 2>/dev/null
reap S25

# ------------------------------------------------------------------ events log
# 26: events.jsonl over 1 MiB rotates to events.jsonl.1; the new file holds
# this run's lines; every line of both parses.
newpool p26 1
mkdir -m 0700 "$POOL"
awk 'BEGIN { for (i = 0; i < 40000; i++) printf "{\"event\":\"filler\",\"i\":%d}\n", i }' >"$POOL/events.jsonl"
"$BIN" --label L26 -- true 2>/dev/null
check 26-rotated present "$POOL/events.jsonl.1"
check 26-new-has-run eq "$(event_count acquired L26)" 1
check 26-new-small eval '[ "$(stat -c %s "$POOL/events.jsonl")" -lt 1048576 ]'
check 26-parse eval 'jq -e . "$POOL/events.jsonl" >/dev/null && jq -e . "$POOL/events.jsonl.1" >/dev/null'

# ------------------------------------------------------------------- signals
# 27: CMD gets the INT/QUIT dispositions test-slot started with, not bash's
# background-job ignore. SigIgn bits: INT = 0x2, QUIT = 0x4.
sigign_bits() { # sigign_bits FILE -> INT/QUIT bits of the SigIgn line in FILE
  local hex; hex=$(sed -n 's/^SigIgn:[[:space:]]*//p' "$1"); echo $(( 16#${hex: -8} & 0x6 ))
}
newpool p27 1
env --default-signal=INT,QUIT "$BIN" -- bash -c 'cat /proc/$$/status' >"$W/27a.status" 2>/dev/null
check 27-default-restored eq "$(sigign_bits "$W/27a.status")" 0
env --default-signal=QUIT --ignore-signal=INT "$BIN" -- bash -c 'cat /proc/$$/status' >"$W/27b.status" 2>/dev/null
check 27-caller-ignore-kept eq "$(sigign_bits "$W/27b.status")" 2

# 28/29: INT and TERM sent to the wrapper reach CMD; CMD's own exit code
# (130 / 143) comes back, the outcome file and events record it, and CMD did
# not run to completion. (Under timeout(1) the wrapper is not in a terminal's
# foreground group, so INT is forwarded.)
for sig in INT TERM; do
  case $sig in INT) want=130 ;; TERM) want=143 ;; esac
  newpool "p28$sig" 1
  mkfifo "$W/S28$sig.fifo"
  BG_PRE=(env --default-signal=INT,QUIT)
  bg "S28$sig" --label "S28$sig" --outcome-file "$W/28$sig.outcome" -- bash -c "$HOLD_CMD" _ "$W/S28$sig"
  BG_PRE=()
  await_file "$W/S28$sig.started" 20 || bad "28-$sig-start" "holder never started"
  kill -s "$sig" "$(cat "$W/S28$sig.wrapper")"
  reap "S28$sig"
  check "28-$sig-rc" eq "$RC" "$want"
  check "28-$sig-cmd-stopped" absent "$W/S28$sig.done"
  check "28-$sig-outcome" eq "$(cat "$W/28$sig.outcome" 2>/dev/null)" "ran exit=$want"
  check "28-$sig-event" eq "$(events | jq -s --argjson w "$want" '[.[] | select(.event=="released" and .exit==$w)] | length')" 1
done

# ------------------------------------------------------------------- summary
if [ "$FAIL" -eq 0 ]; then
  echo "test-slot: self-test OK ($PASS checks)"
  exit 0
fi
echo "test-slot: self-test FAILED ($FAIL failed, $PASS passed)" >&2
echo "Fix: read the FAIL lines above; each names its QA Plan row (DND-485)." >&2
exit 1
