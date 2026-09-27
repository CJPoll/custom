#!/usr/bin/env bash
# self-test for ai/bin/test-slot-bench (DND-489) — discovered by harness-gate.
#
# Hermetic: no docker, no gen_saas. The "gen_saas worktrees" are git worktrees
# of a throwaway repo whose bin/prep-commit.sh is a shim; the slot pool is a
# throwaway pool (ATHENA_TEST_SLOT_DIR + ATHENA_TEST_SLOTS seams); load comes
# from a fake loadavg file (TEST_SLOT_BENCH_LOADAVG). A blocking shim blocks
# on a FIFO bounded by `read -t`; every "wait until X" is a bounded poll; every
# background bench is bounded by timeout(1). Case ids are the QA Plan's rows
# (b1..b9 bench, h1..h5 decision helper) plus c* for contamination labels.
set -u -o pipefail

here="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$here/../../bin" && pwd)/test-slot-bench"
TS_BIN="$(cd "$here/../../bin" && pwd)/test-slot"

for f in "$BIN" "$TS_BIN"; do
  if [ ! -x "$f" ]; then
    echo "test-slot-bench self-test: FAIL — $f missing or not executable" >&2
    echo "Fix: restore it and chmod +x it." >&2
    exit 1
  fi
done
for tool in jq flock timeout mkfifo git setsid; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "test-slot-bench self-test: FAIL — required tool '$tool' not on PATH" >&2
    echo "Fix: install $tool and re-run." >&2
    exit 1
  fi
done

unset ATHENA_TEST_SLOT_HELD ATHENA_TEST_SLOT_DIR ATHENA_TEST_SLOTS ATHENA_TEST_SLOT_HEARTBEAT
unset TEST_SLOT_BENCH_TEST_SLOT TEST_SLOT_BENCH_LOADAVG TEST_SLOT_BENCH_CENSUS TEST_SLOT_BENCH_FAKE_UNSLOTTED

W="$(mktemp -d "${TMPDIR:-/tmp}/test-slot-bench-selftest.XXXXXX")"
BG_PIDS=()
cleanup() {
  local f p
  for f in "$W"/shim/*.pid; do
    [ -e "$f" ] || continue
    p="$(cat "$f" 2>/dev/null)"
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  for p in "${BG_PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  wait 2>/dev/null
  git -C "$W/repo" worktree prune >/dev/null 2>&1
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
absent() { [ ! -e "$1" ]; }
present() { [ -e "$1" ]; }
eq() { [ "$1" = "$2" ]; }
await() { # await SECONDS CMD... — bounded poll for CMD to succeed
  local i n=$(($1 * 20)); shift
  for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.05; done
  return 1
}
gone() { ! kill -0 "$1" 2>/dev/null; }

# ------------------------------------------------------------ fixture repo
# bin/prep-commit.sh shim; its behaviour is SHIM_MODE (env, passed through
# test-slot and the bench unchanged):
#   ok       record start, exit 0
#   solo     exit 0 alone; exit 1 when another shim run is alive at once
#   block    record pid, block on $SHIM_DIR/go.fifo (bounded), exit 0
mkdir -p "$W/repo/bin" "$W/shim"
cat >"$W/repo/bin/prep-commit.sh" <<'EOF'
#!/usr/bin/env bash
d=${SHIM_DIR:?}
echo $$ >"$d/$$.pid"
: >"$d/$$.alive"
rc=0
case ${SHIM_MODE:-ok} in
  ok) ;;
  solo)
    for ((i = 0; i < 40; i++)); do
      for f in "$d"/*.alive; do
        p=${f##*/}; p=${p%.alive}
        [ "$p" != $$ ] && kill -0 "$p" 2>/dev/null && rc=1
      done
      [ "$rc" = 1 ] && break
      sleep 0.05
    done ;;
  block) exec 3<>"$d/go.fifo"; read -t 30 -u 3 _x ;;
esac
# peak concurrency
exec 8>>"$d/lock"; flock 8
n=0; for f in "$d"/*.alive; do p=${f##*/}; p=${p%.alive}; kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
m=$(cat "$d/max" 2>/dev/null || echo 0); [ "$n" -gt "$m" ] && echo "$n" >"$d/max"
flock -u 8
rm -f "$d/$$.alive"
exit "$rc"
EOF
chmod +x "$W/repo/bin/prep-commit.sh"
git -C "$W/repo" init -q
git -C "$W/repo" -c user.email=t@t -c user.name=t add -A
git -C "$W/repo" -c user.email=t@t -c user.name=t commit -q -m init
SHA=$(git -C "$W/repo" rev-parse HEAD)
for i in 1 2 3; do git -C "$W/repo" worktree add -q --detach "$W/wt$i" HEAD; done
WTS="$W/wt1,$W/wt2,$W/wt3"
mkfifo "$W/shim/go.fifo"
export SHIM_DIR="$W/shim"

