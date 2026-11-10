# #232 — Odporuč Trubbo kamarátovi + zdieľanie vlastného balíka

**Triage:** enhancement · ready-for-agent
**Status:** plán 2026-11-09, rozhodnutia foundera nižšie, design-soundness SOUND 0,85 (2 kolá); ďalej 232.0 overenie
**Founder:** 2026-11-09 „viac propagovať zdieľanie appky za nejaký benefit, napríklad balík 10 custom otázok“
**Návrh a prieskum:** https://claude.ai/artifact/FT91hmcTC6Xhczf7TpJnmQ (session quiz-agent-20)

## Cieľ

Hráč pozve kamaráta alebo mu pošle svoj vlastný balík. Keď kamarát v appke dohrá prvý kvíz, pozývajúci dostane vlastný balík 10 otázok zadarmo.

**Hotovo, keď:**
- hráč pošle pozvánku a kamarát sa cez odkaz (alebo kód) dostane do appky;
- pozývajúci dostane balík 10 otázok s témou podľa vlastného výberu, keď kamarát dohrá prvý kvíz, sólo alebo ako hosť v hre spolu;
- jeden človek dostane najviac 3 takéto balíky a jeden fyzický mobil môže odmenu spustiť len raz;
- hráč pošle svoj vlastný balík kamarátovi, ktorý si ho zahrá zadarmo;
- hotový vlastný balík sa dá hrať v hre spolu;
- všetko je za vypínačom na serveri, analytické udalosti sú v tom istom PR a test na zariadení prešiel.

## Rozhodnutia foundera (2026-11-09)

| Otázka | Voľba |
|---|---|
| Kto dostane odmenu | **Len pozývajúci** (pozvaný nič, bezpečné voči Apple 3.2.2) |
| Odmena | Vlastný balík **10 otázok**, tému si vyberie pozývajúci |
| Kedy | Až keď kamarát **dohrá prvý kvíz**, samotné pozvanie ani stiahnutie nestačí |
| Strop | **3 balíky na človeka**. Rozpočet je takmer nulový: aj keď pozve influencer, náklad je najviac ~$3. Iné stratégie až z tržieb. |
| Zdieľanie balíka | **Hneď spolu** s odporúčaním |
| Ochrana proti zneužitiu | **Obe poistky** (2026-11-10, „ak je to bežná best practice“): označenie mobilu kamaráta cez Apple DeviceCheck a odmena až po prihlásení pozývajúceho cez Apple. Obe sú bežné: Apple uvádza DeviceCheck práve na mobily, ktoré už využili promo ponuku, a odporúčacie programy (Dropbox, Revolut, Duolingo) odmenu dávajú len na účet. |
| Balík v hre spolu | Founder sa pýtal „môžu si custom balík zahrať spolu, že?“. Dnes **nie**, server balíky v miestnosti odmieta (len sólo). Pridávam to sem, lebo je to prirodzený spôsob, ako balík zdieľať. |

## Čo už platí (overené 2026-11-09)

