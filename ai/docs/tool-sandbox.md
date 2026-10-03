# tool-sandbox

**Kind: living normative document.** Amended in place, per
`~/dev/custom/CLAUDE.md` → *Documentation conventions*.

`ai/bin/tool-sandbox` runs one command so it cannot reach the network, the
owner's HOME and credentials, `~/.claude`, the `~/dev/custom` main checkout,
forge tokens, the Athena inbox root, or the docker socket. It is the execution
boundary for model-written code (DND-1426; epic *Harness — sandboxed tool
creation*, requirement R3 and adoption-gate state S3). `ai/bin/tool-propose`
(DND-176) builds on it.

```
ai/bin/tool-sandbox --prepare-clone DEST [--sha SHA]
ai/bin/tool-sandbox --work DEST/repo [--out DIR] [--stdin FILE] [--timeout SECS] -- CMD [ARGS...]
ai/bin/tool-sandbox --self-test
```

## Mechanism

Bubblewrap (`bwrap`), unprivileged, no daemon. A path that is not bound does
not exist inside. Docker was rejected: its socket is root-equivalent, and one
bind or flag mistake hands the child root (the epic's Architecture &
Engineering page, *Mechanism decision: bubblewrap, not docker*).

The argv is built in exactly one place, `ai/lib/tool_sandbox/policy.rb`
(`ToolSandbox::Policy.argv`). It is the only source of a bind mount or an
environment variable. No flag of the CLI adds either.

```
timeout --kill-after=10 SECS
prlimit --cpu=SECS --fsize=1073741824 --nofile=1024 --core=0 --   (each lowered to the caller's hard limit)
bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL --clearenv
      --setenv <the allowlist below>
      --ro-bind /usr /usr   --symlink usr/... /bin /lib /lib64 /sbin (mirrored from the host)
      --ro-bind /etc /etc   --proc /proc  --dev /dev  --perms 1777 --tmpfs /tmp
      --dir /home/sandbox   --bind WORK /work  [--bind OUT /out]  [--ro-bind ORIGIN /origin]
      --chdir /work --json-status-fd 3 -- CMD...
```

## What it denies, and the probe that proves each

`tool-sandbox --self-test` runs every probe against real bwrap on every
harness-gate run. A probe whose sandbox cannot start fails; none skips.

| Denied | How | Probe |
|---|---|---|
| Network, incl. abstract unix sockets (X11, D-Bus) | `--unshare-all` (new net ns) | E-1 a host loopback listener and 1.1.1.1 are unreachable; E-2 a host abstract socket and `@/tmp/.X11-unix/X0` refuse |
| HOME and every credential under it | `/home` not bound; `HOME=/home/sandbox` | E-3 the real HOME is ENOENT |
| `~/.claude` | not bound | E-4 |
| The main checkout | not bound; work is a clone under the temp root | E-5 this checkout's `ai/bin/tool-sandbox` and `~/dev/custom` are ENOENT |
| The inbox root | not bound; `ATHENA_INBOX_ROOT` not set | E-6 |
| The docker socket | `/run`, `/var/run` not bound | E-7 |
| Forge tokens and every other env var | `--clearenv` + an allowlist; the launchers themselves get a 3-variable env | E-8 the child's env is exactly the allowlist plus bwrap's `PWD` |
| Writes to the system | `/usr`, `/etc` read-only | E-9 EROFS |
| Persistence outside work/out | `/tmp`, HOME are fresh tmpfs | E-10 |
| Runaway time, CPU, files | `timeout`; `prlimit` | E-11 `sleep 30` under `--timeout 2` exits 124; E-12 reads `/proc/self/limits` |
| Host processes | `--unshare-all` (pid ns), `--new-session`, `--die-with-parent`, `--cap-drop ALL` | E-13 a different pid ns, at most 3 pids visible |
| Leaked file descriptors | spawned with `close_others`; bwrap closes its status fd | E-20 an fd the caller leaks is not open inside, and no fd but 0-2 and the probe's own is |
| The caller's stdin | stdin is `/dev/null` | E-21 |
| A `--stdin FILE` beyond its bytes | the host reads FILE and writes its bytes into a pipe that is the child's fd 0; FILE is never bound | E-23 the child reads exactly the bytes from a pipe, FILE's path is ENOENT inside, and a write through `/proc/self/fd/0` leaves FILE unchanged; a symlink, a directory, a missing, relative, hardlinked or out-of-root FILE is refused (125) and CMD never runs |
| A sandbox outliving tool-sandbox | TERM/INT/HUP are trapped before the spawn and forwarded to `timeout` | E-22 a TERM mid-run exits 143 and leaves no bwrap running |
| Host files through the work dir | refusals below | E-17 each refused path exits 125 and CMD never runs |

Environment allowlist: `PATH=/usr/bin:/bin`, `HOME=/home/sandbox`,
`LANG=C.UTF-8`, `TMPDIR=/tmp`, `TERM=dumb`,
`XDG_STATE_HOME=/home/sandbox/.local/state`,
`XDG_CACHE_HOME=/home/sandbox/.cache`. bwrap adds `PWD=/work`.

## Paths it accepts

`--work`, `--out` and `DEST` are validated as keys before anything runs. Each
refusal names the path and why (exit 125, `Fix:`):

- absolute, existing (DEST: absent or empty), a real directory, not a symlink
  leaf, owned by you, and inspectable (an EACCES is a named refusal);
- realpath strictly beneath the temp root. The temp root is the realpath of
  `Dir.tmpdir` and must be sticky and world-writable, so `TMPDIR=$HOME` cannot
  widen it. The root itself is refused: it would bind every other process's
  `/tmp` entries;
