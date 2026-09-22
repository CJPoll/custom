#!/usr/bin/env bash
# resolve-project.sh -- print THIS session's inbox project NAME (the registry
# entry filename minus .json), using ONLY athena:inbox's own resolver.
#
#   resolve-project.sh        the project name + exit 0, or an exit code below
#   resolve-project.sh -h     this header
#
# There is NO second copy of the cwd -> repo -> entry matching here. Identity is
# `inbox_repo_key`, the candidate records are `fs_registry_records`, and the
# authoritative match is `descriptor_select` -- the same three functions the
# count path uses. This file only maps the winning entry back to its FILENAME,
# which no existing command exposes and which the shim needs for the meta
# `project` attribute and the ATHENA_INBOX_EXPECT_PROJECT assertion.
#
# EXIT CODES (load-bearing, like the rest of the skill):
#   0  a single entry owns this repo; its project name is on stdout
#   1  no entry owns this repo (not opted in) -- silent, not a fault
#   2  ambiguous ownership (two entries claim this repo) -- refused, by count
#   3  could-not-tell the repo identity (no git, cwd gone, dubious ownership)
#
# A missing name is NEVER printed as an empty success: 1/2/3 are distinct so a
# caller cannot read "could not tell" as "not opted in".
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(dirname "${HERE}")/lib"

case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | grep -v '^set -uo pipefail$' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') : ;;
  *)
    printf 'resolve-project.sh: unexpected argument "%s"\n' "$1" >&2
    printf '  Fix: run it with no arguments (it resolves from the cwd), or -h for help.\n' >&2
    exit 3
    ;;
esac

# shellcheck source=/dev/null
. "${LIB}/err.sh"
# shellcheck source=/dev/null
. "${LIB}/names.sh"
# shellcheck source=/dev/null
. "${LIB}/descriptor.sh"
# shellcheck source=/dev/null
. "${LIB}/fs.sh"
# shellcheck source=/dev/null
. "${LIB}/inbox.sh"

# Identity, via the resolver's own classifier. Non-zero here is could-not-tell.
key="$(inbox_repo_key ".")" || exit 3

# The candidate records: "<canonicalised one-line json>\t<file>" per entry.
records="$(fs_registry_records)" || exit 3

# The authoritative match. descriptor_select returns the winning entry's json
# (exit 0), refuses on ambiguity (exit 2), or is silent on no-match (exit 1).
winner="$(printf '%s\n' "${records}" | descriptor_select "${key}")"; rc=$?
[ "${rc}" -eq 2 ] && exit 2
[ "${rc}" -eq 0 ] || exit 1

# Map the winning json back to its filename. descriptor_select returns the same
# canonicalised json fs_registry_records printed, so an exact first-field match
# is unambiguous. json is one-line `jq -c` output and cannot contain a tab.
file="$(printf '%s\n' "${records}" | awk -F'\t' -v w="${winner}" '$1==w {print $2; exit}')"
[ -n "${file}" ] || exit 1

base="${file##*/}"
printf '%s\n' "${base%.json}"
exit 0
