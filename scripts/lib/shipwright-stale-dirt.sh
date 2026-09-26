# shellcheck shell=bash
#
# shipwright-stale-dirt.sh — classify the main checkout's dirt as LIVE or STALE,
# and decide when a stale streak escalates (DND-692). Sourced by
# scripts/athena-shipwright-run.sh; no side effects on load.
#
# Why this exists. The runner yields a tick whenever the main checkout is dirty
# (section 4, "yield to a live editor"). The yield is exit 0 and deliberately
# never feeds the wedge counter. Measured 2026-09-22..25: 84 consecutive hourly
# skips on inert leftovers (an abandoned node_modules, an erl_crash.dump), days
# old. No alert, no ticket, no journal entry: "yielded to a live editor" and
# "blocked forever by leftovers" produced the same exit 0. This file tells them
# apart. It never touches the dirt: what to do with someone else's files is the
# owner's call (commit, gitignore, remove).
#
# The model:
#   signature  sha256 of the sorted dirty path list (NUL-separated, `git status
#              --porcelain -z -uall`, ai-artifacts/ excluded) plus the newest
#              mtime among them. Any edit, addition or removal changes it.
#   newest     the newest mtime of the dirty paths (lstat, so a symlink is aged
#              as itself). A path that no longer exists (a deleted tracked file)
#              is aged by its nearest existing ancestor directory, whose mtime a
#              deletion updates. A path is never skipped for lacking an age:
#              skipping would make a deletion-only tree look ageless.
#   STALE      now - newest >= the age threshold. Otherwise LIVE.
#   streak     consecutive STALE skips on one unchanged signature. A LIVE skip
#              on the same signature neither counts nor resets; a new signature
#              restarts at 0; a clean tree drops the state entirely.
#   escalate   streak >= N and this signature not yet alerted.

# sd_dirty_paths <checkout> — NUL-separated dirty paths, ai-artifacts/ excluded.
# Rename/copy entries contribute BOTH paths (the -z format puts the origin in a
# separate field). Exit non-zero when git cannot measure: a failed scan must not
# read as a clean tree.
sd_dirty_paths() {
  local checkout="$1" raw entry xy path rest
  raw="$(mktemp)" || return 1
  # To a file first, so git's own exit status is observed (a pipeline would
  # report the reader's).
  if ! git -C "${checkout}" status --porcelain=v1 -z -uall >"${raw}" 2>/dev/null; then
    rm -f "${raw}"; return 1
  fi
  while IFS= read -r -d '' entry; do
    xy="${entry:0:2}"
    path="${entry:3}"
    case "${xy}" in
      R*|C*) IFS= read -r -d '' rest || rest=""
             sd__emit "${path}"; [ -n "${rest}" ] && sd__emit "${rest}" ;;
      *)     sd__emit "${path}" ;;
    esac
  done <"${raw}"
  rm -f "${raw}"
}

sd__emit() {
  case "$1" in ai-artifacts/*) return 0 ;; esac
  printf '%s\0' "$1"
}

# sd_mtime_of <checkout> <path> — epoch mtime of the path, or of its nearest
# existing ancestor when the path is gone. Always prints a number: the repo
# root exists, so the walk ends there at the latest.
sd_mtime_of() {
  local checkout="$1" p="$2"
  while :; do
    if [ -e "${checkout}/${p}" ] || [ -L "${checkout}/${p}" ]; then
      stat -c %Y -- "${checkout}/${p}" 2>/dev/null && return 0
    fi
    case "${p}" in
      */*) p="${p%/*}" ;;
      *)   stat -c %Y -- "${checkout}" 2>/dev/null; return ;;
    esac
  done
}

# sd_measure <checkout> — prints three lines: signature, newest mtime, path
# count. Exit non-zero when nothing could be measured.
sd_measure() {
  local checkout="$1" raw list present p newest=0 m count=0 rc=0
  raw="$(mktemp)" && list="$(mktemp)" && present="$(mktemp)" || return 1
  sd_dirty_paths "${checkout}" >"${raw}" && sort -z "${raw}" >"${list}" || rc=1
  if [ "${rc}" -eq 0 ]; then
    # Existing paths are aged by one xargs-batched stat (a stray node_modules
    # is thousands of files); a gone path walks up to its nearest ancestor.
    while IFS= read -r -d '' p; do
      count=$(( count + 1 ))
      if [ -e "${checkout}/${p}" ] || [ -L "${checkout}/${p}" ]; then
        printf '%s\0' "${p}" >>"${present}"
      else
        m="$(sd_mtime_of "${checkout}" "${p}")"
        case "${m}" in ''|*[!0-9]*) rc=1; break ;; esac
        [ "${m}" -gt "${newest}" ] && newest="${m}"
      fi
    done <"${list}"
  fi
  if [ "${rc}" -eq 0 ] && [ -s "${present}" ]; then
    # A path that vanished between the scan and the stat fails the measure:
    # that is a live change, and an unmeasured tree must never read as stale.
    m="$(set -o pipefail; cd -- "${checkout}" && xargs -0 stat -c %Y -- <"${present}" | sort -n | tail -n 1)" || rc=1
    case "${m}" in ''|*[!0-9]*) rc=1 ;; *) [ "${m}" -gt "${newest}" ] && newest="${m}" ;; esac
  fi
  [ "${count}" -gt 0 ] || rc=1
  if [ "${rc}" -eq 0 ]; then
    printf '%s\n' "$({ cat "${list}"; printf 'newest=%s' "${newest}"; } | sha256sum | cut -d' ' -f1)"
    printf '%s\n%s\n' "${newest}" "${count}"
  fi
  rm -f "${raw}" "${list}" "${present}"
  return "${rc}"
}

# sd_state_get <state-file> <key> — a value from the key=value state file.
sd_state_get() {
  [ -r "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# sd_next_streak <prev-sig> <prev-streak> <sig> <stale 0|1> — the new streak.
# Pure: the whole counting rule in one place.
sd_next_streak() {
  local prev_sig="$1" prev="$2" sig="$3" stale="$4"
  case "${prev}" in ''|*[!0-9]*) prev=0 ;; esac
  [ "${prev_sig}" = "${sig}" ] || prev=0
  if [ "${stale}" -eq 1 ]; then printf '%s\n' "$(( prev + 1 ))"; else printf '%s\n' "${prev}"; fi
}

# sd_display_paths <checkout> [max] — the dirty paths with untracked
# directories collapsed (e.g. node_modules/; -unormal pins that against the
# user's status.showUntrackedFiles), control
# characters stripped, capped at max lines with an "and N more" tail.
sd_display_paths() {
  local checkout="$1" max="${2:-20}" all n
  all="$(git -C "${checkout}" -c core.quotePath=false status --porcelain -unormal 2>/dev/null \
    | cut -c4- | grep -v '^ai-artifacts/' | LC_ALL=C tr -d '\000-\010\013-\037\177' || true)"
  n="$(printf '%s\n' "${all}" | grep -c . || true)"
  printf '%s\n' "${all}" | head -n "${max}"
  if [ "${n}" -gt "${max}" ]; then printf '... and %s more\n' "$(( n - max ))"; fi
}
