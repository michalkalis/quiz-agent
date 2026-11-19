"""#231.4 batch 2: merge the reviewed Ukrainian questions into one import file.

Input: review/all-new.json (batch 2 + winter-holiday set + fresh entertainment, 240 rows),
review/review-{1,2,3}.json (independent editors: keep / fix / drop) and review/dups.json
(same-fact and spoiler pairs against the live rows and inside the batch).
A row survives when an editor kept it and the duplicate pass did not drop it; rows flagged
"reword" for a spoiler are dropped too unless REWORDED below gives them new text.
Output: merged-uk.json, dropped.json (id -> reason). Usage: python3 merge.py"""

import json
from pathlib import Path

RUN = Path(__file__).parent
REV = RUN / "review"
TAGS = {"seasonal": ["winter-holidays", "winter-holidays-2026"], "fresh": ["fresh-2026-w47"]}
# Session decisions on the duplicate pass (it applied the spoiler rule mechanically).
# Kept as they are: the "spoiled" answer is a household name (Гоголь, Шевченко, Чернівці…)
# that the other question only mentions in passing, without the fact that is asked.
VETO = {
    "18970fff", "de729fb0", "7a413a4b", "fe53ed67", "13035780", "06eb30ea", "0e9eb2ec",
    "98757607", "68c395e3", "e9659d75", "fa438ed6", "bb7d7856", "67c6c5c7", "594c78d4",
    "3653c0b6",  # the editor already cut the Titanic clue
}
# id8 -> (old, new): real spoilers where both questions are worth keeping, reworded.
REWORDED: dict[str, tuple[str, str]] = {
    "dbfa2048": ("Замок Паланок у Мукачеві стоїть", "Закарпатський замок Паланок стоїть"),
    "6c312982": ("У «Лісовій пісні» лісова дівчина", "У відомій драмі Лесі Українки лісова дівчина"),
    "1cfb606a": ("жила в Чернівцях", "жила в Україні"),
    "0188268a": ("На Андрія дівчата кидали", "Під час зимових ворожінь на судженого дівчата кидали"),
    "a876a7cc": ("На Андріївських вечорницях до калити", "На зимових вечорницях до коржа-калити"),
    "20a77da2": ("роллю гуцула Івана", "роллю Івана"),
    "6d73d814": (", коли Україна брала в ньому участь лише вдруге", ""),
    "fd6098df": ("Джеймс Кемерон не хотів, щоб у «Титаніку» звучала", "Режисер «Титаніка» не хотів, щоб у фільмі звучала"),
    "3c53c007": ("І Блохін 1975 року, і Бєланов 1986 року отримали", "Двоє гравців київського «Динамо», 1975 і 1986 року, отримали"),
    "a0e4d92b": ("взяті із суахілі", "взяті з африканської мови"),
}

rows = json.loads((REV / "all-new.json").read_text())
keep, fixes, dropped = set(), {}, {}
for n in (1, 2, 3):
    r = json.loads((REV / f"review-{n}.json").read_text())
    keep |= set(r["keep"])
    for f in r.get("fix", []):
        fixes.setdefault(f["id"], {})[f["field"]] = f["new"]
    for d in r.get("drop", []):
        dropped[d["id"]] = "editor: " + d["why"]
by8 = {q["id"][:8]: q["id"] for q in rows}
for d in json.loads((REV / "dups.json").read_text()):
    full = by8.get(d["target"][:8])
    if full is None or full not in keep:
        continue
    if d["kind"] == "spoiler" and d["target"][:8] in VETO | set(REWORDED):
        continue
    keep.discard(full)
    dropped[full] = f"{d['kind']} with {[i for i in d['ids'] if i[:8] != d['target'][:8]]}: {d['why']}"
assert keep | set(dropped) == {q["id"] for q in rows}, "a row has no decision"

out = []
for q in rows:
    if q["id"] not in keep:
        continue
    src = q.pop("_src")
    q.update(fixes.get(q["id"], {}))
    if q["id"][:8] in REWORDED:
        old, new = REWORDED[q["id"][:8]]
        assert old in q["question"], q["id"]
        q["question"] = q["question"].replace(old, new)
    if q["id"] in fixes and {"question", "correct_answer"} & set(fixes[q["id"]]) or q["id"][:8] in REWORDED:
        for f in ("embedding", "embedding_model", "embedding_dim", "embedding_qa", "embedding_qa_model"):
            q[f] = None  # text changed: the importer embeds it again
    assert q["language"] == "uk" and q.get("source_url"), q["id"]
    extra = TAGS.get(src.split("/")[0])
    if extra:
        q["tags"] = sorted(set(q.get("tags") or []) | set(extra))
    out.append(q)
(RUN / "merged-uk.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
(RUN / "dropped.json").write_text(json.dumps(dropped, ensure_ascii=False, indent=1))
print(f"kept {len(out)} of {len(rows)}; dropped {len(dropped)}")
