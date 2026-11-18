---
name: implementation-loop
description: >-
  Autonomous build loop for non-trivial (often multi-repo) changes: plan →
  single codex sanity pass on the plan (contract-heavy work only) → implement via reviewed subagents →
  convergence-managed codex review ladder over the diff → report. Optional
  low|medium|high intensity profile (default high). Invoke via
  /implementation-loop.
---

# Implementation Loop

Build a non-trivial change end-to-end: **plan it, have codex sanity-check the
plan, implement it (leaning on cheaper models but reviewing everything), have
codex tear the implementation apart until it's clean, then report.**

The task is whatever the user described (arguments and/or the preceding
conversation). If it is ambiguous about *what* to build, pick the most
reasonable interpretation, state it in the plan, and proceed.

## Autonomous mandate

**Never pause for the user.** No approval gates, no "should I proceed?", no
mid-run questions — including in the plan sanity pass. Decide everything from
the codebase, the plan, and sensible defaults. Keep a `TaskCreate` list current
(one task per phase, one subtask per implementation work-item) so the user can
follow along; they see the **final report** only.

## Roles and models

- **You** orchestrate and are the **arbiter**: every codex finding and every
  audit-subagent report is advice. Nothing is fixed or dismissed without you
  verifying it against the actual code, and every non-fix gets a written
  reason in the ledger. Silently ignoring a finding is not allowed.
- **Implementation / fix / audit subagents** run via the `Agent` tool as
  `subagent_type: "loop-worker"` (Opus 5.5 at `high` effort, from
  `~/.claude/agents/loop-worker.md`; if that type is missing, use
  `general-purpose` with `model: "opus"`). Pass `model: "haiku"` only for
  trivial mechanical edits. Honor a user-supplied `SUBAGENT_MODEL=...`
  argument as the `model` override (an `Agent` alias: `opus`, `sonnet`,
  `haiku` or `fable`).
- **The codex reviewer** uses the helper's default model (`CODEX_MODEL` to
  override; default `gpt-6.2-sol`), at **`medium` effort until clean, then
  `xhigh`** — the medium tier clears the cheap findings before the expensive
  rounds. An `xhigh` verification round has run about 200–230k codex tokens
  and 30–45 minutes.

## Intensity profiles (optional argument — default `high`)

A profile scales the review **machinery**, never the models (a cheaper
reviewer produces noisier findings that waste orchestrator judgment; cheaper
implementers buy extra review rounds).

| Profile | Phase 2 | Phase-4 ladder | Sweep | Verification cap |
|---|---|---|---|---|
| `high` (default) | as written | `medium` tier → `xhigh` tier | yes* | 5 rounds at `xhigh` |
| `medium` | as written | `medium` tier only | yes* | 2 rounds at `xhigh` |
| `low` | skip | one `medium` round + fixes | no | 1 round at `medium` |

\* Skippable only when the whole ladder produced **zero valid findings** —
then there is no class to generalize. One valid finding, even if the next
round is clean, means its analogous sites were never audited: sweep.

Judgment, ledger, finding classification and repo gates apply at every profile.

## Codex review helpers

Codex runs **on the host under its own read-only sandbox** (`codex exec -s
read-only`): it reads repos straight from disk and cannot write. Always go
through the two colocated helpers (prerequisites in the repo README):

