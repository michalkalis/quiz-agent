# #167 — Entertainment otázky z nedávneho diania (web-search sourcing)

**Triage:** feature · ready-for-agent
**Status:** prepared / ready — prep uzavretý 2026-08-26 (`/prepare-issue` Phase 1–6). Rozdelené na 6 agentských sessions + 1 founder bránu → [`issue-167-execution-prompts.md`](issue-167-execution-prompts.md)
**Created:** 2026-08-26
**Reversibility:** `a` — reversible (žiadna migrácia, žiadna schéma, prod flagy nedotknuté, všetko flag/config-gated) — plné posúdenie v D9

## Why

★ TOP PRIORITA foundera (2026-08-12). Nová trieda otázok zo zábavného priemyslu viazaná na dianie **za knowledge cutoffom gen modelov** → generátor si fakty pre ne nevie vymyslieť z váh, musí ich dostať z webu. Founder príklad žiadaného typu: známi hudobní producenti a akých umelcov majú pod sebou.

Hodnota: dnešný korpus je 100 % evergreen (a OpenTDB, jediný externý katalóg, je evergreen zámerne). Otázka „kto produkoval tento minuloročný album" je presne ten „surprise reward", ktorý founderova rubrika odmeňuje a ktorý sa z evergreen zásoby nedá vyrobiť. Zároveň je to podľa D21b **merateľne najrizikovejšia trieda** (7.85 vs f-base 8.01, a všetkých 6 vecných chýb + 2 stale boli v e-news ramenách) — preto pilot, nie dávka.

Kontext:
- Dormantná news-sourcing + expiry infra z #76: `ENABLE_NEWS_SOURCING` + `EXPIRY_CLASSIFICATION` (oba default off), kategória entertainment F-3b.
- Kandidát 17 v `docs/research/gen-pipeline-joint-review-2026-08-09.md`.
- Nadväzuje na #153 (generation pipeline mega review) a uzavreté #164/#166: Fable 5 + direct v1 = kanonická gen konfigurácia; web fact-check cez gpt-5-mini + Responses web_search; plný web check pre všetky otázky.
- Korpusové otázky vrátane entertainment sa robia do zásoby (founder 2026-08-25); regrow korpusu cez Anthropic Batch API je potvrdený smer (samostatná TODO položka).

## Research (Phase 1)

> Lokálna rekognoskácia (kód + doterajšie issue/research dokumenty). **Web/deep-research pass NEBEŽAL** — je vypnutý pre toto kolo; viď „Externá neznáma" na konci sekcie.

### A1 — Dormantná #76 F-3b infra: čo tam naozaj je

- Flagy: `EXPIRY_CLASSIFICATION` → `app/feature_flags.py:123-133` (default off), číta ho worker (`app/worker/worker.py:84-89`) aj CLI (`scripts/generate_pack.py:298-302`). `ENABLE_NEWS_SOURCING` **nie je** vo `feature_flags.py` — číta sa inline v `app/sourcing/fact_sourcer.py:34-39` a len prepína `WebSearchSource(news_mode=True)` → Tavily `topic="news"`, `time_range="week"` (`app/sourcing/web_search_source.py:148-156`). Ani jeden flag nie je nastavený vo `fly.toml` → v prode oba off.
- Expiry polovica je **kompletná a živá**: `ExpiryClassifier` (`app/generation/expiry_classifier.py`, `CONTENT_CLASS_TTL` current 14 d / semi-stable 365 d / evergreen None, fail-safe, nikdy nehádže) → stampovanie v `app/orchestrator/stages/generation.py:299-305` → stĺpce `expires_at`/`freshness_tag` (`app/db/models/question.py:92-95`, migrácia už existuje) → serve-time filter `Question.is_expired()` v `apps/quiz-agent/app/retrieval/question_retriever.py:119,129`. Filter je reálny prod kód, dnes no-op (žiadny riadok nemá `expires_at`).
- Testy existujú a nie sú zhnité: `tests/sourcing/test_web_search_recency.py`, `tests/generation/test_expiry_classifier.py`, `tests/orchestrator/stages/test_generation.py`, `tests/scripts/test_generate_pack_flags.py`, `apps/quiz-agent/tests/test_question_retriever_expiry.py`. Žiadne mŕtve importy.
- **⚠️ Blokujúci nález — trojitá dormancia, „stačí prehodiť 2 flagy" NEPLATÍ.** Od #166 (`81825633`) je `DIRECT_GENERATION` default **on** (`feature_flags.py:261-269`) → `SourcingStage.run` sa pri `ctx.direct_generation` okamžite vráti s `ctx.facts=[]` (`app/orchestrator/stages/sourcing.py:89-93`) → `GenerationStage` tak dostane prázdny fact set (posiela `source_facts=ctx.facts or None` → `None`, `stages/generation.py:214`) → `use_fact_first` je False (`app/generation/advanced_generator.py:1080-1082`) → **category→prompt dispatch (`advanced_generator.py:1086-1101`) sa nikdy nespustí**. Takže na dnešnej kanonickej ceste je mŕtve aj `ENABLE_NEWS_SOURCING`, aj celý entertainment prompt z F-3a, aj kids prompt z #162.

### A2 — Súčasná gen pipeline (#164/#166) a kam sa „recent events" zapája

- Kanonická konfigurácia: `DIRECT_GENERATION=1` (sourcing preskočený), `GEN_PROMPT_VERSION=direct_v1` → `prompts/question_generation_direct.md` (`advanced_generator.py:317-322`), `LLM_ROLE_GEN=claude-fable-5`, best-of-N/critique/judge gate vypnuté. Stage list: `app/worker/tasks.py:74-131`.
- Sourcing je **per-order (per-batch), nie per-question**: `SourcingStage` odvodí ≤3 topic tokeny z promptu alebo vzorkuje `TopicPool`, potom jeden `FactSourcer.gather_facts` (`app/sourcing/fact_sourcer.py:42-105`). Tavily je jediný web zdroj (`TAVILY_API_KEY` povinný, `web_search_source.py:113-116`), s credibility klasifikáciou domén (`web_search_source.py:20-107`).
- Fact-check: `app/verification/fact_verifier.py` — default `gpt-5-mini` cez OpenAI Responses `web_search` (`_call_openai:142-179`), Anthropic native vetva ako alternatíva; verdikty `ok|fact_error|logic_flaw|stale`, fail-closed (`_held:337-345`); merge + drop v `app/orchestrator/stages/verification.py`. Plný web check beží pre **všetky** otázky (founder 2026-08-25); tier router (`app/verification/tier_router.py`, `FACTCHECK_TIER_ROUTING`) je dormant a **nezapínať** bez novej validácie.
- **Precedens existuje a je zmeraný:** D21b už mala e-news ramená (`scripts/run_d21b_arms.py`, `source` režim si sám nastaví `ENABLE_NEWS_SOURCING=1` a vypne wiki/OpenTDB, riadky 109-128) s promptom `prompts/question_generation_entertainment_v2.md`, 6 tém × 8 Tavily faktov. Výsledok: e-news-f (Fable) **7.85** @ n=20, e-news-k (Kimi) 7.20 @ n=10 vs f-base 8.01 — a **všetkých 6 vecných chýb + 2 stale boli v e-news ramenách** (issue-166 riadky 287, 319-320). Táto trieda otázok je merateľne najrizikovejšia.
- **Prompt v2 nie je v produkte:** `_CATEGORY_PROMPT_FILES` (`advanced_generator.py:51-57`) mapuje `entertainment` stále na v1 `question_generation_entertainment.md`; v2 používa iba experimentálny skript.
- Seam pre #167 = potreba **per-order/per-kategóriu vynútiť sourcing** (obísť direct default) + zapojiť news režim + zvoliť category prompt aj na direct ceste. Dnes taký prepínač neexistuje: `ctx.direct_generation` sa berie z `order.generation_mode == "direct"` alebo z globálneho flagu (`app/orchestrator/pack_generator.py:136-139`).

### A3 — Korpus, import, taxonómia, freshness

