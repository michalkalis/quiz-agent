# #201 — Zábava, na ktorú sa dá odpovedať

**Triage:** enhancement · in-progress
**Založené:** 2026-10-13 (founder: „entertainment otázky sú trochu nudné, takmer bez šance vedieť odpoveď“)
**Súvisí:** #195 (čerstvá zábava, 2× zvýhodnenie), #199 (zásoba čerstvej zábavy), [prior art](../research/question-craft-prior-art-2026-07-10.md), [kalibrácia](../research/question-quality-founder-calibration-2026-07-09.md)

## Cieľ a kedy je hotovo

Otázky zo zábavy, na ktoré má bežný dospelý v krajine hráča reálnu šancu (tipnúť, odhadnúť, vylúčiť), bez straty zábavnosti. Podiel noviniek ostáva.

**Hotovo** = founder v slepom porovnaní (10 starý recept vs 10 nový, en; potom sk) hodnotí nový recept aspoň rovnako na zábavu a výrazne vyšší podiel „mal som šancu“. Až potom sa recept stane predvoleným pre ďalšie dopĺňanie zábavy (#199). Prenos na ostatné kategórie = samostatné rozhodnutie podľa výsledku.

## Diagnóza (2026-10-13, vzorka 32 otázok z behov 10-08 a 10-12)

- 41 % takmer nemožných, 25 % ľahkých len vďaka nápovede v znení („bývalý Kylo Ren“, „hrá Olivia Benson“), ~⅓ naozaj tipovateľných.
- Typy: ceny/nominácie 34 %, herci/štáb 19 %, zákulisie hudby 16 %; virálne 1/79.
- **Čerstvé behy idú cez všeobecný `direct_v1` prompt, nie cez `question_generation_entertainment_v2.md`** (37/39 otázok `prompt_version: direct_v1`). Pravidlo „slávne mená“ z v2 sa tak neuplatňuje vôbec; tón určuje brief + zoznam „seed“ faktov.
- Seedy sú dátumové novinky typu „kto vyhral kategóriu X“, brief žiada „mostly July–October 2026“.
- Slepá kontrola zodpovedateľnosti (`app/verification/answerability.py`) hrá „silného hráča“; pri uzavretej otázke o udalosti po jeho cutoffe nemôže vedieť odpoveď, takže **prepúšťa hlavne otázky, ktoré odpoveď prezradia**, a férové vyradí ako `wrong_answer`. O bežnom človeku nemeria nič.
- Pilot #167 (founder 8–10/10) = veľké titulky, porovnania, odhady — nie drobnosti.

Výskum (10-13): zvedavosť vrcholí pri „mám tip, nie som si istý“ (Kang, Loewenstein a kol. 2009, https://nautil.us/curiosity-depends-on-what-you-already-know-235803); autor kvízov mieri ~70 % správnych v mixe (anekdota, nie štúdia: https://annabookbel.net/quizzing-and-the-art-of-writing-good-quiz-questions/); najprv slávna vec, potom prekvapivý uhol; popularita entity (návštevnosť článku na Wikipédii) predpovedá, čo ľudia poznajú (PopQA, arXiv 2212.10511).

## Rozhodnutia foundera (2026-10-13)

- Schválené na slepé porovnanie páky **1** (sláva najprv), **2** (kontrola „bežný hráč“ + vyradiť prezradené), **3** (cieľ ~70 %, mix), **5** (nepoznateľné → 3 možnosti), **6** (domáca SK/CZ zábava).
- **Novinky ostávajú** (páka 4 „menej noviniek“ zamietnutá). Páky 1/2 sa uplatnia aj na novinky.
- Zábava je viazaná na jazyk = národ: sk = prevažne slovenské celebrity, reality šou, domáca scéna; cs obdobne.
- Zdroje nie len Wikipédia. Hierarchia ostáva: Wikipédia → doménové autority (IFPI, ČSFD na popularitu, Billboard…) → renomované médiá; žiadne agregátory ani bulvár.
- Reddit (r/todayilearned a podobné) ako zdroj nápadov; otázka sa napíše nanovo, fakt sa overí cez dôveryhodný zdroj (`source_url` povinné).
- Odložené: formát postupných nápovedí, formát „tri príbehy, jeden pravdivý“.

## Riešenie

Princíp: jadro promptov sa nemení (founder 09-03: kvalita sa nesmie znížiť ani zmeniť; zmena pipeline len za vypínačom a po slepom porovnaní). Mení sa recept behu (seedy + brief = vyhradené sloty) a pribúda nová kontrola za vypínačom, predvolene vypnutá.

### 201.1 Seedy: sláva najprv (páky 1, 6, Reddit)

Recept zberu seedov pre čerstvé behy (zapísaný v run adresári, robí ho agent cez web):
- Zdroje nápadov: najčítanejšie články Wikipédie za posledných 30 dní v jazyku hráča (Wikimedia pageviews API „top“, bez kľúča), Google „Rok vo vyhľadávaní“ SK/CZ, IFPI rebríčky (domáce hity SK/CZ), sledovanosť TV (MediaGuru / PMT) pre reality šou, Reddit top za mesiac (r/todayilearned, r/popculturechat, r/movies, r/Slovakia, r/czech) — čítané ako nápady, nie hromadne sťahované.
- Každý seed nesie **slávu témy**: mesačná návštevnosť článku o hlavnej entite v jazyku hráča (en/sk/cs Wikipédia) cez nový skript `apps/quiz-pack-api/scripts/entity_fame.py`. Seedy pod prahom sa vyhodia (prah sa kalibruje na prvom behu, štart: horná tretina zoznamu).
- Seed = „vec, o ktorej sa hovorilo“ + jeden prekvapivý uhol, nie „kto vyhral vedľajšiu kategóriu“.
- sk/cs: ≥ ~70 % domácich seedov, zvyšok svetové megahity.

### 201.2 Brief v2 (páky 1, 3, 5)

Nový text briefu (len `--prompt` slot), oproti dnešnému pridáva:
- pýtaný detail musí byť niečo, čo bežný sledovateľ mohol zachytiť, alebo si to odvodiť — nestačí, že je slávne meno;
- cieľ: priemerne ~7 z 10 bežných hráčov aspoň tipne správne; mix pár ľahkých a pár ťažších;
- detail, ktorý sa nedá vedieť ani odvodiť (presné číslo, víťaz kategórie) → otázka s 3 jasne odlišnými možnosťami alebo iný fakt; MCQ stále najviac ~30 %;
- žiadna nápoveda, ktorá odpoveď prezradí (popis, ktorý jednoznačne ukáže na meno);
- freshness časť ostáva ako dnes.

### 201.3 Kontrola „bežný hráč“ (páka 2, 3) — kód

Nový `CasualPlayerChecker` (`app/verification/casual_player.py`) zapojený **do `ScoringStage`** ako voliteľný spolupracovník, vypínač `CASUAL_PLAYER_GATE` (`0` predvolene / `shadow` / `1`) + `CASUAL_PLAYER_CATEGORIES=entertainment`.
- Prečo v scoringu: beží **po overení**, keď direct-mode otázka už má zdroj od overovača (`_attach_source` vo `VerificationStage`) — bez neho by kontrola o udalosti po svojom cutoffe len hádala. A tú istú inštanciu scoringu používa aj `TopUpStage`, takže stačí zapojiť v CLI (`generate_pack._build_stages`) a vo workeri (`app/worker/tasks.py`) — platí aj pre predvolený prod režim `PACK_BATCH_SCHEDULE`.
- Jedno volanie na otázku (Sonnet 5.5 — pozná aj domácu scénu; haiku nestačí, viď #195). Model vidí otázku, možnosti, odpoveď, zdrojový úryvok, jazyk → krajinu hráča a dnešný dátum.
- Vráti JSON: odhad % bežných dospelých v krajine, ktorí by trafili (0–100), `leak` (znenie samo prezradí odpoveď niekomu, kto fakt nepozná — odlíšiť od férovej dedukcie), krátke zdôvodnenie.
- `1`: vyradí `leak` a odhad pod podlahou (štart 25 %). `shadow`: nevyraďuje, len zapíše verdikt. Verdikt vždy do `generation_metadata.extra.casual_player` (meranie mixu aj ablácia v 201.4).
- Slepá kontrola zodpovedateľnosti: pri zapnutej kontrole (`1` aj `shadow`) v rovnakých kategóriách sa **len pri otvorených textových otázkach** nevyraďuje `wrong_answer` (slepý model nemôže poznať udalosť po cutoffe, takže dnes prepúšťa prezradené a vyraďuje férové). Pri MCQ ostáva vyradenie pri nezhode — to je poistka proti druhej obhájiteľnej možnosti. Obe miesta čítajú jednu funkciu `feature_flags.casual_player_applies(category)`.
- Výpadok volania = otázka ostáva (rovnaké pravidlo ako ostatné kontroly).
- Testy: prezradená vypadne, pod podlahou vypadne, férová prejde, `shadow` nevyraďuje ale zapisuje, výpadok ponechá, iná kategória sa nekontroluje, vypínač OFF = dnešné správanie, MCQ nezhoda vypadne aj pri zapnutej kontrole.

Mix (páka 3) sa v tomto kroku iba **meria** (rozdelenie odhadov); výberová logika podľa pásiem príde len ak bude rozdelenie mimo cieľa.

### 201.4 Slepé porovnanie

- Rovnaký deň, počet a **pripnutý `GENERATION_MODEL`** (inak `GEN_ALT` náhodne prehodí časť behov na iný model). Rameno A = dnešný recept (brief + seedy ako 10-12, kontrola OFF). Rameno B = 201.1 + 201.2 + kontrola v režime `shadow`.
- en: 10 z A + 10 z B, ktoré kontrola prepustila, + ~5 z B, ktoré by vyradila — zamiešané, bez označenia, kľúč k ramenám v run adresári `docs/testing/runs/gettable-entertainment-2026-10-13/`. Founder hodnotí zábavu 1–10 a „mal som šancu“ áno/nie. Vyradené vs prepustené ukáže, či kontrola sama pomáha (ablácia bez ďalšieho ramena).
- sk v tom istom hodnotení (8 + 8 + ~4, jedno kolo pre foundera namiesto dvoch) — overí domácu scénu a kontrolu Sonnetom.
- Výsledok + rozhodnutie sem a do pamäte.

**Výsledok (2026-10-13, 44 otázok, `analyze_ratings.py` v run adresári):**

| Skupina | n | Zábava ⌀ | Šanca | Zábava 9–10 |
|---|---|---|---|---|
| A (starý recept) en / sk | 10 / 8 | 7,9 / 9,2 | 10/10 / 8/8 | 4 / 7 |
| B prepustené en / sk | 10 / 8 | 7,7 / 9,2 | 8/10 / 8/8 | 1 / 6 |
| B vyradené kontrolou en / sk | 4 / 4 | 7,8 / 8,2 | 3/4 / 4/4 | 1 / 1 |

- **B neporazil A.** Spolu 8,4 vs 8,5, šanca 16/18 vs 18/18. Recept seedov + brief v2 merateľne nepomohol.
- **Kontrola „bežný hráč“ nepredpovedá hodnotenie** (korelácia odhadu so zábavou 0,10; otázky, ktoré by vyradila, 8,4 a šanca 11/12 — vrátane dvoch za 10). Zapnutie by vyhadzovalo dobré otázky → `CASUAL_PLAYER_GATE` ostáva `off`.
- **Najsilnejší signál je jazyk/národ:** sk 9,0 vs en 7,8 v oboch ramenách; founder: „fakt je rozdiel či sú to slovenské alebo anglické otázky, toto je veľmi dôležité pre zábavnosť“.
- Najnižšie hodnotené (6–7): ocenenia („kto čo kedy vyhral“), štáb a tvorcovia (režisér, bábkoherec), americky/niche témy (Nintendo, BTS čísla, Razzie). Najvyššie: veľmi známe veci s prekvapivým uhlom (Netflix, Tom Holland, McConaughey/Harrelson, Harry Potter, Eurovízia/Elán, Warhol/Medzilaborce).
- Otvorená číselná otázka (Baby Shark „10 billion“) nehovorí, aká odchýlka sa ráta → číselné otázky len ako MCQ alebo s uvedenou presnosťou.
- Founder upozorňuje, že jeho hodnotenie je jeden hráč; skutočný signál prinesie beta.

### 201.5 Nasadenie receptu

Po víťazstve B: recept seedov + brief v2 ako predvolené pre dopĺňanie čerstvej zábavy (#199), `CASUAL_PLAYER_GATE=1` pre zábavu v prode (pack-api). Ostatné kategórie = nové rozhodnutie foundera.

## Riziká

- Slovenská Wikipédia má o domácich celebritách krátke alebo žiadne články → zdroj z cs/en Wikipédie alebo autority; inak otázka vypadne. Domácich otázok môže byť spočiatku menej.
- Odhad „% bežných ľudí“ od modelu je nepresný (výskum: LLM odhaduje obtiažnosť len stredne dobre) → slúži ako sito na extrémy, nie presné číslo; podlaha nízko.
- Reddit: podmienky zakazujú hromadné sťahovanie a komerčné API bez dohody → len ručné čítanie top príspevkov ako nápad, fakt a `source_url` vždy z iného zdroja.

## Stav

- [x] 201.1 recept seedov + `entity_fame.py`
- [x] 201.2 brief v2
- [x] 201.3 `CasualPlayerChecker` v scoringu za vypínačom + testy (PR #394, vypnuté)
- [x] 201.4 slepé porovnanie en + sk — B ≈ A, kontrola nepomáha
- [ ] 201.5 nasadenie receptu
