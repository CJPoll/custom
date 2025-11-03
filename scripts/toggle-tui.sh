#!/usr/bin/env bash
# Toggle TUI application in a special workspace
# Launches the app if not running, otherwise closes it
# This ensures proper sizing when switching monitors
#
# Usage: toggle-tui.sh --name <name> --executable <path> [--interactive]

# Parse arguments
INTERACTIVE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --name)
      NAME="$2"
      shift 2
      ;;
    --executable)
      EXECUTABLE="$2"
      shift 2
      ;;
    --interactive)
      INTERACTIVE=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: toggle-tui.sh --name <name> --executable <path> [--interactive]" >&2
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$NAME" ]]; then
  echo "Error: --name is required" >&2
  exit 1
fi

if [[ -z "$EXECUTABLE" ]]; then
  echo "Error: --executable is required" >&2
  exit 1
fi

# Toggle logic
if pgrep -f "alacritty.*${NAME}" > /dev/null; then
  # Process exists - check if this window is currently focused
  ACTIVE_TITLE=$(hyprctl activewindow -j | jq -r '.title')

  if [[ "$ACTIVE_TITLE" == "$NAME" ]]; then
    # This window is focused - hide it
    hyprctl dispatch togglespecialworkspace "${NAME}"
  else
    # Workspace exists but not focused - show and focus it
    hyprctl dispatch togglespecialworkspace "${NAME}"
    # Give it a moment to appear, then focus
    sleep 0.05
    hyprctl dispatch focuswindow "title:${NAME}"
  fi
else
  # Launch app - window rules put it in special:${NAME} (hidden)
  if [[ "$INTERACTIVE" == "true" ]]; then
    # Use interactive shell to ensure .zshrc is sourced (needed for asdf, etc.)
    alacritty --title "${NAME}" -e zsh -ic "${EXECUTABLE}" &
  else
    # Direct execution (faster, no .zshrc overhead)
    EDITOR="vim" alacritty --title "${NAME}" -e "${EXECUTABLE}" &
  fi

  # Wait for window to be created
  sleep 0.1

  # Show the special workspace and focus the window
  hyprctl dispatch togglespecialworkspace "${NAME}"
  hyprctl dispatch focuswindow "title:${NAME}"
fi
