# Rozpoznávanie reči v aute (hluk, šum, reč v pozadí) — research 2026-09-21

**Podnet:** founder test v aute 09-20, slovenčina. Odpovede sa rozpoznávali zle (treba kričať), povely fungovali „ako tak“ len nahlas, detekcia ticha občas nahrávala slová aj po dohovorení. Wispr Flow (nahraj → prepíš na serveri) v tých istých podmienkach fungoval bez problémov. Founder chce: prejsť z realtime na prepis po nahratí, zachovať auto-stop pri tichu, na confirm obrazovke prečítať rozpoznanú odpoveď.

**Súvisiace:** `docs/issues/issue-184-batch-stt-car-noise.md` (plán) · #119 (kvalita povelov, mikrofón bez spracovania) · #120 (DictationTranscriber seam) · #104 (BT Media/Call režim) · `docs/research/issue-93-cost-model-2026-07-08.md` (ElevenLabs = STT).

## 1. Čo appka robí dnes (recon kódu)

| Cesta | Engine | Ukončenie nahrávania | Spracovanie mikrofónu |
|---|---|---|---|
| **Odpovede** | ElevenLabs **Scribe v2 Realtime** (WebSocket, 16 kHz PCM po 250 ms) | **serverová VAD ElevenLabs** (`commit_strategy=vad`, ticho 1,5 s); watchdog 5 s bez commitu → prázdna odpoveď; ElevenLabs sám po 15 s ticha vráti prázdny commit | **žiadne** (bez `setVoiceProcessingEnabled`, bez AGC/NS), mód `.spokenAudio` |
| Odpovede – fallback | OpenAI **whisper-1** batch (m4a cez `/voice/submit`), len keď ElevenLabs token zlyhá (kvóta, sieť) | ? (batch cesta, nie je v hlavnom toku) | rovnako |
| **Povely** | Apple on-device: `DictationTranscriber` sk-SK/cs-CZ (SpeechTranscriber nemá slovanské jazyky, `contextualStrings` ignoruje) + `SpeechDetector` VAD `.low`, hangover 1,5 s | lokálny stavový stroj (VADTuning.swift, hodnoty označené „provizórne, nikdy neoverené v aute“) | rovnako |
| Confirm obrazovka | text v editovateľnom poli, **bez prečítania nahlas** | povely ok/again/stop | – |

Kľúčové zistenia:
- **Nahrávka ide do ElevenLabs úplne surová.** Apple echo cancellation, potlačenie šumu a AGC sú vypnuté. To je jediný veľký rozdiel oproti Wispr Flow (tá používa systémovú audio pipeline s voice processing). Vysvetľuje „musím hovoriť nahlas“ = Lombardov efekt (človek v hluku kričí → posun formantov → ASR degraduje viac než samotný hluk; literatúra: 4–17 % abs. WER, pri 10 dB SNR až 32–38 %).
- **Ukončenie odpovede riadi server (ElevenLabs VAD), nie appka.** Pri hluku v aute serverová VAD nevie, čo je hluk auta a čo reč → „nahráva slová aj po dohovorení“. Po prechode na batch musí ticho detegovať appka lokálne.
- **Realtime vs batch Scribe:** realtime je odvodený model optimalizovaný na latenciu; batch v2 má k dispozícii celý klip, podporuje pauzy, `keyterms` (do 1000), per-slovo `logprob` a `audio_event` (nereč). Batch je presnejší pri rovnakej cene ($0,22/h vs $0,39/h).
- Sentry (7 dní): fallback na whisper-1 nastal 3× (09-14, 09-15, 09-20 15:05, dôvod `streaming_setup_failed`). Test 09-20 mal 2 bloky (09:49–10:06, 15:03–15:12). Trvanie nahrávok ani konfidencie sa zo Sentry vyčítať nedajú (breadcrumby, nie logy) — pri implementácii doplniť štruktúrované logy.

## 2. STT služby pre krátke slovenské odpovede v hluku

