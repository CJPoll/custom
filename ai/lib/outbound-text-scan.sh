# shellcheck shell=bash
#
# outbound-text-scan.sh — the forge-neutral half of the outbound scan that
# gh-athena (ai/lib/gh-outbound-scan.sh, DND-699) and glab-athena
# (ai/lib/glab-outbound-scan.sh, DND-1938) run on text bound for a PUBLIC
# repository or project. Sourced, never run.
#
# One set of rules for both forges. Each forge guard parses its own CLI's argv
# and decides whether the target is public; everything after that lives here:
# how a field reaches the scanner (a private copy, never argv), and what each
# scanner outcome means.
#
#   CLEAN / WAIVED - NOT SCANNED   the write goes ahead (the scanner's line is
#                                  shown on stderr)
#   HITS                           REFUSED, exit 1: labels and locations only
#   COULD NOT MEASURE              REFUSED, exit 3, except where the overlay is
#                                  ABSENT and this machine is not marked as one
#                                  that holds it (no outbound pre-push hook in
#                                  the harness checkout's common git dir). There
#                                  the write goes ahead, and a WARNING says the
#                                  text went out UNSCANNED. The overlay is
#                                  optional (contract -> Discovery); the
#                                  installed hook is the mark of a machine that
#                                  must measure.
#   exit 1 without HITS, other     REFUSED, exit 3: a scanner failure is never
#                                  read as a result
#
# The caller sets:
#   OTS_TOOL   the wrapper's name, the prefix of every line (gh-athena)
#   OTS_WHAT   the command being judged, for messages ("pr create")
#   OTS_DEST   what a public target is called ("repository", "project")
#   FCI_CFG_DIR  the wrapper's private config dir (ai/lib/forge-cli-isolation.sh);
#              the private copies go in its outbound-scan/ subdirectory.
#
# Test seam: none of its own. ai/test/gh-athena-outbound/self-test.sh and
# ai/test/glab-athena-outbound/self-test.sh drive the real wrappers.

OTS_BIN_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin"
OTS_TOOL="${OTS_TOOL:-outbound-scan}"
OTS_WHAT="${OTS_WHAT:-write}"
OTS_DEST="${OTS_DEST:-repository}"
OTS_COPY=""

# ots_refuse <exit code> <message with its Fix:> : prints and exits.
ots_refuse() {
  local rc="$1"; shift
  printf '%s: REFUSED: %s\n' "$OTS_TOOL" "$*" >&2
  exit "$rc"
}

# ots_machine_marked : 0 when the harness checkout holding this library has the
# outbound pre-push hook installed in its common git dir.
#
# Three outcomes, never two: 0 marked, 1 not marked (the hook path resolved
# and holds no outbound hook), 2 could not determine (git could not resolve
# the hook path, or the hook exists but cannot be read). The caller treats 2
# as "must measure": a failed lookup never reads as "not marked". The hook
# path honours core.hooksPath (git rev-parse --git-path).
ots_machine_marked() {
  local hook
  hook="$(git -C "$OTS_BIN_DIR" rev-parse --path-format=absolute --git-path hooks/pre-push 2>/dev/null)" || return 2
  [ -n "$hook" ] || return 2
  [ -e "$hook" ] || return 1
  [ -r "$hook" ] || return 2
  if grep -q -e outbound-scan -e outbound-pre-push "$hook" 2>/dev/null; then return 0; fi
  return 1
}

