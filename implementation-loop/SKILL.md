---
name: implementation-loop
description: >-
  Autonomous plan → codex-review → implement → codex-review → report loop for
  non-trivial changes, especially ones spanning multiple repos. Drafts a plan,
  runs a single codex sanity pass over it (contract-heavy work only),
  implements it by delegating to cheaper-model subagents while reviewing their
  work, then hardens the implementation through a CONVERGENCE-MANAGED codex
  ladder (medium effort until clean, then high; per-finding rounds only while
  they surface NEW bug classes, then a parallel discipline sweep + capped
  verification), and reports what changed plus every finding fixed across both
  loops. Use when the user wants a change built with codex review gates on both
  the plan and the code, run end-to-end with no check-ins. Invoke via
  /implementation-loop.
---

# Implementation Loop

Build a non-trivial change end-to-end: **plan it, have codex sanity-check the
plan, implement it (leaning on cheaper models but reviewing everything), have
codex tear the implementation apart until it's clean, then report.** Runs
**fully autonomously** — see the mandate below.

The task to build is whatever the user described (this skill's arguments and/or
the preceding conversation). If the task is truly ambiguous about *what* to
build, make the most reasonable interpretation, state it in the plan, and
proceed — do not stop to ask.

## Autonomous mandate

**Do not pause for the user between or within phases.** No approval gates, no
"should I proceed?", no mid-run questions. Make every decision yourself using the
codebase, the plan, and sensible defaults. The user sees the **final report**
only. Narrate progress and keep the task list current, but never block on input.
Even the plan sanity pass (Phase 2) *proceeds* on your own judgment — it never
asks.

Keep a `TaskCreate` list current for visibility: one task per phase, plus a
subtask per implementation work-item. This is a long run; the list is how the
user follows along.

---

## Codex review helpers (read once)

Codex reviews run **inside a Docker sandbox**: the container IS the sandbox —
every repo is mounted **read-only**, and codex's own sandbox is disabled inside
it. Two colocated helpers wrap it — always go through them (see this repo's
README for the image build and prerequisites):

- **`~/.claude/skills/implementation-loop/codex-review.sh <prompt-file> [effort] [repo ...]`**
  Runs one codex pass. `effort` = `high | medium | low` (default `high`).
  **Pass every repo in play** — each is mounted **read-only** at
  `/work/projects/<basename>`, and this works for repos **anywhere on disk**, not
  just under one root (paths must be free of spaces and shell metacharacters —
  the script validates and fails loudly). The prompt file's directory is mounted at `/work/input`.
  Codex's answer streams to stdout; **you decide convergence by reading codex's
  final answer for the sentinel `NO ISSUES FOUND`** (see *Parsing & judgment
  notes* — the raw transcript also echoes the prompt and appends token counts, so
  never grep it naively). Repo **basenames must be unique** per call (collisions
  are rejected loudly). Each call is bounded by `CODEX_TIMEOUT` (default 3600s,
  exit 124 on hit). (If you pass no repos, it falls back to mounting
  `$HOME/projects` — override via `CODEX_PROJECTS_ROOT` — but the skill always
  passes repos explicitly.)
- **`~/.claude/skills/implementation-loop/collect-diff.sh <repo-path>`**
  Prints a comprehensive, binary-safe review diff for one repo (tracked changes
  vs HEAD + new untracked files). Never mutates the repo. Works on any repo path.

Assumes: the `codex-review:latest` image is built (Dockerfile in this repo),
docker is runnable (wrap it via `CODEX_DOCKER_CMD` if your setup needs e.g.
`sg docker -c`), and codex auth lives in `$HOME/.codex`. Project location is
**not** assumed — repos are mounted per basename.

Each high-effort round costs roughly 200–450k codex tokens; medium is markedly
cheaper. **Model split (defaults, validated on a long production campaign):**
the main session orchestrates and judges everything; implementation subagents
run on a cheaper strong model via the `Agent` tool (e.g. `model: "opus"`); the
codex reviewer is the script's default model (override via `CODEX_MODEL`), run
**`medium`-effort until clean, then `high`** — the medium ladder clears the
cheap findings before the expensive rounds start.

---

## Phase 0 — Setup

1. Create a scratch dir and remember it:
   `SCRATCH="$(mktemp -d -t iloop-XXXXXX)"` — everything (plan, diffs, prompts,
   per-round codex outputs) lives here. It's mounted into codex at `/work/input`.
2. Identify **every repo** the task touches (the user may name several; infer the
   rest). Record their absolute paths — **anywhere on disk** — in a shell array,
   e.g. `REPOS=(/path/to/repo-a /path/to/repo-b)`. Pass `"${REPOS[@]}"` to
   every `codex-review.sh` call (each mounts read-only at `/work/projects/<basename>`)
   and run `collect-diff.sh` once per repo. Every later phase — implement, diff,
   review, report — must cover **all** of them.
