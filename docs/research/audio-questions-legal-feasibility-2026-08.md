# Research: Audio otázky — čo sa dá legálne prehrávať v kvíze

**Dátum:** 2026-08-27 | **Zadanie:** founder 2026-08-19 — znova preveriť možnosti prehrávania zvukových ukážok v kvízových otázkach: pesničky, film/TV, voľné zvuky a ďalšie typy. Právne posúdenie + použiteľné zdroje/API per kategória + odporúčanie pre komerčnú freemium iOS appku (EU/SK jurisdikcia, App Store).

## Executive Summary

- **Úryvky pesničiek: NIE.** Mýtus „pár sekúnd je OK" je právne vyvrátený v EU aj US (Pelham/Metall auf Metall, Bridgeport). Žiadne oficiálne preview API nedáva licenciu na kvízovú appku — Spotify trivia hry **explicitne zakazuje** a preview URL pre nové appky zrušil (11/2024), Apple previews smú slúžiť len na promo store obsahu, Deezer vyžaduje osobitný komerčný deal. Priama licencia od labelov = biznis-development úroveň SongPop, nie API integrácia.
- **Film/TV klipy: NIE.** EU citačná výnimka ani US fair use kvízové použitie nepokrývajú (precedens Castle Rock v. Carol Publishing — Seinfeld trivia kniha prehrala). Žiadne self-serve licenčné API pre indie appky neexistuje.
- **Voľné zvuky: ÁNO, čisto a hneď.** Zvieratá, prostredie, efekty a nástroje z CC0/CC-BY zdrojov (Freesound cez web, Pixabay, Wikimedia Commons); národné hymny cez public-domain nahrávky US Navy Band (~150 krajín).
- **TTS/AI audio: ÁNO s podmienkami.** Neutrálny (ne-celebritný) TTS hlas je komerčne čistý; od 2. 8. 2026 vyžaduje EU AI Act (čl. 50) označenie AI-generovaného audia. Hlasy pripomínajúce reálne osoby = nikdy.
- **Klasická hudba: ÁNO s per-track overením.** Skladateľ 70+ rokov po smrti + PD/CC0 nahrávka (alebo vlastná/syntetizovaná) = legálne „uhádni skladbu".

## Key Findings

### 1. Pesničky — žiadna legálna skratka neexistuje

Neexistuje žiadna „de minimis" výnimka pre hudbu. CJEU v Pelham/Metall auf Metall (C-476/17, 2019) odmietol akýkoľvek minimálny prah — aj 2-sekundový sample porušuje práva k zvukovej nahrávke; množstvo kopírovania nie je test. V US Bridgeport v. Dimension Films (2005): „get a license or don't sample". Kvízová appka porušuje práva k **nahrávke aj kompozícii** súčasne.

Oficiálne preview API sú slepá ulička:

