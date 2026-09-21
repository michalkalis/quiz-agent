# #184 — Odpovede: prepis po nahratí + lokálna detekcia ticha + prečítanie odpovede (hluk v aute)

**Triage:** bug/enhancement · needs-info (čaká na odpovede foundera k testu 09-20 a na výber trackov)

## Smer

Founder 09-21 po teste v aute (slovenčina): odpovede sa rozpoznávajú zle (treba kričať), povely fungujú len nahlas, auto-stop pri tichu občas nahrá slová aj po dohovorení. Wispr Flow v rovnakom aute prepisoval bez problémov. Požiadavky: **prejsť z realtime prepisu na prepis po nahratí**, **zachovať auto-stop pri tichu** (musí sa spoľahlivo zastaviť, keď dohovorím), **na confirm obrazovke prečítať rozpoznanú odpoveď**, a spresniť aj povely.

Research: [stt-car-noise-research-2026-09-21.md](../research/stt-car-noise-research-2026-09-21.md). Kľúčové závery:
- Dnešná pipeline posiela do ElevenLabs Scribe v2 **Realtime** úplne surový mikrofón (bez Apple echo cancellation / potlačenia šumu / AGC) a koniec odpovede určuje **serverová VAD** ElevenLabs (1,5 s). To vysvetľuje oba symptómy; Wispr Flow beží cez systémovú voice-processing pipeline.
- Najlepší kandidát na batch: **ElevenLabs Scribe v2 batch** (už máme účet + kvótovú bránu; publikované sk čísla; `keyterms` + per-slovo `logprob` na odstránenie cudzích slov na konci). A/B challenger: Azure MAI-Transcribe-2 (preview bez SLA). Dnešný fallback whisper-1 halucinuje na tichu → nahradiť `gpt-transcribe`.
- Lokálna detekcia ticha: Silero VAD v5 cez FluidAudio (CoreML), alebo spike iOS 26 `SpeechDetector` (už v kóde pre povely). Parametre: pre-roll 400–500 ms, koncové ticho 700–800 ms, min. reč 250 ms, max 15 s, brána 300–500 ms po TTS.
- Povely: nechať on-device (DictationTranscriber sk/cs + `contextualStrings`), pridať voice processing, n-best + Jaro-Winkler v matcheri, earcon začiatku/konca počúvania cez hlavnú audio trasu.

## Tracky

- **A – Mikrofónová pipeline (spoločné pre odpovede aj povely):** `.voiceChat` + `setVoiceProcessingEnabled(true)`, v Call režime `setPreferredInput(builtInMic)` pri nahrávaní odpovede, 16 kHz mono PCM, brána po dohratí TTS. Overiť na zariadení, že AEC skutočne beží (mód `.default` ho potichu vypína) a že sa nezmenil počet kanálov. Sentry: štruktúrované logy trvania nahrávky, trasy vstupu, VP stavu (dnes len breadcrumby, nedajú sa dopytovať).
- **B – Lokálna detekcia ticha:** Silero VAD (FluidAudio) alebo `SpeechDetector` spike; ring buffer pre-roll; stavový stroj reč → ticho → stop; nahrať WAV do pamäte. Testy cez existujúci clock seam (#180), bez wall-clock časovačov. Meranie na 30–50 reálnych nahrávkach z auta (founder nahrá počas jazdy; appka môže klipy dočasne ukladať v debug builde).
- **C – Batch prepis:** backend `/voice/submit` prepnúť z whisper-1 na Scribe v2 batch (jazyk kvízu, `keyterms` = texty MCQ možností + povelové slová, odfiltrovať koncové slová s nízkym `logprob`), fallback `gpt-transcribe`; iOS odpoveďová cesta = nahraj → pošli → confirm; realtime cesta ostáva za prepínačom na A/B kým sa neodmeria. Rozhodnúť: zavolať ElevenLabs priamo z iOS (ako dnes realtime) alebo cez backend (jednoduchšia rotácia kľúča a fallback; +1 hop latencia).
- **D – Prečítanie odpovede:** po prepise `POST /api/v1/tts/synthesize` (existuje, cache) → prehrať pri otvorení confirm sheetu, okno povelov zavreté počas prehrávania, potom brána. Produktová otázka: čítať vždy, alebo len pri hlasovej odpovedi (MCQ tap nie — founder 09-13 označil čítanie MCQ výberu za zbytočné).
- **E – Povely:** n-best hypotézy + `max(Levenshtein, Jaro-Winkler)` + sk/cs fonetická normalizácia v `VoiceCommandMatcher`; overiť `supportsOnDeviceRecognition` pre sk-SK na zariadení; earcon začiatok/koniec okna cez hlavnú audio trasu (nie ringer). Po tracku A najprv zmerať, či samotné voice processing nestačí.

Poradie: A → B → C (merateľný prírastok: nahrávky z auta pred/po) → D → E. A je predpoklad pre všetko ostatné.

## Otvorené otázky pre foundera (09-21)

1. Test 09-20: telefón v držiaku alebo v ruke / na sedadle? Vzdialenosť od úst? Bol pripojený Bluetooth alebo CarPlay (a ktorý režim v appke: Media/Call)?
2. Zlé rozpoznanie = úplne iné slová, alebo prázdna/oneskorená odpoveď (watchdog 5 s → prázdny sheet)?
3. Wispr Flow test: v tom istom aute počas jazdy, s tou istou hlasitosťou reči a hlukom (rádio, spolujazdci)?
4. Nahrávanie klipov z auta na meranie: súhlas s dočasným debug ukladaním nahrávok odpovedí do appky (lokálne, export cez Files) na 30–50 vzoriek?
5. Prečítanie odpovede: len pri hlasovej odpovedi, alebo aj pri MCQ tapnutí?

## Done-state

- Nahrávka odpovede končí do ~1 s po dohovorení v idúcom aute, bez cudzích slov na konci (overené na vzorkách z auta pred/po).
- WER na 30–50 sk vzorkách z auta: batch pipeline lepšia než dnešná realtime (číslo doplniť po meraní).
- Confirm sheet prečíta rozpoznanú odpoveď; povely fungujú pri bežnej hlasitosti reči.
