# Build-gate probes for Inbox-on-Channels (P1, P2, P4, P5)

**Kind: dated record** (a probe log in `ai/docs/`; annotate, never rewrite —
`~/dev/custom/CLAUDE.md` → *Documentation conventions*). **Date:** 2026-09-21
(UTC). **Ticket:** DND-284 (T0), epic *Inbox on Channels*. **Design:**
`ai/docs/inbox-channels-design.md` §1 *Inferred*, *The development-flag dialog
is the operational risk* (§4.3), *Ordering* / Phase 0 (§9.7).

**Later (2026-09-22): ABANDONED.** The Inbox-on-Channels delivery mechanism these
probes were gating was **reverted** by owner decision in favor of the
`inbox-wait` background waiter, and the channels-delivery code was removed. This
probe log is retained as the dated record of what was measured on its date;
annotated, not rewritten, per the doc conventions. See
`ai/docs/inbox-channels-design.md` (top annotation) and auto-memory
`autonomous-run-2026-09-21-channels-hold.md`.

**Reachability note:** as of this record the design doc is **not yet on
`origin/main`** — it lives on the unmerged branch `design/inbox-channels`
(`git show origin/design/inbox-channels:ai/docs/inbox-channels-design.md`). Every
`§` citation below resolves against that branch until the design lands. A reader
who greps `inbox-channels-design.md` on `main` and finds nothing should look
there, not conclude the reference is broken (*A failed lookup must never look
like an empty one*, at the document level).

