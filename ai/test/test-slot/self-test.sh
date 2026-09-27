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
# SIG_DEFAULT — the BG_PRE for every case that SIGNALS a wrapper. A signal
# ignored when a process starts cannot be trapped by bash, and an ignore is
# inherited across fork and exec, so a case that sends INT, QUIT, TERM or HUP
# must reset each to default itself. Otherwise it measures its caller's
# environment instead of test-slot. Measured (DND-815b): a gate launched under
# nohup starts this suite with HUP ignored, so the case-30 waiter ignored HUP,
# kept waiting, and ran its command (7 FAILs, 2 of 2 gate runs, reported as a
# load flake).
SIG_DEFAULT=(env --default-signal=INT,QUIT,TERM,HUP)
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
  t eq "$(ticket_of /p/waiters/q-000000000042.w)" 42
  t eq "$(ticket_of q-000000000007.w)" 7
  t eval '! ticket_of /p/waiters/123-1790000000.w >/dev/null'
  t eval '! ticket_of /p/waiters/.q-5.99.tmp >/dev/null'
  t eval '! ticket_of /p/waiters/q-.w >/dev/null'
  # DND-925: parent_state ORIG_PPID CURRENT_PPID PID_NS
  host='pid:[4026531836]'
  t eq "$(parent_state 100 100 "$host")" alive
  t eq "$(parent_state 100 1 "$host")" gone
  t eq "$(parent_state 100 4242 "$host")" gone
  t eq "$(parent_state 1 1 "$host")" gone
  t eq "$(parent_state 1 1 'pid:[4026532999]')" alive
  t eq "$(parent_state 0 0 "$host")" alive
  t eq "$(parent_state 100 '' "$host")" unknown
  t eq "$(parent_state '' 100 "$host")" unknown
  t eq "$(parent_state 100 x "$host")" unknown
  t eq "$(parent_state 1 1 '')" unknown
  t eq "$(parent_state 100 100 '')" alive
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
  BG_PRE=("${SIG_DEFAULT[@]}")
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

