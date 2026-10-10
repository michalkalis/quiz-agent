#!/usr/bin/env python3
"""#197 track 197.4 — replay car answer recordings through today's voice path.

Every recording the founder's TestFlight build uploaded (Settings › voice
diagnostics › "Save answer recordings") is run again through the CURRENT code
and models: STT → ``parse_answer_intents`` → ``AnswerEvaluator`` — the same
functions ``/voice/submit`` calls, so a change to STT, parser or grader model
(``STT_*`` / ``LLM_*`` env, #196) shows up here as an accuracy number.

Expected result per sample = the founder's label when there is one (197.3),
else what the app decided at the time (``appDecision`` in the sidecar). So an
unlabeled run measures DRIFT from production; a labeled one measures accuracy.

Sources (pick one):
    --server https://quiz-agent-api.fly.dev   pulls GET /api/v1/voice-samples
                                              (needs ADMIN_API_KEY) into --cache
    --folder ~/Downloads/AnswerRecordings     an exported folder: <stamp>.wav +
                                              <stamp>.json [+ <stamp>.label.json
                                              {"transcript","decision"} or the
                                              older <stamp>.ref.txt]

STT (``--stt``): ``prod`` (default, the live transcriber with quiz context and
MCQ keyterms), ``sidecar`` (no STT call: reuse what prod heard — grader only),
or a single provider from stt_compare.py (``scribe``, ``gpt-transcribe``…).

Usage (repo root, backend env loaded from .env):
    uv run --no-sync python scripts/voice_replay.py --server https://quiz-agent-api.fly.dev
Report → docs/testing/runs/voice-replay-<date>/report.md
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import os
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "packages" / "shared"))
sys.path.insert(0, str(ROOT / "apps" / "quiz-agent"))
sys.path.insert(0, str(ROOT / "scripts"))

from stt_compare import wer

NOT_CORRECT_WRONGLY = {"incorrect", "partially_incorrect"}


@dataclass
class Sample:
    id: str
    wav_path: Path
    sidecar: dict
    label: dict | None = None

    @property
    def expected_decision(self) -> str | None:
        if self.label and self.label.get("decision"):
            return self.label["decision"]
        return self.sidecar.get("appDecision")

    @property
    def reference_transcript(self) -> str | None:
        return (self.label or {}).get("transcript")


@dataclass
class Replay:
    sample: Sample
    transcript: str
    decision: str
    error: str | None = None


@dataclass
class Summary:
    total: int = 0
    scored: int = 0
    matches: int = 0
    correct_marked_wrong: int = 0
    wrong_marked_correct: int = 0
    wer_vs_label: list[float] = field(default_factory=list)
    wer_vs_prod: list[float] = field(default_factory=list)

    @property
    def accuracy(self) -> float | None:
        return self.matches / self.scored if self.scored else None


def summarize(replays: list[Replay]) -> Summary:
    """The scoring math. A sample counts toward decision accuracy only when an
    expected decision exists and is a real verdict (an ``error`` at record time
    says nothing about the grader). "Correct marked wrong" is the founder's
    headline failure: the answer was right and the app said it wasn't."""
    s = Summary(total=len(replays))
    for r in replays:
        expected = r.sample.expected_decision
        if r.error is None and expected and expected != "error":
            s.scored += 1
            s.matches += r.decision == expected
            if expected == "correct" and r.decision != "correct":
                s.correct_marked_wrong += 1
            if expected != "correct" and r.decision == "correct":
                s.wrong_marked_correct += 1
        if r.error is not None:
            continue
        if r.sample.reference_transcript:
            s.wer_vs_label.append(wer(r.sample.reference_transcript, r.transcript))
        prod = r.sample.sidecar.get("transcript")
        if prod:
            s.wer_vs_prod.append(wer(prod, r.transcript))
    return s


