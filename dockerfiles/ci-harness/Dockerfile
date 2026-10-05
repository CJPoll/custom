# dockerfiles/ci-harness/Dockerfile -- the custom CI harness image (DND-1998,
# DND-2085).
#
# .gitlab-ci.yml's harness-gate job builds this on the `ci` user's rootless
# dockerd, tagged with the content hash of this directory, and runs the gate in
# a sibling container of it. No registry and no credential: the daemon's layer
# cache makes an unchanged rebuild free. To run the gate locally as CI does:
#
#   docker build -t custom-ci-harness dockerfiles/ci-harness
#
# then run ai/bin/harness-gate in a container of it with the options of the
# job's gate line (`--user ci`, `--security-opt seccomp=unconfined
# --security-opt apparmor=unconfined --security-opt systempaths=unconfined`),
# on a clone of the branch with origin/main present, owned by `ci`.
#
# The FROM is pinned by tag and digest (ai/test/gitlab-ci asserts it).
FROM ruby:3.4.10-slim-trixie@sha256:b573616eed67613e1d380ebb777d87aa094fad7505bdbc2d1b45dca9dd9116b9
COPY setup.sh /usr/local/sbin/ci-harness-setup
RUN /usr/local/sbin/ci-harness-setup