# 30/31 (DND-815; 29 is unused): a signal to a WAITING wrapper exits it promptly. Before the
# fix a waiter sat in a foreground `flock -w <=60s` (queue) or `sleep 2`
# (head), and bash runs a trap only after its foreground child returns, so
# TERM went unanswered for up to a minute. The bound is a blocking wait on the
# pid (tail --pid), never a sleep. After exit: rc 128+sig, no outcome file,
# the waiter file is gone, no helper child of the waiter survives, the holder
# is untouched, and the queue still serves the next run.
# pid_of_bg NAME — the test-slot pid under a bg run's timeout(1).
pid_of_bg() { pgrep -P "$(cat "$W/$1.bg")" | head -n 1; }
# exits_within PID SECONDS — 0 when PID is gone within SECONDS (blocking).
exits_within() { timeout "$2" tail --pid="$1" -f /dev/null; }
# await_kids PID — bounded poll until PID has a child (its wait helper);
# prints the child pids. Never empty on success, so a no-orphan check below
# can not pass vacuously.
await_kids() {
  local i k
  for ((i = 0; i < 200; i++)); do
    k="$(pgrep -P "$1" | tr '\n' ' ')"
    [ -n "$k" ] && { printf '%s\n' "$k"; return 0; }
    sleep 0.05
  done
  return 1
}
# no_orphans PIDS... — 0 when none of PIDS is still alive.
no_orphans() { local k; for k in "$@"; do kill -0 "$k" 2>/dev/null && return 1; done; return 0; }
# await_waiters N — bounded poll until --status --json reports N waiters.
await_waiters() {
  local i
  for ((i = 0; i < 400; i++)); do
    [ "$("$BIN" --status --json 2>/dev/null | jq .waiting)" = "$1" ] && return 0
    sleep 0.05
  done
  return 1
}
# The fixture itself: launched the way bg launches, from a caller that
# ignores INT, QUIT, TERM and HUP (nohup ignores HUP), SIG_DEFAULT leaves none
# of them ignored. SigIgn bits: HUP 0x1, INT 0x2, QUIT 0x4, TERM 0x4000.
(trap '' INT QUIT TERM HUP; exec timeout 60 "${SIG_DEFAULT[@]}" cat /proc/self/status) >"$W/30fix.status" 2>&1
fix_hex=$(sed -n 's/^SigIgn:[[:space:]]*//p' "$W/30fix.status")
check 30-fixture-read eval '[ -n "$fix_hex" ]'
check 30-fixture-signals-default eq "$(( 16#${fix_hex:-0} & 0x4007 ))" 0
for sig in TERM INT HUP; do
  case $sig in INT) want=130 ;; TERM) want=143 ;; HUP) want=129 ;; esac
  newpool "p30$sig" 1
  hold "A30$sig" "holder-A30$sig"
  # B: the queue head, polling the slots. C: behind B, blocked on B's queue
  # file (queue.lock before DND-823).
  bg "B30$sig" --label "B30$sig" -- sh -c ': > "$1"' _ "$W/B30$sig.ran"
  await_grep "$W/B30$sig.err" "WAITING" 20 || bad "30-$sig-B-wait" "B never waited"
  BG_PRE=("${SIG_DEFAULT[@]}")
  bg "C30$sig" --label "C30$sig" --outcome-file "$W/30$sig.outcome" -- sh -c ': > "$1"' _ "$W/C30$sig.ran"
  BG_PRE=()
  await_grep "$W/C30$sig.err" "WAITING" 20 || bad "30-$sig-C-wait" "C never waited"
  check "30-$sig-two-waiting" await_waiters 2
  cpid="$(pid_of_bg "C30$sig")"
  kids="$(await_kids "$cpid")"
  check "30-$sig-has-helper" eval '[ -n "$kids" ]'
  kill -s "$sig" "$cpid"
  check "30-$sig-exits-promptly" exits_within "$cpid" 10
  reap "C30$sig"
  check "30-$sig-rc" eq "$RC" "$want"
  check "30-$sig-C-not-run" absent "$W/C30$sig.ran"
  check "30-$sig-no-outcome" absent "$W/30$sig.outcome"
  # shellcheck disable=SC2086 # word-split pid list
  check "30-$sig-no-orphan-helper" no_orphans $kids
  st="$("$BIN" --status --json 2>/dev/null)"
  check "30-$sig-waiting-1" eq "$(jq .waiting <<<"$st")" 1
  check "30-$sig-held-1" eq "$(jq .held <<<"$st")" 1
  check "30-$sig-waiter-is-B" eq "$(jq -r '.waiters[0].label' <<<"$st")" "B30$sig"
  release "A30$sig"
  reap "B30$sig"; check "30-$sig-B-rc" eq "$RC" 0
  check "30-$sig-B-ran" present "$W/B30$sig.ran"
  reap "A30$sig"
  timeout 10 "$BIN" --label "E30$sig" -- true 2>"$W/E30$sig.err"; rc=$?
  check "30-$sig-queue-free" eq "$rc" 0
  check "30-$sig-no-wait" lacks "$W/E30$sig.err" "WAITING"
done

# 31: the queue HEAD, --exclusive, holding the one free slot of N=2 while it
# waits for the other: TERM exits it promptly and frees exactly what it held
# (its partial slot), never the holder's. Its poll-sleep helper dies with it.
# (Not a failing-first case for promptness: the old head delay was <= 2 s.)
newpool p31 2
hold A31 holder-A31
BG_PRE=("${SIG_DEFAULT[@]}")
bg X31 --label X31 --exclusive -- sh -c ': > "$1"' _ "$W/X31.ran"
BG_PRE=()
await_grep "$W/X31.err" "WAITING" 20 || bad "31-X-wait" "X never waited"
st="$("$BIN" --status --json 2>/dev/null)"
check 31-X-holds-partial eq "$(jq '[.holders[] | select(.label == "X31")] | length' <<<"$st")" 1
xpid="$(pid_of_bg X31)"
xkids="$(await_kids "$xpid")"
check 31-has-helper eval '[ -n "$xkids" ]'
kill -TERM "$xpid"
check 31-exits-promptly exits_within "$xpid" 10
reap X31; check 31-rc eq "$RC" 143
# shellcheck disable=SC2086 # word-split pid list
check 31-no-orphan-helper no_orphans $xkids
check 31-X-not-run absent "$W/X31.ran"
st="$("$BIN" --status --json 2>/dev/null)"
check 31-held-1 eq "$(jq .held <<<"$st")" 1
check 31-holder-kept eq "$(jq -r '.holders[0].label' <<<"$st")" holder-A31
check 31-waiting-0 eq "$(jq .waiting <<<"$st")" 0
release A31; reap A31; check 31-A-rc eq "$RC" 0

