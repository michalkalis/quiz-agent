# Zvláštne štatistiky hráča

Nápad foundera (2026-10-27): netypické, zábavné štatistiky o tom, *ako* hráč odpovedá. Napríklad hýbe telefónom viac, keď odpovedá zle, mení hlas, spomalí, otáča mobilom, keď si nie je istý.

## Zhrnutie

- **Kvízová appka, ktorá by to robila, neexistuje.** Nenašiel som žiadnu. Je to voľné miesto na trhu, ktoré môže Trubbo odlíšiť.
- **Najlepší zdroj máme zadarmo: hlas.** Appka už nahráva každú odpoveď a meria hlasitosť. Rýchlosť odpovede, váhanie, hlasitosť a slová ako „asi“ či „určite“ sa dajú zmerať priamo v telefóne, bez nového povolenia a bez AI.
- **Pohyb telefónu je najslabší kandidát.** V aute je mobil v držiaku a hýbe ním auto, nie hráč. Funguje len doma alebo na párty, keď ho niekto drží v ruke. Navyše na podobný nápad (nervozita z otrasov ovládača) má patent Nintendo.
- **Nehovoriť o pocitoch, len o správaní.** „Keď povieš ‚asi‘, máš pravdu v 40 %“ je zábavné a pravdivé. „Bol si nervózny“ je veda na vode a od augusta 2026 to v EÚ spadá pod pravidlá pre rozpoznávanie emócií.

## Čo robia iní

| Kto | Čo meria | Poučenie pre nás |
|---|---|---|
| Spotify Wrapped | osobnostné typy („Maestro“, „Adventurer“), hra „tipni si svoje čísla“ | typ hráča + tipovanie vlastných štatistík ľudí baví a zdieľajú to |
| Yoodli, Orai (tréning reči) | počet „ehm“, slová za minútu, pauzy, energia hlasu | tieto merania sú overené a ľudia ich chápu |
| „Lie Detector“ party appky | kolísanie hlasitosti, váhanie, „trasenie“ hlasu | existujú ako zábava, vedecky nefungujú |
| Nevermind (hra) | strach cez tep alebo kameru, hra sa sťaží | biofeedback v hrách funguje, ale potrebuje senzor |
| Nintendo patent US 8821298 | nervozita z otrasov ovládača a zbytočných dotykov | presne náš nápad s pohybom, len patentovaný |
| IBM patent, výskum 2026 | istota z páuz a výplňových slov | váhanie v reči je merateľný signál istoty |

## Návrhy

Zoradené od najistejšieho po najodvážnejší.

### A. Hlasové zvyky (odporúčam ako prvé) <span class="badge ok">bez povolenia</span>

Všetko z nahrávky, ktorú už máme. Počíta sa v telefóne, ukladajú sa len čísla, nie zvuk.

1. **„Asi“ verzus „určite“.** Slová neistoty a istoty v odpovedi (sk/cs/en). *„Keď povieš ‚asi‘, trafíš 4 z 10. Keď ‚určite‘, 9 z 10.“* Najzábavnejšie a najpravdivejšie zo všetkých.
2. **Prvý inštinkt.** Ako často platí prvá odpoveď a ako často pomohla zmena názoru. *„Zmenil si názor 3×. Pomohlo to raz.“*
3. **Rýchlosť.** Čas od konca otázky po odpoveď, porovnaný so správnosťou. *„Správne odpovede vystrelíš o 2 sekundy rýchlejšie.“* Najrýchlejšia správna odpoveď kola.
4. **Hlasitosť.** Hlasnejšie pri správnych alebo pri zlých? Vždy len v rámci jedného kola, lebo v aute hučí motor. *„Zlé odpovede hovoríš o tretinu tichšie.“*
5. **Váhanie.** Pauza pred odpoveďou a „ehm, hmm“. *„Najdlhšie si váhal pri histórii.“*

### B. Typ hráča a mesačný prehľad <span class="badge info">nadstavba nad A</span>

Z čísel z bodu A raz za mesiac poskladať typ hráča: *Rýchlostrelec*, *Opatrný mudrc*, *Tipér s intuíciou*. Pred odhalením si hráč tipne svoje čísla, ako vo Wrapped. Vznikne karta na zdieľanie, ktorá poslúži aj marketingu na sociálnych sieťach.

### C. Pohyb telefónu <span class="badge warn">len mimo auta</span>

Zapína sa len keď appka vie, že sa nejazdí, a telefón je v ruke. *„Pri ťažkých otázkach si krútil mobilom.“* Bez povolenia sa dá čítať len samotný pohyb. Na rozpoznanie jazdy treba povolenie „Pohyb a kondícia“. Pred stavbou treba preveriť Nintendo patent. Odporúčam až po A, a len ak sa osvedčí.

### D. Rozpoznávanie emócií z hlasu <span class="badge bad">neodporúčam</span>

„Stres v hlase“, „nervozita“. Výsledky sú nespoľahlivé, ľudia to vnímajú ako šmírovanie a EÚ zákon o AI ukladá pri rozpoznávaní emócií povinnosť informovať, možno aj prísnejšie pravidlá. Rovnaký zážitok dá bod A bez týchto rizík.

## Ako to ukázať

- **Jedna zaujímavosť na konci kola**, nie celý prehľad. Pasuje k pokojnému dizajnu a k pravidlu o málo zvukoch.
- **Len hravé alebo neutrálne vety.** Podľa pravidiel z gamifikácie: žiadne zosmiešňovanie chýb, pri slabom kole radšej mlčať.
- **Hra spolu:** pri viacerých hráčoch na jednom telefóne sa hlasy nedajú spoľahlivo rozlíšiť. Tam len štatistiky celej skupiny.
- **Súkromie:** všetko sa počíta v telefóne, na server idú len čísla. Doplniť vetu do zásad ochrany súkromia.

## Otvorené rozhodnutia pre foundera

1. Ktoré smery chceš: A, A+B, alebo aj C?
2. Zaujímavosť na konci kola: aj nahlas (prečíta hlas), alebo len na obrazovke?
3. Mesačný typ hráča: zdarma pre všetkých, alebo súčasť predplatného?

## Zdroje

- Nintendo patent nervozity z ovládača: <https://patents.google.com/patent/US8821298>
- IBM patent, hodnotenie podľa váhania v reči: <https://patents.justia.com/patent/10339923>
- Rozpoznanie istoty hovoriaceho z hlasu (2026): <https://arxiv.org/pdf/2605.12387>
- Party appka „Lie Detector“: <https://apps.apple.com/om/app/id6762190053>
- Yoodli, výplňové slová: <https://yoodli.ai/blog/how-to-stop-using-filler-words>
- Nevermind (biofeedback): <https://store.steampowered.com/app/342260>
- EÚ AI Act, článok 50: <https://artificialintelligenceact.eu/transparency-rules-article-50/>
- Rozpoznávanie emócií a transparentnosť: <https://www.stibbe.com/publications-and-insights/feeling-watched-transparency-obligations-for-emotion-recognition-and>
- StatsApp (Wrapped štýl): <https://apps.apple.com/mx/app/statsapp-for-spotify-stats/id6460035325>
