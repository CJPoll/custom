---
name: overlay-probe
description: Confirms the private overlay's work plugin is loaded. Use only when asked to run the work overlay probe.
---

# work:overlay-probe

A synthetic skill shipped in the overlay skeleton. It exists so the owner can
measure that plugin skills load in each mode (an interactive session, a
headless `claude -p`, a subagent) before any real work skill moves here.

When invoked, reply with exactly this line and nothing else:

WORK-OVERLAY-PROBE-OK
