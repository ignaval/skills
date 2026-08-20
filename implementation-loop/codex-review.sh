#!/usr/bin/env bash
# codex-review.sh — run ONE codex review pass on the host, sandboxed by codex itself.
#
# Sandboxing: `codex exec -s read-only` — model-generated shell commands can
# read the filesystem but write nothing. exec mode is non-interactive, so no
# approval prompts, and no external sandbox (no Docker) is required.
#
# TRUST BOUNDARY: read-only protects your files from writes; the reviewer can
# still READ broadly on your machine. Only review repos whose content you
# trust not to prompt-inject the reviewer.
#
# Hardened-kernel note: on setups that restrict unprivileged user namespaces
# (e.g. Ubuntu 24.04 with kernel.apparmor_restrict_unprivileged_userns=1),
# codex's BUNDLED bubblewrap fails with errors like
#   bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted
# Fix: install the system package — `sudo apt install bubblewrap` — which
# ships the AppArmor profile that unblocks it; codex prefers a bwrap found on
# PATH over its bundled one.
#
# Usage:
#   codex-review.sh <prompt-file> [effort] [repo ...]
#
#   <prompt-file>  Path to the review prompt (markdown), piped to codex on stdin.
#   [effort]       codex reasoning effort: high (default) | medium | low.
#                  Optional even when repos follow: a non-effort second
#                  argument is treated as the first repo.
#   [repo ...]     Repo paths the review covers. Each is validated to exist and
#                  the FIRST becomes codex's working directory. Reference repos
#                  and diff/plan files by ABSOLUTE path in the prompt — the
#                  reviewer reads them straight from disk.
#
# Env overrides:
#   CODEX_MODEL       codex model id      (default: gpt-5.6-sol)
#   CODEX_TIMEOUT     seconds per call    (default: 3600; exit 124 on hit)
#   CODEX_EXTRA_ARGS  extra flags appended to `codex exec`, whitespace-split
#                     (e.g. "--ephemeral --ignore-user-config").
#
# The sandbox mode is HARDCODED to read-only on purpose — an autonomous
# reviewer must never write. If you need something else, you are not running
# a review; edit the script and own the consequences.
#
# Output: codex's full response streams to stdout. NOTE for the caller: the
#   stream includes an ECHO OF THE PROMPT and trailing token accounting — do not
#   grep the raw transcript for the sentinel; judge codex's final answer.
#   Exit code is codex's (non-zero only on execution/auth/network/timeout
#   errors, NOT on "found issues" — findings are normal successful output).
set -euo pipefail

PROMPT_FILE="${1:?usage: codex-review.sh <prompt-file> [effort] [repo ...]}"
# effort is optional: when $2 is not an effort level, treat it as the first repo.
case "${2:-}" in
  high|medium|low) EFFORT="$2"; REPOS=( "${@:3}" ) ;;
  *)               EFFORT="high"; REPOS=( "${@:2}" ) ;;
esac

MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
TIMEOUT="${CODEX_TIMEOUT:-3600}"

die() { echo "codex-review: $*" >&2; exit 2; }

command -v codex >/dev/null || die "codex CLI not found on PATH (npm install -g @openai/codex)"
# GNU timeout: plain `timeout` on Linux, `gtimeout` from coreutils on macOS.
if command -v timeout >/dev/null; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null; then TIMEOUT_BIN=gtimeout
else die "GNU timeout not found (on macOS: brew install coreutils for gtimeout)"
fi
[[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"
case "$EFFORT" in high|medium|low) ;; *) die "effort must be high|medium|low (got: $EFFORT)";; esac
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "CODEX_TIMEOUT must be a positive integer number of seconds (got: $TIMEOUT)"

for r in "${REPOS[@]}"; do
  [[ -d "$r" ]] || die "repo not a directory: $r"
done

# Whitespace-split on purpose: operator-supplied flags. Flags that would
# change or disable the sandbox are refused — read-only is this script's
# contract, not a default.
read -r -a EXTRA_ARGS <<< "${CODEX_EXTRA_ARGS:-}"
for a in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
  case "$a" in
    --dangerously-*|-s|--sandbox|-s=*|--sandbox=*)
      die "CODEX_EXTRA_ARGS may not change the sandbox (refused: $a)";;
  esac
done

# Absolute path before any cd — the prompt may have been given relative.
PROMPT_ABS="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"

# First repo (when given) becomes the working directory, so repo-relative
# tooling behaves; prompts should still use absolute paths throughout.
if [[ ${#REPOS[@]} -gt 0 ]]; then
  cd "${REPOS[0]}"
fi

exec "$TIMEOUT_BIN" --kill-after=30s "${TIMEOUT}s" \
  codex exec -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
  -s read-only --skip-git-repo-check \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  - < "$PROMPT_ABS"
