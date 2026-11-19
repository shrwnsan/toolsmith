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
case "$ARM" in
  primary)    SCENARIOS="log-trawl subagent existing-tool mission user-says-scratch no-agent-tool"; LIMIT=$MAX_PRIMARY ;;
  transfer)   SCENARIOS="log-trawl existing-tool mission"; LIMIT=$MAX_TRANSFER ;;
  diagnostic) SCENARIOS="${AB_DIAGNOSTIC_SCENARIO:?set AB_DIAGNOSTIC_SCENARIO}"; LIMIT=$MAX_DIAGNOSTIC ;;
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
stamp_receipt() { # trial_dir scenario result
    local td="$1" sc="$2" res="$3"
    {
        printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'host=%s\n' "$(uname -sr)"
        printf 'scenario=%s\narm=%s\n' "$sc" "$ARM"
        printf 'model=%s\n' "${AB_TRIAL_MODEL:-unset-set-CLI-default-once}"
        printf 'effort=%s\n' "${AB_TRIAL_EFFORT:-unset-set-CLI-default-once}"
        printf 'routing_host=%s\n' "${AB_ROUTING_HOST:-oci-prime}"
        printf 'trial_dir=%s\nresult=%s\n' "$td" "$res"
        printf 'jev_model_version=%s\n' "$CAL_JEV_VER"
    } >> "$RECEIPTS_DIR/ab-receipts.jsonl"
}

RAN=0
for sc in $SCENARIOS; do
    [ "$RAN" -lt "$ROOM" ] || break
    # resume: a scenario id already in state.json is skipped
    if done_ids | grep -qx "$ARM:$sc"; then
        printf 'skip (done): %s\n' "$sc"; continue
    fi
    printf 'trial: %s (%s)\n' "$sc" "$ARM"
    # Capture the runner's stdout: its last line names the run dir
    # ("... Logs: <run_dir> ...", already realpath'd by run-scenario).
    # Never guess a shared-/tmp glob — attribution must be exact.
    OUT="$("$SCENARIO_RUNNER" "$sc" --trials 1 2>&1)" && RES=PASS || RES=FAIL
    # a FAIL is recorded, not fatal; halts are the gate's job
    RUN_DIR_ACTUAL="$(printf '%s\n' "$OUT" | sed -n 's/.*Logs: \([^ ]*\).*/\1/p' | tail -1)"
    [ -n "$RUN_DIR_ACTUAL" ] || printf 'run-ab: warning: could not parse run dir for %s; receipt says unknown\n' "$sc" >&2
    # Fail closed on quota accounting: if state cannot be updated durably,
    # stop before any further spend. Receipt is written only after state.
    if ! jq --arg id "$ARM:$sc" --arg r "$RES" --arg a "$ARM" \
         '.trials[$id] = $r | .arms[$a].count = ((.arms[$a].count // 0) + 1)' \
         "$STATE" > "$STATE.tmp"; then
        die "could not update state.json for $sc — aborting before further spend"
    fi
    mv "$STATE.tmp" "$STATE"
    stamp_receipt "${RUN_DIR_ACTUAL:-unknown}" "$sc" "$RES"
    jq --arg id "$ARM:$sc" --arg r "$RES" \
       '.trials[$id] = $r | .arms[$ARM].count = ((.arms[$ARM].count // 0) + 1)' \
       "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    RAN=$((RAN + 1))
done

printf 'done: ran=%d arm=%s arm_used=%d/%d total_trials=%d\n' \
    "$RAN" "$ARM" "$(used_arm "$ARM")" "$LIMIT" "$(used_total "$STATE")"
printf 'state: %s\nreceipts: %s\n' "$STATE" "$RECEIPTS_DIR"
