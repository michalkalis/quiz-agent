# Obrázkové otázky v Trubbo

Rešerš 2026-10-29 · bez generovania otázok, bez míňania API kreditov (len webové vyhľadávanie a čítanie kódu).
Nadväzuje na #98 — geografické otázky kreslené priamo v appke a #68 — predvolené nastavenia pre jazdu.

## Zhrnutie

- **Základy už máme.** Appka vie zobraziť obrázkovú otázku a odpoveď sa dáva hlasom. Server ju pošle len hráčovi, ktorý si ju zapne, ale prepínač je v appke skrytý, takže ich dnes nikto nedostane. V produkcii je asi 25 starých obrázkových otázok.
- **Najlepší pomer zábava a náklady: skutočné fotky z Wikimedie.** Sú zadarmo a dajú sa zbierať automaticky. Pri štruktúrovaných typoch (vlajka, obraz a jeho autor, pamiatka a jej mesto) sa otázka dá zostaviť zo šablóny, bez AI a bez kreditov.
- **Obrázok k textovej otázke sa zobrazuje počas otázky ako kontext** (rozhodnutie foundera nižšie). Každý taký obrázok musí prejsť kontrolou, že neprezrádza odpoveď.
- **Obrázok zadarmo má takmer každá otázka z Wikipédie.** Hlavný obrázok článku, z ktorého otázka vznikla, vieme stiahnuť bez poplatku (len voľné licencie).
- **AI generované obrázky len ako ilustrácia** (rébusy, štylizované obrázky). Nikdy pre skutočné miesta, vlajky ani umelecké diela, lebo si vymýšľajú detaily a v kvíze je to faktická chyba. Výnimka: karikatúry historických osobností (rozhodnutie foundera); žijúce osobnosti čakajú na právny názor.
- **Odložiť:** logá (ochranné známky) a tváre žijúcich ľudí (osobnostné práva podľa slovenského Občianskeho zákonníka §12).
- **Navrhovaný ďalší krok:** bezplatný pilot 30 až 50 obrázkových otázok zo šablón, na posúdenie v artefakte. Nič sa nepublikuje, kým ich neschváliš.

## Rozhodnutia foundera (2026-10-29)

