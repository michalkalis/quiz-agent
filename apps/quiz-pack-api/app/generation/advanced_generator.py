"""Advanced question generator with multi-stage quality pipeline.

This implements:
1. Chain of Thought reasoning during generation
2. Best-of-N selection with LLM judge
3. Multi-stage critique → regenerate loop
4. Quality metadata tracking
"""

import asyncio
import json
import re
from typing import List, Optional, Dict, Any, Literal
from langchain_core.messages import HumanMessage
from pydantic import BaseModel, Field, ValidationError

from quiz_shared.llm import factory as llm_factory

import os

from quiz_shared.models.question import GenerationProvenance, Question
from .prompt_builder import PromptBuilder, STRUCTURED_MCQ_FORMAT_NOTE
from .pattern_routing import verification_mode
from .examples import example_corpus_path, load_gold_standard, load_anti_patterns
from ..scoring.multi_model_scorer import resolve_correct_answer
from .. import feature_flags

try:
    from ..sourcing.models import Fact
except ImportError:
    Fact = None  # sourcing package not installed


# Stable id for the current ("fun") generation pipeline, stamped on every
# question's provenance so rows from this flow stay distinguishable from legacy
# imports and older runs even if a model id later repeats (issue #72 —
# distinguish question sources). Bump when the flow materially changes.
GENERATION_FLOW = "fun-redesign-72"


# Issue #76 F-3a — category→prompt-file registry for the fact-first dispatch.
# A category listed here gets its own generation prompt (a fact-first variant of
# v3); `_build_batch_prompt` selects the matching builder over the generic v3 one
# for an order whose category is registered. General map, not an entertainment
# special-case, so kids/themed register later by adding one line — no new branch
# (decisions 3, 2d). An unregistered category falls through to v3 unchanged.
_CATEGORY_PROMPT_FILES = {
    "entertainment": "question_generation_entertainment.md",
}

# 2026-07-30 (generation review A2) — every fact-first template must carry
# every injection placeholder. A missing one silently disables quality
# machinery: entertainment shipped without `{craft_guards_section}`, so the
# #99 guards were a no-op for every entertainment order even with the flag on.
# Checked at generator construction so a broken template fails the app at
# boot, not mid-order.
_REQUIRED_FACT_FIRST_PLACEHOLDERS = (
    "{facts_section}",
    "{escape_hatch_section}",
    "{craft_guards_section}",
    "{mcq_patterns_section}",
    "{response_format_section}",
    "{process_header}",
)

# Splits the cacheable static prefix (role, contract, patterns, examples,
# order specs) from per-call dynamic content (fact slice, MCQ pattern pin,
# count). Under the OpenRouter gateway with an Anthropic generation model the
# static half is sent as a `cache_control` block — the five concurrent MCQ
# sub-batch calls share one prefix, and any sequential reuse (top-up,
# follow-up order) reads it from cache instead of re-paying for it
# (generation review section B). Other providers just get the marker stripped;
# static-first ordering still helps their implicit prefix caching.
CACHE_BREAKPOINT_MARKER = "<!--CACHE_BREAKPOINT-->"


# Issue #72 — per-question source attribution. Tokeniser for matching a
# generated question back to the specific source Fact it was built from, so each
# question cites its OWN fact's URL instead of the whole pack inheriting one
# global URL (the "every question looks military" misattribution). The small
# stopword set keeps the overlap score driven by content words, not glue words.
_SOURCE_MATCH_STOPWORDS = frozenset({
    "the", "and", "for", "with", "from", "are", "was", "were", "been", "its",
    "this", "that", "these", "those", "which", "who", "what", "when", "where",
    "how", "why", "than", "then", "into", "about", "over", "after", "before",
    "more", "most", "some", "any", "all", "one", "two", "first", "also", "has",
    "have", "had", "but", "not", "you", "your", "they", "their", "them",
})


def _content_tokens(*texts: object) -> set[str]:
    """Lowercased alphanumeric content tokens (len >= 3, stopwords removed).

    The match key for `_best_matching_fact`: shared content words between a
    question and a fact signal that the question was built from that fact.
    """
    tokens: set[str] = set()
    for text in texts:
        if not text:
            continue
        for raw in re.findall(r"[a-z0-9]+", str(text).lower()):
            if len(raw) >= 3 and raw not in _SOURCE_MATCH_STOPWORDS:
                tokens.add(raw)
    return tokens


# Issue #72 P2.2 (Lever B / RC-5) — the v3 escape hatch. Dormant unless the
# `V3_ESCAPE_HATCH` flag is on. v3's hard rule ("rely ONLY on source facts,
# never your own knowledge") leaves no room for a surprising *angle*, which is
# why output stays "prvoplánové". This loosens the rule for the *framing* only
# — the core factual claim (the answer) must still trace to a source fact, so
# grounding (the reason v3 exists) is preserved. Begins with a blank line so it
# appends cleanly to the grounding rule of THE CONTRACT; empty when the flag is
# off keeps flag-off output byte-identical. Fully revertible (flip the flag
# off). Wording is direction-neutral ("provided source facts") because the
# static-first template ordering (2026-07-30) places the facts BELOW this rule.
_V3_ESCAPE_HATCH_SECTION = """

   **Escape Hatch: A Surprising Angle (the answer still traces to a source).** You MAY draw a surprising *angle, comparison, or framing* from your own general knowledge to make a question more engaging — on **one strict condition: the core factual claim (the answer the player must reach) still traces to one of the provided source facts.** Use general knowledge for the *angle*, never for the *answer*. NOT allowed: an answer whose correctness depends on a fact that is not in the SOURCE FACTS list — if the angle only works with an unsourced fact, drop it. When you use this, `source_excerpt` must still confirm the answer."""


# Issue #72 Phase 3 / 2026-07-30 consolidation — founder-calibrated CRAFT
# GUARDS, injected only when `GEN_CRAFT_GUARDS` is on. The RULES themselves
# moved into THE CONTRACT (always on, deduplicated — generation review
# section B); what stays behind the flag are the founder's worked
# illustrations and carve-outs, which are the calibration data the contract's
# terse rules can't carry. Calibration: founder rating sessions 2026-07-09/10
# and #99 G3 blind-rating 2026-07-15; examples verbatim from those sessions.
_V3_CRAFT_GUARDS_SECTION = """

**Craft guards — founder-calibrated illustrations (apply together with the rules above):**

- **Stem leak** (rule 6). BAD: "The myth that Napoleon was short came from British wartime propaganda. Which country's cartoonists spread it?" → "Britain" — the stem already says it. Re-read every stem as the player: any word handing over the answer → rewrite.
- **Deductive giveaway** (rule 6). BAD: "every British tank has a built-in boiling vessel — what beverage is it designed to make?" → tea (British + beverage: the stereotype answers for you). BAD: "the only U.S. state made up of two distinct peninsulas" → Michigan (the frame is a lookup key). BAD: "a Renaissance genius sketched a diving suit… who designed it?" → Leonardo da Vinci (famous-inventor reputation). Fix: ask about the surprising detail instead of the identity the frame gives away.
- **Clue pile** (rule 7). BAD: "known for its ancient empire, iconic amphitheater, gladiators…" — one sharp hook, never a list of properties.
- **Unanchored referent** (rule 8). BAD: "a citizen called a 'hippeus' owned which animal?" (term never glossed); a temperature record with no year or era; "appear the same size" with no vantage point. Context evicted from the answer by the word cap lands in the stem as a NEUTRAL anchor — never as a category hint, never dropped entirely.
- **Telegraphed T/F → transform** (rule 15). "St Andrews originally had 22 holes — true or false?" becomes "How many holes did the Old Course at St Andrews originally have?" with options.
- **Convoluted stem** (rule 10). BAD: "you're never more than six miles from a body of water" — double condition in imperial units; forces a second listen.
- **Answer context payoff** (rule 9). `explanation` is read aloud after the reveal: 1–2 sentences of genuinely interesting context (where, how big, why surprising) — never empty, never a restatement.

**Carve-outs — do NOT over-apply the rules:**

- An **estimable numeric is a GOOD open question**: heart beats per day — count your pulse and multiply. Ban only numerics with no reasoning path (rule 5).
- An **iconic source figure may keep imperial in parentheses**: "100 °F (38 °C)" (rule 10).
- **Exact years are right** when the year IS the question (`year_guess`, rule 11) and in every entertainment date anchor."""