# Throwaway pool (N=3) and fake load.
export ATHENA_TEST_SLOT_DIR="$W/pool" ATHENA_TEST_SLOTS=3
export TEST_SLOT_BENCH_TEST_SLOT="$TS_BIN" TEST_SLOT_BENCH_LOADAVG="$W/loadavg" TEST_SLOT_BENCH_CENSUS=true
setload() { printf '%s %s 0.10 2/300 999\n' "$1" "$1" >"$W/loadavg"; }
setload 0.50
FAST0=(--settle-s 0.05 --settle-max 2 --sample-s 0.05 --tail-s 0 --run-timeout 60)
FAST=("${FAST0[@]}" --wait-timeout 30)

# ------------------------------------------------------------ pure helpers
(
  # shellcheck source=/dev/null
  source "$BIN"
  f=0
  t() { if "$@"; then :; else echo "FAIL [helper] $*" >&2; f=$((f + 1)); fi; }
  t eq "$(parse_levels 5,1,3,3)" "1 3 5"
  t eval '! parse_levels 1,x >/dev/null'
  t eval '! parse_levels 0 >/dev/null'
  t eval '! parse_levels "" >/dev/null'
  t eq "$(contamination_reason 2.0 1.50 0 0)" ""
  t eq "$(contamination_reason 2.0 2.00 0 0)" ""
  t eq "$(contamination_reason 2.0 3.00 0 0)" "bg_load1=3.00>2.0"
  t eq "$(contamination_reason 2.0 1.0 2 0)" "unslotted=2"
  t eq "$(contamination_reason 2.0 1.0 0 1)" "foreign_holders=1"
  t eq "$(contamination_reason 2.0 unknown unknown unknown)" "load1=unknown;unslotted=unknown;foreign_holders=unknown"
  t eq "$(parse_unslotted '{"unslotted":4}')" 4
  t eq "$(parse_unslotted '')" unknown
  t eq "$(parse_unslotted 'garbage')" unknown
  printf 'ts,elapsed_s,load1,load5,runnable\n10,0,1.0,1,2\n11,1,5.0,1,9\n12,2,3.0,1,4\n20,10,7.5,1,3\n' >"$W/ls.csv"
  t eq "$(load_stats "$W/ls.csv" 10 12)" "7.50 3.00 9"
  printf 'ts,elapsed_s,load1,load5,runnable\n' >"$W/ls0.csv"
  t eq "$(load_stats "$W/ls0.csv" 0 1)" "n/a n/a n/a"
  exit "$f"
)
if [ $? -eq 0 ]; then ok; else bad helpers "pure helper cases failed (see above)"; fi

