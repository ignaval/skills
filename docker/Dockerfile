# codex-review sandbox image.
#
# The container IS the sandbox: repos are mounted read-only by codex-review.sh
# and codex runs inside with its own sandbox disabled
# (--dangerously-bypass-approvals-and-sandbox). The read-only mounts protect
# your checkouts; note that $CODEX_HOME is mounted writable for auth/session
# state and the container has network access — see the trust-boundary note in
# codex-review.sh.
#
# Build:
#   docker build -t codex-review:latest docker/
# Pin a tested codex CLI version for reproducible builds:
#   docker build --build-arg CODEX_VERSION=0.144.1 -t codex-review:latest docker/
#
# ca-certificates is required — without it every codex API call fails with
# "invalid peer certificate: UnknownIssuer".
FROM node:22-bookworm-slim

ARG CODEX_VERSION=latest

RUN apt-get update \
  && apt-get install -y --no-install-recommends git ripgrep ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && update-ca-certificates \
  && npm i -g "@openai/codex@${CODEX_VERSION}"

WORKDIR /work
