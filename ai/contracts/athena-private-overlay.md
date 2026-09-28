# Athena Private Overlay — contract

**Kind: living normative document.** Amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*.

**Status:** normative. **Adopted:** 2026-09-28 (DND-702). This contract says where
work-domain values live now that `CJPoll/custom` is public, how a harness tool
finds them, and what it does when it cannot. The implementation is
`ai/bin/private-overlay` over `ai/lib/private_overlay.rb` (the rules) and
`ai/lib/private_overlay_resolver.rb` (the env and filesystem reads). Its tests
are `ai/test/private-overlay/self-test.sh`.

**Provenance.** The design record is the Notion page "Design — private work
overlay (custom-work) and its harness integration" (2026-09-25) and its epic
"Harness — lessons from howie (2026-09)". Both are dated records. Where they
disagree with this contract, **this contract wins**. The epic's owner decisions
(2026-09-25) replaced the design's "private repo at `~/dev/custom-work`" with an
on-machine directory holding local-only git history. This contract states the
result only.

**How this document is amended.** Normative prose is amended in place. Each
amendment that supersedes an existing rule gets exactly one paragraph opening
with a bold dated UTC label (`**Later (YYYY-MM-DD):** …`) at the definitional
mention. Purely additive content carries no label. Sections are cited **by
name**, never by number.

**Conformance language.** MUST / MUST NOT / SHOULD / MAY carry their usual force.

## Why

`CJPoll/custom` is public. Work-domain values must not be published in it: work
people and contacts, work Slack ids, work Notion ids, work ticket ids and bodies,
and work repo internals (owner decision on DND-699, 2026-09-25). The public
harness names **keys**; the values live in the overlay, on the machine.

## Discovery

The overlay root is resolved by one rule. There is no scanning and no pointer
file.

1. If `ATHENA_PRIVATE_ROOT` is **set** (even to the empty string), it is
   authoritative. It MUST be an absolute path to a valid root. Set but invalid
   is **MALFORMED**. It never falls through to the default.
2. Otherwise the root is `$HOME/.config/athena/work`. The directory missing is
   **ABSENT**. Present but invalid is **MALFORMED**. A `HOME` that is unset,
   empty or relative is **MALFORMED**: the default cannot be computed, and that
   is an error, not an absence.

A valid root is a directory (a symlink is resolved to its realpath) that:

- is owned by the invoking user, with no group or other permission bits (the
  resolver refuses any; the owner creates it `0700`);
- holds the marker described in *Marker*.

The overlay is **optional**. The public harness MUST work with it absent. It is
created by the owner, never by an agent or an installer run by an agent. It is
never pushed anywhere: it keeps local-only git history (no remote) and is synced
between the owner's machines over ssh.

## States and exit codes

`ai/bin/private-overlay get <file> <.key.path>` ends in exactly one state:

| Exit | State | When |
|---|---|---|
| 0 | FOUND | the value is on stdout and is non-empty |
| 2 | USAGE | bad arguments; `<file>` not `[a-z0-9-]+`; the path not of the form `.key.key[0]` |
| 3 | ABSENT | `ATHENA_PRIVATE_ROOT` unset and the default directory missing |
| 4 | MALFORMED | an invalid root, marker or overlay file; a value that is an empty string, an empty collection, or the wrong type on the way down |
| 5 | KEY_NOT_FOUND | a valid overlay, but the file or the key is missing or `null` |

`status` prints `PRESENT root=…`, `ABSENT probed=…` or `MALFORMED reason=…` on
stdout, with exits 0, 3 and 4. `root` prints the validated root.

Every non-zero exit writes **one** stderr line:

```
private-overlay: <STATE>: key=<file><path> root=<root or probed path>. <reason>. Fix: <action>
```

A value MUST NOT appear on stderr, in a reason, or in any log. A USAGE refusal
reads nothing. An ABSENT Fix says the overlay directory is missing and the
feature is unavailable on this machine, naming the path. It MUST NOT tell anyone
to clone a repository.

## Marker

`<root>/athena-overlay.json`, a JSON object:

```json
{"kind": "athena-private-overlay", "schema": 1}
```

`kind` MUST equal `athena-private-overlay`. `schema` MUST be an integer the
resolver supports (today: `1`). A missing, unparseable, wrong-kind or
unsupported-schema marker is MALFORMED, and the reason says which.

## Overlay files

Values live in `<root>/overlay/<file>.json`, where `<file>` matches
`[a-z0-9-]+` (no `/`, no `..`). A key path starts with `.` and names at least one
key: `.people.owner.user_id`, `.vip_person_ids[0]`. Strings print raw; objects
and arrays print as compact JSON; numbers and booleans print as JSON.

The files and keys the harness uses are declared by the tickets that move each
value (DND-704 and its siblings). Every such key is named in public prose; its
value is not.

## No credentials

The overlay holds identifiers and procedures, never credentials. Tokens and
keys stay where they are today (`~/.claude/*token*`,
`~/.config/athena-inbox-client/`, the GitHub App key). A credential found in the
overlay is a defect to report.

## Consumer obligation

A consumer that needs a work value reads it with `ai/bin/private-overlay get`.

- A non-zero exit is **reported** in the consumer's own output, carrying the
  resolver's stderr line and its Fix. It is never replaced by a guess, a
  lookup by name, or a hardcoded fallback.
- An action that needs the value (a DM, a Notion assignment) is **not taken**
  when the resolve fails. Saying so is the result.
- A tracked file MUST NOT carry the value, in prose, fixtures or tests. Tests
  use synthetic values (`UFAKE00001`, `SYNTH-TOKEN-1`) and fixture roots through
  `ATHENA_PRIVATE_ROOT`.

