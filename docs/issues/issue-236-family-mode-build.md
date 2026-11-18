# #236.5 — Režim „S deťmi“ v appke: plán stavby

**Triage:** enhancement · ready-for-agent (po nezávislej kontrole návrhu)
**Nadradený plán:** [#236 — Rodinná sekcia „S deťmi“](issue-236-family-section.md) (rozhodnutia foundera, mantinely Apple a súkromia, 236.3 obrazovky, 236.7 pásmo 4–6)
**Plátno:** https://claude.ai/artifact/RaPirQB58rKk4qws7Pjsos (sekcia „B · rozpracované“ F1–F4, rad „V hre“ D1–D3, D5)
**Stav kódu overený:** 2026-11-18 na `origin/main` (b8cd653d). Revízia 2 po kontrole návrhu (UNSOUND 0,6) a odpovediach foundera.

## Cieľ

Rodič prepne Úvod na „S deťmi“, vyberie vek a tému a zahrá s dieťaťom kolo bez časového limitu, bez skóre a bez drámy po omyle. Na konci vidia, čo sa dozvedeli. Bežný kvíz, denná výzva, štatistiky rodiča a staré buildy sa nezmenia.

**Hotovo, keď:** na TestFlight builde sa dá zahrať kolo v každom pásme aspoň na dvoch témach v slovenčine; zahraná téma sa hrá ďalej s opakovaním a poznámkou „Už ste hrali, opakujeme“; štatistiky rodiča kolo nezapočítajú; vypnutý vypínač na serveri režim úplne skryje a starý build dostane presne to isté čo dnes.

## Rozhodnutia foundera (2026-11-18)

| Otázka | Voľba |
|---|---|
| Kvóta zadarmo | Kolo s deťmi sa **počíta** do mesačného limitu ako bežný kvíz. Rozohrané kolo sa vždy dohrá, ponuka predplatného len na Úvode, nikdy počas kola. Hráč zadarmo s jednou zostávajúcou otázkou teda zahrá celé kolo (6 alebo 10 otázok) |
| Schvaľovanie pre App Store | Čisté otázky idú do App Store automaticky. Otázky, ktoré automatická kontrola označí ako **hraničné** (málo zábavné pre dieťa, podozrenie na očividnosť), čakajú na foundera; ten ich hodnotí **naslepo**, bez verdiktu stroja. Páry (verdikt stroja, verdikt foundera) sa uchovajú na neskoršie vyhodnotenie značkovania |
| Krajiny | **Všade hneď.** V režime jasná veta, že odpovedá dospelý. Vypínač podľa krajiny ostáva ako páka, pri vydaní nie je skrytá žiadna krajina |
| Dĺžka kola | 4–6 má **6 otázok**, 7–9 a 10–12 majú **10** |
| Otázky „na pokec“ | **Zatiaľ nie** („tie na pokec by som zatiaľ celkovo nedával“). Mení rozhodnutie z 2026-11-15; v tomto pláne nie sú, v nadradenom ostávajú v „Neskôr“ |
| Zahraná téma | Otázky sa **opakujú od tých, ktoré rodina hrala najdávnejšie**, s krátkou poznámkou „Už ste hrali, opakujeme“. Téma kvôli tomu nikdy nezmizne |
| Značky v názvoch tém | **Skutočné názvy** (LEGO, Minecraft, Harry Potter…) ako obyčajný text na kartách, aj v App Store builde; žiadne logá ani obrázky; malé riziko pri recenzii founder prijal. Záložné opisné názvy („Stavebnice“, „Kockový svet“, „Svet čarodejníkov“) ostávajú zapísané pre prípad námietky recenzie |

## Ako to bude vyzerať (pre foundera)

- **Úvod.** Hore prepínač „Kvíz | S deťmi“. V režime: nadpis „Témy pre 4–6“, vejár tém daného veku, pod ním Jazyk kvízu · Vek · Téma, tlačidlo „Štart s deťmi“ a nad ním veta, že odpovedá dospelý (návrh „Odpovedáš ty, deti hádajú s tebou.“, znenie cez kontrolu textov). Denná výzva, rýchla hra a „Vyber viac“ sa v režime neukazujú. Vlastné balíky ostávajú, Úvod je časť pre rodiča.
- **Prvé prepnutie** otvorí výber veku (F1) s tou istou vetou o dospelom. Potom sa vek mení v stĺpci Vek. Appka si pamätá režim, vek aj poslednú tému pre každý vek.
- **Témy:** vpredu záľuby a hry, všeobecné témy v menšine (pilot 236.4). Téma sa ukáže, keď má v danom jazyku aspoň jedno celé kolo. Bez tém v jazyku sa prepínač neukáže.
- **Otázka.** Bez odpočítavania. Mikrofón sa zapne ťuknutím alebo povelom ako dnes. Pre 4–6 dve veľké tlačidlá.
- **Po odpovedi.** Správne aj nesprávne: správna odpoveď a „Prečo“, bez prečiarknutia, bez červenej, bez odkazu na zdroj, bez série. Ďalej až na „Ďalšia“ (ťuknutie alebo povel), aby sa stihli porozprávať.
- **Opakovanie.** Keď kolo obsahuje už hrané otázky, na prvej otázke sa raz ukáže „Už ste hrali, opakujeme“.
- **Koniec kola.** „Toto ste sa dozvedeli“: otázky so správnymi odpoveďami, bez skóre, bez ponuky predplatného. Tlačidlá „Iná téma“ a „Úvod“.
- **Nedá sa:** poslať kolo odkazom, hrať ho v Hre spolu. Tlačidlá sa v režime neukazujú.

## Technické voľby (s dôvodom)

| Čo | Voľba | Prečo |
|---|---|---|
| Témy pre pásmo | Nový endpoint servera, appka ich nemá natvrdo | Zoznam sa bude meniť (236.4) a téma sa smie ukázať len vtedy, keď pre ňu v jazyku a kanáli buildu existuje celé kolo. `/app-config` je verejný, cachovaný 60 s podľa User-Agent a nelíši sa podľa jazyka ani kanála (`app/api/routes/app_config.py`) |
| Kde je téma na otázke | Pole `category` s kľúčmi `family-*` (napr. `family-lego`), žiadny nový stĺpec | Výber otázok filtruje `category` (`_build_metadata_filters`, `question_retriever.py:528-610`); `topic` je voľný text na striedanie v kole (`:925-928`); `subtopic` je bunka pokrytia z #170 — pokrytie a duplicity a ostáva na podtémy. Bežná session berie len otázky bez pásma (PR #853), takže `family-*` sa do bežného kvízu nedostane. Otázku určuje dvojica pásmo + kľúč (Tvoje telo je v 4–6 aj 7–9). Predpona slúži aj na vylúčenie zo štatistík (S2) |
| Štart kola | Nepovinné `age_band` na dnešnom `POST /api/v1/sessions`, téma ako jediná položka v `categories` | Celá cesta session (hlas, hodnotenie, kvóta, obnova po reštarte) bez kópie `create_session` (`app/api/routes/sessions.py:83-166`); nepovinné pole neporuší starý build (`infra/ci/openapi_compat.py`) |
| Typ `age_band` | V požiadavke pevný zoznam troch hodnôt (`AGE_BANDS`, `quiz_shared/models/question.py:20`), iná hodnota 422; v odpovediach obyčajný text | Brána kompatibility stráži nové hodnoty výčtu v odpovediach; štvrté pásmo neskôr tak bránu nezastaví. Výčet v požiadavke je dovolený |
| Celé kolo vopred | Server pri `/start` vyberie celé kolo do `fixed_question_ids` | Mechanizmus už existuje pre dennú výzvu a zdieľaný kvíz (`question_retriever.py:280-283`, `_next_fixed_question` `:428-448`). Dĺžka kola je istá, opakovanie najstarších je jedno miesto v kóde a príznak opakovania je známy pred prvou otázkou |
| Jazyk otázok | Len **natívne** otázky v jazyku session; žiadny preklad pri hraní ani anglické otázky v sk/cs kole | Detské kontroly (limity slov a čísel `app/audience.py` `LIMITS`, sudca `app/kids_check.py`, zákaz zdrobnenín) bežia na texte v jazyku generovania; preklad pri hraní by ich obišiel. Uložený preklad ako pri dennej výzve (`question_retriever.py:498-521`) kontrolu pre deti tiež nemá. v1: sk, cs a en každý natívne; ukrajinčina bez obsahu, režim sa v nej neukáže. Preklad s opätovnou detskou kontrolou je možné rozšírenie neskôr |
| Časový limit | Vypína ho appka | Limit sólo hry je len v appke (`QuizTimersController.swift:126` a odpočet nahrávania); server žiadny nemá |
| Skóre | Server hodnotí ako dnes, appka body neukazuje | Hodnotenie dáva „Prečo“ a správnu odpoveď; zmena by zasiahla celé `quiz/flow.py` |
| Uložený režim | Samostatný kľúč `family_settings` v `PersistenceStore` | Bežné kategórie a náročnosť ostanú nedotknuté a chyba dekódovania nezmaže bežné nastavenia. Vzor `Services/MultiplayerSettingsStore.swift` |
| Vypínače | `family_mode_enabled` (TestFlight), `family_mode_enabled_app_store`, oba predvolene vypnuté; `family_mode_hidden_storefronts` (zoznam krajín, predvolene prázdny) | Vzor Hry spolu (`multiplayer_enabled` / `_app_store`, `app/app_switches.py:53-58`). `/app-config` sa nelíši podľa krajiny, preto zoznam porovná appka s krajinou obchodu (StoreKit `Storefront`). Server vypnutý vypínač vynucuje aj pri štarte kola |

## Server

### S1: témy, štart a opakovanie

- **`GET /api/v1/family/topics?language=sk`** → pásma, v každom zoradené témy: `key`, `name` (v jazyku), `round_size` (6 alebo 10). Hlavička `X-Build-Channel` ako pri štarte (`sessions.py:143`). Vypnutý vypínač pre kanál → prázdny zoznam.
  - Katalóg je súbor v kóde (`app/family/topics.py`: kľúč, pásma, názvy sk/cs/en, poradie). Mení sa PR-om s kontrolou textov.
  - Téma sa vráti, keď počet hrateľných otázok (pásmo + kľúč + jazyk + stavy kanála) ≥ `round_size`. **Počet zámerne nepozná históriu hráča:** podľa rozhodnutia o zahranej téme zahraná téma ostáva hrateľná opakovaním, takže zoznam hovorí len „existuje celé kolo“ a dá sa cachovať (~5 min na jazyk a kanál, jeden dopyt so zoskupením podľa `category`).
- **`POST /api/v1/sessions` s `age_band`:** `categories` musí mať jeden kľúč, ktorý patrí k pásmu (inak 400 `family_topic_invalid`); s `pack_id` alebo `mode=multiplayer` 400; vypnutý vypínač 403 `family_disabled`. Server nastaví `max_questions` podľa pásma (hodnotu klienta ignoruje), náročnosť `random` (náročnosť je „v rámci pásma“, 236.1), `include_images` vypnuté. Odpoveď session nesie `age_band`, aby appka po obnove kola vedela, že je to kolo s deťmi.
- **`POST /sessions/{id}/start` pre kolo s pásmom** (`app/api/routes/quiz.py:56`, `excluded_question_ids` už posiela každý štart, `deps.py:167-173`):
  1. Bazén = otázky pásma + témy + jazyka + stavov kanála (filter z `_build_metadata_filters`, jazyk prísne rovnaký).
  2. Nehrané (mimo `excluded_question_ids`) v náhodnom poradí, kým nie je `round_size`.
  3. Ak chýba, doplnia sa hrané otázky bazéna v poradí, v akom sú v `excluded_question_ids`. To je história appky `asked_question_history`, zoradená od najstaršej a orezaná na 5 000 (`PersistenceStore.swift:119`, `:255-263`); otázka, ktorá z okna vypadla, sa ráta ako nehraná, čo je zároveň najstaršia. Výsledok: opakuje sa od najdávnejšie hraných. **Podmienka (nález revízie plánu 2026-11-18):** appka dnes otázku pri opätovnom zahratí v histórii neposúva (`PersistenceStore.swift:255-258`, `addQuestionId` sa pri známom id vráti), takže poradie by bolo podľa prvého zahratia a zahraná téma by donekonečna opakovala tých istých pár otázok. A1 preto zmení zápis histórie: znova zahraná otázka sa presunie na koniec (na vylučovanie v bežnom kvíze to nemá vplyv). Test: dve kolá po sebe na celej zahranej téme nesmú dať tie isté otázky. Známe obmedzenie v1: história je na zariadení, na druhom zariadení sa hrané otázky tvária ako nehrané a poznámka o opakovaní sa neukáže.
  4. Ak je bazén menší ako `round_size` (téma medzi obnovením zoznamu a štartom schudla), kolo je kratšie. Ak je bazén **prázdny**, 409 `family_topic_empty`; to je jediný prípad 409, nie dnešná 500 (`quiz.py:217-240`) ani `reset_history` (`:204-215`).
  5. Uloží `fixed_question_ids`; odpoveď štartu nesie nové nepovinné pole `repeats` (true, keď krok 3 niečo doplnil). Z neho appka ukáže „Už ste hrali, opakujeme“.
- **Kontrola pred štartom z #174 — TF test 2026-09-08 (kolo nesmie skončiť skôr, než sľúbilo).** Appka dnes pred každým štartom bez balíka, dennej výzvy a odkazu volá `POST /questions/availability` s bežnými `settings.categories` a bez pásma (`QuizViewModel.swift:1268-1280`, `:1514-1522`; server `misc.py:168-225`). Kolo s pásmom ju **preskočí** (rovnako ako balíky): nedostatok otázok nastať nemôže, lebo kolo sa vyberie celé a opakuje sa, a skrátenie kvótou nechceme, lebo rozohrané kolo sa dohrá. Endpoint sa nemení.
- **Prázdna téma v appke:** pri 409 appka tému skryje lokálne do najbližšieho spustenia a ukáže ďalšiu tému. Neobnovuje zoznam hneď, takže nevznikne slučka s cachovaným zoznamom.
- **Kvóta:** `/start` kontroluje limit ako dnes (`quiz.py:89-112`): s nulou zostávajúcich 429 a dnešný paywall na Úvode; s aspoň jednou otázkou kolo začne. Kontrola po každej odpovedi (`quiz/flow.py:329-353`) pre kolo s pásmom odpadne (S2), takže kolo dobehne a počítadlo `record_question` môže prejsť nad limit. Test v S2 overí, že `get_usage` vtedy hlási 0 zostávajúcich, nie záporné číslo.
- **Analytika (server):** `quiz_started` dostane `age_band` a `repeats`, `answer_evaluated` a `quiz_completed` dostanú `age_band`. Pásmo je nastavenie obsahu na udalosti, nikdy vlastnosť hráča (mantinel 1). `app/analytics/taxonomy.py` + `docs/product/analytics-events.md`.

### S2: čo kolo s pásmom nesmie (v1)

| Čo | v1 | Prečo a kde |
|---|---|---|
| Denná výzva | Mimo | Už izolované: denná sada ide cez sondu bez pásma (`daily_candidates`, `question_retriever.py:499-521`). Appka ju v režime skryje (plátno, poznámka sG) |
| Zdieľanie odkazom (#232 — zdieľanie kvízu odkazom) | Mimo, 409 `family_not_shareable` | Snímka berie otázky cez sondu bez pásma (`shared_quiz/creation.py:54-108`, `snapshot.py:18-37`); odkaz by stratil otázky a prijímateľ by hral bežnú session |
| Hra spolu (#212 — Hra spolu, #230 — na diaľku) | Mimo | Miestnosť vzniká z hostiteľovej session (`rooms/service.py:97-127`); `is_solo_only` (`quiz_shared/models/session.py:301-309`) dostane aj `age_band` |
| Štatistiky, séria, prehľady | Mimo, filtrom na predponu `family-` v kategórii | Počítajú sa z udalostí `answer_evaluated` a berú posledný riadok na otázku (`app/player_stats/queries.py:23-45`); opravené hodnotenie posiela nový riadok bez `age_band` (`app/quiz/resubmission.py:254-267`). `category` nesú obe udalosti aj `quiz_started` (`fetch_games`), preto je filter na predponu jednoduchší a ťažšie sa rozbije než nová vlastnosť |
| Kvóta | Počíta sa, kolo sa dohrá | Rozhodnutie foundera; kontrola po odpovedi pre kolo s pásmom odpadne (`quiz/flow.py:329-353`) |
| Verejné stránky, web | Mimo | Už filtrujú `age_band IS NULL` (`pgvector_client.py:471`, `apps/website/tools/export_questions.py`) |

## Appka (iOS)

- **Stav režimu:** `FamilySettings` (`isOn`, `band`, `topicByBand`) pod kľúčom `family_settings` v `Services/PersistenceStore.swift`. Za behu ho drží `QuizViewModel` (Úvod nemá vlastný view model) v rozšírení `ViewModels/QuizViewModel+Family.swift`; `isFamilySession` sa odvodí z `age_band` session (obnova kola po reštarte, `current_session_id`). Vypínače zo servera (`Models/RemoteAppConfig.swift`, `Services/AppConfigStore.swift`; chýbajúci kľúč = vypnuté) majú prednosť: vypnutý alebo skrytá krajina skryje prepínač, uložené nastavenie sa nezmaže.
- **Úvod** (`Views/HomeView.swift`, `Views/Home/*`):
  - segmentový `Picker` hore (`home.mode.quiz`, `home.mode.family`); prvé zapnutie otvorí list `FamilyBandSheet` (`family.band.<id>`) s vetou o dospelom;
  - `HomeCategoryDeck` dostane položky zvonku namiesto `Config.categoryOptions` (`Views/Home/HomeCategoryDeck.swift`, krokovanie `QuizViewModel+CategoryDeck.swift:13`); vybraná téma ide do `topicByBand`, nie do `settings.categories`;
  - `difficultyMenu` v `settingPills` nahradí menu Vek (`home.band.menu`, `home.band.<id>`); tretí stĺpec ukáže tému;
  - `startQuizButton` → „Start with kids“ / „Štart s deťmi“ (`home.startFamily`), štart cez `beginQuizStart()` s pásmom a témou a s preskočením kontroly počtu pred štartom (`QuizViewModel.swift:1193`, `:1268`; `createSession` v `Services/NetworkService.swift:331`);
  - v režime skryté: `HomeDailyChallengeSection`, `quickGameRow`, „Vyber viac“. Rýchla hra sa pre kolo s deťmi nepoužije (preskakuje vysvetlenie, `QuizViewModel+QuickGame.swift`).
- **V hre** (varianty dnešných obrazoviek, žiadny paralelný tok):
  - `QuizTimersController`: v kole s deťmi sa nespustí odpočet na rozmyslenie, odpočet nahrávania ani automatický posun z výsledku (`:126`, `:357`); nahrávanie ukončí ticho ako dnes;
  - `QuestionView`: poznámka „Už ste hrali, opakujeme“ pri `repeats` na prvej otázke; `MCQOptionPicker` (`Views/Components/MCQOptionPicker.swift`) pri pásme 4–6 a dvoch možnostiach veľké tlačidlá na celú šírku, hlas počúva ako pri dnešnom výbere z možností. Otázky 4–6 sú `text_multichoice` s dvoma možnosťami, žiadny nový typ;
  - `ResultView` / `ResultAnswerPanel`: pokojný variant bez červenej a prečiarknutia, bez `HangsSourceLink` (mantinel 3), bez série;
  - koniec: trasa `.learned` v `Views/RoundCompleteView.swift` nad dnešným zoznamom odpovedí, bez skóre, bez `completionUpsell` a bez zdieľania; tlačidlá `family.end.otherTopic`, `family.end.home`.
- **Hlas a ťukanie:** povely ostávajú; dve veľké tlačidlá sú hlavná cesta pre 4–6. Ak skúška 236.7 ukáže, že hlas nestačí, pásmo 4–6 vypne mikrofón jednou podmienkou v `QuizViewModel+Family.swift`.
- **Texty:** sk/cs/en v `Localizable.xcstrings` (ukrajinčina v katalógu appky ešte nie je, príde s #231 — ukrajinčina ako štvrtý jazyk). Pravidlá `docs/design/copy-style.md` (tykanie, rodovo neutrálne, rozkazovací spôsob tlačidiel, „Ďalšia“ pre ďalšiu otázku oproti „Ďalej“, bez pomlčiek ako interpunkcie, rozsah „4–6“ dovolený), CI `copy-review`. Názvy tém v katalógu servera prejdú tou istou kontrolou ručne v PR.
- **Prístupnosť:** identifikátory na každom prvku (`scripts/lint-a11y-ids.py`); VoiceOver číta vek „4 až 6 rokov“; dve tlačidlá aspoň 64 bodov vysoké; pri veľkom písme sa stĺpce skladajú pod seba ako dnes; vejár rešpektuje obmedzenie pohybu.
- **Analytika (`Services/AnalyticsEvent.swift`, test `AnalyticsEventsTests.swift`):** `family_mode_changed {enabled}`, `family_band_selected {band, first_time}`, `family_topic_selected {band, topic}`, `family_topic_empty {band, topic}`, `family_round_end_action {action: other_topic | home}`; dohraté kolo cez `quiz_completed` s `age_band`.
- **Testy:** unit testy `QuizViewModel` s `TestClock` (odpočty sa nespustia ani po dnešnej hranici 10 s, žiadny automatický posun, kontrola počtu pred štartom sa nevolá, poznámka pri `repeats`, 409 skryje tému bez nového dopytu, obnova kola s pásmom); `FamilySettings`; snímky `AppScreen` (`HangsTests/AppScreenSnapshotTests.swift`): Úvod v režime pre každé pásmo, prvé prepnutie, otázka 4–6, výsledok po omyle, koniec kola × sk/cs/en; Page Object `HangsUITests/Pages/HomePage.swift`, RS scenár „kolo s deťmi“ (`docs/testing/regression-scenarios.md`), `RSAppConfigTests` pre vypnutý vypínač.

## Obsah: bez otázok je režim prázdny

- **Katalóg tém (návrh, poradie = poradie vo vejári):** záľuby a hry vpredu, všeobecné témy v menšine (pilot 236.4). 4–6: Dinosaury, Superschopnosti zvierat, Rozprávky a večerníčky, Fuj ale pravda, Zvuky a smiešne slová, Tvoje telo. 7–9: LEGO, Minecraft, Pokémon, Futbal, Superschopnosti zvierat, Dinosaury, Fuj ale pravda, Rekordy, Ako sa čo vyrába. 10–12: Minecraft, Harry Potter, Roblox, Futbal, Špióni a šifry, Dalo by sa to?, Rekordy, Vesmír, Jedlo ako veda. Pokémon, Roblox, futbal a rozprávky pribudli z verdiktu pilotu a štartových tém 236.4; poradie je návrh, founder ho mení v PR katalógu.
- **Minimum na interný test (pilot C1):** v slovenčine dve témy na pásmo × 20 otázok, spolu ~120: 4–6 Dinosaury + Fuj ale pravda, 7–9 Minecraft + LEGO, 10–12 Harry Potter + Špióni a šifry (jedna overená téma z pilotu na porovnanie). 20 otázok = 3 kolá pre 4–6, 2 kolá pre staršie. Pre vydanie: každá ponúkaná téma aspoň 30 otázok v každom jazyku, v ktorom sa ukáže (cieľ 236.4 ~150 na pásmo a jazyk), natívne v sk, cs aj en.
- **Cesta do knižnice:** cez korpus, nie cez vlastné balíky (otázky balíka sú viazané na balík a strojové schválenie ich odmieta; pilot 2026-11-18 išiel cestou balíkov). Krok C1:
  - do generovania korpusu (`apps/quiz-pack-api/app/corpus/fresh_*`, recept `docs/setup/general-corpus-recipe.md`) pripojiť `audience`: šablónu `prompts/question_generation_direct_kids.md`, limity a sudcu `app/kids_check.py`, pohľad dieťaťa v sudcoch (`multi_model_scorer._with_audience`, `app/scoring/multi_model_scorer.py:422`), `app/audience.py`;
  - otázka nesie `age_band` a `category = family-<téma>`; importér `scripts/import_questions_json.py` ich prenesie už dnes (test `test_age_band_survives_importer_orm_and_pgvector_paths` v `tests/scripts/test_boost_until_roundtrip.py`, PR #853); doplní sa kontrola, že pásmo je z `AGE_BANDS` a téma z katalógu;
  - pokrytie z #170 — pokrytie a duplicity (`pack_id IS NULL`) musí otázky s pásmom vynechať, inak by `family-*` skreslili pokrytie bežného kvízu.
- **Schvaľovanie (rozhodnutie foundera, krok C2):** App Store dostane len `approved`, `pending_review` vidí len TestFlight (`CONTEXT.md`, „Review status × build channel“).
  - **Bezpečnosť nie je hraničná:** detská kontrola pri `unsuitable` alebo `unsure` otázku vyhodí (`kids_check.py`, zlyhá do bezpečia), na foundera sa nedostane.
  - **Hraničná značka:** pri generovaní s pásmom sa uložia skóre sudcov s pohľadom dieťaťa v zábavných rozmeroch (`surprise_delight`, `conversation_spark`, `tellability`, skupina „fun“, `multi_model_scorer.py:238-364`) do `generation_metadata.extra`. Strojové schválenie (`app/scoring/machine_approval.py:101`) dostane pre otázky s pásmom jeden dôvod navyše, `kids_borderline`: priemer pod prahom, chýbajúci verdikt sudcu, alebo nízke skóre za prekvapenie (stand-in pre očividnosť). Hraničná otázka dostane `pending_review`, čistá ide ďalej dnešnými bránami.
  - **Slepé hodnotenie:** hraničné otázky idú do dávky existujúceho nástroja na slepé hodnotenie z #154 — úložisko hodnotení a web (`RatingBatch` + stránka `GET /web/rate/{batch_id}`, `apps/quiz-pack-api/app/web/rate.py`, `app/api/v1/ratings.py`). Stránka dostane len zaslepené otázky, priradenie ostáva na riadku dávky; verdikt stroja sa uloží tam, nie na stránku.
  - **Páry:** hodnotenie foundera (`Rating`) a verdikt stroja sa spoja cez zaslepené id dávky; malý skript ich vyexportuje a podľa prahu foundera povýši na `approved` (`reviewed_by=michal`) alebo zamietne. Páry ostávajú v databáze na kalibráciu prahu.
  - Prah sa nastaví z prvého pilotu: founder ohodnotí naslepo všetkých ~120, stroj ich ohodnotí tiež a prah sa zvolí tak, aby hraničné zachytili väčšinu zlých.
  - Strojové schválenie dnes pokrýva en/sk/cs/uk (`machine_approval.py:43-44`); veta v `CONTEXT.md`, že iné jazyky ako angličtina sa strojovo neschvaľujú, je zastaraná a opraví sa zvlášť.
- **Náklad (odhad pred behom, na schválenie):** meranie 2026-11-08, balík 30 otázok ~2,80 USD v plnej cene (Claude 1,68 + overenie faktov cez web 1,09), je zapísané len v pamäti agenta, nie v repo (v repo je zastaraných 4,23 USD s porotou vypnutou od #166 — experimentálne kolo D21b, `docs/issues/issue-143-pack-cogs-reduction.md`), preto **neoverené v repo**. Korpus ~9 centov na otázku (`docs/setup/general-corpus-recipe.md:34`, uvedené, nie zmerané). Detská skúška 3×4 otázky 3,61 USD (236.1). **Na 100 detských otázok ~9–10 USD, s rezervou na vyhodené ~12–15 USD.** Pilot ~15–20 USD; plné pokrytie natívne v troch jazykoch rádovo stovky USD. Presný odhad ide founderovi pred behom.

## Kroky (malé PR, každý za vypínačom, `main` vydateľný)

| # | Krok | Závisí od | Dá sa skúšať potom |
|---|---|---|---|
| S1 | Server: katalóg + `GET /family/topics`, `age_band` pri štarte, kontroly, celé kolo vopred s opakovaním a `repeats`, 409 len pri prázdnom bazéne, vypínače, analytika | — | testy servera; staging s ručne vloženými otázkami |
| S2 | Server: zábrany (odkaz 409, `is_solo_only`, štatistiky bez `family-*`, dohranie kola pri kvóte) | — (paralelne s S1) | testy servera |
| C1 | Obsah: `audience` v korpuse, kontroly importéra, vynechanie v pokrytí, uloženie skóre sudcov, pilot ~120 sk otázok ako `pending_review` | S1 nasadené pred importom | founder hrá na TestFlight builde po A1 |
| C2 | Schvaľovanie: dôvod `kids_borderline`, dávka slepého hodnotenia, skript párov a povýšenia, kalibrácia prahu na pilote | C1 | founder hodnotí dávku na webe |
| A1 | Appka: prepínač, výber veku, veta o dospelom, témy vo vejári, Vek namiesto Náročnosti, „Štart s deťmi“, preskočenie kontroly počtu pred štartom, presun znova zahranej otázky na koniec histórie, uloženie, skrytie dennej výzvy a rýchlej hry; hra na dnešných obrazovkách | S1 nasadené | **prvý TestFlight build na požiadanie** |
| A2 | Appka: bez odpočtov a automatického posunu, poznámka o opakovaní, pokojný výsledok bez zdroja, dve veľké tlačidlá 4–6, „Toto ste sa dozvedeli“, bez ponuky a zdieľania | A1 zlúčené (spoločný stav režimu) | **TestFlight build, hlavný test foundera** |
| R | Vydanie: skúška hlasu s deťmi (236.7), texty a súkromie (236.2), plný obsah schválený cez C2, RS scenár, zapnutie `family_mode_enabled_app_store` | všetko | App Store |

Paralelne samostatní workeri: S1 ∥ S2 ∥ C1 na začiatku; C2 ∥ A1; A2 po A1. Každý vo vlastnom worktree, iOS s vlastným simulátorom a DerivedData. Serverové kroky nečakajú na build appky a nasadzujú sa po zlúčení (`backend-deploy.yml`); vypínače ostávajú vypnuté, kým founder nepovie.

## Otázky pre foundera

Žiadne otvorené; odpovede z 2026-11-18 sú v „Rozhodnutia foundera“.

## Riziká

| Riziko | Ošetrenie |
|---|---|
| COPPA v USA | Founder 2026-11-18 rozhodol vydať všade s vetou, že odpovedá dospelý. **Táto veta nie je právna záruka:** americký úrad môže časť appky s detskými témami posudzovať ako zameranú na deti a hlas dieťaťa, ak prehovorí, ide na prepis k inej firme. Founder toto riziko prijal. Páka: `family_mode_hidden_storefronts` skryje režim v krajine bez nového buildu; pásmo v analytike len ako nastavenie obsahu. Posúdenie právnikom ostáva ako nepovinný ďalší krok, nie podmienka vydania |
| Hlas malých detí sa nerozpozná | Odpovedá dospelý; 4–6 dve tlačidlá; skúška pred vydaním (236.7); keď nestačí, 4–6 bez mikrofónu |
| Hodnotiteľ je na detskú odpoveď prísny | Kolo bez skóre, omyl ukáže len odpoveď a „Prečo“; sledovať podiel „nesprávne“ v kolách s pásmom, pri vysokom dať hodnotiteľovi pásmo do zadania |
| Zapamätaný režim ostane zapnutý | Prepínač hore, „Štart s deťmi“, „Témy pre 4–6“; meranie `family_mode_changed` krátko po štarte kola a kolá ukončené po 1–2 otázkach |
| Tenké témy, časté opakovanie | Zoznam len s celým kolom, opakovanie od najstarších, 409 len pri prázdnom bazéne bez slučky; podiel `repeats` v `quiz_started` ukáže, kde dopĺňať |
| Zlá hraničná značka (stroj pustí nudné, alebo pošle foundrovi priveľa) | Prah z kalibrácie na pilote, páry stroj/founder uchované, prah sa dá posunúť bez novej generácie |
| Starý build alebo bežný kvíz dostane detskú otázku | Izolácia z PR #853, zábrany S2, testy `apps/quiz-agent/tests/db/test_age_band_isolation.py` rozšírené o kolo vybrané vopred |
| App Review vyhodnotí appku ako určenú deťom, alebo namietne značky | Rámovanie na rodiča, žiadne detské motívy v ikone a snímkach; pri námietke voči značkám opisné názvy v katalógu (zmena servera, bez buildu) |
