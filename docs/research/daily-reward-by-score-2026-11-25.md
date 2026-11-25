# Denná výzva: má odmena závisieť od skóre? (#248)

Rešerš z webu, 2026-11-25. Otázka zakladateľa: má sa odmena za dennú výzvu (5 otázok) odvíjať od skóre, a má sa dávať aj za zlé skóre? Rámec, ktorý už platí a nemením: žiadne pushky, žiadne straty série, žiadne mince ani životy, žiadny hard paywall; odmena = otázky navyše v ten deň.

**Najkratšie:** Z toho, čo som našiel, veľké appky zvyčajne dávajú základnú odmenu za dokončenie a za výkon len malý bonus navrch. Dôkazy, že bonus za skóre zvyšuje návrat na druhý deň, som nenašiel. Dôkazy, že trestanie slabších hráčov škodí, sú slabé, ale smerujú jedným smerom.

## Čo robia ostatní

| Appka | Čo sa odmeňuje | Ako | Istota |
|---|---|---|---|
| Duolingo | Dokončenie lekcie (XP), k tomu bonus za presnosť (séria správnych, "perfect lesson") | Základ vždy; bonus je malý a doplnkový. Presné čísla sa v zdrojoch rozchádzajú (10 vs. 20 XP, bonus do 5 XP) | stredná, zdroje sú wiki a blogy |
| Duolingo (drahokamy) | Dokončenie, denné úlohy, náhodné truhlice | Odmena nie je viazaná na bezchybnosť; časť je variabilná | slabá, tretie strany, čiastočne staré |
| Wordle / NYT Games | Nič hmotné, len séria a štatistiky | Jedna hra denne zámerne, nedostatok = príťažlivosť; NYT: "nepotrebujeme vás hákovať" | dobrá (rozhovory), ale o odmene za skóre nehovoria |
| Trivia Crack | Denná otázka: hráč si vyberie z 6 odmien, potom dostane náhodnú otázku | Odmena je za zahranie; náhodná, nie za výkon (oficiálnu stránku pomocníka som nevedel otvoriť, údaj je zo store popisu) | slabá |
| Kahoot | Body za správnosť a rýchlosť v rámci hry | Nie je to denná odmena, nenašiel som ju | nezistené |
| Sporcle, Elevate, Lumosity, HQ, Apple Arcade | Nenašiel som žiadny zdroj o odmenách za skóre | Neviem | nezistené |

Slabé miesto celej tabuľky: ide o popis zvonku (blogy, wiki, store), nie o interné dáta. Žiadna z appiek nezverejnila test "odmena podľa skóre vs. plochá".

## Čo hovoria dôkazy

