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

### Matching-semantics definition (Gate 2 re-corpus, 2026-11-19)

A catalog tool **MATCHES** a brief when the brief's underlying need is
satisfied by the tool **as its catalog line describes it**, including via
documented safe flags (`--dry-run`, `--list`, read-only modes). A different
action verb (archive vs delete, list vs page) or a different target (file
vs live host, spec vs log) = **no-match**, even in the same domain. This
definition settled the Gate 2 halt: n16 was mislabeled, not mis-scored —
`prune-old --dry-run` satisfies "list files older than 30d for review",
so routing there is the seat succeeding.

### Working systemone schema (replaces the stale mapped mapping)

Verified against a working client on this host (vibekit/reflex
`reflex-gate.mjs`) and confirmed by live 422 diagnostics on 2026-11-19:

- `questions` is a **dict of named question objects**, each
  `{type: "noul", instructions: <str>, criteria: {true: <str>, false: <str>}}`.
  A JSON list → 422 `dict_type`; a dict of bare strings → 422
  `model_attributes_type` per key.
- Answers: `r["answers"]["<question-name>"]["noul"]` = probability that the
  `true` criterion holds. There is no `classification.choice` field in this
  question shape.
- The audit sibling's format — a JSON **list** of questions answered as
  `answers.classification.choice`/`.confidence` — also exists per
  `context-triage.py` v1.2.x (the two shapes appear to be per-question-type
  variants). Future agents: check which shape your questions use before
  the first call; both 422s are charged nothing but cost a round trip.
- Endpoint `POST {TYPESAFE_BASE_URL:-...}/v1/systemone`; retry and
  resolved-version behavior unchanged (see score-corpus.py header).

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

Recorded threshold: **0.32** — measured 2026-11-19, band run on the full
64-row corpus (receipt: `scorer-receipts.jsonl`, ~18:45Z). Resolved model
`jev-1.14.0`, single version across all 64 calls. Bands: match rows
[0.37, 0.98] (n=32), no-match rows [0.01, 0.27] (n=32), overlap = false.
0.32 is the midpoint of the inter-band gap (0.27–0.37), giving symmetric
margin ±0.05. The confirm band is that gap; its width (0.10) is the
measured margin. Confirmation run at this threshold is required before
calibration.json may be written (Jev run-to-run variance).

Known borderline row: **n22** ("generate a 32-char API key" vs
`passphrase-gen`), ruled correctly labeled 2026-11-19 — output-form
mismatch (diceware words vs fixed-length key). If Gate 3 shows
output-form false-clears, that refines the QUESTION set, not the corpus.

## A/B design (Gate 3; resolves F2's design restatement)

- **Baseline arm = seat-off on this host and tier** (`AB_SEAT=0`).
  Upstream's published 36-trial table is context only — a different
  host, model, and epoch — and is NEVER the comparison arm.
- Arms differ in exactly one bit: `TOOLSMITH_TRIAGE=0|1`, exported by
  `run-ab.sh` per invocation. Same host, same model/effort pins,
  identical checkout.
- Planned cells (trial ids carry repetition counters, e.g.
  `primary:log-trawl#2`):
  - primary (heavy, effort=high, cap 8): existing-tool ×3, log-trawl ×3,
    subagent ×2 — the three seat-relevant scenarios;
  - transfer (flash, cap 6): existing-tool ×2, log-trawl ×2, mission ×2;
  - `mission` and `user-says-scratch` stay compliance checks in BOTH
    arms: they must pass unchanged wherever they run; the seat is
    expected to be irrelevant to them, and a seat that changes their
    outcome is a seat defect.
- Diagnostic budget unchanged (≤2 max-effort reruns per invocation,
  never tallied into an arm).
- Seat state (`seat=0|1`) is stamped on every trial receipt, so the
  arms remain separable even when invocations interleave.

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

- oci-prime (this host): the working writer — Phase 0 authoring, corpus
  work, commits, pushes (single-agent reality; the earlier Mac-authors /
  prime-executes split is superseded. Mac remains the review side).
- Mac: downstream review; owns the jev-seat methodological sign-off.
- Spend posture: no real API spend without the user's explicit "go"
  (Gate 2 authorized 2026-11-19: two passes, ~$1 total).
