"""Build cases.jsonl for the #196 track 196.3 hot-path model eval.

Questions come from real corpus rows (the 2026-09-10 translation review files
and apps/quiz-agent/questions_export.json) or, where marked ``x:``, from the
evaluator prompt / unit tests. Player answers are authored to mimic voice
transcripts; each carries the verdict a fair human judge would give. Cases
with a debatable verdict were left out rather than guessed.

Run from the repo root: python3 docs/testing/runs/haiku-eval-2026-10-10/build_cases.py
"""

from __future__ import annotations

import json
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parents[3]
CORPUS = ROOT / "docs/testing/runs/translation-corpus-2026-09-10"

C, I = "correct", "incorrect"

# Authored questions (source given per entry).
AUTHORED = {
    "monet": ("en", "Which French Impressionist painted the Water Lilies series?", "Claude Monet", [], "evaluator prompt example (Monet/Manet)"),
    "henry": ("en", "Which English king had six wives?", "Henry VIII", ["Henry the Eighth"], "evaluator prompt example (Henry VII vs VIII)"),
    "iran": ("en", "Which country's capital is Tehran?", "Iran", [], "evaluator prompt example (Iran/Iraq)"),
    "parachute": ("en", "How did the man in the field die?", "His parachute failed to open", ["His parachute didn't deploy", "He fell from a plane"], "test_evaluator_paraphrase_tolerance.py"),
    "lincoln": ("en", "Which U.S. president delivered the Gettysburg Address?", "Abraham Lincoln", [], "evaluator prompt example (shorter name)"),
    "teflon": ("sk", "Ktorý prvok okrem uhlíka tvorí polymér na nepriľnavých panviciach?", "Fluór", ["F", "fluór", "ef", "prvok fluór"], "test_evaluator_paraphrase_tolerance.py (prod 2026-10-07 Teflón)"),
    "ba": ("sk", "Ktoré mesto je hlavným mestom Slovenska?", "Bratislava", [], "test_evaluator_sk_cs_answers.py (inflection)"),
    "praha": ("cs", "Které město je hlavním městem Česka?", "Praha", [], "test_evaluator_sk_cs_answers.py (inflection)"),
    "hus": ("sk", "Ktorý reformátor bol upálený v Kostnici v roku 1415?", "Hus Jan", [], "test_evaluator_sk_cs_answers.py (word order)"),
}

