# Athena Machine Secrets — contract

**Kind: living normative document.** Amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*.

**Status:** normative. **Adopted:** 2026-09-30 (DND-845). This contract says where
a per-machine secret lives, how a tool loads it, how an agent may inspect it,
and how the harness checks all of that. It is the one home of these rules;
every other document cites it by section name.

The implementation:
- `ai/secrets/registry.json`: the public registry (*The registry*).
- `ai/secrets/env-allowlist.json`: the env allowlist (*The env allowlist*).
- `ai/bin/check-machine-secrets` over `ai/lib/machine_secrets.rb`: the check
  (*check-machine-secrets*).
- `ai/bin/with-secret`: the per-command loader (*with-secret*).
- `ai/hooks/secret-env-warn.sh`: the SessionStart warning (*secret-env-warn*).
- Tests: `ai/test/machine-secrets/self-test.sh` and
  `ai/hooks/secret-env-warn.self-test.sh`.

**Provenance.** The design record is the Notion page "Per-machine secrets
practice — proposal (2026-09-30)", agreed by the custom, walt_ui and laptop
sessions (round 3.2). It is a dated record: its inventory and migration steps
say what was true then. Where it disagrees with this contract, **this contract
wins**.

**How this document is amended.** Normative prose is amended in place. Each
amendment that supersedes an existing rule gets exactly one paragraph opening
with a bold dated UTC label (`**Later (YYYY-MM-DD):** …`) at the definitional
mention. Purely additive content carries no label. Sections are cited **by
name**, never by number.

**Conformance language.** MUST / MUST NOT / SHOULD / MAY carry their usual force.

## Scope

A **per-machine secret** is a copy of a credential that lives on a developer
machine and is used by local tools and agents. That includes a server
credential that also has a copy on the machine (a tenant repo's local env file
may hold production credentials). Rotating such a secret means updating its
canonical store, the server, and every machine copy. Server-side storage and
deployment of secrets are out of scope.

**Exposure words.** A value is **env-wide** when it is in the Claude Code
process env: it then reaches every Bash tool child, hook, stdio MCP server and
subagent. A value is **per-process** when only the consuming process holds it.
The rules below exist to keep every secret per-process.

## Where

One secret per regular file, mode `0600` (`0400` allowed), owned by the user, in
a directory that is not group- or world-accessible.

What probe (c) enforces is narrower on the directory: not group- or
world-**writable**. A writable directory lets another user swap the file; a
`0755` one only lists its names. The narrower bar keeps existing tool
directories (`~/.config/gh`, `~/.config/gcloud`) from failing, while the rule
above still governs every directory you create (`0700`).

- New secrets go under
  `${ATHENA_SECRETS_ROOT:-~/.config/athena-secrets}/<scope>/<name>`, with each
  directory `0700`.
- Existing files keep their paths (`~/.claude/*token*`, the inbox client
  config, the GitHub App key). They are declared (*Declared*), not moved.
- A secret MUST NOT be placed in a git worktree, `ai-artifacts/`, a scratchpad,
  the private overlay, or a dotenv file that is not `0600`.

**The dotenv carve-out.** A repo's tooling may require a dotenv file inside the
worktree (a compose `env_file`). That file is allowed when all of these hold:
- it is gitignored;
- it is mode `0600`;
- it is declared in a registry with its `copies` glob;
- **every copy is a symlink to the primary or a regular file at `0600`.**

Probe (c) checks exactly the mode and copy conditions. It cannot tell how a
regular file was made. New copies are made by symlink or `install -m 600`
(*Rotating a secret*). Such a file MAY hold several secrets.

## Declared

Every per-machine secret has a registry entry (*The registry*). A value never
goes in a registry.
- Harness secrets are declared in `ai/secrets/registry.json` (public).
- Work-domain secrets go in the private overlay's `overlay/secrets.json`: the
  same schema, private (`ai/contracts/athena-private-overlay.md` → *Overlay
  files*).

## Load at point of use

A secret is loaded into the consuming process only. Use these, in preference
order:

1. **The consumer reads a path.** A `FOO_FILE` variable, or the tool's own
   `--config` or `*_TOKEN_FILE`. This is the **`_FILE` convention**: a
   variable named `<NAME>_FILE` holds the absolute path of the file whose
   content is `<NAME>`'s value. A consumer that supports it reads the file when
   `<NAME>_FILE` is set, and the plain `<NAME>` otherwise, so a server that
   sets the plain variable is unchanged. Exporting a `_FILE` path is allowed
   anywhere: a path is not a secret.
