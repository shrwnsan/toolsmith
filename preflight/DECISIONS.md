# Preflight decisions (preserved context, 2026-11-19)

Durable in-repo copy of the handoff snapshot's `preserved_context` entries
(napkin `docs/labs/toolsmith-jev-seat-handoff-2026-11.yaml`). Settled after
full review; do not re-derive or re-litigate here. One section per entry.

## 1. Hygiene (non-negotiable)

Raw trial output — transcripts, `claude.json`, `.err`, trial dirs — is never
committed to any remote. It lives on the executor host only. Committed
summaries are curated and scrubbed: upstream's own README warns transcripts
contain the account email. On this host: raw output stays under
`~/code/toolsmith-preflight/receipts/` (outside the clone) or the run's temp
dir; only curated summaries enter `preflight/`.

## 2. Framing rule

Flash-tier pass-rate findings about the upstream plugin are introduced in
the GitHub issue conversation, collegially — never baked into committed repo
prose ahead of the issue. Preflight docs describe our own apparatus; they
publish no upstream findings.

## 3. Upstream facts (measured by author, cited not re-verified)

Trials cost $0.10–0.70 each on CC 2.1.318 / opus-5-5; 36 trials recorded,
18/18 pass with the plugin; baselines FAIL as predicted; auto-mode classifier
caveat ("the classifier is a model"). These numbers anchor our cost
extrapolation ($1–2 Gate 2, $10–30 Gate 3) and the decision to treat Gate 3
as the decisive test. We do not re-measure them.

## 4. SessionStart hook matcher gap

`hooks/hooks.json:5` lacks `resume` — resumed sessions get no injection.
Possible PR-side fix; do NOT bundle it with the seat. Kept as a separate
candidate so the seat PR stays reviewable.

## 5. Upstream declares MIT, ships no LICENSE file

Ask for a LICENSE file in the Gate 4 issue — it affects forking legality
formally. Not a preflight work item; recorded so Gate 4 doesn't forget.

## 6. Secrets discipline

Presence-only checks for `TYPESAFE_API_KEY` / `ANTHROPIC_BASE_URL`; never
print values; if a probe surfaces a value, redact it everywhere. The 2026-11-19
env probe on this host passed under this rule (receipt:
`~/code/toolsmith-preflight/receipts/env-probe-20261119-1429.md`, outside the
clone by design).

## 7. Branch and push discipline

Do not push `jev-seat`; the user (Mac side) pushes when asked. No commits
unless asked. The branch lives directly in a fresh dedicated clone — worktree
ceremony intentionally skipped, a conscious deviation from the global
new-branch-as-worktree norm.

## 8. Canonical clone locations

The Mac authoring session ran inside `~/.dotfiles` (unrelated unstaged
changes; irrelevant). Its toolsmith work lives in `~/Developer/sandbox/toolsmith`.
The `/tmp/toolsmith-review-1795084709/toolsmith` clone was the ephemeral
review copy, not canonical. On this host (oci-prime) the canonical clone is
`~/code/toolsmith-preflight/toolsmith`.

## 9. Inherited global rules

Receiving agent inherits the global AGENTS.md rules: trash not `rm`,
conventional commits, secret files never opened, exact versions for new
dependencies, unslop for user-facing prose docs.

## 10. Jev facts (user's eval-024, 2026-10-02/23)

~$0.001/call. Calibration is version-dependent — re-run the baseline per
model update. `api.typesafe.ai` egress varies per session; settle it with a
probe GET, not assumptions. Jev is not on OpenRouter / AI Gateway (own
protocol).

## 11. Private-mirror question: resolved as public fork

Artifacts decompose into raw trial output (never committed anywhere) and
curated evidence (publishable). A private mirror would only buy
reversibility while costing deploy keys on oci-prime, a PR-time fork dance,
and explanation burden. Full critical review 2026-11-19; public fork
`shrwnsan/toolsmith` chosen. Corollary: decide visibility before pushing
anything — GitHub forks of public repos cannot be made private later.

## 12. context-triage.py is not reusable as-is for Gate 2

The auditing-agent-harnesses skill's scorer encodes audit failure costs: its
taxonomy is benign/pipeline-shaped and its auto-resolve gate is
(>= 0.75 AND non-benign on pipeline-shaped). The preflight corpus labels are
match/no-match with a different error asymmetry (a false clear spends a wasted
toolsmith round trip and hides a catalog gap; a false block costs one grep).
Gate 2 needs a thin sibling scorer sharing the discipline — probe, receipts,
measured band, pinned model — not the script.

## 13. Trial env does not record the model pin

Pressure-scenario trials inherit the host claude CLI's saved config;
`run-scenario` execs plain `claude` with no `--model` pin, and `trial.env`
records neither model nor effort. Receipts must stamp model + routing +
effort manually per trial, and the pin is implicit: set the CLI default once
and never touch it mid-experiment.

## 14. Compliance is model-tier sensitive; order heavy-first

Toolsmith's mechanism is pure behavioral suppression (convincing a model not
to do its trained instinct); compliance varies sharply by tier and a
flash-tier baseline may land at floor. Order experiments heavy-tier-first for
attribution (debug the seat on a reliable apparatus); flash is a small
transfer check (~6 trials) second. Max effort is a diagnostic probe only,
never an experimental arm.
