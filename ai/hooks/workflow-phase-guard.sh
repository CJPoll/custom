#!/bin/sh
# PreToolUse workflow-phase guard  (DND-173 / gap 12; consumes DND-172's registry)
#
# Gates which first-party tools a Bash command may invoke based on the session's
# current WORKFLOW PHASE, using the C1 risk classes (ai/tools/risk.yml, read via
# ai/bin/check-tool-risk). It denies, e.g., a destructive tool while the agent
# has declared a read-only/exploration phase — intra-session, per-directory,
# state-machine guardrails on top of the coarse per-agent tool restrictions.
#
# PHASE SIGNAL = an agent-written MARKER FILE keyed on realpath(cwd). Claude Code
# exposes no built-in "current phase" at PreToolUse time; of the candidates
# (env var / marker file / agent-type inference / skill context) only a marker
# file is BOTH readable by a PreToolUse hook (which sees stdin JSON: tool_name,
# tool_input, cwd) AND mutable by the agent at a phase transition. Env can't be
# mutated mid-session; skill context is not on hook stdin. So: a marker file it
# is, and this script DOUBLES as the setter CLI that writes it.
#
#   Marker dir : ${XDG_STATE_HOME:-$HOME/.local/state}/athena/workflow-phase/
#   Marker file: sha256(realpath(cwd)).phase   (hash the realpath so a path
#                containing any delimiter can never collide or split — the
#                "failed lookup must be distinct from an empty one" rule)
#   Content    : one token of {read-only, local, write, full}
#
# marker_path_for() is the SINGLE function used by BOTH the reader (hook, from
# stdin .cwd) and the setter (from $PWD), so the realpath+hash normalisation is
# provably identical on both sides (the same failed-lookup rule).
#
# Ceiling lattice (tool risk rank vs. phase ceiling):
#   tool class : readOnly(0) < idempotent(1) < destructive(2)   [from C1]
#   phase      : read-only -> ceiling 0   (deny idempotent + destructive)
#                local     -> ceiling 1   (deny destructive)
#                write     -> ceiling 2   (allow all)
#                full      -> ceiling 2   (allow all)
#   decision   : DENY iff rank(tool_class) > ceiling(phase), else ALLOW.
#   absent / malformed / unknown phase -> FAIL-OPEN (allow everything).
#
# FAIL-OPEN GUARANTEE (an explicit acceptance criterion). Every one of these
# ALLOWS: empty/unparseable stdin, missing jq, non-Bash tool, empty command,
# cwd unresolvable, marker absent, marker malformed/unreadable, check-tool-risk
# missing/erroring (e.g. C1 not yet merged), no known registry tool referenced,
# any unexpected error. The ONLY deny is a valid restrictive phase together with
# a matched tool whose rank exceeds the ceiling. There are NO false denials on
# the happy path. A bug here can never wedge a session or a fleet.
#
# Deny-by-default is INHERITED, never re-implemented: every class comes from
# `check-tool-risk --class-of`, whose unknown-tool default is `destructive`.
#
# No self-block: the hook shelling out to check-tool-risk does not re-trigger
# PreToolUse, and the deny message tells the agent to run THIS ai/hooks file
# (not an ai/bin registry tool), so acting on the remedy never self-denies.
#
# Wired in ~/.claude/settings.json as a PreToolUse hook scoped to Bash
# (ai/hooks/registry.json is the source of truth; `scripts/setup-hooks --install`
# wires it). It fails open, so once wired it no-ops until C1's check-tool-risk
# lands, then activates automatically.
#
# CLI (setter + diagnostics; the agent uses these to drive the phase machine):
#   --set <phase>              write the marker for $PWD (phase must be valid)
#   --clear                    remove the marker for $PWD
#   --get                      print $PWD's current phase, or `none`
#   --marker-path [--cwd DIR]  print the resolved marker path (DIR defaults $PWD)
#   --self-test                run the hermetic self-test suite
#
# Overridable for the hermetic self-test (never set in normal use):
#   WORKFLOW_PHASE_MARKER_DIR  marker directory
#   WORKFLOW_PHASE_LOG         decision/warn log file
#   WORKFLOW_PHASE_CLASS_CMD   the class resolver (a stub standing in for
#                              check-tool-risk: supports --json and --class-of X)

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
MARKER_DIR="${WORKFLOW_PHASE_MARKER_DIR:-$STATE_HOME/athena/workflow-phase}"
LOG_FILE="${WORKFLOW_PHASE_LOG:-$STATE_HOME/athena/workflow-phase-guard.log}"

# ---- shared helpers --------------------------------------------------------

