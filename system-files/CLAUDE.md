# System Files

This directory contains system-level configuration files that require root privileges to install.

## Files

- `greetd-config.toml` - Greetd display manager configuration

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
