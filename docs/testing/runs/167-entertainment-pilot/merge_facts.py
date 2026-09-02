"""One-off merge of #167 sourcing rounds into a single fact file.

Preserves the {"topics": [...], "facts": [...]} shape that
generate_pack.py --facts-file reads, de-duplicating facts by
(normalized source_url, normalized text).
"""

import json
import re
import sys
from pathlib import Path


def norm_url(u: str | None) -> str:
    if not u:
        return ""
    u = u.strip().lower()
    u = re.sub(r"^https?://", "", u)
    u = re.sub(r"^www\.", "", u)
    return u.rstrip("/")


def norm_text(t: str | None) -> str:
    return re.sub(r"\s+", " ", (t or "").strip().lower())


def main(argv: list[str]) -> int:
    out_path = Path(argv[1])
    inputs = [Path(p) for p in argv[2:]]

    topics: list[str] = []
    facts: list[dict] = []
    seen: set[tuple[str, str]] = set()
    per_file: list[tuple[str, int, int]] = []

    for p in inputs:
        data = json.loads(p.read_text())
        added = 0
        for t in data.get("topics", []):
            if t not in topics:
                topics.append(t)
        for f in data.get("facts", []):
            key = (norm_url(f.get("source_url")), norm_text(f.get("text")))
            if key in seen:
                continue
            seen.add(key)
            facts.append(f)
            added += 1
        per_file.append((p.name, len(data.get("facts", [])), added))

    out_path.write_text(json.dumps({"topics": topics, "facts": facts}, indent=2))

    for name, total, added in per_file:
        print(f"{name}: {total} facts, {added} new after dedup")
    print(f"merged: {len(facts)} unique facts across {len(topics)} topics -> {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
