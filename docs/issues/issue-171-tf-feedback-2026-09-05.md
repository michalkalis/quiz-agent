# #171 — TF feedback 2026-09-05: prvá otázka bez zvuku, hlasitosť, prázdna nahrávka, pauza, vyhodnocujem, päta, timer potvrdenia, MCQ potvrdenie

**Triage:** bug · ready-for-agent (founder rozhodnutia 2026-09-05 nižšie)
**Status:** diagnóza DONE 2026-09-05, founder rozhodol všetky výbery, implementácia beží v paralelných PR (viď Poradie)
**Created:** 2026-09-05
**Founder round:** TestFlight, slovenský kvíz, iOS 26
**Varianty:** [`docs/design/variants/issue-171-tf-feedback-2026-09-05.html`](../design/variants/issue-171-tf-feedback-2026-09-05.html)
**Reversibility:** `a` — všetko iOS-side okrem G (backend validácia prekladu, additívna)

## Founder nálezy → tracky

| # | Nález | Track | Typ |
|---|---|---|---|
| 1 | „Nahrávať“ + ikona + 23s sa nezmestia (SK) | C | layout bug + výber C1/C2/C3 |
| 2 | Slovenský text otázky „palácapalác“ | G | prekladový artefakt (serve-time preklad, #168 ešte nie je live) |
| 3 | Prvá otázka sa neprehrá, až po klepnutí na opakovanie | A | P0 audio bug |
| 4 | Kvíz sa nedá pauznúť | D | feature + výber A1/A2 |
| 5 | Prázdna nahrávka → banner + celý odpočet odznova | B | flow bug (founder: nikdy neopakovať, ísť ďalej / na potvrdenie) |
| 6 | Čo robí appka v pozadí? | H | dnes: odpočet beží, mikrofón stop; rozhodnutie o návrate |
| 7 | „Vyhodnocujem“ špiní spodok obrazovky | E | UI + výber B1/B2 |
| 8 | Hlasitosť skáče (koreluje s počúvaním povelov) | A | audio, štrukturálny fix |
| 9 | Zvuk aj pri stlmenom bočnom prepínači | A | overené: funguje (kategória `.playback` / `.playAndRecord`) |
| 10 | Timer potvrdenia pridlhý | F | hodnota + nastavenie |
| 11 | MCQ hlasom: odpoveď sa vezme hneď, bez potvrdenia; nejasné, či sa dá odpovedať textom možnosti | I | flow + copy (founder: potvrdenie povinné, text možnosti povoliť) |

## Track A — Audio: prvá otázka ticho + skákanie hlasitosti (P0)

**Prvá otázka (med-high istota).** Domáci poslucháč povelov (mikrofónový engine s voice-processing) sa pri štarte kvízu **nevypína**; kvíz pod ním prekonfiguruje a znova aktivuje audio session (`QuizViewModel.swift:892` → `AudioService.swift:245-251`) a hneď spustí prehrávanie bez usadenia (`AudioDeviceState+Playback.swift:38-42`). AVPlayer sa nerozbehne, po 5 s stall timer vyhodí `playbackFailed`, chyba ide len do Sentry bez UI (`AudioDeviceState.swift:303-309`) → ticho, odpočet beží. Otázky 2+ majú `stopAnyPlayingAudio()` + 0,1 s pauzu (`QuizViewModel.swift:1799-1803`) → preto fungujú. Repo túto poruchu už pozná: `AudioService.swift:385-389`. Overiť pred fixom v Sentry: `"TTS audio failed"` kind=question.

**Hlasitosť (high).** Nikto nepíše hardvérovú hlasitosť (#131 E platí). Počuteľné zmeny zisku:
1. `.playAndRecord ↔ .playback` swap pri každom čítaní (otázka + spätná väzba = 2× na otázku), repo sám pinuje ~6 dB (`AudioService.swift:346-348, 362-407`);
2. **voice-processing I/O ON/OFF** pri každom zapnutí/vypnutí poslucháča povelov (`SilenceDetectionService+InputTap.swift:36-45`), 2–4× na otázku, vlastný AGC → presne korelácia, ktorú founder cíti;
3. settle loop až 12× `setActive(true)` pri arme (`SilenceDetectionService+Engine.swift:126-133`).

**Bočný prepínač:** TTS hrá vždy (kategórie ignorujú prepínač); iba earcony cez system sound sú stlmené, už mitigované haptikou (`EarconPlayer.swift:61-71`). Nič netreba.

**Fix (štrukturálny, jeden PR):**
- Krok 1: pri `startNewQuiz` najprv zastaviť poslucháča povelov, potom **raz** nakonfigurovať session (`.playAndRecord` + `.spokenAudio` + fixné options) a prvé prehrávanie podmieniť usadením (rovnaký vzor ako Q2+).
- Krok 2: zrušiť per-utterance `.playback` swap; stratených ~6 dB dorovnať staticky (gain TTS assetu / override output port), nie per čítanie.
- Krok 3: voice-processing držať zapnuté počas celého kvízu (arm/disarm len pri štarte/konci), nie per okno. Home si necháva svoju tichú session z #136, aplikovanú raz pri vstupe na Home.
- Kompatibilné s #104 (žiadne HFP renegotiation) a #136. Testy: rozšíriť `QuietListeningSessionOptionsTests` o „počas kvízu sa kategória nemení“ + test „prvé prehrávanie až po stopnutí poslucháča“.
- Overenie: Sentry TTS-failed počítadlo = 0 v ďalšom TF kole; founder ucho na hlasitosť.

## Track B — Prázdna nahrávka nesmie reštartovať odpočet

Dnes 3-stupňová retry slučka (`RecordingCoordinator+Capture.swift:253-286`): stupeň 1 a 2 = banner „Prepáč, nezachytil som to…“ + návrat do `.askingQuestion` + `restartAnswerWindow()` → **nový celý odpočet** (`QuizViewModel.swift:1592-1601`); stupeň 3 = skip. Do tej istej funkcie tečú 4 cesty: prázdny prepis, watchdog STT (5 s), Whisper bez výsledku, backend 400 „speech not understood“. Iba `unattendedSilence` slučku obchádza a končí skipom.

**Fix (founder pravidlo: žiadne opakovanie):** všetky 4 cesty → jedna vetva bez `restartAnswerWindow()`:
- otvoriť potvrdzovaciu obrazovku s prázdnym poľom (`transcribedAnswer = ""`, `showAnswerConfirmation = true`), klávesnica k dispozícii, auto-potvrdenie beží; vypršanie alebo potvrdenie prázdneho = „bez odpovede“ → výsledok (**odporúčané**, viď rozhodnutie R2);
- `AnswerConfirmationView.swift:145-147` dnes zakazuje Potvrdiť pri prázdnom prepise → zmeniť na „Potvrdiť = bez odpovede“ alebo ponúknuť Preskočiť.
- Prepísať testy `ResetModelTests.swift:115-181` (4 testy pinujú retry slučku) na nové pravidlo; zdôvodnenie slučky v `RecordingCoordinator.swift:167` nahradiť odkazom sem.

## Track C — Päta: Nahrávať + 23s (výber C1/C2/C3)

Príčina: Písať/Preskočiť majú pevnú šírku podľa textu bez zmenšovania (`QuestionVoiceFooter.swift:168-200`), Nahrávať dostane zvyšok; pill so sekundami nemá `fixedSize`/priority (`HangsButton.swift:68-77`), tak sa oreže práve on. SK stringy sú najdlhšie zo všetkých jazykov (Nahrávať / Písať / Preskočiť).
- **C1 ikony bez textu** (odporúčané): Písať a Preskočiť 56×56 ikonové tlačidlá s accessibility label; Nahrávať dostane ~2/3 šírky. Jazykovo nezávislé.
- C2 dva riadky; C3 „Nahrať“ + `minimumScaleFactor` na sekundárnych + `fixedSize` na pille (nutné aj pri C1/C2 ako poistka).
- Odpočet ostáva v tlačidle Nahrávať (#131 B). Testy: snapshot päty SK + CS.

## Track D — Pauza (výber A1/A2)

Mechanika dnes: stavový stroj bez `paused` (`QuizViewModel.swift:22-32`), X = alert (Pokračovať / Nastavenia / Ukončiť s výsledkami / Ukončiť), odpočty bežia aj za alertom (founder rozhodnutie, `QuestionView.swift:135-138`). Na výsledku existuje `currentQuestionPaused` + pill ZOSTAŤ/POKRAČOVAŤ (`ResultFooter.swift:64-93`), ale pozastavuje **iba auto-posun**, nie čítanie ani počúvanie, a nečíta sa ako pauza. Session sa po relaunchu neobnoví (backend TTL 30 min, `resumeSession()` = stub).
- **A1 pauza medzi otázkami** (odporúčané): pill ZOSTAŤ → „⏸ Pauza“ + povel „pauza“; pauzovaný stav = overlay na výsledku, stop čítania + poslucháča + auto-posunu; Pokračovať = ďalšia otázka; Ukončiť = existujúci `endQuizWithResults()`. Zovšeobecniť `currentQuestionPaused` na `isPaused` v `QuizTimersController`, teardown zdieľať so scene-phase `.background` cestou (`QuizViewModel+ScenePhase.swift:25-54`).
- A2 pauza kedykoľvek: + ikona ⏸ v navigácii, zmrazenie odpočtov (časovače sú `Task.sleep` slučky bez zostatku → každá potrebuje seed zostávajúcich sekúnd, `QuizTimersController.swift:104-291`), po Pokračovať otázku prečítať znova. Výnimka z #131 B. Väčšia práca, TTL 30 min stále platí.

## Track E — „Vyhodnocujem…“ cez celú obrazovku (výber B1/B2)

Dnes `processingRow` (`QuestionView.swift:715-726`) nahrádza pätu (voice) alebo sa vkladá nad lištu (MCQ, `:415-419`), stav `isProcessing` (`:732-734`). Žiadny generický overlay v appke neexistuje; najbližší vzor je `processingBody` potvrdzovacieho sheetu (`AnswerConfirmationView.swift:200-215`).
- Nový `HangsProcessingOverlay` (ZStack nad koreňom `QuestionView`, id `question.processingIndicator` zachovať — pinujú ho inspector testy a snapshoty), voice aj MCQ.
- **B1 karta nad rozmazanou otázkou** (odporúčané, kontext ostáva) / B2 plná obrazovka. Text: „Vyhodnocujem…“ + „Povedal si: „…““.

## Track F — Timer potvrdenia

Dnes 10 s pevne (`Config.swift:144`), iba on/off v nastaveniach (`QuizSettings.autoConfirmEnabled`). Ostatné časy pre koherenciu: premýšľanie 10 s (0–120), odpoveď 30 s (0–60), auto-posun výsledku 8 s (5/8/10/15), nahrávka max 15 s.
- Návrh: default **5 s** + `QuizSettings.autoConfirmDelay` s možnosťami 5/8/10 vedľa auto-posunu (rovnaký `sessionMenuRow`). Hodnota = rozhodnutie R1.

## Track G — Preklad „palácapalác“

Slovenčina ide **serve-time** cez `TranslationService` (`translator.py:51`, model `TRANSLATION_MODEL` default `claude-opus-5`), #168 (batch predpreklad) **nie je live**. Validácia kontroluje len prázdno/dĺžku (`:121-159, 276-322`) → duplikované slovo prejde a **uloží sa navždy** do cache (SQLite `TranslationStore`, verzia promptu 2) → tá istá chyba sa opakuje.
- Stopgap: detekcia zdvojeného slova/substringu vo `_validate_translation` + `_validate_payload` (fail → retry raz → fallback EN), test s „palácapalác“; purge cache riadku tejto otázky (alebo bump `TRANSLATION_PROMPT_VERSION`). Definitívne rieši #168.
- **DONE** (PR #88): deterministický guard na zdvojené/zlepené slovo v oboch validátoroch → retry → existujúci EN fallback; `TRANSLATION_PROMPT_VERSION` 2→3 (cache bust namiesto purge); 25 nových testov, 663 backend zelených. Nenasadené.

## Track H — Pozadie

Dnes (zámerne, otestované `ScenePhaseTeardownTests`): TTS dohrá (background audio mode), mikrofón + poslucháč sa vypnú, **odpočty bežia ďalej**; po návrate s vypršaným odpočtom zostane používateľ „zaparkovaný“ na otázke, lebo štart nahrávania je v pozadí potlačený (`RecordingCoordinator+Capture.swift:35-43`).
- Návrh (R3): nechať bežať (founder sklon: súperí sám so sebou) + pri návrate do popredia s vypršaným premýšľaním prejsť rovno na potvrdzovaciu obrazovku (Track B cesta „bez odpovede“), nie zaparkovať. Test: scene `.active` po vypršaní → `showAnswerConfirmation`.

## Track I — MCQ hlasom: potvrdenie + odpoveď textom možnosti

**Potvrdenie preskočené zámerne, ale rozhodnutie je sporné.** `RecordingCoordinator+Streaming.swift:126-143`: pri zhode s možnosťou sa volá `submitMCQAnswer` priamo („skipping the confirmation modal“), sheet ide len pri nezhode (`:145-153`). Pôvod = #45 task 45.3; founderom vyriešené D4 v tom istom issue (`issue-45…md:28`, task `45.7-wire`, nikdy nedodané) hovorí opak: MCQ → potvrdenie → výsledok. Konflikt je evidovaný ako „dve pravdy v kóde“ (`docs/artifacts/ui-review-2026-07.md:86`, audit 07-30 → #133). **Founder 2026-09-05 rozhodol: potvrdenie povinné aj pre MCQ.**

**Odpoveď textom možnosti už funguje**, ale iba presná zhoda po normalizácii (`MCQTranscriptMatcher.swift:47-71`, tier 1 = text možnosti pred písmenom/poradím; SK „áčko/béčko“, radové číslovky `:104-117`). Chýba tolerancia: skloňovanie („kocku“), STT varianty → nezhoda → sheet so surovým prepisom → backend MCQ evaluátor bez LLM záchrany vyhodnotí ako nesprávne (`evaluator.py:105-145`). Lišta hovorí len „Povedz A–D“ (`ListenBar.swift:199`); lepší string „Počúvam — povedz A–D alebo odpoveď“ už existuje nepoužitý (`Localizable.xcstrings:3421`).

**Fix:**
- I1 Zhoda hlasom → **nesubmitovať**, ale `transcribedAnswer = text možnosti` (nie surový prepis, inak backend nezhodnotí), `showAnswerConfirmation = true`, auto-potvrdenie beží; sheet dostane voliteľné `matchedOption` (písmeno + text) na zobrazenie „A · Kocka“. Potvrdenie ide existujúcou cestou `resubmitAnswer` → backend value-match (`evaluator.py:126-129`).
- I2 Tier 1.5 tolerantná zhoda na text možnosti (normalizovaný Levenshtein ≥ ~0.85 / spoločný kmeň), musí padnúť na práve jednu možnosť; inak sheet so surovým prepisom ako dnes.
- I3 Caption MCQ lišty → existujúci string „Povedz A–D alebo odpoveď“ (SK/CS/EN už preložené).
- Testy: prepísať 3 z `QuizViewModelMCQVoiceTests` (pinujú priamy submit), pridať tolerančné prípady do `MCQTranscriptMatcherTests` (skloňovanie SK), overiť `MCQOptionPickerRaceTests` (tap vs. hlas počas sheetu). RS-09 (hlasová zhoda MCQ) dnes končí priamym submitom → po I1 scenár aktualizovať na „zhoda → potvrdzovací sheet → potvrdiť → výsledok“ v `docs/testing/regression-scenarios.md`.
- Uzavrieť `45.7-wire` v #45 odkazom sem.

## Rozhodnutia (founder 2026-09-05, LOCKED)

- **Pauza = na potvrdzovacej obrazovke** (nie výsledok, nie navigácia). Potvrdzovací sheet je po Track B + I univerzálny bod „po odpovedi“, pauza tam zastaví auto-potvrdenie, čítanie aj počúvanie; Potvrdiť funguje ručne kedykoľvek, „Pokračovať“ znovu spustí 5 s odpočet. Interpretácia agenta: pauza = zmrazený sheet, nie samostatný overlay.
- **Timer potvrdenia = 5 s pevne**, bez nastavenia.
- **Prázdna nahrávka → potvrdzovacia obrazovka s prázdnym poľom**, auto-potvrdenie beží, vypršanie/potvrdenie prázdneho = bez odpovede.
- **Pozadie:** odpočty bežia ďalej. Návrat do popredia = urobiť to, čo malo nastať: ak vypršalo premýšľanie a okno odpovede ešte beží → **hneď spustiť nahrávanie**; ak vypršalo celé okno → potvrdzovacia obrazovka s prázdnym poľom.
- **MCQ hlasom → potvrdzovacia obrazovka** (Track I) + odpoveď textom možnosti s toleranciou + caption „Povedz A–D alebo odpoveď“.
- **Vyhodnocujem = B1** (polopriesvitná karta nad rozmazanou otázkou, nie plná obrazovka).
- **Päta = C1** (Písať/Preskočiť ikonou) — founder nevybral explicitne, ide odporúčaný variant; poistka z C3 (`fixedSize` na pille) tiež.

## Poradie implementácie (po výbere)

Paralelne (worktree per PR): PR-A Track A audio · PR-B Tracks B + I + F + H („každá odpoveď ide cez potvrdenie“, 5 s, návrat z pozadia) · PR-C Tracks C1 + E (päta ikony, overlay B1) · PR-G Track G backend + deploy + purge cache. Potom PR-D Track D pauza na sheete (po merge PR-B).

TF build až na požiadanie foundera po krokoch 1–3.

## Follow-ups (mimo #171)

- Session persistence / resume po relaunchi (odložené už v #132) — pauza dlhšia ako 30 min dnes stratí session.
- Earcony cez system sound = stlmené bočným prepínačom; ak má byť cue počuť vždy, presunúť na AVAudioPlayer.
