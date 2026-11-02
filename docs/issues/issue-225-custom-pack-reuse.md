# #225 — Vlastný balík: rovnaké zadanie = hotové otázky

**Triage:** enhancement · blocked-on-#224 (224.3 — obťažnosť v objednávke)
**Status:** plán 2026-11-02; implementácia po zlúčení 224.3
**Založené:** 2026-11-02 (founder)
**Súvisí:** #224 — TF test 2026-11-02 (224.3 povinná obťažnosť), #143 — Custom-pack COGS reduction, #182 — Custom pack: hrať hneď po prvej otázke, #93 — vlastné balíky

## Cieľ

Keď si hráč B objedná vlastný balík s rovnakým zadaním, jazykom a obťažnosťou ako už hotový balík hráča A, dostane hneď kópiu otázok z A, bez generovania. Šetrí ~$4 na balík (#143) a B nečaká.

## Rozhodnutia foundera (2026-11-02)

- **Zhoda = rovnaký text** po úprave: bez ohľadu na veľké písmená, medzery a interpunkciu („Harry Potter“ = „harry potter!“). Nie podľa významu.
- **Plná cena** aj pri hotovom balíku.
- **Ten istý hráč, to isté zadanie znova** → generuje sa nový balík (hotový dostanú len iní).
- **Veľkosti:** dnes je len jedna veľkosť vlastného balíka, takže otázka „väčší balík ako hotový“ zatiaľ odpadá. Nápad do budúcna: ponúknuť kúpu väčšieho balíka (zaznamenané, nerieši sa).

## Predpoklady agenta (technické)

- Kľúč zhody: upravený text zadania + jazyk + obťažnosť + kategória + téma + počet otázok. Objednávky zo starších buildov bez obťažnosti sa párujú len medzi sebou (bez obťažnosti = zmiešaná).
- Úprava textu: Unicode NFKC, malé písmená, interpunkcia → medzera, zlúčené medzery. **Diakritika sa zachováva** („Pán prsteňov“ ≠ „Pan prstenov“), lebo môže meniť význam; ak data ukážu, že ľudia píšu bez mäkčeňov, dá sa prehodnotiť.
- Skryté značky v texte zadania (MCQ dôraz, priame generovanie) sú súčasťou textu, takže sa porovnávajú automaticky.
- Súkromie: kópia sa dá len pri presnej zhode textu, ktorý B sám napísal, takže sa nič nové neprezradí. Otázky z A sa kopírujú do nového balíka vlastneného B; balík A sa nemení a kontrola vlastníctva pri hraní ostáva bez zmeny.

## Kedy sa hotový balík použije (zdroj)

Zdroj musí byť: objednávka iného hráča, stav `delivered`, balík `complete` s plným počtom otázok, objednávka nevrátená (refund), v balíku žiadna nahlásená chyba v otázke. Z viacerých vhodných sa berie najnovší. Ak B už vlastní kópiu z toho istého zdroja, zdroj sa preskočí.

Ak zhodný balík ešte len vzniká, B dostane normálne generovanie (jednoduchšie; čakanie na cudzí beh by viazalo B na zlyhanie A).

## Návrh riešenia

1. **Databáza:** nový stĺpec `prompt_key` (upravený text) na objednávke + index na (prompt_key, language, difficulty, category, theme, target_count); stĺpec `reused_from_order_id`. Migrácia nadväzuje na migráciu z 224.3. Doplniť `prompt_key` aj starým objednávkam (spätne, v migrácii).
2. **Objednávka:** v `create_order` po všetkých dnešných kontrolách (StoreKit, idempotencia, pauza objednávok) a vložení objednávky: hľadanie zdroja. Pri zhode sa v jednej transakcii vytvorí nový balík pre B, skopírujú sa otázky (nový `pack_id`, ostatné polia rovnaké vrátane zdrojov a obťažnosti), objednávka = `delivered`, náklady 0, žiadne zaradenie do fronty. Bez zhody = dnešný tok.
3. **Poistka:** prepínač v DB (`app_switches`), predvolene zapnutý; vypnutie = vždy generovať.
4. **Analytika (v tom istom PR):** pri každej objednávke záznam, či bola z hotového balíka (+ zdroj), aby sa dala vyčísliť úspora; súčet v admin prehľade nákladov.
5. **iOS:** bez zmeny API. Overiť, že appka zvládne objednávku, ktorá je hotová hneď pri prvom zistení stavu (sledovanie stavu, SSE, „pripravujem ďalšiu otázku“).

## Testy (prečo, nielen čo)

- Rovnaké zadanie s inými veľkými písmenami/interpunkciou od iného hráča → hotová kópia, žiadne volanie generátora, náklady 0 (úspora je celý zmysel).
- Iná obťažnosť alebo iný jazyk → generovanie (inak by B dostal zlý balík).
- Ten istý hráč znova → generovanie (founder: zaplatil za nové otázky).
- Zdroj vrátený / nedokončený / s nahlásenou chybou → nepoužije sa (nešíriť zlé balíky).
- Kópia patrí B, A ju nevidí a naopak; balík A ostáva nezmenený.
- Vypnutý prepínač → vždy generovanie.

## Kolízie

224.3 (iná session) práve mení objednávku, model objednávky, generátor a pridáva migráciu. Implementácia #225 začne až po zlúčení 224.3 do `main`, vo vlastnej vetve z aktuálneho `main`.

## Stav

- [ ] 225.1 backend (DB, objednávka, poistka, analytika, testy) — po 224.3
- [ ] 225.2 overenie iOS toku s okamžite hotovou objednávkou (simulátor)
- [ ] 225.3 nasadenie + overenie na prode (druhá objednávka rovnakého zadania)
