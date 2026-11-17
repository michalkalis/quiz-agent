# #236 — Rodinná sekcia „S deťmi“

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-15 plán uznaný (SOUND 0.8); 236.1 hotové na serveri (PR #803) aj vo formulári appky (PR #806, vyjde s ďalším buildom); kontroly kvality posudzujú detský balík očami dieťaťa daného pásma (PR #807, naživo); druhá skúška 2026-11-17: „vcelku zábavné“, pridané pravidlo o veľkých číslach (PR #818); ďalej 236.2 texty a 236.3 návrh obrazoviek sekcie
**Founder:** 2026-11-15 „do kvízu by sa veľmi hodila trochu viac separátna sekcia pre deti … ide skôr o to, aby rodičia mohli hrať s deťmi. Hlavne mať detské témy, možno deliť podľa veku.“

## Prečo

Rodiny s deťmi sú od MVP prvý smer rastu, ale dnes pre ne v appke nie je nič:

- Detská kategória zanikla pri prechode na záujmové kategórie (2026-08-26). 52 otázok je v archíve, nehrá sa žiadna.
- Pole vhodnosti podľa veku na otázke (`age_appropriate`: all / 8+ / 12+ / 16+) existuje v modeli, generátore aj nastaveniach appky, ale pri výbere otázok sa nepoužíva.
- Formulár vlastného balíka radí zadať „vesmír pre deti“, ale balík sa generuje postupom pre dospelých: produkcia beží v priamom režime (`question_generation_direct.md`, „broad international adult audience“), detská šablóna je napojená len na režim so zdrojovými faktami a na zrušenú kategóriu `kids`, navyše je písaná pre 8–14 rokov.

## Rozhodnutia foundera (2026-11-15)

| Otázka | Voľba |
|---|---|
| Čím začať | Najprv vek pri vlastnom balíku, potom sekcia „S deťmi“ |
| Vekové pásma | **4–6, 7–9, 10–12** hneď od začiatku |
| Otázky „na pokec“ (absurdné, bez správnej odpovede, bez bodov) | **Áno, už v prvej verzii** |

Skoršie: hádanky „čo som“ founder odmietol ako detinské klišé (2026-10-14), nepoužívať.

## Mantinely (Apple a súkromie)

Overené z App Store Review Guidelines 1.3, 2.3.8, 5.1.4:

- **Do Kids Category nevstupujeme.** Je dobrovoľná; zakazuje posielať hlas a údaje o zariadení tretím stranám, analytiku tretích strán, odkazy a nákupy mimo rodičovskej brány. S hlasom v cloude, Sentry, nákupmi a odkazmi na zdroje otázok je nesplniteľná, a kto raz vstúpi, musí pravidlá plniť natrvalo.
- **Mimo nej platí zákaz slov:** názov, podnadpis, ikona, snímky ani popis nesmú naznačovať, že hlavným publikom sú deti; „For Kids / For Children“ je vyhradené pre Kids Category. Kľúčové slová pravidlo nemenuje, berieme ich rovnako opatrne.
- **Sekcia s detskými témami vo vnútri appky zakázaná nie je.** Rámovanie: rodinné, „hraj s deťmi“, hráč a majiteľ účtu je rodič. Toto je náš výklad, Apple ho nikde výslovne nepotvrdzuje a overený precedens sa nenašiel.

Pravidlá návrhu, ktoré z toho plynú:

1. Žiadne detské účty ani profily. Vek je nastavenie obsahu („otázky pre 7–9“), nikdy údaj o osobe, a neposiela sa do analytiky ako vlastnosť hráča.
2. Nákupy a prihlásenie ostávajú v častiach pre rodiča; v sekcii žiadne výzvy na nákup počas hry.
3. V detských otázkach sa neotvára web so zdrojom (zdroj sa ukladá ďalej, len sa neponúka odkaz).
4. Texty v App Store a na webe: „rodinné“, „hraj s deťmi“, nie „pre deti“ ani „detský kvíz“.

## Riešenie

### 236.1 Vek pri vlastnom balíku

- Objednávka dostane nepovinnú voľbu „Pre koho“: dospelí (predvolené) / deti 4–6 / 7–9 / 10–12. Nepovinné pole, staré buildy fungujú bez zmeny.
- **Šablóna:** nový detský variant šablóny priameho režimu (tá istá cesta ako dnešná produkcia, žiadne prepínanie režimu generovania, teda rovnaká cena a overovanie; priamy režim dnes skladá zadanie raz na generátor, voľbu šablóny podľa objednávky treba doplniť). Pravidlá: bez násilia, alkoholu, romantiky, hororu, politiky; krátke vety, jednoduché slová. Stará šablóna pre 8–14 ostáva len ako podklad.
- **Pásmo a obtiažnosť sú dve osi:** pásmo určuje slovník, dĺžku a tvar otázky; obtiažnosť (ľahká / stredná / ťažká) znamená „v rámci pásma“. Šablóna nesmie vek odvodzovať z obtiažnosti.
- **Kontrola po vygenerovaní na serveri** (nález externej revízie 2026-08-09: nie len pokyn v zadaní): pevné limity dĺžky podľa pásma + malý model ako sudca zakázaných okruhov. Zoznam slov sme zavrhli, v štyroch skloňovaných jazykoch je krehký. Pri detskom balíku platí opak než inde: keď kontrola zlyhá alebo si nie je istá, otázka vypadne. Výpadok samotného sudcu sa neberie ako zamietnutie otázok: kontrola sa zopakuje a ak nejde ani potom, objednávka sa zastaví ako zlyhaná (bežná cesta vrátenia), aby dopĺňanie nekupovalo ďalšie behy v rámci rozpočtu objednávky zbytočne.
- Kontrola témy pred platbou (#233 — kontrola témy vlastného balíka) dostane detský stupeň (hraničná téma sa zastaví, nezjemňuje sa). Je to len pohodlie pre hráča: volá ju appka a pri chybe pustí, takže skutočnou poistkou sú šablóna a kontrola po vygenerovaní.
- Znovupoužitie hotových balíkov (#225 — hotové balíky znova) berie vek ako súčasť zhody, detský a dospelý balík na tú istú tému sa nezamieňajú.
- **Prvá skúška (2026-11-15, 3×4 otázky, 3,61 USD) a verdikt foundera:** „trochu nudné pre deti“. Zabralo „Ráno po prebudení si o kúsok vyšší než večer“ (vlastné telo a život dieťaťa), nezabral učebnicový fakt o Venuši. Zábavnosť pre dospelého nie je zábavnosť pre dieťa, ani pre inak staré dieťa. Preto PR #807: sudcovia kvality aj kontrola „bežného hráča“ hodnotia ako dieťa daného pásma, áno/nie otázky bez stropu pre 4–6 a 9 z 30 pre staršie (dospelí 2 z 30), odpoveď do 6 slov pre 7–9 a 10–12 (4–6 ostáva 2), zadanie vedie k vlastnému telu, domovu, jedlu a veciam, čo sa dajú hneď vyskúšať; neškodný telesný humor je povolený. Zadania pre dospelých sa nezmenili (strážené odtlačkom v testoch).
- **Druhá skúška (2026-11-17; „fuj, ale pravda“ 4–6, LEGO 7–9, Harry Potter cez skutočný svet 10–12) a verdikt foundera:** „vcelku sú zábavné“. Výhrada: deti nemajú predstavu o vysokých číslach, takže tipovanie rádovo veľkých čísel nie je otázka pre ne; menšie počty sú v poriadku. Preto PR #818 (naživo): odpoveď ani možnosť nesmie niesť číslo nad 10 (4–6), 100 (7–9), 1 000 (10–12), founder hranice potvrdil; číslo vo vysvetlení ostať môže. Vedľajší účinok: vypadne aj rok ako odpoveď.
- Otvorené z druhej skúšky: úzke zadanie skĺzne k jednej podtéme (Harry Potter: tri zo štyroch otázok o sovách); kontrola textu nezachytila nejednotné meno (Hedwiga / Hedviga) a čiarku navyše; skúšobný beh nevie čerpať kredit z predplatného (chýba zmiešaná cesta Claude priamo, ostatné cez OpenRouter).
- Zvolené pásmo si formulár pamätá do ďalšej objednávky (founder 2026-11-15).
- Otvorené: tvar otázky pre 4–6 je len pokyn v zadaní, nie pevná kontrola; overovač faktov môže zjednodušenú detskú odpoveď označiť ako nepresnú. Sledovať v druhej skúške.
- Hotovo keď: skutočný balík „vesmír“ pre 7–9 prejde detskou šablónou aj kontrolou a founder ho posúdi; analytická udalosť objednávky nesie pásmo.

### 236.2 Texty a súlad

- App Store kľúčové slová a plán vlastnej stránky „Rodina a deti“ (#220 — App Store marketing) prepísať na rodinné rámovanie; `kids quiz` vypustiť.
- Zásady súkromia: doplniť hlas dieťaťa pri hre s rodičom (appka je určená dospelým, hlas sa po prepise neukladá).
- Znova prejsť dotazník vekového hodnotenia; overiť vek digitálneho súhlasu v SR a ČR (predpoklad 16 a 15, neoverené).
- **Otvorené, treba právnika pred vydaním sekcie v USA:** americký COPPA posudzuje aj časť služby zameranú na deti a výnimka pre hlasové nahrávky nerieši posielanie zvuku službe na prepis. Rámovanie „hráčom je rodič“ pokrýva pravidlá Apple o slovách, nie nutne toto. Dovtedy možnosť: sekcia len v obchodoch EÚ.

### 236.3 Návrh obrazoviek

Varianty na Design plátne, founder vyberie pred kódom: karta „S deťmi“ na domovskej obrazovke → výber veku → témy → hra. V hre: bez časového limitu, miernejšia reakcia na zlú odpoveď, kratšie otázky.

### 236.4 Obsah

- Founder 2026-11-17 schválil celý zoznam 30 tém z rešerše (telo a zmysly, fuj ale pravda, jedlo ako veda, veci doma, ako sa čo vyrába, značky a hry cez skutočný svet, rekordy, „dalo by sa to?“, peniaze, špióni, optické klamy, superschopnosti zvierat, dinosaury, vesmír cez dieťa, zvuky a smiešne slová).
- Lákavé témy podľa foundera (2026-11-15): menej bežné a zo života dieťaťa, napríklad Harry Potter, LEGO, jedlo, veci z každého dňa, čo niečo naučia; „fuj, ale pravda“ o tele pre najmenších. Známe značky a príbehy cez skutočný svet okolo nich (ako vzniká kocka, kde sa nakrúcalo), nie cez dej.
- Témy na štart: zvieratá, rozprávky a večerníčky, vesmír, ľudské telo, príroda, šport, jedlo, Slovensko a Česko. Miestne témy natívne v sk/cs, ostatné podľa bežného postupu korpusu.
- Pásmo sa ukladá ako samostatný údaj otázky (dnešné 8+/12+/16+ hovorí „od koľkých rokov je to vhodné“, nie „pre koho je to písané“); jedna otázka patrí jednému pásmu.
- **Izolácia od bežného kvízu:** spoločný filter výberu otázok (`_build_metadata_filters`, vetva spoločnej knižnice: bežná hra a denná výzva) predvolene vynechá všetko, čo má pásmo. Hra kúpeného balíka sa nemení, tá je oddelená už svojím balíkom, takže detský balík z 236.1 sa prehrá celý aj v starých buildoch. Otázky s pásmom dostane len hra, ktorá si pásmo výslovne vyžiada. Staré buildy a bežní hráči tak detskú otázku nedostanú nikdy; kvalita dnešného kvízu sa nemení. Filter ide do produkcie skôr než prvá otázka s pásmom.
- Pilot ~20 otázok na pásmo, founder skalibruje rubriku pre deti, až potom plný beh (~150 na pásmo a jazyk). Odhad nákladov pred behom na schválenie.
- 52 archivovaných otázok prejsť novou rubrikou, použiteľné vrátiť.

### 236.5 Sekcia v appke

Výber otázok podľa pásma a témy, obrazovky podľa 236.3, analytické udalosti (vstup do sekcie, pásmo, téma, dohraté kolo), za vypínačom na serveri.

### 236.6 Otázky „na pokec“

Otázka bez správnej odpovede: appka prečíta, počká na pokyn „ďalej“, nič nehodnotí a nepočíta body. Nie je to nová hodnota typu otázky (typ hovorí, ako sa otázka zobrazí; otázka pre 4–6 môže byť výber z dvoch a zároveň nehodnotená), ale samostatný údaj „hodnotí sa / nehodnotí sa“; správna odpoveď prestane byť pri nehodnotených povinná. Server ich podáva len v sekcii a len buildom, ktoré ich vedia zahrať; denná výzva a štatistiky hráča ich vynechávajú. Vlastná téma v sekcii. Treba vyriešiť od generovania (iná rubrika: vtip a rozhovor, nie fakt; zdroj sa nevyžaduje) cez hlasový priebeh po skóre. Pravidlo „každá otázka má zdroj“ ostáva pre všetky vedomostné otázky.

### 236.7 Pásmo 4–6

Len otázky áno/nie alebo výber z dvoch, odpoveď môže ťuknúť rodič. Pred vydaním skúška rozpoznávania hlasu so skutočnými deťmi v sk/cs (rodič súhlasí, nič sa neukladá); ak hlas nestačí, pásmo ide von len s ťukaním.

### Neskôr

Hra spolu s pásmom pri hráčovi (dieťa dostane na tú istú tému ľahšiu otázku, tím rodič + dieťa) — až podľa používania sekcie.

## Riziká

| Riziko | Ošetrenie |
|---|---|
| App Review vyhodnotí appku ako určenú deťom | Rámovanie na rodiča, žiadne detské motívy v ikone a snímkach, sekcia za vypínačom na serveri |
| Hlas malých detí sa nerozpozná (štúdie: až tretina slov zle u škôlkarov; sk/cs nemerané) | 236.7: uzavreté odpovede, ťuknutie rodiča, skúška pred vydaním |
| Nevhodná otázka v detskom obsahu | Kontrola po generovaní (pevné limity dĺžky + malý model ako sudca, pri neistote otázka vypadne) + overovanie faktov ako dnes |
| COPPA v USA (nejasné, viď 236.2) | Právne posúdenie pred vydaním sekcie v USA; vypínač podľa krajiny |
| Dopyt je neoverený (žiadne dáta o hľadanosti ani tržbách) | 236.1 je malý krok a zmeria záujem cez podiel detských objednávok |

## Zdroje

- App Store Review Guidelines 1.3, 2.3.8, 5.1.4: https://developer.apple.com/app-store/review/guidelines/ · https://developer.apple.com/app-store/kids-apps/
- Vekové hodnotenia: https://developer.apple.com/help/app-store-connect/reference/age-ratings
- COPPA: https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions
- Rozpoznávanie detskej reči: https://the-learning-agency.com/guides-resources/closing-the-child-speech-recognition-gap-evidence-limitations-and-paths-forward/ · https://www.cise.ufl.edu/~esmaeili/assets/speech-paper.pdf
- Vekové pásma u iných: https://weekend.com/post/trivia-questions-for-kids · https://quizado.com/blog/trivia-questions-for-kids
- Interné: `docs/research/competitive-analysis-voice-driving-trivia-2026-06-27.md` (rodinný klin), `docs/issues/issue-162-kids-prompt-wiring.md`, `docs/issues/issue-170-question-dedup-coverage-steering.md` (vek ako samostatná os)
