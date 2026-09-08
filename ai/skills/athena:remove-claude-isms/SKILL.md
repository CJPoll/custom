---
name: athena:remove-claude-isms
description: Edit prose to strip "AI-isms" / "claude-isms" — the tics that make writing read as machine-generated (em-dash overuse, "it's not X, it's Y" negative parallelism, rule-of-three padding, slop vocabulary like "delve/tapestry/robust", filler openers and closers, over-formatting, and sycophantic tone). Use when asked to remove AI-isms/claude-isms, de-slop, "humanize", or make a draft not sound like AI — or to self-check the agent's own draft before sending. Rewrites to preserve meaning and voice; it does not blanket-ban punctuation.
argument-hint: "[file-or-text | nothing = clean your own last draft]"
allowed-tools: Read Edit Write
---

# athena:remove-claude-isms

Rewrite prose so it stops reading as machine-generated, **without** flattening
it into stilted, punctuation-starved text. The goal is to remove the *tells* —
and the clustering of tells — while keeping the meaning, the facts, and the
author's voice intact.

The full catalog of tells and their fixes lives in [`reference.md`](reference.md).
Read it before a substantial edit; the summary below is enough for a quick pass.

## Core principle: density, not prohibition

None of these devices is banned. An em dash, a tricolon, a "not X but Y" — each
is fine once. What marks writing as AI is **frequency and clustering**: three
em dashes a paragraph, every list arriving in threes, four filler transitions
on one page. So the job is to *thin and vary*, not to search-and-destroy.

Corollary rules:
- **Preserve meaning and specifics.** Never drop a fact, caveat, or number to
  make a sentence "cleaner." Rewrite the phrasing, keep the content.
- **Preserve the author's voice.** If the source is deliberately punchy, formal,
  or casual, keep that register. Don't neutralize it into house style.
- **Don't overcorrect.** Replacing every em dash with a comma, or every "delve"
  with "explore," just trades one tell for another. Vary the fix.
- **Leave code, quotes, and cited text alone.** Only edit the prose you were
  asked to edit. Never rewrite someone else's quoted words.

## Default: just fix it

The default is to **apply the edits, not describe them.** Don't ask for
confirmation, don't present a plan, don't narrate each change — clean the text
and hand back the result. The only time you pause first is when a "fix" would
require dropping or altering a fact (see step 4); prefer keeping the fact.

- **A file** → edit it **in place** with Edit/Write, then give a one-line
  confirmation (path + a rough count, e.g. "cleaned; thinned ~9 em dashes, cut 3
  filler openers"). Don't paste the whole rewritten file back.
- **Pasted text** → return only the cleaned text, nothing wrapped around it.
- **Your own last draft** → silently apply the passes before sending; no
  meta-commentary about having done so.

Produce a categorized change summary **only if the user explicitly asks** what
changed (or says "show me the diff" / "explain the edits"). "Just fix it" is the
contract; the explanation is opt-in.

## Process

1. **Determine the target.** A file or pasted text → edit that. Nothing → clean
   *your own* most recent draft before sending it.
2. **Scan for clusters, not single instances.** Read the whole piece first and
   note where tells pile up. A lone tell in an otherwise clean page is usually
   fine; leave it.
3. **Run the passes** (below). Fix the densest offenders first.
4. **Read it back aloud in your head.** If a fix made a sentence stilted or
   changed its meaning, revert or re-do it. Natural beats "clean." If the only
   way to remove a tell is to drop a fact, caveat, or number — keep the fact and
   leave the tell.
5. **Apply and confirm.** Write the result (in place for a file), then give the
   one-line confirmation. No change log unless asked.

## The passes

Work through these in order. Details and per-item swaps are in `reference.md`.

1. **Punctuation** — Thin em-dash overuse (aim for at most one per few
   paragraphs; recast the rest as commas, periods, parentheses, or colons,
   varied). Break up habitual parenthetical hedging — commit to the sentence.
2. **Sentence structure** — Kill negative parallelism ("It's not X, it's Y",
   "not just X but Y", "It isn't about X — it's about Y"). Break up rule-of-three
   / tricolon padding so enumerations aren't all threes. Cut "from X to Y" and
   "whether you're a … or a …" scaffolding.
3. **Vocabulary** — Replace slop words (delve, tapestry, underscore, intricate,
   meticulous, showcase, robust, seamless, vibrant, realm, boasts, landscape,
   testament, pivotal, leverage, foster) with plain, specific alternatives that
   fit the sentence. Don't reach for a single global substitute.
4. **Filler openers / closers / transitions** — Delete "In today's fast-paced
   …", "It's important/worth noting that", "Let's dive in", "In conclusion",
   hooky openers ("Picture this:", "Have you ever wondered", "What if I told
   you"), and robotic connectives ("Furthermore", "Moreover", "Additionally")
   when they add nothing. Say the thing directly.
5. **Formatting** — Right-size structure. Don't answer a one-sentence point with
   an emoji header + three bullets + a "Key Takeaway". Drop decorative emoji
   (👉 ✅ ❌) and gratuitous **bold-term:** lists where prose reads better. Match
   formatting weight to content weight.
6. **Tone / behavior** (for the agent's own replies especially) — Cut
   sycophancy ("You're absolutely right!", "Great question!"), performative
   enthusiasm ("exciting", "incredible", "powerful"), unsolicited hedging
   ("often", "typically", "generally", "may" softening every claim), and vague
   authority ("studies have shown", "experts agree") with no source. Be direct;
   cite specifics or say you're unsure.

## When to stop

Stop when the remaining tells are isolated and unobtrusive — not when the text
is sterile. If you've removed so much that the writing lost its rhythm or its
point, you went too far. A human wrote with some of these devices too; the tell
was always the machine's *overuse* of them.
