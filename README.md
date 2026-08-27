# skills

Two [Claude Code](https://claude.com/claude-code) skills that pair Claude (as
orchestrator, implementer, and judge) with OpenAI's `codex` CLI (as an
adversarial reviewer), plus the helper scripts they share.

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
- **The orchestrator reads answers, not transcripts.** A codex round's session
  stream is easily 2 MB (every shell call echoed) while its verdict is 3 KB.
  The helper writes the final answer to its own file as schema-checked JSON
  (`{"findings": [...]}`, empty = clean), so convergence is a mechanical check
  and no round costs the orchestrator a megabyte of context.

## Prerequisites

- **Claude Code** (the skills are markdown instructions for it).
- **Codex CLI**, installed and logged in: `npm install -g @openai/codex`,
  then `codex login`. Check with `codex exec -s read-only "say ok"`.
- **GNU coreutils `timeout`** — present on Linux; on macOS
  `brew install coreutils` (the script finds `gtimeout` on its own).

No Docker, no image builds, no daemons.

## Install

```bash
git clone https://github.com/ignaval/skills.git
cd skills
mkdir -p ~/.claude/skills && cp -r implementation-loop review-loop ~/.claude/skills/
```

Install **both** directories: `review-loop` reuses `implementation-loop`'s
scripts and schema rather than shipping copies. The SKILL.md files reference
them at `~/.claude/skills/implementation-loop/`; if you install elsewhere,
update those paths.

Sanity-check the helper once (the answer lands next to the prompt):

```bash
echo "Read README.md in the current directory. Report zero findings." > /tmp/hello.md
~/.claude/skills/implementation-loop/codex-review.sh /tmp/hello.md low "$PWD" > /tmp/hello.log
cat /tmp/hello.md.answer.json     # -> {"findings":[]}
```

## How to use

Open a Claude Code session in the repo you are working on and type one of
the slash commands. Arguments are free-form prose — the model reads them, so
plain English works alongside the named knobs.

**Build something new** — plan, codex-check the plan, implement, review
until clean, report:

```text
/implementation-loop add rate limiting to the webhook endpoints, config-driven
/implementation-loop medium add a CSV export to the reports page
/implementation-loop the API lives in ../api and the client in ../webapp; add a "pause savings" flow end to end
```

**Harden work you already did** in the current session (uncommitted or
committed during the conversation):

```text
/review-loop
/review-loop low
```

**Knobs** (all optional):

| Knob | Where | Effect |
|---|---|---|
| `low` / `medium` / `high` | first word of the arguments | Intensity profile, default `high` — see below |
| `SUBAGENT_MODEL=<model>` | in the arguments | Model for implementation / fix / audit subagents (default `opus`) |
| `CODEX_MODEL=<id>` | shell env before starting Claude Code | Reviewer model (default `gpt-5.6-sol`) |
| `CODEX_TIMEOUT=<seconds>` | shell env | Per-round cap (default 3600) |
| `CODEX_EXTRA_ARGS="..."` | shell env | Extra `codex exec` flags, e.g. `--ephemeral` |

**What happens.** Both skills run fully autonomously — no approval gates, no
questions — and narrate progress through the task list. Each codex round
reads your repos from disk under codex's read-only sandbox and returns a JSON
findings list; the orchestrating model verifies every finding against the
code before fixing it or writing a dismissal reason into a ledger that is fed
back into the next round. The run ends with one report: what changed per
repo, rounds per tier, every finding fixed, every finding dismissed with its
reason, and test/lint results. Changes are left **uncommitted** unless you
asked for commits (`review-loop` matches whatever commit style the session
already used). Per-round transcripts, answers, diffs, prompts and the ledger
land in a scratch directory (`/tmp/iloop-*` or `/tmp/rloop-*`) the report
points at.

### Intensity profiles

| Profile | Review ladder | Discipline sweep | Verification rounds | When |
|---|---|---|---|---|
| `high` (default) | medium-effort rounds until clean, then high-effort | yes | up to 5 at high | money paths, migrations, cross-repo contracts |
| `medium` | medium-effort rounds only | yes | up to 2 at high | ordinary features |
| `low` | one medium-effort round + fixes | no | 1 at medium | small changes, quick sanity pass |

A profile scales the **ceremony**, never the models. That is deliberate: a
cheaper reviewer produces noisier findings that waste orchestrator judgment,
and cheaper implementers buy extra review rounds, so swapping models is a
false economy. Models change only through `CODEX_MODEL` and `SUBAGENT_MODEL`.
`implementation-loop low` also skips the plan sanity pass.

### Using the helpers directly

You do not need Claude Code to use the reviewer:

```bash
# 1. Build a review diff for a repo (tracked changes vs HEAD + new files)
~/.claude/skills/implementation-loop/collect-diff.sh ~/code/api > /tmp/diff-api.patch

# 2. Write a prompt that points at it by absolute path
cat > /tmp/review.md <<'PROMPT'
You are a rigorous staff engineer reviewing a code DIFF: /tmp/diff-api.patch
Full source: /home/me/code/api
Review for correctness bugs, security holes, data-integrity problems, races.
OUTPUT: JSON matching the provided schema; an EMPTY findings list only if you found nothing.
PROMPT

# 3. One read-only review pass; the verdict lands in the answer file
CODEX_ANSWER_FILE=/tmp/review-1.answer.json \
  ~/.claude/skills/implementation-loop/codex-review.sh /tmp/review.md medium ~/code/api > /tmp/review-1.log
jq . /tmp/review-1.answer.json
```

- **`codex-review.sh <prompt-file> [effort] [repo ...]`** — one review pass
  under `codex exec -s read-only`. The first repo is codex's working
  directory (`-C`), the rest are granted with `--add-dir`. The session
  stream goes to stdout (keep it for humans, never parse it); the **final
  answer** goes to `$CODEX_ANSWER_FILE` (default `<prompt-file>.answer.json`)
  as JSON validated against `implementation-loop/findings.schema.json`
  (`{"findings":[{severity, location, problem, fix}]}`). `CODEX_OUTPUT_SCHEMA`
  swaps the schema or, as `none`, gives free text — for direct use only; the
  skills pin the bundled schema. The sandbox mode is hardcoded to read-only,
  and `CODEX_EXTRA_ARGS` cannot change it, the answer path, or the
  directories in scope.
- **`collect-diff.sh <repo-path>`** — comprehensive, binary-safe, read-only
  review diff for one repo, with a loud warning when it is too large for one
  round.

## Security note

Read-only protects your files from writes; the reviewer can still **read**
broadly on your machine while reviewing. Only review repos whose content you
trust not to prompt-inject the reviewer. `CODEX_EXTRA_ARGS="--ephemeral"`
keeps session history out of `~/.codex` on codex versions that support it.

On hardened kernels that restrict unprivileged user namespaces (e.g. Ubuntu
24.04 with `kernel.apparmor_restrict_unprivileged_userns=1`), codex's
*bundled* bubblewrap fails with errors like `bwrap: loopback: Failed
RTM_NEWADDR` — install the system package (`sudo apt install bubblewrap`),
which ships the AppArmor profile that unblocks it.

## License

[MIT](LICENSE)
