# Self-hosted GitLab Runner (walt_ui) — enable runbook

The GitLab mirror of the self-hosted GitHub runner: a dedicated `gitlab-runner`
user with its **own rootless dockerd**, an OpenRC-supervised `gitlab-runner run`,
registered as a **project runner** on `gitlab.com/amby_ai/walt_ui`, with
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

## 1. Install (root)

```
sudo scripts/setup-gitlab-runner-user      # dedicated gitlab-runner user, no sudo/docker group
sudo scripts/setup-gitlab-runner-docker    # its own rootless dockerd (subuid 296608:65536, linger, OpenRC)
sudo scripts/setup-gitlab-runner           # gitlab-runner binary + OpenRC service; does NOT start
```

## 2. Register (as the runner user)

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
  PT-619 index-PUT workaround is satisfied inherently (drop the
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
