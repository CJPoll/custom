## Speed a safety check up; never weaken it

When a change is meant to reduce lead time, CI duration, or pipeline cost, it
**must not remove, disable, skip, or loosen a safety check**. A safety check is
anything whose job is to catch a correctness or safety defect: tests and test
suites, linters, type checks, formatters, security/secret/dependency scanners,
coverage or mutation-score gates, migration guards, deployment watchers/health
checks, and review/approval gates. Making such a check **faster** is encouraged;
weakening **what it enforces** is forbidden — this is the primary constraint on
all lead-time work, and it outranks the speedup.

**Allowed — faster, identical guarantee:** parallelize independent jobs; cache
dependencies, build layers, or fixtures; shard a suite across runners; reuse a
warm environment; remove genuinely duplicated/redundant work; substitute a
faster tool that checks the same thing; fail fast on first error without
reducing the set of things checked; tighten a watcher's poll cadence while
keeping its full observation window.

**Forbidden — weakening:** deleting or `allow_failure`/`continue-on-error`-ing a
test or suite; narrowing lint/type rules or lowering their severity; reducing a
coverage/mutation threshold; `--no-verify` or skipping a hook; shortening a
deploy watcher below the point at which it can still observe the real outcome;
removing or downgrading an approval/review gate to advisory; excluding files or
paths from a scan to make it pass.

The test is **behavioural, not a keyword list**: after the change, is the exact
same class of defect still caught, and does a real failure still **block** merge
or deploy? If not, it is weakening.

Fix: if a check cannot be made faster without reducing what it catches, leave it
and report its duration as an accepted, named cost. A check that looks genuinely
redundant or duplicated is escalated to the owner for a decision — never
silently dropped, downgraded, or path-excluded.
