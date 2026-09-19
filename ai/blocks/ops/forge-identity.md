## Forge writes go through the Athena wrapper

Forge WRITES — PR/MR create, merge, comment, review, and authenticated push —
go through the Athena wrapper: `~/dev/custom/ai/bin/gh-athena` (GitHub) or
`~/dev/custom/ai/bin/glab-athena` (GitLab), so writes are attributed to Athena,
not the machine owner. The App config is present, so the wrapper works. READS
may use plain `gh`/`glab`. Verify wrapper health with
`~/dev/custom/ai/bin/forge-preflight` if a write fails. (This is the rule the
`forge-identity-guard.sh` hook warns about — the guard warns, the block
instructs.)
