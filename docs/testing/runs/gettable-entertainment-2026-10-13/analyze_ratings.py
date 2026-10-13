"""#201.4: join the founder's blind ratings (ratings_raw/, exported from the rating page db) with blind_key.json."""
import glob, json, os
from statistics import mean

RUN = os.path.dirname(os.path.abspath(__file__))
key = json.load(open(f"{RUN}/blind_key.json"))
a_pct = {}
for lang in ("en", "sk"):
    for o in json.load(open(f"{RUN}/A-{lang}.casual.json")):
        a_pct[o["id"]] = o
rows = []
for f in glob.glob(f"{RUN}/ratings_raw/ratings/*.json"):
    rid = os.path.basename(f)[:-5]
    r = json.load(open(f))
    k = key[rid]
    cp = k["casual_player"] or a_pct.get(k["qid"]) or {}
    drop = cp.get("would_drop") if "would_drop" in cp else None
    rows.append({"id": rid, "lang": "en" if rid[0] == "E" else "sk", "arm": k["arm"], "fun": r["fun"],
                 "chance": r["chance"] == "yes", "pct": cp.get("pct"), "drop": bool(drop)})

def line(label, rs):
    if not rs:
        return
    print(f"{label:22} n={len(rs):2}  fun={mean(r['fun'] for r in rs):.1f}  chance={sum(r['chance'] for r in rs)}/{len(rs)}"
          f"  fun>=9={sum(r['fun'] >= 9 for r in rs)}")

for lang in ("en", "sk", None):
    sub = [r for r in rows if lang is None or r["lang"] == lang]
    print(f"--- {lang or 'all'}")
    for arm in ("A", "B-pass", "B-drop"):
        line(arm, [r for r in sub if r["arm"] == arm])
    line("B all", [r for r in sub if r["arm"] != "A"])
    line("checker pass (A+B)", [r for r in sub if r["pct"] is not None and not r["drop"]])
    line("checker drop (A+B)", [r for r in sub if r["pct"] is not None and r["drop"]])

scored = [r for r in rows if r["pct"] is not None]
print("--- calibration: checker pct bucket vs founder")
for lo, hi in ((0, 25), (25, 50), (50, 101)):
    line(f"pct {lo}-{hi - 1}", [r for r in scored if lo <= r["pct"] < hi])
n = len(scored)
mx, my = mean(r["pct"] for r in scored), mean(r["fun"] for r in scored)
cov = sum((r["pct"] - mx) * (r["fun"] - my) for r in scored)
sx = sum((r["pct"] - mx) ** 2 for r in scored) ** .5
sy = sum((r["fun"] - my) ** 2 for r in scored) ** .5
print(f"pearson(pct, fun) = {cov / (sx * sy):.2f} over n={n}")