Nezávislý benchmark pre slovenčinu neexistuje (Open ASR multilingual = de/fr/it/es/pt; Artificial Analysis AA-WER = angličtina). Čísla pre sk sú od vendorov. **Pred záväzkom overiť na 30–50 vlastných nahrávkach z auta.**

| Služba (batch) | Slovenčina | Hluk (nezávisle) | Latencia 3 s klip | Cena | Biasing | Konfidencia/slovo |
|---|---|---|---|---|---|---|
| **ElevenLabs Scribe v2** | tier „Excellent“ (≤5 % WER); vendor: FLEURS sk 3,4 %, CV 5,5 % (Whisper-v3 13,2 %) | AA-WER 2,2 % (#4/61) | ~0,5–1 s e2e (odhad) | $0,22/h (+$0,05/h keyterms) | `keyterms` ≤1000 | **áno** (`logprob`) + `audio_event` |
| **Azure MAI-Transcribe-2** | sk+cs v tabuľke 60 jazykov | AA-WER 2,0 % (#3); docs: hluk + prekrývajúca reč | nepublikované | $0,10/h promo do 12/2026 | `phraseList` | neoverené; **public preview bez SLA** |
| OpenAI `gpt-transcribe` (07/2026) | Whisper rodina, sk WER nepublikované | AA-WER 3,3 % | ~0,6–1,2 s | $0,27/h | `prompt` + `keywords` (prompt pre ne-EN merateľne slabý, arXiv 2406.05806) | **nie** |
| Deepgram Nova-3 | sk+cs pridané 12/2025, WER nepublikované | AA-WER 5,2 % (najslabší z top) | ~0,3–0,6 s (najrýchlejší) | $0,26/h | `keyterm` (sk podpora neoverená) | áno |
| Speechmatics | oficiálne sk+cs stránky | AA-WER 4,9 % | nepubl. | ~$0,30–0,50/h | `additional_vocab` | áno |
| Google Chirp 2/3 | sk-SK podporované, **jediný vendor s dokumentovaným model adaptation pre sk**; vývojári hlásia slabú sk/cs kvalitu | AA-WER 4,3 % | nepubl. | $0,96/h štd | `PhraseSet` boost | nie (Google: „nie je skutočná konfidencia“) |
| whisper-1 (dnešný fallback) | 99 jazykov | **halucinuje na tichu / krátkych klipoch** („thank you for watching“) | – | $0,36/h | prompt 224 tok | nie |
| Gladia, AssemblyAI U-3, Voxtral, Picovoice, Vosk, Apple SpeechTranscriber | bez sk alebo bez sk zisku | – | – | – | – | – |

**Kandidáti:** 1) **ElevenLabs Scribe v2 batch** (už máme účet, kľúč, kvótovú bránu; sk publikované; keyterms + logprob riešia presne „cudzie slová na konci“). 2) **Azure MAI-Transcribe-2** ako A/B challenger (lepšie nezávislé skóre, lacnejší, ale preview bez SLA, trvalá cena neznáma). Fallback whisper-1 nahradiť `gpt-transcribe` (halucinácie na tichu preč, `keywords`).

## 3. Zachytenie zvuku v aute (iOS)