# (question ref, heard transcript, expected verdict, tag)
GRADE = [
    # ── Slovak ──
    ("sk:75634579", "sokola sťahovavého", C, "inflect"),
    ("sk:75634579", "jastrab", I, "wrong_plausible"),
    ("sk:75634579", "orol skalný", I, "wrong_plausible"),
    ("sk:22156a55", "Jany z Arku", C, "inflect"),
    ("sk:22156a55", "žan dark", C, "stt"),
    ("sk:22156a55", "Mária Antoinetta", I, "wrong_plausible"),
    ("sk:e2fd6bf2", "Bejonsé", C, "stt"),
    ("sk:e2fd6bf2", "Rihanna", I, "wrong_plausible"),
    ("sk:720fdaf8", "mal rozšírenú zrenicu po bitke", C, "paraphrase"),
    ("sk:720fdaf8", "farebné šošovky", I, "wrong_plausible"),
    ("sk:80ec52c8", "Hansov ostrof", C, "stt"),
    ("sk:80ec52c8", "Grónsko", I, "wrong_plausible"),
    ("sk:0a0ba41c", "Venecuela", C, "stt"),
    ("sk:0a0ba41c", "Kolumbia", I, "wrong_plausible"),
    ("sk:e7c3a836", "hacune miko", C, "stt"),
    ("sk:c2e3d05c", "z hliníka", C, "inflect"),
    ("sk:c2e3d05c", "striebro", I, "wrong_plausible"),
    ("sk:b3b469fd", "popol zo sopky", C, "paraphrase"),
    ("sk:b3b469fd", "morská soľ", I, "wrong_plausible"),
    ("sk:086a3325", "z orchideí", C, "inflect"),
    ("sk:086a3325", "z palmy", I, "wrong_plausible"),
    ("sk:581fe118", "vaterló", C, "stt"),
    ("sk:581fe118", "Mamma Mia", I, "wrong_plausible"),
    ("sk:ef1d8e7a", "teplo ich tela", C, "paraphrase"),
    ("sk:ef1d8e7a", "echolokáciu", I, "wrong_plausible"),
    ("sk:be59ae96", "čaju", C, "inflect"),
    ("sk:be59ae96", "káva", I, "wrong_plausible"),
    ("sk:484a45af", "na Kube", C, "inflect"),
    ("sk:484a45af", "Jamajka", I, "wrong_plausible"),
    ("sk:0d4b442d", "Kazachstan", I, "wrong_plausible"),
    ("sk:c3c795b7", "plávanie na chrbte", C, "paraphrase"),
    ("sk:c3c795b7", "motýlik", I, "wrong_plausible"),
    ("sk:e0ed8486", "Sprite", I, "wrong_plausible"),
    ("sk:db6b3698", "tí es eliot", C, "stt"),
    ("sk:db6b3698", "Oscar Wilde", I, "wrong_plausible"),
    ("sk:a276ab70", "midnajt kauboj", C, "stt"),
    ("sk:a276ab70", "Taxikár", I, "wrong_plausible"),
    ("sk:9e8c2ebd", "pemzu", C, "inflect"),
    ("sk:9e8c2ebd", "obsidián", I, "wrong_plausible"),
    ("sk:1e38b127", "muškátový oriešok", I, "wrong_plausible"),
    ("sk:732a7f2f", "svetlo sa láme", C, "paraphrase"),
    ("sk:732a7f2f", "odraz svetla", I, "wrong_plausible"),
    ("sk:f5cadc97", "svetlo sa v dúhovke rozptyľuje", C, "paraphrase"),
    ("sk:f5cadc97", "odraz modrej oblohy", I, "wrong_plausible"),
    ("sk:dc9dd98f", "Despacito", I, "wrong_plausible"),
    ("sk:8a79020d", "Holandsko", I, "wrong_plausible"),
    ("sk:967f25c3", "burna boj", C, "stt"),
    ("sk:967f25c3", "Wizkid", I, "wrong_plausible"),
    ("sk:d5ee198f", "mega det", C, "stt"),
    ("sk:d5ee198f", "Metallica", I, "wrong_plausible"),
    ("sk:8fc9b176", "Paragvaj", C, "stt"),
    ("sk:8fc9b176", "Uruguaj", I, "soundalike_other"),
    ("sk:f66ef57e", "auto", I, "wrong_clear"),
    ("sk:72e2d072", "kávové bobule", C, "paraphrase"),
    ("sk:72e2d072", "čaj", I, "wrong_plausible"),
    ("sk:cdcb3755", "z rybacej omáčky", C, "paraphrase"),
    ("sk:cdcb3755", "z jabĺk", I, "wrong_plausible"),
    ("sk:2312b30b", "krab", I, "wrong_plausible"),
    ("sk:97778415", "esperanta", C, "inflect"),
    ("sk:97778415", "Volapük", I, "wrong_plausible"),
    ("sk:3a73db5c", "v Austrálii", C, "inflect"),
    ("sk:3a73db5c", "Rakúsko", I, "soundalike_other"),
    ("sk:e80155a7", "Peru", I, "wrong_plausible"),
    ("sk:cc7082a3", "Saturn", I, "wrong_plausible"),
    ("sk:cc7082a3", "Jupitera", C, "inflect"),
    ("sk:ab505aa0", "Rajen Kugler", C, "stt"),
    ("sk:ab505aa0", "Jordan Peele", I, "wrong_plausible"),
    ("sk:2b1f9c75", "Elvisa", C, "inflect"),
    ("sk:2b1f9c75", "Johnny Cash", I, "wrong_plausible"),
    ("sk:b5a41f93", "zahral si golf", C, "paraphrase"),
    ("sk:b5a41f93", "tenis", I, "wrong_plausible"),
    ("sk:8022e07b", "mikrovlnku", C, "inflect"),
    ("sk:8022e07b", "radar", I, "different_entity"),
    ("sk:37b1867e", "mobilom", C, "inflect"),
    ("sk:37b1867e", "pevná linka", I, "wrong_plausible"),
    ("sk:d3e90bd4", "lebo tam nie je gravitácia", I, "misconception"),
    ("sk:d3e90bd4", "stále padajú okolo zeme", C, "paraphrase"),
    ("sk:fa6d75c2", "kov lepšie vedie teplo", C, "paraphrase"),
    ("sk:fa6d75c2", "kov je studenší", I, "misconception"),
    ("sk:5cb7c0ed", "kosti srastú dokopy", C, "paraphrase"),
    ("sk:5cb7c0ed", "kosti sa rozpustia", I, "wrong_plausible"),
    ("sk:b08c37fd", "zatmenie mesiaca", I, "wrong_plausible"),
    ("sk:b30f81e2", "sú vyšší o pár centimetrov", C, "paraphrase"),
    ("sk:b30f81e2", "váha", I, "wrong_plausible"),
    ("sk:595a26ea", "ukazuje ostatným smer ku kvetom", C, "paraphrase"),
    ("sk:595a26ea", "varuje pred nebezpečenstvom", I, "wrong_plausible"),
    ("sk:6fa83da7", "dvakrát na mesiac a späť", I, "number"),
    ("x:teflon", "Teflón. Teflón.", I, "different_entity"),
    ("x:teflon", "fluórom", C, "inflect"),
    ("x:ba", "Bratislavy", C, "inflect"),
    ("x:hus", "Jan Hus", C, "word_order"),
    # ── Czech ──
    ("cs:720fdaf8", "rozšířená zornička", C, "paraphrase"),
    ("cs:720fdaf8", "každé oko mělo jinou duhovku", I, "misconception"),
    ("cs:6afeb849", "aby beton chladl", C, "paraphrase"),
    ("cs:6afeb849", "na vyztužení", I, "wrong_plausible"),
    ("cs:d8c7a633", "Riplís", C, "stt"),
    ("cs:d8c7a633", "Guinness", I, "wrong_plausible"),
    ("cs:dfb0de63", "rohaté helmy", C, "paraphrase"),
    ("cs:dfb0de63", "křídla", I, "wrong_plausible"),
    ("cs:48de98bb", "Frankenštajn", C, "stt"),
    ("cs:48de98bb", "Drákula", I, "wrong_plausible"),
    ("cs:923d2bb1", "hvízdáním na prsty", C, "paraphrase"),
    ("cs:923d2bb1", "znakovou řečí", I, "wrong_plausible"),
    ("cs:22564f0f", "Francii", C, "inflect"),
    ("cs:22564f0f", "Velká Británie", I, "wrong_plausible"),
    ("cs:40d5dbc2", "Džon Wiliams", C, "stt"),
    ("cs:40d5dbc2", "Hans Zimmer", I, "wrong_plausible"),
    ("cs:c65a16ad", "Brendan Frejzer", C, "stt"),
    ("cs:c65a16ad", "Brendan Gleeson", I, "wrong_plausible"),
    ("cs:8730a6ed", "Marakaibo", C, "stt"),
    ("cs:8730a6ed", "Titicaca", I, "wrong_plausible"),
    ("cs:b3d6ea9b", "Sardinie", I, "soundalike_other"),
    ("cs:1c5745d9", "kvůli praseti", C, "inflect"),
    ("cs:1c5745d9", "kráva", I, "wrong_plausible"),
    ("cs:eb92a5b7", "z Vídně", C, "inflect"),
    ("cs:eb92a5b7", "Budapešť", I, "wrong_plausible"),
    ("cs:9d148f41", "Karling", C, "stt"),
    ("cs:9d148f41", "hokej", I, "wrong_plausible"),
    ("cs:5965f766", "Šeklton", C, "stt"),
    ("cs:5965f766", "Amundsen", I, "wrong_plausible"),
    ("cs:7197355f", "Isnera", C, "inflect"),
    ("cs:7197355f", "Federer", I, "wrong_plausible"),
    ("cs:74b0fa56", "Vezuv", C, "stt"),
    ("cs:74b0fa56", "Etna", I, "wrong_plausible"),
    ("cs:2c5b24ce", "platina", I, "wrong_plausible"),
    ("cs:f7edbcc8", "Lajnus Polink", C, "stt"),
    ("cs:f7edbcc8", "Albert Einstein", I, "wrong_plausible"),
    ("cs:932f7686", "Hery Stajls", C, "stt"),
    ("cs:932f7686", "Louis Tomlinson", I, "wrong_plausible"),
    ("cs:27bca867", "Venuši", C, "inflect"),
    ("cs:27bca867", "Merkur", I, "wrong_plausible"),
    ("cs:0830cc7d", "stříbrem", C, "inflect"),
    ("cs:0830cc7d", "zlato", I, "wrong_plausible"),
    ("cs:2896283e", "plyn etylen", C, "paraphrase"),
    ("cs:2896283e", "metan", I, "wrong_plausible"),
    ("cs:a822f59d", "ďasa", C, "inflect"),
    ("cs:a822f59d", "murena", I, "wrong_plausible"),
    ("cs:fd623190", "písek ze Sahary", C, "paraphrase"),
    ("cs:fd623190", "Gobi", I, "wrong_plausible"),
    ("cs:edab36a4", "tahání za lano", C, "paraphrase"),
    ("cs:edab36a4", "kriket", I, "wrong_plausible"),
    ("cs:99d505ea", "Haleyho kometa", C, "stt"),
    ("cs:99d505ea", "Hale-Bopp", I, "soundalike_other"),
    ("cs:e5c76e10", "křenem", C, "inflect"),
    ("cs:e5c76e10", "hořčice", I, "wrong_plausible"),
    ("cs:a0eac58d", "Kanada a Rusko", I, "wrong_plausible"),
    ("cs:f12ff131", "z diamantů", C, "inflect"),
    ("cs:f12ff131", "rubín", I, "wrong_plausible"),
    ("cs:cdcb3755", "z rajčat", I, "misconception"),
    ("cs:d3e90bd4", "protože pořád padají kolem Země", C, "paraphrase"),
    ("cs:d3e90bd4", "protože tam není gravitace", I, "misconception"),
    ("cs:6aa6b188", "devadesát devět celých devadesát čtyři", C, "number"),
    ("cs:6aa6b188", "devadesát devět celých čtyři", I, "number"),
    ("cs:65e3f927", "sedum", C, "stt"),
    ("cs:65e3f927", "osm", I, "number"),
    ("cs:6ffb1eae", "dva krát", C, "number"),
    ("cs:6ffb1eae", "tři", I, "number"),
    ("x:praha", "Prahu", C, "inflect"),
    # ── English ──
    ("en:3fdd0ab9", "shakes beer", C, "stt"),
    ("en:3fdd0ab9", "Charles Dickens", I, "wrong_plausible"),
    ("en:b01aa938", "the number four", C, "paraphrase"),
    ("en:b01aa938", "five", I, "number"),
    ("en:99559613", "forty below zero", C, "number"),
    ("en:99559613", "zero", I, "number"),
    ("en:52512815", "M and M's", C, "stt"),
    ("en:52512815", "Skittles", I, "wrong_plausible"),
    ("en:d8f17bc5", "toy store", C, "stt"),
    ("en:d8f17bc5", "Shrek", I, "wrong_plausible"),
    ("en:b2e894fe", "Maria Kerry", C, "stt"),
    ("en:b2e894fe", "Whitney Houston", I, "wrong_plausible"),
    ("en:afb101f2", "coke", C, "paraphrase"),
    ("en:afb101f2", "Pepsi", I, "wrong_plausible"),
    ("en:3f12ed10", "mendeleevium", C, "stt"),
    ("en:3f12ed10", "Mendeleev", I, "different_entity"),
    ("en:a70fcf8b", "Sansibar", C, "stt"),
    ("en:27a84fc0", "Paraguay", I, "wrong_plausible"),
    ("en:266355c6", "Lesuto", C, "stt"),
    ("en:266355c6", "Swaziland", I, "wrong_plausible"),
    ("en:d4bf78e4", "the skeleton sled", C, "paraphrase"),
    ("en:d4bf78e4", "luge", I, "wrong_plausible"),
    ("en:82fa5e5b", "power bird", C, "stt"),
    ("en:82fa5e5b", "magpie", I, "wrong_plausible"),
    ("en:abe73817", "Esher", C, "stt"),
    ("en:abe73817", "Salvador Dali", I, "wrong_plausible"),
    ("en:b5d4030a", "Thor", I, "different_entity"),
    ("en:5e4bc825", "koala", I, "wrong_plausible"),
    ("en:84e88b51", "Quincy Adams", C, "partial_name"),
    ("en:84e88b51", "John Adams", I, "soundalike_other"),
    ("en:7f513a73", "Kyoto", I, "soundalike_other"),
    ("en:a4238404", "a pine apple", C, "stt"),
    ("en:3143c525", "vampire bats", C, "inflect"),
    ("en:3143c525", "leech", I, "wrong_plausible"),
    ("en:7d01902b", "President Taft", C, "partial_name"),
    ("en:7d01902b", "Grover Cleveland", I, "wrong_plausible"),
    ("x:monet", "Manet", I, "soundalike_other"),
    ("x:monet", "Mo nay", C, "stt"),
    ("x:henry", "Henry the seventh", I, "number"),
    ("x:iran", "Iraq", I, "soundalike_other"),
    ("x:parachute", "the parachute never opened", C, "paraphrase"),
    ("x:parachute", "a heart attack", I, "wrong_clear"),
    ("x:lincoln", "Lincoln", C, "partial_name"),
]

