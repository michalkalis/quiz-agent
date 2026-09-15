# #179 — TF feedback 2026-09-14 (build 61, slovenský kvíz, MCQ + otvorené)

**Triage:** bug · done (agent-side) · **Owner:** agent · **Nadväzuje na:** #178 — TF feedback 2026-09-13, #174 — TF feedback 2026-09-08, #173 — TF feedback 2026-09-07

Founder testoval build 61 (2026-09-14 16:05–16:23, 15 screenshotov). Desať nálezov; rozdelené na **opravy bez feedbacku** (agent implementuje hneď) a **dizajn/produkt** (HTML varianty → founder pick → Pencil → kód).

## Nálezy a diagnóza

| # | Nález (founder) | Diagnóza (kód) | Rieši |
|---|-----------------|----------------|-------|
| 1 | Lišta hlasových povelov je nekonzistentná: „POČÚVAM PRÍKAZY“ bez nápovedy slov, MCQ vs. otvorená otázka sa líšia, chýbajú hinty aké slová fungujú | `ListenBar.captionText` má 6 stavov; slová nápovedy sa skryjú po 5 dokončených kvízoch (`QuizSettings.voiceHintsFreeQuizzes`), founder má >5 → vidí len „POČÚVAM PRÍKAZY“. MCQ lišta má odpočet („PREMÝŠĽAJ — POČÚVAM O 3 S“), otvorená nie (odpočet je vo výplni tlačidla Štart). Počas čítania otázky MCQ lišta nie je vôbec (screenshot 9) | **Dizajn D1** (varianty v artefakte) |
| 2 | Toolbar: mute a pauza ďaleko od seba, ikony naprieč appkou bez jednotného štýlu; play modrý | `HangsQuizToolbar`: mute + pauza v jednej `ToolbarItemGroup` pilulke (systémový rozostup), ⋯ samostatne. Play = `blue` len v pauze (jediné „pokračuj“ CTA), founder na konci: „play možno môže byť modrý“ → ostáva. Ikonový audit = dizajn | **Dizajn D2**; play ostáva modrý |
| 3 | MCQ hlasom „Lichtenštajnsko“ → nič nerozpoznané, obrazovka zamrzla (možnosti sivé, lišta preč, Preskočiť neaktívne); veľký font otázky | Sivé možnosti + bez lišty + skip off = `quizState == .processing` bez potvrdzovacieho sheetu (`QuestionView.isProcessing`). Potvrdenie ide cez `resubmitAnswer` → `submitTextInput` **bez `withUserFacingTimeout`** (30 s limit z #178 má len ťuknutie MCQ a hlasový free-text submit). Zaseknutá požiadavka = žiadny exit z `.processing`. Zhoda textu: `MCQTranscriptMatcher` (Levenshtein ≥ 0,85 + SK skloňovanie) — „Lichtenštajnsko“ vs. „Lichtenštajnsko“ by prešlo; prečo prepis neprišiel, bez Sentry logov (PR #150 nie je v builde 61) nevieme | **T1** timeout + watchdog; **T5** font |
| 4 | Otvorená otázka: „Preskoč“ (+ možno ďalšia akcia) → Štart vyblednutý, spinner v Preskoč navždy | `skipQuestion` → `submitTextInput("skip")` tiež **bez `withUserFacingTimeout`**; exit z `.skipping` len cez návrat `await`. Dvojité ťuknutie je ošetrené (single-flight cez `transition`), ale prehratý súper ticho nič neurobí | **T1** |
| 5 | Výsledok sady: v rozbalenom riadku nevidno celé znenie otázky | `SetRecapView` riadok má `lineLimit(2)`; `expandedSection` znenie vôbec nevykresľuje, len „tvoja odpoveď“ + vysvetlenie | **T2** |
| 6 | Chýba hint na hlasový povel / čo robiť, žiadny odpočet (screenshot 9: MCQ počas čítania) | Viď 1: počas `.askingQuestion` s TTS lišta chýba, odpočet začína až po dočítaní | **Dizajn D1** |
| 7 | Mute v toolbare nezastavil čítanie otázky; ikona mute zvážiť; „Preskoč“ vs. „Preskočiť otázku“ nekonzistentné | `toggleMute()` zastaví prehrávanie **len ak `isPlayingQuestionTTS()`** (`AudioDeviceState+Playback.swift:232`); na screenshote 10 je otázka sivá = iný stav prehrávania (možnosti / replay / prefetch) → podmienka false → hrá ďalej. Skip label: MCQ chip „Preskočiť otázku“, otvorená päta „Preskoč“ | **T3** mute bezpodmienečne; label = **Dizajn D3** |
| 8 | Otázka Sacher/Demel prezrádza odpoveď („Sacher“ → „Sachertorta“); chýba odkaz na zdroj pri každej odpovedi vo výsledku | id `3be05aa5-6342-49c4-b60c-130de791a8a6`, MCQ. Brána `stem_leak_reason()` (`craft_guards.py:143`) sa pri MCQ **preskakuje** a `compute_distractor_quality` porovnáva len možnosti medzi sebou, nie so znením → MCQ nemá žiadnu kontrolu úniku. `source_url` ide do appky (`PublicQuestion`), ale `RecapEntry` ho zahadzuje | **T4** archivovať + MCQ brána; **T2** zdroj vo výsledku |
| 9 | Paywall: ťuknutie na „Balík 100 otázok“ hneď kupuje; má len vybrať, kúpiť má spodné tlačidlo. CTA balíka má vlastný štýl (fialový) aj vlastný loading; „Možno zajtra“ preč | `PaywallView.packCard` action = `storeManager.purchase` priamo; `planCard` len nastaví `selectedPlan`. CTA = `PaywallNarratingCTA` (vlastný posuvný indikátor), nie `HangsPrimaryButton(isLoading:)`. „Možno zajtra“ = `HangsGhostButton` → `onDismiss()` (2×, aj offline variant) | **T6** |
| 10 | MCQ so 4 dlhými možnosťami: „Preskočiť otázku“ orezané dole | `mcqBody` = `VStack` bez ScrollView; rolluje len znenie (min 300/360 pt); možnosti (`lineLimit(3)`) rastú bez stropu → päta vytlačená pod okraj | **T5** |

## Tasky — opravy bez feedbacku

- [x] **T1 (iOS)** Zamrznutia: `withUserFacingTimeout(seconds: 30)` (zdieľaný z #178) na `resubmitAnswer`, `skipQuestion` a `endQuiz`; timeout → chybová obrazovka s retry ako pri MCQ ťuknutí. Navyše watchdog: ak `quizState ∈ {.processing, .skipping}` a nie je otvorený sheet ani `isEvaluatingAnswer` dlhšie ako 35 s → `handleError` s retry (poistka pre osirelé Tasky, napr. po zatvorení sheetu / návrate z pozadia — `QuizViewModel+ScenePhase` v `.processing` nič nerobí). Testy: timeout na resubmit/skip, watchdog, návrat z pozadia počas `.processing`.
- [x] **T2 (iOS)** Výsledok sady: v rozbalenom riadku celé znenie otázky (bez `lineLimit` v expanded stave); `RecapEntry` prenáša `sourceUrl`; v `expandedSection` odkaz na zdroj rovnakým komponentom ako `ResultScreenSections.sourceLink` (doména + ikona, `Link`). Snapshot/unit test na expanded riadok so zdrojom.
- [x] **T3 (iOS)** Mute zastaví akékoľvek prehrávanie hneď: `toggleMute()` volá `stopAnyPlayingAudio()` vždy pri prepnutí do mute (bez podmienky `isPlayingQuestionTTS`); zrušiť aj čakajúci prefetch/replay štart. Test: mute počas čítania možností / replay → playback stopnutý.
- [x] **T4 (backend)** (a) Prod — HOTOVÉ 2026-09-14 z laptopu (`updated_count: 1`): `POST /admin/questions/review-status` `{"ids": ["3be05aa5-…"], "status": "archived"}`. (b) `quiz-pack-api`: MCQ únik zo znenia — `stem_leak_reason()` neskákať pri `possible_answers`, porovnať znenie so správnou možnosťou (rovnaké tokeny/prefixy, prah 50 %); test na Sacher/Demel (fail) + čistú MCQ (pass). Nemení skóre existujúcich schválených otázok okrem úniku — spustiť existujúce testy brán.
- [x] **T5 (iOS)** MCQ layout: celé `mcqBody` (znenie + lišta + možnosti + päta) v jednom `ScrollView` s pätou pripnutou dole (`safeAreaInset(edge: .bottom)`), alebo strop výšky možností + rolovanie zoznamu — zvoliť to, čo nezmení správanie krátkych MCQ. Font znenia: MCQ `hangsDisplay(34/30)` → `30/26`, otvorená `28` → `26`; `minimumScaleFactor` ponechať. Snapshot test: 4 možnosti × 2 riadky → päta viditeľná.
- [x] **T6 (iOS)** Paywall: karta balíka len vyberie (`selectedProduct` = ročné / mesačné / balík), spodné CTA kupuje vybraný produkt („Predplatiť — 99 Kč / mesiac“ · „Kúpiť balík 100 otázok — 49 Kč“); CTA aj loading = `HangsPrimaryButton(isLoading:)` (pink, štandardný spinner), `PaywallNarratingCTA` zrušiť; „Možno zajtra“ odstrániť (obe miesta), zavretie = ✕. Test: tap na balík nespustí nákup; CTA titul podľa výberu.

## Dizajn / produkt — na rozhodnutie foundera (artefakt)

- **D1** Lišta povelov: jednotný model stavov pre MCQ aj otvorenú otázku (čítam otázku → premýšľaj + odpočet → počúvam odpoveď → vyhodnocujem), nápoveda slov vždy v lište (nie len prvých 5 kvízov), „Počúvam príkazy“ nahradiť konkrétnymi slovami.
- **D2** Toolbar + ikonový audit: jedna sada SF Symbols (hmotnosť, štýl outline vs. fill), zoskupenie mute/pauza, ikona mute.
- **D3** Skip: jeden text („Preskočiť“) a jeden tvar na MCQ aj otvorenej otázke.

Varianty: `docs/design/variants/issue-179-tf-feedback-2026-09-14.html` · rozhodnutia → `docs/design/ui-variants-2026-09-14-decisions.md`.

**Rozhodnuté 2026-09-15** (founder, in-session) — implementačné tasky:

- [x] **D1 (iOS)** Lišta povelov = variant A: jeden model 4 stavov (čítam otázku → premýšľaj + odpočet → počúvam odpoveď → vyhodnocujem) pre MCQ aj otvorenú, stavový popis + slovné čipy („štart“ · „zopakuj“ · „preskoč“), slová vždy viditeľné (`voiceHintsFreeQuizzes` brána preč, Settings prepínač ostáva), „POČÚVAM PRÍKAZY“ preč, lišta nemizne počas vyhodnocovania. **Podmienka:** zvyšný layout nemenný — spodný rad tlačidiel ostáva v jednom riadku. Testy: stavový mapping lišty pre oba typy, prítomnosť čipov bez ohľadu na počet kvízov, footer v jednom riadku (structure test).
- [x] **D2 (iOS)** Toolbar = variant A (podľa HIG): mute + pauza v jednej viditeľnej pilulke, ⋯ zvlášť; pravidlo obrysová = vypnuté / plná = zapnuté; play v pauze modrý; 4 zjednotenia ikon z auditu (skúsiť znova → `arrow.clockwise`, prehrať odpoveď → `speaker.wave.2`, chybové ikony obrysové, balík `shippingbox` obrysový).
- [x] **D3 (iOS)** Preskoč: jeden text v rozkazovacom spôsobe („Preskoč“, nie „Preskočiť otázku“/„Preskočiť“) a jeden tvar (kapsula s `chevron.right.2`) na MCQ aj otvorenej; audit ostatných tlačidiel na rozkazovací spôsob (Potvrď, Zopakuj, …) vo VŠETKÝCH jazykoch katalógu; spodný rad tlačidiel ostáva v jednom riadku.
- [ ] **Pencil sync** (`design/quiz-agent.pen`: question frame — lišta, toolbar, päta) po odsúhlasení kódu founderom.

## Regresné riziko (pozor)

- T1: `transition()` má validačnú tabuľku — nové exity z `.processing`/`.skipping` musia ísť cez `.error`; nezasahovať do `submissionEpoch`.
- T3: mute je per kvíz (override, nie Settings `isMuted`) — nemeniť.
- T5: `MCQOptionPicker.usesGrid` (2 možnosti = riadky, > 24 znakov = zoznam) ostáva; krátke MCQ musia vyzerať ako doteraz (snapshoty).
- T6: `storeManager.purchase` volá sa naďalej len z CTA; obnova nákupov nemenená.

## Stav

- 2026-09-14: založené, diagnóza hotová (4 prieskumy kódu). iOS T1/T2/T3/T5/T6 → mba (worktree, vetva `fix/179-ios-tf-feedback`), backend T4 + artefakt → laptop.
- 2026-09-14 (mba): T4b hotové — `stem_leak_reason()` beží aj pre MCQ (porovnáva znenie so správnou možnosťou, len rozlišujúce slová; výnimka keď znenie vymenúva možnosti). Sacher/Demel → flag, 115 MCQ z repo dát → 0 falošných. Guards ostávajú v SHADOW (`CRAFT_GUARDS_ENFORCE` off).
- 2026-09-15 (mba): T4b merged (#155) + quiz-pack-api deployed v68. T1/T3 = PR #156 (2 review nálezy opravené: watchdog sa po sheet-e re-armuje, mute reštartuje počúvanie povelov). T2/T5/T6 = PR #158. Artefakt publikovaný, founder rozhodol D1 A · D2 A (HIG) · D3 rozkazovací spôsob + kapsula → tasky D1–D3 vyššie.
- 2026-09-15 (mba, close-out): #156 (T1+T3) a #158 (T2+T5+T6) merged; D2+D3 = #159 merged (zlúčená pilulka mute+pauza, jednotné ikony, jedna kapsula „Preskoč“, 66 tlačidiel sk/cs v rozkazovacom spôsobe); D1 = #160 (jedna lišta, 4 stavy, slová vždy viditeľné). TF build: agent ho spustiť nemohol (auto-mode klasifikátor blokol /testflight, požiadavka prišla cez inú session) → spúšťa founder. Otvorené pre foundera: prečítať sk/cs znenie tlačidiel (testy kontrolujú len EN kľúče), TF on-device kontrola, Pencil sync. Neoverené: SE-class obrazovky (T5 päta, D1 slim lišta), veľký Dynamic Type pri pilulke.
