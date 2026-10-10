# Research: Automatické meranie kvality rozpoznania reči na MacBooku

**Date:** 2026-10-10 | **Query:** Ako môže agent na MacBooku automaticky merať kvalitu prepisu odpovedí, s použitím foundrových nahrávok z auta. Pôvodný nápad: nahrávky púšťať nahlas z reproduktorov, súčasne nahrávať mikrofónom a posielať na prepis.

## Executive Summary

- **Odporúčanie: nahrávky posielať na prepis priamo ako súbor, nie cez reproduktor a mikrofón.** Akustika auta je už v nahrávke. Druhé prehranie cez reproduktor MacBooku pridá miestnosť, reproduktor a potlačenie ozveny, čiže šum, ktorý v aute nie je. Výsledky by sa medzi behmi líšili bez zmeny v appke.
- **Najväčšia medzera nie je harness, ale nahrávky.** Appka dnes zvuk odpovedí nikde neukladá. Treba spôsob, ako ich v aute zbierať (odporúčané: skrytý TestFlight prepínač „ukladaj moje odpovede").
- **Metrika = či by appka odpoveď uznala**, nie chybovosť slov. Pri 1–3 slovných odpovediach je WER (word error rate) príliš hrubá; jedna chyba = 100 %.
- **Overené na tomto Macu (macOS 26.7.1):** Apple `SpeechTranscriber` nemá sk ani cs (len en-*). `DictationTranscriber` a `SFSpeechRecognizer` majú sk-SK aj cs-CZ.

## Ako appka prepisuje dnes (recon)

| Cesta | Kde | Poznámka |
|---|---|---|
| ElevenLabs Scribe v2 Realtime (WebSocket, PCM 16 kHz) | `Services/ElevenLabsSTTService.swift`, voľba v `RecordingCoordinator+Capture.swift:94` | **Predvolená** pre odpovede; jazyk = jazyk kvízu |
| Záloha: M4A → backend `/voice/submit` → OpenAI `whisper-1` | `app/voice/transcriber.py:124` | Len keď streaming zlyhá |
| Apple on-device (`SpeechTranscriber` en / `DictationTranscriber` sk, cs) | `Services/CommandTranscriberAdapter.swift` | **Len hlasové povely**, nie odpovede |
| Vyhodnotenie odpovede | `app/evaluation/evaluator.py` (normalizovaná zhoda → LLM sudca), MCQ v `Utilities/MCQTranscriptMatcher.swift` | Toto je „pravda" pre metriku |

- Žiadne existujúce STT eval nástroje ani audio fixtures s reálnymi odpoveďami.
- Testovací HTTP listener (`UITestSupport.swift`, port 9999) vkladá **hotový text**, nie zvuk; skutočné rozpoznávanie obchádza.
- Súvisiace: `docs/issues/issue-05-slovak-transcription.md`.

## Možnosti

### A. Priamy prenos súboru (odporúčané, hlavná metrika)
- Agent pošle každú nahrávku tou istou cestou ako appka: Scribe Realtime WebSocket (PCM 16 kHz po kúskoch), prípadne Scribe batch API a whisper-1 na porovnanie.
- Apple engine sa dá volať z malého Swift CLI na Macu (súbor → `DictationTranscriber`); vzor: [yap](https://github.com/finnvoor/yap). Súbor nepotrebuje povolenie mikrofónu.
- Plusy: opakovateľné, rýchle, bez povolení, beží bez dozoru, ľahko porovná viac enginov a nastavení (jazyk, `keyterms`, kontext otázky).
- Mínus: obchádza mikrofón a detekciu ticha v appke. Rieši sa tým, že sa korpus nahrá priamo v appke jej vlastnou cestou (zvuk = presne to, čo išlo do Scribe).
- Scribe API: [convert](https://elevenlabs.io/docs/api-reference/speech-to-text/convert) (`language_code`, `keyterms` +20 % cena).

### B. Akustická slučka reproduktor → mikrofón (pôvodný nápad; neodporúčané ako hlavná metrika)
- Problémy: farbenie zvuku reproduktorom a miestnosťou, potlačenie ozveny môže prehrávaný zvuk vymazať, beh len v reálnom čase, povolenie mikrofónu pre terminál, rozptyl, ktorý sa nedá oddeliť od chyby prepisu.
- Digitálna verzia bez miestnosti: virtuálne zvukové zariadenie **BlackHole** ako vstup Simulátora (Device → Sound → Sound Input, [Apple doc](https://developer.apple.com/documentation/xcode/configuring-the-environment-of-a-simulated-device.md)). Otestuje celú appku vrátane detekcie ticha. **Neoverené end-to-end**; Simulator audio vstup býva nespoľahlivý ([forum](https://developer.apple.com/forums/thread/742572)).
- Použitie: občasný test „celej cesty" (napr. pred vydaním), nie meranie kvality.

### C. Celá appka na Macu („Designed for iPad")
- Projekt cieli na iPad, takže by mohol bežať na Apple Silicon Macu, ale nie je overené a Apple `SpeechTranscriber` v Simulátore nefunguje ([forum](https://developer.apple.com/forums/thread/802969)). Pre meranie odpovedí zbytočné, keďže odpovede idú cez ElevenLabs.

## Metriky

1. **Úspešnosť odpovede (hlavná):** prepis prejde skutočným vyhodnocovačom appky; porovná sa s verdiktom nad správnym (ručne overeným) prepisom. Výsledok: % odpovedí, kde prepis zmenil verdikt.
2. **Kľúčový výraz:** zachytil prepis meno/číslo/pojem (fuzzy zhoda).
3. **CER** (chybovosť znakov) ako diagnostika, cez [jiwer](https://github.com/jitsi/jiwer); počítať súhrnne za celý set, nie priemer na nahrávku ([zdroj](https://arxiv.org/pdf/2310.08225)).
4. **Tvrdé zlyhania:** prázdny prepis, zlý jazyk, oneskorenie, timeout.
- Normalizácia sk/cs: malé písmená, bez interpunkcie, čísla na slová; reportovať s diakritikou aj bez (veľa chýb je len chýbajúci háček).

## Korpus

- **Zber (odporúčané):** skrytý prepínač v TestFlight builde, ktorý pri každej odpovedi uloží zvuk poslaný do Scribe + prepis + otázku + správnu odpoveď + verdikt. Export cez zdieľanie súboru. Alternatíva bez kódu: Diktafón v aute, ale iná cesta mikrofónu než appka.
- **Ground truth:** agent predvyplní prepis enginom, ktorý sa netestuje; founder opraví len rozdiely.
- **Veľkosť:** ~100 nahrávok na jazyk na hrubé rozdiely, 150–300 na porovnanie dvoch enginov (±5 bodov; párový test McNemar). Pravidlo palca, neoverené zdrojom.
- **Podmienky:** označiť rýchlosť, okná, hudbu. Reálne nahrávky z auta majú prednosť pred umelým miešaním šumu ([audiomentations](https://github.com/iver56/audiomentations) ako doplnok pri 20/10/5 dB SNR).
- **Súkromie:** korpus v gitignorovanom priečinku; nahrávky s hlasmi iných ľudí vyradiť; Scribe/OpenAI zvuk dostanú (už dnes dostávajú).

## Existujúce nástroje
- [Open ASR Leaderboard](https://arxiv.org/abs/2510.06961v2) – prevziať normalizáciu a štruktúru, nie dáta (anglické).
- Nič hotové nepokrýva Apple engine ani náš vyhodnocovač → vlastný tenký harness (Python skript + voliteľné Swift CLI, výstup tabuľka po enginoch/jazykoch/podmienkach).

## Otvorené body na overenie pri stavbe
- Dá sa Scribe Realtime kŕmiť rýchlejšie než v reálnom čase (inak beh 200 nahrávok × ~4 s ≈ 15 min, stále OK).
- BlackHole → Simulátor naozaj doručí zvuk do appky (len ak sa robí možnosť B).
