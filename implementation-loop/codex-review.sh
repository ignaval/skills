#!/usr/bin/env bash
# codex-review.sh — run ONE codex review pass inside the codex-review Docker sandbox.
#
# Why Docker: the CONTAINER is the sandbox — repos are mounted READ-ONLY and
# codex's own sandbox is disabled inside it. This sidesteps environments where
# codex's bundled sandbox can't run (e.g. kernels that restrict unprivileged
# user namespaces) and guarantees the reviewer can never mutate your checkouts.
# Build the image from docker/Dockerfile in this repo (tag: codex-review:latest).
#
# TRUST BOUNDARY: the container has network access and mounts $CODEX_HOME
# writable (codex needs it for auth/session state). The read-only mounts protect
# your checkouts, not your codex credentials — only review repos whose content
# you trust not to prompt-inject the reviewer. (CODEX_EXTRA_ARGS="--ephemeral"
# keeps session history out of the mounted dir on codex versions that have it.)
#
# The container runs AS THE INVOKING USER by default (see CODEX_CONTAINER_USER
# below — rootless Docker needs "0:0"), so files codex writes into the mounted
# CODEX_HOME stay owned by you — a root container would litter root-owned files
# there and break later host-side codex runs. This requires the CODEX_HOME
# contents to be owned by you; if a previous root-container run left root-owned
# files behind, heal once with:
#   docker run --rm -v "$HOME/.codex:/ch" codex-review:latest chown -R "$(id -u):$(id -g)" /ch
#
# Usage:
#   codex-review.sh <prompt-file> [effort] [repo ...]
#
#   <prompt-file>  Host path to the review prompt (markdown). The prompt file's
#                  PARENT DIRECTORY is mounted read-only at /work/input, so the
#                  prompt and any sibling files (plan.md, diff-*.patch) are
#                  reachable inside as /work/input/<name>.
#   [effort]       codex reasoning effort: high (default) | medium | low
#   [repo ...]     Zero or more repo paths to expose to codex. Works for repos
#                  ANYWHERE on disk (paths must match [A-Za-z0-9/._-] — no
#                  spaces or shell metacharacters; the interpolation-safety
#                  whitelist below rejects anything else LOUDLY, by design).
#                  Each is mounted read-only at
#                  /work/projects/<basename> (host <repo> -> /work/projects/<basename>).
#                  Basenames must be unique across the given repos (collisions
#                  would silently shadow a mount — rejected loudly instead).
#                  If NONE are given, the whole projects root is mounted at
#                  /work/projects instead (default $HOME/projects, override with
#                  CODEX_PROJECTS_ROOT) — a convenience for repos under one root.
#
# Env overrides:
#   CODEX_MODEL          codex model id              (default: gpt-5.6-sol)
#   CODEX_HOME           codex config/auth dir       (default: $HOME/.codex)
#   CODEX_PROJECTS_ROOT  fallback root mount         (default: $HOME/projects)
#   CODEX_TIMEOUT        per-call timeout in seconds (default: 3600; exit 124 on hit)
#   CODEX_DOCKER_CMD     command that executes the docker invocation string
#                        (default: "bash -c"; set to "sg docker -c" if your
#                        user needs the docker group activated per-command)
#   CODEX_CONTAINER_USER uid:gid the container runs as (default: "$(id -u):$(id -g)").
#                        Set to "0:0" for ROOTLESS Docker, where bind mounts
#                        already map to your host user and a numeric uid would
#                        map to a subordinate uid that can't read CODEX_HOME.
#   CODEX_EXTRA_ARGS     extra flags appended to `codex exec` (default: empty;
#                        e.g. "--ephemeral --ignore-user-config" to keep session
#                        history out of the mounted CODEX_HOME and ignore host
#                        config.toml — verify your codex version supports them)
#
# Output: codex's full response streams to stdout. NOTE for the caller: the
#   stream includes an ECHO OF THE PROMPT and trailing token accounting — do not
#   grep the raw transcript for the sentinel; judge codex's final answer.
#   Exit code is codex's (non-zero only on execution/auth/network/timeout errors,
#   NOT on "found issues" — findings are normal successful output).
#
# Note: git inside the container needs  git config --global --add safe.directory '*'
#   before any git command (mounts owned by a different uid). Prefer embedding a
#   precomputed patch (see collect-diff.sh) so codex needn't run git at all.
set -euo pipefail

