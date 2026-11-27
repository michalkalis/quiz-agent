# Issue #251 — TF test 2026-11-27: pripomienky k 1.3

**Triage:** in progress · founder 2026-11-27 (TF 1.3 build 94, tá ide do App Store bez týchto zmien; App Store prípravu robí session quiz-agent-1d)

## Pripomienky foundera

1. Výsledok otázky: pauza hlasu medzi odpoveďou a vysvetlením je zbytočne dlhá.
2. Otázka, fáza „Premýšľaj“: nápoveda hlasových povelov, možno nový povel na pauzu, hlasová nápoveda pri prvých otázkach. **Návrhy na rozhodovacej stránke, founder vyberie.**
3. Výsledok otázky: „Ďalej“ ukazuje „3 s“ aj počas čítania; sekundy až keď odpočet naozaj beží (po dočítaní).
4. Denná výzva po dohraní: zoznam otázok s mojou a správnou odpoveďou.
5. Po „Štart“ sa obrazovka objaví bez animácie → pridať animáciu.
6. Home, denná výzva: „Dnes máš 9 otázok navyše“ → povedať, že som ich získal (rodovo neutrálne, všetky jazyky).

## Rozhodnutia foundera

- 2026-11-27: ukrajinčina v App Store verzii zatiaľ vypnutá; 1.3 store build 95 ju skrýva (quiz-agent-1d, PR #1015), v bete ostáva.
- 2026-11-27 (rozhodovacia stránka): povely pri „Premýšľaj“ vyzerajú ako v iných fázach; len prvé 3 otázky kvízu a len v prvých kvízoch, potom exponenciálne zriedkavejšie (10, 20, 40…); hlasový tip raz v prvom kvíze, nie hneď na začiatku (okolo 5. otázky), text nie „keď budeš vedieť“, ale „nemusíš čakať do konca času“, chce viac návrhov; povel „pauza“ NIE; animácia po Štart zatiaľ nie, neskôr natívne (okno cez celú obrazovku); text odmeny A, otázky navyše platia do polnoci.

## Kroky

- [x] 251.1 — body 1 + 3 (časovanie hlasu a odpočtu na výsledku) — PR #1014
- [x] 251.2 — bod 4 (zoznam otázok v dennej výzve) — PR #1014, len pre kolo hrané na tomto telefóne
- [x] 251.3 — bod 6 „Odmena: dnes ešte N otázok navyše“ — PR #1014 (snímky na iPhone 18 Pro hotové)
- [ ] 251.5 — bod 5 animácia po Štart: vysunutie ako zmena obrazovky skúsené a vyhodené (lišta je v systémovej navigácii, ostala hore; zatvorenie sa nezasunulo). Founder 11-27: zatiaľ nič, neskôr natívne riešenie (okno cez celú obrazovku; presunúť okná, ktoré sa otvárajú počas kvízu)
- [~] 251.4 — povely pri „Premýšľaj“: zobrazené od začiatku odpočtu (nečakajú na živý mikrofón, ten naskočí až po „Premýšľaj“ a rozbehu rozpoznávania), plán kvízy 1–3, potom 10., 20., 40.… (predbežne, potvrdenie na druhej stránke)
- [ ] 251.6 — hlasový tip: text a chvíľa čakajú na druhú rozhodovaciu stránku (návrh: „Na koniec času čakať nemusíš…“, keď hráč prvýkrát nechá dobehnúť celý čas, inak na 5. otázke)
