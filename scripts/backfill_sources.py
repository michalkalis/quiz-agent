#!/usr/bin/env python3
"""Backfill source_url and source_excerpt into ChromaDB from enriched JSON.

Reads an enriched questions JSON file (produced by /verify-questions) and
updates ChromaDB metadata for questions that have source data.

Usage:
    # Dry run
    python scripts/backfill_sources.py data/verification/enriched_2025-01-15.json --dry-run

    # Apply changes
    python scripts/backfill_sources.py data/verification/enriched_2025-01-15.json

    # Custom ChromaDB path
    python scripts/backfill_sources.py enriched.json --chroma-path /data/chroma_data
"""

import argparse
import json
import sys
from pathlib import Path

# Add shared package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packages" / "shared"))
from quiz_shared.database.chroma_client import ChromaDBClient


def main():
    parser = argparse.ArgumentParser(
        description="Backfill source_url and source_excerpt into ChromaDB"
    )
    parser.add_argument(
        "enriched_file",
        help="Path to enriched questions JSON file",
    )
    parser.add_argument(
        "--chroma-path",
        default="./chroma_data",
        help="Path to ChromaDB data directory (default: ./chroma_data)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview changes without updating the database",
    )
    args = parser.parse_args()

    # Load enriched questions
    enriched_path = Path(args.enriched_file)
    if not enriched_path.exists():
        print(f"ERROR: File not found: {enriched_path}")
        sys.exit(1)

    with open(enriched_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    # Handle both formats: flat array or {"questions": [...]}
    if isinstance(data, list):
        questions = data
    elif isinstance(data, dict) and "questions" in data:
        questions = data["questions"]
    else:
        print("ERROR: Unrecognized JSON format. Expected array or {questions: [...]}")
        sys.exit(1)

    # Filter to questions with source data
    sourced = [
        q for q in questions
        if q.get("source_url") or q.get("source_excerpt")
    ]

    if not sourced:
        print("No questions with source data found. Nothing to update.")
        return

    print(f"Found {len(sourced)} questions with source data (out of {len(questions)} total)")

    # Connect to ChromaDB
    print(f"Connecting to ChromaDB at: {args.chroma_path}")
    chroma = ChromaDBClient(persist_directory=args.chroma_path)

    # Read raw data to update metadata directly (faster than full Question round-trip)
    raw = chroma.collection.get(include=["metadatas", "documents", "embeddings"])
    raw_by_id = {}
    embeddings = raw.get("embeddings")
    has_embeddings = embeddings is not None and len(embeddings) > 0
    for i, qid in enumerate(raw["ids"]):
        raw_by_id[qid] = {
            "metadata": raw["metadatas"][i],
            "document": raw["documents"][i],
            "embedding": embeddings[i] if has_embeddings and i < len(embeddings) else None,
        }

    updated_count = 0
    skipped_count = 0
    not_found_count = 0

    for q in sourced:
        qid = q.get("id")
        if not qid:
            skipped_count += 1
            continue

        if qid not in raw_by_id:
            not_found_count += 1
            print(f"  SKIP [{qid}] not found in ChromaDB")
            continue

        existing = raw_by_id[qid]
        meta = existing["metadata"]
        changed = False

        if q.get("source_url") and meta.get("source_url") != q["source_url"]:
            meta["source_url"] = q["source_url"]
            changed = True
        if q.get("source_excerpt") and meta.get("source_excerpt") != q["source_excerpt"]:
            meta["source_excerpt"] = q["source_excerpt"]
            changed = True

        if not changed:
            skipped_count += 1
            continue

        updated_count += 1
        question_preview = (existing["document"] or "")[:80]
        print(f"  [{qid}] {question_preview}...")
        print(f"    source_url: {q.get('source_url', 'N/A')[:60]}")

        if not args.dry_run:
            upsert_kwargs = {
                "ids": [qid],
                "metadatas": [meta],
                "documents": [existing["document"]],
            }
            if existing["embedding"] is not None:
                upsert_kwargs["embeddings"] = [existing["embedding"]]

            chroma.collection.upsert(**upsert_kwargs)

    # Summary
    print(f"\n{'='*60}")
    print(f"Source Backfill Summary {'(DRY RUN)' if args.dry_run else ''}")
    print(f"{'='*60}")
    print(f"Questions with sources:  {len(sourced)}")
    print(f"Updated:                {updated_count}")
    print(f"Already up-to-date:     {skipped_count}")
    print(f"Not found in ChromaDB:  {not_found_count}")

    if args.dry_run and updated_count > 0:
        print(f"\nThis was a dry run. Run without --dry-run to apply changes.")
    elif updated_count > 0:
        print(f"\nDatabase updated successfully.")
    else:
        print(f"\nNo changes needed.")


if __name__ == "__main__":
    main()