2. **`ai/bin/with-secret NAME -- cmd …`** (*with-secret*), for a consumer that
   reads only env.
3. **MCP:** a headersHelper (http) or a stdio wrapper that reads the file
   (`ai/bin/notion-athena-mcp` is the exemplar).
4. **curl:** a `--config` file in a `mktemp -d` under `$XDG_RUNTIME_DIR`,
   removed by `trap … EXIT`.
5. **AWS:** the AWS CLI's own cache (the `aws login` flow).

## Never

- `source` a project env file (`.envrc`, `.env*`) into an interactive shell.
  Load it inside the one command that needs it.
- `export` a secret from:
  - a shell init file (`~/.zshrc*`, `~/.zshenv`, `~/.zprofile`, `~/.profile`,
    `~/.bash*`, `environment.d`);
  - `settings.json` `env`;
  - `~/.claude.json` MCP `env`, `headers` or `args`;
  - a launcher that execs `claude`;
  - `CLAUDE_ENV_FILE`.
- Put a secret in argv, a URL, a log, a commit, a ticket, a report, a Slack
  message, or a persistent temp file.
- Give a harness tool an env-var fallback for its token. A tool reads its
  declared file. It does not also accept the value from a variable, because the
  fallback invites a global export.

Exporting a `_FILE` **path** is fine.

## Inspect by metadata only

Agents check a secret by name, path, mode, owner, length, or prefix *count*.

- A search over any file that might hold a value uses `grep -l` or `grep -c`,
  never line output. "Names only" is a property of the command's OUTPUT, not of
  its search term: a `grep -n NAME` over a file that quotes config prints the
  value on the same line. (Measured 2026-09-30: the survey for this contract
  printed a key into a transcript that way, and the key had to be rotated.)
- Never `cat`, `echo` or `printenv NAME` a secret, and never run an unfiltered
  `env` or `set`.
- Docker readers print a container's env just the same: `docker compose config`
  (it prints the merged `env_file` values), `docker inspect`, and `docker
  compose exec <svc> env` or `printenv`.
- To check whether a variable is present, use a presence test that prints
  nothing from the value: `printenv NAME >/dev/null && echo set`, or
  `docker compose exec <svc> sh -c '[ -n "${NAME+x}" ] && echo set'`.
- **Never parse `env` output** (`env | cut -d= -f1`, `env | grep`). A
  multi-line value (a PEM key, a JSON blob) puts its continuation lines, which
  have no `=`, on the output whole. `cut -s` only narrows the leak. Read names
  as a structure instead: Ruby's `ENV.keys`, or `/proc/<pid>/environ` split on
  NUL.

## The owner page shows the last 4

The server-side owner page (gen_saas `/secrets`, ADR 18 rule 1) shows the last 4
characters of each secret stored through it. This is intended. It is a
fingerprint, so the owner can tell two stored keys apart and see that a
rotation took. It is not a way to read the secret back. Server-side storage is
otherwise out of scope (*Scope*); this section fixes only what that page may
reveal about a value, so a reader implementing from this contract knows the
limit. The limits, as ADR 18 and `Athena.Secrets.Last4` set them:

- **Fixed length.** Exactly 4 characters, never more. A page MUST NOT show a
  longer suffix, a prefix, a length, or a hash.
- **Never for a short value.** A value under 16 characters keeps no last 4. The
  page shows "not shown". 4 characters of a short value are too large a
  fraction of it.
- **Rewritten on every store.** A rotation replaces the last 4, so the page
  never shows the old one. A row stored before ADR 18 has none.
- **It is the only part shown.** The full value is never shown back, logged or
  put in telemetry.

This is about the owner page only. It does not relax *Inspect by metadata
only*: an agent never prints any part of a secret value, the last 4 included.
The page stores the last 4 as plaintext beside the encrypted value.

## Adding a secret

1. `install -d -m 700` the scope directory.
2. Write the value without echoing it: from the console by the owner, from
   `op read … >file`, or by an agent when the value is already on the machine.
3. Add the registry entry (*The registry*).
4. Wire the consumer per *Load at point of use*.

## Rotating a secret

1. Mint the new value. This is owner-only unless a bot can mint it
   (`~/.claude/CLAUDE.md` → *Owner approval policy* → *Only Cody can run*).
2. Write it to `<path>.new` (`0600`) in the same directory, then `mv` it over
   the old file.
3. Restart each consumer the registry names, with the exact command in its
   entry's `restart` field. A compose `env_file` is read only when the
   container is created, so a plain restart keeps the old value. For a tenant
   repo whose worktrees each run their own compose stack, the command runs in
   **every checkout whose stack is up**, main and each worktree; the entry's
   `restart` says so.
