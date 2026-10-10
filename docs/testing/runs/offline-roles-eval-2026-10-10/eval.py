"""#196 track 196.4 — offline quiz-pack-api helper roles: current vs Claude.

Runs the PRODUCTION call sites (same prompts, parsers, guards) with the model
swapped, and writes ``results_<role>.json`` next to this file. Run from
``apps/quiz-pack-api`` with the worktree's ``packages/shared`` +
``apps/quiz-pack-api`` on PYTHONPATH, root ``.env`` (+ app ``.env``) loaded
and ``LLM_GATEWAY=direct``:

    python <this> expiry|topics|otdb|hint|silhouette|vision|sourcing [--n N]

Cost: LangChain calls are metered by the app's own usage recorder; the
native-SDK sourcing calls are metered from each response's usage block
(+ $10/1k web searches on both providers).
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import io
import json
import random
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = Path(
    "/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/"
    "apps/quiz-pack-api/data"
)

from quiz_shared.llm import factory as llm_factory  # noqa: E402

from app import llm_usage  # noqa: E402

# gpt-5.6-sol is not in the app price table; ASSUMED list price for the
# spend cap only (conservative). Bedrock deepseek is priced in the table.
EXTRA_PRICES = {"gpt-5.6-sol": (5.00, 40.00)}

RECORDER = llm_usage.UsageRecorder()
llm_factory.set_usage_handler(llm_usage.UsageCallbackHandler(RECORDER))


def usage_cents() -> float:
    total = 0.0
    for (_, model), b in RECORDER._data.items():
        price = llm_usage._price_for_model(model)
        if price is not None:
            total += (b["input_tokens"] * price["input"] + b["output_tokens"] * price["output"]) / 1e4
            continue
        for key, (pin, pout) in EXTRA_PRICES.items():
            if key in model:
                total += (b["input_tokens"] * pin + b["output_tokens"] * pout) / 1e4
    return round(total, 3)


def save(role: str, payload: dict) -> None:
    payload["metered_cost_cents"] = usage_cents() if "cost_cents" not in payload else payload["cost_cents"]
    (HERE / f"results_{role}.json").write_text(json.dumps(payload, indent=1, ensure_ascii=False))
    print(json.dumps(payload.get("summary", {}), indent=1, ensure_ascii=False))
    print("cost cents:", payload["metered_cost_cents"])


# --- expiry classifier ------------------------------------------------------

async def run_expiry(models: list[str], runs: int) -> None:
    from quiz_shared.models.question import Question

    from app.generation import expiry_classifier as ec

    items = [json.loads(line) for line in (HERE / "expiry_set.jsonl").read_text().splitlines()]
    out: dict = {"items": items, "runs": {}, "summary": {}}
    for model in models:
        ec._CLASSIFIER_MODEL = model
        per_run = []
        for run in range(runs):
            order = list(range(len(items)))
            random.Random(run).shuffle(order)
            qs = [
                Question(id=f"q{i}", question=items[i]["q"], correct_answer=items[i]["a"],
                         topic="General", category="adults", difficulty="medium")
                for i in order
            ]
            t0 = time.time()
            res = await ec.ExpiryClassifier(api_key="x").classify(qs)
            dt = time.time() - t0
            preds = {order[k]: (r.content_class if r else None) for k, r in enumerate(res)}
            per_run.append({"seconds": round(dt, 1), "pred": [preds[i] for i in range(len(items))]})
        out["runs"][model] = per_run
        correct = [sum(p["pred"][i] == it["label"] for i, it in enumerate(items)) for p in per_run]
        # Worst error: a "current" question stamped evergreen never expires.
        critical = [sum(it["label"] == "current" and p["pred"][i] == "evergreen" for i, it in enumerate(items)) for p in per_run]
        missing = [sum(p["pred"][i] is None for i in range(len(items))) for p in per_run]
        out["summary"][model] = {"n": len(items), "correct_per_run": correct, "current_as_evergreen": critical,
                                 "unclassified": missing, "seconds": [p["seconds"] for p in per_run]}
    save("expiry", out)


# --- topic planner ----------------------------------------------------------

_BROAD = {"science", "history", "nature", "geography", "art", "music", "sport", "sports", "food",
          "technology", "space", "general knowledge", "trivia", "random facts", "culture"}
_MILITARY = re.compile(r"\b(war|wars|military|weapon|weapons|battle|army|navy|missile|tank|soldier|siege)\b", re.I)


async def run_topics(models: list[str], runs: int) -> None:
    from app.sourcing.topic_planner import TopicPlanner

    out: dict = {"runs": {}, "summary": {}}
    for model in models:
        lists = []
        for _ in range(runs):
            lists.append(await TopicPlanner(model=model, topic_count=5).propose())
        out["runs"][model] = lists
        flat = [t for lst in lists if lst for t in lst]
        out["summary"][model] = {
            "parsed_runs": sum(1 for lst in lists if lst),
            "topics": len(flat),
            "unique_across_runs": len({t.lower() for t in flat}),
            "broad_or_generic": sum(t.lower() in _BROAD for t in flat),
            "military": sum(bool(_MILITARY.search(t)) for t in flat),
            "word_count_out_of_2_6": sum(not (2 <= len(t.split()) <= 6) for t in flat),
        }
    save("topics", out)


# --- OpenTriviaDB rewriter --------------------------------------------------

async def run_otdb(models: list[str], n: int) -> None:
    from app.sourcing.opentriviadb_source import OpenTriviaFactRewriter, _fact_echoes_question

    raw = json.loads((HERE / "otdb_raw.json").read_text())["results"][:n]
    dec = lambda s: base64.b64decode(s).decode()  # noqa: E731
    items = [{"q": dec(r["question"]), "a": dec(r["correct_answer"]), "type": dec(r["type"])} for r in raw]
    out: dict = {"items": items, "outputs": {}, "summary": {}}
    for model in models:
        rw = OpenTriviaFactRewriter(model=model)
        outs = [await rw.rewrite(it["q"], it["a"]) for it in items]
        out["outputs"][model] = outs
        ok = [o for o in outs if o]
        out["summary"][model] = {
            "returned": len(ok), "n": len(items),
            "over_25_words": sum(len(o.split()) > 25 for o in ok),
            "echoes_question": sum(_fact_echoes_question(o, it["q"]) for o, it in zip(outs, items) if o),
            "says_the_answer_is": sum("the answer is" in o.lower() for o in ok),
            "answer_present_mc": sum(1 for o, it in zip(outs, items)
                                     if o and it["type"] == "multiple" and it["a"].lower() in o.lower()),
            "mc_items": sum(it["type"] == "multiple" for it in items),
        }
    save("otdb", out)


# --- hint-image question text -----------------------------------------------

EXTRA_HINT_SEEDS = [
    {"topic": "Geography", "correct_answer": "Venice", "difficulty": "easy"},
    {"topic": "Music", "correct_answer": "The Beatles", "difficulty": "medium"},
    {"topic": "Film", "correct_answer": "Titanic", "difficulty": "easy"},
    {"topic": "Science", "correct_answer": "Photosynthesis", "difficulty": "medium"},
    {"topic": "History", "correct_answer": "The Fall of the Berlin Wall", "difficulty": "hard"},
]
_TRIGGERS = ["book", "cover", "poster", "sign", "title", "logo", "text", "words", "letters"]
_ENDING = "No text, no words, no letters, no writing anywhere in the image."


def _answer_tokens(answer: str) -> list[str]:
    stop = {"the", "of", "and", "fall", "landing"}
    return [w for w in re.findall(r"[a-z]+", answer.lower()) if len(w) >= 4 and w not in stop]


def run_hint(models: list[str]) -> None:
    from app.image_generation import hint_images as hi

    seeds = json.loads((DATA / "hint_image_seeds.json").read_text()) + EXTRA_HINT_SEEDS
    out: dict = {"seeds": seeds, "outputs": {}, "summary": {}}
    for model in models:
        hi.QUESTION_MODEL = model
        outs = []
        for s in seeds:
            try:
                outs.append(hi.generate_hint_image_prompt(s["topic"], s["correct_answer"], s["difficulty"]))
            except Exception as e:  # noqa: BLE001
                outs.append({"error": repr(e)[:200]})
        out["outputs"][model] = outs
        valid = [(o, s) for o, s in zip(outs, seeds) if "image_prompt" in o and "question" in o]

        def leaks(text: str, ans: str) -> bool:
            return any(re.search(rf"\b{t}\b", text.lower()) for t in _answer_tokens(ans))

        body = lambda p: p.replace(_ENDING, "")  # noqa: E731
        out["summary"][model] = {
            "valid_json": len(valid), "n": len(seeds),
            "answer_in_image_prompt": sum(leaks(o["image_prompt"], s["correct_answer"]) for o, s in valid),
            "answer_in_question": sum(leaks(o["question"], s["correct_answer"]) for o, s in valid),
            "trigger_word_in_prompt": sum(any(re.search(rf"\b{t}s?\b", body(o["image_prompt"]).lower()) for t in _TRIGGERS) for o, _ in valid),
            "missing_required_ending": sum(not o["image_prompt"].strip().endswith(_ENDING) for o, _ in valid),
        }
    save("hint", out)


# --- silhouette question text ----------------------------------------------

COUNTRIES = [("Italy", "easy"), ("Japan", "easy"), ("Chile", "medium"), ("Norway", "medium"),
             ("New Zealand", "medium"), ("Greece", "hard"), ("Cuba", "medium"), ("India", "easy"),
             ("United Kingdom", "medium"), ("Australia", "easy")]


def run_silhouette(models: list[str]) -> None:
    from app.image_generation.silhouette_questions import generate_silhouette_question_text

    out: dict = {"countries": COUNTRIES, "outputs": {}, "summary": {}}
    for model in models:
        outs = []
        for c, d in COUNTRIES:
            try:
                outs.append(generate_silhouette_question_text(c, d, model=model))
            except Exception as e:  # noqa: BLE001
                outs.append({"error": repr(e)[:200]})
        out["outputs"][model] = outs
        valid = [(o, c) for o, (c, _) in zip(outs, COUNTRIES) if "question" in o]
        out["summary"][model] = {
            "valid_json": len(valid), "n": len(COUNTRIES),
            "names_country_in_question": sum(c.lower() in o["question"].lower() for o, c in valid),
            "has_alternative_answers": sum(bool(o.get("alternative_answers")) for o, _ in valid),
        }
    save("silhouette", out)


# --- hint-image validation (vision) ----------------------------------------

def _png(img) -> bytes:
    img = img.convert("RGB")
    img.thumbnail((768, 768))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def vision_set() -> list[dict]:
    from PIL import Image, ImageDraw, ImageFont

    hint_dir = DATA / "generated/hint_images/images"
    sil_dir = DATA / "generated/silhouettes/images"
    answers = {"beethoven": "Beethoven", "dna": "DNA", "the_great_gatsby": "The Great Gatsby",
               "the_mona_lisa": "The Mona Lisa", "the_moon_landing": "The Moon Landing"}
    font = ImageFont.load_default(size=64)
    items = []
    for stem, ans in answers.items():
        img = Image.open(hint_dir / f"{stem}.png")
        items.append({"id": f"hint/{stem}", "answer": ans, "has_text": False, "img": _png(img)})
        # Same painting with a caption burned in — the defect stage 3 exists to catch.
        cap = img.convert("RGB").copy()
        draw = ImageDraw.Draw(cap)
        draw.rectangle([0, cap.height - 140, cap.width, cap.height], fill=(245, 240, 225))
        draw.text((40, cap.height - 115), "VISIT OUR MUSEUM TODAY", fill=(20, 20, 20), font=font)
        items.append({"id": f"hint/{stem}+caption", "answer": ans, "has_text": True, "img": _png(cap)})
    for c in ["italy", "japan", "chile", "norway", "greece"]:
        nice = c.title()
        items.append({"id": f"sil/{c}", "answer": nice, "has_text": False, "img": _png(Image.open(sil_dir / f"{c}.png"))})
        items.append({"id": f"sil/{c}_labeled", "answer": nice, "has_text": True,
                      "img": _png(Image.open(sil_dir / f"{c}_labeled.png"))})
    return items


def run_vision(models: list[str]) -> None:
    from app.image_generation import hint_images as hi

    items = vision_set()
    out: dict = {"items": [{k: v for k, v in it.items() if k != "img"} for it in items], "outputs": {}, "summary": {}}
    for model in models:
        hi.VALIDATION_MODEL = model
        outs = []
        for it in items:
            try:
                outs.append(hi.validate_image(it["img"], it["answer"]))
            except Exception as e:  # noqa: BLE001
                outs.append({"error": repr(e)[:200]})
        out["outputs"][model] = outs
        valid = [(o, it) for o, it in zip(outs, items) if isinstance(o.get("has_text"), bool)]
        out["summary"][model] = {
            "valid_json": len(valid), "n": len(items),
            "has_text_correct": sum(o["has_text"] == it["has_text"] for o, it in valid),
            "missed_text": sum(it["has_text"] and not o["has_text"] for o, it in valid),
            "false_text": sum(not it["has_text"] and o["has_text"] for o, it in valid),
            "labeled_silhouette_flagged_too_obvious": sum(bool(o.get("too_obvious")) for o, it in valid if it["id"].endswith("_labeled")),
            "would_pass_gate": sum((not o["has_text"]) and (o.get("quality_score") or 0) >= 7 and not o.get("too_obvious") for o, _ in valid),
            "would_pass_gate_on_text_images": sum((not o["has_text"]) and (o.get("quality_score") or 0) >= 7 and not o.get("too_obvious") for o, it in valid if it["has_text"]),
        }
    save("vision", out)


# --- web-search fact sourcing ----------------------------------------------

SOURCING_TOPICS = ["deep-sea bioluminescence", "the history of the printing press", "2026 Oscars",
                   "volcanic islands of Iceland", "the history of chocolate", "Formula 1 in 2026"]


def _norm(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower())


async def _grounded(client, url: str, excerpt: str) -> str:
    """'yes'/'no' — does the cited page contain the excerpt (>=60 % of its
    word trigrams)? 'unfetchable' when the page can't be read (403 etc.)."""
    try:
        r = await client.get(url, follow_redirects=True, timeout=20)
        if r.status_code != 200:
            return "unfetchable"
        page = " ".join(_norm(re.sub(r"<[^>]+>", " ", r.text)))
    except Exception:  # noqa: BLE001
        return "unfetchable"
    words = _norm(excerpt)
    grams = [" ".join(words[i:i + 3]) for i in range(max(1, len(words) - 2))]
    hit = sum(g in page for g in grams) / max(1, len(grams))
    return "yes" if hit >= 0.6 else "no"


