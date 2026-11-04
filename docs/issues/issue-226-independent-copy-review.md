# #226 — Nezávislá kontrola textov iným modelom (sk · cs · en)

**Triage:** wip · founder 2026-11-04

## Cieľ
Všetky texty, ktoré hráč vidí alebo počuje, prejde model mimo Anthropicu, lebo texty písal a prekladal Claude. Kontrola vždy dostane kontext: poznámku vývojára, obrazovku (súbor) a susedné texty, štýlové pravidlá `docs/design/copy-style.md`.

**Hotové =** pilot na podozrivých textoch vyhodnotený founderom → founder rozhodne o plnej kontrole → plná kontrola všetkých textov (appka, hovorené texty a povely, App Store, web) → opravy cez PR.

## Rozhodnutia foundera
- 2026-11-04: najprv automaticky nájsť podozrivé texty, tie poslať na pilot; plná kontrola všetkých textov (appka, hovorené + povely, App Store, web) až po pilote a finálnom rozhodnutí.
- 2026-11-04: pilot len Gemini, „fakt max okolo $1“.
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
| 226.5 | Founder posúdi nálezy v [artefakte](https://claude.ai/artifact/Q8Z8fwHHVcyDYbx6JyTA1D) (voľby v db `verdicts/fN`) → presnosť | čaká na foundera |
| 226.6 | Founder rozhodne o plnej kontrole (rozsah, modely, cena) | |
| 226.7 | Plná kontrola + opravy cez PR (zhoda oboch = navrhnúť opravu, nezhoda = founder) | |

Behy: `docs/testing/runs/copy-review-2026-11-04/`.

## Zistenia
- Konflikt: copy-style pravidlo 3 uvádza sk „Ďalej“, tlačidlo je od #224 „Ďalšia“ → manuál opraviť podľa verdiktu foundera (nálezy 7, 10, 11).
- Flash predtriedenie je drahšie na výstup (premýšľanie ~2× vstup); pri plnej kontrole rátať s tým.
