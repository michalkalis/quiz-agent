# Obrázkové otázky v Trubbo

Rešerš 2026-10-29 · bez generovania otázok, bez míňania API kreditov (len webové vyhľadávanie a čítanie kódu).
Nadväzuje na #98 — geografické otázky kreslené priamo v appke a #68 — predvolené nastavenia pre jazdu.

## Zhrnutie

- **Základy už máme.** Appka vie zobraziť obrázkovú otázku a odpoveď sa dáva hlasom. Server ju pošle len hráčovi, ktorý si ju zapne, ale prepínač je v appke skrytý, takže ich dnes nikto nedostane. V produkcii je asi 25 starých obrázkových otázok.
- **Najlepší pomer zábava a náklady: skutočné fotky z Wikimedie.** Sú zadarmo a dajú sa zbierať automaticky. Pri štruktúrovaných typoch (vlajka, obraz a jeho autor, pamiatka a jej mesto) sa otázka dá zostaviť zo šablóny, bez AI a bez kreditov.
- **Obrázok k textovej otázke patrí hlavne k odhaleniu odpovede.** Po odpovedi nič neprezradí a pomáha zapamätať si fakt. Pred odpoveďou len vtedy, ak prejde kontrolou, že neprezrádza odpoveď.
- **Obrázok zadarmo má takmer každá otázka z Wikipédie.** Hlavný obrázok článku, z ktorého otázka vznikla, vieme stiahnuť bez poplatku (len voľné licencie).
- **AI generované obrázky len ako ilustrácia** (rébusy, štylizované obrázky). Nikdy pre skutočné miesta, ľudí, vlajky ani umelecké diela, lebo si vymýšľajú detaily a v kvíze je to faktická chyba.
- **Odložiť:** logá (ochranné známky) a tváre žijúcich ľudí (osobnostné práva podľa slovenského Občianskeho zákonníka §12).
- **Navrhovaný ďalší krok:** bezplatný pilot 30 až 50 obrázkových otázok zo šablón, na posúdenie v artefakte. Nič sa nepublikuje, kým ich neschváliš.

## Čo appka dnes vie

| Oblasť | Stav |
|---|---|
| Typ otázky „obrázková“ a odkaz na obrázok | <span class="badge ok">existuje</span> |
| Zobrazenie obrázka nad otázkou, odpoveď hlasom | <span class="badge ok">funguje</span> len pre typ „obrázková“ |
| Obrázok pri bežnej textovej otázke | <span class="badge bad">nie</span> appka ho pri textovej otázke nezobrazí |
| Obrázok pri odhalení odpovede | <span class="badge bad">nie</span> |
| Prepínač „obrázkové otázky“ | <span class="badge warn">skrytý</span> napevno v appke, nedá sa zapnúť zo servera |
| Hra spolu | <span class="badge warn">vypnuté</span> server obrázky v miestnosti vypína; každý telefón má vlastnú kópiu otázky, takže zobraziť obrázok na všetkých je jednoduché |
| Autor a licencia obrázka | <span class="badge bad">chýba</span> nie je kam to uložiť |
| Zber obrázkov z Wikimedie | <span class="badge bad">neexistuje</span> Wikipédiu dnes čítame len kvôli textu |
| Staré generovanie (slepé mapy, obrysy, AI ilustrácie) | <span class="badge warn">ručné skripty</span> nie je v bežnom toku, takmer bez testov; AI ilustrácie bežia na OpenAI modeli, ktorý má byť podľa jedného zdroja vyradený (neoverené) |
| Zvukové otázky (ukážky) | <span class="badge bad">nie</span> typ existuje len na papieri, appka ho neprehrá |

## Typy otázok v kvízoch a ako by fungovali u nás

Zábava je odhad z herných vzorov (Worldle mal v prvý deň 577 tisíc hráčov, Sporcle 6 miliárd odohratí) a z pub kvízov. Tvrdé dáta o tom, ktorý formát je najzábavnejší, som nenašiel.

### Obrázkové

