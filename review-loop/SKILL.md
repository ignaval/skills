---
name: review-loop
description: >-
  Autonomous convergence-managed codex review loop over the changes made in
  the current conversation (uncommitted or committed this session) — the
  implementation-loop's review machinery alone: per-repo session diff → codex
  ladder → fixes → discipline sweep → capped verification → report. Optional
  low|medium|high intensity profile (default high). Invoke via /review-loop.
---

# Review Loop

Take **the changes produced in this conversation** — staged, unstaged and/or
committed this session — and harden them through the same convergence-managed
codex ladder as `implementation-loop` Phase 4. No planning, no implementation:
the work exists; make it survive an adversarial reviewer, fixing what's real.

Runs **fully autonomously**: no approval gates, no mid-run questions. Narrate
progress, keep a `TaskCreate` list current (one task per phase), never block
on input. The user sees the final report.

## Roles and models

- **You** orchestrate and are the **arbiter**: codex findings and audit reports
  are advice; every one is verified against the code before it is fixed, and
  every non-fix gets a written reason in the ledger. Nothing is silently
  ignored.
- **Fix / audit subagents** run via the `Agent` tool as
  `subagent_type: "loop-worker"` (Opus 5.5 at `high` effort, from
  `~/.claude/agents/loop-worker.md`; if that type is missing, use
  `general-purpose` with `model: "opus"`); honor a user-supplied
  `SUBAGENT_MODEL=...` as the `model` override (an `Agent` alias: `opus`,
  `sonnet`, `haiku` or `fable`).
- **The codex reviewer** uses the helper's default model (`CODEX_MODEL`;
  default `gpt-6.2-sol`), at **`medium` effort until clean, then `xhigh`**.

## Intensity profiles (optional argument — default `high`)

Profiles scale the **machinery**, never the models (a cheaper reviewer makes
noisier findings that waste orchestrator judgment).

| Profile | Phase-1 ladder | Phase 2 (sweep) | Phase 3 (verification) |
|---|---|---|---|
| `high` (default) | `medium` tier → `xhigh` tier | yes* | up to 5 rounds at `xhigh` |
| `medium` | `medium` tier only | yes* | up to 2 rounds at `xhigh` |
| `low` | one `medium` round + fixes | skip | 1 round at `medium` |

\* Skippable only when the whole ladder produced **zero valid findings**;
one valid finding means its analogous sites were never audited: sweep.

## Shared machinery (from implementation-loop — do not duplicate)

- **`~/.claude/skills/implementation-loop/codex-review.sh <prompt-file> [effort] [repo ...]`**
  One codex pass on the host under codex's read-only sandbox. Pass every repo
  (first = cwd, rest `--add-dir`ed); reference repos, diffs and the ledger by
  **absolute path** in the prompt. **stderr** carries the full session stream
  (stdout the final message) — redirect both (`> file 2>&1`) to a transcript
  file for humans; never read, parse or `tee` it
  (that pulls megabytes into your context). **`$CODEX_ANSWER_FILE`** holds codex's
  final answer only, as JSON `{"findings":[{severity,location,problem,fix}...]}`
  — **an empty list is the convergence signal**; judge every round from this
  file alone and give each round its own path. Non-zero exit (auth, network,
  timeout = 124) is a failed round, not a finding: retry once, then stop and
  report.
- **`~/.claude/skills/implementation-loop/collect-diff.sh <repo-path>`** — the
  working-tree diff (staged vs HEAD, unstaged vs the index, untracked), binary-safe, read-only.
- **Running a round:** shell variables do not persist between Bash tool
  calls, so write `$SCRATCH`, the answer and transcript paths and every repo
  as **literal absolute paths** in each command. A round can take up to
  `CODEX_TIMEOUT` (an `xhigh` round has taken 30–45 minutes), longer than a
  foreground Bash call may run: start it with `run_in_background: true` and a
  Bash `timeout` of at least `CODEX_TIMEOUT` + 120 s (3,720,000 ms by
  default), then wait for the completion notification; its exit code is the
  round's. One round at a time.

## Phase 0 — Scope: what THIS conversation changed

1. `SCRATCH="$(mktemp -d -t rloop-XXXXXX)"`.
2. List **every repo touched in this conversation** (you were there — use the
   conversation, not guesswork) as absolute paths in `REPOS=(...)`, each with a
   unique **slug** (basename, suffixed on collision).
3. Per repo, determine `BASE` = HEAD **before this conversation's first
   commit** (conversation knowledge is the authority; the `Co-Authored-By:
   Claude` trailer corroborates). If nothing was committed, `BASE` = HEAD. If
   the repo had no commits before the session's first one, `BASE` is git's
   empty tree (`git hash-object -t tree /dev/null`); if HEAD is still unborn,
   there is no committed span and the `git diff BASE..HEAD` part of Phase 1
   is skipped. A repo with neither committed nor uncommitted session changes
   is dropped from `REPOS`.
4. **Out-of-scope guard:** dirty state that predates this conversation is out
   of scope — say so in every prompt and keep it out of the report. If
   pre-session and session edits overlap in the **same hunks**, review the
   combined hunk and flag the limitation in the prompt and the report.
5. Run each repo's relevant quality gates (`CLAUDE.md` / `Makefile` /
   `pyproject.toml` / `package.json`) once so the loop starts from green.
