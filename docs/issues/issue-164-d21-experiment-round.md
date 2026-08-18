# #164 — Experimentálne kolo D21 (gen-review blok 3)

**Triage:** in-progress (2026-08-15, session so zakladateľom)
**Nahrádza:** odložené #153 Phase A kolo 2 (rozhodnutie D10).
**Kontext:** `docs/research/gen-pipeline-joint-review-2026-08-09.md` (D21, D27, kandidát 7 + 17).

## Cieľ

1. Vygenerovať surové otázky v izolovaných ramenách (bez kritika/duelov/brán/sudcov),
   zakladateľ + 1 hodnotiteľ ich ohodnotia cez multi-rater web (#154).
2. Tie isté otázky prehnať vrstvami pipeline (kritik, duely, answerability,
   sudcovia, verifikácia — D27) a spočítať korelácie s ľudskými hodnoteniami
   per vrstva → ktoré vrstvy ostávajú, prahy, judge panel, kanonické prompty.
3. Ohodnotené otázky zmraziť ako P1 eval set.

## Schválená matica (zakladateľ in-session 2026-08-15)

11 ramien × 8 otázok = 88 otázok. Jedna os sa mení naraz.

| Rameno | Režim | Model | Prompt |
|---|---|---|---|
| g-v3 | grounded | Kimi K2.5 (Bedrock) | v3 fact-first (prod baseline) |
| g-v5free | grounded | Kimi K2.5 | v5-free (víťaz #153 kola 1) |
| g-v6free | grounded | Kimi K2.5 | v6-free (nikdy nehodnotený) |
| d-base | direct | Kimi K2.5 | **nový direct v1** (D3/D16), bez persony (D23d) |
| d-persona-a | direct | Kimi K2.5 | direct v1 + „retold at table" (D23a) |
| d-persona-b | direct | Kimi K2.5 | direct v1 + „no way really" (D23b) |
| d-gemini | direct | Gemini 3.1 Pro (OpenRouter) | direct v1 |
| d-deepseek | direct | DeepSeek V3.2 (Bedrock) | direct v1 |
| d-opus | direct | Opus 5 (OpenRouter; Bedrock Claude zamknutý, re-overené 08-15) | direct v1 |
| d-fable | direct | Fable 5 (OpenRouter) | direct v1 |
| e-news | grounded + news search | Kimi K2.5 | entertainment (kandidát 17, #76 F-3b: `ENABLE_NEWS_SOURCING=1`) |

Vyradené: v4 (prehral #153 kolo 1), duely ako os (D22 — rameno bez duelov je
implicitné: všetky ramená sú surové). Persona c (auto) vyradená v D23.

## Metodické opory

- Ramená g-* zdieľajú IDENTICKÝ fact set (`facts_shared.json`, Tavily+wiki,
  OpenTDB off kvôli D6); direct ramená zdieľajú tie isté témy.
- e-news má vlastné témy z aktuálneho diania (news mód Tavily, čisto web) —
  hodnotí sa samostatne, nie proti ostatným ramenám.
- Surové generovanie = žiadna výberová vrstva nesmie filtrovať, inak sa
  korelácie nedajú spočítať (D21). `critique_llm=None`, `_generate_batch` priamo.
- Blind: publish_batch.py zamieša a preznačí na q01…; mapping ostáva len
  lokálne + na serveri.

## Nástroje (všetko v `apps/quiz-pack-api/scripts/`)

- `run_d21_arms.py source|generate` — fakty + surové ramená → `docs/testing/runs/d21-round-2026-08-15/`
- `rating_page/publish_batch.py` — publikácia na multi-rater web (prod)
- `replay_d21_layers.py` — po ohodnotení: 5 vrstiev nad tými istými otázkami,
  priebežné ukladanie/resume; env musí zrkadliť prod stack (Bedrock critique/verify)
- `correlate_d21.py --ratings <export.jsonl> --batch-id <id>` — join +
  Spearman/Pearson per vrstva + per-arm priemery

## Stav

- [x] Matica + náklady schválené zakladateľom (P6) — modely +Fable 5; hodnotia 2 raters
- [x] Nový direct prompt v1 + persona a/b varianty
- [x] Multi-rater web mobilný (rate.html responsive pass)
- [x] Fakty: 24 shared + 24 news
- [x] Generovanie 11 ramien — 88/88 otázok OK (usage: ~150k in / 42k out tokenov)
- [x] Deploy quiz-pack-api (mobile web) — health 200
- [x] Publikované 2026-08-15, batch `c1f109ec-9cc9-432c-88fd-d41e39292aec` (88 otázok, seed 20260815, bez dedupe — všetky otázky musia byť ohodnotené):
      `https://quiz-pack-api.fly.dev/web/rate/c1f109ec-9cc9-432c-88fd-d41e39292aec?rater=michal` · druhý hodnotiteľ `?rater=rater2` (meno v URL = atribúcia; nemeniť uprostred hodnotenia)
- [x] Ohodnotené 2026-08-18: michal 88/88, druhý rater hodnotil pod menom `svitlanka` (nie `rater2`) 88/88
- [x] Replay + korelácie hotové 2026-08-18 (fix: stale langchain import v replay skripte; correlate číta `blinded_qid`). Výsledky nižšie. Pôvodné príkazy:
      1. `uv run --no-sync python scripts/rating_page/export_ratings.py --base-url https://quiz-pack-api.fly.dev --admin-key $QUIZ_PACK_ADMIN_API_KEY --out ratings_export.jsonl`
      2. env zrkadliaci prod: `LLM_GATEWAY=openrouter LLM_ROLE_CRITIQUE=bedrock:deepseek.v3.2 VERIFY_MODEL=bedrock:deepseek.v3.2` + `JUDGE_MODELS` prečítať z prod secrets (`fly ssh console -a quiz-pack-api -C env`) — POZOR, bez toho sudcovský panel beží na code-default, nie prod paneli
      3. `... uv run --no-sync python scripts/replay_d21_layers.py`
      4. `uv run --no-sync python scripts/correlate_d21.py --ratings ratings_export.jsonl --batch-id c1f109ec-9cc9-432c-88fd-d41e39292aec --rater michal`
- [ ] P1: zmraziť ohodnotené otázky ako eval set (nadväzné issue)

## Výsledky (2026-08-18)

Per-arm human mean (obaja raters, 8 q/rameno):
d-opus 8.38 · d-fable 7.75 · g-v5free 7.38 · d-gemini 7.00 · d-base 6.88 ·
d-deepseek 6.88 · g-v6free 6.31 · g-v3 6.25 · d-persona-b 5.88 · e-news 5.25 ·
d-persona-a 5.00

Korelácie vrstiev s ľuďmi (Spearman, both/michal/svitlanka):
critique .18/.19/.05 · duely (within-arm) .15/.00/.14 · answerability .24/.22/.13 ·
judges panel .21/.24/.13 · verify .08/.11/.08

**Kľúčový nález: inter-rater Spearman = −0.04 (n=88)** — hodnotitelia sa na
per-otázkovej kvalite prakticky nezhodujú; per-otázkové korelácie vrstiev sú tým
zhora ohraničené šumom. Per-arm poradie je konzistentnejšie (d-opus top u oboch;
persona varianty a e-news dole u oboch; nezhoda hlavne d-fable/d-base/g-v3).

Interpretačné dôsledky (na spoločnú session, nerozhodnuté):
- Žiadna vrstva pipeline nekoreluje silno (max ~.24); verify a duely prakticky nulové.
- Persona prompty (D23a/b) škodia vs. d-base u oboch raterov.
- Frontier direct (Opus/Fable) > grounded Kimi ramená; v5-free ostáva najlepší Kimi prompt.
- e-news slabé — news mód potrebuje repromptovanie, nie zahodenie (8 q, malá vzorka).

Artefakty: `apps/quiz-pack-api/ratings_export.jsonl`, replay + correlate výstupy
v `docs/testing/runs/d21-round-2026-08-15/`.

## Náklady (odhad, schválený)

Generovanie ~$1 (prevažne AWS kredit); replay ~$5–10 (prevažne AWS kredit);
reálne peniaze mimo kreditu (OpenRouter: Gemini/Opus/Fable + answerability) < $5.

## Otvorené

- mba nedostupný (LAN+Tailscale) — zakladateľov entertainment príklad z ~12.8.
  zapracovať do promptu, keď sa mba zobudí (netreba pred generovaním, zadanie
  je zachytené v TODO).
- Wikipedia zdroj vrátil 0 faktov pri shared sourcing behu (Tavily pokryl
  budget) — nepreskúmané, nezablokovalo; pozrieť pri bloku 4 (sourcing).
