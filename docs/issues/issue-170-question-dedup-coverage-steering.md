# #170 — Coverage-driven dedup: pozitívne riadenie tém pre priame generovanie otázok

**Triage:** backend/content · needs-triage
**Status:** prep (`/prepare-issue`)
**Created:** 2026-09-03
**Reversibility:** `b` — potvrdené v Phase 1 a spresnené v Phase 2 (D8/D9): alembic migrácia nutná (4 nullable stĺpce na `questions`; **žiadna zmena vector indexu** — D9). Všetko ostatné aditívne za feature flagmi default OFF. → `ready-for-human`, nie Ralph.

## Why

Founder (2026-09-03): s rastúcim korpusom bude drahšie a ťažšie odhaľovať duplikáty a nové generovania budú produkovať čoraz viac duplikátov. Otázka: nedáva zmysel posielať kľúčové slová / hinty už do generačného promptu, aby bola prevencia lacnejšia než post-hoc zahadzovanie?

Research `docs/research/question-dedup-strategy.md` (2026-09-03): detekcia (pgvector + `text-embedding-3-small`) s rastom DB nedrahne; rastie **odpad** (zaplatená generácia za zahodený duplikát) kvôli mode collapse generátora. Na kanonickej priamej ceste (od #166 `DIRECT_GENERATION` default) dostane generátor iba kategóriu + počet: `{topic_section}` aj `{avoid_section}` v `prompts/question_generation_direct.md` sú prázdne, `TopicPool` sa nevolá. Best practice = pozitívne pridelenie buniek (kategória × podtéma × typ otázky) z mapy pokrytia; celokorpusové negatívne zoznamy sa neškálujú (pink elephant, lineárny kontext).

## Locked decisions (founder 2026-09-03)

1. Strop opakovaných odpovedí platí **per kategória**, nie globálne.
2. Duplikát v korpuse **nie je tragédia**; cieľ je nízky odpad, nie nulová tolerancia.
3. **Custom packy sú nezávislé od globálneho korpusu**: žiadny pack ↔ korpus dedup, prekryv nevadí.
4. **Kvalita otázok sa nesmie znížiť ani zmeniť** (founder 2026-09-03, dôrazne): dnešné otázky sú veľmi kvalitné. Každá zmena promptu/pipeline ide za feature flag, default OFF, a zapína sa až po slepom porovnaní na ratovanej dávke (rovnaká kategória, rovnaký model) bez poklesu kvality. Prompt mimo `{topic_section}`/`{avoid_section}` sa nemení.
5. **Podtémy:** model navrhne (~15–20 na kategóriu), founder jednorazovo schváli; cieľ neskôr plne automaticky, ale prvé kolo vždy s overením. Výsledok = statický súbor v repe, ďalej bez LLM.
6. **Strop rovnakej odpovede:** žiadne fixné číslo. Per-kategória konfigurovateľný, skôr voľnejší; rôzne kategórie sú rôzne špecifické, takže rôzne stropy (plán navrhne východiskové hodnoty per kategória, founder doladí).
6a. **`entertainment` znesie voľnejší dedup než evergreen korpus** (founder 2026-09-03, relay z #167 session):
   konkrétna inštancia locked 6 — per-kategória prísnosť musí byť konfigurovateľná pre **strop odpovedí aj
   cosine prah**, a `entertainment` dostane najvoľnejšie hodnoty. Zdroj: memory `project_167_pilot_verdict_2026_09_03`,
   issue-167 § Follow-ups („per-category dedup strictness"). Implementáciu vlastní #170, z #167 nepríde.
7. Mimo rozsah: UX "otaguj ako duplikát → náhradná otázka zadarmo" (+ anti-abuse) = samostatný follow-up; per-user expozícia; novelty score do scoring (voliteľný follow-up).

## Raw scope (founder prompt)

1. Register odpovedí/podtém pri persist + mapa pokrytia buniek kategória × podtéma × typ otázky.
2. Pozitívne pridelenie najmenej pokrytých buniek do direct promptu (`{topic_section}`), krátky cielený `{avoid_section}` ≤ ~10 položiek na bunku, nikdy celokorpusový zoznam.
3. Strop opakovaných odpovedí per kategória v `DedupStage` + embedding otázka+odpoveď (prekalibrovať prahy na ratovanej dávke).
4. Lacný LLM sudca pre šedú zónu cosine ~0.70–0.85.
5. Overiť HNSW index na `questions.embedding`.

Otvorené pre plán: podtémy pre bunky ručne (~10–20 na kategóriu) vs. navrhnuté modelom + schválené founderom.

## Research (Phase 1)

> Web pass: **ran 2026-09-03** offline via `docs/research/question-dedup-strategy.md` (external best-practice sourcing already done there) — `/deep-research` NOT re-run.

### A. Code recon

**Direct prompt path (the gap is real).**
- `prompts/question_generation_direct.md`: `{topics}` in the order header; `{topic_section}` + `{avoid_section}` sit one line each after `**Question Type:**`. Empty → the placeholder collapses to a blank line, no heading text reaches the model.
- `app/generation/prompt_builder.py:233-236` builds `topic_section` (`**Preferred Topics:** …` + optional `**Avoid Topics:** …`); `:239-243` builds `avoid_section` (`**Do NOT repeat…**` + `avoid_questions[:10]`, the hard cap of 10); `:283` `topics` falls back to the literal `"any"`.
- `advanced_generator.py` never fills them — it forwards `topics/excluded_topics/avoid_questions` kwargs at 8 call sites (`:506,531,552,639,712,1017,1145,1323`).
- `app/orchestrator/stages/generation.py:184`: `topics = [t for t in (ctx.category, ctx.theme) if t] or None`. The `generate_questions(...)` call (~`:195`) **never passes `excluded_topics` or `avoid_questions`** → both `None` on every orchestrator/worker/CLI order. Only the legacy HTTP API (`app/api/routes.py:75,121`) and experiment script `scripts/run_d21b_arms.py:230` ever supply them. Wiring them in is the cheapest lever.

**Topic source — nothing reusable per category.**
- `app/sourcing/topic_pool.py:37-93` `TopicPool` = flat, **un-keyed** list of 50 strings (`topic_pool.json` = `{"topics":[…]}`); no category/taxonomy keying. Used only by `SourcingStage` (grounded mode) and `scripts/generate_pack.py:287-347`. `TopicPlanner` runs offline via `scripts/refresh_topic_pool.py`. → **not reusable as a per-category subtopic source without restructuring.**
- Taxonomy: `app/generation/classification.py:17-31` `CATEGORIES` = flat 9-id tuple (`general, adults, kids, wizarding-world, superheroes, disney, football, sports-mix, entertainment`); `entertainment` added by #167 (`6299864d`). Aliases `:34-47`. **No subtopic layer exists anywhere.**

**Dedup / persist / schema.**
- `dedup.py`: 4 checks, first match drops — cosine ≥ `0.85` (`:113-125`, `:214-227`), Jaccard vs gold ≥ `0.80` (`:229-238`), in-batch Jaccard ≥ `0.60` (`:118-124,145-152`), same-fact (`_fact_key` = normalized url+answer, or content Jaccard ≥ `0.35`) (`:153-181`). Calibration note `:60-68` records the 2026-08-07 rated batch (dup pairs 0.39–0.52 vs noisiest non-dup 0.21) and the **accepted residual**: same fact / disjoint wording = 0.735 cosine vs a 0.738 non-dup → not separable by any threshold today. Helpers `_normalize_answer:255-256`, `_normalize_url:258-262`.
- `pgvector_client.py:275-303` `find_duplicates(question_text, threshold=0.85)` — `cosine_distance`, `ORDER BY … LIMIT 10`, similarity filtered client-side, no self-id exclusion. `_embedding_for:312-317` embeds **`question.question` only — the answer is not in the embedding**, which is exactly the 0.735/0.738 blind spot.
- `persist.py:79-86,96-115` writes a pre-computed `embedding` (`text-embedding-3-small`, `:41`); it does not embed.
- Convention to follow: `spent_facts.py:52-59` **imports** `_fact_key/_fact_tokens/_jaccard/_normalize_answer/_normalize_url` from `dedup.py` and wraps non-`Question` inputs in a duck-typed dataclass (`:64-75`), pinned by a `__module__` test (`:34-36`). Any new stage must do the same — never reimplement.
- `app/db/models/question.py`: has `category`(String64), `topic`(String128), `correct_answer`, `embedding Vector(1536)` (`:33`), `embedding_model/dim`, indexes `ix_questions_pack_id`, `ix_questions_language_category_review_status` (`:121-131`). **No `subtopic`, no taxonomy-id, no normalized-answer column.**
- Alembic head = **`f2a91c4b8e57`** (`f2a91c4b8e57_order_generation_mode.py`). Vector index exists but is **ivfflat, not HNSW**: `1c5e0fa7b3d4_core_entities_issue_33_task_1_5.py:256-257` (`USING ivfflat (embedding vector_cosine_ops) WITH (lists=100)`); no `hnsw` anywhere. Stack: `pgvector>=0.3.0` (`pyproject.toml:45`), `pgvector/pgvector:pg16` (`docker-compose.yml`) → HNSW supported.

**Cost / roles / judge.**
- Role registry: `packages/shared/quiz_shared/llm/factory.py:128-168` (`GEN, CRITIQUE, …, EMBED`, env-overridable via `_role` `:118-122`); OpenRouter remap `:175-203`; **session-gateway tier map `_SESSION_ALIAS_FOR_ID:243-253`** + `LLM_SESSION_MAP`. A new cheap-judge role = one constant + one entry in each map.
- Per-call cost: `app/llm_usage.py:76-100` price table, `current_stage` contextvar `:56-58`.
- Judge client to reuse: `app/scoring/multi_model_scorer.py:516` `MultiModelScorer` (`_default_models:551`, `_invoke:645`, `score_question:720`) — already does gateway routing, key gating, usage accounting. Flags `app/feature_flags.py:220,290,304`. **#169 judges-always-OFF-in-session** enforced at `scripts/generate_pack.py:244` (`_judges_enabled`), test `tests/scripts/test_generate_pack_session.py:9` → a gray-zone judge under the session gateway must be a *separate* switch or it is silently disabled.

**Corpus stats — nothing exists.** No SQL aggregate over `questions`; `/reviews/stats` (`app/api/routes.py:353`) iterates the *pending* store only (comment `:356-357` deliberately excludes the pgvector corpus). A coverage map needs a new `GROUP BY category, subtopic, type` query/script.

**Tests.** Dedup: `tests/orchestrator/stages/test_dedup.py` (+ `_non_blocking`, `_same_fact`) — in-memory fake finder, no DB; real-pgvector variant `tests/db/test_pgvector_dedup.py` (`TEST_DATABASE_URL`). Generation: `tests/orchestrator/stages/test_generation.py` (fake generator double). Prompt builder: `tests/generation/test_prompt_response_format.py`, `test_category_prompt_dispatch.py`, `test_v3_prompt_engagement_machinery.py` — plain string assertions. Persist: `tests/orchestrator/stages/test_persist.py` — live DB, `alembic upgrade head` per module. Conftests: `tests/conftest.py` (pins `LLM_GATEWAY=direct`), `tests/integration/conftest.py` (canned payloads, `_two_judge_panel`).

**Zero-cost exercise.** `scripts/generate_pack.py` (`--direct`, `--per-topic-cap`, `--topics`, `--no-judges`, `--dry-run` skips persist). Session runbook `docs/issues/issue-169-session-gateway-subscription-llm.md:63`: `LLM_GATEWAY=session python scripts/generate_pack.py --dry-run --target-count 3`; only `OPENAI_API_KEY` (embeddings) still costs.

**Composition overlap.** `composition.py:41-42,56-67,82-115` caps survivors **per batch** per normalized free-text `question.topic` (default `max(2, ceil(2*target/30))`) plus a T/F-format cap. The proposed per-category answer cap is **corpus-wide on a normalized answer** — different axis, no conflict; but a subtopic cap must not also be added here or the two will fight.

### B. Build-vs-adopt

| Need | Call | Reason |
|---|---|---|
| Coverage-cell weighted sampling | **Build (stdlib)** | `random.choices(cells, weights=…)` with inverse-coverage weights is ~10 lines; a sampling lib is dead weight. |
| Answer normalisation | **Adopt in-repo** | Import `_normalize_answer`/`_fact_key` from `dedup.py` per the `spent_facts.py:52-59` precedent; keeps the `__module__` anti-fork test honest. |
| HNSW index | **Adopt (pgvector native)** | `CREATE INDEX … USING hnsw (embedding vector_cosine_ops)`, one migration; pg16 image supports it. See open question 2 on whether it is warranted. |
| Gray-zone pairwise judge | **Adopt in-repo** | `MultiModelScorer` (`multi_model_scorer.py:516`) with a single cheap model. A new client would fork gateway routing, key gating and cost accounting. |
| Per-category subtopic list | **Build** | `TopicPool` is flat/un-keyed; no library fits a domain taxonomy. Source = manual vs model-proposed (product question below). |

### Files touched

| File | Change |
|---|---|
| `app/db/models/question.py` | + `subtopic`, + normalized-answer column |
| `alembic/versions/<new>` (on head `f2a91c4b8e57`) | columns + optional HNSW index |
| `app/orchestrator/stages/generation.py` | pass `topics`/`excluded_topics`/`avoid_questions` from the coverage map |
| `app/orchestrator/stages/dedup.py` | per-category answer cap; question+answer embed text; gray-zone judge hook |
| `app/orchestrator/stages/persist.py` | write subtopic + normalized answer |
| `packages/shared/quiz_shared/database/pgvector_client.py` | `_embedding_for` → question+answer; coverage query |
| `app/generation/prompt_builder.py` | likely unchanged (placeholders already correct) |
| `packages/shared/quiz_shared/llm/factory.py` | new cheap-judge role + session/openrouter map entries |
| new: coverage-map module + per-category subtopic data file | cell counting + allocation |
| `scripts/generate_pack.py` | flags for coverage mode / judge switch |
| `tests/orchestrator/stages/test_{dedup,generation,persist}.py`, `tests/db/test_pgvector_dedup.py` | new cases |

**Reversibility assessment:** **class `b`** — an alembic migration is required (new columns on `questions` + a vector-index change). Everything else is additive behind flags, but the migration alone routes this to `ready-for-human`, never Ralph.

### Open technical questions

1. **Re-embedding backfill.** Switching embedded text to question+answer invalidates every existing `questions.embedding`. Full backfill in the migration, or dual-write + cutover? Mixed old/new embeddings silently corrupt cosine dedup.
2. **Is HNSW warranted?** ivfflat `lists=100` already exists and `find_duplicates` is `LIMIT 10` over a low-hundreds corpus. Measure first; it may be a no-op that costs a migration.
3. **Coverage-cell cardinality.** 9 categories × ~15 subtopics × ~3 types ≈ 400 cells against a corpus in the low hundreds → nearly every cell reads zero-coverage and the weighting degenerates to uniform random. Needs coarser cells or a smoothing rule.
4. **Judge switch vs #169.** A gray-zone judge under `LLM_GATEWAY=session` is disabled by `_judges_enabled` (`generate_pack.py:244`) if it reuses the judge flag. Separate flag, or accept OFF in session runs?
5. **Recalibration data.** `dedup.py:60-68` was calibrated on the 2026-08-07 rated batch; batch `353c88ca` (82 q, 2026-09-02) is still unrated — threshold recalibration blocks on founder ratings.
6. **Subtopic assignment.** Generator returns it in the JSON (prompt change, unvalidated) or a classifier pass (extra LLM call per question)?

### Product questions for founder — **oba vyriešené**

1. **Subtopic source** → locked 5: model navrhne, founder jednorazovo schváli, výsledok je statický súbor v repe. Detail v D4.
2. **Per-category answer cap number** → locked 6 + 6a: východiskové hodnoty per kategória navrhuje D6, founder ich doladí cez env bez zásahu do kódu. Žiadna otvorená produktová otázka nezostáva.

## Scope

**In**
- **Podtémový layer:** statický `app/generation/subtopics.json` v tvare `{language: {category: [subtopic, …]}}` (~15–20 podtém na kategóriu), vyrobený novým `scripts/propose_subtopics.py` (session gateway) a **jednorazovo schválený founderom pred akoukoľvek ďalšou úlohou** (locked 5, D4). Runtime ho len číta, žiadny LLM.
- **Mapa pokrytia** buniek `(language, category, subtopic)` = jeden `GROUP BY` nad `questions` + deterministické vážené vzorkovanie buniek pre dávku (D3).
- **Pozitívne riadenie direct promptu:** pridelené bunky do `{topic_section}` a ≤ ~10 už obsadených odpovedí tej bunky do `{avoid_section}` (dnes obe prázdne) — za flagom `COVERAGE_STEERING`, default OFF.
- **Register odpovedí:** `answer_key` (normalizovaná odpoveď) na `questions` + **deterministický backfill `answer_key` nad existujúcim korpusom** (bez LLM, D2) + **per-kategória strop** opakovaných odpovedí v `DedupStage` — flag `ANSWER_CAP`, default OFF, hodnoty konfigurovateľné (D6).
- **Per-kategória prísnosť dedupu** (cap aj cosine prah) ako jeden konfiguračný mechanizmus — locked 6a (D6).
- **Embedding otázka+odpoveď** ako **samostatný stĺpec** `embedding_qa` + backfill skript — flag `DEDUP_QA_EMBEDDING`, default OFF (D2).
- **Lacný LLM sudca pre šedú zónu** cosine 0.70–0.85, vlastný flag + tvrdý strop volaní na beh (D7).
- **Migrácia** (class `b`): 4 nullable stĺpce + 2 btree indexy na heade `f2a91c4b8e57` (D8).
- **Quality guard:** slepé ratované porovnanie ON vs OFF pred akýmkoľvek zapnutím v prode (sekcia nižšie).

**Out (vedome, s dôvodom)**
- **HNSW / akákoľvek zmena vector indexu** — D9. Detekcia nie je nákladový problém (research §1) a pri tomto počte riadkov je migrácia riziko bez merateľného zisku.
- **Custom packy** — locked 3. Žiadny pack ↔ korpus dedup; obe nové generačné/dedup správania sa zapínajú **volajúcim** (CLI/worker korpusové behy), app/API pack cesta ich nikdy nenastaví (D5).
- **UX „otaguj ako duplikát"**, per-user expozícia, novelty score do scoringu — locked 7, samostatné follow-upy.
- **Zmena promptu mimo `{topic_section}`/`{avoid_section}`** — locked 4. Šablóna, model, teplota, poradie stage-ov ostávajú byte-identické.
- **Globálne prekalibrovanie prahu 0.85** (question-only) — globálny **default** ostáva nedotknutý; QA cesta má vlastnú konštantu (D2), per-kategória odchýlky (ktoré prepisujú oba prahy) rieši D6. Rekalibrácia na dávke `353c88ca` je follow-up, blokovaný na founder ratingu, nie na tomto issue.
- **`retired` stav namiesto delete**, verbalized sampling, per-typ bunky — neriešime (D1, D9).
- **Zmena retrieval/hot path** — `search()` (`pgvector_client.py:265-290`) ďalej používa pôvodný `embedding` stĺpec, sémantika serve-time vyhľadávania sa nemení vôbec.

## Resolved design decisions

### Gate cycle 1 → fixes
- **A1** (fail-loud gate lámal merge s flagmi OFF) → D2: kontrola pokrytia `embedding_qa` beží **len pri `DEDUP_QA_EMBEDDING` ON**; povinnosť importéra tiež.
- **A2** (`answer_key` bez backfillu = tichý under-enforce) → D2: deterministický `--answer-key-only` backfill v tom istom skripte + Scope „In".
- **A3** (`subtopics.json` bez schémy/zdroja/poradia) → D4 + Scope: schéma `{language: {category: […]}}`, `scripts/propose_subtopics.py`, founder sign-off ako **prvá úloha**.
- **B1** (locked 6a nebolo implementované) → D6: `DEDUP_COSINE_PER_CATEGORY` prepisuje **oba** prahy; zjednotenie dropov a first-match poradie vysvetlené.
- **B2** (mapa prázdna v čase guardu) → D4 + Quality guard: aplikovaný subtopic backfill = vstupná podmienka; coverage modul fail-loud pri kategórii bez tagov.
- **B3** (mäkký tripwire) → Quality guard metrika 1: `B ≥ A` bez rezervy, CI párového rozdielu, slepá founder otázka „cítiš rozdiel", + otvorene priznaná potreba ~145 q/rameno pri 0.5 bodu → founder call.
- Nity: prah ambiguita (B1), jazyk v kľúči `subtopics.json` (A3), metrika 2 validuje len steering, `LIMIT 10` pred prahom (D2), `EXPLAIN` warning aj v coverage module (D9), sebapotvrdzujúca mapa priznaná (D4).

**Build-vs-adopt (z Phase 1 §B, potvrdené s jednou korekciou).** Adoptujeme: normalizáciu odpovede (`_normalize_answer`/`_fact_key` importované z `dedup.py` podľa precedensu `spent_facts.py:52-59`), `llm_factory` role registry + `app/llm_usage.py` účtovanie, `random.choices` zo stdlib. **Korekcia D7:** Phase 1 navrhla adoptovať `MultiModelScorer` — jeho verejné API je `score_question` (5-dimenzionálna rubrika kvality, kvórum, parsing skóre), z čoho pre párový dedup verdikt nesedí nič; použiteľné je len `_get_client` (`multi_model_scorer.py:616-631`), čo sú **tri riadky nad `llm_factory.chat_openai`**. Adoptujeme teda ten istý seam (factory + usage), nie triedu.

### D1 — Bunka = `(language, category, subtopic)`, **bez** typu otázky
Phase 1 riziko #3: 9 × ~15 × 3 ≈ 400 buniek proti korpusu v nízkych stovkách → takmer každá bunka číta nulu a váženie degeneruje na uniformné. Typ otázky sa z bunky **vypúšťa**, čím kardinalita klesá 3× (~150 buniek) — a je to zároveň jediná os, ktorú už reguluje niekto iný: `composition.py:41-42,82-115` capuje T/F formát a per-topic prežitie v rámci dávky. Dve nezávislé regulácie tej istej osi by si odporovali (Phase 1, „Composition overlap").

`language` je v kľúči zámerne: SK/CS vetva (#168) inak zamieša počty do anglického korpusu a mapa pokrytia začne steerovať podľa cudzieho jazyka.

### D2 — Embedding otázka+odpoveď: **druhý stĺpec**, nie prepis existujúceho
Prepnutie textu embeddingu invaliduje každý existujúci `questions.embedding` a **v repe sú dve nezávislé miesta, kde sa embedduje**: `pgvector_client._embedding_for:333-337` (`question.question`) a `scripts/import_questions_json.py:148` (`[q.question for q in batch]`). Na riadku nie je žiadny marker, ktorá verzia v ňom leží → pri prepise na mieste by kosínus dedupu ticho porovnával staré vektory s novými (Phase 1 riziko #1) a zlyhal by smerom „nič nenájde", teda neviditeľne.

**Riešenie:** nový nullable `embedding_qa` (+ `embedding_qa_model`). Pôvodný `embedding` sa **nemení a ostáva pre retrieval**. QA vetva dedupu má vlastný SQL predikát `embedding_qa IS NOT NULL` a vlastný prah `DEFAULT_QA_COSINE_THRESHOLD = 0.90` (research §1: produkčné QA pipeline embeddujú otázku+odpoveď a prahujú na 0.90; prahy nie sú prenosné medzi vstupmi, takže zdediť 0.85 by bolo tichým posunom citlivosti).

**Prečo sa nemôže ticho zmiešať:** dva rôzne stĺpce sa fyzicky nedajú porovnať navzájom; a keďže NULL riadky by boli pre QA vetvu neviditeľné (a dedup by ticho strácal recall), `DedupStage` **fail-loud** overí pokrytie: `COUNT(*) WHERE embedding IS NOT NULL AND embedding_qa IS NULL` musí byť 0, inak beh spadne s inštrukciou dobehnúť backfill. **Kontrola sa spúšťa výhradne keď je `DEDUP_QA_EMBEDDING` ON** (A1) — pri flagu OFF (default aj stav pri merge) sa nevykoná vôbec, takže existujúce direct/CLI behy sú migráciou nedotknuté a „merge tohto issue nič v prode nezapína" platí doslova. Rovnako povinnosť importéra plniť `embedding_qa` (D10) vzniká až so zapnutým flagom. Nikdy neprepne na tichý fallback.

**Recall strop QA dotazu:** `find_duplicates` reže `LIMIT 10` **pred** prahovým filtrom (`pgvector_client.py:292-303`), takže s rastúcim korpusom môže skutočný najbližší pár vypadnúť z okna. Nový QA dotaz preto filtruje prahom **v SQL** (`WHERE cosine_distance <= 1 - threshold`) a `LIMIT` aplikuje až nad filtrom; pôvodný `find_duplicates` sa nemení (hot path, locked 4).

Zamietnuté: (a) prepis na mieste + dual-write — nemá ako odlíšiť už prepísané riadky bez ďalšieho stĺpca, čiže je to ten istý stĺpec navyše, len s horšou sémantikou; (b) verzia v `embedding_model` — je to voľný string bez constraintu, prepisuje ho `persist.py:115-119` aj importér, ako gate nespoľahlivý.

**Náklad backfillu:** korpus v nízkych stovkách × ~40 tokenov, `text-embedding-3-small` @ $0.02/1M (research §1) → **rádovo centy**, jednorazovo. Nový skript `scripts/backfill_embedding_qa.py`, idempotentný (spracúva len `embedding_qa IS NULL`), dávkuje ako importér.

**`answer_key` backfill v tom istom skripte (A2).** Bez neho by strop z D6 rátal len riadky persistnuté po migrácii a ticho pod-vynucoval proti celému existujúcemu korpusu. Ten istý skript preto v jednom prechode nad `answer_key IS NULL` dopočíta `answer_key = _normalize_answer(correct_answer)` (import z `dedup.py` podľa precedensu `spent_facts.py:52-59`) — **deterministicky, bez LLM a bez OpenAI volania**. Keďže `ANSWER_CAP` nezávisí od `DEDUP_QA_EMBEDDING`, skript má prepínač `--answer-key-only`, ktorý beží úplne zadarmo a bez sieťového volania.

### D3 — Váženie pokrytia: `1/(count + K)` so samokalibrujúcim `K`
Požiadavka: pri malom korpuse sa musí degradovať na uniformné, pri rastúcom začať riadiť — bez magickej konštanty, ktorá po naplnení korpusu prestane platiť.

Váha bunky `w_i = 1 / (count_i + K)`, kde `K = max(1, round(N_kategórie / počet_buniek_kategórie))` (priemerné obsadenie bunky). Vlastnosti: pri prázdnom korpuse sú všetky `count_i = 0` a `K = 1` → **presne uniformné**; pri `count` rádovo pod `K` je pomer váh blízko 1 (jemné riadenie); až keď obsadenie prerastie priemer, pomer váh rastie a steering sa zapne. Žiadny prah „od N riadkov", škáluje sa sám.

Determinizmus a testovateľnosť: `random.Random(seed).choices(cells, weights=…, k=…)` (stdlib, Phase 1 §B), `seed` = `--coverage-seed` na CLI, inak `order_id`. Test = fixný seed + fixné počty → fixný zoznam buniek; plus dva okrajové testy: všetky counts 0 → distribúcia sa štatisticky nelíši od uniformnej; jedna bunka výrazne prekročí `K` → jej podiel klesne.

### D4 — Podtéma sa **odvodzuje z pridelenej bunky**, nula LLM volaní navyše
Phase 1 otvorená otázka #6 (generátor ju vráti v JSON vs. klasifikačný priebeh). Pri `COVERAGE_STEERING` ON pipeline **už vie**, ktorú bunku dávke pridelila, takže podtéma je vstup, nie výstup — zapíše sa pri persist bez akéhokoľvek modelového volania a bez zmeny response formátu (ktorý locked 4 zakazuje meniť). Pri flagu OFF ostáva `subtopic` NULL.

**Tvar a zdroj `subtopics.json` (A3).** Schéma je kľúčovaná presne ako bunka z D1: `{language: {category: [subtopic, …]}}`, napr. `{"en": {"entertainment": ["…", …]}}` — SK/CS vetva (#168) tak pridá blok `"sk"` bez zmeny kódu a index `ix_questions_lang_category_subtopic` (D8) sedí 1:1 s kľúčom súboru. Producent = nový `scripts/propose_subtopics.py` cez **session gateway** (`LLM_GATEWAY=session`, nulový marginálny náklad): jedno volanie na kategóriu, ~15–20 podtém, výstup do JSON. **Poradie je záväzné a je to prvá úloha issue:** (1) `propose_subtopics.py` vygeneruje návrh → (2) founder ho jednorazovo schváli (locked 5) → (3) schválený súbor sa commitne → (4) až potom má zmysel `backfill_subtopics.py` a čokoľvek z D1/D3. Runtime súbor len číta.

Riziko, ktoré tým vzniká a je vedome prijaté: model môže pridelenú podtému ignorovať a napísať otázku o niečom inom → riadok dostane nepresný tag. Dôsledok je len skreslená mapa pokrytia (mierne horšie riadenie), nie chybná otázka; a je to merateľné pri quality guard ratingu, kde founder aj tak vidí, či dávka sedí na pridelené podtémy. Áno, mapa je tým do istej miery **sebapotvrdzujúca** (zapisuje sa pridelená, nie overená podtéma) a drift v nej samej nevidno — vedome prijaté, cena alternatívy je klasifikačný LLM priebeh na každú otázku (D4 ho práve odstraňuje).

**Existujúce riadky:** jednorazový `scripts/backfill_subtopics.py` cez **session gateway** (`LLM_GATEWAY=session`, #169) — jedno dávkové volanie na kategóriu, ktoré zaradí existujúce otázky do schváleného zoznamu podtém, výstup najprv do JSON na founder náhľad, zápis až druhým behom `--apply`. Marginálny náklad **nula** (predplatné), mimo generačnej cesty.

**Backfill je predpoklad, nie doplnok (B2).** Kým `--apply` nedobehne, má každý existujúci riadok `subtopic` NULL, všetky `count_i = 0` a váženie z D3 je preukázateľne **uniformné** — arm B v quality guard by potom meral „náhodná podtéma v `{topic_section}`", nie coverage steering, a metrika 2 by hodnotila mechanizmus, ktorý sa nikdy nezapol. Preto: (a) **aplikovaný subtopic backfill nad kategóriou experimentu je uvedená vstupná podmienka quality guard** (viď sekcia nižšie), a (b) modul mapy pokrytia **fail-loud** spadne, keď kategória, pre ktorú sa žiada alokácia, nemá **ani jeden** riadok s neprázdnym `subtopic` — nikdy nesteeruje naslepo a nikdy ticho nedegraduje na uniformné.

### D5 — Ako sa nové správanie zapína: volajúcim, nie globálne
Locked 3 (packy nedotknuté) a locked 4 (kvalita sa nesmie zmeniť) sú splnené **konštrukciou**, nie disciplínou: všetky štyri flagy sú `_truthy`-štýl default OFF (`app/feature_flags.py:29-30`) a v prode sa nenastavujú (žiadne Fly secrets) až do founder podpisu. Coverage allocation sa navyše aplikuje **iba** keď je beh direct (`ctx.direct_generation`) a flag ON — grounded cesta #167 si témy nesie z `SourcingStage._forced_topics` (`stages/sourcing.py:80-86`) a coverage do nej nezasahuje, inak by dva zdroje tém bojovali o ten istý `{topic_section}`.

Štyri **nezávislé** flagy (`COVERAGE_STEERING`, `DEDUP_QA_EMBEDDING`, `ANSWER_CAP`, `DEDUP_GRAYZONE_JUDGE`), nie jeden spoločný — inak by regresia v ratovanom porovnaní nebola priraditeľná ku konkrétnej zmene a rollback by vypol aj to, čo fungovalo.

### D6 — Per-kategória prísnosť: strop odpovedí + cosine prah, jeden mechanizmus
Locked 1 + 6 + **6a**: per kategória, žiadne fixné globálne číslo, skôr voľnejšie, a `entertainment` **najvoľnejšie zo všetkých**. Strop sa počíta nad `(language, category, answer_key)` v korpuse; pri prekročení `DedupStage` zahodí kandidáta s dôvodom `answer_cap` (vlastný counter v `StageResult.info`, aby sa v metrikách nezliaval s kosínusovými dropmi).

Prísnosť má **dve páky a jednu konfiguračnú formu** — `ANSWER_CAP_PER_CATEGORY="entertainment=6,kids=4,…"` a `DEDUP_COSINE_PER_CATEGORY="entertainment=0.92,…"` (kv reťazec ako existujúce env flagy, fallback `ANSWER_CAP_DEFAULT=3`). Vyšší cosine prah = **menej** dropov, čiže voľnejší dedup; obe páky idú tým istým smerom a ladia sa nezávisle.

**Ktorý prah `DEDUP_COSINE_PER_CATEGORY` prepisuje: oba (B1).** `DedupStage` zahadzuje pri **prvej** zhode a kosínusová kontrola je prvá v poradí (`dedup.py:105-160`), takže dropy question-only a QA vetvy sú **zjednotenie** — kandidát padne, ak ho zhodí ktorákoľvek. Keby per-kategória hodnota prepisovala len QA prah (D2), bola by pri `DEDUP_QA_EMBEDDING` OFF (default aj stav pri merge) úplne bez účinku a pri oboch vetvách ON by ju prísnejší question-only `0.85` (`dedup.py:53`) predbehol skôr, než sa k QA vetve vôbec dôjde → locked 6a by nebolo implementované ani v jednom stave. Jedna hodnota per kategória preto nastavuje **obe** hranice: question-only prah (globálny default `0.85`) aj QA prah (globálny default `0.90`, D2) sa pre danú kategóriu posunú na ňu. Globálne defaulty ostávajú nedotknuté pre každú kategóriu bez záznamu, takže `entertainment=0.92` uvoľní obe vetvy naraz a nič mimo `entertainment` sa nehne.

| Kategória | Cap | Cosine prah | Prečo |
|---|---|---|---|
| `entertainment` | **6** | **0.92** | Founder verdikt 2026-09-03 (memory `project_167_pilot_verdict_2026_09_03`, issue-167 § Follow-ups „per-category dedup strictness"): táto trieda znesie výrazne voľnejší dedup než evergreen korpus — post-cutoff fakty sa točia okolo malého počtu aktuálnych entít (jeden album, jeden festival), takže prísny strop by zhadzoval legitímne rôzne otázky. #170 to vlastní, z #167 implementácia nepríde. |
| `wizarding-world`, `superheroes`, `disney` | **5** | default | Uzavreté fandomy s desiatkami, nie tisíckami entít; príliš tvrdý strop by tu zhadzoval legitímne rôzne otázky o tej istej postave. |
| `kids`, `football` | **4** | default | Užší kánon (známe zvieratá/farby; top kluby a hráči), opakovanie je prirodzené. |
| `general`, `adults`, `sports-mix` | **3** | default | Široký priestor odpovedí — tretie opakovanie tej istej entity je už signál mode collapse. |

Cap **nie je** brána kvality, je to brzda odpadu (locked 2: duplikát nie je tragédia). Preto je voľný a preto sa pri jeho dosiahnutí nič neregeneruje — kandidát len padne. Čísla sú návrh, founder ich doladí bez zásahu do kódu.

### D7 — Sudca šedej zóny: vlastný flag, **nezávislý od `_judges_enabled`**, s tvrdým stropom volaní
Toto **nie je** kvalitatívny sudca — je to párový verdikt „ten istý fakt áno/nie" nad kandidátmi s cosine 0.70–0.85, presne na zdokumentovaný gap `dedup.py:22-27` (0.735 dup vs 0.738 non-dup, prahom nerozlíšiteľné). Preto **nesmie** visieť na `_judges_enabled` (`scripts/generate_pack.py:244`), ktorý by ho v session behoch ticho vypol spolu s panelom kvality.

Vlastný flag `DEDUP_GRAYZONE_JUDGE` (default OFF) + nová rola `DEDUP_JUDGE` v `factory.py:128-168` (+ entry v `_REMAP_OPENROUTER` a v `_SESSION_ALIAS_FOR_ID:243-253`). V session režime **je povolený** — a dôvod, prečo to neporušuje #169: tam bol problém objem (42 opus volaní na 3 otázky, ~80 % kvóty), nie princíp. Preto sa berie skutočná príčina, nie jej proxy: `GRAYZONE_JUDGE_MAX_CALLS` (default **20** na beh), po vyčerpaní sa zvyšné šedé páry riešia dnešným správaním (pod prahom → prejde) a fakt vyčerpania sa **zaloguje ako warning + počet**, nikdy sa neschová.

### D8 — Migrácia: 4 nullable stĺpce na heade `f2a91c4b8e57`
Nová revízia `down_revision = "f2a91c4b8e57"` (`f2a91c4b8e57_order_generation_mode.py`), čisto aditívna, žiadny backfill v migrácii (ten je samostatný idempotentný skript, D2/D4 — migrácia nesmie robiť platené OpenAI volania):

- `subtopic VARCHAR(64) NULL`, `answer_key VARCHAR(255) NULL`
- `embedding_qa Vector(1536) NULL`, `embedding_qa_model VARCHAR(64) NULL`
- `ix_questions_lang_category_subtopic` (btree, mapa pokrytia), `ix_questions_lang_category_answer_key` (btree, strop)
- **žiadny** vector index na `embedding_qa` (D9)

Seam: polia idú na `quiz_shared.models.question.Question` a cez `question_to_row`, čím ich `persist.py:_question_row_dict:107-120`, `_write_out` JSON aj `import_questions_json.py` preberú automaticky (rovnaká vlastnosť, na ktorú sa spoľahlo #167 D6). Pozor pri behu: shared model sa mení → `uv pip install -e packages/shared` v každom venve, inak „no field" chyby (známy gotcha).

Downgrade dropuje stĺpce aj indexy. Class `b` ostáva → `ready-for-human`, nie Ralph.

### D9 — HNSW: OUT, s podmienkou návratu
Research §1 aj Phase 1 riziko #2 sa zhodujú: detekcia nie je nákladový problém, `find_duplicates` je `LIMIT 10` (`pgvector_client.py:292-303`) nad korpusom v nízkych stovkách. Migrácia indexu je tu riziko bez merateľného zisku.

Poctivo o existujúcom stave: `ivfflat … WITH (lists=100)` (`1c5e0fa7b3d4_…:256-257`) je pri pár stovkách riadkov **prehnane rozdelený** — pri default `ivfflat.probes=1` by index scan čítal ~1 % riadkov, čiže by dedup recall reálne poškodil. Dnes to nevadí len preto, že planner pri tejto veľkosti tabuľky volí seq scan. To je predpoklad, nie garancia, takže do backfill skriptu (D2) ide **jednoriadková `EXPLAIN` kontrola** dedup dotazu, ktorá **hlási warning, ak sa použije ivfflat index scan** — nulový náklad, žiadna migrácia, a je to presne signál „teraz je čas na HNSW". Revisit pri **> ~5 000 riadkoch** korpusu alebo na ten warning. Keďže jednorazový skript by prestal strieľať práve vtedy, keď rast korpusu urobí ivfflat scan pravdepodobným, tú istú jednoriadkovú `EXPLAIN` kontrolu (a warning) dedí aj **modul mapy pokrytia**, ktorý beží pri každej steerovanej dávke.

### D10 — Second-order lens
- **Grounded #167:** nedotknuté — coverage beží len na direct vetve (D5); `SpentFactIndex` rieši tú istú vec v rámci behu, `answer_key` je jeho trvalý korpusový ekvivalent, nie konkurent. Voľnejšia prísnosť pre `entertainment` (D6) je jediná väzba a je konfiguračná.
- **Custom packy:** nedotknuté — flagy OFF v prode + app/API cesta ich nenastavuje (D5). Žiadny pack ↔ korpus dedup nikde nepribúda.
- **Rating web / import:** `import_questions_json.py` musí popri `embedding` plniť aj `embedding_qa` (rovnaká dávková slučka, druhý vstupný text), inak by importované riadky prepadli fail-loud kontrolou z D2 — to je žiadané, hlási sa hlasno.
- **Korpusový runbook (#169):** mapa pokrytia, subtopic backfill aj `--dry-run` behy idú cez session gateway s nulovým marginálnym nákladom; jediné platené ostávajú OpenAI embeddingy (D2, rádovo centy).
- **SK/CS vetva (#168):** `language` v kľúči bunky aj stropu (D1) → jazykové vetvy sa navzájom neriedia.

## Quality guard

Locked 4 je tvrdá brána: **kvalita sa nesmie znížiť ani zmeniť**. Preto platí falzifikovateľné go/no-go, a **v prode ostávajú všetky štyri flagy OFF, kým founder nepodpíše výsledok** — merge tohto issue nič v prode nezapína.

**Čo sa vôbec testuje ratingom.** Iba `COVERAGE_STEERING` mení *obsah* otázok (napĺňa dnes prázdne `{topic_section}`/`{avoid_section}`). Zvyšné tri flagy len **zahadzujú** kandidátov — kvalitu prežitých otázok zmeniť nevedia, takže sa validujú počítaním a náhľadom zahodených, nie ratovanou dávkou.

**Vstupná podmienka (B2).** `subtopics.json` je schválený a commitnutý **a** `backfill_subtopics.py --apply` dobehol nad kategóriou experimentu. Bez toho je mapa pokrytia prázdna, váženie uniformné a arm B nemeria steering, ale náhodnú podtému (D4). Experiment sa v takom stave **nespúšťa**.

**Experiment (arm A vs arm B).** Rovnaká kategória, rovnaký model (kanonický Fable 5), rovnaký prompt súbor, **N = 30 otázok na rameno**. Arm A = flag OFF (dnešný stav), arm B = `COVERAGE_STEERING=1`. Obe dávky sa publikujú na **produkčný rating web** neoznačené a premiešané (rovnaký postup ako slepé dávky #168 / PR #70) — founder nevie, ktorá otázka je z ktorého ramena.

**Metrika 1 — kvalita (tvrdá brána, musí prejsť; B3):** bodový odhad ramena B **≥ A** na priemere **aj mediáne** founder ratingu (škála 1–10, baseline f-base 8.01 z D21b) — **žiadna tolerančná rezerva**. Predchádzajúca verzia pripúšťala −0.3 priemeru na n = 30, čo je menej než jedna SE rozdielu, takže skutočná polbodová regresia by prešla častejšie, než by padla; locked 4 („nesmie sa znížiť ani zmeniť") sa takou latkou nedá presadiť. K číslam sa **reportuje 95 % CI párového rozdielu B − A** (bootstrap nad ratingami) — nie ako brána, ale aby bolo čierne na bielom, aká veľká regresia sa ešte do dát zmestí. Tretí prvok je kvalitatívny a rieši to „ani zmeniť": founder dostane **slepú otázku** „líši sa niečím táto dávka od bežnej — téma, štýl, opakovanie, nuda?" ešte pred odhalením ramien; „áno, cítim rozdiel" = **no-go aj pri vyhovujúcich číslach**.

**Poctivo o sile testu (a čo z toho plynie founderovi).** n = 30 na rameno na `B ≥ A` ako *dôkaz* nestačí. Pri typickej SD ~1.5 bodu je SE rozdielu ~0.39, takže s 80 % silou sa detegujú až rozdiely ~1.1 bodu; na spoľahlivé zachytenie 0.5 bodu by bolo treba **~145 otázok na rameno** (290 spolu), na 0.3 bodu ~390 na rameno. To je ručný founder rating v tom rozsahu. Plán latku neznižuje ani ju sám nedvíha: `B ≥ A` + slepá otázka je najsilnejšie, čo n = 30 unesie, a **rozhodnutie je founderovo** — buď akceptuje, že guard chytí len hrubú regresiu, alebo objedná väčšiu dávku podľa čísel vyššie. Agent väčšiu dávku sám nespustí a menšiu nevyhlási za dostatočnú.

**Metrika 2 — odpad (musí sa zlepšiť):** `dedup drop rate` = `dropped / (kept + dropped)` z `StageResult.info` `DedupStage` na rovnakej kategórii a rovnakom počte vygenerovaných kandidátov. Rameno B musí byť **striktne nižšie** než A. Drop dôvody sa reportujú rozpadnuté (cosine / jaccard / in-batch / same-fact / `answer_cap`), aby sa zlepšenie nedalo predstierať posunom medzi kategóriami dropov. Meria sa s **troma dedup flagmi OFF** (podľa rozdelenia vyššie), takže táto brána validuje **výhradne `COVERAGE_STEERING`** — nie `ANSWER_CAP` ani ostatné, tie majú vlastnú neratovanú validáciu nižšie.

**Validácia dedup flagov (bez ratingu):** `DEDUP_QA_EMBEDDING` + `ANSWER_CAP` + `DEDUP_GRAYZONE_JUDGE` sa zapnú nad tou istou dávkou kandidátov a **zahodené riadky sa vypíšu s dôvodom a s párom, voči ktorému padli**; founder prezrie vzorku. Brána: **žiadny false drop** (dve reálne odlišné otázky označené za duplikát) vo vzorke; sudca šedej zóny navyše hlási počet volaní a či narazil na `GRAYZONE_JUDGE_MAX_CALLS`.

**Go:** metrika 1 prejde (B ≥ A na priemere aj mediáne **a** slepá otázka bez signálu rozdielu) **a** metrika 2 zlepšená **a** žiadny false drop → founder rozhodne o zapnutí flagov v prode (per flag, nie hromadne).
**No-go:** čokoľvek z toho zlyhá → flagy ostávajú OFF, kód ostáva zmergovaný a dormantný (rovnaký vzor ako `GATE_V2`, `app/feature_flags.py:228-238`), a zlyhanie sa reportuje founderovi s číslami. Agent latku sám neznižuje a krátku/čiastočnú dávku nevyhlási za hotovú.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | 🔄 wip (cycle 2) | cycle 1: ready-check NOT-READY (3 blockers) · design-soundness UNSOUND 0.72 (3 flaws) → všetkých 6 opravených |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check … · design-soundness … |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-09-03 · **Next:** Phase 3 gates (cycle 2) (Plan review — dual gate) · **Gate attempts:** P3 1/3 · P5 0/3
