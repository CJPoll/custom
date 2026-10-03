## Forge writes go through the Athena wrapper

Forge WRITES — PR/MR create, merge, comment, review, and authenticated push —
go through the Athena wrapper: `~/dev/custom/ai/bin/gh-athena` (GitHub) or
`~/dev/custom/ai/bin/glab-athena` (GitLab) — each a drop-in for the base CLI,
same commands as `gh`/`glab` — so writes are attributed to Athena, not the
machine owner. The App config is present, so the wrapper works. READS
may use plain `gh`/`glab`. Verify wrapper health with
`~/dev/custom/ai/bin/forge-preflight` if a write fails. (Enforced twice, each with a
`Fix:`: the `forge-identity-guard.sh` hook denies the command text, and the agent
PATH `git`/`gh`/`glab` wrappers refuse the process, scripts included.)
