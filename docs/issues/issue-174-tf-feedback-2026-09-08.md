# #174 — TF feedback 2026-09-08 (slovenský kvíz, MCQ, build 57)

**Triage:** in-progress · **Owner:** agent · **Nadväzuje na:** #173 — TF feedback 2026-09-07 · **Varianty:** [HTML](../design/variants/issue-174-tf-feedback-2026-09-08.html)

## Nálezy foundera (4 screenshoty, 20:28–20:29)

| # | Nález | Diagnóza | Stav |
|---|-------|----------|------|
| 1 | Sada nastavená na 10 otázok skončila po 3 (výsledok „1/3“) | Backend nenašiel ďalšiu nevidenú otázku (general + sk + approved − 100+ videných ID z telefónu) a ticho prepol session na `finished` (`flow.py` `no_more_questions`, HTTP 200, `message` sa nezobrazí). Sentry issue 145770867, 18:28:58Z. **Build 57 bežal proti stagingu** (596 otázok, backend z 31. 7.), prod má 994. | D1 (nahlas) + D2 (fallback) = rozhodnutie foundera |
| 2 | Celoobrazovkový overlay „Vyhodnocujem…“ stále existuje | Po PR #114 ostal pre cesty bez sheetu: ťuknutá MCQ možnosť + preskočenie (`QuestionView.isProcessing`). | **Opravené** v tejto vetve (E) |
| 3 | MCQ možnosti sa nečítajú nahlas | Staging backend (v25, 31. 7.) je pred fixom `8b28e8f4` (3. 8., `spoken_question_text`). Prod číta možnosti; kód na `main` je v poriadku. | Zmizne s prod buildom |
| 3b | MCQ možnosti sa nezmestia do dlaždíc | Mriežka 2×2, ~150 pt na text, `minimumScaleFactor(0.7)` + `lineLimit(3)`. | C = rozhodnutie foundera |
| 4a | Potvrdzovací sheet nie je odlíšený od obrazovky | `.presentationBackground(Theme.bg)` = tá istá farba, bez úchytky, bez stmavenia. | A = rozhodnutie foundera |
| 4b | „Vyhodnocujem…“ v tlačidle rozbije layout | HStack 50/50, SK label 2× dlhší → `minimumScaleFactor(0.7)` + orezanie. | B = rozhodnutie foundera |

## Príčina build 57 na stagingu

`/testflight` skill mal default `staging` (v rozpore s rozhodnutím foundera z 2026-07-30: len prod). Dnešný run 34231518795 = `fastlane ios beta`. Opravené: default `production`, staging len na explicitnú žiadosť. Náhradný prod build spustený 18:46Z (run 34265056126).

## Vedľajšie zistenia

- **ElevenLabs kvóta vyčerpaná** (18:28:54Z: `401 quota_exceeded`, 9 kreditov, treba 88) → TTS padá na OpenAI fallback aj na prode. Founder: dobiť / počkať na reset.
- **CI flake (nesúvisí s #174):** Swift Testing beží suity paralelne, 15 súborov HangsTests používa procesovo-globálny `withMainSerialExecutor` → časovacie testy hladujú; na `main` padali 3 zo 4 plných behov. Fix v tejto vetve: `-parallel-testing-enabled NO` v ios-ci.yml + lokálny príkaz v `ios.md`.
- **Skutočná chyba poradia (follow-up do #173):** `startRecording` nastaví dead-air poistku pred nábehom enginu (`RecordingCoordinator+Capture.swift`); pri pomalom handshaku vystrelí v medzere, stav spadne na `askingQuestion` a znovu nastavená poistka sa vetuje vlastným guardom → mikrofón ostane otvorený bez limitu. V produkcii zriedkavé (15 s), v testoch so sub-sekundovou poistkou bežné.
- Sentry prostredie `staging` + `browser: Hangs 57` = spoľahlivý spôsob, ako zistiť, proti čomu build beží.

## Úlohy

- [x] E — overlay preč; ťuknutá dlaždica = spinner namiesto písmena, ostatné stlmené; Preskočiť = spinner namiesto ikony (label sa nemení)
- [x] `/testflight` default → production
- [x] HTML varianty A/B/C/D + otázka D2
- [ ] Founder: výber A / B / C / D2
- [ ] A — sheet: povrch, úchytka, stmavenie podľa výberu
- [ ] B — tlačidlo bez skoku podľa výberu
- [ ] C — layout možností podľa výberu (+ Pencil sync)
- [ ] D1 — backend `finish_reason: corpus_exhausted` v odpovedi + výsledková obrazovka s vysvetlením a akciou
- [ ] D2 — fallback v `_fallback_retrieval` podľa výberu (iná kategória / uvoľniť najstaršie videné / nič)
- [ ] Founder: ElevenLabs kredity
- [ ] Dead-air poistka: nastaviť až po nábehu enginu (viď Vedľajšie zistenia)
- [ ] Founder: TF kontrola prod buildu (možnosti sa čítajú, 10 otázok, #173 položky)

## Neprebrať znova

- Hlasový povel nemôže ukončiť kvíz (lexikón nemá quit/end; `.stop` len na sheete).
- iOS nemá lokálny počítadlo otázok; koniec = server `phase == finished`.
- Prod Fly logy sa pri auto-stop stroji strácajú; dôkazy brať zo Sentry.
