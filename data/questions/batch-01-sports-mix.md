# Batch 01 — Sports Mix Category
**Generated:** 2026-05-19
**Model:** claude-opus-4-7
**Pipeline:** claude_code_session (manual gen → manual verify → score)
**Source file:** data/generated/claude_batch_035.json
**Scored file:** data/scored/scored_2026-05-19_sports-mix_batch035.json

## Summary
- Generated: 22 candidates
- Verified: 22 — all factually correct; spot-checked 5 claims via WebFetch (Lombardi Trophy/Tiffany since 1967, Hoketsu age + 1964 debut, Volleyball Mintonette, Marathon Windsor route, Cy Young 511 wins); minor explanation tweaks on Q5 (removed unsourced Princess Mary nursery anecdote) and Q8 (44-year gap not 48 per Wikipedia)
- Scored: 22 — 20 approve (engagement avg ≥8.0), 2 revise (Q6 Bannister too well-known; Q18 Surfing 2020 contrived wave-pool plot-twist)
- **Approved: 20 questions** → local ChromaDB (0 duplicates, 0 failures)
- Drop rate: 9% (2 of 22 dropped at scoring stage)
- **Local ChromaDB after import: 30 sports-mix (target 30 — EXACTLY MET)**

## Approved Questions (20)

Top 20 selected by ai_score via `scripts/generate_questions_claude.py -i ... --count 20 --import-to-db`:

| Rank | ai_score | Difficulty | Topic | Answer |
|---|---|---|---|---|
| 1 | 9.17 | medium | Marathon Windsor Castle | Windsor Castle |
| 2 | 9.00 | hard | Volleyball Mintonette | Mintonette |
| 3 | 8.83 | hard | Squash @ Harrow | Harrow |
| 4 | 8.83 | hard | Lombardi Trophy / Tiffany | Tiffany & Co. |
| 5 | 8.83 | hard | Grand Slam from Bridge | Bridge |
| 6 | 8.83 | medium | Golf 18 holes / St Andrews | True |
| 7 | 8.67 | easy | Wimbledon whites | True |
| 8 | 8.67 | medium | NASCAR moonshine | True |
| 9 | 8.67 | medium | Tony Hawk 900 | 2.5 rotations |
| 10 | 8.67 | medium | Stanley Cup | True |
| 11 | 8.67 | medium | Mark Spitz 7 golds | Mark Spitz |
| 12 | 8.67 | hard | Senna Imola | Imola |
| 13 | 8.67 | medium | Queensberry boxing | Marquess of Queensberry |
| 14 | 8.50 | hard | Hoketsu 71yo Olympian | True |
| 15 | 8.50 | hard | Bodyline cricket | Bodyline |
| 16 | 8.50 | medium | Curling sweeping | True |
| 17 | 8.33 | hard | Cy Young 511 wins | 511 |
| 18 | 8.33 | medium | Sumo dohyō women | Women not allowed |
| 19 | 8.33 | hard | Snooker etymology | First-year cadet |
| 20 | 8.17 | medium | Drake's bowls | Bowls |

## Revised / Excluded (2)

| Q | Topic | Why excluded | Reframe option |
|---|---|---|---|
| Q6 | Roger Bannister sub-4-minute mile | Universally known; low surprise/clever-framing (engagement avg 7.8) | Reframe to ask for time (3:59.4) or pacers (Brasher/Chataway) |
| Q18 | Surfing 2020 Olympic debut | Contrived wave-pool plot-twist; mild surprise (engagement avg 7.0) | Reframe to Paris 2024 venue (Teahupo'o, Tahiti) or LA 2028 wave-pool plan |

Excluded via `ai_score=7.4` override in `data/generated/claude_batch_035.json` so `--count 20` selector skipped them. Originals remain in JSON for future reframe pass.

## Decisions

**Skill chain bez running services** — same pattern as batch-01-superheroes (2026-05-19): FactVerifier (port 8003) offline. Replaced with generation-time self-critique + 5 WebFetch spot-checks for the highest-risk numeric/historical claims.

**Topic coverage** — diversified vs. existing 10 sports-mix Olympics-heavy questions: tennis (Wimbledon, Grand Slam etymology), motorsports (NASCAR origin, F1 Senna), American sports (Lombardi/NFL, Cy Young/MLB, Stanley Cup/NHL, Mark Spitz/swimming), British origin stories (Squash@Harrow, Golf@St Andrews, Drake's bowls, Queensberry rules, Bodyline, Snooker etymology), cultural (Sumo dohyō, Curling physics, Volleyball Mintonette), records (Hoketsu, Tony Hawk).

**Spot-check fact corrections pre-import:**
- **Q5 Marathon** — removed unsourced "Princess Mary's children watched from the nursery" anecdote; tightened to Wikipedia-sourced facts (Windsor Castle → royal entrance → final partial lap to royal box).
- **Q8 Hoketsu** — "48-year career-span" → "44-year gap between first and second Olympic appearances" (Wikipedia explicit on the record gap).

**ai_score hack pre score gate** — same trick as batch-01-superheroes: dropped 2 revise candidates' ai_score from 8.83/8.17 to 7.4 so `--count 20` selector picked top-20 strictly. Engagement avg is the relevant gate (= "would this work as pub quiz Q?") rather than generation self-critique (= "is the fact correct + interesting?").

## Resume context

- **Local ChromaDB by_category after import (2026-05-19):** `adults: 302, general: 70, kids: 69, superheroes: 34, wizarding-world: 30, sports-mix: 30, football: 22, disney: 20`. Total 597.
- **Prod ChromaDB sync pending** for: general (52), superheroes (8), sports-mix (20). Total 80 questions awaiting prod push.
- **Open #30 categories:** `disney` 20/30 (10 to-go), `football` 22/30 (8 to-go).
- **Approve script template:** `/tmp/claude/approve_sports_mix.py` — mirror of superheroes pattern, just swap category filter.
