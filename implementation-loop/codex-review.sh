#!/usr/bin/env bash
# codex-review.sh — run ONE codex review pass on the host, sandboxed by codex itself.
#
# Sandboxing: `codex exec -s read-only` — model-generated shell commands can
# read the filesystem but write nothing. exec mode is non-interactive, so no
# approval prompts and no external sandbox are required.
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
#   [effort]       codex reasoning effort: xhigh (default) | high | medium | low | max.
#                  Optional even when repos follow: a non-effort second
#                  argument is treated as the first repo. A repo whose path is
#                  literally an effort word (`./high` written as `high`) is read
#                  as the effort, so pass repos as absolute paths.
#   [repo ...]     Repo paths the review covers. Each is validated to exist;
#                  the FIRST becomes codex's working directory (-C) and the
#                  rest are granted as extra directories (--add-dir). Still
#                  reference repos and diff/plan files by ABSOLUTE path in
#                  the prompt.
#
# Outputs:
#   stderr            codex's full session stream (shell calls, reasoning,
#                     an ECHO OF THE PROMPT, token accounting), plus this
#                     script's own errors. Keep it on disk for humans; do NOT
#                     parse it.
#   stdout            codex's final message, repeated. Redirect both streams
#                     to the same log (`> log 2>&1`).
#   $CODEX_ANSWER_FILE
#                     codex's FINAL ANSWER only, written via `-o`. This is
#                     the file a caller reads. It is JSON matching
#                     $CODEX_OUTPUT_SCHEMA (default: the colocated
#                     findings.schema.json — `{"findings":[...]}`, empty
#                     array = clean). Default path: <prompt-file>.answer.json
#                     — pass a per-round path so rounds don't overwrite.
#
# Env overrides:
#   CODEX_MODEL          codex model id   (default: gpt-6.2-sol)
#   CODEX_TIMEOUT        seconds per call (default: 3600; exit 124 on hit)
#   CODEX_ANSWER_FILE    where the final answer goes (see above)
#   CODEX_OUTPUT_SCHEMA  JSON Schema for the final answer; "none" disables
#                        the schema (final answer is then free text)
#   CODEX_SERVICE_TIER   codex service tier: fast | flex | default (unset: the
#                        user's config). Validated here, since -c is refused below.
#   CODEX_EXTRA_ARGS     extra flags appended to `codex exec`, whitespace-split.
#                        ALLOWLIST: --ephemeral, --ignore-user-config,
#                        --strict-config, --json, --color=<always|never|auto>.
#                        Anything else is refused: codex has many flags that
#                        weaken the sandbox (--yolo, --trust, --enable, ...),
#                        and a denylist cannot keep up with them.
#
# The sandbox mode is HARDCODED to read-only on purpose — an autonomous
# reviewer must never write. If you need something else, you are not running
# a review; edit the script and own the consequences.
#
# Exit code is codex's (non-zero only on execution/auth/network/timeout
# errors, NOT on "found issues" — findings are normal successful output).
# On ANY failure — preflight, codex non-zero, signal, or codex exiting 0
# without an answer — the answer file is REMOVED. So: a present, non-empty
# answer file always means a review happened.
set -euo pipefail
# CDPATH would make a relative `cd` land in another tree, and print that
# path into captured output.
unset CDPATH

PROMPT_FILE="${1:?usage: codex-review.sh <prompt-file> [effort] [repo ...]}"
# effort is optional: when $2 is not an effort level, treat it as the first repo.
case "${2:-}" in
  high|medium|low|xhigh|max) EFFORT="$2"; REPOS=( "${@:3}" ) ;;
  *)               EFFORT="xhigh"; REPOS=( "${@:2}" ) ;;
esac

# Not symlink-resolved (no portable readlink -f on bash 3.2/macOS): keep
# findings.schema.json beside this script; symlink the DIRECTORY, not the file.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${CODEX_MODEL:-gpt-6.2-sol}"
TIMEOUT="${CODEX_TIMEOUT:-3600}"
SCHEMA="${CODEX_OUTPUT_SCHEMA:-$HERE/findings.schema.json}"

die() { echo "codex-review: $*" >&2; exit 2; }

# Absolute paths — codex runs with its cwd set to the first repo. Prints
# nothing and fails when the parent directory does not exist.
abspath() {
  local d
  d="$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd)" || return 1
  echo "$d/$(basename -- "$1")"
}

# THE ANSWER-FILE INVARIANT: a present, non-empty answer file means a review
# happened. So the file is claimed and cleared FIRST — before any fallible
# preflight, including the prompt and schema checks — and a trap removes it on
# every exit path; the trap is disarmed only after a successful run wrote a
# non-empty answer. The only exits that leave the path alone are the ones that
# cannot leave a stale answer behind (its directory cannot be created) or must
# not touch it (it aliases an input).
ANSWER_FILE="${CODEX_ANSWER_FILE:-${PROMPT_FILE}.answer.json}"
mkdir -p "$(dirname -- "$ANSWER_FILE")" || die "cannot create answer directory for: $ANSWER_FILE"
ANSWER_ABS="$(abspath "$ANSWER_FILE")" || die "cannot resolve answer path: $ANSWER_FILE"
# Inputs are resolved best-effort here (empty when their directory is
# missing) so the alias check runs before the answer file is truncated; their
# existence is checked after the clear.
PROMPT_ABS="$(abspath "$PROMPT_FILE")" || PROMPT_ABS=""
SCHEMA_ABS=""
if [[ "$SCHEMA" != none ]]; then SCHEMA_ABS="$(abspath "$SCHEMA")" || SCHEMA_ABS=""; fi
# Never let the answer file alias an input (-ef also catches symlink/hard-link
# aliases; it is false for a missing file).
if [[ -n "$PROMPT_ABS" && ( "$ANSWER_ABS" == "$PROMPT_ABS" || "$ANSWER_ABS" -ef "$PROMPT_ABS" ) ]] \
   || [[ -n "$SCHEMA_ABS" && ( "$ANSWER_ABS" == "$SCHEMA_ABS" || "$ANSWER_ABS" -ef "$SCHEMA_ABS" ) ]]; then
  die "CODEX_ANSWER_FILE must not be the prompt or the schema: $ANSWER_ABS"
