# #178 — TF feedback 2026-09-13 (slovenský kvíz, MCQ)

**Triage:** ready-for-human · **Owner:** agent · **Nadväzuje na:** #174 — TF feedback 2026-09-08 (rozkazovacie tlačidlá, mic glyf, nápovedy)

## Nálezy foundera (2 screenshoty: 2026-09-12 21:13, 2026-09-13 08:52)

| # | Nález | Diagnóza | Stav |
|---|-------|----------|------|
| 1 | Malé mikrofóny na tlačidlách sa nepáčia; vrátiť nápovedu ako predtým (✕ na zavretie, po 5 kvízoch skryť, zapnúť v Nastaveniach) | Nápoveda s ✕ (#173 — TF feedback 2026-09-07, variant B1) **nikdy nezmizla** — #174 k nej pridal len glyfy a pravidlo „slová pod lištou len prvých 5 dokončených kvízov, potom prepínač v Nastaveniach“. Founder má >5 kvízov → slová sa mu už automaticky skryli, ostali len glyfy. | Glyfy odstránené (A); pravidlo 5 kvízov + prepínač ostávajú |
| 2 | Prvá otázka sa znova neprečítala | Sentry 06:49:18Z: sťahovanie audia prvej otázky vypršalo (10 s limit klienta, `-1001`), retry po 300 ms. Backend v tom čase: ElevenLabs kvóta → OpenAI fallback (pomalší) **a každá otázka sa syntetizuje 2× naraz** (backend prefetch + požiadavka klienta v tom istom okamihu, cache sa zapíše až po syntéze → obe minú cache; pri prvej otázke vždy, lebo klient žiada hneď). Sedenie z 09-12 21:13 nemá v Sentry žiadne logy. | Kvóta = founder; single-flight v TTS službe = F |
| 3 | Ťuknutie na MCQ možnosť počas čítania otázky nezastaví čítanie | `submitMCQAnswer` nikde nevolá stop prehrávania (barge-in aj replay áno). | **Opravené** (B): stop po prechode do `.processing`, aby retry čítania mlčal |
| 4 | Po ťuknutí na MCQ možnosť (4/10) appka zamrzla: spinner v písmene, možnosti sivé | Spinner = stav `.processing`; opustí ho len `handleQuizResponse`/chyba. Ťuknutá odpoveď išla bez časového limitu a bez možnosti zrušenia (hlasová má 30 s + retry od #131 — TF feedback 2026-07-29). Sentry: posledný log 06:52:41Z, backend spracoval odpoveď až ~06:52:42 (35 s po ťuknutí, prefetch ďalšej otázky), nič medzi tým — požiadavka visela na sieti (5G). Backend nemá access logy, MCQ submit nemá štruktúrované logy = slepé miesto. | **Opravené** (C): 30 s limit → chybová obrazovka s retry; zdieľaný `withUserFacingTimeout` |
| 5 | Slovenský hlas znie divne | ElevenLabs kľúč `carquiz` vyčerpal per-key limit 5 000 kreditov (06:49Z `quota_exceeded`, 9 kreditov) → všetko cez OpenAI fallback. Účet má ešte ~4 750 do resetu 28. 9. Opakuje sa (#174 09-08). Navyše rekapitulácia si vždy pýtala OpenAI hlas `nova` → ElevenLabs `voice_not_found` → vždy fallback. | Kód: PR #145 (recap voice) merged + v prode. Kvóta: founder zdvihne limit kľúča / platený plán |

## Rozhodnutia

- Pravidlo nápovied ostáva na **dokončených** kvízoch (`QuizStats.totalQuizzes`, #174 09-09), nie na spusteniach — founder 09-13 napísal „5 pusteniach“; rozdiel len pri nedokončených kvízoch, prepnutie triviálne ak bude chcieť.
- ✕ ostáva len na MCQ lište, per otázka (`ListenBarDismissal`), ako v #173 — TF feedback 2026-09-07 (variant B1).

## Tasky

- [x] A — (PR #146) odstrániť `VoiceGlyph` + plumbing (`voiceGlyph:` / `showsVoiceGlyph`) zo všetkých tlačidiel, toolbaru a footeru; test `voiceGlyphIsOptIn` zmazať
- [x] B — MCQ ťuknutie počas TTS zastaví čítanie
- [x] C — zamrznutie po MCQ ťuknutí: root cause + fix + test
- [x] D — prvá otázka bez zvuku: diagnóza zo Sentry logov (viď nález 2)
- [x] F — backend: single-flight pre súbežné identické TTS syntézy (prefetch + klient), test — PR #147 merged + v prode 2026-09-13
- [ ] E — Pencil sync: glyfy preč z Answer-Confirm / Question-Listen / Result / Home / Settings (založené v #174)
- [ ] `[HUMAN]` ElevenLabs: zdvihnúť limit kľúča `carquiz` (API Keys → carquiz → Character limit) alebo Starter plán 5 $/mes
- [ ] `[HUMAN]` TF kontrola — build spustený 2026-09-13 (run 34746030931) na žiadosť foundera