# Best-effort append to the log; NEVER changes the hook's exit behaviour.
log() {
  _d=$(dirname "$LOG_FILE")
  mkdir -p "$_d" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$*" >> "$LOG_FILE" 2>/dev/null || :
  return 0
}

valid_phase() {
  case "$1" in
    read-only|local|write|full) return 0 ;;
    *) return 1 ;;
  esac
}

ceiling_of_phase() {
  case "$1" in
    read-only) echo 0 ;;
    local)     echo 1 ;;
    write)     echo 2 ;;
    full)      echo 2 ;;
    *)         echo -1 ;;   # caller fails open before reaching this
  esac
}

rank_of_class() {
  case "$1" in
    readOnly)    echo 0 ;;
    idempotent)  echo 1 ;;
    destructive) echo 2 ;;
    *)           echo 2 ;;  # unknown class -> most restrictive (deny-by-default)
  esac
}

# marker_path_for <dir> : realpath+hash <dir>, print "$MARKER_DIR/<sha256>.phase".
# The ONE normalisation used by both reader and setter. Non-zero on any failure
# (unresolvable dir, missing realpath/sha256sum) with nothing printed.
marker_path_for() {
  _rp=$(realpath "$1" 2>/dev/null) || return 1
  [ -n "$_rp" ] || return 1
  _h=$(printf '%s' "$_rp" | sha256sum 2>/dev/null | cut -d' ' -f1) || return 1
  [ -n "$_h" ] || return 1
  printf '%s/%s.phase' "$MARKER_DIR" "$_h"
}

# ---- setter / diagnostic CLI ----------------------------------------------

case "$1" in
  --self-test)
    _st="$(dirname "$0")/workflow-phase-guard.self-test.sh"
    [ -f "$_st" ] || { echo "workflow-phase: self-test not found at $_st. Fix: restore ai/hooks/workflow-phase-guard.self-test.sh." >&2; exit 1; }
    exec sh "$_st"
    ;;
  --set)
    _phase=$2
    if ! valid_phase "$_phase"; then
      echo "workflow-phase: invalid phase '${_phase:-}'. Fix: use one of read-only|local|write|full." >&2
      exit 2
    fi
    _mp=$(marker_path_for "$PWD") || {
      echo "workflow-phase: cannot resolve marker path for $PWD. Fix: ensure the directory exists and realpath/sha256sum are on PATH." >&2
      exit 2
    }
    mkdir -p "$(dirname "$_mp")" 2>/dev/null || {
      echo "workflow-phase: cannot create $MARKER_DIR. Fix: check permissions on the state dir." >&2
      exit 2
    }
    printf '%s\n' "$_phase" > "$_mp" || {
      echo "workflow-phase: cannot write $_mp. Fix: check permissions on the state dir." >&2
      exit 2
    }
    echo "workflow-phase: set to '$_phase' for $PWD"
    exit 0
    ;;
  --clear)
    _mp=$(marker_path_for "$PWD") || { echo "workflow-phase: nothing to clear (unresolvable cwd)"; exit 0; }
    rm -f "$_mp" 2>/dev/null
    echo "workflow-phase: cleared for $PWD"
    exit 0
    ;;
  --get)
    _mp=$(marker_path_for "$PWD") || { echo none; exit 0; }
    if [ -f "$_mp" ]; then
      _v=$(tr -d ' \t\r\n' < "$_mp" 2>/dev/null)
      [ -n "$_v" ] && echo "$_v" || echo none
    else
      echo none
    fi
    exit 0
    ;;
  --marker-path)
    _target=$PWD
    if [ "$2" = "--cwd" ] && [ -n "$3" ]; then _target=$3; fi
    _mp=$(marker_path_for "$_target") || {
      echo "workflow-phase: cannot resolve marker path for $_target. Fix: ensure the directory exists and realpath/sha256sum are on PATH." >&2
      exit 2
    }
    echo "$_mp"
    exit 0
    ;;
  -*)
    echo "workflow-phase: unknown flag '$1'. Fix: use --set|--clear|--get|--marker-path|--self-test, or invoke with no args as a PreToolUse hook (stdin JSON)." >&2
    exit 2
    ;;
  ?*)
    # Any other NON-EMPTY first arg is misuse: reject rather than fall through to
    # hook mode (which would block on stdin). Empty $1 (the real hook path) does
    # not match this and proceeds below.
    echo "workflow-phase: unexpected argument '$1'. Fix: use --set|--clear|--get|--marker-path|--self-test, or invoke with no args as a PreToolUse hook (stdin JSON)." >&2
    exit 2
    ;;
esac

