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
#   * glab-merge-guard.sh (ai/lib/, behind every GitLab merge or train board
#     through glab-athena, DND-1845) reads the receipt with ir_read_receipt
#     before any merge call. It is NOT declaration-keyed: it never asks
#     ir_declared_gate_on, so every project merged through glab-athena needs a
#     receipt, declared gate or not. Held with the rest of the chain (DND-1873).
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
# The receipt is SEALED (DND-1814). The store is a plain directory that the
# branch's own gate code, run unsandboxed by integration-gate, can write, and
# a hand-written receipt of the right shape used to pass every reader above.
# So integration-gate seals what it writes (ai/bin/receipt-seal: the git blobs
# of the gate files that wrote it, and an HMAC under this machine's
# receipt-seal key), and ir_read_receipt -- the one read every caller makes,
# ir_push_covered included -- refuses a receipt that does not verify:
# RECEIPT UNVERIFIED (unsealed, edited, another key's, or from a gate copy that
# never landed) or RECEIPT UNVERIFIABLE (COULD NOT LOOK). The rules live once,
# in ai/lib/receipt_seal.rb. Residual, said out loud: a receipt that is merely
# written never passes, but code running as this user that deliberately
# invokes the sealer (ai/bin/receipt-seal seal) or reads the key can still
# seal one; receipt_seal.rb's header says what closing that needs. OPEN, both
# DND-1808's (this seal does not fix it): (a) the sealer is an oracle to any
# same-uid process; (b) gen_saas's gate cannot be sandboxed.
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

# ir_gate_ever_declared <repo-dir> <commit-sha> : prints the declared gate
# path if any IR_DECLARED_GATES path is a blob on <commit-sha> or was ever
# touched in its history (DND-1690: with no landed main to read the
# declaration from, a commit that deletes the gate must not escape it).
# Returns 0 when one is found, 1 when the history never held one, 2 when git
# cannot read <commit-sha> -- "could not look" is never "no gate".
ir_gate_ever_declared() {
  local dir="$1" sha="$2" g hit rc=0
  g="$(ir_declared_gate_on "$dir" "$sha")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$g"; return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  for g in "${IR_DECLARED_GATES[@]}"; do
    hit="$(git -C "$dir" rev-list -1 "$sha" -- "$g" 2>/dev/null)" || return 2
    if [ -n "$hit" ]; then printf '%s\n' "$g"; return 0; fi
  done
  return 1
}

# ir_store <git-common-dir> / ir_receipt_path <git-common-dir> <head-sha>
ir_store() { printf '%s/integration-receipts' "$1"; }
ir_receipt_path() { printf '%s/%s.json' "$(ir_store "$1")" "$2"; }

# The seal tool beside this library (ai/bin/receipt-seal; its rules live in
# ai/lib/receipt_seal.rb). Resolved from this file, never from PATH or env.
IR_SEAL="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin" 2>/dev/null && pwd)/receipt-seal"