async def run_sourcing(models: list[str], n: int, offset: int = 0) -> None:
    import httpx

    from app.sourcing.openai_web_search_source import OpenAIWebSearchSource

    topics = SOURCING_TOPICS[offset:offset + n]
    out: dict = {"topics": topics, "facts": {}, "summary": {}}
    total_cents = 0.0
    async with httpx.AsyncClient(headers={"User-Agent": "Mozilla/5.0 (quiz-agent eval)"}) as web:
        for model in models:
            src = OpenAIWebSearchSource(model=model)
            meter = {"in": 0, "out": 0, "searches": 0, "calls": 0}
            if src._anthropic:
                orig = src.client.messages.create

                async def wrapped(*a, _o=orig, **k):
                    resp = await _o(*a, **k)
                    meter["calls"] += 1
                    meter["in"] += resp.usage.input_tokens + (resp.usage.cache_read_input_tokens or 0) + (resp.usage.cache_creation_input_tokens or 0)
                    meter["out"] += resp.usage.output_tokens
                    stu = getattr(resp.usage, "server_tool_use", None)
                    meter["searches"] += getattr(stu, "web_search_requests", 0) or 0
                    return resp
                src.client.messages.create = wrapped
            else:
                orig = src.client.responses.create

                async def wrapped(*a, _o=orig, **k):
                    resp = await _o(*a, **k)
                    meter["calls"] += 1
                    meter["in"] += resp.usage.input_tokens
                    meter["out"] += resp.usage.output_tokens
                    meter["searches"] += sum(1 for it in resp.output if getattr(it, "type", None) == "web_search_call")
                    return resp
                src.client.responses.create = wrapped
            rows, secs = [], []
            for t in topics:
                t0 = time.time()
                facts = await src.get_facts(count=5, topics=[t])
                secs.append(round(time.time() - t0, 1))
                for f in facts:
                    rows.append({"topic": t, "fact": f.text, "excerpt": f.excerpt, "url": f.source_url,
                                 "credibility": f.credibility,
                                 "grounded": await _grounded(web, f.source_url, f.excerpt)})
            price = llm_usage._price_for_model(model)
            cents = (meter["in"] * price["input"] + meter["out"] * price["output"]) / 1e4 + meter["searches"] * 1.0
            total_cents += cents
            out["facts"][model] = rows
            g = [r["grounded"] for r in rows]
            out["summary"][model] = {
                "facts": len(rows), "topics_with_facts": len({r["topic"] for r in rows}), "topics": len(topics),
                "grounded_yes": g.count("yes"), "grounded_no": g.count("no"), "unfetchable": g.count("unfetchable"),
                "credibility_high": sum(r["credibility"] == "high" for r in rows),
                "seconds_per_topic": secs, "meter": meter, "cost_cents": round(cents, 2),
            }
    out["cost_cents"] = round(total_cents, 2)
    save("sourcing" if not offset else f"sourcing_part{offset + 1}", out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("role")
    ap.add_argument("--models", required=True, help="comma-separated, current first")
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    args = ap.parse_args()
    models = args.models.split(",")
    r = args.role
    if r == "expiry":
        asyncio.run(run_expiry(models, args.n or 2))
    elif r == "topics":
        asyncio.run(run_topics(models, args.n or 5))
    elif r == "otdb":
        asyncio.run(run_otdb(models, args.n or 20))
    elif r == "hint":
        run_hint(models)
    elif r == "silhouette":
        run_silhouette(models)
    elif r == "vision":
        run_vision(models)
    elif r == "sourcing":
        asyncio.run(run_sourcing(models, args.n or 6, args.offset))
    else:
        sys.exit(f"unknown role {r}")


if __name__ == "__main__":
    main()