fi
# A symlinked answer path would be written through to its target, and the
# trap would remove only the link: replace it with a regular file.
if [[ -L "$ANSWER_ABS" ]]; then rm -f "$ANSWER_ABS" || die "cannot replace symlinked answer path: $ANSWER_ABS"; fi
trap 'rm -f "$ANSWER_ABS"' EXIT
: > "$ANSWER_ABS" || die "cannot write answer file: $ANSWER_ABS"

# codex runs as a background child so a signal is handled at once (bash
# defers traps until a FOREGROUND child exits, and GNU timeout puts itself in
# its own process group, so a terminal Ctrl-C never reaches it). The handler
# stops timeout, which forwards the signal to codex and KILLs it after the
# grace period, and waits for it: no orphan can write an answer after the
# EXIT trap has removed the file.
CHILD=""
on_signal() {
  if [[ -n "$CHILD" ]]; then
    kill -TERM "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
  fi
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

[[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"

command -v codex >/dev/null || die "codex CLI not found on PATH (npm install -g @openai/codex)"
# GNU timeout: plain `timeout` on Linux, `gtimeout` from coreutils on macOS.
if command -v timeout >/dev/null; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null; then TIMEOUT_BIN=gtimeout
else die "GNU timeout not found (on macOS: brew install coreutils for gtimeout)"
fi
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "CODEX_TIMEOUT must be a positive integer number of seconds (got: $TIMEOUT)"
if [[ "$SCHEMA" != none ]]; then
  [[ -n "$SCHEMA_ABS" && -f "$SCHEMA_ABS" ]] || die "output schema not found: $SCHEMA (set CODEX_OUTPUT_SCHEMA=none for free text)"
fi

for r in ${REPOS[@]+"${REPOS[@]}"}; do   # bash 3.2: empty-array guard under set -u
  [[ -d "$r" ]] || die "repo not a directory: $r"
done

# Whitespace-split on purpose: operator-supplied flags. An ALLOWLIST, not a
# denylist: read-only is this script's contract, and codex keeps adding flags
# that weaken it (--yolo, --trust, --worktree, --enable <feature>, ...).
# -d '' so newlines split too (IFS whitespace), not just the first line;
# read returns non-zero at EOF in that mode, hence || true.
EXTRA_ARGS=()
read -r -d '' -a EXTRA_ARGS <<< "${CODEX_EXTRA_ARGS:-}" || true
for a in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
  case "$a" in
    --ephemeral|--ignore-user-config|--strict-config|--json|--color=always|--color=never|--color=auto) ;;
    *) die "CODEX_EXTRA_ARGS allows only --ephemeral, --ignore-user-config, --strict-config, --json and --color=<always|never|auto> (refused: $a)";;
  esac
done

CWD_ARGS=()
ADD_DIR_ARGS=()
if [[ ${#REPOS[@]} -gt 0 ]]; then
  CWD_ARGS=( -C "$(cd -- "${REPOS[0]}" && pwd)" )
  for r in "${REPOS[@]:1}"; do ADD_DIR_ARGS+=( --add-dir "$(cd -- "$r" && pwd)" ); done
fi
SCHEMA_ARGS=()
if [[ -n "$SCHEMA_ABS" ]]; then SCHEMA_ARGS=( --output-schema "$SCHEMA_ABS" ); fi
TIER_ARGS=()
case "${CODEX_SERVICE_TIER:-}" in
  "") ;;
  fast|flex|default) TIER_ARGS=( -c "service_tier=\"$CODEX_SERVICE_TIER\"" ) ;;
  *) die "CODEX_SERVICE_TIER must be fast|flex|default (got: $CODEX_SERVICE_TIER)" ;;
esac

# Not exec'd: the EXIT trap must still run after codex returns. Backgrounded
# and waited on so INT/TERM interrupt the wait (see on_signal).
rc=0
"$TIMEOUT_BIN" --kill-after=30s "${TIMEOUT}s" \
  codex exec -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
  -s read-only --skip-git-repo-check \
  ${CWD_ARGS[@]+"${CWD_ARGS[@]}"} \
  ${ADD_DIR_ARGS[@]+"${ADD_DIR_ARGS[@]}"} \
  ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
  ${TIER_ARGS[@]+"${TIER_ARGS[@]}"} \
  -o "$ANSWER_ABS" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  - < "$PROMPT_ABS" &
CHILD=$!
wait "$CHILD" || rc=$?
CHILD=""
if (( rc != 0 )); then
  echo "codex-review: codex exited $rc — no review happened; answer file removed" >&2
  exit "$rc"   # EXIT trap removes the answer file
fi
[[ -s "$ANSWER_ABS" ]] || die "codex exited 0 but wrote no final answer (answer file removed): $ANSWER_ABS"
trap - EXIT    # success: keep the answer
