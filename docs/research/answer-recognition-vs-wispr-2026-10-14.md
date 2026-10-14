# Rozpoznávanie odpovedí vs. Wispr Flow — rešerš 2026-10-14

**Otázka foundera:** rozpoznávanie odpovedí (nie povelov) pôsobí horšie ako klávesnica Wispr Flow. Čo sa dá ešte zlepšiť?
**Plán:** [#204 — Spoľahlivejšie rozpoznanie hlasovej odpovede](../issues/issue-204-answer-recognition.md)
**Predchádzajúce:** [stt-car-noise 09-21](stt-car-noise-research-2026-09-21.md) · [stt-eval-harness 10-10](stt-eval-harness-2026-10-10.md)

Značky: [V] overené na zdroji · [S] len z výsledku vyhľadávania · [U] neoverené / náš úsudok.

## Dnešný stav (origin/main 2026-10-14)

- Odpoveď = WAV z appky → backend → ElevenLabs **Scribe v2 batch**, `language_code` = jazyk relácie; `keyterms` len pri MCQ (texty možností + slová označení). Otvorené otázky bez nápovedy zámerne (aby recognizer „nepočul“ správnu odpoveď). Záloha `gpt-transcribe` s promptom. Prod nemá `STT_*` override (defaulty).
- Koniec odpovede: **lokálna energetická VAD** (kalibrácia šumu 0,3 s, +7 dB, dobeh 0,8 s, strop 8 s). Sentry 10-10: 7 zo 40 odpovedí došlo do stropu, 4 z nich mali 9,5–14,7 s „reči“ = hluk auta braný ako hlas.
- Mikrofón na A2DP/CarPlay **bez voice processing** (žiadne AEC/NS/AGC), lebo VP stiahlo zvuk z autorádia (#185). Úprava zvuku pred odoslaním (high-pass + normalizácia) je vypnutá.
- Vyhodnotenie: presná zhoda (diakritika sa nezahadzuje) → alternatívy → MCQ párovač → „znie ako“ (len pravopisné varianty / jedna samohláska) → Haiku 5.5 sudca s otázkou + správnou odpoveďou.
- **Chyba zálohy:** posielame `language`, ale pre `gpt-transcribe` ho nahradilo `languages` (pole) — „Don't send both fields“, zlé kódy API odmieta [V] https://developers.openai.com/api/docs/guides/speech-to-text. Záloha tiež nedostáva `keywords`.

## Prečo pôsobí Wispr Flow lepšie

- Cloud ASR (model nezverejnený [U]) + **doladený Llama prepis** s kontextom používateľa a appky, cieľ ~700 ms od konca reči [V] https://wisprflow.ai/post/technical-challenges · https://www.baseten.co/resources/customers/wispr-flow/
- **Koniec reči určuje človek** (podrž / ťukni), žiadna energetická VAD [S] https://sidsaladi.substack.com/p/wispr-flow-101-the-complete-guide
- Učenie z opráv („never makes the same mistake twice“) je ich **plán**, nie potvrdená funkcia [V] technical-challenges.
- Žiadne čísla presnosti ani nič o sk/cs [U].

## Zachytenie zvuku a koniec reči

- **Odšumenie pred STT škodí:** MetricGAN+ zvýšil WER v 40/40 nastaveniach, Whisper najcitlivejší [S] https://arxiv.org/abs/2512.17562 · SAM-Audio pred Whisperom 10,5 → 21,7 % [S] https://arxiv.org/abs/2603.04710. Prínos tvrdia len predajcovia (Krisp). → posielať surový zvuk, čistiť najviac pre rozhodnutie VAD.
- **Silero VAD v6** (neurónový hlas vs. hluk): FluidAudio CoreML, iOS 17+, okno 256 ms [S] https://docs.fluidinference.com/vad/getting-started.md; CoreML export ~640 kB, okno 32 ms [S] https://huggingface.co/aufklarer/Silero-VAD-v6.2.1-CoreML. Model sa dá **pribaliť do appky** (09-21 odmietnuté len kvôli sťahovaniu počas jazdy).
- Apple `SpeechDetector` stále nie je `SpeechModule`, oprava sľúbená, nepotvrdená [S] https://developer.apple.com/forums/thread/797544 → nespoliehať sa.
- Sémantické ukončenie (Pipecat Smart Turn v3.2, ~8 MB) — anglické, na 1–5 slov zbytočné [S] https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/
- **`setPrefersEchoCancelledInput`** (iOS 18.2+): AEC bez VP jednotky, len `.playAndRecord` + **default mode** (nie `.spokenAudio`), len novšie iPhony, overiť `isEchoCancelledInputEnabled` [S] https://github.com/dotnet/macios/wiki/AVFAudio-iOS-xcode16.2-b3. Či ostane A2DP výstup [U] → test v aute. Rieši len ozvenu vlastného TTS, nie hluk cesty.
- Voice Isolation si appka nevynúti, len otvorí systémový výber [S] https://developer.apple.com/forums/thread/844448
- Predný mikrofón + kardioida cez `setPreferredDataSource` / `setPreferredPolarPattern` [V] https://developer.apple.com/library/ios/qa/qa1799/_index.html — správanie pri A2DP [U].

## Rozpoznávacie služby (sk/cs)

| Služba | sk/cs | Nápoveda | Cena | Poznámka |
|---|---|---|---|---|
| ElevenLabs Scribe v2 | áno | `keyterms` ≤ 1000, +20 %; >100 termov = min. 20 s účtovania | ~$0,22/h + | vlastné FLEURS sk ~3,4 %, cs ~3,5 %; Common Voice sk 12,9 % [V/S] |
| Soniox v5 async | áno | `context` (general/text/terms) | ~$0,10/h | vlastný sk test: Soniox 8,5 % vs ElevenLabs 10,8 % [S, predajca] |
| OpenAI gpt-transcribe | sk/cs neoverené | `prompt` + `keywords` + `languages` | $0,0045/min | sk/cs WER nezverejnené |
| Deepgram Nova-3 | uvedené | keyterms | — | slabý v cudzích testoch (sk 23,6 %) |
| AssemblyAI, Voxtral | nie | — | — | vyradené |

Zdroje: https://elevenlabs.io/docs/api-reference/speech-to-text/convert · https://soniox.com/docs/stt/concepts/context · https://soniox.com/media/SonioxSTTBenchmarks2025.pdf · https://developers.openai.com/api/docs/guides/speech-to-text
- Scribe nemá `prompt` ani n-best; vracia `logprob` po slovách, má `temperature` a `seed` [V]. Žiadny Scribe v3 do 10/2026 [S].
- Krátky klip = málo dát na detekciu jazyka → **jazyk nechať pripnutý**, otestovať na vlastných klipoch [U].

## Vyhodnotenie, keď poznáme správnu odpoveď

- Nápoveda len so správnou odpoveďou tlačí recognizer ju „počuť“ [U]; štandardná obrana = pridať podobne znejúce nesprávne odpovede (hard negatives) [S] https://arxiv.org/pdf/2304.08862 · https://arxiv.org/pdf/2512.21828. Čísla falošného uznania pre náš prípad neexistujú → merať.
- LLM oprava prepisu pomáha (HyPoradise, GenSEC) [S] https://arxiv.org/pdf/2309.15701, ale bez brzdy „prepravuje“ čisté prepisy → spúšťať len pri nízkej istote [S] https://arxiv.org/html/2407.21414v1
- Audio-LLM, ktorému povieme správnu odpoveď, ju má sklon „počuť“ (text prebije zvuk) [S] https://arxiv.org/html/2602.11488v1 → nanajvýš druhý názor naslepo.
- Fonetické porovnanie: Double Metaphone je anglický; pre sk/cs vlastné pravidlá (i/y, ch/h, znelosť, sh→š, w→v, ph→f) ako ďalšia úroveň, nie náhrada presnej zhody [U]. Zahodenie diakritiky len ako nižšia úroveň (pas/pás).
- Alexa: kanonická hodnota + synonymá na úrovni dát [S] https://developer.amazon.com/docs/custom-skills/entity-resolution-for-custom-slot-types.html → výslovnostné varianty generovať pri tvorbe otázky.
- Metrika = **správnosť verdiktu** (falošné zamietnutie / falošné uznanie po jazykoch), nie WER; ≥ 100 zámerne nesprávnych podobných odpovedí ako negatívy [U].

## Čo nerobiť

Apple STT na odpovede (SpeechTranscriber nemá sk/cs) · odšumenie pred STT · audio-LLM so správnou odpoveďou v prompte · ladiť energetickú VAD naslepo po tretí raz.
