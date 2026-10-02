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
created from the public skeleton with `scripts/setup-private-overlay --init`,
run as *Installer* → *Who runs it* says. No agent creates it on its own
initiative, and no installer creates it as a side effect of another mode. It is never pushed anywhere: it keeps local-only git history
(no remote) and is synced between the owner's machines over ssh.

**Later (2026-09-28):** this paragraph said the overlay is "created by the
owner, never by an agent or an installer run by an agent". Superseded by
DND-703, which ships the skeleton and `--init`, and by the owner's direction of
2026-09-28 07:15Z letting the harness session create the directory (DND-701's
non-owner step). What stays forbidden is creation nobody asked for.

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

Keys in use (DND-704), with where each is used:

| File | Key | Shape | Used by |
|---|---|---|---|
| `slack` | `.people.owner.user_id` | Slack user id | `athena:slack` (owner DM, click check), `athena:ticket-management` (Needs Attention DM), `ai/bin/judgment-label`, `ai/bin/judgment-eval` (`--use-case slack_routing`) |
| `slack` | `.people` | `{alias: {user_id, name}}` | `athena:slack` → *Reading the workspace* |
| `slack` | `.channels` | `{name: channel id}` | `athena:slack` → *Reading the workspace* |
| `slack` | `.channels.owner_dm` | DM channel id | `athena:epic-clustering` (the daily digest) |
| `notion` | `.work.owner_person_id` | notion-work person id | `athena:ticket-management`, `athena:flaky-ticket` (after the roster) |
| `notion` | `.work.tickets_data_source` | work Tickets data source id | `mark-in-progress`, `ai/bin/lead-time` (the work tracker's dispatch stamp, DND-1341; `ai/lib/dispatch_trackers.rb`) |
| `notion` | `.work.ticket_prefix` | the work tickets' `ID` prefix (2-10 upper-case letters) | same |
| `notion` | `.work.in_progress_property` | name of the work Tickets date property holding the dispatch stamp | same |
| `notion` | `.work.first_dispatch_from` | array of status names a move to `In Progress` from which is a first dispatch | same |
| `gitlab` | `.group` | the work GitLab group path (string) | `ai/bin/glab-athena refresh` (resolves the group id to mint the service-account token; DND-1668) |
| `notion` | `.vip_person_ids` | array of notion-work person ids | declared as the VIP seed in `athena-events.md`; the server keeps its own copy in its config |

The Athena bot's own Slack user and bot ids are not overlay keys: `athena:slack`
`bin/whoami` reports the live identity.

**`secrets.json` (optional).** `overlay/secrets.json` declares the work-domain
per-machine secrets: their names, paths, copies, consumers and restart
commands. It uses the registry schema in `ai/contracts/athena-machine-secrets.md`
→ *The registry*. Like every overlay file it holds names and paths only, never
a value (*No credentials*). `ai/bin/check-machine-secrets` and
`ai/bin/with-secret` read it when the overlay is present. An absent overlay
means no work-domain secrets are declared on that machine.

## No credentials

The overlay holds identifiers and procedures, never credentials. Tokens and
keys stay where they are today (`~/.claude/*token*`,
`~/.config/athena-inbox-client/`, the GitHub App key). A credential found in the
overlay is a defect to report. Where a secret lives, how it is declared and
how it is loaded: `ai/contracts/athena-machine-secrets.md`.

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

## Installer

`scripts/setup-private-overlay` wires the overlay into a machine. Rules:
`ai/lib/private_overlay_install.rb`; reads and writes:
`ai/lib/private_overlay_install_host.rb`; tests:
`scripts/test/setup-private-overlay/self-test.sh`. Every mode answers
`--help`; `--dry-run` previews `--init`, `--install` and `--remove`.

**Skeleton.** `ai/private-overlay/skeleton/` is the public template: the
marker, `overlay/slack.json`, `overlay/notion.json` and `overlay/gitlab.json` as empty objects,
`outbound/patterns.tsv` with comments only, `.claude-plugin/marketplace.json`
(marketplace `custom-work`), `plugins/work/.claude-plugin/plugin.json`, a
synthetic `work:overlay-probe` skill for the plugin-loading measurement, and a
README carrying *No credentials*. It MUST NOT carry a work-domain value.

**`--init`.** Resolves the root by the *Discovery* rule. A root that cannot be
computed (an empty or relative `ATHENA_PRIVATE_ROOT`, a bad `HOME`) is exit 4.
It refuses a path that already exists (exit 5), whatever is there. Otherwise it copies the skeleton
(root and directories `0700`, files `0600`), runs `git init`, and makes one
local commit. It never adds a remote. It ends by reading the root back through
the resolver, and a root that does not read PRESENT is exit 4.

A fresh overlay is PRESENT with zero patterns, so from that moment every
outbound scan on the machine is COULD NOT MEASURE and gh-athena refuses public
writes (*The forge path* below). `--init` prints that consequence and its Fix.
Commit at least one pattern right after `--init`, before anything else on the
machine needs gh-athena.

**`--install`** is merge-only and idempotent. It requires a PRESENT overlay
(ABSENT is exit 3 with a Fix naming `--init`; MALFORMED is exit 4), then:

1. registers the marketplace: `claude plugin marketplace add <root> --scope user`;
2. installs `work@custom-work` at user scope, or enables it when disabled;
3. writes the pre-push hook at `git rev-parse --git-path hooks/pre-push` of the
   **main** checkout: a wrapper that carries a fixed marker line and `exec`s
   the main checkout's `ai/git-hooks/outbound-pre-push.sh`. A missing target
   fails the `exec`, so the push is refused.

It never overwrites what it did not write. A pre-push hook without the marker
line, or a `custom-work` marketplace registered from another source, is
reported and left alone, and the plugin is then not installed. The hook is
written only when the main checkout's scanner reports CLEAN on an empty probe:
with no committed pattern, an installed hook would refuse every push.

**`--check`** is read-only and prints one line per component, `overlay`,
`marketplace`, `plugin` and `hook`, each `OK` or its gap, with a Fix. The hook
line is `hook: OK` only when this installer's hook is present, targets this
main checkout, and the scanner can measure. Anything else is `hook: NOT
ACTIVE (<why>)`, never OK. With no valid overlay root to compare against, a
registered `custom-work` is `marketplace: UNVERIFIED`, never OK. Exit 0 when all four are OK, 3 when any read
failed (`COULD NOT MEASURE`: no `claude` on PATH, unparseable `claude` JSON,
an unresolvable hook path), else 1.

**`--remove`** removes this installer's hook, uninstalls the plugin and removes
the marketplace. It never deletes the overlay directory, a foreign hook, or a
`custom-work` marketplace registered from another source or one it cannot
confirm as this overlay's (UNVERIFIED), nor the plugin while such a
marketplace holds the name. It manages the user-scope plugin only.

**Who runs it.** `--init` and `--install` change the owner's machine: its
Claude Code user settings and the main checkout's `.git/hooks`. Who may run
them: `~/.claude/CLAUDE.md` → *Owner approval policy* → *Notify after*, as for
the other committed installers. `--check` is read-only and anyone may run it.
Tests use a fixture repo, a temp `HOME`, a temp `CLAUDE_CONFIG_DIR` and a stub
`claude`.

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
`path:line` (tree mode), `commit <sha> message:<n>`, `commit <sha> path
<redacted>`, `tracked path <redacted>`, or `<field>:<n>`. A path that itself
matches a pattern is never printed: every rendered path is checked against the
patterns at render time. Each pattern is matched on its own, never through a
combined regex. An unexpected scanner error is COULD NOT MEASURE and names only
the error's class, never its message, which could quote a pattern.

**Surfaces.** Three modes of `ai/bin/outbound-scan`, exactly one per run:

- `--pre-push --remote NAME [--url URL]` — git's pre-push stdin. For each pushed
  ref, the commits in `<remote sha>..<local sha>` (a new ref, or a remote tip
  not present locally: every commit not on a `refs/remotes/<NAME>/*` ref). When
  git passes a URL as NAME, it is mapped back to the configured remote with that
  url or pushurl. For
  each commit: the lines and paths it **introduces**, and its message. A root
  commit introduces its whole tree. A one-parent commit introduces the added
  lines and new or renamed paths of its diff against that parent. A merge
  introduces only what differs from **every** parent (a combined diff, `--cc`):
  a conflict resolution, or text found in no parent. Content a merge carries in
  from a parent is that parent's. It is scanned where that parent's commits are
  in the pushed range, and it is already on the remote where they are not, so
  skipping it at the merge publishes nothing new. A deleted ref publishes
  nothing. Every file is diffed as text (`--text`, no textconv, no external
  diff), so a `.gitattributes` in the pushed commit cannot mark its own content
  binary and skip the scan. Tag messages and the author and committer
  identities are not scanned.
- `--tree` — every tracked file of the current repository: its path and its
  INDEX copy (what is tracked, not an unstaged working-tree edit). Binary
  content is scanned too, as bytes split on newlines: no file opts out.
  `harness-gate` runs it through `ai/bin/check-outbound-tree` (see *The gate
  check* below).
- `--text FILE [--label NAME]` — one file's lines (gh-athena's title and body).

