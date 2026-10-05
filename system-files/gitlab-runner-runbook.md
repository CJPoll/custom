# Self-hosted GitLab Runner (walt_ui) — enable runbook

The GitLab mirror of the self-hosted GitHub runner: a dedicated `gitlab-runner`
user with its **own rootless dockerd**, an OpenRC-supervised `gitlab-runner run`,
registered as a **project runner** on the work GitLab project, with
gitlab.com **shared runners as fallback**. Architecture decided in DND-177.

The committed files (`scripts/setup-gitlab-runner*`, `system-files/*gitlab-runner*`)
are authored by the harness. **The steps below are yours to run** — they create a
user, install OpenRC services, and edit a shared team repo, none of which the
harness executes on your behalf.

## Design invariants (why it's shaped this way)

- **Fallback is non-negotiable, for every job type incl. builds.** All CI jobs
  stay **untagged**; the self-hosted runner is created with "Run untagged jobs"
  ON and **no tags**. So it grabs jobs when online (zero CI minutes) and
  gitlab.com shared runners run them when it is stopped/down.
- **`privileged = false`, always.** A CI job can never reach host root.
- **Image builds run unprivileged via BuildKit-as-a-job-image**
  (`moby/buildkit:rootless` + `buildctl-daemonless.sh`), NOT privileged dind and
  NOT a mounted docker socket. GitLab's docs confirm this same untagged job runs
  on **both** gitlab.com SaaS (no extra config) and a self-managed **unprivileged**
  runner (needs only the `security_opt` in `config.toml`).

**Later (2026-10-04, DND-1973):** the invariants above hold for the untagged
runner and any tag other than `ci` and `deploy`. A `ci` or `deploy` entry
written by `scripts/setup-gitlab-runner` carries a runner contract, because
those jobs drive a docker daemon (a project's Build and Tooling jobs, and its
deploy image builds):

| Role | `volumes` | `builds_dir` | `services_tmpfs` |
|---|---|---|---|
| `ci` | `/run/user/<uid>/docker.sock:/var/run/docker.sock`, `<builds>:<builds>`, `/srv/ci/<user>/cache:/cache` | `<builds>` = `/srv/ci/<user>/builds` | `"/var/lib/postgresql/data" = "rw,size=2g"` |
| `deploy` | the same three, each the deploy user's own | the deploy user's `<builds>` | none |
| other | `/srv/ci/<user>/cache:/cache` | unset | none |

`privileged = false` for every role. `<uid>` is the runner user's own uid, so
the socket is that user's rootless dockerd (`setup-gitlab-runner-docker`).
`setup-gitlab-runner-user` creates `<builds>` at `0711`, owned by the user;
`/srv/ci/<user>` (`0710 root:<user>`) keeps other host users out, and `0711`
lets a job's non-root user reach its checkout. It does not open the daemon to
that user: the socket stays the runner user's, so only the job's container root
can connect, unless the job proxies it (as gen_saas's `as-ci-user` does). `setup-gitlab-runner` refuses a
`ci` or `deploy` entry when the builds dir is missing or the uid is not a
number. A deploy runner is created in GitLab with `access_level=ref_protected`
and a `maximum_timeout` at least its longest job's.

Residual, named. Mounting the `ci` user's docker socket into `ci` jobs gives job
code control of that daemon, so a job can read anything the `ci` runner user
can, including its `config.toml` and runner token. That is accepted only
because the `ci` user holds no deploy secret (the deploy runner is its own user
and daemon), only the owner and the bot can push branches, and fork pipelines
never run in the parent project (DND-1942). The kit checks none of those three:
the first is the project's membership and protected-branch settings (owner
steps), and the last is the harness refusal DND-1942 adds. The deploy socket
gives the same power over the deploy user, and only protected-branch jobs reach
it.

**Later (2026-10-04, DND-1999):** `security_opt` is per role. Until then the
kit wrote `["seccomp:unconfined", "apparmor:unconfined"]` into every entry,
deploy included, so the "any tag other than `ci` and `deploy`" sentence above
no longer holds for `security_opt`: an unknown tag gets Docker's defaults.

| Role | `[runners.docker] security_opt` | Why |
|---|---|---|
| `ci` | `["seccomp:unconfined", "apparmor:unconfined"]` | tool-sandbox runs `bwrap --unshare-all ... --proc /proc`. Docker's default seccomp refuses the user namespace. The job container's `/proc` stays masked, so custom's job starts the gate in a sibling container through the job's socket, with the docker CLI's `systempaths=unconfined` (DND-2085, `ai/docs/ci-harness-masked-proc.md`). |
| `deploy` | none: Docker's default seccomp, masked `/proc` | Its jobs only drive the mounted socket (`docker build`; buildx's buildkitd is a sibling container the daemon starts). |
| untagged (`-`) | `["seccomp:unconfined", "apparmor:unconfined"]` | Rootless BuildKit as a job image nests a user namespace (the invariants above). `/proc` stays masked. |
| other | none: Docker's defaults | The kit knows no need for it. Deny by default. |

