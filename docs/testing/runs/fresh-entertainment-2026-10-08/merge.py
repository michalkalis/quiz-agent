"""#195 — merge the 2026-10-08 fresh entertainment batches into one import file per language,
dropping cross-batch duplicates and off-tone rows (founder 2026-10-08: only CURRENT politics and CURRENT wars are off-limits).
Drops are keyed by question-id prefix. Usage: python3 merge.py → merged-{en,sk,cs}.json"""

import json
from pathlib import Path

RUN = Path(__file__).parent
DROPS = {
    "8bdb3722": "Eurovision 'why Austria hosted' — weak, same fact as the Vienna question",
    "b53bab43": "KPop Demon Hunters / Golden — reverse of the Best Original Song question",
    "a1124e40": "Wonder Man / Trevor Slattery — same fact already in the prod corpus",
    "9a70faab": "Michael B. Jordan twins — duplicate of en-01 #1",
    "cdac896d": "Bad Bunny Super Bowl — covered by the Grammys + Super Bowl question",
    "ec120f05": "Jessie Buckley / Shakespeare — duplicate of en-01 #9",
    "ead46d4d": "Eurovision 2026 Vienna — duplicate of en-02 #18",
    # --- curation pass 2 (2026-10-08) ---
    # en: same fact twice in the set / answer stated in another stem
    "aa08c85e": "Chalamet Globe for Marty Supreme — same fact as eb26e388",
    "fbe457ed": "Bad Bunny Album of the Year — same fact as 37c9d7d0",
    "23316680": "Clair Obscur studio = France — stated in 3222f149 stem",
    "51f05182": "Stranger Things finale in cinemas T/F — stated in e8f6fe3a stem; 4th MCQ",
    "64aa98fe": "Pluribus creator Gilligan — stated in ebca0636 stem",
    "d1f71fd9": "SZA on luther — stated in b5ca5627 stem",
    # en: same fact already in older corpus (167 pilot accepted / d21b corpus import)
    "6a8ccee2": "Sinners 16 Oscar noms — already in 167 pilot",
    "583cd587": "Brand New Day vs Endgame opening — already in 167 pilot",
    "e5faca16": "Eurovision 2026 Vienna — already in 167 pilot",
    "3b6fe1c6": "first woman Best Cinematography — already in 167 pilot",
    "a4663164": "BTS Arirang — already in d21b corpus import",
    # sk domestic: duplicates
    "f0ea47f8": "Nvotová directed Otec — dup (kept 60d8f443 states it)",
    "9582161b": "Nvotová directed Otec — dup",
    "b7c6c617": "Nvotová directed Otec — dup, stated in 60d8f443 stem",
    "03bad684": "why best film != most awarded — self-evident answer",
    "b798a658": "Pohoda Gorillaz — dup of 7bffe6e8",
    "ad932c3a": "Pohoda Gorillaz — dup of 7bffe6e8",
    "3ebe6212": "Pohoda tickets — dup of fe335f61",
    "e2d65248": "SK not at Eurovision 2026 T/F — stated in 83faeb43 stem",
    "7fa5c194": "SK not at Eurovision 2026 T/F — dup",
    "cd994260": "SK not at Eurovision 2026 T/F — dup",
    "7534f3af": "SK cinema admissions 2025 — dup of 0518901b",
    "836f1393": "Ewa Farná SuperStar juror — dup of 91077bb8",
    "be30e2cb": "Müller + Banket — dup of 9616dd40",
    "e03b2de9": "Nepela film — stem gives away native-sk c614e844 (1972)",
    "7f8c77fc": "Moloch MCQ — obscure, over MCQ cap",
    # sk world: off-tone / repeats an en fact / dup
    "b7a36d71": "Zootopia 2 five-day opening — same as en 8e24ff80",
    "e7e9ff70": "Stranger Things finale in cinemas — same as en e8f6fe3a",
    "0c9acf23": "Stranger Things finale on NYE — stated in en e8f6fe3a",
    "31cba411": "Stranger Things finale on NYE — dup",
    "f295f424": "Oscar 'who didn't win' MCQ — en states the winners; MCQ cap",
    "c28fb531": "Ariana Grande Glinda — dup of 20f92ef9",
    "fe24edaf": "Clair Obscur = France — stated in en 3222f149",
    "e6d9a8eb": "Clair Obscur = France — dup",
    "daac901c": "Fate of Ophelia → Hamlet — same as en 89e75de4",
    "84ebe20c": "HUNTR/X name — stated in en 2008b006",
    "ab87fad1": "Oasis reunion — stated in en 8a8b8cfc",
    # cs domestic: off-tone / duplicates / MCQ cap
    "f60126f2": "Zrádci show name — stated in a708a05b stem",
    "d418c795": "most-visited 2025 film domestic T/F — implied by 76e2e8f8; MCQ cap",
    "51636cc1": "CZ cinema admissions 2025 — dup of 3ae58406",
    "27fd1ea4": "Holland's Kafka film — dup of 1d1dcdb4",
    "8029f1aa": "Idan Weiss as Kafka — dup of 1d1dcdb4",
    "553e0b4b": "Bardotky Pořízková — dup of b2e00414",
    "f4116c3e": "Prokop Ostraka — dup of 9871a103",
    "f884ae48": "Noid Bárta Zpěvák roku — dup of d397f03e",
    "0a4a0480": "Noid Bárta Zpěvák roku — dup of d397f03e",
    "2fc8475f": "Dustin Hoffman KVIFF — dup of 61480634",
    "1c155fc5": "Mišík Síň slávy — dup of b8dd5f56",
    # cs world: off-tone / repeats an en fact
    "441927ae": "Noah Wyle Globe / ER — same as en c5e8bfc2",
    "f1b1407f": "Stranger Things finale NYE — stated in en e8f6fe3a",
    "a286da58": "Hawkins — same as en e8f6fe3a",
    "9abbb661": "Zootopia 2 Gary snake — same as en ee428820",
    "c0e86bb9": "Jessie Buckley Hamnet — same as en e49c1c8b",
    "0f7037f8": "Chalamet Globe — same as en eb26e388",
    "6e98398d": "KPop Demon Hunters Animated Feature — same as en fb7b6e01",
    "a5965779": "HUNTR/X name — stated in en 2008b006",
    "2c3888f7": "Fate of Ophelia — same as en 89e75de4",
    "ba6541dc": "Michael B. Jordan dual role — same as en 59df8356",
    "e4caf77f": "Nolan's Odyssey — stated in en b187f1a6",
    "e7ecd5fd": "Kendrick luther — stated in en b5ca5627",
    "6fc6a081": "Switch 2 sales — same as en f7c93aa0; MCQ cap",
}
TARGET = 50
for lang in ("en", "sk", "cs"):
    out = []
    for p in sorted(RUN.glob(f"{lang}-*.json")):
        if p.name.endswith("usage.json"):
            continue
        for q in json.load(p.open()):
            reason = DROPS.get(q["id"][:8])
            if reason:
                print(f"drop {p.stem}: {q['question'][:60]}… — {reason}")
                continue
            assert q["language"] == lang and q.get("source_url"), (p.stem, q["id"])
            out.append(q)
    print(f"{lang}: {len(out)} (target {TARGET})")
    (RUN / f"merged-{lang}.json").write_text(json.dumps(out[:TARGET], ensure_ascii=False, indent=1))