def question_from_sidecar(sidecar: dict):
    """The question exactly as the app showed it (translated text + options,
    the served correct answer), so a Slovak answer is graded against Slovak."""
    from quiz_shared.models.question import Question

    if not sidecar.get("questionText") or not sidecar.get("correctAnswer"):
        return None
    options = sidecar.get("options") or None
    return Question(
        id=sidecar.get("questionId") or "replay",
        question=sidecar["questionText"],
        type="text_multichoice" if options else "text",
        possible_answers=options,
        correct_answer=sidecar["correctAnswer"],
        headline_answer=sidecar.get("headlineAnswer"),
        topic="replay",
        category="replay",
        difficulty="medium",
    )


async def decide(
    transcript: str, question, parser, evaluator, *, valid: bool = True
) -> str:
    """Mirror of ``/voice/submit`` after transcription, in the app's decision
    vocabulary (see iOS ``AnswerRecordingStore.Decision``)."""
    from app.evaluation.evaluator import UNMATCHED
    from app.quiz.flow import parse_answer_intents

    if not valid or not transcript.strip():
        return "not_captured:no_speech"
    intents = await parse_answer_intents(
        transcript, question, "awaiting_answer", parser
    )
    for intent in intents:
        kind = intent.get("intent_type")
        if kind == "answer":
            answer = (intent.get("extracted_data") or {}).get("answer") or ""
            result, _ = await evaluator.evaluate(answer, question, question.question)
            return "not_captured:mcq_unmatched" if result == UNMATCHED else result
        if kind == "skip":
            return "skipped"
    return "not_captured:no_answer"


async def transcribe(sample: Sample, question, stt: str) -> tuple[str, bool]:
    from app.evaluation.mcq_matcher import label_keyterms, match_option, option_labels
    from app.voice.transcriber import VoiceTranscriber

    if stt == "sidecar":
        return sample.sidecar.get("transcript") or "", True
    wav = sample.wav_path.read_bytes()
    language = sample.sidecar.get("language")
    if stt != "prod":
        from stt_compare import run_provider

        return await run_provider(stt, wav, sample.wav_path.name, language), True
    options = question.possible_answers if question else None
    keyterms = (
        [str(v) for v in options.values()]
        + label_keyterms(option_labels(options), language)
        if options
        else []
    )
    result = await VoiceTranscriber().transcribe_with_quiz_context(
        audio_file=io.BytesIO(wav),
        filename=sample.wav_path.name,
        current_question=question.question if question else None,
        language=language,
        keyterms=keyterms,
    )
    min_chars = 1 if match_option(result.text, options) else 2
    return result.text, result.is_valid(min_chars=min_chars)


def load_folder(folder: Path) -> list[Sample]:
    samples = []
    for wav in sorted(folder.glob("*.wav")):
        sidecar_path = wav.with_suffix(".json")
        sidecar = json.loads(sidecar_path.read_text()) if sidecar_path.exists() else {}
        label = None
        label_path = folder / f"{wav.stem}.label.json"
        ref_path = folder / f"{wav.stem}.ref.txt"
        if label_path.exists():
            label = json.loads(label_path.read_text())
        elif ref_path.exists():
            label = {"transcript": ref_path.read_text().strip()}
        samples.append(Sample(id=wav.stem, wav_path=wav, sidecar=sidecar, label=label))
    return samples


def pull_from_server(server: str, cache: Path) -> None:
    import httpx

    key = os.environ.get("ADMIN_API_KEY")
    if not key:
        raise SystemExit("ADMIN_API_KEY is required for --server")
    cache.mkdir(parents=True, exist_ok=True)
    resp = httpx.get(
        f"{server.rstrip('/')}/api/v1/voice-samples",
        headers={"X-Admin-Key": key},
        timeout=60,
    )
    resp.raise_for_status()
    for item in resp.json()["items"]:
        wav_path = cache / f"{item['id']}.wav"
        if not wav_path.exists():
            wav_path.write_bytes(httpx.get(item["audio_url"], timeout=60).content)
        (cache / f"{item['id']}.json").write_text(json.dumps(item["sidecar"], indent=2))
        label_path = cache / f"{item['id']}.label.json"
        if item.get("label"):
            label_path.write_text(json.dumps(item["label"], indent=2))
        elif label_path.exists():
            label_path.unlink()


