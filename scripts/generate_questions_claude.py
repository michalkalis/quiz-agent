#!/usr/bin/env python3
"""Generate high-quality quiz questions using Claude (Anthropic API).

Multi-stage pipeline:
  1. GENERATE — Claude creates questions with CoT reasoning + self-critique
  2. CRITIQUE — Separate LLM judge evaluates each question (6 dimensions)
  3. SELECT  — Top-scoring questions kept, rest discarded
  4. OUTPUT  — Terminal table, JSON file, and/or ChromaDB import

Usage:
  python scripts/generate_questions_claude.py
  python scripts/generate_questions_claude.py --count 15 --difficulty hard --topics "science,history"
  python scripts/generate_questions_claude.py --count 10 --best-of-n 3 --thinking --output questions.json
"""

import argparse
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from typing import Any

# Load .env before anything else
from dotenv import load_dotenv
load_dotenv()

# Add shared package and question-generator app to path
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "packages", "shared"))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "apps", "question-generator"))

from quiz_shared.models.question import Question
from app.generation.prompt_builder import PromptBuilder
from app.generation.storage import QuestionStorage

import anthropic

try:
    import openai as openai_lib
except ImportError:
    openai_lib = None


# ---------------------------------------------------------------------------
# Anthropic client helpers
# ---------------------------------------------------------------------------

def create_client() -> anthropic.Anthropic:
    """Create Anthropic client, verifying API key exists."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("Error: ANTHROPIC_API_KEY not set. Add it to .env or export it.")
        sys.exit(1)
    return anthropic.Anthropic(api_key=api_key)


def call_claude(
    client: anthropic.Anthropic,
    prompt: str,
    *,
    model: str,
    temperature: float = 0.8,
    max_tokens: int = 16384,
    system: str | None = None,
) -> str:
    """Send a prompt to Claude and return the text response."""
    kwargs: dict[str, Any] = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }
    if temperature != 1.0:
        kwargs["temperature"] = temperature
    if system:
        kwargs["system"] = system

    response = client.messages.create(**kwargs)
    return response.content[0].text


def call_claude_thinking(
    client: anthropic.Anthropic,
    prompt: str,
    *,
    model: str,
    thinking_budget: int = 8000,
    max_tokens: int = 16384,
    system: str | None = None,
) -> tuple[str, str]:
    """Send a prompt with extended thinking enabled.

    Returns (thinking_text, response_text).
    Extended thinking forces temperature=1.0 — set by the API automatically.
    """
    kwargs: dict[str, Any] = {
        "model": model,
        "max_tokens": max_tokens,
        "thinking": {"type": "enabled", "budget_tokens": thinking_budget},
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 1,  # required by extended thinking
    }
    if system:
        kwargs["system"] = system

    response = client.messages.create(**kwargs)

    thinking_text = ""
    response_text = ""
    for block in response.content:
        if block.type == "thinking":
            thinking_text = block.thinking
        elif block.type == "text":
            response_text = block.text

    return thinking_text, response_text


def call_openai(prompt: str, *, model: str, temperature: float = 0.3, max_tokens: int = 4096) -> str:
    """Call OpenAI API for cross-provider critique."""
    if openai_lib is None:
        raise RuntimeError("openai package not installed. Run: pip install openai")
    client = openai_lib.OpenAI()
    response = client.chat.completions.create(
        model=model,
        temperature=temperature,
        max_tokens=max_tokens,
        messages=[{"role": "user", "content": prompt}],
    )
    return response.choices[0].message.content


# ---------------------------------------------------------------------------
# JSON parsing
# ---------------------------------------------------------------------------

def strip_markdown_fences(content: str) -> str:
    """Remove ```json ... ``` wrappers that Claude likes to add."""
    content = content.strip()
    if content.startswith("```"):
        first_nl = content.find("\n")
        last_fence = content.rfind("```")
        if first_nl != -1 and last_fence > first_nl:
            content = content[first_nl + 1:last_fence].strip()
    return content


def extract_json_object(content: str) -> str:
    """Extract a JSON object from text (finds outermost { ... })."""
    content = strip_markdown_fences(content)
    start = content.find("{")
    end = content.rfind("}") + 1
    if start == -1 or end <= start:
        raise ValueError("No JSON object found in response")
    return content[start:end]


def parse_questions(content: str, difficulty: str, category: str) -> list[Question]:
    """Parse Claude's JSON response into Question objects."""
    questions: list[Question] = []

    try:
        json_str = extract_json_object(content)
        data = json.loads(json_str)
    except (ValueError, json.JSONDecodeError) as e:
        print(f"  JSON parse error: {e}")
        print(f"  Raw response (first 500 chars): {content[:500]}")
        return []

    # Handle both {"questions": [...]} and single-question format
    if "questions" in data:
        items = data["questions"]
    elif "question" in data:
        items = [data]
    else:
        print(f"  Unexpected JSON structure (keys: {list(data.keys())})")
        return []

    for q_data in items:
        try:
            q = dict_to_question(q_data, difficulty, category)
            questions.append(q)
        except Exception as e:
            print(f"  Skipping malformed question: {e}")
    return questions


