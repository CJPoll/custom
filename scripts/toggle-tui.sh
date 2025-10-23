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
  # Kill the process - window closes and workspace auto-hides
  pkill -f "alacritty.*${NAME}"
else
  # Launch app - window rules put it in special:${NAME} (hidden)
  if [[ "$INTERACTIVE" == "true" ]]; then
    # Use interactive shell to ensure .zshrc is sourced (needed for asdf, etc.)
    alacritty --title "${NAME}" -e zsh -ic "${EXECUTABLE}" &
  else
    # Direct execution (faster, no .zshrc overhead)
    alacritty --title "${NAME}" -e "${EXECUTABLE}" &
  fi
  # Show the special workspace
  hyprctl dispatch togglespecialworkspace "${NAME}"
fi
