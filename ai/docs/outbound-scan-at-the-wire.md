# Outbound scan at the wire

**Kind: living normative document.** Amended in place, per
`~/dev/custom/CLAUDE.md` → *Documentation conventions*.

This is the design for DND-2016: scan what `gh` and `glab` actually send, not
what their argv says they will send. It names the chosen mechanism, the options
it was chosen over, the evidence, and the build order. Once built, the normative
homes are the ones *Where things live* names; this document then defers to them.

## The class

`gh-athena` and `glab-athena` scan text bound for a public repository for
work-domain values (`ai/contracts/athena-private-overlay.md` → *The forge
path*). The scan reads the wrapper's argv and reconstructs the request the CLI
will make: which flags carry text, which file a flag names, which repository is
the target, which URL forms the CLI accepts, and which placeholders it fills.
Each of those is a model of the CLI, and each model has been wrong in a new way.

| Ticket | The CLI did | The argv model said |
|---|---|---|
| DND-1976 | `-l -t -b X`: pflag gives `-l` the value `-t`; X is the body | X is a positional, not scanned |
| DND-2006 | `-R ''` falls back to `GH_REPO` | a `-R` was given; the checkout's repo is the target |
| DND-2007 | `gh api` writes reach a public repo | api writes are out of scope |
| DND-2009 | glab fills `:branch` after the scan; `HTTPS://` routes like `https://` | the scanned text is the sent text; scheme match is case-sensitive |
| DND-2012 | `//host/<p>/-/merge_requests/N` names project `<p>` | not a URL; the cwd is the target |
| DND-2013 | text in an api endpoint's path segment reaches the repo | only the `?query` carries text |
| DND-2014 | `--related-issue` copies a server-side issue title into the MR | no text flag was given |
| DND-2015 | `-R gitlab.com/g/p` names host `gitlab.com`, project `g/p` | project `gitlab.com/g/p` (404, refused) |
| DND-2010 | the merge guard reads `-F query=@file`, then gh reads it again | the guard judged the bytes gh sends |
| DND-2017 | the hidden glab flag `--experimental-notes-text-or-file` sends a file as release notes | the flag table, built from `--help`, has no hidden flags |
| DND-2018 | `mr create -H <p> --create-source-branch` creates a branch on the head project | the head project is not a target |
| DND-2019 | `pr create --fill/--template` and `issue develop` send text gh builds | the text is the flags' text |

DND-2014 (landed, 6f16580c) names a whole class in glab's argv scan: *text
glab builds itself* (`--related-issue`, `--fill`, `--recover`, `--signoff`, an
editor). The argv scan cannot read that text, so it refuses those flags on any
target that is not private. DND-2019 is the same class on gh.

Every fix was correct and found the next hole, because the model is of an
external program whose input language is open-ended: pflag spellings, env
fallbacks, URL grammars, placeholders, locale, and text the server supplies.
DND-2014 cannot be closed by any argv model at all: the text is not in argv.
This is the non-converging loop `athena:critic-convergence` describes, and the
same shape as the git-stash-guard false-fire history (a lexical model of a
shell, patched one instance at a time).

The wire has no such ambiguity. A request has one method, one host, one path,
one query and one body, already resolved by the CLI. Scan that.

## What the scan protects, and from whom