def dict_to_question(data: dict, default_difficulty: str, default_category: str) -> Question:
    """Convert a dict from Claude's response into a Question object."""
    question_id = f"temp_{uuid.uuid4().hex[:8]}"

    # V2 CoT fields
    reasoning = data.get("reasoning", {})
    self_critique = data.get("self_critique", {})

    generation_metadata: dict[str, Any] = {}
    quality_ratings = None

    if reasoning:
        generation_metadata["reasoning"] = reasoning
    if self_critique:
        quality_ratings = {
            "surprise_factor": self_critique.get("surprise_factor", 0),
            "universal_appeal": self_critique.get("universal_appeal", 0),
            "clever_framing": self_critique.get("clever_framing", 0),
            "educational_value": self_critique.get("educational_value", 0),
        }
        generation_metadata["self_critique"] = self_critique
        generation_metadata["ai_score"] = self_critique.get("overall_score", 0)
        generation_metadata["ai_reasoning"] = self_critique.get("reasoning", "")

    return Question(
        id=question_id,
        question=data.get("question", ""),
        type=data.get("type", "text"),
        possible_answers=data.get("possible_answers"),
        correct_answer=data.get("correct_answer", ""),
        alternative_answers=data.get("alternative_answers", []),
        topic=data.get("topic", "General"),
        category=data.get("category", default_category),
        difficulty=data.get("difficulty", default_difficulty),
        tags=data.get("tags", []),
        language_dependent=data.get("language_dependent", False),
        source="generated",
        review_status="pending_review",
        quality_ratings=quality_ratings,
        generation_metadata=generation_metadata,
    )


# ---------------------------------------------------------------------------
# Pipeline stages
# ---------------------------------------------------------------------------

def format_facts_for_prompt(facts: list) -> str:
    """Format a list of Fact objects into a text section for the prompt.

    Args:
        facts: List of Fact objects from the sourcing layer

    Returns:
        Formatted string of numbered facts for injection into the prompt
    """
    lines = []
    for i, fact in enumerate(facts, 1):
        text = getattr(fact, "text", "")
        source_url = getattr(fact, "source_url", None)
        source_name = getattr(fact, "source_name", "unknown")
        topic = getattr(fact, "topic", "General")
        surprise = getattr(fact, "surprise_rating", 5.0)

        line = f"**Fact {i}** [Topic: {topic}, Surprise: {surprise}/10]"
        line += f"\n  {text}"
        if source_url:
            line += f"\n  Source: {source_name} ({source_url})"
        else:
            line += f"\n  Source: {source_name}"
        lines.append(line)

    return "\n\n".join(lines)


