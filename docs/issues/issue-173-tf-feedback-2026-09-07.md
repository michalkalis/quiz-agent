# #173 — TF feedback 2026-09-07: mute pretrváva, hlavička MCQ, hlasitosť pri nahrávaní, dĺžka nahrávania, pauza+mute do toolbaru, vyhodnocujem v tlačidle, replay v MCQ, banner nad možnosťami

**Triage:** bug · ready-for-human (founder TF kontrola)
**Status:** IMPLEMENTOVANÉ 2026-09-08 — PR #112 docs · #114 UI (natívny toolbar, segmentový progress 1-based, pauza z toolbaru, vyhodnocujem v tlačidle, banner nad možnosťami s ✕, replay `arrow.counterclockwise`) · #113 audio/timery (mute per kvíz + jednorazové zmazanie starého uloženého mute, VPIO preč, 5 s odpočet od otvorenia mikrofónu, skrytá 15 s poistka). CI: 1099 iOS testov zelených. Open = founder TF kontrola (prvá otázka počuť, hlasitosť bez skoku, citlivosť povelov v aute, MCQ hlavička, pauza spod sheetu) · SK/CS znenie novej hlášky „Skryť lištu“ · Pencil sync hlavičky (odložené po TF potvrdení) · `swiftformat` nie je na tomto Macu (hook bol no-op, štýl ručne).
**Created:** 2026-09-07
**Founder round:** TestFlight, slovenský kvíz, iOS 26 (nadväzuje na #171 — TF feedback 2026-09-05)
**Varianty:** [`docs/design/variants/issue-173-tf-feedback-2026-09-07.html`](../design/variants/issue-173-tf-feedback-2026-09-07.html)
**Reversibility:** `a` — všetko iOS-side

## Founder nálezy → tracky

| # | Nález | Track | Diagnóza |
|---|---|---|---|
| 1a | Po štarte kvízu sa otázka neprečítala (alebo išla zo slúchadla) | A | **Potvrdené zo screenshotu:** mute bol ZAPNUTÝ (ružový `speaker.slash` v 20:41), `isMuted` sa ukladá do UserDefaults a prežije reštart appky. Otázka sa nečítala, lebo bola stlmená z predchádzajúceho testu. Route do slúchadla nepotvrdená: `.defaultToSpeaker` je na všetkých vetvách, `overrideOutputAudioPort` nikde. |
| 1b | Kategória sa prekrýva s tlačidlami feedback/hodnotenie (MCQ) | B | MCQ má vlastný zlúčený riadok `mcqTopRow` (QuestionView.swift:216-241) bez limitu šírky kategórie; chipy feedback/hodnotenie sú absolútny overlay (QuestionRatingEntry.swift:107-124) s pevným odsadením 96 pt. Otvorená otázka používa `HangsQuizTopBar` + samostatný `metaRow` (:265-290), preto tam prekryv nie je. MCQ hlavička nemá ozubené koliesko (zámerne, :212-215). |
| 1c | Progress bar = poradie otázky | B | Bar berie `questionsAnswered / total` (0-based), label `questionsAnswered + 1` (1-based) → pri „01 / 10“ je bar prázdny, pri poslednej otázke nikdy nie je plný. Rovnaké pre MCQ aj otvorené. Fix: bar = (index + 1) / total. |
| 2 | Hlasitosť sa zmení, keď vyprší premýšľanie a začne nahrávanie | A | **Potvrdené v kóde:** poslucháč povelov beží na engine s voice processing (VPIO + ducking iného audia, SilenceDetectionService+InputTap.swift:34-53); štart nahrávania ho zhodí (RecordingCoordinator+Capture.swift:127) a nahrávací engine ide bez VPIO → ducking hudby/systému skočí. Krok 3 z #171 — TF feedback 2026-09-05 (držať VPIO celý kvíz) nebol urobený. |
| 3 | „Nahrať znova“ má 14 s | C | Jediná konštanta `autoRecordingDuration = 15` (Config.swift:134), re-record ide tou istou cestou (RecordingCoordinator+Confirmation.swift:110-137 → RecordingCoordinator+Capture.swift:77). |
| 3b | Prvé nahrávanie tiež pridlhé, „bolo menej“ | C | Pôvodne 4 s (komentár v Config.swift:133: „Increased from 4s to 15s for Phase 2 silence detection“). 15 s je poistka na mŕtvy vzduch; pri reči ukončí nahrávanie ElevenLabs VAD 1,5 s po dohovorení. |
| 4 | Pauza preč zo sheetu, pauza + mute do toolbaru, ostatné pod ⋯ | B | Pauza existuje len na sheete (QuizViewModel+Pause.swift:24-60, guard `showAnswerConfirmation`). Hlavička je custom HStack, ale obrazovka je v `NavigationStack` (ContentView.swift:113) → natívny `.toolbar` je dostupný. HIG: len najdôležitejšie položky v lište, zvyšok v „More“ menu (glyph `ellipsis`), max ~3 skupiny. |
| 5 | Overlay „Vyhodnocujem“ škaredý → stav do tlačidla | D | Sheet sa zavrie synchrónne v `confirmAnswer()` (RecordingCoordinator+Confirmation.swift:25), potom `isProcessing` (QuestionView.swift:776-779) ukáže overlay. `HangsPrimaryButton` už má `isLoading`. HIG Progress indicators: spinner „next to a specific control, such as a button“; vzor App Store Get / Sign in with Apple. Sheet ostane hore, primárne tlačidlo = spinner + „Vyhodnocujem…“, ostatné disabled. |
| 6 | MCQ nemá ikonu prehrať otázku znova; ikona má byť „again“ | B | Zámerne vynechaná (QuestionView.swift:576-578, „vertical space is tight“), otvorené používa `speaker.wave.2.fill` (:392-398). Odporúčanie: `arrow.counterclockwise` (Apple = reštart/reload; `repeat` = loop režim; speaker koliduje s mute). |
| 7 | Banner „Premýšľaj“ nad možnosťami + zavrieť ✕ | B | V MCQ je pod gridom (QuestionView.swift:469-494), bez dismiss (ListenBar.swift:209-264). TipKit nevhodný (obsah sa mení každú sekundu). Návrh: banner nad gridom, ✕ vpravo, bez pamätania zavretia (per otázka). |

## Founder rozhodnutia (locked 2026-09-07 večer)

1. **Hlavička = A3 pre VŠETKY typy otázok** (MCQ, otvorené, obrázkové): natívny `.toolbar` — vľavo ✕, vpravo skupina [mute][pauza] + samostatný ⋯ (Nastavenia, Spätná väzba, Hodnotiť otázku). Pod lištou segmentový progress (10 dielikov, aktuálna otázka = vyplnená, 1-based), pod ním drobný mono riadok: kategória vľavo, „1/10“ vpravo.
2. **Banner = B1**, nad mriežkou možností, s ✕ vpravo, **menšia výška** (tesnejšie odsadenie, menšie písmo). Zavretie sa nepamätá (per otázka).
3. **Nahrávanie = 5 s na začatie reči** (prvé aj opakované): odpočet 5 s; prvý čiastočný prepis z ElevenLabs odpočet skryje a nahrávanie končí VAD-om (1,5 s ticha); skrytá poistka 15 s ostáva.
4. **Mute per kvíz**: ikona v kvíze stlmí len bežiaci kvíz (reset pri štarte kvízu); prepínač „Zvuk“ v Nastaveniach ostáva trvalý.
5. **VPIO vypnúť úplne** (žiadny ducking = žiadny skok); citlivosť povelov founder overí v aute.
6. Vyhodnocujem v tlačidle (C2), replay `arrow.counterclockwise` aj v MCQ, progress 1-based — bez výberu, potvrdené v zadaní.

**Agentov predpoklad (pauza mimo sheetu):** pauza z toolbaru zmrazí bežiace odpočty (premýšľanie / odpoveď / auto-potvrdenie) a zastaví TTS; počas aktívneho nahrávania nahrávanie ukončí a otvorí potvrdzovací sheet v pauze. Founder môže upraviť po TF teste.

## Tracky (po výbere)

- **A audio:** mute reset pri štarte kvízu; VPIO podľa rozhodnutia 5; test: prvá otázka počuť po reštarte appky s mute z minulého behu.
- **B hlavička/MCQ:** natívny `.toolbar` (spoločný pre MCQ aj otvorené), meta riadok/titulok podľa výberu, progress bar 1-based, replay `arrow.counterclockwise` aj v MCQ, ListenBar nad gridom s ✕, mute chip z `audioStrip` preč, pauza dostupná z toolbaru v každom stave (nie len na sheete).
- **C timery:** odpočet nahrávania podľa rozhodnutia 3, rovnaký pre prvé aj opakované nahrávanie.
- **D vyhodnocujem:** sheet ostáva počas `.processing`, primárne tlačidlo `isLoading`, ostatné disabled, `HangsProcessingOverlay` odstrániť z potvrdenej cesty (skip ostáva?).

## Overenie
- iOS unit testy (timery, pause z ľubovoľného stavu, progress 1-based), snapshot MCQ + otvorená hlavička, sim jazda RS s MCQ.
