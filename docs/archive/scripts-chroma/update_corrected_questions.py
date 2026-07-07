#!/usr/bin/env python3
"""Update corrected questions in ChromaDB after verification.

Matches questions by document text (substring), then updates:
- Question text (document) if reworded
- Metadata fields (correct_answer, alternative_answers, source_url, source_excerpt)

Usage:
    # Dry run
    python scripts/update_corrected_questions.py --dry-run

    # Apply changes
    python scripts/update_corrected_questions.py
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packages" / "shared"))
from quiz_shared.database.chroma_client import ChromaDBClient


# Define corrections: (search_text_in_old_question, batch_file, enriched_file)
BATCH_FILES = [
    "data/generated/claude_batch_005.json",
    "data/generated/claude_batch_013.json",
    "data/generated/claude_batch_016.json",
]

ENRICHED_FILES = [
    "data/verification/enriched_2026-03-12_batch005.json",
    "data/verification/enriched_2026-03-12_batch013.json",
    "data/verification/enriched_2026-03-12_batch016.json",
]


def load_questions(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and "questions" in data:
        return data["questions"]
    return []


def find_chroma_id(question_text, chroma_docs, chroma_ids):
    """Find ChromaDB ID by matching a unique substring of the question."""
    # Try exact match first
    for i, doc in enumerate(chroma_docs):
        if doc and doc.strip() == question_text.strip():
            return chroma_ids[i], i

    # Try substring match on first 60 chars
    prefix = question_text[:60]
    matches = [(chroma_ids[i], i) for i, doc in enumerate(chroma_docs) if doc and prefix in doc]
    if len(matches) == 1:
        return matches[0]

    # Try longer substring
    prefix = question_text[:100]
    matches = [(chroma_ids[i], i) for i, doc in enumerate(chroma_docs) if doc and prefix in doc]
    if len(matches) == 1:
        return matches[0]

    return None, None


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--chroma-path", default="./chroma_data")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    chroma = ChromaDBClient(persist_directory=args.chroma_path)
    raw = chroma.collection.get(include=["metadatas", "documents", "embeddings"])
    chroma_ids = raw["ids"]
    chroma_docs = raw["documents"]
    chroma_metas = raw["metadatas"]
    chroma_embeds = raw.get("embeddings")
    has_embeddings = chroma_embeds is not None and len(chroma_embeds) > 0

    print(f"ChromaDB: {len(chroma_ids)} questions loaded")

    # Build source data lookup from enriched files (match by question text)
    source_by_question = {}
    for efile in ENRICHED_FILES:
        p = Path(efile)
        if not p.exists():
            print(f"  WARN: {efile} not found, skipping source data")
            continue
        enriched = load_questions(efile)
        for q in enriched:
            if q.get("source_url"):
                key = q["question"][:80]
                source_by_question[key] = {
                    "source_url": q.get("source_url"),
                    "source_excerpt": q.get("source_excerpt"),
                }

    updated = 0
    source_updated = 0
    not_found = 0

    for bfile in BATCH_FILES:
        p = Path(bfile)
        if not p.exists():
            print(f"  WARN: {bfile} not found")
            continue

        batch_qs = load_questions(bfile)
        batch_name = Path(bfile).stem
        print(f"\nProcessing {batch_name} ({len(batch_qs)} questions)...")

        for q in batch_qs:
            q_text = q["question"]

            # Find in ChromaDB — try the corrected text first, then common substrings
            cid, cidx = find_chroma_id(q_text, chroma_docs, chroma_ids)

            if cid is None:
                # For rewritten questions, try matching on answer + topic combo
                # or unique keywords from the original question
                keywords_to_try = []
                if "frog" in q_text.lower():
                    keywords_to_try = ["frog survives winter"]
                elif "goalkeeper" in q_text.lower():
                    keywords_to_try = ["goalkeeper", "longest goal"]
                elif "SpaceX" in q_text:
                    keywords_to_try = ["SpaceX lands its rocket"]
                elif "Apollo 11" in q_text:
                    keywords_to_try = ["Apollo 11 moon landing guidance"]
                elif "Eddie Eagan" in q_text or "Summer and Winter Games" in q_text:
                    keywords_to_try = ["gold medals in both the Summer and Winter"]
                elif "Fencing, athletics, swimming" in q_text:
                    keywords_to_try = ["fencing, swimming, horse riding"]
                elif "iPhone" in q_text and ("copy" in q_text.lower() or "text editing" in q_text.lower()):
                    keywords_to_try = ["first iPhone launched in 2007"]
                elif "Victor Hugo" in q_text:
                    keywords_to_try = ["Victor Hugo", "shortest letter"]
                elif "Wood Wide Web" in q.get("correct_answer", ""):
                    keywords_to_try = ["underground fungal"]
                elif "ice crystals forming between" in q_text:
                    keywords_to_try = ["frog survives winter"]

                for kw in keywords_to_try:
                    matches = [(chroma_ids[i], i) for i, doc in enumerate(chroma_docs) if doc and kw in doc]
                    if len(matches) == 1:
                        cid, cidx = matches[0]
                        break

            if cid is None:
                not_found += 1
                print(f"  NOT FOUND: {q_text[:70]}...")
                continue

            meta = chroma_metas[cidx].copy()
            old_doc = chroma_docs[cidx]
            changes = []

            # Update document (question text) if different
            new_doc = old_doc
            if old_doc.strip() != q_text.strip():
                new_doc = q_text
                changes.append(f"question text updated")

            # Update answer
            if meta.get("correct_answer") != q["correct_answer"]:
                changes.append(f"answer: '{meta.get('correct_answer')}' → '{q['correct_answer']}'")
                meta["correct_answer"] = q["correct_answer"]

            # Update alternative_answers
            old_alts = meta.get("alternative_answers", "")
            new_alts = json.dumps(q.get("alternative_answers", []))
            if old_alts != new_alts:
                meta["alternative_answers"] = new_alts
                changes.append("alternative_answers updated")

            # Update source data from enriched files
            q_key = q_text[:80]
            if q_key in source_by_question:
                src = source_by_question[q_key]
                if src.get("source_url") and meta.get("source_url") != src["source_url"]:
                    meta["source_url"] = src["source_url"]
                    changes.append(f"source_url added")
                    source_updated += 1
                if src.get("source_excerpt") and meta.get("source_excerpt") != src["source_excerpt"]:
                    meta["source_excerpt"] = src["source_excerpt"]

            if not changes:
                continue

            updated += 1
            print(f"  [{cid}] {changes}")

            if not args.dry_run:
                upsert_kwargs = {
                    "ids": [cid],
                    "metadatas": [meta],
                    "documents": [new_doc],
                }
                if has_embeddings and chroma_embeds[cidx] is not None:
                    upsert_kwargs["embeddings"] = [chroma_embeds[cidx]]
                chroma.collection.upsert(**upsert_kwargs)

    print(f"\n{'='*60}")
    print(f"Update Summary {'(DRY RUN)' if args.dry_run else ''}")
    print(f"{'='*60}")
    print(f"Questions processed: {sum(len(load_questions(f)) for f in BATCH_FILES if Path(f).exists())}")
    print(f"Updated:            {updated}")
    print(f"Sources added:      {source_updated}")
    print(f"Not found:          {not_found}")

    if args.dry_run and updated > 0:
        print(f"\nDry run. Run without --dry-run to apply.")
    elif updated > 0:
        print(f"\nDatabase updated.")
    else:
        print(f"\nNo changes needed.")


if __name__ == "__main__":
    main()