# MCQ questions for the parser (options from the corpus where possible).
MCQ = {
    "berries": ("sk", "sk:a928cf39"),
    "saunas": ("sk", "sk:90acd238"),
    "islands": ("sk", "sk:7e0c66f0"),
    "planet_cs": ("cs", ("Která planeta je největší ve sluneční soustavě?", {"a": "Mars", "b": "Jupiter", "c": "Saturn", "d": "Venuše"}, "b", "authored")),
    "planet_en": ("en", ("Which planet is the largest in the solar system?", {"a": "Mars", "b": "Jupiter", "c": "Saturn", "d": "Venus"}, "b", "authored")),
}

# (question ref, heard, required intents, forbidden intents, answer check)
# answer check: str fragment that must appear in the extracted answer (folded),
#               or "mcq:<key>" — extracted answer must resolve to that option.
PARSE = [
    # Slovak
    ("sk:75634579", "myslím, že je to sokol sťahovavý", ["answer"], ["skip"], "sokol"),
    ("sk:0a0ba41c", "hmm neviem, asi Venezuela", ["answer"], ["skip"], "venezuela"),
    ("sk:0a0ba41c", "neviem, preskoč túto otázku", ["skip"], ["answer"], None),
    ("sk:0a0ba41c", "toto fakt neviem, daj ďalšiu otázku", ["skip"], ["answer"], None),
    ("sk:8fc9b176", "Paraguaj, super otázka mimochodom", ["answer", "rating"], [], "paraguaj"),
    ("sk:8fc9b176", "zopakuj mi tú otázku prosím", [], ["answer"], None),
    ("sk:2312b30b", "čo je to vlastne ten kôrovec?", [], ["answer"], None),
    ("sk:c2e3d05c", "Hliník. Táto otázka sa mi vôbec nepáči", ["answer", "rating"], [], "hlinik"),
    ("sk:e2fd6bf2", "uhm, počkaj, to je tá... Beyoncé", ["answer"], ["skip"], "beyonce"),
    ("sk:9e8c2ebd", "pemza, lebo pláva na vode", ["answer"], ["skip"], "pemza"),
    ("sk:9e8c2ebd", "končím, na dnes mi to stačilo", ["quit"], ["answer"], None),
    ("sk:cc7082a3", "no tak to bude asi ten Jupiter", ["answer"], ["skip"], "jupiter"),
    ("sk:97778415", "fakt nemám šajn, preskoč", ["skip"], ["answer"], None),
    ("mcq:berries", "hmm počkaj, myslím, že to bude tá druhá možnosť", ["answer"], ["skip"], "mcq:b"),
    ("mcq:berries", "banán nie, dám jahodu", ["answer"], ["skip"], "mcq:b"),
    ("mcq:saunas", "určite to bude to prvé, Fínsko predsa", ["answer"], ["skip"], "mcq:a"),
    ("mcq:islands", "dám tretiu možnosť, to je moja odpoveď", ["answer"], ["skip"], "mcq:c"),
    ("mcq:islands", "myslím že Švédsko, ale nie som si istý", ["answer"], ["skip"], "mcq:c"),
    # Czech
    ("cs:eb92a5b7", "myslím si, že je to Vídeň", ["answer"], ["skip"], "vide"),
    ("cs:eb92a5b7", "nevím, dej další otázku", ["skip"], ["answer"], None),
    ("cs:eb92a5b7", "tohle nevím, přeskoč to prosím", ["skip"], ["answer"], None),
    ("cs:9d148f41", "Curling, to je skvělá otázka", ["answer", "rating"], [], "curling"),
    ("cs:5965f766", "co to vlastně znamená pakový led?", [], ["answer"], None),
    ("cs:5965f766", "zopakuj mi to ještě jednou prosím", [], ["answer"], None),
    ("cs:168ae470", "to je ten první letoun... Wright Flyer", ["answer"], ["skip"], "flyer"),
    ("cs:65e3f927", "sedm, stejně jako u člověka", ["answer"], ["skip"], "sedm"),
    ("cs:27bca867", "je to Venuše, ta otázka byla moc lehká", ["answer", "rating"], [], "venus"),
    ("cs:27bca867", "končím, už nechci hrát", ["quit"], ["answer"], None),
    ("mcq:planet_cs", "myslím, že to bude to béčko", ["answer"], ["skip"], "mcq:b"),
    ("mcq:planet_cs", "Saturn ne, takže Jupiter", ["answer"], ["skip"], "mcq:b"),
    # English
    ("en:7f513a73", "I think it's Tokyo, but this question is too easy", ["answer", "rating"], [], "tokyo"),
    ("en:7f513a73", "um I'm not sure, skip this one", ["skip"], ["answer"], None),
    ("en:7f513a73", "can you repeat the question please", [], ["answer"], None),
    ("en:abe73817", "what does lithograph even mean", [], ["answer"], None),
    ("en:baa096ab", "Which bird can sleep while flying? The alpine swift", ["answer"], ["skip"], "alpine swift"),
    ("en:5e4bc825", "let me think... a wombat", ["answer"], ["skip"], "wombat"),
    ("en:5e4bc825", "I don't know this one", ["skip"], ["answer"], None),
    ("en:5e4bc825", "stop the quiz I'm done", ["quit"], ["answer"], None),
    ("en:99559613", "minus forty degrees I think", ["answer"], ["skip"], "forty"),
    ("en:9a4e37d9", "Monopoly. Great question!", ["answer", "rating"], [], "monopoly"),
    ("en:7f513a73", "rate this question 3, the answer is Tokyo", ["answer", "rating"], [], "tokyo"),
    ("mcq:planet_en", "I'll go with the second one I guess", ["answer"], ["skip"], "mcq:b"),
    ("mcq:planet_en", "not Saturn... it's Jupiter", ["answer"], ["skip"], "mcq:b"),
]


