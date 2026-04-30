#!/usr/bin/env python3
"""Push source_url / source_excerpt from an enriched JSON to production.

Usage:
    ADMIN_API_KEY=xxx .venv/bin/python scripts/push_sources_to_prod.py \
        [data/verification/enriched_2026-04-20.json] \
        [--api-url https://quiz-agent-api.fly.dev]
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "enriched_file",
        nargs="?",
        default="data/verification/enriched_2026-04-20.json",
    )
    parser.add_argument("--api-url", default="https://quiz-agent-api.fly.dev")
    args = parser.parse_args()

    admin_key = os.environ.get("ADMIN_API_KEY")
    if not admin_key:
        print("ERROR: set ADMIN_API_KEY env var", file=sys.stderr)
        return 1

    with open(args.enriched_file) as f:
        data = json.load(f)
    questions = data["questions"] if isinstance(data, dict) else data

    items = [
        {
            "id": q["id"],
            "source_url": q.get("source_url"),
            "source_excerpt": q.get("source_excerpt"),
        }
        for q in questions
        if q.get("source_url")
    ]
    print(f"Sending {len(items)} items to {args.api_url}")

    req = urllib.request.Request(
        f"{args.api_url.rstrip('/')}/api/v1/admin/questions/backfill-sources",
        data=json.dumps({"items": items}).encode(),
        headers={"Content-Type": "application/json", "X-Admin-Key": admin_key},
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(req, timeout=60)
        print(resp.read().decode())
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
