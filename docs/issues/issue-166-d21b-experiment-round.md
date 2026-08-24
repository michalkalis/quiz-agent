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
- [x] **[HUMAN] OpenRouter top-up** — dobité 2026-08-18 (60 $ total)
- [x] Generovanie všetkých ramien 2026-08-18 — vo viacerých pasoch (pooly:
      f-base 124, e-news-f 34, e-news-k 55 raw). Prvý pas mal priveľa duplicít
      (f-base 31/88; e-news-k len ~4 rôzne odpovede z 13 — Kimi sa fixuje na
      málo faktov), preto `--target`/`--facts-file` top-up flagy v
      `run_d21b_arms.py` + čerstvé fakty len pre Kimi (`facts_news_k2.json`,
      26 nových, URL-disjunktné s pôvodnými). OpenRouter 402 na nízkom
      zostatku = rezervácia plného 64k output capu → explicitný
      `max_tokens=16384` v skripte.
- [x] Dedupe: kept 70/70 + 20/20 + 10/10 (dropped 88; `dedupe_report.json`)
- [x] Publish 2026-08-18: batch `df12c686-a914-4715-a71b-6b94190a19bd`, 100 q,
      rateri michal + svitlanka; mapping v run dir; checklist flagy overené
      v live HTML (4/4 prítomné)
- [~] **[HUMAN] ratingy 2×100** — michal 100/100 hotové 2026-08-18/20
      (0 checklist flagov); **svitlanka 0/100 — čaká sa**
- [x] Replay 4 vrstiev (bez duelov) nad publikovanou 100 — 2026-08-21,
      `replay/replay_results.json` (pozor: run-dir `replay/` = dedup súbory,
      nie raw pooly; manifest musel dostať všetky 3 ramená). Env zrkadlil
      prod (JUDGE_MODELS z fly: deepseek.v3.2 + zai.glm-5).
- [x] Agentný fact-check 100 q (5× Sonnet subagent s webom) —
      `factcheck_agent_2026-08-21.json`
