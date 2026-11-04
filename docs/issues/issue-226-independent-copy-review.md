# #226 — Nezávislá kontrola textov iným modelom (sk · cs · en)

**Triage:** wip · founder 2026-11-04

## Cieľ
Všetky texty, ktoré hráč vidí alebo počuje, prejde model mimo Anthropicu, lebo texty písal a prekladal Claude. Kontrola vždy dostane kontext: poznámku vývojára, obrazovku (súbor) a susedné texty, štýlové pravidlá `docs/design/copy-style.md`.

**Hotové =** pilot na podozrivých textoch vyhodnotený founderom → founder rozhodne o plnej kontrole → plná kontrola všetkých textov (appka, hovorené texty a povely, App Store, web) → opravy cez PR.

## Rozhodnutia foundera
- 2026-11-04: najprv automaticky nájsť podozrivé texty, tie poslať na pilot; plná kontrola všetkých textov (appka, hovorené + povely, App Store, web) až po pilote a finálnom rozhodnutí.
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
| 226.3 | Predtriedenie Gemini Flash (`screen.py`), kandidáti = 226.2 ∪ 226.3 | beží |
| 226.4 | Pilot: kandidáti + kontrolná vzorka bez nálezu → Gemini 3.1 Pro + GPT-5.5, nálezy v JSON (MQM kategória, závažnosť, citát, oprava) | |
| 226.5 | Founder posúdi nálezy pilotu v artefakte → presnosť oboch recenzentov | |
| 226.6 | Founder rozhodne o plnej kontrole (rozsah, modely, cena) | |
| 226.7 | Plná kontrola + opravy cez PR (zhoda oboch = navrhnúť opravu, nezhoda = founder) | |

Behy: `docs/testing/runs/copy-review-2026-11-04/`.