- **Zapnúť Apple voice processing**: `AVAudioSession` mód `.voiceChat` + `inputNode.setVoiceProcessingEnabled(true)` = AEC + NS + AGC ladené per zariadenie. Odstráni aj vlastné TTS z nahrávky (otázka hrá z reproduktorov auta). Pozor: `.default` mód AEC potichu vypne; playback graf pripojiť pred zapnutím; môže zmeniť počet kanálov. Priamy A/B (VP on/off vs cloud WER) nikto nezmeral → **zmerať na vlastných nahrávkach**. Poznámka: #119 to označil ako známu medzeru, no v kóde stále chýba (pamäť z 07/26 tvrdila „shipped“ — neplatí).
- **Bluetooth mikrofón auta = najhorší vstup** (HFP 8/16 kHz úzkopásmový). Media režim už HFP nepovoľuje (dobre), Call režim áno → v Call režime pri nahrávaní odpovede zvážiť `setPreferredInput(builtInMic)`. CarPlay: podľa dev reportov s `.default` ide vstup cez mikrofón auta, mód to mení (neoverené primárnym zdrojom).
- **`.measurement` NIE** (vypína systémové spracovanie; tutoriály ho radia, ale v hluku škodí). Formát 16 kHz mono PCM16/WAV, neupsamplovať, **nerobiť vlastnú redukciu šumu** (Google: typicky zhoršuje presnosť).
- Smerový mikrofón: `setPreferredPolarPattern(.subcardioid)` na prednom data source — plausibilné, neoverené v aute.
- **Zvukové signály začiatku a konca počúvania** sú v Alexa Auto povinné, nie nice-to-have; haptika/earcon na ringer trase je v aute nepočuteľná (známe z #119) → earcon cez hlavnú audio trasu.

## 4. Lokálna detekcia ticha (koniec odpovede)

- **Silero VAD v5** (MIT, ~1 ms/chunk, 32 ms okná @16 kHz) cez **FluidAudio** (Apache-2.0, CoreML/ANE, iOS 17+, SPM) = najlepšie udržiavaná Swift cesta. RMS prah s adaptívnym šumovým dnom v aute zlyháva (hukot 100–500 Hz prekrýva F0 mužského hlasu, hudba/spolujazdec nestacionárne); WebRTC VAD ~21 % chýb vs ~14 % malá DNN. Picovoice Cobra má najlepšie (vlastné) čísla, ale free tier 3 užívatelia/mesiac → nie.
- **iOS 26 `SpeechDetector`** (už v kóde pre povely) nie je viazaný na lokálnu tabuľku → spike ako bezzávislostná alternatíva; správanie pri sk audiu neoverené. Dnešné hodnoty (`.low`, hangover 1,5 s) sú výslovne „nikdy neladené v aute“.
- **Východiskové parametre** (OpenAI server_vad 300/500 ms, LiveKit 500/550, Pipecat 500/250): pre-roll ring buffer **400–500 ms** (aby prežila prvá slabika), koncové ticho **700–800 ms** (horná hranica pre hluk + slovenské pauzy; dnes 1,5 s = pomalé a zbiera cudzie slová), min. reč 250 ms, max 15 s, **300–500 ms brána po dohratí TTS** (dozvuk AEC; 800 ms pri BT).
- **Radšej poslať o kúsok dlhší klip než odseknúť koniec** — moderné batch modely (Scribe v2, gpt-transcribe) zvládajú ticho na konci; whisper-1 nie. Cudzie slová na konci filtrovať cez per-slovo `logprob` (Scribe) – to je skutočná obrana, nie serverová VAD. Diarizácia (spolujazdec) na 1–5 s klipoch pravdepodobne nespoľahlivá — netestovať v prvej iterácii.

## 5. Hlasové povely (presnosť v hluku)

- **Nechať on-device** — cloud round-trip nikdy nebude „okamžitý“; jediný vendor s dokumentovaným sk biasingom je Google (a hlásená slabá sk kvalita).
- **DictationTranscriber je jediná Apple cesta so sk/cs + biasing** (`contextualStrings` ≤~100 fráz, `setContext` nahrádza, nie zlučuje; `ContentHint.shortForm + .farField`). Overiť na zariadení, či sk sk-SK beží on-device (`supportsOnDeviceRecognition`), Apple tabuľku nepublikuje. Biasing malým zoznamom = ideálny prípad (literatúra ~40 % rel. WER zlepšenie pri 100 frázach).
- **Voice processing (bod 3) pomôže povelom rovnako ako odpovediam** — dnes ich transcriber počúva surový hluk + vlastné TTS.
- **Matching:** existujúci dizajn (gramatika per obrazovka, Levenshtein, prahy, filler slová) je správny; rozšíriť o **n-best hypotézy** (Alexa štúdia: +34 % recall, +16 % F1, FP 1→4 %), `max(Levenshtein, Jaro-Winkler)` (JW chytí useknuté začiatky „…skoč“), ručná sk/cs fonetická normalizácia nad 7 povelmi (Double Metaphone je anglocentrický). Žiadny živý LLM na tejto ceste.
- Slepé uličky pre sk/cs: Picovoice Porcupine/Rhino/Cheetah, Sensory, Vosk (sk model neexistuje, cs 21 % WER), Whisper tiny/base on-device, openWakeWord (len 1 fráza, DIY ONNX).
- UX: implicitné potvrdenie (akcia + earcon) pre bezpečné povely, explicitné len pre deštruktívne (už máme); PTT tlačidlo rovnocenná cesta, nie fallback; **netrénovať používateľa kričať** — problém je model/pipeline.

## 6. Prečítanie odpovede na confirm obrazovke

Backend už má generický endpoint `POST /api/v1/tts/synthesize` (text ≤1000 znakov, cache) a iOS klient `synthesizeSpeech(text:)` (použité pre recap). Stačí zavolať po prijatí prepisu a prehrať pred otvorením/pri otvorení sheetu; počas prehrávania držať okno povelov zavreté (TTS single-flight pravidlo z #178), po dohratí brána 300–500 ms.

## Zdroje (výber)

Apple: [SpeechTranscriber locales](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales) · [DictationTranscriber ContentHint](https://developer.apple.com/documentation/speech/dictationtranscriber/contenthint) · [DTS: contextualStrings ignored](https://developer.apple.com/forums/thread/801877) · [setVoiceProcessingEnabled](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/setvoiceprocessingenabled(_:)) · [allowBluetoothHFP](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp) · [QA1799 preferred input](https://developer.apple.com/library/archive/qa/qa1799/_index.html) · [.default mode kills AEC](https://barock.dev/2026/04/22/why-your-ios-voice-agent-still-hears-itself)
STT: [Scribe v2](https://elevenlabs.io/blog/introducing-scribe-v2) · [Scribe keyterms](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting) · [Scribe Slovak](https://elevenlabs.io/speech-to-text/slovak) · [Artificial Analysis STT](https://artificialanalysis.ai/speech-to-text/non-streaming) · [Azure MAI-Transcribe-2](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe) · [OpenAI STT guide](https://developers.openai.com/api/docs/guides/speech-to-text) · [whisper-1 hallucinations](https://github.com/openai/whisper/discussions/1606) · [Deepgram Nova-3 sk/cs](https://deepgram.com/learn/deepgram-expands-nova-3-with-11-new-languages-across-europe-and-asia) · [Google adaptation langs](https://docs.cloud.google.com/speech-to-text/docs/speech-to-text-supported-languages) · [Google audio best practices](https://docs.cloud.google.com/speech-to-text/docs/v1/best-practices-provide-speech-data)
VAD: [Silero VAD](https://github.com/snakers4/silero-vad) · [FluidAudio](https://github.com/FluidInference/FluidAudio) · [VAD comparison CS230](http://cs230.stanford.edu/projects_winter_2020/reports/32224732.pdf) · [Picovoice free tier](https://picovoice.ai/blog/introducing-picovoices-free-tier/)
Povely/UX: [Alexa n-best matching](https://arxiv.org/html/2501.06129v1) · [Contextual biasing](https://arxiv.org/pdf/2305.12493) · [Grammar augmentation](https://arxiv.org/pdf/1811.06096) · [Lombard effect & ASR](https://www.sciencedirect.com/science/article/pii/S0167639317302674) · [Alexa Auto invoking](https://developer.amazon.com/en-US/docs/alexa/alexa-auto/invoking-alexa.html) · [Picovoice languages](https://picovoice.ai/docs/faq/porcupine/) · [Vosk models](https://alphacephei.com/vosk/models)
