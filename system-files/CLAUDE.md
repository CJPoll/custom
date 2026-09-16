# System Files

This directory contains system-level configuration files that require root privileges to install.

## Files

- `greetd-config.toml` - Greetd display manager configuration
- `bt-hci-capture` - Rotating `btmon` HCI capture loop, run by the btmon service
- `btmon.initd` - OpenRC service running `bt-hci-capture`
- `btmon.confd` - Options for that service (`BTMON_OPTS`)
- `docker-rootless-athena.initd` - OpenRC service running rootless `dockerd` as a non-root user
- `docker-rootless-athena.confd` - Options for that service (`DOCKER_ROOTLESS_USER`, `DOCKERD_ROOTLESS_OPTS`)

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