4. Revoke the old value.
5. Repeat on each machine and each declared copy that holds it. For a server
   credential, also update the canonical store and the server.

A copy made from a primary file is a symlink to it, or an `install -m 600`
copy. Never a plain `cp`: it carries a `0644` mode forward and multiplies the
stale copies.

Machine tokens are per-machine by design. Never copy one between machines.

## A leaked value is rotated

Once a value has reached a transcript, a file (a core dump included), or a mode
other users can read, it is rotated, not just deleted. Purge the copies
afterwards.

## The registry

A registry file is JSON:

```json
{
  "kind": "athena-machine-secrets",
  "schema": 1,
  "secrets": [ { "name": "…", "path": "…", "consumers": ["…"], "kind": "…",
                 "restart": "…", "rotate": "…" } ]
}
```

Each entry:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Unique across the public registry and the overlay's: a name in both is could-not-measure for the check and a refusal for `with-secret`. `[A-Za-z0-9][A-Za-z0-9_.-]*`. A secret loaded by `with-secret` is named by the env variable its consumer reads (`[A-Za-z_][A-Za-z0-9_]*`). |
| `path` | yes | The primary file. Absolute, or `~/…` (expanded against `$HOME`). A symlink is allowed; its target is what is checked. |
| `copies` | no | A glob naming every copy of the primary (`*`, `**`, `?`, `[…]`, `{a,b}`). Same path rules. |
| `consumers` | yes | Non-empty list of strings: what reads the file. |
| `kind` | yes | `[a-z0-9-]+`. `dotenv` marks a file that holds several secrets (*Where* → *The dotenv carve-out*); `with-secret` refuses it. |
| `restart` | yes | The exact command that makes each consumer pick up a new value, or `none` with the reason. |
| `rotate` | yes | Where the new value is minted. |
| `user` | no | The local account that holds the file, when it is not the account running the check (a CI runner user's `config.toml`, DND-1937). `[a-z_][a-z0-9_-]{0,31}`. `path` must then be absolute, and `copies` is not allowed. |

A top-level key starting with `_` is a comment. Any other unknown key, at the
top level or in an entry, is malformed.

A registry is **malformed** when it is not JSON, has the wrong `kind` or
`schema`, an entry lacks a required field or has one of the wrong type, a name
repeats, a path is neither absolute nor `~/…`, a path contains `..` or a NUL,
or any string field or key matches a credential prefix (*check-machine-secrets*
→ *Credential patterns*). A malformed registry is never read as an empty one:
the check exits 3 and `with-secret` refuses. The credential test runs first and
its error names the entry by position and the field by name, so a value pasted
as an entry's `name` is never echoed.

The public registry declares the harness's own secrets. A secret that is absent
on a machine is fine: the check lists it as `not provisioned here: NAME`.

**An entry held by another account (`user`).** Probe (c) checks the file is
owned by that account, mode `0600`/`0400`, in a directory that is not group- or
world-writable. The account missing on a machine reads `not provisioned here`.
A file the checking account cannot stat (it sits in that account's `0700`
home) reads `not checked as this account: NAME …; run as root or USER to check
it`: named per entry, never `ok`, and not a finding. `with-secret` refuses such
an entry: a session never loads another account's secret.

## The env allowlist

`ai/secrets/env-allowlist.json` names the env variables probe (a) and probe (b)
do not report even though their name matches:

```json
{ "kind": "athena-machine-secrets-env-allowlist", "schema": 1,
  "exact": ["…"], "rules": ["file-path", "git-config-key"] }
```

- `exact`: exact variable names. There is **no wildcard**. In particular, no
  `CLAUDE_CODE_*` pattern: `CLAUDE_CODE_OAUTH_TOKEN` is a real credential that
  people export for headless auth.
- `rules`: named rules the check implements.
  - `file-path`: a `*_FILE` variable whose value is an existing path.
  - `git-config-key`: `GIT_CONFIG_KEY_<n>`.

**The allowlist is read as landed.** It is the check's own bar, so the check
honours an entry only when it is present in the working tree AND at every
landed point that has the file: the tip of `origin/main` and the merge-base,
through `ai/lib/landed.rb` (`~/dev/custom/CLAUDE.md` → *A check's own bar must
not live in the diff it is checking*). A branch that adds an entry gets no
relief from it until it lands. When the landed allowlist cannot be read, no
entry is honoured: a name only the allowlist would excuse is reported as
`allowlist unverified`, which counts as could-not-measure (exit 3), never as a
pass.

The public registry is read the same way for probe (c): the entries checked
are the union of the working tree's and each landed point's, so a branch
cannot drop a landed entry from its own check.

## check-machine-secrets

`ai/bin/check-machine-secrets [--probe a,b,c,d]` runs the probes named (all
four by default). `--probe a --brief` prints one line per reported name, Fix
inline, and nothing when clean: the hook's form.

**Exit codes.** 0 clean. 1 a finding. 3 could not measure. A finding wins over
could-not-measure for the exit code; both are always printed. `PENDING
RESTART` and `not provisioned here` lines are informational and exit 0.

**Output never contains a value.** Every line names a variable, a path, a mode,
a size or a count. The self-test seeds synthetic values and asserts none
reaches stdout or stderr.

### Credential patterns

A **credential name** matches, case-insensitively:
`TOKEN|SECRET|PASSWORD|PASSWD|BEARER|API_?KEY|PRIVATE_KEY|ACCESS_KEY|SESSION_TOKEN|CREDENTIAL`,
or `PAT` as a word (`(^|_)PAT($|_)`).

A **credential value** starts with (env and config values) or contains at a
word boundary (file contents, probe (d)) one of:

| Prefix | Minimum after the prefix (contents only) |
|---|---|
| `sk-ant-` | 20 `[A-Za-z0-9_-]` |
| `xoxa-`, `xoxb-`, `xoxp-` | 10 `[A-Za-z0-9-]` |
| `ghp_`, `gho_`, `ghs_`, `ghu_` | 30 `[A-Za-z0-9]` |
| `github_pat_` | 30 `[A-Za-z0-9_]` |
| `glpat-` | 20 `[A-Za-z0-9_-]` |
| `ntn_` | 30 `[A-Za-z0-9]` |
| `AKIA`, `ASIA` | exactly 16 `[A-Z0-9]` |
| `-----BEGIN` … `PRIVATE KEY-----` | the whole header |
| `re_` | 20 `[A-Za-z0-9]`, and anchored: at the start of a value, or at a word boundary in contents. It is too short to use bare. |

The minimums apply to file contents, where prose names a prefix without a
value. An env or config value is matched on the prefix alone (the `re_` and
`AKIA`/`ASIA` lengths still apply).

### Probe (a): live env

It reads variable names from its own environment as a structure (Ruby's
`ENV.keys`), never by parsing `env` output, and prints names only. It reports a
variable whose name is a credential name or whose value is a credential value,
unless the allowlist excuses it. Its environment is its caller's: the harness
gate passes its env through, and a SessionStart hook inherits Claude Code's, so
it fires in exactly the state of a session started from a terminal that
exported a secret.

**PENDING RESTART** (exit 0, named) needs all three of these:
1. A recorded `(NAME, file, line)`. Whenever probe (b) sees an export it
   writes that record to a machine-local state file,
   `${XDG_STATE_HOME:-~/.local/state}/athena/machine-secrets/exports.json`.
2. That assignment is now gone from that file.
3. **That file's own** mtime (`stat -L`) is later than the start of the
   nearest ancestor `claude` process.

With no record, with the assignment still present, or with no `claude`
ancestor, the result is FAIL. The comparison deliberately does not use the
newest mtime of any probed file: `.zshrc` is a symlink into this repo, so every
`git pull` would bump it and let a launcher export hide behind the restart
label. This follows the DND-1036 precedent (`check-hooks-registered`'s PENDING
RESTART), so a fixed dotfile does not red every running session.

So run the check once, standalone, **before** deleting an export: that run
records it. The self-test injects the session start through
`CHECK_MS_TEST_CLAUDE_START` (epoch seconds, or `none`); the output names the
injection. The seam is honoured only when `HOME` is under the temp directory,
as a fixture's is; anywhere else it is ignored, said so, and the real ancestor
is not consulted, so a caller cannot relabel a live FAIL as PENDING RESTART.

### Probe (b): static config

It scans:
- the shell init files in *Never* (`~/.zshrc`, `~/.zshrc.*`, `~/.zshenv`,
  `~/.zprofile`, `~/.zlogin`, `~/.profile`, `~/.bashrc`, `~/.bash_profile`,
  `~/.bash_login`, `~/.config/environment.d/*.conf`) and this repo's
  `dotfiles/.zshrc`;
- `~/.claude/settings.json` `env`;
- `~/.claude.json` MCP `env`, `headers`, `args` and `url`, top level and per
  project.

It reports each assignment whose name is a credential name or whose value is
a credential value, as `FILE:LINE NAME` (a JSON file gives its key path in
place of a line number). An empty assignment is not reported. In a shell file
every other assignment is judged: `export X=$Y` puts Y's value in the env as
X. An MCP `env`, `headers` or `args` value that is only a `${VAR}` reference is
not reported, because Claude Code expands it into that one child. A header
`Bearer <literal>` is reported whatever the header's name. It also reports a
scanned file (a shell init file or one of the two JSON files) that is group-
or world-readable **and** holds a finding.

### Probe (c): declared files

Every registry entry (public, plus the overlay's when the overlay is present)
is checked: a regular file, owned by the uid, mode `0600` or `0400`, parent
directory not group- or world-writable.
- Symlinks are resolved, for a primary path and a copy alike. The target's
  mode and owner are checked, and the report names the link and its target.
- `copies`: every match is checked. The output prints the count of matches and
  the count of violators, so a glob that matches nothing reads as `0 matched`,
  never as a silent pass. A `**` glob walks every directory below it; prefer a
  bounded pattern (`{*,*/*}/backend/.env`) over a large tree.
- Absent: `not provisioned here: NAME` (listed, pass). A laptop may lack a
  desktop secret, and saying so by name keeps the miss visible.
- A path that cannot be resolved (`$HOME` unset or relative) is could-not-
  measure, naming the entry. An unreadable or malformed registry is exit 3.
  An absent overlay is not a fault; a malformed one is exit 3.

### Probe (d): persistent plaintext

It scans, for credential values:
- the `ai-artifacts/` directories of this repo's main checkout, and of the main
  checkout of every repo in the committed inbox tenancy registry
  (`ai/inbox/registry.json`), at any depth (e.g. `backend/ai-artifacts/`).

The walk skips `deps/`, `_build/`, `node_modules/` and `.git/` and counts what
it skipped. It reports **paths only**, plus the list of roots it scanned.

It also lists core dumps under `~/dev` by **path and size only**, with the
same skips. A core dump is a regular file named `core`, `core.*` or `*.core`
whose ELF header says `ET_CORE`; the header is the only part read, because a
content scan would be tens of GB of IO. A core dump always counts as a finding,
because it carries the process environ.

### Fix texts

- (a), (b): `Fix: move NAME's value to a 0600 file
  (ai/contracts/athena-machine-secrets.md -> Adding a secret), load it with
  with-secret or a _FILE path, delete the export at FILE:LINE, then restart the
  terminal and every Claude session started from it.`
- (b), a readable scanned file: `Fix: chmod 600 PATH`.
- (c): `Fix: chmod 600 PATH` (or `chmod 700 DIR`).
- (d): `Fix: delete PATH, or redact the value in it; if the value was ever
  readable elsewhere, rotate it (Rotating a secret).` For a core dump: `Fix:
  delete PATH (a core dump holds the process env); rotate any secret that was
  in that process's env.`

## with-secret

`ai/bin/with-secret NAME -- cmd [args…]` resolves NAME through the registries
(public, then the overlay's), checks the resolved file as probe (c) does, and
`exec`s `cmd` with `NAME` set to the file's content in that process's env
only. The value never goes in argv, and nothing is printed from it. One
trailing newline is dropped. It refuses, with a `Fix:` line and no exec: an
unknown name, a malformed registry, a `dotenv` entry, an entry held by
another account (`user`), a name that is not an env identifier, a missing, empty, or mis-permissioned file, and a missing
command.

## secret-env-warn

`ai/hooks/secret-env-warn.sh` is a SessionStart hook. It runs probe (a) only
and prints one context line per reported name, with the Fix. It never blocks.
It covers sessions that never run the harness gate (a tenant repo's). Hooks
inherit Claude Code's env, so it fires in exactly the state a global export
creates. Reading the landed allowlist costs one `git ls-remote origin` per
session start (about 1.4 s over SSH). Offline, allowlisted names print as
could-not-measure and real findings still print. The hook caps the check at
30 s and says so if it times out.

## Rollout

The check is **not** in the harness gate and the hook is **not** registered in
`ai/hooks/registry.json` until the migration's final step: both machines have
removed their exports, restarted, and pass the check standalone. Landing
either earlier would red every session on a machine that still exports a
secret. The migration steps, their order and their owners are in the design
record (*Provenance*). The final step adds the gate entry, adds the hook's
registry row, lands both, then runs `scripts/setup-hooks --install`
(`~/dev/custom/CLAUDE.md` → *Hook registration*).