**Purpose.** Phase 0 of the design's *nothing old comes down before the new path
is proven* ordering: measure the five inferred claims the channel design rests
on **before** any T3 launcher code exists ("can step N's inputs exist at step
N"). P1/P2/P4/P5 are recorded here; P3 (optional, `-p` longevity) is not in
scope — the design uses the interactive-in-tmux form.

**P2 is the hard gate**: if the development-flag dialog cannot be answered
non-interactively and the registration confirmed, the whole epic's activation
stops and falls back to PR #47. **P2 result: 5/5 PASS.**

## Environment (verified)

| Fact | Value | How |
|---|---|---|
| Claude Code | **2.1.278** | `claude --version`; banner `Claude Code v2.1.278` |
| Model in launched session | Fable 5.1, medium effort | session banner (default model; any model works for the attendant) |
| Account | **Claude Max** (`claude_max`; org record exists, not Team/Enterprise) | session banner `· Claude Max`; no org-block line (P5) |
| Node | v24.10.0 (asdf shim), no bun | `node --version` |
| tmux | 3.5a at `/usr/bin/tmux` (`/usr/sbin/tmux` is a broken usrmerge symlink — sandbox denies it) | `/usr/bin/tmux -V` |
| `MCP_PROTOCOL_NEGOTIATION` | **unset** (left unset per the Negotiation-bug row of design §1 *Confirmed*) | `echo` |
| MCP SDK | `@modelcontextprotocol/sdk` 1.30.0 | installed into the scratch project |

## Method — the stub and the scratch harness

- **Stub:** `ai-artifacts/probe/inbox-channels/stub.mjs` (gitignored scratch, not
  committed as production code). A minimal stdio MCP server that (a) declares
  `capabilities.experimental['claude/channel'] = {}`, (b) logs at startup which
  `CLAUDE_AGENT_*` keys are in its subprocess env (P4), and (c) runs a
  `127.0.0.1:<port>` HTTP receiver (P2/P5 launches on `:8788`; the P1 idle
  session on `:8791`, so each session's stub binds its own port) — a POST turns into exactly one
  `notifications/claude/channel` event whose `content` names a `PROBE-ACK-<nonce>`
  token the session is asked to echo (drives P1). Bind failure is non-fatal (the
  channel capability does not need HTTP).
- **Isolation:** registered **user-scope** as `athena-inbox-probe`
  (`claude mcp add -s user … node <abs>/stub.mjs`), launched from a **scratch
  project dir with its own git repo** so no production registry entry, inbox,
  hook, or `.mcp.json` is touched. The stub listens on `127.0.0.1` only. Torn
  down at the end (kill sessions + `claude mcp remove -s user athena-inbox-probe`).
- **Launch (exactly as T3 will):**
  `tmux new-session -d … claude --dangerously-load-development-channels server:athena-inbox-probe --permission-mode default`.
- **Conformance to the ticket:** the stub is the docs' localhost webhook receiver
  on `:8788`, exactly as the ticket describes.
- **Deviation from the ticket's method, noted:** the stub is registered
  **user-scope** (as the ticket says), and this choice — rather than a project
  `.mcp.json` — avoids a recurring per-project MCP-consent dialog (see the dialog
  inventory below), a finding that simplifies T3.
- **Safe-wait:** every wait blocks on a process or is a paced, bounded poll
  (2–5s cadence, capped iterations); no spin.

## Dialog inventory (what a cold launch actually shows)

Three *candidate* dialog surfaces exist; #2 did not appear under user-scope
registration, so a cold launch in a fresh dir actually shows **two** (folder-trust,
then dev-channels), and only the dev-channels dialog recurs:

1. **Folder-trust dialog — one-time per directory** (persisted in `~/.claude.json`;
   did NOT reappear on launches 2–5). Verbatim:
   ```
    Accessing workspace:
    /home/cjpoll/.local/worktrees/custom/dnd-284-channel-probes/ai-artifacts/probe/inbox-channels
    Quick safety check: Is this a project you created or one you trust? ...
    Claude Code'll be able to read, edit, and execute files here.
    Security guide
    ❯ No, exit
      Yes, I trust this folder
    Enter to confirm · Esc to cancel
   ```
   **Answered by:** `send-keys Down`, then `send-keys Enter` (moves to "Yes, I
   trust this folder" and confirms).

2. **"New MCP server found" / MCP-consent dialog — DID NOT APPEAR.** Because the
   server is registered **user-scope** (explicitly added by the user), Claude
   Code did not prompt for MCP consent. A project-scope `.mcp.json` server would
   show this dialog; user-scope avoids it. (Refines design *The development-flag
   dialog is the operational risk* (§4.3), which lists an MCP-consent dialog
   among the one-time install steps — under user-scope there is none.)

3. **Development-channels warning — EVERY launch** (matches *The development-flag
   dialog is the operational risk* (§4.3): "Every launch shows a full-screen
   warning"). Verbatim:
   ```
     WARNING: Loading development channels

     --dangerously-load-development-channels is for local channel development only. Do not use this option to run channels you
     have downloaded off the internet.

     Please use --channels to run a list of approved channels.

     Channels: server:athena-inbox-probe

     ❯ 1. I am using this for local development
       2. Exit

     Enter to confirm · Esc to cancel
   ```
   **Answered by:** a single `send-keys Enter` (option 1 "I am using this for
   local development" is pre-selected).

**Net per-launch cost for the standing attendant (T3):** exactly ONE full-screen
dialog (the dev-channels warning), dismissed by one `Enter`. This is better than
the *development-flag dialog* risk section (§4.3) feared: folder-trust and
MCP-consent do not recur.

## Registration notice (verbatim)

After the dev-channels dialog is accepted, the dim notice appears in the pane:

```
▎ Channels (experimental) messages from server:athena-inbox-probe inject directly in this session · restart without
▎ --dangerously-load-development-channels to stop
```

Its presence is the registration proof (design *The development-flag dialog is
the operational risk* (§4.3) and *Making a dropped event observable* (§3.4):
absence is a **fault**, never a quiet channel). `/mcp` corroborates: `athena-inbox-probe · ✔ connected`.

---

## P1 — an idle session still receives an event and the turn fires

**Claim (§1 Inferred):** an interactive session in tmux, idle, still receives a
`<channel>` event and the turn fires. The design cites "2h idle".

**Smoke (short idle, PASS):** a session that had been idle since launch received
a POST-triggered event. The pane showed the inbound line
`← athena-inbox-probe: PROBE-EVENT <nonce>: …`, the model started a turn
(`✽ Unfurling… thinking`), echoed `● PROBE-ACK-<nonce>`, and completed
(`✻ Cooked for 7s · done`). Wake latency ≈ **5 s** to turn-start.

**Bounded idle probe (PASS):** the P1 session was launched, registered, and left
strictly idle (no input, no events) for **720 s (12 min)**. A single POST at
`18:18:14` then triggered one event; the pane showed the inbound line, the model
woke, echoed `PROBE-ACK-<nonce>`, and completed. Wake latency ≈ **10 s** from
POST to ACK. Full record: idle from `18:06:14` → event `18:18:14` → done
`18:18:25`. No timeout or missed wake after 12 min idle.

**True-2h assertion: `n/a — needs a longer-running probe.`** A 2h idle is
impractical within a single work turn. Per the dispatch brief, the true-2h
result is recorded as `n/a`, NOT fabricated. The wake **mechanism** is proven
(smoke + bounded idle); what remains unproven is only whether a multi-hour idle
introduces a timeout. **Verdict: PASS for the mechanism; the 2h-specific
assertion is `n/a`.** See *Gaps surfaced* below.

## P2 — the development-flag dialog is answerable non-interactively (THE GATE)

**Claim (§1 Inferred):** the full-screen warning can be answered by `send-keys`
and the registration confirmed by grepping the pane for the dim notice.

**Procedure:** 5 consecutive **cold** launches (fresh `claude` process each,
same scratch dir). Each: launch → (folder-trust already persisted) → `send-keys
Enter` on the dev-channels dialog → assert the registration notice within a
bounded poll → kill.

| Launch | Dialogs shown | Keys sent | Notice observed | Org-block line |
|---|---|---|---|---|
| 1 | dev-channels | `Enter` | yes | none |
| 2 | dev-channels | `Enter` | yes | none |
| 3 | dev-channels | `Enter` | yes | none |
| 4 | dev-channels | `Enter` | yes | none |
| 5 | dev-channels | `Enter` | yes | none |

**Verdict: P2 = 5/5 PASS.** The dialog is deterministically answerable by a
single `Enter` (option 1 pre-selected), and the registration notice naming
`server:athena-inbox-probe` appears every time. `claude --version` = 2.1.278.

## P4 — does the MCP subprocess env carry `CLAUDE_AGENT_*`?

**Claim (§1 *Inferred* / *What the shim is* (§3.2)):** if absent, the shim may reuse `inbox-wait`; if
present, it must use its own `fs.watch` fallback.

**Result: ABSENT.** The stub, spawned by the real interactive
`--dangerously-load-development-channels` session, logged on two independent launches:
```
CLAUDE_AGENT_keys=<none> CLAUDE_AGENT_ID=<unset> CLAUDE_AGENT_TYPE=<unset>
```
(Controlled for: the launching shell's own env carries no `CLAUDE_AGENT_*`
keys, so this is a true negative, not an inherited blank.)

**Verdict: PASS — `CLAUDE_AGENT_*` is absent.** T2's shim **may reuse
`inbox-wait`** as its blocking waiter; the `fs.watch` fallback is not forced.

## P5 — does a Max account with an `organizationUuid` register channels?

**Claim (§1 *Inferred*; the Org-gating row of §1 *Confirmed* quotes the upstream
Claude Code docs):** "Pro and Max users without an organization skip these checks
entirely"; the startup notice names the problem if the account is instead gated.

**Result:** across all 5 launches, no "blocked by org policy" / "not registered"
/ organization-gating line appeared; the registration notice appeared naming the
server; the banner renders `· Claude Max`.

**Verdict: PASS.** This `claude_max` account (with an org record that is not
Team/Enterprise) is treated as "without an organization" for the
`channelsEnabled` check — channels register.

---

## Informational (feeds T3, not a gate)

- **`/mcp` connected:** `athena-inbox-probe · ✔ connected` (User MCPs).
- **One-bell context cost:** a single bell + minimal-response turn appended
  ≈ **4287 bytes** to the session transcript (`stat` on the session `.jsonl`
  before/after). Informative for the *Supervision and lifecycle* rotation bounds
  (§4.2) (transcript-bytes bound).
- **Mid-turn batching:** `n/a — not independently reproduced.` The attempt sent
  a "think for 20s" prompt then fired two events, but the model completed the
  initial turn faster than the events arrived, so each event fired its own turn
  rather than batching. Holding the model genuinely busy long enough to batch
  was not arranged. The docs (§1 *Confirmed*) state events batch onto the next turn when the
  session is busy; this probe neither confirms nor contradicts it. Recorded
  `n/a`, not `0`.

## Gaps surfaced to the admiral (Pass-2, non-blocking)

1. **P1 2h vs practical idle.** The ticket asks for a `>= 2h` idle result; the
   dispatch brief overrides this to a practical bounded interval with the 2h
   assertion recorded `n/a`. The wake mechanism is proven; only the multi-hour
   timeout question is open. A longer-running (out-of-band) probe would close it
   before the attendant is relied on for genuinely long idles.
2. **Fewer dialogs than the design feared.** Design *The development-flag dialog
   is the operational risk* (§4.3): under user-scope registration the standing
   session shows exactly ONE recurring full-screen dialog (dev-channels), not the
   folder-trust + MCP-consent + dev-channels set that section enumerates as
   install steps. Its per-launch operational risk is one `Enter`, deterministic
   on 2.1.278.
3. **Version-pin obligation confirmed real.** The dialog text, the pre-selected
   option, and the notice string are all 2.1.278-specific; the same *development-
   flag dialog* section's (§4.3) "re-verify P2 on every Claude Code upgrade" is
   warranted — the send-keys sequence is coupled to this exact dialog layout.

## Teardown

`tmux kill-session` for every `dnd284-*` probe session; `claude mcp remove -s
user athena-inbox-probe`; scratch dir under `ai-artifacts/probe/` is gitignored.
Production inbox, registry entries, hooks, and `~/.claude.json` `mcpServers`
(other than the removed probe entry) untouched throughout.