class MCQQuestionItem(BaseModel):
    """One structured multiple-choice question (#42 task 42.25).

    Mirrors the subset of ``Question`` fields the generation LLM must fill
    for an MCQ. ``type`` is a fixed ``Literal`` so the model cannot fall
    back to free-form ``text`` — the v3 template's ``possible_answers:
    null`` example was the root cause of the collapsed MCQ yield (2/13).
    Binding this via ``with_structured_output`` turns the contract into a
    parse-time guarantee that prompt instructions alone could not enforce.
    """

    question: str = Field(..., description="The question text")
    possible_answers: Dict[str, str] = Field(
        ...,
        description="Answer options keyed by letter, e.g. {'a': 'True', 'b': 'False'}",
    )
    correct_answer: str = Field(
        ..., description="Key letter of the correct option, e.g. 'a'"
    )
    type: Literal["text_multichoice"] = "text_multichoice"
    explanation: Optional[str] = Field(
        None, description="Short factual context for the answer"
    )
    # 2026-07-27 live-run F-e — the structured contract must carry the model's
    # per-question assessment (topic was missing entirely, so every MCQ row
    # landed as topic="General"; category/difficulty had no filling
    # instruction, so the code fallback stamped "general"/"medium" pack-wide).
    topic: Optional[str] = Field(
        None, description="Subject of the question, e.g. 'Geography' or 'Music'"
    )
    category: Optional[str] = Field(
        None,
        description=(
            "Player-facing category filter id. When the prompt names an order "
            "category, copy it exactly; otherwise classify this question as "
            "one of: general | adults | kids | wizarding-world | superheroes "
            "| disney | football | sports-mix (use 'general' when nothing "
            "themed fits)"
        ),
    )
    difficulty: Optional[str] = Field(
        None,
        description=(
            "easy | medium | hard — honest per-question assessment for a "
            "non-native-English adult player, never one value copied across "
            "the batch"
        ),
    )
    language_dependent: bool = Field(
        False,
        description=(
            "True if the fact holds only as an English lexical convention and "
            "breaks under literal translation: wordplay, spelling, letter "
            "counts, acronyms, and also collective nouns ('a murder of "
            "crows'), idioms, proverbs, English-only naming quirks (#128)"
        ),
    )
    age_appropriate: Optional[str] = Field(
        None,
        description=(
            "Minimum recommended age band: 'all' | '8+' | '12+' | '16+'"
        ),
    )
    pattern_used: Optional[str] = Field(
        None,
        description="snake_case reasoning-pattern key, e.g. 'true_false' or 'odd_one_out'",
    )
    # 2026-07-30 generation review A4 — craft guard "name the wrong assumption"
    # was unenforceable on the structured MCQ path because the schema had no
    # field to carry it. Also feeds the critique judge context.
    why_interesting: Optional[str] = Field(
        None,
        description=(
            "The wrong assumption the player starts from and how the answer "
            "overturns it. If none exists, the question is plain recall — "
            "pick a different fact or framing instead of emitting it"
        ),
    )
    # 2026-07-27 live-run F-d: the structured MCQ contract had no source
    # fields at all, so every MCQ question depended on the token-overlap
    # matcher for attribution — the airport-runway/Library-of-Alexandria
    # misattribution. Letting the model copy the exact fact URL makes the
    # attribution exact at the source; the matcher stays as the gap net.
    source_url: Optional[str] = Field(
        None,
        description=(
            "Exact URL of the ONE source fact this question was built from, "
            "copied verbatim from that fact's Source line"
        ),
    )
    source_excerpt: Optional[str] = Field(
        None,
        description="Short snippet from that same source fact confirming the answer",
    )


class MCQBatchOutput(BaseModel):
    """Structured-output container for one MCQ sub-batch (#42 task 42.25)."""

    questions: List[MCQQuestionItem] = Field(default_factory=list)


