# #229 — Kontrola vyhľadávania otázok a duplicít (embeddingy)

**Triage:** enhancement · ready-for-agent
**Status:** založené 2026-11-05; nezačaté
**Založené:** 2026-11-05 (founder)
**Súvisí:** #228 — vlastný balík vždy plný (doplnenie z knižnice stojí na podobnosti), #170 — coverage-driven dedup, ivfflat zrušený (PR #540), sudca rovnakého faktu zapnutý (PR #542), čistenie korpusu (PR #552)

## Cieľ

Founder: „rag/embedding databáza otázok a teda kontrola duplicít a celkovo ako funguje táto technológia u nás, či je dobre nastavená“. Výstup = zrozumiteľný prehľad, čo funguje, čo nie a čo opraviť; opravy ako samostatné úlohy.

## Čo preveriť

1. **Ako to funguje:** kde sa embeddingy vytvárajú (model, jazyk, z akého textu: otázka, odpoveď, obe), kde sa čítajú (výber otázok v hre, dedup pri generovaní, dedup pri importe, hotové balíky #225).
2. **Nastavenie:** index v Postgrese (po zrušení ivfflat: presné hľadanie, rýchlosť pri raste korpusu), prahy podobnosti a odkiaľ sa vzali, sk/cs/en (porovnáva sa naprieč jazykmi?).
3. **Kvalita dedup:** vzorka dvojíc tesne nad a pod prahom → koľko skutočných duplicít uniká a koľko rôznych otázok sa zbytočne zahodí. Sudca rovnakého faktu: koľko stojí a ako často mení výsledok.
4. **Pokrytie:** chýbajúce embeddingy, staré embeddingy po prepise textu otázky.
5. **Pre #228:** aký prah zhody je „fakt vysoký“ pre doplnenie z knižnice.

## Pravidlá
- Len čítanie produkcie; žiadne zmeny dát bez súhlasu.
- Výstup: krátky prehľad v chate (plus artefakt, ak treba niečo posúdiť), nie dlhý report.

## Úlohy
- [ ] 229.1 mapa (1) + nastavenie (2)
- [ ] 229.2 meranie dedup na vzorke (3, 4)
- [ ] 229.3 návrh prahu pre #228 (5) + zoznam opráv → founder
