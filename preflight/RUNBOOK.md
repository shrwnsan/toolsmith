# RUNBOOK: toolsmith Jev-seat preflight (canonical protocol)

This file is canonical. If any other artifact (prompt, memory, chat)
conflicts with it, this file wins. Decisions themselves live in
`DECISIONS.md`; the Gate 1 collision analysis in `DESIGN-NOTE.md`.

## Gate ladder

| Gate | What | Cost | Status |
|---|---|---|---|
| 1 | Anti-goal collision check | free | done — see DESIGN-NOTE.md |
| 2 | Corpus baseline via Jev scorer | ~$0.50 TypeSafe | blocked on user "go" |
| 3 | A/B on upstream's own `tests/scenarios/run-scenario` harness | $10–30 | after Gate 2 passes |
| 4 | Maintainer probe (issue with receipts) | free | after Gate 3 |

No real API spend of any kind until the user explicitly says go.

## Pins (never adjusted mid-experiment)

- **Primary arm:** heavy glm-5.3, effort = high. Chosen for attribution:
  debug the seat on a reliable apparatus (DECISIONS §14).
- **Transfer check:** flash tier, ~6 trials, only after the primary arm
  is read. Its result is a transfer observation, never merged into the
  primary tallies.
- **Max effort:** diagnostic probe only — one scenario rerun, result
  logged as diagnostic, never into arm tallies. Diagnostic budget:
  at most 2 per run invocation.
- **Model pin is implicit** (DECISIONS §13): the harness execs plain
  `claude`, so set the host CLI default once and never touch it
  mid-experiment. Receipts stamp the resolved model per trial.

## Calibration gate (before any arm)

1. Probe egress (free, unauthenticated GET; any HTTP response = reachable).
2. Measure the confidence **band** first (`score-corpus.py --band`): score
   the corpus with no threshold and record min/max confidence per label
   class from the receipts.
3. **The threshold is measured, never assumed.** The audit sibling's 0.75
   does NOT transfer — it was measured against its own questions, and our
   QUESTIONS are different (authored for match/no-match). Pick the
   threshold from the measured band, then record BOTH the threshold and
   the confirm-band mechanics here (below) before any scored run.
4. Baseline is the full corpus scored at that threshold (~$0.50).
5. **Halt conditions — stop and report, do not tune pins:**
   - baseline lands at floor (near-0 discrimination) or ceiling
     (near-perfect on everything including hard negatives);
   - false-clear rate at the chosen threshold is not ~0;
   - the resolved Jev version differs from the calibrated one, or more
     than one version appears in a single run (calibration is
     version-dependent, DECISIONS §10);
   - egress probe fails (no HTTP response at all).
   A halt is a valid result. Report; the user decides the next pin set.
6. Calibration never transfers across hosts, model updates, or question
   sets.

### Confirm-band mechanics (match/no-match; recorded at Gate 2)

To be filled in from the measured band — the mechanics are re-derived for
match/no-match, not inherited from the audit gate:

- Predicted match = classifier choice `match` AND confidence >= threshold.
  Below threshold, the seat escalates to the toolsmith (today's baseline
  behavior — never blocks).
- **False clear** (predicted match on a no-match row) is the barred
  failure: it runs the wrong tool or hides a catalog gap. Gate 2 passes
  only at false-clear = 0.
- **False block** (no predicted match on a match row) costs one wasted
  toolsmith round trip — the baseline cost, tolerated but counted.
- The band between "lowest confident true match" and "highest confident
  false clear" (if they overlap, the question set is too weak — halt) is
  the confirm band; the threshold sits inside it, and its width is the
  measured margin, reported as such.

Recorded threshold: **unset — measured at Gate 2**, per step 3.

## Trial quota caps (per `run-ab.sh` invocation)

- Max trials per invocation: 12.
- Max concurrent: 1 (serial; trials are minutes-long and probabilistic).
- Per-arm caps: primary ≤ 8, transfer ≤ 6 total across all invocations,
  diagnostics ≤ 2 (see Pins).
- The runner refuses to start without a passing calibration state file,
  refuses past quota, and is resumable (see below).

## Receipt stamping (every trial and every scorer call)

`trial.env` records neither model nor effort (DECISIONS §13), so every
receipt line carries explicitly:
`date, host, scenario, arm, model, effort, routing-host,
trial-dir, result`.
Scorer receipts add: `jev-model-version, threshold, score, label,
predicted`. Receipts are written to the host-side receipts dir —
on oci-prime: `~/code/toolsmith-preflight/receipts/` (outside the
clone) — never into the repo, never pushed.

## Hygiene rules (non-negotiable; DECISIONS §1)

- Raw trial output (transcripts, `claude.json`, `.err`, trial dirs)
  lives on the executor host only; NEVER committed to any remote.
- Committed summaries are curated and scrubbed (transcripts contain the
  account email).
- Secrets: presence-only checks; never print values; redact on surfacing.
- Trials run with upstream's own isolation: `TOOLSMITH_TEST_REPO` temp
  tools repo, fresh temp caller repo, `--setting-sources project
  --strict-mcp-config` (no user hooks load).
- Framing rule (DECISIONS §2): no upstream findings in committed prose.

## Resumable state

`run-ab.sh` keeps `state.json` in the run dir: completed trial ids with
result and receipt path, arm counters, quota consumed. On re-invocation
it skips completed ids, refuses if quota is exhausted, and only proceeds
past the calibration gate if `calibration.json` exists with
`status: pass` and a matching `jev-model-version`. Deleting `state.json`
restarts quota accounting (a deliberate, user-visible act).

## Execution-host split

- oci-prime (this host): staged executor, preferred for scheduled /
  overnight runs (no sleep). Probe verdict 2026-11-19: ready-to-execute.
- Mac: authoring home — corpus authoring, PR work, commits, pushes.
- oci-prime holds read-only-until-instructed posture: no push, no spend
  without explicit "go".
