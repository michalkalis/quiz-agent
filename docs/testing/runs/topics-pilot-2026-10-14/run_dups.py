"""#203: list a run's questions for the intra-run same-fact review.

Generation dedups only against prod, so one fact can come out twice inside a run
(pilot: France–Brazil border in en, sk and cs; the Jáchymov dollar twice in cs).
Embedding cosine caught the same-language pair (0.89) but missed most cross-language
ones (bread in the fridge en/cs, wombat en/cs below 0.55), so the review is an LLM
pass: a Sonnet subagent reads this list and names same-fact pairs. On the pilot it
found all 8 pairs with no false positive.
Pairing rule for the reviewer: same language, or en vs sk/cs (en rows reach every
player); sk vs cs never meet a player. Drop rule: keep the en row (it still reaches
sk/cs players through translation) and drop the sk/cs copy; within one language drop
the later one.
Usage: run_dups.py <run-dir> > list.txt   (one line: id [lang] question => answer)
"""

import json
import sys
from pathlib import Path

run = Path(sys.argv[1])
for p in sorted(run.glob("[A-Z]-[0-9]*.json")):
    if p.name.endswith("usage.json"):
        continue
    for i, q in enumerate(json.loads(p.read_text()), 1):
        answer = q["correct_answer"]
        answer = (q.get("possible_answers") or {}).get(str(answer), answer)
        print(f"{p.stem}#{i} [{q['language']}] {q['question']} => {answer}")
