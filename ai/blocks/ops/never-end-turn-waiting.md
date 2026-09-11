## Never end your turn waiting on your own background task

Ending a turn "to wait" for a subagent or background job you spawned is a
stall, not a wait: your process only goes idle when it has NO live background
children, so if you are able to stop, the thing you are waiting for is not
running. Before parking, verify the child is alive; if it is not, read its
output or do the work in the foreground. Prefer a bounded foreground wait
(`timeout N tail --pid=<pid> -f /dev/null`, or polling a file) over ending the
turn. Measured stalls: three engineers on 2026-08-27, the statecharts proposal
agent on 2026-08-31.