| API | Stav pre kvízovú appku |
|---|---|
| Spotify | `preview_url` zrušené pre nové appky (27. 11. 2024); Developer Policy explicitne zakazuje „create a game, including trivia quizzes" — aj čisto na metadátach |
| Apple Music / iTunes Search | 30s previews len na promo store obsahu (povinný store link + „courtesy of iTunes"); „not be used for independent entertainment value" — kvíz je presne to |
| Deezer | 30s previews existujú, ale ToU nedávajú komerčnú certifikáciu; rhythm/quiz hry potrebujú osobitnú licenciu mimo API |

Reálna prax trhu: SongPop má priame dohody s labelmi. Heardle bežal na sivej zóne, Spotify ho kúpil a **sám zavrel po 9 mesiacoch** — licenčná matematika snippet hier nevychádza ani vlastníkovi rights infraštruktúry. SOZA sadzobníky pokrývajú verejné produkcie/vysielanie, nie interaktívny in-app playback — potrebný by bol bespoke deal s labelmi (masters) + publishermi, s minimálnymi garanciami.

### 2. Film/TV — právne to isté ako hudba, náhrada = public domain prejavy

EU citačná výnimka (InfoSoc čl. 5(3)(d)) vyžaduje, aby citát „vstupoval do dialógu" s dielom (kritika, komentár) — prehratie klipu na hádanie tento test nespĺňa. US fair use: Castle Rock v. Carol Publishing (2d Cir. 1998) — trivia kniha o Seinfeldovi bola infringement, lebo trivia použitie je netransformatívne a konkuruje derivátnemu trhu držiteľa práv. To je najbližší precedens presne pre náš use case a prehral.

Štúdiá licencujú klipy len bespoke (Sony/Disney clip desks, cena pre korporátny marketing, nie freemium ekonomika). Public-domain filmy (pre-1930) sú legálne OK, ale prakticky úzke: väčšinou nemé/rané talkies so slabým dialógovým audiom, a **reštaurované verzie majú nový copyright** — použiteľný je len originálny, nereštaurovaný zvuk.

Čistá náhrada: **nahrávky federálnej vlády USA sú public domain** — NASA mission audio („one small step"), prejavy nahraté vládou (JFK „We choose to go to the Moon"). Pozor: PD je len vládou vyhotovená nahrávka, nie sieťový broadcast toho istého prejavu — provenance treba overiť per súbor.

### 3. Voľné zvuky — najsilnejšia kategória, nasaditeľná hneď

Freemium so subscription/IAP **je komerčné použitie** podľa štandardnej CC definície → všetko s NC doložkou je vylúčené.

| Zdroj | Licencia | Komerčne? | Poznámka |
|---|---|---|---|
| Freesound.org | mix CC0/CC-BY/CC-NC per zvuk | ÁNO (CC0/CC-BY) | **API je non-commercial only** — sťahovať cez web UI, nie API; CC-BY = credits obrazovka |
| Pixabay audio | vlastná, bez atribúcie | ÁNO | najjednoduchší zdroj |
| Wikimedia Commons | CC0/CC-BY/CC-BY-SA/PD | ÁNO | NC tam nie je hostované; preferovať CC0/CC-BY; per-file check |
| Zapsplat | free = atribúcia, Gold = bez | ÁNO | Gold tier ak objem |
| BBC Sound Effects | RemArc non-commercial | NIE | komerčne len cez Pro Sound Effects (platené) |
| Macaulay Library (Cornell) | default non-commercial | per-recording | len s explicitným povolením/CC |
| xeno-canto (vtáky) | CC per nahrávka, aj NC | čiastočne | filtrovať non-NC |
| Internet Archive | ToS „noncommercial" rámec | ambivalentné | nepoužiť ako primárny zdroj; rovnaké súbory brať z Commons |

**Národné hymny:** kompozície sú väčšinou PD (overiť per krajina), ale nahrávka má vlastný copyright. Čistá cesta: PD nahrávky **US Navy Band** (~150 krajín) na Wikimedia Commons.

### 4. TTS / AI audio a klasická hudba

- Neutrálny TTS (hlásky, jazykolamy, spelling, „uhádni jazyk", čítanie zvukomalebných textov) je právne bezproblémový. OpenAI TTS: komerčné použitie OK, zákaz impersonácie, povinnosť informovať používateľa, že hlas je AI. ElevenLabs: komerčne len na platenom pláne (free tier sa nesmie monetizovať).
- **EU AI Act čl. 50 (účinný od 2. 8. 2026, t. j. už teraz):** AI-generované audio musí byť strojovo čitateľne označené ako syntetické a deepfake reálnej osoby musí byť používateľovi disclosed. Pre nás: metadata flag + krátky disclosure v appke; celebrity-like hlasy vôbec (viď OpenAI „Sky"/Scarlett Johansson).
- Vlastná/MIDI nahrávka melódie obchádza práva k nahrávke, **nie k dielu** — melódia musí byť PD (skladateľ 70+ rokov po smrti; Bach/Mozart/Beethoven čisté, 20. storočie overovať per krajina). Musopen/IMSLP nahrávky: licencie overovať per track (IMSLP používa kanadské PD pravidlá, Musopen negarantuje PD).
- App Store guideline 5.2.3 cieli na neautorizované streamovanie cudzích katalógov; pri vlastnom/PD/CC obsahu nehrozí, ale review si môže vyžiadať doklady o právach — asset-level license metadata sa oplatí mať od začiatku.

### 5. UX prior art pre hands-free

Vzor „auto-play klip → hráč povie odpoveď" (SongPop, Song Quiz) a Alexa/Google voice trivia skills (otázka TTS, odpoveď ASR, krátke stingy na správne/nesprávne) sú priamo prenositeľné na náš driving-first flow — audio otázka do neho zapadá bez novej interakcie.

## Implications for Trubbo

- Audio otázky sa dajú spustiť **bez jediného licenčného dealu** — celý Tier 1 (nižšie) stojí na PD/CC0/CC-BY + TTS, ktorý už v pipeline máme.
- „Uhádni pesničku z rádia" — najžiadanejší formát — je jediné, čo legálne nevieme; nahraditeľné formátmi „uhádni skladbu (klasika)", „čia je to hymna", „aké zviera počuješ", „z akého jazyka je táto veta".
- Potrebná infra: asset storage + per-asset license metadata (zdroj, licencia, autor, URL) v korpuse, credits obrazovka pre CC-BY, AI-audio flag pre AI Act.

## Recommendations

1. **Tier 1 — nasadiť (žiadne právne riziko):** zvuky zvierat/prostredia/nástrojov (CC0 Freesound web + Pixabay + Commons), národné hymny (US Navy Band PD), TTS otázky (jazyky, jazykolamy, spelling) s AI-disclosure.
2. **Tier 2 — nasadiť s per-asset overením:** klasická hudba (PD skladateľ + PD/CC0/vlastná nahrávka), slávne PD prejavy a NASA audio (provenance check per súbor).
3. **Nerobiť:** pop/rock úryvky (vrátane „len 3 sekundy"), film/TV klipy, celebrity AI hlasy, čokoľvek s NC licenciou, Freesound API, BBC RemArc.
4. **Pred implementáciou:** vlastný prep round (`/prepare-issue`) — asset pipeline (download, trim, normalize, license metadata), backend serving, iOS playback v quiz flow, credits obrazovka.
5. **Ak by pesničky boli produktovo kľúčové:** jediná cesta je priamy deal s labelmi — treat ako samostatný biznis projekt s minimálnymi garanciami, nie ako feature. Neodporúčam pre MVP fázu.

## Sources

1. [CJEU Pelham C-476/17 — Simkins summary](https://www.simkins.com/news/the-kraftwerk-case-does-a-two-second-sample-infringe-copyright) — žiadny de minimis prah pre sampling v EU
2. [Bridgeport v. Dimension Films (6th Cir. 2005)](https://en.wikipedia.org/wiki/Bridgeport_Music,_Inc._v._Dimension_Films) — US: akýkoľvek sample nahrávky = infringement
3. [Spotify — changes to Web API 2024-11-27](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api) — preview_url zrušené pre nové appky
4. [Spotify Developer Policy](https://developer.spotify.com/policy) — explicitný zákaz trivia hier
5. [Apple iTunes preview podmienky — dev forum](https://developer.apple.com/forums/thread/681105) — previews len na store promo
6. [Deezer API Terms of Use](https://developers.deezer.com/termsofuse) — bez komerčnej certifikácie pre hry
7. [Spotify shuts down Heardle — Hollywood Reporter](https://www.hollywoodreporter.com/business/digital/spotify-heardle-music-game-to-shut-down-1235375321/) — licenčná matematika snippet hier
8. [Castle Rock v. Carol Publishing (2d Cir. 1998)](https://en.wikipedia.org/wiki/Castle_Rock_Entertainment,_Inc._v._Carol_Publishing_Group_Inc.) — trivia použitie ≠ fair use
9. [Fieldfisher — CJEU quotation limitation](https://www.fieldfisher.com/en/services/intellectual-property/intellectual-property-blog/cjeu-rules-on-the-scope-of-the-quotation-limitation-to-copyright-infringement-and-the-application-of-fundamental-freedoms) — citačná výnimka vyžaduje „dialóg" s dielom
10. [Internet Archive — audio z PD filmov](https://archive.org/post/109072/what-are-the-rules-for-using-audio-from-public-domain-movies) — reštaurácie majú nový copyright
11. [Freesound API Terms of Use](https://freesound.org/docs/api/terms_of_use.html) — API non-commercial; web download OK per CC licencia
12. [Pixabay license summary](https://pixabay.com/service/license-summary/) — komerčne bez atribúcie
13. [BBC Sound Effects licensing](https://sound-effects.bbcrewind.co.uk/licensing) — RemArc non-commercial only
14. [Wikimedia Commons — US Navy Band anthems](https://commons.wikimedia.org/wiki/Category:Audio_files_of_national_anthems_performed_by_the_United_States_Navy_Band) — PD nahrávky hymien
15. [CC NonCommercial definícia](https://en.wikipedia.org/wiki/Creative_Commons_NonCommercial_license) — freemium = komerčné
16. [EU AI Act čl. 50](https://artificialintelligenceact.eu/article/50/) — označovanie syntetického audia od 8/2026
17. [OpenAI Voice Engine safety](https://openai.com/index/expanding-on-how-voice-engine-works-and-our-safety-research/) — zákaz impersonácie, disclosure
18. [ElevenLabs komerčné podmienky — Terms.Law](https://terms.law/ai-output-rights/elevenlabs/) — komerčne len paid plan
19. [Musopen FAQ](https://musopen.org/faq/) · [IMSLP Licensing](https://imslp.org/wiki/IMSLP:Licensing_Policy_and_Guidelines) — per-track license check pre klasiku
20. [App Store Review Guidelines 5.2](https://developer.apple.com/app-store/review/guidelines/) — IP doklady pri review