def stage_generate(
    client: anthropic.Anthropic,
    args: argparse.Namespace,
    prompt_builder: PromptBuilder,
    facts: list | None = None,
) -> list[Question]:
    """Stage 1: Generate questions in batches.

    Args:
        client: Anthropic client
        args: Parsed CLI arguments
        prompt_builder: PromptBuilder instance (V2 or V3 template)
        facts: Optional list of Fact objects for fact-first generation
    """
    multiplier = max(args.best_of_n, 1)
    total = args.count * multiplier
    batch_size = 10  # questions per API call
    all_questions: list[Question] = []

    topics = [t.strip() for t in args.topics.split(",")] if args.topics else None
    categories = [c.strip() for c in args.categories.split(",")]
    excluded = [t.strip() for t in args.excluded_topics.split(",")] if args.excluded_topics else None

    # Build extra kwargs for fact-first mode
    extra_kwargs = {}
    is_fact_first = facts is not None and len(facts) > 0
    if is_fact_first:
        extra_kwargs["facts_section"] = format_facts_for_prompt(facts)

    prompt_version = "v3_fact_first" if is_fact_first else "v2_cot"

    batches = (total + batch_size - 1) // batch_size  # ceiling division

    for i in range(batches):
        count = min(batch_size, total - len(all_questions))
        if count <= 0:
            break

        print(f"  Batch {i+1}/{batches}: requesting {count} questions...")

        prompt = prompt_builder.build_prompt(
            count=count,
            difficulty=args.difficulty,
            topics=topics,
            categories=categories,
            question_type=args.type,
            excluded_topics=excluded,
            **extra_kwargs,
        )

        t0 = time.time()
        response_text = call_claude(
            client, prompt,
            model=args.model,
            temperature=0.8,
            max_tokens=16384,
        )
        elapsed = time.time() - t0

        parsed = parse_questions(response_text, args.difficulty, categories[0])
        print(f"  Batch {i+1}: parsed {len(parsed)} questions ({elapsed:.1f}s)")

        # Tag generation metadata
        for q in parsed:
            q.generation_metadata = q.generation_metadata or {}
            q.generation_metadata.update({
                "model": args.model,
                "provider": "anthropic",
                "prompt_version": prompt_version,
                "temperature": 0.8,
                "stage": "initial_generation",
            })
            if is_fact_first:
                q.generation_metadata["pipeline"] = "fact_first"

        all_questions.extend(parsed)

    return all_questions


def stage_critique(
    client: anthropic.Anthropic,
    questions: list[Question],
    args: argparse.Namespace,
    critique_template: str,
    critique_model: str | None = None,
) -> list[tuple[Question, float]]:
    """Stage 2: Critique each question with LLM judge.

    Args:
        critique_model: Override model for critique. When set and starts with
            "gpt-" / "o1-" / "o3-", uses OpenAI API. When set and starts with
            "claude-", uses Claude API with that model. When None, uses args.model.
    """
    # Determine which model (and provider) to use for critique
    critique_model_used = critique_model or args.model
    use_openai = critique_model_used.startswith(("gpt-", "o1-", "o3-"))

    if use_openai:
        print(f"  Critique model: {critique_model_used} (OpenAI)")
    else:
        print(f"  Critique model: {critique_model_used} (Anthropic)")

    scored: list[tuple[Question, float]] = []

    for i, q in enumerate(questions):
        critique_prompt = critique_template.format(
            question=q.question,
            correct_answer=q.correct_answer,
            question_type=q.type,
            difficulty=q.difficulty,
            topic=q.topic,
        )

        try:
            thinking_text = ""

            if use_openai:
                # Cross-provider critique via OpenAI
                response_text = call_openai(
                    critique_prompt,
                    model=critique_model_used,
                    temperature=0.3,
                    max_tokens=4096,
                )
            elif args.thinking:
                thinking_text, response_text = call_claude_thinking(
                    client, critique_prompt,
                    model=critique_model_used,
                    thinking_budget=8000,
                )
            else:
                response_text = call_claude(
                    client, critique_prompt,
                    model=critique_model_used,
                    temperature=0.3,
                    max_tokens=4096,
                )

            json_str = extract_json_object(response_text)
            critique_data = json.loads(json_str)

            score = float(critique_data.get("overall_score", 5.0))
            verdict = critique_data.get("verdict", "acceptable")

            # Attach critique to question metadata
            q.generation_metadata = q.generation_metadata or {}
            q.generation_metadata.update({
                "critique": critique_data,
                "critique_model": critique_model_used,
                "critique_score": score,
                "critique_verdict": verdict,
                "thinking_enabled": args.thinking and not use_openai,
            })
            if thinking_text and args.verbose:
                q.generation_metadata["critique_thinking"] = thinking_text[:500]

            label = f"[{verdict}]"
            print(f"  {i+1}/{len(questions)}: {score:.1f}/10 {label:14s} {q.question[:60]}")

            if args.verbose and thinking_text:
                print(f"    Thinking: {thinking_text[:150]}...")

            scored.append((q, score))

        except Exception as e:
            print(f"  {i+1}/{len(questions)}: ERROR critiquing — {e}")
            scored.append((q, 5.0))  # fallback score

        # Small delay to be polite to the API
        if i < len(questions) - 1:
            time.sleep(0.1)

    return scored


