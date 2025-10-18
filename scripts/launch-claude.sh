#!/bin/bash

# Change to default development directory
cd "$HOME/dev/custom" || cd "$HOME" || exit 1

# Launch an interactive shell that runs claude
exec "$SHELL" -i -c "/home/cjpoll/.asdf/shims/claude"
