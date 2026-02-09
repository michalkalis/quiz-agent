"""Backfill missing metadata fields in ChromaDB questions.

Production ChromaDB has questions stored before `type`, `review_status`, and
`language_dependent` metadata fields were added. ChromaDB's WHERE clause
silently excludes documents that lack a filtered field, so the quiz retriever
returns zero matches even though 69 questions exist.

This script reads raw ChromaDB data (bypassing the Question model defaults)
and upserts missing fields with sensible defaults:
  - type           → "text"
  - review_status  → "approved"
  - language_dependent → False

Usage:
    # Dry run (preview what would change)
    python scripts/backfill_chroma_metadata.py --dry-run

    # Apply changes
    python scripts/backfill_chroma_metadata.py

    # Custom ChromaDB path (e.g. on Fly.io)
    python scripts/backfill_chroma_metadata.py --chroma-path /data/chroma_data
"""

import argparse
import sys
from pathlib import Path

# Add shared package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packages" / "shared"))
from quiz_shared.database.chroma_client import ChromaDBClient


# Fields to backfill and their default values
DEFAULTS = {
    "type": "text",
    "review_status": "approved",
    "language_dependent": False,
}


def main():
    parser = argparse.ArgumentParser(
        description="Backfill missing metadata fields in ChromaDB questions"
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

    print(f"Connecting to ChromaDB at: {args.chroma_path}")
    chroma = ChromaDBClient(persist_directory=args.chroma_path)

    # Read raw data from ChromaDB to see actual stored metadata
    # (bypassing _metadata_to_question which applies defaults in Python)
    raw = chroma.collection.get(include=["metadatas", "documents", "embeddings"])
    ids = raw["ids"]
    metadatas = raw["metadatas"]
    documents = raw["documents"]
    embeddings = raw.get("embeddings")

    print(f"Found {len(ids)} questions in database\n")

    if not ids:
        print("No questions found. Nothing to do.")
        return

    updated_count = 0
    skipped_count = 0

    for i, qid in enumerate(ids):
        meta = metadatas[i]
        fields_to_add = {}

        for field, default in DEFAULTS.items():
            if field not in meta:
                fields_to_add[field] = default

        if not fields_to_add:
            skipped_count += 1
            continue

        updated_count += 1
        question_preview = (documents[i] or "")[:80]
        print(f"  [{qid}] {question_preview}...")
        print(f"    Adding: {fields_to_add}")

        if not args.dry_run:
            updated_meta = {**meta, **fields_to_add}
            upsert_kwargs = {
                "ids": [qid],
                "metadatas": [updated_meta],
                "documents": [documents[i]],
            }
            # Preserve existing embeddings if available
            if embeddings is not None and i < len(embeddings) and embeddings[i] is not None:
                upsert_kwargs["embeddings"] = [embeddings[i]]

            chroma.collection.upsert(**upsert_kwargs)

    # Summary
    print(f"\n{'='*60}")
    print(f"Backfill Summary {'(DRY RUN)' if args.dry_run else ''}")
    print(f"{'='*60}")
    print(f"Total questions:  {len(ids)}")
    print(f"Updated:          {updated_count}")
    print(f"Already complete: {skipped_count}")

    if args.dry_run and updated_count > 0:
        print(f"\nThis was a dry run. Run without --dry-run to apply changes.")
    elif updated_count > 0:
        print(f"\nDatabase updated successfully.")
    else:
        print(f"\nAll questions already have required metadata. No changes needed.")


if __name__ == "__main__":
    main()
