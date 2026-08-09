# External independent review #2 — question quality across the whole pipeline (2026-08-09)

**Provenance:** Second independent external review, code-only + sampled real generated output (`data/generated/`, `data/pilot-2026-07-30/`). Reviewer got NO internal rubric/decisions; goal framed as "how do we improve the quality of generated questions" across the entire pipeline. Companion to `external-review-gen-pipeline-2026-08-09.md` (14 architecture/verification findings).

**Status:** Recorded, NOT yet assessed. Follow-up session: triage together with review #1 (findings 1–3 here overlap its criticals; verify every file:line and whether pilot-2026-07-30 examples predate #153 Phase 0/A fixes).

**Reviewer's quality bar:** factually defensible from a traceable source · one fair answer · works after one TTS listen · short spoken answer · rewards knowledge/reasoning not wording tricks · fits topic/age/format. Anchored on human-rated 8+ gold examples (`app/generation/examples.py:41`).

## Findings

### Critical

1. **Verification failures still reach delivery.** `app/orchestrator/stages/verification.py:119,141` — gate drops only low confidence; held + missing-verdict questions kept. Evidence: pilot Champawat Tiger question shipped with `verified: false`, score 0.3, `held_for_review: true` (`data/pilot-2026-07-30/gemini_3_1_pro_preview.json:296,373`). *Rec:* fail closed — deliverable only if verdict verified/likely_correct + calibrated confidence + not held; otherwise replace or human review. *(Overlaps review #1 finding 3.)*

2. **Sourcing treats search fragments and low-credibility pages as generation-ready facts.** `app/sourcing/web_search_source.py:165` (snippets → Facts, verified=False), `sourcing/models.py:215` (low-credibility kept when topic is scarce), `opentriviadb_source.py:192` ("The answer to '[q]' is [a]" pseudo-facts). Evidence: pilot sources include BuzzFeed, YouTube, LinkedIn (penguin claim from LinkedIn, json:688,709). *Rec:* source policy pre-generation — authoritative/corroborated only, claim-level evidence, no social/video/listicle for paid packs; scarcity never justifies keeping an unsupported claim. DIRECT_GENERATION_MODE noted again as bypass (`stages/sourcing.py:86`, `stages/generation.py:535`). *(Overlaps review #1 findings 12, 5.)*

### High

3. **Critique scores don't define a meaningful ship bar.** `stages/scoring.py:84` accepts avg 3.0 / distractor 4, self-described lenient; `advanced_generator.py:583` `min_quality_score` unused. Evidence: judge itself flagged `deductive_giveaway` on a 6.6 question (json:587,645) and `telegraphed_tf`+`deductive_giveaway` on the 5.9 penguin T/F (json:743) — both still shipped. *Rec:* calibrate paid-pack threshold vs human ratings; minimums on factual accuracy/answerability/craft; hard-reject critical red flags. *(Overlaps review #1 finding 11.)*

4. **MCQ quality under-tested on the voice path.** `advanced_generator.py:621,702` — MCQ-emphasis batches skip best-of-N; critique telemetry-only, drops nothing. `multi_model_scorer.py:137` distractor check misses semantic plausibility / exactly-one-defensible-answer. Evidence: "In the dozens / hundreds / thousands / tens of thousands" makes two options disposable (json:296). *Rec:* option-aware judge + hard gates (one defensible answer, same-kind comparable distractors, no elimination-by-absurdity); apply selection to MCQs; reject test-wise absolute T/F wording ("Every single species…").

5. **Kids prompt (safety/vocab/age rules) is not wired — kids falls back to generic v3.** `advanced_generator.py:41,976` — category registry contains only `entertainment`. `prompts/question_generation_kids.md:20,83` has explicit safety + score≥8 rules that never run. *Rec:* wire kids + all themed categories to their prompts; enforce safety/age deterministically post-generation.

### Medium

6. **User's free-text topic is not preserved as generation intent** (medium-high). `stages/sourcing.py:255` extracts a few tokens; generation receives only category/theme/facts (`stages/generation.py:205`). *Rec:* parse order into structured intent (subject, scope, exclusions, era, audience) → feed generation AND judging; add post-generation topicality check.

7. **Dedup prevents repeated wording, not repeated stories.** `stages/dedup.py:260` — same-fact identity = normalized URL + answer only. Evidence: pilot has 2× Champawat tiger (json:199,296) and 2× knocker-uppers (json:489,587) from one BuzzFeed article. *Rec:* stable fact/story IDs at sourcing; one question per story per pack; pack-level caps by source/topic/pattern. *(Complements #153 Phase 0 composition caps — story-level identity is the new part.)*

8. **Visual questions break the voice-first contract when the image is absent.** `prompts/question_generation_hint_image.md:20` demands TTS-answerable text, but output like "This atmospheric painting hints at a classic American novel. What is it?" (`data/generated/hint_image_questions.json:3`) needs the image; silhouette/blind-map reuse "Which…" templates + 35-word clue stacks (`silhouette_questions.json:83`). *Rec:* separate visual-only vs driving-safe contracts; blind answerability test with asset hidden; spoken-length budget; varied openings.

## Assessment session TODO

- [ ] Merge triage with review #1 doc — dedupe overlapping findings (1↔#1.3, 2↔#1.12/#1.5, 3↔#1.11), then one prioritized fix plan (amend #153 or new issue).
- [ ] Verify pilot-2026-07-30 evidence against current pipeline state — several cited defects may predate #153 Phase 0 fixes (sourcing credibility, ungrounded-drop, composition caps).
- [ ] New-to-us items to verify first: kids prompt unwired (finding 5), MCQ path skips best-of-N (finding 4), topic-intent loss (finding 6), story-level dedup (finding 7), hint-image voice contract (finding 8).
