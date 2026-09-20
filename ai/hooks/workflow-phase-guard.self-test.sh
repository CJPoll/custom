#!/bin/sh
# Self-test for workflow-phase-guard.sh.
#
# Hermetic: an overridable MARKER_DIR + LOG, and an INJECTED class resolver
# (WORKFLOW_PHASE_CLASS_CMD -> a stub that emulates check-tool-risk's --json /
# --class-of), so the suite runs with NO session state and does NOT depend on
# C1's check-tool-risk being present/merged. No network, no mutation outside a
# private temp dir.
#
# Covers: the full 3x3 deny/allow matrix {readOnly,idempotent,destructive} x
# {read-only,local,write} (deny iff rank > ceiling), the fail-open cells (absent
# / malformed / unresolvable phase signal, non-Bash tool, empty command, empty /
# unparseable stdin, class-resolver erroring, no-registry-tool referenced), the
# `full` ceiling, the deny message's Fix:+phase+tool+class content, the DISTINCT
# log lines for absent vs malformed vs unresolvable, and the setter CLI. Emits a
# `Fix:` clause on failure.
#
# Exit 0 iff every case passes.

HOOK="$(dirname "$0")/workflow-phase-guard.sh"
HOOK=$(CDPATH= cd "$(dirname "$HOOK")" && printf '%s/%s' "$(pwd)" "$(basename "$HOOK")")
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; echo "Fix: restore ai/hooks/workflow-phase-guard.sh."; exit 1; }

TMP=$(mktemp -d 2>/dev/null) || { echo "FAIL: mktemp -d failed"; echo "Fix: ensure a writable TMPDIR."; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

MDIR="$TMP/markers"
LOG="$TMP/guard.log"
STUB="$TMP/ctr-stub"

# ---- the injected class resolver (stands in for check-tool-risk) -----------
cat > "$STUB" <<'STUBEOF'
#!/bin/sh
case "$1" in
  --json)
    printf '%s\n' '{"critic-review":"readOnly","harness-gate":"readOnly","build-agents":"idempotent","gh-athena":"destructive","glab-athena":"destructive"}'
    ;;
  --class-of)
    case "$2" in
      critic-review|harness-gate) echo readOnly ;;
      build-agents)               echo idempotent ;;
      gh-athena|glab-athena)      echo destructive ;;
      *)                          echo destructive ;;
    esac
    ;;
  *) exit 2 ;;
esac
STUBEOF
chmod +x "$STUB"

# A stub that ERRORS, to exercise the class-resolver-unavailable fail-open cell.
STUB_ERR="$TMP/ctr-err"
printf '#!/bin/sh\nexit 3\n' > "$STUB_ERR"
chmod +x "$STUB_ERR"

export WORKFLOW_PHASE_MARKER_DIR="$MDIR"
export WORKFLOW_PHASE_LOG="$LOG"
export WORKFLOW_PHASE_CLASS_CMD="$STUB"

PASS=0
FAIL=0

# run <json> : hook in stdin (hook) mode; sets OUT + STATUS.
run() {
  OUT=$(printf '%s' "$1" | sh "$HOOK" 2>/dev/null)
  STATUS=$?
}

