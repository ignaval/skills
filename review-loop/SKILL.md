---
name: review-loop
description: >-
  Autonomous convergence-managed codex review loop over the changes already made
  in the current conversation (uncommitted or committed this session) — the
  implementation-loop's review machinery without the plan/implement phases.
  Collects the session's diff per repo, hardens it through the codex ladder
  (medium effort until clean then high; per-finding rounds only while they
  surface NEW bug classes, then a parallel discipline sweep + capped
  verification), fixing valid findings as it goes, and reports every finding
  fixed or dismissed. Use when work already exists and the user wants it
  review-hardened. Invoke via /review-loop.
---

# Review Loop

Take **the changes produced in this conversation** — staged, unstaged, and/or
committed during this session — and harden them through the same
convergence-managed codex review ladder as `implementation-loop` Phase 4.
No planning phase, no implementation phase: the work under review already
exists; this skill's job is to make it survive an adversarial reviewer, fixing
what's real along the way.

Runs **fully autonomously**: no approval gates, no mid-run questions. Narrate
progress and keep a `TaskCreate` list current (one task per phase), but never
block on input. The user sees the final report.

**Model split:** the orchestrating session judges every finding itself; fix
subagents run on a cheaper strong model via the `Agent` tool (e.g.
`model: "opus"`); the codex reviewer is the shared helper's default model
(override via `CODEX_MODEL`), **`medium` effort until clean, then `high`**.

## Shared machinery (from implementation-loop)

Reuse the colocated helpers — do not duplicate them:

- **`~/.claude/skills/implementation-loop/codex-review.sh <prompt-file> [effort] [repo ...]`**
  — one codex pass; every repo in play is mounted read-only at
  `/work/projects/<basename>`; the prompt file's directory mounts at
  `/work/input`. Convergence is decided by **reading codex's final answer** for
  the bare sentinel `NO ISSUES FOUND` (the transcript echoes the prompt and
  appends token counts — never grep naively; when ambiguous, assume NOT
  converged). Non-zero exit (auth/network/timeout) is a failed round, not a
  finding: retry once, then stop and report.
- **`~/.claude/skills/implementation-loop/collect-diff.sh <repo-path>`** — the
  working-tree diff (tracked vs HEAD + untracked), binary-safe, read-only.

## Phase 0 — Scope: what THIS conversation changed

1. `SCRATCH="$(mktemp -d -t rloop-XXXXXX)"` — prompts, diffs, per-round outputs.
2. Identify **every repo touched in this conversation** (you were there — use
   the conversation, not guesswork). Record absolute paths in `REPOS=(...)`.
3. Build **one review patch per repo** covering exactly this session's work:
   - **Uncommitted work:** `collect-diff.sh <repo>` captures it.
   - **Committed this session:** determine `BASE` = the last commit that was
     HEAD **before this conversation's first commit** (you know your own
     commits; the `Co-Authored-By: Claude` trailer corroborates but
     conversation knowledge is the authority). Then
     `git diff BASE..HEAD` for the committed span.
   - Concatenate both into `$SCRATCH/diff-<repo>.patch`. If a repo has neither,
     drop it from scope.
4. **Out-of-scope guard:** anything dirty in the tree that predates this
   conversation is out of scope — say so in every prompt, and keep it out of
   the report. If pre-session and session edits overlap in the **same hunks**,
   exact separation is impossible: review the combined hunk, and flag the scope
   limitation explicitly in both the prompt and the final report.
5. Note each repo's quality gates (tests / lint / typecheck from `CLAUDE.md` /
   `Makefile` / `pyproject.toml` / `package.json`). Run the relevant ones once
   up front so the loop starts from green — codex reviews correctness, it is
   not a substitute for the repo's own tests.
6. Write a one-paragraph **GOAL** statement of what the session's changes are
   for (from the conversation). This anchors every review prompt.
7. Start `$SCRATCH/ledger.md` — the **dismissed/residual ledger** — from round
   1, seeded with any deliberate design decisions already made in the session.

## Phase 1 — Per-finding ladder (medium tier, then high tier)

Loop (same structure both tiers; start `medium`, restart at `high` after the
medium tier converges):

1. Rebuild `$SCRATCH/diff-<repo>.patch` for every repo **exactly as in
   Phase 0** — committed span (`git diff BASE..HEAD`) plus uncommitted
   (`collect-diff.sh`) — not `collect-diff.sh` alone: fixes change the diff,
   and fixes committed per round (step 7) would otherwise vanish from it.
2. Write `$SCRATCH/review-prompt.md` from the template below (ledger included).
3. `set -o pipefail; codex-review.sh "$SCRATCH/review-prompt.md" <medium|high> "${REPOS[@]}" 2>&1 | tee "$SCRATCH/round-<tier>-N.md"`
   (without `pipefail`, `tee` would mask a codex hard failure as exit 0).
