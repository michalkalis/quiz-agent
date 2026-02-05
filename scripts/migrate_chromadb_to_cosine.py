"""Migrate ChromaDB collection from L2 (default) to cosine distance.

This script:
1. Exports all questions (with cached embeddings) from the existing collection
2. Saves a JSON backup to chroma_data_backup.json
3. Deletes the old collection
4. Creates a new collection with hnsw:space=cosine
5. Re-imports all questions (reuses cached embeddings, no OpenAI API calls)
6. Verifies the count matches

Usage:
    python scripts/migrate_chromadb_to_cosine.py [--chroma-path ./chroma_data]
"""

import argparse
import json
import sys
from pathlib import Path

import chromadb


COLLECTION_NAME = "quiz_questions"
BACKUP_FILENAME = "chroma_data_backup.json"


def export_collection(collection) -> dict:
    """Export all data from a ChromaDB collection."""
    results = collection.get(
        include=["embeddings", "documents", "metadatas"]
    )

    count = len(results["ids"])
    print(f"Exported {count} questions from collection")
    print(f"  Distance metric: {collection.metadata}")

    return {
        "ids": results["ids"],
        "documents": results["documents"],
        "metadatas": results["metadatas"],
        "embeddings": results["embeddings"],
    }


def save_backup(data: dict, backup_path: Path) -> None:
    """Save exported data as JSON backup."""
    # Embeddings are lists of floats - JSON serializable as-is
    with open(backup_path, "w") as f:
        json.dump(data, f, indent=2, default=str)
    size_mb = backup_path.stat().st_size / (1024 * 1024)
    print(f"Backup saved to {backup_path} ({size_mb:.1f} MB)")


def import_collection(client, data: dict) -> None:
    """Create new cosine collection and import data."""
    collection = client.create_collection(
        name=COLLECTION_NAME,
        metadata={
            "description": "Pub quiz questions with embeddings",
            "hnsw:space": "cosine",
        },
    )
    print(f"Created new collection with cosine distance")

    count = len(data["ids"])
    if count == 0:
        print("No questions to import")
        return collection

    # ChromaDB supports batch add
    BATCH_SIZE = 100
    for start in range(0, count, BATCH_SIZE):
        end = min(start + BATCH_SIZE, count)
        collection.add(
            ids=data["ids"][start:end],
            documents=data["documents"][start:end],
            metadatas=data["metadatas"][start:end],
            embeddings=data["embeddings"][start:end],
        )
        print(f"  Imported questions {start + 1}-{end}")

    return collection


def verify(collection, expected_count: int) -> bool:
    """Verify migration succeeded."""
    actual_count = collection.count()
    metadata = collection.metadata

    print(f"\nVerification:")
    print(f"  Expected count: {expected_count}")
    print(f"  Actual count:   {actual_count}")
    print(f"  Distance metric: {metadata.get('hnsw:space', 'L2 (default)')}")

    if actual_count != expected_count:
        print("  FAILED: Count mismatch!")
        return False

    if metadata.get("hnsw:space") != "cosine":
        print("  FAILED: Distance metric not set to cosine!")
        return False

    print("  PASSED: Migration successful")
    return True


def main():
    parser = argparse.ArgumentParser(description="Migrate ChromaDB to cosine distance")
    parser.add_argument(
        "--chroma-path",
        default="./chroma_data",
        help="Path to ChromaDB persistent storage (default: ./chroma_data)",
    )
    parser.add_argument(
        "--backup-path",
        default=None,
        help="Path for JSON backup file (default: <chroma-path>/chroma_data_backup.json)",
    )
    args = parser.parse_args()

    chroma_path = Path(args.chroma_path)
    backup_path = Path(args.backup_path) if args.backup_path else chroma_path / BACKUP_FILENAME

    if not chroma_path.exists():
        print(f"ChromaDB path not found: {chroma_path}")
        sys.exit(1)

    # Connect to ChromaDB
    client = chromadb.PersistentClient(path=str(chroma_path))

    # Check if collection exists
    try:
        collection = client.get_collection(COLLECTION_NAME)
    except Exception:
        print(f"Collection '{COLLECTION_NAME}' not found. Nothing to migrate.")
        sys.exit(0)

    current_space = collection.metadata.get("hnsw:space", "L2 (default)")
    print(f"Current distance metric: {current_space}")

    if current_space == "cosine":
        print("Collection already uses cosine distance. No migration needed.")
        sys.exit(0)

    # Step 1: Export
    print("\n--- Step 1: Export ---")
    data = export_collection(collection)
    expected_count = len(data["ids"])

    if expected_count == 0:
        print("Collection is empty. Deleting and recreating with cosine distance.")
        client.delete_collection(COLLECTION_NAME)
        import_collection(client, data)
        print("Done.")
        sys.exit(0)

    # Step 2: Backup
    print("\n--- Step 2: Backup ---")
    save_backup(data, backup_path)

    # Step 3: Delete old collection
    print("\n--- Step 3: Delete old collection ---")
    client.delete_collection(COLLECTION_NAME)
    print(f"Deleted collection '{COLLECTION_NAME}'")

    # Step 4: Create new collection and import
    print("\n--- Step 4: Create new collection with cosine distance ---")
    new_collection = import_collection(client, data)

    # Step 5: Verify
    print("\n--- Step 5: Verify ---")
    success = verify(new_collection, expected_count)

    if not success:
        print("\nMigration FAILED. Restore from backup:")
        print(f"  Backup file: {backup_path}")
        sys.exit(1)

    print(f"\nMigration complete. Backup at: {backup_path}")


if __name__ == "__main__":
    main()
