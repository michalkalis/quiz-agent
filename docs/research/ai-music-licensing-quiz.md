# Research: AI hudba (Suno & spol.) a licencie pre hudobné otázky v kvíze

**Date:** 2026-09-16 (oprava Apple ukážok 2026-09-18) | **Query:** Dá sa cez Suno/AI vygenerovať „upravená“ verzia reálnej pesničky a tým obísť licencie? Ako inak využiť AI hudbu v appke?

## Executive Summary
- **Nie.** AI cover/soundalike reálnej pesničky licenčný problém nerieši, len ho presúva. Práva ku *skladbe* (melódia, text) ostávajú vydavateľovi bez ohľadu na to, kto ju nahral. „Hádaj pesničku“ funguje práve preto, že skladba je rozpoznateľná, čiže preberá to chránené jadro.
- **Súdy to v 2026 potvrdili priamo na Suno:** GEMA v. Suno (Mníchov, 31. 7. 2026) zakázal Suno reprodukovať a sprístupňovať výstupy napodobňujúce chránené skladby (Atemlos, Daddy Cool, Mambo No. 5…). Nie je právoplatné, ale smer EÚ je jasný. V USA sa UMG a Sony so Suno stále súdia, Warner sa vyrovnal.
- **Aj podmienky platforiem to zakazujú:** Suno dáva strike za „Impersonation“ a zakazuje klonovanie hlasu; Udio po dohode s UMG zavádza „walled garden“ (bez exportu). Takže technicky by to bol aj breach ToS, nielen copyright.
- **Apple Music 30 s ukážky sú šedá zóna, nie čistá cesta (oprava 09-18).** Apple podmienky pre ukážky (iTunes Search API / Apple Music Feed) zakazujú použitie „na samostatnú zábavnú hodnotu mimo promo účelu“ a vyžadujú promo obrazovku s Apple Music odkazom a atribúciou. Kvíz je presne samostatná zábava. Intro-quiz appky v App Store (Intro King, MusIQ, Heard-It!) na tom napriek tomu bežia, čiže review to v praxi púšťa, ale Apple ich môže kedykoľvek stiahnuť. Zhoduje sa s augustovým researchom (`audio-questions-legal-feasibility-2026-08.md`). Spotify ukážky sú pre nové appky od 11/2024 mŕtve a Spotify trivia hry výslovne zakazuje.
- **AI hudba má v appke zmysel inde:** originálne znelky, stingery, podkresy a „štýlové“ hádanky (dekáda, žáner, nástroj) bez reálnych skladieb. Najbezpečnejší generátor je ElevenLabs Music (trénovaný len na licencovaných dátach, výstup „cleared for commercial use“, výnimka len film/TV/veľké hry), a už máme u nich účet.

## Key Findings

### 1. Prečo „upravená“ pesnička nič nerieši
Každá pesnička má dve vrstvy práv: **skladbu** (kompozícia + text, vydavateľ/autor, u nás SOZA/OSA) a **nahrávku** (master, label). AI soundalike obíde len master. Skladba je stále cudzia: reprodukcia = mechanická licencia, použitie v appke so „scenárom“ = sync/synchronizačná licencia, zmena aranžmánu = odvodené dielo, na ktoré treba súhlas autora. Slovenský autorský zákon má citačnú výnimku, ale tá je viazaná na kritiku, recenziu, výuku, nie na zábavný produkt; v praxi sa na kvíz nedá oprieť.

Branža toto pozná zo športových „sound-alike“ coverov: ClicknClear výslovne varuje, že väčšina soundalike verzií neprináša žiadne práva od vydavateľov a „kupujete si problém s porušením autorských práv“. Súdna prax v USA (Midler v. Ford, Waits v. Frito-Lay) navyše chráni aj rozpoznateľný hlas interpreta, čo je presne to, čo by „hádaj speváka“ potreboval.

### 2. Stav žalôb a dohôd (09/2026)
- **UMG × Udio** (10/2025): vyrovnanie + licencia, royalty ~0,002–0,005 $ za generovanie; nová licencovaná platforma v 2026, „walled garden“ bez sťahovania.
- **WMG × Udio** (11/2025) a **WMG × Suno** (11/2025): vyrovnanie + licencia; Suno stiahlo nelicencované modely, sprísnilo podmienky (free účty = nekomerčné navždy, aj po neskoršom predplatnom).
- **UMG × Suno, Sony × Suno/Udio**: stále v spore, Suno argumentuje fair use; kľúčové pojednávanie 07/2026 v Massachusetts, rokovania stoja.
- **GEMA × Suno** (Mníchov, rozsudok 31. 7. 2026): tréning v USA aj výstupy v Nemecku porušujú autorské práva; súd zakázal reprodukciu a sprístupňovanie výstupov k 6 skladbám. Prvý EÚ rozsudok o generatívnej hudbe; očakáva sa odvolanie. Pre SK/CZ kontext (kontinentálne právo, kolektívni správcovia SOZA/OSA) je toto relevantnejší precedens než US fair use.
- **AFM (hudobnícka únia) × UMG/WMG** (2026): žaloba, že dohody s Suno/Udio obchádzajú interpretov. Ukazuje, že ani „licencovaný“ AI výstup nie je ešte právne usadený.