# ------------------------------------------------------------ decision helper
HDR='level,rep,runs,passed,median_wall_s,max_wall_s,peak_load1,mean_load1,peak_runnable,bg_load1,unslotted,foreign_holders,contaminated,reason,class'
ROW_CLASS=gen_saas:prep-commit.sh
row() { # row K REP PEAK PASSED_ALL(yes|no) CONTAMINATED(yes|no)   (class: ROW_CLASS)
  local passed=$1
  [ "$4" = yes ] || passed=0
  printf '%s,%s,%s,%s,100,120,%s,%s,5,0.5,0,0,%s,%s,%s\n' "$1" "$2" "$1" "$passed" "$3" "$3" "$5" "$([ "$5" = yes ] && echo 'bg_load1=3.0>2.0')" "$ROW_CLASS"
}
decide_on() { # decide_on NAME CEILING ROWS... -> $W/NAME.dec, rc in DRC
  local name=$1 ceil=$2; shift 2
  { echo "$HDR"; printf '%s\n' "$@"; } >"$W/$name.csv"
  "$BIN" --decide "$W/$name.csv" --ceiling "$ceil" --min-reps 2 >"$W/$name.dec" 2>"$W/$name.err"
  DRC=$?
}
# h1: 1->6, 3->12, 5->15, all ok, ceiling 16 → N=5, no request.
decide_on h1 16 "$(row 1 1 6 yes no)" "$(row 1 2 6 yes no)" "$(row 3 1 12 yes no)" "$(row 3 2 12 yes no)" "$(row 5 1 15 yes no)" "$(row 5 2 15 yes no)"
check h1-rc eq "$DRC" 0
check h1-N has "$W/h1.dec" "DECISION: N=5"
check h1-no-request eval '! grep -q REQUEST "$W/h1.dec"'
# h2 (and b6): 5 peaks over the ceiling → N=3 and request k=4.
decide_on h2 16 "$(row 1 1 6 yes no)" "$(row 1 2 6 yes no)" "$(row 3 1 12 yes no)" "$(row 3 2 10 yes no)" "$(row 5 1 19 yes no)" "$(row 5 2 20 yes no)"
check h2-N has "$W/h2.dec" "DECISION: N=3"
check h2-request has "$W/h2.dec" "REQUEST: measure k=4"
# h3: 3 FAILS, 5 ok → a higher level cannot rescue a failed lower one: N=1.
decide_on h3 16 "$(row 1 1 6 yes no)" "$(row 1 2 6 yes no)" "$(row 3 1 12 no no)" "$(row 3 2 12 yes no)" "$(row 5 1 15 yes no)" "$(row 5 2 15 yes no)"
check h3-N has "$W/h3.dec" "DECISION: N=1"
check h3-names-failure has "$W/h3.dec" "level 3: FAILS: a run failed;"
# h4: k=1 contaminated (n/a), 3 ok → refuse, no baseline, exit 1 + Fix.
decide_on h4 16 "$(row 1 1 6 yes yes)" "$(row 1 2 6 yes yes)" "$(row 3 1 12 yes no)" "$(row 3 2 12 yes no)"
check h4-rc eq "$DRC" 1
check h4-none has "$W/h4.dec" "DECISION: none"
check h4-na has "$W/h4.dec" "level 1: n/a"
check h4-fix has "$W/h4.err" "Fix:"
check h4-no-N eval '! grep -q "N=" "$W/h4.dec"'
# h5: level 4 measured alone after a k=1 baseline (two files) → N=4.
decide_on h5a 16 "$(row 1 1 6 yes no)" "$(row 1 2 6 yes no)"
{ echo "$HDR"; row 4 1 15 yes no; row 4 2 15 yes no; } >"$W/h5b.csv"
"$BIN" --decide "$W/h5a.csv,$W/h5b.csv" --ceiling 16 --min-reps 2 >"$W/h5.dec" 2>&1
check h5-N has "$W/h5.dec" "DECISION: N=4"
# h6: a contaminated rep is excluded and NAMED; enough clean reps still score.
decide_on h6 16 "$(row 1 1 6 yes no)" "$(row 1 2 6 yes no)" "$(row 1 3 9 yes yes)" "$(row 3 1 12 yes no)" "$(row 3 2 12 yes no)" "$(row 3 3 30 no yes)"
check h6-N has "$W/h6.dec" "DECISION: N=3"
check h6-excluded has "$W/h6.dec" "contaminated reps 1 excluded"
# h7: the default ceiling is 12 (the owner's dispatch threshold).
{ echo "$HDR"; row 1 1 6 yes no; row 1 2 6 yes no; row 3 1 13 yes no; row 3 2 11 yes no; } >"$W/h7.csv"
"$BIN" --decide "$W/h7.csv" >"$W/h7.dec" 2>&1
check h7-default-ceiling has "$W/h7.dec" "DECISION: N=1"

# h8: a decision is about ONE gate class; rows of two classes refuse.
{ echo "$HDR"; row 1 1 6 yes no; row 1 2 6 yes no; ROW_CLASS=custom:harness-gate row 3 1 5 yes no; ROW_CLASS=custom:harness-gate row 3 2 5 yes no; } >"$W/h8.csv"
"$BIN" --decide "$W/h8.csv" --min-reps 2 >"$W/h8.dec" 2>&1; rc=$?
check h8-rc eq "$rc" 1
check h8-mixed has "$W/h8.dec" "rows mix gate classes"
check h8-names-class has "$W/h1.dec" "class: gen_saas:prep-commit.sh"
# h9: a row of the old 14-column shape is refused and counted, never dropped
# (dropping it would read as "no baseline").
{ echo "$HDR"; row 1 1 6 yes no; row 1 2 6 yes no | cut -d, -f1-14; } >"$W/h9.csv"
"$BIN" --decide "$W/h9.csv" --min-reps 1 >"$W/h9.dec" 2>"$W/h9.err"; rc=$?
check h9-rc eq "$rc" 1
check h9-counted has "$W/h9.dec" "1 row(s) do not have the 15 levels.csv columns"
check h9-fix has "$W/h9.err" "Fix:"

