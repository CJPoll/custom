## Never end your turn waiting on your own background task

Ending a turn "to wait" for a subagent or background job you spawned is a
stall, not a wait: your process only goes idle when it has NO live background
children, so if you are able to stop, the thing you are waiting for is not
running. Before parking, verify the child is alive; if it is not, read its
output or do the work in the foreground. Prefer a bounded foreground wait
(`timeout N tail --pid=<pid> -f /dev/null`, or polling a file) over ending the
turn. Measured stalls: three engineers on 2026-08-27, the statecharts proposal
agent on 2026-08-31.

Being marked "completed" is not proof your work is done — it only means you
have no live child. Neither a completed status nor a background verification
gate you launched (a pipeline poll, a detached `prep-commit`, a spawned
reviewer) is license to yield: your task is done only when its own definition
of done is on disk — the commit made, the MR opened where the repo has one,
and the report written. If such a gate is running detached, block on it (rule
2) and finish the commit / MR / report in the SAME turn; never end a turn with
an uncommitted background gate you launched, and never park mid-gate expecting
to be resumed. (A merge-train or pipeline the harness genuinely cannot observe
is a legitimate external poll under rule 3 or an explicit hand-off to the
session that can watch it — not this case.) Measured stalls: captains on
2026-09-14/15 (ui-bg, aggregate-alignment ×3) and 2026-09-16 (PT-1289 ×3,
PT-1297, PT-1312) ended the turn on a background gate before committing /
opening the MR / writing the report; Sonnet captains did it chronically
(graphql-epics, workflows-phase1, processors-phase1, anchor-integration).
