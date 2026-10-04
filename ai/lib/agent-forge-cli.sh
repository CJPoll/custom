# shellcheck shell=bash
# agent-forge-cli.sh — the agent PATH `gh` and `glab` wrappers (DND-1803).
# Sourced by ai/agent-bin/gh and ai/agent-bin/glab, which set AFC_TOOL (gh or
# glab) and AFC_SELF (their own path, $0) and call `afc_main "$@"`.
#
# WHERE THEY RUN. ai/agent-bin/ goes first on PATH only in agent sessions
# (ai/agent-env/session-env.sh, DND-775/DND-1080). The owner's terminal never
# puts it there. A plain `gh` / `glab` in an agent session, typed or inside a
# script, reaches this file before the real CLI.
#
# WHY. ai/hooks/forge-identity-guard.sh reads the Bash command TEXT, so a
# `gh pr create` inside a script run as `bash <script>` was never judged and
# ran as the machine owner. This judges the real argv of the process.
#
# HOW IT DECIDES:
#   1. `--help` alone: the real CLI's help, then this wrapper's note; exit 0.
#   2. The real CLI: the first <tool> on PATH AFTER this wrapper's own entry
#      that is not this wrapper (`test -ef`) and not a wrapper already passed
#      through (ATHENA_AGENT_<TOOL>_SEEN), as ai/agent-bin/git finds git; with
#      no entry of its own on PATH, or none after it, the first other <tool>
#      on PATH. None: exit 127 with a Fix:.
#   3. ROUTED: the call comes from the Athena wrapper, which runs the CLI as a
#      child with the owner's login out of reach (ai/lib/forge-cli-isolation.sh,
#      fci_isolate): the config dir variable (GH_CONFIG_DIR / GLAB_CONFIG_DIR)
#      names a directory this user owns, mode 0700, not a symlink, whose name
#      is fci_isolate's template (gh-athena-cfg.XXXXXXXX /
#      glab-athena-cfg.XXXXXXXX); the token variable (GH_TOKEN / GITLAB_TOKEN)
#      is one token; the host variable is github.com / gitlab.com; and, for
#      gh, the dir holds no hosts.yml. Then the CLI cannot read the owner's
#      stored login, and its identity is the token. Routed: exec the real CLI.
#   4. Otherwise the argv is judged by ai/lib/forge-write-class.awk, the
#      classifier ai/hooks/forge-identity-guard.sh uses too. A read: exec the
#      real CLI. A write: REFUSED, exit 1, with a Fix: naming the Athena route.
#      A classifier that cannot run: REFUSED (deny by default).
#
# RESIDUAL (it is not a sandbox). Defeated by: a caller that builds the routed
# marker by hand (a mktemp dir with the template name, GH_TOKEN set to the
# owner's token read out with `gh auth token`), which is deliberate; the real
# CLI run by absolute path, `command -p`, or a PATH that skips ai/agent-bin; a
# gh/glab alias or extension (an unknown group reads as a read, as in the hook);
# a non-CLI client (curl with the owner's token). Known false denies are the
# classifier's (its header), plus a GraphQL query read from a file, and two
# more: a push the CLI itself runs on a routed call (`gh-athena repo create
# --push`, `glab-athena mr create --push`) is judged by the git wrapper and
# refused, so push first with `<route> git push`; and `glab-athena refresh`,
# which mints with the OWNER's plain glab on purpose, is refused here, so it
# runs only from the owner's own terminal (it is owner-gated anyway).
#
# A refusal names the command's group and verb, never the rest of its argv:
# an argument can carry a secret (`gh secret set X --body …`).

AFC_ESC='If the Athena wrapper itself fails, do not work around this; escalate to your admiral with the command and the error (athena:github -> "When a forge write can'"'"'t be done as Athena").'

afc_refuse() {
  printf '%s (agent wrapper): REFUSED %s\n' "$AFC_TOOL" "$1" >&2
  exit "${2:-1}"
}

# afc_seen <path> : the path is a wrapper already passed through.
afc_seen() {
  local var="ATHENA_AGENT_${AFC_TOOL^^}_SEEN" w
  local IFS=:
  for w in ${!var:-}; do
    [ -n "$w" ] && [ "$1" -ef "$w" ] && return 0
  done
  return 1
}

