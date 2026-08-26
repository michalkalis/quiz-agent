"""One-off corpus migration to the interest-based category taxonomy (2026-08).

Remaps every approved + pending_review question in prod from the old
audience/fandom categories (general, adults, entertainment, …) onto the six
interest categories the app now exposes: science-nature, history,
geography-world, movies-music, sports, food-everyday.

Deterministic: topic → category table below, plus per-id overrides for
questions whose topic ("General") carries no signal. Fandom questions
(Harry Potter / Fantastic Beasts, all pending_review) are intentionally
skipped — they are pack material, not filter categories.

Usage (after the set-category endpoint is deployed):
    ADMIN_API_KEY=... python scripts/recategorize_corpus.py [--dry-run]
"""

import argparse
import json
import os
import sys
import urllib.request

API_BASE = os.environ.get("QUIZ_API_BASE", "https://quiz-agent-api.fly.dev")

SCIENCE = "science-nature"
HISTORY = "history"
GEO = "geography-world"
ENT = "movies-music"
SPORTS = "sports"
FOOD = "food-everyday"

# Topic match is case-insensitive (the corpus has case variants of some topics).
TOPIC_MAP = {
    # science & nature
    "space": SCIENCE,
    "space exploration": SCIENCE,
    "space history": SCIENCE,
    "astronomy": SCIENCE,
    "science": SCIENCE,
    "biology": SCIENCE,
    "marine biology": SCIENCE,
    "animal biology oddities": SCIENCE,
    "chemistry in everyday life": SCIENCE,
    "ocean and deep sea mysteries": SCIENCE,
    "weather and natural phenomena": SCIENCE,
    "the human body": SCIENCE,
    "plants and fungi oddities": SCIENCE,
    "records and extremes in nature": SCIENCE,
    "physics & landmarks": SCIENCE,
    "aviation engineering": SCIENCE,
    "engineering marvels": SCIENCE,
    "technology origins and firsts": SCIENCE,
    "transport and aviation firsts": SCIENCE,
    "history of inventions": SCIENCE,
    # history
    "history": HISTORY,
    "ancient civilizations daily life": HISTORY,
    "famous rulers and royal quirks": HISTORY,
    "military history": HISTORY,
    "money and trade": HISTORY,
    "business & gaming history": HISTORY,
    "business & gaming": HISTORY,
    "games and toys history": HISTORY,
    # geography & world
    "geography": GEO,
    "world geography surprises": GEO,
    "famous landmarks and their secrets": GEO,
    "maps and borders quirks": GEO,
    "geography & flags": GEO,
    "national symbols": GEO,
    "architecture": GEO,
    # movies & music (incl. wider pop culture / arts)
    "music": ENT,
    "film": ENT,
    "literature": ENT,
    "art and artists surprises": ENT,
    "classic films and pop culture history": ENT,
    "music history milestones": ENT,
    "biggest music artists recent releases and chart records": ENT,
    "blockbuster films and famous directors recent releases": ENT,
    "major music and film awards recent winners": ENT,
    "famous artist collaborations and reunions recent": ENT,
    "famous music producers and the artists they make hits for": ENT,
    # sports
    "sports history": SPORTS,
    "ancient olympics": SPORTS,
    # food & everyday life
    "everyday food science": FOOD,
    "beverages": FOOD,
}

# Fandom topics stay in their pack-style categories; never remapped here.
SKIP_TOPICS = {"harry potter", "fantastic beasts"}

# topic == "General" carries no signal; assigned by hand per question text.
ID_OVERRIDES = {
    "f8c9e5c6-6cde-4ae5-90e6-ce78a0c40c41": SCIENCE,  # ginger cat genetics
    "a2dc2ec4-8f8d-44c7-8c8f-ca34a4e6fc18": SCIENCE,  # newborn colour vision
    "5e86ee19-2438-4feb-bee5-8f59a17aab27": SCIENCE,  # human/banana DNA overlap
    "cc9db6e6-b3b6-4631-b2f8-30ef07d10892": GEO,  # Louvre pyramid architect
    "49275265-daf6-4d8e-8895-6916d5137113": SCIENCE,  # psychology of laziness
    "944c79db-14c3-41e4-8fa1-b13d54ed78fb": GEO,  # Ethiopian currency
    "84a82a8f-b5f4-44da-80d0-58f7da931d58": FOOD,  # Gouda/Edam origin
    "8bd2aa09-dcd5-4f16-9894-4eee0772c7ff": FOOD,  # Japanese square melons
    "12263c24-48dd-4b6f-8f6c-b09ae1f498b7": FOOD,  # carrot colours
    "a928cf39-5172-4ee3-b982-3a857a6737a7": SCIENCE,  # botanical berries odd-one-out
    "e28f0808-72c9-47db-9be8-e5d11c8cad0b": FOOD,  # Caesar salad origin
    "37825bd1-b9cd-44fc-a2aa-dbc002e2c5d7": FOOD,  # nectarine etymology
    "812e30e1-439e-4b68-a972-153b13c8b893": ENT,  # DC Comics Star City
    "052fcb0d-8aa0-445b-9bc0-c45185bd7fc5": SCIENCE,  # human body growth facts
    "e6ab36db-58fd-41cd-ae87-c355ec8860d0": SCIENCE,  # berry botanical definition
    "c9ed935a-7644-4be2-861a-69b72155a585": GEO,  # languages without yes/no
}


def _request(path: str, key: str, payload: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"{API_BASE}{path}",
        headers={"X-Admin-Key": key, "Content-Type": "application/json"},
        data=json.dumps(payload).encode() if payload is not None else None,
    )
    return json.load(urllib.request.urlopen(req, timeout=60))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    key = os.environ.get("ADMIN_API_KEY") or os.environ.get("QUIZ_ADMIN_KEY")
    if not key:
        print("ADMIN_API_KEY not set", file=sys.stderr)
        return 1

    data = _request("/api/v1/admin/questions?limit=1000", key)
    targets = [
        q
        for q in data["questions"]
        if q["review_status"] in ("approved", "pending_review")
    ]

    assignments = []
    skipped, unmapped = [], []
    for q in targets:
        topic = q["topic"].strip().lower()
        if topic in SKIP_TOPICS:
            skipped.append(q["id"])
            continue
        category = ID_OVERRIDES.get(q["id"]) or TOPIC_MAP.get(topic)
        if category is None:
            unmapped.append((q["id"], q["topic"]))
            continue
        assignments.append({"id": q["id"], "category": category})

    print(f"{len(targets)} candidates: {len(assignments)} to assign, "
          f"{len(skipped)} fandom skipped, {len(unmapped)} unmapped")
    if unmapped:
        for qid, topic in unmapped:
            print(f"  UNMAPPED {qid} topic={topic!r}", file=sys.stderr)
        print("Refusing to run with unmapped topics — extend TOPIC_MAP.",
              file=sys.stderr)
        return 1

    if args.dry_run:
        from collections import Counter

        for cat, n in Counter(a["category"] for a in assignments).most_common():
            print(f"  {cat}: {n}")
        return 0

    result = _request(
        "/api/v1/admin/questions/set-category", key, {"assignments": assignments}
    )
    print(json.dumps(result, indent=2))
    return 0 if result.get("success") and not result.get("not_found_ids") else 1


if __name__ == "__main__":
    sys.exit(main())
