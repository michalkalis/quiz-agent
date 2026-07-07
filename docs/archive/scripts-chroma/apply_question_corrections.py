#!/usr/bin/env python3
"""Apply human-reviewed corrections to questions in local DB and/or production.

Pipeline:
  data/questions/backfill-needs-fix.md   ← human review surface
                ↓
  data/verification/corrections_*.json   ← field-level diffs (this script's input)
                ↓
  local ChromaDB (--local)               ← canonical truth applied first
                ↓
  prod ChromaDB (--prod)                 ← delete + reimport + backfill-sources

Why local-first: prod's admin endpoints cannot patch a Question in place
(import auto-approves and resets timestamps; GET returns a thin projection).
We apply locally via QuestionStore.upsert (single source of truth for
serialization), then ship the post-correction Question shape to prod.

Usage:
    # Dry run on local
    python scripts/apply_question_corrections.py --local --dry-run

    # Apply locally
    python scripts/apply_question_corrections.py --local

    # Apply to prod (requires ADMIN_API_KEY)
    ADMIN_API_KEY=xxx python scripts/apply_question_corrections.py --prod

    # Both (local first, then prod)
    ADMIN_API_KEY=xxx python scripts/apply_question_corrections.py --local --prod
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packages" / "shared"))
from quiz_shared.database.chroma_client import ChromaDBClient  # noqa: E402
from quiz_shared.database.question_store import ChromaDBQuestionStore  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402

PATCHABLE_FIELDS = {
    "question",
    "correct_answer",
    "alternative_answers",
    "source_url",
    "source_excerpt",
    "review_status",
    "explanation",
    "topic",
    "category",
    "difficulty",
}


def load_corrections(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict) and "corrections" in data:
        return data["corrections"]
    if isinstance(data, list):
        return data
    raise ValueError(f"Unrecognized corrections format in {path}")


def apply_patches(question: Question, correction: dict) -> Question:
    for field, value in correction.items():
        if field == "id" or field.startswith("_"):
            continue
        if field not in PATCHABLE_FIELDS:
            print(f"    WARN: unknown field '{field}' in correction for {correction['id']}")
            continue
        setattr(question, field, value)
    if "question" in correction:
        question.embedding = None
    return question


def apply_local(corrections: list[dict], chroma_path: str, dry_run: bool) -> dict[str, Question]:
    print(f"\n=== LOCAL ({'DRY RUN' if dry_run else 'WRITE'}) ===")
    print(f"ChromaDB: {chroma_path}")

    chroma = ChromaDBClient(persist_directory=chroma_path)
    store = ChromaDBQuestionStore(chroma.collection)

    corrected: dict[str, Question] = {}
    counts = {"updated": 0, "not_found": 0, "failed": 0}

    for c in corrections:
        qid = c["id"]
        existing = store.get(qid)
        if existing is None:
            print(f"  NOT FOUND: {qid}")
            counts["not_found"] += 1
            continue

        before_q = existing.question[:60]
        before_a = existing.correct_answer
        before_status = existing.review_status

        patched = apply_patches(existing, c)
        corrected[qid] = patched

        print(f"  [{qid}]")
        if "question" in c:
            print(f"    Q: '{before_q}...' → '{patched.question[:60]}...'")
        if "correct_answer" in c:
            print(f"    A: {before_a!r} → {patched.correct_answer!r}")
        if "review_status" in c and c["review_status"] != before_status:
            print(f"    status: {before_status} → {patched.review_status}")
        if "source_url" in c:
            print(f"    source_url: {patched.source_url[:60]}...")

        if dry_run:
            counts["updated"] += 1
            continue

        if store.upsert(patched):
            counts["updated"] += 1
        else:
            print(f"    FAILED upsert for {qid}")
            counts["failed"] += 1

    print(f"\nLocal summary: updated={counts['updated']} "
          f"not_found={counts['not_found']} failed={counts['failed']}")
    return corrected


def question_to_import_payload(q: Question) -> dict:
    """Map Question → admin /questions/import payload (QuestionImport shape).

    Note: source_url / source_excerpt are not part of QuestionImport. They are
    backfilled in a second pass via /questions/backfill-sources.
    """
    payload = {
        "id": q.id,
        "question": q.question,
        "type": q.type,
        "correct_answer": q.correct_answer,
        "alternative_answers": q.alternative_answers or [],
        "topic": q.topic,
        "category": q.category,
        "difficulty": q.difficulty,
        "tags": q.tags,
        "source": q.source,
        "language_dependent": q.language_dependent,
    }
    if q.possible_answers:
        payload["possible_answers"] = q.possible_answers
    if q.created_by:
        payload["created_by"] = q.created_by
    if q.media_url:
        payload["media_url"] = q.media_url
    if q.media_duration_seconds is not None:
        payload["media_duration_seconds"] = q.media_duration_seconds
    if q.explanation:
        payload["explanation"] = q.explanation
    if q.image_subtype:
        payload["image_subtype"] = q.image_subtype
    if q.generation_metadata:
        payload["generation_metadata"] = q.generation_metadata
    return payload


def http(method: str, url: str, headers: dict, body: Any = None, timeout: int = 30) -> tuple[int, str]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def http_with_retry(method: str, url: str, headers: dict, body: Any = None,
                    timeout: int = 30, max_retries: int = 3) -> tuple[int, str]:
    """HTTP call with backoff on 429. Admin endpoints are 5/minute."""
    for attempt in range(max_retries):
        code, body_resp = http(method, url, headers, body, timeout)
        if code != 429:
            return code, body_resp
        sleep_s = 65
        print(f"    429 rate-limited; sleeping {sleep_s}s (retry {attempt + 1}/{max_retries})")
        time.sleep(sleep_s)
    return code, body_resp


def apply_prod(corrected: dict[str, Question], api_url: str, admin_key: str, dry_run: bool) -> None:
    print(f"\n=== PROD ({'DRY RUN' if dry_run else 'WRITE'}) ===")
    print(f"API: {api_url}")

    headers = {"Content-Type": "application/json", "X-Admin-Key": admin_key}
    api = api_url.rstrip("/")

    if dry_run:
        for qid, q in corrected.items():
            print(f"  [{qid}] would DELETE then IMPORT '{q.question[:60]}...' "
                  f"(answer={q.correct_answer!r})")
        return

    deleted = 0
    deleted_missing = 0
    delete_failed = 0
    qids = list(corrected.keys())
    # /api/v1/admin DELETE is rate-limited to 5/minute. Space calls so we
    # don't trip the limiter on a >5-question correction batch.
    delete_spacing_s = 13 if len(qids) > 5 else 0
    for i, qid in enumerate(qids):
        code, body = http_with_retry("DELETE", f"{api}/api/v1/admin/questions/{qid}", headers)
        if code == 200:
            print(f"  DELETED {qid}")
            deleted += 1
        elif code == 404:
            print(f"  not present: {qid}")
            deleted_missing += 1
        else:
            print(f"  DELETE FAILED [{qid}]: HTTP {code} {body}")
            delete_failed += 1
        if delete_spacing_s and i < len(qids) - 1:
            time.sleep(delete_spacing_s)

    import_payload = {
        "questions": [question_to_import_payload(q) for q in corrected.values()],
        "skip_duplicates": False,
        "force": True,
    }
    code, body = http_with_retry("POST", f"{api}/api/v1/admin/questions/import", headers, import_payload, timeout=60)
    if code != 200:
        print(f"  IMPORT FAILED: HTTP {code} {body}")
        return
    result = json.loads(body)
    print(f"  imported={result.get('imported_count')} "
          f"skipped={result.get('skipped_count')} "
          f"failed={result.get('failed_count')}")
    if result.get("failed_ids"):
        print(f"  failed_ids: {result['failed_ids']}")

    backfill_items = [
        {"id": q.id, "source_url": q.source_url, "source_excerpt": q.source_excerpt}
        for q in corrected.values()
        if q.source_url or q.source_excerpt
    ]
    if backfill_items:
        code, body = http_with_retry(
            "POST",
            f"{api}/api/v1/admin/questions/backfill-sources",
            headers,
            {"items": backfill_items},
            timeout=60,
        )
        if code == 200:
            r = json.loads(body)
            print(f"  source_url updated={r.get('updated_count')} "
                  f"skipped={r.get('skipped_count')} "
                  f"not_found={r.get('not_found_count')}")
        else:
            print(f"  BACKFILL-SOURCES FAILED: HTTP {code} {body}")

    print(f"\nProd summary: deleted={deleted} deleted_missing={deleted_missing} "
          f"delete_failed={delete_failed}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--corrections-file",
        default="data/verification/corrections_2026-05-04.json",
    )
    parser.add_argument("--chroma-path", default="./chroma_data")
    parser.add_argument("--api-url", default="https://quiz-agent-api.fly.dev")
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--prod", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.local and not args.prod:
        print("ERROR: pass --local and/or --prod")
        return 1

    corrections = load_corrections(Path(args.corrections_file))
    print(f"Loaded {len(corrections)} corrections from {args.corrections_file}")

    corrected: dict[str, Question] = {}
    if args.local:
        corrected = apply_local(corrections, args.chroma_path, args.dry_run)
        if not corrected:
            print("\nNothing to apply locally; aborting before prod step.")
            return 1
    elif args.prod:
        # --prod without --local: still need full Question shape, fetch from local
        chroma = ChromaDBClient(persist_directory=args.chroma_path)
        store = ChromaDBQuestionStore(chroma.collection)
        for c in corrections:
            q = store.get(c["id"])
            if q is None:
                print(f"  WARN: {c['id']} not in local DB; skipping for prod")
                continue
            corrected[c["id"]] = q

    if args.prod:
        admin_key = os.environ.get("ADMIN_API_KEY")
        if not admin_key:
            print("ERROR: --prod requires ADMIN_API_KEY env var")
            return 1
        apply_prod(corrected, args.api_url, admin_key, args.dry_run)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
