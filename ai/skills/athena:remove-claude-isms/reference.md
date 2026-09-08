# Reference: catalog of AI-isms / claude-isms and their fixes

The exhaustive list behind [`SKILL.md`](SKILL.md). Each entry is: the tell, why
it reads as AI, and how to fix it. Remember the core principle — **thin and
vary, don't ban.** A single instance is usually fine; the problem is density
and clustering.

---

## 1. Punctuation

### Em-dash overuse
The single most-cited tell. Multiple em dashes per paragraph, used where a
comma, period, colon, or parentheses would read more naturally.
- **Fix:** Keep at most one per few paragraphs. Recast the rest — but *vary* the
  replacement (comma here, full stop there, a colon, occasionally parentheses).
  Don't replace every dash with the same mark; that's just a new tell.
- **Not a problem when:** a lone em dash sets off a genuine aside or break in
  thought. Leave it.

### Parenthetical hedging
Constantly tucking clarifications into parentheses instead of committing to the
sentence. Reads as the model hedging its bets.
- **Fix:** Fold the aside into the main clause, or make it its own sentence, or
  cut it if it adds nothing. Reserve parentheses for genuine asides.

---

## 2. Sentence structure & rhetorical tics

### Negative parallelism / antithesis — "It's not X, it's Y"
The most recognizable structural tell, in all its forms:
- "It's not X — it's Y."
- "It's not just X; it's Y."
- "This isn't about X. It's about Y."
- "Not only X, but also Y."
- **Fix:** State Y directly. If the contrast with X actually matters, keep it
  once and phrase it plainly; don't use the template as a rhythm crutch.

### Rule of three / tricolon padding
Everything arrives in threes — three adjectives, three-item lists, three
parallel clauses, often back-to-back.
- **Fix:** Vary list lengths (two, four, one). Cut the third item when it's
  filler added only for cadence. One deliberate tricolon is elegant; every
  sentence in threes is the tell.

### "From X to Y" framing
"From startups to enterprises…", "from onboarding to offboarding…" as a stand-in
for actually naming the range.
- **Fix:** Name the specific cases, or state the scope plainly.

### "Whether you're a … or a …"
Audience-hedging setup that pretends to address everyone.
- **Fix:** Address the actual reader. Cut the construction.

### Vague scale/importance claims
"plays a pivotal/crucial role", "a key factor", "cannot be overstated".
- **Fix:** Say what it does, concretely. Delete the meta-claim about importance.

---

## 3. Overused vocabulary ("slop" words)

Replace with plain, specific alternatives that fit the sentence — **not** a
single global substitute (swapping every "delve" for "explore" is its own tell).

**Tier 1 (kill on sight — rare in unforced human writing):**
`delve`, `tapestry`, `underscore` (as verb), `intricate`, `meticulous`,
`showcase`.

**Tier 2 (promotional register — suspicious in clusters):**
`robust`, `seamless`, `vibrant`, `realm`, `boasts (a)`, `landscape` (as
metaphor), `testament (to)`, `pivotal`, `leverage` (as verb), `foster`,
`navigate` (metaphorical), `elevate`, `unlock`, `harness`, `streamline`,
`empower`, `bespoke`, `myriad`, `plethora`, `crucial`.

**Metaphor clichés:** symphonies, tapestries, "a complex dance", "a symphony
of", "the beating heart of".
- **Fix:** Drop the metaphor and describe the actual thing.

---

## 4. Filler: openers, closers, transitions

### Opener filler
- "In today's fast-paced / rapidly evolving digital landscape…"
- "In the world of …"
- Hooks: "Picture this:", "Have you ever wondered…", "What if I told you…",
  "This is where it gets interesting."
- **Fix:** Delete. Open with the actual point.

### Mid-body filler
- "It's important to note that…", "It's worth noting that…"
- "Let's dive in / Let's delve into…"
- "At the end of the day…", "The truth is…", "Here's the thing…"
- **Fix:** Delete the frame; keep the noted thing. If it's important, just say it.

### Robotic transitions
`Furthermore`, `Moreover`, `Additionally`, `In addition` stacked as connective
tissue between points they don't actually connect.
- **Fix:** Remove, or replace with a real logical link, or start a new sentence.

### Closer filler
- "In conclusion / In summary…", "Ultimately…", "All in all…"
- The reflexive wrap-up paragraph that restates everything already said.
- **Fix:** End on the last real point. A short summary is fine only when the
  piece is long enough to need one.

---

## 5. Formatting

### Over-formatting simple content
Emoji header + three bullets + a bold **"Key Takeaway"** for something that
warranted one sentence.
- **Fix:** Match structure to substance. Short answer → short prose.

### Decorative emoji
👉 ✅ ❌ 🚀 as bullet markers or emphasis.
- **Fix:** Remove unless the context genuinely calls for them.

### Reflexive "**bold term:** explanation" lists
Turning flowing prose into a bulleted glossary because it looks organized.
- **Fix:** Use a list when the content is genuinely a list; otherwise write
  prose. Don't bold every lead-in term.

### Uniform paragraph/section shape
Every section the same length, every paragraph three sentences, headers on
everything.
- **Fix:** Let structure follow the content's real shape.

---

## 6. Tone & behavior (especially for the agent's own replies)

### Sycophancy
"You're absolutely right!", "Great question!", "Excellent point!", "I'd be happy
to help!" — reflexive validation, often regardless of whether the user asserted
anything.
- **Fix:** Skip the flattery. Answer. Agreement should be earned and specific
  ("Yes — because …"), not a reflex.

### Performative enthusiasm
"exciting", "incredible", "powerful", "amazing", "game-changing".
- **Fix:** Cut the adjective or replace it with a concrete claim about what the
  thing does.

### Compulsive hedging
Every statement softened — "often", "typically", "generally", "can be", "may",
"in many cases" — as risk aversion rather than genuine uncertainty.
- **Fix:** State it plainly when you're confident. Reserve hedges for real
  uncertainty, and then say *why* it's uncertain.

### Vague authority
"studies have shown", "experts agree", "research suggests", "a recent survey
found" with nothing cited; "a popular app", "leading professionals" instead of
names.
- **Fix:** Cite the specific source, name the specific thing, or say you don't
  have a source.

### Both-sides non-commitment
Ending with "ultimately, it depends" / "there's no one-size-fits-all answer"
when the reader asked for a recommendation.
- **Fix:** Give the recommendation. Note the one real caveat if there is one.

---

## Quick self-check (agent's own drafts)

Before sending, scan your draft for:
- [ ] More than ~1 em dash per few paragraphs
- [ ] Any "not X, it's Y" / "not just X but Y" construction
- [ ] Lists/enumerations all in threes
- [ ] Tier-1 slop words (delve, tapestry, underscore, intricate, meticulous)
- [ ] Filler openers/closers ("It's important to note", "In conclusion")
- [ ] Emoji headers / decorative emoji / bold-term lists on light content
- [ ] "You're absolutely right" / "Great question" / performative enthusiasm
- [ ] Claims of authority with no source

If several are clustered, thin them. If they're isolated, leave them.
