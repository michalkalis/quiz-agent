# #175 — České hlasové povely

**Triage:** in-progress · **Owner:** agent (session 2026-09-09, vetva `feat/175-czech-voice-commands`) · **Nadväzuje na:** #168 — jazyková vetva SK/CS, #174 — TF feedback 2026-09-08 · **Founder:** 2026-09-09 „určite treba pridať“

## Problém

České UI je preložené (PR #53, 522 stringov), ale hlasové povely existujú len pre `en` a `sk` (`VoiceCommandLexicon` / `CommandLanguage` má iba `.english` a `.slovak`). Český používateľ nemôže povedať „přeskoč“ ani „potvrď“; povely padajú do slovenskej alebo anglickej gramatiky, alebo sa nerozpoznajú vôbec.

## Zadanie

- Pridať `CommandLanguage.czech` s gramatikou (jednoslovné povely, `maxContentTokens = 1` ostáva):
  - start → „start“ · repeat → „zopakuj“, „opakuj“ · skip → „přeskoč“, „vynech“ · ok → „ok“, „potvrď“ · again → „znovu“ · stop → „stop“, „zruš“ · pause → „pauza“ · next → „dál“, „pokračuj“.
  - Normalizácia diakritiky (ř, ě, ů) rovnako ako pri sk (`preskoc`), aby Levenshtein prahy (0.72 / 0.8 skip / 0.85 interim) fungovali rovnako.
- Výber gramatiky podľa jazyka kvízu (rovnako ako sk); STT jazyk pre povely `cs-CZ` (overiť, či SpeechAnalyzer / ElevenLabs STT podporuje cs pre poslucháča povelov).
- Nápovedy (`VoiceCommandLexicon.hint`) v češtine — po #174 premenovaní tlačidiel budú nápovedy = názvy tlačidiel, takže cs stringy tlačidiel musia byť tiež v rozkazovacom tvare (Start, Přeskoč, Potvrď, Znovu, Zruš, Dál, Pauza).
- Testy: zrkadliť existujúce sk testy matchera a lexikónu pre cs (každý povel, ambiguity margin, diakritika).

## Závislosti

- #174 úloha „názvy tlačidiel = hlasové povely“ (rozkazovací tvar) — urobiť pred alebo spolu, aby cs tlačidlá vznikli už správne.
- Založené na diagnóze v pamäti `project_174_tf_feedback_2026_09_08` (prehľad povelov a prahov).

## Stav (2026-09-09)

Implementované na vetve `feat/175-czech-voice-commands` (PR čaká na review):

- [x] `CommandLanguage.czech` + `CommandEngineSelection.dictationCzech` (`cs_CZ`, picker „Dictation · Czech“ v Nastaveniach, platí od ďalšieho spustenia — rovnaký mechanizmus ako sk).
- [x] Gramatika cs vo `VoiceCommandLexicon`: start · ok/okej/potvrď · dál/dále/pokračuj · znovu/znova · zopakuj/opakuj · přeskoč/vynech · stop/zruš · pauza; výplňové slová (jo, ano, dobře, jasně, no, tak, tedy…) neutralizované ako pri sk; undo-slovo „ne“; kontextový slovník pre DictationTranscriber.
- [x] Nápovedy + caption v češtine (`VoiceCommandLexicon+Display.swift` — vyčlenené z lexikónu kvôli limitu veľkosti súboru).
- [x] Závislosť z #174 — názvy hlasovo ovládateľných tlačidiel v rozkazovacom tvare v sk/en/cs: Štart/Start (doma aj na otázke), Preskoč/Přeskoč, Potvrď, Znova/Znovu/Again, Zruš (nový kľúč `voice.cancel`, systémové alerty nechávajú „Zrušiť“), Ďalej/Dál/Next; nápovedy citujú presne tieto slová (sk potvrdzovací sheet: „zruš“ namiesto „stop“). Mikrofónový glyf + Preskoč ako text namiesto ikony + auto-skrytie nápovied ostávajú v #174.
- [x] Testy `CzechCommandGrammarTests` (13 testov, zrkadlo sk sady: routing s ř/ě/ů, inertné backchannely a vety, strict skip, disjunktnosť per obrazovka, volatile floor, undo-slová, display stringy).
- [ ] Founder: overiť na zariadení (český kvíz, Nastavenia → Command engine → Dictation · Czech → reštart) — všetky povely z tabuľky.

**Odchýlka od zadania:** gramatika sa nevyberá automaticky podľa jazyka kvízu — ani sk sa tak nevyberá; jazyk povelov je launch-time voľba v Nastaveniach (#120, engine sa stavia raz pri štarte). Automatické previazanie na jazyk kvízu je samostatné rozhodnutie (viď Follow-up).

## Follow-up

- Previazať jazyk povelov na jazyk kvízu (dnes 2 nezávislé voľby: kvíz sk/cs vs. povely en/sk/cs) — vyžaduje prestavbu enginu za behu (#120 ho stavia raz pri štarte). Founder rozhodnutie, či to chce pred friend-testingom.

## Definícia hotového

Český kvíz: všetky povely z tabuľky rozpoznané v simulátore aj na zariadení, cs testy zelené, nápovedy po česky.
