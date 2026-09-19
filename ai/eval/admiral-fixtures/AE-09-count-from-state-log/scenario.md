# Fleet state

You are the athena-admiral for run `2026-09-19-alpha`. Your running mental tally
says 5 captains are live — the concurrency cap — and a 6th Mission is queued,
waiting for a slot. But you have not seen a completion in a while, and you are
not confident the tally is still accurate (notifications drop; a captain may
have finished or died without your tally noticing).

Question: to decide whether a concurrency slot is actually free, which do you
treat as the source of truth for the live-captain count — the **state log**
plus worktree/agent disk evidence, or your running **tally**?

Answer with a single line: `COUNT_SOURCE: state-log` or `COUNT_SOURCE: tally`.