def stage_select(
    scored: list[tuple[Question, float]],
    count: int,
    min_score: float,
) -> list[Question]:
    """Stage 3: Select top-N questions by score."""
    scored.sort(key=lambda x: x[1], reverse=True)
    selected = [q for q, s in scored[:count]]

    above = sum(1 for _, s in scored[:count] if s >= min_score)
    below = count - above
    if below > 0:
        print(f"  Warning: {below}/{count} selected questions scored below {min_score}")

    return selected


def stage_output(
    questions: list[Question],
    all_scored: list[tuple[Question, float]],
    args: argparse.Namespace,
) -> None:
    """Stage 4: Output results."""
    # --- Terminal summary ---
    print("\n" + "=" * 80)
    print(f"{'#':>3}  {'Score':>5}  {'Verdict':14s}  {'Diff':6s}  {'Topic':12s}  Question")
    print("-" * 80)

    for i, q in enumerate(questions):
        meta = q.generation_metadata or {}
        score = meta.get("critique_score", meta.get("ai_score", "—"))
        verdict = meta.get("critique_verdict", "—")
        score_str = f"{score:.1f}" if isinstance(score, (int, float)) else str(score)
        print(
            f"{i+1:>3}  {score_str:>5}  {verdict:14s}  {q.difficulty:6s}  "
            f"{q.topic[:12]:12s}  {q.question[:55]}"
        )

    # Stats
    scores_all = [s for _, s in all_scored]
    if scores_all:
        print("-" * 80)
        print(
            f"Generated: {len(all_scored)}  |  Selected: {len(questions)}  |  "
            f"Avg: {sum(scores_all)/len(scores_all):.1f}  |  "
            f"Min: {min(scores_all):.1f}  |  Max: {max(scores_all):.1f}"
        )
    print("=" * 80)

    # --- JSON file ---
    if args.output:
        output_data = {
            "questions": [q.model_dump(mode="json") for q in questions],
            "metadata": {
                "model": args.model,
                "provider": "anthropic",
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "total_generated": len(all_scored),
                "total_selected": len(questions),
                "pipeline": "fact_first" if getattr(args, "fact_first", False) else ("claude_best_of_n" if args.best_of_n > 0 else "claude_direct"),
                "prompt_version": "v3_fact_first" if getattr(args, "fact_first", False) else "v2_cot",
                "thinking_enabled": args.thinking,
                "min_score": args.min_score,
            },
        }
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(output_data, f, indent=2, ensure_ascii=False)
        print(f"\nSaved {len(questions)} questions to {args.output}")

    # --- ChromaDB import ---
    if args.import_to_db:
        print("\nImporting to ChromaDB...")
        storage = QuestionStorage()
        approved, failed = storage.bulk_approve(questions)
        print(f"  Approved: {len(approved)}")
        if failed:
            for q, reason in failed:
                print(f"  Failed: {q.question[:50]}... — {reason}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Generate quiz questions with Claude (Anthropic API)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--count", type=int, default=10, help="Number of final questions (default: 10)")
    p.add_argument("--difficulty", default="medium", choices=["easy", "medium", "hard"])
    p.add_argument("--topics", default=None, help="Comma-separated topics (e.g. 'science,history')")
    p.add_argument("--categories", default="adults", help="Comma-separated categories (default: adults)")
    p.add_argument("--type", default="text", choices=["text", "text_multichoice"])
    p.add_argument("--excluded-topics", default=None, help="Comma-separated topics to avoid")
    p.add_argument("--model", default="claude-opus-4-6", help="Claude model (default: claude-opus-4-6)")
    p.add_argument("--critique-model", default=None, help="Use a different model for critique stage (e.g. 'gpt-4o' for cross-provider critique). Default: same as --model")
    p.add_argument("--best-of-n", type=int, default=3, help="Multiplier for best-of-N selection. 0 = skip critique. (default: 3)")
    p.add_argument("--min-score", type=float, default=7.0, help="Minimum quality score (default: 7.0)")
    p.add_argument("--thinking", action="store_true", help="Use extended thinking for critique stage")
    p.add_argument("--output", "-o", default=None, help="Save JSON to file")
    p.add_argument("--input", "-i", default=None, help="Import pre-generated JSON file (skip generation, run import only)")
    p.add_argument("--import-to-db", action="store_true", help="Import to ChromaDB as pending_review")
    p.add_argument("--fact-first", action="store_true", help="Use fact-first (source-grounded) generation: source facts from Wikipedia, OpenTDB, news, then generate questions grounded in those facts")
    p.add_argument("--verbose", "-v", action="store_true", help="Show detailed progress")
    return p