- no socket, fifo, device or hardlinked file anywhere beneath, and no
  directory that cannot be listed. A bound unix socket reaches a host process
  whatever the net namespace, and a tmux or agent socket is host command
  execution. A hardlink shares its inode with a file elsewhere, so writing it
  inside writes that file. The walk runs only after the path itself passed;
- a `--work` whose `.git` is a file (a linked worktree pointing at a host
  repo) is refused;
- a `--work` or `--out` holding an `origin.git` (a `--prepare-clone` DEST
  itself) is refused: bound read-write, the mirror could be rewritten.

`--stdin FILE` (DND-176) is validated as a key too: absolute, an existing
regular file that is not a symlink leaf, owned by you, with one link, at most
16 MiB, and with a realpath strictly beneath the temp root. The host opens it
with `O_NOFOLLOW` and feeds its bytes through a pipe, so the child never holds
a descriptor of FILE. Without `--stdin`, stdin stays `/dev/null`.

`DEST/origin.git` is bound read-only at `/origin` when `--work` is
`DEST/repo`. If it is present but fails validation, the run is refused; it is
never silently left unbound. The bound directories must not overlap: an
`--out` that is, holds or sits inside the mirror or `--work` is refused.

## The pinned clone

`--prepare-clone DEST` reads the current checkout's
`refs/remotes/origin/main` (it does not fetch; run `git fetch origin` first
for a fresh pin) and builds:

- `DEST/origin.git`: `git init --bare`, then a fetch of SHA itself. Its only
  ref is `refs/heads/main` = SHA. A fetch copies objects through a pack, so it
  shares no object store with the host, and carries no other branch and no
  commit after SHA.
- `DEST/repo`: a `--no-hardlinks` clone of it, detached at SHA, origin url
  `/origin`, `refs/remotes/origin/main` = SHA.

git runs from `/usr/bin` with a fixed environment and no global or system
config, so an inherited `GIT_DIR` or `GIT_CONFIG_*` cannot redirect it into
the caller's repo.

Inside the sandbox `git ls-remote origin refs/heads/main` answers SHA with no
network, so harness-gate's landed-ref checks (`ai/lib/landed.rb`) measure
against exactly what was cloned. The mirror is read-only there, so sandboxed
code cannot rewrite it. `--sha` pins an ancestor of origin/main.

## Exit codes

| Exit | Meaning |
|---|---|
| CMD's own | the child ran; a signalled child is 128+N |
| 124 | the wall timeout fired (`TIMEOUT after Ns`) |
| 125 | tool-sandbox could not set the sandbox up, or CMD could not be executed inside it; nothing ran unsandboxed |
| 128+N | tool-sandbox itself got SIGN (TERM, INT, HUP), forwarded it and stopped the sandbox (`interrupted by SIGN`) |
| 2 | usage |

bwrap's own exit 1 collides with a child's exit 1. The `--json-status-fd`
stream disambiguates: a child's status is taken only from bwrap's `exit-code`
record. No record means the command never produced a status: a failed bind,
an unexecutable CMD, the timeout, a forwarded signal, or something else killing
bwrap. That is 124 only when timeout(1) stopped it and the wall time reached
`--timeout`, 128+N when tool-sandbox forwarded a signal, and 125 otherwise.
It is never the child's verdict.

## Residuals

- **Shared kernel.** bwrap shares the host kernel; a kernel exploit escapes
  it. The child can create further user namespaces (needed for a nested
  tool-sandbox), which is kernel attack surface. The human adoption step is
  the second line (the epic's Architecture & Engineering page, *The adoption
  gate: what enforces it, and in which state*).
- **A child can print what tool-sandbox prints.** A child that itself exits
  124, 125 or 128+N, and writes a `tool-sandbox:` line to stderr, reads like
  tool-sandbox's own outcome. Stderr is shared. A caller that must tell them
  apart needs a channel the child cannot write, which this tool does not yet
  provide. For model-written code the forgery only makes its own run read as
  failed, never as passed.
- **A DEST is single-use, and tainted after a run.** `DEST/repo` is writable
  inside, including `.git/config` and `.git/hooks`. Sandboxed code can repoint
  `origin` for later runs in the same DEST, or plant a hook, `core.fsmonitor`
  or a filter that a HOST git would then execute unsandboxed. Never run host
  git (or any host tool) in a `DEST/repo` a sandboxed command has touched; read
  only `--out`, and discard the DEST.
- **The caller's stdout and stderr** are inherited as they are. If they are a
  host file, the child can reopen it through `/proc/self/fd/1` and read what
  is already there.
- **The docker group.** The owner's uid is in `docker`, which is
  root-equivalent. The socket is not bound, so the child cannot reach it; E-7
  asserts that on every gate run.
- **/etc is readable.** It holds no registry secret
  (`ai/secrets/registry.json` and the overlay registry list none under
  `/etc`, checked 2026-09-30), and `/etc/shadow` is unreadable to the uid.
- **What the caller binds, the child reaches.** The work and out dirs are the
  caller's choice. Pass a fresh `mktemp -d` or a `--prepare-clone` DEST, never
  a directory other processes use.
- **Validation is not atomic with the bind.** A path swapped between
  validation and bwrap's bind is not re-checked. Only the caller's own
  processes can swap it; the validated realpath, not the raw argument, is what
  bwrap binds.
- **A SIGKILLed tool-sandbox** leaves `timeout` and the sandbox running until
  the wall timeout. TERM, INT and HUP are forwarded (E-22).
- **git for the clone** is found in the trusted directories only, like bwrap;
  the clone runs outside the sandbox as trusted code.
- **Not modelled:** GPU and other devices beyond bwrap's minimal `/dev`;
  memory limits (no cgroup); CPU contention with the host.
