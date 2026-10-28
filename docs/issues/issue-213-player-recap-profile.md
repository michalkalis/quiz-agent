# #213 — Prehľad hráča (Wrapped) a záložka Profil

**Triage:** enhancement · ready-for-agent
**Founder:** 2026-10-27/28 · rešerš [player-recap-wrapped-2026-10-27.md](../research/player-recap-wrapped-2026-10-27.md) · návrh obrazoviek https://claude.ai/artifact/TZdKxSW2v1rdzncgCedQiV

## Cieľ

Hráč vidí zábavné štatistiky o tom, ako hrá (silná kategória, kde a kedy hrá, bežná hra, zlepšovanie, najrýchlejšia kategória), kedykoľvek v novej záložke Profil. Mesačne a ročne dostane prehľad ako príbeh na snímkach, ktorý vie zdieľať na Instagram a TikTok.

**Hotovo, keď:** Profil s kartami beží v appke (sk/cs/en), karty sa odomykajú podľa prahov, mesačný prehľad sa vytvorí sám, posledná snímka sa dá zdieľať ako obrázok, a meriame otvorenie aj zdieľanie.

## Rozhodnutia foundera

| Kedy | Rozhodnutie |
|---|---|
| 10-27 | Len smer Spotify Wrapped. Pohyb telefónu, hlas, váhanie, emócie NIE. |
| 10-27 | Rytmus: mesačne + ročne (december), štatistiky kedykoľvek v appke. |
| 10-27 | Celé zadarmo. Zdieľateľná karta hneď v prvej verzii. |
| 10-28 | Dolná lišta **B**: dve záložky „Hrať“ a „Profil“. Balíčky a nastavenia idú do Profilu. Počas kvízu lišta skrytá. |
| 10-28 | Profil **variant 1**: prehľad navrchu, mriežka kariet, zamknuté karty s postupom, nastavenia pod ozubeným kolieskom. Príbehové snímky schválené („super“). |
| 10-28 | Nastavenia treba premyslieť: dostupné z Home aj z obrazovky kvízu, iné pre solo a hru spolu. |

## Prahy (z rešerše)

- Prvý prehľad: 60 odpovedí v 3+ dňoch (~40 min hry, prod: ~40 s na otázku).
- Mesačný: 30+ odpovedí v 2+ dňoch v mesiaci, inak sa mesiac ticho preskočí.
- Ročný: 150+ odpovedí, dáta do 30. novembra.
- Každá karta má vlastný prah (tabuľka v rešerši). Prahy sú konfigurácia na serveri, aby sa dali prepočítať bez buildu.

## Hranice

- Žiadne AI vo výpočte, len počty nad `analytics_events` (+ `daily_challenge_answers`).
- Žiadne nové povolenia v appke. Poloha nie.
- API len pridáva (nový endpoint, nové voliteľné vlastnosti udalostí), živé buildy fungujú ďalej.
- Hra spolu (session quiz-agent-81, rešerš [multiplayer-same-room-2026-10-23.md](../research/multiplayer-same-room-2026-10-23.md)): odpovede v hre spolu sa rátajú do štatistík každého hráča pod jeho `subject_id`, s príznakom hry spolu. Tlačidlo SPOLU vedľa Štartu na záložke Hrať je s lištou B v súlade.

## Úlohy

Poradie: 213.1 hneď (dáta sa musia zbierať pred spustením), potom 213.2 → 213.3, súbežne 213.4.

- [ ] **213.1 Chýbajúce merania** — časové pásmo hráča pri štarte hry (`quiz_context`), čas od otvorenia mikrofónu po začiatok reči na odpoveď (`answer_captured`). Allowlist v `taxonomy.py` + iOS + `docs/product/analytics-events.md`. Malé, ide samostatne.
- [ ] **213.2 Výpočet štatistík (server)** — služba nad udalosťami hráča: karty, stav zamknutia a postup („ešte 2 hry“). Endpoint pre appku. Porovnanie zlepšenia pri rovnakej obťažnosti. Testy na prahy a hranice (prázdny hráč, presne na prahu, jedna kategória).
- [ ] **213.3 Prehľady (server)** — prvý, mesačný (1. deň mesiaca za predošlý), ročný (december). Uložená snímka prehľadu, aby sa po čase nemenil. Typ hráča podľa pevných pravidiel. Mazanie spolu s účtom.
- [ ] **213.4 Lišta a Profil (appka)** — natívna dolná lišta (Hrať, Profil), skrytá počas kvízu. Home bez ozubeného kolieska. Profil: účet, prehľad navrchu, mriežka kariet, Moje balíčky, nastavenia. Rýchle nastavenia hry z Home aj z kvízu (koordinovať s hrou spolu: ktoré platia v hre spolu a predvolené hodnoty, napr. hlasové povely vypnuté, definuje multiplayer plán). Identifikátory, snímky obrazoviek, RS scenár.
- [ ] **213.5 Príbeh a zdieľanie (appka)** — prehrávanie snímok, posledná snímka ako obrázok 9:16 na zdieľanie. Texty sk/cs/en cez copy review, veľké nadpisy na jeden riadok.
- [ ] **213.6 Meranie** — udalosti: otvorenie Profilu, prehľad videný (koľko snímok), zdieľaný. Vyhodnotenie po prvom mesačnom prehľade.
- [ ] **213.7 Zásady ochrany súkromia** — veta o štatistikách z herných dát a o časovom pásme.

## Otvorené

- Nezávislá kontrola návrhu dát (`/design-soundness`) pred 213.2/213.3.
- Oznámenie nového prehľadu: zatiaľ len značka na záložke Profil, push notifikácie nie.
- Hráč bez prihlásenia: štatistiky „na tomto zariadení“, po prihlásení sa spoja.
