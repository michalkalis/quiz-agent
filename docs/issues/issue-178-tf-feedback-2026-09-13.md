# #178 — TF feedback 2026-09-13 (slovenský kvíz, MCQ)

**Triage:** in-progress · **Owner:** agent · **Nadväzuje na:** #174 — TF feedback 2026-09-08 (rozkazovacie tlačidlá, mic glyf, nápovedy)

## Nálezy foundera (2 screenshoty: 2026-09-12 21:13, 2026-09-13 08:52)

| # | Nález | Diagnóza | Stav |
|---|-------|----------|------|
| 1 | Malé mikrofóny na tlačidlách sa nepáčia; vrátiť nápovedu ako predtým (✕ na zavretie, po 5 kvízoch skryť, zapnúť v Nastaveniach) | Nápoveda s ✕ (#173 B1) **nikdy nezmizla** — #174 k nej pridal len glyfy a pravidlo „slová pod lištou len prvých 5 dokončených kvízov, potom prepínač v Nastaveniach“. Founder má >5 kvízov → slová sa mu už automaticky skryli, ostali len glyfy. | Glyfy odstránené (A); pravidlo 5 kvízov + prepínač ostávajú |
| 2 | Prvá otázka sa znova neprečítala | _doplniť po diagnóze_ | |
| 3 | Ťuknutie na MCQ možnosť počas čítania otázky nezastaví čítanie | _doplniť po diagnóze_ | |
| 4 | Po ťuknutí na MCQ možnosť (4/10) appka zamrzla: spinner v písmene, možnosti sivé | _doplniť po diagnóze_ | |
| 5 | Slovenský hlas znie divne | ElevenLabs kľúč `carquiz` vyčerpal per-key limit 5 000 kreditov (06:49Z `quota_exceeded`, 9 kreditov) → všetko cez OpenAI fallback. Účet má ešte ~4 750 do resetu 28. 9. Opakuje sa (#174 09-08). Navyše rekapitulácia si vždy pýtala OpenAI hlas `nova` → ElevenLabs `voice_not_found` → vždy fallback. | Kód: PR #145 (recap voice). Kvóta: founder zdvihne limit kľúča / platený plán |

## Rozhodnutia

- Pravidlo nápovied ostáva na **dokončených** kvízoch (`QuizStats.totalQuizzes`, #174 09-09), nie na spusteniach — founder 09-13 napísal „5 pusteniach“; rozdiel len pri nedokončených kvízoch, prepnutie triviálne ak bude chcieť.
- ✕ ostáva len na MCQ lište, per otázka (`ListenBarDismissal`), ako v #173 B1.

## Tasky

- [ ] A — odstrániť `VoiceGlyph` + plumbing (`voiceGlyph:` / `showsVoiceGlyph`) zo všetkých tlačidiel, toolbaru a footeru; test `voiceGlyphIsOptIn` zmazať
- [ ] B — MCQ ťuknutie počas TTS zastaví čítanie
- [ ] C — zamrznutie po MCQ ťuknutí: root cause + fix + test
- [ ] D — prvá otázka bez zvuku: diagnóza zo Sentry logov
- [ ] E — Pencil sync: glyfy preč z Answer-Confirm / Question-Listen / Result / Home / Settings (založené v #174)
- [ ] `[HUMAN]` ElevenLabs: zdvihnúť limit kľúča `carquiz` (API Keys → carquiz → Character limit) alebo Starter plán 5 $/mes
- [ ] `[HUMAN]` TF kontrola po builde (na požiadanie)