3. **Capture a baseline per repo** so pre-existing work is never confused with
   this run's work: `collect-diff.sh <repo> > "$SCRATCH/baseline-<repo>.patch"`
   and record each repo's `git rev-parse HEAD` (or note "no commits yet" for a
   repo with an unborn HEAD). If a baseline shows changes — its `git status
   --short` section is non-empty (the file always contains headers, so don't
   test for emptiness) — the repo was already dirty: tell codex in every
   impl-review prompt that those pre-existing changes are **out of scope**, and
   keep them out of the final report's "what was built".
4. Note each repo's own quality gates (tests / lint / typecheck) from its
   `CLAUDE.md` / `AGENTS.md` / `README` / `Makefile` / `pyproject.toml` /
   `package.json`. You'll run these in Phase 3.
5. Seed the task list (Phases 1–5).

---

## Phase 1 — Plan

Produce a concrete implementation plan and write it to `$SCRATCH/plan.md`.
Investigate the actual code first — read the real files, don't plan against
assumptions. A good plan states:

- **Goal & interpretation** — what "done" means, in one short paragraph.
- **Affected repos** and, per repo, the specific files/modules to change.
- **Ordered steps**, each concrete enough to hand to another engineer, with the
  key functions/endpoints/migrations named.
- **Data & migrations** — schema changes, backfills, reversibility.
- **Edge cases, failure modes, security/data-integrity considerations.**
- **Verification** — how each part will be tested/exercised.
- **Cross-repo contracts** — API/interface changes and who consumes them.

Write for a reviewer who can read the repos but wasn't in this conversation.

---

## Phase 2 — Plan sanity pass (codex · single round, not a loop)

A plan-review LOOP is deliberately absent: in practice its per-round cost
matches the impl ladder's while catching mostly prose-level issues — the impl
ladder catches the rest at the same price. What remains is the one class with
outsized ROI: wrong assumptions about an external contract, money sequencing,
migrations, or a cross-repo interface, which cost real rework once code exists.

- **UI-only / no-contract work:** skip Phase 2 entirely.
- **Money-path / schema / cross-repo-contract work:** run **exactly one**
  `medium` codex round over the plan (plan-review template below). Judge the
  findings, fix the plan or ledger them, and **proceed — no re-review**. The
  impl ladder is the safety net for anything a single pass misses.

## Phase 3 — Implement (cheaper models, always reviewed)

Execute `plan.md` across all repos. **Delegate to cheaper models where the work is
well-scoped; review their output yourself before accepting it.**

- **Decompose** the plan into work-items (roughly one per ordered step / file
  cluster). Add each as a subtask.
- **Delegate** each well-scoped item to a subagent via the `Agent` tool with
  a strong implementation model (e.g. `model: "opus"`; `"haiku"` only for
  trivial mechanical edits), a precise prompt
  (the relevant plan slice, exact files, and constraints), and
  **`run_in_background: false`** so you get the result before continuing. Keep
  genuinely architectural / cross-cutting items for yourself.
- **Review every subagent's work** before marking the subtask done: read the diff,
  check it against the plan and for correctness, style-match the surrounding code.
  If it's wrong or incomplete, fix it yourself or re-delegate with specific
  feedback. **Nothing is "done" on a subagent's say-so.**
- **Concurrency:** this session edits files in place (no worktree isolation), so
  concurrent subagents on the **same files collide**. Default to **sequential**
  within a repo; only parallelize items on **disjoint files / disjoint repos**.
- **Run each repo's own gates** (tests / lint / typecheck from Phase 0) and get
  them green before Phase 4. Codex is a reviewer, not a substitute for the repo's
  tests. Fix what they surface.

---

## Phase 4 — Implementation review loop (codex · convergence-managed)

Harden the actual diff against codex. **Two effort tiers, and a phase-transition
rule that stops the per-finding ladder as soon as it stops teaching** (learned
the hard way on a long campaign where an unmanaged ladder ran 76 rounds:
per-finding loops find new bug CLASSES early, then degrade into one-more-site
repeats and follow-ons to your own fixes).

**Tier order:** run the loop at `medium` effort until it converges, then restart
it at `high`. Both tiers follow the same round structure and the same
phase-transition rule below. Loop:

1. Regenerate diffs for **every** touched repo (one file per repo). In the
   default flow work stays uncommitted, so
   `collect-diff.sh <repo> > "$SCRATCH/diff-<repo>.patch"` captures it all.
   If the user asked for commits along the way, that alone would drop the
   committed work: build the patch as the committed span since the Phase-0
   baseline (`git diff <phase-0 HEAD>..HEAD`; use git's empty-tree hash as the
   base for a repo that had no commits) concatenated with the
   `collect-diff.sh` output.