# 32 (DND-823, fail-first): slots are granted in ARRIVAL order. N=1, holder
# A; W1 queues first (the head), then W2, then W3, each seen in the queue
# before the next starts. W2 renews its wait every second (heartbeat seam 1);
# W3 uses the default 60 s. Before the fix every waiter blocked on queue.lock
# in a `flock -w <heartbeat>` and re-joined the kernel's wait list at its
# back each time that timed out, so the grant order was the order of each
# waiter's LAST renewal, not of arrival: W3 overtook W2 here, and in the fleet
# a gate starved for 55 min while later arrivals ran. After the fix: W1 W2 W3.
# heartbeats FILE — how many heartbeat lines a waiter has printed so far.
heartbeats() { grep -c "still waiting" "$1" 2>/dev/null; }
newpool p32 1
hold A32 holder-A32
bg W321 --label W321 -- sh -c 'echo W1 >> "$1"' _ "$W/32.order"
check 32-W1-queued await_waiters 1
ATHENA_TEST_SLOT_HEARTBEAT=1 bg W322 --label W322 -- sh -c 'echo W2 >> "$1"' _ "$W/32.order"
check 32-W2-queued await_waiters 2
bg W323 --label W323 -- sh -c 'echo W3 >> "$1"' _ "$W/32.order"
check 32-W3-queued await_waiters 3
# W2 renews its wait twice more AFTER W3 queued (bounded poll).
hb0="$(heartbeats "$W/W322.err")"
for ((i = 0; i < 200; i++)); do [ "$(heartbeats "$W/W322.err")" -ge $((hb0 + 2)) ] && break; sleep 0.05; done
check 32-W2-renewed eval '[ "$(heartbeats "$W/W322.err")" -ge $((hb0 + 2)) ]'
release A32
for k in 1 2 3; do reap "W32$k"; check "32-W$k-rc" eq "$RC" 0; done
reap A32
check 32-fifo eq "$(tr '\n' ' ' <"$W/32.order" 2>/dev/null)" "W1 W2 W3 "

# 33 (DND-823): --status shows each waiter's queue position; a SIGKILLed
# queued waiter leaves the queue at once (its place is judged by its flock,
# never its pid) and blocks nobody behind it; a waiter behind the head still
# times out with exit 75, and the queue closes up behind it.
newpool p33 1
hold A33 holder-A33
for k in 1 2 3; do
  bg "W33$k" --label "W33$k" -- sh -c 'echo "$1" >> "$2"' _ "W$k" "$W/33.order"
  check "33-W$k-queued" await_waiters "$k"
done
bg W334 --label W334 --wait-timeout 8 --outcome-file "$W/33.outcome" -- sh -c 'echo W4 >> "$1"' _ "$W/33.order"
check 33-W4-queued await_waiters 4
st="$("$BIN" --status --json 2>/dev/null)"
check 33-json-positions eq "$(jq -c '[.waiters[] | [.position, .label]]' <<<"$st")" \
  '[[1,"W331"],[2,"W332"],[3,"W333"],[4,"W334"]]'
check 33-json-tickets-rise eq "$(jq '[.waiters[].ticket] | . == sort' <<<"$st")" true
txt="$("$BIN" --status 2>/dev/null)"
check 33-text-positions eval '[[ "$txt" == *"WAITING #1: W331 "*"WAITING #2: W332 "*"WAITING #3: W333 "*"WAITING #4: W334 "* ]]'
check 33-W4-told-position await_grep "$W/W334.err" "queue position 4 of 4" 20
kill -9 "$(pid_of_bg W332)"
reap W332; check 33-W2-killed eq "$RC" 137
# await_gone LABEL — bounded poll until no live waiter carries LABEL.
await_gone() {
  local i
  for ((i = 0; i < 100; i++)); do
    [ "$("$BIN" --status --json 2>/dev/null | jq --arg l "$1" '[.waiters[] | select(.label == $l)] | length')" = 0 ] && return 0
    sleep 0.05
  done
  return 1
}
check 33-W2-left-queue await_gone W332
st="$("$BIN" --status --json 2>/dev/null)"
check 33-closed-up eq "$(jq -c '[.waiters[] | [.position, .label]]' <<<"$st")" \
  '[[1,"W331"],[2,"W333"],[3,"W334"]]'
