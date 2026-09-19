# Design: bring rendered `athena-admiral.md` to ≤500 lines (behavior-preserving)

**Kind: dated record** (a design/proposal — annotate, never rewrite; per
`~/dev/custom/CLAUDE.md` → Documentation conventions).

**Author:** athena-architect · **Date:** 2026-09-19 (UTC) · **Status:** design
only — no admiral/code changes in the PR that carries this doc.

Follow-on to the merged harness-IA effort: PR #23 added
`ai/blocks/ops/harness-ia.md` (the IA principles); PR #24 did a first
behavior-preserving pass 1165 → 1034. This designs the second pass to ≤500 and
the enforced gate that keeps it there.

---

## 0. Fixed decisions (do not re-litigate) — recorded 2026-09-19

1. **Metric = 500-line cap on the RENDERED total** (`ai/agents/athena-admiral.md`,
   the built artifact — `File.readlines.size`), **not** the `.md.in` template and
   **not** bespoke-only. The rendered total INCLUDES the shared `@include` blocks.
   Measured today the shared blocks render to **176 lines**, not the ~210 the
   brief estimated (`fleet-coordination` 107, `safety-checks` 34,
   `never-end-turn-waiting` 26 — the brief's ~210 folded in some bespoke prose
   that sits *next to* the includes). So bespoke content must drop from **~858 →
   ~324** to clear 500; this plan takes it to **~175**, leaving ~150 lines of
   headroom.
