# #184 — Odpovede: prepis po nahratí + lokálna detekcia ticha + prečítanie odpovede (hluk v aute)

**Triage:** bug · ready-for-human (kód všetkých trackov A–E hotový 2026-09-22, PR #182 MERGED, backend quiz-agent v117 v prode; open = TF build na požiadanie, test v aute + 30–50 vzoriek, `scripts/stt_compare.py`)

## Smer

Founder 09-21 po teste v aute (slovenčina): odpovede sa rozpoznávajú zle (treba kričať), povely fungujú len nahlas, auto-stop pri tichu občas nahrá slová aj po dohovorení. Wispr Flow v rovnakom aute prepisoval bez problémov. Požiadavky: **prejsť z realtime prepisu na prepis po nahratí**, **zachovať auto-stop pri tichu** (musí sa spoľahlivo zastaviť, keď dohovorím), **na confirm obrazovke prečítať rozpoznanú odpoveď**, a spresniť aj povely.

Research: [stt-car-noise-research-2026-09-21.md](../research/stt-car-noise-research-2026-09-21.md). Kľúčové závery:
- Dnešná pipeline posiela do ElevenLabs Scribe v2 **Realtime** úplne surový mikrofón (bez Apple echo cancellation / potlačenia šumu / AGC) a koniec odpovede určuje **serverová VAD** ElevenLabs (1,5 s). To vysvetľuje oba symptómy; Wispr Flow beží cez systémovú voice-processing pipeline.
- Najlepší kandidát na batch: **ElevenLabs Scribe v2 batch** (už máme účet + kvótovú bránu; publikované sk čísla; `keyterms` + per-slovo `logprob` na odstránenie cudzích slov na konci). A/B challenger: Azure MAI-Transcribe-2 (preview bez SLA). Dnešný fallback whisper-1 halucinuje na tichu → nahradiť `gpt-transcribe`.
- Lokálna detekcia ticha: Silero VAD v5 cez FluidAudio (CoreML), alebo spike iOS 26 `SpeechDetector` (už v kóde pre povely). Parametre: pre-roll 400–500 ms, koncové ticho 700–800 ms, min. reč 250 ms, max 15 s, brána 300–500 ms po TTS.
- Povely: nechať on-device (DictationTranscriber sk/cs + `contextualStrings`), pridať voice processing, n-best + Jaro-Winkler v matcheri, earcon začiatku/konca počúvania cez hlavnú audio trasu.

## Tracky

- **A – Mikrofónová pipeline (spoločné pre odpovede aj povely):** `.voiceChat` + `setVoiceProcessingEnabled(true)`, zistiť, či pri BT pripojení ide mikrofón cez HFP auta (Sentry log trasy vstupu); pri nahrávaní odpovede `setPreferredInput(builtInMic)`, 16 kHz mono PCM, brána po dohratí TTS. Overiť na zariadení, že AEC skutočne beží (mód `.default` ho potichu vypína) a že sa nezmenil počet kanálov. Sentry: štruktúrované logy trvania nahrávky, trasy vstupu, VP stavu (dnes len breadcrumby, nedajú sa dopytovať).
- **B – Lokálna detekcia ticha:** Silero VAD (FluidAudio) alebo `SpeechDetector` spike; ring buffer pre-roll; stavový stroj reč → ticho → stop; nahrať WAV do pamäte. Testy cez existujúci clock seam (#180), bez wall-clock časovačov. Meranie na 30–50 reálnych nahrávkach z auta: debug/TF prepínač „ukladať nahrávky odpovedí“ (lokálne, export cez Files; founder súhlasil 09-21), offline skript pošle vzorky do Scribe batch / Azure / dnešný realtime a porovná s ručným prepisom.
- **C – Batch prepis:** backend `/voice/submit` prepnúť z whisper-1 na Scribe v2 batch (jazyk kvízu, `keyterms` = texty MCQ možností + povelové slová, odfiltrovať koncové slová s nízkym `logprob`), fallback `gpt-transcribe`; iOS odpoveďová cesta = nahraj → pošli → confirm; realtime cesta ostáva za prepínačom na A/B kým sa neodmeria. Rozhodnúť: zavolať ElevenLabs priamo z iOS (ako dnes realtime) alebo cez backend (jednoduchšia rotácia kľúča a fallback; +1 hop latencia).
- **D – Prečítanie odpovede:** po prepise `POST /api/v1/tts/synthesize` (existuje, cache) → prehrať pri otvorení confirm sheetu, okno povelov zavreté počas prehrávania, potom brána. Len pri hlasovej odpovedi, nie pri MCQ tapnutí (founder 09-21; 09-13 čítanie MCQ výberu označil za zbytočné).
- **E – Povely:** n-best hypotézy + `max(Levenshtein, Jaro-Winkler)` + sk/cs fonetická normalizácia v `VoiceCommandMatcher`; overiť `supportsOnDeviceRecognition` pre sk-SK na zariadení; earcon začiatok/koniec okna cez hlavnú audio trasu (nie ringer). Po tracku A najprv zmerať, či samotné voice processing nestačí.

Poradie: A → B → C (merateľný prírastok: nahrávky z auta pred/po) → D → E. A je predpoklad pre všetko ostatné.

## Odpovede foundera (09-21)

- **Zapojenie:** Bluetooth k autu (zvuk z reproduktorov auta), telefón v držiaku na palubovke/vetraní (~40–70 cm od úst). Režim appky (Media/Call) neuvedený → v tracku A najprv z logov/nastavení zistiť, či išiel mikrofón cez HFP auta; ak áno, je to samostatná príčina.
- **Typ chýb:** všetky naraz — skomolené/iné slová, prázdna odpoveď alebo dlhé čakanie (poistka 5 s), nahrávanie sa neskončilo a pribralo cudzie slová, fungovalo len nahlas a veľmi zreteľne. Wispr Flow: hovoril normálne, „ako keby sa s niekým bavím v aute“.
- **Vzorky z auta:** ÁNO, appka môže v debug/TF builde dočasne ukladať nahrávky odpovedí (lokálne, export cez Files), cieľ 30–50 vzoriek → meranie kombinácií (voice processing on/off, VAD parametre, Scribe batch vs Azure vs dnešný realtime). Nahrávky nejdú do repa.
- **Čítanie odpovede:** len pri hlasovej odpovedi, nie pri MCQ tapnutí.
- **Triage:** needs-info → **ready-for-agent** po tomto bloku; produktové otázky zodpovedané.

## Stav 2026-09-22 — implementované (všetky tracky, jeden PR)

**Rozhodnutia pri implementácii (odchýlky od plánu, s dôvodom):**
- **Jeden mikrofónový engine.** Batch nahrávka odpovede už nebeží cez `AVAudioRecorder` popri engine poslucháča (dva klienti mikrofónu, nahrávka bez voice processing). Tap engine poslucháča (`SilenceDetectionService`) odbočuje tie isté 16-bit PCM vzorky, ktoré vidí VAD, do `AnswerCapture` → WAV → `/voice/submit`. Koniec reči určuje existujúci on-device `SpeechDetector` (nie nový Silero/FluidAudio — nová závislosť + model sťahovaný z HuggingFace za jazdy; ostáva ako záloha, ak SpeechDetector v aute nestačí). Keď engine nejde spustiť (zlyhanie rozpoznávača), nahráva starý `AVAudioRecorder` (bez VP, bez VAD) — tlačidlo mikrofónu funguje vždy.
- **Voice processing** (AEC/NS/AGC) späť po #173 — na OBOCH engine (poslucháč aj realtime), s najmenším duckingom (`.min`), pod runtime prepínačom. Režim session ostáva `.spokenAudio`: `.voiceChat` by zapol Bluetooth HFP a vrátil 8 kHz mikrofón auta (#104). Či AEC skutočne bežal, je v Sentry logu každej nahrávky (`voiceProcessing`, `inputPort`, `inputHz`).
- **`setPreferredInput(builtInMic)` NEUROBENÉ:** Media Mode už používa vstavaný mikrofón (#104), Call Mode je vedomá voľba BT mikrofónu (AirPods). Vynútiť telefón by Call Mode zrušilo. Trasa vstupu sa loguje → rozhodnúť po vzorkách z auta.
- **VAD parametre:** hangover 1,5 → 0,8 s, min. reč 0,3 → 0,25 s (`VADTuning`); rovnaké pre auto aj manuálne nahrávanie (parita s realtime server VAD).
- **Realtime cesta** ostáva za runtime prepínačom (default OFF), rovnako voice processing (default ON) a ukladanie vzoriek (default OFF) — Settings › „voice diagnostics" (len TF/debug), bez nového buildu na kombináciu.
- **Prečítanie odpovede** len z hlasovej cesty (streaming commit aj batch upload); MCQ ťuk a písaná odpoveď nie. Počas čítania je okno povelov zavreté; 5 s auto-potvrdenie a okno „ok/znova" sa spustia až po dohraní (mute = hneď).
- **Povely:** Jaro-Winkler len pre FINÁLNE prepisy a len pre skrátený začiatok slova (token kratší než variant so spoločným 2-znakovým prefixom) — plný `max(Lev, JW)` lámal 3 field-tuned guardy (#119 „skib"→skip, „nekst"→next; #175 české „no"→znovu). n-best (`.alternativeTranscriptions`) len na DictationTranscriber (sk/cs), finály. Earcony cez `AVAudioPlayer` na hlavnej trase (syntetizované tóny), systémový zvuk len fallback.
- **Backend:** Scribe v2 batch primár (`stt_provider=elevenlabs`), fallback `gpt-transcribe` (`stt_fallback_model`; `whisper-1` = plný rollback). Keyterms = texty MCQ možností (preložené, ak sú); otvorené otázky bez keyterms (správna odpoveď nesmie ovplyvniť rozpoznávanie). Koncové slová s `logprob < -1.0` odrezané (`stt_trailing_logprob_cutoff`, kalibrovať na vzorkách). Provider v INFO logu každého prepisu.

**Meranie:** `scripts/stt_compare.py <folder>` — WAV + sidecar JSON z exportu appky (+ ručný `<stamp>.ref.txt`) → WER Scribe / gpt-transcribe / prod prepis. Azure MAI-Transcribe-2 nezapojený (bez kľúča), realtime sa z súboru neprehrá (stĺpec `prod` = to, čo počul backend pri nahrávke).

**Neoverené (potrebuje zariadenie / auto):** skutočný stav AEC pod `.spokenAudio`; skok hlasitosti pri zapnutí VP (#173) — obe engine teraz rovnako; kalibrácia `logprob` cutoffu; či `gpt-transcribe` prijme `language`+`prompt` na multipart (SDK signatúra áno, živý hovor nie); `.alternativeTranscriptions` na sk-SK.

**Ďalší krok:** ~~merge PR → `fly deploy` quiz-agent~~ (hotové 2026-09-22, v117) → TF build na požiadanie → founder: zapnúť „Save answer recordings", 30–50 odpovedí v aute, export, `stt_compare.py`.

## Done-state

- Nahrávka odpovede končí do ~1 s po dohovorení v idúcom aute, bez cudzích slov na konci (overené na vzorkách z auta pred/po).
- WER na 30–50 sk vzorkách z auta: batch pipeline lepšia než dnešná realtime (číslo doplniť po meraní).
- Confirm sheet prečíta rozpoznanú odpoveď; povely fungujú pri bežnej hlasitosti reči.