- **Odkazy:** pozvánky do hry spolu idú cez trubbo.app/join?t=… a otvárajú appku (univerzálny odkaz). Bez appky sa zobrazí statická stránka join.html v sk/cs/en s tlačidlom App Store. Web je statický (GitHub Pages, bez smerovania ciest), takže nová stránka musí ísť rovnakým spôsobom: p.html a trubbo.app/p?c=KÓD. Do appky sa po inštalácii nedá preniesť žiadny údaj, takže kód treba zadať ručne.
- **Balík zadarmo bez nákupu:** server balíkov vytvára objednávky s vlastným identifikátorom transakcie a rovnaký identifikátor nikdy nevytvorí balík druhýkrát. Kópiu hotového balíka pre iného vlastníka už vie urobiť (#225 opätovné použitie balíka).
- **Vlastníctvo balíka:** balík patrí jednému hráčovi a zoznam „Moje balíky“ sa skladá z jeho objednávok. Ochrana proti čítaniu cudzích balíkov sa nemení.
- **Hráči:** predvolene anonymní, Prihlásenie cez Apple je voliteľné a zlúčenie účtov existuje. Prihlasovacie údaje sú v iPhone Keychain, ktorý reinštaláciu zvyčajne prežije, ale Apple to nezaručuje. Anonymnú identitu preto nemožno brať ako poistku proti zneužitiu.
- **Dohraný kvíz:** zapisuje sa hráčovi, ktorému patrí relácia. V hre spolu je to hostiteľ, takže hosť dnes „nedohrá“ nič.
- **Balík v miestnosti:** server ho odmieta pri vytváraní miestnosti (spoločná podmienka s dennou výzvou). Vlastníctvo balíka sa overí už pri štarte relácie hostiteľa. Hra v miestnosti nečaká na balík, ktorý sa ešte vyrába, a pri prázdnom zásobníku skončí.
- **Analytika:** vlastná tabuľka udalostí so zoznamom povolených. Zdieľanie dnes meria len zhrnutie profilu.
- **Kampaňové odkazy App Store** ukazujú len súhrny, nie konkrétneho človeka, takže na pripísanie odmeny nestačia.
- **Prieskum:** odporúčanie je doplnok, nie hlavný zdroj hráčov (Duolingo +3 %). Zdroje sú v artefakte.

## Návrh riešenia

**Osobný kód.** Každý hráč má krátky kód (6 znakov, bez zameniteľných znakov). Odkaz trubbo.app/p?c=KÓD otvorí appku, ak ju kamarát má, a kód sa doplní sám. Ak appku nemá, zobrazí sa stránka s tlačidlom App Store a veľkým kódom, ktorý zadá v appke v časti „Mám kód od kamaráta“ (v profile a po prvom kvíze).

**Ochrana proti zneužitiu** (hlavný predpoklad, nie doplnok). Anonymná identita sa dá obnoviť reinštaláciou, preto sa obe strany viažu na niečo trvalejšie:
- **Mobil kamaráta:** Apple DeviceCheck (bez SDK, Apple si drží 2 bity na fyzický mobil pre celý vývojársky tím, [dokumentácia](https://developer.apple.com/documentation/devicecheck/dcdevice)). Pri pripísaní odmeny server nastaví bit „tento mobil už odmenu spustil“. Bit prežije reinštaláciu, vynuluje sa až rozhodnutím servera. Bez platného DeviceCheck tokenu (simulátor, chyba) odmena nepríde. Server spracúva uplatnenia jedného mobilu postupne, lebo prečítanie a zápis bitu nie sú jedna operácia. Použijeme jeden z dvoch bitov a druhý ostane voľný.
- **Pozývajúci:** odmenu dostane len hráč **prihlásený cez Apple**. Strop 3 sa ráta na Apple účet, ktorý reinštaláciu prežije. Odkaz a kód môže poslať ktokoľvek. Kým sa neprihlási, odmena čaká a appka mu to povie („prihlás sa a balík je tvoj“).
- **Ďalej:** vlastný kód sa nedá použiť. Kód sa prijme len od hráča, ktorý ešte nedohral žiadny kvíz, alebo je v appke najviac 7 dní.
- **Výsledok:** jedna odmena si vyžaduje nový fyzický mobil, takže zneužitie sa nedá opakovať v slučke.

**Kedy sa odmena pripíše.** Keď kamarát po zadaní kódu dohrá kvíz, sólo aj ako hosť v hre spolu. Koniec hry v miestnosti sa preto ráta každému účastníkovi zvlášť, nie len hostiteľovi. Inak by pozvánka „po hre spolu“ nikdy nefungovala.

**Odmena ako kredit, bez novej knihy.** Riadok odporúčania je zároveň kredit (stavy: čaká na prihlásenie, získaný, minutý, číslo objednávky). Pozývajúci uvidí na Domove „Máš balík zadarmo, vyber tému“. Minutie ide existujúcim vytvorením objednávky s identifikátorom referral-{id}, takže jeden kredit dá najviac jeden balík. Tabuľka je v spoločnej databáze. Vlastní ju quiz-agent (pozná hráčov a dohrané kvízy) a quiz-pack-api kredit len mení na objednávku (rovnaký vzor ako app_switches). Kredit nevyprší. Po 3 odmenách sa pozvánky dajú posielať ďalej, ale appka vopred povie, že odmena už nepríde.

**Zdieľanie balíka.** Pri vlastnom hotovom balíku je „Pošli kamarátovi“. Odkaz trubbo.app/p?c=KÓD&b=TOKEN nesie aj kód odosielateľa.
- Kamarátovi vznikne **vlastná kópia** existujúcou kópiou balíka (#225) a objednávka s identifikátorom share-{token}-{hráč}. Opakované otvorenie nič nezduplikuje a balík sa mu zobrazí v jeho zozname.
- Pravidlá vlastníctva sa nemenia.
- Webová stránka ukáže tému balíka cez verejný endpoint, ktorý podľa tokenu vráti len názov a jazyk.
- Ak je kamarát nový a dohrá kvíz, odosielateľ dostane odmenu ako pri pozvánke.

**Balík v hre spolu.** Podmienka pri zakladaní miestnosti sa rozdelí: denná výzva ostáva len sólo, **hotový** vlastný balík sa povolí. Balík, ktorý sa ešte vyrába, sa pre miestnosť nedá vybrať, takže netreba čakanie v hre spolu. Hostia dostávajú otázky v tom istom tvare ako dnes, kontrakt sa nemení.

**Kde sa ponúkne.** Riadok „Pozvi kamaráta“ v profile, nenápadná výzva po dobre odohranom kvíze (najviac raz za čas) a po hre spolu. Nič nevyskakuje opakovane.

**Súkromie.** Len systémové okno zdieľania. Appka nikomu nepíše, nečíta kontakty a nevyžaduje žiadne povolenie (Apple 5.1.2, GDPR).

**Pravidlá Apple.** Odmena len pre pozývajúceho a až za činnosť v appke (3.2.2). Zaplatený obsah sa nikdy nepodmieňuje zdieľaním (3.1.2). Poslaný balík je obsah, ktorý odosielateľ už má, nič sa ním neodomyká mimo nákupov.

**Kompatibilita a vypínač.** Prepínač v app-config na serveri, predvolene vypnutý, kým founder neotestuje (pravidlo z 2026-10-16). Nové endpointy a polia sú len doplnky a v existujúcich odpovediach nepribudne žiadna nová hodnota zoznamu (napr. dôvod konca miestnosti), aby prešla kontrola kompatibility starých buildov.

## Úlohy

- [ ] **232.0 Overenie a príprava**
  - DeviceCheck: na reálnom iPhone overiť, či bit prežije reinštaláciu.
  - Founder vytvorí kľúč DeviceCheck (.p8) v Apple Developer. Agent dá presný postup, kľúč pôjde do tajných premenných servera, nikdy do chatu.
  - Overiť, či Keychain identita prežije reinštaláciu (len na informáciu, poistka na tom nestojí).
  - Univerzálny odkaz /p vedľa /join.
- [ ] **232.1 Server: kódy, ochrana, kredity**
  - Kód hráča.
  - Uplatnenie kódu s DeviceCheck a pravidlami vyššie.
  - Koniec hry pre každého účastníka miestnosti.
  - Pripísanie odmeny, kredit na Apple účet, strop 3.
  - Minutie kreditu cez objednávku referral-{id}.
  - Vypínač.
  - Udalosti: pozvánka zdieľaná, kód uplatnený, odmena pripísaná, kredit použitý.
- [ ] **232.2 Server: zdieľaný balík + balík v hre spolu**
  - Zdieľací token.
  - Kópia balíka kamarátovi (share-…).
  - Verejný endpoint s názvom a jazykom balíka.
  - Miestnosť prijme hotový balík.
  - Udalosti: balík zdieľaný, zdieľaný balík otvorený a dohraný, miestnosť s balíkom.
- [ ] **232.3 Web**
  - p.html v sk/cs/en (kód, tlačidlo App Store, téma balíka).
  - Rozšírenie súboru pre univerzálne odkazy.
- [ ] **232.4 Appka**
  - Pozvi kamaráta (profil, po kvíze, po hre spolu).
  - Pole na kód a DeviceCheck token.
  - Kredit, výzva na prihlásenie a výber témy.
  - Pošli kamarátovi pri balíku.
  - Výber hotového balíka v hre spolu.
  - Texty sk/cs/en cez xcstrings.
  - Pixel snímky.
- [ ] **232.5 Texty na schválenie**
  - Správa pri zdieľaní, web a appka v artefakte pre foundera.
  - Podľa copy-style: rodovo neutrálne, nie ako AI a bez cien v texte zdieľania.
- [ ] **232.6 Test foundera** na TestFlight builde (keď si ho vyžiada): dva reálne iPhony, pozvánka, odmena, zdieľaný balík, balík v hre spolu. Potom zapnúť vypínač.

## Otvorené

- Náklad balíka 10 je len odhad (~$1, z merania balíka 30). Prvé odmeny zmerať, úzke témy vychádzajú drahšie.
- Pozvaný kamarát nedostane nič (rozhodnutie). Ak sa ukáže, že pozvánky nikto neprijíma, vrátiť sa k tomu až s dátami z udalostí.
- **Pri implementácii (z kontroly):**
  - Koniec hry pre každého účastníka mení, čo počíta udalosť dohraného kvízu. Pridať vlastnosť hostiteľ/hosť alebo samostatnú udalosť, aby sedeli prehľady aj limity.
  - Strop 3 overovať pri prevzatí a pri zlúčení účtov, nie pri vzniku. Inak zlúčenie viacerých anonymných identít prekročí strop.
  - Objednávky referral- a share- potrebujú vlastnú vetvu oprávnenia vedľa nákupu a administrátora. Nikdy neprijmú identifikátor s predponou od appky a pozastavenie objednávok aj kópia balíka pre ne platia.
