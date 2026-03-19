#!/usr/bin/env python3
"""Prepare verified questions for production import.

Reads enriched + report file pairs from data/verification/,
filters to 'correct' and 'needs_review' verdicts, generates IDs
where missing, and outputs a single import-ready JSON file.

Usage:
    python scripts/prepare_import.py
    python scripts/prepare_import.py --include-needs-review false
    python scripts/prepare_import.py --output data/verification/import_ready.json
"""

import json
import hashlib
import glob
import argparse
from pathlib import Path
from collections import Counter


VERIFICATION_DIR = Path("data/verification")
OUTPUT_DEFAULT = VERIFICATION_DIR / "import_ready.json"

IMPORTABLE_VERDICTS = {"correct", "needs_review"}


def generate_id(question: dict) -> str:
    """Generate a stable ID from topic + question text hash."""
    topic = question.get("topic", "unknown").lower().replace(" ", "_")
    text_hash = hashlib.sha256(question["question"].encode()).hexdigest()[:12]
    return f"q_{topic}_{text_hash}"


def find_file_pairs() -> list[tuple[Path, Path]]:
    """Find matching enriched/report file pairs."""
    enriched_files = sorted(VERIFICATION_DIR.glob("enriched_*.json"))
    report_files = sorted(VERIFICATION_DIR.glob("report_*.json"))

    # Build lookup: suffix -> report path (e.g. "2026-03-18_batch001" -> path)
    report_lookup = {}
    for rp in report_files:
        suffix = rp.name.replace("report_", "").replace(".json", "")
        report_lookup[suffix] = rp

    pairs = []
    for ep in enriched_files:
        suffix = ep.name.replace("enriched_", "").replace(".json", "")
        if suffix in report_lookup:
            pairs.append((ep, report_lookup[suffix]))
        else:
            print(f"  WARNING: No report file for {ep.name}, skipping")

    return pairs


def build_verdict_map(report: dict) -> dict[str, dict]:
    """Map question text -> verdict info from a report file."""
    verdict_map = {}
    for q in report["questions"]:
        verdict_map[q["question"]] = {
            "verdict": q["verdict"],
            "suggested_fix": q.get("suggested_fix"),
            "notes": q.get("notes"),
        }
    return verdict_map


def prepare_import(include_needs_review: bool = True) -> list[dict]:
    """Process all file pairs and return import-ready questions."""
    pairs = find_file_pairs()
    print(f"Found {len(pairs)} enriched/report file pairs\n")

    all_questions = []
    verdict_counts = Counter()
    seen_texts = set()

    for enriched_path, report_path in pairs:
        with open(enriched_path) as f:
            enriched_raw = json.load(f)
        # Handle both formats: plain array or {"questions": [...]}
        enriched = enriched_raw if isinstance(enriched_raw, list) else enriched_raw.get("questions", [])
        with open(report_path) as f:
            report = json.load(f)

        verdict_map = build_verdict_map(report)
        batch_name = enriched_path.name
        imported = 0
        skipped = 0

        for question in enriched:
            q_text = question["question"]
            verdict_info = verdict_map.get(q_text)

            if not verdict_info:
                print(f"  WARNING: No verdict for question in {batch_name}: {q_text[:60]}...")
                skipped += 1
                continue

            verdict = verdict_info["verdict"]
            verdict_counts[verdict] += 1

            if verdict not in IMPORTABLE_VERDICTS:
                skipped += 1
                continue

            if not include_needs_review and verdict == "needs_review":
                skipped += 1
                continue

            # Deduplicate by question text
            if q_text in seen_texts:
                skipped += 1
                continue
            seen_texts.add(q_text)

            # Ensure ID exists
            if not question.get("id"):
                question["id"] = generate_id(question)

            # Mark review status based on verdict
            question["review_status"] = "approved" if verdict == "correct" else "needs_review"

            all_questions.append(question)
            imported += 1

        print(f"  {batch_name}: {imported} imported, {skipped} skipped")

    print(f"\n{'='*50}")
    print(f"VERDICT SUMMARY")
    print(f"{'='*50}")
    for verdict, count in sorted(verdict_counts.items()):
        marker = " ← importing" if verdict in IMPORTABLE_VERDICTS else ""
        print(f"  {verdict}: {count}{marker}")
    print(f"  TOTAL: {sum(verdict_counts.values())}")

    return all_questions


def main():
    parser = argparse.ArgumentParser(description="Prepare verified questions for import")
    parser.add_argument(
        "--output", "-o",
        default=str(OUTPUT_DEFAULT),
        help=f"Output file path (default: {OUTPUT_DEFAULT})",
    )
    parser.add_argument(
        "--include-needs-review",
        default=True,
        type=lambda x: x.lower() in ("true", "1", "yes"),
        help="Include needs_review questions (default: true)",
    )
    args = parser.parse_args()

    print("Preparing questions for import...\n")
    questions = prepare_import(include_needs_review=args.include_needs_review)

    # Stats
    topics = Counter(q["topic"] for q in questions)
    difficulties = Counter(q["difficulty"] for q in questions)

    print(f"\n{'='*50}")
    print(f"IMPORT READY: {len(questions)} questions")
    print(f"{'='*50}")
    print(f"\nBy topic:")
    for topic, count in sorted(topics.items(), key=lambda x: -x[1]):
        print(f"  {topic}: {count}")
    print(f"\nBy difficulty:")
    for diff, count in sorted(difficulties.items()):
        print(f"  {diff}: {count}")

    # Write output
    output_path = Path(args.output)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(questions, f, indent=2, ensure_ascii=False)

    print(f"\nWritten to: {output_path}")
    print(f"\nNext step:")
    print(f"  python apps/quiz-agent/import_questions.py \\")
    print(f"    --questions-file {output_path} \\")
    print(f"    --admin-key $ADMIN_API_KEY \\")
    print(f"    --api-url https://quiz-agent-api.fly.dev")


if __name__ == "__main__":
    main()
