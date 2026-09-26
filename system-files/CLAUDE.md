# System Files

This directory contains system-level configuration files that require root privileges to install.

## Files

- `greetd-config.toml` - Greetd display manager configuration
- `bt-hci-capture` - Rotating `btmon` HCI capture loop, run by the btmon service
- `btmon.initd` - OpenRC service running `bt-hci-capture`
- `btmon.confd` - Options for that service (`BTMON_OPTS`)
- `docker-rootless-athena.initd` - OpenRC service running rootless `dockerd` as a non-root user
- `docker-rootless-athena.confd` - Options for that service (`DOCKER_ROOTLESS_USER`, `DOCKERD_ROOTLESS_OPTS`)
- `docker-rootless-gitlab-runner.initd` / `.confd` - rootless `dockerd` for the `gitlab-runner` user
- `gitlab-runner.initd` / `.confd` - supervise-daemon OpenRC service running `gitlab-runner run` as that user
- `gitlab-runner-config.toml.example` - non-secret reference shape for the registered `config.toml` (the live token-bearing one is never committed)
- `gitlab-runner-runbook.md` - the Cody-runs enable steps + the walt_ui `.gitlab-ci.yml` `buildctl` rewrite spec (DND-177)
- `lib/initd-proc-tree.sh` - sourced by every `*.initd` here: ends a service instance's whole process tree on stop and asserts nothing is left (DND-812)
- `test/initd-proc-tree/self-test.sh` - hermetic test of that stop path for every initd (discovered by the harness gate)

## Symlink Integration

These configs are symlinked to their system locations (requires sudo):

```bash
/etc/greetd/config.toml -> ~/dev/custom/system-files/greetd-config.toml
```

## Installation

To create the symlinks (requires root):

```bash
sudo ln -sf ~/dev/custom/system-files/greetd-config.toml /etc/greetd/config.toml
```

## Notes

### greetd-config.toml

This configuration:
- Uses `tuigreet` as the greeter
- Starts Hyprland via a wrapper script (`scripts/start-hyprland`) that ensures a D-Bus session is properly initialized
- Runs on VT 7

The wrapper script is necessary because greetd doesn't automatically create a D-Bus session for the user. Without it, applications that depend on D-Bus (system tray icons, notifications, etc.) won't work properly.

### btmon service (bt-hci-capture, btmon.initd, btmon.confd)

Keeps a rotating, timestamped text capture of Bluetooth HCI traffic in
`/var/log/btmon/` (readable by the `log` group) so that `scripts/bt-trace` can
show what the controller was doing right before a firmware crash. A2DP/SCO
media payloads are not captured, so an hour is typically a few MB.

These are copied rather than symlinked: root runs them, and a symlink would
let a user-writable file run as root.

`bt-setup service` runs the following for you (use `--dry-run` to see it):

```bash
sudo install -m 755 ~/dev/custom/system-files/bt-hci-capture /usr/local/sbin/bt-hci-capture
sudo install -m 755 ~/dev/custom/system-files/btmon.initd /etc/init.d/btmon
sudo install -m 644 ~/dev/custom/system-files/btmon.confd /etc/conf.d/btmon
sudo rc-update add btmon default
sudo rc-service btmon start
```

After a change to `bt-hci-capture`, re-run the first `install` line and
`sudo rc-service btmon restart`.

### docker-rootless-athena service (docker-rootless-athena.initd/.confd)

Runs a **rootless** Docker daemon as the `athena` user (default), so athena
gets Docker without being in the root-equivalent `docker` group. The daemon
runs under her UID with its own socket (`$XDG_RUNTIME_DIR/docker.sock`) and
data root (`~/.local/share/docker`), fully isolated from the system docker
daemon. Requires `rootlesskit`, `slirp4netns`, `fuse-overlayfs`, subuid/subgid
ranges, and lingering (`loginctl enable-linger athena`) so `/run/user/<uid>`
exists at boot.