**Later (2026-09-28):** the `--tree` bullet said "It is not in `harness-gate`
yet: the tree still carries work values until DND-704, DND-705 and DND-706
land". Superseded: with those deletions the tree scans 0 hits, and DND-699
wired the check described in *The gate check*.

**The gate check.** `ai/bin/check-outbound-tree`, declared in `harness-gate`,
runs tree mode over the checkout under test. Verdict rules:
`ai/lib/outbound_tree_check.rb`; the mark probe: `ai/lib/outbound_mark.rb`;
tests: `ai/test/check-outbound-tree/self-test.sh`. It reads the same mark as
the forge path below: the outbound pre-push hook at the path
`git rev-parse --git-path hooks/pre-push` resolves (the common git dir's
`hooks/`, or `core.hooksPath` when set). A mark that cannot be determined
counts as marked, and so does a directory at that path (the forge path reads
it as unmarked). Every ABSENT verdict prints the hook path it probed.

| Overlay | Marked (or undeterminable) | Unmarked |
|---|---|---|
| ABSENT | FAIL (exit 3), `COULD NOT MEASURE` | pass (exit 0), `NOT MEASURED (no overlay on this unmarked machine; …)` |
| MALFORMED, zero patterns, no committed floor, unreadable tree | FAIL (exit 3), `COULD NOT MEASURE` | the same |
| HITS | FAIL (exit 1): a location and `label=<label>` per hit (a matching path is redacted), never the text, with `Fix:` | the same |
| CLEAN | pass (exit 0), `CLEAN` + the `SCANNED` line | the same |

