# #224 — TF test 2026-11-02: Hra spolu, Home, výsledky, vlastné balíky

**Triage:** enhancement · ready-for-agent (rýchle opravy) · ready-for-human (návrhy na výber, 2 rozhodnutia)
**Status:** založené 2026-11-02; tracky 224.1–224.3 bežia, návrhy 224.4–224.6 na plátne; 224.7 odložené
**Založené:** 2026-11-02 (founder testuje TF build, sk/cs)
**Súvisí:** #212 — Hra spolu (multiplayer v jednej miestnosti), #216 — záložky Hrať + Profil, #208 — hlasové povely z TF testu, #93 — vlastné balíky

## Nálezy (founder, 2026-11-02)

1. Obrazovka otázky v Hre spolu zaostáva za sólom: text otázky stále odskrolovaný dole, neposúva sa s čítaním, okno malé, zbytočný indikátor skrolovania, celý layout iný a nevyladený. Napodobniť sólo, kde to dáva zmysel.
2. „Založ hru“ je širšie ako lišta záložiek; lišta sa pri skrolovaní Home nemá schovať do Play, stačí ak sa zmenší.
3. Po vypnutí čítania v pravidlách hry čítanie hneď neprestane; chýbajú tlačidlá stlmiť, prečítať znova a pod.
4. Čas na odpoveď v Hre spolu zadať aj ručne.
5. Home: zrušiť hlasové povely aj malý panel s nimi (štart tlačidlom stačí).
6. Kartičky kategórií na Home: ťuk vpravo = ďalšia kategória, vľavo = predchádzajúca, s animáciou; návrhy animácií.
7. Hra spolu: medzi otázkami chýbajú akcie (pauza).
8. Hra spolu, výsledky: chýba kto ako odpovedal; obrazovka nevyladená; návrhy.
9. Odpovedanie hlasom v Hre spolu by mohlo byť platené.
10. Sólo, výsledok: počúvanie povelov zbytočné (stačí tlačidlo), mätie.
11. Výsledkové obrazovky neprehľadné: veľa farieb, preťažené informáciami; premyslieť layout.
12. Vlastný balík: povinný výber obťažnosti (balíky boli príliš ľahké); bez výberu sa nedá generovať.
13. Tlačidlo aj povel „Preskoč“ → „Ďalšia“ (cs „Další“, en „Next“): ľahšie sa vyslovuje, intuitívnejšie.

## Rozhodnutia foundera (2026-11-02)

- **Obťažnosť vlastného balíka:** Ľahká / Stredná / Ťažká, povinný výber bez predvoľby.
- **Hlasové odpovede v Hre spolu:** odložené; najprv vyladiť Hru spolu a pozrieť dáta (v jednej miestnosti mobily počujú aj ostatných).
- **Lišta záložiek (agent):** systém nemá režim „trochu zmenšiť“, preto lišta ostáva celá (nezmenšuje sa vôbec).

## Zistenia z kódu

- Otázka v Hre spolu je karta s pevným stropom výšky, skrolovaním ukotveným dole a bez automatického posunu; sólo má automatický posun textu (časovaný, nie podľa čítania) a ovládanie stlmiť / pauza / zopakovať.
- Vypnutie čítania len uloží nastavenie; prebiehajúce prehrávanie nikto nezastaví.
- Server berie čas na odpoveď 3–60 s, appka ponúka len 15/30/45/60.
- Pauza v Hre spolu neexistuje ani na serveri; automatický posun na ďalšiu otázku riadi mobil hostiteľa.
- Server už posiela odpovede všetkých hráčov ku každej otázke; koncová obrazovka ukazuje len vlastnú odpoveď.
- Lišta záložiek sa zmenšuje systémovým správaním „pri skrolovaní dole“ (#216); systém nemá medzistupeň „trochu zmenšiť“.
- Obťažnosť vlastného balíka: generátor ju vie použiť, ale objednávka ju neprenáša (chýba v požiadavke, v databáze aj pri spustení generovania).
- Hlasové odpovede v Hre spolu dnes neexistujú (všetci ťukajú alebo píšu).

## Tracky

| Track | Nález | Čo | Kde |
|---|---|---|---|
| 224.1 | 5, 10, 13 | Home a sólový výsledok bez počúvania povelov a bez panelu; „Preskoč“ → „Ďalšia“ / „Další“ / „Next“ na tlačidle, v nápovedách aj ako povel, staré slovo ostáva skrytým synonymom | iOS |
| 224.2 | 2, 3 (zastavenie), 4 | Vypnutie čítania zastaví prehrávanie hneď a otvorí otázku; čas na odpoveď aj ručne (predvoľby + vlastná hodnota 3–60 s); „Založ hru“ v šírke lišty; lišta sa pri skrolovaní neschová | iOS |
| 224.3 | 12 | Povinná obťažnosť vlastného balíka: výber vo formulári, pole v objednávke (voliteľné kvôli starším buildom), stĺpec v databáze, odovzdanie generátoru | iOS + quiz-pack-api |
| 224.4 | 1, 3 (tlačidlá), 7 | Návrh: otázka a medzi-obrazovka Hry spolu ako sólo (veľká karta, posun textu, stlmiť / zopakovať / pauza pre hostiteľa) | plátno → iOS + backend (pauza) |
| 224.5 | 8, 11 | Návrh: výsledky (sólo po otázke, Hra spolu po otázke a na konci s odpoveďami všetkých) pokojnejšie, menej farieb | plátno → iOS |
| 224.6 | 6 | Návrh: prepínanie kategórií ťukom, 3 animácie | plátno → iOS |
| 224.7 | 9 | Platené hlasové odpovede v Hre spolu | odložené (founder) |

Poradie: 224.1, 224.2 a 224.3 paralelne (každý vlastný PR); 224.4–224.6 po výbere foundera.