**Later (2026-10-05, DND-2039):** the `ci` row read `["seccomp:unconfined",
"apparmor:unconfined", "systempaths=unconfined"]`. The Docker Engine API
refuses `systempaths=unconfined` (it is a docker CLI flag; the API accepts only
`seccomp`, `apparmor`, `label` and `no-new-privileges` keys, "invalid
--security-opt 2"), so every `ci` job failed to start from 2026-10-04 10:52Z
until the live runner was set back to the pair. The kit matches the live
runner again, and its self-test rejects any value outside that grammar. The
masked `/proc` stays: unmasking it for `ci` is DND-1998, reopened for a new
approach, and is not decided here.

**Later (2026-10-05, DND-2085):** the `ci` row said "`/proc` stays masked, so
the proc mount is still refused (DND-1998 tracks unmasking it)". DND-1998
closed without a runner change. The job container's `/proc` stays masked.
custom's `harness-gate` job uses the socket it already holds to start the gate
in a sibling container with `--security-opt systempaths=unconfined`, which the
docker CLI turns into empty `MaskedPaths`/`ReadonlyPaths` the Engine API
accepts. A boundary probe in the job asserts on every run that the sibling's
root still cannot write `/proc/sys` or `/proc/sysrq-trigger` or read
`/proc/kcore` (`.gitlab-ci.yml`, `dockerfiles/ci-harness/boundary-probe.sh`).
Measured on the live `ci` runner 2026-10-05 (spike pipeline 2913148572): the
same sibling without `systempaths=unconfined` fails "Can't mount proc on
/proc", and with it bwrap mounts its own `/proc`.

Where AppArmor is not loaded, `apparmor:unconfined` changes nothing; it keeps
bwrap's and BuildKit's mounts working on a host where AppArmor is loaded. The
`ci` and `deploy` values match what the live runners were set to by hand on
2026-10-04 (DND-1998, DND-1999), so a rebuild reproduces them.

Residual, named. `seccomp:unconfined` lifts Docker's whole default filter for
`ci` job code, not only the calls bwrap needs. A job can create user
namespaces and mount `/proc` inside its job container, and can reach calls such
as `keyctl`, `bpf`, `perf_event_open` and `userfaultfd`. That is accepted on
the grounds of the residual above: the `ci` user holds no deploy secret.
Host-only `/proc` stays refused, because the job's root is a subuid on the
host. Measured on the live `ci` runner: writes to `/proc/sysrq-trigger` and
`/proc/sys/kernel/sysrq` are denied, and `/proc/kcore` cannot be opened. A
narrow seccomp profile for `ci` (Docker's default plus `unshare`, `clone`,
`clone3`, `mount`, `umount2`, `pivot_root`) closes the gap; it is tracked as
DND-2005.

A re-run keeps an existing entry, as below. If the kept entry's
`security_opt` is not its role's, `setup-gitlab-runner` names it with a
`Fix:` line: set or delete that one line in `config.toml` (`gitlab-runner`
reloads it without a restart), or delete the block and re-run with its token.

An entry written before DND-1973 has no contract, and a re-run keeps it as is.
To add the contract, delete that `[[runners]]` block from the config and re-run
`setup-gitlab-runner` with its token on stdin. The builds dir is not cleaned
by the kit: a cancelled job's leftovers stay until removed by hand.

## 1. Install (root)

```
sudo scripts/setup-gitlab-runner-user      # dedicated gitlab-runner user, no sudo/docker group
sudo scripts/setup-gitlab-runner-docker    # its own rootless dockerd (subuid 296608:65536, linger, OpenRC)
sudo scripts/setup-gitlab-runner           # gitlab-runner binary + OpenRC service; does NOT start
```

**Later (2026-10-03, DND-1937):** the kit serves N runner users per host, one
per trust domain. The commands above install the default user `gitlab-runner`,
unchanged. A second user adds `--user gitlab-runner-<suffix>` to all three
scripts; it gets its own subuid block, rootless dockerd
(`docker-rootless-gitlab-runner.<suffix>`), runner service
(`gitlab-runner.<suffix>`) and `0700` `/srv/ci/<user>/{docker,cache}`. Each
script's `--help` has the flags. One runner user holds one trust role: a ci
runner and a deploy runner are two users (e.g. `gitlab-runner-<suffix>` and
`gitlab-runner-<suffix>-deploy`), because a ci job runs merge-request code with
its user's docker socket and could otherwise reach a deploy job's OIDC token,
checkout and images. `setup-gitlab-runner` refuses a deploy entry in a ci user's
config. The deploy runner is created in GitLab with
`access_level=ref_protected`, so only protected-branch jobs reach it.

## 2. Register (as the runner user)

**Later (2026-10-03, DND-1937):** step 2 below puts the `glrt-` token in
`register`'s argv, where any process on the host can read it. Superseded:
create the runner with its tag and "Run untagged jobs" set in GitLab, then
`sudo scripts/setup-gitlab-runner --user <user> --runner <name>:<tag>` with
the token on stdin. It writes the `[[runners]]` entry with the
`[runners.docker]` block below into a `0600` config.toml. The walt_ui runner is
untagged (set in GitLab), and step 3's `concurrent = 3` is its job limit, so its
spec is `--runner <name>:-:3`; `-` records "untagged" in the entry.

1. GitLab: **walt_ui → Settings → CI/CD → Runners → New project runner**. Turn ON
   **"Run untagged jobs"**, leave **Tags empty**, copy the `glrt-…` token.
2. Register (the `--docker-security-opt` flags set the rootless-BuildKit block;
   `privileged` stays false):

   ```
   sudo -u gitlab-runner /usr/local/bin/gitlab-runner register --non-interactive \
     --url https://gitlab.com --token glrt-… \
     --executor docker --docker-image alpine:3.20 \
     --docker-security-opt seccomp:unconfined \
     --docker-security-opt apparmor:unconfined \
     --docker-volumes /cache \
     --config /home/gitlab-runner/.gitlab-runner/config.toml
   ```
3. Set global concurrency: edit that config, top-level `concurrent = 3`. Reconcile
   the whole `[runners.docker]` block against
   `system-files/gitlab-runner-config.toml.example`.

## 3. ⚠️ Ordering — do NOT start the service yet

Image-build jobs are untagged, so the runner grabs them the moment it starts. But
until walt_ui's **buildctl-rewrite MR** (below) is merged, those jobs still use
privileged dind and would **fail red** on the rootless runner. So: land that MR
first, **then**:

```
sudo rc-service gitlab-runner start
sudo rc-service gitlab-runner status
```

(Test/lint jobs are fine on the runner either way — only image builds need the MR.)

## 4. walt_ui `.gitlab-ci.yml` rewrite — your MR (harness never touches walt_ui)

Rework the image-build jobs from **privileged dind + `docker buildx`** to
**rootless BuildKit + `buildctl`**, keeping them **untagged** so both runners can
run them. Jobs affected: `.build:gcr-image` (base) + `release:push-image:{test,prod,amc}`
+ `porter:preview:build`. Per job:

- **DROP:** `image: docker:24`, the privileged `services: docker:24-dind`, the
  `DOCKER_HOST`/TLS vars, `docker context create`, `docker buildx create`.
- **ADD:** `image: { name: moby/buildkit:rootless, entrypoint: [""] }` and
  `variables: BUILDKITD_FLAGS: --oci-worker-no-process-sandbox`.
- **before_script** (no docker CLI in this image — write the registry auth
  directly to `~/.docker/config.json`): GitLab-registry jobs use
  `CI_REGISTRY_USER`/`CI_REGISTRY_PASSWORD`; GCR jobs use `_json_key` +
  `GCP_SERVICE_ACCOUNT_KEY`.
- **script** (`buildx → buildctl` mapping, verified):

  ```
  buildctl-daemonless.sh build \
    --frontend dockerfile.v0 \
    --local context=backend --local dockerfile=backend \
    --opt filename=Dockerfile \
    --opt build-arg:KEY=VAL … \
    --import-cache type=registry,ref=<cache-ref>          # was --cache-from
    --export-cache type=registry,ref=<cache-ref>,mode=max,image-manifest=true,oci-mediatypes=true \
                                                          # was --cache-to type=registry,mode=max
    --output type=image,"name=<REF1>,<REF2>",push=true    # was --tag … --push (multi-tag = comma-separated)
  ```
- **Stays UNTAGGED.** `buildctl` emits no provenance/sbom by default, so the
  earlier index-PUT workaround is satisfied inherently (drop the
  `--provenance=false --sbom=false` flags).
- **Re-validate** the old `--mtu=1400` / `--oci-worker-net=host` pin: it was
  SaaS-GCP-**dind**-specific. With no dind it drops; only re-add
  `BUILDKITD_FLAGS=--oci-worker-net=host` (or an MTU clamp) if large downloads
  (e.g. the tailwind binary) blackhole on this box's slirp4netns.

## 5. Enable-time validation (yours)

1. First real self-hosted build: confirm **nested unprivileged userns** works
   (buildkit-rootless nested inside the rootless-docker job container). If it
   errors, raise `user.max_user_namespaces` / confirm
   `kernel.unprivileged_userns_clone=1`. (The github-runner's rootless docker
   already proves userns is on; nesting only adds budget.)
2. Confirm `buildctl` push + cache to GCR and the GitLab registry.
3. Stop the self-hosted service and confirm the **same untagged job is green on
   SaaS** — that is the non-negotiable fallback, proven.

## Reverting

`sudo rc-service gitlab-runner stop` forces everything to SaaS. To fully remove:
`sudo rc-update del gitlab-runner; sudo rc-update del docker-rootless-gitlab-runner`,
stop both, and (optionally) `sudo userdel -r gitlab-runner`.
