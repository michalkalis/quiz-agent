# Tvoj Trubbo prehľad

Founder 2026-10-27: z pôvodných nápadov (pohyb telefónu, hlas, váhanie) ostáva **len smer Spotify Wrapped**, teda osobný prehľad, ako hráč hrá. Tento dokument hovorí, čo sa dá merať a kedy má zmysel prehľad ukázať.

## Zhrnutie

- **Väčšinu už meriame.** Kategórie, výsledky, čas hry, počet otázok, či hrá cez auto alebo reproduktor, povely: to všetko appka už posiela. Prehľad sa z toho dá poskladať bez nových povolení.
- **Chýbajú tri veci:** časové pásmo hráča (bez neho „hráš večer“ vyjde o hodiny vedľa), rýchlosť odpovede (na „najrýchlejšiu kategóriu“) a väzba hráča naprieč zariadeniami pred prihlásením.
- **Prvý prehľad po ~60 odpovediach v aspoň 3 rôznych dňoch**, čo je asi 40 minút hry. Potom mesačne, ak hráč v mesiaci hral, a veľký ročný prehľad v decembri.
- **Každá karta má vlastný prah.** Kým nie je dosť dát, karta sa neukáže alebo ukáže „ešte 2 hry“. Nikdy netvrdíme niečo, čo dáta nenesú.

## Ako to robia iní

| Kto | Kedy ukáže | Čo z toho beriem |
|---|---|---|
| Spotify Wrapped | raz ročne, už od ~30 skladieb od 5 interpretov | nízky prah na vstup, osobnostné typy, tipni si svoje čísla |
| Spotify Listening stats (2025) | každý týždeň, kĺzavé 4 týždne, jeden „highlight“ týždňa | častejší kontakt, jedna zaujímavosť navrch |
| Apple Music Replay | od februára, mesačne, ukazuje postup k odomknutiu | lišta „ešte toľkoto do prehľadu“ |
| Duolingo Year in Review | 2020: aspoň 7 dní a 20 lekcií; 2021: aspoň 5 dní | prah má byť aj v **dňoch**, nielen v množstve |
| HomeExchange (Wrapped štýl) | jednorazovo | 67 % otvorení, ľudia dopozerali do konca (údaj od dodávateľa) |

## Čo hráč v Trubbo reálne robí

Ostré dáta za posledných 60 dní (len 2 hráči, 28 hier, teda orientačné):

- bežná hra trvá **asi 3 minúty** a má **5 otázok**,
- jedna otázka aj s vysvetlením trvá **asi 40 sekúnd**,
- najaktívnejší hráč (founder) má 80 odpovedí v 9 dňoch.

Z toho: 60 odpovedí je asi 40 minút hry, čo je pri bežnom hraní 1 až 2 týždne.

## Čo sa dá merať

<span class="badge ok">máme</span> dáta sa už zbierajú · <span class="badge warn">doplniť</span> treba malú úpravu v appke · <span class="badge bad">nemáme</span> treba nové meranie

| Karta | Príklad vety | Dáta | Kedy sa odomkne |
|---|---|---|---|
| Najlepšia kategória | „Tvoja silná stránka: Geografia, 82 %.“ | <span class="badge ok">máme</span> | aspoň 3 kategórie s 10+ odpoveďami; ukázať len ak vedie o 10+ bodov, inak „si všestranný“ |
| Najslabšia kategória | „Hudba ťa ešte potrápi.“ | <span class="badge ok">máme</span> | rovnako; vždy jemne, nikdy ako výčitka |
| Kde hráš | „Dve tretiny hier v aute.“ | <span class="badge ok">máme</span> | 5+ hier; rozlišujeme auto (CarPlay, autorádio), reproduktor, slúchadlá |
| Kedy hráš | „Si večerný hráč. Najčastejšie v nedeľu.“ | <span class="badge warn">doplniť</span> časové pásmo | 5+ hier v 3+ dňoch |
| Bežná hra | „Zvyčajne hráš 4 minúty, 6 otázok.“ | <span class="badge ok">máme</span> | 5+ hier |
| Spolu | „Spolu 312 otázok, 3 hodiny kvízu.“ | <span class="badge ok">máme</span> | vždy |
| Zlepšuješ sa? | „Za mesiac si o 12 bodov lepší.“ | <span class="badge ok">máme</span> | 150+ odpovedí za 3+ týždne; porovnávať pri rovnakej obťažnosti; pri malom rozdiele „držíš formu“ |
| Najdlhšia séria | „9 správnych za sebou.“ | <span class="badge ok">máme</span> | 1 hra |
| Ťažké otázky | „Z ťažkých otázok si dal 7 z 10.“ | <span class="badge ok">máme</span> | 10+ ťažkých odpovedí |
| Výber z možností vs. vlastná odpoveď | „S možnosťami si istejší.“ | <span class="badge ok">máme</span> | 10+ z každého |
| Obľúbený povel | „Najčastejšie si pýtal zopakovať otázku.“ | <span class="badge ok">máme</span> | 5+ povelov |
| Denná výzva | „Výzvu si dal 12×, 3× bez chyby.“ | <span class="badge ok">máme</span> | 3+ výzvy |
| Najrýchlejšia / najpomalšia kategória | „Na šport odpovedáš za 2 s, na vedu za 6 s.“ | <span class="badge bad">nemáme</span> rýchlosť odpovede | 10+ meraných odpovedí v kategórii |
| Vzácny zásah | „Toto vedelo len 8 % hráčov.“ | <span class="badge ok">máme</span> | až keď otázku hralo 30+ ľudí (platné pravidlo z gamifikácie) |
| Typ hráča | *Rýchlostrelec*, *Cestovateľ*, *Nočná sova* | z kariet vyššie | po prvom prehľade |