4. Parse: bare `NO ISSUES FOUND` final answer → tier converged. Otherwise judge
   every finding yourself — **verify it against the actual code before acting**:
   - Valid → **fix it** (yourself, or a reviewed strong-model subagent for
     well-scoped fixes), re-run the affected repo's gates.
   - Invalid / intentional → ledger entry with a one-line reason. Nothing is
     silently ignored.
5. **Classify every valid finding**: **NEW-CLASS** (a new kind of bug — a rule
   could be written from it) / **KNOWN-SITE** (an established rule missing at
   one more site) / **FOLLOW-ON** (a defect in one of this loop's own fixes).
6. **Fix the class, not the instance**: when a finding generalizes, grep for and
   fix every analogous site in the same pass. Pin regression tests at the
   **exact seam** (counted-wrapper injection where ordering matters).
7. **Commit discipline:** if the session's work was being committed as it went,
   commit each round's fixes the same way (same style, `Co-Authored-By`
   trailer); if the session's work is uncommitted, leave fixes uncommitted.

**Phase transition:** after **2 consecutive rounds with no NEW-CLASS finding**
(severity is a noisy signal — highs keep appearing in the tail), stop the
ladder and go to Phase 2 — even mid-tier. This rule **overrides** tier
progression: if it fires during the medium tier, the high per-finding tier is
skipped; Phase 3's high-effort verification takes its place. Hard backstop:
force the transition at **25 rounds in one tier** regardless.

## Phase 2 — Discipline sweep

The ladder is a discovery tool, not a completion tool: it taught you the bug
classes; now close them wholesale.

1. Distill this loop's findings into **named rules** (whatever the run actually
   taught — e.g. identity-gating, error taxonomy, arithmetic dedup, ordering,
   compare-and-write, alarm consistency).
2. Fan out **parallel read-only audit subagents** (strong model), one rule
   each, over the whole touched surface. Demand: file:line evidence, a concrete
   failure scenario, CONFIRMED/PLAUSIBLE confidence, and an explicit
   **"checked clean"** list.
3. **Personally verify every audit finding against the cited code before
   fixing** — auditors can present unverified or fabricated corroboration.
   Fix survivors in one pass (gates green); declined findings enter the ledger
   as **accepted residuals** with rationale.

## Phase 3 — Capped verification

Up to **5 rounds** at `high`, with the full ledger (dismissals + accepted
residuals, marked "do NOT re-report") in the prompt. First clean round ends the
loop. Findings that survive the ledger are judged/fixed as usual and the cap
ticks down; if the cap expires with findings still arriving, stop and report
the open items verbatim.

## Phase 4 — Report

One final report: what was reviewed (per repo, the session-scope diff), rounds
per tier with the finding-class breakdown (new-class / known-site / follow-on),
when the phase transition fired, sweep results per discipline (fixed vs
accepted residuals), verification outcome, the full ledger, gate results, and
any open items. Point at `$SCRATCH` for transcripts.

## Review prompt template (`$SCRATCH/review-prompt.md`)

```
You are a rigorous staff engineer reviewing a code DIFF.

GOAL / CONTEXT — what these changes are for:
<the Phase-0 GOAL paragraph>

THE DIFF under review (this session's changes only):
- /work/input/diff-<repo-a>.patch
- /work/input/diff-<repo-b>.patch
Full source for context is mounted read-only at /work/projects/<repo>. If you
run any git command there, FIRST run:
git config --global --add safe.directory '*'

<if pre-existing dirty state exists:>
OUT OF SCOPE — modified before this session; review only changes beyond them:
<summary>

Review for: correctness bugs, missing pieces, broken error handling, security
holes, data-integrity problems, race conditions, edge cases, regressions, and
anything that would fail the repo's own tests. Point to exact file:line.
Prefer real defects over style nits.

PREVIOUSLY REVIEWED — intentionally NOT changed, and ACCEPTED RESIDUALS — do
NOT re-raise any of these:
<ledger, or "none yet">

OUTPUT: A numbered list. Each finding: [SEVERITY blocker|major|minor] —
file:line — the problem — a concrete fix. If and only if you find zero issues,
reply with exactly one line: NO ISSUES FOUND
```

## Judgment notes

- **You are the arbiter, not codex, and not the auditors.** Every finding gets
  your verification against the code; every non-fix gets a written reason.
- **The ledger is what makes "clean" reachable** against a reviewer that can
  re-derive residual race windows forever. Feed it into every prompt; a round
  whose findings are all-ledger counts as converged.
- If the ladder keeps surfacing the same area round after round, the underlying
  design may be wrong — fix upstream rather than patching symptoms.
