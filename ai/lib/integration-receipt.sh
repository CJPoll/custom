# shellcheck shell=bash
#
# integration-receipt.sh -- the ONE implementation of integration-gate's
# receipt and gate-declaration rules (DND-969). Sourced, never run.
#
# Three callers share it so they cannot drift:
#   * integration-gate (ai/skills/athena:merge-boarding/scripts/) resolves the
#     repo's declared gate with ir_declared_gate_on and writes the receipt at
#     ir_receipt_path with schema $IR_SCHEMA.
#   * locked-merge (same directory) reads the receipt with ir_read_receipt under
#     its merge lock.
#   * gh-merge-guard.sh (ai/lib/, behind every `gh-athena pr merge`) asks
#     ir_declared_gate_on whether the PR's repo declares a gate on the base tip,
#     and if so reads the receipt with ir_read_receipt before any merge call.
#     Both readers accept a recorded base that is the tip or an ancestor of it
#     (DND-1463).
#
# The receipt: <git common dir>/integration-receipts/<head-sha>.json, written by
# integration-gate only on INTEGRATION OK (DND-965). The git common dir is the
# same for a main checkout and every linked worktree, so any checkout of the
# repo finds it.
#
# There is deliberately no flag, env var or marker here that skips a check
# (~/dev/custom/CLAUDE.md -> "A check's own bar must not live in the diff it is
# checking"). The owner override is integration-gate's --owner-approval, which
# the receipt records.

IR_SCHEMA="integration-receipt/1"

# A repo's gate is DECLARED by convention: the first of these paths that is a
# blob on the target commit (DND-479). Read out of git, never the working tree.
IR_DECLARED_GATES=( bin/prep-commit.sh ai/bin/harness-gate )

# ir_declared_gate_on <repo-dir> <commit-sha> : prints the declared gate path.
# Returns 0 when one is declared, 1 when the commit declares none, and 2 when
# the commit is not in <repo-dir>'s object store -- "could not look" must never
# read as "no gate" (~/dev/custom/ai/CLAUDE.md -> "A failed lookup must never
# look like an empty one").
ir_declared_gate_on() {
  local dir="$1" sha="$2" g
  git -C "$dir" cat-file -e "${sha}^{commit}" 2>/dev/null || return 2
  for g in "${IR_DECLARED_GATES[@]}"; do
    if [ "$(git -C "$dir" cat-file -t "${sha}:${g}" 2>/dev/null)" = "blob" ]; then
      printf '%s\n' "$g"; return 0
    fi
  done
  return 1
}

# ir_store <git-common-dir> / ir_receipt_path <git-common-dir> <head-sha>
ir_store() { printf '%s/integration-receipts' "$1"; }
ir_receipt_path() { printf '%s/%s.json' "$(ir_store "$1")" "$2"; }