# ------------------------------------------------------------ b1: --help
out="$(XDG_STATE_HOME="$W/xdg1" "$BIN" --help 2>"$W/b1.err")"; rc=$?
check b1-rc eq "$rc" 0
check b1-usage eval '[[ "$out" == *Usage:* && "$out" == *--worktrees* ]]'
check b1-quiet eval '[ ! -s "$W/b1.err" ]'
check b1-created-nothing absent "$W/xdg1"

# ------------------------------------------------------------ b2: bad input
mkdir -p "$W/notgensaas"
git -C "$W/notgensaas" init -q
"$BIN" --worktrees "$W/notgensaas" --levels 1 --out-dir "$W/b2" 2>"$W/b2.err"; rc=$?
check b2-rc eq "$rc" 2
check b2-fix has "$W/b2.err" "Fix:"
check b2-names has "$W/b2.err" "bin/prep-commit.sh"
check b2-no-out absent "$W/b2"
"$BIN" --worktrees "$W/wt1,$W/wt2" --levels 1,3 2>"$W/b2b.err"; rc=$?
check b2b-too-few eq "$rc" 2
check b2b-fix has "$W/b2b.err" "needs 3 worktrees"
git -C "$W/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
git -C "$W/repo" worktree add -q --detach "$W/wtx" HEAD
"$BIN" --worktrees "$W/wt1,$W/wtx" --levels 1 2>"$W/b2c.err"; rc=$?
check b2c-sha-mismatch eq "$rc" 2
check b2c-fix has "$W/b2c.err" "different commits"
"$BIN" --worktrees "$W/wt1,$W/wt1" --levels 1 2>"$W/b2d.err"; rc=$?
check b2d-dup eq "$rc" 2
"$BIN" --worktrees "$WTS" --levels 1 --reps 0 2>"$W/b2e.err"; rc=$?
check b2e-reps eq "$rc" 2
"$BIN" --worktrees "$WTS" --bogus 2>"$W/b2f.err"; rc=$?
check b2f-unknown eq "$rc" 2
check b2f-fix has "$W/b2f.err" "Fix:"

# ------------------------------------------------------------ b8: --dry-run
out="$("$BIN" --worktrees "$WTS" --levels 1,3 --out-dir "$W/b8" --dry-run 2>"$W/b8.err")"; rc=$?
check b8-rc eq "$rc" 0
check b8-sha eval '[[ "$out" == *"pinned SHA: $SHA"* ]]'
check b8-wt eval '[[ "$out" == *"$W/wt3"* ]]'
check b8-plan eval '[[ "$out" == *"step: rep 1 level 3 -> worktrees 1..3"* ]]'
check b8-created-nothing absent "$W/b8"
check b8-no-slot-taken absent "$W/pool"
check b8-class eval '[[ "$out" == *"class: repo:prep-commit.sh"* ]]'
# b8b: a shell running a string is its own class (opaque), never a known tool.
out="$("$BIN" --worktrees "$WTS" --levels 1 --cmd 'bash -c bin/prep-commit.sh' --dry-run 2>&1)"
check b8b-opaque eval '[[ "$out" == *"class: repo:opaque"* ]]'
out="$("$BIN" --worktrees "$WTS" --levels 1 --cmd 'timeout 60 bin/prep-commit.sh' --dry-run 2>&1)"
check b8c-wrapper eval '[[ "$out" == *"class: repo:prep-commit.sh"* ]]'

