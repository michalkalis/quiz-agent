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

- 2026-11-27: ukrajinčina v App Store verzii zatiaľ vypnutá (rieši quiz-agent-1d, len server).

## Kroky

- [x] 251.1 — body 1 + 3 (časovanie hlasu a odpočtu na výsledku) — PR #1014
- [x] 251.2 — bod 4 (zoznam otázok v dennej výzve) — PR #1014, len pre kolo hrané na tomto telefóne
- [x] 251.3 — body 5 + 6 (vysunutie zdola, „Odmena: dnes ešte N otázok navyše“) — PR #1014; animáciu ešte overiť na simulátore
- [ ] snímky dennej výzvy a Home s odmenou nahrať na iPhone 18 Pro (lokálny disk bol plný)
- [ ] 251.4 — bod 2 podľa výberu foundera (rozhodovacia stránka 11-27: vzhľad, kedy, hlasová nápoveda, povel „pauza“, text odmeny)
