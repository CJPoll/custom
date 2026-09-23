#!/usr/bin/env bash
# Prune stale walt_ui git worktrees older than N days (default 7), by directory mtime.
#
#   ./prune-stale-walt-worktrees.sh            # DRY RUN — lists what would be deleted
#   ./prune-stale-walt-worktrees.sh --apply    # actually delete
#   DAYS=14 ./prune-stale-walt-worktrees.sh --apply
#
# Safety:
#   - Only ever touches worktrees under ~/.local/worktrees/walt_ui/ .
#   - NEVER touches the primary checkout (~/dev/walt_ui).
#   - Age = the worktree directory's own mtime, so anything a Captain touched in
#     the last N days (i.e. active work) is excluded automatically.
#   - Flags worktrees with UNCOMMITTED changes as "DIRTY" in the dry run so you
#     can spot work that would be lost before you --apply.
#   - Root-owned docker leftovers that a normal remove can't delete are collected
#     and removed with a single `sudo rm -rf` (prompts for your password once).
set -euo pipefail

REPO="${WALT_REPO:-$HOME/dev/walt_ui}"
WT_ROOT="$HOME/.local/worktrees/walt_ui"
DAYS="${DAYS:-7}"
APPLY=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --days=*) DAYS="${a#--days=}" ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

cd "$REPO"
now=$(date +%s)

# Collect worktree paths from git's own registry (authoritative).
mapfile -t ALL < <(git worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')

candidates=()
for wt in "${ALL[@]}"; do
  # scope: only the linked worktrees under the worktree root; never the primary.
  case "$wt" in "$WT_ROOT"/*) : ;; *) continue ;; esac
  [ -d "$wt" ] || { candidates+=("$wt"); continue; }   # dir already gone -> prunable
  # older than DAYS by directory mtime?
  if [ -n "$(find "$wt" -maxdepth 0 -mtime +"$DAYS" 2>/dev/null)" ]; then
    candidates+=("$wt")
  fi
done

echo "Threshold: older than ${DAYS} days.  Scope: ${WT_ROOT}/"
echo "Stale worktrees found: ${#candidates[@]} of ${#ALL[@]} total"
echo
for wt in "${candidates[@]}"; do
  if [ -d "$wt" ]; then
    age=$(( (now - $(stat -c %Y "$wt")) / 86400 ))
    br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
    dirty=""
    if grep -q . <<<"$(git -C "$wt" status --porcelain 2>/dev/null)"; then dirty="  ** DIRTY (uncommitted) **"; fi
    printf '  %4sd  %-52s  %s%s\n' "$age" "$br" "$wt" "$dirty"
  else
    printf '  gone   %-52s  %s\n' "(dir missing)" "$wt"
  fi
done

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "DRY RUN — nothing deleted. Re-run with --apply to remove the above."
  echo "Review any lines marked DIRTY first; --apply force-removes them too."
  exit 0
fi

echo
echo "Applying..."
needs_sudo=()
for wt in "${candidates[@]}"; do
  if git worktree remove --force "$wt" 2>/dev/null; then
    echo "removed:    $wt"
  elif [ -d "$wt" ] && rm -rf "$wt" 2>/dev/null; then
    echo "rm -rf:     $wt"
  elif [ ! -d "$wt" ]; then
    :   # already gone; prune will clear the registration
  else
    needs_sudo+=("$wt")
    echo "needs sudo: $wt"
  fi
done

if [ "${#needs_sudo[@]}" -gt 0 ]; then
  echo
  echo "Removing ${#needs_sudo[@]} root-owned leftover dir(s) with sudo (docker artifacts)..."
  sudo rm -rf "${needs_sudo[@]}"
fi

git worktree prune
echo
echo "Done. Worktrees remaining: $(git worktree list | wc -l)"
