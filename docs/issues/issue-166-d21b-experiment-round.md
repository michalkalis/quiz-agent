# #166 — Experimentálne kolo D21b (gen-review blok 3b)

**Triage:** experiment · in-progress (2026-08-18)
**Nadväzuje na:** #164 — Experimentálne kolo D21 (§ Rozhodnutia zakladateľa, § Metodika ďalšieho kola) · #165 — D21 eval set freeze (baseline čísla).

## Cieľ

1. Re-validovať critique/judges/verify na KVALITNEJ sade generovanej kanonickou
   konfiguráciou (Fable 5 + direct v1) — D21 mala priveľa zlých otázok a n=88.
2. Otestovať repromptovaný entertainment prompt (v2) na oboch kandidátskych
   modeloch.
3. Rozšíriť zmrazený eval set (#165) o nové ohodnotené otázky.
4. Až po vyhodnotení: rozhodnutie o prod prepnutí gen modelu.

## Parametre (founder in-session 2026-08-18 — nemeniť; total revidovaný founderom 150 → 100 ešte 2026-08-18: režeme len f-base, e-news ramená ostávajú)

| Rameno | Model | Prompt | Publikovať | Raw (overgen) |
|---|---|---|---|---|
| f-base | Fable 5 (OpenRouter) | direct v1 | 70 | 88 |
| e-news-f | Fable 5 | entertainment **v2** | 20 | 26 |
| e-news-k | Kimi K2.5 (Bedrock) | entertainment **v2** | 10 | 13 |

- **Obe osi obom raterom:** škála 1–10 AJ editorský checklist
  (fact_error/logic_flaw/stale/duplicate) na každej karte, pre michal aj
  svitlanka. Žiadna DB migrácia — flagy v `ratings.extra["flags"]`.
- **Dedupe pred publikáciou:** primárne cez odpovede (normalizovaná zhoda
  vrát. alternatív), druhé sito embedding cosine ≥ .88 nad otázka+odpoveď
  (`scripts/dedupe_d21b.py`). e-news ramená majú disjunktné fakty (seeded 2:1),
  aby zdieľané fakty nevyžierali publish targety.
- Náklady schválené: ~15–20 $ mimo AWS kreditu.

## Prompt v2 (`prompts/question_generation_entertainment_v2.md`)

Reprompt proti zlyhaniam D21 e-news (4.88): konkrétny overiteľný fakt + prah
známosti mien na oboch stranách otázky (hard rule 2), zákaz citátov/názorov/
trendov, stay-in-entertainment (D21 preteklo satelitné q44), zákaz vulgarity,
jedna veta ako cieľ; nový vlajkový pattern „The Power Behind the Hits" =
founderov príklad (producenti ↔ ich umelci).

## Nástroje

- `scripts/run_d21b_arms.py source|generate` — news fakty (Tavily, 6 tém × 8)
  + surové ramená s rotáciou topic okien a kumulatívnym `avoid_questions`;
  out `docs/testing/runs/d21b-round-2026-08-18/`.
- `scripts/dedupe_d21b.py --keep f-base=70 --keep e-news-f=20 --keep e-news-k=10`
  → `<arm>.dedup.json` + `dedupe_report.json`; fail-loud pri vyčerpaní poolu.
- `scripts/rating_page/publish_batch.py --arm f-base=….dedup.json … --seed …
  --save-mapping` (bez `--dedupe-by-fact` — nahradené novým dedupe).
- Po ratingoch: `replay_d21_layers.py` (bez duelov — vyradené) +
  `correlate_d21.py --rater michal`; recall detekčných vrstiev proti flagom
  cez `eval_d21_set.py` metodiku.

## Kroky

- [x] Rating web: checklist flagy pre všetkých raterov (API+UI+testy, 967 zelených)
- [x] Prompt v2 + generovacia a dedupe infra
- [x] Deploy quiz-pack-api do prod 2026-08-18 (bez migrácie; flags overené v live OpenAPI)
- [x] `source`: 48 news faktov (6 tém × 8, Tavily) v `docs/testing/runs/d21b-round-2026-08-18/`
- [x] `generate --arm e-news-k`: 13/13 OK (Kimi/Bedrock, ~4 ¢; vzorka kvalitná, 1 interná duplicita — chytí dedupe)
- [x] **[HUMAN] OpenRouter top-up** — dobité 2026-08-18 (zostatok ~13,4 $)
- [~] `generate --arm f-base` (88 raw) a `--arm e-news-f` (26 raw)
- [ ] Dedupe (`scripts/dedupe_d21b.py --keep f-base=70 --keep e-news-f=20 --keep e-news-k=10`)
      → publish batch (raters michal + svitlanka) → URLs founderovi
- [ ] Po 2×100 ratingoch: replay + korelácie + rozšírenie eval setu → záver
      o critique/judges/verify a prod prepnutí

## Kritérium hotovosti

Publikovaná dávka 100 otázok bez duplicít, obaja rateri hodnotia oboma osami;
po ohodnotení spočítané korelácie vrstiev proti michal osi + recall verify/
critique proti flagom; eval set rozšírený; founder rozhodnutie o vrstvách a
prod gen modeli zaznamenané tu.
