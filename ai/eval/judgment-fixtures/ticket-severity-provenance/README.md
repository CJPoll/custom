# ticket_severity provenance fixtures (DND-1590)

**Kind: dated record (2026-10-01).**

A labelled set for `ai/bin/judgment-eval --use-case ticket_severity`. It
measures whether a trailing `Source:`/`Context:` provenance block pulls
`ticket-severity-v1` up to CRITICAL.

Every id, ticket ref, path and time here is synthetic.

- `OVR-1`..`OVR-8`: paraphrases of eight findings filed after a prod incident.
  Each ends with the same provenance block. The label is the filer's value
  (`tracker_record`); the filer overrode Jev's CRITICAL on each.
- `CTL-*`: controls written against the Severity criteria (`rule_confirmed`).
  - Five are CRITICAL: the defect itself is prod down, data loss, or an
    actively exploitable exposure. Three of them carry the provenance block,
    so dropping it cannot pull them down.
  - Five more cover HIGH, MEDIUM and LOW, with and without the block.

15 of the 21 bodies carry the block, and 6 do not. The 6 are byte-identical
before and after, so they read the model's run-to-run noise.
`ai/skills/athena:ticket-management/test/ticket-classify/self-test.sh` pins
that split against `Classify.sent_body`.

## How it was measured

- **Before:** `corpus.jsonl` as is, the body as filed.
- **After:** the same rows with each body passed through
  `Classify.sent_body`, the function `ticket-classify` sends through.

Both runs go to the same server question set. Measurement only: no run was
applied. Each run file records the corpus it sent: before
`e7601ac4…` (this `corpus.jsonl`), after `b7139e53…` (the same rows through
`Classify.sent_body`), labels `f0e82048…`.

```
ai/bin/judgment-eval --use-case ticket_severity --labels labels.jsonl --corpus corpus.jsonl
```

## Result (`ticket-severity-v1`, `jev-1.13.0`, 2026-10-01)

Two runs per side. Both runs on a side gave the same label on every case
they both scored.

| | before | after |
|---|---|---|
| runs | `498655b8`, `20776c61` | `c00ac5b8`, `6630900b` |
| OVR cases judged CRITICAL | 8/8, 8/8 | 0/8, 0/8 |
| OVR cases exactly right | 0/8 | 3/8 |
| CRITICAL controls kept CRITICAL | 5/5 | 5/5 |
| CRITICAL precision | 5/14 | 5/5 |
| HIGH recall | 2/5 | 5/5 |
| MEDIUM recall | 2/4 | 3/4 |
| LOW recall | 3/7 (2/6 on `20776c61`, one case unscored) | 3/7 |
| accuracy | 12/21 (11/20 on `20776c61`) | 16/21 |

Residual: the four LOW findings are still judged HIGH after the block is
dropped. The block is not what drives that.