**Vedome vynechané:** poloha (doma vs. inde) by vyžadovala povolenie polohy a na zábavnú štatistiku to nestojí. „Kde hráš“ sa preto odvodzuje len z toho, kam ide zvuk.

## Kedy prehľad ukázať

| Prehľad | Prah | Prečo |
|---|---|---|
| **Prvý prehľad** | 60 odpovedí v 3+ dňoch (asi 40 min hry) | stačí na 3 až 4 kategórie s 10+ odpoveďami; dni zabezpečia, že „kedy a kde hráš“ nie je náhoda jedného večera |
| **Mesačný** | v mesiaci 30+ odpovedí v 2+ dňoch; inak sa mesiac ticho preskočí | ako Apple Replay a Spotify týždenné štatistiky; neotravuje neaktívnych |
| **Ročný (december)** | 150+ odpovedí za rok | veľká zdieľateľná udalosť ako Wrapped, dáta do konca novembra |
| **Stále v profile** | karty sa odomykajú postupne | zamknutá karta ukazuje „ešte 2 hry“, ako postup v Apple Replay |

Prahy prepočítať, keď bude viac hráčov. Dnešné čísla stoja na dvoch ľuďoch.

## Čo treba doplniť pred stavbou

1. **Časové pásmo hráča** pri štarte hry. Malá úprava, bez povolenia.
2. **Rýchlosť odpovede**: čas od dočítania otázky po začiatok reči. Hlasový záznam to už takmer meria, chýba to uložiť.
3. **Jeden hráč naprieč zariadeniami**: bez prihlásenia má každé zariadenie vlastnú históriu. Prehľad je teda „na tomto zariadení“, kým sa hráč neprihlási.
4. **Výpočet na serveri**, raz za deň alebo pri otvorení prehľadu. Bez AI, len počty, takže lacné a rýchle.

## Rozhodnutia foundera (2026-10-27)

1. Rytmus: **mesačne aj ročne**, a štatistiky si hráč môže kedykoľvek pozrieť v appke.
2. Prehľad je **celý zadarmo**.
3. Zdieľateľná karta na Instagram a TikTok **hneď v prvej verzii**.
4. Nápad: dolná lišta so záložkami, posledná záložka **Profil** s údajmi o hráčovi a štatistikami. Ďalší krok: varianty návrhu na výber.

## Zdroje

- Spotify Wrapped, prah 30 skladieb: <https://bgr.com/2042375/spotify-wrapped-2025-now-available/>
- Spotify Wrapped 2025: <https://newsroom.spotify.com/?p=37765>
- Spotify Listening stats: <https://www.androidauthority.com/spotify-weekly-listening-stats-3613636>
- Apple Music Replay: <https://www.macrumors.com/2026/02/03/apple-music-replay-2026-now-available/>
- Duolingo Year in Review 2020: <https://blog.duolingo.com/duolingo-2020-year-in-review>
- Duolingo Year in Review 2021: <https://blog.duolingo.com/year-in-review-2021/>
- HomeExchange case study: <https://inappstory.com/case-studies/case-study-stories-homeexchange>
- Rozpoznanie auta podľa zvukového výstupu: <https://bignerdranch.com/blog/detecting-caraudio>
- Pôvodne zvážené a zamietnuté nápady (pohyb, hlas, emócie): Nintendo patent <https://patents.google.com/patent/US8821298>, EÚ AI Act čl. 50 <https://artificialintelligenceact.eu/transparency-rules-article-50/>
