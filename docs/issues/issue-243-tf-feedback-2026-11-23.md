# #243 — TF test 2026-11-22/23: hlasová navigácia, potvrdenie, výsledky

**Triage:** enhancement · ready-for-agent (rozhodnuté 2026-11-24, viď nižšie)
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
| B3 | Na potvrdzovacej obrazovke niekedy nahráva odpoveď namiesto povelov | Obrazovka „Nič nebolo počuť“ počúva len povely. Obrazovka s prepisom odpovede berie každú vetu, ktorá nie je povel, ako **novú odpoveď** (zámer z #185 — test v aute). Pravdepodobne to founder zažil tam, alebo pri automatickom druhom pokuse | zámer, ale mätúci → rozhodnutie |
| B4 | Keď appka nič nepočuje, možno predĺžiť čas na odpoveď („nie som si istý“) | Na začiatok reči čaká 5 s, odpoveď končí po 0,8 s ticha, tvrdý strop 8 s | rozhodnutie (súvisí s B1) |

### C. Obrazovky a nastavenia

| # | Obrázok | Founder | Ako je to dnes | Stav |
|---|---|---|---|---|
| C1 | 2, 3 | Predvoľby časov nie sú praktické | Premýšľanie: 0, 10, 15, 30, 45, 60, 90, 120 s (predvolené 10). Automatický posun po výsledku: 5, 8, 10, 15 s (predvolené 8; po vyslovenom verdikte ide ďalej už po 3 s). Automatické potvrdenie fixne 5 s | rozhodnutie (navrhnúť menej a rozumnejších hodnôt) |
| C2 | 4 | Vsuvka v otázke „aký si dáte po žúre“ je blbosť | Výplňová fráza z generovania (jedlo a pitie, sk) | chyba obsahu: opraviť otázku; skontrolovať, či recept a kontrola textov zachytia podobné vsuvky (#238 — brány kvality otázok) |
| C3 | 5 | „Rozpoznávanie reči · Pripravené · počul ‚odpovedz‘“ — čo je to? | Diagnostický riadok rozpoznávania povelov, zámerne viditeľný v každom builde (aby šlo na zariadení overiť, že povely počúvajú) | chyba: skryť pre hráčov, nechať len v ladiacej sekcii |
| C4 | 7 | Chýba stavový pásik nad tlačidlami? | Pásik sa schováva, keď niet odpočtu (premýšľanie 0 s, po odpočte, stlmené). Povely pritom počúvajú ďalej. Schované zámerne v builde 90 (ponúkal povely, ktoré sa zle rozpoznávali) | rozhodnutie (podľa diagramu: čo má hráč vidieť, keď appka počúva) |
| C5 | 8 | Dlhá správna odpoveď, „snáď ok“ | OK. Všimnuté navyše: tvoja odpoveď bola prepísaná **po česky** („Vyšel v pondělí.“) v slovenskom kvíze | chyba na preverenie (jazyk prepisu odpovede) |
| C6 | 8 | Vysvetlenie je zahlcujúce; vždy 1–2, max 3 vety? Celý text ťukateľný na prehratie? Zobrazovať text vôbec? | Vysvetlenia sú dlhé (tu ~5 viet), tlačidlo „vypočuj si“ existuje | rozhodnutie (dĺžka pri generovaní + skrátenie existujúcich, ťuk na text, text áno/nie) |

### D. Zvuk a hlas

| # | Founder | Ako je to dnes | Stav |
|---|---|---|---|
| D1 | Nevypína hudbu pri spustení kvízu (pri štarte appky netreba) | Hudba sa pri kvíze len stíši, nezastaví; zastavia sa len podcasty. Po konci kvízu sa vráti na plnú hlasitosť | chyba (zastaviť hudbu pri štarte kvízu, po konci ju nechať pokračovať) |
| D2 | Zle číta číslice, čísla, roky | sk/cs/uk čísla sa prepisujú na slová na serveri, roky ako bežné čísla; angličtinu neupravuje nič. Chýbajú konkrétne príklady | chyba na preverenie: zozbierať príklady (founder alebo vzorka otázok cez prepis hlasu, nie prehrávanie nahlas) |
| D3 | Pri 140 km/h v aute appka rozpoznala len každú druhú-tretiu odpoveď | Odpovede prepisuje server (OpenAI), začiatok a koniec reči určuje telefón podľa hlasitosti voči šumu; ladenie na hluk v aute je podľa kódu stále len „východiskový bod“ (#185 — test v aute) | chyba na preverenie: záznamy z buildu (Sentry, záznam letu kvízu) z tej jazdy; zistiť, či to bolo cez Bluetooth/CarPlay alebo mikrofón telefónu

## Rozhodnutia foundera (2026-11-24, stránka /decide)

1. **Ohlásenie fáz:** slovo + tichý tón, na začiatku dlhšie. Prvé dve otázky kvízu: „Premýšľaj, máš desať sekúnd.“ a „Odpovedaj.“; potom len „Premýšľaj.“ / „Odpovedaj.“ a tón pri zapnutí mikrofónu.
2. **Ticho pri odpovedi:** späť do premýšľania („Premýšľaj ešte.“ a nový odpočet), mikrofón sa hneď znova neotvára. Po druhom tichu ponuka „Zopakovať otázku, znova, alebo ďalšia?“ (povely zopakuj · znova · ďalšia), appka čaká. „Ďalšia“ počas premýšľania = neviem.
3. **Potvrdenie:** počúva len „znova“; iná reč sa ignoruje (ruší zámer z #185 — test v aute, že reč na potvrdení = nová odpoveď).
4. **Výsledok otázky:** vysvetlenie vždy 1 až 2 vety (nové otázky aj prepísanie existujúcich); ťuk na text vysvetlenia ho prečíta. Povely na výsledku otázky **nie** (D nevybraté). Zásada od foundera: povely sa počúvajú až **po hlasovej výzve, ktorá ich pomenuje**, a až po prečítaní skóre či vysvetlenia (príklad: „Pre ďalšie kolo povedz znova.“).
5. **Koniec kvízu:** „Hotovo, 7 z 10. Znova, alebo domov?“ (povely znova · domov; pri tichu sa raz spýta, potom čaká). Zmena kategórie hlasom pred ďalším kolom: founder váha („obávam sa, že by to bolo moc komplikované“), stačí „domov“. Rešerš (doplnok 11-24): iné hlasové kvízy zoznam kategórií nečítajú; teraz bez zmeny kategórie hlasom, neskôr prípadne „nová téma“ s jednou náhodnou ponukou. Platí pre všetky konce (bežný, súhrn, denná výzva).
6. **Predvoľby časov:** premýšľanie 5 · 10 (predvolené) · 20 · 30 s · Bez limitu (čaká na „odpovedz“); posun po výsledku: Hneď po verdikte (predvolené) · 8 s · 15 s · Čakať na „ďalšia“.

Pásik so slovami povelov vždy, keď appka počúva (bod 7), a opravy označené **chyba** idú bez ďalšieho rozhodovania.

## Postup (návrh)

1. **Stavový diagram appky** — HOTOVÉ 2026-11-23: rozhodovacia stránka `/decide` (dnes vs. návrh, poznámky, rešerš, 6 otázok: ohlásenie fáz, ticho, potvrdenie, výsledok, koniec kvízu, predvoľby časov); čaká na odpovede foundera. Rešerš: [hlasová navigácia v iných appkách](../research/voice-navigation-patterns-2026-11-23.md).
Implementácia, jeden PR na riadok (stav `[ ]` todo · `[x]` hotové):

- [x] 243.1 Hudba sa pri štarte kvízu zastaví (nie len stíši), po konci kvízu môže pokračovať
- [x] 243.2 Diagnostický riadok „Rozpoznávanie reči“ len v ladiacej sekcii
- [x] 243.3 Hlasové výzvy fáz (rozhodnutie 1): klipy sk/cs/en/uk hlasom appky z ElevenLabs (vygenerované vopred a pribalené, aby zazneli hneď aj bez signálu), nikdy systémový hlas iPhonu (founder 2026-11-24); dlhšia verzia pre prvé dve otázky; ticho pri vypnutom „Čítať nahlas“ a Bez zvuku
- [ ] 243.4 Ticho pri odpovedi (rozhodnutie 2) + cesta späť k otázke z ponuky (B2). Nápoveda hlasom appky len keď appka hráčovi nerozumie (zachytila reč, ale nevie z nej odpoveď, napr. nejasná možnosť pri výbere); pri tichu žiadna hláška, len návrat do premýšľania (founder 2026-11-24)
- [ ] 243.5 Potvrdenie počúva len „znova“ (rozhodnutie 3)
- [x] 243.6 Pásik so slovami povelov vždy, keď appka počúva (C4)
- [x] 243.7 Koniec kvízu hlasom (rozhodnutie 5), aj súhrn a denná výzva; nový povel „domov“ len tu
- [ ] 243.8 Predvoľby časov (rozhodnutie 6) + prevod uložených hodnôt
- [x] 243.9 Ťuk na text vysvetlenia ho prečíta (rozhodnutie 4)
- [x] 243.10 Vysvetlenia 1 až 2 vety: pravidlo v generovaní + prepísanie existujúcich (dávka z predplatného, nie API; kvalita otázok sa nemení)
- [x] 243.11 Prieskum: odpoveď prepísaná po česky v sk kvíze (C5); záznamy z jazdy 140 km/h (D3); čísla a roky – vzorka cez prepis hlasu (D2)
- [x] 243.12 Oprava otázky „po žúre“ + kontrola výplňových vsuviek (C2)
- [x] 243.13 Krížik na výsledku: rovnaké správanie ako na otázke (podrží odpočet)

Stav 2026-11-24 (session quiz-agent-49): zlúčené kroky 243.1–243.3, 243.6, 243.7 a 243.9–243.13 (PR pri každom kroku v git histórii); v prod zapísaných 103 skrátených vysvetlení + oprava döner otázky (súhlas foundera). Otvorené: 243.4 ticho pri odpovedi (ponuka po tichu dlhá → po 2 vypočutiach krátka, „Nepočujem odpoveď. Povedz: zopakuj…“; vlastný hlas appky sa z prepisu vyškrtne), 243.5 potvrdenie len „znova“, 243.8 predvoľby časov (+ „Povedz: ďalšia.“). Hlas ostáva George; pokyny jedno slovo, ElevenLabs nastavenie B (premýšľanie) / C (odpovedaj). 243.11: čísla OK, chybné boli mená/kódy s číslicami (opravené); Sentry záznamy z jazdy neprečítané (chýba povolenie na kľúč), jazda išla cez mikrofón telefónu.
