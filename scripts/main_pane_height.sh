#!/usr/bin/env bash

CLIENT_HEIGHT=$(tmux display-message -p '#{client_height}');
MAIN_PANE_HEIGHT=$((CLIENT_HEIGHT * 2/3));

tmux set-window-option -g main-pane-height ${MAIN_PANE_HEIGHT};
