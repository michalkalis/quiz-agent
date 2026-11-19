# #241 — Vianoce 2026: vianočné otázky a príspevky na sociálne siete

**Triage:** ready-for-agent · enhancement
**Status:** 73 otázok v produkcii (2026-11-18); videá čakajú na denný limit hlasu
**Session:** quiz-agent-47 · 2026-11-18

## Cieľ

Malý sezónny krok, operatívne, bez nových funkcií v appke (founder 2026-11-18: „okej priprav… už aj tento týždeň alebo budúci môže ísť niečo na socials ohľadne Vianoc“). Rešerš: `docs/research/seasonal-themes-and-competition-2026-11-18.md`.

## Rozhodnutia

- Otázky o histórii a tradíciách, nie o správach. Bez politiky a vojen, náboženstvo kultúrne a fakticky.
- sk a cs majú natívne sady (Ježiško, kapor, rozprávky), en má vlastnú sadu. Žiadne preklady.
- Generuje sa na predplatnom Claude (`LLM_GATEWAY=session`), rovnakým postupom ako ostatné otázky: zdroj, kontrola faktov, štýl.
- Server nevie zvýhodnenie od dátumu (`boost_until` má len koniec). Preto:
  - otázky sa importujú hneď ako schválené, bez zvýhodnenia, aby sa dali použiť v príspevkoch;
  - 1. 12. sa im jedným príkazom nastaví zvýhodnenie do 27. 12. Denná výzva potom dáva jednu vianočnú otázku denne a bežné kvízy ich vyberajú dvakrát častejšie.
  - Ak to treba opakovať, pridať do servera začiatok zvýhodnenia. Teraz by to bola zbytočná práca.

## Úlohy

- [x] 241.1 Vygenerovať 8 tém × 4 otázky v sk, cs, en (`docs/testing/runs/christmas-2026-11-18/run.sh`): 31 + 31 + 32.
- [x] 241.2 Výber cez nezávislých recenzentov (`review-<lang>.json`, `merge.py`): sk 24, cs 22, en 27. Vyradené duplicity so živými otázkami, odpovede, ktoré sa hlasom nedajú vyhodnotiť, slabé zdroje a fakty, ktoré sa môžu zmeniť.
- [x] 241.3 Import do produkcie ako schválené (`run_import.sh`): 73 riadkov so štítkom `christmas-2026`, overené v databáze.
- [x] 241.4 Príspevky: krátke video s 3 otázkami (round) pre oba Instagram účty. Founder schválil 2026-11-19, naplánované v `batches/2026-W48.json` a `2026-W49.json` (Instagram + Facebook; YouTube a TikTok nie).
  - 29. 11. (1. adventná nedeľa): sk 74d5f281, 12339e3d, 03ac60b8; en 2bd67f18, 20a0f4e4, 63372a84.
  - 5. 12. večer (Mikuláš v Česku): cs 4065c0bb, 159187d4, b8eb51f5. 6. 12. (St Nicholas Day): en 3164feae, 1665056c, a07de814.
  - Hlas: nový hlas pre sociálne siete (#210, PR #892), vlastný vianočný úvod cez `--open-line` (PR #904). Founderovi znie český hlas divne, výmena českého hlasu je samostatná úloha.
- [ ] 241.5 1. 12.: nastaviť zvýhodnenie do 27. 12. pre otázky z tejto sady (id v `ids.txt`).
- [ ] 241.6 27. 12.: nastaviť zvýhodnenie do 6. 1. pre novoročné otázky (Silvester, Nový rok, Traja králi, kalendár; 32 otázok sk/cs/en nahraných 2026-11-19 so štítkom `new-year-2026`, id v `docs/testing/runs/seasonal-2026-11-19/ids.txt`). Rovnaký príkaz ako pri 241.5.
