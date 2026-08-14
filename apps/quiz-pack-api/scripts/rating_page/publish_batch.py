#!/usr/bin/env python3
"""Register a blind rating batch with quiz-pack-api and print the rater URLs.

Server-backed twin of `build_page.py` (issue #154): same arms in, same seeded
interleave and blinding, but instead of writing `rating.html` + `mapping.json`
to a run directory it POSTs the batch to `/v1/ratings/batches` and prints
`/web/rate/{batch_id}?rater=…`. Ratings then land in Postgres per rater
instead of in one browser's localStorage.

The selection/blinding functions are IMPORTED from `build_page` — the two
modes must blind identically or rounds built with different tools stop being
comparable.

Usage:
    python publish_batch.py --arm v5=runs/154/v5.json \
                            --arm v6=runs/154/v6.json \
                            --seed 154 --dedupe-by-fact \
                            --title "Hodnotenie otázok — kolo 3" \
                            --base-url http://localhost:8003 \
                            --rater michal --rater zuzka

`ADMIN_API_KEY` comes from the environment or the repo `.env` (override with
--admin-key). Point --base-url at prod to publish there.
"""

import argparse
import json
import os
import sys
from pathlib import Path
from urllib.parse import quote

import httpx

# Import through the package path (not a bare `import build_page` off this
# directory): running the file as a script and importing it as
# `scripts.rating_page.publish_batch` must resolve to ONE build_page module,
# or the two would drift apart unnoticed.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.rating_page.build_page import add_selection_args, select_and_blind

META_KEYS = (
    "options",
    "alternative_answers",
    "explanation",
    "topic",
    "difficulty",
    "source_url",
)


def to_api_question(q: dict) -> dict:
    """`build_page`'s blinded dict → the API's {qid, question, answer, meta}.

    The API rejects unknown top-level keys on a question, so anything that is
    not identity/prompt/answer has to go under `meta` — which is also what
    keeps an arm field from ever being smuggled into the rater payload.
    """
    meta = {k: q[k] for k in META_KEYS if q.get(k)}
    return {
        "qid": q["id"],
        "question": q["question"],
        "answer": q.get("correct_answer"),
        "meta": meta or None,
    }


def _admin_key(explicit: str | None) -> str:
    if explicit:
        return explicit
    try:
        from quiz_shared.paths import load_dotenv_from_ancestors

        load_dotenv_from_ancestors(Path(__file__))
    except ImportError:
        pass
    key = os.environ.get("ADMIN_API_KEY")
    if not key:
        raise SystemExit(
            "ADMIN_API_KEY not set — put it in the repo .env or pass --admin-key."
        )
    return key


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    add_selection_args(ap)
    ap.add_argument("--title", default="Hodnotenie otázok")
    ap.add_argument("--base-url", default="http://localhost:8003",
                    help="quiz-pack-api base URL (local or prod)")
    ap.add_argument("--admin-key", default=None,
                    help="defaults to ADMIN_API_KEY from the environment / .env")
    ap.add_argument("--rater", action="append", default=[],
                    help="print a ready-to-send URL for this rater (repeatable)")
    ap.add_argument("--save-mapping", type=Path, default=None,
                    help="also write the unblinding mapping locally (it is stored "
                         "server-side either way; this is only a convenience copy)")
    args = ap.parse_args()

    questions, mapping = select_and_blind(args.arm, args.seed, args.dedupe_by_fact)
    payload = {
        "title": args.title,
        "questions": [to_api_question(q) for q in questions],
        "mapping": mapping,
    }

    base = args.base_url.rstrip("/")
    resp = httpx.post(
        f"{base}/v1/ratings/batches",
        json=payload,
        headers={"X-Admin-Key": _admin_key(args.admin_key)},
        timeout=60.0,
    )
    if resp.status_code != 201:
        raise SystemExit(f"batch registration failed: {resp.status_code} {resp.text}")

    batch_id = resp.json()["batch_id"]
    print(f"registered batch {batch_id} — {len(questions)} questions, "
          f"{len(args.arm)} arms")

    if args.save_mapping:
        args.save_mapping.parent.mkdir(parents=True, exist_ok=True)
        args.save_mapping.write_text(
            json.dumps(mapping, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"mapping copy: {args.save_mapping} — never send it to a rater")

    print("\nrating URLs:")
    for rater in args.rater or ["<name>"]:
        print(f"  {base}/web/rate/{batch_id}?rater={quote(rater)}")
    print("\nExport when the round is done: python export_ratings.py "
          f"--base-url {base}")


if __name__ == "__main__":
    main()