- Korpus = Postgres tabuľka `questions` (`app/db/models/question.py:38-131`); `review_status` default `pending_review`, povolené `pending_review|approved|rejected|needs_revision|archived` (`question.py:35`). Serving filtruje `review_status="approved"` + `pack_id IS NULL` (`question_retriever.py:246`); pack sessions filter obchádzajú.
- Cesta do korpusu je dnes **iba CLI**: `scripts/generate_pack.py --dry-run --out …` → offline scoring/verify → `scripts/import_questions_json.py --review-status approved --execute`. Web review UI approval je **retired (410)** — `app/web/routes.py:173-180`.
- **Taxonómia neobsahuje `entertainment`:** `CATEGORIES = ("general","adults","kids","wizarding-world","superheroes","disney","football","sports-mix")` (`app/generation/classification.py:17-25`); `normalize_category()` neznámu hodnotu zráža na `"general"` (`classification.py:54-68`). Zrkadlo v iOS `apps/ios-app/Hangs/Hangs/Utilities/Config.swift:96-106`. Ak má byť entertainment používateľsky viditeľná kategória, treba obe.
- **Freshness dnes:** nič otázky neexpiruje ani nearchivuje automaticky. Existuje len serve-time filter `is_expired()` (viď A1) a monitoring, ktorý expirované iba počíta (`apps/quiz-agent/app/monitoring/question_monitor.py:71-79`). Žiadny job, žiadny prechod na `archived`, žiadne mazanie.

### B — Prior art & build-vs-adopt

