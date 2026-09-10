# #176 — Review štítok otázky v TF buildoch + TF servíruje aj odmietnuté preklady

**Triage:** `ready-for-human` · founder rozhodnutia 2026-09-10 · nadväzuje na #168 (T23 cutover, HG-4/HG-5)
**Design:** [HTML varianty](../design/variants/issue-168-tf-review-badges.html) → **Variant A**, všetkých 5 stavov · [decisions](../design/ui-variants-2026-09-10-decisions.md)

## Prečo

Founder testuje SK/CS preklady v TestFlighte, ale v hre nevidí, či je otázka ľudsky schválená, strojom schválená, alebo strojom odmietnutá. Odmietnuté preklady sa dnes neservírujú vôbec, takže kritické chyby (prezradená odpoveď, zlá zodpovedateľnosť) vidí len na rating webe, nie v hre. Cieľ: jeden štítok vedľa existujúceho riadku s modelom, len v TF/debug buildoch; App Store build nevidí nič navyše.

## Founder rozhodnutia (nerozporovať)

1. **Päť stavov** štítku: `approved` · `pending_review` · `translation_machine` · `translation_flagged` · `translation_critical` (+ `en_fallback` po cutovere, keď preklad chýba).
2. **TF servíruje aj strojom odmietnuté preklady** (`question_translations.status = rejected`) so štítkom „kritické“. App Store ich nikdy nedostane.
3. **Umiestnenie = Variant A:** riadok pod otázkou `model · jazyk · štítok` (rovnaké 11pt mono ako dnešný `generated_by` badge, štítok farebný); ten istý štítok v meta riadku výsledkovej obrazovky.
4. **Sémantika „approved“ (2026-09-10, mení pravidlo 08-28):** App Store smie zobrazovať aj otázky, ktoré neschválil človek, ale iba v stave `approved`. Rozhoduje stav, nie kto ho nastavil. `pending_review` ostáva TF-only. (Otvorené: či strojové brány smú nastavovať `approved` pre nové EN otázky — dnes importér dáva `pending_review`.)

## Mapovanie stavu (server-side, jeden enum)

| Zdroj | Štítok |
|---|---|
| EN `review_status = pending_review` | `pending_review` (bez ohľadu na jazyk kvízu) |
| EN `approved`, kvíz **EN** | `approved` (TF: tichý zelený bod, App Store: nič) |
| preklad `approved`, `verification.judge.verdict = ok`, bez findings a bez regional flagu | `translation_machine` |
| preklad `approved`, sudca má findings alebo regional flag | `translation_flagged` |
| preklad `rejected` (guard / translation_flip / critical) | `translation_critical` |
| kvíz sk/cs, preklad **nie je** v `question_translations`, text dal serve-time LLM preklad | `translation_live` |
| kvíz sk/cs, preklad chýba aj live preklad nedobehol, servíruje sa EN | `en_fallback` |

Priorita pri kombinácii: `translation_critical` > `translation_flagged` > `pending_review` > `translation_machine` > `translation_live` > `en_fallback` > `approved`.