# afc_resolve_real : sets AFC_REAL, and records this wrapper (and a fallback)
# in ATHENA_AGENT_<TOOL>_SEEN; returns 1 when there is no real CLI.
afc_resolve_real() {
  local var="ATHENA_AGENT_${AFC_TOOL^^}_SEEN" d c before="" past="" fallback=""
  local -a dirs=()
  AFC_REAL=""
  IFS=: read -r -a dirs <<<"$PATH:"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || d=.
    c="$d/$AFC_TOOL"
    [ -f "$c" ] && [ -x "$c" ] || continue
    if [ "$c" -ef "$AFC_SELF" ]; then past=1; continue; fi
    afc_seen "$c" && continue
    if [ -n "$past" ]; then AFC_REAL="$c"; break; fi
    [ -n "$before" ] || before="$c"
  done
  if [ -z "$AFC_REAL" ] && [ -n "$before" ]; then AFC_REAL="$before"; fallback="$before"; fi
  [ -n "$AFC_REAL" ] || return 1
  printf -v "$var" '%s' "${!var:+${!var}:}$AFC_SELF${fallback:+:$fallback}"
  export "${var?}"
  return 0
}

afc_help() {
  # The real help only: no update check, no network.
  if afc_resolve_real; then GLAB_CHECK_UPDATE=false GH_NO_UPDATE_NOTIFIER=1 "$AFC_REAL" --help 2>/dev/null; fi
  local route=gh-athena
  [ "$AFC_TOOL" = glab ] && route=glab-athena
  printf '\n%s (agent wrapper): ai/agent-bin/%s, in front of the real %s in agent sessions (DND-1803).\n' "$AFC_TOOL" "$AFC_TOOL" "$AFC_TOOL"
  printf '  Reads pass through to %s. A forge write not made through ~/dev/custom/ai/bin/%s is refused with a Fix:.\n' "${AFC_REAL:-the real $AFC_TOOL (none found on PATH)}" "$route"
  printf '  The rules and residuals: ai/lib/agent-forge-cli.sh.\n'
}

# afc_routed : 0 when the call comes from the Athena wrapper (rule 3).
afc_routed() {
  local tok dir host want base mode
  case "$AFC_TOOL" in
    gh) tok="${GH_TOKEN:-}"; dir="${GH_CONFIG_DIR:-}"; host="${GH_HOST:-}"; want=github.com ;;
    *) tok="${GITLAB_TOKEN:-}"; dir="${GLAB_CONFIG_DIR:-}"; host="${GITLAB_HOST:-}"; want=gitlab.com ;;
  esac
  [ "$host" = "$want" ] || return 1
  case "$tok" in '' | *[[:space:]]* | *[[:cntrl:]]*) return 1 ;; esac
  [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  base="${dir%/}"; base="${base##*/}"
  case "$base" in "$AFC_TOOL-athena-cfg."????????) ;; *) return 1 ;; esac
  mode="$(stat -c %a "$dir" 2>/dev/null)" || return 1
  [ "$mode" = 700 ] || return 1
  [ "$AFC_TOOL" = gh ] && [ -e "$dir/hosts.yml" ] && return 1
  return 0
}

# afc_classify <argv...> : sets AFC_VERDICT to READ, or to the classifier's
# write line (<cli> TAB <group> TAB <verb> TAB <reads>). Refuses when the
# classifier cannot run.
afc_classify() {
  local lib text out rc=0
  lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-write-class.awk"
  text="$(cat "$lib" 2>/dev/null)" && [ -n "$text" ] \
    || afc_refuse "\`$AFC_TOOL …\`: the classifier $lib cannot be read, so whether this is a forge write is unknown. Fix: restore ai/lib/forge-write-class.awk in the checkout that holds ai/agent-bin; meanwhile run the command through ~/dev/custom/ai/bin/$AFC_TOOL-athena. $AFC_ESC"
  # Every literal `$` is masked as the hook masks single-quoted text: the argv
  # is already expanded, so a `$` in a GraphQL query is text, not expansion.
  out="$(awk "$text"'
    BEGIN {
      fwc_init()
      n = ARGC - 1
      for (i = 1; i <= n; i++) { t[i] = ARGV[i]; gsub(/[$]/, "\034", t[i]); ARGV[i] = "" }
      MUT = 0
      for (i = 2; i <= n; i++) if (tolower(t[i]) ~ /(^|[^a-z0-9_])mutation([^a-z0-9_]|$)/) MUT = 1
      judge(1)
      print "READ"
      exit
    }' "$AFC_TOOL" "$@" 2>/dev/null)" || rc=$?
  if [ "$rc" != 0 ] || { [ "$out" != READ ] && [[ "$out" != "$AFC_TOOL"$'\t'* ]]; }; then
    afc_refuse "\`$AFC_TOOL …\`: the classifier failed (exit $rc), so whether this is a forge write is unknown. Fix: run the command through ~/dev/custom/ai/bin/$AFC_TOOL-athena, and report the classifier failure to your admiral."
  fi
  AFC_VERDICT="$out"
}

