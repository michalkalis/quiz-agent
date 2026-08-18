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

## Výsledky a uzavretie (2026-08-18)

**Interpretačný rámec (rozhodnutie zakladateľa):** rater „michal" = cieľová
produktová metrika (zábavnosť/hrateľnosť v aute) — voči nej sa hodnotia ramená,
prompty aj vrstvy. Rater „svitlanka" = editorský/faktický pohľad — nie škála
kvality, ale zdroj reálnych chýb, ktoré má chytať pipeline. Súhrnné „both"
čísla z prvého behu correlate sú preto zavádzajúce a nižšie sa nepoužívajú.

### Os 1 — produktová metrika (michal, 8 q/rameno)

d-fable **9.12** · d-base 8.38 · d-opus 8.25 · g-v3 8.00 · g-v5free 7.50 ·
g-v6free 7.50 · d-deepseek 6.88 · d-gemini 6.75 · d-persona-b 6.12 ·
e-news 4.88 · d-persona-a 3.88

Závery pre prompt/model:
- **Direct v1 prompt vyhráva nad grounded promptami aj na tom istom modeli**
  (Kimi: d-base 8.38 > g-v3 8.00 > v5free/v6free 7.50). Kandidát na kanonický prompt.
- **Frontier direct je top** (d-fable 9.12); persona varianty (D23a/b) jasne
  škodia (3.88/6.12 vs base 8.38) → vyradiť.
- e-news 4.88 — najslabšie rameno; reprompt, nie zahodenie (n=8).

Vrstvy vs. michal (Spearman): judges .24 · answerability .22 (pass 7.33 vs
fail 6.05) · critique .19 · verify .11 · **duely .00**. Žiadna vrstva
nepredikuje zábavnosť silno; duely sú na tejto osi mŕtve.

### Os 2 — editorské nálezy (svitlanka) a či ich pipeline chytila

Reálne faktické/logické chyby + verdikt verify vrstvy z replaya:

| Q | Rameno | Chyba | verify |
|---|---|---|---|
| q27 | d-deepseek | JA má DVE vnútrozemské krajiny (Bolívia+Paraguaj), otázka tvrdí jednu | ❌ verified |
| q35 | d-base | „dve farby oceánu na Cape Horn" = geografický mýtus (reálne Encontro das Águas) | ❌ verified |
| q46 | d-persona-b | Voyager 1 štartoval za Cartera, nie Forda | ❌ verified |
| q33 | g-v3 | červené Skittles už karmín nepoužívajú (prítomný čas = nepravda) | ❌ (nedetegované) |
| q24 | d-base | „orgán prežije v tme" — logický nezmysel | ✅ likely_wrong |
| q52 | g-v3 | košenila nie je chrobák (beetle) | ✅ likely_wrong |
| q68 | g-v6free | cena výroby penny — zastaraný údaj | ✅ likely_wrong |

- Verify chytila **3 zo 7** tvrdých chýb. Jej verdikt pritom s editorskou osou
  súhlasí (svitlanka mean: likely_wrong 3.0 vs verified 6.3) → verify je reálny,
  ale deravý detektor chýb; nízka korelácia s michalom je očakávaná (meria
  správnosť, nie zábavu). Chýbajú jej hlavne chyby vyžadujúce web-grounding
  (q27, q35, q46 sú z parametrickej pamäte direct módu).
- **Frontier direct ramená (d-opus, d-fable) nemajú ani jednu editorsky
  nájdenú faktickú chybu**; Kimi direct (d-base) má 2, DeepSeek 1.
- 16 z jej 88 hodnotení sú jednotky za **duplicity** — artefakt dizajnu kola
  (ramená zdieľajú fakty/témy, publikované zámerne bez dedupe). Nie sú to dáta
  o kvalite otázok a z jej škály sa vylučujú.

**Inter-rater Spearman = −0.04 (n=88), po vylúčení duplicít −0.05 (n=72)** —
nezhoda nie je artefakt duplicít, sú to skutočne dve nezávislé osi. Per-otázkové
korelácie vrstiev proti zmiešanej škále sú preto bezcenné; správna referencia
vrstiev = michal (zábava) + binárne editorské nálezy (chybovosť).

### Metodika ďalšieho kola (zafixované)

1. **Dve oddelené osi:** michal hodnotí 1–10 (produktová metrika). Druhý rater
   dostane editorský checklist (faktická chyba / logická diera / zastaraný údaj /
   duplicita + komentár), NIE škálu 1–10.
2. **Dedupe pred publikáciou** (alebo duplicitné položky explicitne označené
   a vylúčené z korelácií).
3. Korelácie vrstiev sa počítajú len proti michal osi; editorské nálezy sa
   vyhodnocujú ako recall detekčných vrstiev (verify/critique), nie Spearmanom.

### Stav rozhodnutí

- Vyradené (dáta jednoznačné, oba osi): persona prompty D23a/b, duely ako vrstva.
- Na schválenie zakladateľom (interaktívne): kanonický prompt + gen model,
  osud critique/answerability/verify vrstiev, e-news reprompt. Zapíše sa sem.

Artefakty: `ratings_export.jsonl`, replay + correlate výstupy (aj per-rater
`correlations_michal.json` / `correlations_svitlanka.json`)
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
