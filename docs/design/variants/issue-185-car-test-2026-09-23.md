# #185 Test v aute 2026-09-23: diagnóza a návrhy UX

Zdroj: founder test TF buildu v aute (slovenský kvíz, Bluetooth), 23. 9. 2026 večer. Dôkazy: backend logy prepisov z tej jazdy (16 nahrávok, 17:10 až 17:27 UTC) + analýza kódu na aktuálnom `main`.

**Najdôležitejší nový fakt z logov:** všetkých 16 nahrávok odpovede má dĺžku 5,0 až 5,3 s. Lokálna detekcia reči v aute **ani raz** nezachytila, že hovoríš; každú nahrávku ukončil až 5-sekundový limit „začni hovoriť“. Prepis aj tak fungoval (zvuk sa nahral), ale auto-stop je v aute mŕtvy a pravdepodobne je to ten istý dôvod, prečo povely treba kričať (rovnaký detektor filtruje zvuk pre povely).

| # | Problém | Typ | Príčina (istota) | Treba tvoje rozhodnutie? |
|---|---|---|---|---|
| 1 | Confirm obrazovka na ďalšej otázke | bug | reťaz: detektor reči nefunguje → odpoveď odseknutá na 5 s → prázdny prepis → „bez odpovede“ sheet sa po 5 s sám potvrdí = preskočenie → nová otázka potichu → tvoje zopakovanie sa nahralo už k nej (vysoká, Sentry záznam jazdy) | áno: rozsah opravy (len fix, alebo fix + 1. krok stabilizácie stavov) |
| 2 | Zvuk z iPhonu namiesto auta | bug | spracovanie hlasu (novinka z #184) odtláča zvuk z Bluetooth na reproduktor (vysoká, neoverené na zariadení) | áno: kompromis mikrofónu |
| 3 | Povely treba kričať | bug + UX | detektor reči v aute nezachytí reč, prísny matcher, čaká sa na finálny výsledok (stredná, logy to podporujú) | áno: UX návrhy |
| 4a | „curling“ → „Paddling“, „Carling“, neuznané | bug | prepis vynútený na slovenčinu + vyhodnocovač nevie, že ide o prepis reči, „Carling“ berie ako iné slovo (vysoká) | áno: miera tolerancie |
| 4b | Žiadny feedback počas hovorenia, auto-stop nefungoval | bug + UX | viď vyššie, detektor reč nevidí (vysoká, 16/16 nahrávok) | áno: typ feedbacku |
| 5 | Oprava odpovede cez „znova“ je neistá | UX | okno 5 s sa míňa na reštart mikrofónu, „nie, znova“ / „ešte raz“ sa nechytí, žiadny signál, že počúvam (stredne vysoká) | áno: nový flow |
| 6 | MCQ písmeno „c“ nerozumie | bug + UX | od #184 sa hlasová MCQ odpoveď vyhodnocuje len presnou zhodou na serveri; „C“ má 1 znak a zahodí sa (vysoká) | áno: čísla vs. písmená |

---

## 1. Confirm obrazovka na ďalšej otázke

**Čo sa stalo (z telemetrie tvojej jazdy, 23. 9. 17:12:43 až 17:13:02 UTC):**

1. Odpoveď na otázku N sa nahrávala len 5 s a potom ju odsekol limit, lebo detektor reči v aute nefunguje (viď úvod).
2. Prepis vyšiel prázdny → server vrátil „nerozumel som“ → appka otvorila prázdnu potvrdzovaciu obrazovku „bez odpovede“ s 5 s odpočtom.
3. Na tejto obrazovke appka **neberie hovorenú odpoveď**, len povely. Tvoje zopakovanie odpovede preto nikam nešlo (mikrofón povelov nič nezachytil).
4. Po 5 s sa prázdna odpoveď automaticky „potvrdila“, čo znamená **preskočenie otázky**. Keďže hráš s vyhodnotením až na konci, nová otázka sa objavila bez výsledku a bez ohlásenia.
5. O necelú sekundu sa na otázke N+1 spustilo nahrávanie (čo ho spustilo, telemetria nezaznamenáva; nahrávanie sa navyše dnes môže spustiť aj počas čítania otázky). Nahralo sa to, čo si ešte hovoril k otázke N → potvrdzovacia obrazovka na N+1 s odpoveďou z predošlej otázky.

Nešlo teda o „starý stav, ktorý prežil do ďalšej otázky“, ale o reťaz troch slabín: mŕtvy detektor reči, tiché automatické preskočenie prázdnej odpovede a nahrávanie, ktoré nečaká na dočítanie otázky. Pravdepodobne pomohol aj bug 2: ak zvuk išiel do iPhonu, začiatok novej otázky si v aute nepočul.

Popri tom analýza kódu našla aj skutočný „starý stav“ (neskorý výsledok z otázky N sa môže zapísať do N+1 cez chybové cesty bez kontroly vlastníka). Tentoraz to nebol spúšťač, ale je to rovnaká trieda chýb, ktoré sa ti dlhodobo objavujú (viď Stabilizácia stavov nižšie).

**Opravy bez rozhodnutia (bugy):**

- 5 s limit „začni hovoriť“ platí len keď detektor reči preukázateľne funguje; inak nahrávanie nesmie odseknúť odpoveď (+ zistiť na zariadení, prečo detektor mlčí).
- Nahrávanie sa nespustí, kým sa otázka nedočítala (alebo ju zastaví, ak je to zámer „skočiť do reči“).
- Každý asynchrónny výsledok overí, že patrí aktuálnej otázke a pokusu.

**Návrhy UX (treba rozhodnúť):**

- **1.1 Prázdna odpoveď sa nikdy potichu nepreskočí** (odporúčané): namiesto sheetu „bez odpovede“ appka povie „Nepočul som, povedz to znova“ a hneď znova nahráva. Až po druhom neúspechu ponúkne „Znova / Preskoč“, a preskočenie len na povel alebo ťuknutie, nie odpočtom.
- **1.2 Ohlásiť prechod na novú otázku** aj v režime vyhodnotenia na konci: krátky tón alebo „Ďalšia otázka“, aby vodič vedel, že sa otázka zmenila.
- **1.3 Na potvrdzovacej obrazovke brať aj hovorenú odpoveď** (je to zároveň návrh 5.1).

---

## 2. Zvuk ide z iPhonu, hoci je Bluetooth pripojený

**Čo sa deje:** v #184 sme zapli Apple „spracovanie hlasu“ (potlačenie šumu a ozveny) na mikrofóne. To je režim pre telefonovanie a Bluetooth „hudobný“ výstup (A2DP) s ním nevie bežať súčasne. iOS preto pri otvorení mikrofónu presunie zvuk na reproduktor iPhonu. Bluetooth ostane pripojený, presne ako si opísal. Aplikácia potom trasu nevráti späť a otázku začne čítať skôr, než sa Bluetooth stihne obnoviť.

**Možnosti:**

| | Riešenie | Plus | Mínus |
|---|---|---|---|
| **A** | Keď zvuk ide do Bluetooth auta/slúchadiel, spracovanie hlasu vypnúť; na reproduktore iPhonu ho nechať | zvuk ostane v aute, žiadna „hovor“ obrazovka | v aute mikrofón bez potlačenia šumu (stav pred #184; prepis po nahratí to už zvláda lepšie ako vtedy) |
| **B** | Použiť mikrofón auta cez „režim hovoru“ (už existuje v Nastaveniach) | spracovanie hlasu beží, mikrofón bližšie k tebe | auto ukáže „telefonát“, všetok zvuk v kvalite telefonátu (aj čítanie otázok), preruší hudbu |
| **C** | Nechať spracovanie všade a trasu po každom nahrávaní ručne vracať | | krehké, pomalšie, zvuk aj tak na chvíľu skočí do iPhonu |

**Odporúčanie:** A ako predvolené + B ako voliteľný „lepší mikrofón“ v Nastaveniach. Pridať záznam trasy zvuku do Sentry pri každej zmene, aby ďalšia jazda potvrdila príčinu.

---

## 3. Povely sa ťažko zadávajú

**Čo sa deje:** povely rozpoznáva iPhone lokálne, ale len zvuk, ktorý detektor reči označí ako reč. Ten je nastavený na nízku citlivosť a v aute (ako ukazujú nahrávky odpovedí) reč nezachytí, kým nekričíš. K tomu prísny matcher (max. jedno slovo navyše, vysoký prah istoty) a čakanie na finálny výsledok.

**Návrhy:**

- **3.1 Opraviť detektor** (bug, bez rozhodnutia): vyššia citlivosť alebo detektor oddelený od rozpoznávania povelov; zmerať na nahrávkach z auta.
- **3.2 Tlačidlá na volante / slúchadlách** (nové): „ďalšia skladba“ = preskoč/ďalej, „play/pauza“ = začni odpovedať / potvrď, „predošlá“ = znova. V aute najspoľahlivejší hands-free vstup, nulová závislosť od rozpoznávania reči. Funguje cez štandardné ovládanie médií iOS.
- **3.3 Zvukový signál „počúvam povel“ a „rozumel som“**: krátky tón, keď sa okno povelov otvorí, a potvrdzovací tón, keď povel chytí. Vodič vie, či má zopakovať.
- **3.4 Širší slovník, menej kolízií**: prijať aj „nie“, „ešte raz“, „zle“, „áno“, „hej“, „jasné“; zmerať skóre na reálnych vzorkách.
- **3.5 Logovať text povelov** v TF buildoch (dnes len dĺžka), inak sa to nedá ladiť.

**Odporúčanie:** 3.1 + 3.3 + 3.4 + 3.5 teraz; 3.2 ako samostatné vylepšenie (veľký prínos do auta, stredná práca).

---

## 4a. „curling“ sa nerozpozná ani neuzná

**Čo sa deje (z logov):** jedna odpoveď bola prepísaná ako „Paddling“, druhá ako „Carling“. Prepis je nútený do slovenčiny, takže anglické slovo sa „posloví“. Vyhodnocovač (LLM) odpúšťa len „drobné preklepy“ a nevie, že text je prepis reči; „Carling“ je navyše značka piva, tak ho berie ako inú odpoveď.

**Návrhy:**

- **4a.1 Tolerancia na podobne znejúce slová** (odporúčané): vyhodnocovač dostane informáciu, že ide o hlasový prepis v hlučnom aute, a pred LLM prebehne rýchla zvuková zhoda („carling“ ≈ „curling“ → uznané).
- **4a.2 Ukázať, čo sa uznalo**: na výsledku „Uznané (rozumel som: Carling)“, aby bolo jasné, prečo.
- **4a.3 Pri generovaní otázok** pridať k cudzím slovám bežné fonetické varianty ako alternatívne odpovede.
- **Nedoporučujem:** posielať správnu odpoveď do prepisu ako nápovedu; prepis by „videl“ odpoveď aj keď ju nepovieš (podvod).

**Rozhodnutie:** ako benevolentne uznávať? (prísne = len zhoda znenia; stredne = podobne znejúce slová; voľne = LLM rozhodne podľa zmyslu)

---

## 4b. Feedback počas hovorenia + auto-stop

**Čo sa deje:** počas nahrávania je len odpočet „začni hovoriť“ (5 s), žiadny ukazovateľ, že mikrofón počuje. Auto-stop sa v aute nespustil ani raz (16/16 nahrávok skončilo na 5 s limite).

**Riziko, ktoré z toho plynie:** kým detektor v aute nevidí reč, každá dlhšia odpoveď (začneš hovoriť po 3 s) sa po 5 s odsekne.

**Návrhy feedbacku:**

- **A. Pulzujúci kruh / vlnovka podľa hlasitosti** (odporúčané): kruh okolo mikrofónu sa zväčšuje podľa toho, čo mikrofón počuje. Okamžite vidno „počuje ma“. Bez textu, periférne viditeľné.
- **B. Text stavu**: „Počúvam…“ → „Zachytávam…“ keď detekujem reč → „Spracúvam…“.
- **C. Tón pri konci nahrávania** (už existuje „rozumel som“ tón), doplniť jemný tón pri začatí reči? (môže rušiť, neodporúčam)
- Oprava auto-stopu (bug): kontrolovať ticho pravidelne podľa času, nie len keď detektor niečo nahlási, + záložná detekcia podľa hlasitosti voči šumu auta.

**Odporúčanie:** A + B + oprava auto-stopu.

---

## 5. Keď appka zle rozumie a treba opakovať

**Čo sa deje dnes:** po prepise appka prečíta odpoveď, spustí 5 s odpočet na automatické potvrdenie a až potom reštartuje mikrofón pre povely (reštart trvá často 1 až 3 s). Na „znova“ ostáva málo času, nie je žiadny signál, že počúva, a prirodzené „nie, znova“ alebo „ešte raz“ sa nechytí.

**Návrhy:**

- **5.1 „Proste povedz odpoveď znova“** (odporúčané): na potvrdzovacej obrazovke je mikrofón otvorený; ak povieš niečo, čo nie je povel, berie sa to ako nová odpoveď (nahradí starú). Žiadne kúzelné slovo. Ticho do konca odpočtu = potvrdené.
- **5.2 Odpočet až keď mikrofón naozaj počúva** + krátky tón „počúvam“. Odstráni stratu času.
- **5.3 Širšie „nie“ povely**: „nie“, „zle“, „ešte raz“, „znova“ = nahrať znova; „áno“, „hej“, „ok“, „potvrď“ = potvrdiť.
- **5.4 Ponuka alternatív** (napr. „Curling / Carling?“ z viacerých hypotéz prepisu) ako tlačidlá pre spolujazdca. Menší prínos pre vodiča.
- **5.5 Tlačidlo na volante „predošlá skladba“ = znova** (viď 3.2).

**Odporúčanie:** 5.1 + 5.2 + 5.3; 5.5 spolu s 3.2.

---

## 6. MCQ: písmeno „c“ nerozumie

**Čo sa deje:** od #184 sa hlasová MCQ odpoveď vyhodnocuje len na serveri a len presnou zhodou s textom možnosti. Šikovnejšie párovanie v appke (písmená „céčko“, poradie „tretia“, skloňovanie) sa na tejto ceste vôbec nepoužije (regresia). Samotné „C“ má jeden znak a server ho zahodí ako prázdne; krátka slabika môže byť aj pod minimálnou dĺžkou reči.

**Návrhy označenia možností:**

| | Označenie | Prečo |
|---|---|---|
| **A** | **Čísla 1 až 4; písmená A až D len keď sú odpovede čísla** (tvoj návrh) | „jedna/dva/tri/štyri“ sú dlhšie a zreteľnejšie slová ako „cé“, rozpoznanie spoľahlivejšie |
| **B** | Písmená, ale hovorené „áčko, béčko, céčko, déčko“ | zaužívané v SK kvízoch, ale treba to užívateľa naučiť |
| **C** | Bez označenia, len text odpovede | najprirodzenejšie, ale dlhé odpovede sa zle hovoria |

**Vo všetkých prípadoch prijať všetko:** číslo, písmeno, poradie („prvá“, „posledná“) aj text možnosti. Pri čísleach ako odpovediach (roky, počty) prepnúť na písmená, aby „tri“ nebolo nejednoznačné.

**Odporúčanie:** A + prijímať všetky formy + opraviť regresiu (párovanie presunúť na server, aby bol jeden zdroj pravdy) + prepisu dať ako nápovedu označenia („jedna, dva, tri, štyri“ alebo „áčko…“).

---

## Stabilizácia stavov kvízu (dlhodobé)

Research: [quiz-state-robustness-2026-09-24.md](../../research/quiz-state-robustness-2026-09-24.md) (26 zdrojov).

**Hlavný záver:** oneskorené výsledky (prepis, vyhodnotenie, časovače, prehrávanie) nie sú viazané na otázku a pokus, ktorý ich spustil. Poistky kontrolujú len názov fázy („spracúvam“), takže neskorá odpoveď z otázky N prejde aj počas otázky N+1. Netreba nový framework; treba ten princíp dotiahnuť.

| Krok | Čo | Čomu zabráni | Veľkosť |
|---|---|---|---|
| 1 | Každý pokus o odpoveď dostane „lístok“ (otázka + poradie); každý asynchrónny výsledok ho overí, inak sa zahodí. Každý zamietnutý prechod ide do Sentry + „čierna skrinka“ posledných udalostí pri TF feedbacku | celej triede „stav z minulej otázky“ + dá dôkaz z auta | malý |
| 2 | Test, ktorý náhodne kombinuje udalosti (reč, povely, časovače, prerušenia) a po každom kroku overí pravidlá; pád zredukuje na minimálnu sekvenciu; záznamy z auta sa dajú prehrať ako test | chybám, ktoré ručne nikoho nenapadnú | stredný |
| 3 | Zlúčiť roztrúsené prepínače do jedného stavu s lístkom (po častiach, najprv potvrdzovanie) | nemožné kombinácie stavov | stredný až veľký, keď sa na kód aj tak siaha |
| 4 | Úplný „reduktor“ (čistá funkcia stav + udalosť) | zvyšku | veľký, len ak 1 až 3 nestačia; nie pred launchom |

**Odporúčanie:** krok 1 spolu s opravou bugu 1 (je malý a priamo ho rieši), krok 2 hneď potom, krok 3 priebežne. Nepreberať TCA ani iný framework celý.

---

## 7. Obrazovka zhasne na výsledkoch (doplnené 24. 9.)

Počas čítania odpovedí a vysvetlení na výsledkoch sa vypína displej. Appka drží displej zapnutý počas kvízu, ale nie v stave „kvíz skončený“; pravdepodobne práve v ňom beží čítanie výsledkov na konci sady. Oprava: displej držať, kým kvíz naozaj neskončí (vrátane čítania). Bez rozhodnutia.

---

## Rozhodnutia (24. 9.)

<span class="badge ok">ROZHODNUTÉ</span> Detail a tracky: [issue #185](../../issues/issue-185-car-test-2026-09-23.md) · [#186](../../issues/issue-186-quiz-state-robustness.md) · [#187](../../issues/issue-187-car-media-buttons.md).

| | Rozhodnutie |
|---|---|
| 1 | 1.1: „Nepočul som, povedz to znova“ + nový pokus; po 2. neúspechu bez automatického preskočenia |
| 2 | A + B, ale hľadať kompromis so zachovaním potlačenia šumu (režim hovoru mal veľmi zlú kvalitu) a otestovať viac variantov; ukladanie nahrávok zapnúť |
| 3 | 3.1 + 3.4 + 3.5; tlačidlá na volante do budúcnosti (#187) |
| 4a | 4a.1, radšej benevolentnejšie |
| 4b | A + B + jemný tón pri začiatku reči + oprava auto-stopu |
| 5 | 5.1 až 5.4; slová nie, zle, ešte raz, stop, znova; slovník vždy vo všetkých jazykoch |
| 6 | Čísla 1 až 4, písmená pri číselných odpovediach |
| Tóny | zjemniť, stíšiť, pridať haptiku |
| Stavy | krok 1 aj 2 teraz |
