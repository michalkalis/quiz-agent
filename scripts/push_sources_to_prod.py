#!/usr/bin/env python3
"""Push source_url / source_excerpt from enriched JSON(s) to production.

Accepts one or more enriched files; merges to one POST so we don't trip the
admin endpoint's 5/minute rate limit. Last-writer-wins per ID — pass files
in chronological order so newer enriched data overrides older.

Usage:
    ADMIN_API_KEY=xxx .venv/bin/python scripts/push_sources_to_prod.py \
        [data/verification/enriched_*.json] \
        [--api-url https://quiz-agent-api.fly.dev]
"""

import argparse
import glob
import json
import os
import sys
import urllib.error
import urllib.request


def _load(path: str) -> list[dict]:
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, dict) and "questions" in data:
        return data["questions"]
    if isinstance(data, dict) and "corrections" in data:
        return data["corrections"]
    if isinstance(data, dict) and "items" in data:
        return data["items"]
    if isinstance(data, list):
        return data
    print(f"WARN: unrecognized JSON shape in {path}; skipping", file=sys.stderr)
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "enriched_files",
        nargs="*",
        default=["data/verification/enriched_2026-04-20.json"],
        help="One or more enriched JSON files (globs OK)",
    )
    parser.add_argument("--api-url", default="https://quiz-agent-api.fly.dev")
    args = parser.parse_args()

    admin_key = os.environ.get("ADMIN_API_KEY")
    if not admin_key:
        print("ERROR: set ADMIN_API_KEY env var", file=sys.stderr)
        return 1

    paths: list[str] = []
    for pat in args.enriched_files:
        expanded = sorted(glob.glob(pat)) if any(c in pat for c in "*?[") else [pat]
        paths.extend(expanded)
    if not paths:
        print("ERROR: no input files", file=sys.stderr)
        return 1

    merged: dict[str, dict] = {}
    for p in paths:
        loaded = _load(p)
        before = len(merged)
        for q in loaded:
            qid = q.get("id")
            if not qid or not q.get("source_url"):
                continue
            existing = merged.get(qid, {"id": qid})
            existing["source_url"] = q["source_url"]
            if q.get("source_excerpt"):
                existing["source_excerpt"] = q["source_excerpt"]
            merged[qid] = existing
        print(f"  {p}: {len(loaded)} rows → +{len(merged) - before} new IDs (running total {len(merged)})")

    items = list(merged.values())
    print(f"\nSending {len(items)} unique items to {args.api_url}")

    req = urllib.request.Request(
        f"{args.api_url.rstrip('/')}/api/v1/admin/questions/backfill-sources",
        data=json.dumps({"items": items}).encode(),
        headers={"Content-Type": "application/json", "X-Admin-Key": admin_key},
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        print(resp.read().decode())
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
