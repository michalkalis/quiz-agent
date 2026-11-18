# #239 — Kvalita appky z voľnej kapacity predplatného

**Triage:** enhancement · in-progress
**Status:** 2026-11-18 plán zapísaný (session quiz-agent-87); 239.1 audit kódu a 239.2 prechody appkou sa spúšťajú ako prvé
**Founder:** 2026-11-18 „mám moc veľa kreditov voľných a nestíhame ich minúť… najlepšie niečo, čo by zvýšilo kvalitu appky… ale automatizovane“; „ElevenLabs ani kredity nechcem čerpať, ideálne len zo subscription. Prechody appkou ok, tj. dôkladné testovanie… možno aj UX review a podobne“

Podklad: [rešerš 2026-11-18](../research/claude-code-quality-from-subscription-2026-11-18.md) (čo ide z predplatného, čo funguje, čo je plytvanie).

## Rozhodnutia foundera (2026-11-18)

1. Všetko **len z predplatného Claude**. API kredit ani ElevenLabs nie.
2. Jediná výnimka: robot-hráč pre hlas smie **malé čerpanie ElevenLabs** na prepis odpovedí (rádovo 2 kredity na odpoveď; strop tejto úlohy 5 000 kreditov, viac len po novom súhlase).
3. Vybrané na začiatok: audit kódu kolo 2, prechody appkou, vzhľad a prístupnosť, použiteľnosť + bezpečnosť.
4. Týždenné príspevky (#210 — marketing na sociálnych sieťach) pokračujú ako doteraz, bez nového hlasu z ElevenLabs.

## Pravidlá pre všetky časti

- Výstup sú **len potvrdené nálezy**: každý nález musí prežiť druhého agenta, ktorý ho má vyvrátiť; pri chybe v kóde je dôkazom test, ktorý bez opravy zlyhá. Zhoda agentov dôkazom nie je.
- Opravy idú bežnou cestou: vetva, PR, nezávislá kontrola. Rozhodnutia o správaní appky (UX, rozsah) idú founderovi, technické rieši agent.
- Žiadne plánované ani nočné behy; každé kolo sa púšťa na požiadanie.
- `/code-review ultra` sa nepoužíva (platí sa zvlášť).
- Simulátor: len existujúce zariadenia, Mac stlmený, iPhone 18 Pro pod zámkom, vlastný DerivedData na workera.
- Čo sa prekrýva s #238 — brány kvality otázok, sa tu nerobí.

## Časti

### 239.1 — Audit kódu, kolo 2
Od auditu 2026-07-30 pribudlo ~950 zmien, ktoré takým auditom neprešli. Hľadači po oblastiach, každý nález dostane skeptika.

Oblasti: Hra spolu (v miestnosti aj na diaľku) · zdieľanie kvízu odkazom · nákupy, predplatné, limity a tester strop · vlastné balíky (objednávka, worker, kontrola témy, opätovné použitie) · stavy kvízu a hlasová cesta v appke · denná výzva a profil · prihlásenie a účet · hlas na serveri a jeho cache · nasadenie a prevádzka na Hetzneri.

Hotové, keď: zoznam potvrdených nálezov podľa závažnosti je tu v časti Výsledky, kritické a vysoké sú opravené cez PR s testom, ostatné majú rozhodnutie (opraviť / nechať s dôvodom).

### 239.2 — Prieskumné prechody appkou
Agent prechádza appku na simulátore podľa zadaní s pomenovanými okrajovými prípadmi: prvé spustenie, kvíz hlasom aj ťukaním, MCQ, denná výzva, nákup a zlyhaný nákup, vlastný balík, Hra spolu, zdieľaný kvíz, profil, nastavenia; v sk/cs/en/uk; pomalá a vypadnutá sieť; odchod do pozadia a návrat.

Nález platí až po zopakovaní druhým agentom so snímkou a krokmi. Potvrdené chyby sa po oprave zmrazia do regresných scenárov (RS).

### 239.3 — Stráže vzhľadu a prístupnosti
Snímky obrazoviek doplniť o ukrajinčinu, malý telefón a najväčšie písmo; zabudovaný audit prístupnosti Xcode v UI testoch (kontrast, veľkosť cieľov, popisky, orezaný text); pseudojazyk s dvojnásobnou dĺžkou textu. Popisky pre čítačku obrazovky na hlavných obrazovkách.

### 239.4 — Prechod použiteľnosti po úlohách
Agent vykoná úlohy za nového hráča, rodinu a partiu a meria ťuknutia, čakanie a slepé uličky. Výstup: artefakt so snímkami a návrhmi na posúdenie founderom. Nič z toho sa nemení v appke bez jeho rozhodnutia.

### 239.5 — Bezpečnostný prechod
Jednorazový prechod servera aj appky (prihlásenie, platby, admin, odkazy na zdieľanie, limity) + bezplatné kontroly v CI (úniky tajomstiev, zraniteľné knižnice).

### 239.6 — Robot-hráč pre hlas
Odpovede a povely nahovorené hlasmi zabudovanými v Macu do súboru (bez zvuku nahlas), rôzne hlasy a tempo, s pridaným hlukom auta; pustené cez rozpoznávanie povelov aj prepis odpovedí. Výstup: podiel nepočutých podľa jazyka + sada, ktorá stráži zhoršenie. Nadväzuje na #197 — nahrávky z auta a #204 — spoľahlivejšie rozpoznanie odpovede.

### 239.7 — Preverenie testov úmyselnými chybami (neskôr)
Mutačné sondy na peniaze, limity, vyhodnotenie odpovedí a stavy kvízu; každá prežitá mutácia = nový test.

## Výsledky

(dopĺňa sa po každej časti)
