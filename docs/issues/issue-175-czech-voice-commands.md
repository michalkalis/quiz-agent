# #175 — České hlasové povely

**Triage:** ready-for-agent · **Owner:** agent (ďalšia session) · **Nadväzuje na:** #168 — jazyková vetva SK/CS, #174 — TF feedback 2026-09-08 · **Founder:** 2026-09-09 „určite treba pridať“

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

## Definícia hotového

Český kvíz: všetky povely z tabuľky rozpoznané v simulátore aj na zariadení, cs testy zelené, nápovedy po česky.
