# shellcheck shell=bash
#
# gh-outbound-scan.sh — the outbound scan behind `gh-athena` PR and issue
# writes (DND-699). Sourced by ai/bin/gh-athena, never run.
#
# The second publish path. A pre-push hook covers what reaches a public repo
# through git; a PR or issue title and body reach it through the API. Before gh
# runs one of these writes against a PUBLIC repository:
#
#   pr create | pr edit | pr comment | pr review | issue create | issue edit | issue comment
#
# the guard scans --title/-t, --body/-b and --body-file/-F (a `-` body file is
# read from stdin into a private file, scanned, and handed to gh in its place)
# with `ai/bin/outbound-scan --text`, and:
#
#   CLEAN / WAIVED - NOT SCANNED   gh runs (the scanner's line is shown on stderr)
#   HITS                           REFUSED, exit 1: labels and locations only
#   COULD NOT MEASURE              REFUSED, exit 3 — except where the overlay is
#                                  ABSENT and this machine is not marked as one
#                                  that holds it (no outbound pre-push hook in
#                                  the harness checkout's common git dir). There
#                                  gh runs, and a WARNING says the text went out
#                                  UNSCANNED. The overlay is optional
#                                  (contract -> Discovery); the installed hook
#                                  is the mark of a machine that must measure.
#
# Target visibility: `gh repo view [<repo>] --json visibility`, as the App.
# PRIVATE and INTERNAL targets are not scanned. A visibility that cannot be
# read is scanned as PUBLIC (deny by default).
#
# Residuals, stated: `pr create --fill` (the body is commit messages, which the
# pre-push hook scans), an interactive editor or --web, `gh api` writes, other
# commands (release notes, gist), a value no pattern describes, and the waiver.
#
# Test seam: none of its own. ai/test/gh-athena-outbound/self-test.sh drives the
# real wrapper with a stub gh on PATH and GH_ATHENA_MERGE_DRY_RUN=1.

GOS_BIN_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin"

gos_refuse() {
  local rc="$1"; shift
  printf 'gh-athena: REFUSED: %s\n' "$*" >&2
  exit "$rc"
}

# gos_machine_marked : 0 when the harness checkout holding this wrapper has the
# outbound pre-push hook installed in its common git dir.
gos_machine_marked() {
  local common hook
  common="$(git -C "$GOS_BIN_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  hook="$common/hooks/pre-push"
  [ -f "$hook" ] && grep -q 'outbound-scan\|outbound-pre-push' "$hook" 2>/dev/null
}

# gos_scan <label> <file> : run the scanner on one field; handles the outcome.
gos_scan() {
  local label="$1" file="$2" out rc=0
  out="$("$GOS_BIN_DIR/outbound-scan" --text "$file" --label "$label" 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/gh-athena: /' >&2
  case "$rc" in
    0) return 0 ;;
    1) gos_refuse 1 "the $label of this $GOS_WHAT to a PUBLIC repository carries work-domain values (locations and labels above). Fix: remove them from the $label, or read them from the private overlay instead of pasting them (ai/contracts/athena-private-overlay.md -> Consumer obligation), then retry." ;;
    3)
      local st=0
      "$GOS_BIN_DIR/private-overlay" status >/dev/null 2>&1 || st=$?
      if [ "$st" = 3 ] && ! gos_machine_marked; then
        printf 'gh-athena: WARNING: the %s of this %s went out UNSCANNED: the private overlay is ABSENT and this machine is not marked as one that holds it (no outbound pre-push hook installed). This is not a clean result. Fix: none needed on a machine without the overlay; on one that should hold it, the owner creates it and installs the hook (DND-703).\n' "$label" "$GOS_WHAT" >&2
        return 0
      fi
      gos_refuse 3 "the outbound scan of the $label could not measure (above), and this machine must measure. Fix: the Fix: line above names the problem; correct it and retry, or set ATHENA_OUTBOUND_WAIVE=<reason> for a recorded waiver." ;;
    *) gos_refuse 3 "the outbound scanner failed (exit $rc) on the $label. Fix: run \`$GOS_BIN_DIR/outbound-scan --help\` and correct the call; report the defect if the call was right." ;;
  esac
}

