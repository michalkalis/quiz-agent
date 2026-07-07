#!/usr/bin/env python3
"""Backfill source_url and source_excerpt into ChromaDB from enriched JSON.

Reads one or more enriched questions JSON files (produced by /verify-questions)
and updates ChromaDB metadata for questions that have source data.

Pipeline split (do not collapse):
  /verify-questions skill  →  enriched_*.json  →  this script  →  ChromaDB
  (calls FactVerifier on    (verdict + source   (writeback only,    (local /
   :8003)                    fields)             no network calls)   prod)

Why we write via `chroma.collection.upsert(...)` and not `QuestionStore.upsert`:
  - We're patching two metadata fields on existing rows. Routing through
    `QuestionStore.upsert` would re-embed every question (OpenAI cost + risk
    of embedding drift on identical text).
  - The historical `ChromaDBClient.update_question` no-op bug (memory:
    project_chroma_update_bug) is unrelated — that was the legacy `add`-based
    write path, since fixed. The collection-level `upsert` here was always
    correct.

Usage:
    # Dry run on one file
    python scripts/backfill_sources.py data/verification/enriched_2026-04-20.json --dry-run

    # Merge multiple enriched files (idempotent, last-wins on duplicate IDs)
    python scripts/backfill_sources.py data/verification/enriched_*.json

    # Custom ChromaDB path
    python scripts/backfill_sources.py enriched.json --chroma-path /app/data/chroma
"""

import argparse
import json
import sys
from pathlib import Path

# Add shared package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packages" / "shared"))
from quiz_shared.database.chroma_client import ChromaDBClient


def _load_enriched(path: Path) -> list[dict]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and "questions" in data:
        return data["questions"]
    if isinstance(data, dict) and "items" in data:
        # push_sources_to_prod payload shape
        return data["items"]
    print(f"ERROR: Unrecognized JSON format in {path}. Expected list, "
          f"{{questions: [...]}}, or {{items: [...]}}.")
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Backfill source_url and source_excerpt into ChromaDB"
    )
    parser.add_argument(
        "enriched_files",
        nargs="+",
        help="One or more enriched questions JSON files",
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

    # Load + merge enriched questions across all input files. Last write wins
    # for a given ID (so newer enriched files override older ones — pass them
    # in chronological order).
    questions: list[dict] = []
    for fname in args.enriched_files:
        p = Path(fname)
        if not p.exists():
            print(f"ERROR: File not found: {p}")
            sys.exit(1)
        loaded = _load_enriched(p)
        questions.extend(loaded)
        print(f"Loaded {len(loaded):>4} questions from {p}")

    # Merge across files: last-writer-wins per ID. Without this, an ID that
    # appears in multiple enriched files would be counted as N "updates" in
    # one run, breaking the idempotency claim and inflating the summary.
    desired: dict[str, dict] = {}
    for q in questions:
        qid = q.get("id")
        if not qid:
            continue
        if not (q.get("source_url") or q.get("source_excerpt")):
            continue
        merged = desired.get(qid, {}).copy()
        if q.get("source_url"):
            merged["source_url"] = q["source_url"]
        if q.get("source_excerpt"):
            merged["source_excerpt"] = q["source_excerpt"]
        desired[qid] = merged

    if not desired:
        print("No questions with source data found. Nothing to update.")
        return

    print(f"Found {len(desired)} unique IDs with source data "
          f"(merged from {len(questions)} input rows)")

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

    for qid, want in sorted(desired.items()):
        if qid not in raw_by_id:
            not_found_count += 1
            print(f"  SKIP [{qid}] not found in ChromaDB")
            continue

        existing = raw_by_id[qid]
        meta = existing["metadata"]
        changed = False

        if "source_url" in want and meta.get("source_url") != want["source_url"]:
            meta["source_url"] = want["source_url"]
            changed = True
        if "source_excerpt" in want and meta.get("source_excerpt") != want["source_excerpt"]:
            meta["source_excerpt"] = want["source_excerpt"]
            changed = True

        if not changed:
            skipped_count += 1
            continue

        updated_count += 1
        question_preview = (existing["document"] or "")[:80]
        print(f"  [{qid}] {question_preview}...")
        print(f"    source_url: {(want.get('source_url') or 'N/A')[:60]}")

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
    print(f"Unique IDs with sources: {len(desired)}")
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
