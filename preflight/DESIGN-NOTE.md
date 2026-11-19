# DESIGN-NOTE: Jev seat vs. upstream goals and anti-goals (Gate 1)

Gate 1 of the 4-gate ladder: check the proposed seat for collisions with
upstream's design intent before any spend. Scored against
`docs/superpowers/specs/2026-11-05-toolsmith-plugin-design.md` (goals,
anti-goals, constraints). Status: **pass-with-conditions** — every collision
found has a named mitigation; the two hard failures are scoped out of the
seat entirely.

## The proposed seat

Escalation-boundary triage at the caller. Before spending a toolsmith round
trip, the caller scores its brief against the catalog lines it just grepped
(a Jev call, ~$0.001). Score >= threshold: use the near-match catalog entry
(read the tool, run `--help`). Score < threshold: escalate to the toolsmith
as today. Secondary seats (extend-vs-new, semantic standards lint) are
out of preflight scope. The seat is env-flag-gated and degrades to plain
grep when the key is absent.

## Collision table

| # | Upstream intent | Seat pressure | Verdict | Mitigation |
|---|---|---|---|---|
| 1 | Anti-goal: "a toolsmith slow enough that agents prefer a heredoc" — one round trip max | A triage miss that sends a would-fit brief to the toolsmith is *today's* behavior (still one round trip). A triage hit that returns a near-match **saves** the round trip. Seat adds ~1 Jev call (~$0.001, sub-second) | **No collision** | None needed; measure false-clear rate at Gate 2 before trusting savings |
| 2 | Anti-goal: "a catalog that drifts from the repo" — toolsmith must trust catalog lines | The seat scores *against catalog lines*; a drifted line gets a confident match to a tool that no longer matches its text | **Soft collision** | The seat reads catalog lines only (generated, drift-resistant by design). Gate 2 corpus includes near-miss negatives on stale-ish lines; seat never edits the catalog |
| 3 | Anti-goal / "line between tool and mission": scope creep into mission work | A model-scored gate between the caller and the toolsmith is a new judgment surface in the mission agent's path; a chatty or wrong scorer could push agents to bypass (the heredoc leak again) | **Soft collision** | Seat is silent on miss (plain escalation, unchanged wording); it never blocks or argues. Gate 2 success bar: false-clear ~ 0 at chosen threshold |
| 4 | Constraint: "Local repo, local git. No network." (design constraints) | The Jev call is a network call on every triage | **Hard collision if unconditional** | Env-flag-gated (`TOOLSMITH_TRIAGE=1`-style opt-in), and offline-first: no key or failed probe → degrade to plain grep, plugin fully functional without it. Upstream constraint governs the *plugin's* default; the seat ships as opt-in |
| 5 | Constraint: no edits to the user's config beyond install; no enforcement hooks | Seat adds no hooks, no config edits — it lives in `writing-tools` skill text + a tiny helper | **No collision** | None. Do not convert the seat into a PreToolUse gate (that would also collide with the "no enforcement hooks" decision) |
| 6 | Constraint: "must not depend on anything in one person's CLAUDE.md" (shareable like superpowers) | Seat depends on a TypeSafe key the user must provision | **Soft collision** | Same as #4: absent key = seat absent. No behavior change, no prompt noise when unconfigured |
| 7 | "The catalog is generated, never grown" — improvement loop is author-side | Seat could be tempted to write back scores/lessons | **Scoped out** | No write-back, ever (upstream has no telemetry by design; grep-verified 2026-11-19). Scores go to receipts on the executor host only |
| 8 | Injection-surface: hook injects catalog path; caller greps raw catalog | Seat reads caller's brief + catalog text — both attacker-influenceable in adversarial sessions | **Soft collision** | Catalog content is sanitized (plain text into the score prompt, no instruction-following from it); brief is caller-authored, same trust as today's subagent brief. Noted as a known surface; not testable in preflight |
| 9 | Reply-format determinism (`tool:`-line contract) | Seat does not touch the toolsmith reply path; it only chooses *whether* to call | **No collision** | None |

## Conditions carried into RUNBOOK.md

1. Opt-in env flag; absent key → seat disabled, zero behavior change (rows 4/6).
2. Gate 2 success bar: false-clear ~ 0 at the chosen threshold, measured on a
   labeled corpus with hard negatives (rows 2/3).
3. No write-back from the seat; scorer outputs live in host-side receipts
   only (row 7).
4. Calibration is version-dependent: re-run baseline on any Jev model update
   (DECISIONS §10).

## Verdict

Proceed to Gate 2 (corpus baseline, ~$0.50 TypeSafe spend) — but only after
the user's explicit "go"; no spend before that. Gate 1 itself is free and
complete on review of this table.
