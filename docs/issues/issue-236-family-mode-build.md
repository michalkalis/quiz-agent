# #236.5 — Režim „S deťmi“ v appke: plán stavby

**Triage:** enhancement · ready-for-agent (po nezávislej kontrole návrhu)
**Nadradený plán:** [#236 — Rodinná sekcia „S deťmi“](issue-236-family-section.md) (rozhodnutia foundera, mantinely Apple a súkromia, 236.3 obrazovky, 236.6 „na pokec“, 236.7 pásmo 4–6)
**Plátno:** https://claude.ai/artifact/RaPirQB58rKk4qws7Pjsos (sekcia „B · rozpracované“ F1–F4, rad „V hre“ D1–D5)
**Stav kódu overený:** 2026-11-18 na `origin/main` (b8cd653d)

## Cieľ

Rodič prepne Úvod na „S deťmi“, vyberie vek a tému a zahrá s dieťaťom kolo bez časového limitu, bez skóre a bez drámy po omyle. Na konci vidia, čo sa dozvedeli. Bežný kvíz, denná výzva, štatistiky rodiča a staré buildy sa nezmenia.

**Hotovo, keď:** na TestFlight builde sa dá zahrať kolo v každom pásme aspoň na dvoch témach v slovenčine, „na pokec“ karta sa objaví a preskočí bez hodnotenia, štatistiky rodiča kolo nezapočítajú, vypnutý vypínač na serveri režim úplne skryje a starý build dostane presne to isté čo dnes.

## Ako to bude vyzerať (pre foundera)

- **Úvod.** Hore prepínač „Kvíz | S deťmi“. V režime S deťmi: nadpis „Témy pre 4–6“, vejár tém daného veku, pod ním Jazyk kvízu · Vek · Téma, tlačidlo „Štart s deťmi“. Denná výzva, rýchla hra a „Vyber viac“ sa v režime neukazujú (denná výzva je pre dospelých, kolo je vždy jedna téma). Vlastné balíky ostávajú, Úvod je časť pre rodiča.
- **Prvé prepnutie** otvorí výber veku (F1). Potom sa vek mení v stĺpci Vek. Appka si pamätá režim, vek aj poslednú tému pre každý vek.
- **Téma bez otázok sa neukáže.** Ak v danom jazyku nie je pre vek žiadna téma s celým kolom, prepínač sa neukáže vôbec.
- **Otázka.** Bez odpočítavania. Mikrofón sa zapne ťuknutím alebo povelom ako dnes, nič neutečie. Pre 4–6 dve veľké tlačidlá, ťukne rodič alebo dieťa; hlasom sa dá odpovedať tiež.
- **Po odpovedi.** Správne aj nesprávne: správna odpoveď a „Prečo“, bez prečiarknutia, bez červenej, bez odkazu na zdroj, bez série. Ďalej až na „Ďalšia“ (ťuknutie alebo povel), aby sa stihli porozprávať.
- **Na pokec.** Vlastná karta: „Na pokec“, otázka, „Správna odpoveď tu nie je a nič sa neboduje.“, „Porozprávajte sa“ a tlačidlo „Ďalšia“ (povel „ďalšia“).
- **Koniec kola.** „Toto ste sa dozvedeli“: zoznam otázok so správnymi odpoveďami, bez skóre, bez ponuky predplatného. Tlačidlá „Iná téma“ a „Úvod“.
- **Nedá sa:** poslať kolo odkazom, hrať ho v Hre spolu. Tlačidlá sa v režime neukazujú.

## Rozhodnutia v tomto pláne (s dôvodom)

| Čo | Voľba | Prečo |
|---|---|---|
| Témy pre pásmo | Server ich podáva novým endpointom, appka ich nemá natvrdo | Zoznam sa bude meniť (founder chce overiť na rodičoch, či ťahajú záľuby alebo všeobecné témy, 236.4) a téma sa smie ukázať len vtedy, keď pre ňu v jazyku a kanáli buildu existuje celé kolo. To appka sama nevie. `/app-config` na to nie je: je verejný, cachovaný 60 s podľa User-Agent a nelíši sa podľa jazyka ani kanála (`app/api/routes/app_config.py`) |
| Kde je téma na otázke | Existujúce pole `category` s novými kľúčmi `family-*` (napr. `family-lego`), žiadny nový stĺpec | Výber otázok už dnes filtruje práve `category` (`_build_metadata_filters`, `question_retriever.py:528-610`); `topic` je povinný voľný text a výber ho používa len na striedanie tém v kole (`question_retriever.py:925-928`), `subtopic` je bunka pokrytia z #170 — pokrytie a duplicity (`question.py:261`) a ostáva na podtémy v rámci témy. Kľúče `family-*` sa do bežného kvízu nedostanú, lebo bežná session berie len otázky bez pásma (PR #853). Jedna téma môže byť vo viacerých pásmach (Tvoje telo 4–6 aj 7–9): otázku určuje dvojica pásmo + kľúč |
| Ako sa kolo spustí | Nepovinné pole `age_band` na dnešnom `POST /api/v1/sessions`, téma ide v dnešnom `categories` ako jediná položka | Celá cesta session (výber, hlas, hodnotenie, kvóta, obnova po reštarte) sa použije bez kópie. Nový endpoint by duplikoval `create_session` (`app/api/routes/sessions.py:83-166`). Nepovinné pole neporuší starý build (brána OpenAPI, `infra/ci/openapi_compat.py`) |
| Kontrola pásma | `age_band` v požiadavke je výčet troch hodnôt (`AGE_BANDS`, `quiz_shared/models/question.py:20`), iná hodnota 422 | Dnes `QuizSession.age_band` prijme ľubovoľný text a nič ho nenastavuje; výčet v požiadavke bránu kompatibility neporuší (tá stráži nové hodnoty výčtu v odpovediach) |
| Časový limit | Vypína ho appka, server nič nemení | Limit sólo hry je len v appke (`QuizTimersController.swift:126`, `startThinkingTimeCountdown`, a odpočet nahrávania); server žiadny nemá |
| Skóre | Server hodnotí ako dnes, appka body neukazuje | Hodnotenie dáva „Prečo“ a správnu odpoveď; zmena by zasiahla celé `quiz/flow.py`. Body ostanú len v session, nikam sa nezapočítajú |
| Uložený režim | Samostatný kľúč `family_settings` v `PersistenceStore`, nie pole v `QuizSettings` | Bežné nastavenia (kategórie, náročnosť) ostanú nedotknuté pri prepínaní a chyba dekódovania nového záznamu nezmaže bežné nastavenia. Vzor: `Services/MultiplayerSettingsStore.swift` |
| Vypínač | `family_mode_enabled` (TestFlight) a `family_mode_enabled_app_store`, oba predvolene vypnuté | Rovnaký vzor ako Hra spolu (`multiplayer_enabled` / `_app_store`, `app/app_switches.py:53-58`): founder skúša na TestFlight builde bez toho, aby to videl App Store. Server vypnutý vypínač vynucuje aj pri štarte kola, nielen skrytím v appke |

## Server

### S-API: témy a štart kola

- **`GET /api/v1/family/topics?language=sk`** → pásma a v každom zoradené témy: `key`, `name` (v jazyku), `available` (počet hrateľných otázok, zhora orezaný na 50). Hlavičku `X-Build-Channel` číta ako dnes (`sessions.py:143`), lebo TestFlight smie vidieť aj neschválené otázky. Témy s menej ako jedným celým kolom (10) sa nevracajú. Vypnutý vypínač pre kanál buildu → prázdny zoznam.
  - Katalóg tém je súbor v kóde servera (`app/family/topics.py`: kľúč, pásma, názvy sk/cs/en, poradie). Dôvod: mení sa PR-om s kontrolou textov, nie v databáze; zoznam foundera z 236.3 je štartovný stav.
  - Počty: rovnaký filter ako hra, cez dočasnú session ako dnes `POST /questions/availability` (`app/api/routes/misc.py:168-191`), s cache ~5 min na (jazyk, kanál). Jeden dopyt so zoskupením podľa `category` namiesto jedného na tému.
- **`POST /api/v1/sessions`** dostane nepovinné `age_band`. Keď je vyplnené:
  - `categories` musí mať práve jeden kľúč, ktorý v katalógu patrí k tomu pásmu, inak 400 `family_topic_invalid`; s `pack_id` alebo `mode=multiplayer` 400.
  - Vypínač vypnutý pre kanál → 403 `family_disabled`.
  - Session si uloží `age_band`; náročnosť sa nastaví na `random` (náročnosť je „v rámci pásma“, 236.1, a appka v režime náročnosť neponúka). `include_images` vypnuté.
  - Odpoveď session nesie `age_band` (nové nepovinné pole odpovede, brána to dovolí), aby appka po obnove rozohraného kola vedela, že je to kolo s deťmi.
- **Málo otázok.** Dnes `/start` pri nule vráti 500 a pri 80 % videných 409 `reset_history` (`app/api/routes/quiz.py:190-240`). Pre kolo s pásmom: nula → 409 `family_topic_empty` (appka tému skryje a obnoví zoznam); keď je menej ako `max_questions`, kolo je kratšie a skončí ako dnes `no_more_questions` (`quiz/flow.py:366-382`). Ústupky výberu (`_fallback_retrieval`, `question_retriever.py:648-715`) uvoľňujú len náročnosť, pásmo ani tému nikdy, to ostáva.
- **Iný jazyk.** Ako bežný korpus: slovenský hráč dostane natívne sk otázky aj anglické bez jazykovej závislosti cez preklad (`question_retriever.py`, vetva jazyka). Témy viazané na miesto sa generujú natívne (236.4).
- **Analytika (server):** `quiz_started` a `answer_evaluated` dostanú vlastnosť `age_band`; `quiz_completed` tiež. Pásmo je nastavenie obsahu na udalosti, nikdy vlastnosť hráča (mantinel 1). Zoznam: `app/analytics/taxonomy.py` + `docs/product/analytics-events.md`.

### S-GUARD: čo kolo s pásmom nesmie (v1)

| Čo | v1 | Prečo a kde |
|---|---|---|
| Denná výzva | Mimo | Už izolované: výber dennej sady ide cez dočasnú session bez pásma (`daily_candidates`, `question_retriever.py:499-520`). Appka ju v režime skryje (plátno, poznámka sG) |
| Zdieľanie odkazom (#232 — zdieľanie kvízu odkazom) | Mimo, server 409 `family_not_shareable` | Odkaz z kola s pásmom by stratil otázky: snímka berie otázky cez sondu bez pásma (`shared_quiz/creation.py:54-108`, `snapshot.py:18-37`) a prijímateľ by hral bežnú session. Podporiť to chce pásmo v zdieľanom kvíze, to je samostatná zmena podľa záujmu |
| Hra spolu (#212 — Hra spolu, #230 — na diaľku) | Mimo | Miestnosť vzniká z hostiteľovej session a zdedila by jej filtre (`rooms/service.py:97-127`); `is_solo_only` (`quiz_shared/models/session.py:301-309`) dostane aj `age_band`. Spoločná hra s pásmom je v „Neskôr“ nadradeného plánu |
| Štatistiky, séria, prehľady | Mimo | Počítajú sa z udalostí `answer_evaluated` bez ohľadu na session (`app/player_stats/queries.py:23-60`, `recaps.py`). Dopyty vynechajú riadky s `age_band`. Omyl dieťaťa nemá kaziť rodičovi štatistiky a kolo s deťmi je bez skóre zámerne |
| Kvóta zadarmo | Ako bežný kvíz (počíta sa každá podaná otázka, `app/usage/tracker.py`), ale rozohrané kolo sa vždy dohrá | Mantinel 2: žiadna výzva na nákup počas hry. Dnes sa limit kontroluje po každej odpovedi a kolo preruší (`quiz/flow.py:329-353`); pri kole s pásmom sa kontroluje len na štarte, kolo dobehne a ponuka sa ukáže až na Úvode. Či sa má kolo s deťmi počítať vôbec, je otázka foundera (O1) |
| Verejné stránky otázok, web | Mimo | Už filtrujú `age_band IS NULL` (`pgvector_client.py:471`, `apps/website/tools/export_questions.py`) |

### S-CHAT: otázky „na pokec“ (236.6)

- **Údaj:** nový stĺpec `questions.scored` (boolean, nullable, NULL = hodnotí sa), na modeli `scored: bool = True`. Migrácia len pridáva, najprv quiz-pack-api, potom quiz-agent (pravidlo tabuľky `questions`, `.claude/rules/backend.md`, Migrations).
- **Správna odpoveď:** stĺpec `correct_answer` ostáva povinný, nehodnotená otázka nesie prázdny text `""`. Dôvod: povinnú odpoveď predpokladá vyše desiatich miest (hodnotiteľ `app/evaluation/evaluator.py:85-93` a `:175-188`, `serializers.py:94-168`, `quiz/flow.py:621-660` a `:734-850`, preklady s `correct_answer NOT NULL`, denná výzva, miestnosti, verejné otázky, kľúč duplicít). Prázdny text je už dnes zavedená podoba „bez odpovede“ (`Question.from_dict`, `question.py:410-418`). Overenie modelu: `scored=False` ⇔ prázdna odpoveď a bez možností; nehodnotená otázka musí mať pásmo. Tým sa nikdy nedostane do dennej výzvy, miestnosti, odkazu ani na web, takže z vymenovaných miest ju uvidí len podanie otázky a jej zobrazenie na konci kola.
- **Komu sa podáva:** len session s pásmom a s novou schopnosťou `unscored-cards` v hlavičke `X-Client-Capabilities` (`app/client_capabilities.py:21-35`; vzor `answer-codes` a `option-labels`). Bez nej filter `scored $in_or_null [True]` (operátor existuje, `pgvector_client.py:167-223`). Dôvod: build z prvých krokov (A1, A2) už posiela `age_band`, ale kartu „na pokec“ ešte nevie zahrať.
- **Koľko a kde v kole:** predvolene najviac jedna na kolo, nie prvá ani posledná (pozícia 3 až 8). Mení sa nastavením servera; počet je otázka foundera (O4).
- **Hodnotenie sa nekoná:** akýkoľvek vstup na nehodnotenú otázku (ťuknutie „Ďalšia“, povel „ďalšia“, ktorý je v sk slovníku už dnes „preskoč“, `VoiceCommandLexicon.swift:148`) ide cestou preskočenia: `Evaluation(result="skipped", points=0)` (`quiz/flow.py:652-675`), žiadne volanie hodnotiteľa, žiadna nová hodnota výsledku (nová hodnota výčtu v odpovedi by neprešla bránou). Otázka sa počíta do kvóty ako každá podaná otázka.
- **Zdroj:** pravidlo „každá otázka má zdroj“ platí pre vedomostné otázky; nehodnotená ho nemá. Strojové schválenie zdroj vyžaduje (`app/scoring/machine_approval.py`), takže „na pokec“ ostanú `pending_review` (len TestFlight), kým ich founder neschváli ručne. To je zámer, nie chyba.
- **Kedy:** samostatný krok po prvom hrateľnom režime, ale pred vydaním do App Store (founder: „už v prvej verzii“, teda v prvom vydaní sekcie). Dôvod: potrebuje vlastný stĺpec, generovanie s inou rubrikou (vtip a rozhovor, nie fakt) a ručné schválenie, a nesmie brzdiť test samotného režimu.

## Appka (iOS)

- **Stav režimu:** `FamilySettings` (Codable: `isOn`, `band`, `topicByBand`) pod kľúčom `family_settings` v `Services/PersistenceStore.swift`. Za behu ho drží `QuizViewModel` (Úvod nemá vlastný view model, `Views/HomeView.swift`) v novom rozšírení `ViewModels/QuizViewModel+Family.swift`; `isFamilySession` sa odvodí z `age_band` session, nie z prepínača (obnova kola po reštarte, `current_session_id`). Vypínač zo servera (`Models/RemoteAppConfig.swift`, `Services/AppConfigStore.swift`; chýbajúci kľúč = vypnuté) má prednosť: vypnutý skryje prepínač a Úvod ukáže bežný kvíz, uložené nastavenie sa nezmaže.
- **Úvod** (`Views/HomeView.swift`, `Views/Home/*`):
  - prepínač ako segmentový `Picker` hore (`home.mode.quiz`, `home.mode.family`); prvé zapnutie otvorí list výberu veku `FamilyBandSheet` (`family.band.<id>`);
  - `HomeCategoryDeck` dostane zoznam položiek zvonku namiesto `Config.categoryOptions` (`Views/Home/HomeCategoryDeck.swift`, krokovanie `QuizViewModel+CategoryDeck.swift:13`), v režime témy z `family/topics`; vybraná téma sa ukladá do `topicByBand`, nie do `settings.categories`;
  - `difficultyMenu` v `settingPills` nahradí menu Vek (`home.band.menu`, `home.band.<id>`); tretí stĺpec ukáže tému;
  - `startQuizButton` → „Start with kids“ / „Štart s deťmi“ (`home.startFamily`), štart cez `beginQuizStart()` s pásmom a témou (`QuizViewModel.swift:1193`, `createSession` v `Services/NetworkService.swift:331`);
  - skryté v režime: `HomeDailyChallengeSection`, `quickGameRow`, „Vyber viac“. Rýchla hra sa pre kolo s deťmi nepoužije, aj keby bola zapnutá (preskakuje vysvetlenie, `QuizViewModel+QuickGame.swift`).
- **V hre** (varianty dnešných obrazoviek, žiadny paralelný tok):
  - `QuizTimersController`: v kole s deťmi sa nespustí odpočet na rozmyslenie, odpočet nahrávania ani automatický posun z výsledku (`QuizTimersController.swift:126`, `:357`); nahrávanie ukončí ticho ako dnes;
  - `QuestionView` + `MCQOptionPicker` (`Views/Components/MCQOptionPicker.swift`): pri pásme 4–6 a dvoch možnostiach veľké tlačidlá na celú šírku, hlas počúva ako pri dnešnom výbere z možností. Otázky 4–6 sú `text_multichoice` s dvoma možnosťami (áno/nie sú tiež dve možnosti), žiadny nový typ otázky;
  - karta „na pokec“: variant `QuestionView` pri `scored == false` (`question.chatNext`), krok A3;
  - `ResultView` / `ResultAnswerPanel`: pokojný variant (bez červenej a prečiarknutia), bez `HangsSourceLink` (mantinel 3), bez série;
  - koniec: nová trasa `.learned` v `Views/RoundCompleteView.swift` nad dnešným zoznamom odpovedí, bez skóre a bez ponuky predplatného (`completionUpsell`), tlačidlá `family.end.otherTopic`, `family.end.home`. Zdieľanie skryté.
- **Hlas a ťukanie spolu:** povely ostávajú (skrátka „ďalšia“ na karte aj po výsledku); dve veľké tlačidlá sú hlavná cesta pre 4–6, hlas doplnok. Ak skúška 236.7 ukáže, že hlas malých detí nestačí, pásmo 4–6 vypne mikrofón a ostane len ťukanie (jedna podmienka v `QuizViewModel+Family.swift`).
- **Texty:** sk/cs/en v `Localizable.xcstrings` (ukrajinčina v katalógu appky zatiaľ nie je, príde s #231 — ukrajinčina ako štvrtý jazyk). Pravidlá `docs/design/copy-style.md` (tykanie, rodovo neutrálne, rozkazovací spôsob tlačidiel, „Ďalšia“ pre ďalšiu otázku oproti „Ďalej“, bez pomlčiek ako interpunkcie, rozsah „4–6“ je dovolený), kontroluje CI `copy-review`. Pozor: text na plátne „Keby si mal chvost“ je rodovo viazaný, obsah musí byť neutrálny (napr. „Keby ľudia mali chvost, na čo by bol?“); pravidlo patrí do rubriky C2. Názvy tém sú v katalógu servera, prejdú rovnakou kontrolou textov ručne v PR.
- **Prístupnosť:** identifikátory na každom prvku (`scripts/lint-a11y-ids.py`); VoiceOver číta vek ako „4 až 6 rokov“; dve tlačidlá aspoň 64 bodov vysoké; pri veľkom písme sa stĺpce pod vejárom skladajú pod seba ako dnes; vejár rešpektuje obmedzenie pohybu.
- **Analytika (appka, `Services/AnalyticsEvent.swift` + test `AnalyticsEventsTests.swift`):** `family_mode_changed {enabled}`, `family_band_selected {band, first_time}`, `family_topic_selected {band, topic}`, `family_chat_card_next {band, topic}`, `family_round_end_action {action: other_topic | home}`. Vstup do sekcie, pásmo, téma a dohraté kolo (236.5) sú tým pokryté, dohraté kolo cez `quiz_completed` s `age_band`.
- **Testy:** unit testy `QuizViewModel` s `TestClock` (odpočty sa nespustia ani po prekročení dnešnej hranice 10 s; žiadny automatický posun; obnova kola s pásmom po reštarte), `FamilySettings` uloženie a dekódovanie, vypínač; snímky `AppScreen` (`HangsTests/AppScreenSnapshotTests.swift`): Úvod v režime pre každé pásmo, prvé prepnutie, otázka 4–6, výsledok po omyle, karta na pokec, koniec kola × sk/cs/en; Page Object v `HangsUITests/Pages/HomePage.swift` a nový RS scenár „kolo s deťmi“ (`docs/testing/regression-scenarios.md`), plus `RSAppConfigTests` pre vypnutý vypínač.

## Obsah: bez otázok je režim prázdny

- **Minimum na interný test:** v slovenčine dve témy na pásmo × 20 otázok (dve celé kolá), spolu ~120 otázok, a 5 otázok „na pokec“ na pásmo. Pre vydanie: každá ponúkaná téma aspoň 30 otázok v každom jazyku, v ktorom sa režim ukáže (cieľ 236.4 je ~150 na pásmo a jazyk).
- **Cesta do knižnice:** cez korpus, nie cez vlastné balíky. Otázky balíka sú viazané na balík a strojové schválenie ich odmieta; pilot 2026-11-18 išiel cestou balíkov. Treba (krok C1):
  - do generovania korpusu (`apps/quiz-pack-api/app/corpus/fresh_*`, recept `docs/setup/general-corpus-recipe.md`) pripojiť `audience` z balíkov: detskú šablónu `prompts/question_generation_direct_kids.md`, limity a sudcu `app/kids_check.py`, pohľad dieťaťa v sudcoch (`multi_model_scorer._with_audience`), `app/audience.py`;
  - generovaná otázka nesie `age_band` a `category = family-<téma>`; importér `scripts/import_questions_json.py` ich prenesie už dnes (test `tests/scripts/test_boost_until_roundtrip.py`, `test_age_band_survives_importer_orm_and_pgvector_paths`, PR #853), doplní sa len kontrola, že pásmo je z `AGE_BANDS` a téma z katalógu;
  - pokrytie z #170 — pokrytie a duplicity počíta kategórie pre `pack_id IS NULL`; otázky s pásmom musí vynechať, inak by ich `family-*` kľúče skreslili pokrytie bežného kvízu.
- **Schválenie pre App Store** (pravidlo `CONTEXT.md`, „Review status × build channel“): App Store dostane len `approved` (founder alebo strojové brány z #177 — strojové schválenie bez nálezov), `pending_review` len TestFlight. Strojové schválenie v kóde dnes pokrýva en/sk/cs/uk (`machine_approval.py:43-44`); veta v `CONTEXT.md`, že iné jazyky ako angličtina sa strojovo neschvaľujú, je zastaraná a treba ju opraviť zvlášť. Či detské otázky smú ísť do App Store len cez strojové brány, rozhodne founder (O2); dovtedy sa importujú s `--review-status pending_review`.
- **Náklad (odhad pred behom, na schválenie):**
  - meranie 2026-11-08: vlastný balík 30 otázok ~2,80 USD v plnej cene (Claude 1,68 + overenie faktov cez web 1,09); zdroj je meranie zapísané v pamäti agenta, v repo dokumentoch nie je (v repo je len zastaraných 4,23 USD s porotou, ktorá je od #166 — experimentálne kolo D21b vypnutá, `docs/issues/issue-143-pack-cogs-reduction.md`), preto **neoverené v repo**;
  - korpus: ~9 centov na otázku cez priame API (`docs/setup/general-corpus-recipe.md:34`, uvedené, nie zmerané);
  - detská skúška 3×4 otázky stála 3,61 USD (`issue-236-family-section.md`, 236.1), drahá na otázku pre malé dávky;
  - **na 100 detských otázok teda ~9–10 USD**, s rezervou na otázky, ktoré detská kontrola vyhodí (zlyhá do bezpečia), **~12–15 USD**. Minimum na interný test ~15–20 USD, plné pokrytie podľa počtu tém a jazykov rádovo stovky USD; presný odhad ide founderovi pred behom (pravidlo nad ~3–4 USD so súhlasom).

## Kroky (malé PR, každý za vypínačom, `main` vydateľný)

| # | Krok | Závisí od | Dá sa skúšať potom |
|---|---|---|---|
| S1 | Server: katalóg tém + `GET /family/topics`, `age_band` pri štarte, kontrola pásma a témy, 409 pri prázdnej téme, vypínače, analytika `age_band` | — | testy servera; `curl` na staging s ručne vloženými otázkami |
| S2 | Server: zábrany (odkaz 409, `is_solo_only`, štatistiky bez pásma, dohranie kola pri kvóte) | — (paralelne s S1) | testy servera |
| C1 | Obsah: `audience` v korpuse, kontrola importéra, vynechanie v pokrytí, pilot ~120 otázok ako `pending_review` | S1 nasadené pred importom (počty tém) | founder hrá na TestFlight builde po A1 |
| A1 | Appka: prepínač, výber veku, témy vo vejári, Vek namiesto Náročnosti, „Štart s deťmi“, uloženie, skrytie dennej výzvy a rýchlej hry; hra beží na dnešných obrazovkách | S1 nasadené | **prvý TestFlight build na požiadanie** |
| A2 | Appka: bez odpočtov a automatického posunu, pokojný výsledok bez zdroja, dve veľké tlačidlá 4–6, koniec „Toto ste sa dozvedeli“, bez ponuky a zdieľania | A1 zlúčené (spoločný stav režimu) | **TestFlight build, hlavný test foundera** |
| S3 | Server: `scored` (migrácia quiz-pack-api, potom quiz-agent), schopnosť `unscored-cards`, preskočenie hodnotenia, pole `scored` v otázke | — (paralelne s A1/A2) | testy servera |
| C2 | Obsah: rubrika a generovanie „na pokec“, ručné schválenie founderom | S3 | — |
| A3 | Appka: karta „na pokec“, schopnosť v hlavičke | A2, S3 | TestFlight build s „na pokec“ |
| R | Vydanie: skúška hlasu s deťmi (236.7), právne kroky (236.2), plný obsah, RS scenár, zapnutie `family_mode_enabled_app_store` | všetko | App Store |

Paralelne môžu ísť samostatní workeri: S1 ∥ S2 ∥ C1 (kód generovania) na začiatku; S3 ∥ A1 ∥ A2; C2 ∥ A3. Každý worker vo vlastnom worktree, iOS s vlastným simulátorom a DerivedData. Serverové kroky nečakajú na build appky, S1–S3 sa nasadzujú hneď po zlúčení (`backend-deploy.yml`); vypínače ostávajú vypnuté, kým founder nepovie.

## Otázky pre foundera

**O1 — Počíta sa kolo s deťmi do 30 otázok zadarmo mesačne?** Dnes sa do limitu počíta každá podaná otázka bežného kvízu; denná výzva, zdieľaný kvíz a vlastné balíky sa nepočítajú. Kolo s deťmi má 10 otázok, teda tretinu mesačného limitu. Možnosti: (A) počíta sa ako bežný kvíz, rozohrané kolo sa vždy dohrá a ponuka predplatného sa ukáže až na Úvode; vedie k predaju predplatného rodinám, ale rodina bez predplatného zahrá tri kolá za mesiac. (B) nepočíta sa vôbec ako denná výzva; režim je lákadlo do appky, náklad je len hlas a hodnotenie odpovede (rádovo desatina centa na otázku), ale predplatné nič navyše neodomkne. (C) vlastný menší limit len pre režim, napr. 5 kôl mesačne. Odporúčam A: nič nového na vysvetľovanie, a dohranie kola rieši zákaz výziev na nákup počas hry.

**O2 — Smú detské otázky ísť do App Store bez tvojho schválenia?** Dnes otázka bez nálezov strojových kontrol ide do App Store sama, ostatné vidia len testeri. Detské otázky navyše prejdú detskou kontrolou, ktorá pri pochybnosti otázku vyhodí. Možnosti: (A) každú detskú otázku schváliš ty; najbezpečnejšie, ale pri ~150 otázkach na vek a jazyk je to stovky otázok. (B) rovnako ako dospelé, strojovo; najrýchlejšie, ale zábavnosť pre deti stroj zatiaľ nevie posúdiť (skúšky 236.1). (C) strojovo, ale tému v danom veku a jazyku zapneme pre App Store až po tom, čo ohodnotíš vzorku 20 otázok. Odporúčam C; otázky „na pokec“ schvaľuješ vždy ty (nemajú zdroj, stroj ich neschváli).

**O3 — Kde sa režim S deťmi ukáže po vydaní?** Americký zákon o ochrane detí na internete (COPPA) môže posudzovať aj časť appky zameranú na deti a hlas dieťaťa ide na prepis k inej firme; bez právnika to nevieme. Možnosti: (A) len v obchodoch EÚ, kým právnik nepovie inak; appka podľa krajiny obchodu režim skryje. (B) všade hneď; viac rodín, ale neznáme právne riziko v USA. (C) všade, ale v USA len s ťukaním bez hlasu; obíde hlas, ale nie celý COPPA. Odporúčam A.

**O4 — Ako dlhé je kolo a koľko je v ňom otázok „na pokec“?** Bežné kolo má 10 otázok. Malé deti dlho nevydržia a „na pokec“ trvá dlhšie, lebo sa pri nej rozpráva. Možnosti: (A) 10 otázok pre všetky veky, z toho jedna na pokec; (B) 4–6 má 6 otázok, 7–9 a 10–12 majú 10, v každom kole jedna na pokec; (C) ako B, ale dve na pokec v staršom veku. Odporúčam B: krátke kolo pre najmenších sa dá dohrať a kvóta sa míňa pomalšie.

**O5 — Čo keď téma dôjde?** Pri ~20 otázkach na tému je téma po dvoch kolách zahraná. Možnosti: (A) appka začne otázky opakovať od najstarších, s krátkou poznámkou „Už ste hrali, opakujeme“; deťom opakovanie nevadí a téma nezmizne. (B) téma ukáže „Všetko zahrané, vyber inú tému“; čistejšie, ale téma, ktorú dieťa chce, je preč, kým nepribudnú otázky. Odporúčam A.

**O6 — Názvy tém so značkami (LEGO, Minecraft, Harry Potter) na kartách?** Otázky o nich sú cez skutočný svet a značky ťahajú, ale App Review môže pri cudzej značke v rozhraní chcieť dôkaz práv (pravidlo o duševnom vlastníctve). Možnosti: (A) skutočné názvy, bez log a obrázkov, len text; najlákavejšie, malé riziko pri recenzii. (B) opisné názvy („Stavebnice“, „Kockový svet“, „Svet čarodejníkov“) a značka len v otázkach; bezpečné, menej lákavé. Odporúčam A pre TestFlight a pred App Store rozhodnúť podľa toho, či to recenzia vôbec rieši; ak by hrozilo zamietnutie celej verzie, B.

## Riziká

| Riziko | Ošetrenie |
|---|---|
| Hlas malých detí sa nerozpozná (štúdie: až tretina slov zle u škôlkarov, sk/cs nemerané) | 4–6 len dve tlačidlá, ťuká aj rodič; skúška so skutočnými deťmi pred vydaním (236.7); keď nestačí, 4–6 bez mikrofónu jedným prepínačom |
| Hodnotiteľ je na detskú odpoveď prísny (skrátená, nepresná výslovnosť) | Kolo je bez skóre, omyl ukáže len správnu odpoveď a „Prečo“; sledovať podiel „nesprávne“ v kolách s pásmom cez `answer_evaluated.age_band`, ak bude vysoký, dať hodnotiteľovi pásmo do zadania |
| COPPA v USA (viď 236.2) | O3; vypínač podľa krajiny obchodu; v analytike pásmo len ako nastavenie obsahu, nikdy vek osoby |
| Zapamätaný režim ostane zapnutý a dospelý dostane detskú otázku | Prepínač hore, „Štart s deťmi“, nadpis „Témy pre 4–6“; meranie: `family_mode_changed` krátko po štarte kola s pásmom a kolá ukončené po 1–2 otázkach; ak to bude časté, vrátiť sa k founderovej voľbe s dátami |
| Prázdne alebo tenké témy | Server vracia len témy s celým kolom, prepínač sa bez tém neukáže, 409 namiesto dnešnej 500, O5 |
| Starý build alebo bežný kvíz dostane detskú otázku | Izolácia z PR #853 (bežná session len bez pásma), `scored` len so schopnosťou, zábrany S2; testy izolácie `apps/quiz-agent/tests/db/test_age_band_isolation.py` sa rozšíria o `scored` |
| App Review vyhodnotí appku ako určenú deťom | Mantinely nadradeného plánu: rámovanie na rodiča, žiadne detské motívy v ikone a snímkach, vypínač |
| Značky v názvoch tém | O6 |