- **`~/.claude/skills/implementation-loop/codex-review.sh <prompt-file> [effort] [repo ...]`**
  One codex pass. `effort` = `xhigh | high | medium | low | max`. **Pass every repo in
  play** (the first becomes codex's cwd, the rest are `--add-dir`ed) and
  reference repos, diffs and the plan by **absolute path** in the prompt.
  Two outputs:
  - **stderr + stdout** — the full session stream (on stderr: shell calls, an
    echo of your prompt, token counts) and the final message (stdout).
    Redirect both to a transcript file for humans (`> file 2>&1`). **Never read
    or parse it**; never `tee` it, which pulls megabytes into your context.
  - **`$CODEX_ANSWER_FILE`** — codex's **final answer only**, as JSON matching
    `findings.schema.json`: `{"findings":[{severity,location,problem,fix}...]}`.
    **An empty `findings` array is the convergence signal.** Read only this
    file to judge a round; set a per-round path so rounds don't overwrite.
  Non-zero exit (auth, network, timeout = 124) means **no review happened**:
  retry once, then stop the loop and report the error state. Never count a
  failed round as converged.
- **`~/.claude/skills/implementation-loop/collect-diff.sh <repo-path>`**
  Comprehensive, binary-safe, read-only review diff for one repo (staged
  changes vs HEAD, unstaged changes vs the index, new untracked files). Warns on stderr when too large for
  one round.

**Running a round.** Shell variables do not persist between Bash tool calls:
write `$SCRATCH`, the answer and transcript paths and every repo as **literal
absolute paths** in each command. A round takes up to `CODEX_TIMEOUT` (an
`xhigh` round has taken 30–45 minutes), longer than a foreground Bash call may
run, so start it with `run_in_background: true` and a Bash `timeout` of at
least `CODEX_TIMEOUT` + 120 s (3,720,000 ms by default), then wait for the
completion notification; its exit code is the round's. Run one round at a
time.

## Phase 0 — Setup

1. `SCRATCH="$(mktemp -d -t iloop-XXXXXX)"` — plan, diffs, prompts, ledger,
   per-round outputs all live here; reference them by absolute path.
2. Identify **every repo** the task touches (named or inferred), record
   absolute paths in `REPOS=(...)`, and give each a unique **slug** (basename,
   suffixed on collision) used in every `$SCRATCH` filename. Every later phase
   must cover all of them.
3. **Baseline per repo:** `~/.claude/skills/implementation-loop/collect-diff.sh <repo> > "$SCRATCH/baseline-<slug>.patch"`
   and record `git rev-parse HEAD` (or "no commits yet"). If a baseline's
   `git status --short` section is non-empty (the file always has headers —
   don't test emptiness) the repo was already dirty: mark those changes **out
   of scope** in every impl-review prompt and keep them out of the report.
4. Note each repo's quality gates (tests / lint / typecheck) from `CLAUDE.md` /
   `AGENTS.md` / `README` / `Makefile` / `pyproject.toml` / `package.json`.
5. Start `$SCRATCH/ledger.md` (empty, or seeded with design decisions already
   made in the conversation). Seed the task list (Phases 1–5).

## Phase 1 — Plan

Write `$SCRATCH/plan.md` after reading the real code. It states: goal and
interpretation (what "done" means); affected repos and files; ordered concrete
steps naming the functions/endpoints/migrations; data and migration changes
(backfills, reversibility); edge cases, failure modes, security and
data-integrity considerations; verification per part; cross-repo contracts and
their consumers. Write for a reviewer who can read the repos but wasn't in this
conversation.

## Phase 2 — Plan sanity pass (codex · exactly one round)

A plan-review *loop* is deliberately absent: it costs as much per round as the
impl ladder and mostly catches prose. The one class with outsized ROI is wrong
assumptions about external contracts, money sequencing, migrations, or
cross-repo interfaces — rework once code exists.

- **UI-only / no-contract work:** skip.
- **Money-path / schema / cross-repo-contract work:** one `medium` round with
  the plan-review template. Judge the findings, fix the plan or ledger them,
  **proceed — no re-review**.

## Phase 3 — Implement

Execute `plan.md` across all repos.

- **Decompose** into work-items (roughly one per step / file cluster), one
  subtask each.
- **Delegate** well-scoped items to subagents with a precise prompt (plan
  slice, exact files, constraints) and `run_in_background: false`. Keep
  architectural / cross-cutting items yourself.
- **Review every subagent diff** against the plan and the surrounding code
  before marking it done; fix or re-delegate with specific feedback. Nothing
  is done on a subagent's say-so.
- **Concurrency:** files are edited in place, so subagents on the same files
  collide. Sequential within a repo; parallel only on disjoint files/repos.
- **Gates green** per repo before Phase 4. Codex reviews correctness; it is
  not a substitute for the repo's tests.

## Phase 4 — Implementation review loop (codex · convergence-managed)

An unmanaged per-finding ladder once ran 76 rounds: it finds new bug
**classes** early, then degrades into one-more-site repeats and follow-ons to
its own fixes. So: two effort tiers, a transition rule that stops the ladder
when it stops teaching, a sweep that closes classes wholesale, and capped
verification that proves closure.

**Tier order:** `medium` until converged, then restart at `xhigh` (trimmed by
the profile table). Each round, either tier (`<tier>` is `medium` or `xhigh`;
`N` restarts at 1 in each tier):

1. **Diffs:** for every repo, `~/.claude/skills/implementation-loop/collect-diff.sh <repo> > "$SCRATCH/diff-<slug>.patch"`.
   If the user asked for commits along the way, prepend the committed span
   since the Phase-0 HEAD (`git diff <phase-0 HEAD>..HEAD`; git's empty-tree
   hash, `git hash-object -t tree /dev/null`, for a repo that had no commits;
   add `--no-color`) — `collect-diff.sh` alone would drop it. This is the only
   place diffs are built; a fix always leads back here.
2. **Prompt:** write `$SCRATCH/impl-review-prompt.md` from the template. Keep
   it stable across rounds: reference `plan.md`, the diffs and `ledger.md` by
   path, never inline them.
3. **Run** (in the background, as in *Running a round*):
   `CODEX_OUTPUT_SCHEMA=~/.claude/skills/implementation-loop/findings.schema.json CODEX_ANSWER_FILE="$SCRATCH/impl-review-<tier>-N.answer.json" ~/.claude/skills/implementation-loop/codex-review.sh "$SCRATCH/impl-review-prompt.md" <tier> <every repo path> > "$SCRATCH/impl-review-<tier>-N.md" 2>&1`
4. **Judge** from the answer file only. The round **converged** when
   `findings` is empty or every finding is already in the ledger: medium →
   start the xhigh tier; xhigh → the ladder ends (sweep unless the footnote
   applies). Otherwise, per finding, **verify against the code**: valid → fix
   (yourself or a reviewed subagent), re-run that repo's gates; invalid /
   intentional → append to `ledger.md` with a one-line reason, leave the code
   alone.
5. **Classify** each valid finding in the round log: **NEW-CLASS** (a rule
   could be written from it) / **KNOWN-SITE** (an established rule missing at
   one more site) / **FOLLOW-ON** (a defect in one of this run's own fixes).
6. **Fix the class, not the instance:** grep for and fix every analogous site
   in the same pass; pin regression tests at the **exact seam** (counted-wrapper
   injection where ordering matters).

**Phase transition.** Count consecutive **non-converged** rounds with no
NEW-CLASS finding (severity is a noisy signal — highs keep appearing in the
tail). A converged round ends its tier through step 4 instead, and the count
restarts at 0 when a tier starts. At **2**, stop the ladder even mid-tier —
this **overrides** tier progression; a skipped xhigh tier is replaced by the
sweep plus xhigh-effort verification. Backstop: force it at **25 rounds in
one tier**.

**Sweep.** Distill this run's findings into **named rules** (identity-gating,
error taxonomy, arithmetic dedup, ordering, compare-and-write, … whatever the
run taught). Fan out **parallel read-only audit subagents**, one rule each,
over the whole touched surface, demanding file:line evidence, a concrete
failure scenario, CONFIRMED/PLAUSIBLE confidence, and an explicit
**"checked clean"** list. Auditors can present unverified or fabricated
corroboration: verify every citation yourself, fix the survivors in one pass
(gates green), ledger the declined ones as **accepted residuals**.

**Capped verification.** Up to the profile's cap of rounds, at its
verification effort. Each one is a ladder round: rebuild the diffs (step 1 —
the sweep changed code), reuse the prompt (it references the ledger, now with
the accepted residuals, by path), and name the files `verify-N.answer.json`
and `verify-N.md`. The first converged round ends Phase 4. Otherwise judge,
fix and classify as in steps 4–6, and the cap ticks down. If the cap runs out
with findings still arriving, fix the valid ones from the last round, re-run
the gates, and report those findings verbatim as fixed but not re-verified.

If the ladder keeps surfacing the same area, the **plan** may be wrong — fix
upstream rather than patching symptoms.

## Phase 5 — Report

One final report: **what was built** per repo (key files/commits); **plan
sanity pass** (ran? notable findings, plan changes, ledgered items);
**review loop** (rounds per tier, finding-class breakdown, when the transition
fired, sweep results per rule — fixed vs accepted residual — and how it ended:
empty findings, all-ledger fixed point, or forced transition); the **ledger**
verbatim (a decision record); **gate results** per repo; **follow-ups /
risks**. Leave changes **uncommitted** unless asked. Point at `$SCRATCH` for
transcripts.

## Codex prompt templates

Both must end with the same output contract (the helper enforces the schema;
the sentence keeps the reviewer honest about what "empty" means):

> OUTPUT: JSON matching the provided schema. `findings` is a list of
> `{severity: blocker|major|minor, location: file:line (or plan section),
> problem, fix}`. Report an EMPTY `findings` list if and only if you found zero
> issues.

### Plan-review template (`$SCRATCH/plan-review-prompt.md`)

```
You are a rigorous staff engineer reviewing an implementation PLAN (not code yet).

GOAL / TASK:
<one-paragraph statement of what is being built>

REPOS INVOLVED (read them from disk to sanity-check feasibility):
- /absolute/path/to/repo-a
- /absolute/path/to/repo-b

THE PLAN under review: <absolute $SCRATCH path>/plan.md

Find everything that would make this plan fail, ship incomplete, or cause a
correctness/security/data-integrity problem: wrong or missing files & APIs,
invalid assumptions about how the current code works, missing steps, bad
ordering or dependency mistakes, unhandled edge cases and failure modes,
migration/backfill gaps, cross-repo contract mismatches. Verify claims against
the actual code on disk. Report EVERY real problem you find, not only the most
important: each round costs the same whether it reports one finding or ten.
Skip nitpicks.
The sandbox is read-only and nothing is built yet: do not run builds or test
suites; read the code.

PREVIOUSLY REVIEWED — intentionally NOT changed, do NOT re-raise anything in:
<absolute $SCRATCH path>/ledger.md   (or: "none yet")

OUTPUT: <the output contract above>
```

### Impl-review template (`$SCRATCH/impl-review-prompt.md`)

```
You are a rigorous staff engineer reviewing a code DIFF that implements a plan.

GOAL / TASK:
<one-paragraph statement of what was built>

THE PLAN it should satisfy: <absolute $SCRATCH path>/plan.md

REPOS INVOLVED (full source on disk, for context):
- /absolute/path/to/repo-a
- /absolute/path/to/repo-b

THE DIFF under review (full working-tree change per repo):
- <absolute $SCRATCH path>/diff-<slug-a>.patch
- <absolute $SCRATCH path>/diff-<slug-b>.patch

<if any Phase-0 baseline showed changes:>
OUT OF SCOPE — already modified before this task started (see
<absolute $SCRATCH path>/baseline-<slug>.patch); review only changes beyond them:
<one-line summary>

Review for: correctness bugs, deviations from the plan, missing pieces, broken
or missing error handling, security holes, data-integrity/migration problems,
edge cases, regressions, and anything that would fail the repo's own tests.
Point to exact file:line. Prefer real defects over style nits.
Report EVERY defect you find, not only the most important: each round costs
the same whether it reports one finding or ten.
The sandbox is read-only and the repo's tests/lint/typecheck already passed
before this round: do not run builds or test suites (they fail on writes
here); read the code.

PREVIOUSLY REVIEWED — intentionally NOT changed, and ACCEPTED RESIDUALS — do
NOT re-raise anything in: <absolute $SCRATCH path>/ledger.md   (or: "none yet")

OUTPUT: <the output contract above>
```
