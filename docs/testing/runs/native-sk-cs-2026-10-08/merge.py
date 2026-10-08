"""Merge the 2026-10-08 native sk/cs batches into one import file per language, dropping
intra-run duplicates (keyword check vs the prod EN corpus found no real overlap).
Usage: python3 merge.py  →  merged-sk.json, merged-cs.json"""

import json
from pathlib import Path

RUN = Path(__file__).parent
DROPS = {
    ("cs", "01", 1): "same premise as cs-01 #10 (roof of Europe); long free-text answer",
    ("cs", "02", 10): "robot coined by Čapek — same fact as cs-03 #6 (kept: who coined it)",
    ("cs", "03", 1): "Seifert Nobel — same fact as cs-02 #9",
    ("cs", "04", 6): "robot / Josef Čapek — duplicate of cs-03 #6",
    ("sk", "03", 1): "Obchod na korze / Kroner — duplicate of sk-02 #12",
    ("sk", "01", 8): "euro-coin mountain — same fact as sk-05 #6 (kept: Kriváň, open answer)",
    # Trim to 50 per language: weakest rows (approximate numeric answers, long
    # free-text answers, dated or mislabelled-difficulty items).
    ("sk", "01", 12): "Laugaricio inscription labelled easy, specialist knowledge",
    ("sk", "05", 3): "approximate answer (about a million cars)",
    ("cs", "01", 12): "approximate answer (about 140 m)",
    ("cs", "02", 1): "long free-text answer (odd-number palindrome)",
    ("cs", "05", 5): "dated admin fact (e-vignette 2021)",
}
TARGET = 50
for lang in ("sk", "cs"):
    out = []
    for p in sorted(RUN.glob(f"{lang}-0*.json")):
        if p.name.endswith("usage.json"):
            continue
        b = p.stem.split("-")[1]
        for i, q in enumerate(json.load(p.open()), 1):
            if (lang, b, i) in DROPS:
                print(f"drop {p.stem} #{i}: {q['question'][:60]}… — {DROPS[(lang, b, i)]}")
                continue
            assert q["language"] == lang and q.get("source_url"), (p.stem, i)
            out.append(q)
    assert len(out) == TARGET, (lang, len(out))
    (RUN / f"merged-{lang}.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(f"{lang}: {len(out)} → merged-{lang}.json")