# ------------------------------------------------------------ b3: 1,3 all pass
export SHIM_MODE=ok
"$BIN" --worktrees "$WTS" --levels 1,3 --reps 1 --min-reps 1 --out-dir "$W/b3" "${FAST[@]}" >"$W/b3.out" 2>"$W/b3.err"; rc=$?
check b3-rc eq "$rc" 0
check b3-levels eq "$(cut -d, -f1 "$W/b3/levels.csv" | tail -n +2 | tr '\n' ' ')" "1 3 "
check b3-k3-passed eq "$(awk -F, '$1 == 3 { print $4 "/" $3 }' "$W/b3/levels.csv")" "3/3"
check b3-k3-logs eq "$(find "$W/b3" -maxdepth 1 -name 'run-3-1-*.log' | wc -l)" 3
check b3-runs-rows eq "$(tail -n +2 "$W/b3/runs.csv" | wc -l)" 4
check b3-bg-recorded eq "$(awk -F, 'NR > 1 { print $8 }' "$W/b3/runs.csv" | sort -u)" "0.50"
check b3-clean eq "$(awk -F, 'NR > 1 { print $11 }' "$W/b3/runs.csv" | sort -u)" no
check b3-peak-recorded eq "$(awk -F, '$1 == 3 { print $7 }' "$W/b3/levels.csv")" "0.50"
check b3-concurrent eq "$(cat "$W/shim/max")" 3
check b3-decision has "$W/b3/decision.txt" "DECISION: N=3"
check b3-summary has "$W/b3.out" "| 3 | 1 | 3/3 |"
check b3-exclusive eq "$(jq -s '[.[] | select(.event == "acquired" and .exclusive == true and .label == "DND-489 bench")] | length' "$W/pool/events.jsonl")" 1
check b3-sha-in-meta has "$W/b3/meta.txt" "pinned SHA: $SHA"
# The class is test-slot's own derivation for this argv in these worktrees.
want_class="$(cd "$W/wt1" && "$TS_BIN" --class -- bin/prep-commit.sh)"
check b3-class-derivation eq "$want_class" "repo:prep-commit.sh"
check b3-class-meta has "$W/b3/meta.txt" "class: $want_class"
check b3-class-runs eq "$(awk -F, 'NR > 1 { print $13 }' "$W/b3/runs.csv" | sort -u)" "$want_class"
check b3-class-levels eq "$(awk -F, 'NR > 1 { print $15 }' "$W/b3/levels.csv" | sort -u)" "$want_class"
check b3-decision-class has "$W/b3/decision.txt" "class: $want_class"
check b3-load-samples eval '[ "$(wc -l <"$W/b3/load-3-1.csv")" -ge 2 ]'