# ots_scan <label> <file> : run the scanner on one field; handles the outcome.
ots_scan() {
  local label="$1" file="$2" out rc=0
  out="$("$OTS_BIN_DIR/outbound-scan" --text "$file" --label "$label" 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed "s/^/$OTS_TOOL: /" >&2
  case "$rc" in
    0) return 0 ;;
    1)
      # Exit 1 is HITS only when the scanner says so; a crash (a Ruby
      # exception is also exit 1) is a scanner failure, never read as a result.
      case "$out" in
        *"outbound-scan: HITS mode="*) ;;
        *) ots_refuse 3 "the outbound scanner exited 1 on the $label without reporting HITS (a crash, output above). Fix: run \`$OTS_BIN_DIR/outbound-scan --help\` and report the defect." ;;
      esac
      ots_refuse 1 "the $label of this $OTS_WHAT to a PUBLIC $OTS_DEST carries work-domain values (locations and labels above). Fix: remove them from the $label, or read them from the private overlay instead of pasting them (ai/contracts/athena-private-overlay.md -> Consumer obligation), then retry." ;;
    3)
      local st=0
      "$OTS_BIN_DIR/private-overlay" status >/dev/null 2>&1 || st=$?
      local marked=0
      ots_machine_marked || marked=$?
      if [ "$st" = 3 ] && [ "$marked" = 1 ]; then
        printf '%s: WARNING: the %s of this %s went out UNSCANNED: the private overlay is ABSENT and this machine is not marked as one that holds it (no outbound pre-push hook installed). This is not a clean result. Fix: none needed on a machine without the overlay; on one that should hold it, the owner creates it with scripts/setup-private-overlay --init and installs the hook with scripts/setup-private-overlay --install.\n' "$OTS_TOOL" "$label" "$OTS_WHAT" >&2
        return 0
      fi
      ots_refuse 3 "the outbound scan of the $label could not measure (above), and this machine must measure. Fix: the Fix: line above names the problem; correct it and retry." ;;
    *) ots_refuse 3 "the outbound scanner failed (exit $rc) on the $label. Fix: run \`$OTS_BIN_DIR/outbound-scan --help\` and correct the call; report the defect if the call was right." ;;
  esac
}

# ots_dir : echoes the private directory the copies go in, creating it.
ots_dir() {
  [ -n "${FCI_CFG_DIR:-}" ] || ots_refuse 3 "the private config dir (FCI_CFG_DIR) is unset, so the outbound scan has nowhere to copy the text. Fix: run $OTS_TOOL as a whole (it sets the dir up before this guard); report a defect if it did."
  local dir="$FCI_CFG_DIR/outbound-scan"
  mkdir -p "$dir" || ots_refuse 3 "could not create $dir for the outbound scan. Fix: make \$TMPDIR writable and retry."
  printf '%s\n' "$dir"
}

# ots_scan_text <label> <noun> <key> <text> : writes <text> to a private file
# named <key> and scans it. <noun> names the field in a refusal ("body").
ots_scan_text() {
  local label="$1" noun="$2" key="$3" text="$4" dir f
  dir="$(ots_dir)" || exit 3
  f="$dir/$key"
  printf '%s\n' "$text" > "$f" || ots_refuse 3 "could not write the $noun to $f for the outbound scan. Fix: make \$TMPDIR writable and retry."
  ots_scan "$label" "$f"
}

# ots_copy_scan <label> <noun> <flag> <key> <path or -> : copies the file (or
# stdin, for `-`) once into a private file named <key>, sets OTS_COPY to it,
# and scans the copy. The caller hands the CLI OTS_COPY in place of the
# original: a pipe (-F <(...), /dev/fd/N, a FIFO, stdin) can be read only
# once, and a regular file can change between the scan and the CLI's own read.
# <flag> is the option the caller should pass instead, for a Fix:.
ots_copy_scan() {
  ots_copy "$2" "$3" "$4" "$5"
  ots_scan "$1" "$OTS_COPY"
}

# ots_copy <noun> <flag> <key> <path or -> : the copy half of ots_copy_scan,
# for a caller that must read the text before it decides to scan (a GraphQL
# query, read once from the copy rather than twice from a pipe).
ots_copy() {
  local noun="$1" flag="$2" key="$3" src="$4" dir f
  dir="$(ots_dir)" || exit 3
  f="$dir/$key"
  if [ "$src" = "-" ]; then
    cat > "$f" || ots_refuse 3 "could not read the $noun from stdin. Fix: pass $flag <path> instead."
  else
    [ -r "$src" ] || ots_refuse 3 "the $noun file $src is not readable, so it cannot be scanned. Fix: pass a readable $flag."
    cat -- "$src" > "$f" || ots_refuse 3 "could not copy the $noun file $src for the outbound scan. Fix: pass a readable regular file and retry."
  fi
  OTS_COPY="$f"
  return 0
}
