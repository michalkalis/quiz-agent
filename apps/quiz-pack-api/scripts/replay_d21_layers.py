"""D21 replay — run pipeline layers over the rated experiment questions.

Runs AFTER the founder has rated the batch (D21/D27 ordering). Each layer
judges the same raw questions the humans rated; correlate_d21.py then joins
both sides and computes per-layer agreement with human taste.

One command (from apps/quiz-pack-api/, prod-mirroring env set by caller):

    LLM_GATEWAY=openrouter uv run --no-sync python scripts/replay_d21_layers.py

Layers: critique, duels (within-arm ring-3 pairwise), answerability,
judges (MultiModelScorer panel), verify (FactVerifier web check, D27).
Results merge into `<run-dir>/replay_results.json` after EVERY layer, so a
crashed run resumes where it stopped; a layer already present is skipped
(--force-layer to redo one).
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

DEFAULT_RUN_DIR = (
    Path(__file__).resolve().parents[3] / "docs" / "testing" / "runs"
    / "d21-round-2026-08-15"
)
LAYERS = ("critique", "duels", "answerability", "judges", "verify")
CONCURRENCY = 4


def _load_questions(run_dir: Path):
    """(arm, Question) pairs from every generated arm file in the manifest."""
    from quiz_shared.models.question import Question

    manifest = json.loads((run_dir / "manifest.json").read_text())
    pairs = []
    for arm in manifest["arms"]:
        path = run_dir / f"{arm}.json"
        if not path.exists():
            continue
        for entry in json.loads(path.read_text()):
            pairs.append((arm, Question.from_dict(entry)))
    return pairs


def _answer_str(q) -> str:
    a = q.correct_answer
    return " / ".join(str(x) for x in a) if isinstance(a, list) else str(a)


async def _map_limited(coros, limit=CONCURRENCY):
    sem = asyncio.Semaphore(limit)

    async def _one(coro):
        async with sem:
            return await coro

    return await asyncio.gather(*(_one(c) for c in coros), return_exceptions=True)


def _entry(results: dict, arm: str, q) -> dict:
    e = results.setdefault(
        q.id, {"arm": arm, "question": q.question, "answer": _answer_str(q)}
    )
    return e


async def _layer_critique(pairs, results):
    from app.generation.advanced_generator import AdvancedQuestionGenerator

    gen = AdvancedQuestionGenerator()
    out = await _map_limited([gen._critique_question(q) for _, q in pairs])
    for (arm, q), res in zip(pairs, out):
        if isinstance(res, Exception):
            res = {"error": str(res)}
        _entry(results, arm, q)["critique"] = res


async def _layer_duels(pairs, results):
    """Within-arm ring-3 pairwise duels → per-question win rate.

    Mirrors `_select_top_pairwise` (ring neighbours, alternating A/B flip,
    same prompt/parser/judge model) but keeps per-question win counts instead
    of a top-N selection — selection loses the granularity correlation needs.
    """
    from langchain.schema import HumanMessage

    from app.generation.advanced_generator import AdvancedQuestionGenerator

    gen = AdvancedQuestionGenerator()
    by_arm: dict[str, list] = {}
    for arm, q in pairs:
        by_arm.setdefault(arm, []).append(q)

    async def _duel(a, b, flip):
        qa, qb = (b, a) if flip else (a, b)
        prompt = gen._PAIRWISE_PROMPT.format(
            a=gen._render_question_for_judge(qa),
            b=gen._render_question_for_judge(qb),
        )
        resp = await gen.critique_llm.ainvoke([HumanMessage(content=prompt)])
        winner = gen._parse_pairwise_winner(resp.content)
        if winner is None:
            return None
        return (qa if winner == "A" else qb).id

    jobs, meta = [], []
    for arm, qs in by_arm.items():
        n = len(qs)
        # ring pairs, deduped
        seen = set()
        for i in range(n):
            for step in (1, 2, 3):
                j = (i + step) % n
                pair = tuple(sorted((i, j)))
                if i == j or pair in seen:
                    continue
                seen.add(pair)
                jobs.append(_duel(qs[pair[0]], qs[pair[1]], flip=bool(sum(pair) % 2)))
                meta.append((arm, qs[pair[0]].id, qs[pair[1]].id))
    outcomes = await _map_limited(jobs)

    wins: dict[str, int] = {}
    played: dict[str, int] = {}
    for (arm, id_a, id_b), winner_id in zip(meta, outcomes):
        if isinstance(winner_id, Exception) or winner_id is None:
            continue
        for qid in (id_a, id_b):
            played[qid] = played.get(qid, 0) + 1
        wins[winner_id] = wins.get(winner_id, 0) + 1
    for arm, q in pairs:
        e = _entry(results, arm, q)
        p = played.get(q.id, 0)
        e["duels"] = {
            "wins": wins.get(q.id, 0),
            "played": p,
            "win_rate": (wins.get(q.id, 0) / p) if p else None,
        }


async def _layer_answerability(pairs, results):
    from app.verification.answerability import AnswerabilityChecker

    checker = AnswerabilityChecker()
    out = await _map_limited([checker.check(q) for _, q in pairs])
    for (arm, q), res in zip(pairs, out):
        if isinstance(res, Exception):
            payload = {"error": str(res)}
        else:
            payload = {
                "passed": res.passed,
                "reason": res.reason,
                "model_answer": res.model_answer,
            }
        _entry(results, arm, q)["answerability"] = payload


async def _layer_judges(pairs, results):
    from app.scoring.multi_model_scorer import MultiModelScorer

    scorer = MultiModelScorer()
    sem = asyncio.Semaphore(CONCURRENCY)
    out = await asyncio.gather(
        *(
            scorer.score_question(
                question=q.question,
                answer=_answer_str(q),
                difficulty=q.difficulty or "medium",
                topic=q.topic or "General",
                possible_answers=q.possible_answers,
                semaphore=sem,
            )
            for _, q in pairs
        ),
        return_exceptions=True,
    )
    for (arm, q), res in zip(pairs, out):
        if isinstance(res, Exception):
            res = {"error": str(res)}
        _entry(results, arm, q)["judges"] = res


async def _layer_verify(pairs, results):
    from app.verification.fact_verifier import FactVerifier

    verifier = FactVerifier()
    out = await _map_limited(
        [
            verifier.verify(
                question=q.question,
                claimed_answer=_answer_str(q),
                topic=q.topic or "",
            )
            for _, q in pairs
        ]
    )
    for (arm, q), res in zip(pairs, out):
        if isinstance(res, Exception):
            payload = {"error": str(res)}
        else:
            payload = {
                "verdict": res.verdict,
                "confidence": res.confidence,
                "held_for_review": getattr(res, "held_for_review", False),
                "notes": getattr(res, "notes", None),
            }
        _entry(results, arm, q)["verify"] = payload


async def _main(args) -> int:
    run_dir = Path(args.run_dir)
    out_path = run_dir / "replay_results.json"
    results = json.loads(out_path.read_text()) if out_path.exists() else {}
    pairs = _load_questions(run_dir)
    if not pairs:
        raise SystemExit(f"no arm files found in {run_dir}")
    print(f"{len(pairs)} questions across arms")

    runners = {
        "critique": _layer_critique,
        "duels": _layer_duels,
        "answerability": _layer_answerability,
        "judges": _layer_judges,
        "verify": _layer_verify,
    }
    for layer in args.layers.split(","):
        layer = layer.strip()
        if layer not in runners:
            raise SystemExit(f"unknown layer: {layer}")
        done = results and all(layer in e for e in results.values())
        if done and layer != args.force_layer:
            print(f"== {layer}: already replayed, skipping")
            continue
        print(f"== {layer}")
        await runners[layer](pairs, results)
        out_path.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
        errs = sum(
            1
            for e in results.values()
            if isinstance(e.get(layer), dict) and e[layer].get("error")
        )
        print(f"   saved ({errs} errors)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", default=str(DEFAULT_RUN_DIR))
    parser.add_argument("--layers", default=",".join(LAYERS))
    parser.add_argument("--force-layer", default=None, help="redo this layer even if present")
    args = parser.parse_args()
    return asyncio.run(_main(args))


if __name__ == "__main__":
    raise SystemExit(main())