# ir_read_receipt <git-common-dir> <head-sha> <tip-sha> : is there a usable
# pass for exactly <head-sha>, recorded against <tip-sha> or an ANCESTOR of it?
#
# DND-1463 (owner, 2026-10-01: "Let's soften that merge guard requirement."):
# the recorded base used to have to EQUAL the tip, so every merge that landed
# while a PR waited forced a full re-gate. Now a recorded base the tip descends
# from is accepted: the base moved on, nothing rewrote it. The head is still
# exact. A merge conflict between the head and the moved tip is refused by the
# forge (and by locked-merge before its merge call). What no gate ran is the
# head combined with the commits between the recorded base and the tip.
#
# Returns 0 when there is, and sets IR_RECEIPT, IR_RECORDED_AT, IR_TARGET,
# IR_BASE (the recorded base) and IR_BASE_MOVED (1 when IR_BASE != <tip-sha>).
# Otherwise returns 1 and sets:
#   IR_KIND  one of five textually distinct outcomes:
#              NO RECEIPT
#              RECEIPT UNREADABLE (COULD NOT LOOK)
#              RECEIPT INVALID
#              RECEIPT FOR ANOTHER BASE  (the recorded base is not an ancestor)
#              RECEIPT BASE UNKNOWN (COULD NOT LOOK)  (ancestry not computable)
#   IR_WHY   what was found, naming the path searched
#   IR_HOW   a step to take BEFORE re-gating, or empty. The caller composes
#            the Fix: from it plus its own re-gate text.
# "The gate never passed" and "whether it passed could not be read" call for
# different next steps, so they never share a kind. Ancestry is read from the
# object store under <git-common-dir>, shared by every checkout of the repo.
ir_read_receipt() {
  local common="$1" head="$2" base="$3" store fields where o rc
  local r_schema r_verdict r_head r_base r_target r_at
  IR_KIND="" IR_WHY="" IR_HOW="" IR_RECORDED_AT="" IR_TARGET="" IR_BASE="" IR_BASE_MOVED=0
  store="$(ir_store "$common")"
  IR_RECEIPT="$(ir_receipt_path "$common" "$head")"
  if [ -e "$store" ] && { [ ! -d "$store" ] || [ ! -r "$store" ] || [ ! -x "$store" ]; }; then
    IR_KIND="RECEIPT UNREADABLE (COULD NOT LOOK)"
    IR_WHY="the receipt store ${store} exists but cannot be searched, so whether integration-gate passed ${head} is unknown -- not the same as no receipt"
    IR_HOW="repair the permissions on ${store} (ls -ld '${store}') and re-run; if the receipt is still missing,"
    return 1
  fi
  if [ ! -e "$IR_RECEIPT" ]; then
    if [ -d "$store" ]; then where="the store exists; it holds no receipt for this head"; else where="the store does not exist yet"; fi
    IR_KIND="NO RECEIPT"
    IR_WHY="integration-gate has recorded no pass for ${head} (looked for ${IR_RECEIPT}; ${where}). A RED, refused, or never-run gate leaves none"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    IR_KIND="RECEIPT UNREADABLE (COULD NOT LOOK)"
    IR_WHY="${IR_RECEIPT} exists but jq is not on PATH, so it cannot be read"
    IR_HOW="install jq and re-run;"
    return 1
  fi
  if ! fields="$(jq -er '[.schema, .verdict, .head, .base, (.target_ref // ""), (.recorded_at // "")] | map(tostring) | @tsv' "$IR_RECEIPT" 2>/dev/null)"; then
    IR_KIND="RECEIPT UNREADABLE (COULD NOT LOOK)"
    IR_WHY="${IR_RECEIPT} exists but is not a readable receipt (unreadable file or malformed JSON)"
    IR_HOW="inspect it (cat '${IR_RECEIPT}'); then"
    return 1
  fi
  IFS=$'\t' read -r r_schema r_verdict r_head r_base r_target r_at <<<"$fields"
  if [ "$r_schema" != "$IR_SCHEMA" ] || [ "$r_verdict" != "pass" ] || [ "$r_head" != "$head" ]; then
    IR_KIND="RECEIPT INVALID"
    IR_WHY="${IR_RECEIPT} is not a pass for ${head} (schema '${r_schema}', verdict '${r_verdict}', head '${r_head}')"
    return 1
  fi
  if ! [[ "$r_base" =~ ^[0-9a-f]{40}$ ]]; then
    IR_KIND="RECEIPT INVALID"
    IR_WHY="${IR_RECEIPT} records base '${r_base}', which is not a full commit SHA"
    return 1
  fi
  if [ "$r_base" != "$base" ]; then
    for o in "$r_base" "$base"; do
      if git --git-dir="$common" cat-file -e "$o" 2>/dev/null \
         && [ "$(git --git-dir="$common" cat-file -t "$o" 2>/dev/null)" != "commit" ]; then
        IR_KIND="RECEIPT INVALID"
        IR_WHY="${o} (the recorded base ${r_base}, or the tip ${base}) is a $(git --git-dir="$common" cat-file -t "$o" 2>/dev/null), not a commit"
        return 1
      fi
      if ! git --git-dir="$common" cat-file -e "${o}^{commit}" 2>/dev/null; then
        IR_KIND="RECEIPT BASE UNKNOWN (COULD NOT LOOK)"
        IR_WHY="integration-gate passed ${head} against ${r_base} (${r_target}, ${r_at}) and the base tip is ${base}, but ${o} is not in the object store under ${common}, so whether the tip descends from the recorded base is unknown -- not the same as another base"
        IR_HOW="fetch origin in this repo (git fetch origin); if ${o} is still missing, the base was rewritten past it, so"
        return 1
      fi
    done
    # A shallow clone can cut the history between the two and answer 1 here.
    # That still refuses (as another base); it never reads as a pass.
    git --git-dir="$common" merge-base --is-ancestor "$r_base" "$base" 2>/dev/null; rc=$?
    case "$rc" in
      0) IR_BASE_MOVED=1 ;;
      1) IR_KIND="RECEIPT FOR ANOTHER BASE"
         IR_WHY="integration-gate passed ${head} against ${r_base} (${r_target}, ${r_at}), which is not an ancestor of the base tip ${base} (the base was rewritten, or the receipt is for another branch)"
         return 1 ;;
      *) IR_KIND="RECEIPT BASE UNKNOWN (COULD NOT LOOK)"
         IR_WHY="git merge-base --is-ancestor ${r_base} ${base} failed (exit ${rc}) under ${common}, so whether the tip descends from the recorded base is unknown"
         return 1 ;;
    esac
  fi
  IR_RECORDED_AT="$r_at" IR_TARGET="$r_target" IR_BASE="$r_base"
  return 0
}