# ir_verify_seal <receipt-file> [<name>] : did a landed integration-gate seal
# it on this machine (DND-1814)? <name> is the path messages show (the store
# path, when <receipt-file> is a one-read snapshot of it). Returns 0 when it verifies. Otherwise returns 1 and
# sets IR_KIND, IR_WHY and IR_HOW:
#   RECEIPT UNVERIFIED  unsealed, forged or edited, sealed under another key,
#                       or written by a gate copy that never landed
#   RECEIPT UNVERIFIABLE (COULD NOT LOOK)  no key, an unsafe key, a landed
#                       history it cannot read, or no seal tool to ask
# Neither is ever a pass.
ir_verify_seal() {
  local f="$1" name="${2:-$1}" err rc
  if [ ! -x "$IR_SEAL" ]; then
    IR_KIND="RECEIPT UNVERIFIABLE (COULD NOT LOOK)"
    IR_WHY="${name} cannot be checked: the seal tool ${IR_SEAL} is missing or not executable"
    IR_HOW="restore ai/bin/receipt-seal beside ai/lib in this checkout;"
    return 1
  fi
  err="$("$IR_SEAL" verify --kind integration "$f" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && return 0
  local sfix=""
  case "$err" in *$'\n'"Fix: "*) sfix="${err#*$'\n'Fix: }"; sfix="${sfix%%$'\n'*}" ;; esac
  err="${err%%$'\n'Fix:*}"; err="${err#receipt-seal: }"; err="${err//"$f"/"$name"}"
  if [ "$rc" -eq 1 ]; then
    IR_KIND="RECEIPT UNVERIFIED"
    IR_WHY="${err}; only integration-gate as landed seals a receipt, so a hand-written file, one branch code wrote, or one from an unlanded gate copy is never a pass"
    IR_HOW=""
  else
    IR_KIND="RECEIPT UNVERIFIABLE (COULD NOT LOOK)"
    IR_WHY="${err:-receipt-seal verify exited ${rc} with no reason}; a seal that cannot be checked is never a pass"
    IR_HOW="${sfix:-repair what it names (receipt-seal --help; for a missing landed history, git fetch origin in ~/dev/custom) and retry.} If it is still refused,"
  fi
  return 1
}

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
#   IR_KIND  one of seven textually distinct outcomes:
#              NO RECEIPT
#              RECEIPT UNREADABLE (COULD NOT LOOK)
#              RECEIPT INVALID
#              RECEIPT UNVERIFIED  (no seal of a landed gate: ir_verify_seal)
#              RECEIPT UNVERIFIABLE (COULD NOT LOOK)  (the seal cannot be checked)
#              RECEIPT FOR ANOTHER BASE  (the recorded base is not an ancestor)
#              RECEIPT BASE UNKNOWN (COULD NOT LOOK)  (ancestry not computable)
#   IR_WHY   what was found, naming the path searched
#   IR_HOW   a step to take BEFORE re-gating, or empty. The caller composes
#            the Fix: from it plus its own re-gate text.
# "The gate never passed" and "whether it passed could not be read" call for
# different next steps, so they never share a kind. Ancestry is read from the
# object store under <git-common-dir>, shared by every checkout of the repo.
ir_read_receipt() {
  local common="$1" head="$2" base="$3" store where snap rc
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
  # One read of the file: the fields and the seal are both checked on this
  # snapshot, so a receipt swapped between the two checks is never read as
  # the sealed one.
  if ! snap="$(mktemp "${TMPDIR:-/tmp}/ir-receipt.XXXXXX" 2>/dev/null)"; then
    IR_KIND="RECEIPT UNREADABLE (COULD NOT LOOK)"
    IR_WHY="${IR_RECEIPT} exists but no temp file could be made to read it once (mktemp in ${TMPDIR:-/tmp} failed)"
    IR_HOW="free space or fix permissions in ${TMPDIR:-/tmp}; then"
    return 1
  fi
  if ! cat -- "$IR_RECEIPT" >"$snap" 2>/dev/null; then
    rm -f -- "$snap"
    IR_KIND="RECEIPT UNREADABLE (COULD NOT LOOK)"
    IR_WHY="${IR_RECEIPT} exists but cannot be read"
    IR_HOW="inspect it (ls -l '${IR_RECEIPT}'); then"
    return 1
  fi
  ir_check_snapshot "$common" "$head" "$base" "$snap"; rc=$?
  rm -f -- "$snap"
  return "$rc"
}