- **Protects:** a work-domain value (the private overlay's patterns) reaching a
  public repository through the forge API, written by an honest agent that made
  a mistake.
- **Not a boundary:** a same-uid adversary. It can run the real CLI, read the
  token cache, or kill the proxy. That residual is already stated for the
  transport (`ai/lib/forge-transport/git-remote-athena-forge`) and the CLI
  isolation (`ai/lib/forge-cli-isolation.sh`), and it stands here unchanged.
- **The merge guards** protect a second property with the same argv shape: a
  merge or ref move happens only on a verified head. *Merges and ref moves at
  the wire* covers them.

## Options evaluated

### Option 1: a forward proxy the wrapper forces the CLI through

The wrapper starts a local MITM proxy for each invocation, then runs the CLI
with `HTTPS_PROXY` pointing at it and a trust store that holds only that
invocation's CA. The proxy reads each request, judges it, and forwards it or
refuses it.

- **Exact or reconstructed:** exact. The proxy sees the decoded request after
  the CLI resolved flags, files, env fallbacks, placeholders and server-derived
  text. Measured: `gh api graphql -F owner='{owner}'` reached the proxy as
  `"variables":{"owner":"CJPoll"}`, the placeholder already filled (*Evidence*).
- **Fail-closed:** by construction, not by enumeration. The CLI's trust store
  holds only the proxy's CA (`SSL_CERT_FILE=<ca>`, `SSL_CERT_DIR=<empty dir>`),
  so a connection that bypasses the proxy fails TLS before any byte of the
  request is sent. Measured for both CLIs with `NO_PROXY` set to the forge host:
  `x509: certificate signed by unknown authority`. A dead proxy is
  `connection refused`. A request the proxy cannot parse is refused.
- **Retires:** DND-2013 (the path is scanned); DND-2014's class and DND-2019
  (text the CLI builds is in the body it sends); DND-2017 (a hidden flag's file
  is in the body; no flag table decides what is text); DND-2018 and
  `issue develop` (a branch created through the API is a `ref` operation,
  refused without a grant, and its project is the wire path's); DND-2015 (the
  target comes from the wire path; the argv `-R` parse is retired with the argv
  scan); DND-2010 (with *Merges and ref moves at the wire*); and the class: no
  argv reading decides what is scanned.
- **Residual:** git content (it travels over the git transport, not the API;
  *Residuals*); text the server generates (GitHub `--generate-notes`); a
  multi-request command refused part-way leaves its earlier, clean writes in
  place; GitLab GraphQL mutation targets (scanned as public).
- **Cost:** measured parts: Ruby start with `openssl` loaded plus a P-256 CA key
  57 ms wall; a P-256 leaf certificate under 1 ms. Per connection, one extra
  loopback TLS handshake. Per distinct write target, one visibility read, which
  the argv scan already makes as a `gh repo view` / `glab api` subprocess. The
  scanner runs in-process instead of one `ruby` process per field. The
  end-to-end before/after wall time is measured by the proxy ticket on the
  self-test corpus (*Testing*), not asserted here.
- **Keys:** the CA key exists only in the proxy's memory. Only the CA
  certificate (public) is written, into the wrapper's 0700 per-invocation dir
  that `fci_isolate` already removes on exit. The forge token reaches the proxy
  only as the request header the CLI sends; it is never in the proxy's
  environment, argv, a file or a log.

### Option 2: the CLI's own request dump

- `glab`: `GLAB_DEBUG_HTTP=true` wraps the transport in `debugTransport`, which
  dumps the request and then calls `RoundTrip` on the same request
  (`internal/api/debug_transport.go`, glab 1.92.1). It is a log written at send
  time, with no point to stop the send.
- `gh`: `GH_DEBUG=api` logs traffic from the HTTP client in the same way. gh's
  source is not on this machine; the conclusion below does not depend on it.
- Neither CLI has a dry-run for writes. A rehearsal (run the command once
  against a sink, scan the capture, run it again for real) is a reconstruction
  too: the real run makes different requests when responses differ (`pr
  create` needs repository ids from earlier responses), stdin is consumed by
  the first run, and the second run's bytes are never the ones scanned.
- **Rejected.** Not pre-send, not exact, not fail-closed.

### Option 3: an allowlist of argv command shapes

A grep of the harness's own callers (`ai`, `scripts`, `git-custom`, tests
excluded) finds a small set: `pr create|merge|edit|close|comment|reopen`, `mr
create|merge|note|accept|list`, `api` with a few routes, `run rerun|watch`,
`repo create`. Agents type more shapes than scripts do, so a strict allowlist
refuses ordinary work.

- **Exact or reconstructed:** reconstructed. Matching a shape still parses argv
  with a model of pflag, so every DND-1976-style ambiguity stays.
- **Cannot see:** env fallbacks (DND-2006), placeholders filled later
  (DND-2009), text the CLI builds or copies from the server (DND-2014,
  DND-2019), files read twice (DND-2010), hidden flags (DND-2017).
- **Retires:** instances only, by refusing their shapes; not the class.
- **Rejected as the scan.** Its sound part moves to the wire, where operations
  are canonical: *The operation table*.

### Option 4: combinations

- **Chosen:** option 1, plus an allowlist of write *operations* judged at the
  wire (method and route template, GraphQL mutation field name), plus the
  merge guards demoted from detectors to granters.
- The argv scan stays in front of the wire scan, enforcing, until the owner
  decides to retire it (*Retiring the argv scan*). Two scans that must both pass
  are strictly stronger than either.

## The design

### Where it sits