# ---- PreToolUse hook mode (no CLI flag: read stdin JSON) -------------------

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

RAWCWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
[ -n "$RAWCWD" ] || { log "WARN no cwd on stdin; fail-open allow"; exit 0; }

CWD=$(realpath "$RAWCWD" 2>/dev/null) || { log "WARN cwd unresolvable '$RAWCWD'; fail-open allow"; exit 0; }
[ -n "$CWD" ] || { log "WARN cwd unresolvable '$RAWCWD'; fail-open allow"; exit 0; }

MP=$(marker_path_for "$CWD") || { log "WARN cannot compute marker path for '$CWD'; fail-open allow"; exit 0; }

if [ ! -f "$MP" ]; then
  log "$CWD phase=none decision=allow"
  exit 0
fi

PHASE=$(tr -d ' \t\r\n' < "$MP" 2>/dev/null) || { log "WARN malformed phase (unreadable) at $MP; fail-open allow"; exit 0; }
if ! valid_phase "$PHASE"; then
  log "WARN malformed phase '$PHASE' at $MP; fail-open allow"
  exit 0
fi

CEIL=$(ceiling_of_phase "$PHASE")

# write / full permit everything: allow without touching the registry (keeps the
# common working-phase path free of subprocess cost).
if [ "$CEIL" -ge 2 ]; then
  log "$CWD phase=$PHASE decision=allow (ceiling permits all)"
  exit 0
fi

# Resolve the class command (C1's check-tool-risk), overridable for the self-test.
CLASS_CMD="${WORKFLOW_PHASE_CLASS_CMD:-}"
if [ -z "$CLASS_CMD" ]; then
  HD=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd) || { log "WARN cannot resolve hook dir; fail-open allow"; exit 0; }
  CLASS_CMD="$HD/../bin/check-tool-risk"
fi

# The registry key set (known first-party tools). Any failure -> fail-open. This
# is where an unmerged C1 (no check-tool-risk on main) lands: the command is not
# resolvable, so we log and allow.
JSON=$("$CLASS_CMD" --json 2>/dev/null) || { log "WARN check-tool-risk unresolvable/errored ($CLASS_CMD); fail-open allow"; exit 0; }
[ -n "$JSON" ] || { log "WARN check-tool-risk produced no output ($CLASS_CMD); fail-open allow"; exit 0; }
KEYS=$(printf '%s' "$JSON" | jq -r 'keys[]' 2>/dev/null) || { log "WARN cannot parse check-tool-risk --json; fail-open allow"; exit 0; }
[ -n "$KEYS" ] || { log "WARN check-tool-risk --json had no keys; fail-open allow"; exit 0; }

# Most-restrictive matched tool wins (MAX rank over every known tool referenced,
# word-boundary matched in the command).
MAXRANK=-1
MAXTOOL=""
MAXCLASS=""
# Disable pathname globbing for the word-split over $KEYS: we want word-splitting
# on IFS, NOT for a (hypothetical future) key containing *, ?, or [ to glob
# against the cwd. Restored immediately after.
set -f
for tool in $KEYS; do
  if printf '%s' "$CMD" | grep -Fqw -- "$tool"; then
    cls=$("$CLASS_CMD" --class-of "$tool" 2>/dev/null) || cls="destructive"
    [ -n "$cls" ] || cls="destructive"
    r=$(rank_of_class "$cls")
    if [ "$r" -gt "$MAXRANK" ]; then
      MAXRANK=$r; MAXTOOL=$tool; MAXCLASS=$cls
    fi
  fi
done
set +f

# No known registry tool referenced -> ALLOW (keeps ordinary Bash denial-free).
if [ "$MAXRANK" -lt 0 ]; then
  log "$CWD phase=$PHASE tool=none decision=allow (no registry tool referenced)"
  exit 0
fi

if [ "$MAXRANK" -gt "$CEIL" ]; then
  log "$CWD phase=$PHASE tool=$MAXTOOL class=$MAXCLASS decision=deny"
  reason="workflow-phase gate: you are in the '$PHASE' phase, which forbids '$MAXCLASS' tools; this command references '$MAXTOOL' (class $MAXCLASS). Fix: if this step is intended, raise the phase for this directory — run \`ai/hooks/workflow-phase-guard.sh --set write\` (or \`--set full\`), or \`--clear\` to drop phase gating entirely, then re-run the command. If it was NOT intended, do not run it."
  jq -cn --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
    2>/dev/null || { log "WARN jq could not encode deny; fail-open allow"; exit 0; }
  exit 0
fi

log "$CWD phase=$PHASE tool=$MAXTOOL class=$MAXCLASS decision=allow"
exit 0
