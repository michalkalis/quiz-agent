# UI-variant decisions — 2026-09-10 round (#168 → #176 TF review badges)

Founder picks, in-session 2026-09-10. Variant page: `variants/issue-168-tf-review-badges.html`. Implementation issue: `../issues/issue-176-tf-review-badges.md`.

## Stavy → **všetkých päť**

`approved` (tichý zelený bod) · `pending_review` · `translation_machine` · `translation_flagged` · `translation_critical`; plus `en_fallback` po cutovere. Len TF/debug buildy (brána `BuildChannel.debugSurfacesEnabled()`, rovnaká ako rating chip).

## Kritické preklady v TF → **áno, skúsime**

TF servíruje aj strojom odmietnuté preklady so štítkom „kritické“. App Store ich nikdy nedostane.

## Umiestnenie → **Variant A**

Riadok pod otázkou `model · jazyk · štítok` v dnešnom 11pt mono riadku s modelom; rovnaký štítok v meta riadku výsledku. Varianty B (chip v navigácii) a C (pruh s dôvodom na výsledku) odložené; klepnutie → rating sheet je nápad do zásoby.

## Poznámka foundera (mení pravidlo 2026-08-28)

App Store verzia smie zobrazovať aj otázky, ktoré neschválil človek, ale len tie v stave `approved`. Rozhoduje stav, nie kto ho nastavil. `pending_review` ostáva TF-only.

## Pipeline

HTML picks (this doc) → Pencil sync (`design/quiz-agent.pen`: question + result frame riadok; founder `⌘S`) → backend + SwiftUI (#176).