```
gh-athena / glab-athena
  isolation (fci_isolate) -> merge guard (argv; grants) -> argv scan
  -> forge-wire start (CA, port, grants) -> CLI child with
     HTTPS_PROXY, SSL_CERT_FILE, SSL_CERT_DIR -> forge-wire judges each
     request -> forwards with the system trust store, or refuses
  -> wrapper reads the verdict log and sets its exit code
```

The proxy wraps every CLI child the wrapper runs for its caller, reads
included. Deciding from argv which calls could write is the reconstruction this
design removes. The merge guard's own reads run before the proxy starts and are
unaffected.

### Components, by bucket

| Bucket | Module (proposed path) | Job |
|---|---|---|
| Domain | `ai/lib/forge_wire/request.rb` | An HTTP/1.1 request as data: method, host, path, query, headers, body. Framing rules (Content-Length, chunked, refusal of anything else). |
| Domain | `ai/lib/forge_wire/target.rb` | The target of a request: GitHub `/repos/{o}/{r}/…`, `uploads.github.com/repos/{o}/{r}/…`, `/repositories/{id}/…`, GraphQL node ids; GitLab `/api/v4/projects/{id or path}/…`, `/groups/…`, GraphQL. |
| Domain | `ai/lib/forge_wire/fields.rb` | The text of a write: decoded path segments, query keys and values, and the body by content type. |
| Domain | `ai/lib/forge_wire/graphql.rb` | A GraphQL document's selected operation: type, name, top-level fields, string literals. |
| Domain | `ai/lib/forge_wire/operations.rb` | The operation table (data: `ai/lib/forge_wire/operations.tsv`) and grant matching. |
| Domain | `ai/lib/forge_wire/verdict.rb` | Forward or refuse, with the reason and exit code. Calls `OutboundScan.scan_line` (`ai/lib/outbound_scan.rb`, already pure). |
| Side Effects | `ai/lib/forge_wire/listener.rb` | Loopback listener, CONNECT, TLS termination with per-host leaf certificates, ALPN `http/1.1` only. |
| Side Effects | `ai/lib/forge_wire/upstream.rb` | Forwards to the real host with the system trust store, no proxy, TLS verification on (the `ai/lib/forge-http-pin.sh` rules). Reads visibility with the request's own credential header. |
| Side Effects | overlay patterns | `ai/lib/outbound_scan_sources.rb`, loaded once per proxy. |
| Manager | `ai/lib/forge_wire/manager.rb` | Per request: parse, derive target, read visibility, judge, forward or refuse, append the verdict log. |
| Framework | `ai/bin/forge-wire` | Starts the proxy for one invocation; `--help` on stdout, exit 0. |
| Framework | `ai/bin/gh-athena`, `ai/bin/glab-athena` | Start `forge-wire`, run the CLI through it, map verdicts to exit codes. |

The proxy and its operation table are loaded from the main checkout, as the
pre-push hook runs the main checkout's scanner, so a branch cannot widen the
table it is judged by (`~/dev/custom/CLAUDE.md` → *A check's own bar must not
live in the diff it is checking*). Self-tests load the branch copy explicitly.

### Starting the proxy

1. The wrapper isolates the CLI (`fci_isolate`), runs its merge guard and its
   argv scan, as it does.
2. It starts `forge-wire` with: the per-invocation dir, the forge
   (`github`/`gitlab`), the grants the merge guard issued, and a random proxy
   credential. The proxy's environment has no forge token and no proxy or TLS
   override variables (`FG_HTTP_UNSET_ENV`).
3. `forge-wire` creates the CA in memory, writes `ca.pem`, binds `127.0.0.1:0`,
   writes the port, and only then reports ready. The wrapper waits on the ready
   file with a bounded poll. No ready file is a refusal (exit 3, `Fix:`); the
   CLI does not run.
4. The CLI runs as a child with `HTTPS_PROXY` and `HTTP_PROXY` set to
   `http://<cred>@127.0.0.1:<port>`, `SSL_CERT_FILE=<dir>/ca.pem`,
   `SSL_CERT_DIR=<dir>/empty`, and `NO_PROXY`, `no_proxy`, `ALL_PROXY` unset.
   The proxy refuses a CONNECT without the credential, so it serves only this
   invocation.
5. When the CLI exits, the wrapper stops the proxy (blocking on its pid), reads
   the verdict log, prints each refusal with its `Fix:`, and exits 1 on HITS, 3
   on could-not-look or unparseable, else the CLI's own code.

