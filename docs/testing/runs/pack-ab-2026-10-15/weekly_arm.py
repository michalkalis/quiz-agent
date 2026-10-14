"""#203 203.9 blind test, #202 arm: one weekly-job dry run on the subscription, questions dumped to JSON.
Usage (from apps/quiz-pack-api, PYTHONPATH set): FRESH_TOPUP_SESSION=1 FRESH_HOUSE_STYLE=0|1 weekly_arm.py <lang> <count> <out.json>
"""
import json
import sys

from app.corpus import fresh_pins

fresh_pins.apply()

from app.corpus import importer  # noqa: E402  pins must come first
from app.corpus.fresh_topup import main  # noqa: E402

lang, count, out = sys.argv[1], sys.argv[2], sys.argv[3]
real = importer.import_questions


async def dump_then_import(questions, **kw):
    with open(out, "w") as f:
        json.dump([q.model_dump(mode="json") for q in questions], f, ensure_ascii=False, indent=1)
    return await real(questions, **kw)


importer.import_questions = dump_then_import
sys.exit(main(["--dry-run", "--languages", lang, "--count", count]))