def _corpus():
    rows = {}
    for lang, f in (("sk", "sk-review.json"), ("cs", "cs-review.json")):
        for r in json.loads((CORPUS / f).read_text()):
            rows[f"{lang}:{r['id'][:8]}"] = (lang, r, f"{CORPUS.name}/{f}#{r['id']}")
    for r in json.loads((ROOT / "apps/quiz-agent/questions_export.json").read_text()):
        rows[f"en:{r['id'][-8:]}"] = ("en", r, f"apps/quiz-agent/questions_export.json#{r['id']}")
    return rows


def _question(ref, rows):
    if ref.startswith("x:"):
        lang, q, a, alts, src = AUTHORED[ref[2:]]
        return lang, {"question": q, "correct_answer": a, "alternative_answers": alts, "possible_answers": None}, src
    if ref.startswith("mcq:"):
        lang, spec = MCQ[ref[4:]]
        if isinstance(spec, str):
            _, r, src = rows[spec]
            return lang, {k: r.get(k) for k in ("question", "correct_answer", "alternative_answers", "possible_answers")}, src
        q, opts, key, src = spec
        return lang, {"question": q, "correct_answer": key, "alternative_answers": [], "possible_answers": opts}, src
    lang, r, src = rows[ref]
    return lang, {k: r.get(k) for k in ("question", "correct_answer", "alternative_answers", "possible_answers")}, src


def main():
    rows = _corpus()
    out = []
    for n, (ref, heard, exp, tag) in enumerate(GRADE):
        lang, q, src = _question(ref, rows)
        out.append({"id": f"g{n:03d}", "role": "grade", "lang": lang, "tag": tag, "heard": heard,
                    "expected": exp, "question": q, "source": src})
    for n, (ref, heard, req, forb, check) in enumerate(PARSE):
        lang, q, src = _question(ref, rows)
        out.append({"id": f"p{n:03d}", "role": "parse", "lang": lang, "heard": heard,
                    "required": req, "forbidden": forb, "answer_check": check,
                    "question": q, "source": src})
    path = HERE / "cases.jsonl"
    path.write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in out))
    print(f"wrote {len(out)} cases → {path}")


if __name__ == "__main__":
    main()
