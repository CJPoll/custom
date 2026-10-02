# shellcheck shell=bash
#
# integration-receipt.sh -- the ONE implementation of integration-gate's
# receipt and gate-declaration rules (DND-969). Sourced, never run.
#
# Its callers share it so they cannot drift:
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
#   * main-health.sh (ai/lib/) reads a landed tip's receipt with
#     ir_read_receipt.
#   * forge-git-passthrough.sh (ai/lib/, behind every `gh-athena git push`
#     and `glab-athena git push`) asks ir_push_covered whether a push to main
#     in a gated repo is covered by a receipt (DND-1690).
#   * test-slot (ai/bin/) asks ir_declared_gate_on whether the command it runs
#     is the caller's declared gate, for its gate.run telemetry (DND-1530).
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

# ---- Push-to-main coverage (DND-1690) ----------------------------------------
# ir_push_covered <git-common-dir> <pushed-sha> <landed-sha or ""> : may
# <pushed-sha> become the default branch of a repo that declares a gate?
# <landed-sha> is the landed main as last fetched (refs/remotes/origin/main),
# or empty when none is known.
#
# Why: `gh-athena git push` checked a receipt only while main was RED
# (DND-1482). On a green main a cron lane pushed bcfd66b6 with no receipt and
# no critic verdict, and main went red (DND-1685). Now every push to main in a
# gated repo needs one of:
#   exact   a pass receipt for exactly <pushed-sha>. integration-gate refuses a
#           dirty tree, so the gated tree IS the pushed tree. That also closes
#           DND-1689's staged-subset gap: the receipt is keyed on the commit.
#   rebase  <pushed-sha> contains <landed-sha>, and its tree equals the clean
#           merge (git merge-tree) of a gated head H onto <landed-sha>, where
#           H's receipt was recorded against <landed-sha> or an ancestor of it.
#           That is the owner's DND-1463 rule: a clean rebase of a gated head
#           onto a moved main lands with no re-gate. A merge commit of
#           <landed-sha> and H qualifies the same way.
#   landed  <pushed-sha> is <landed-sha> or an ancestor of it: nothing new
#           lands.
# Candidates for H: receipt heads whose commit has <pushed-sha>'s author,
# author date and subject (what a rebase keeps), plus receipt heads inside
# <landed-sha>..<pushed-sha> (a merge). Each candidate is checked in full; the
# identity only picks which ones.
#
# Returns 0 and sets IR_COVER (exact|rebase|landed) and IR_COVER_HEAD (the
# gated head, for exact and rebase; IR_RECEIPT is its receipt). Returns 1 with
# IR_KIND "NO RECEIPT" and IR_WHY naming how many receipts and candidates it
# looked at, so a miss is never silent. Returns 2 (COULD NOT LOOK) when a
# receipt, the store or git cannot be read; IR_HOW may hold a first step. A
# receipt it cannot read is a refusal, never a pass.
#
# Residuals, said out loud: <landed-sha> is the LOCAL tracking ref. A stale one
# only refuses (the tree no longer matches); it cannot admit unlanded content,
# because the pushed tree must equal <landed-sha> plus the gated change. A
# rebase whose sequential result differs from the three-way merge (rare) is
# refused; re-gate it. Like every receipt, this is local machine state.
ir_push_covered() {
  local common="$1" p="$2" m="$3" rc store f h line want ptree tree
  local exact_why n_store=0 n_cand=0 cl="" conflicts=0
  local -a heads=() cands=() commits=()
  local -A seen=() inrange=()
  IR_COVER="" IR_COVER_HEAD=""
  if ir_read_receipt "$common" "$p" "$p"; then
    IR_COVER=exact IR_COVER_HEAD="$p"; return 0
  fi
  case "$IR_KIND" in *"COULD NOT LOOK"*) return 2 ;; esac
  exact_why="$IR_WHY"
  if [ -z "$m" ]; then
    IR_KIND="NO RECEIPT" IR_HOW=""
    IR_WHY="${exact_why}; and no landed main is known (no refs/remotes/origin/main), so no clean rebase of a gated head can be checked"
    return 1
  fi
  git --git-dir="$common" merge-base --is-ancestor "$p" "$m" 2>/dev/null; rc=$?
  case "$rc" in
    0) IR_COVER=landed; return 0 ;;
    1) ;;
    *) IR_KIND="COULD NOT LOOK" IR_HOW=""
       IR_WHY="git merge-base --is-ancestor ${p} ${m} failed (exit ${rc}) under ${common}"
       return 2 ;;
  esac
  git --git-dir="$common" merge-base --is-ancestor "$m" "$p" 2>/dev/null; rc=$?
  case "$rc" in
    0) ;;
    1) IR_KIND="NO RECEIPT" IR_HOW="git fetch origin and rebase onto origin/main; then"
       IR_WHY="${exact_why}; and ${p} does not contain the landed main ${m}, so it cannot be a clean rebase of a gated head onto it"
       return 1 ;;
    *) IR_KIND="COULD NOT LOOK" IR_HOW=""
       IR_WHY="git merge-base --is-ancestor ${m} ${p} failed (exit ${rc}) under ${common}"
       return 2 ;;
  esac
  store="$(ir_store "$common")"
  if [ -e "$store" ]; then
    if [ ! -d "$store" ] || [ ! -r "$store" ] || [ ! -x "$store" ]; then
      IR_KIND="RECEIPT UNREADABLE (COULD NOT LOOK)" IR_HOW="repair the permissions on ${store} (ls -ld '${store}'); then"
      IR_WHY="the receipt store ${store} exists but cannot be searched, so whether a gated head covers ${p} is unknown"
      return 2
    fi
    for f in "$store"/*.json; do
      [ -e "$f" ] || continue
      h="${f##*/}"; h="${h%.json}"
      [[ "$h" =~ ^[0-9a-f]{40}$ ]] || continue
      [ "$h" = "$p" ] && continue
      heads+=( "$h" ); n_store=$((n_store + 1))
    done
  fi
  if [ "${#heads[@]}" -gt 0 ]; then
    if ! want="$(git --git-dir="$common" log -1 --format='%an%x09%ae%x09%at%x09%s' "$p" 2>/dev/null)"; then
      IR_KIND="COULD NOT LOOK" IR_HOW="" IR_WHY="git log could not read ${p} under ${common}"
      return 2
    fi
    # Receipt heads still in the object store (a gc may have pruned some).
    mapfile -t commits < <(printf '%s\n' "${heads[@]}" \
      | git --git-dir="$common" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
      | sed -n 's/^\([0-9a-f]\{40\}\) commit$/\1/p')
    if [ "${#commits[@]}" -gt 0 ]; then
      while IFS= read -r line; do
        h="${line%%$'\t'*}"
        if [ "${line#*$'\t'}" = "$want" ] && [ -z "${seen[$h]:-}" ]; then seen[$h]=1; cands+=( "$h" ); fi
      done < <(printf '%s\n' "${commits[@]}" \
        | git --git-dir="$common" log --no-walk=unsorted --stdin --format='%H%x09%an%x09%ae%x09%at%x09%s' 2>/dev/null)
    fi
    while IFS= read -r h; do inrange[$h]=1; done \
      < <(git --git-dir="$common" rev-list "${m}..${p}" 2>/dev/null)
    for h in "${heads[@]}"; do
      if [ -n "${inrange[$h]:-}" ] && [ -z "${seen[$h]:-}" ]; then seen[$h]=1; cands+=( "$h" ); fi
    done
  fi
  if ! ptree="$(git --git-dir="$common" rev-parse --verify -q "${p}^{tree}" 2>/dev/null)"; then
    IR_KIND="COULD NOT LOOK" IR_HOW="" IR_WHY="git could not read the tree of ${p} under ${common}"
    return 2
  fi
  for h in "${cands[@]}"; do
    n_cand=$((n_cand + 1))
    if ! ir_read_receipt "$common" "$h" "$m"; then
      case "$IR_KIND" in *"COULD NOT LOOK"*) cl="${cl:+$cl; }${IR_WHY}" ;; esac
      continue
    fi
    tree="$(git --git-dir="$common" merge-tree --write-tree "$m" "$h" 2>/dev/null)"; rc=$?
    case "$rc" in
      0) tree="${tree%%$'\n'*}"
         if [ "$tree" = "$ptree" ]; then
           IR_COVER=rebase IR_COVER_HEAD="$h"; return 0
         fi ;;
      1) conflicts=$((conflicts + 1)) ;;
      *) cl="${cl:+$cl; }git merge-tree --write-tree ${m} ${h} failed (exit ${rc})" ;;
    esac
  done
  if [ -n "$cl" ]; then
    IR_KIND="COULD NOT LOOK" IR_HOW=""
    IR_WHY="${exact_why}; and whether a gated head covers ${p} as a clean rebase onto ${m} is unknown: ${cl}"
    return 2
  fi
  IR_KIND="NO RECEIPT" IR_HOW=""
  IR_WHY="${exact_why}; and no gated head covers it as a clean rebase onto the landed main ${m}: of ${n_store} other receipt(s) in ${store}, ${n_cand} candidate(s) (same author, date and subject as ${p}, or inside ${m}..${p}) were checked, ${conflicts} conflicting with ${m}, none giving ${p}'s tree"
  return 1
}
