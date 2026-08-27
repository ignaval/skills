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
#   [effort]       codex reasoning effort: high (default) | medium | low.
#                  Optional even when repos follow: a non-effort second
#                  argument is treated as the first repo.
#   [repo ...]     Repo paths the review covers. Each is validated to exist;
#                  the FIRST becomes codex's working directory (-C) and the
#                  rest are granted as extra directories (--add-dir). Still
#                  reference repos and diff/plan files by ABSOLUTE path in
#                  the prompt.
#
# Outputs:
#   stdout            codex's full session stream (shell calls, reasoning,
#                     an ECHO OF THE PROMPT, token accounting). Keep it on
#                     disk for humans; do NOT parse it.
#   $CODEX_ANSWER_FILE
#                     codex's FINAL ANSWER only, written via `-o`. This is
#                     the file a caller reads. It is JSON matching
#                     $CODEX_OUTPUT_SCHEMA (default: the colocated
#                     findings.schema.json — `{"findings":[...]}`, empty
#                     array = clean). Default path: <prompt-file>.answer.json
#                     — pass a per-round path so rounds don't overwrite.
#
# Env overrides:
#   CODEX_MODEL          codex model id   (default: gpt-5.6-sol)
#   CODEX_TIMEOUT        seconds per call (default: 3600; exit 124 on hit)
#   CODEX_ANSWER_FILE    where the final answer goes (see above)
#   CODEX_OUTPUT_SCHEMA  JSON Schema for the final answer; "none" disables
#                        the schema (final answer is then free text)
#   CODEX_EXTRA_ARGS     extra flags appended to `codex exec`, whitespace-split
#                        (e.g. "--ephemeral --ignore-user-config").
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

PROMPT_FILE="${1:?usage: codex-review.sh <prompt-file> [effort] [repo ...]}"
# effort is optional: when $2 is not an effort level, treat it as the first repo.
case "${2:-}" in
  high|medium|low) EFFORT="$2"; REPOS=( "${@:3}" ) ;;
  *)               EFFORT="high"; REPOS=( "${@:2}" ) ;;
esac

# Not symlink-resolved (no portable readlink -f on bash 3.2/macOS): keep
# findings.schema.json beside this script; symlink the DIRECTORY, not the file.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
TIMEOUT="${CODEX_TIMEOUT:-3600}"
SCHEMA="${CODEX_OUTPUT_SCHEMA:-$HERE/findings.schema.json}"

die() { echo "codex-review: $*" >&2; exit 2; }

# Absolute paths — codex runs with its cwd set to the first repo.
abspath() {
  local d
  d="$(cd -- "$(dirname -- "$1")" && pwd)" || die "cannot resolve path: $1"
  echo "$d/$(basename -- "$1")"
}

# THE ANSWER-FILE INVARIANT: a present, non-empty answer file means a review
# happened. So the file is claimed and cleared FIRST — before any fallible
# preflight — and a trap removes it on every exit path; the trap is disarmed
# only after a successful run wrote a non-empty answer.
[[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"
PROMPT_ABS="$(abspath "$PROMPT_FILE")"
ANSWER_FILE="${CODEX_ANSWER_FILE:-${PROMPT_FILE}.answer.json}"
mkdir -p "$(dirname -- "$ANSWER_FILE")" || die "cannot create answer directory for: $ANSWER_FILE"
ANSWER_ABS="$(abspath "$ANSWER_FILE")"
SCHEMA_ABS=""
if [[ "$SCHEMA" != none ]]; then SCHEMA_ABS="$(abspath "$SCHEMA")"; fi
# Never let the answer file alias an input (-ef also catches symlink/hard-link
# aliases; it is false for a missing file).
if [[ "$ANSWER_ABS" == "$PROMPT_ABS" || "$ANSWER_ABS" -ef "$PROMPT_ABS" ]] \
   || [[ -n "$SCHEMA_ABS" && ( "$ANSWER_ABS" == "$SCHEMA_ABS" || "$ANSWER_ABS" -ef "$SCHEMA_ABS" ) ]]; then
  die "CODEX_ANSWER_FILE must not be the prompt or the schema: $ANSWER_ABS"
fi
: > "$ANSWER_ABS" || die "cannot write answer file: $ANSWER_ABS"
trap 'rm -f "$ANSWER_ABS"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v codex >/dev/null || die "codex CLI not found on PATH (npm install -g @openai/codex)"
# GNU timeout: plain `timeout` on Linux, `gtimeout` from coreutils on macOS.
if command -v timeout >/dev/null; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null; then TIMEOUT_BIN=gtimeout
else die "GNU timeout not found (on macOS: brew install coreutils for gtimeout)"
fi
case "$EFFORT" in high|medium|low) ;; *) die "effort must be high|medium|low (got: $EFFORT)";; esac
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "CODEX_TIMEOUT must be a positive integer number of seconds (got: $TIMEOUT)"
if [[ "$SCHEMA" != none ]]; then
  [[ -f "$SCHEMA" ]] || die "output schema not found: $SCHEMA (set CODEX_OUTPUT_SCHEMA=none for free text)"
fi

for r in ${REPOS[@]+"${REPOS[@]}"}; do   # bash 3.2: empty-array guard under set -u
  [[ -d "$r" ]] || die "repo not a directory: $r"
done

# Whitespace-split on purpose: operator-supplied flags. Flags that would
# change or disable the sandbox, or redirect the answer, are refused —
# read-only is this script's contract, not a default.
# -d '' so newlines split too (IFS whitespace), not just the first line;
# read returns non-zero at EOF in that mode, hence || true.
EXTRA_ARGS=()
read -r -d '' -a EXTRA_ARGS <<< "${CODEX_EXTRA_ARGS:-}" || true
for a in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
  case "$a" in
    --dangerously-*|-s*|--sandbox|--sandbox=*)
      die "CODEX_EXTRA_ARGS may not change the sandbox (refused: $a)";;
    -c*|--config|--config=*|-p*|--profile|--profile=*)
      die "CODEX_EXTRA_ARGS may not override config or profiles (they can redefine the sandbox) (refused: $a)";;
    -o*|--output-last-message|--output-last-message=*|--output-schema|--output-schema=*|-C*|--cd|--cd=*|--add-dir|--add-dir=*)
      die "CODEX_EXTRA_ARGS may not set the answer file, schema, cwd or extra dirs — use the env knobs / repo args (refused: $a)";;
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

# Not exec'd: the EXIT trap must still run after codex returns.
rc=0
"$TIMEOUT_BIN" --kill-after=30s "${TIMEOUT}s" \
  codex exec -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
  -s read-only --skip-git-repo-check \
  ${CWD_ARGS[@]+"${CWD_ARGS[@]}"} \
  ${ADD_DIR_ARGS[@]+"${ADD_DIR_ARGS[@]}"} \
  ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
  -o "$ANSWER_ABS" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
  - < "$PROMPT_ABS" || rc=$?
if (( rc != 0 )); then
  echo "codex-review: codex exited $rc — no review happened; answer file removed" >&2
  exit "$rc"   # EXIT trap removes the answer file
fi
[[ -s "$ANSWER_ABS" ]] || die "codex exited 0 but wrote no final answer (answer file removed): $ANSWER_ABS"
trap - EXIT    # success: keep the answer
