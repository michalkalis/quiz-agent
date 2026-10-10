# Research: Automatické meranie rozpoznania odpovedí a detekcie ticha na MacBooku

**Date:** 2026-10-10 | **Query:** Ako môže agent na MacBooku automaticky merať kvalitu prepisu odpovedí na founderových nahrávkach z auta (pôvodný nápad: púšťať ich nahlas z reproduktorov a súčasne nahrávať). Doplnok: detekcia ticha „je príliš citlivá a nerozpozná, kedy som prestal hovoriť“.
**Nadväzuje na:** `docs/issues/issue-197-voice-replay-corpus.md` (zber nahrávok + replay testy), #184/#185 (detekcia ticha, Scribe v2 batch).

## Executive Summary

- **Nahrávky posielať do prepisu priamo ako súbor, nie cez reproduktor a mikrofón.** Akustika auta je už v nahrávke; druhé prehratie pridá miestnosť, reproduktor a potlačenie ozveny MacBooku, čo v aute nie je, a výsledky by kolísali bez zmeny v appke. Toto je smer #197.4.
- **Detekcia ticha sa dá testovať na tých istých nahrávkach**, lebo je to čistý výpočet nad zvukom. Agent pustí WAV detektorom (Swift test na Macu) a porovná, kedy by zastavil, s tým, kedy founder naozaj dohovoril (časové značky slov zo Scribe).
- **Sentry dáta (40 odpovedí, 2026-09-29 až 10-10) potvrdzujú sťažnosť:** 7× nahrávanie dobehlo na 15 s strop; v 4 z nich a v 2 dnešných detektor počítal 5,6–14,7 s ako „reč“, hoci typická odpoveď má 0,3–0,8 s reči. Hluk auta sa berie ako hlas.
- **Overené na tomto Macu (macOS 26.7.1):** Apple `SpeechTranscriber` nemá sk ani cs (len en-*); `DictationTranscriber` a `SFSpeechRecognizer` majú sk-SK aj cs-CZ.

## Dnešná cesta odpovede (main, 2026-10-10)

- Mikrofón s voice processingom → lokálny **energetický detektor** (`Services/SilenceDetectionService+VAD.swift`, konštanty `Utilities/VADTuning.swift`) → WAV → backend `/voice/submit` → ElevenLabs **Scribe v2 batch** → vyhodnocovač (Haiku 5.5, #196).
- Detektor: kalibrácia šumu 0,3 s na začiatku; reč = +7 dB nad šumom (držať 60 ms), koniec = pod +4 dB; šumová hladina stúpa pomaly (2 s), klesá rýchlo (0,1 s); koniec odpovede po 0,8 s ticha; min. reč 0,25 s (MCQ 0,1 s); strop 15 s; 5 s okno na začatie.
- Každé zastavenie loguje Sentry `answer recording stopped` (dôvod, dĺžka, ms reči, ms nejasného stavu, výstupný port, voice processing).
- #184 už má prepínač „Save answer recordings“ (WAV + sidecar) a `scripts/stt_compare.py`; #197 doplnil upload na server (PR #334).

## Sentry: posledných 40 nahrávaní odpovedí

| Dôvod zastavenia | Počet | Pozorovanie |
|---|---|---|
| ticho (VAD) | 31 | reč typicky 0,3–0,8 s, nahrávka 2–5 s; občas 7–9 s pri <1 s reči |
| strop 15 s | 7 | 4× „reč“ 9,5–14,7 s (hluk = hlas); 3× reč len 0,1–1 s (nejasné, chýba čas začiatku reči) |
| žiadna reč za 5 s | 2 | — |

- Dnes (build 69, reproduktor telefónu): dve odpovede za sebou s 5,6 s a 9,9 s „reči“.
- **Chýba v logu:** kedy reč začala a kedy naposledy skončila (ms od začiatku). Bez toho sa nedá odlíšiť „neskoro som začal“ od „neskoro zastavilo“.

### Hypotéza príčiny
Energetický detektor rozlišuje len hlasitosť. Hluk auta kolíše (výmole, predbiehanie, ventilácia) a hladina šumu sa prispôsobuje nahor pomaly (2 s), takže hlasnejší úsek hluku prejde prahom +4 dB a udrží stav „hovorí“. Modelové detektory (napr. Silero VAD, Apple SpeechDetector) rozlišujú hlas od hluku podľa tvaru zvuku, nie hlasitosti; #185 SpeechDetector nahradil, lebo v aute mlčal. Rozhodnúť **na dátach**, nie ďalším ladením naslepo (tretíkrát).

## Možnosti merania prepisu

### A. Priamy prenos súboru (odporúčané)
- Agent pošle WAV tou istou cestou ako appka (Scribe v2 batch cez backend), voliteľne aj iné enginy na porovnanie (Scribe s `keyterms`, Apple `DictationTranscriber` cez malé Swift CLI, vzor [yap](https://github.com/finnvoor/yap)).
- Opakovateľné, rýchle, bez povolení mikrofónu, beží bez dozoru.

### B. Akustická slučka reproduktor → mikrofón (pôvodný nápad; len ako občasný test celej appky)
- Farbenie zvuku, potlačenie ozveny môže prehrávaný zvuk vymazať, beh v reálnom čase, povolenie mikrofónu pre terminál, rozptyl, ktorý sa nedá oddeliť od chyby prepisu.
- Digitálna verzia: virtuálne zariadenie BlackHole ako vstup Simulátora (Device → Sound → Sound Input, [Apple doc](https://developer.apple.com/documentation/xcode/configuring-the-environment-of-a-simulated-device.md)). Neoverené end-to-end; audio vstup Simulátora býva nespoľahlivý ([forum](https://developer.apple.com/forums/thread/742572)).

## Metriky

- **Prepis:** hlavná = zmenil prepis verdikt appky oproti správnemu prepisu? Pomocná = zachytený kľúčový výraz; CER cez [jiwer](https://github.com/jitsi/jiwer), súhrnne za set ([prečo nie WER na krátkych odpovediach](https://arxiv.org/pdf/2310.08225)); reportovať s diakritikou aj bez.
- **Detekcia ticha:** (1) oneskorenie konca = zastavenie − koniec posledného slova (cieľ ~0,8–1,2 s); (2) % nahrávok na strope; (3) **predčasné useknutie** = slová po zastavení. Na (3) treba, aby diagnostická nahrávka pokračovala ~3 s po zastavení (len v uloženom súbore, hra beží ďalej).

## Korpus

- Zber cez #197 (prepínač ON v TF builde, automatický upload). Diktafón zamietnutý (iná cesta mikrofónu).
- ~100 nahrávok na jazyk na hrubé rozdiely; 150–300 na porovnanie dvoch enginov (pravidlo palca, párový test McNemar).
- Označiť podmienky (rýchlosť, okná, hudba, reproduktor vs. Bluetooth). Umelé miešanie šumu ([audiomentations](https://github.com/iver56/audiomentations)) len ako doplnok.
- Žiadny hotový nástroj nepokrýva náš detektor ani vyhodnocovač ([Open ASR Leaderboard](https://arxiv.org/abs/2510.06961v2) len na inšpiráciu) → rozšíriť `stt_compare.py` podľa #197.4.

## Návrh doplnkov k #197
1. Sentry log zastavenia doplniť o čas začiatku a konca reči (ms).
2. Diagnostická nahrávka: +3 s po zastavení, so značkou okamihu zastavenia.
3. Replay detektora na nahrávkach (Swift test na Macu) + porovnanie alternatív (prahy, modelový VAD) → zmena len s dátami.
