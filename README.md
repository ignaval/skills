# claude-skills

Two [Claude Code](https://claude.com/claude-code) skills that pair Claude (as
orchestrator, implementer, and judge) with OpenAI's `codex` CLI (as an
adversarial reviewer), plus the sandboxed helper scripts they share.

| Skill | What it does |
|---|---|
| [`implementation-loop`](implementation-loop/SKILL.md) | Builds a non-trivial change end-to-end: plan → codex sanity pass on the plan → implement via reviewed subagents → convergence-managed codex review ladder over the diff → final report. Fully autonomous, multi-repo aware. |
| [`review-loop`](review-loop/SKILL.md) | Just the review machinery: takes the changes already made in the current session and hardens them through the same convergence-managed codex ladder, fixing valid findings and ledgering dismissals. |

Both skills came out of long real-world campaigns. The design lessons baked in:

- **Convergence management.** An unmanaged per-finding review loop once ran 76
  rounds. Per-finding rounds surface new bug *classes* early, then degrade into
  one-more-site repeats. So the ladder stops as soon as two consecutive rounds
  teach no new class, a parallel "discipline sweep" closes every known class
  wholesale, and capped verification rounds prove closure.
- **A dismissed/residual ledger.** An adversarial reviewer can re-derive
  residual race windows forever; feeding every dismissal (with a written
  reason) back into every prompt is what makes "clean" reachable at all.
- **Two effort tiers.** Medium-effort rounds until clean, then high-effort —
  the cheap tier clears the cheap findings before the expensive rounds start.
- **The orchestrator is the arbiter.** Codex findings and audit-subagent
  reports are advice; nothing is fixed or dismissed without the orchestrating
  model verifying it against the actual code.

## Intensity profiles

Both skills accept an optional `low | medium | high` profile argument
(default `high` — exactly the behavior described above). A profile scales the
**ceremony** — which effort tiers run, whether the discipline sweep runs, the
verification cap — never the models. That split is deliberate: a cheaper
reviewer model produces noisier findings that waste orchestrator judgment, and
cheaper implementation models buy extra review rounds, so swapping models is a
false economy. Models are overridden explicitly instead: `CODEX_MODEL` for the
reviewer, a `SUBAGENT_MODEL` argument for implementation/fix subagents. `low`
is the "quick pass": one medium-effort review round plus fixes and a single
verification round.

## Prerequisites

- **Claude Code** (the skills are markdown instructions for it).
- **Docker.** Codex runs inside a container: the container *is* the sandbox —
  every repo is mounted read-only, so the reviewer can never mutate your
  checkouts, and codex's own sandbox (which some kernels can't run) is disabled
  inside. Build the image once:

  ```bash
  docker build -t codex-review:latest docker/
  ```

  For reproducible builds, pin the codex CLI version:
  `docker build --build-arg CODEX_VERSION=<x.y.z> -t codex-review:latest docker/`.

- **Codex CLI + auth.** Install the CLI on the host
  (`npm install -g @openai/codex`) and log in once. The scripts mount
  `$HOME/.codex` (override: `CODEX_HOME`) into the container, so the
  credentials must be **file-backed** (`auth.json` in that directory) — an
  OS-keyring login is not visible inside the container.

### Security note

The read-only mounts protect your **checkouts**, not your codex credentials:
the container has network access and mounts `$CODEX_HOME` writable (codex
needs it for auth/session state). Only review repos whose content you trust
not to prompt-inject the reviewer. `CODEX_EXTRA_ARGS="--ephemeral"` keeps
session history out of the mounted directory on codex versions that support
it.

## Install

Copy (or symlink) the two skill directories into your Claude Code skills dir:

```bash
mkdir -p ~/.claude/skills && cp -r implementation-loop review-loop ~/.claude/skills/
```

> The SKILL.md files reference the helper scripts at
> `~/.claude/skills/implementation-loop/` — if you install somewhere else,
> update those paths.

## Usage

Invoke from any Claude Code session. Arguments are free-form prose — the model
reads them, so plain English works alongside the named knobs:

```text
# Build a change end-to-end, full ceremony (default profile: high)
/implementation-loop add rate limiting to the webhook endpoints, config-driven

# Same, mid-cost: medium-effort ladder only, 2 verification rounds
/implementation-loop medium add a CSV export to the reports page

# Harden work you already did in this session (uncommitted or committed)
/review-loop

# Quick pass over the session's changes: one review round + fixes
/review-loop low

# Override the implementation/fix subagent model for this run
/implementation-loop SUBAGENT_MODEL=haiku rename the config keys across both repos
```

The reviewer model is set per-shell instead (`CODEX_MODEL=<id>`), since the
helper script reads it directly.

**What a run looks like:** both skills run fully autonomously — no approval
gates — and narrate progress as they go. They end with a single report: what
changed per repo, rounds per tier, every finding fixed, and every finding
dismissed with its reason. Changes are left **uncommitted** unless you asked
for commits (`review-loop` matches whatever commit style the session already
used). Full per-round codex transcripts land in a scratch directory the report
points at.

## Helper scripts

- **`implementation-loop/codex-review.sh <prompt-file> [effort] [repo ...]`** —
  one codex review pass in the sandbox. Each repo mounts read-only at
  `/work/projects/<basename>`; the prompt file's directory mounts at
  `/work/input`. Paths must be free of spaces and shell metacharacters — the
  script validates and fails loudly (deliberate: values are interpolated into
  one docker command string). Env knobs: `CODEX_MODEL`, `CODEX_HOME`,
  `CODEX_TIMEOUT`, `CODEX_PROJECTS_ROOT`, `CODEX_EXTRA_ARGS`,
  `CODEX_DOCKER_CMD` (how to execute the docker invocation; auto-detected —
  plain docker, with an `sg docker -c` fallback when the docker group is not
  active in the calling shell).
- **`implementation-loop/collect-diff.sh <repo-path>`** — a comprehensive,
  binary-safe, read-only review diff for one repo: tracked changes vs HEAD plus
  full contents of new untracked files, with a loud warning when the diff is
  too large for one review round.

`review-loop` deliberately reuses `implementation-loop`'s scripts rather than
shipping copies — install both directories.

## License

[MIT](LICENSE)
