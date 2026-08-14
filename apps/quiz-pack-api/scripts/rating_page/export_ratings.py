#!/usr/bin/env python3
"""Download the canonical ratings store as JSONL (issue #154).

Thin wrapper over `GET /v1/ratings/export`: one line per rating with every
column plus `score_normalized_10`, which is what makes 1–5 historical rounds
(#156) and current 1–10 rounds comparable in one analysis.

Usage:
    python export_ratings.py --base-url http://localhost:8003 --out ratings.jsonl

`ADMIN_API_KEY` comes from the environment or the repo `.env`.
"""

import argparse
import os
from datetime import datetime, timezone
from pathlib import Path

import httpx


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
    ap.add_argument("--base-url", default="http://localhost:8003")
    ap.add_argument("--admin-key", default=None,
                    help="defaults to ADMIN_API_KEY from the environment / .env")
    ap.add_argument("--out", type=Path,
                    default=Path(
                        f"ratings-{datetime.now(timezone.utc).date().isoformat()}.jsonl"
                    ))
    args = ap.parse_args()

    url = args.base_url.rstrip("/") + "/v1/ratings/export"
    with httpx.stream(
        "GET", url, headers={"X-Admin-Key": _admin_key(args.admin_key)}, timeout=120.0
    ) as resp:
        if resp.status_code != 200:
            resp.read()
            raise SystemExit(f"export failed: {resp.status_code} {resp.text}")
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with args.out.open("w", encoding="utf-8") as fh:
            for chunk in resp.iter_text():
                fh.write(chunk)

    lines = sum(1 for line in args.out.read_text(encoding="utf-8").splitlines() if line.strip())
    print(f"wrote {args.out} — {lines} ratings")


if __name__ == "__main__":
    main()