reap W334; check 33-W4-timeout-rc eq "$RC" 75
check 33-W4-timeout-msg has "$W/W334.err" "TIMEOUT"
check 33-W4-outcome eq "$(cat "$W/33.outcome" 2>/dev/null)" "timeout"
check 33-W4-left-queue await_waiters 2
release A33
reap W331; check 33-W1-rc eq "$RC" 0
reap W333; check 33-W3-rc eq "$RC" 0
reap A33
check 33-order eq "$(tr '\n' ' ' <"$W/33.order" 2>/dev/null)" "W1 W3 "
check 33-queue-empty eq "$("$BIN" --status --json 2>/dev/null | jq .waiting)" 0

# 34 (DND-823 rollout): pre-fix and fixed test-slot share one live pool while
# the fix lands. The pre-fix copy (f99806a, the last version before DND-823)
# queues on queue.lock; the fixed head takes queue.lock too, so there is one
# slot poller at a time across versions, slots stay flock-exclusive (never
# two runs at once at N=1), neither version deletes the other's live waiter
# file, and whichever head queued first is served first.
OLD_REV=f99806ad299a5ead0b404f0ce19aa7e64e271f60
OLD="$W/test-slot-pre-dnd-823"
if git -C "$here" show "$OLD_REV:ai/bin/test-slot" >"$OLD" 2>"$W/34.git.err" && [ -s "$OLD" ]; then
  chmod +x "$OLD"
  # oldbg NAME ARGS... — like bg, but runs the pre-fix copy.
  oldbg() {
    local name=$1; shift
    timeout 60 "$OLD" "$@" >"$W/$name.out" 2>"$W/$name.err" &
    echo $! >"$W/$name.bg"
    BG_PIDS+=("$!")
  }
  # ORDER_CONC NAME ORDERFILE DIR: record the run order, then concurrency.
  ORDER_CONC='echo "$1" >> "$2"; exec "$3" "$4" 2 20'
  for first in old new; do
    newpool "p34$first" 1
    mkdir -p "$W/c34$first"
    hold "A34$first" "holder-A34$first"
    if [ "$first" = old ]; then
      oldbg "O34$first" --label "O34$first" -- sh -c "$ORDER_CONC" _ old "$W/34$first.order" "$W/conc.sh" "$W/c34$first"
      check "34-$first-O-waits" await_grep "$W/O34$first.err" "WAITING" 20
      bg "N34$first" --label "N34$first" -- sh -c "$ORDER_CONC" _ new "$W/34$first.order" "$W/conc.sh" "$W/c34$first"
      check "34-$first-N-waits" await_grep "$W/N34$first.err" "WAITING" 20
      want="old new "
    else
      bg "N34$first" --label "N34$first" -- sh -c "$ORDER_CONC" _ new "$W/34$first.order" "$W/conc.sh" "$W/c34$first"
      check "34-$first-N-waits" await_grep "$W/N34$first.err" "WAITING" 20
      oldbg "O34$first" --label "O34$first" -- sh -c "$ORDER_CONC" _ old "$W/34$first.order" "$W/conc.sh" "$W/c34$first"
      check "34-$first-O-waits" await_grep "$W/O34$first.err" "WAITING" 20
      want="new old "
    fi
    check "34-$first-both-waiting" await_waiters 2
    st="$("$BIN" --status --json 2>/dev/null)"
    check "34-$first-new-positioned" eq "$(jq -r '.waiters[] | select(.label == "N34'"$first"'") | .position' <<<"$st")" 1
    check "34-$first-old-unordered" eq "$(jq -r '.waiters[] | select(.label == "O34'"$first"'") | .position' <<<"$st")" null
    check "34-$first-old-status-text" eval '[[ "$("$BIN" --status 2>/dev/null)" == *"WAITING (pre-DND-823 waiter, unordered): O34$first "* ]]'
    release "A34$first"
    reap "O34$first"; check "34-$first-O-rc" eq "$RC" 0
    reap "N34$first"; check "34-$first-N-rc" eq "$RC" 0
    reap "A34$first"
    check "34-$first-order" eq "$(tr '\n' ' ' <"$W/34$first.order" 2>/dev/null)" "$want"
    check "34-$first-max1" eq "$(cat "$W/c34$first/max" 2>/dev/null)" 1
    timeout 10 "$BIN" --label "E34$first" -- true 2>"$W/E34$first.err"; rc=$?
    check "34-$first-pool-usable" eq "$rc" 0
    check "34-$first-no-wait" lacks "$W/E34$first.err" "WAITING"
    timeout 10 "$OLD" --label "F34$first" -- true 2>"$W/F34$first.err"; rc=$?
    check "34-$first-pool-usable-old" eq "$rc" 0
  done