`scripts/setup-athena-docker` installs and starts it (copy, not symlink, for
the same run-as-root safety reason as btmon). Override the target user via
`DOCKER_ROOTLESS_USER` in `/etc/conf.d/docker-rootless-athena`.

### Self-hosted GitLab Runner (docker-rootless-gitlab-runner + gitlab-runner)

The GitLab mirror of the self-hosted GitHub runner (DND-177): a dedicated
`gitlab-runner` user with its **own** rootless dockerd
(`docker-rootless-gitlab-runner`, isolated from athena's and github-runner's),
and a supervise-daemon service (`gitlab-runner`) running `gitlab-runner run` **as
that user** — a deliberate divergence from GitLab's default root packaging,
required so the docker executor hits the user's rootless socket. It's a **project
runner** on `gitlab.com/amby_ai/walt_ui` with gitlab.com shared runners as
fallback; `privileged = false`; image builds run via rootless BuildKit
(`moby/buildkit:rootless`) so the same untagged job runs on both the self-hosted
runner and SaaS. `scripts/setup-gitlab-runner{-user,-docker,}` install these
(copy, not symlink, for the run-as-root safety reason). The full enable runbook —
register steps, the `keep-stopped-until-the-walt_ui-MR-merges` ordering, the
`.gitlab-ci.yml` `buildctl` rewrite spec, and enable-time validation — is in
**`gitlab-runner-runbook.md`**. The live `config.toml` holds the `glrt-` token and
is never committed; `gitlab-runner-config.toml.example` is the non-secret shape.

### Stopping a service ends its whole process tree (lib/initd-proc-tree.sh)

`supervise-daemon` and `start-stop-daemon` signal ONE pid on stop. A command
that forks long-lived children leaves them running, re-parented to PID 1:
`run.sh` -> `run-helper.sh` -> `Runner.Listener`, or `dockerd-rootless.sh` ->
`rootlesskit` -> `dockerd`. Measured on the laptop (DND-812): two listeners
per GitHub runner registration, and a "stopped" runner kept taking jobs.

So every `.initd` file here:

- passes `--env ATHENA_SVC_TREE=${RC_SVCNAME}` to its command only
  (`supervise_daemon_args` / `start_stop_daemon_args`). Every descendant
  inherits it; the `openrc-run` doing the stop never carries it. `RC_SVCNAME`
  is not the tag, because `openrc-run` carries that too.
- runs `proc_tree_reap` in `stop_post` AND at the end of `start_pre`. It
  SIGTERMs every process of the service's uid that carries the tag, or whose
  exe or cwd is under the instance's anchor (`RUNNER_DIR` for github-runner,
  `RUNNER_BIN` for gitlab-runner). It waits, SIGKILLs survivors, then asserts
  none remain; otherwise stop fails with a `Fix:` line.
- matches by `/proc/<pid>/environ`, `exe`, and `cwd` only, never argv text, and
  compares anchors as whole path components (`actions-runner` never matches
  `actions-runner-2`). Instances never touch each other.

The lib is installed as a root-owned copy at
`/usr/local/lib/athena/initd-proc-tree.sh` (override: `ATHENA_PROC_TREE_LIB` in
`/etc/conf.d/<svc>`; SIGTERM grace: `ATHENA_PROC_TREE_TIMEOUT`, default 10s).
Every `scripts/setup-*` installer and `bt-setup service` install it. A missing
lib fails start and stop loudly, with the install command as its `Fix:`.

Consequences to know:

- The anchor match is by design broader than the tree. Start and stop also end
  a shell or `config.sh` run as `github-runner` inside `RUNNER_DIR`, or a
  manual `gitlab-runner register` as `gitlab-runner`. These are dedicated
  service users; do such work with the service stopped.
- The docker-rootless services and btmon match by tag only. A process started
  before the tag existed (any orphan from before this fix) is not found by
  them; clean those by PID once, by hand, when installing.

Not covered: supervise-daemon's own respawn after the command crashes. It runs
no `start_pre`, so a child that outlives a crashed `run.sh` can still meet a
respawned one.
