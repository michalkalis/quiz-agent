# #243 — TF test 2026-11-22/23: hlasová navigácia, potvrdenie, výsledky

**Triage:** needs-founder-decision (stavový diagram → rozhodnutie o hlasovej navigácii) · zatiaľ len zapísané, neopravovať
**Zdroj:** founder, TF build z 2026-11-22 (PR #929–#956), jazda v aute aj doma; nadväzuje na TODO riadok „TF test 2026-11-22: hlasom navádzať“ (zlúčený sem).
**Súvisí:** [#208 — TF test hlasových povelov](issue-208-tf-voice-feedback-2026-10-16.md) · [#185 — test v aute](issue-185-car-test-2026-09-23.md) · rozhodnutia: žiadny moderovaný kvíz (11-21), povely len na telefóne a okamžite (11-22), minimum zvukov (10-06).

Founder celkovo: „appka je už v super stave, som spokojný.“

## Nálezy

Stav: **chyba** = opraviť bez rozhodnutia · **rozhodnutie** = founder cez `/decide` · **zámer** = tak je to postavené, founder to vníma inak.

### A. Hlasové navádzanie (hlavná téma)

| # | Founder | Ako je to dnes | Stav |
|---|---|---|---|
| A1 | Pri začiatku premýšľania povedať „premýšľaj“, pri začiatku odpovede „odpovedaj“; tóny nestačia | Fázy sa neohlasujú hlasom. Začiatok odpovede = krátky tón; začiatok premýšľania nemá žiadny signál | rozhodnutie (znenie sk/cs/en, ticho pri „Čítať nahlas“ vypnuté / bez zvuku) |
| A2 | Na konci kvízu nestačí „povedz znova“; ponúknuť ďalšie kroky hlasom | Appka povie „Hotovo, X z Y správne. Povedz znova.“ a počúva len „znova“ (ten istý balík). Tlačidlá: Hrať znova, Domov, Poslať kamarátovi, Zavrieť. Denná výzva a rekapitulácia nepovedia nič | rozhodnutie (podľa diagramu) |
| A3 | Celkovo viac hlasových výziev pre navigáciu a stavy; najprv **stavový diagram** celej appky | Diagram neexistuje | ďalší krok |
| A4 | (11-22) skóre a čas nahlas, potom „pokračovať, alebo ísť domov?“; „Premýšľaj, máš 10 sekúnd“ napísať aj povedať | viď A1, A2 | rozhodnutie |

Poznámka: posúva to rozhodnutie z 10-06 „minimum zvukov“. Founder teraz výslovne chce krátke hlasové výzvy stavov (nie tóny, nie moderátora).

### B. Odpoveď nezachytená, potvrdenie

| # | Founder | Ako je to dnes | Stav |
|---|---|---|---|
| B1 | Keď nestihnem vymyslieť odpoveď, raz vyskočí „Nič nebolo počuť“, inokedy znova nahráva; nechcem stále dookola nahrávať, chcem viac času alebo pauzu | Prvé prázdne nahrávanie: appka povie „Odpoveď sa nepodarilo zachytiť, skús to znova“ a hneď nahráva znova. Druhé: obrazovka Znova / Ďalšia. Pauza ani „daj mi čas“ tam nie je | rozhodnutie (napr. po prvom zlyhaní vrátiť sa do premýšľania, alebo voľba „pauza“) |
| B2 | Z obrazovky „Nič nebolo počuť“ sa nedá dostať k prečítaniu otázky; „Znova“ hneď nahráva bez zopakovania otázky | Potvrdzuje kód: na tejto obrazovke počúva len „znova“ a „ďalšia“, „zopakuj“ funguje len počas otázky; „Znova“ spustí nahrávanie hneď | chyba (chýba cesta späť k otázke) |
| B3 | Na potvrdzovacej obrazovke niekedy nahráva odpoveď namiesto povelov | Obrazovka „Nič nebolo počuť“ počúva len povely. Obrazovka s prepisom odpovede berie každú vetu, ktorá nie je povel, ako **novú odpoveď** (zámer z #185). Pravdepodobne to founder zažil tam, alebo pri automatickom druhom pokuse | zámer, ale mätúci → rozhodnutie |
| B4 | Keď appka nič nepočuje, možno predĺžiť čas na odpoveď („nie som si istý“) | Na začiatok reči čaká 5 s, odpoveď končí po 0,8 s ticha, tvrdý strop 8 s | rozhodnutie (súvisí s B1) |

### C. Obrazovky a nastavenia

| # | Obrázok | Founder | Ako je to dnes | Stav |
|---|---|---|---|---|
| C1 | 2, 3 | Predvoľby časov nie sú praktické | Premýšľanie: 0, 10, 15, 30, 45, 60, 90, 120 s (predvolené 10). Automatický posun po výsledku: 5, 8, 10, 15 s (predvolené 8; po vyslovenom verdikte ide ďalej už po 3 s). Automatické potvrdenie fixne 5 s | rozhodnutie (navrhnúť menej a rozumnejších hodnôt) |
| C2 | 4 | Vsuvka v otázke „aký si dáte po žúre“ je blbosť | Výplňová fráza z generovania (jedlo a pitie, sk) | chyba obsahu: opraviť otázku; skontrolovať, či recept a kontrola textov zachytia podobné vsuvky (#238) |
| C3 | 5 | „Rozpoznávanie reči · Pripravené · počul ‚odpovedz‘“ — čo je to? | Diagnostický riadok rozpoznávania povelov, zámerne viditeľný v každom builde (aby šlo na zariadení overiť, že povely počúvajú) | chyba: skryť pre hráčov, nechať len v ladiacej sekcii |
| C4 | 7 | Chýba stavový pásik nad tlačidlami? | Pásik sa schováva, keď niet odpočtu (premýšľanie 0 s, po odpočte, stlmené). Povely pritom počúvajú ďalej. Schované zámerne v builde 90 (ponúkal povely, ktoré sa zle rozpoznávali) | rozhodnutie (podľa diagramu: čo má hráč vidieť, keď appka počúva) |
| C5 | 8 | Dlhá správna odpoveď, „snáď ok“ | OK. Všimnuté navyše: tvoja odpoveď bola prepísaná **po česky** („Vyšel v pondělí.“) v slovenskom kvíze | chyba na preverenie (jazyk prepisu odpovede) |
| C6 | 8 | Vysvetlenie je zahlcujúce; vždy 1–2, max 3 vety? Celý text ťukateľný na prehratie? Zobrazovať text vôbec? | Vysvetlenia sú dlhé (tu ~5 viet), tlačidlo „vypočuj si“ existuje | rozhodnutie (dĺžka pri generovaní + skrátenie existujúcich, ťuk na text, text áno/nie) |

### D. Zvuk a hlas

| # | Founder | Ako je to dnes | Stav |
|---|---|---|---|
| D1 | Nevypína hudbu pri spustení kvízu (pri štarte appky netreba) | Hudba sa pri kvíze len stíši, nezastaví; zastavia sa len podcasty. Po konci kvízu sa vráti na plnú hlasitosť | chyba (zastaviť hudbu pri štarte kvízu, po konci ju nechať pokračovať) |
| D2 | Zle číta číslice, čísla, roky | sk/cs/uk čísla sa prepisujú na slová na serveri, roky ako bežné čísla; angličtinu neupravuje nič. Chýbajú konkrétne príklady | chyba na preverenie: zozbierať príklady (founder alebo vzorka otázok cez prepis hlasu, nie prehrávanie nahlas) |
| D3 | Pri 140 km/h v aute appka rozpoznala len každú druhú-tretiu odpoveď | Odpovede prepisuje server (OpenAI), začiatok a koniec reči určuje telefón podľa hlasitosti voči šumu; ladenie na hluk v aute je podľa kódu stále len „východiskový bod“ (#185) | chyba na preverenie: záznamy z buildu (Sentry, záznam letu kvízu) z tej jazdy; zistiť, či to bolo cez Bluetooth/CarPlay alebo mikrofón telefónu

## Postup (návrh)

1. **Stavový diagram appky** (founder ho výslovne chce pred rozhodnutím o hlasovej navigácii): Home → kvíz (čítanie, premýšľanie, odpoveď, potvrdenie, výsledok otázky) → koniec kvízu → ďalšie kroky; pri každom stave čo appka povie, čo počúva, aké tlačidlá. Vizuálne, cez `/decide`, s návrhom hlasových výziev sk/cs/en.
2. Opraviť chyby, ktoré nečakajú na rozhodnutie (označené **chyba** nižšie), samostatnými PR.
3. Po rozhodnutí foundera: hlasové výzvy stavov, výsledková obrazovka, predvoľby časov, skrátenie vysvetlení.
