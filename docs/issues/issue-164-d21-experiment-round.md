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
- [~] Generovanie 11 ramien (beží)
- [ ] Publikácia batchu + linky pre raterov
- [ ] Deploy quiz-pack-api (mobile web) — pred hodnotením
- [ ] ČAKÁ NA ĽUDÍ: ohodnotenie 88 otázok
- [ ] Replay + korelácie (jeden príkaz, po ratingoch)
- [ ] P1: zmraziť ohodnotené otázky ako eval set (nadväzné issue)

## Náklady (odhad, schválený)

Generovanie ~$1 (prevažne AWS kredit); replay ~$5–10 (prevažne AWS kredit);
reálne peniaze mimo kreditu (OpenRouter: Gemini/Opus/Fable + answerability) < $5.

## Otvorené

- mba nedostupný (LAN+Tailscale) — zakladateľov entertainment príklad z ~12.8.
  zapracovať do promptu, keď sa mba zobudí (netreba pred generovaním, zadanie
  je zachytené v TODO).
- Wikipedia zdroj vrátil 0 faktov pri shared sourcing behu (Tavily pokryl
  budget) — nepreskúmané, nezablokovalo; pozrieť pri bloku 4 (sourcing).
