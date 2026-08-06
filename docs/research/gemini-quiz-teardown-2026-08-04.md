# Gemini quiz teardown — čo z neho vieme prevziať (2026-08-04)

**Kontext:** founder prompt 2026-08-04 (mba session) — „na gemini.google.com sa dá spustiť kvíz a vyzerá dosť dobre, aj super otázky. Vieš sa naň napojiť a spraviť research? My máme brutálne komplexnú pipeline a tým pádom sú custom balíčky drahé." Zadanie bolo **research only, žiadne zmeny**. Session dobehla, výstup ostal len v chate — tento súbor ho zachováva. Priamo súvisí s [#143 — custom-pack COGS reduction](../issues/issue-143-pack-cogs-reduction.md).

## Odpoveď krátko

**Napojiť sa na Gemini kvíz priamo sa nedá.** Predplatné pokrýva webové a mobilné rozhranie, nie programový prístup. Kvízy v Gemini Canvas a režim Guided Learning sú produktová funkcia aplikácie, nemajú vlastné API. Existujú neoficiálne knižnice, ktoré sa tvária ako prehliadač a berú prihlasovacie cookies — porušenie podmienok, láme sa pri každej zmene Googlu, do produkcie sa to dať nedá. Neodporúča sa.

**Legálna cesta je Gemini API** (platba za tokeny, nezávisle od predplatného) s tými istými modelmi. Dôležité zistenie: **LearnLM** — model, ktorý Google trénoval na pedagogiku — už neexistuje samostatne, je vtavený do bežných Gemini modelov. Žiadna tajná ingrediencia, ku ktorej by sme sa nedostali: to, čo robí ten kvíz dobrým, je model plus spôsob zadania, a oboje máme k dispozícii.

## Prečo im to vyzerá tak lacno a rýchlo

Ich kvíz a náš balíček sú dva rôzne produkty:

| | Gemini kvíz | Náš balíček |
|---|---|---|
| Životnosť | jednorazový, zahodí sa | trvalý, opakovane predávaný obsah |
| Overovanie faktov | žiadne | samostatná fáza |
| Zdroje | voliteľné | povinné, každá otázka má zdroj |
| Kontrola duplicít | žiadna | proti celej existujúcej databáze |
| Forma | text na obrazovke | číta sa nahlas počas šoférovania |
| Cena chyby | používateľ pokrčí plecami | zaplatený obsah, sťažnosť |

Gemini spraví jeden prechod modelom a hotovo. My máme osem fáz (hľadanie zdrojov, generovanie, kritika, kontrola zodpovedateľnosti, overenie faktov, viacmodelové hodnotenie, deduplikácia, uloženie). Odtiaľ je tá cena.

Pozor na dojem „super otázky": Gemini 3 Flash má v nezávislom benchmarku veľmi vysokú mieru vymýšľania si, keď odpoveď nepozná; novšia Pro verzia to znížila zhruba na polovicu. Chybnú otázku si na téme, ktorú neovládaš, jednoducho nevšimneš.

## Čo sa oplatí prevziať

1. **Dvojrýchlostný model balíčkov — najväčšia páka na cenu.** „Okamžitý" balíček = jeden prechod modelom, zahrá sa hneď, neukladá sa do predajného korpusu. Overená pipeline zostáva pre obsah, ktorý predávame a recyklujeme. Podľa cenníka Gemini Flash by jednorazový balíček vyšiel hlboko pod cent; dnes nás tridsať otázok stojí zhruba $0,20–$0,85 podľa modelu (celková cena behu vrátane hodnotenia ≈ $4,23). Rádovo 10–50× rozdiel, zaplatený tým, že sa fakty neoveria.
2. **Vstavané ukotvenie v Google vyhľadávaní.** Gemini API to má ako natívnu funkciu jedného volania. U nás je hľadanie zdrojov samostatná fáza s vlastnými poskytovateľmi — mohlo by zjednodušiť infraštruktúru aj znížiť cenu.
3. **Gemini ako generujúci model.** Už je v schválenom zozname na slepý test v [#135](../issues/issue-135-gen-pipeline-founder-feedback-round-2.md) — nič nové netreba schvaľovať.
4. **Okamžitá spätná väzba a nápoveda.** Podľa všetkého robí ich kvíz príjemným minimálne tak ako kvalita otázok. Zdrojový úryvok pri každej otázke už máme, takže „prečo je to tak" vieme povedať skoro zadarmo. Skôr UX vec než technická.

## Otvorené rozhodnutie pre foundera

Či ideme do **dvojrýchlostného modelu** — lacný okamžitý balíček bez záruky správnosti vedľa overeného prémiového. Je to produktové rozhodnutie o tom, čo predávame a čo sľubujeme, nie technické. Ak áno, spíše sa ako návrh issue s číslami.

## Zdroje

- [Personalize learning with Quizzes in Gemini Canvas](https://workspaceupdates.googleblog.com/2025/05/gemini-canvas-quizzes.html)
- [Create quizzes, flashcards, practice tests in Gemini Apps](https://support.google.com/gemini/answer/16275879?hl=en&co=GENIE.Platform%3DAndroid)
- [Gemini Guided Learning mode](https://www.engadget.com/ai/geminis-new-guided-learning-mode-can-quiz-students-and-create-interactive-study-aids-181743349.html)
- [LearnLM — Gemini API docs](https://ai.google.dev/gemini-api/docs/learnlm)
- [Reverse-engineered Gemini web API (why not to use it)](https://github.com/HanaokaYuzu/Gemini-API)
- [Gemini 3.6 Flash pricing](https://www.cometapi.com/gemini-3-6-flash-api-pricing-migration/)
- [Gemini 3 Flash hallucination rate](https://tech.yahoo.com/ai/gemini/articles/gemini-3-flash-doesn-t-214500774.html)