- **Obrázok k textovej otázke sa zobrazuje počas otázky ako kontext**, nie pri odhalení („po odhalení mi to moc nedáva zmysel“). Tým padá pôvodné odporúčanie obrázka pri odhalení; kontrola prezradenia je potrebná od začiatku.
- **Pilot: všetky štyri typy** (čo je na obrázku, priblížený detail, historická fotka a rok, obrysy a slepé mapy). Rozhodne testovanie, nudné typy vypadnú.
- **Predvolene zapnuté, v malom pomere k textovým otázkam**, s ohľadom na náklady.
- **AI karikatúry osobností** (známa osobnosť ako kreslená postavička, hráč háda) vyskúšať, rozpočet pilotu max 2 $.
- Pilot hotový: 45 otázok v artefakte https://claude.ai/artifact/DbjgViwqVmBK957ZkvSMvM; AI karikatúry stáli asi 0,38 $ (6 obrázkov novým modelom OpenAI, 6 lacným). V pilote len historické osobnosti; žijúce osobnosti čakajú na právny názor.

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
| **Obrys krajiny, slepá mapa** (#98 — geografické otázky kreslené v appke) | hlas | Natural Earth (voľné dielo), kreslí appka | <span class="badge ok">vysoká</span> už navrhnuté | vysoká, overené hrou Worldle |
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

1. **Pri odhalení odpovede** <span class="badge bad">founder zamietol</span> Nič neprezradí. Výskum zapamätania (efekt prevahy obrázka nad slovom) ukazuje, že obrázok spolu s textom sa pamätá lepšie ako samotný text. Zároveň to dáva odhaleniu „odmenu“.
2. **Počas otázky ako kontext** <span class="badge ok">rozhodnuté</span> Pomôže pri otázkach, kde slovný opis nestačí. Riziko: fotka Sagrady Família pri otázke „V ktorom meste…“ prezradí odpoveď. Každý taký obrázok musí prejsť kontrolou prezradenia.
3. **Vôbec** pri otázkach, kde obrázok nemá zmysel (abstraktné pojmy, čísla). Čisto dekoratívne obrázky podľa výskumu takmer nepomáhajú (neoverené presne), takže obrázok musí súvisieť s faktom.

Zdroj zadarmo: hlavný obrázok článku Wikipédie, ktorý je už zdrojom otázky. Vyberáme len voľné licencie. Obrázok sa stiahne raz do nášho úložiska, appka ho nikdy neťahá priamo z Wikimedie.

## Zdroje obrázkov

| Zdroj | Čo ponúka | Licencia | Cena | Poznámka |
|---|---|---|---|---|
| Wikimedia Commons + Wikidata | fotky, vlajky, erby, mapy, obrazy | každý súbor iná; CC0 a voľné diela bez uvedenia, CC BY-SA s uvedením autora | zadarmo | názvy súborov často obsahujú odpoveď, treba ich premenovať |
| Wikipédia, hlavný obrázok článku | jeden obrázok k článku | len voľné (predvolené nastavenie) | zadarmo | najjednoduchší zdroj pre obrázky k textovým otázkam |
| Natural Earth | hranice krajín | voľné dielo | zadarmo | základ pre #98 — geografické otázky kreslené priamo v appke |
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

Tisíc obrázkov by stálo približne 10 až 50 $. Skutočným nákladom je ich kontrola. Hodia sa na rébusy, štylizované ilustrácie a vymyslené predmety. Nehodia sa na nič skutočné, čo má hráč rozpoznať, okrem karikatúr historických osobností, kde hráča vedú rekvizity a oblečenie.

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
| Appka: obrázok počas textovej otázky, tlačidlo „i“ | malá až stredná |
| Appka: efekty priblíženia a rozmazania | stredná |
| Prepínač zo servera namiesto napevno v appke + analytika (koľko hráčov ich zapne, ako často odpovedajú správne) | malá |
| Zber obrázkov z Wikidata a Commons do nášho úložiska, premenovanie, kontrola licencie | stredná |
| Kontrola prezradenia (pre obrázky pred odpoveďou) | malá; jedno lacné AI volanie na obrázok, cenu overím pred spustením |
| Hra spolu: obrázok na každom telefóne | malá |
| #98 — geografické otázky kreslené v appke (obrysy a slepé mapy) | podľa plánu v issue |

## Náklady a kredity

| Krok | Kredity |
|---|---|
| Táto rešerš | 0 $ |
| Pilot zo šablón (vlajky, erby, obrazy, pamiatky, zvieratá) | 0 $ — len sťahovanie z Wikimedie |
| Doplnenie obrázkov ako kontextu k existujúcim otázkam | 0 $ za stiahnutie; kontrola prezradenia a zhody obrázka s otázkou cez AI zlomok centu na otázku, overím vopred |
| Nové obrázkové otázky, ktorých text píše AI | rovnako ako dnešné textové otázky |
| AI ilustrácie | 0,01 až 0,05 $ za obrázok, len po schválení |

## Odporúčaný postup

1. **Pilot zadarmo.** 30 až 50 ukážkových otázok zo šablón, každá s obrázkom, zdrojom a licenciou. Posúdiš ich v artefakte.
2. **Obrázok počas otázky ako kontext** k existujúcim otázkam z Wikipédie, s kontrolou prezradenia od začiatku.
3. **Obrázkové otázky s efektom priblíženia**, zapínané zo servera, najprv pre testerov.
4. **#98 — geografické otázky kreslené v appke** (obrysy a slepé mapy) podľa existujúceho plánu.
5. **Neskôr:** Hra spolu, AI karikatúry a rébusy podľa výsledku pilotu.

## Kolo 2: verdikt pilotu a hlbšia rešerš (2026-10-29)

**Verdikt foundera:** „celkovo nič moc, nie je to zábavné ani prínosné“. Baví 2 zo 45 (pomalé oddiaľovanie ananásu, obrys Nového Zélandu). Historická fotka a rok: 5 z 5 nudné. Rozpoznávanie a obrysy: takmer všetko „ujde“. AI karikatúry: 4 ujde, 2 nudné. Poznámky: slepá mapa bez hraníc (s nimi je príliš ľahká), oddiaľovanie pomalšie, kontextový obrázok často zbytočný.

### Prečo pilot nebavil

Pilot bol takmer celý **holé rozpoznávanie** („čo je to“, „kto to namaľoval“). Autori pub kvízov presne toto považujú za vatu: ľahký blok na rozbeh, nie hlavné jedlo. Bez témy a bez zvratu sa z toho stáva test zraku. Zábava prichádza z **hádanky s „aha“ momentom**: hráč z obrázkov niečo vyvodí, nielen rozpozná. Obe otázky, ktoré ťa bavili, majú tento prvok (postupné odhaľovanie, nečakaný tvar).

### Mechaniky, ktoré v kvízoch fungujú a dajú sa hrať hlasom

| Mechanika | Čo hráč robí | Prečo baví | Výroba u nás |
|---|---|---|---|
| **Čo spája tieto obrázky** | vidí 4 obrázky, povie spojitosť | žiadny obrázok sám nie je odpoveď, rozlúštenie celku | <span class="badge info">stredná</span> sady z Wikidata + AI návrh spojitosti + ručná kontrola |
| **Čo sem nepatrí** | 4 obrázky, jeden nepatrí | „prečo“ po odhalení je najzapamätateľnejšia chvíľa | <span class="badge info">stredná</span> ako vyššie |
| **Postupné odhaľovanie s témou** | obrázok sa pomaly oddiaľuje, téma je daná | každá sekunda pridá stopu, skorá odpoveď = viac bodov | <span class="badge ok">ľahká</span> efekt v appke; témy („raňajky“, „v kuchyni“) |
| **Čo chýba / čo je zle** | vlajka s inou farbou, mapa bez riek, obrázok s vymazaným prvkom | treba si všimnúť rozdiel, nie len pomenovať | <span class="badge ok">ľahká</span> pri vlajkách a mapách (upravíme programom, zadarmo) |
| **Dva obrázky = jedno slovo** (rébus) | slnko + kvet = slnečnica | „aha“ z premýšľania, nie z pamäti | <span class="badge warn">ťažká</span> každý jazyk zvlášť; AI obrázky tu dávajú zmysel |
| **Vtedy a dnes, domáce miesta** | stará fotka slovenského alebo českého miesta | „to poznám!“, nedá sa vygoogliť | <span class="badge info">stredná</span> staré fotky z voľných archívov (napr. Fortepan, licenciu overím) |
| **Spojené tváre** | dve osobnosti zliate do jednej | vtipné, dve odpovede | <span class="badge bad">odložiť</span> žijúce osobnosti majú právne riziko |

Koľko: pub kvízy dávajú jedno obrázkové kolo s 8 až 12 obrázkami na celý večer. Viac ako 20 sa neodporúča a ten istý trik nanajvýš dvakrát za kvíz. To podporuje tvoje „v malom pomere“: skôr **krátke obrázkové kolo s témou** (napr. 5 otázok jednej mechaniky) ako obrázky roztrúsené medzi textovými otázkami.

### Kontextový obrázok pri textovej otázke

- **Výskum:** obrázok pomáha len vtedy, keď ukazuje to, na čo sa otázka pýta (vzhľad, tvar, farba, vzor). Čisto ilustračná fotka niečoho, čo otázka len spomína, nepomáha a pri časovom tlaku môže mierne rozptyľovať (meta-analýzy „zvodných detailov“).
- To sedí s tvojím hodnotením: Čičmany (otázka o vzoroch) áno, Oravský hrad (otázka o filme) zbytočné.
- **Odhad podielu:** z 45 náhodných otázok našej sady by obrázok naozaj pomohol asi 5 (Čičmany, čokoláda so zbelením, káva dalgona, pizza Margherita, Čumil), teda zhruba každej desiatej.
- **Umiestnenie, ak áno:** pod text otázky, malý, ťuknutím sa zväčší. Výskum radí mať obrázok hneď pri texte, ku ktorému patrí. Zdroje k rozloženiu v appkách som nenašiel, toto je úsudok.
- **Odporúčanie:** zatiaľ nestavať ako samostatnú funkciu. Ak budú obrázkové otázky, rovnaké zobrazenie potom zapneme aj pre textové otázky, ktoré pri generovaní dostanú značku „obrázok pomáha“ (len vzhľad, tvar, farba, vzor).

### Návrh ďalšieho kroku

Druhý malý pilot: 15 otázok v štyroch mechanikách (čo spája obrázky, čo sem nepatrí, postupné odhaľovanie s témou, čo chýba alebo je zle), poskladaných ako krátke obrázkové kolá. Bez API kreditov: otázky navrhnem sám, obrázky z voľných zdrojov. Alternatíva: tému obrázkov zatiaľ odložiť.

**Rozhodnutie foundera (2026-10-29):** druhý malý pilot áno. Kontextový obrázok neskôr, spolu s obrázkovými otázkami: len pri otázkach o vzhľade, malý pod textom otázky.

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
- Autori pub kvízov o obrázkových kolách: https://quizado.com/pub-quiz-picture-round · https://pubquizzes.org/pub-quiz-picture-round-ideas/ · https://quizquiz.co/blog/picture-round-ideas
- Framed (postupné odhaľovanie): https://www.nme.com/news/wordle-spin-off-framed-asks-cinema-fans-to-guess-films-from-still-images-3189472
- Zvodné detaily, meta-analýza: https://www.learningscientists.org/blog/2019/6/20-1 · https://news.wsu.edu/2020/03/19/seductive-details-inhibit-learning/
- Funkcie obrázkov pri texte (Carney a Levin 2002): https://link.springer.com/article/10.1007/BF02769434
- Kahoot, obrázky pri otázkach: https://support.kahoot.com/hc/en-us/articles/360037705733-How-to-add-or-edit-images-and-videos-in-mobile-app