**Dve úpravy tabuľky pri implementácii backendu (PR #176-backend):**
1. **`translation_live` = nový šiesty stav.** #168 cutover (T23/T24) ešte nebeží, takže serve-time LLM preklad zostáva ako *fallback*, keď pre (otázka, jazyk) neexistuje riadok. Taký text neprešiel žiadnou bránou a nesmie si pôjčať kredibilitu `translation_machine` riadku, preto má vlastný štítok. `en_fallback` ostáva pre prípad, keď nedobehne ani live preklad.
2. **Rozpor v pôvodnej tabuľke vyriešený v prospech `translation_machine`.** Druhý riadok („EN approved, kvíz EN **alebo preklad so sudcom bez nálezu**" → `approved`) si protirečil s tretím („preklad approved, verdict ok, bez regional flagu" → `translation_machine`). Vybraný je `translation_machine`: `question_translations` nemá `reviewed_by`, takže o schválenom preklade sa nedá tvrdiť, že ho čítal človek — a presne túto distinkciu má štítok ukázať. `approved` teda platí len pre EN kvíz.

## Rozsah

### Backend (`apps/quiz-agent`, hot path, bez LLM) — **HOTOVÉ (PR, nedeployované)**
- [x] `PublicQuestion` + wire shape (`packages/shared/quiz_shared/models/question.py`): voliteľné `review_badge`, `translation_language`, `review_note` (1 riadok z `verification.judge.findings[0].note`, len pre `flagged`/`critical`). **Vyplnené len keď `session.build_channel == "testflight"`**; inak kľúče na drôte vôbec nie sú (nie `null` — iOS rozlišuje podľa absencie kľúča), takže App Store payload je byte-identický so stavom pred #176.
  - *Odchýlka:* `review_note` má poradie zdrojov judge findings → `guards.reasons[0]` → `answerability.verdict` → `regional.reason`. Dôvod: v #168 korpusovom behu je väčšina rejectov answerability flip (36/50 sk) alebo guard, kde judge findings vôbec nie sú — note by bol prázdny práve pri najhlasnejšom štítku.
- [x] Servírovanie prekladov (`app/stored_translation.py` + `app/serializers.py`): primárny zdroj je riadok v `question_translations` cez `get_translations` (bez LLM callu); serve-time LLM preklad ostáva ako fallback, keď riadok nie je. TF berie `approved` aj `rejected`, App Store iba `approved`. Štítok sa počíta raz pri stavbe recordu a jazdí na `session.current_question_translation`, takže `/question`, `/question/audio` a re-grade ho reprodukujú bez ďalšieho dotazu.
- [x] Store surface rozšírený (`packages/shared/quiz_shared/database/translation_queries.py`): `fetch_approved_translations` → `fetch_servable_translations(..., statuses=("approved",))`, mirror tabuľka dostala `verification`, `_SERVE_COLUMNS` dostali `status` + `verification`. `PgvectorQuestionStore.get_translations` má tretí parameter `statuses`.
- [x] `translated_question_view` kopíruje `alternative_answers` zo *stored* riadku (#168 C1/DD5) — bez toho by sa slovenská odpoveď hodnotila proti anglickým alternatívam. Live record tento kľúč nemá, takže EN/live cesta je nezmenená.
- [x] **Retriever: žiadna zmena.** Gate `approved_languages` v `apps/quiz-agent` dnes **neexistuje** (je to otvorený #168 T23) — takže „pre TF ho nepoužiť" je splnené tým, že sa nepridáva. `review_status` brána podľa build channelu (`question_retriever.py:278-282`) a pack branch ostávajú presne ako na `main`. App Store gate je ďalší founder-gated krok.
- [x] OpenAPI: `scripts/export_openapi.py` generuje spec, `PublicQuestionWire` má 17 properties (14 + 3 nové), `required` set nezmenený. `/verify-api` + iOS Codable ide s iOS PR-om.

### iOS (`apps/ios-app`)
- `Question.swift` Codable: `reviewBadge`, `translationLanguage`, `reviewNote`.
- `QuestionView.swift:502-517` `generatedByBadge` → rozšíriť na riadok `model · jazyk · štítok`; štítok = 5 farieb podľa Theme (zelená/oranžová/tyrkysová/oranžová/červená), `lineLimit(1)`, `minimumScaleFactor`. Zobrazenie viazať na `BuildChannel.debugSurfacesEnabled()` (dnes badge nemá bránu; `TEMP` komentár odstrániť, toto ho nahrádza).
- ResultView meta riadok: ten istý štítok + `reviewNote` (1 riadok, ellipsis).
- Lokalizácia sk/en/cs (`xcstringstool sync`).
- Snapshot/unit test: TF session zobrazí štítok, App Store nie.

### Pencil
- `design/quiz-agent.pen`: question + result frame, riadok podľa Variantu A (founder ⌘S).

## Mimo rozsahu
- Klepnutie na štítok → rating sheet (Variant B/C nápad, odložené).
- Zmena defaultu importéra na `approved` (otvorená founder otázka, bod 4).
- T24 serve-path deletion (#168) ostáva samostatný krok.

## Akceptácia
- TF SK kvíz: každá otázka má presne jeden štítok; odmietnutý preklad sa servíruje so štítkom „kritické“.
- App Store session: odpoveď API neobsahuje `review_badge`, odmietnuté preklady ani `pending_review` EN otázky (existujúce testy retrievera ostávajú zelené).
- EN kvíz: žiadny regres v `generated_by` riadku; pre `approved` otázku len zelený bod.
- Backend testy + iOS cielené testy zelené; `/verify-api` čistý.

## Poradie
1. ~~Backend (polia + TF serving rejected + TF-bez-gate) → PR~~ **hotové** → deploy prod ostáva (prepínač len podľa build channel, EN/App Store nedotknuté).
2. iOS (Codable + riadok + result meta + lokalizácia) → PR.
3. Pencil sync → founder ⌘S.
4. TF build **len na požiadanie foundera**.
