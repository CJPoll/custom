---
name: athena:brief-verification
description: Two verification disciplines for the athena-admiral — (4a) an environment fact must be VERIFIED with a named second probe before it enters a brief/state-log/merge decision (inherited facts are NOT verified; a subordinate's "unsatisfiable" report IS a probe result), and (4b) re-read a defect's CURRENT state immediately before dispatching a fix. Use before writing any environment claim into a brief and immediately before dispatching any fix.
---

# athena:brief-verification

A brief is where your conclusions become every captain's premises, so a wrong
fact does not stay wrong in one place — it is copied into five.

## 4a. An environment fact you put in a brief must be VERIFIED, not inferred

**A tool's failure output frequently cannot distinguish "absent" from
"misconfigured", and the default reading is the wrong one.** Measured twice:

- 2026-09-18-athena-inbox — bare `tmux` printed
  `command not found: _zsh_tmux_plugin_run`, a *broken zsh wrapper*, which reads
  as "tmux is not installed". The admiral concluded absence, **put it in a
  brief, and a captain "confirmed" it with the same broken tool.** *Agreement
  between two agents using one broken tool is not corroboration.* The verifying
  form is `command tmux` — bypass the shell's function/alias layer.
- The same run's `gh-athena` — `gh-athena api user` returns 403 for a GitHub App
  installation token, making a perfectly HEALTHY wrapper look broken to a naive
  probe. The wrapper's own `gh-athena --check` is the verifying form; a captain
  that took the 403 at face value would have fallen back to plain `gh` and
  mis-attributed the PR.

So: before an "X is not available / X is broken" claim enters a brief, a state
log, or a merge decision, **confirm it with a second, independent probe** — the
tool's own `--check`/`--version`, `command <name>`, `type -a <name>`, the
package/file on disk — and **write down WHICH probe you used**. When you dispatch
the claim, dispatch the probe with it, so a captain can re-verify rather than
re-assert. If you cannot find a second probe, mark the fact **unverified** in the
brief rather than stating it.

**A fact you INHERITED is not a verified fact** — a handoff note, a predecessor
admiral's state log, a prior brief. It is someone else's conclusion with the
probe missing, and a resume is exactly when you are most likely to copy it into
five briefs without noticing you never checked it. **And a subordinate's report
that an instruction is unsatisfiable IS a probe result** — the captain ran into
the real system, which you did not. Weigh it as evidence about the environment,
not as an excuse to be graded.

*Measured 2026-09-18-athena-inbox: the handoff listed "captains skip the Notion
status transition" as laziness, so admiral #2 put `In Review` into all five
briefs. The Tickets DB has no such option. Four captains had independently
reported that instruction as unsatisfiable and were disbelieved; the admiral's
own correction reads "THE PRIOR CAPTAINS WERE RIGHT, not evasive."*

Before an inherited fact enters a brief:

- **Query the authority, not the note.** For a tracker's
  status/label/assignee vocabulary that authority is the DB schema itself — read
  the property's options directly and paste the actual option set. One API call,
  cheaper than correcting five live captains.
- **Two independent subordinates reporting the same constraint outrank a handoff
  sentence.** Before concluding they are evading an instruction, verify the
  instruction is satisfiable at all. An agent that reports a rule as impossible
  is doing its job; the expensive failure is a fleet that silently fakes
  compliance.
- **When the authority cannot satisfy the instruction, write down the
  substitution** in the brief rather than dropping the requirement (for the
  no-`In Review` tracker: leave Status at `In Progress`, append an
  "Implementation status" block to the ticket BODY — PR URL, head SHA, CI state,
  scope boundary — and the terminal move stays yours; see [[athena:fleet-inputs]]).
  Record it as an assumption and report it; changing the schema is the owner's
  call.

## 4b. Re-read the defect immediately before you dispatch it

4a is about a fact you never verified. This is about one you verified
**correctly**, which then changed. With five concurrent captains, peer agents on
other machines, and an hourly cron all writing to the same repos and trackers,
every report you hold is a claim about the past by the time you act on it.
Staleness here is the normal condition, not bad luck.

**Before you spawn anyone to fix X, re-read X's current state.** The probe is
whatever makes the defect observable — `git log`/`git show` on the file or the
fix's own commit message, the ticket's current status, `gh pr view`, the file
itself. One call. Record in the state log what you re-read, what it said, and
when.

*The expensive instance, 2026-09-18: a captain report described a whole-worktree
staging sweep; the admiral judged it live and dispatched a captain to fix it. A
peer cron shipwright had ALREADY fixed it, merged and pushed before the dispatch.
Both `git log` and the tracker said so. Nobody looked, and a captain worked a
solved problem for ~45 minutes. Two more that night: an epic asserted to have run
on this machine when the PR author and session directory said otherwise, and an
outage about to be reported from three dead pids a supervisor had already
replaced.*

Two rules make the discipline durable:

- **A subordinate's report is evidence about the moment it was written, not
  about now.** Read its as-of fingerprint (the captain template requires one);
  re-check the mutable facts it names. A report with no fingerprint is not
  thereby current — treat every mutable claim in it as needing the probe.
- **"I already know this" is the state that produces the failure.** All three
  instances were confident, and two had a plausible rationalisation ready. A
  rationalisation that explains away missing evidence is the signal to run the
  probe, not the reason to skip it.

This is a step, not a virtue: the cost is one command, and skipping it is visible
in the state log as a dispatch with no recorded probe.

---

*Source (behavior-preserving relocation): athena-admiral §4a "An environment
fact you put in a brief must be VERIFIED" + §4b "Re-read the defect immediately
before you dispatch it". The admiral keeps a resident one-line trigger pointing
here.*
