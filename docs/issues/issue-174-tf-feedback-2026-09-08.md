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

## Founder rozhodnutia (2026-09-09)

- **A1** zdvihnutý povrch sheetu, **bez úchytky** (sheet sa nedá zavrieť ťahom), stmavenie pozadia; pauza v toolbare pod sheetom ostáva klikateľná.
- **B1** vertikálny footer: primárne na celú šírku, „Nahrať znova“ pod ním ako textové.
- **C2** adaptívne možnosti: mriežka 2×2 len keď sú všetky ≤ 24 znakov, inak zoznam.
- **D** namiesto D1/D2: pri štarte kvízu kontrola dostupných otázok; ak je ich menej než požadované → alert „Nie je dosť otázok“ s voľbami *Začať s N* / *Resetovať videné* / *Zrušiť*. Uprostred kvízu sa nič nemení.
- ElevenLabs: chyba `quota_exceeded` bola zo **staging** kľúča; founderov účet má kredity (API: 5 207/10 000, free tier). Prod kľúč nebolo možné porovnať digestom.
- Hlasové povely = názvy tlačidiel + nápovedy v Nastaveniach: analýza poslaná founderovi 2026-09-09, čaká na rozhodnutie (viď pamäť #174).

## Úlohy

- [x] E — overlay preč; ťuknutá dlaždica = spinner namiesto písmena, ostatné stlmené; Preskočiť = spinner namiesto ikony (label sa nemení)
- [x] `/testflight` default → production
- [x] HTML varianty A/B/C/D + otázka D2
- [x] Founder: výber A1 / B1 / C2 / D-alert (2026-09-09)
- [x] A1 + B1 + C2 — vetva `feat/174-sheet-button-options`
- [ ] D — availability check pri štarte + alert — vetva `feat/174-corpus-precheck`
- [ ] Pencil sync (sheet, footer, zoznam možností) po TF potvrdení
- [x] ElevenLabs: nie je problém (staging kľúč)
- [ ] Hlasové povely = názvy tlačidiel + prepínač nápoved — čaká na founder rozhodnutie
- [ ] Dead-air poistka: nastaviť až po nábehu enginu (viď Vedľajšie zistenia)
- [ ] Founder: TF kontrola prod buildu (možnosti sa čítajú, 10 otázok, #173 položky)

## Neprebrať znova

- Hlasový povel nemôže ukončiť kvíz (lexikón nemá quit/end; `.stop` len na sheete).
- iOS nemá lokálny počítadlo otázok; koniec = server `phase == finished`.
- Prod Fly logy sa pri auto-stop stroji strácajú; dôkazy brať zo Sentry.
