#!/usr/bin/env python3
"""score-corpus.py — thin match/no-match scorer for the toolsmith Jev seat.

Sibling of the auditing-agent-harnesses context-triage.py DISCIPLINE, not a
port of the script. The audit scorer's taxonomy (benign/pipeline-shaped) and
gate (>= 0.75 AND non-benign on pipeline-shaped) encode audit failure costs.
Here the labels are match/no-match and the error asymmetry differs:

  false CLEAR (says "near-match" when none exists) => a saved round trip that
      runs the wrong tool or hides a catalog gap  -> the failure Gate 2 bars;
  false BLOCK => one wasted toolsmith round trip  -> today's baseline cost.

Shared discipline kept from the audit sibling:
  - unauthenticated GET probe before any scored call (any HTTP response =
    reachable; mapping verified from context-triage.py v1.2.x source);
  - every call writes a receipt line with the RESOLVED model version
    (response "model" field) stamped alongside the requested pin;
  - a measured score band is printed before any threshold is chosen;
  - the model is pinned; a version drift halts rather than re-calibrates.

NOT transferred from the audit sibling:
  - QUESTIONS are authored here for match/no-match; the audit questions'
    benign/pipeline-shaped taxonomy is deliberately not carried over;
  - the 0.75 threshold does NOT transfer (measured on audit questions).
    Gate 2's baseline must MEASURE a fresh threshold; see RUNBOOK.

Not runnable by accident: it refuses without an explicit --go, performs no
network call until the egress probe succeeds, and exits 2 on any halt
condition. Secrets: the key is read from TYPESAFE_API_KEY, never printed,
never logged.

Protocol (mapped from context-triage.py v1.2.x):
  POST {TYPESAFE_BASE_URL:-https://api.typesafe.ai/v1/systemone}
  headers: Authorization Bearer $TYPESAFE_API_KEY, Content-Type json
  body:    {"state": <text>, "model": <model>, "questions": <questions>}
  resp:    r["answers"]["classification"]["choice"] / ["confidence"];
           r["model"] = resolved version -> receipts
  retry:   3 attempts on 429/500/502/503, backoff delay*4*(attempt+1)

Usage:
  score-corpus.py --probe-only --go                # egress check, no spend
  score-corpus.py --band --go --limit N            # measure confidence band
  score-corpus.py --threshold T --go               # scored run at threshold T
Exit codes: 0 ok, 1 usage, 2 halt condition (RUNBOOK), 3 probe failure.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

# Gate 2 must measure a fresh threshold from the confidence band; nothing
# here defaults to the audit sibling's 0.75 (see module docstring).
ENDPOINT = os.environ.get("TYPESAFE_BASE_URL", "https://api.typesafe.ai/v1/systemone")
DEFAULT_MODEL = "jev-latest"
RETRYABLE = {429, 500, 502, 503}
MAX_ATTEMPTS = 3
BASE_DELAY = 0.25  # seconds; delay*4*(attempt+1) per the mapped retry rule

# Authored for match/no-match triage. These are OURS; the audit script's
# benign/pipeline-shaped questions are intentionally absent.
QUESTIONS = [
    "Does the catalog line describe a tool that, as written, performs the "
    "action the brief asks for?",
    "Does the brief ask for the opposite direction or the inverse "
    "transformation of what the tool does?",
    "Is the tool's purpose merely adjacent to the brief — same domain, "
    "different action or different target?",
    "If you ran the tool as its catalog line describes, would the brief's "
    "underlying need be satisfied?",
]


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def receipt(receipts_dir, kind, payload):
    os.makedirs(receipts_dir, exist_ok=True)
    line = json.dumps({"ts": now_iso(), "kind": kind, **payload}, sort_keys=True)
    with open(os.path.join(receipts_dir, "scorer-receipts.jsonl"), "a",
              encoding="utf-8") as fh:
        fh.write(line + "\n")
    print(line)  # stdout is a run log, not a receipt; receipts are the file


def egress_probe(timeout=8):
    """Unauthenticated GET probe; any HTTP response = reachable. Never
    sends the key."""
    req = urllib.request.Request("https://api.typesafe.ai/", method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return True, f"http_{resp.status}"
    except urllib.error.HTTPError as exc:
        # a 4xx/5xx still proves DNS+TLS+host are up; 404 on / is expected
        return True, f"http_{exc.code}"
    except Exception as exc:  # noqa: BLE001 - probe reports, does not traceback
        return False, type(exc).__name__


def call_jev(state_text, model, receipts_dir):
    """One scored call. Returns the parsed response dict. Retries per the
    mapped rule; the resolved version (response 'model') goes to receipts."""
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not key:
        print("halt: TYPESAFE_API_KEY absent", file=sys.stderr)
        sys.exit(2)  # presence-only failure; never quotes the value
    body = json.dumps({
        "state": state_text,
        "model": model,
        "questions": QUESTIONS,
    }).encode()
    last = None
    for attempt in range(MAX_ATTEMPTS):
        req = urllib.request.Request(
            ENDPOINT, data=body,
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + key})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.load(resp)
            receipt(receipts_dir, "call", {
                "attempt": attempt + 1, "model_requested": model,
                "model_resolved": data.get("model")})
            return data
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code in RETRYABLE and attempt < MAX_ATTEMPTS - 1:
                time.sleep(BASE_DELAY * 4 * (attempt + 1))
                continue
            raise
    raise last  # pragma: no cover


def score_one(row, model, receipts_dir):
    """Returns (choice, confidence, resolved_version)."""
    state_text = ("Brief: " + row["brief"] + "\n\n"
                  "Catalog line: " + row["catalog_line"])
    data = call_jev(state_text, model, receipts_dir)
    cls = data["answers"]["classification"]
    return cls["choice"], float(cls["confidence"]), data.get("model")


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--corpus", default="preflight/corpus.jsonl")
    ap.add_argument("--threshold", type=float,
                    help="confidence threshold ABOVE which a 'match' choice "
                         "clears (escalates the toolsmith below it). Must be "
                         "measured at Gate 2, never assumed.")
    ap.add_argument("--band", action="store_true",
                    help="measure the confidence band only (no threshold)")
    ap.add_argument("--probe-only", action="store_true")
    ap.add_argument("--limit", type=int, help="score only the first N rows")
    ap.add_argument("--receipts-dir", default=os.path.expanduser(
        "~/code/toolsmith-preflight/receipts"))
    ap.add_argument("--model", default=os.environ.get(
        "TYPESAFE_MODEL", DEFAULT_MODEL))
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
    if args.band == (args.threshold is None):
        print("choose exactly one of --band or --threshold", file=sys.stderr)
        sys.exit(1)

    rows = [json.loads(l) for l in open(args.corpus, encoding="utf-8")]
    if args.limit:
        rows = rows[: args.limit]

    false_clear = false_block = 0
    conf = []
    versions = set()
    for i, row in enumerate(rows):
        choice, confidence, resolved = score_one(row, args.model,
                                                 args.receipts_dir)
        conf.append(confidence)
        versions.add(resolved)
        receipt(args.receipts_dir, "score", {
            "id": row["id"], "label": row["label"], "choice": choice,
            "confidence": confidence, "model_resolved": resolved})
        if args.band:
            continue
        predicted_match = choice == "match" and confidence >= args.threshold
        if predicted_match and row["label"] == "no-match":
            false_clear += 1
        elif not predicted_match and row["label"] == "match":
            false_block += 1

    resolved_seen = sorted(v for v in versions if v)
    if len(resolved_seen) > 1:
        print(f"halt: multiple model versions resolved {resolved_seen}",
              file=sys.stderr)
        sys.exit(2)

    summary = {
        "scored": len(rows), "confidence_min": min(conf),
        "confidence_max": max(conf), "model_resolved": resolved_seen,
    }
    if args.band:
        # Band printout: the operator picks the threshold FROM this band and
        # records it + the confirm-band mechanics in RUNBOOK before the
        # scored run. Nothing here picks one.
        print(json.dumps({"band": summary,
                          "note": "pick threshold from this band; record in "
                                  "RUNBOOK before any scored run"}))
        return
    summary.update({"threshold": args.threshold,
                    "false_clear": false_clear, "false_block": false_block,
                    "gate": "PASS" if false_clear == 0 else "HALT"})
    print(json.dumps(summary))
    if false_clear > 0:
        sys.exit(2)  # RUNBOOK halt: false-clear not ~0; do not tune pins mid-run


if __name__ == "__main__":
    main()
