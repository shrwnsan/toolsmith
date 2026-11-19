#!/usr/bin/env bash
# run-ab.sh — calibration-gated, resumable, quota-bounded A/B runner
# for the toolsmith Jev-seat preflight Gate 3 (see preflight/RUNBOOK.md,
# which is canonical over this script).
#
# Wraps upstream's tests/scenarios/run-scenario. Adds:
#   - calibration gate: refuses without a passing calibration.json whose
#     jev-model-version matches the current pin (RUNBOOK Calibration);
#   - quota caps: max 12 trials per invocation, 1 concurrent, primary <= 8,
#     transfer <= 6 lifetime, diagnostics <= 2 (RUNBOOK quota caps);
#   - resumable state: state.json records completed trial ids; re-invocation
#     skips them; deleting state.json restarts quota accounting (deliberate);
#   - receipt stamping: trial.env lacks model/effort (DECISIONS §13), so each
#     trial gets a stamped receipt line in the host receipts dir;
#   - hygiene: trial output stays in the runner's temp dir and the host
#     receipts dir; nothing raw is written inside the repo or pushed.
#
# It never spends on its own: the arm list is an explicit argument, and the
# user's "go" is a precondition recorded in calibration.json by the operator.
#
# Usage: run-ab.sh <arm>            arm in {primary, transfer, diagnostic}
# Requires: tests/scenarios/run-scenario on PATH or at repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${AB_RUN_DIR:-${TMPDIR:-/tmp}/toolsmith-ab/run-$(date +%Y%m%d)}"
# Preflight shim dir: covers only MISSING commands (uuidgen on minimal
# Linux hosts; run-scenario:202 hard-requires it with no fallback —
# candidate micro-contribution for the upstream issue). Prepending means
# a real uuidgen still wins on machines that have one.
PATH="$REPO_ROOT/preflight/shim:$PATH"
export PATH
RECEIPTS_DIR="${AB_RECEIPTS_DIR:-$HOME/code/toolsmith-preflight/receipts}"
STATE="$RUN_DIR/state.json"
CALIBRATION="${AB_CALIBRATION:-$RECEIPTS_DIR/calibration.json}"

MAX_PER_INVOCATION=12
MAX_PRIMARY=8
MAX_TRANSFER=6
MAX_DIAGNOSTIC=2

die() { printf 'run-ab: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq required"
SCENARIO_RUNNER="$REPO_ROOT/tests/scenarios/run-scenario"
[ -x "$SCENARIO_RUNNER" ] || die "run-scenario not found/executable at $SCENARIO_RUNNER"

ARM="${1:-}"
# Seat state for this invocation: 0 = seat-off (baseline arm), 1 = seat-on.
# Only the flag differs between arms — same host, same model/effort pins,
# identical checkout (RUNBOOK A/B design).
AB_SEAT="${AB_SEAT:-0}"
case "$AB_SEAT" in 0|1) ;; *) die "AB_SEAT must be 0 or 1" ;; esac
export TOOLSMITH_TRIAGE="$AB_SEAT"

# Per-trial model pin (RUNBOOK): DECISIONS §13's host-CLI-default approach
# would flip the operator's own sessions too, so trials get an explicit
# env override. The pin file holds the PROBED id (verified reachable
# through this host's routing). Receipts stamp the requested pin; the
# void rule (resolved ≠ pin) is checked against the session transcript
# at review (transcripts record the resolved model per message).
MODEL_PIN="$(cat "$REPO_ROOT/preflight/trial-model-pin" 2>/dev/null | head -1)"
[ -n "$MODEL_PIN" ] || die "preflight/trial-model-pin missing — probe the heavy-tier id first"
export ANTHROPIC_MODEL="$MODEL_PIN"

case "$ARM" in
  # Planned cells (RUNBOOK A/B design): the three seat-relevant scenarios.
  primary)    CELLS="existing-tool:3 log-trawl:3 subagent:2"; LIMIT=$MAX_PRIMARY ;;
  transfer)   CELLS="existing-tool:2 log-trawl:2 mission:2";  LIMIT=$MAX_TRANSFER ;;
  # Diagnostic: single-scenario max-effort rerun; never an experimental arm.
  diagnostic) CELLS="${AB_DIAGNOSTIC_SCENARIO:?set AB_DIAGNOSTIC_SCENARIO}:1"; LIMIT=$MAX_DIAGNOSTIC ;;
  *) die "usage: run-ab.sh primary|transfer|diagnostic" ;;
esac