Why `SSL_CERT_DIR` too: Go's `loadSystemRoots` replaces the default cert
*files* with `SSL_CERT_FILE` but still reads the default cert *directories*
unless `SSL_CERT_DIR` is set (`crypto/x509/root_unix.go`, Go 1.26). Both CLIs
are Go. glab's own `ca_cert` and `skip_tls_verify` come only from its config,
which is the wrapper's fresh empty dir.

### What is judged

Every request is parsed. A request is a **write** when its method is not GET or
HEAD, or it is a GraphQL request whose operation is a mutation, or whose
operation type cannot be read. GraphQL operation type is read by a lexer that
skips strings and comments and finds the selected operation's keyword; anything
else is unreadable and judged as a mutation.

For a write, **the text** is:

- every decoded path segment and every query key and value;
- the body, by `Content-Type`: JSON, every string key and value, recursively;
  form-urlencoded, every decoded key and value; multipart, every part's name,
  filename and content; anything else, the raw bytes;
- a request `Content-Encoding` of gzip or deflate is decoded; any other is
  refused.

**The target** is derived from the host and path:

- GitHub REST: `repos/{o}/{r}` (api and uploads hosts); `repositories/{id}`
  resolved by id; any other path is unknown.
- GitHub GraphQL: every value under a `variables` key named `id`, `*Id` or
  `*Ids` is resolved with one `node` query to its repository. A mutation whose
  document holds a string literal, an id that is not a non-empty string, a
  mutation with no id, or an id that does not resolve, has an unknown target.

  **Later (2026-10-04, DND-2025):** this read "each `ID` value in
  `variables`". The judge has no schema, and gh sends its ids inside input
  objects (`input.repositoryId`, `input.subjectId`), whose GraphQL type is
  the input type, so a type-driven reading finds none. The key name is what
  the wire carries; a missed id can only add an unknown (public) target.
- GitLab REST: `api/v4/projects/{id or encoded path}` and `api/v4/groups/…`;
  any other path is unknown. A body `target_project_id` is a second target:
  `mr create -H <head>` posts the MR to the head project's route with the
  target project in the body (the DND-2018 fixture).
- A path segment not spelled plainly (a percent-escape in a GitHub owner or
  repo, a dot or empty segment, a GitLab project whose decoded path is not
  plain) makes the target unknown: two readers of one unplain path can name
  two repositories.
- GitLab GraphQL: unknown (*Residuals*).

Visibility is read upstream with the request's own credential header, once per
target per invocation: GitHub `GET /repos/{o}/{r}` → `.visibility`, GitLab
`GET /api/v4/projects/{id}` → `.visibility`. The outcome rules are the argv
scan's, unchanged (`ai/lib/outbound-text-scan.sh`): the text is scanned unless
every target reads private; an unknown target is public; GitHub scans an
unreadable visibility as public; GitLab refuses it (COULD NOT LOOK); GitLab
`internal` is public. The scanner outcomes (CLEAN, HITS, COULD NOT MEASURE, the
unmarked-machine warning, WAIVED) keep their meanings.

### The operation table

A write is forwarded only if the table names its operation. Unknown is refused
(exit 3) with a `Fix:` naming the operation and the table. Operations are
canonical at the wire: one route template or one mutation field name per
operation, so the table converges where an argv table does not.

Each row is `forge, method or "graphql", route template or mutation name,
class`:

- `text`: scanned under *What is judged*.
- `ref`: moves a branch or merges. Forwarded only under a matching grant.
- `plain`: carries no free text (a rerun, a label id). Still scanned; the class
  is documentation.

The initial rows are the operations the captured fixtures show the harness's
commands making (*Testing*). Example rows, synthetic and illustrative:

```
github  POST   /repos/{o}/{r}/issues/{n}/comments   text
github  PUT    /repos/{o}/{r}/pulls/{n}/merge        ref
github  graphql createPullRequest                     text
github  graphql mergePullRequest                      ref
gitlab  POST   /projects/{p}/merge_requests           text
gitlab  PUT    /projects/{p}/merge_requests/{iid}/merge   ref
gitlab  POST   /projects/{p}/merge_trains/merge_requests/{iid}  ref
```

### Merges and ref moves at the wire

Access control for the `ref` class:

1. **Who.** Only an invocation whose merge guard (`gmg_guard`,
   `glmg_guard`) verified a merge: head pinned, checks green, integration
   receipt, base not red. The guard's verification rules are unchanged.