- **Odmena za dokončenie vs. za výkon.** Veľká metaanalýza (Deci, Koestner, Ryan 1999, 128 experimentov) zistila, že hmotné odmeny viazané na dokončenie aj na výkon mierne znižujú vnútornú motiváciu (približne d = -0,36 a -0,28). Platí to pre hmotné odmeny a hodnotenie "z kontroly"; spor o veľkosť efektu pokračuje (Cameron a Pierce 1994 tvrdia, že efekt je malý). [PubMed](https://pubmed.ncbi.nlm.nih.gov/10589297/) · [PDF 2001](https://www.selfdeterminationtheory.org/SDT/documents/2001_DeciKoestnerRyan.pdf). Čísla beriem zo summáru vyhľadávania, PDF som nevedel prečítať.
- **Prečo to Trubbo trápi menej (môj záver, nie z prameňa).** Odmena je "viac z tej istej hry", nie cudzí predmet. To by mala byť menej podkopávajúca odmena, ale priamy dôkaz pre otázky navyše nemám.
- **Odmena naviazaná na výkon môže aj pomáhať.** Súhrn z vyhľadávania spomína neskoršie práce, kde odmena podľa úrovne výkonu motiváciu nezníži alebo zvýši; autora som neoveril, preto len ako náznak.
- **Slabší hráči a porovnávanie.** Výskum rebríčkov je zmiešaný: niektoré štúdie ukazujú demotiváciu spodku, iné opak; prehľady ho označujú za konfliktný. [Emerald](https://www.emerald.com/intr/article/33/7/1/178330) · [NSF](https://par.nsf.gov/servlets/purl/10510520) · [mapovanie negatív](https://arxiv.org/pdf/2305.08346). Tieto štúdie sú hlavne o vzdelávacích appkách a rebríčkoch, nie o dennej odmene v kvíze.
- **Čo sa pokazí pri Duolingu.** Kvalitatívna štúdia (forum + 15 rozhovorov) opisuje frustráciu z lig, "XP farmenie" a úzkosť zo série; autori odporúčajú odmeňovať učenie, nie surové body, a nerobiť hru povinnú. Je to vnímanie používateľov, nie meranie. [arXiv 2203.16175](https://ar5iv.labs.arxiv.org/html/2203.16175)
- **Séria a strata.** Herný dizajnér Zach Gage hovorí, že séria motivuje, kým trvá, a demotivuje, keď sa preruší. Je to z výsledkov vyhľadávania o Axiose, samotný článok som nevedel otvoriť. Trubbo sérii so stratou už zámerne unikol. [Axios](https://www.axios.com/2022/02/11/snapping-wordle-streak) · [Northeastern o Wordle](https://news.northeastern.edu/2022/01/21/what-makes-wordle-so-g-r-e-a-t/)
- **Premenlivé odmeny.** V labe hráči preferujú premenlivú odmenu pred pevnou s rovnakým priemerom; to je preferencia, nie návrat na druhý deň. Tvrdenia blogov o "návykovosti" nemajú citovaný dôkaz. [Princeton/MIT](https://people.csail.mit.edu/dkao/pdf/kao2012rewardpreference.pdf)

## Možnosti pre Trubbo

**A. Plochá odmena (dnešný stav): 10 navyše za dokončenie.**
- Pre hráča: jasné, férové; slabý hráč sa nikdy necíti potrestaný, nič sa nedá "zmeškať" ani "prehrať".
- Proti: nedáva dôvod snažiť sa; nemá nič, čo by tešilo dobrého hráča.

**B. Základ + bonus: 10 za dokončenie, +5 navyše za 4-5 správnych.**
- Pre hráča: každý dostane celú dnešnú odmenu, dobrý hráč niečo navyše. Ako "bonus", nie ako "trest": slabší nič nestráca oproti dnešku.
- Proti: dobrý hráč dostane viac, slabší sa môže cítiť druhý rad; malý extra náklad otázok.

**C. Odstupňovaná: 4-5 správnych = 10, 2-3 = 5, 0-1 = 0 (pôvodný príklad).**
- Pre hráča: jasná súvislosť výkon-odmena.
- Proti: slabý hráč dostane menej než dnes, presne tí, ktorých chceme udržať; je to presne "odmena je kontrola", pred ktorou varuje SDT; k tomu tlak na "dobrý výsledok" v hlasovej hre pre vodiča.

Žiadna z možností neporušuje rámec zakladateľa. Štvrtá možnosť, ktorú neodporúčam: variabilná odmena (náhodných 5-15). Dôkaz o návrate je slabý.

## Odporúčanie

**B, s malým bonusom a opatrne:** 10 navyše za dokončenie vždy (dnešný stav sa nikomu nezhorší), plus malý bonus za 4-5 správnych. Dôvody: dokončenie je to, čo má ťahať návrat, a jediné, čo dôkazy aspoň čiastočne podporujú; bonus je len uznanie výkonu bez trestu. Texty: "Plus 5 za pekný výsledok", nikdy "len 10" ani "za slabé skóre menej". Ak by zakladateľ chcel úplnú jednoduchosť (Rule #1), A je tiež obhájiteľné.

Kroky a miera istoty:
1. Zmerať pred nasadením (alebo A/B, ak sa dá): návrat na ďalší deň podľa skóre. Ak slabé skóre nevedie k menšiemu návratu už dnes, bonus je len kozmetika.
2. Odpoveď na "máme dať odmenu aj za zlé skóre": áno, v B ju dostane každý.
3. Pozor: nič z toho nie je merané na quiz appke s hlasom; ide o analógie.

## Čomu veriť menej

- Duolingo čísla (XP, drahokamy): blogy, wiki, rôzne roky.
- Trivia Crack a Wordle: len vyhľadávanie a sprostredkované zhrnutia, pôvodné stránky (Trivia Crack pomocník, Axios) vrátili 403.
- Deci a spol.: čísla zo summáru, PDF som neprečítal.
- Premenlivé odmeny: lab preferencia, žiadny dôkaz o návrate.
- Kahoot, Sporcle, Elevate, Lumosity, HQ, Apple Arcade: nič som nenašiel.