### 3. Podmienky platforiem
| Platforma | Komerčné použitie | Vlastníctvo výstupu | Napodobňovanie |
|---|---|---|---|
| **Suno** | len platené plány (Pro/Premier); free = nikdy | Suno postupuje svoje práva, ale negarantuje, že výstup je vôbec chránený | zakázané klonovanie hlasu, strike za „Impersonation“ |
| **Udio** | platené plány áno, ale „len ako služba dovolí“; ToS uvádza vlastníctvo Udio/licensors | de facto licencia, nie vlastníctvo | smer „walled garden“, export obmedzený |
| **ElevenLabs Music** | áno, „cleared for commercial use“; self-serve vylučuje film/TV/Studio Games (Enterprise pokrýva všetko) | tréning len na licencovaných dátach (Merlin, Kobalt; 09/2026 dohoda aj s UMG) | model nie je stavaný na napodobňovanie konkrétnych umelcov |

### 4. App Store a Apple MusicKit (opravené 09-18)
Dve vrstvy pravidiel:
- **Review Guideline 4.5.2**: MusicKit „nie je náhrada licencií pre hlbšiu integráciu“ (hrať konkrétnu skladbu v konkrétnom momente = presne kvíz). 5.2.3 zakazuje sťahovanie/kešovanie.
- **Podmienky ukážok (iTunes Search API / Apple Music Feed API)**: obsah len streamovaný, „not used for independent entertainment value apart from its promotional purpose“, len na obrazovkách, ktoré propagujú hudbu, s Apple Music odznakom/odkazom a atribúciou „provided courtesy of Apple Music“.

Záver: kvíz na Apple ukážkach je **porušenie podmienok na papieri, tolerované v praxi**. Intro-quiz appky v App Store prežívajú roky, ale bez záruky; SongPop má priame dohody s labelmi, Heardle Spotify sám zavrel. Ak by sme do toho išli, minimálna mitigácia = ukážka vždy so store odkazom na skladbu + atribúcia + streaming bez keše, aby sa dalo argumentovať promo účelom. Riziko: **stredné až vysoké** (stiahnutie z App Store, nie súd).

Spotify: od 27. 11. 2024 nové appky `preview_url` nedostanú (vracia null), takže Spotify ako zdroj ukážok odpadá.

### 5. Kde AI hudba v appke dáva zmysel
- **Zvuková identita:** znelka pri štarte kvízu, stingery správne/nesprávne, podkres pri recap obrazovke. Jednorazovo vygenerované, uložené do bundle, nulový hot-path cost. Sedí to k vision „hands-free v aute“, kde zvuk nesie UX.
- **Nový typ otázky bez licencií:** „Z ktorej dekády je tento štýl?“, „Ktorý nástroj hrá sólo?“, „Aký je to žáner/tanec?“ na originálnej AI skladbe v danom štýle. Nehráme nič cudzie, len štýl. Pozor na hranicu: prompt „v štýle Beatles“ je šedá zóna, „britský beat 60. rokov“ je bezpečný.
- **Royalty-free knižnice** (Epidemic Sound, Artlist, Pixabay) fungujú na to isté, ale licencie pre in-app použitie treba čítať (Epidemic/Artlist majú samostatné app/game licencie; Pixabay je voľné, kvalita kolíše). AI generátor je lacnejší a dáva presne to, čo si vypýtame.

## Implications for Hangs
- „Hádaj pesničku“ z reálnych hitov cez AI cover: **zamietnuť**. Riziko vysoké (copyright skladby, GEMA precedens, ToS strike, App Store).
- „Hádaj pesničku“ z reálnych hitov cez **Apple Music ukážky**: šedá zóna (riziko stredné až vysoké, App Store stiahnutie). Jediná dostupná cesta k reálnym hitom bez priamej dohody s labelmi; ak áno, tak až po prvom App Store release, s promo mitigáciou a vedomím, že to Apple môže vypnúť.
- AI **originálna hudba** (ElevenLabs Music): riziko nízke, hodí sa na znelky a nový typ štýlových otázok. Držať sa promptov bez mien umelcov/skladieb.
- Voice-first kontext: hudobná ukážka v aute + STT konflikt (mikrofón počúva pri prehrávaní) treba vyriešiť rovnako ako pri TTS single-flight.

## Recommendations
1. Zapísať rozhodnutie: **žiadne AI covery/soundalike reálnych skladieb**, ani „mierne upravené“.
2. Reálne hity: **po prvom App Store release** (founder 09-18) rozhodnúť, či ísť do šedej zóny Apple ukážok s promo mitigáciou, alebo ostať pri originálnej hudbe. Priama dohoda s labelmi/SOZA je jediná čistá cesta, pre MVP mimo dosah.
3. Znelky a stingery: vygenerovať cez **ElevenLabs Music** (už máme účet), uložiť do bundle. Malý, lacný krok s okamžitým UX efektom.
4. Nový typ otázok „štýl/dekáda/nástroj“ na AI originálnej hudbe: produktová otázka pre foundera, či to do kvízu patrí.

