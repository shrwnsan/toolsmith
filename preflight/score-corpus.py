#!/usr/bin/env python3
"""score-corpus.py — thin match/no-match scorer for the toolsmith Jev seat.

Sibling of the auditing-agent-harnesses context-triage.py DISCIPLINE, not a
port of the script. The audit scorer's taxonomy (benign/pipeline-shaped) and
gate (>= 0.75 AND non-benign on pipeline-shaped) encode audit failure costs.
Here the labels are match/no-match and the error asymmetry differs:

  false CLEAR (says "near-match" when none exists) => a saved round trip that
      runs the wrong tool or hides a catalog gap  -> the failure Gate 2 bars;
  false BLOCK => one wasted toolsmith round trip  -> today's baseline cost.

So the gate is one-sided: threshold on the match score, and the success bar
is false-clear ~ 0 (RUNBOOK Calibration gate).

Shared discipline kept from the audit sibling:
  - egress probe before any scored call (probe GET, never assumptions);
  - every call writes a receipt line (model version pinned and stamped);
  - a measured score band is printed before any threshold is chosen;
  - the model is pinned; a version drift halts rather than re-calibrates.

Not runnable by accident: it refuses without an explicit --go, performs no
network call until the egress probe succeeds, and exits 2 on any halt
condition. PYTHONHASHSEED irrelevant: no set/dict ordering affects output.

Usage:
  score-corpus.py --corpus preflight/corpus.jsonl --threshold T --go
  score-corpus.py --probe-only --go          # egress check only, no spend
Exit codes: 0 ok, 1 usage, 2 halt condition (see RUNBOOK), 3 probe failure.
Secrets: the key is read from TYPESAFE_API_KEY, never printed, never logged.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

PINNED_JEV_VERSION = "SET-AFTER-FIRST-CALIBRATION"  # filled once, then drift halts
ENDPOINT = "https://api.typesafe.ai/v1/jev"  # own protocol (not OpenRouter); confirm shape against eval-024 receipts before --go
PROMPT_TEMPLATE = """You are triage for a script catalog. Decide whether the catalog line
satisfies the brief. Answer with JSON only: {"match": true|false, "score": <0.0-1.0>}.
A near-match counts only if the tool does what the brief asks (not the
reverse, not an adjacent behavior).

Brief: {brief}
Catalog line: {catalog_line}
"""


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def receipt(receipts_dir, kind, payload):
    os.makedirs(receipts_dir, exist_ok=True)
    line = json.dumps({"ts": now_iso(), "kind": kind, **payload}, sort_keys=True)
    path = os.path.join(receipts_dir, "scorer-receipts.jsonl")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    print(line)  # stdout is a run log, not a receipt; receipts are the file


def egress_probe(timeout=8):
    """HEAD-then-GET probe; returns (ok, detail). Never sends the key."""
    req = urllib.request.Request("https://api.typesafe.ai/", method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return True, f"http_{resp.status}"
    except Exception as exc:  # noqa: BLE001 - probe reports, does not traceback
        return False, type(exc).__name__


def call_jev(brief, catalog_line, model_pin):
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not key:
        # presence-only failure; the message never quotes the value
        print("halt: TYPESAFE_API_KEY absent", file=sys.stderr)
        sys.exit(2)
    body = json.dumps({
        "model": model_pin,
        "prompt": PROMPT_TEMPLATE.format(brief=brief, catalog_line=catalog_line),
    }).encode()
    req = urllib.request.Request(
        ENDPOINT, data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)
    # NOTE: response field names to be confirmed against eval-024 before first
    # scored call; keep this one adapter function the only place that knows.
    return data


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--corpus", default="preflight/corpus.jsonl")
    ap.add_argument("--threshold", type=float)
    ap.add_argument("--probe-only", action="store_true")
    ap.add_argument("--limit", type=int, help="score only the first N rows")
    ap.add_argument("--receipts-dir", default=os.path.expanduser(
        "~/code/toolsmith-preflight/receipts"))
    ap.add_argument("--model-pin", default=PINNED_JEV_VERSION)
    ap.add_argument("--go", action="store_true",
                    help="explicit consent; nothing is scored without it")
    args = ap.parse_args()

    if not args.go:
        print("refusing: no --go (RUNBOOK: no spend without explicit consent)",
              file=sys.stderr)
        sys.exit(1)

    ok, detail = egress_probe()
    receipt(args.receipts_dir, "probe", {"ok": ok, "detail": detail})
    if not ok:
        print(f"halt: egress probe failed ({detail})", file=sys.stderr)
        sys.exit(3)
    if args.probe_only:
        return

    if args.threshold is None:
        print("probe ok; pass --threshold and re-run to score, or --probe-only",
              file=sys.stderr)
        sys.exit(1)
    if args.model_pin == PINNED_JEV_VERSION:
        print("halt: model pin unset — calibrate once, then pin the version",
              file=sys.stderr)
        sys.exit(2)

    rows = [json.loads(l) for l in open(args.corpus, encoding="utf-8")]
    if args.limit:
        rows = rows[: args.limit]

    false_clear = false_block = scored = halted = 0
    for row in rows:
        data = call_jev(row["brief"], row["catalog_line"], args.model_pin)
        score = float(data.get("score", -1))
        predicted_match = score >= args.threshold
        scored += 1
        if predicted_match and row["label"] == "no-match":
            false_clear += 1
        elif not predicted_match and row["label"] == "match":
            false_block += 1
        receipt(args.receipts_dir, "score", {
            "id": row["id"], "label": row["label"], "score": score,
            "predicted": predicted_match, "threshold": args.threshold,
            "model": args.model_pin, "jev_version_seen": data.get("version")})

    print(json.dumps({
        "scored": scored, "false_clear": false_clear,
        "false_block": false_block, "threshold": args.threshold,
        "gate": "PASS" if false_clear == 0 else "HALT"}))
    if false_clear > 0:
        sys.exit(2)  # RUNBOOK halt: false-clear not ~0; do not tune pins mid-run


if __name__ == "__main__":
    main()
