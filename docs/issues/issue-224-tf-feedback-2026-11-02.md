# #224 — TF test 2026-11-02: Hra spolu, Home, výsledky, vlastné balíky

**Triage:** enhancement · ready-for-agent (rýchle opravy) · ready-for-human (návrhy na výber, 2 rozhodnutia)
**Status:** 224.1–224.3 zlúčené (PR #694 #697 #698, quiz-pack-api nasadené); 224.3b zadanie AI čaká na skúšku (PR #701); návrhy vybrané 2026-11-03 → 224.4–224.6, 224.8, 224.9 v práci; 224.7 odložené
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
14. Sólo výsledok po pauze: tlačidlo „Pokračuj“ má rozbitý layout (text širší ako tlačidlo).
15. Bežná a rýchla hra: v rýchlej hre „Ďalšia“ prejde hneď na ďalšiu otázku bez výsledku a vysvetlenia; s analytikou; návrhy.
16. Sólo otázka: písanie odpovede je nevýrazné; napr. rovnako výrazné ako „Odpovedz“, „Ďalšia“ menej výrazná, bez textu; návrhy.

## Rozhodnutia foundera (2026-11-02)

- **Obťažnosť vlastného balíka:** Ľahká / Stredná / Ťažká, povinný výber bez predvoľby.
- **Hlasové odpovede v Hre spolu:** odložené; najprv vyladiť Hru spolu a pozrieť dáta (v jednej miestnosti mobily počujú aj ostatných).
- **Zadanie pre AI pri zvolenej obťažnosti (2026-11-03):** upraviť, aby úroveň dodržalo, a overiť skúšobnými otázkami pred nasadením (≤ 4 $).
- **Výber z plátna (2026-11-03, https://claude.ai/artifact/3cu7qxk8Ti1M24q9Z1k4v9):** otázka v Hre spolu B (tváre hráčov a čas nad väčšou kartou, ťuk na kartu = prečítať znova); pauza medzi otázkami P1 („Zostaň“ vedľa „Ďalej“, hostia vidia „Hostiteľ dal pauzu“); sólo výsledok B1b (neutrálna karta, zelená len pri správnej); koniec kola B4a („7 z 10“, jedna farba); odhalenie v Hre spolu B2b (A–D s tvárami, písané odpovede ako zoznam B2a); koniec hry B3a (poradie + otázky na rozbalenie); kategórie C1 (karta odíde dozadu vejára); bežná/rýchla hra D2 (riadok „Rýchla hra“ pod výbermi, po „Ďalšia“ krátko „Preskočené, správne: X“); päta otázky E1 („Odpovedz“ a „Napísať“ vedľa seba, „Ďalšia“ len ikona).
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
| 224.3b | 12 | Zadanie pre AI vynúti zvolenú úroveň; skúšobné otázky v artefakte | quiz-pack-api (PR #701) |
| 224.4 | 1, 3, 7 | Hra spolu: otázka B, pauza medzi otázkami P1 (stav pauzy na serveri, hostia ju vidia), odhalenie B2b/B2a | iOS + backend |
| 224.5 | 8 | Hra spolu: koniec hry B3a s odpoveďami všetkých | iOS |
| 224.6 | 6 | Kategórie na Home ťukom vľavo/vpravo, animácia C1, pri obmedzení pohybu len prelínanie | iOS |
| 224.7 | 9 | Platené hlasové odpovede v Hre spolu | odložené (founder) |
| 224.8 | 15 | Rýchla hra (D2) + analytika | iOS |
| 224.9 | 11 | Sólo výsledok B1b a koniec kola B4a | iOS |
| 224.10 | 16 | Päta sólo otázky E1 | iOS |

Poradie: 224.1–224.3 hotové. Ďalej tri prúdy naraz, v každom PR po jednom: Hra spolu (224.4 → 224.5), Home (224.6 → 224.8), sólo (224.9 → 224.10).