else
  bad 34-old-copy "could not extract the pre-fix test-slot at $OLD_REV: $(cat "$W/34.git.err" 2>/dev/null). Fix: run the suite from a git checkout of ~/dev/custom that contains $OLD_REV (git fetch origin)."
fi

# ------------------------------------------------- parent death (DND-925)
# A queued test-slot whose caller died used to keep its queue place (the
# kernel reparents it and sends it no signal), later take a slot and run a
# gate nobody was waiting on. Measured 2026-09-27 (DND-794): a killed zsh left
# a queued harness-gate waiter under PID 1. Now it leaves the queue within a
# bound and never runs CMD. These cases wait with blocking pid waits or 1 s
# polls, never sub-second ones (DND-875 tracks the older 0.05 s polls above).
# await_grep_s FILE STRING SECONDS / await_waiters_s N SECONDS: 1 s polls.
await_grep_s() {
  local i
  for ((i = 0; i < $3; i++)); do has "$1" "$2" && return 0; sleep 1; done
  has "$1" "$2"
}
await_waiters_s() {
  local i
  for ((i = 0; i < $2; i++)); do
    [ "$("$BIN" --status --json 2>/dev/null | jq .waiting)" = "$1" ] && return 0
    sleep 1
  done
  return 1
}
# parent.sh BIN W NAME: a caller that WAITS on test-slot (bash does not exec
# a command that is followed by another), so killing it orphans the waiter.
cat >"$W/parent.sh" <<'EOF'
#!/usr/bin/env bash
bin=$1 w=$2 name=$3
"$bin" --label "$name" -- sh -c 'echo "$1" >> "$2"' _ "$name" "$w/$name.order" 2>"$w/$name.err"
echo "rc=$?" >"$w/$name.parentrc"
EOF
chmod +x "$W/parent.sh"
# orphan_start NAME: start parent.sh NAME and wait until its test-slot is
# WAITING; sets PARENT_PID (the caller) and ORPHAN_PID (test-slot under it).
orphan_start() {
  "$W/parent.sh" "$BIN" "$W" "$1" &
  PARENT_PID=$!
  BG_PIDS+=("$PARENT_PID")
  await_grep_s "$W/$1.err" "WAITING" 20 || bad "$1-wait" "never waited: $(cat "$W/$1.err" 2>/dev/null)"
  ORPHAN_PID="$(pgrep -P "$PARENT_PID" | head -n 1)"
  # Recorded as a .pid so cleanup kills it even if the fix regresses.
  [ -n "$ORPHAN_PID" ] && echo "$ORPHAN_PID" >"$W/$1.orphan.pid"
}

# 35: the queue HEAD (polling the slots) loses its caller. It must leave the
# queue within a bound, say ORPHANED with a Fix, log `orphaned`, and never run
# CMD, even once the slot frees.
newpool p35 1
hold A35 holder-A35
orphan_start O35
check 35-orphan-pid eval '[ -n "$ORPHAN_PID" ]'
kill -9 "$PARENT_PID"
wait "$PARENT_PID" 2>/dev/null
check 35-exits-promptly exits_within "${ORPHAN_PID:-0}" 15
check 35-left-queue await_waiters_s 0 5
check 35-says-orphaned has "$W/O35.err" "ORPHANED"
check 35-fix has "$W/O35.err" "Fix:"
check 35-event eq "$(event_count orphaned O35)" 1
release A35; reap A35; check 35-A-rc eq "$RC" 0
exits_within "${ORPHAN_PID:-0}" 15
check 35-never-ran absent "$W/O35.order"
check 35-no-acquire eq "$(event_count acquired O35)" 0