# ir_check_snapshot <git-common-dir> <head> <tip> <snapshot> : the body of
# ir_read_receipt, run on one read of IR_RECEIPT. Messages name IR_RECEIPT.
ir_check_snapshot() {
  local common="$1" head="$2" base="$3" snap="$4" fields o rc
  local r_schema r_verdict r_head r_base r_target r_at
  if ! fields="$(jq -er '[.schema, .verdict, .head, .base, (.target_ref // ""), (.recorded_at // "")] | map(tostring) | @tsv' "$snap" 2>/dev/null)"; then
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
  # The seal (DND-1814): a receipt a landed integration-gate did not seal on
  # this machine is never a pass. ir_verify_seal sets the outcome itself.
  ir_verify_seal "$snap" "$IR_RECEIPT" || return 1
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
# gated head, for exact and rebase; IR_RECEIPT is its receipt). IR_COVER_HEADS
# lists EVERY gated head that covers <pushed-sha>: the one for exact, each
# candidate giving its tree for rebase, none for landed. The lead-time ledger
# joins a push landing to its gated head by this rule, and refuses to guess
# when two heads cover it (DND-1809). IR_COVER_HEAD is the first of them, the
# one this function returned before. Returns 1 with
# IR_KIND "NO RECEIPT" and IR_WHY naming how many receipts and candidates it
# looked at, so a miss is never silent. Returns 2 (COULD NOT LOOK) when a
# receipt, the store or git cannot be read; IR_HOW may hold a first step. A
# receipt it cannot read is a refusal, never a pass.
#
# Residuals, said out loud: <landed-sha> is the LOCAL tracking ref. A stale
# (behind) one only refuses: the pushed tree must equal <landed-sha> plus the
# gated change, and the commits it lacks are not in that sum. One moved AHEAD of
# the remote by hand (`git update-ref` to an unlanded commit) is trusted: its
# content then lands ungated. That is local state a process in this repo can
# forge; a diff cannot. (A hand-written receipt file no longer is: it does not
# verify, DND-1814.) A rebase
# whose sequential result differs from the three-way merge (rare) is refused;
# re-gate it.
ir_push_covered() {
  local common="$1" p="$2" m="$3" rc store f h line want ptree tree out
  local exact_why n_store=0 n_cand=0 cl="" conflicts=0 other_base=0 unverified=0
  local -a heads=() cands=() commits=() covers=()
  local -A seen=() inrange=()
  IR_COVER="" IR_COVER_HEAD="" IR_COVER_HEADS=()
  if ir_read_receipt "$common" "$p" "$p"; then
    IR_COVER=exact IR_COVER_HEAD="$p" IR_COVER_HEADS=( "$p" ); return 0
  fi
  case "$IR_KIND" in *"COULD NOT LOOK"*) return 2 ;; esac
  exact_why="$IR_WHY"
  if [ -z "$m" ]; then
    IR_KIND="NO RECEIPT" IR_HOW="fetch the remote you push to, so its main is known locally; then"
    IR_WHY="${exact_why}; and no landed main is known for the pushed remote, so no clean rebase of a gated head can be checked"
    return 1
  fi
  git --git-dir="$common" merge-base --is-ancestor "$p" "$m" 2>/dev/null; rc=$?
  case "$rc" in
    0) IR_COVER=landed; return 0 ;;
    1) ;;
    *) ir_could_not_look "git merge-base --is-ancestor ${p} ${m} failed (exit ${rc}) under ${common}"; return 2 ;;
  esac
  git --git-dir="$common" merge-base --is-ancestor "$m" "$p" 2>/dev/null; rc=$?
  case "$rc" in
    0) ;;
    1) IR_KIND="NO RECEIPT" IR_HOW="fetch, and rebase onto the landed main; then"
       IR_WHY="${exact_why}; and ${p} does not contain the landed main ${m}, so it cannot be a clean rebase of a gated head onto it"
       return 1 ;;
    *) ir_could_not_look "git merge-base --is-ancestor ${m} ${p} failed (exit ${rc}) under ${common}"; return 2 ;;
  esac
  store="$(ir_store "$common")"
  if [ -e "$store" ]; then
    if [ ! -d "$store" ] || [ ! -r "$store" ] || [ ! -x "$store" ]; then
      IR_KIND="RECEIPT UNREADABLE (COULD NOT LOOK)"
      IR_HOW="repair the permissions on ${store} (ls -ld '${store}') and retry; if it is still refused,"
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
  # Each read below is checked: a failed read is COULD NOT LOOK, never zero
  # candidates (~/.claude/CLAUDE.md -> "A failed lookup must never look like
  # an empty one").
  if [ "${#heads[@]}" -gt 0 ]; then
    if ! want="$(git --git-dir="$common" log -1 --format='%an%x09%ae%x09%at%x09%s' "$p" 2>/dev/null)"; then
      ir_could_not_look "git log could not read ${p} under ${common}"; return 2
    fi
    # Receipt heads still in the object store (a gc may have pruned some).
    if ! out="$(printf '%s\n' "${heads[@]}" | git --git-dir="$common" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null)"; then
      ir_could_not_look "git cat-file --batch-check over the ${n_store} receipt heads failed under ${common}"; return 2
    fi
    while IFS=' ' read -r h line; do
      [ "$line" = commit ] && commits+=( "$h" )
    done <<<"$out"
    if [ "${#commits[@]}" -gt 0 ]; then
      if ! out="$(printf '%s\n' "${commits[@]}" | git --git-dir="$common" log --no-walk=unsorted --stdin --format='%H%x09%an%x09%ae%x09%at%x09%s' 2>/dev/null)"; then
        ir_could_not_look "git log --no-walk over ${#commits[@]} receipt heads failed under ${common}"; return 2
      fi
      while IFS= read -r line; do
        h="${line%%$'\t'*}"
        if [ "${line#*$'\t'}" = "$want" ] && [ -z "${seen[$h]:-}" ]; then seen[$h]=1; cands+=( "$h" ); fi
      done <<<"$out"
    fi
    if ! out="$(git --git-dir="$common" rev-list "${m}..${p}" 2>/dev/null)"; then
      ir_could_not_look "git rev-list ${m}..${p} failed under ${common}"; return 2
    fi
    while IFS= read -r h; do [ -n "$h" ] && inrange[$h]=1; done <<<"$out"
    for h in "${heads[@]}"; do
      if [ -n "${inrange[$h]:-}" ] && [ -z "${seen[$h]:-}" ]; then seen[$h]=1; cands+=( "$h" ); fi
    done
  fi
  if ! ptree="$(git --git-dir="$common" rev-parse --verify -q "${p}^{tree}" 2>/dev/null)"; then
    ir_could_not_look "git could not read the tree of ${p} under ${common}"; return 2
  fi
  for h in "${cands[@]}"; do
    n_cand=$((n_cand + 1))
    if ! ir_read_receipt "$common" "$h" "$m"; then
      case "$IR_KIND" in
        *"COULD NOT LOOK"*) cl="${cl:+$cl; }${IR_WHY}" ;;
        "RECEIPT UNVERIFIED") unverified=$((unverified + 1)) ;;
        *) other_base=$((other_base + 1)) ;;
      esac
      continue
    fi
    tree="$(git --git-dir="$common" merge-tree --write-tree "$m" "$h" 2>/dev/null)"; rc=$?
    case "$rc" in
      0) tree="${tree%%$'\n'*}"
         [ "$tree" = "$ptree" ] && covers+=( "$h" ) ;;
      1) conflicts=$((conflicts + 1)) ;;
      *) cl="${cl:+$cl; }git merge-tree --write-tree ${m} ${h} failed (exit ${rc})" ;;
    esac
  done
  # Every candidate is checked, so IR_COVER_HEADS is complete. A cover found
  # still wins over a candidate that could not be read, as it did when the
  # loop stopped at the first cover. The re-read restores IR_RECEIPT and the
  # other receipt fields to the first cover's, which later reads overwrote.
  # It is best-effort: that receipt already passed in this call, so a read
  # that now fails (the file removed meanwhile) leaves only the note's
  # receipt fields stale, never the answer.
  if [ "${#covers[@]}" -gt 0 ]; then
    ir_read_receipt "$common" "${covers[0]}" "$m" || true
    IR_COVER=rebase IR_COVER_HEAD="${covers[0]}" IR_COVER_HEADS=( "${covers[@]}" ); return 0
  fi
  if [ -n "$cl" ]; then
    ir_could_not_look "${exact_why}; and whether a gated head covers ${p} as a clean rebase onto ${m} is unknown: ${cl}"
    return 2
  fi
  IR_KIND="NO RECEIPT" IR_HOW=""
  IR_WHY="${exact_why}; and no gated head covers it as a clean rebase onto the landed main ${m}: of ${n_store} other receipt(s) in the store, ${n_cand} candidate(s) (same author, date and subject as ${p}, or inside ${m}..${p}) were checked: ${other_base} with no pass recorded on an ancestor of ${m}, ${unverified} with a receipt that does not verify (no seal of a landed gate), ${conflicts} conflicting with ${m}, none giving ${p}'s tree"
  return 1
}

# ir_could_not_look <why> : set the COULD NOT LOOK outcome for ir_push_covered.
ir_could_not_look() { IR_KIND="COULD NOT LOOK" IR_HOW="" IR_WHY="$1"; }