2. **What.** One grant per verified merge: forge, repository, PR or MR
   number, head SHA, and the operations that merge sends (for example the
   head-branch delete of `--delete-branch`).
3. **Where.** The proxy's verdict, before forwarding, on the path every
   request takes.
4. **How.** It integrates the existing guards as the only granters. No second
   merge policy. The guard's argv parse now only decides whether to grant, and
   the proxy checks the actual request against the grant: GitHub REST `sha` in
   the body, GraphQL `expectedHeadOid` and the node the `pullRequestId`
   resolves to; GitLab `sha` on the merge and merge-train routes. Which fields
   each sanctioned merge command sends is read from the captured fixtures, not
   assumed. A misparse can only fail to grant, which refuses.
5. **Denial.** The proxy answers the CLI 403 and logs the reason; the wrapper
   exits 3 with a `Fix:` naming `integration-gate`, then `locked-merge`.

Deny by default: a `ref` operation with no grant, a grant for another SHA, PR
or repository, and a second use of a one-shot grant are all refused. This
retires DND-2010: the proxy judges the GraphQL document gh sends, not the file
the guard read. It also replaces the guards' lists of forbidden api routes and
mutations, which have the argv shape: the table's default-deny covers a route
or mutation nobody listed.

### Fail-closed behaviour

| State | Result |
|---|---|
| `forge-wire` fails to start or never reports ready | wrapper exit 3, CLI not run |
| CLI dials the forge directly (`NO_PROXY`, a code path that ignores the proxy) | TLS fails on the CA-only trust store; nothing sent |
| proxy dies mid-run | CLI gets connection refused; nothing more sent; wrapper exit 3 |
| CONNECT without the invocation's credential | refused |
| request not HTTP/1.1, bad chunk framing, unknown request encoding, `Expect` other than `100-continue`, an upgrade | refused, exit 3 |
| body over the size cap (set by the proxy ticket, named in `--help`) | refused, exit 3 |
| write to an operation not in the table | refused, exit 3 |
| `ref` operation without a matching grant | refused, exit 3 |
| CONNECT to a host outside the forge's list | reads forwarded; any write refused |
| visibility unreadable | GitHub: scanned as public; GitLab: refused (COULD NOT LOOK) |
| scanner COULD NOT MEASURE | refused, exit 3, except the unmarked-machine rule |
| verdict log missing or unreadable after the CLI exits | wrapper exit 3: a missing log never reads as clean |

### Residuals

- **git content.** Pushes go over the git transport. The pre-push hook scans
  them, and git can be told to skip it, so the transport
  (`git-remote-athena-forge`) runs the landed scan on the pushed range itself
  through `ai/lib/forge-push-scan` (DND-2023). The hook script, scanner and
  patterns it runs are the main checkout's; the transport and
  `forge-push-scan` themselves load beside the wrapper invoked, so a
  worktree's wrapper runs that branch's copies. Its residuals are in that
  program's header.

  **Later (2026-10-05, DND-2023):** this bullet said `gh-athena git push
  --no-verify` skipped the scan and named the transport scan as its own
  ticket. The regression test (`ai/test/forge-push-scan/self-test.sh`)
  reproduced the skip for `--no-verify` and three `core.hooksPath` routes;
  the transport scan refuses each of them through the main checkout's
  wrapper.
- **Server-generated text.** `--generate-notes`, `--notes-from-tag`: GitHub
  composes it. Its sources (PR titles, tag messages) were scanned when written.
- **Partial writes.** A multi-request command refused part-way leaves its
  earlier writes, which were clean.
- **GitLab GraphQL mutations** have an unknown target, so work text sent to a
  private project that way is refused when it matches. glab's harness writes
  are REST.
- **Same uid.** As stated in *What the scan protects, and from whom*.
- **The scanner's patterns** are the overlay's; a value no pattern describes
  passes, as today.

### Retiring the argv scan

The argv text scan, its target resolution and its flag tables (`gos_*`,
`glos_*`, the text half of `ai/lib/outbound-text-scan.sh`, `gh-target-repo.sh`)
become redundant once the wire scan refuses every case in their regression
suites. Dropping a check that looks redundant is the owner's decision
(`ai/blocks/ops/safety-checks.md`; `~/.claude/CLAUDE.md` → *Owner approval
policy*, item 5). Until then both run, and the argv scan's false refusals
stand: DND-2015, and the *text glab builds itself* refusals (`--fill` and the
rest on a public project), which the wire scan would judge by their actual text
instead.

