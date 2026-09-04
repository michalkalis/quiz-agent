# #170 Coverage-driven dedup — Session A: súhrn a rozhodnutia (2026-09-04)

<span class="badge ok">Session A hotová</span> <span class="badge info">PR #83 merged</span> <span class="badge warn">Produkcia: nedotknutá, #170 ostáva mimo main</span>

## 1. Stav v jednej vete

Skript na návrh podtém je hotový, otestovaný a zmergovaný; dva návrhy podtém čakajú na tvoje schválenie. Pipeline generovania otázok sa **nezmenil ani o riadok**. Podľa tvojho pokynu (2026-09-04) ide všetka ďalšia práca na #170 na **oddelenú integračnú vetvu**, nie na main a nie do produkcie.

## 2. Tvoj pokyn a ako ho riešim

**Pokyn:** práca na #170 môže pokračovať, ale nesmie ísť do produkcie ani ovplyvniť kvalitu dnešných otázok; duplikáty zatiaľ nie sú reálny problém.

**Riešenie: integračná vetva `feat/170-coverage-dedup`.**

| Čo | Ako |
|---|---|
| Kde žije kód #170 | vetva `feat/170-coverage-dedup`, založená z main; každé sedenie (B–L) ide cez PR **do tejto vetvy**, nie do main |
| Review a testy | Claude Code Review beží na každom PR bez ohľadu na cieľovú vetvu; backend CI dostane túto vetvu do zoznamu (jednoriadková zmena workflow) |
| Produkcia | deploy ide výhradne z `origin/main` (deploy skill), takže integračná vetva sa **nemôže** dostať do produkcie omylom; migrácia schémy, backfilly a prepínače ostávajú mimo produkcie |
| Údržba | vetva sa priebežne rebase-uje na main, aby nezastarala |
| Kedy do main | až keď povieš, že duplikáty sú reálny problém; aj potom platí plán: všetky prepínače OFF, slepé porovnanie kvality pred zapnutím čohokoľvek |
| Čo už je na main | len skript na návrh podtém, jeho testy a dokumenty (PR #83, #84). Nič z toho pipeline nečíta, takže netreba nič vracať späť |

Kroky z plánu, ktoré sa dotýkajú produkcie (migrácia, backfilly, publikácia na rating web, zapnutie prepínačov), sú tým **odložené na neurčito**, kým nepovieš inak.

## 3. Rozhodnutia, ktoré potrebujem od teba

| # | Rozhodnutie | Odporúčanie | Prečo |
|---|---|---|---|
| R1 | **Taxonómia kategórií pre podtémy:** 6 záujmových + `entertainment`, alebo 9 starých generačných kategórií | **6 záujmových + entertainment** | appka a prod korpus bežia na 6 záujmových kategóriách od augusta; staré fandom a vekové kategórie nemajú ani jednu živú otázku; generátor dnes záujmovú kategóriu ani nevie zapísať (padá na `general`), čo treba zosúladiť pred Session B |
| R2 | **Čo je „živá“ otázka** pre mapu pokrytia a výber kategórie experimentu: approved + pending, alebo len approved | **approved + pending** | obe sa hrajú (approved v prode, pending na TestFlighte); archivované otázky (565 z 949) sa nesmú rátať vôbec, dnešný dotaz z plánu by inak vybral `adults` s 307 archivovanými |
| R3 | **Schválenie podtém** v `docs/testing/runs/170-coverage-steering/subtopics-proposal.json` | prejsť, škrtať, dopĺňať | pravidlá: aspoň 10 na kategóriu, do 64 znakov, bez duplicít; podtéma je široké územie, nie jedno dielo či osoba |
| R4 | **Potvrdiť vetvovú stratégiu** z bodu 2 | integračná vetva | alternatíva „merge do main s prepínačmi OFF“ by priniesla migráciu schémy do produkcie, čo si nechcel |

Až po R1 až R4 spúšťam Session B (zmrazenie schválených podtém do vetvy #170).

## 4. Prod korpus dnes (read-only dotaz, 949 otázok mimo packov)

| kategória | živé (approved + pending) | z toho approved | archív |
|---|---:|---:|---:|
| general | 81 | 18 | 70 |
| science-nature | 81 | 51 | 0 |
| movies-music | 62 | 35 | 0 |
| geography-world | 40 | 13 | 0 |
| history | 40 | 16 | 0 |
| sports | 30 | 6 | 0 |
| food-everyday | 28 | 9 | 0 |
| entertainment | 21 | 21 | 0 |
| adults | 0 | 0 | 307 |
| kids | 0 | 0 | 52 |
| superheroes | 0 | 0 | 34 |
| sports-mix · wizarding-world | 0 | 0 | 30 · 30 |
| football · disney | 0 | 0 | 22 · 20 |

Poznámky: 63 nových otázok čaká na review pod `general`, lebo generátor nevie emitovať záujmové kategórie (potvrdzuje R1). 240 otázok nemá vyplnený jazyk; plán to rieši backfillom. 21 otázok `entertainment` z #167 je pod kategóriou, ktorú picker appky nepozná, hrajú sa len bez filtra kategórie.

## 5. Návrh podtém (odporúčaná taxonómia, 20 na kategóriu)

Zapracované tvoje poznámky: podtémy sú **široké hinty, nie ploty** (model dostal zákaz úzkych tém typu jedno dielo alebo osoba), inšpirácia = medzinárodná časť banky tém z „Kvíz, please!“, čisto české témy vynechané.

<details><summary>science-nature</summary>

Mammals and their behaviour · Birds, reptiles, amphibians and insects · Marine life and the oceans · Dinosaurs and prehistoric life · Trees, flowers and plant life · Fungi, microbes and the microscopic world · Human anatomy and the senses · Diseases, medicine and first aid · Chemical elements and the periodic table · Everyday chemistry and materials · Forces, energy, light and sound · Planets, moons and the solar system · Stars, galaxies and space exploration · Weather, climate and natural disasters · Volcanoes, rocks and the Earth's structure · Inventions and inventors · Computers, gadgets and everyday technology · Units and things named after scientists · Famous scientists, rivalries and Nobel Prizes · Records and extremes in nature

</details>

<details><summary>history</summary>

Prehistory and early humans · Ancient Egypt and Mesopotamia · Ancient Greece and Rome · Ancient China, India and the Americas · Medieval Europe and the Vikings · Islamic caliphates and Asian empires · Kings, queens and royal dynasties · Explorers and voyages of discovery · Colonial empires and decolonisation · Revolutions and uprisings · Famous battles and military leaders · World War I · World War II · The Cold War era · Assassinations and mysterious deaths · Plagues, famines and disasters · Everyday life in past centuries · Nicknames of historical figures · Vanished states and lost cities · Treaties, documents and famous speeches

</details>

<details><summary>geography-world</summary>

Capital cities of the world · Countries and their neighbours · Enclaves, exclaves and disputed territories · Rivers, lakes and waterfalls · Mountains, volcanoes and peaks · Oceans, seas and straits · Islands, archipelagos and peninsulas · Deserts, forests and natural wonders · Flags, anthems and national symbols · Languages and writing systems of the world · Peoples, ethnic groups and demonyms · Famous landmarks and monuments · Geographical records and extremes · Microstates, territories and dependencies · Vanished states and renamed places · City nicknames and place-name origins · Currencies and international organisations · Regions, provinces and US states · Climate, time zones and hemispheres · Megacities and famous urban districts

</details>

<details><summary>movies-music</summary>

Golden-age Hollywood and film classics · Famous directors and their signature films · Actors and their iconic roles · Film awards and festivals · Famous movie lines and taglines · Movie villains, monsters and creatures · Film franchises, sequels and remakes · Animated films and their characters · World cinema beyond Hollywood · TV series, sitcoms and crime dramas · Reality, game shows and TV formats · Film soundtracks and TV theme songs · Rock and metal bands · Pop stars and chart-topping hits · Hip-hop, R&B, electronic and dance music · Classical music, opera and instruments · Jazz, blues, folk and world music · Stage names, duos and famous rivalries · Musicals on stage and screen · Records, firsts and extremes in film and music

</details>

<details><summary>sports</summary>

Club football and domestic leagues · World Cup and international football · Olympic Games history and host cities · Tennis stars and Grand Slam tournaments · Motorsport and racing drivers · Winter sports and ice hockey · Athletics and track-and-field records · Basketball, baseball and American football · Rugby, cricket, handball and volleyball · Combat sports and martial arts · Swimming, sailing and water sports · Golf, snooker, darts and precision sports · Cycling, marathons and endurance events · Sports rules, scoring and equipment · Stadiums, venues and sports geography · Athlete nicknames and famous rivalries · Sports origins, firsts and inventors · Doping, scandals and sporting controversies · Trophies, mascots and sporting traditions · Extreme, unusual and traditional sports

</details>

<details><summary>food-everyday</summary>

World cuisines and national dishes · Cooking methods and kitchen equipment · Spices, herbs and condiments · Fruits, vegetables and nuts · Meat, fish and seafood dishes · Bread, pasta, rice and grains · Cheese, eggs and dairy · Desserts, sweets and chocolate · Coffee, tea and soft drinks · Beer, wine and spirits · Cocktails and drinking customs · Fast food and restaurant chains · Foods named after people and places · Diets, nutrition and food science · Global brands, logos and slogans · Supermarkets, shopping and packaging · Cars, driving and car makers · Public transport, roads and travel · Household objects and their inventors · Hobbies, crafts, toys and games

</details>

<details><summary>entertainment</summary>

Animated films and their characters · Film franchises, sequels and remakes · Famous film quotes and iconic scenes · Superheroes and comic book adaptations · Directors and behind-the-scenes trivia · World cinema and film festivals · Box office records, flops and firsts · Sitcoms and comedy series · Crime, drama and fantasy series · Reality shows, talent shows and game shows · Pop stars and chart-topping hits · Rock, metal and legendary bands · Hip-hop, R&B and electronic music · Film music, soundtracks and musicals · Music festivals, tours and song contests · Awards ceremonies and their winners · Video game characters and worlds · Esports, streamers and the gaming industry · Memes, viral videos and internet culture · Stage names, nicknames and celebrity families

</details>

Postreh: `movies-music` a `entertainment` sa prekrývajú zhruba na polovicu. Je to dôsledok dvoch taxonómií (R1), nie chyba návrhu; po R1 sa jedna z nich zúži alebo zlúči.

Záložný návrh pre 8 starých kategórií je v `subtopics-proposal-legacy-taxonomy.json` (použije sa iba ak v R1 ponecháš starú taxonómiu).

## 6. Čo je zaručené ohľadom kvality otázok

- Dnes: generačný prompt, model, teplota a poradie krokov sú byte-identické so stavom pred #170. Skript na podtémy beží mimo pipeline a nič nečíta z neho.
- Na integračnej vetve: každá zmena promptu alebo dedupu je za prepínačom s predvoleným OFF; zapnúť ju smieš len ty, až po slepom ratovanom porovnaní (rovnaká kategória, rovnaký model), kde nová dávka nesmie byť horšia a ty nesmieš „cítiť rozdiel“.
- Do produkcie sa z vetvy nič nedostane bez tvojho výslovného rozhodnutia o merge do main.

## 7. Ďalšie kroky

1. **Ty:** R1 až R4 (stačí odpoveď v chate, podtémy uprav priamo v JSON alebo mi napíš, čo škrtnúť).
2. **Ja, po tvojom GO:** založím integračnú vetvu, doplním backend CI o túto vetvu, zapíšem vetvovú stratégiu do plánu a spustím Session B.
3. **Kedykoľvek neskôr:** keď povieš, že duplikáty začali bolieť, otvoríme merge do main podľa plánu (prepínače OFF, guard kvality, potom per-prepínač zapnutie).
