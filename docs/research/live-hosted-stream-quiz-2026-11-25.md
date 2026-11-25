# Živý kvíz s founderom na streame (#247)

Stav: nápad foundera 2026-11-25, malá rešerš. Nič sa nestavia, kým founder nerozhodne.

**Nápad:** founder občas osobne moderuje verejný kvíz, streamuje ho (Twitch, YouTube, TikTok alebo Instagram Live) a diváci sa pripoja mobilom cez QR kód alebo odkaz na obrazovke a hrajú naraz s ním, s poradím naživo.

## Záver v skratke

- **Ako zdroj inštalácií sám o sebe asi nestačí.** Nový stream mívá 5 až 30 divákov naraz. Aj zabehnutý nemecký moderátor kvízov s 18 tis. sledujúcimi mal v priemere 78 ([mein-mmo](https://mein-mmo.de/en/twitch-tim-horus-quizshows,1541149/)).
- **Hodnota je v obsahu.** Nemecké kvízové show sa šíria cez zostrihy na YouTube, TikToku a Instagrame, nie cez samotný priamy prenos. Pre Trubbo je stream dobrý zdroj klipov na sociálne siete (zapadá do [#210 — marketing na sociálnych sieťach](../issues/issue-210-social-marketing.md)).
- **Komunita a tvár značky.** Founder ako moderátor = osobný kontakt s hráčmi, spätná väzba naživo, dôvod sa vrátiť v pravidelný čas.
- **V SK/CZ sme žiadny zabehnutý kvízový stream nenašli.** Môže to byť voľné miesto, ale aj znak, že dopyt je malý. Slovenská Twitch scéna je malá ([TwitchTracker](https://twitchtracker.com/languages/Slovak)).
- **Odporúčanie:** 2 až 3 skúšobné streamy so sledovaným odkazom. Pokračovať len vtedy, keď počet inštalácií a klipov na jeden stream stojí za tú námahu.

## Čo sa osvedčilo inde

| Kto | Ako | Poučenie |
|---|---|---|
| HQ Trivia | 2M+ hráčov naraz, peňažné výhry, koniec 2020 | Výhry z vlastného vrecka, podvádzanie robotmi, výpadky serverov, závislosť od jedného moderátora. Len hry v pevný čas nestačili ([TechCrunch](https://techcrunch.com/2020/02/14/hq-trivia-shuts-down), [Slidebean](https://slidebean.com/blog/what-happened-to-hq-trivia)) |
| Jackbox na Twitchi | Diváci zadajú kód miestnosti na webe, alebo hrajú priamo v Twitchi | Najbližší funkčný model; odporúčajú režim s nízkym oneskorením, max ~10 s ([Jackbox](https://www.jackboxgames.com/blog/dodo-re-mi-latency-faq)) |
| Kvíz v krčme na Twitchi (Geeks Who Drink) | Týždenne, ~1 000 divákov | Pevný týždenný termín funguje, ale ide o veľkú značku |
| Crowdpurr, Kahoot a podobné | Web, odkaz alebo kód, bez inštalácie | Všetky nástroje na streamy idú cez web, nie cez appku |

## Ako by to mohlo vyzerať v Trubbe

**Formát (odhad, dáta k tomu nie sú):** raz týždenne alebo raz za dva týždne, 20 až 30 minút, 10 až 15 otázok, téma večera (napr. sezónna, desaťročia, SK a CZ). Founder číta otázky a komentuje odpovede, na konci poradie a pozdrav víťazom.

**Pripojenie:** QR kód a krátky kód miestnosti stále na obrazovke streamu.

**Oneskorenie streamu (5 až 15 s) je hlavný technický problém.** Riešenie, ktoré používajú ostatní: otázka sa ukáže priamo v mobile a čas na odpoveď beží každému od chvíle, keď ju jeho mobil dostal. Stream je len moderovanie navyše. Odhalenie správnej odpovede a poradie sa ukážu s malým odkladom, aby moderátor neprezradil odpoveď skôr, než ju divák uvidí ([Crowdpurr](https://community.crowdpurr.com/t/solved-mitigating-streaming-latency-when-using-crowdpurr/42)).

**Výhry:** radšej žiadne peniaze. Stačí meno na streame, poradie, prípadne mesiac Trubbo Plus. Kvíz rozhodnutý vedomosťami je na Slovensku zrejme mimo hazardu, žrebovanie medzi účastníkmi je už propagačná lotéria. Česko sme neoverili a pred výhrami treba právnika ([CMS](https://cms.law/en/int/expert-guides/cms-expert-guide-to-gambling-laws-in-cee/slovakia)).

## Čo dnes chýba v Hre spolu ([#212](../issues/issue-212-multiplayer-same-room.md), [#230](../issues/issue-230-together-remote.md))

Hra spolu už vie miestnosť, QR aj odkaz a hru cez internet. Pre stream by chýbalo:

1. **Viac hráčov.** Miestnosť má dnes najviac 8 hráčov; stream potrebuje desiatky, výnimočne stovky.
2. **Hra bez appky.** Hosť si dnes musí stiahnuť appku (founder 10-28: bez App Clipu). Pri skenovaní zo streamu väčšina divákov inštaláciu nespraví. Webová stránka na hranie by išla, appka by bola ponuka až po hre. Toto je produktové rozhodnutie.
3. **Moderátor nehrá.** Founder len vedie hru z počítača alebo mobilu a ukazuje poradie na streame.
4. **Obrazovka pre stream.** Veľká otázka, QR, priebežné poradie, ktorú si founder pridá do vysielacieho programu (napr. OBS).
5. **Platenie:** dnes platí otázky hostiteľ (M1). Pri verejnom kvíze to nehrá rolu, hrá founder.
6. **Meranie:** sledovaný odkaz na stream, inštalácie a hráči z neho.

Lacnejší prvý krok bez vývoja: zahrať prvý stream cez existujúci nástroj (napr. Kahoot alebo Crowdpurr) s otázkami z Trubba. Overí sa, či ľudia prídu, a stavať sa začne až potom.

## Pravidlá platforiem

- **Twitch** zakazuje posielať divákov na *iný priamy prenos*. QR na kvízovú stránku by nemal byť problém, ale v oficiálnom texte to nie je potvrdené ([Twitch pravidlá](https://safety.twitch.tv/articles/en_US/Knowledge/Community-Guidelines)).
- **TikTok LIVE** chce vek 18+ a zrejme ~1 000 sledujúcich ([TikTok](https://newsroom.tiktok.com/tiktoklive?lang=en-ZA)). Trubbo účet treba overiť.
- **YouTube a Instagram:** pravidlá pre odkazy a QR sme neoverili. Treba to spraviť pred prvým streamom.
- **App Store:** webový kvíz sa ho netýka; výhry priamo v appke by mali vlastné pravidlá.

## Neisté miesta

- Žiadny zdroj nemeria inštalácie ani návratnosť z priamych prenosov pri malej appke. Prínos je odhad.
- Čísla o počte divákov sú z druhej ruky.
- Formát a dĺžka sú odhad, nie dáta.