## Testing

Functional only (DND-1222): no load, no timing verdicts. A timeout only caps a
hang.

- **Fixtures are real bytes.** `ai/lib/test/forge-wire/capture/capture` runs
  the pinned gh 2.96.0 and glab 1.92.1 against a local fake upstream with
  synthetic tokens and synthetic repositories, for each harness command shape
  and each earlier leak, and records each request under
  `ai/lib/test/forge-wire/fixtures/`. Nothing reaches a forge: the fake is a
  CONNECT proxy with no upstream socket, and the CLI's trust store holds only
  its CA.

  **Later (2026-10-04, DND-2025):** this named "a capture mode of the proxy".
  The judge (build step 1) lands before the proxy (step 2), so the capture is
  a test tool of its own; it never forwards, so it shares nothing with the
  proxy's forwarding path.
- **Domain tests** feed the fixtures to `request`, `target`, `fields`,
  `operations` and `verdict`, plus hand-built malformed requests for every row
  of *Fail-closed behaviour*.
- **Every historical instance is a regression case.** DND-1976, 2006, 2007,
  2009, 2010, 2012, 2013, 2014, 2017, 2018 and 2019 each run through the real wrapper and the real
  CLI against the fake upstream: sent with the wire scan off (the current
  wrappers), refused with it on. The planted value is synthetic.
- **Grant tests:** a granted merge is forwarded; a merge with no grant, another
  SHA, another number, another repository, or a reused grant is refused.
- **Bypass tests:** the CLI with `NO_PROXY` covering the fake host fails TLS;
  a dead proxy refuses; a CONNECT without the credential is refused.
- **The fake upstream** is a seam that changes where the proxy forwards and
  which CA it trusts upstream. It cannot turn judging off.

## Build order

1. Wire judge, Domain only, with captured fixtures.
2. `forge-wire` proxy (listener, upstream, manager, verdict log, `--help`).
3. `glab-athena` runs glab through it, enforcing, beside the argv scan.
4. `gh-athena` the same, after PR #392 (DND-2007) lands.
5. The operation table and merge grants in both wrappers; the merge guards
   become granters.
6. The git transport scans the pushed range itself (built: DND-2023).
7. Retiring the argv scan, on the owner's decision.

## Where things live

Once built: the proxy's `--help` (`ai/bin/forge-wire`) and the module headers
under `ai/lib/forge_wire/`; the outcome rules stay in
`ai/lib/outbound-text-scan.sh` and the contract's *The forge path* and *The
GitLab forge path*, which the wrapper tickets amend. The git half: the
header of `ai/lib/forge-push-scan` and the contract's *The transport's
push-range scan*.

## Evidence

Read-only probes, 2026-10-04, real gh 2.96.0 (`/usr/bin/gh`) and glab 1.92.1,
a capture-only Ruby proxy that never connected upstream, synthetic tokens,
empty CLI config dirs:

- `gh api repos/synth-owner/pub` through the proxy: `CONNECT api.github.com`,
  ALPN `http/1.1`, `GET /repos/synth-owner/pub`, credential in
  `Authorization`.
- `gh api graphql -f query='query { viewer { login } }' -F owner='{owner}'`:
  `POST /graphql`, body `{"query":"query { viewer { login } }","variables":{"owner":"CJPoll"}}`.
  gh filled the placeholder from the checkout before sending.
- `glab api 'projects/synth-group%2Fpub'`: `CONNECT gitlab.com`,
  `GET /api/v4/projects/synth-group%2Fpub`, credential in `Private-Token`.
- `glab api graphql -f query=…`: `POST /api/graphql`, JSON body.
- With `NO_PROXY` set to the forge host and the CA-only trust store: gh
  `tls: failed to verify certificate: x509: certificate signed by unknown
  authority`, exit 1; glab the same, exit 1.
- With the proxy port closed: gh `proxyconnect tcp: … connection refused`,
  exit 1.
- Proxy setup (EC CA, listener) inside Ruby: 0.9 ms. Ruby start with
  `openssl` plus one P-256 key: 57 ms wall.
- glab source: `internal/api/client.go` (transport `Proxy:
  http.ProxyFromEnvironment`, `ca_cert` from config only),
  `internal/api/debug_transport.go` (dump, then send).