## Sources
1. [Bird & Bird: Munich District Court rules GEMA v Suno](https://www.twobirds.com/en/insights/2026/germany/munich-district-court-rules-on-ai-generated-music-gema-v-suno) — 4 zakázané úkony vrátane výstupov; prvý EÚ rozsudok.
2. [Music Ally: GEMA wins against Suno](https://musically.com/2026/07/31/german-collecting-society-gema-wins-its-copyright-infringement-lawsuit-against-suno/) — skladby reprodukované „takmer nota po note“ len promptom.
3. [Forbes: Suno lost to GEMA, why it should worry AI music companies](https://www.forbes.com/sites/virginieberger/2026/08/05/suno-lost-to-gema-why-the-ruling-should-worry-ai-music-companies/) — dopad na EÚ.
4. [AI Lawsuit Tracker: UMG/Sony/WMG v Suno & Udio](https://ailawsuittracker.com/cases/umg-v-suno/) — stav US sporov, WMG vyrovnanie, UMG/Sony pokračujú.
5. [Forbes: Launch, Train, Settle](https://www.forbes.com/sites/virginieberger/2025/12/18/launch-train-settle-how-suno-and-udios-licensing-deals-made-copyright-infringement-profitable/) — detaily dohôd 2025.
6. [MBW: AFM sues UMG and WMG over Suno/Udio settlements](https://www.musicbusinessworldwide.com/musicians-union-sues-umg-and-warner-music-alleging-member-recordings-were-licensed-to-suno-and-udio-without-compensation-or-credit/) — právna neistota aj po dohodách.
7. [Suno Terms of Service](https://suno.com/terms) a [terms.law: Suno commercial rights 2026](https://terms.law/ai-output-rights/suno/) — free vs. platené, bez záruky copyrightu, zákaz impersonácie.
8. [Digital Music News: Suno 2026 changes under Warner deal](https://www.digitalmusicnews.com/2025/12/22/suno-warner-music-deal-changes/) — stiahnutie nelicencovaných modelov.
9. [musicmake.ai: Udio ToS 2026](https://musicmake.ai/blog/udio-terms-of-service-commercial-use-2026) a [New Industry Focus: Udio downloads](https://newindustryfocus.com/articles/udio-allows-downloads-for-48-hours-following-umg-deal-outcry) — walled garden, vlastníctvo Udio/licensors.
10. [TechCrunch: ElevenLabs Music cleared for commercial use](https://techcrunch.com/2025/08/05/elevenlabs-launches-an-ai-music-generator-which-it-claims-is-cleared-for-commercial-use/) a [Billboard: Merlin & Kobalt licences](https://www.billboard.com/pro/elevenlabs-ai-music-model-merlin-kobalt-licenses-details/) — licencovaný tréning, výnimky pre film/TV/Studio Games.
11. [TechTimes: ElevenLabs × UMG deal 09/2026](https://www.techtimes.com/articles/327314/20260911/elevenlabs-signs-first-lawsuit-free-ai-music-deal-umg-fans-get-remix-platform.htm) — prvá bezžalobná dohoda s majorom.
12. [Apple Developer Forums: Apple Music API & licenses](https://developer.apple.com/forums/thread/681105) a [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — 4.5.2 „MusicKit nie je náhrada licencie“, 5.2.3 zákaz sťahovania.
12b. [iTunes Search API terms (Apple Performance Partners)](https://performance-partners.apple.com/search-api) a [Apple Music Feed API clauses](https://lawinsider.com/clause/apple-music-feed-api) — ukážky „not used for independent entertainment value apart from promotional purpose“, promo obrazovka + atribúcia; predchádzajúci research [audio-questions-legal-feasibility-2026-08.md](audio-questions-legal-feasibility-2026-08.md).
13. [Spotify: Changes to Web API (27. 11. 2024)](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api) a [community thread Preview URLs deprecated](https://community.spotify.com/t5/Spotify-for-Developers/Preview-URLs-Deprecated/td-p/6791368) — nové appky bez preview_url.
14. [ClicknClear: Sound-alikes, all you need to know](https://www.clicknclear.com/post/sound-alikes-all-you-need-to-know) — soundalike neprináša práva vydavateľa.
15. [US Copyright Office: What musicians should know](https://www.copyright.gov/engage/musicians/) a [Wikipedia: Synchronization rights](https://en.wikipedia.org/wiki/Synchronization_rights) — skladba vs. nahrávka, sync/mechanical.
16. App Store príklady intro-quizov na MusicKit ukážkach: [Intro King](https://apps.apple.com/jp/app/intro-king/id6449006748?l=en-US), [MusIQ](https://apps.apple.com/us/app/musiq-guess-the-song/id6748839500), [Heard-It!](https://apps.apple.com/us/app/heard-it-music-trivia-game/id6747206677).
