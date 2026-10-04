# dockerfiles/ci-harness/Dockerfile -- the custom CI harness image (DND-1998).
#
# The same image .gitlab-ci.yml's harness-gate job builds in place: the same
# base digest, then the same setup.sh. Use it to run the gate locally exactly
# as CI does:
#
#   docker build -t custom-ci-harness -f dockerfiles/ci-harness/Dockerfile dockerfiles/ci-harness
#
# then, in a container of it run with `--security-opt seccomp=unconfined
# --security-opt systempaths=unconfined` (what the gate needs from the `ci`
# runner; .gitlab-ci.yml's header says where the runner gets them), a
# clone of the branch with origin/main present, owned by `ci`, and the job's
# last line: `runuser -u ci -- env HOME=/home/ci ai/bin/harness-gate`.
#
# The job does not pull a prebuilt image: building and publishing one needs a
# registry write credential, and the job carries none. ai/test/gitlab-ci
# asserts the FROM digest equals the job's image digest.
FROM ruby:3.4.10-slim-trixie@sha256:b573616eed67613e1d380ebb777d87aa094fad7505bdbc2d1b45dca9dd9116b9
COPY setup.sh /usr/local/sbin/ci-harness-setup
RUN /usr/local/sbin/ci-harness-setup