6. Write a one-paragraph **GOAL** statement of what the session's changes are
   for; start `$SCRATCH/ledger.md`, seeded with any deliberate design
   decisions already made in the session.

## Phase 1 — Per-finding ladder (medium tier, then xhigh tier)

Each round (`medium` until converged, then restart at `xhigh`, trimmed by the
profile; `<tier>` is `medium` or `xhigh`, and `N` restarts at 1 in each tier):

1. **Diffs:** per repo, `git diff --no-color BASE..HEAD` followed by `~/.claude/skills/implementation-loop/collect-diff.sh <repo>`,
   concatenated into `$SCRATCH/diff-<slug>.patch`. Always both — fixes change
   the diff, and fixes committed per round would otherwise vanish. This is the
   only place diffs are built; a fix always leads back here.
2. **Prompt:** `$SCRATCH/review-prompt.md` from the template — stable across
   rounds, everything by path.
3. **Run** (in the background, as in *Running a round*):
   `CODEX_OUTPUT_SCHEMA=~/.claude/skills/implementation-loop/findings.schema.json CODEX_ANSWER_FILE="$SCRATCH/round-<tier>-N.answer.json" ~/.claude/skills/implementation-loop/codex-review.sh "$SCRATCH/review-prompt.md" <tier> <every repo path> > "$SCRATCH/round-<tier>-N.md" 2>&1`
4. **Judge** from the answer file only. The round **converged** when
   `findings` is empty or every finding is already in the ledger: medium →
   start the xhigh tier; xhigh → the ladder ends. Otherwise verify each finding against the code:
   valid → fix (yourself or a reviewed subagent), re-run that repo's gates;
   invalid / intentional → ledger with a one-line reason.
5. **Classify** each valid finding: **NEW-CLASS** / **KNOWN-SITE** /
   **FOLLOW-ON** (a defect in one of this loop's own fixes).
6. **Fix the class, not the instance:** fix every analogous site in the same
   pass; pin regression tests at the exact seam.
7. **Commit discipline:** match the session — if its work was committed as it
   went, commit each round's fixes the same way (same style, trailer);
   otherwise leave fixes uncommitted.

**Phase transition:** count consecutive **non-converged** rounds with no
NEW-CLASS finding; a converged round ends its tier through step 4 instead,
and the count restarts at 0 when a tier starts. At **2**, stop the ladder
even mid-tier (this **overrides** tier progression — a skipped xhigh tier is
replaced by the sweep plus Phase 3 at the profile's effort). Backstop: force
it at **25 rounds in one tier**.

## Phase 2 — Discipline sweep

The ladder is a discovery tool, not a completion tool. Distill this loop's
findings into **named rules**; fan out **parallel read-only audit subagents**,
one rule each, over the whole touched surface, demanding file:line evidence, a
concrete failure scenario, CONFIRMED/PLAUSIBLE confidence and an explicit
**"checked clean"** list. Verify every citation yourself (auditors can present
fabricated corroboration), fix survivors in one pass (gates green), ledger the
declined ones as **accepted residuals**.

## Phase 3 — Capped verification

Up to the profile's cap of rounds, at its verification effort. Each one is a
Phase-1 round: rebuild the diffs (step 1 — the sweep changed code), reuse the
prompt (it references the ledger, now with the accepted residuals, by path),
and name the files `verify-N.answer.json` and `verify-N.md`. The first
converged round ends the loop. Otherwise judge, fix and classify as in
steps 4–7, and the cap ticks down. If the cap runs out with findings still
arriving, fix the valid ones from the last round, re-run the gates, and
report those findings verbatim as fixed but not re-verified.

If the ladder keeps surfacing the same area, the underlying design may be
wrong — fix upstream rather than patching symptoms.

## Phase 4 — Report

What was reviewed (per repo), rounds per tier with the finding-class
breakdown, when the transition fired, sweep results per rule (fixed vs
accepted residual), verification outcome, the full ledger, gate results, open
items, and `$SCRATCH` for transcripts.

## Review prompt template (`$SCRATCH/review-prompt.md`)

```
You are a rigorous staff engineer reviewing a code DIFF.

GOAL / CONTEXT — what these changes are for:
<the Phase-0 GOAL paragraph>

THE DIFF under review (this session's changes only):
- <absolute $SCRATCH path>/diff-<slug-a>.patch
- <absolute $SCRATCH path>/diff-<slug-b>.patch
Full source for context is on disk:
- /absolute/path/to/repo-a
- /absolute/path/to/repo-b

<if pre-existing dirty state exists:>
OUT OF SCOPE — modified before this session; review only changes beyond them:
<one-line summary>

Review for: correctness bugs, missing pieces, broken error handling, security
holes, data-integrity problems, race conditions, edge cases, regressions, and
anything that would fail the repo's own tests. Point to exact file:line.
Prefer real defects over style nits.
The sandbox is read-only and the repo's tests/lint/typecheck already passed
before this round: do not run builds or test suites (they fail on writes
here); read the code.

PREVIOUSLY REVIEWED — intentionally NOT changed, and ACCEPTED RESIDUALS — do
NOT re-raise anything in: <absolute $SCRATCH path>/ledger.md   (or: "none yet")

OUTPUT: JSON matching the provided schema. `findings` is a list of
{severity: blocker|major|minor, location: file:line, problem, fix}. Report an
EMPTY `findings` list if and only if you found zero issues.
```