## Outbound-scan interface

DND-699's scanner (`ai/bin/outbound-scan`) refuses a push or a public forge
write that carries a work-domain value. It reads its bar from the overlay, so
the bar never lives in the public diff it checks. Rules:
`ai/lib/outbound_scan.rb`; reads: `ai/lib/outbound_scan_sources.rb`; tests:
`ai/test/outbound-scan/self-test.sh` and `ai/test/gh-athena-outbound/self-test.sh`.

**Patterns file.** `<root>/outbound/patterns.tsv`. One pattern per line:
`<label><TAB><regex>`. Blank lines and lines starting with `#` are skipped. The
label matches `[a-z0-9][a-z0-9_.-]{0,63}` (at most 64 characters) and is
non-sensitive (`slack-person-3`,
`work-ticket-id`). The regex is a Ruby regular expression (ERE-compatible for
ordinary patterns). Any other line makes the whole file unreadable, reported by
source and line number, never by content.

**Union rule.** The pattern set is the **union** of the working-tree
`outbound/patterns.tsv` and the latest committed copy,
`git -C <root> show HEAD:outbound/patterns.tsv`. A local uncommitted edit can
only add a pattern. Removing one means moving the overlay's `HEAD` to a copy
without it. Residual, stated: anything that moves `HEAD` can lower the floor
(a commit, a `reset`, a `checkout` of an older commit or another branch). An
overlay that is not a git repository, has no commits, or has no committed
`patterns.tsv` has **no floor**, and the scan says so as COULD NOT MEASURE.

**Scan states.** Each is textually distinct:

| Exit | State | Meaning |
|---|---|---|
| 0 | CLEAN | the surface was scanned with at least one pattern, and nothing matched |
| 1 | HITS | at least one match; each is reported as a location plus the pattern **label**, never the matched text |
| 2 | USAGE | the scanner was called wrongly (no mode, two modes, a bad flag); nothing was scanned |
| 3 | COULD NOT MEASURE | the overlay is absent or malformed, the floor is missing, the pattern set is empty or unreadable, a pattern exceeded its match-time budget, or the surface could not be read; the reason names which |
| 0 | WAIVED - NOT SCANNED | `ATHENA_OUTBOUND_WAIVE=<reason>` was set; the reason is printed and logged; this is never printed as CLEAN |

A run that measured prints `SCANNED commits=N lines=M patterns=P hits=H`.

A hit is printed as a location and the pattern label: `path:line (commit <sha>)`,
`commit <sha> message:<n>`, `commit <sha> path <redacted>`, or `<field>:<n>`. A
path that itself matches a pattern is never printed.

**Surfaces.** Three modes of `ai/bin/outbound-scan`, exactly one per run:

- `--pre-push --remote NAME [--url URL]` — git's pre-push stdin. For each pushed
  ref, the commits in `<remote sha>..<local sha>` (a new ref, or a remote tip
  not present locally: every commit not on a `refs/remotes/<NAME>/*` ref). For
  each commit: the lines and paths it **introduces**, and its message. A root
  commit introduces its whole tree. A one-parent commit introduces the added
  lines and new or renamed paths of its diff against that parent. A merge
  introduces only what differs from **every** parent (a combined diff, `--cc`):
  a conflict resolution, or text found in no parent. Content a merge carries in
  from a parent is that parent's. It is scanned where that parent's commits are
  in the pushed range, and it is already on the remote where they are not, so
  skipping it at the merge publishes nothing new. A deleted ref publishes
  nothing. Binary files are skipped and counted (`binary_skipped=N`). Tag
  messages are not scanned.
- `--tree` — every tracked file of the current repository: content and path.
  It is not in `harness-gate` yet: the tree still carries work values until
  DND-704, DND-705 and DND-706 land, and wiring it earlier would turn every
  gate red.
- `--text FILE [--label NAME]` — one file's lines (gh-athena's title and body).

**The pre-push hook.** `ai/git-hooks/outbound-pre-push.sh`, installed by
DND-703's installer at the main checkout's `.git/hooks/pre-push`. It serves
every linked worktree and lane, and it runs the **main checkout's** (landed)
scanner, never a branch's copy. A missing scanner refuses the push (exit 3). An
installed hook marks a machine that must measure, so an ABSENT overlay refuses
the push there.

**The forge path.** `ai/bin/gh-athena` scans every `--title`/`--subject`,
`--body` and `--body-file` (each gh spelling, including `-bVALUE`) of
`pr create|edit|comment|review|merge` and `issue create|edit|comment` before gh
runs; a squash merge's subject and body become a commit made on the server,
where no pre-push hook runs. A short-flag cluster that could hide one of these
fields is refused. The scan runs when the target repository is PUBLIC or its visibility cannot be
read. HITS refuse (exit 1). COULD NOT MEASURE refuses (exit 3), except where the
overlay is ABSENT and the machine is not marked (no outbound pre-push hook in
the harness checkout's common git dir): there the write proceeds with a
WARNING that the text went out unscanned, never a CLEAN line.

**Residuals, stated.** An agent or a human can push with `--no-verify`, set the
waiver, edit the main checkout's scanner, or commit a pattern removal in the
overlay. `gh pr create --fill`, an editor or `--web` body, `gh api` writes, and
other commands (release notes, gists) are not scanned by the forge path. No
scan catches a value it has no pattern for. Each bypass raises the cost or
leaves a trace; none is impossible.

**Consequence for this repo.** The owner's scope (2026-09-25) puts work ticket
ids in the pattern list. Once the overlay holds that pattern and the hook is
installed, harness commit messages and PR bodies can no longer cite work ticket
ids.