def _fmt(value: float | None, pct: bool = False) -> str:
    if value is None:
        return "–"
    return f"{value:.0%}" if pct else f"{value:.2f}"


def _mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def render_report(
    replays: list[Replay], summary: Summary, stt: str, models: str
) -> str:
    lines = [
        f"# Voice replay — {date.today().isoformat()}",
        "",
        f"STT: `{stt}` · {models}",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Samples | {summary.total} |",
        f"| Decision accuracy (vs label, else app decision) | {_fmt(summary.accuracy, pct=True)} ({summary.matches}/{summary.scored}) |",
        f"| Correct answers marked wrong | {summary.correct_marked_wrong} |",
        f"| Wrong answers marked correct | {summary.wrong_marked_correct} |",
        f"| Mean WER vs label transcript | {_fmt(_mean(summary.wer_vs_label))} (n={len(summary.wer_vs_label)}) |",
        f"| Mean WER vs prod transcript | {_fmt(_mean(summary.wer_vs_prod))} (n={len(summary.wer_vs_prod)}) |",
        "",
        "| Sample | Lang | Type | Prod heard | Replay heard | Expected | Replay | |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in replays:
        sc = r.sample.sidecar
        expected = r.sample.expected_decision or "–"
        source = "label" if (r.sample.label or {}).get("decision") else "app"
        mark = "ERR" if r.error else ("ok" if r.decision == expected else "DIFF")
        replay = r.error or r.decision
        lines.append(
            f"| {r.sample.id} | {sc.get('language', '')} | {sc.get('questionType', '')} "
            f"| {sc.get('transcript') or ''} | {r.transcript} | {expected} ({source}) | {replay} | {mark} |"
        )
    return "\n".join(lines) + "\n"


async def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--server")
    source.add_argument("--folder", type=Path)
    parser.add_argument(
        "--cache", type=Path, default=Path.home() / ".cache" / "trubbo-voice-samples"
    )
    parser.add_argument("--stt", default="prod")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument(
        "--out",
        type=Path,
        default=ROOT
        / "docs"
        / "testing"
        / "runs"
        / f"voice-replay-{date.today().isoformat()}",
    )
    args = parser.parse_args()

    from dotenv import load_dotenv

    load_dotenv(ROOT / ".env")
    from app.evaluation.evaluator import AnswerEvaluator
    from app.input.parser import InputParser

    folder = args.folder
    if args.server:
        pull_from_server(args.server, args.cache)
        folder = args.cache
    samples = load_folder(folder)[: args.limit]
    if not samples:
        print(f"no samples in {folder}", file=sys.stderr)
        return 1

    input_parser, evaluator = InputParser(), AnswerEvaluator()
    replays: list[Replay] = []
    for sample in samples:
        question = question_from_sidecar(sample.sidecar)
        if question is None:
            replays.append(
                Replay(sample, "", "", error="no question context in sidecar")
            )
            continue
        try:
            text, valid = await transcribe(sample, question, args.stt)
            decision = await decide(
                text, question, input_parser, evaluator, valid=valid
            )
            replays.append(Replay(sample, text, decision))
        except Exception as exc:
            replays.append(Replay(sample, "", "", error=f"error: {exc}"))
        print(f"{sample.id}: {replays[-1].decision or replays[-1].error}")

    summary = summarize(replays)
    args.out.mkdir(parents=True, exist_ok=True)
    report = args.out / "report.md"
    models = f"parser `{input_parser.model}` · grader `{evaluator.model}`"
    report.write_text(render_report(replays, summary, args.stt, models))
    print(
        f"\naccuracy {_fmt(summary.accuracy, pct=True)} ({summary.matches}/{summary.scored}) → {report}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