`NOT MEASURED` is textually distinct from `CLEAN`: it prints no `CLEAN`, no
`OK` and no `SCANNED` line. The check calls the scan's libraries, not the CLI,
so `ATHENA_OUTBOUND_WAIVE` does not waive it: the waiver is for a push. The
bar is the overlay's pattern list, outside the diff (`~/dev/custom/CLAUDE.md`
→ *A check's own bar must not live in the diff it is checking*).

Residual, stated: removing the hook mark from a machine with no overlay turns
the check into `NOT MEASURED`, a pass. The mark is outside the diff too (it is
in the common git dir, not a tracked file), so a branch cannot remove it; an
agent or human acting on the machine can. A gate on a machine without the
overlay and without the mark (the laptop today) measures nothing.

**The pre-push hook.** `ai/git-hooks/outbound-pre-push.sh`. Once installed at
the main checkout's `.git/hooks/pre-push`, it serves every linked worktree and
lane, and it runs the **main checkout's** (landed) scanner, never a branch's
copy. A missing scanner refuses the push (exit 3). An installed hook marks a
machine that must measure, so an ABSENT overlay refuses the push there.
`scripts/setup-private-overlay --install` installs it (see *Installer*), and
only once the scanner can measure. Until the owner runs the installer on a
machine, no push is scanned there, the machine is not marked, and the forge
path below runs in its unmarked mode there.

**Later (2026-09-28):** this paragraph said "Nothing installs it yet: the
installer is DND-703." Superseded by DND-703's installer.

**The forge path.** `ai/bin/gh-athena` scans every `--title`/`--subject`,
`--body`, `--body-file` and (on close/reopen) `--comment` (each gh spelling,
including `-bVALUE`) of `pr create|edit|comment|review|merge|close|reopen` and
`issue create|edit|comment|close|reopen` before gh runs; a squash merge's
subject and body become a commit made on the server, where no pre-push hook
runs. Every body file is copied once, the copy is scanned, and gh is handed the
copy, so a pipe or a changing file cannot differ from what was scanned. A
short-flag cluster that could hide one of these fields is refused. The scan runs unless every repository the write can reach
reads PRIVATE or INTERNAL: each `-R`/`--repo`, the repository of each PR or
issue URL given positionally, `GH_REPO` when no `-R` is given, and otherwise
the current directory's. A visibility that cannot be read, or a URL that cannot
be parsed, counts as PUBLIC. HITS refuse (exit 1); a scanner exit 1 that does
not report HITS is a failure (exit 3), never a result. COULD NOT MEASURE
refuses (exit 3), except where the overlay is ABSENT and the machine is
known not to be marked (the harness checkout's `hooks/pre-push`, as
`git rev-parse --git-path` resolves it, holds no outbound hook): there the
write proceeds with a WARNING that the text went out unscanned, never a CLEAN
line. A mark that cannot be determined counts as marked.

**Residuals, stated.**

- An agent or a human can push with `--no-verify`, set the waiver, edit the
  main checkout's scanner, or move the overlay's `HEAD` to drop a pattern.
- The waiver is self-granted and is written to a local log that nothing reads
  today. It leaves a record, not an alert.
- The forge path does not scan `gh pr create --fill`, an editor or `--web`
  body, `gh api` writes, or other commands (release notes, gists, repository or
  label descriptions). An unknown flag whose value is a field flag's name
  (`-l -b -t X`) is read differently by gh and by the guard.
- gh-athena runs the scanner beside it, so a worktree's gh-athena runs that
  branch's scanner. Only the pre-push hook pins the landed scanner.
- No scan catches a value it has no pattern for.

Each bypass raises the cost or leaves a trace; none is impossible.

**Consequence for this repo.** The owner's scope (2026-09-25) puts work ticket
ids in the pattern list. Once the overlay holds that pattern and the hook is
installed, harness commit messages and PR bodies can no longer cite work ticket
ids.