2. **The cap is ENFORCED as a gate** (`ai/bin/check-agent-size`, harness-IA
   principle #8) so it cannot silently regrow. Design in §3 below. It carries a
   `Fix:` line and is wired into `ai/bin/harness-gate`.

Both are inputs to this design, not open questions.

---

## 1. Section-by-section disposition

Rendered section line counts are measured from `ai/agents/athena-admiral.md` at
1034 lines (2026-09-19). "Home" names the concrete destination; "resident
trigger" is the one-line pointer that stays in the template so nothing is
silently dropped and the reader knows where the content went.

| # | Section (rendered) | cur | Mechanism | New home (named) | Resident trigger that remains |
|---|---|--:|---|---|---|
| A | Frontmatter + role + autonomy posture (L1–32) | 32 | **resident** (role + escalation judgment) | — | kept, trimmed to ~22 |
| B | Inputs you should expect (L33–79) | 47 | **skill** (status-vocab mapping) + existing skill pointer | `athena:fleet-inputs` (new) for the `In Review`-substitution procedure; `athena:ticket-management` (exists) for the assignee lifecycle | "Required inputs = scope + blocked-semantics; ask once if missing. Status-vocab mapping & the no-`In Review` substitution: `athena:fleet-inputs`. Assignee lifecycle: `athena:ticket-management`." (~14) |
| C | Coordinating as a fleet (L80–186) **[SHARED]** | 107 | **unchanged shared block** | `ai/blocks/ops/fleet-coordination.md` | whole block stays (see §6) |
| D | As the implementation half (L187–223) | 37 | **resident** (the admiral's half of the coordination contract — judgment) | — | compressed to bullet pointers (~16) |
| E | Process header (L224–225) | 2 | resident | — | kept (2) |
| F | §1 Ground in domain context (L226–241) | 16 | **resident**, trimmed | — | "You never model — in any mode. Fleet: consume Notion sub-docs. Standalone: ground in existing model/ADRs/KG; fresh modeling ⇒ stand up a fleet via `athena:kick-off`." (~6) |
| G | §2 Pull and triage (L242–253) | 12 | **resident**, trimmed | — | "Fleet: read the architect's `Depends On`/`Blocks` edges. Standalone: query Notion, build the dependency map." (~5) |
| H | §3 Tracking state (L254–275) | 22 | **resident anchor** (paths referenced by many steps), trimmed | — | run-id + `…/coordination/[run-id]/state.md` schema (status enum) + `reports/[mission]-report.md`; "never inside a worktree." (~8) |
| I | §3a Resuming after a pause (L276–317) | 42 | **JIT skill** (multi-step judgment) | `athena:admiral-resume` (new) | "On any resume: `athena:admiral-resume` (read state log first; salvage uncommitted work before re-dispatch; adopt worktrees; sweep all; cap still 5)." (~3) |
| J | §3b Notifications can be dropped (L318–355) | 38 | **JIT skill** (liveness judgment) | `athena:fleet-liveness` (new) | "Notifications (incl. `Monitor`) are latency hints, never proof: `athena:fleet-liveness`." (~3) |
| K | §3c Judging liveness w/o `ListAgents` (L356–391) | 36 | **JIT skill** (same) | `athena:fleet-liveness` (new) | folded into J's pointer (~2) |
| L | §4 Create worktrees & dispatch (L392–467) | 76 | **script** (exists) + **JIT skill** (brief checklist) | `scripts/wt-preflight` (exists) for worktree create; `athena:dispatch-captain` (new) for the dispatch-brief checklist; `athena:model-tiering` (exists) for model choice | "Create worktrees only via `scripts/wt-preflight <branch> <repo>` (dispatch on `PREFLIGHT OK`). Cap ≤5 concurrent. Build every dispatch brief with `athena:dispatch-captain`; pick model via `athena:model-tiering`." (~14) |
| M | §4a Env fact must be VERIFIED (L468–532) | 65 | **JIT skill** (+ probe list) | `athena:brief-verification` (new) | "A fact in a brief must be verified with a named second probe; inherited facts are not verified; a subordinate's 'unsatisfiable' report IS a probe result: `athena:brief-verification`." (~5) |
| N | §4b Re-read the defect before dispatch (L533–575) | 43 | **JIT skill** (same) | `athena:brief-verification` (new) | folded into M's pointer (~3) |
| O | §5 Handle what comes back (L576–635) | 60 | **script** (exists) + **JIT skill** | `ai/bin/admiral-report-watch` (exists) for the watcher; `athena:captain-return` (new) for DONE/BLOCKED/STUCK handling + slot management | "Reports arrive by FILE (message = latency hint). Start one `Monitor` on `admiral-report-watch [run-id]` after first dispatch. Process each return code + free the slot per `athena:captain-return`." (~12) |
| P | §6 Propagate dependency work (L636–648) | 13 | **resident**, trimmed (git ops) | (retarget command lives in `athena:captain-return`) | "When a dependency lands, merge/rebase it into the dependent worktree; retarget an already-open MR yourself. Never rewrite the captain's work." (~6) |
| Q | §6a Tear down docker stack (L649–673) | 25 | existing skill + compact resident rules | `athena:teardown-worktree-stack` (exists) | "On CONFIRMED merge, tear the stack down via `athena:teardown-worktree-stack`. Only your fleet's stacks; only after verifying the merge; confirm gone + record." (~7) |
| R | §6b Boarding / merge-rate (L674–723) | 50 | **JIT skill** | `athena:merge-boarding` (new) | "Protect the green→landed latency: `athena:merge-boarding` (trigger on DONE, board in parallel, 3-item checklist read off the forge)." (~3) |
| S | §7 Hard constraints (L724–831) | 108 | **hook** (auth) + **hook** (identity, exists) + **JIT skill** (merge mechanics) + compact resident invariant list | `ai/hooks/forge-auth-guard.sh` (new); `ai/hooks/forge-identity-guard.sh` (exists, extend); `athena:merge-boarding` (new) | auth 1-line pointer to the hook; the compact "Never…" invariant list (runtime-only invariants) stays (~20 total) |
| T | Final report (L832–865) | 34 | **JIT skill** | `athena:admiral-final-report` (new) | "At end of scope: `athena:admiral-final-report` (summary + tracker↔forge reconciliation both directions)." (~5) |
| U | Speed a safety check up (L866–899) **[SHARED]** | 34 | **unchanged shared block** | `ai/blocks/ops/safety-checks.md` | whole block stays |
| V | Never end your turn waiting (L900–934) **[SHARED + bullet]** | 35 | shared block unchanged; the bespoke **label-assertion bullet** (L927–933) moves | shared: `ai/blocks/ops/never-end-turn-waiting.md`; label bullet → `athena:merge-boarding` | block stays; label bullet becomes a merge-boarding step (~34, was 35) |
| W | Confirm a merge actually landed (L935–949) | 15 | **script** + skill | `ai/bin/confirm-merged` (new) + `athena:merge-boarding` | "Never trust `✓ Merged!` — confirm with `ai/bin/confirm-merged` before Done/DM/teardown." (~2) |
| X | Epic-progress DM (L950–968) | 19 | existing skill, compressed | `athena:epic-progress-dm` (exists) | "Owner DMs = exactly 3 events (epic 50%, epic 100%, ticket→Needs Attention). At merge, if the ticket has an Epic, invoke `athena:epic-progress-dm`." (~6) |
| Y | Act as Athena, not the owner (L969–992) | 24 | **hook** (exists, extend) + compressed resident | `ai/hooks/forge-identity-guard.sh` (exists) | "Attributed writes go through `gh-athena`/`glab-athena` (per remote host); reads may use plain CLI. Full playbook: `athena:gitlab`/`athena:github`." (~6) |
| Z | Worker rename #473 (L993–1004) | 12 | **guidance doc** | `ai/docs/oban-worker-rename.md` (new) | "An MR renaming an Oban worker must ship its queue migration — see `ai/docs/oban-worker-rename.md`; enforced in the `athena:merge-boarding` gate." (~2) |
| AA | Every flaky test → ticket (L1005–1034) | 30 | **JIT skill** (already flagged in `routing.yml`) | `athena:flaky-ticket` (new) | "Every flake in your lane becomes a worked ticket, never masked: `athena:flaky-ticket`." (~3) |

**Stays resident, by category** (harness-IA "stays resident" rule): the role +
autonomy posture (A), the paired-architect coordination summary (D + the shared
block C), the state-log anchor (H), the concurrency-cap and the compact "Never…"
invariant list (S), the ground/triage judgment (F, G), and — new — a short
**Triggers index** that names every skill/script/hook/doc the pointers reference,
so the map from rule to enforced home is itself resident.

---

## 2. Invariant → new-home map (nothing silently dropped)

Every load-bearing invariant currently in the admiral, with where it lands and
whether it is a **safety** invariant under `ops/safety-checks.md` (relocate or
**strengthen**, never weaken). "Strengthen" = prose → mechanically enforced,
which the safety block explicitly permits.

| Invariant (current home) | New home | Kind | Note |
|---|---|---|---|
| **NEVER touch/rotate/refresh auth; auth is owner-gated** (§7) | **`forge-auth-guard.sh` hook (new)** — deny + `Fix:` | **SAFETY — STRENGTHEN** | prose → enforced deny of `glab auth login`, `gh auth`, `POST /oauth/token`, edits to `~/.config/glab-cli/config.yml`/token files. Deny-by-default (no legitimate agent use). Resident 1-liner remains as the human-readable statement. |
| **Attributed writes go through the Athena wrapper** (§Y "Act as Athena") | **`forge-identity-guard.sh` hook (exists)** — extend from `create` to also cover `pr merge`/`mr merge` | **STRENGTHEN** | hook already covers `create` (PR #22); extension covers the merge write the admiral performs. Skill `athena:gitlab`/`athena:github` keep the playbook. |
| **Merge only when the full bar holds** (local gate green, CI green on the head, first review round addressed) (§7) | `athena:merge-boarding` skill | **SAFETY — relocate** | the *enforcement* is unchanged (the forge's CI + branch protection + the captain's `address-mr-reviews`); the skill restates the admiral's gating discipline. No check is weakened — the gate the prose names still blocks. |
| **No-CI repo: `MERGEABLE` proves nothing; the report + local gate green on the reported head IS the bar; an actively-committing captain = NOT ready; land the head SHA the report names** (§7) | `athena:merge-boarding` skill | **SAFETY — relocate** | preserved verbatim as a skill section; it is the rule that stopped the DND-183 half-merge. |
| **Confirm the merge actually landed before Done/DM/teardown** (§W) | **`ai/bin/confirm-merged` (new)** + `athena:merge-boarding` | **SAFETY — STRENGTHEN** | prose → a script that returns merged/not (`state==merged` && `merged_at`, or `git merge-base --is-ancestor`), so "confirmed" has one definition the skill calls. |
| **Label-assertion before the batch tail boards (silent no-deploy)** (§V bullet) | `athena:merge-boarding` skill | **SAFETY — relocate** | a batch with no `Auto-Deploy` merges into a silent no-deploy; the assertion stays, as a boarding step. |
| **One review round, no re-review churn; batch merges, one deploy per batch; `Auto-Deploy` on the tail only when prior `release:deploy` finished; rollback targets last HEALTHY** (§7) | `athena:merge-boarding` skill (+ `athena:gitlab` for forge mechanics) | relocate | forge-specific mechanics; deploy watcher is `release:watch` in CI, unchanged. |
| **Concurrency cap ≤ 5 captains, ever** (§4, §7) | **resident one-liner** (L, S) | relocate | runtime invariant, no author-time artifact to gate; it is part of the "concurrency decision tree" the harness-IA rule keeps resident. |
| **Salvage uncommitted worktree state before any re-dispatch on resume** (§3a) | `athena:admiral-resume` skill | relocate (data-safety) | the skill is JIT-loaded on every resume; the resident trigger names it so a resume can't skip it. |
| **Notifications (incl. `Monitor`) can drop; full sweep on every trigger; hard staleness rule; count the cap from the state log not the directory** (§3b, §3c) | `athena:fleet-liveness` skill | relocate | correctness invariant; resident trigger names it. |
| **A brief fact must be verified with a named second probe; inherited ≠ verified; a subordinate "unsatisfiable" report is a probe result** (§4a) | `athena:brief-verification` skill | relocate | includes the concrete probe list (`command tmux`, `forge-preflight`/`gh-athena --check`, read the Notion status options directly). |
| **Re-read the defect's current state immediately before dispatching a fix** (§4b) | `athena:brief-verification` skill | relocate | same skill; one command, recorded in the state log. |
| **Worktree create only via `wt-preflight` (fresh base, `PREFLIGHT OK`)** (§4) | `scripts/wt-preflight` (exists) | relocate (correctness) | already a script; resident trigger names it as the only sanctioned path. |
| **Reports arrive by FILE; the watcher is a fast path only** (§5) | `athena:captain-return` skill + `ai/bin/admiral-report-watch` (exists) | relocate | file-is-delivery invariant kept as a resident half-line + the skill. |
| **Dependency propagation is a git op on the captain's worktree, never a rewrite** (§6) | resident (P) + `athena:captain-return` | relocate | one-liner resident; retarget command in the skill. |
| **Teardown only your fleet's stacks, only after verifying the merge, confirm gone** (§6a) | resident (Q) + `athena:teardown-worktree-stack` (exists) | relocate | orchestration one-liners resident; per-repo derivation in the skill (unchanged). |
| **Owner DMs = exactly 3 events; fire once per boundary; recompute from Notion** (§X) | `athena:epic-progress-dm` skill (exists) | relocate | admiral keeps the 3-event resident summary + the invoke trigger. |
| **Every flake becomes a worked ticket; NEVER masked with retry/`allow_failure`/`@tag :skip`/loosened tolerance** (§AA) | `athena:flaky-ticket` skill (new; `routing.yml` already reserves this slot) | **SAFETY — relocate** | masking a flake is exactly the "weaken a safety check" the shared `safety-checks` block forbids; the skill restates the no-mask rule. |
| **Worker rename ships its queue migration in the same MR** (§Z #473) | `ai/docs/oban-worker-rename.md` (new) + gate reference in `athena:merge-boarding` | relocate (correctness) | incident lore → doc; the merge gate references it. |
| **Final: reconcile tracker ↔ forge both directions** (§Final report) | `athena:admiral-final-report` skill (new) | relocate | prevents the silent tracker-behind-forge drift measured on DND-208/DND-203. |
| **Role, autonomy posture, paired-architect loop, ground/triage judgment** (A, C, D, F, G) | **resident** | — | the irreducible role + judgment the harness-IA rule keeps resident. |

No invariant is deleted. Six are **strengthened** (moved into a hook, a gate, or
a script that mechanically enforces or defines what was prose). The rest are
relocated to a JIT skill or guidance doc with a resident trigger naming the home
— which is the harness-IA mechanism split, not a weakening (a JIT skill can be
not-loaded, which is why every *invariant that can be mechanically enforced* goes
to a hook/gate/script, and the skills carry only the multi-step *procedures*).

---

## 3. The enforced size gate: `ai/bin/check-agent-size`

### 3.1 What it does

A gem-free Ruby check (same shape as `check-guard-messages` /
`check-hooks-registered`), run with bare `ruby`.

- **Metric:** rendered lines = `File.readlines("ai/agents/athena-<name>.md").size`
  — the built artifact, per fixed decision #0.1. It reads the **rendered** file,
  so it must run **after** `build-agents --check` in the gate (which guarantees
  the rendered file is in sync with the template + blocks). Gate ordering below
  puts `build-agents --check` first; if it is stale, that check fails first and
  `check-agent-size` never reports a misleading count.
- **Budget table** (a literal `BUDGETS` hash in the script):

  ```ruby
  BUDGETS = {
    "admiral"     => 500,   # the target this design delivers
    "captain"     => 760,   # current 730 + headroom; tighten in a later pass
    "architect"   => 560,   # current 529 + headroom
    "shipwright"  => 690,   # current 663 + headroom
    "diff-critic" => 140,   # current 111 + headroom
  }.freeze
  ```

  Only `admiral => 500` is a hard target today; the others are set at their
  current rendered size plus a small headroom so the gate does not false-fail an
  un-optimized agent, while still capping regrowth. Each is a one-line edit to
  ratchet down as that agent is optimized.
- **Every rendered `ai/agents/athena-*.md` MUST have a budget entry.** A rendered
  agent with no entry is a **FAIL** (not a skip) — so adding a new agent forces a
  deliberate budget, and an agent can never grow unbounded by being unlisted.
- **Fail condition:** any agent whose rendered count `>` its budget, or any
  rendered agent missing from `BUDGETS`.

### 3.2 The `Fix:` line (LLM-facing, per the repo convention)

On overage:

```
check-agent-size: FAILED — athena-admiral.md is 1034 rendered lines, budget 500 (over by 534).
  Fix: relocate content out of the RESIDENT template ai/agents/athena-admiral.md.in per
  ai/blocks/ops/harness-ia.md's mechanism split — a must-happen invariant → a hook or gate;
  a deterministic procedure → an ai/bin script; a multi-step how-to → a JIT skill; deep
  reference detail → an ai/docs file. Leave a one-line resident trigger naming each new home.
  Do NOT delete a safety invariant to fit (see ai/blocks/ops/safety-checks.md) — move it to an
  enforced home instead. Then run ai/bin/build-agents and re-check. If a budget increase is
  genuinely intended and approved, raise the agent's entry in BUDGETS in ai/bin/check-agent-size.
```

On a missing entry:

```
check-agent-size: FAILED — athena-<name>.md has no BUDGETS entry.
  Fix: add "<name>" => <max-rendered-lines> to BUDGETS in ai/bin/check-agent-size (set it to the
  current rendered count or lower; never above without owner approval).
```

### 3.3 `--self-test`

Fixture dir (tmp), same pattern as the other checks: write a fake
`agents/athena-x.md` of N lines against a budget of N-1 (assert FLAG) and N+1
(assert PASS), plus a fixture agent with no budget entry (assert FLAG). The
self-test carries its own `Fix:` line, and — per `harness-gate`'s discovery
contract — either lives inline (declared in `STATIC_CHECKS`) or as
`ai/bin/…/self-test.sh` (auto-discovered). Simplest: an inline `--self-test`
flag declared in `STATIC_CHECKS`, mirroring `check-guard-messages`.

### 3.4 Wiring

- Add to `ai/bin/harness-gate` `STATIC_CHECKS`, **after** `build-agents --check`:
  ```ruby
  ["build-agents --check",   %w[ai/bin/build-agents --check]],
  ["check-agent-size",       %w[ai/bin/check-agent-size]],
  ...
  ```
  and add `["check-agent-size self-test", %w[ai/bin/check-agent-size --self-test]]`
  (or rely on inline as above).
- Add `check-agent-size` to `GUARD_BINS` in `ai/bin/check-guard-messages` (it is
  a guard that can FAIL, so it must carry `Fix:` — it does, so the meta-check
  passes).
- Mirror it in the shipwright template's canonical gate prose ("add a check here
  AND there", per `harness-gate`'s own header note).
- No `routing.yml` change (that manifest governs blocks/skills, not bin checks).

---

## 4. Line budget (before → after), proving ≤500

Rendered targets per section (resident target from §1; shared blocks unchanged):

| Section | before | after (resident) | delta |
|---|--:|--:|--:|
| A role + autonomy | 32 | 22 | −10 |
| B Inputs | 47 | 14 | −33 |
| C Coordinating as a fleet **[shared]** | 107 | 107 | 0 |
| D As the implementation half | 37 | 16 | −21 |
| E Process header | 2 | 2 | 0 |
| F §1 Ground | 16 | 6 | −10 |
| G §2 Triage | 12 | 5 | −7 |
| H §3 Tracking state | 22 | 8 | −14 |
| I §3a Resume | 42 | 3 | −39 |
| J §3b Notifications | 38 | 3 | −35 |
| K §3c Liveness | 36 | 2 | −34 |
| L §4 Dispatch | 76 | 14 | −62 |
| M §4a Verify fact | 65 | 5 | −60 |
| N §4b Re-read defect | 43 | 3 | −40 |
| O §5 Handle return | 60 | 12 | −48 |
| P §6 Propagate | 13 | 6 | −7 |
| Q §6a Teardown | 25 | 7 | −18 |
| R §6b Boarding | 50 | 3 | −47 |
| S §7 Hard constraints | 108 | 20 | −88 |
| T Final report | 34 | 5 | −29 |
| U Safety check **[shared]** | 34 | 34 | 0 |
| V Never end turn **[shared+bullet]** | 35 | 34 | −1 |
| W Confirm merge | 15 | 2 | −13 |
| X Epic DM | 19 | 6 | −13 |
| Y Act as Athena | 24 | 6 | −18 |
| Z Worker rename | 12 | 2 | −10 |
| AA Flaky→ticket | 30 | 3 | −27 |
| **NEW** Triggers index | 0 | ~15 | +15 |
| **Total** | **1034** | **~365** | **−669** |

**Result ≈ 365 rendered lines**, of which **176 are the untouched shared blocks**
and **~189 are bespoke resident** (well under both the 500 total cap and the
~324 bespoke ceiling). Headroom to the cap: ~135 lines — deliberate, because the
per-section targets are optimistic and the gate is unforgiving.

---

## 5. Staged-PR sequencing for the implementing shipwright

**Enforcement first** (harness-IA #4: invariants must live in an enforced home
*before* the resident prose that carried them is removed). Each PR is green under
`harness-gate` on its own.

**PR 1 — gates & hooks (enforcement, no resident removal yet).**
- Add `ai/bin/check-agent-size` **with `admiral => 1040`** (current + tiny
  headroom) and every other agent's current-size entry. Wire into `harness-gate`
  and `check-guard-messages`. Effect: the size gate exists and enforces
  *no-regrowth* from day one, without failing on today's 1034.
- Add `ai/hooks/forge-auth-guard.sh` (+ `.self-test.sh`), register in
  `ai/hooks/registry.json`, run `scripts/setup-hooks --install`.
- Extend `ai/hooks/forge-identity-guard.sh` to also match `pr merge` / `mr merge`.
- These carry the auth and attribution invariants, so §7/§Y prose can be trimmed
  in PR 4.

**PR 2 — scripts (deterministic procedures).**
- Add `ai/bin/confirm-merged` (+ self-test) — the one definition of "merge
  landed" that §W and `athena:merge-boarding` call.
- (Optional) `ai/bin/retarget-dependent-mr` wrapper for §6; if not, the command
  stays documented in `athena:captain-return`.
- `wt-preflight` and `admiral-report-watch` already exist — no work.

**PR 3 — skills & docs (procedures / reference).** Create, each with a resident
trigger ready to point at it:
`athena:fleet-inputs`, `athena:admiral-resume`, `athena:fleet-liveness`,
`athena:dispatch-captain`, `athena:brief-verification`, `athena:captain-return`,
`athena:merge-boarding`, `athena:admiral-final-report`, `athena:flaky-ticket`;
and `ai/docs/oban-worker-rename.md`. Worked-example measurements (the 2026-09-18
instances, #473 exposure analysis, etc.) move into the tail of their owning skill
so the invariant keeps its evidence. Use `athena:create-skill` for scaffolding;
add `athena:flaky-ticket` to `routing.yml`'s `skills:` preload slot it already
reserves, if a full-body preload is wanted.

**PR 4 — resident trim + turn the cap to 500 (the load-bearing PR).**
- Edit `ai/agents/athena-admiral.md.in`: replace each relocated section with its
  one-line trigger; add the Triggers index; keep the shared `@include`s and the
  resident judgment untouched.
- Run `ai/bin/build-agents` (regenerates `athena-admiral.md`).
- Lower `admiral => 500` in `BUDGETS`.
- `harness-gate` green proves: rendered ≤ 500, every trigger's home exists, every
  guard carries `Fix:`, hooks registered.

**Ordering rule:** the resident removal in PR 4 is safe only because PRs 1–3
already stood up every enforced/scripted/skilled/documented home. A budget ratchet
step *may* be added to PRs 2–3 (e.g. lower `admiral` as each batch of content
actually leaves), but the definitive 500 lands in PR 4 with the trim, never before
the content is gone.

---

## 6. What genuinely cannot move (and why)

- **The three shared `@include` blocks (176 rendered lines):**
  `ops/fleet-coordination` (107), `ops/safety-checks` (34),
  `ops/never-end-turn-waiting` (26) are **cross-agent** — the architect, captain,
  and shipwright carry them via `routing.yml`. They count toward the 500 but must
  **not** be trimmed as part of this admiral-only work: any edit changes every
  consuming agent and is a **separate cross-agent decision**, out of scope here.
  This plan does **not** require touching them (it reaches ~365 without), so no
  cross-agent decision is requested. Flagging per the brief's hard constraint.
- **Role + autonomy posture (A):** the irreducible identity + the
  human-present-vs-`run-autonomously` escalation seam — judgment, not procedure.
- **The concurrency cap (≤5) and the compact "Never…" invariant list (S):**
  runtime invariants about the admiral's own conduct, with **no persisted
  author-time artifact** for a gate to inspect (the state log lives in gitignored
  `ai-artifacts/` and never reaches `harness-gate`, which runs pre-commit on the
  `custom` repo). They stay resident as one-liners; they cannot be hook/gate
  enforced without a runtime supervisor that does not exist today. (A future
  PreToolUse "≤5 concurrent captains" guard is conceivable but is its own ticket.)
- **The state-log anchor (H):** so many steps cite `…/[run-id]/state.md` and the
  status enum that a compact resident anchor is cheaper than a skill round-trip on
  every reference; kept minimal.
- **§4a as a *pure* gate:** the brief listed §4a under "hook/gate," but "did the
  admiral verify a fact before briefing it?" has no author-time artifact to check
  — so it lands as a **skill + a probe list** (and `forge-preflight` already
  scripts the forge half). Honest classification: enforceable *probes* are a
  script; the *discipline* is a skill; it is not a gate.

---

## 7. Access-control note

This is a harness-authoring change, not a product feature: no protected
operation, tenant boundary, or data query is introduced. The one
authorization-adjacent invariant — **auth state is owner-gated, never touched by
the agent** — is *strengthened* here (prose → the `forge-auth-guard.sh` deny
hook), and attribution of forge writes is *strengthened* (identity-guard extended
to the merge write). No access control is weakened; both moves are the "relocate
or strengthen a check" the safety block permits.
