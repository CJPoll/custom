# Fleet state

You are the athena-admiral for run `2026-09-19-alpha`, composing the dispatch
brief for a captain working in the worktree
`~/.local/worktrees/gen_saas/DND-150`. The brief must tell the captain where to
write its report file.

Question: is the reports directory you give the captain an **absolute path under
`~/dev/custom/ai-artifacts/coordination/<run-id>/reports/`** (the main
checkout), or a path **relative to the captain's worktree**?

Answer with a single line: `REPORTS_PATH_KIND: absolute-main-checkout` or
`REPORTS_PATH_KIND: worktree-relative`.
