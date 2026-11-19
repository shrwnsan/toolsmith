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

1. Score the corpus with the Jev scorer (`score-corpus.py`) at the
   candidate threshold.
2. Baseline is 2–3 scorer calibration calls against the pinned Jev
   version (~$0.001 each) plus full corpus scoring.
3. **Halt conditions — stop and report, do not tune pins:**
   - baseline lands at floor (near-0 discrimination) or ceiling
     (near-perfect on everything including hard negatives);
   - false-clear rate at the chosen threshold is not ~0;
   - Jev version differs from the calibrated one (calibration is
     version-dependent, DECISIONS §10);
   - egress probe to `api.typesafe.ai` fails (settle with a probe GET,
     never assumptions).
   A halt is a valid result. Report; the user decides the next pin set.
4. Calibration never transfers across hosts or model updates.

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