is_deny()  { [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'; }
is_allow() { [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; }

check() {
  _label=$1; _expect=$2
  if [ "$_expect" = deny ]; then
    if is_deny; then _r=PASS; else _r=FAIL; fi
  else
    if is_allow; then _r=PASS; else _r=FAIL; fi
  fi
  if [ "$_r" = PASS ]; then
    PASS=$((PASS + 1)); printf '  PASS  %s (expected %s)\n' "$_label" "$_expect"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (expected %s) status=%s out=[%s]\n' "$_label" "$_expect" "$STATUS" "$OUT"
  fi
}

# assert <label> <condition-result 0/1 already evaluated> — generic PASS/FAIL.
assert() {
  _label=$1; _ok=$2
  if [ "$_ok" -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$_label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$_label"
  fi
}

# JSON with an explicit cwd.
json() { jq -cn --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'; }

# Set a phase for a workdir via the PUBLIC setter (uses $PWD), env-scoped markers.
setphase() { ( cd "$1" && sh "$HOOK" --set "$2" >/dev/null ); }

# Representative commands, one per tool class.
CMD_RO="ai/bin/critic-review --self-test"      # readOnly  (rank 0)
CMD_IDEMP="ai/bin/build-agents --check"         # idempotent (rank 1)
CMD_DESTR="ai/bin/gh-athena pr create -t x -b y" # destructive (rank 2)

echo "workflow-phase-guard self-test"
echo "hook: $HOOK"
echo

# ---- workdirs, one per phase (so a --set never clobbers another cell) ------
WD_RO="$TMP/wd-readonly";  mkdir -p "$WD_RO";  setphase "$WD_RO" read-only
WD_LO="$TMP/wd-local";     mkdir -p "$WD_LO";  setphase "$WD_LO" local
WD_WR="$TMP/wd-write";     mkdir -p "$WD_WR";  setphase "$WD_WR" write
WD_FU="$TMP/wd-full";      mkdir -p "$WD_FU";  setphase "$WD_FU" full
WD_AB="$TMP/wd-absent";    mkdir -p "$WD_AB"   # no marker on purpose
WD_MAL="$TMP/wd-malformed"; mkdir -p "$WD_MAL"

echo "--- 3x3 matrix: DENY iff rank(class) > ceiling(phase) ---"
# read-only (ceiling 0)
run "$(json "$CMD_RO"    "$WD_RO")"; check "readOnly    in read-only" allow
run "$(json "$CMD_IDEMP" "$WD_RO")"; check "idempotent  in read-only" deny
run "$(json "$CMD_DESTR" "$WD_RO")"; check "destructive in read-only" deny
# local (ceiling 1)
run "$(json "$CMD_RO"    "$WD_LO")"; check "readOnly    in local"     allow
run "$(json "$CMD_IDEMP" "$WD_LO")"; check "idempotent  in local"     allow
run "$(json "$CMD_DESTR" "$WD_LO")"; check "destructive in local"     deny
# write (ceiling 2)
run "$(json "$CMD_RO"    "$WD_WR")"; check "readOnly    in write"     allow
run "$(json "$CMD_IDEMP" "$WD_WR")"; check "idempotent  in write"     allow
run "$(json "$CMD_DESTR" "$WD_WR")"; check "destructive in write"     allow
# full (ceiling 2)
run "$(json "$CMD_DESTR" "$WD_FU")"; check "destructive in full"      allow

echo
echo "--- deny message content (Fix: + phase + tool + class) ---"
run "$(json "$CMD_DESTR" "$WD_RO")"
printf '%s' "$OUT" | grep -q 'Fix:';        assert "deny msg carries Fix:"            $?
printf '%s' "$OUT" | grep -q "read-only";   assert "deny msg names the phase"         $?
printf '%s' "$OUT" | grep -q "gh-athena";   assert "deny msg names the tool"          $?
printf '%s' "$OUT" | grep -q "destructive"; assert "deny msg names the class"         $?

echo
echo "--- phase-signal cells (fail-open) + DISTINCT log lines ---"
: > "$LOG"
run "$(json "$CMD_DESTR" "$WD_AB")";  check "absent phase -> allow"        allow
grep -q "phase=none" "$LOG";          assert "absent logs phase=none"      $?

# malformed: write a non-vocab token directly to the marker path
MP_MAL=$(sh "$HOOK" --marker-path --cwd "$WD_MAL"); mkdir -p "$(dirname "$MP_MAL")"; printf 'bogus\n' > "$MP_MAL"
: > "$LOG"
run "$(json "$CMD_DESTR" "$WD_MAL")"; check "malformed phase -> allow"     allow
grep -q "malformed phase 'bogus'" "$LOG"; assert "malformed logs DISTINCT WARN" $?

: > "$LOG"
run "$(json "$CMD_DESTR" "/no/such/dir/xyz123")"; check "cwd unresolvable -> allow" allow
grep -q "cwd unresolvable" "$LOG";    assert "unresolvable logs DISTINCT WARN"      $?

echo
echo "--- class-resolver unavailable (e.g. C1 unmerged) -> fail-open ---"
( WORKFLOW_PHASE_CLASS_CMD="$STUB_ERR"; export WORKFLOW_PHASE_CLASS_CMD
  OUT=$(printf '%s' "$(json "$CMD_DESTR" "$WD_RO")" | sh "$HOOK" 2>/dev/null); ST=$?
  [ "$ST" -eq 0 ] && [ -z "$OUT" ] ); assert "resolver error in read-only -> allow" $?
( WORKFLOW_PHASE_CLASS_CMD="/no/such/check-tool-risk"; export WORKFLOW_PHASE_CLASS_CMD
  OUT=$(printf '%s' "$(json "$CMD_DESTR" "$WD_RO")" | sh "$HOOK" 2>/dev/null); ST=$?
  [ "$ST" -eq 0 ] && [ -z "$OUT" ] ); assert "resolver missing in read-only -> allow" $?

echo
echo "--- no false denials on the happy path (read-only phase) ---"
run "$(json "git status" "$WD_RO")";                   check "git status (no tool)"      allow
run "$(json "ls -la"     "$WD_RO")";                   check "ls (no tool)"              allow
run "$(json "mix test"   "$WD_RO")";                   check "mix test (no tool)"        allow
run "$(json "grep -r foo ." "$WD_RO")";                check "grep (no tool)"            allow
run "$(json "$CMD_IDEMP" "$WD_LO")";                   check "build-agents in local"     allow
# a substring that is NOT a whole-word tool reference must not match
run "$(json "echo gh-athenaXYZ" "$WD_RO")";            check "non-word substring -> allow" allow

echo
echo "--- fail-open: malformed / non-Bash / empty inputs ---"
run '';                                                        check "empty stdin"          allow
run 'not json at all';                                         check "non-JSON stdin"       allow
run '{"tool_name":"Bash","tool_input":';                       check "truncated JSON"       allow
run '{"tool_name":"SendMessage","tool_input":{"command":"ai/bin/gh-athena pr create"},"cwd":"'"$WD_RO"'"}'
check "non-Bash tool"        allow
run '{"tool_name":"Bash","tool_input":{"command":null},"cwd":"'"$WD_RO"'"}'
check "null command"         allow
run "$(jq -cn --arg d "$WD_RO" '{tool_name:"Bash",tool_input:{command:""},cwd:$d}')"
check "empty command"        allow

echo
echo "--- setter CLI ---"
WD_CLI="$TMP/wd-cli"; mkdir -p "$WD_CLI"
( cd "$WD_CLI" && sh "$HOOK" --set write >/dev/null && [ "$(sh "$HOOK" --get)" = write ] ); assert "--set write then --get = write" $?
( cd "$WD_CLI" && sh "$HOOK" --clear >/dev/null && [ "$(sh "$HOOK" --get)" = none ] );      assert "--clear then --get = none"    $?
( cd "$WD_CLI" && sh "$HOOK" --set bogus 2>/dev/null ); [ $? -ne 0 ] && _z=0 || _z=1;        assert "--set invalid phase rejected" "$_z"
( cd "$WD_CLI" && sh "$HOOK" --marker-path | grep -q "^$MDIR/.*\.phase$" );                 assert "--marker-path under MARKER_DIR" $?
# a stray NON-flag arg must be rejected (exit != 0), never fall through to a
# stdin-blocking hook run.
sh "$HOOK" bogus-arg </dev/null >/dev/null 2>&1; [ $? -ne 0 ] && _z=0 || _z=1;             assert "stray non-flag arg rejected" "$_z"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
if [ "$FAIL" -ne 0 ]; then
  echo "Fix: a cell above diverged from the deny-iff-rank>ceiling matrix or the fail-open guarantee — read the FAIL line (expected vs actual) and correct ai/hooks/workflow-phase-guard.sh (or this suite if the expectation is wrong)."
  exit 1
fi
echo "ALL CASES PASS"
exit 0
