#!/usr/bin/env bash

CLIENT_HEIGHT=$(tmux display-message -p '#{client_height}');
MINOR_PANE_HEIGHT=$(((${CLIENT_HEIGHT} / 4)));
MAIN_PANE_HEIGHT=$((($CLIENT_HEIGHT - $MINOR_PANE_HEIGHT)));

tmux set-window-option -g main-pane-height ${MAIN_PANE_HEIGHT};