afc_main() {
  local who route grp verb reads
  if [ "$#" -eq 1 ] && [ "$1" = --help ]; then afc_help; exit 0; fi
  if ! afc_resolve_real; then
    afc_refuse "\`$AFC_TOOL …\`: no real $AFC_TOOL on PATH after the wrapper $AFC_SELF (PATH=$PATH). Fix: put the directory holding the real $AFC_TOOL on PATH after ai/agent-bin; a shim that execs this wrapper must have a real $AFC_TOOL after the wrapper on PATH." 127
  fi
  if afc_routed; then exec "$AFC_REAL" "$@"; fi
  afc_classify "$@"
  [ "$AFC_VERDICT" = READ ] && exec "$AFC_REAL" "$@"
  IFS=$'\t' read -r _ grp verb reads <<<"$AFC_VERDICT"
  if [ "$AFC_TOOL" = gh ]; then who='GitHub records it as the machine owner, not athena-harness[bot]'; route=gh-athena
  else who='GitLab records it as the machine owner, not athena-amby'; route=glab-athena; fi
  if [ "$grp" = api ]; then
    afc_refuse "\`$AFC_TOOL api …\`: a plain \`$AFC_TOOL api\` call that WRITES (a method other than GET/HEAD, a field or --input with no -X GET, a method-override header, or a GraphQL mutation or a query read from a file). $who (DND-1803). Fix: run the same call through the Athena route, \`~/dev/custom/ai/bin/$route api …\` (check it with \`~/dev/custom/ai/bin/forge-preflight\` if it fails); to only READ, pass \`-X GET\`. $AFC_ESC"
  fi
  if [ "$grp" = alias ]; then
    afc_refuse "\`$AFC_TOOL alias $verb …\`: an alias can run a forge write under a name the classifier does not recognise, as the machine owner (DND-1179, DND-1803). Fix: do not define aliases; run the command itself, and run a write through \`~/dev/custom/ai/bin/$route\`. $AFC_ESC"
  fi
  if [ "$AFC_TOOL $grp $verb" = "gh pr merge" ]; then
    afc_refuse "\`gh pr merge …\`: a merge on plain gh is stamped to the machine owner AND skips the pinned-head, all-green merge guard (DND-609, DND-1803). Fix: merge through the one guarded path: run \`~/dev/custom/ai/skills/athena:merge-boarding/scripts/integration-gate\` from the PR's worktree, then \`~/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr <n> --head <sha>\` with the SHA its INTEGRATION OK line names (athena:merge-boarding -> \"Landing onto a moving main\"). $AFC_ESC"
  fi
  case "$AFC_TOOL $grp $verb" in
    "glab mr merge" | "glab mr accept")
      afc_refuse "\`glab mr $verb …\`: a merge on plain glab is stamped to the machine owner AND skips the pinned-head, passed-pipeline merge guard (DND-742, DND-1803). Fix: board the merge train through the Athena route, \`~/dev/custom/ai/bin/glab-athena api -X POST \"projects/:id/merge_trains/merge_requests/<iid>\" -f sha=<head sha>\`, or with no train \`~/dev/custom/ai/bin/glab-athena mr merge <iid> --sha <head sha> --auto-merge=false --yes\`, once the head pipeline passed on that head. $AFC_ESC" ;;
  esac
  reads="${reads#|}"; reads="${reads%|}"; reads="${reads//|/, }"
  [ -n "$reads" ] || reads='none; it runs an agent or a server that can write as the owner'
  afc_refuse "\`$AFC_TOOL $grp $verb …\`: a forge WRITE ($AFC_TOOL $grp reads are only: $reads). $who (DND-1803). Fix: run the same command through the Athena route, \`~/dev/custom/ai/bin/$route $grp $verb …\` (check it with \`~/dev/custom/ai/bin/forge-preflight\` if it fails). Reads may stay on plain $AFC_TOOL. $AFC_ESC"
}