- **Interné (hlavný kandidát):** #76 F-3b — jediná existujúca implementácia „news → otázky → expiry" v repe. Doplnkovo `run_d21b_arms.py` ako overený news-sourcing recept.
- **Externé (bez web passu, z už zaznamenaného):** OpenTriviaDB je zámerne 100 % evergreen (žiadny current/viral bucket); TMDB vylúčené ToS-om (zákaz LLM komerčných pipeline); NewsAPI.org 449 $/mes; GNews len doplnkovo — všetko `docs/research/entertainment-category-f3-2026-06-29.md:48-77`. Hotové fact-check frameworky (FacTool/SAFE/Loki/OpenFactCheck) = mŕtvy výskumný kód 2024, žiadny drop-in (issue-166:137-141). **Žiadny drop-in produkt na „kvízové otázky z aktuálnych správ" nie je známy.**
- **Build-vs-adopt call — SPLIT, a to nie kompromis, ale rez podľa toho, čo #166 rozbilo:**
  - **ADOPT (oživiť) expiry polovicu #76** — `ExpiryClassifier` + stampovanie + read-path filter sú intaktné, otestované, bez migrácie a bez zmeny API. Dôvod: #166 sa jej vôbec nedotklo (mení sa len to, čo beží pred generovaním), takže tu naozaj stačí flag + validácia TTL hodnôt na reálnej dávke.
  - **BUILD (nanovo na #166 stacku) sourcing/routing polovicu** — `ENABLE_NEWS_SOURCING` je architektonicky odrezaný: predpokladá grounded flow, ktorý je dnes default-off. Oživenie by znamenalo buď globálne `DIRECT_GENERATION=0` (regres na 8.01 → horšiu, drahšiu, pomalšiu konfiguráciu pre *všetky* objednávky), alebo aj tak napísať nový per-order/per-kategóriu prepínač. Reuse starého flagu by tu bol dlh, nie úspora. Znovupoužiteľné ostáva: `WebSearchSource(news_mode=…)`, credibility klasifikátor, prompt v2 a D21b recept.

### Externá neznáma / web pass

**Web pass v Phase 1 nebežal — bol pre toto kolo vypnutý.** Lokálna rekognoskácia uzavrela všetko, čo issue potrebuje, s jedinou výnimkou zaznamenanou v **D5** (sourcing cez OpenAI Responses `web_search` namiesto Tavily). Nie je blokujúca pre pilot; je blokujúca pred konsolidáciou providera.

## Founder decisions (2026-08-26, in-session — locked)

Zaznamenané doslovne tak, ako padli:

1. **Question type:** semi-stable post-cutoff facts first (producer rosters, new albums/films, awards; TTL ~365 d). Fresh news (14 d TTL) explicitly deferred to a later expansion — plan must leave room for it but NOT build it now.
2. **Expiry handling:** serve-time filter only (existing `is_expired()` mechanism). No auto-archive job now — founder wants it recorded as a follow-up TODO item.
3. **Category:** Entertainment becomes a USER-VISIBLE category — backend taxonomy (`CATEGORIES` in app/generation/classification.py) + iOS mirror (Config.swift) + category picker + translations (note xcstrings sync requirement).
4. **Volume:** pilot ~30 questions into corpus stock, founder personally rates them before any bigger batch (D21b-style).
5. **Pilot topic list (locked, 6 themes × ~5 questions):** (1) music producers and their artists (founder's example), (2) 2026 album releases, (3) 2026 awards & nominations (Oscars, Grammys), (4) new 2026 films & series, (5) 2026 tours & festivals, (6) 2026 streaming hits.

**Referenčný dátum „post-cutoff" = rok 2026.** Gen model pilota je Fable 5, knowledge cutoff **január 2026** → za post-cutoff sa pre tento pilot považuje fakt datovaný rokom **2026 alebo neskôr**. Toto je jediná definícia recency v celom pláne (žiadne news okno, viď D4) a je to zároveň predikát prijímacieho filtra v D6.

Tým padajú Phase-1 produktové otázky 1, 2, 3, 4 a 5. Otvorená ostáva len otázka 6 (latka kvality pre túto triedu) — odpovedá ju až founder rating pilota, viď D8.

## Scope

**In**
- Per-order/per-kategóriu vynútenie grounded (sourced) generovania na dnešnej direct-default ceste — D2.
- Entertainment prompt v2 do produkčného registra — D3.
- Sourcing pre post-cutoff fakty cez `FactSourcer` (wiki + Tavily web search, OpenTDB vypnutý), **bez** news režimu, s locked topic listom — ako **samostatný skript pred generovaním** (`scripts/source_facts.py`), nie ako súčasť generačného behu — D4/D5.
- Expiry klasifikácia zapnutá pre beh pilota (len ako telemetria/TTL stamp) — D6.
- **Post-cutoff prijímací filter** ako samostatný pre-import krok (nový malý skript) — D6; toto je jediná brána, ktorá meria definičnú vlastnosť triedy.
- `entertainment` ako používateľsky viditeľná kategória: backend taxonómia + **dva** iOS mirrory + picker + xcstrings sync — D7.
- Pilot ~30 otázok: agentský segment (generate → verify/score → post-cutoff filter → publikovaná rating dávka) + founder rating + post-rating import — D8.

**Out (vedome, s dôvodom)**
- **Fresh-news režim** (`ENABLE_NEWS_SOURCING`, Tavily `topic="news"`/`time_range="week"`, TTL `current` 14 d) — founder decision 1 ho odkladá. Kód zostáva nedotknutý a funkčný; expanzia = preklopiť flag + prijať `current` riadky (D10).
- **Auto-archive / expiry job** — founder decision 2: iba serve-time filter. Follow-up TODO.
- **Fact-check tier routing** (`FACTCHECK_TIER_ROUTING`, `app/verification/tier_router.py`) — dormant a nezapínať bez novej validácie (issue-166). Pilot ide plným web checkom ako všetko ostatné.
- **Konsolidácia sourcing providera Tavily → OpenAI Responses `web_search`** — jediná otvorená externá otázka, neblokuje pilot (D5).
- **Väčšia dávka než pilot**, kadencia obnovy, per-kategóriu automatika v prode (worker/API cesta) — až po founder ratingu.
- **Zmena gen modelu** pre túto triedu — pilot beží na kanonickom Fable 5 zámerne (D10).

## Resolved design decisions

**Build-vs-adopt (z Phase 1 §B, potvrdené): SPLIT.** *Adoptujeme* expiry polovicu #76 — `ExpiryClassifier` + stampovanie + read-path filter sú intaktné, otestované, bez migrácie (D6). *Staviame nanovo* sourcing/routing polovicu na #166 stacku, lebo `ENABLE_NEWS_SOURCING` je architektonicky odrezaný a jeho oživenie by bolo dlh, nie úspora (D2). Zo starej vetvy salvage-ujeme komponenty, nie flag: `WebSearchSource(news_mode=…)`, credibility klasifikátor domén, prompt v2 a D21b recept (`scripts/run_d21b_arms.py:109-128`).

### D1 — Trieda: post-cutoff usadené fakty, nie news
Founderov príklad (producent → jeho umelci pre album z 2026) je fakt, ktorý je *usadený*, len leží za cutoffom modelu. Dôsledok pre celý zvyšok plánu: **nepotrebujeme recency okno, potrebujeme aktuálny web index** — a to je iný prepínač než ten, čo #76 postavilo.

**Korekcia oproti prvej verzii plánu (dôležitá, nesie ju D6):** taký fakt **nie je `semi-stable` v terminológii `ExpiryClassifier`** — je to datovaný uzavretý fakt („kto produkoval album X z 2026"), ktorý sa nemení, čiže klasifikátor ho korektne označí ako **`evergreen` → `freshness_tag = NULL`**, presne ako otázku o albume z 1994. Founderovo „semi-stable, TTL ~365 d" (decision 1) je **produktový zámer o kadencii obnovy zásoby**, nie predikcia výstupu klasifikátora.

Z toho plynie tvrdá vlastnosť, na ktorej stojí D6: **`freshness_tag` NEVIE odlíšiť post-cutoff otázku od evergreen otázky ani od fail-safe zlyhania klasifikátora** — všetky tri končia ako NULL. Klasifikátor meria *ako rýchlo odpoveď zastará*, nie *či fakt leží za cutoffom*. Definičnú vlastnosť triedy musí merať samostatný filter (D6), inak ju nemeria nič.

### D2 — Seam: explicitná `generation_mode="grounded"` prebije globálny default
Dnes `pack_generator.py:136-139` počíta `direct_generation = (order.generation_mode == "direct") or feature_flags.direct_generation_default()`. Globálny default (on od #166) teda prebije *čokoľvek* okrem `"direct"` → grounded sa objednať nedá.

**Riešenie:** urobiť stĺpec autoritatívnym v oboch smeroch — `"direct"` → True, `"grounded"` → False, `NULL` → globálny default. CHECK constraint už presne tieto dve hodnoty povoľuje (`app/db/models/order.py:113-114`), stĺpec existuje (`order.py:50`), migrácia netreba. CLI dostane `--grounded` ako zrkadlo `--direct` (`scripts/generate_pack.py:185`, argument pri :604).

**Prečo neregresuje bežné objednávky:** app/API cesta stĺpec nikdy nenastavuje (`#157` D4: „set only by internal paths"), takže zostáva `NULL` → default direct → byte-identické správanie. Zmena je aditívna vetva pre hodnotu, ktorá je dnes ticho ignorovaná.

Zamietnuté alternatívy: (a) globálne `DIRECT_GENERATION=0` — regres 8.01 na horšiu/drahšiu/pomalšiu konfiguráciu pre *všetky* objednávky; (b) nový env flag „grounded pre kategóriu X" — config sprawl a stále per-proces, nie per-order; (c) vetva na `ctx.category` vnútri `SourcingStage` — `ctx.direct_generation` by potom klamalo a režim by bol schovaný v stage namiesto na objednávke.

### D3 — Prompt: povýšiť entertainment v2 do registra
`_CATEGORY_PROMPT_FILES` (`app/generation/advanced_generator.py:51-57`) mapuje `entertainment` na v1; v2 (`prompts/question_generation_entertainment_v2.md`) je dnes len v experimentálnom skripte, hoci je to práve tá verzia, ktorá bežala v D21b e-news ramenách. Zmena = jeden riadok registra.

Overené, nie predpokladané: v2 nesie **17 placeholderov** vrátane **všetkých 6** z `_REQUIRED_FACT_FIRST_PLACEHOLDERS` (`advanced_generator.py:65-72`: `facts_section`, `escape_hatch_section`, `craft_guards_section`, `mcq_patterns_section`, `response_format_section`, `process_header`) — takže boot-time kontrola (`advanced_generator.py:380-395`) prejde a `{craft_guards_section}` nie je no-op (to bola pôvodná chyba z 2026-07-30).

v1 sa nemaže: zostáva ako rollback jedného riadku.

### D4 — Sourcing režim: bez `news_mode`, s vynútenými témami
`ENABLE_NEWS_SOURCING=1` prepne Tavily na `topic="news", time_range="week"` (`app/sourcing/web_search_source.py:148-156`) — to je *týždňové spravodajstvo*, presne odložená trieda. Pre post-cutoff semi-stable fakty je to škodlivé zúženie.

Pilot preto beží **s flagom vypnutým** a recency nesie **topic list**, nie provider režim: `--topics` (`generate_pack.py:577-584` → `SourcingStage._forced_topics`, `stages/sourcing.py:80-86`). Zoznam je **locked founder decision 5**, 6 tém × ~5 otázok, doslovne (kopírovateľné znenie je v príkaze 167.9): `music producers and their artists, 2026 album releases, 2026 awards and nominations (Oscars, Grammys), new 2026 films and series, 2026 tours and festivals, 2026 streaming hits`.

**Sourcing config — vedomá odchýlka od D21b, nie „rovnaký recept".** D21b `_source` (`scripts/run_d21b_arms.py:112-115`) beží `FactSourcer(enable_wikipedia=False, enable_opentdb=False)` s komentárom „Wikipedia/OpenTDB would pollute recency (D21 rule)". Pilot nastavuje **`FactSourcer(enable_opentdb=False)`** — a robí to **vnútri nového sourcing skriptu** (viď nižšie), nie zmenou zdieľanej CLI cesty. OpenTDB von (zhoda s D21b), **Wikipedia zapnutá (odchýlka)**:

- **OpenTDB von:** statický evergreen katalóg, ktorý pri týchto témach vie doručiť len pre-cutoff fakty a riediť fact set. Nulová recency hodnota → jeden konštruktorový argument, žiadny dôvod ho tam nechať.
- **Wikipedia dnu, a prečo je to bezpečné:** D21 pravidlo bolo napísané pre **news okno** (`time_range="week"`) — tam wiki zaostáva za týždeň starou udalosťou a naozaj kontamináciu recency spôsobí. Táto trieda je opak: **datované usadené fakty z 2026**, kde je wiki článok o albume/ocenení jeden z najaktuálnejších autoritatívnych zdrojov a zároveň prvá položka founderovej hierarchie dôvery (`feedback_source_trust_hierarchy`). Trieda, pre ktorú bolo D21 pravidlo písané, je práve tá, ktorú founder decision 1 odložil.
- **Reziduálne riziko a kto ho chytí:** wiki môže na tému „2026 album releases" vrátiť aj pre-cutoff fakt (diskografia, staršie ocenenia) → vznikne evergreen otázka, ktorá do tejto triedy nepatrí. Toto **nie je** chytené `freshness_tag`-om (D1) — chytí to post-cutoff filter v D6. Je to hlavný dôvod, prečo ten filter v pláne existuje.
- **Poctivo:** oproti ramenu, ktoré dalo 7.85, meníme tri premenné (news_mode off, wiki on, iný topic list). Pilot preto **nie je replikácia** toho ramena a nemeria sa proti 7.85 — meria sa vlastným founder ratingom (D8). 7.85 zostáva len ako varovanie o rizikovosti triedy, nie ako baseline.

**Tvrdé zlyhanie pri prázdnom sourcingu (vedome ponechané fail-loud).** V grounded režime, ak Tavily+wiki nevrátia nič, `ctx.facts` je prázdny → ungrounded-drop slučka (`app/orchestrator/stages/generation.py:480`) sa preskočí a **F8 hodí** na `stages/generation.py:547` a celý beh spadne. Pre CLI pilot je to žiadané správanie: nikdy nevznikne „entertainment" dávka bez webových faktov.

**Sourcing je samostatný krok PRED generovaním — `--dump-facts` na to nestačí.** `--dump-facts` zapisuje až *po* návrate `pack_generator.run` (`generate_pack.py:449-461`), a `PackGenerator.run` výnimku stage-u re-raisuje (`pack_generator.py:194-196`) → v prázdnom prípade F8 spadne a fact súbor **nevznikne vôbec**; navyše bez `--grounded` by taký beh len ticho dumpol 0 faktov (`stages/sourcing.py:89-93`). Pilot preto dostane **nový samostatný skript `apps/quiz-pack-api/scripts/source_facts.py`** podľa overeného receptu `run_d21b_arms.py:108-128` (`_source`): spustí iba `FactSourcer(enable_opentdb=False)` nad locked témami a zapíše `{"topics": [...], "facts": [...]}` — presne formát, ktorý `_FactsFileSourcingStage` číta (`generate_pack.py:241-252`). Prah thin yield „< 40 faktov" (D21b) skript hlási sám nenulovým exit kódom + per-topic tally (`FactBatch.facts_per_topic`, `fact_sourcer.py:100-105`); pri tenkom yielde sa sourcing zopakuje s užšími formuláciami tém, brána sa neobchádza. Generuje sa až potom, z `--facts-file`.

Dva dôsledky, ktoré tento tvar rieši „zadarmo": **(a) OpenTDB lever nepotrebuje zásah do zdieľanej CLI cesty** — `SourcingStage(FactSourcer(), …)` v `generate_pack.py:318-322` je vetva ternárneho výrazu, pri `--facts-file` sa vôbec nekonštruuje, takže `enable_opentdb=False` vlastní nový skript a `scripts/generate_pack.py` sa nemení ani o riadok (žiadny nový `--no-opentdb` flag, žiadny nový default pre ostatné objednávky); **(b) batch cesta (D10) dostane fact súbor, ktorý reálne existuje** — vzniká pred generovaním, nezávisle od toho, či generovanie prejde.

**`--facts-file` samo o sebe nestačí — ale z iného dôvodu, než sa zdá.** `_FactsFileSourcingStage` naplní `ctx.facts` a `GenerationStage` ich generátoru **pošle bezpodmienečne** (`source_facts=ctx.facts or None`, `stages/generation.py:214`), takže `use_fact_first` aj category→prompt dispatch fungujú aj pri `ctx.direct_generation=True`. Čo direct režim reálne vypína, sú **obe atribučné brány**: ungrounded-drop slučka (`stages/generation.py:480`) aj F8 (`stages/generation.py:547`). Bez nich by v dávke prežili riadky bez `source_url` aj riadky s `unmatched_fallback` atribúciou — a práve na ich neprítomnosti stojí bezpečnosť offline joinu v D6. **Každý generačný príkaz pilota preto nesie `--grounded`** (D2).

### D5 — Provider: Tavily pre pilot; konsolidácia = otvorená externá otázka
Pilot ide cez **Tavily** — je to jediný implementovaný sourcing zdroj, `TAVILY_API_KEY` je povinný (`web_search_source.py:113-116`), credibility klasifikátor domén (`web_search_source.py:20-107`) je postavený na jeho výsledkoch a D21b recept je overený. ~30 otázok = rádovo desiatky advanced searchov, bez rizika limitu.

**Neuzavreté a nehádame:** či OpenAI Responses `web_search` (dnes vo fact-check, `app/verification/fact_verifier.py:142-179`) vie slúžiť aj ako **sourcing** provider, t. j. vrátiť fakty s URL/doménou, na ktorých credibility klasifikátor ešte dáva zmysel. Ak áno, Tavily vypadne z pipeline úplne (Rule #11: platený plán je kandidát na zrušenie, počas #166 evalu sa narazilo na PAYG limit). → **jediná otvorená externá otázka, riešiť úzkym web passom pred akýmkoľvek scale-upom alebo pred zrušením Tavily plánu.** Pilot ňou nie je blokovaný a rozhodnutie je reverzibilné (výmena adaptéra za `WebSearchSource`).

### D6 — Post-cutoff prijímací filter (skutočná brána) + expiry ako telemetria

**Čo sa opravuje:** prvá verzia plánu robila bránu triedy z `freshness_tag` („`current` sa neimportuje"). Podľa D1 to **nemeria nič** — očakávaný výstup tejto triedy je `evergreen`/NULL, rovnako ako pri evergreen otázke aj pri fail-safe zlyhaní klasifikátora, takže kritérium „`freshness_tag ∈ {semi-stable, NULL}`" prepustí všetky tri. Navyše to bolo označené za „bez nového kódu, len výberom pri importe", čo je **nepravda**: `scripts/import_questions_json.py` nemá žiadnu freshness/expiry vetvu (jediná brána je #158 `held_for_review`/`verified=False` na `:60-73`) a `_write_out` (`generate_pack.py:355-372`) dumpuje všetko ako `pending_review`.

**Mechanizmus — zvolený: explicitný pre-import filter krok** (z troch možností: nový flag importéra / samostatný filter krok / manuálna kurácia). Nový malý skript `apps/quiz-pack-api/scripts/filter_postcutoff.py`, ktorý číta `--out` JSON dávky **plus `--facts-file facts_167.json`** a rozdelí dávku na `accepted.json` / `rejected.json` + vypíše počty. Je **plne offline** — nič nesťahuje z webu, len číta dva lokálne JSONy. Prečo nie flag importéra: importér je zdieľaná fail-closed brána pre celý korpus a toto je pravidlo jednej triedy pilota; prečo nie manuálna kurácia ako primárna vrstva: nie je strojovo overiteľná, takže by z D8 zmizol agentsky dosiahnuteľný done-state.

**Predikát (na poliach, ktoré pipeline reálne produkuje):** riadok je prijatý, ak
1. je ročný token **≥ 2026** (referenčný dátum z founder decision 5) v `question` **alebo** `answer`, **alebo** v excerpte faktu, z ktorého otázka vznikla, **a**
2. `freshness_tag != "current"` (to je odložená news trieda — decision 1).

**Poctivo o excerpt nohe — je best-effort, nie garancia.** F8 (`stages/generation.py:536-551`) filtruje na `q.source_url`, takže garantuje **iba URL**; `_attribute_sources` (`advanced_generator.py:906-941`) dopĺňa `source_excerpt` len vtedy, keď model sám žiadne URL neemitoval (`if q.source_url: continue`). Riadok teda môže prísť s URL a **bez** excerptu. Preto filter excerpt dopĺňa offline z fact súboru: pre riadok bez `source_excerpt` dohľadá fakt podľa `source_url` a použije jeho `excerpt`/`text` (`app/sourcing/models.py:78-84`). Join je bezpečný, lebo v grounded režime sa každý riadok s fallback atribúciou zahodí ešte v GenerationStage (`stages/generation.py:496-510`) → prežije len model-emitted URL alebo URL reálne zmatchovaného faktu. Riadky s model-emitted URL v fact súbore nie sú a padajú na text otázky/odpovede — to je akceptovaná degradácia, nie skrytá diera.

**Čo filter nechytí (a kto to chytí) — proxy chybuje na obe strany:**
- *False positive:* prepustí otázku, ktorá „2026" spomenie, ale pýta sa na pre-cutoff fakt. Vidí to **founder pri ratingu** (D8); filter zabezpečí, že zlyhanie je spočítané a viditeľné.
- *False negative:* zahodí post-cutoff otázku bez ročného tokenu (typicky wiki roster producenta bez roku v texte). **Miera nie je odhadnutá** — prvé kolo pilota ju zmeria: `rejected.json` je práve to meranie a agent jeho počet + pár vzoriek uvedie v správe k ratingovej dávke. Smer chyby je konzervatívny (stráca sa yield, nie kvalita), a jeho cenu platí done-state nižšie.

Fact-check vrstva sa tu zámerne nepoužíva: `VerificationResult.sources` (`app/verification/fact_verifier.py:75`) sa do otázky **neperzistuje** — `VerificationStage` ukladá len `verified`/`verification_score`/`verification_notes`/`held_for_review` (`stages/verification.py:185-190`) — takže „musí citovať zdroj z 2026" by si vyžiadalo zmenu verification stage, čo je nad rámec pilota.

**Náprava, keď `accepted` < 20 z 30 (definovaná, fail-loud).** Presne jedno opakovacie kolo: znovu sourcing (`source_facts.py`) s **užšími/konkrétnejšími formuláciami** tém, ktoré podľa `facts_per_topic` a podľa `rejected.json` doručili najmenej prijatých riadkov, potom generovanie a filter; výsledky sa spoja s prvým kolom.

**Cross-round uniqueness nesie merge krok, nie pipeline dedup.** `DedupStage` tu chrániť **nevie**: (a) `--dedup-store` má default `noop` (`generate_pack.py:559-568`), `_NoopQuestionStore.find_duplicates` vracia `[]` (`generate_pack.py:340-360`) a príkazy pilota v D8 ho neprepínajú; (b) aj s `pgvector` kontroluje len **perzistovaný** korpus + in-batch Jaccard v rámci jedného behu (`app/orchestrator/stages/dedup.py:119-155`) — riadky 1. kola ležia v neimportovanom `pilot_167_accepted.json` až do segmentu 3, takže sú pre 2. kolo z konštrukcie neviditeľné. A 2. kolo púšťa tie isté témy, ten istý prompt a ten istý model nad prekrývajúcimi sa faktami → near-verbatim opakovanie je reálne a bez brány by prešlo cez prah ≥ 20 až k founder ratingu.

Preto `filter_postcutoff.py` dostane **merge režim** (`--merge-with pilot_167_accepted.json`) — rovnako plne offline (číta len lokálne JSONy), zrkadliaci in-batch logiku `DedupStage`. Riadok 2. kola sa zahodí, ak (a) má rovnaký fact key ako niektorý už prijatý riadok, t. j. zhodný normalizovaný `source_url` + normalizovanú `correct_answer` (`dedup.py:260-272`), **alebo** (b) Jaccard tokenov normalizovaného textu otázky voči niektorému prijatému riadku je ≥ **0.60** (`DEFAULT_IN_BATCH_JACCARD_THRESHOLD`, `dedup.py:60`). Zahodené idú do `rejected.json` s dôvodom `duplicate_round1`; ich počet agent uvedie v správe k ratingovej dávke. Do prahu ≥ 20 sa počíta až výsledok merge.

Ak je aj po druhom kole `accepted` < 20, agentský beh **končí eskaláciou founderovi in-session** — s počtami accepted/rejected a vzorkami dôvodov. Agent v tom bode **nepublikuje krátku dávku ako hotovú** a **sám latku neznižuje**: znížiť prah alebo triedu zrušiť je produktové rozhodnutie (Rule #13).

**Expiry klasifikácia zostáva zapnutá, ale degradovaná na telemetriu:** `EXPIRY_CLASSIFICATION=1` len pre pilotný CLI beh (`scripts/generate_pack.py:298-302`); vo `fly.toml` sa nič nemení, worker/prod zostáva off. TTL hodnoty ostávajú nedotknuté (`CONTENT_CLASS_TTL`: current 14 d / semi-stable 365 d / evergreen None) — founder ich zafixoval v decision 1. Zmysel jej ponechania: nastampuje `expires_at`/`freshness_tag`, takže pilot je prvým reálnym vstupom serve-time filtra a zároveň zmeria, ako sa klasifikátor na tejto triede naozaj správa (očakávanie: prevažne `evergreen`; ak by vyšlo veľa `current`, je to signál, že generátor spadol do news triedy).

Stampovanie (`app/orchestrator/stages/generation.py:299-305`) → `expires_at`/`freshness_tag` (`app/db/models/question.py:92-95`) prežije aj cestu cez JSON: dry-run zapisuje plný `Question.model_dump` (`generate_pack.py:355-372`), shared model tie polia má (`packages/shared/quiz_shared/models/question.py:239-240`) a importér ich mapuje cez `question_to_row` (`question.py:190-191`). Serve-time filter `is_expired()` už beží v prode (`apps/quiz-agent/app/retrieval/question_retriever.py:119,129`) a dnes je no-op — pilot je jeho prvý reálny vstup. Fail-safe správanie klasifikátora (neklasifikované → expiry unset) zostáva.

### D7 — Kategória viditeľná pre používateľa
Backend: pridať `"entertainment"` do `CATEGORIES` (`app/generation/classification.py:17-25`). Bez toho `normalize_category()` zráža model-emitted `entertainment` na `"general"` (`classification.py:54-68`) — dnes to maskuje len to, že `order_category` vždy vyhráva, takže korpusové riadky by kategóriu mali, ale klasifikácia mimo entertainment objednávok by ju stratila.

iOS: **dva zrkadlá, nie jedno** — obe treba upraviť naraz, inak sa rozídu:
1. `Config.categoryOptions` (`apps/ios-app/Hangs/Hangs/Utilities/Config.swift:96-106`) — riadok s `String(localized:)`; picker číta pole, takže UI netreba meniť.
2. `QuizSettings.categoryOptions` (`apps/ios-app/Hangs/Hangs/Models/QuizSettings.swift:225-229`) — validačné pole `[String?]` s komentárom „Mirrors `Config.categoryOptions`". Bez neho by uložená hodnota `entertainment` neprešla validáciou nastavení.

**Povinné:** `xcstringstool sync` nad `Hangs/Hangs/Localizable.xcstrings` (cesta z `apps/ios-app/`; je to **jediný** string zdroj v repe — `.strings` súbory neexistujú) **plus doplniť neprázdny `sk` preklad** nového kľúča, inak string odíde nepreložený. Vzor: `.strings["Sports Mix"].localizations.sk` → `"Športový mix"`.

Aliasy do `_CATEGORY_ALIASES` zámerne nepridávame — „movies"/„music" by kradli z `general` bez dát o tom, či to founder chce.

### D8 — Doručenie pilota: tri segmenty s explicitnou hranicou agent / founder

Cesta je jediná servable (A3), ale **nie je celá agentská** — hranica sa musí povedať, inak autonómny beh nemá dosiahnuteľný done-state. Founder rating leží v strede, takže agentský beh končí *pred* ním, nie pri importe.

**Segment 1 — AGENT (terminálny, celý autonómny):**
1. **Sourcing (samostatný krok, pred generovaním — D4):** `scripts/source_facts.py --topics "<locked list z decision 5>" --out facts_167.json`. Skript spadne nenulovým kódom pri thin yielde (< 40 faktov) → zopakovať s užšími témami.
2. Generovanie: `scripts/generate_pack.py --grounded --category entertainment --facts-file facts_167.json --target-count 30 --dry-run --out pilot_167.json` (`--target-count`, nie `--count` — `generate_pack.py:535-540`; `--grounded` je povinné aj pri `--facts-file`, viď D4), s `EXPIRY_CLASSIFICATION=1` v prostredí behu.
3. Offline verify + `/score-questions`.
4. **Post-cutoff filter** (D6): `scripts/filter_postcutoff.py pilot_167.json --facts-file facts_167.json` → `pilot_167_accepted.json` + `pilot_167_rejected.json`. Ak `accepted` < 20 → jedno opakovacie kolo krokov 1–4 s užšími témami, pričom filter 2. kola beží s `--merge-with pilot_167_accepted.json` (cross-round uniqueness, D6) a jeho výstup je zlúčený `accepted`; potom eskalácia founderovi (náprava definovaná v D6).
5. Publikovanie rating dávky na **prod** rating web (`https://quiz-pack-api.fly.dev`, precedens D21/D21b): `build_page.py` (offline záloha) + `publish_batch.py --base-url … --admin-key "$QUIZ_PACK_ADMIN_API_KEY" --rater michal --save-mapping …`; presné príkazy a prerekvizita kľúča v 167.12.

**Agentský done-state (strojovo overiteľný artefakt):** publikovaná rating dávka obsahujúca **N ≥ 20 riadkov, ktoré prešli post-cutoff filtrom** (t. j. `pilot_167_accepted.json` má ≥ 20 položiek a `publish_batch.py` ich publikoval), plus uložený mapping súbor a `facts_167.json`. Tu agentský beh **končí a je hotový** — ďalší postup vyžaduje človeka. Jediný alternatívny terminálny stav je eskalácia z kroku 4 (accepted < 20 po druhom kole) — tiež koniec agentského behu, len s otázkou pre foundera namiesto dávky.

**Segment 2 — FOUNDER (mimo agentského behu):** ohodnotí dávku na rating webe; agent nič nečaká, nič nepolluje. Výstup: `scripts/rating_page/export_ratings.py`.

**Segment 3 — AGENT, samostatný beh po ratingu:** import ohodnotených a founderom prijatých riadkov cez `scripts/import_questions_json.py --review-status approved --execute`; potom sa s founderom uzavrie latka kvality pre túto triedu (Phase-1 otázka 6) a rozhodne o väčšej dávke. Web review UI je retired (410, `app/web/routes.py:173-180`).

**Brány a očakávané straty (poradie je dôležité):** #158 fail-closed brána platí pri importe — riadok s `held_for_review` alebo `verified: False` sa do korpusu nedostane za žiadneho `--review-status` (`import_questions_json.py:60-73`); v tejto najchybovejšej triede je to očakávaný filter. Pred ňou uberá post-cutoff filter (D6, segment 1) a medzi nimi founder rating. Preto sa z 30 vygenerovaných počíta s citeľným úbytkom a `--target-count 30` je vstup, nie výstup.

**Success kritériá — oddelené podľa segmentu:**
- *Segment 1 (agent):* ≥ 20 post-filter riadkov (po cross-round merge, ak bežalo 2. kolo) v publikovanej rating dávke (inak náprava/eskalácia podľa D6); 0 riadkov bez `source_url`; `facts_167.json` vytvorený **pred** generovaním samostatným sourcing krokom a použitý ako `--facts-file` (= zároveň artefakt batch cesty, D10).
- *Segment 3 (po founderovi):* importované approved entertainment riadky v korpuse a zaznamenaná latka kvality triedy. Počet sa nefixuje dopredu — určí ho founder rating, to je jeho zmysel.

### D9 — Reverzibilita: **reversible**
- Žiadna DB migrácia: `expires_at`/`freshness_tag` existujú (`alembic/versions/1c5e0fa7b3d4_core_entities_issue_33_task_1_5.py:220`), `generation_mode` aj jeho CHECK constraint tiež.
- Kódové zmeny sú malé a odstrániteľné: podmienka v `pack_generator`, riadok v registri promptov, riadok v `CATEGORIES`, riadok v `Config.swift` + riadok v `QuizSettings.swift`, CLI flag `--grounded` (jediná zmena v `scripts/generate_pack.py` — sourcing config sa tam **nemení**, viď D4), a **dva** nové samostatné skripty: `scripts/source_facts.py` (volá iba `FactSourcer`, nemení žiadnu zdieľanú cestu) a `scripts/filter_postcutoff.py` (číta lokálne JSONy, nič neimportuje z pipeline; vrátane `--merge-with` režimu pre cross-round uniqueness z D6). Oba sú zmazateľné bez dopadu.
- Flagy: `EXPIRY_CLASSIFICATION` sa v prode nezapína, grounded režim je per-order (nie globálny). Korpus: ~30 riadkov, vratné cez `scripts/archive_questions.py` / `review_status='archived'` — nič sa neprepisuje.
- **Jediná lepkavá časť** je produktová, nie technická: kategória, ktorú používateľ raz uvidí v pickeri, sa nedá odobrať bez regresu UX. Preto je viazaná na founder decision 3 a nie na agentské rozhodnutie.

### D10 — Druhoradé dopady na blízky roadmap
- **Regrow korpusu cez Anthropic Batch API** (potvrdený smer, samostatná TODO): grounded režim pridáva *pred* generovanie synchrónny web krok, čo s 24h async batchom nesedí v jednom kroku. Seam ale existuje — čitateľská polovica `--facts-file` (`generate_pack.py:318, 241-252`) je hotová a pilot dodáva zapisovateľskú: `scripts/source_facts.py` píše fact set **pred** generovaním (D4), takže sa dá nasourcovať teraz a vygenerovať z neho batchom neskôr. (`--dump-facts` na to nestačí — píše až po úspešnom behu, viď D4.)
- **Blind test lacnejšieho gen modelu (Fable vs Opus vs Kimi):** pilot beží na kanonickom Fable 5 zámerne — jedna premenná naraz. A opačne: entertainment otázky **nesmú** tvoriť eval set toho blind testu, inak sa obtiažnosť triedy (D21b: všetky vecné chyby v e-news ramenách, Kimi arm 60 % chybovosť) zamieša do rozdielu medzi modelmi.
- **Budúca fresh-news expanzia:** ostáva celá nedotknutá — `ENABLE_NEWS_SOURCING`, `topic="news"`, TTL `current` 14 d aj `current` výstup klasifikátora. Expanzia = preklopiť flag, prijať `current` riadky pri importe a doplniť archive job. Tento plán jej nič nezatvára.
- **Rule #11 (náklady):** ak sa D5 uzavrie v prospech OpenAI Responses `web_search`, z pipeline zmizne celý jeden platený provider (Tavily plán) bez náhrady iným.

## Tasks (atomic)

Poradie = build order. Každá úloha je samostatne commitovateľná a self-contained; test ide v tom istom commite ako kód, ktorý overuje. **[A]** = agentská · **[F]** = founder, mimo agentského behu. Cesty sú relatívne k `apps/quiz-pack-api/`, ak nie je uvedené inak.

- [x] **167.1 [A] — `generation_mode` autoritatívny v oboch smeroch (D2).** V `app/orchestrator/pack_generator.py:136-139` nahradiť dnešný `or`-výraz trojcestným rozhodnutím: `"direct"` → True, `"grounded"` → False, `NULL`/chýbajúce → `feature_flags.direct_generation_default()`. Žiadna migrácia (stĺpec aj CHECK constraint existujú, `app/db/models/order.py:50,113-114`). Test: `tests/orchestrator/test_pack_generator.py::test_generation_mode_resolves_over_global_default` — 3 hodnoty stĺpca × oba stavy globálneho defaultu (6 asserts); intent = „explicitná objednávka prebije globálny default, `NULL` ho zdedí (byte-identické správanie app/API cesty)".
- [x] **167.2 [A] — CLI `--grounded` ako zrkadlo `--direct` (D2).** `scripts/generate_pack.py`: dnes žiadna mutually-exclusive skupina neexistuje — vytvoriť ju (`ap.add_mutually_exclusive_group()`), presunúť do nej doterajší `--direct` (`:605`) a pridať `--grounded`, aby platil exit-2 prípad z A2; `:185` → `generation_mode="direct" if args.direct else ("grounded" if args.grounded else None)`. Sourcing config sa **nemení** (D4). Test: `tests/scripts/test_generate_pack_flags.py::test_grounded_flag_sets_generation_mode` — `--grounded` → `"grounded"`, `--direct` → `"direct"`, ani jeden → `None`, oba naraz → argparse exit 2.
- [x] **167.3 [A] — entertainment prompt v2 do registra (D3).** `_CATEGORY_PROMPT_FILES` (`app/generation/advanced_generator.py:51-57`): `entertainment` → `question_generation_entertainment_v2.md`. v1 sa nemaže (rollback jedného riadku). Testy: `tests/generation/test_category_prompt_dispatch.py` (dispatch mieri na v2) + `tests/generation/test_entertainment_prompt.py` (v2 nesie všetkých 6 `_REQUIRED_FACT_FIRST_PLACEHOLDERS`, `advanced_generator.py:65-72`, takže boot-time kontrola `:380-395` prejde).
- [x] **167.4 [A] — `entertainment` v backend taxonómii (D7).** Pridať do `CATEGORIES` (`app/generation/classification.py:17-25`). Aliasy sa **nepridávajú** (D7). Test v `tests/generation/test_classification.py`: `normalize_category("entertainment") == "entertainment"` (dnes padá na `"general"`).
- [ ] **167.5 [A] — nový `scripts/source_facts.py` (D4).** Podľa receptu `run_d21b_arms.py:108-128` (`_source`): `FactSourcer(enable_opentdb=False)` (wiki zapnutá — odchýlka odôvodnená v D4) nad `--topics`, zápis `{"topics": [...], "facts": [...]}` do `--out` = formát, ktorý číta `_FactsFileSourcingStage` (`generate_pack.py:241-252`). `ENABLE_NEWS_SOURCING` sa **nenastavuje**. Thin-yield brána: < 40 faktov → exit 1 + per-topic tally z `FactBatch.facts_per_topic` (`app/sourcing/fact_sourcer.py:100-105`) na stdout. Test `tests/scripts/test_source_facts.py` s mocknutým `FactSourcer`: (a) 40+ faktov → exit 0 a výstupný JSON načíta `_FactsFileSourcingStage` bez chyby, (b) 39 faktov → exit 1 a tally menuje slabé témy, (c) `enable_opentdb=False` je odovzdané konštruktoru.
- [x] **167.6 [A] — nový `scripts/filter_postcutoff.py`: post-cutoff predikát (D6).** Plne offline: číta dávkový JSON + `--facts-file`, píše `<stem>_accepted.json` / `<stem>_rejected.json` a tally na stdout. Predikát podľa D6: ročný token ≥ 2026 v `question`/`answer`/excerpte **a** `freshness_tag != "current"`. Excerpt sa pre riadok bez `source_excerpt` dohľadá offline z fact súboru podľa normalizovaného `source_url` (`app/sourcing/models.py:78-84`). Každý zahodený riadok nesie `reason` (`no_2026_token` / `freshness_current`). Test `tests/scripts/test_filter_postcutoff.py`: accept cez text, accept cez dohľadaný excerpt, reject bez roka, reject `current`, riadok s model-emitted URL mimo fact súboru padá na text (akceptovaná degradácia).
- [x] **167.7 [A] — `--merge-with` cross-round uniqueness (D6).** Rovnaký skript, druhý režim: riadok 2. kola sa zahodí (`reason: duplicate_round1`), ak voči ktorémukoľvek už prijatému riadku platí (a) zhodný `_fact_key`, **alebo** (b) Jaccard tokenov otázky ≥ `DEFAULT_IN_BATCH_JACCARD_THRESHOLD`, **alebo** (c) Jaccard `_fact_tokens` ≥ `DEFAULT_FACT_JACCARD_THRESHOLD` (0.35) — tretia noha zrkadlí same-fact content-overlap check `dedup.py:164-174` a chytá „ten istý fakt, iná URL, preformulované pod 0.60". **Helpery sa NEreimplementujú:** `from app.orchestrator.stages.dedup import _tokenize, _jaccard, _fact_key, _fact_tokens, DEFAULT_IN_BATCH_JACCARD_THRESHOLD, DEFAULT_FACT_JACCARD_THRESHOLD` (rovnaký package, jedna definícia, žiadny drift). `_fact_key`/`_fact_tokens` berú **inštanciu `Question`**, nie dict — filter preto dumpnuté riadky oboch JSONov najprv rehydruje cez zdieľaný model (`Question.model_validate(row)`, `packages/shared/quiz_shared/models/question.py`) a až tie odovzdá helperom; surové dicty sa im nikdy neposielajú. Test v `tests/scripts/test_filter_postcutoff.py`: po jednej dvojici na každú z troch nôh + jeden near-miss pár, ktorý má prejsť; plus assert, že `filter_postcutoff._jaccard.__module__ == "app.orchestrator.stages.dedup"` (falzifikuje tichý fork prahov).
- [x] **167.8 [A] — `entertainment` v iOS (D7).** Obe zrkadlá naraz: `Config.categoryOptions` (`apps/ios-app/Hangs/Hangs/Utilities/Config.swift:96-106`, riadok s `String(localized:)`) a validačné pole `QuizSettings.categoryOptions` (`apps/ios-app/Hangs/Hangs/Models/QuizSettings.swift:225-229`). Picker číta pole, UI sa nemení. **Povinné:** `xcstringstool sync` nad `Hangs/Hangs/Localizable.xcstrings` + doplniť neprázdny `sk` preklad nového kľúča (A9). Nový parity test v `HangsTests`: `QuizSettings.categoryOptions == Config.categoryOptions.map { $0.id }` (key path `\.id` na tuple label nekompiluje) — intent = „zrkadlá sa nesmú rozísť" (dnes to drží iba komentár).
- [ ] **167.9 [A] — Segment 1 / krok 1: sourcing beh (D8).** `uv run --no-sync python scripts/source_facts.py --topics "music producers and their artists, 2026 album releases, 2026 awards and nominations (Oscars, Grammys), new 2026 films and series, 2026 tours and festivals, 2026 streaming hits" --out facts_167.json`. Pri exit 1 (thin yield): **presne jedno** opakovanie s užšími formuláciami tém, ktoré podľa tally doručili najmenej — symetricky s nápravou pri `accepted < 20`. Ak je aj druhý pokus < 40, agent **eskaluje founderovi in-session** a prah neznižuje (Rule #13).
- [ ] **167.10 [A] — Segment 1 / kroky 2–3: generovanie + verify/score (D8).** `EXPIRY_CLASSIFICATION=1 uv run --no-sync python scripts/generate_pack.py --grounded --category entertainment --facts-file facts_167.json --target-count 30 --dry-run --out pilot_167.json` (`--grounded` je povinné aj pri `--facts-file` — bez neho padnú obe atribučné brány, D4). Potom offline verify + `/score-questions`. Beh je fail-loud: prázdny fact set = F8 pád, dávka nevznikne.
- [ ] **167.11 [A] — Segment 1 / krok 4: post-cutoff filter a prípadné 2. kolo (D6/D8).** `uv run --no-sync python scripts/filter_postcutoff.py pilot_167.json --facts-file facts_167.json`. Ak `accepted < 20`: presne jedno opakovanie krokov 167.9–167.11 s užšími témami, filter 2. kola beží s `--merge-with pilot_167_accepted.json`, výsledok sa zlúči. Ak je aj potom `< 20` → eskalácia founderovi s počtami a vzorkami; agent nepublikuje krátku dávku ako hotovú.
- [ ] **167.12 [A] — Segment 1 / krok 5: publikovanie rating dávky (D8, terminálny agentský stav).** **Prerekvizita (fail-loud, overiť PRED behom):** `QUIZ_PACK_ADMIN_API_KEY` musí byť v repo `.env` (`.env.example:79-82` — deployed quiz-pack-api má vlastný kľúč; `ADMIN_API_KEY` je kľúč quiz-agentu a na prode dá 401). Ak chýba, agent **nepublikuje** a pýta si ho od foundera in-session (`publish_batch.py:77-82` inak končí `SystemExit`). Publish target = **prod rating web `https://quiz-pack-api.fly.dev`**, presne ako D21 (`issue-164:66`, batch `c1f109ec-9cc9-432c-88fd-d41e39292aec`) a D21b (`issue-166`, batch `df12c686-a914-4715-a71b-6b94190a19bd`); `/web/rate/{batch_id}` nie je admin-gated (#154). Jedno rameno, fixný seed 167, **bez** `--dedupe-by-fact` (dedup už spravil merge v D6). Z `apps/quiz-pack-api/`:
  ```bash
  uv run --no-sync python scripts/rating_page/build_page.py --arm e-2026=pilot_167_accepted.json --seed 167 \
    --batch-id 167-entertainment-pilot --title "Entertainment pilot #167" --out-dir ../../docs/testing/runs/167-entertainment-pilot
  uv run --no-sync python scripts/rating_page/publish_batch.py --arm e-2026=pilot_167_accepted.json --seed 167 \
    --title "Entertainment pilot #167" --base-url https://quiz-pack-api.fly.dev --admin-key "$QUIZ_PACK_ADMIN_API_KEY" \
    --rater michal --save-mapping ../../docs/testing/runs/167-entertainment-pilot/mapping_published.json
  ```
  Prvý príkaz je offline záloha (`rating.html` + `mapping.json` v run dir), druhý je samotná publikácia — vytlačí `batch_id` a `…/web/rate/{batch_id}?rater=michal`; obe idú do správy k dávke. Správa ďalej uvádza: počet accepted/rejected po dôvodoch (vrátane `duplicate_round1`), 2–3 vzorky false-negative rejectov (meranie miery z D6) a rozloženie `freshness_tag` (očakávanie: prevažne `evergreen`/NULL).
- [ ] **167.13 [F] — Segment 2: founder rating dávky.** Mimo agentského behu — agent nič nečaká a nepolluje. Výstup: `scripts/rating_page/export_ratings.py`.
- [ ] **167.14 [A, samostatný beh po ratingu] — Segment 3: import + latka triedy (D8).** `uv run --no-sync python scripts/import_questions_json.py <accepted-po-ratingu> --review-status approved --execute` (#158 fail-closed brána `import_questions_json.py:60-73` platí). Potom s founderom uzavrieť latku kvality triedy (Phase-1 otázka 6) a rozhodnúť o väčšej dávke.

## Acceptance

Každé kritérium je falzifikovateľné a menuje spôsob overenia. Príkazy sa púšťajú z `apps/quiz-pack-api/` (iOS z `apps/ios-app/`).

**Kód (CI, blokujúce pre merge):**

| # | Kritérium | Ako sa overí |
|---|-----------|--------------|
| A1 | `generation_mode` prebije globálny default v oboch smeroch, `NULL` ho zdedí | `pytest tests/orchestrator/test_pack_generator.py::test_generation_mode_resolves_over_global_default -q` → exit 0 |
| A2 | `--grounded` mapuje na stĺpec; `--direct --grounded` je chyba | `pytest tests/scripts/test_generate_pack_flags.py -q` → exit 0 |
| A3 | entertainment dispatch mieri na v2 a v2 prejde boot-time placeholder kontrolou | `pytest tests/generation/test_category_prompt_dispatch.py tests/generation/test_entertainment_prompt.py -q` → exit 0 |
| A4 | `normalize_category("entertainment")` nezráža na `"general"` | `pytest tests/generation/test_classification.py -q` → exit 0 |
| A5 | `source_facts.py` píše formát čitateľný `_FactsFileSourcingStage`; < 40 faktov = exit 1 + tally | `pytest tests/scripts/test_source_facts.py -q` → exit 0 |
| A6 | post-cutoff predikát vrátane offline excerpt joinu | `pytest tests/scripts/test_filter_postcutoff.py -q` → exit 0 |
| A7 | merge chytá všetky tri nohy a **nemá vlastnú kópiu** dedup helperov | tá istá suita; obsahuje assert `filter_postcutoff._jaccard.__module__ == "app.orchestrator.stages.dedup"` |
| A8 | iOS zrkadlá kategórií sú zhodné | `xcodebuild test -scheme Hangs …` → nový parity test v `HangsTests` prejde |
| A9 | nový UI string **má neprázdny slovenský preklad** | Z `apps/ios-app/`: `jq -e '.strings["Entertainment"].localizations.sk.stringUnit.value \| select(. != null and . != "")' Hangs/Hangs/Localizable.xcstrings` → exit 0 (chýbajúci kľúč aj prázdny/chýbajúci `sk` = nenulový exit; overené na sourcinge `"Sports Mix"` → `"Športový mix"`). Plus `xcstringstool sync Hangs/Hangs/Localizable.xcstrings` a následne `git diff --exit-code Hangs/Hangs/Localizable.xcstrings` → exit 0 (sync bol spravený v commite). Samotný sync je vacuous ako brána prekladu — repo nemá žiadne `.strings` súbory (precedens issue-155), jediný zdroj je `Hangs/Hangs/Localizable.xcstrings` |
| A10 | žiadny API drift (issue nemení Pydantic/Codable modely) | `/verify-api` → 0 nezhôd |

**Runbook — Segment 1 (agentský done-state):**

| # | Kritérium | Ako sa overí |
|---|-----------|--------------|
| A11 | `facts_167.json` existuje, má ≥ 40 faktov a vznikol **pred** `pilot_167.json` | `jq '.facts \| length' facts_167.json` ≥ 40; `test facts_167.json -ot pilot_167.json` → exit 0 |
| A12 | žiadny riadok dávky bez `source_url` (okrem `logical_puzzle` výnimky, `stages/generation.py:536-551`) | `jq '[.[] \| select(.source_url == null and .generation_metadata.pipeline != "logical_puzzle")] \| length' pilot_167.json` == 0 (`_write_out` dumpuje plain JSON pole, `generate_pack.py:355-372`). Výnimka je v kritériu zámerne: `OPEN_SHAPE_FRACTION=0.04` pri `--target-count 30` vyrobí ~1 open-shape riadok (`stages/generation.py:196`) a vypnúť ho sa nedá bez nového knobu — zrkadliť F8 je jednoduchšie než pridávať prepínač |
| A13 | ≥ 20 riadkov po filtri (po merge, ak bežalo 2. kolo) | `jq 'length' pilot_167_accepted.json` ≥ 20 — alebo doložená eskalácia founderovi s počtami a vzorkami (jediný alternatívny terminálny stav) |
| A14 | rating dávka je publikovaná na **prod** rating webe a mapping uložený | `publish_batch.py` (príkaz z 167.12) exit 0 a vytlačí `batch_id`; `test -s ../../docs/testing/runs/167-entertainment-pilot/mapping_published.json` → exit 0; `curl -s -o /dev/null -w '%{http_code}' "https://quiz-pack-api.fly.dev/web/rate/<batch_id>?rater=michal"` → `200` |
| A15 | správa k dávke uvádza rejects po dôvodoch, vzorky false-negative a rozloženie `freshness_tag` | vizuálna kontrola správy proti `pilot_167_rejected.json` |

**Runbook — Segment 3 (po founder ratingu):**

| # | Kritérium | Ako sa overí |
|---|-----------|--------------|
| A16 | approved entertainment riadky sú v korpuse | `SELECT count(*) FROM questions WHERE category='entertainment' AND review_status='approved' AND pack_id IS NULL` > 0 (počet sa dopredu nefixuje — určí ho founder rating) |
| A17 | latka kvality triedy je zaznamenaná | Phase-1 otázka 6 zodpovedaná v tomto issue alebo v TODO položke o kadencii obnovy |

## Follow-ups (mimo #167, do TODO)

- **Auto-archive expirovaných otázok** — dnes nič neprechádza na `archived`, monitoring ich iba počíta (`apps/quiz-agent/app/monitoring/question_monitor.py:71-79`). Founder decision 2 to explicitne odkladá; bez toho korpus ticho tichne.
- **Úzky web pass na D5** (Tavily vs OpenAI Responses `web_search` ako sourcing provider) pred scale-upom / pred zrušením Tavily plánu.
- **Kadencia obnovy** entertainment zásoby (až po founder ratingu pilota).


## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | lokálna rekognoskácia (bez web passu); build-vs-adopt = SPLIT; 6 produktových otázok na foundera |
| 2 · Plan              | ✅ done (cycle 4) | Re-plan po gate cycle 3: cross-round uniqueness pri `< 20` náprave presunutý z (neexistujúceho) pipeline dedupu do offline merge režimu `filter_postcutoff.py --merge-with` (D6/D8/D9); opravený mechanizmus `--facts-file` bez `--grounded` v D4/A1 (fakty ku generátoru idú vždy; direct režim vypína ungrounded-drop + F8). Predtým (cycle 3): sourcing vytiahnutý do samostatného skriptu pred generovaním (`--dump-facts` po páde F8 nič nezapíše) → rieši aj OpenTDB lever bez zásahu do zdieľanej CLI cesty; D6 excerpt noha priznaná ako best-effort + offline join z fact súboru; definovaná náprava pri accepted < 20. Predtým (cycle 1): locked topic list + referenčný dátum 2026 (decision 5); post-cutoff filter nahradil neúčinnú `freshness_tag` bránu (D1/D6); D4 sourcing odchýlka od D21b odôvodnená; D8 rozdelené na agent / founder / post-rating segmenty |
| 3 · Plan review       | ✅ done (cycle 4) | cycle 4: ready-check READY · design-soundness SOUND 0.87 (predtým cycle 3: READY · UNSOUND 0.72 → founder approved 4. kolo) |
| 4 · Impl-plan         | ✅ done | 14 atomických úloh (6 backend + iOS + 5 runbook segmentov + founder leg) + 17 strojovo overiteľných acceptance kritérií; zapracované non-blocking nálezy z Gate A/B cycle 4 |
| 5 · Impl-plan review  | ✅ done (cycle 2) | **cycle 2: ready-check READY · design-soundness SOUND 0.89.** Predtým (cycle 1): ready-check NOT-READY (1 blocker: 167.12 executable command) · SOUND 0.88 → re-impl (167.12/A14 prepísané na copy-pasteable príkazy s prod publish targetom + `QUIZ_PACK_ADMIN_API_KEY` prerekvizitou a curl 200 checkom; 3 Gate B nity: `map { $0.id }`, vytvorenie mutually-exclusive skupiny v 167.2, rehydrácia dictov cez `Question` v 167.7) |
| 6 · Split             | ✅ done | 14 úloh prešlo atomicity/self-containment latkou bez presekávania. **Multi-session → [`issue-167-execution-prompts.md`](issue-167-execution-prompts.md)**: 6 agentských sessions (A backend seams 167.1–167.4 ∥ B `source_facts.py` 167.5 ∥ C `filter_postcutoff.py` 167.6–167.7 ∥ D iOS 167.8 → E pilot runbook 167.9–167.12 → **[F] founder rating 167.13** → F import 167.14) + recon snapshot + locked-decisions tabuľka + human prerequisites. Class guard: **`a`** — žiadna migrácia (stĺpce aj CHECK constraint existujú), žiadna schéma, žiadny auth/payments kód, `fly.toml` nenastavuje ani jeden z `EXPIRY_CLASSIFICATION`/`ENABLE_NEWS_SOURCING`/`DIRECT_GENERATION` (overené), grounded je per-order, import v 167.14 sú dáta nie schéma → `ready-for-agent`. Founder brána (167.13) je vlastný krok medzi dvoma sessionmi, nie schovaná v agentskom behu. Non-blocking fixy zapracované: A9 prepísané na falzifikovateľný `sk`-preklad assert (`Hangs/Hangs/Localizable.xcstrings`, repo nemá `.strings`), runbook príkazy 167.9–167.11 (+167.14) normalizované na `uv run --no-sync` |

**Last updated:** 2026-08-26 (Phase 6 Split — prep uzavretý) · **Next:** — (prep complete; spúšťať cez execution prompts, Session A/B/C/D môžu bežať paralelne) · **Gate attempts:** P3 closed (3/3 + founder-approved 4th) · P5 closed (1/3)