- [x] Korelácie — `replay/correlations.json`; závery nižšie
- [ ] Rozšírenie zmrazeného eval setu (#165 — D21 eval set freeze) o D21b
      otázky vrát. fact-check anotácií
- [x] [HUMAN] founder rozhodnutie 2026-08-24: **schválené všetky 3 návrhy** —
      (1) prod gen → Fable 5 + direct v1, (2) critique + judges vyradiť
      z gen pipeline, (3) verify nahradiť Claude web-grounded fact-checkom
      (minimálne pre news/entertainment). Implementácia = nová session
      (handoff v docs/handoffs/).

## Implementácia (2026-08-24, poradie schválené founderom in-session)

Inkrement 1 = (1)+(2) naraz (presne meraná D21b konfigurácia), staré verify
ostáva ako poistka. Inkrement 2 = (3) web fact-check cez firemný Anthropic
účet (natívne web search — vzor, ktorý chytil 6/6; účet aj tak treba na
korpus-regrow).

- [x] Inkrement 1 v kóde (commit `81825633`): DIRECT_GENERATION default on
      (sourcing skip, F8 stand-down), GEN_PROMPT_VERSION=direct_v1,
      BEST_OF_N off (bez overgen/critique/duelov), JUDGE_GATE off
      (ScoringStage bez panelu drží deterministické brány), max_tokens=32768
      na gen LLM (OpenRouter 402 gotcha). Každá zmena má env rollback páku.
      Testy 978 passed 2×; reálny smoke (Fable/OpenRouter, direct v1) OK.
- [x] Prod secret pripravený: `LLM_ROLE_GEN=claude-fable-5` staged
      (aplikuje sa najbližším deployom; dnešná hodnota bola
      `bedrock:moonshotai.kimi-k2.5` = rollback).
- [x] [HUMAN] Fly billing uhradený founderom 2026-08-24
- [x] Deploy quiz-pack-api 2026-08-24 + skúšobný pack e2e: admin order
      pack_10 doručený za **3 min 17 s**, 10/10 otázok, **84 ¢ celkovo**
      (LLM 68 ¢ + Tavily verify 16 ¢) — vs. ~30–40 min a pack_30 COGS
      ~4,23 $ pred zmenou; extrapolácia pack_30 ≈ 2,5 $ aj s Fable gen.
      Prod overený: LLM_ROLE_GEN=claude-fable-5, sourcing skip (direct),
      citation-strip aktívny. Objednávka 13ccb5a2, pack 5cb50f9b.
- [x] Inkrement 2: web-grounded fact-check namiesto verify — kód `6aa295cf`
      (FactVerifier = adversariálny Claude fact-check s natívnym web_search,
      FACTCHECK rola claude-sonnet-5, verdikty ok/fact_error/logic_flaw/stale,
      problem = drop, výpadok = fail-closed withhold #158; náklady cez
      StageResult.cost_cents). Testy 986 passed 2×. **NASADENÉ 2026-08-24**
      (ANTHROPIC_API_KEY secret + deploy) a e2e overené: admin pack_10
      doručený za **5 min 15 s**, 9/10 otázok, verdikty v
      `generation_metadata.extra` (9/9 „ok" 0.9, notes s reálnymi zdrojmi —
      Britannica, Snopes atď.), žiadne 429 (retry_count 0, concurrency 8 OK).
      Objednávka d46add92, pack 0b543fbd.
- [x] Cost flag: fact-check ~180 ¢/pack_10 (≈ 18 ¢/q; celkovo 262 ¢ = gen
      82 ¢ + fact-check) — nad odhadom; dôvod: web výsledky = input tokeny ×
      multi-turn resume. Pack_30 ≈ 7–8 $. **Founder 2026-08-24 večer schválil
      3-bodový plán zlacnenia (inkrement 3):**
      1. Dvojúrovňová kontrola — evergreen otázky lacná/žiadna web kontrola
         (D21b: f-base 70/70 čistý), plný web fact-check len news/fresh.
      2. Lacný variant (vlastný search Exa/Tavily + kompresia kódom +
         single-turn model) validovať na D21b sade — akceptačná latka
         recall 6/6 na q03/q18/q32/q48/q63/q81
         (`docs/testing/runs/d21b-round-2026-08-18/factcheck_agent_2026-08-21.json`)
         + nízke falošné alarmy; bez prejdenia latky sa prod fact-check nemení.
      3. Hneď: `_MAX_WEB_SEARCHES` 5 → 2–3 (validovať na D21b sade);
         korpus regrow fact-check cez Anthropic Batch API (−50 %).
      Prieskum hotových riešení: FacTool/SAFE/Loki/OpenFactCheck = mŕtvy
      2024 výskumný kód, žiadny drop-in; Perplexity Sonar / Exa /answer =
      lacné grounded API kandidáti pre bod 2. Bedrock modely len v bode 2
      (Bedrock nemá natívny web search). Tavily už v ostrom toku nebeží
      nikde — zvážiť zrušenie plateného plánu.
- [ ] Pozorovanie z e2e: v packu prešli 2 near-duplicitné Zanzibar otázky
      (dedup ich nechytil); 10. otázka padla v pipeline pred persistom
      (nie je v DB — gate/dedup/fact-check drop, log sa nezachoval).

## Výsledky — os 2 (fact-check) a vrstvy (2026-08-21)

**Fact-check (agentná editorská os):** 6/100 reálnych problémov — 4 fact_error
+ 2 stale, **všetky v e-news ramenách** (e-news-f 3/20, e-news-k 3/10);
f-base **70/70 fakticky čistý**. Nálezy: q03 (Last Christmas prekonal
„jediný 2× UK Christmas No.1"), q18 (Snoop 16→20 nominácií), q32+q81
(Spider-Man: Brand New Day je 2026, nie 2025), q48 (Derringer neprodukoval
Steely Dan), q63 ($2B za 17, nie 20 dní).

**Korelácie vrstiev vs. michal (n=100, Spearman):** critique .205 ·
judges .175 · answerability .056 · verify .015 — žiadna vrstva nepredikuje
zábavnosť (konzistentné s D21: .19/.24/.22/.11).

**Recall detekčných vrstiev proti 6 chybám: 0/6.** Verify dalo 5/6
„verified" s conf .88–.95 (len q32 „uncertain"); critique factual_accuracy
9–10 na všetkých 6. Falošné alarmy na čistých: verify 1 (q31), critique 1
(q89 fa=1). Verify je na news otázkach z 2026 slepé — chyby chytil až
web-grounded Claude fact-check (6/6).

**Návrh záverov (na founder potvrdenie):**
1. Prod gen → Fable 5 + direct v1 potvrdené (8.01 @ n=70, 0 faktických chýb).
2. Critique + judges na Fable kvalite nepridávajú signál (ani zábava, ani
   fakticita) → kandidáti na vyradenie z pipeline pre f-base tok.
3. e-news potrebuje nový web-grounded fact-check krok (Claude + web, ako
   agentná os) — súčasné verify (DeepSeek) na aktuálnych faktoch zlyháva;
   stale riziko je vlastné news otázkam → pri publikácii news packov
   kontrola čerstvosti.

## Výsledky — os 1 produktová metrika (michal, 100/100, 2026-08-20)

| Rameno | n | Priemer | Medián | ≥8 | ≤4 |
|---|---|---|---|---|---|
| f-base (Fable direct v1) | 70 | **8.01** | 8.5 | 47 (67 %) | 5 |
| e-news-f (Fable, ent. v2) | 20 | **7.85** | 7.5 | 10 | 1 |
| e-news-k (Kimi, ent. v2) | 10 | 7.20 | 8.0 | 6 | 1 |
| celkovo | 100 | 7.90 | 8.0 | 63 | 7 |

- **Fable direct v1 potvrdený na veľkej vzorke**: D21 9.12 (n=8) → 8.01 (n=70);
  pokles je očakávaná regresia k priemeru, úroveň drží (29 % otázok = 10/10).
- **Entertainment reprompt v2 = najväčší skok kola: 4.88 → 7.85** (Fable).
  Kimi na tom istom prompte 7.20 (n=10) — použiteľný, ale slabší a pri
  generovaní sa fixoval na málo faktov.
- **Pozor na interpretáciu flagov:** michal fakticitu aktívne nekontroloval
  (founder 2026-08-21) — 0 flagov ≠ 0 chýb. Dôvody nízkych skóre sú
  štylistické (príliš očividné q23/q67, prekomplikované znenie q29/q38/q34,
  niche fakt q22), ale editorská os chýba.
- **Editorská os (founder 2026-08-21):** svitlanka toto kolo hodnotiť nebude
  a founder sa faktickej kontrole chce vyhnúť → náhrada = agentný
  web-grounded fact-check všetkých 100 otázok (Claude subagenti s vyhľadávaním);
  founderovi sa predložia len podozrivé nálezy na potvrdenie. Recall
  verify/critique sa počíta proti tejto osi.

## Náklady Fable 5 vs. custom packy (founder 2026-08-19 — súčasť rozhodnutia po D21b)

Fable 5 = 10 $/M vstup, 50 $/M výstup. Namerané v tomto kole: ~10 ¢/publikovanú
otázku len za generovanie (direct mode, vrát. overgenu) vs. Kimi < 1 ¢. Custom
pack_30 by s Fable gen stúpol z COGS ~4,20 $ na ~7 $+ → pri cene 4,99 € strata
na každom predaji. **Rozhodnutie o riešení až po vyhodnotení D21b.** Founder
sa prikláňa k **Anthropic Batch API cez priamy Anthropic účet** (−50 % na
asynchrónne dávky; pack gen je aj tak background job) → gen packu ~1,5 $.
Dôsledky, ak sa potvrdí: firemný Anthropic účet (pravidlo company accounts),
batch cesta v LLM factory popri OpenRouter, ANTHROPIC_API_KEY v prod secrets.
Alternatívy na stole: dvojúrovňová stratégia (Fable len korpus/oficiálne packy,
custom na lacnom modeli) a hybrid (lacný generátor + Fable výber/edit).

Update founder 2026-08-21: Batch API potvrdený ako preferovaný smer; custom
pack smie byť spočiatku stratový (loss leader na akvizíciu platiacich),
cena sa stiahne časom (lacnejšie modely alebo iné riešenie). Finálne
rozhodnutie stále až po vyhodnotení D21b.

Parametre Batch API (overené v oficiálnych docs 2026-08-24, na founder
otázku): väčšina dávok < 1 h, garantovaný strop 24 h (nestihnuté requesty
expirujú NEúčtované); limit dávky 100 000 requestov / 256 MB; vlastné rate
limity (Start tier: 1 000 volaní/min, 200 000 requestov vo fronte); nový
účet štartuje na znížených Evaluation-tier limitoch; zľava 50 % na vstup aj
výstup; výsledky 29 dní; spend cap Start tieru 500 $/mes.

**Update founder 2026-08-24: Batch API pre CUSTOM packy VYRADENÉ — latencia
(typicky < 1 h, strop 24 h) je pre zákaznícku objednávku pridlhá; pack sa má
vygenerovať čo najrýchlejšie.** Custom packy teda pôjdu realtime API
(paralelné volania = jediná rýchlostná páka aj proti dnešnému ~30–40 min
pipeline). Batch API ostáva relevantné len tam, kde latencia nehrá rolu:
korpus, oficiálne/mesačné packy, eval replaye — **founder 2026-08-24 potvrdil
korpus-cez-batch ako smer, ktorý sa ide robiť čoskoro (TODO položka
„Spoločný korpus — regrow cez Anthropic Batch API").** Cenové páky pre custom packy
na stole (rozhodnutie po D21b): loss leader s Fable realtime (schválené
08-21 ako štart) → časom lacnejší model (Kimi 7.20 použiteľný) alebo hybrid
(lacný generátor + Fable výber/edit).

## Kritérium hotovosti

Publikovaná dávka 100 otázok bez duplicít, obaja rateri hodnotia oboma osami;
po ohodnotení spočítané korelácie vrstiev proti michal osi + recall verify/
critique proti flagom; eval set rozšírený; founder rozhodnutie o vrstvách a
prod gen modeli zaznamenané tu.
