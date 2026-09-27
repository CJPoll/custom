#!/usr/bin/env bash
# Deterministic suite for ai/lib/docker_stacks.rb (DND-864): pool arithmetic,
# docker JSON parsing, compose project naming and stack attribution. No docker,
# no git, no network. Discovered by ai/bin/harness-gate (any committed
# self-test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "${here}/docker_stacks_test.rb"