# 36: a waiter in the MIDDLE of the queue (blocked in the kernel on its
# predecessor's queue file) loses its caller. It leaves within the parent
# check bound (5 s), not the 60 s heartbeat chunk, and the waiter behind it
# moves up.
newpool p36 1
hold A36 holder-A36
bg W361 --label W361 -- sh -c 'echo W1 >> "$1"' _ "$W/36.order"
check 36-W1-queued await_waiters_s 1 20
orphan_start O36
check 36-O-queued await_waiters_s 2 20
bg W363 --label W363 -- sh -c 'echo W3 >> "$1"' _ "$W/36.order"
check 36-W3-queued await_waiters_s 3 20
kill -9 "$PARENT_PID"
wait "$PARENT_PID" 2>/dev/null
check 36-exits-promptly exits_within "${ORPHAN_PID:-0}" 15
st="$("$BIN" --status --json 2>/dev/null)"
check 36-closed-up eq "$(jq -c '[.waiters[] | [.position, .label]]' <<<"$st")" '[[1,"W361"],[2,"W363"]]'
check 36-event eq "$(event_count orphaned O36)" 1
release A36
reap W361; check 36-W1-rc eq "$RC" 0
reap W363; check 36-W3-rc eq "$RC" 0
reap A36
exits_within "${ORPHAN_PID:-0}" 15
check 36-order eq "$(tr '\n' ' ' <"$W/36.order" 2>/dev/null)" "W1 W3 "
check 36-never-ran absent "$W/O36.order"

# 37: the MISSING case: the caller is already gone when test-slot starts (its
# first check). C blocks on a FIFO under parent P; P is killed, so C is
# reparented to PID 1; then C execs test-slot on a FREE pool. It must refuse
# to run, before it ever queues.
newpool p37 1
mkfifo "$W/C37.fifo" "$W/P37.fifo"
cat >"$W/c37.sh" <<'EOF'
#!/usr/bin/env bash
# c37.sh FIFO BIN RAN ERR: block on FIFO, then become test-slot.
read -t 20 _ <"$1"
exec "$2" --label O37 -- sh -c ': > "$1"' _ "$3" 2>"$4"
EOF
cat >"$W/p37.sh" <<'EOF'
#!/usr/bin/env bash
# p37.sh PIDFILE HOLDFIFO C37ARGS...: start c37.sh, record its pid, block.
pidfile=$1 hold=$2; shift 2
"$@" &
echo $! >"$pidfile"
exec 3<>"$hold"
read -t 30 -u 3 _
EOF
chmod +x "$W/c37.sh" "$W/p37.sh"
"$W/p37.sh" "$W/C37.orphan.pid" "$W/P37.fifo" "$W/c37.sh" "$W/C37.fifo" "$BIN" "$W/O37.ran" "$W/O37.err" &
p37=$!
BG_PIDS+=("$p37")
await_grep_s "$W/C37.orphan.pid" "" 20
c37="$(cat "$W/C37.orphan.pid" 2>/dev/null)"
kill -9 "$p37"
wait "$p37" 2>/dev/null
c37_ppid=""
if read -r s37 <"/proc/${c37:-0}/stat" 2>/dev/null; then
  r37=${s37##*) }
  read -r _ c37_ppid _ <<<"$r37"
fi
if [ "$c37_ppid" != 1 ]; then
  bad 37-born-orphan "C (pid '${c37:-}') has parent '$c37_ppid', not PID 1. Fix: this case needs a host where an orphan is reparented to PID 1 of the host pid namespace; here a child subreaper (e.g. systemd --user) or a container adopted it, which test-slot cannot tell from a live caller at startup (a named RESIDUAL in ai/bin/test-slot). Run the gate from a login shell outside any subreaper or container."
fi
timeout 5 bash -c 'printf "go\n" > "$1"' _ "$W/C37.fifo"
check 37-exits-promptly exits_within "${c37:-0}" 15
check 37-never-ran absent "$W/O37.ran"
check 37-says-orphaned has "$W/O37.err" "ORPHANED"
check 37-fix has "$W/O37.err" "Fix:"
check 37-never-queued eq "$(event_count waiting O37)$(event_count acquired O37)" 00

# ------------------------------------------------------------------- summary
if [ "$FAIL" -eq 0 ]; then
  echo "test-slot: self-test OK ($PASS checks)"
  exit 0
fi
echo "test-slot: self-test FAILED ($FAIL failed, $PASS passed)" >&2
echo "Fix: read the FAIL lines above; each names its QA Plan row (DND-485)." >&2
exit 1