class AdvancedQuestionGenerator:
    """Multi-stage question generator with quality optimization."""

    def __init__(
        self,
        generation_model: str = llm_factory.GEN,
        critique_model: str = llm_factory.CRITIQUE,
        generation_temperature: float = 0.8,
        critique_temperature: float = 0.3,
        prompt_version: str = "v2_cot",
        verbose: bool = False,
    ):
        """Initialize advanced question generator.

        Args:
            generation_model: Model for question generation (default: the
                factory GEN role — frontier per 2026-07-30 founder policy)
            critique_model: Model for quality critique (default: factory
                CRITIQUE role)
            generation_temperature: Temperature for generation (0.8 for creativity)
            critique_temperature: Temperature for critique (0.3 for consistency)
            prompt_version: Prompt template version (v2_cot uses Chain of Thought)
            verbose: Enable verbose logging of raw responses and parsed fields
        """
        self.verbose = verbose
        self.generation_llm = llm_factory.chat_openai(
            generation_model,
            temperature=generation_temperature,
        )
        self.critique_llm = llm_factory.chat_openai(
            critique_model,
            temperature=critique_temperature,
        )

        self.generation_model = generation_model
        self.critique_model = critique_model
        self.prompt_version = prompt_version

        # Load appropriate prompt template
        current_dir = os.path.dirname(__file__)
        if prompt_version == "v2_cot":
            template_path = os.path.join(
                current_dir, "..", "..", "prompts", "question_generation_v2_cot.md"
            )
        else:
            template_path = os.path.join(
                current_dir, "..", "..", "prompts", "question_generation.md"
            )

        self.prompt_builder = PromptBuilder(template_path=template_path)

        # Load V3 fact-first template (used when source_facts provided)
        v3_template_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_generation_v3_fact_first.md"
        )
        self.v3_prompt_builder = None
        if os.path.exists(v3_template_path):
            self.v3_prompt_builder = PromptBuilder(template_path=v3_template_path)

        # Issue #46 task 46.B4b — open/logical branch template. Open-shape
        # questions (mechanism + lateral puzzles) are generated through this
        # prompt so they emit the two-field `headline_answer` + `explanation`
        # contract (46.B3); pure puzzles are tagged `pipeline="logical_puzzle"`.
        open_template_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_generation_open.md"
        )
        self.open_prompt_builder = None
        if os.path.exists(open_template_path):
            self.open_prompt_builder = PromptBuilder(template_path=open_template_path)

        # Issue #76 F-3a — load the per-category fact-first prompts named in
        # _CATEGORY_PROMPT_FILES, each behind the same os.path.exists guard as the
        # v3/open builders above. `_build_batch_prompt` dispatches to the matching
        # builder for an order whose category is registered here; an unregistered
        # category (or a missing prompt file) falls through to the generic v3 path.
        self.category_prompt_builders: dict[str, PromptBuilder] = {}
        for category, filename in _CATEGORY_PROMPT_FILES.items():
            category_template_path = os.path.join(
                current_dir, "..", "..", "prompts", filename
            )
            if os.path.exists(category_template_path):
                self.category_prompt_builders[category] = PromptBuilder(
                    template_path=category_template_path
                )

        # A2 (2026-07-30): fail loud at load when a fact-first template lacks
        # an injection placeholder — see _REQUIRED_FACT_FIRST_PLACEHOLDERS.
        fact_first_builders = {"v3_fact_first": self.v3_prompt_builder}
        fact_first_builders.update(self.category_prompt_builders)
        for label, builder in fact_first_builders.items():
            if builder is None:
                continue
            missing = [
                p
                for p in _REQUIRED_FACT_FIRST_PLACEHOLDERS
                if p not in builder.template
            ]
            if missing:
                raise ValueError(
                    f"Fact-first template {label!r} ({builder.template_path}) is "
                    f"missing injection placeholder(s) {missing} — quality "
                    "machinery would silently not fire (generation review A2)."
                )

        # Load critique prompt (prefer V2 calibrated version)
        critique_v2_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_critique_v2.md"
        )
        critique_v1_path = os.path.join(
            current_dir, "..", "..", "prompts", "question_critique.md"
        )
        critique_template_path = critique_v2_path if os.path.exists(critique_v2_path) else critique_v1_path
        with open(critique_template_path, "r", encoding="utf-8") as f:
            self.critique_template = f.read()

    async def generate_questions(
        self,
        count: int = 10,
        difficulty: Optional[str] = None,
        topics: Optional[List[str]] = None,
        categories: Optional[List[str]] = None,
        question_type: str = "text",
        excluded_topics: Optional[List[str]] = None,
        avoid_questions: Optional[List[str]] = None,
        user_bad_examples: Optional[List[str]] = None,
        enable_best_of_n: bool = True,
        n_multiplier: int = 3,
        min_quality_score: float = 7.0,
        source_facts: Optional[list] = None,
        mcq_patterns: Optional[set[str]] = None,
        mcq_emphasis: bool = False,
        open_count: int = 0,
    ) -> List[Question]:
        """Generate questions using multi-stage quality pipeline.

        Pipeline:
        1. Generate N x count questions (Best-of-N)
        2. Critique each question with LLM judge
        3. Select top-scoring questions
        4. Optionally regenerate low-scoring questions

        Args:
            count: Number of questions to return
            difficulty: easy, medium, or hard; None (default) = mixed batch —
                the prompt asks the LLM to assess each question and aim for a
                spread (2026-07-27 live-run F-e)
            topics: Preferred topics
            categories: Question categories
            question_type: text or text_multichoice
            excluded_topics: Topics to avoid
            avoid_questions: Previously asked questions to avoid
            user_bad_examples: Questions users rated poorly
            enable_best_of_n: Use Best-of-N selection (default: True)
            n_multiplier: Generate this many times count (default: 3x)
            min_quality_score: Minimum acceptable score (default: 7.0/10)
            source_facts: Optional list of Fact objects for fact-first generation.
                When provided, uses V3 fact-first prompt template instead of V2.
            mcq_patterns: Optional set of reasoning-pattern keys (e.g.
                ``{"true_false", "odd_one_out"}``) for which the LLM must emit
                ``possible_answers`` + a key-letter ``correct_answer``. Routes
                via the ``{mcq_patterns_section}`` prompt placeholder; the
                per-question ``Question.type`` is set later by
                ``GenerationStage`` (#42 task 42.9a) based on the pattern the
                LLM ended up choosing.
            mcq_emphasis: When True (an MCQ-biased order, #42 task 42.20),
                the ``{mcq_patterns_section}`` carries a hard quota — at
                least 7 of every 10 questions must use an MCQ pattern — and
                exempts those patterns from the diversity rule's cap. The
                order prompt never reaches the generation LLM, so this bool
                is the only channel for the emphasis.

        Returns:
            List of Question objects with quality metadata

        Example:
            >>> generator = AdvancedQuestionGenerator()
            >>> questions = await generator.generate_questions(
            ...     count=10,
            ...     difficulty="medium",
            ...     topics=["science"],
            ...     enable_best_of_n=True,
            ...     n_multiplier=3  # Generate 30, return best 10
            ... )
        """
        # Issue #46 task 46.B4b — generate the open-shape slice through the
        # dedicated open/logical prompt (two-field `headline_answer` +
        # `explanation` contract, 46.B3). Best-of-N / critique stays on the
        # closed slice; the open slice is generated directly so the sentence
        # answer survives the critique judge unchanged.
        # 2026-07-30 — sample the gold/anti example sections ONCE per
        # invocation and hand the same strings to every LLM call this order
        # fans out into (MCQ sub-batches, top-ups). Keeps the static prompt
        # prefix identical across the order's calls so provider-side prompt
        # caching can hit (see CACHE_BREAKPOINT_MARKER); orders still rotate
        # exemplars against each other because each invocation resamples.
        example_pack = {
            "excellent_examples": load_gold_standard(
                topics=topics,
                difficulty=difficulty,
                question_type=question_type,
            ),
            "anti_examples": load_anti_patterns(),
        }

        open_questions: List[Question] = []
        if open_count > 0:
            print(f"Generating {open_count} open-shape questions...")
            open_questions = await self._generate_batch(
                count=open_count,
                difficulty=difficulty,
                topics=topics,
                categories=categories,
                question_type=question_type,
                excluded_topics=excluded_topics,
                avoid_questions=avoid_questions,
                user_bad_examples=user_bad_examples,
                open_shape=True,
                example_pack=example_pack,
            )
            count = max(0, count - open_count)
        if count == 0:
            return open_questions

        # Issue #42 task 42.20 (Risk #7 escalation) — MCQ-emphasis orders
        # generate one small sub-batch per MCQ pattern instead of a single
        # large best-of-N call. Asking the generation LLM for
        # ``count * n_multiplier`` (~57) questions at once returned only 4–10
        # raw questions live (collapsing yield), and a single mixed-pattern
        # call let the model satisfy the quota with whichever MCQ pattern was
        # easiest — or none. Pinning each small sub-batch to one pattern keeps
        # per-call counts small (the LLM actually fills them) and forces
        # coverage across every key in ``PATTERNS_TO_MCQ``.
        if mcq_emphasis and mcq_patterns:
            closed_questions = await self._generate_mcq_sub_batches(
                count=count,
                difficulty=difficulty,
                topics=topics,
                categories=categories,
                question_type=question_type,
                excluded_topics=excluded_topics,
                avoid_questions=avoid_questions,
                user_bad_examples=user_bad_examples,
                source_facts=source_facts,
                mcq_patterns=mcq_patterns,
                example_pack=example_pack,
            )
            return open_questions + closed_questions

        if enable_best_of_n:
            # Stage 1: Generate N x count questions
            generate_count = count * n_multiplier
            print(f"Stage 1: Generating {generate_count} questions...")

            raw_questions = await self._generate_batch(
                count=generate_count,
                difficulty=difficulty,
                topics=topics,
                categories=categories,
                question_type=question_type,
                excluded_topics=excluded_topics,
                avoid_questions=avoid_questions,
                user_bad_examples=user_bad_examples,
                source_facts=source_facts,
                mcq_patterns=mcq_patterns,
                mcq_emphasis=mcq_emphasis,
                example_pack=example_pack,
            )

            print(f"Generated {len(raw_questions)} raw questions")

            # Stage 2: Critique each question (concurrently — the critique
            # model is a frontier judge since 2026-07-30; serial calls made
            # this stage the wall-clock bottleneck).
            print(f"Stage 2: Critiquing {len(raw_questions)} questions...")
            critique_sem = asyncio.Semaphore(8)

            async def _critique_bounded(q: Question):
                async with critique_sem:
                    return await self._critique_question(q)

            critiques = await asyncio.gather(
                *(_critique_bounded(q) for q in raw_questions)
            )

            questions_with_scores = []
            for q, critique in zip(raw_questions, critiques):
                if critique is None:
                    # A6 (2026-07-30): a failed judge is a loud unknown, never
                    # a fabricated "acceptable 5.0". Unscored candidates rank
                    # behind every scored one; the error is kept on provenance.
                    critique = {
                        "overall_score": None,
                        "verdict": "unscored",
                        "critique_model": self.critique_model,
                        "error": "critique_failed_after_retry",
                    }
                provenance = q.generation_metadata or GenerationProvenance()
                merged_extra = dict(provenance.extra)
                merged_extra.update(critique)
                q.generation_metadata = provenance.model_copy(update={
                    "critique_model": self.critique_model,
                    "critique_score": critique.get("overall_score"),
                    "extra": merged_extra,
                })
                questions_with_scores.append((q, critique.get("overall_score")))

            # Stage 3: absolute-score prefilter, then pairwise refinement
            # (2026-07-30 review, section C: judges rank pairs far better
            # than they place absolute scores).
            print("Stage 3: Selecting best questions (pairwise refinement)...")
            selected_questions = await self._select_top_pairwise(
                questions_with_scores, count
            )

            # #42 task 42.29 — the dead Stage 4 "regenerate low-quality" stub
            # (it warned but never acted — false confidence) was removed. The
            # real ship gate is now ScoringStage's fail-loud minimum-score drop.
            # `min_quality_score` stays on the signature: it is still accepted
            # via the order API (app/api/routes.py → generate_questions); it is
            # simply no longer consumed in this best-of-N selection path.
            return open_questions + selected_questions

        else:
            # Simple generation without Best-of-N
            closed_questions = await self._generate_batch(
                count=count,
                difficulty=difficulty,
                topics=topics,
                categories=categories,
                question_type=question_type,
                excluded_topics=excluded_topics,
                avoid_questions=avoid_questions,
                user_bad_examples=user_bad_examples,
                source_facts=source_facts,
                mcq_patterns=mcq_patterns,
                mcq_emphasis=mcq_emphasis,
                example_pack=example_pack,
            )
            return open_questions + closed_questions

    async def _generate_mcq_sub_batches(
        self,
        count: int,
        difficulty: Optional[str],
        topics: Optional[List[str]],
        categories: Optional[List[str]],
        excluded_topics: Optional[List[str]],
        avoid_questions: Optional[List[str]],
        user_bad_examples: Optional[List[str]],
        source_facts: Optional[list],
        mcq_patterns: set[str],
        question_type: str = "text",
        example_pack: Optional[dict] = None,
    ) -> List[Question]:
        """Generate ``count`` questions as one small sub-batch per MCQ pattern.

        Issue #42 task 42.20 (Risk #7). MCQ-emphasis orders previously routed
        through the best-of-N path, which asked the LLM for
        ``count * n_multiplier`` (~57) questions in a single call — live runs
        returned only 4–10 raw questions, and a single mixed-pattern call let
        the model satisfy the quota with whichever MCQ pattern was easiest (or
        skip MCQ entirely). Splitting ``count`` into one sub-batch per pattern
        keeps each call small enough that the LLM actually fills it, and forces
        coverage across every key in ``mcq_patterns``. Each sub-batch lists a
        single pattern with ``mcq_emphasis=True`` so the activation section
        pins that pattern's shape as the required output. Best-of-N
        *over-generation* is intentionally skipped here — the downstream
        ``ScoringStage`` is the quality gate, and over-generating to ~57 is the
        very failure mode this path replaces. The self_critique judge still
        runs as opt-in **telemetry** (#72 P4.2, dormant behind
        ``MCQ_CRITIQUE_TELEMETRY``): it annotates each kept question with a
        ``critique_score`` but drops nothing.
        """
        patterns = sorted(mcq_patterns)
        # Spread `count` across the patterns as evenly as possible; the first
        # `extra` patterns absorb the remainder so the totals sum to `count`.
        base, extra = divmod(count, len(patterns))
        per_pattern = [base + (1 if i < extra else 0) for i in range(len(patterns))]
        print(
            f"MCQ emphasis: {count} questions across {len(patterns)} "
            f"per-pattern sub-batches {dict(zip(patterns, per_pattern))}"
        )

        # #42 task 42.28 — give each per-pattern sub-batch a DISJOINT slice of
        # the source facts. Passing the identical ``source_facts`` to every
        # sub-batch made the patterns mine the same handful of facts and emit
        # near-duplicate questions (e.g. four variants of "Bob Dylan's Nobel").
        # Contiguous partitioning keeps the slices distinct so each pattern
        # draws on different material.
        fact_slices = self._partition_facts(source_facts, len(patterns))

        async def _one(pattern: str, n: int, facts: Optional[list]) -> List[Question]:
            if n <= 0:
                return []
            # #42 task 42.25 — each sub-batch now goes through structured
            # output so the LLM cannot silently emit free-form ``text`` for
            # an MCQ-pinned pattern (the 2/13-yield failure). The classic
            # ``_generate_batch`` path stays for non-MCQ generation.
            try:
                return await self._generate_mcq_batch_structured(
                    count=n,
                    difficulty=difficulty,
                    topics=topics,
                    categories=categories,
                    question_type=question_type,
                    excluded_topics=excluded_topics,
                    avoid_questions=avoid_questions,
                    user_bad_examples=user_bad_examples,
                    source_facts=facts,
                    mcq_patterns={pattern},
                    example_pack=example_pack,
                )
            except Exception as exc:  # noqa: BLE001
                # #72 P1.3 (= #42 task 42.31) — crash isolation. One pattern's
                # sub-batch failing (LLM timeout, malformed structured output)
                # must not sink the other patterns. Drop just this sub-batch
                # and let the siblings through.
                print(f"MCQ sub-batch for pattern {pattern!r} failed: {exc!r}")
                return []

        # `return_exceptions=True` is a belt-and-suspenders net for the
        # per-sub-batch try/except above (#72 P1.3): if a failure ever slips
        # past ``_one`` it surfaces here as a value instead of cancelling the
        # surviving sub-batches, and the ``isinstance`` guard then skips it.
        batches = await asyncio.gather(
            *(
                _one(p, n, facts)
                for p, n, facts in zip(patterns, per_pattern, fact_slices)
            ),
            return_exceptions=True,
        )
        questions: List[Question] = [
            q for batch in batches if isinstance(batch, list) for q in batch
        ]
        print(f"MCQ sub-batches produced {len(questions)} raw questions")

        # #72 P4.2 (RC-7) — restore self_critique telemetry on the MCQ path.
        # The sub-batch architecture deliberately does NOT over-generate
        # (best-of-N *selection* asking for ~57 in one call is the yield
        # collapse this path replaced — see the issue's "Do NOT retry"). The
        # critique judge can still run as pure telemetry: when the dormant
        # ``MCQ_CRITIQUE_TELEMETRY`` flag is on it annotates each kept
        # question's provenance with a ``critique_score`` so MCQ quality is
        # observable (fun was measured in ~5 places for text, 0 for MCQ). No
        # question is dropped — ``ScoringStage`` stays the ship gate.
        if feature_flags.mcq_critique_telemetry():
            for q in questions:
                critique = await self._critique_question(q)
                if critique is None:
                    # A6: telemetry must not fabricate a score; record the miss.
                    critique = {
                        "verdict": "unscored",
                        "critique_model": self.critique_model,
                        "error": "critique_failed_after_retry",
                    }
                provenance = q.generation_metadata or GenerationProvenance()
                merged_extra = dict(provenance.extra)
                merged_extra.update(critique)
                q.generation_metadata = provenance.model_copy(update={
                    "critique_model": self.critique_model,
                    "critique_score": critique.get("overall_score"),
                    "extra": merged_extra,
                })

        return questions

    @staticmethod
    def _partition_facts(facts: Optional[list], n: int) -> List[Optional[list]]:
        """Split ``facts`` into ``n`` disjoint contiguous chunks (#42 task 42.28).

        One chunk per MCQ pattern sub-batch. The chunks are disjoint and
        cover the input in order, so no two sub-batches see the same fact —
        the fix for the near-duplicate questions that resulted from handing
        every sub-batch the identical fact list. Sizes follow the same
        even-split-with-remainder rule as ``per_pattern`` above. When there
        are no facts (or fewer facts than patterns) the spare slots get
        ``None`` so those sub-batches fall back to the fact-free prompt, the
        pre-42.28 behaviour.
        """
        if n <= 0:
            return []
        if not facts:
            return [None] * n
        base, extra = divmod(len(facts), n)
        slices: List[Optional[list]] = []
        start = 0
        for i in range(n):
            size = base + (1 if i < extra else 0)
            chunk = facts[start:start + size]
            slices.append(chunk or None)
            start += size
        return slices

    @staticmethod
    def _best_matching_fact(question: Question, facts: list):
        """The fact whose text best overlaps this question, or ``None`` when
        nothing shares a content word.

        Matches the model's confirming ``source_excerpt`` (classic/text path)
        and the question/answer/explanation (MCQ structured path, which carries
        no excerpt at all) against each fact's ``text`` + ``excerpt``. Lets a
        question be linked to the fact it was actually built from instead of the
        pack's first sourced fact (issue #72 single-URL misattribution).
        """
        q_tokens = _content_tokens(
            question.source_excerpt,
            question.question,
            question.correct_answer,
            question.explanation,
        )
        if not q_tokens:
            return None
        best = None
        best_score = 0
        for fact in facts:
            f_tokens = _content_tokens(
                getattr(fact, "text", None), getattr(fact, "excerpt", None)
            )
            score = len(q_tokens & f_tokens)
            if score > best_score:
                best_score = score
                best = fact
        return best

    def _attribute_sources(
        self, questions: List[Question], facts: Optional[list]
    ) -> None:
        """Stamp each question with the ``source_url``/``source_excerpt`` of the
        fact it was built from, scoped to the facts this sub-batch actually saw
        (its disjoint ``_partition_facts`` slice).

        Replaces the orchestrator's single global fallback fact that made an
        entire pack cite one URL (issue #72). Only fills gaps — a ``source_url``
        the model itself emitted is kept. A question that matches nothing falls
        back to the slice's first sourced fact (still slice-local, never the
        global pack head); the orchestrator's global net + the F8 gate catch
        anything still unsourced (e.g. a fact-free sub-batch).

        2026-07-27 live-run F-d: a fallback-stamped URL is by construction a
        sibling fact's URL, which is worse than null for a fact-check pass —
        so the fallback now marks provenance ``source_attribution:
        "unmatched_fallback"`` instead of passing as a real attribution.
        """
        if not facts:
            return
        sourced = [f for f in facts if getattr(f, "source_url", None)]
        if not sourced:
            return
        for q in questions:
            if q.source_url:
                continue
            match = self._best_matching_fact(q, sourced)
            if match is None:
                match = sourced[0]
                self._mark_source_attribution(q, "unmatched_fallback")
            q.source_url = getattr(match, "source_url", None)
            if q.source_excerpt is None:
                q.source_excerpt = getattr(match, "excerpt", None) or getattr(
                    match, "text", None
                )

    @staticmethod
    def _mark_source_attribution(question: Question, value: str) -> None:
        """Record on provenance that ``source_url`` is not a real attribution."""
        provenance = question.generation_metadata or GenerationProvenance()
        extra = dict(provenance.extra)
        extra["source_attribution"] = value
        question.generation_metadata = provenance.model_copy(
            update={"extra": extra}
        )

    async def _generate_batch(
        self,
        count: int,
        difficulty: Optional[str],
        topics: Optional[List[str]],
        categories: Optional[List[str]],
        question_type: str,
        excluded_topics: Optional[List[str]],
        avoid_questions: Optional[List[str]],
        user_bad_examples: Optional[List[str]],
        source_facts: Optional[list] = None,
        mcq_patterns: Optional[set[str]] = None,
        mcq_emphasis: bool = False,
        open_shape: bool = False,
        example_pack: Optional[dict] = None,
    ) -> List[Question]:
        """Generate a batch of questions.

        Args:
            source_facts: Optional list of Fact objects. When provided,
                uses V3 fact-first prompt template with facts injected.
            mcq_patterns: Reasoning-pattern keys that must emit MCQ payloads.
                Rendered into ``{mcq_patterns_section}`` of the prompt; the
                LLM is told to set ``reasoning.pattern_used`` to one of the
                snake_case keys and emit ``possible_answers`` + key-letter
                ``correct_answer`` when it picks one.
            example_pack: Pre-sampled example sections shared by every call of
                one order (prompt-cache stability); None = sample per call.
        """
        prompt, prompt_version, use_open, use_fact_first = self._build_batch_prompt(
            count=count,
            difficulty=difficulty,
            topics=topics,
            categories=categories,
            question_type=question_type,
            excluded_topics=excluded_topics,
            avoid_questions=avoid_questions,
            user_bad_examples=user_bad_examples,
            source_facts=source_facts,
            mcq_patterns=mcq_patterns,
            mcq_emphasis=mcq_emphasis,
            open_shape=open_shape,
            example_pack=example_pack,
        )

        # Call LLM
        response = await self.generation_llm.ainvoke([
            HumanMessage(content=self._prompt_message_content(prompt))
        ])

        # Parse response
        questions = self._parse_response(
            response.content,
            default_difficulty=difficulty or "medium",
            default_category=categories[0] if categories else "general"
        )

        return self._finalize_questions(
            questions,
            prompt_version=prompt_version,
            use_open=use_open,
            use_fact_first=use_fact_first,
            source_facts=source_facts,
        )

    def _build_batch_prompt(
        self,
        *,
        count: int,
        difficulty: Optional[str],
        topics: Optional[List[str]],
        categories: Optional[List[str]],
        question_type: str,
        excluded_topics: Optional[List[str]],
        avoid_questions: Optional[List[str]],
        user_bad_examples: Optional[List[str]],
        source_facts: Optional[list] = None,
        mcq_patterns: Optional[set[str]] = None,
        mcq_emphasis: bool = False,
        open_shape: bool = False,
        example_pack: Optional[dict] = None,
        response_format_section: Optional[str] = None,
    ):
        """Select the prompt template and render the generation prompt.

        Extracted from ``_generate_batch`` (#42 task 42.25) so the
        structured-output MCQ path reuses the identical template-selection
        and section-rendering rules instead of duplicating them. Returns
        ``(prompt, prompt_version, use_open, use_fact_first)``.

        ``response_format_section`` overrides the builder's prose-JSON output
        contract; the structured MCQ path passes the tool-schema note so the
        prompt never ships two conflicting output contracts (review A4).
        """
        # Determine which prompt builder and version to use. The open/logical
        # branch (46.B4b) takes precedence and never uses source_facts — open
        # questions are generated from the dedicated prompt, not fact-first.
        use_open = open_shape and self.open_prompt_builder is not None
        use_fact_first = (
            not use_open and source_facts and self.v3_prompt_builder is not None
        )
        if use_open:
            prompt_builder = self.open_prompt_builder
            prompt_version = "open"
        elif use_fact_first:
            # Issue #76 F-3a — category→builder dispatch. When the order's
            # category is registered in `category_prompt_builders`, select that
            # category's fact-first prompt (e.g. entertainment tone + driving
            # safety); an unregistered category is byte-identical to the generic
            # v3 path. Kept *inside* this `use_fact_first` branch so the
            # {facts_section}/{escape_hatch_section}/{mcq_patterns_section}
            # injection below still runs unchanged (C-b) — the dispatch changes
            # *which* fact-first builder, never *whether* facts are injected.
            category = categories[0] if categories else None
            if category in self.category_prompt_builders:
                prompt_builder = self.category_prompt_builders[category]
                prompt_version = f"v3_fact_first_{category}"
            else:
                prompt_builder = self.v3_prompt_builder
                prompt_version = "v3_fact_first"
        else:
            prompt_builder = self.prompt_builder
            prompt_version = self.prompt_version

        # Build the facts section for V3 prompt
        extra_kwargs = {}
        if use_fact_first:
            facts_section = self._format_facts_section(source_facts)
            extra_kwargs["facts_section"] = facts_section
            # Issue #72 P2.2 (Lever B) — inject the v3 escape hatch only when
            # the flag is on. Dormant by default: with the flag off the
            # placeholder falls back to its empty default so the prompt is
            # byte-identical to today's hard-bound v3.
            if feature_flags.v3_escape_hatch():
                extra_kwargs["escape_hatch_section"] = _V3_ESCAPE_HATCH_SECTION
            # Issue #72 Phase 3 — same dormant-injection mechanism for the
            # founder-calibrated craft guards.
            if feature_flags.gen_craft_guards():
                extra_kwargs["craft_guards_section"] = _V3_CRAFT_GUARDS_SECTION

        # Issue #42 task 42.9b — render MCQ activation rules into the prompt.
        # Empty section when no MCQ patterns are configured so the prompt
        # reads cleanly for non-MCQ runs (and back-compat with callers that
        # haven't been wired through yet, e.g. ad-hoc scripts).
        extra_kwargs["mcq_patterns_section"] = self._format_mcq_patterns_section(
            mcq_patterns, mcq_emphasis=mcq_emphasis
        )

        # A4 (2026-07-30) — the structured MCQ path replaces the prose-JSON
        # output contract with the tool-schema note.
        if response_format_section is not None:
            extra_kwargs["response_format_section"] = response_format_section

        # Build prompt
        prompt = prompt_builder.build_prompt(
            count=count,
            difficulty=difficulty,
            topics=topics,
            categories=categories,
            question_type=question_type,
            excluded_topics=excluded_topics,
            avoid_questions=avoid_questions,
            user_bad_examples=user_bad_examples,
            generation_model=self.generation_model,
            **(example_pack or {}),
            **extra_kwargs,
        )
        return prompt, prompt_version, use_open, use_fact_first

    def _prompt_message_content(self, prompt: str):
        """Message content for a generation prompt, honouring the cache marker.

        Under the OpenRouter gateway with an Anthropic generation model, the
        static prefix (everything above ``CACHE_BREAKPOINT_MARKER``) is sent
        as a ``cache_control`` text block so repeated calls within one order
        (and sequential top-ups) read it from the provider prompt cache.
        Everywhere else the marker is stripped — static-first ordering still
        benefits providers with implicit prefix caching.
        """
        if CACHE_BREAKPOINT_MARKER not in prompt:
            return prompt
        static, dynamic = prompt.split(CACHE_BREAKPOINT_MARKER, 1)
        if (
            llm_factory.gateway() == llm_factory.OPENROUTER
            and llm_factory.provider_for_model(self.generation_model) == "anthropic"
        ):
            return [
                {
                    "type": "text",
                    "text": static,
                    "cache_control": {"type": "ephemeral"},
                },
                {"type": "text", "text": dynamic},
            ]
        return static + dynamic

    def _finalize_questions(
        self,
        questions: List[Question],
        *,
        prompt_version: str,
        use_open: bool,
        use_fact_first: bool,
        source_facts: Optional[list] = None,
    ) -> List[Question]:
        """Attach provenance metadata, then dedup vs gold standard + check diversity.

        Extracted from ``_generate_batch`` (#42 task 42.25) so the
        structured-output MCQ path tags provenance (pattern lift,
        ``pipeline`` classification) and post-filters identically to the
        classic free-text path.
        """
        # Add generation metadata
        for q in questions:
            # Issue #42 task 42.9b — preserve LLM-emitted `pattern_used` so
            # the post-generation type-tagging step in `GenerationStage`
            # (42.9a) can route the question via `PATTERNS_TO_MCQ`. The
            # `_parse_response` → `Question.from_dict` path lands the
            # parsed `reasoning` dict under `generation_metadata.extra`
            # (via GenerationProvenance._absorb_unknown_keys); we lift
            # `pattern_used` into the typed `reasoning_pattern` slot here.
            pattern_used = self._extract_pattern_used(q.generation_metadata)
            # A4 (2026-07-30): keep the model's why_interesting on provenance —
            # it is the craft-guard "name the wrong assumption" evidence and
            # would otherwise be dropped when provenance is rebuilt below.
            why_interesting = self._extract_reasoning_field(
                q.generation_metadata, "why_interesting"
            )
            # Issue #46 task 46.B4b — tag pure lateral puzzles
            # `pipeline="logical_puzzle"` at generation time so F8's
            # source_url relaxation (46.B4a / D4) applies; open-mechanism
            # questions stay web-verifiable and keep no special pipeline.
            if use_open:
                pipeline = (
                    "logical_puzzle"
                    if verification_mode(pattern_used, q.question) == "logical"
                    else None
                )
            elif use_fact_first:
                pipeline = "fact_first"
            else:
                pipeline = None
            q.generation_metadata = GenerationProvenance(
                model=self.generation_model,
                provider=llm_factory.provider_for_model(self.generation_model),
                prompt_version=prompt_version,
                # getattr: frontier models reject sampling params, so the
                # factory may construct the client without a temperature.
                generation_temperature=getattr(
                    self.generation_llm, "temperature", None
                ),
                pipeline=pipeline,
                reasoning_pattern=pattern_used,
                generation_flow=GENERATION_FLOW,
                extra={
                    "stage": "initial_generation",
                    "escape_hatch": feature_flags.v3_escape_hatch(),
                    "gen_craft_guards": feature_flags.gen_craft_guards(),
                    **(
                        {"why_interesting": why_interesting}
                        if why_interesting
                        else {}
                    ),
                },
            )
            # Extract self-critique if present (from V2/V3 CoT prompt)
            # This will be in the parsed data if using V2/V3 prompt

        # Issue #72 — link each question to the specific source fact it was built
        # from (within this sub-batch's disjoint slice), so packs stop citing one
        # global URL for every question. Runs before dedup so a dropped duplicate
        # never strands its attribution.
        self._attribute_sources(questions, source_facts)

        # Dedup against gold standard to prevent verbatim copying
        questions = self._dedup_against_gold_standard(questions)

        # Warn if batch lacks structural diversity
        self._check_batch_diversity(questions)

        return questions

    async def _generate_mcq_batch_structured(
        self,
        *,
        count: int,
        difficulty: Optional[str],
        topics: Optional[List[str]],
        categories: Optional[List[str]],
        question_type: str,
        excluded_topics: Optional[List[str]],
        avoid_questions: Optional[List[str]],
        user_bad_examples: Optional[List[str]],
        source_facts: Optional[list],
        mcq_patterns: set[str],
        example_pack: Optional[dict] = None,
    ) -> List[Question]:
        """Generate one MCQ sub-batch via structured output (#42 task 42.25).

        Replaces the free-text ``ainvoke`` + ``_parse_response`` round-trip
        (still used by the classic best-of-N path) with
        ``with_structured_output(MCQBatchOutput)`` so every returned
        question is a parse-time-guaranteed ``text_multichoice`` with
        populated ``possible_answers`` + key-letter ``correct_answer``.
        Prompt instructions alone could not beat the v3 template's
        ``possible_answers: null`` example — the root cause of the 2/13
        live MCQ yield; the schema makes the contract a parse-time
        guarantee.

        ``method="function_calling"`` (not langchain's default
        ``json_schema``) keeps the path gateway-agnostic: under
        ``LLM_GATEWAY=openrouter`` the model id becomes ``openai/gpt-4o``
        and function-calling is proxied reliably, whereas ``json_schema``
        proxying through OpenRouter is not guaranteed.
        """
        prompt, prompt_version, use_open, use_fact_first = self._build_batch_prompt(
            count=count,
            difficulty=difficulty,
            topics=topics,
            categories=categories,
            question_type=question_type,
            excluded_topics=excluded_topics,
            avoid_questions=avoid_questions,
            user_bad_examples=user_bad_examples,
            source_facts=source_facts,
            mcq_patterns=mcq_patterns,
            mcq_emphasis=True,
            example_pack=example_pack,
            # A4: structured output is bound below — the prompt must carry the
            # tool-schema note, not the prose-JSON contract, or the model gets
            # two conflicting output contracts.
            response_format_section=STRUCTURED_MCQ_FORMAT_NOTE,
        )

        # 2026-07-27 live-run F-a: `include_raw=True` so one invalid item can
        # no longer void its whole sub-batch. Without it, a single question
        # coming back as open `text` with `possible_answers: null` failed the
        # whole `MCQBatchOutput` parse and every valid sibling was discarded
        # with it (measured: 64/106 delivered, one batch collapsed to 4/16).
        # The raw tool-call args survive the failed parse, so we salvage
        # per-question below instead of hardening the prompt further.
        structured_llm = self.generation_llm.with_structured_output(
            MCQBatchOutput, method="function_calling", include_raw=True
        )
        result = await structured_llm.ainvoke([
            HumanMessage(content=self._prompt_message_content(prompt))
        ])
        items = self._mcq_items_from_structured_result(result)

        default_category = categories[0] if categories else "general"
        pinned_pattern = sorted(mcq_patterns)[0] if mcq_patterns else None

        questions: List[Question] = []
        for item in items:
            try:
                questions.append(
                    Question.from_dict(
                        {
                            "question": item.question,
                            "type": "text_multichoice",
                            "possible_answers": item.possible_answers,
                            "correct_answer": item.correct_answer,
                            "explanation": item.explanation,
                            "topic": item.topic or "General",
                            "category": item.category or default_category,
                            "difficulty": item.difficulty or difficulty or "medium",
                            "language_dependent": item.language_dependent,
                            "age_appropriate": item.age_appropriate,
                            "source_url": item.source_url,
                            "source_excerpt": item.source_excerpt,
                            "reasoning": {
                                "pattern_used": item.pattern_used or pinned_pattern,
                                # A4: craft guard "name the wrong assumption"
                                # is now observable on the structured path.
                                "why_interesting": item.why_interesting,
                            },
                        },
                        default_difficulty=difficulty or "medium",
                        default_category=default_category,
                    )
                )
            except Exception as e:
                print(f"Error building structured MCQ question: {e}")

        print(
            f"MCQ structured sub-batch ({pinned_pattern}) produced "
            f"{len(questions)} questions"
        )
        return self._finalize_questions(
            questions,
            prompt_version=prompt_version,
            use_open=use_open,
            use_fact_first=use_fact_first,
            source_facts=source_facts,
        )

    @staticmethod
    def _mcq_items_from_structured_result(result: Any) -> List[MCQQuestionItem]:
        """Per-question salvage for one MCQ sub-batch (2026-07-27 live-run F-a).

        With ``include_raw=True`` the structured chain returns
        ``{"raw": AIMessage, "parsed": MCQBatchOutput | None, "parsing_error"}``.
        When the batch parse succeeded, use it as-is. When it failed — one
        item with ``possible_answers: null`` is enough — re-validate each
        question in the raw tool-call args individually, keeping the valid
        siblings and dropping only the offender. A bare ``MCQBatchOutput``
        (no ``include_raw``) is accepted for callers/tests that stub the
        chain directly.
        """
        if isinstance(result, MCQBatchOutput):
            return list(result.questions)
        if not isinstance(result, dict):
            return []
        parsed = result.get("parsed")
        if isinstance(parsed, MCQBatchOutput):
            return list(parsed.questions)

        items: List[MCQQuestionItem] = []
        dropped = 0
        for call in getattr(result.get("raw"), "tool_calls", None) or []:
            args = call.get("args") if isinstance(call, dict) else None
            for raw_item in (args or {}).get("questions") or []:
                try:
                    items.append(MCQQuestionItem.model_validate(raw_item))
                except ValidationError:
                    dropped += 1
        if dropped:
            print(
                f"MCQ sub-batch salvage: dropped {dropped} invalid "
                f"question(s), kept {len(items)} valid sibling(s)"
            )
        return items

    @staticmethod
    def _strip_markdown_fences(content: str) -> str:
        """Remove ```json ... ``` wrappers that LLMs sometimes add around JSON."""
        content = content.strip()
        if content.startswith("```"):
            first_nl = content.find("\n")
            last_fence = content.rfind("```")
            if first_nl != -1 and last_fence > first_nl:
                content = content[first_nl + 1:last_fence].strip()
        return content

    @staticmethod
    def _jaccard_similarity(text_a: str, text_b: str) -> float:
        """Compute Jaccard word-overlap similarity between two texts."""
        words_a = set(text_a.lower().split())
        words_b = set(text_b.lower().split())
        if not words_a or not words_b:
            return 0.0
        intersection = len(words_a & words_b)
        union = len(words_a | words_b)
        return intersection / union if union else 0.0

    def _dedup_against_gold_standard(
        self, questions: List[Question], threshold: float = 0.80
    ) -> List[Question]:
        """Remove questions that are too similar to gold standard examples."""
        # Shared resolver: a fixed `parents[N]` path silently resolved to a
        # non-existent /data/examples in the Docker layout, making this whole
        # check a no-op in prod.
        gold_path = example_corpus_path("gold_standard.json")
        with gold_path.open("r", encoding="utf-8") as f:
            gold_examples = json.load(f)
        gold_texts = [ex.get("question", "") for ex in gold_examples]

        unique = []
        for q in questions:
            is_copy = False
            for gold_q in gold_texts:
                if self._jaccard_similarity(q.question, gold_q) > threshold:
                    print(f"  Dedup: removed near-copy of gold standard: {q.question[:60]}...")
                    is_copy = True
                    break
            if not is_copy:
                unique.append(q)
        return unique

    @staticmethod
    def _check_batch_diversity(questions: List[Question], threshold: float = 0.30) -> None:
        """Warn if more than threshold fraction of questions start with 'Which'."""
        if not questions:
            return
        which_count = sum(1 for q in questions if q.question.strip().startswith("Which"))
        ratio = which_count / len(questions)
        if ratio > threshold:
            print(
                f"  ⚠ Diversity warning: {which_count}/{len(questions)} "
                f"({ratio:.0%}) questions start with 'Which' (target: ≤{threshold:.0%})"
            )

    @staticmethod
    def _format_mcq_patterns_section(
        mcq_patterns: Optional[set[str]], mcq_emphasis: bool = False
    ) -> str:
        """Render the MCQ-activation block for `{mcq_patterns_section}`.

        Empty string when no patterns are configured so the prompt reads as
        if MCQ wasn't requested (the original non-MCQ behaviour). When
        patterns are present, we emit a single instruction block per
        pattern keyed by the exact snake_case label the routing helper
        (`pattern_routing.choose_question_type`) expects — drift between
        the two would silently downgrade MCQ output to free-form text.

        ``mcq_emphasis`` injects the hard MCQ quota (≥7 of every 10
        questions) plus an unconditional diversity-rule exemption directly
        into the section. The previous wording gated the exemption on "if
        the order prompt declares MULTIPLE-CHOICE EMPHASIS" — a condition
        the generation LLM can never observe, because the order prompt is
        not part of the generation prompt (#42 task 42.20 blocker, root
        cause D). Unbiased runs (the default) keep the diversity rule
        untouched.

        Issue #42 tasks 42.9b + 42.20 blocker fix.
        """
        if not mcq_patterns:
            return ""

        # Per-pattern emission contract. The keys MUST match
        # `PATTERNS_TO_MCQ`; the body tells the LLM what shape of
        # `possible_answers` and `correct_answer` to emit. Order is
        # deterministic so prompt caching stays warm across runs.
        recipes: dict[str, str] = {
            "true_false": (
                "frame the source fact as a single True/False claim "
                "(pick this directly — it is not numbered in the Pattern "
                "Library). Two options, e.g. "
                "`{\"a\": \"True\", \"b\": \"False\"}`, "
                "with `correct_answer` set to `\"a\"` or `\"b\"`."
            ),
            "odd_one_out": (
                "the MCQ form of Pattern Library #9 'The Odd One Out'. "
                "Four options labelled a/b/c/d, with `correct_answer` set to "
                "the key letter of the odd item. Put the reasoning in "
                "`explanation`. CRITICAL — the odd one must NOT be guessable "
                "from the surface form of the options. All four MUST look like "
                "the same kind of thing (all real people, all countries, all "
                "films, all animals, …) so the solver has to KNOW the hidden "
                "fact to pick it. NEVER make the odd one obviously different on "
                "its face — e.g. a cartoon character among real people, or a "
                "fictional name among historical ones — because then the "
                "question answers itself and tests nothing. The surprising fact "
                "that sets the odd one apart MUST be the point of the question, "
                "not a detail you reveal in `explanation`."
            ),
            "comparison_bet_older_larger": (
                "the MCQ form of Pattern Library #12 'The Comparison Bet' — "
                "which of two things wins on a surprising dimension (older / "
                "larger / heavier / faster / longer / closer / more populous / "
                "more valuable — A or B?). Two options A and B as "
                "`{\"a\": \"<option A>\", \"b\": \"<option B>\"}`, with "
                "`correct_answer` set to the key letter of the surprising "
                "winner."
            ),
            "year_guess": (
                "frame a date/era fact as 'in which year/decade?' (pick "
                "this directly — it is not numbered in the Pattern Library). "
                "Four plausible year/decade options labelled a/b/c/d, with "
                "`correct_answer` set to the key letter of the correct year."
            ),
            "order_of_magnitude": (
                "the driving-safe MCQ form of the Estimation pattern (pick "
                "this directly — it is not numbered in the Pattern Library). "
                "Frame a quantity (population, distance, age, count, size) as "
                "'roughly how many / how large?' Four NON-overlapping magnitude "
                "buckets labelled a/b/c/d (e.g. `{\"a\": \"hundreds\", "
                "\"b\": \"thousands\", \"c\": \"millions\", \"d\": "
                "\"billions\"}`), with `correct_answer` set to the key letter "
                "of the bucket the true value falls in."
            ),
        }

        lines = [
            "## Multiple-Choice Activation (pattern-driven)",
            "",
            "When you choose any of the patterns listed below, the question "
            "MUST be multiple-choice. You MUST:",
            "",
            "1. Set `reasoning.pattern_used` to the exact snake_case key "
            "(e.g. `true_false`, NOT `\"True/False Bet\"`).",
            "2. Set `type` to `text_multichoice`.",
            "3. Emit `possible_answers` per the shape described below.",
            "4. Set `correct_answer` to the key letter (`\"a\"`, `\"b\"`, …), "
            "not the value.",
            "5. When Source Facts are provided, set `source_url` to the exact "
            "URL of the ONE fact this question was built from (copy it "
            "verbatim from that fact's Source line — never a sibling fact's "
            "URL) and `source_excerpt` to the snippet from that same fact "
            "that confirms the answer.",
            "",
            "**These patterns are selectable choices, not just the numbered "
            "Pattern Library.** `odd_one_out` and `comparison_bet_older_larger` "
            "are the MCQ forms of Library patterns 9 and 12; `true_false`, "
            "`year_guess` and `order_of_magnitude` are MCQ patterns in their "
            "own right — choose them directly even though they are not numbered "
            "in the Library above, and emit `reasoning.pattern_used` as the "
            "exact snake_case key.",
            "",
            "**Distractor quality rule (all MCQ patterns):** every distractor "
            "must be plausible. NEVER include a throwaway wrong option, NEVER "
            "let one option give away the answer through length / specificity, "
            "NEVER include the correct answer as a substring of a distractor.",
            "",
        ]
        if mcq_emphasis:
            lines += [
                "**MULTIPLE-CHOICE EMPHASIS (this order):** at least 7 of "
                "every 10 questions in this batch MUST use one of the "
                "patterns listed below. Those patterns are EXEMPT from the "
                "PATTERN DIVERSITY RULE's per-pattern cap for this order — "
                "repeating them is expected and correct. Emit "
                "`possible_answers` for every question using one of them.",
                "",
            ]
        lines += [
            "**Patterns that require MCQ:**",
            "",
        ]
        for key in sorted(mcq_patterns):
            recipe = recipes.get(
                key,
                "four plausible options labelled a/b/c/d, with "
                "`correct_answer` set to the key letter.",
            )
            lines.append(f"- `{key}` — {recipe}")
        return "\n".join(lines)

    @staticmethod
    def _extract_pattern_used(
        provenance: Optional[GenerationProvenance],
    ) -> Optional[str]:
        """Lift the LLM-emitted `reasoning.pattern_used` out of `extra`.

        `Question.from_dict` puts the parsed `reasoning` dict into
        `generation_metadata` as-is; `GenerationProvenance` routes it to
        `extra["reasoning"]` via `_absorb_unknown_keys`. This helper
        normalises the lookup so `_generate_batch` can pass the value
        into the typed `reasoning_pattern` slot.

        Issue #42 task 42.9b.
        """
        if provenance is None:
            return None
        reasoning = provenance.extra.get("reasoning")
        if not isinstance(reasoning, dict):
            return None
        pattern = reasoning.get("pattern_used")
        return pattern if isinstance(pattern, str) and pattern else None

    @staticmethod
    def _extract_reasoning_field(
        provenance: Optional[GenerationProvenance], key: str
    ) -> Optional[str]:
        """A string field out of the parsed ``reasoning`` dict, if present."""
        if provenance is None:
            return None
        reasoning = provenance.extra.get("reasoning")
        if not isinstance(reasoning, dict):
            return None
        value = reasoning.get(key)
        return value if isinstance(value, str) and value else None

    @staticmethod
    def _format_facts_section(facts: list) -> str:
        """Format a list of Fact objects into a text section for the prompt.

        Args:
            facts: List of Fact objects (or dicts with 'text', 'source_url', etc.)

        Returns:
            Formatted string of numbered facts for injection into the prompt
        """
        lines = []
        for i, fact in enumerate(facts, 1):
            # Support both Fact dataclass objects and plain dicts
            if hasattr(fact, "text"):
                text = fact.text
                source_url = getattr(fact, "source_url", None)
                source_name = getattr(fact, "source_name", "unknown")
                topic = getattr(fact, "topic", "General")
                surprise = getattr(fact, "surprise_rating", 5.0)
            elif isinstance(fact, dict):
                text = fact.get("text", "")
                source_url = fact.get("source_url")
                source_name = fact.get("source_name", "unknown")
                topic = fact.get("topic", "General")
                surprise = fact.get("surprise_rating", 5.0)
            else:
                continue

            line = f"**Fact {i}** [Topic: {topic}, Surprise: {surprise}/10]"
            line += f"\n  {text}"
            if source_url:
                line += f"\n  Source: {source_name} ({source_url})"
            else:
                line += f"\n  Source: {source_name}"
            lines.append(line)

        return "\n\n".join(lines)

    @staticmethod
    def _render_question_for_judge(question: Question) -> str:
        """One-block rendering of a question for judge prompts.

        A3 (2026-07-30): judges must see the OPTIONS and the resolved answer
        TEXT — an MCQ scored against a bare key letter made surprise and
        factual-confidence judgments noise.
        """
        _, answer_text = resolve_correct_answer(
            question.correct_answer, question.possible_answers
        )
        lines = [f"Q: {question.question}"]
        if question.possible_answers:
            opts = " | ".join(
                f"{str(k).lower()}) {v}"
                for k, v in question.possible_answers.items()
            )
            lines.append(f"Options: {opts}")
        lines.append(f"Answer: {answer_text}")
        if question.explanation:
            lines.append(f"Explanation: {question.explanation}")
        return "\n".join(lines)

    _PAIRWISE_PROMPT = """You are choosing the better of two trivia questions for a voice-first quiz played hands-free while driving. Each question is heard ONCE by a non-native-English adult and answered by voice.

Judge on substance, in this order: the reveal (does the answer overturn an assumption worth retelling?), fairness (a reasoning path besides recall; for MCQ, plausible-but-eliminable options), one-listen clarity, retellability. Ignore superficial polish differences.

QUESTION A:
{a}

QUESTION B:
{b}

Respond in JSON only:
{{"winner": "A" or "B", "reason": "<one short sentence>"}}"""

    def _parse_pairwise_winner(self, content: str) -> Optional[str]:
        """'A' | 'B' from a pairwise verdict, else None (pair is skipped)."""
        text = self._strip_markdown_fences(content)
        start = text.find("{")
        end = text.rfind("}") + 1
        if start == -1 or end <= start:
            return None
        try:
            data = json.loads(text[start:end])
        except json.JSONDecodeError:
            return None
        winner = str(data.get("winner", "")).strip().upper()
        return winner if winner in ("A", "B") else None

    async def _select_top_pairwise(
        self,
        questions_with_scores: List[tuple],
        count: int,
    ) -> List[Question]:
        """Absolute-score prefilter, then pairwise refinement (review C).

        Judges rank pairs far better than they place absolute scores, so the
        final ordering comes from pairwise wins among the top ``2*count``
        absolute-scored candidates (ties broken by absolute score). Pairing is
        a deterministic ring — full round-robin when small enough, otherwise
        each candidate meets its 5 ring-nearest peers; A/B presentation order
        alternates to cancel position bias. A failed/unparseable verdict skips
        that pair only. Candidates whose critique failed (score None) sort
        behind every scored candidate and never displace one.
        """

        def _abs_key(item: tuple) -> float:
            score = item[1]
            return -1.0 if score is None else float(score)

        ordered = sorted(questions_with_scores, key=_abs_key, reverse=True)
        if count <= 0:
            return []
        if len(ordered) <= count:
            return [q for q, _ in ordered]

        shortlist = ordered[: min(2 * count, len(ordered))]
        n = len(shortlist)
        pairs: set[tuple[int, int]] = set()
        if n * (n - 1) // 2 <= 80:
            pairs = {(i, j) for i in range(n) for j in range(i + 1, n)}
        else:
            for i in range(n):
                for d in range(1, 6):
                    j = (i + d) % n
                    pairs.add((min(i, j), max(i, j)))

        sem = asyncio.Semaphore(8)

        async def _judge_pair(i: int, j: int, flip: bool) -> Optional[int]:
            a_idx, b_idx = (j, i) if flip else (i, j)
            prompt = self._PAIRWISE_PROMPT.format(
                a=self._render_question_for_judge(shortlist[a_idx][0]),
                b=self._render_question_for_judge(shortlist[b_idx][0]),
            )
            try:
                async with sem:
                    response = await self.critique_llm.ainvoke(
                        [HumanMessage(content=prompt)]
                    )
            except Exception as exc:  # noqa: BLE001 — judge call boundary
                print(f"Pairwise judge call failed (pair skipped): {exc!r}")
                return None
            winner = self._parse_pairwise_winner(response.content)
            if winner is None:
                print("Pairwise judge verdict unparseable (pair skipped)")
                return None
            return a_idx if winner == "A" else b_idx

        outcomes = await asyncio.gather(
            *(
                _judge_pair(i, j, flip=bool((i + j) % 2))
                for (i, j) in sorted(pairs)
            )
        )
        wins = [0] * n
        for w in outcomes:
            if w is not None:
                wins[w] += 1

        ranked = sorted(
            range(n),
            key=lambda idx: (wins[idx], _abs_key(shortlist[idx])),
            reverse=True,
        )
        return [shortlist[idx][0] for idx in ranked[:count]]

    async def _critique_question(self, question: Question) -> Optional[Dict[str, Any]]:
        """Critique a question using the LLM judge.

        Returns critique data ({"overall_score": …, "scores": {…}, "verdict":
        …, …}) or **None** after one retry — never a fabricated neutral score.
        A6 (2026-07-30): the old parse-failure fallback returned
        ``overall_score: 5.0, verdict: "acceptable"``, silently ranking failed
        judgments as average; callers now handle None explicitly.
        """
        if question.possible_answers:
            options_block = " | ".join(
                f"{str(k).lower()}) {v}"
                for k, v in question.possible_answers.items()
            )
        else:
            options_block = "(not multiple-choice)"
        _, answer_text = resolve_correct_answer(
            question.correct_answer, question.possible_answers
        )
        critique_prompt = self.critique_template.format(
            question=question.question,
            correct_answer=answer_text,
            options_block=options_block,
            explanation=question.explanation or "(none provided)",
            question_type=question.type,
            difficulty=question.difficulty,
            topic=question.topic,
        )

        for attempt in (1, 2):
            try:
                response = await self.critique_llm.ainvoke([
                    HumanMessage(content=critique_prompt)
                ])
                critique_content = self._strip_markdown_fences(response.content)
                start = critique_content.find('{')
                end = critique_content.rfind('}') + 1
                if start == -1 or end <= start:
                    print(
                        f"No JSON in critique response (attempt {attempt}) "
                        f"for: {question.question[:60]}..."
                    )
                    continue

                critique_data = json.loads(critique_content[start:end])
                critique_data["critique_model"] = self.critique_model

                # Score normalization: if all dimensions scored >8, likely inflated
                scores = critique_data.get("scores", {})
                if scores and all(v > 8 for v in scores.values() if isinstance(v, (int, float))):
                    original = critique_data.get("overall_score", 0)
                    critique_data["overall_score"] = max(0, original - 0.5)
                    critique_data["score_normalized"] = True
                    critique_data["original_score"] = original

                return critique_data

            except Exception as e:  # noqa: BLE001 — judge call boundary
                print(f"Critique attempt {attempt} failed: {e}")

        return None

    def _parse_response(
        self,
        content: str,
        default_difficulty: str = "medium",
        default_category: str = "general"
    ) -> List[Question]:
        """Parse LLM response into Question objects.

        Supports both V1 and V2 formats (V2 includes reasoning and self_critique).

        Args:
            content: LLM response content
            default_difficulty: Default difficulty
            default_category: Default category

        Returns:
            List of Question objects
        """
        questions = []

        try:
            # Strip markdown code fences that LLMs sometimes wrap around JSON
            content = self._strip_markdown_fences(content)

            if self.verbose:
                print(f"  [verbose] Raw response preview: {content[:200]}...")

            # Extract JSON
            start = content.find('{')
            end = content.rfind('}') + 1

            if start == -1 or end <= start:
                print(f"No JSON found in response: {content[:200]}...")
                return []

            json_str = content[start:end]
            data = json.loads(json_str)

            # Handle both formats
            if "questions" in data:
                questions_data = data["questions"]
            elif "question" in data:
                questions_data = [data]
            else:
                print(f"Unexpected JSON structure: {data}")
                return []

            # Convert to Question objects
            for q_data in questions_data:
                try:
                    if self.verbose:
                        has_fields = {k: k in q_data for k in ("reasoning", "self_critique", "surprise_factor")}
                        print(f"  [verbose] Question fields: {has_fields}")
                    question = Question.from_dict(
                        q_data,
                        default_difficulty=default_difficulty,
                        default_category=default_category,
                    )
                    self._check_answer_explanation_consistency(question)
                    questions.append(question)
                except Exception as e:
                    print(f"Error parsing question: {e}")
                    continue

        except json.JSONDecodeError as e:
            print(f"JSON decode error: {e}")
            print(f"Content: {content[:500]}...")
        except Exception as e:
            print(f"Error parsing response: {e}")

        return questions

    def _check_answer_explanation_consistency(self, question: Question) -> None:
        """Log a warning if explanation text doesn't mention the correct answer."""
        if not question.explanation:
            return
        answer_str = str(question.correct_answer).lower().strip()
        if len(answer_str) <= 50 and answer_str not in question.explanation.lower():
            print(
                f"  ⚠ Answer/explanation mismatch: answer '{question.correct_answer}' "
                f"not found in explanation for: {question.question[:80]}..."
            )