| Formát | Hranie u nás | Zdroj obrázka | Automatizácia | Zábava |
|---|---|---|---|---|
| **Čo je na obrázku** (pamiatka, zviera, rastlina, jedlo, predmet) | hlas, krátka odpoveď | Wikidata + Commons, iNaturalist | <span class="badge ok">vysoká</span> šablóna | vysoká |
| **Priblížený detail, ktorý sa postupne oddiaľuje** | hlas; skorá odpoveď môže dať viac bodov | ten istý obrázok, efekt robí appka | <span class="badge ok">vysoká</span> bez nového obsahu | veľmi vysoká, buduje napätie |
| **Rozmazaný obrázok, ktorý sa vyjasňuje** | hlas | ten istý obrázok, efekt v appke | <span class="badge ok">vysoká</span> | vysoká |
| **Obrys krajiny, slepá mapa** (#98) | hlas | Natural Earth (voľné dielo), kreslí appka | <span class="badge ok">vysoká</span> už navrhnuté | vysoká, overené hrou Worldle |
| **Kto namaľoval tento obraz** | hlas | Met Museum, Art Institute Chicago (CC0) | <span class="badge ok">vysoká</span> | stredná až vysoká |
| **Historická fotka: ktorý rok?** | hlas, body podľa toho, ako blízko | Commons, voľné diela | <span class="badge info">stredná</span> treba bodovanie „najbližšie vyhráva“ | vysoká |
| **Vlajky a erby** | hlas alebo výber | Wikidata | <span class="badge ok">vysoká</span> | stredná; známe vlajky sú klišé, erby slovenských a českých miest sú zaujímavejšie |
| **Čo sem nepatrí** (štyri obrázky) | ťuk alebo „A, B, C, D“ hlasom | Wikidata kategórie | <span class="badge info">stredná</span> | stredná |
| **Vtedy a dnes** (dve fotky miesta) | hlas | Commons | <span class="badge warn">nízka</span> ťažko nájsť páry | stredná |
| **Obrázkový rébus** | hlas | AI ilustrácia alebo emoji | <span class="badge warn">nízka</span> každý jazyk zvlášť | vysoká, ale náročná na kvalitu |
| **Logá** | hlas | — | <span class="badge bad">odložiť</span> ochranné známky | vysoká |
| **Tváre žijúcich ľudí** | hlas | — | <span class="badge bad">odložiť</span> osobnostné práva | vysoká |
| **Nájdi rozdiel** | len ťuk | — | <span class="badge bad">nie</span> | nízka pre náš štýl |

### Bez obrázka (pre úplnosť)

| Formát | Hodí sa? | Poznámka |
|---|---|---|
| Vyššie alebo nižšie | áno, hlasom „vyššie“ / „nižšie“ | jednoduché zo šablón (počty obyvateľov, výšky) |
| Odhad čísla, najbližší vyhráva | áno | potrebuje nové bodovanie |
| Zoradenie troch až štyroch vecí | áno, ak sú možnosti očíslované | ťažšie hlasom |
| Spojitosť (čo majú spoločné) | áno | zábavné, náročné na kvalitu |
| Zvukové ukážky (hudba) | áno, najlepšie pre auto | licencie hudby sú drahé; voľné zvuky (zvieratá, nástroje) z Commons sú zadarmo |

## Obrázok k textovej otázke

Tri miesta, kde sa môže zobraziť:

1. **Pri odhalení odpovede** <span class="badge ok">odporúčam</span> Nič neprezradí. Výskum zapamätania (efekt prevahy obrázka nad slovom) ukazuje, že obrázok spolu s textom sa pamätá lepšie ako samotný text. Zároveň to dáva odhaleniu „odmenu“.
2. **Pred odpoveďou ako kontext** <span class="badge warn">s kontrolou</span> Pomôže pri otázkach, kde slovný opis nestačí. Riziko: fotka Sagrady Família pri otázke „V ktorom meste…“ prezradí odpoveď. Každý taký obrázok musí prejsť kontrolou prezradenia.
3. **Vôbec** pri otázkach, kde obrázok nemá zmysel (abstraktné pojmy, čísla). Čisto dekoratívne obrázky podľa výskumu takmer nepomáhajú (neoverené presne), takže obrázok musí súvisieť s faktom.

Zdroj zadarmo: hlavný obrázok článku Wikipédie, ktorý je už zdrojom otázky. Vyberáme len voľné licencie. Obrázok sa stiahne raz do nášho úložiska, appka ho nikdy neťahá priamo z Wikimedie.

## Zdroje obrázkov

| Zdroj | Čo ponúka | Licencia | Cena | Poznámka |
|---|---|---|---|---|
| Wikimedia Commons + Wikidata | fotky, vlajky, erby, mapy, obrazy | každý súbor iná; CC0 a voľné diela bez uvedenia, CC BY-SA s uvedením autora | zadarmo | názvy súborov často obsahujú odpoveď, treba ich premenovať |
| Wikipédia, hlavný obrázok článku | jeden obrázok k článku | len voľné (predvolené nastavenie) | zadarmo | najjednoduchší zdroj pre obrázky k textovým otázkam |
| Natural Earth | hranice krajín | voľné dielo | zadarmo | základ pre #98 |
| Metropolitan Museum | umenie | CC0 | zadarmo, bez kľúča | len diela označené ako voľné |
| Art Institute of Chicago | umenie | CC0 (neoverené) | zadarmo | |
| iNaturalist | zvieratá, rastliny, huby | podľa fotky; brať len CC0 a CC BY | zadarmo | licencia fotky sa môže líšiť od pozorovania |
| Europeana | európske kultúrne dedičstvo | rôzne | zadarmo s kľúčom | |
| Unsplash | pekné fotky | vlastné podmienky | zadarmo | nehodí sa, vyžaduje ťahať obrázok priamo z ich serverov a uvádzať autora pri každom zobrazení |

Úložisko: Cloudflare R2, ktoré už používame. Stiahnutie zadarmo, tisíc obrázkov zaberie asi 150 MB, čo sa zmestí do bezplatného limitu.

## AI generované obrázky

| Model | Cena za obrázok | Zdroj |
|---|---|---|
| OpenAI gpt-image-1 mini | 0,005 až 0,036 $ | OpenAI dokumentácia |
| OpenAI gpt-image-1 | 0,011 až 0,167 $ | OpenAI dokumentácia; možno už vyradený (neoverené) |
| Google Nano Banana 2.1 | 0,034 až 0,050 $ | Google cenník 2026-10-29 |
| Google Nano Banana Pro | 0,134 $ | Google cenník 2026-10-29 |
| Flux 1.1 pro | 0,04 $ | BFL cenník |

Tisíc obrázkov by stálo približne 10 až 50 $. Skutočným nákladom je ich kontrola. Hodia sa na rébusy, štylizované ilustrácie a vymyslené predmety. Nehodia sa na nič skutočné, čo má hráč rozpoznať.

## Riziká a pravidlá

- **Prezradenie odpovede:** názov súboru, popis, text na obrázku (nápis na budove). Súbory premenovať, popisy nezobrazovať, obrázky s textom kontrolovať.
- **Licencie:** pri CC BY-SA treba uviesť autora a licenciu. Návrh: malé tlačidlo „i“ pri obrázku a obrazovka s poďakovaním autorom. Treba na to nové údaje pri otázke.
- **Pravidlá Wikimedie:** sťahovať raz, so správnou identifikáciou, len v štandardných veľkostiach. Od začiatku 2026 inak hrozí obmedzenie.
- **Ľudia a logá:** odložiť. Historické osobnosti na voľných fotkách sú nízke riziko; žijúce osobnosti a logá by si vyžadovali právny názor.
- **Kvalita:** platí doterajšia rubrika. Francúzska vlajka je klišé a stratí body; obrázková otázka musí mať tiež zdroj (stránku na Wikidata alebo Wikipédii).
- **Hlasové hranie:** obrázkovú otázku treba vidieť. Keď hráč displej nevidí (zamknutý telefón, CarPlay), appka ju má preskočiť, nie čítať naslepo.

## Čo by sme museli dorobiť

Odhad podľa relatívnej náročnosti.

| Časť | Náročnosť |
|---|---|
| Server: údaje o autorovi a licencii obrázka, obrázok aj pri textovej otázke | malá |
| Appka: obrázok pri odhalení, pri textovej otázke, tlačidlo „i“ | malá až stredná |
| Appka: efekty priblíženia a rozmazania | stredná |
| Prepínač zo servera namiesto napevno v appke + analytika (koľko hráčov ich zapne, ako často odpovedajú správne) | malá |
| Zber obrázkov z Wikidata a Commons do nášho úložiska, premenovanie, kontrola licencie | stredná |
| Kontrola prezradenia (pre obrázky pred odpoveďou) | malá; jedno lacné AI volanie na obrázok, cenu overím pred spustením |
| Hra spolu: obrázok na každom telefóne | malá |
| #98 obrysy a slepé mapy | podľa plánu #98 |

## Náklady a kredity

| Krok | Kredity |
|---|---|
| Táto rešerš | 0 $ |
| Pilot zo šablón (vlajky, erby, obrazy, pamiatky, zvieratá) | 0 $ — len sťahovanie z Wikimedie |
| Doplnenie obrázkov k existujúcim otázkam pre odhalenie | 0 $ za stiahnutie; prípadná kontrola zhody obrázka s otázkou cez AI zlomok centu na otázku, overím vopred |
| Nové obrázkové otázky, ktorých text píše AI | rovnako ako dnešné textové otázky |
| AI ilustrácie | 0,01 až 0,05 $ za obrázok, len po schválení |

## Odporúčaný postup

1. **Pilot zadarmo.** 30 až 50 ukážkových otázok zo šablón, každá s obrázkom, zdrojom a licenciou. Posúdiš ich v artefakte.
2. **Obrázok pri odhalení** k existujúcim otázkam z Wikipédie. Najväčší dosah pri najmenšom riziku.
3. **Obrázkové otázky s efektom priblíženia**, zapínané zo servera, najprv pre testerov.
4. **#98 obrysy a slepé mapy** podľa existujúceho plánu.
5. **Neskôr:** obrázok pred odpoveďou s kontrolou prezradenia, Hra spolu, AI ilustrácie a rébusy.

## Zdroje

- Pub kvíz, typy kôl: https://en.wikipedia.org/wiki/Pub_quiz
- Worldle, počet hráčov: https://digital-release.nbc4i.com/news/worldle-a-new-country-guessing-game-offers-frustrating-fun-for-geography-buffs
- Sporcle: https://en.wikipedia.org/wiki/Sporcle
- Wikimedia, opätovné použitie a licencie: https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia
- Wikimedia, pravidlá identifikácie: https://foundation.wikimedia.org/wiki/Policy:Wikimedia_Foundation_User-Agent_Policy
- Wikimedia, štandardné veľkosti náhľadov: https://www.mediawiki.org/wiki/Instant_Commons
- Wikidata obrázok (P18): https://www.wikidata.org/wiki/Property:P18
- Natural Earth podmienky: https://www.naturalearthdata.com/about/terms-of-use
- Met Museum API: https://metmuseum.github.io/
- iNaturalist licencie fotiek: https://forum.inaturalist.org/t/are-there-copyright-rules-i-should-be-careful-of-when-making-an-inaturalist-based-quiz/76609
- Unsplash podmienky: https://help.unsplash.com/en/articles/2511245
- OpenAI ceny: https://developers.openai.com/api/docs/models/gpt-image-1-mini
- Google ceny: https://ai.google.dev/gemini-api/docs/pricing
- Flux ceny: https://docs.bfl.ai/quick_start/pricing
- Osobnostné práva SR: https://ficek.sk/vybrane-pravne-aspekty-vyhotovovania-fotografii-inych-osob-69
- Efekt prevahy obrázka: https://en.wikipedia.org/wiki/Picture_superiority_effect
- Efekt modality (počuť je lepšie ako čítať): https://journal.psych.ac.cn/adps/EN/Y2016/V24/I3/335