# gos_guard <gh argv...> : sets GOS_ARGV to the argv gh must run (a `-` body
# file is replaced by the scanned private copy).
#
# Every spelling gh's flag parser accepts for the three fields is read, and
# every occurrence is scanned (not only the last): `--title X`, `--title=X`,
# `-t X`, `-tX`, and the same for --body/-b and --body-file/-F. A single-dash
# cluster that carries t, b, F or R after its first letter (`-dbX`, `-Bmain`
# with a t in it) could hide a field inside it, so it is REFUSED with a Fix
# rather than guessed at. Everything after `--` is positional.
gos_guard() {
  GOS_ARGV=("$@")
  local group="${1:-}" verb="${2:-}"
  case "$group $verb" in
    "pr create" | "pr edit" | "pr comment" | "pr review" | "issue create" | "issue edit" | "issue comment") ;;
    *) return 0 ;;
  esac
  GOS_WHAT="$group $verb"

  local i=2 n=$# a repo=""
  local -a argv=("$@") titles=() bodies=() bf_idx=() bf_pre=() bf_path=()
  while [ "$i" -lt "$n" ]; do
    a="${argv[$i]}"
    case "$a" in
      --) break ;;
      --title=*) titles+=("${a#--title=}") ;;
      --body=*) bodies+=("${a#--body=}") ;;
      --body-file=*) bf_idx+=("$i"); bf_pre+=("--body-file="); bf_path+=("${a#--body-file=}") ;;
      --repo=*) repo="${a#--repo=}" ;;
      -t | --title) i=$((i + 1)); titles+=("${argv[$i]:-}") ;;
      -b | --body) i=$((i + 1)); bodies+=("${argv[$i]:-}") ;;
      -F | --body-file) i=$((i + 1)); bf_idx+=("$i"); bf_pre+=(""); bf_path+=("${argv[$i]:-}") ;;
      -R | --repo) i=$((i + 1)); repo="${argv[$i]:-}" ;;
      -t?*) titles+=("${a#-t}") ;;
      -b?*) bodies+=("${a#-b}") ;;
      -F?*) bf_idx+=("$i"); bf_pre+=("-F"); bf_path+=("${a#-F}") ;;
      -R?*) repo="${a#-R}" ;;
      --*) ;;
      -?*)
        if [ "${#a}" -gt 2 ] && [[ "${a:2}" == *[tbFR]* ]]; then
          gos_refuse 3 "the short-flag cluster \`${a:0:2}…\` in this $GOS_WHAT may carry a title, body or repo the outbound scan cannot separate. Fix: write each short flag as its own word (\`-d -b <text>\`, \`-B <branch>\`), or use the long flags (--title, --body, --body-file, --repo)."
        fi ;;
    esac
    i=$((i + 1))
  done
  [ "$((${#titles[@]} + ${#bodies[@]} + ${#bf_path[@]}))" -gt 0 ] || return 0

  local vis
  if [ -n "$repo" ]; then
    vis="$(gh repo view "$repo" --json visibility --jq .visibility 2>/dev/null)" || vis=""
  else
    vis="$(gh repo view --json visibility --jq .visibility 2>/dev/null)" || vis=""
  fi
  case "$vis" in
    PRIVATE | INTERNAL) return 0 ;;
    PUBLIC) ;;
    *) printf 'gh-athena: the target repository visibility could not be read; scanning as PUBLIC.\n' >&2 ;;
  esac

  local dir="${FCI_CFG_DIR:?gh-athena: outbound scan needs the private config dir}/outbound-scan"
  mkdir -p "$dir" || gos_refuse 3 "could not create $dir for the outbound scan. Fix: make \$TMPDIR writable and retry."
  local k f
  for k in "${!titles[@]}"; do
    f="$dir/title-$k"
    printf '%s\n' "${titles[$k]}" > "$f" || gos_refuse 3 "could not write the title to $f for the outbound scan. Fix: make \$TMPDIR writable and retry."
    gos_scan title "$f"
  done
  for k in "${!bodies[@]}"; do
    f="$dir/body-$k"
    printf '%s\n' "${bodies[$k]}" > "$f" || gos_refuse 3 "could not write the body to $f for the outbound scan. Fix: make \$TMPDIR writable and retry."
    gos_scan body "$f"
  done
  for k in "${!bf_path[@]}"; do
    f="${bf_path[$k]}"
    if [ "$f" = "-" ]; then
      f="$dir/body-stdin-$k"
      cat > "$f" || gos_refuse 3 "could not read the body from stdin. Fix: pass --body-file <path> instead."
      GOS_ARGV[${bf_idx[$k]}]="${bf_pre[$k]}$f"
    else
      [ -r "$f" ] || gos_refuse 3 "the body file $f is not readable, so it cannot be scanned. Fix: pass a readable --body-file."
    fi
    gos_scan body-file "$f"
  done
  return 0
}
