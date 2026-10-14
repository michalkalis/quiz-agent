# #203 — Otrepané otázky: vyčistiť zásobu a zabrániť novým

**Triage:** enhancement · in-progress
**Založené:** 2026-10-14 (founder z TF: otázka „Ktorá žena v roku 1955 v Alabame odmietla uvoľniť miesto v autobuse…“ = „hrozná otázka … nezaujímavá“; „nezábavnosť otázok je úplne kritická vec“)
**Súvisí:** [kalibrácia 07-09](../research/question-quality-founder-calibration-2026-07-09.md) (founder: otrepané otázky rovno vyradiť, bez prepisovania), [prior art 07-10](../research/question-craft-prior-art-2026-07-10.md) (4.6: rozhoduje otázka, nie známosť faktu), #201 — zábava, na ktorú sa dá odpovedať (kontrola „bežný hráč“ nepredpovedala hodnotenie → preto slepé overenie pred nasadením)

## Cieľ a kedy je hotovo

Zo schválenej zásoby zmiznú otrepané učebnicové otázky a nové sa do nej nedostanú.
**Hotovo** = (1) founder naslepo potvrdí, že kontrola sa zhoduje s jeho vkusom; (2) označené otázky sú v archíve (nič sa nemaže) a zásoba kategórií ostáva nad strážnou hranicou #199; (3) kontrola beží pri generovaní.

## Diagnóza (2026-10-14)

- Otázka `4309b697…` (history, `direct_v1`, claude-fable-5, 2026-10-01): schválená strojovo (`machine:gates-v1`), prešla len overením faktu (0,9) a deterministickými kontrolami znenia. Žiadne hodnotenie zábavy ani otrepanosti sa nepočítalo.
- Od zoštíhlenia #166 sú porotcovia (`JUDGE_GATE`) aj kritika s pravidlom „Overexposed Cliché“ (`BEST_OF_N`) vypnuté: nepredpovedali zábavu (Spearman ≤ 0,21). Nič ich pri otrepaných otázkach nenahradilo. Prompt generovania má len mäkkú vetu „nenechaj dávku stáť na klasikách“.
- Zásoba: 1 465 schválených, 1 212 mimo zábavy. 904 vzniklo jedným hromadným behom 2026-10-01.
- Ručná vzorka 80 otázok: 21 % otrepaných (s hraničnými ~30 %). Ďalej 3 páry takmer duplicitných otázok, jedna pokazená MCQ bez možností v znení a jedna, ktorá prezrádza odpoveď (mimo rozsahu tohto issue).

## Rozhodnutia foundera (2026-10-14)

- **Vyčistiť aj zabrániť.** Kontrolu najprv naslepo overí founder, potom archív + zapojenie do generovania.
- **Len otrepané**, nie „cudzie témy“: svetová téma s prekvapivým uhlom ostáva aj v sk/cs.

## Riešenie

### 203.1 Kontrola „otrepaná otázka“ (hotové v PR)

`app/verification/stock_question.py`: jedno dávkové volanie (20 otázok), Opus 5.5 (`LLM_ROLE_STOCK_QUESTION`). Pri chybe sa otázka ponechá. Kotvy sú founderove hodnotenia z 07-09 (King of Pop, mendelévium, Monopoly, Rio → otrepané; míľa, Point Nemo, Kleopatra, Dumbledore → nie) plus Rosa Parks.
- v1 promptu hodnotila očami kvízového fanúšika → 63 % otrepaných (aj „hroch je príbuzný veľryby“). v2 = očami bežného dospelého, ktorý hrá kvíz raz za čas, „pri pochybnosti nie“ → **273 / 1 212 (23 %)**, sedí s ručnou vzorkou. Rosa Parks označená.
- Skript `scripts/classify_stock_questions.py` (len čítanie). Výsledky sú v `docs/testing/runs/stock-questions-2026-10-14/verdicts.json` (v1 v `verdicts-v1-too-strict.json`).

### 203.2 Slepé overenie (čaká na foundera)

30 otázok (15 označených + 15 ponechaných, seed 203, zamiešané): https://claude.ai/artifact/36gGSiEMXVdpZeouTKPDLk. Kľúč je v `blind_key.json`.
Prah: ≥ 12/15 označených founder vyhodí a ≤ 3/15 ponechaných by vyhodil → ide sa ďalej. Inak sa podľa jeho poznámok upraví prompt a overenie sa zopakuje.

### 203.3 Archív

Označené otázky → `archived` s poznámkou `#203 stock question`. Návrat je jeden UPDATE. Pred zápisom sa skontroluje zásoba po kategóriách proti hranici #199. Rozšíriť `archive_questions.py` o zoznam id.

### 203.4 Generovanie

Kontrola sa zapojí do `ScoringStage` rovnako ako kontrola „bežný hráč“ z #201 (CLI + worker, aj týždenný job #202), za vypínačom `STOCK_QUESTION_GATE`. Zapne sa po 203.2. Otrepaná otázka vypadne a top-up ju nahradí.

## Stav

- [x] 203.1 kontrola + beh nad zásobou
- [ ] 203.2 slepé overenie founderom
- [ ] 203.3 archív v prode
- [ ] 203.4 zapojenie do generovania + zapnutie