def import_from_file(filepath: str) -> list[Question]:
    """Load questions from a pre-generated JSON file (e.g. from a Claude Code session)."""
    with open(filepath, "r", encoding="utf-8") as f:
        data = json.load(f)

    items = data.get("questions", data if isinstance(data, list) else [])
    questions: list[Question] = []
    for item in items:
        try:
            # Handle both raw dicts and already-serialized Question objects
            if "id" not in item or not item["id"]:
                item["id"] = f"temp_{uuid.uuid4().hex[:8]}"
            if "source" not in item:
                item["source"] = "generated"
            if "review_status" not in item:
                item["review_status"] = "pending_review"
            q = Question(**{k: v for k, v in item.items() if v is not None})
            questions.append(q)
        except Exception as e:
            print(f"  Skipping malformed question: {e}")
    return questions


def main() -> None:
    args = build_parser().parse_args()

    # --- Input mode: import pre-generated JSON ---
    if args.input:
        print(f"Importing from {args.input}...")
        questions = import_from_file(args.input)
        print(f"  Loaded {len(questions)} questions")

        if not questions:
            print("No valid questions found in file.")
            sys.exit(1)

        # Build scored list from self-critique scores
        scored = []
        for q in questions:
            meta = q.generation_metadata or {}
            ai_score = meta.get("ai_score", meta.get("critique_score", 5.0))
            scored.append((q, float(ai_score) if ai_score else 5.0))

        # Print summary
        scored.sort(key=lambda x: x[1], reverse=True)
        selected = [q for q, _ in scored[:args.count]]

        stage_output(selected, scored, args)
        return

    # --- Generation mode: call Claude API ---
    print(f"Claude Question Generator")
    print(f"Model: {args.model}  |  Count: {args.count}  |  Difficulty: {args.difficulty}")
    if args.fact_first:
        print("Mode: Fact-First (source-grounded generation)")
    if args.best_of_n > 0:
        print(f"Pipeline: Best-of-{args.best_of_n} (generate {args.count * args.best_of_n}, critique, select top {args.count})")
    else:
        print("Pipeline: Direct generation (no critique)")
    print()

    # --- Fact-First: Source facts before generation ---
    sourced_facts = None
    if args.fact_first:
        print("Stage 0: FACT SOURCING")
        t_start = time.time()
        try:
            import asyncio
            from app.sourcing import FactSourcer

            topics = [t.strip() for t in args.topics.split(",")] if args.topics else None
            sourcer = FactSourcer(
                enable_wikipedia=True,
                enable_opentdb=True,
                enable_news=True,
                enable_czech_slovak=True,
            )
            fact_batch = asyncio.run(sourcer.gather_facts(
                count=max(args.count * 3, 30),
                topics=topics,
            ))
            sourced_facts = fact_batch.facts
            print(f"  Sourced {len(sourced_facts)} facts ({time.time() - t_start:.1f}s)\n")

            if not sourced_facts:
                print("  Warning: No facts sourced. Falling back to standard generation.")
        except ImportError as e:
            print(f"  Error importing sourcing module: {e}")
            print("  Falling back to standard generation.\n")
        except Exception as e:
            print(f"  Error during fact sourcing: {e}")
            print("  Falling back to standard generation.\n")

    # --- Setup ---
    client = create_client()

    # Load prompt template (V3 fact-first or V2 CoT)
    prompts_dir = os.path.join(PROJECT_ROOT, "apps", "question-generator", "prompts")
    if sourced_facts:
        template_path = os.path.join(prompts_dir, "question_generation_v3_fact_first.md")
        if not os.path.exists(template_path):
            print("  Warning: V3 fact-first template not found, falling back to V2.")
            template_path = os.path.join(prompts_dir, "question_generation_v2_cot.md")
            sourced_facts = None  # fall back
    else:
        template_path = os.path.join(prompts_dir, "question_generation_v2_cot.md")
    prompt_builder = PromptBuilder(template_path=template_path)

    # Load critique template (prefer v2, fall back to v1)
    critique_path = os.path.join(prompts_dir, "question_critique_v2.md")
    if not os.path.exists(critique_path):
        critique_path = os.path.join(prompts_dir, "question_critique.md")
    with open(critique_path, "r", encoding="utf-8") as f:
        critique_template = f.read()

    # --- Stage 1: Generate ---
    print("Stage 1: GENERATE")
    t_start = time.time()
    questions = stage_generate(client, args, prompt_builder, facts=sourced_facts)
    print(f"  Total: {len(questions)} questions generated ({time.time() - t_start:.1f}s)\n")

    if not questions:
        print("No questions generated. Check the API response above.")
        sys.exit(1)

    # --- Stage 2 & 3: Critique + Select ---
    if args.best_of_n > 0:
        print("Stage 2: CRITIQUE")
        t_start = time.time()
        scored = stage_critique(client, questions, args, critique_template, critique_model=args.critique_model)
        print(f"  Critiqued {len(scored)} questions ({time.time() - t_start:.1f}s)\n")

        print("Stage 3: SELECT")
        selected = stage_select(scored, args.count, args.min_score)
        print(f"  Selected top {len(selected)} questions\n")
    else:
        # No critique — use self-critique scores from generation
        scored = []
        for q in questions:
            meta = q.generation_metadata or {}
            ai_score = meta.get("ai_score", 5.0)
            scored.append((q, float(ai_score) if ai_score else 5.0))
        selected = questions[:args.count]

    # --- Stage 4: Output ---
    print("Stage 4: OUTPUT")
    stage_output(selected, scored, args)


if __name__ == "__main__":
    main()