PROMPT_FILE="${1:?usage: codex-review.sh <prompt-file> [effort] [repo ...]}"
EFFORT="${2:-high}"
REPOS=( "${@:3}" )                                   # zero or more repo paths

MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROJECTS_ROOT="${CODEX_PROJECTS_ROOT:-$HOME/projects}"
TIMEOUT="${CODEX_TIMEOUT:-3600}"
EXTRA_ARGS="${CODEX_EXTRA_ARGS:-}"
CONTAINER_USER="${CODEX_CONTAINER_USER:-$(id -u):$(id -g)}"

die() { echo "codex-review: $*" >&2; exit 2; }

# Everything below is interpolated into a single command string handed to
# CODEX_DOCKER_CMD (e.g. `bash -c "..."`), so each value is validated against a
# strict whitelist — not just "no spaces". A path with ; $ ` " ' etc. would
# otherwise break out of the command string.
safe_path()  { [[ "$1" =~ ^/[A-Za-z0-9/._-]+$ ]] || die "unsafe path (allowed: A-Za-z0-9 / . _ -): $1"; }
safe_token() { [[ "$2" =~ ^[A-Za-z0-9._-]+$   ]] || die "unsafe $1 (allowed: A-Za-z0-9 . _ -): $2"; }

[[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"
case "$EFFORT" in high|medium|low) ;; *) die "effort must be high|medium|low (got: $EFFORT)";; esac
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "CODEX_TIMEOUT must be an integer number of seconds (got: $TIMEOUT)"
safe_token "model" "$MODEL"
[[ "$EXTRA_ARGS" =~ ^[A-Za-z0-9=._\ -]*$ ]] || die "unsafe CODEX_EXTRA_ARGS (allowed: A-Za-z0-9 = . _ - space): $EXTRA_ARGS"
[[ "$CONTAINER_USER" =~ ^[0-9]+:[0-9]+$ ]] || die "CODEX_CONTAINER_USER must be uid:gid (got: $CONTAINER_USER)"

PROMPT_DIR="$(cd "$(dirname "$PROMPT_FILE")" && pwd)"
PROMPT_NAME="$(basename "$PROMPT_FILE")"
safe_path "$PROMPT_DIR"
safe_token "prompt filename" "$PROMPT_NAME"
safe_path "$CODEX_HOME"

# Build the -v mount flags, rejecting duplicate basenames (a duplicate would
# mean one repo silently shadows another at /work/projects/<basename>).
MOUNT_STR=""
SEEN_BASES=" "
if [[ ${#REPOS[@]} -gt 0 ]]; then
  for r in "${REPOS[@]}"; do
    [[ -d "$r" ]] || die "repo not a directory: $r"
    abs="$(cd "$r" && pwd)"
    safe_path "$abs"
    base="$(basename "$abs")"
    [[ "$SEEN_BASES" == *" $base "* ]] && die "duplicate repo basename '$base' — two repos would collide at /work/projects/$base; rename or symlink one"
    SEEN_BASES+="$base "
    MOUNT_STR+=" -v ${abs}:/work/projects/${base}:ro"
  done
else
  [[ -d "$PROJECTS_ROOT" ]] || die "projects root not a directory: $PROJECTS_ROOT (set CODEX_PROJECTS_ROOT or pass repos explicitly)"
  safe_path "$PROJECTS_ROOT"
  MOUNT_STR=" -v ${PROJECTS_ROOT}:/work/projects:ro"
fi

# CODEX_DOCKER_CMD is intentionally word-split: it's an operator-supplied
# wrapper like `bash -c` or `sg docker -c` whose last word takes the whole
# docker invocation as one string argument.
read -r -a DOCKER_CMD <<< "${CODEX_DOCKER_CMD:-bash -c}"

# The inner `bash -c '...'` keeps the quoted TOML value intact through both
# this script's shell and the wrapper's shell. `timeout` runs INSIDE the
# container so the container exits with it (killing the host client would
# leave the container running).
"${DOCKER_CMD[@]}" "docker run --rm \
  --user ${CONTAINER_USER} -e HOME=/tmp -e CODEX_HOME=/codex-home \
 ${MOUNT_STR} \
  -v ${CODEX_HOME}:/codex-home \
  -v ${PROMPT_DIR}:/work/input:ro \
  codex-review:latest \
  bash -c 'timeout --kill-after=30s ${TIMEOUT}s codex exec -m ${MODEL} -c model_reasoning_effort=\"${EFFORT}\" --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox ${EXTRA_ARGS} - < /work/input/${PROMPT_NAME}'"
