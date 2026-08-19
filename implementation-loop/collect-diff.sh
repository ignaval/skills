#!/usr/bin/env bash
# collect-diff.sh — print a comprehensive, review-ready diff for ONE repo.
#
# Emits, with a header identifying the repo/branch/HEAD:
#   1. `git status --short`         (orientation)
#   2. `git diff HEAD`              (all tracked changes vs last commit,
#                                    staged AND unstaged — no index mutation)
#   3. full contents of each new untracked file, rendered as a unified diff via
#      `git diff --no-index` so BINARY files show "Binary files differ" instead
#      of dumping bytes into the review.
#
# Usage:   collect-diff.sh <repo-path>
# Typical: collect-diff.sh /path/to/repo-a > "$SCRATCH/diff-repo-a.patch"
#
# Read-only in git terms: never stages, commits, or otherwise mutates the repo
# (GIT_OPTIONAL_LOCKS=0 suppresses opportunistic index refreshes too). Caveat:
# like ANY `git status`/`git diff`, repository-configured clean/process filters
# (.gitattributes + filter.* config) still execute on the host — this script
# does not neutralize them, so it inherits whatever your repo's filters do.
# Warns on stderr if the emitted diff is very large (may not fit a codex
# context — consider reviewing repos in separate rounds).
set -euo pipefail

# No opportunistic index refresh, no repo-configured external diff/textconv
# drivers. (Clean/process filters still run — see the caveat above.)
export GIT_OPTIONAL_LOCKS=0

REPO="${1:?usage: collect-diff.sh <repo-path>}"
cd "$REPO"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "collect-diff: not a git repo: $REPO" >&2
  exit 2
fi

# symbolic-ref (not rev-parse --abbrev-ref): on an unborn HEAD the latter
# prints "HEAD" on stdout AND fails, so the fallback would append a 2nd line.
branch="$(git symbolic-ref --short -q HEAD || echo '(detached)')"
if git rev-parse --verify -q HEAD >/dev/null; then
  head="$(git rev-parse --short HEAD)"
  has_head=1
else
  head='(no commits yet)'   # unborn HEAD: everything shows up as untracked below
  has_head=0
fi

emit() {
  echo "############################################################"
  echo "# REPO:   $REPO"
  echo "# BRANCH: $branch"
  echo "# HEAD:   $head"
  echo "############################################################"
  echo
  echo "===== git status --short ====="
  git status --short
  echo
  echo "===== tracked changes vs HEAD (git diff HEAD) ====="
  if [[ "$has_head" == 1 ]]; then
    # No || true: a failing diff must abort loudly — an incomplete patch that
    # gets reviewed as comprehensive is worse than a hard error.
    git diff --no-ext-diff --no-textconv HEAD
  else
    echo "(repo has no commits yet — all files appear as untracked below)"
  fi
  echo
  echo "===== new untracked files (full contents as unified diff) ====="
  local f rc
  # Standalone checked command into a file: inside `$( )` or a process
  # substitution, a git failure would slip past `set -e` and silently yield an
  # incomplete "no untracked files" patch. NUL-delimited so filenames with
  # newlines/quoting survive intact.
  git ls-files --others --exclude-standard -z > "$untracked_list"
  if [[ ! -s "$untracked_list" ]]; then
    echo "(none)"
  else
    while IFS= read -r -d '' f; do
      echo
      # Symlinks first: git stores a symlink as its target path, and
      # --no-index either follows it (file target) or errors out (directory
      # target) — record the link itself explicitly instead.
      if [[ -L "$f" ]]; then
        printf 'new untracked symlink: %s -> %s\n' "$f" "$(readlink -- "$f")"
        continue
      fi
      # An embedded git repo shows up as a bare directory entry; diffing it
      # fails uselessly — flag it in the output instead of dropping it.
      if [[ -d "$f" ]]; then
        echo "(embedded repository/directory '$f' NOT included — run collect-diff.sh on it separately)"
        echo "collect-diff: WARNING: skipped embedded repository/directory: $f" >&2
        continue
      fi
      # --no-index against /dev/null renders the whole file as additions and is
      # binary-safe. It exits 1 when files differ (always true here); anything
      # >1 is a real error and must not be silently swallowed.
      rc=0; git diff --no-ext-diff --no-textconv --no-index -- /dev/null "$f" || rc=$?
      if (( rc > 1 )); then
        echo "collect-diff: ERROR: git diff failed (exit $rc) for: $f" >&2
        exit "$rc"
      fi
    done < "$untracked_list"
  fi
}

# Buffer so we can measure: very large diffs won't fit a review context, and
# silently truncated review coverage is worse than a loud warning.
tmp="$(mktemp -t collect-diff-XXXXXX)"
untracked_list="$(mktemp -t collect-diff-untracked-XXXXXX)"
trap 'rm -f "$tmp" "$untracked_list"' EXIT
emit > "$tmp"
lines="$(wc -l < "$tmp")"
if (( lines > 20000 )); then
  echo "collect-diff: WARNING: diff is ${lines} lines — likely too large for one review round; consider reviewing this repo separately or splitting by area" >&2
fi
cat "$tmp"
