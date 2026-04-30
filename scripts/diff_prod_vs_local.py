#!/usr/bin/env python3
"""Diff local ChromaDB vs production questions by ID.

Prints:
  - counts in each side
  - IDs only in local (missing from prod)
  - IDs only in prod (missing from local)
  - IDs in both but with different source_url status

Usage:
    ADMIN_API_KEY=xxx .venv/bin/python scripts/diff_prod_vs_local.py
"""

import json
import os
import sys
import urllib.request

sys.path.insert(0, "packages/shared")
from quiz_shared.database.chroma_client import ChromaDBClient


def main() -> int:
    admin_key = os.environ.get("ADMIN_API_KEY")
    if not admin_key:
        print("ERROR: set ADMIN_API_KEY", file=sys.stderr)
        return 1

    # Local
    client = ChromaDBClient(
        collection_name="quiz_questions",
        persist_directory="./chroma_data",
    )
    raw = client.collection.get(include=["metadatas"])
    local = {}
    for i, qid in enumerate(raw["ids"]):
        meta = raw["metadatas"][i] or {}
        local[qid] = {
            "review_status": meta.get("review_status"),
            "has_source": bool(meta.get("source_url")),
            "topic": meta.get("topic"),
            "image_subtype": meta.get("image_subtype"),
        }

    # Production
    req = urllib.request.Request(
        "https://quiz-agent-api.fly.dev/api/v1/admin/questions?limit=2000",
        headers={"X-Admin-Key": admin_key},
    )
    resp = urllib.request.urlopen(req, timeout=60)
    data = json.loads(resp.read().decode())
    prod_items = data.get("questions", [])
    prod_ids = {q["id"] for q in prod_items}

    print(f"Local total: {len(local)}")
    print(f"Prod total: {len(prod_items)}")
    print()

    only_local = set(local) - prod_ids
    only_prod = prod_ids - set(local)
    print(f"Only in LOCAL: {len(only_local)}")
    print(f"Only in PROD:  {len(only_prod)}")
    print()

    # Focus: image questions on each side
    local_images = [qid for qid, m in local.items() if qid.startswith("q_img_")]
    prod_image_ids = [qid for qid in prod_ids if qid.startswith("q_img_")]
    print(f"Local image questions (q_img_*): {len(local_images)}")
    print(f"Prod image questions (q_img_*):  {len(prod_image_ids)}")
    print()

    # Show prod IDs we've never seen locally (sampled)
    if only_prod:
        print("Sample of prod-only IDs:")
        for qid in list(only_prod)[:10]:
            q = next((x for x in prod_items if x["id"] == qid), {})
            print(f"  [{qid}] topic={q.get('topic')} type={q.get('type')} q={q.get('question','')[:60]}")

    # Prod image-like questions
    prod_images_with_meta = [q for q in prod_items if q["id"].startswith("q_img_")]
    if prod_images_with_meta:
        print(f"\nProd image questions present ({len(prod_images_with_meta)}):")
        for q in prod_images_with_meta[:10]:
            print(f"  [{q['id']}] {q.get('question','')[:70]}")
    else:
        print("\nProd has NO q_img_* questions — they've never been imported to prod.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