# ------------------------------------------------------------ b4: contention fails
rm -f "$W/shim/max" "$W/shim"/*.alive
export SHIM_MODE=solo
"$BIN" --worktrees "$WTS" --levels 1,3 --reps 1 --min-reps 1 --out-dir "$W/b4" "${FAST[@]}" >"$W/b4.out" 2>"$W/b4.err"; rc=$?
check b4-rc eq "$rc" 0
check b4-k1-pass eq "$(awk -F, '$1 == 1 { print $4 "/" $3 }' "$W/b4/levels.csv")" "1/1"
check b4-k3-fail eval '[ "$(awk -F, '"'"'$1 == 3 { print $4 }'"'"' "$W/b4/levels.csv")" -lt 3 ]'
check b4-N1 has "$W/b4/decision.txt" "DECISION: N=1"
check b4-run-failed-recorded eval 'awk -F, '"'"'$1 == 3 && $7 == "no"'"'"' "$W/b4/runs.csv" | grep -q .'
export SHIM_MODE=ok

# ------------------------------------------------------------ c1 (b5): busy background
setload 3.00
"$BIN" --worktrees "$WTS" --levels 1 --reps 1 --min-reps 1 --out-dir "$W/c1" "${FAST[@]}" >"$W/c1.out" 2>"$W/c1.err"; rc=$?
check c1-rc eq "$rc" 0
check c1-contaminated eq "$(awk -F, 'NR > 1 { print $13 }' "$W/c1/levels.csv")" yes
check c1-reason has "$W/c1/levels.csv" "bg_load1=3.00>2.0"
check c1-run-labelled eq "$(awk -F, 'NR > 1 { print $11 }' "$W/c1/runs.csv")" yes
check c1-not-scored has "$W/c1/decision.txt" "level 1: n/a"
check c1-no-N has "$W/c1/decision.txt" "DECISION: none"
check c1-summary-label has "$W/c1.out" "yes: bg_load1=3.00>2.0"
setload 0.50

# c2: a foreign slot holder (slot-4 of a larger-N test-slot) → CONTAMINATED.
mkdir -p "$W/pool"
: >"$W/pool/slot-4.lock"
flock "$W/pool/slot-4.lock" bash -c 'exec 3<>"$1"; read -t 30 -u 3 _x' _ "$W/shim/go.fifo" &
FH=$!; BG_PIDS+=("$FH")
await 5 bash -c '! flock -n -s "$1" true' _ "$W/pool/slot-4.lock" || bad c2-setup "foreign holder never held slot-4"
"$BIN" --worktrees "$WTS" --levels 1 --reps 1 --min-reps 1 --out-dir "$W/c2" "${FAST[@]}" >/dev/null 2>"$W/c2.err"
check c2-contaminated has "$W/c2/levels.csv" "foreign_holders=1"
check c2-run-labelled eq "$(awk -F, 'NR > 1 { print $10 "," $11 }' "$W/c2/runs.csv")" "1,yes"
timeout 5 bash -c 'printf "go\n" > "$1"' _ "$W/shim/go.fifo"
timeout 10 tail --pid="$FH" -f /dev/null

# c3: an UNSLOTTED heavy run (probe seam) → CONTAMINATED.
TEST_SLOT_BENCH_FAKE_UNSLOTTED=1 "$BIN" --worktrees "$WTS" --levels 1 --reps 1 --min-reps 1 --out-dir "$W/c3" "${FAST[@]}" >/dev/null 2>&1
check c3-contaminated has "$W/c3/levels.csv" "unslotted=1"

# c4: seams are ignored outside a test pool (they can never fake a clean run).
out="$(env -u ATHENA_TEST_SLOT_DIR "$BIN" --worktrees "$WTS" --levels 1 --dry-run 2>&1)"
check c4-warn eval '[[ "$out" == *"WARN ignoring TEST_SLOT_BENCH_*"* ]]'
check c4-real-test-slot eval '[[ "$out" == *"held under: $HOME/dev/custom/ai/bin/test-slot"* ]]'

# ------------------------------------------------------------ b7: pool busy → 75
mkfifo "$W/b7.fifo"
timeout 60 "$TS_BIN" --label foreign-b7 -- bash -c 'exec 3<>"$1"; read -t 30 -u 3 _x' _ "$W/b7.fifo" &
H7=$!; BG_PIDS+=("$H7")
await 10 bash -c '[ "$("$1" --status --json 2>/dev/null | jq .held)" = 1 ]' _ "$TS_BIN" || bad b7-setup "holder never took a slot"
"$BIN" --worktrees "$WTS" --levels 1 --reps 1 --out-dir "$W/b7" "${FAST0[@]}" --wait-timeout 2 >/dev/null 2>"$W/b7.err"; rc=$?
check b7-rc eq "$rc" 75
check b7-fix has "$W/b7.err" "Fix:"
check b7-nothing-ran absent "$W/b7/levels.csv"
check b7-outcome eq "$(cat "$W/b7/outcome" 2>/dev/null)" timeout
timeout 5 bash -c 'printf "go\n" > "$1"' _ "$W/b7.fifo"
timeout 10 tail --pid="$H7" -f /dev/null

# ------------------------------------------------------------ b9: killed mid-level
rm -f "$W/shim"/*.pid
export SHIM_MODE=block
timeout 60 "$BIN" --worktrees "$WTS" --levels 3 --reps 1 --min-reps 1 --out-dir "$W/b9" "${FAST[@]}" >/dev/null 2>"$W/b9.err" &
B9=$!; BG_PIDS+=("$B9")
await 20 bash -c '[ "$(find "$1" -maxdepth 1 -name "*.pid" | wc -l)" -ge 3 ]' _ "$W/shim" || bad b9-setup "shims never started: $(cat "$W/b9.err")"
await 10 present "$W/b9/.pids-3-1" || bad b9-setup "no pid record"
shims=$(cat "$W/shim"/*.pid 2>/dev/null | tr '\n' ' ')
runs=$(cat "$W/b9/.pids-3-1" | tr '\n' ' ')
kill -TERM "$B9"
check b9-bench-exits await 20 gone "$B9"
wait "$B9" 2>/dev/null
# shellcheck disable=SC2086
for p in $shims; do check "b9-no-orphan-shim-$p" await 20 gone "$p"; done
# shellcheck disable=SC2086
for p in $runs; do check "b9-no-orphan-run-$p" await 20 gone "$p"; done
sp=$(cat "$W/b9/.sampler-3-1" 2>/dev/null)
check b9-sampler-recorded eval '[ -n "$sp" ]'
check b9-no-sampler await 20 gone "${sp:-0}"
check b9-slots-free eq "$("$TS_BIN" --status --json | jq .held)" 0
export SHIM_MODE=ok

# ------------------------------------------------------------ summary
if [ "$FAIL" -eq 0 ]; then
  echo "test-slot-bench: self-test OK ($PASS checks)"
  exit 0
fi
echo "test-slot-bench: self-test FAILED ($FAIL failed, $PASS passed)" >&2
echo "Fix: read the FAIL lines above; each names its QA Plan row (DND-489: b*, h*, c*)." >&2
exit 1
