# #226 — Nezávislá kontrola textov iným modelom (sk · cs · en)

**Triage:** done · founder 2026-11-04

## Cieľ
Všetky texty, ktoré hráč vidí alebo počuje, prejde model mimo Anthropicu, lebo texty písal a prekladal Claude. Kontrola vždy dostane kontext: poznámku vývojára, obrazovku (súbor) a susedné texty, štýlové pravidlá `docs/design/copy-style.md`.

**Hotové =** pilot na podozrivých textoch vyhodnotený founderom → founder rozhodne o plnej kontrole → plná kontrola všetkých textov (appka, hovorené texty a povely, App Store, web) → opravy cez PR.

## Rozhodnutia foundera
- 2026-11-04: najprv automaticky nájsť podozrivé texty, tie poslať na pilot; plná kontrola všetkých textov (appka, hovorené + povely, App Store, web) až po pilote a finálnom rozhodnutí.
- 2026-11-04: pilot len Gemini, „fakt max okolo $1“.
- 2026-11-05: plná kontrola len Gemini, strop ~$4.
- 2026-11-04: nálezy ohodnotené v artefakte (`pilot-verdicts.json`).
- Cena: lacno; nad ~$3–4 vopred pýtať ([[feedback_spend_approval_threshold]]).

## Výber modelov
Research: [copy-review-models-sk-cs-en-2026-11.md](../research/copy-review-models-sk-cs-en-2026-11.md).
- Hlavný recenzent: **Gemini 3.1 Pro** (`gemini-3.1-pro-preview`), sk-bench #1 v slovenčine, WMT26 en-cs v top skupine.
- Druhý recenzent: **GPT-5.5** (`gpt-5.5`), WMT26 en-cs 77.1, sk-bench 71.0.
- Predtriedenie: **Gemini 3.8 Flash** (platený prepay, centy).
- Vlastný test 2026-09 (preklady): Gemini 2.5 Pro > GPT-4.1 > DeepL v sk aj cs.

## Postup
| Krok | Čo | Stav |
|------|----|------|
| 226.1 | Extrakcia textov s kontextom (`scripts/copy_review/extract.py`) | hotové |
| 226.2 | Pevné kontroly podľa pravidiel (`checks.py`) | hotové |
| 226.3 | Predtriedenie Gemini Flash (`screen.py`), kandidáti = 226.2 ∪ 226.3 | hotové: 173/725 podozrivých, ~$1.8 |
| 226.4 | Pilot: kandidáti + 25 kontrolných → len Gemini 3.1 Pro (founder: max ~$1), `pilot.py --only=gemini --budget=0.95` | hotové: 64/71 volaní, 52 nálezov v 31 textoch, 1 na kontrolných, $0.91 |
| 226.5 | Founder posúdi nálezy v [artefakte](https://claude.ai/artifact/Q8Z8fwHHVcyDYbx6JyTA1D) (voľby v db `verdicts/fN`) → presnosť | hotové: 45/52 správne (87 %), 7 zamietnutých |
| 226.6 | Founder rozhodne o plnej kontrole (rozsah, modely, cena) | hotové 11-05: len Gemini, strop $4 |
| 226.7 | Plná kontrola (`full.py`: zvyšok appky, hovorené + povely, App Store, web, témy, právne texty) → verdikty v [artefakte](https://claude.ai/artifact/W1QU3QB6wDKHfcmret4gKE) → opravy cez PR | 121/121 volaní, 48 nálezov, $1.63; founder schválil 14 (vykanie na tematických stránkach, povely v popise App Store, „Odpovedalo“), právne texty ostávajú vo „vy“ |

Behy: `docs/testing/runs/copy-review-2026-11-04/`.

## Zistenia
- „Ďalšia“ vs „Ďalej“ (founder: rozhodni ty): obe ostávajú, sú to dve akcie (preskoč na ďalšiu otázku vs pokračuj po výsledku); copy-style pravidlo 3 doplnené, nálezy 7, 10, 13 neaplikované, 11 len čiarka.
- Aplikované opravy: PR #732; počty v upozorneniach na zostávajúce otázky prerobené na tvary pre počet (substitutions), rodovo neutrálne „chceš“ namiesto „žiadal si“.
- Flash predtriedenie je drahšie na výstup (premýšľanie ~2× vstup); pri plnej kontrole rátať s tým.
- Plná kontrola: presnosť len 14/47 (30 %) oproti pilotu 87 %, pretože pilot dostal predvybrané podozrivé texty. Bez predvýberu model veľa nálezov vymýšľa (napr. tlačidlo „Preskoč“ v sprievodcovi, „Skús znova“).
- Model prehliadol vykanie „než by ste čakali“ na tematickej stránke; opravené ručne. Pevné kontroly (`checks.py`) treba pustiť aj na web.
- Popis v App Store sa prejaví až pri najbližšom nahraní textov (#220).