2. Write `$SCRATCH/impl-review-prompt.md` using the **Impl-review template** below
   (reference each `/work/input/diff-<repo>.patch`, include the dismissed ledger).
3. Run: `set -o pipefail; codex-review.sh "$SCRATCH/impl-review-prompt.md" <medium|high> "${REPOS[@]}" 2>&1 | tee "$SCRATCH/impl-review-round-N.md"`
   (the effort argument is the current tier's; without `pipefail`, `tee` would
   mask a codex hard failure as exit 0).
4. Parse:
   - Final line **`NO ISSUES FOUND`** → **converged**, exit loop (or move
     medium→high if this was the medium tier). If the high tier converges clean
     this way — without the transition rule below ever firing — the sweep is
     **optional**: run it only when the run's findings suggest unswept siblings;
     a run that ends with codex finding nothing needs no sweep.
   - Findings → judge each: valid → **fix the code** (yourself or via a reviewed
     subagent), re-run the affected repo's gates; invalid/intentional → add
     to the dismissed/residual ledger, **don't change the code**.
   - Regenerate diffs and re-review.
5. **Classify every valid finding** as you fix it (one word in the round log):
   - **NEW-CLASS** — a kind of bug not seen before in this run (a new rule could
     be written from it).
   - **KNOWN-SITE** — an already-established rule missing at one more call site.
   - **FOLLOW-ON** — a defect in a fix made earlier in this run.
6. **Fix the class, not the instance.** When a finding generalizes to a rule,
   apply the fix at **every analogous site in the same pass** — grep for the
   pattern; don't wait for codex to find the siblings one round at a time. Pin
   each regression test at the **exact seam** (counted-wrapper injection where
   ordering matters — a nearby-seam test can pass without exercising the fix).

**Phase transition → discipline sweep.** After **2 consecutive rounds with no
NEW-CLASS finding** (severity is a noisy signal — highs keep appearing in the
tail), stop the per-finding ladder and sweep. This rule **overrides** tier
progression: if it fires during the medium tier, skip the high per-finding tier
entirely — the sweep plus the high-effort capped verification rounds take its
place. Sweep:
- Distill this run's findings into **named rules/disciplines** (e.g.
  identity-gating, error taxonomy, arithmetic dedup, last-instant ordering,
  compare-and-write, alarm consistency — whatever the run actually taught).
- Fan out **parallel read-only audit subagents** (strong model), one rule
  each, over the whole touched surface. Demand: file:line evidence, a concrete
  failure scenario, CONFIRMED/PLAUSIBLE confidence, and an explicit
  **"checked clean"** list (negative coverage the ladder never gives you).
- **Personally verify every audit finding against the cited code before fixing**
  — audit agents can present unverified or fabricated corroboration; nothing is
  fixed on an auditor's say-so. Fix the survivors in one pass; declined findings
  go in the ledger as **accepted residuals** with rationale.
- Then run **capped verification rounds** (`high`, max 5): first clean round ends
  Phase 4. If findings survive, they are judged/fixed as usual and the cap ticks
  down.

**Termination:**
- A round whose findings are **all already in the ledger** counts as converged.
  Feed the ledger (dismissals + accepted residuals) back into **every** prompt —
  the ledger is what makes "clean" reachable at all against an adversarial
  reviewer that can otherwise re-derive residual race windows forever.
- **Runaway backstop:** if the per-finding ladder somehow reaches **25 rounds in
  one tier**, force the phase transition (sweep + capped verification) even if
  new classes are still trickling in.

---

## Phase 5 — Report

Post a single final report to the user:

- **What was built** — the change, per repo, with the key files/commits touched.
- **Plan sanity pass** — whether it ran; notable findings codex caught and how
  the plan changed; any findings deliberately ledgered instead of fixed.
- **Implementation-review loop** — rounds run per tier (medium/high), the
  finding-class breakdown (new-class / known-site / follow-on), whether and when
  the phase transition fired, sweep results (findings fixed vs accepted
  residuals, per discipline), and how convergence ended (`NO ISSUES FOUND`,
  all-ledger fixed point, or forced transition).
- **Dismissed findings** — the ledger: each finding you intentionally didn't act
  on, with the one-line rationale. This is a decision record, not filler.
- **Verification** — repo gate results (tests/lint/typecheck) per repo.
- **Follow-ups / risks** — anything left open.

Leave changes **uncommitted** unless the user asked otherwise (respect the
harness rule: commit/push only when asked). Point them at `$SCRATCH` for the
full per-round codex transcripts.

---

## Codex prompt templates

Both templates must demand the same machine-checkable contract:

> End your response with **either** a line that is exactly `NO ISSUES FOUND`
> (only when you found zero issues), **or** a numbered findings list and **no**
> sentinel line. Never emit both.

### Plan-review template (single sanity pass — write to `$SCRATCH/plan-review-prompt.md`)

```
You are a rigorous staff engineer reviewing an implementation PLAN (not code yet).

GOAL / TASK:
<one-paragraph statement of what is being built>

REPOS INVOLVED (mounted read-only — inspect them to sanity-check feasibility):
- /work/projects/<repo-a>
- /work/projects/<repo-b>

THE PLAN under review:
<paste the full contents of plan.md here, or say "see /work/input/plan.md">

Find everything that would make this plan fail, ship incomplete, or cause a
correctness/security/data-integrity problem: wrong or missing files & APIs,
invalid assumptions about how the current code works, missing steps, bad ordering
or dependency mistakes, unhandled edge cases and failure modes, migration/backfill
gaps, and cross-repo contract mismatches. Verify claims against the actual code in
the mounts. Prefer a few real blockers over a pile of nitpicks.

PREVIOUSLY REVIEWED — intentionally NOT changed, do NOT re-raise:
<dismissed ledger, or "none yet">

OUTPUT: A numbered list. Each finding: [SEVERITY blocker|major|minor] — plan
section and/or file:line — the problem — a concrete fix. If and only if you find
zero issues, reply with exactly one line: NO ISSUES FOUND
```

### Impl-review template (write to `$SCRATCH/impl-review-prompt.md`)

```
You are a rigorous staff engineer reviewing a code DIFF that implements a plan.

GOAL / TASK:
<one-paragraph statement of what was built>

THE PLAN it should satisfy:
<paste plan.md, or "see /work/input/plan.md">

THE DIFF under review (full working-tree change per repo):
- /work/input/diff-<repo-a>.patch
- /work/input/diff-<repo-b>.patch
Full source for context is mounted read-only at /work/projects/<repo>. If you run
any git command there, FIRST run: git config --global --add safe.directory '*'

<if any Phase-0 baseline was non-empty, add:>
OUT OF SCOPE — these files/hunks were already modified before this task started
(see /work/input/baseline-<repo>.patch); review only the changes beyond them:
<summarize the pre-existing changes>


Review for: correctness bugs, deviations from the plan, missing pieces, broken or
missing error handling, security holes, data-integrity/migration problems, edge
cases, regressions, and anything that would fail the repo's own tests. Point to
exact file:line in the diff. Prefer real defects over style nits.

PREVIOUSLY REVIEWED — intentionally NOT changed, do NOT re-raise:
<dismissed ledger, or "none yet">

OUTPUT: A numbered list. Each finding: [SEVERITY blocker|major|minor] —
file:line — the problem — a concrete fix. If and only if you find zero issues,
reply with exactly one line: NO ISSUES FOUND
```

---

## Parsing & judgment notes

- **Convergence check — read, don't grep.** The `tee`'d transcript is codex's full
  session stream: it contains an **echo of your prompt** (which itself includes
  the literal string `NO ISSUES FOUND` in the output instructions) and trailing
  metadata like a `tokens used` line — so naive "last line" or whole-file grep
  matching gives false positives. Read the round file, find codex's **final
  answer**, and treat the round as clean only when that answer is the bare
  sentinel with no findings list. When ambiguous, assume NOT converged and run
  another round.
- **Codex hard failures are not findings.** If `codex-review.sh` exits non-zero
  (auth, network, timeout — exit 124), that round produced no review: retry once;
  if it fails again, **stop the loop and report the error state** in the final
  report rather than spinning on a broken pipeline. Never count a failed round as
  converged.
- **You are the arbiter, not codex.** Every finding gets your judgment. Fix the
  real ones; dismiss the wrong/intentional ones *with a written reason*. Silently
  ignoring a finding is not allowed — it either changes the artifact or enters the
  ledger.
- **The ledger is what makes an unbounded loop terminate.** Feed it back every
  round so codex stops re-raising settled points, and count an all-ledger round as
  converged.
- **Cost awareness:** the medium tier exists to keep the high tier short. If an
  impl loop keeps surfacing the *same* area round after round, consider whether
  the **plan** was wrong and fix upstream rather than patching symptoms — that's
  cheaper than more rounds.
- **The ladder is a discovery tool, not a completion tool.** Its job is to teach
  you the bug classes; closing every instance of a known class is YOUR job (sweep),
  and proving closure is a capped verification round's job. Letting the ladder do
  all three is what produces 70-round runs.
- **Sweep auditors are advisors, not authorities.** Verify their citations
  yourself; require checked-clean lists; treat any corroboration you didn't
  witness as unverified.