# --- calibration gate ------------------------------------------------------
[ -f "$CALIBRATION" ] || die "no calibration.json — run the calibration gate first (RUNBOOK)"
jq -e '.status == "pass"' "$CALIBRATION" >/dev/null || die "calibration status is not pass — halt per RUNBOOK"
CAL_JEV_VER="$(jq -r .jev_model_version "$CALIBRATION")"
CAL_TIME="$(jq -r .calibrated_at "$CALIBRATION")"
[ -n "$CAL_JEV_VER" ] && [ "$CAL_JEV_VER" != "null" ] || die "calibration.json missing jev_model_version"
# version drift halts; re-baselining is the user's decision, never ours.
CURRENT_JEV_VER="${AB_JEV_MODEL_VERSION:-$CAL_JEV_VER}"
[ "$CURRENT_JEV_VER" = "$CAL_JEV_VER" ] || die "jev version drift ($CAL_JEV_VER -> $CURRENT_JEV_VER); halt, re-calibrate by hand"
printf 'calibration: pass, jev=%s, calibrated_at=%s\n' "$CAL_JEV_VER" "$CAL_TIME"

# --- resumable state -------------------------------------------------------
mkdir -p "$RUN_DIR" "$RECEIPTS_DIR"
[ -f "$STATE" ] || printf '{"arms":{},"trials":{}}\n' > "$STATE"

used_arm()  { jq -r --arg a "$1" '.arms[$a].count // 0' "$STATE"; }
used_total(){ jq -r '[.trials[]] | length' "$STATE"; }
done_ids()  { jq -r '.trials | keys[]' "$STATE" 2>/dev/null || true; }

ARM_USED="$(used_arm "$ARM")"
[ "$ARM_USED" -lt "$LIMIT" ] || die "arm '$ARM' quota exhausted ($ARM_USED/$LIMIT lifetime)"
ROOM=$((LIMIT - ARM_USED))
[ "$ROOM" -gt "$MAX_PER_INVOCATION" ] && ROOM=$MAX_PER_INVOCATION

# --- run -------------------------------------------------------------------
stamp_receipt() { # trial_dir trial_id result
    local td="$1" tid="$2" res="$3"
    {
        printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'host=%s\n' "$(uname -sr)"
        printf 'scenario=%s\narm=%s\n' "${tid#*:}" "$ARM"
        printf 'trial_id=%s\nseat=%s\n' "$tid" "$AB_SEAT"
        printf 'model=%s\nrequested_model=%s\n' \
            "${AB_TRIAL_MODEL:-resolved-per-transcript-review}" "$MODEL_PIN"
        printf 'effort=%s\n' "${AB_TRIAL_EFFORT:-unset-set-CLI-default-once}"
        printf 'routing_host=%s\n' "${AB_ROUTING_HOST:-oci-prime}"
        printf 'trial_dir=%s\nresult=%s\n' "$td" "$res"
        printf 'jev_model_version=%s\n' "$CAL_JEV_VER"
    } >> "$RECEIPTS_DIR/ab-receipts.jsonl"
}

RAN=0
for cell in $CELLS; do
    sc="${cell%%:*}"; reps="${cell##*:}"
    rep=1
    while [ "$rep" -le "$reps" ]; do
        [ "$RAN" -lt "$ROOM" ] || break 2
        # trial ids carry a repetition counter (F1) so cells hold many trials
        TID="$ARM:$sc#$rep"
        if done_ids | grep -qx "$TID"; then
            printf 'skip (done): %s\n' "$TID"; rep=$((rep + 1)); continue
        fi
        printf 'trial: %s (arm=%s seat=%s)\n' "$TID" "$ARM" "$AB_SEAT"
        # Capture the runner's stdout: its last line names the run dir
        # ("... Logs: <run_dir> ...", already realpath'd by run-scenario).
        # Never guess a shared-/tmp glob — attribution must be exact.
        OUT="$("$SCENARIO_RUNNER" "$sc" --trials 1 2>&1)" && RES=PASS || RES=FAIL
        # a FAIL is recorded, not fatal; halts are the gate's job
        RUN_DIR_ACTUAL="$(printf '%s\n' "$OUT" | sed -n 's/.*Logs: \([^ ]*\).*/\1/p' | tail -1)"
        [ -n "$RUN_DIR_ACTUAL" ] || printf 'run-ab: warning: could not parse run dir for %s; receipt says unknown\n' "$TID" >&2
        # Fail closed on quota accounting: if state cannot be updated durably,
        # stop before any further spend. Receipt is written only after state.
        if ! jq --arg id "$TID" --arg r "$RES" --arg a "$ARM" \
             '.trials[$id] = $r | .arms[$a].count = ((.arms[$a].count // 0) + 1)' \
             "$STATE" > "$STATE.tmp"; then
            die "could not update state.json for $TID — aborting before further spend"
        fi
        mv "$STATE.tmp" "$STATE"
        stamp_receipt "${RUN_DIR_ACTUAL:-unknown}" "$TID" "$RES"
        RAN=$((RAN + 1))
        rep=$((rep + 1))
    done
done

printf 'done: ran=%d arm=%s arm_used=%d/%d total_trials=%d\n' \
    "$RAN" "$ARM" "$(used_arm "$ARM")" "$LIMIT" "$(used_total "$STATE")"
printf 'state: %s\nreceipts: %s\n' "$STATE" "$RECEIPTS_DIR"
