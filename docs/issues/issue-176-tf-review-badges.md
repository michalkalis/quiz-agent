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
| EN `approved`, kvíz EN alebo preklad so sudcom bez nálezu | `approved` (TF: tichý zelený bod, App Store: nič) |
| preklad `approved`, `verification.judge.verdict = ok`, bez regional flagu | `translation_machine` |
| preklad `approved`, sudca má findings alebo regional flag | `translation_flagged` |
| preklad `rejected` (guard / translation_flip / critical) | `translation_critical` |
| kvíz sk/cs, preklad chýba, servíruje sa EN | `en_fallback` |

Priorita pri kombinácii: `translation_critical` > `translation_flagged` > `pending_review` > `translation_machine` > `approved`.

## Rozsah

### Backend (`apps/quiz-agent`, hot path, bez LLM)
- `PublicQuestion` (`packages/shared/quiz_shared/models/question.py:444`) + wire shape: nové voliteľné polia `review_badge: str | None`, `translation_language: str | None`, `review_note: str | None` (1 riadok z `verification.judge.findings[0].note`, len pre `flagged`/`critical`). **Vyplnené len keď `session.build_channel == "testflight"`**; inak `None` a App Store klient ich nikdy nevidí. Test: App Store session → polia chýbajú/None.
- Serializer (`apps/quiz-agent/app/serializers.py`, okolo `:128` podľa #168 T24) pri výbere prekladového riadku: TF session berie `approved` aj `rejected` riadok (rejected len TF!), App Store iba `approved`. Store surface `get_translations` (#168 T12/T13) — overiť, či vracia status + verification, inak rozšíriť.
- Retriever gate (#168 T23, `question_retriever.py:251-267`): pre TF session `approved_languages` filter **nepoužiť** (servíruje aj odmietnuté + EN fallback), pre App Store použiť. Toto je zároveň vehicle pre HG-5 cutover: TF prvý, App Store až po HG-4 waiveroch.
- OpenAPI → iOS Codable sync (`/verify-api`).

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
1. Backend (polia + TF serving rejected + TF-bez-gate) → PR → deploy prod (prepínač len podľa build channel, EN/App Store nedotknuté).
2. iOS (Codable + riadok + result meta + lokalizácia) → PR.
3. Pencil sync → founder ⌘S.
4. TF build **len na požiadanie foundera**.
